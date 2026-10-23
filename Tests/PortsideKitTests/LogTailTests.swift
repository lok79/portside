import XCTest
@testable import PortsideKit

/// 工单 07：日志尾随（GLOSSARY：日志流——"发现文件 → tail"的 tail 半边）。
/// 轮询经注入 ManualClock 驱动（测试不真睡，spec 低资源硬约束）；
/// 文件是真实临时文件（tail 的本质就是真实文件系统行为）。
/// 教训（工单 02/06）：所有等待有界、stop 后无残留（句柄以 lsof 实证）。
@MainActor
final class LogTailTests: XCTestCase {
    private var logURL: URL?
    private var tail: LogTail?

    override func tearDown() {
        // 必停兜底：任何用例失败中断也保证轮询任务与句柄清场。
        tail?.stop()
        tail = nil
        if let logURL {
            try? FileManager.default.removeItem(at: logURL)
        }
        logURL = nil
    }

    // MARK: - 测试辅助

    private func makeLogFile(content: String = "") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-tail-\(UUID().uuidString).log")
        if !content.isEmpty {
            try! content.write(to: url, atomically: false, encoding: .utf8)
        }
        logURL = url
        return url
    }

    private func append(to url: URL, _ text: String) {
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
        } else {
            try! text.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    /// 增量回调收集器（回调在轮询任务线程，加锁）。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [String] = []
        func record(_ chunk: String) {
            lock.withLock { chunks.append(chunk) }
        }
        var all: String { lock.withLock { chunks.joined() } }
        var count: Int { lock.withLock { chunks.count } }
        func clear() { lock.withLock { chunks = [] } }
    }

    private func makeTail(
        _ url: URL, clock: PortsideClock, recorder: Recorder,
        pollInterval: Duration = .milliseconds(500), maxLines: Int = 500
    ) -> LogTail {
        let tail = LogTail(
            url: url, clock: clock, pollInterval: pollInterval, maxLines: maxLines
        ) { recorder.record($0) }
        self.tail = tail
        return tail
    }

    private func waitUntil(
        timeout: TimeInterval = 5, _ what: String, _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw TestWaitTimeout(what: "LogTail：\(what)", timeout: timeout)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 一个轮询节拍：等循环真的挂上下一次 sleep，再拨过轮询间隔（ManualClock 惯用节拍）。
    private func pollTick(_ clock: ManualClock) async throws {
        try await clock.waitForSleepRegistration(timeout: 5)
        clock.advance(to: clock.now() + .milliseconds(500))
    }

    private static func lines(_ count: Int, prefix: String) -> String {
        (1...count).map { "\(prefix)-\($0)\n" }.joined()
    }

    // MARK: - 启动：读末尾（≤500 行）

    func test启动即读出现有全部行() async throws {
        let url = makeLogFile(content: "first\nsecond\nthird\n")
        let recorder = Recorder()
        let clock = ManualClock()
        makeTail(url, clock: clock, recorder: recorder).start()

        try await waitUntil("启动回填 3 行") { recorder.all == "first\nsecond\nthird\n" }
    }

    func test启动只读末尾500行() async throws {
        let url = makeLogFile(content: Self.lines(600, prefix: "old"))
        let recorder = Recorder()
        let clock = ManualClock()
        makeTail(url, clock: clock, recorder: recorder).start()

        try await waitUntil("回填落定") { recorder.count == 1 }
        let expectedLast500 = (101...600).map { "old-\($0)\n" }.joined()
        XCTAssertEqual(
            recorder.all,
            expectedLast500,
            "spec §6：命中后 tail 末尾 500 行（600 行文件取 old-101..old-600）"
        )
    }

    func test无换行结尾的半行先缓冲补全后才输出() async throws {
        let url = makeLogFile(content: "hel")
        let recorder = Recorder()
        let clock = ManualClock()
        makeTail(url, clock: clock, recorder: recorder).start()
        try await clock.waitForSleepRegistration(timeout: 5)
        XCTAssertTrue(recorder.all.isEmpty, "半行不输出")

        // 循环正停在 sleep#1：直接拨过间隔唤醒，不重等注册（不 advance 就不会有注册）。
        append(to: url, "lo\n")
        clock.advance(to: clock.now() + .milliseconds(500))

        try await waitUntil("半行补全后成整行输出") { recorder.all == "hello\n" }
    }

    // MARK: - 跟随：新写入在一个轮询间隔内出现

    func test追加新行在下一个轮询间隔出现() async throws {
        let url = makeLogFile(content: "boot\n")
        let recorder = Recorder()
        let clock = ManualClock()
        makeTail(url, clock: clock, recorder: recorder).start()
        try await waitUntil("回填 boot") { recorder.all == "boot\n" }
        recorder.clear()

        append(to: url, "tick-1\ntick-2\n")
        try await pollTick(clock)

        try await waitUntil("增量出现") { recorder.all == "tick-1\ntick-2\n" }
        XCTAssertEqual(recorder.count, 1, "一次轮询读出全部新增，合并为一次增量")
    }

    /// 工单验收：新写入 <1s 出现（生产默认 0.5s 轮询）。真实时钟端到端验证节拍。
    func test真实时钟下新写入一秒内出现() async throws {
        let url = makeLogFile(content: "")
        let recorder = Recorder()
        makeTail(url, clock: SystemClock(), recorder: recorder).start()
        try await waitUntil("空文件启动不输出（半行缓冲空）") { recorder.count == 0 }

        append(to: url, "fast-line\n")
        let deadline = Date().addingTimeInterval(1.0)
        while recorder.all.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(recorder.all, "fast-line\n", "新写入 <1s 出现（工单验收①）")
    }

    // MARK: - 轮转/截断：size 变小 → 重开读末尾

    func test文件被截断后重开读新内容末尾() async throws {
        let url = makeLogFile(content: Self.lines(10, prefix: "old"))
        let recorder = Recorder()
        let clock = ManualClock()
        makeTail(url, clock: clock, recorder: recorder).start()
        try await waitUntil("回填 10 行") { recorder.all == Self.lines(10, prefix: "old") }
        recorder.clear()

        // 轮转：原文件被换掉（size 从 60B 变 12B，必然变小）。
        try! "fresh-1\nfresh-2\n".write(to: url, atomically: false, encoding: .utf8)
        try await pollTick(clock)

        try await waitUntil("截断后重开并输出新内容") {
            recorder.all == "fresh-1\nfresh-2\n"
        }
    }

    func test文件未建时等待出现后跟随() async throws {
        let url = makeLogFile()   // 托管服务刚启动、落盘文件还没建的形态
        let recorder = Recorder()
        let clock = ManualClock()
        makeTail(url, clock: clock, recorder: recorder).start()
        // 首轮轮询落定并挂上 sleep#1（文件未建分支已走过）。
        try await clock.waitForSleepRegistration(timeout: 5)
        XCTAssertTrue(recorder.all.isEmpty, "文件未建：静默等待，不报错不装死")

        // 拨过间隔唤醒：文件出现 → 重开读出内容。
        try! "born-now\n".write(to: url, atomically: false, encoding: .utf8)
        clock.advance(to: clock.now() + .milliseconds(500))

        try await waitUntil("文件出现后读出内容") { recorder.all == "born-now\n" }
    }

    // MARK: - 停止：无残留任务、无残留句柄

    func teststop后不再有增量输出() async throws {
        let url = makeLogFile(content: "boot\n")
        let recorder = Recorder()
        let clock = ManualClock()
        let tail = makeTail(url, clock: clock, recorder: recorder)
        tail.start()
        try await waitUntil("回填 boot") { recorder.all == "boot\n" }

        tail.stop()
        recorder.clear()
        append(to: url, "after-stop\n")
        // stop 后循环已退出：不会再有 sleep 注册——直接拨时间并真等一拍，
        // 确认没有任何增量漏出（若任务未终止，这里会被真实轮询读出）。
        clock.advance(to: clock.now() + .seconds(10))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recorder.all, "", "stop 后不再有增量（轮询任务已终止）")
        XCTAssertFalse(tail.isFollowing, "isFollowing 复位")
    }

    func teststop后无残留文件句柄() async throws {
        let url = makeLogFile(content: "boot\n")
        let recorder = Recorder()
        let clock = ManualClock()
        let tail = makeTail(url, clock: clock, recorder: recorder)
        tail.start()
        try await waitUntil("回填落定（句柄已打开）") { recorder.all == "boot\n" }
        XCTAssertTrue(Self.holdsHandle(url), "跟随中确有句柄（对照组）")

        tail.stop()

        try await waitUntil("stop 后句柄关闭（lsof 实证，工单验收⑤）") {
            !Self.holdsHandle(url)
        }
    }

    func teststop可重复调用且未启动也能stop() {
        let url = makeLogFile(content: "")
        let tail = makeTail(url, clock: ManualClock(), recorder: Recorder())
        tail.stop()
        tail.stop()
        XCTAssertFalse(tail.isFollowing, "未启动/重复 stop 均无副作用")
    }

    /// 本进程是否仍持有该文件路径的句柄（独立事实来源：lsof）。
    /// lsof 报告内核 vnode 全解析路径（/private/var/…），与 URL 的符号链接解析形态
    /// （/var/…）差一个 /private 前缀——两形态都算命中。
    private static func holdsHandle(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().path
        let names = openHandlePaths(for: url)
        return names.contains(resolved)
            || names.contains("/private" + resolved)
            || names.contains(url.path)
    }

    /// 本进程持有该文件路径的句柄清单（独立事实来源：lsof）。
    private static func openHandlePaths(for url: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(getpid())", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }
    }
}
