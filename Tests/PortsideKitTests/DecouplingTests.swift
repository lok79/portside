import XCTest
import Darwin
@testable import PortsideKit

/// 工单 08：生命周期解耦集成测试（adr/0001——托管服务比 app 长命）。
///
/// **可测等价物设计**（测试不能对自身进程组发致命信号，否则测试自杀）：
/// `portside-host-sim` 是包内可执行替身——`setpgid(0,0)` 自成进程组（Portside
/// 本身也是一组领袖）、真跑 `ShellProcessController` 经 posix_spawn 起服务、
/// 起完原地挂起且**零退出清理路径**（无 atexit/信号处理器/终止钩子，被杀即裸死）。
/// 测试对宿主整组 `kill -9` = 等价「kill -9 Portside」，随后断言：
/// 服务进程存活、仍是独立组领袖、日志继续落盘、且**未变僵尸**（孤儿由 launchd
/// 接管收尸——宿主的 reaper 线程随宿主死亡，waitpid 权回到 init/launchd）。
@MainActor
final class DecouplingTests: XCTestCase {
    private var hostProcess: Process?
    private var logsDirectory: URL?
    /// 宿主替身起的服务 pid（= 组领袖；tearDown 兜底杀整组）。
    private var servicePID: pid_t?

    override func tearDown() {
        if let servicePID { kill(-servicePID, SIGKILL) }
        if let hostProcess, hostProcess.isRunning {
            kill(hostProcess.processIdentifier, SIGKILL)
        }
        hostProcess = nil
        servicePID = nil
        if let logsDirectory {
            try? FileManager.default.removeItem(at: logsDirectory)
        }
    }

    // MARK: - 测试辅助

    /// 定位包内构建出的宿主替身可执行（#filePath 上溯 3 级 = 包根）。
    private func locateHostSim() throws -> URL {        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PortsideKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根
        let buildRoot = packageRoot.appendingPathComponent(".build", isDirectory: true)
        // swift test 默认 debug；release/其他配置目录兜底（都用同包构建产物）。
        for configuration in ["debug", "release"] {
            let candidate = buildRoot
                .appendingPathComponent(configuration)
                .appendingPathComponent("portside-host-sim")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        let fallbacks = (try? FileManager.default.contentsOfDirectory(atPath: buildRoot.path)) ?? []
        for entry in fallbacks where !entry.hasSuffix(".txt") && !entry.hasSuffix(".json") {
            let candidate = buildRoot.appendingPathComponent(entry)
                .appendingPathComponent("portside-host-sim")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        XCTFail("找不到 portside-host-sim 构建产物（先 swift build）：\(buildRoot.path)")
        throw XCTSkip("宿主替身未构建")
    }

    /// 起宿主替身：自成组 + 真实 controller 起服务 + 零清理路径。
    /// 返回（宿主 pid，服务 pid）——服务 pid 从 STARTED 报告行解析。
    private func startHost(command: String) throws -> (host: pid_t, service: pid_t) {
        let host = Process()
        host.executableURL = try locateHostSim()
        let logs = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-decouple-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logsDirectory = logs
        host.arguments = [logs.path, command]

        let pipe = Pipe()
        // 跨线程缓冲盒（readabilityHandler 任意队列线程回调）。
        final class BufferBox: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()
            func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
            var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
        }
        let buffer = BufferBox()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
        }
        host.standardOutput = pipe
        host.standardError = FileHandle.nullDevice
        try host.run()
        hostProcess = host
        defer { pipe.fileHandleForReading.readabilityHandler = nil }

        // 有界等 STARTED 报告（起服务含判定窗，替身内已压到 0.3s）。
        let deadline = Date().addingTimeInterval(15)
        var text = ""
        while Date() < deadline {
            text = buffer.text
            if let range = text.range(of: "STARTED pid=") {
                let pidPart = text[range.upperBound...]
                    .prefix(while: { $0.isNumber })
                guard let pid = pid_t(pidPart), pid > 0 else {
                    XCTFail("宿主报告无 pid：\(text)")
                    throw TestWaitTimeout(what: "宿主报告 pid", timeout: 15)
                }
                return (host.processIdentifier, pid)
            }
            try awaitBounded(milliseconds: 20)
        }
        XCTFail("宿主 15s 内未报告 STARTED：\(text)")
        throw TestWaitTimeout(what: "宿主 STARTED 报告", timeout: 15)
    }

    /// 同步有界小睡（非 async 辅助里用；20ms 步进）。
    private func awaitBounded(milliseconds: UInt32) throws {
        usleep(useconds_t(milliseconds) * 1000)
    }

    /// 轮询直到条件成立或超时（有界 + 说明在等什么）。
    private func waitUntil(
        timeout: TimeInterval = 5, _ what: String, _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TestWaitTimeout(what: what, timeout: timeout) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func tickCount(in logURL: URL) -> Int {
        guard let data = try? Data(contentsOf: logURL) else { return 0 }
        return String(decoding: data, as: UTF8.self)
            .components(separatedBy: "sim-tick-").count - 1
    }

    /// 进程状态（ps stat 首字符；Z = 僵尸）。读不到返回 nil。
    /// nonisolated + 阻塞 ps：从 detached 任务调用，不占主 actor。
    private nonisolated static func processState(_ pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "stat=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(1))
    }

    // MARK: - 解耦：宿主死亡，服务照常活着

    func test杀掉宿主整组后服务存活且日志继续落盘() async throws {
        // 服务：循环落盘（tick 持续写入 = 输出通道仍由子进程握着）。
        let (hostPID, servicePID) = try startHost(
            command: #"while true; do echo "sim-tick-$RANDOM"; sleep 0.05; done"#
        )
        let logURL = logsDirectory!.appendingPathComponent("host-sim-service.log")
        self.servicePID = servicePID

        // 前置事实：服务活着、日志在涨（宿主还活着时）。
        try await waitUntil("宿主死亡前日志已累计写入 3 行") { self.tickCount(in: logURL) >= 3 }
        XCTAssertEqual(kill(servicePID, 0), 0, "前置：服务存活")
        XCTAssertEqual(getpgid(servicePID), servicePID, "前置：服务是独立组领袖（posix_spawn SETPGROUP）")

        // === 等价「kill -9 Portside」：对宿主整组发 SIGKILL ===
        kill(-hostPID, SIGKILL)
        try await waitUntil("宿主已死并被收尸") { !(self.hostProcess?.isRunning ?? true) }

        // 1) 服务进程存活（解耦核心：宿主死亡不殃及服务）。
        try await waitUntil("宿主死后服务仍存活") { kill(self.servicePID!, 0) == 0 }
        // 2) 未变僵尸：孤儿由 launchd 接管收尸（宿主的 reaper 随宿主死了，
        //    waitpid 权归 launchd——若实现留着 waitpid 挂钩或泄漏，这里会现形）。
        let state = await Task.detached { Self.processState(servicePID) }.value
        XCTAssertEqual(state, "S", "服务应正常运行（S）而非僵尸（Z）：实际 \(state ?? "无")")
        // 3) 日志继续落盘：句柄在子进程手里，宿主死了照写。
        let before = tickCount(in: logURL)
        try await Task.sleep(nanoseconds: 400_000_000)
        let after = tickCount(in: logURL)
        XCTAssertGreaterThan(
            after, before,
            "宿主死亡后日志仍在写入（before=\(before), after=\(after)）"
        )
        // 4) 服务仍是自己的组领袖（未被宿主组回收/收编）。
        XCTAssertEqual(getpgid(servicePID), servicePID)
    }
}
