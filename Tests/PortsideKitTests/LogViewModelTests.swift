import XCTest
@testable import PortsideKit

/// 测试替身：按注入返回发现结果的日志定位器（记录收到的上下文）。
final class FakeLogLocator: LogLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [LogAvailability]
    private(set) var contexts: [LogContext] = []

    init(_ availabilities: [LogAvailability]) {
        queued = availabilities
    }

    func locate(_ context: LogContext) async -> LogAvailability {
        let availability: LogAvailability = lock.withLock {
            contexts.append(context)
            if queued.count > 1 { return queued.removeFirst() }
            return queued.first ?? .notFound
        }
        return availability
    }
}

/// 测试替身：挂起直到测试放行的定位器（复现"发现未落定就返回"的竞速）。
final class GatedLogLocator: LogLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LogAvailability, Never>?
    private(set) var contexts: [LogContext] = []

    func locate(_ context: LogContext) async -> LogAvailability {
        lock.withLock { contexts.append(context) }
        return await withCheckedContinuation { c in
            lock.withLock { continuation = c }
        }
    }

    /// 放行挂起的 locate（无挂起则忽略）。
    func release(with availability: LogAvailability) {
        let continuation: CheckedContinuation<LogAvailability, Never>? = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: availability)
    }
}

/// 测试替身：记录 start/stop 次数的日志尾随器。
final class FakeTail: LogTailing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() { lock.withLock { startCount += 1 } }
    func stop() { lock.withLock { stopCount += 1 } }
}

/// 工单 07：面板日志流状态机（ViewModel 层，不触 UI）。
/// 关键钉子：**同一时刻最多一个活跃 tail；切换/返回/隐藏必停旧 tail；
/// 发现未落定就返回 → 过期结果丢弃不启动**（spec §6 + 工单资源安全要求）。
@MainActor
final class LogViewModelTests: XCTestCase {
    private let argv = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"
    /// 工厂产物收集器（工厂闭包 @Sendable，经此盒跨域记录）。
    private let tailBox = TailBox()

    override func tearDown() {
        // 兜底：任何未停的假 tail 记为停（真实资源安全由 stop 计数断言守着）。
        tailBox.tails.forEach { $0.stop() }
        super.tearDown()
    }

    private var tails: [FakeTail] { tailBox.tails }
    private var lastUpdateHandler: (@Sendable (String) -> Void)? { tailBox.updateHandler }

    // MARK: - 测试辅助

    /// 生产同构装配（同 ManagedActionFlowTests）：托管定义 + 匹配实例 + 外部实例。
    private func makeWiredModel(
        logLocator: LogLocating? = nil
    ) -> (PanelViewModel, ServiceDefinitionCenter, FakeScanner) {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        center.adopt(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")
        let scanner = FakeScanner([.success(ScanResult(services: [
            ListeningService(
                port: 8081, pid: 5011, processName: "java", commandLine: argv,
                workingDirectory: "/apps/server"
            ),
            ListeningService(
                port: 9000, pid: 7001, processName: "node",
                commandLine: "/usr/local/bin/node /x/vite --port 9000",
                workingDirectory: "/apps/web"
            ),
            ListeningService(
                port: 9090, pid: 6001, processName: "java",
                commandLine: "/usr/bin/java -jar /apps/order-service-1.0.0-SNAPSHOT.jar",
                workingDirectory: "/apps/order"
            ),
        ], source: .lsof))])
        let model = PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            resolver: DisplayNameResolver(aliasLookup: { center.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { center.hasDefinition(for: $0) }),
            knownDefinitions: { center.knownDefinitions() },
            uptimeFetcher: nil,
            definitions: center,
            processController: nil,
            store: InMemoryKeyValueStore(),
            logLocator: logLocator,
            logTailFactory: { [weak tailBox] _, onUpdate in
                let tail = FakeTail()
                tailBox?.record(onUpdate: onUpdate)
                tailBox?.append(tail)
                return tail
            }
        )
        return (model, center, scanner)
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-logvm-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 5, _ what: String, _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: - 打开：发现链 + tail 启动

    func test打开外部行走发现链启动tail带pid与工作目录() async throws {
        let logURL = URL(fileURLWithPath: "/apps/web/logs/dev.log")
        let locator = FakeLogLocator([.available(logURL)])
        let (model, _, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .frontend).first)

        model.openLog(rowID: row.id)
        let found = await waitUntil("日志状态变 found") {
            if case .found = model.logStatus { return true }
            return false
        }

        XCTAssertTrue(found, "发现命中：状态 found")
        XCTAssertEqual(model.logContext?.serviceName, "vite")
        XCTAssertEqual(model.logContext?.port, 9000)
        XCTAssertEqual(tails.count, 1, "恰好一个活跃 tail（低资源）")
        XCTAssertEqual(tails[0].startCount, 1)
        XCTAssertEqual(locator.contexts.first, LogContext(
            serviceName: "vite", port: 9000, isManaged: false,
            definitionID: nil, pid: 7001, workingDirectory: "/apps/web"
        ), "发现链输入 = 行上的进程事实（pid + 工作目录）")
    }

    func test打开托管行带定义上下文() async throws {
        let logURL = URL(fileURLWithPath: "/logs/def-1.log")
        let locator = FakeLogLocator([.available(logURL)])
        let (model, center, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .mine).first)
        let definitionID = try XCTUnwrap(center.all().first?.id)

        model.openLog(rowID: row.id)
        _ = await waitUntil("日志状态变 found") {
            if case .found = model.logStatus { return true }
            return false
        }

        XCTAssertEqual(locator.contexts.first?.isManaged, true, "托管 = 已知落盘路径，不走发现链")
        XCTAssertEqual(locator.contexts.first?.definitionID, definitionID)
    }

    func test未发现明示文案不启动tail() async throws {
        let locator = FakeLogLocator([.notFound])
        let (model, _, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .frontend).first)

        model.openLog(rowID: row.id)
        let settled = await waitUntil("状态落定为 notFound") {
            if case .notFound = model.logStatus { return true }
            return false
        }

        XCTAssertTrue(settled)
        guard case .notFound(let message) = model.logStatus else {
            return XCTFail("应当 notFound：\(String(describing: model.logStatus))")
        }
        XCTAssertEqual(message, "外部启动，未发现日志文件", "spec §6 ③：明示文案，不装死")
        XCTAssertTrue(tails.isEmpty, "未发现不启动 tail")
        XCTAssertEqual(model.logContext?.serviceName, "vite", "日志视图仍在（明示行可见）")
    }

    func test点击不存在的行无副作用() async {
        let locator = FakeLogLocator([.available(URL(fileURLWithPath: "/tmp/x.log"))])
        let (model, _, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()

        model.openLog(rowID: "row:不存在的行")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(locator.contexts.isEmpty, "无行不开日志")
        XCTAssertNil(model.logContext)
        XCTAssertTrue(tails.isEmpty)
    }

    // MARK: - 资源安全：切服务/返回/关面板必停旧 tail

    func test切换服务停旧tail启新tail() async throws {
        let locator = FakeLogLocator([.available(URL(fileURLWithPath: "/a.log")),
                                      .available(URL(fileURLWithPath: "/b.log"))])
        let (model, _, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()
        let frontend = try XCTUnwrap(model.rows(in: .frontend).first)
        let backend = try XCTUnwrap(model.rows(in: .backend).first)

        model.openLog(rowID: frontend.id)
        _ = await waitUntil("第一个 tail 启动") { self.tails.count == 1 }
        model.openLog(rowID: backend.id)
        _ = await waitUntil("第二个 tail 启动") { self.tails.count == 2 }

        XCTAssertEqual(tails[0].stopCount, 1, "切服务必停旧 tail（同一时刻最多一个活跃）")
        XCTAssertEqual(tails[0].startCount, 1, "旧 tail 不重启")
        XCTAssertEqual(model.logContext?.serviceName, "order-service", "视图切到新服务")
    }

    func test返回列表停tail清视图() async throws {
        let locator = FakeLogLocator([.available(URL(fileURLWithPath: "/a.log"))])
        let (model, _, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .frontend).first)
        model.openLog(rowID: row.id)
        _ = await waitUntil("tail 启动") { !self.tails.isEmpty }

        model.closeLog()

        XCTAssertEqual(tails[0].stopCount, 1, "返回列表停 tail")
        XCTAssertNil(model.logContext, "日志视图退出")
        XCTAssertEqual(tails[0].startCount, 1, "stop 恰好一次")
    }

    func test面板隐藏停tail并退回列表() async throws {
        let locator = FakeLogLocator([.available(URL(fileURLWithPath: "/a.log"))])
        let (model, _, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .frontend).first)
        model.openLog(rowID: row.id)
        _ = await waitUntil("tail 启动") { !self.tails.isEmpty }

        model.panelDidDisappear()

        XCTAssertEqual(tails[0].stopCount, 1, "面板隐藏即停（低资源硬约束）")
        XCTAssertNil(model.logContext)
    }

    /// 竞速：发现未落定就返回 → 过期结果丢弃，不启动孤儿 tail。
    func test打开未落定即返回则不启动tail() async throws {
        let gate = GatedLogLocator()
        let (model, _, _) = makeWiredModel(logLocator: gate)
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .frontend).first)

        model.openLog(rowID: row.id)
        let located = await waitUntil("发现已受理") { !gate.contexts.isEmpty }
        XCTAssertTrue(located)
        model.closeLog()

        gate.release(with: .available(URL(fileURLWithPath: "/late.log")))
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(tails.isEmpty, "过期结果丢弃：不启动孤儿 tail")
        XCTAssertNil(model.logContext)
    }

    // MARK: - 增量回调 → logText

    func testtail增量回调写入logText() async throws {
        let locator = FakeLogLocator([.available(URL(fileURLWithPath: "/a.log"))])
        let (model, _, _) = makeWiredModel(logLocator: locator)
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .frontend).first)

        model.openLog(rowID: row.id)
        let tailCreated = await waitUntil("tail 已创建（回调就位）") { self.lastUpdateHandler != nil }
        XCTAssertTrue(tailCreated)
        XCTAssertEqual(model.logText, "", "打开即清空，等回填")

        lastUpdateHandler?("boot line\n")
        var landed = await waitUntil("首个增量落定") { model.logText == "boot line\n" }
        XCTAssertTrue(landed, "行增量写入日志文本")

        lastUpdateHandler?("tick-1\ntick-2\n")
        landed = await waitUntil("第二个增量落定") {
            model.logText == "boot line\ntick-1\ntick-2\n"
        }
        XCTAssertTrue(landed, "增量追加")
    }

    /// 截断规则（纯函数）：超容量保尾部、截点对齐行首（视图不出现半行开头）。
    func test超长日志截断保尾部对齐行首() {
        let lines = (0..<1000).map { index in
            "line-\(String(format: "%04d", index))" + String(repeating: "x", count: 990)
        }
        let text = lines.joined(separator: "\n") + "\n"
        XCTAssertEqual(text.count, 1_000_000, "前提：每行恰 1000 字符（含换行）")

        // 容量 9999：suffix 从第 990 行中间开始，截到行首后应从第 991 行起。
        let trimmed = PanelViewModel.trimmedLogText(text, capacity: 9_999)

        XCTAssertLessThanOrEqual(trimmed.count, 9_999 + 1_000, "截断后不超容量（允许多保留一个整行）")
        XCTAssertTrue(trimmed.hasPrefix(lines[991] + "\n"), "截点对齐行首：从完整行起")
        XCTAssertTrue(trimmed.hasSuffix(lines[999] + "\n"), "保尾部：最新内容保留")
    }
}


/// 测试替身：收集工厂产物与增量回调的跨域盒（工厂闭包 @Sendable）。
final class TailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FakeTail] = []
    private var handler: (@Sendable (String) -> Void)?

    func append(_ tail: FakeTail) { lock.withLock { items.append(tail) } }
    var tails: [FakeTail] { lock.withLock { items } }
    func record(onUpdate: @escaping @Sendable (String) -> Void) {
        lock.withLock { handler = onUpdate }
    }
    var updateHandler: (@Sendable (String) -> Void)? { lock.withLock { handler } }
}
