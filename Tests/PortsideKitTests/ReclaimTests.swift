import XCTest
import Darwin
@testable import PortsideKit

/// 工单 08：自动认领（GLOSSARY：认领——按服务定义匹配运行中实例纳回托管态）。
/// 接缝 = `ShellProcessController.reclaim`（受管外部实例登记）+ `ProcessController`
/// 协议默认无操作 + PanelViewModel 扫描管线接线。
/// 可观察面 = 真实进程效果：登记后停止/重启对认领实例生效、重启后回到「自己起的」、
/// 不覆盖事实（宁漏认不误认）、认领实例日志走「标准落盘路径 → 外部发现链兜底」。
@MainActor
final class ReclaimTests: XCTestCase {
    private var controller: ShellProcessController?
    private var logsDirectory: URL?
    /// 测试里经 Foundation Process 起的"外部"实例（不经 controller，模拟用户自己起的）。
    private var externalProcesses: [Process] = []

    override func tearDown() {
        // 必杀兜底：controller 追踪的 + 本测试直接起的外部实例，一个不留。
        controller?.killAllForTesting()
        controller = nil
        for process in externalProcesses where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        externalProcesses = []
        if let logsDirectory {
            try? FileManager.default.removeItem(at: logsDirectory)
        }
    }

    // MARK: - 测试辅助

    private func makeController(
        gracePeriod: Duration = .seconds(8),
        startupWindow: Duration = .milliseconds(500),
        killTimeout: Duration = .milliseconds(500),
        runner: ProcessRunner? = nil
    ) -> ShellProcessController {
        let logs = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-reclaim-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logsDirectory = logs
        let controller = ShellProcessController(
            shellPath: "/bin/sh",
            logsDirectory: logs,
            gracePeriod: gracePeriod,
            startupWindow: startupWindow,
            killTimeout: killTimeout,
            runner: runner
        )
        self.controller = controller
        return controller
    }

    private func definition(
        id: String = "def-test", command: String, port: Int = 18123
    ) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: "认领服务", launchCommand: command, port: port, createdAt: Date()
        )
    }

    /// 起一个"外部"监听进程（不经 controller——外部服务的启动语义）。
    private func startExternalListener(port: Int) throws -> Process {
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "\(port)"]
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        externalProcesses.append(listener)
        return listener
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

    // MARK: - S1 登记：认领实例进运行态，停止对它生效

    func test认领外部实例后停止对它生效() async throws {
        let controller = makeController()
        let listener = try startExternalListener(port: 18123)
        let pid = pid_t(listener.processIdentifier)
        let def = definition(command: "nc -l 18123")

        // 外部实例未经 controller 启动：登记前无追踪。
        XCTAssertFalse(controller.isRunning(definitionID: def.id))
        let reclaimed = controller.reclaim(definitionID: def.id, pid: pid)

        XCTAssertTrue(reclaimed, "存活实例可认领登记")
        XCTAssertEqual(controller.runningProcessID(definitionID: def.id), pid, "登记 pid")
        XCTAssertEqual(
            controller.runningProcessGroupID(definitionID: def.id),
            getpgid(pid),
            "登记 pgid（getpgid 现取）"
        )
        XCTAssertTrue(controller.isRunning(definitionID: def.id))
        XCTAssertTrue(controller.isReclaimedInstance(definitionID: def.id), "受管外部实例")

        // 停止对认领实例生效：整组 TERM，nc 即死。nc 对 TERM 立即退出——
        // stop 必须远快于宽限期（退出感知走有界存活探询，非亲生不能 waitpid）。
        let startedAt = Date()
        try await controller.stop(def)
        let elapsed = Date().timeIntervalSince(startedAt)
        XCTAssertLessThan(elapsed, 5, "认领实例对 TERM 即死，stop 不该等满 8s 宽限（实际 \(elapsed)s）")
        try await waitUntil("认领实例已终止") { kill(pid, 0) != 0 }
        XCTAssertFalse(controller.isRunning(definitionID: def.id), "停止后不再追踪")
        XCTAssertFalse(controller.isReclaimedInstance(definitionID: def.id))
    }

    // MARK: - S2 重启：认领实例重启后回到「自己起的」状态

    func test重启认领实例后回到自己起的状态() async throws {
        let controller = makeController()
        let listener = try startExternalListener(port: 18123)
        let oldPID = pid_t(listener.processIdentifier)
        let def = definition(command: "nc -l 18123")

        XCTAssertTrue(controller.reclaim(definitionID: def.id, pid: oldPID))

        try await controller.restart(def)

        // 旧的外部实例死了；新实例由 controller 亲生（重启后的运行态）。
        try await waitUntil("旧的外部实例已终止") { kill(oldPID, 0) != 0 }
        let newPID = try XCTUnwrap(controller.runningProcessID(definitionID: def.id), "重启后重新追踪")
        XCTAssertNotEqual(newPID, oldPID, "重启 = 停止 + 重新启动（新进程）")
        XCTAssertFalse(
            controller.isReclaimedInstance(definitionID: def.id),
            "重启后回「自己起的」：亲生条目，非认领实例"
        )
        XCTAssertEqual(controller.runningProcessGroupID(definitionID: def.id), newPID, "亲生进程仍是独立组领袖")
    }

    // MARK: - S3 不覆盖事实：亲生身份保留、存活冲突拒绝、死条目可换代

    /// 重启后扫描会再匹配到亲生实例（同 pid）→ 认领必须幂等且**不降级**亲生身份
    /// （否则丢 reaper、日志视图误判「输出未接管」）。
    func test认领幂等同pid不降级亲生身份() async throws {
        let controller = makeController()
        let def = definition(command: #"while true; do sleep 1; done"#)
        try await controller.start(def)
        let pid = try XCTUnwrap(controller.runningProcessID(definitionID: def.id))

        XCTAssertTrue(controller.reclaim(definitionID: def.id, pid: pid), "同 pid 重复登记幂等")

        XCTAssertTrue(controller.isRunning(definitionID: def.id))
        XCTAssertFalse(
            controller.isReclaimedInstance(definitionID: def.id),
            "亲生身份保留：同 pid 重复登记不把亲生条目降级成认领"
        )
    }

    /// 该定义已在追一个存活的异 pid 实例（如用户在我们追踪期间自己换了进程）：
    /// 宁可漏认不误认——拒绝登记、保留原条目。
    func test认领拒绝覆盖存活的异pid条目() async throws {
        let controller = makeController()
        let def = definition(command: #"while true; do sleep 1; done"#)
        try await controller.start(def)
        let trackedPID = try XCTUnwrap(controller.runningProcessID(definitionID: def.id))

        let listener = try startExternalListener(port: 18124)
        let foreignPID = pid_t(listener.processIdentifier)

        let reclaimed = controller.reclaim(definitionID: def.id, pid: foreignPID)

        XCTAssertFalse(reclaimed, "存活异 pid 条目在追：拒绝认领（宁漏认不误认）")
        XCTAssertEqual(
            controller.runningProcessID(definitionID: def.id), trackedPID, "原条目原样保留"
        )
        XCTAssertFalse(controller.isReclaimedInstance(definitionID: def.id))
    }

    /// 旧条目已退出（实例换代）：认领替换之——重开 app 后「死的亲生条目」让位给
    /// 「活着的认领实例」。
    func test认领替换已退出的旧条目() async throws {
        let controller = makeController()
        let def = definition(command: #"while true; do sleep 1; done"#)
        try await controller.start(def)
        let deadPID = try XCTUnwrap(controller.runningProcessID(definitionID: def.id))
        kill(deadPID, SIGKILL)
        try await waitUntil("亲生条目已被 reaper 记为退出") {
            !controller.isRunning(definitionID: def.id)
        }

        let listener = try startExternalListener(port: 18123)
        let pid = pid_t(listener.processIdentifier)
        XCTAssertTrue(controller.reclaim(definitionID: def.id, pid: pid), "死条目可被认领替换")

        XCTAssertEqual(controller.runningProcessID(definitionID: def.id), pid, "换代后的运行实例")
        XCTAssertTrue(controller.isReclaimedInstance(definitionID: def.id))
    }

    /// 已死进程无从登记（getpgid 失败）：扫描轮拿到的是过期 pid 时的自然防御。
    func test认领已死进程返回失败() async throws {
        let controller = makeController()
        let listener = try startExternalListener(port: 18123)
        let pid = pid_t(listener.processIdentifier)
        kill(pid, SIGKILL)
        try await waitUntil("外部实例已死") { kill(pid, 0) != 0 }

        XCTAssertFalse(controller.reclaim(definitionID: "def-死pid", pid: pid))
        XCTAssertFalse(controller.isRunning(definitionID: "def-死pid"))
    }

    // MARK: - S4 扫描管线接线：首轮扫描后自动认领（不阻塞 UI、partial 照常、不误认）

    private let adoptedArgv = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-reclaim-wiring-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 生产同构装配（同 DefinitionWiringTests）：定义中枢 + 注入的记录型控制器。
    private func makeWiredModel(
        services: [ListeningService],
        isPartial: Bool = false,
        processController: ProcessController?,
        logLocator: LogLocating? = nil
    ) -> (PanelViewModel, ServiceDefinitionCenter) {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        center.adopt(name: "用户服务", commandLine: adoptedArgv, port: 8081, pathPrefix: "")
        let model = PanelViewModel(
            scanner: FakeScanner([.success(ScanResult(
                services: services, source: .lsof, isPartial: isPartial
            ))]),
            engine: .defaultEngine(runner: FakeProcessRunner()),
            resolver: DisplayNameResolver(aliasLookup: { center.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { center.hasDefinition(for: $0) }),
            knownDefinitions: { center.knownDefinitions() },
            uptimeFetcher: nil,
            definitions: center,
            processController: processController,
            store: InMemoryKeyValueStore(),
            logLocator: logLocator,
            logTailFactory: { _, _ in FakeTail() }
        )
        return (model, center)
    }

    /// 端到端认领：扫描命中定义 → 登记进控制器（首轮扫描即认领，无需手动刷新）。
    /// 认领登记 O(1) 同步完成，管线不被阻塞（对比：扫描本身才是慢环节）。
    func test首轮扫描后自动认领匹配实例() async throws {
        let controller = FakeProcessController()
        let (model, center) = makeWiredModel(
            services: [ListeningService(
                port: 8081, pid: 5011, processName: "java", commandLine: adoptedArgv
            )],
            processController: controller
        )
        let definitionID = try XCTUnwrap(center.all().first?.id)

        await model.refreshOnce()

        XCTAssertEqual(
            controller.reclaims.count, 1, "首轮扫描命中即认领登记（恰好一次）"
        )
        XCTAssertEqual(controller.reclaims.first?.definitionID, definitionID)
        XCTAssertEqual(controller.reclaims.first?.pid, 5011, "登记实例 pid")
        XCTAssertTrue(controller.calls.isEmpty, "认领不是杀：不动生命周期动作")
        // 行显示托管·运行中（既有 05 语义，此处钉住认领轮不回退）。
        let row = try XCTUnwrap(model.rows(in: .mine).first)
        XCTAssertTrue(row.isManaged)
        XCTAssertTrue(row.isUp)
        XCTAssertEqual(row.definitionID, definitionID)
    }

    /// 红线用例（端到端）：端口同、启动命令不同 → 不认领（落回外部态，不误认）。
    func test端口同命令不同不认领() async {
        let controller = FakeProcessController()
        let (model, _) = makeWiredModel(
            services: [ListeningService(
                port: 8081, pid: 5011, processName: "java",
                commandLine: "/usr/bin/java -jar /apps/order-service-2.0.jar"
            )],
            processController: controller
        )

        await model.refreshOnce()

        XCTAssertTrue(controller.reclaims.isEmpty, "命令不同：定义不认领该实例（宁漏认不误认）")
        // 定义仍在 → 我的服务区只出托管·已停止行（05 语义）；运行实例落回外部态（后端区）。
        let mineRows = model.rows(in: .mine)
        XCTAssertEqual(mineRows.map(\.isUp), [false], "定义无匹配实例 = 托管·已停止行")
        XCTAssertEqual(model.rows(in: .backend).map(\.displayName), ["order-service"])
        XCTAssertFalse(model.rows(in: .backend)[0].isManaged, "运行实例落回外部态")
    }

    /// 降级数据源拿不到命令行：无从比对 → 不认领（不误认）。
    func test命令行缺失不认领() async {
        let controller = FakeProcessController()
        let (model, _) = makeWiredModel(
            services: [ListeningService(port: 8081, pid: 5011, processName: "java", commandLine: nil)],
            processController: controller
        )

        await model.refreshOnce()

        XCTAssertTrue(controller.reclaims.isEmpty, "命令行缺失：不认领")
    }

    /// partial 扫描（lsof 受限）：认领照常按可用数据走——拿得到端口+命令行的照认，
    /// 拿不到的自然落空；顶部明示不受影响。
    func testpartial扫描按可用数据认领() async throws {
        let controller = FakeProcessController()
        let (model, center) = makeWiredModel(
            services: [ListeningService(
                port: 8081, pid: 5011, processName: "java", commandLine: adoptedArgv
            )],
            isPartial: true,
            processController: controller
        )
        let definitionID = try XCTUnwrap(center.all().first?.id)

        await model.refreshOnce()

        XCTAssertEqual(
            controller.reclaims.count, 1, "partial 扫描：可用数据照常认领"
        )
        XCTAssertEqual(controller.reclaims.first?.pid, 5011)
        XCTAssertNotNil(model.scanNotice, "partial 明示仍在")
    }

    /// 无控制器（桩形态）：认领接线零副作用，面板照常。
    func test无控制器时认领接线零副作用() async {
        let (model, _) = makeWiredModel(
            services: [ListeningService(
                port: 8081, pid: 5011, processName: "java", commandLine: adoptedArgv
            )],
            processController: nil
        )

        await model.refreshOnce()

        XCTAssertEqual(model.rows(in: .mine).count, 1, "面板照常出托管行")
    }

    // MARK: - S5 认领实例的日志：标准落盘路径优先，外部发现链兜底，明示不装死

    private func locatorContext(
        definitionID: String, pid: Int?, workingDirectory: String?, isReclaimed: Bool
    ) -> LogContext {
        LogContext(
            serviceName: "认领服务", port: 18123, isManaged: true,
            definitionID: definitionID, pid: pid, workingDirectory: workingDirectory,
            isReclaimed: isReclaimed
        )
    }

    /// 解耦真身：标准落盘文件在（前一世 Portside 落的盘，句柄仍被子进程握着）→
    /// 认领后直接 tail 标准路径——验收「日志完整」的主路径。
    func test认领实例标准落盘日志存在则直接用() async throws {
        let managedDir = makeDirectory()
        let managedURL = managedDir.appendingPathComponent("def-x.log")
        try "old-session output\n".write(to: managedURL, atomically: true, encoding: .utf8)
        let locator = LogLocator(runner: nil, managedLogsDirectory: managedDir)

        let availability = await locator.locate(locatorContext(
            definitionID: "def-x", pid: 5011, workingDirectory: nil, isReclaimed: true
        ))

        XCTAssertEqual(availability, .available(managedURL), "标准路径有文件：命中即正确")
    }

    /// 外部时代起的认领实例（收编前就在跑）：标准路径无文件 → 落 07 发现链
    /// ①fd 扫描——进程正在写的 .out/.log 命中即正确。
    func test认领实例无落盘走外部fd发现兜底() async {
        let managedDir = makeDirectory()
        let runner = FakeProcessRunner()
        let openFile = makeDirectory().appendingPathComponent("nohup.out")
        try? "external output\n".write(to: openFile, atomically: true, encoding: .utf8)
        runner.on(LsofScanner.lsofPath, ["-a", "-p", "5011", "-Fatn"], stdout: """
        p5011
        f3
        aw
        tREG
        n\(openFile.path)
        """)
        let locator = LogLocator(runner: runner, managedLogsDirectory: managedDir)

        let availability = await locator.locate(locatorContext(
            definitionID: "def-x", pid: 5011, workingDirectory: nil, isReclaimed: true
        ))

        XCTAssertEqual(availability, .available(openFile), "标准路径无文件：fd 扫描兜底命中")
    }

    /// fd 扫描也无命中 → ②工作目录惯例兜底（nohup.out 等）。
    func test认领实例无落盘无fd走目录惯例兜底() async {
        let managedDir = makeDirectory()
        let cwd = makeDirectory()
        let nohup = cwd.appendingPathComponent("nohup.out")
        try? "external output\n".write(to: nohup, atomically: true, encoding: .utf8)
        let locator = LogLocator(runner: nil, managedLogsDirectory: managedDir)

        let availability = await locator.locate(locatorContext(
            definitionID: "def-x", pid: 5011, workingDirectory: cwd.path, isReclaimed: true
        ))

        XCTAssertEqual(availability, .available(nohup), "目录惯例兜底命中")
    }

    /// 三处都没有 → 未发现。明示文案区分「认领实例但输出未接管」（不装死），
    /// 与外部服务的「外部启动，未发现日志文件」分开。
    func test认领实例日志未发现明示输出未接管() async throws {
        let controller = FakeProcessController()
        let (model, center) = makeWiredModel(
            services: [ListeningService(
                port: 8081, pid: 5011, processName: "java", commandLine: adoptedArgv
            )],
            processController: controller,
            logLocator: FakeLogLocator([.notFound])
        )
        let definitionID = try XCTUnwrap(center.all().first?.id)
        controller.reclaimedDefinitionIDs = [definitionID]
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .mine).first)

        model.openLog(rowID: row.id)
        // waitUntil 超时即抛（测试失败并说明在等什么）。
        try await waitUntil("状态落定为 notFound") {
            if case .notFound = model.logStatus { return true }
            return false
        }

        guard case .notFound(let message) = model.logStatus else {
            return XCTFail("应当 notFound：\(String(describing: model.logStatus))")
        }
        XCTAssertEqual(
            message, LogLocator.reclaimedLogNotFoundNotice,
            "认领实例的明示文案：已纳管但输出未接管"
        )
        XCTAssertNotEqual(message, LogLocator.externalLogNotFoundNotice, "与外部服务文案区分")
    }

    /// 打开认领实例的日志：上下文带认领标记（isManaged + isReclaimed）——
    /// 「认领实例但输出未接管」在 logContext 里体现，UI 可据此渲染。
    func test打开认领实例行上下文带认领标记() async throws {
        let controller = FakeProcessController()
        let locator = FakeLogLocator([.available(URL(fileURLWithPath: "/tmp/x.log"))])
        let (model, center) = makeWiredModel(
            services: [ListeningService(
                port: 8081, pid: 5011, processName: "java", commandLine: adoptedArgv,
                workingDirectory: "/apps/server"
            )],
            processController: controller,
            logLocator: locator
        )
        let definitionID = try XCTUnwrap(center.all().first?.id)
        controller.reclaimedDefinitionIDs = [definitionID]
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .mine).first)

        model.openLog(rowID: row.id)
        _ = try await waitUntil("发现已受理") { !locator.contexts.isEmpty }

        XCTAssertEqual(locator.contexts.first?.isManaged, true, "托管（有定义）")
        XCTAssertEqual(locator.contexts.first?.isReclaimed, true, "认领实例标记")
        XCTAssertEqual(locator.contexts.first?.definitionID, definitionID)
    }

    /// 亲生托管行（本会话启动）：上下文不带认领标记——仍走标准落盘路径直连。
    func test打开亲生托管行不带认领标记() async throws {
        let controller = FakeProcessController()
        let locator = FakeLogLocator([.available(URL(fileURLWithPath: "/tmp/x.log"))])
        let (model, _) = makeWiredModel(
            services: [ListeningService(
                port: 8081, pid: 5011, processName: "java", commandLine: adoptedArgv
            )],
            processController: controller,
            logLocator: locator
        )
        await model.refreshOnce()
        let row = try XCTUnwrap(model.rows(in: .mine).first)

        model.openLog(rowID: row.id)
        _ = try await waitUntil("发现已受理") { !locator.contexts.isEmpty }

        XCTAssertEqual(locator.contexts.first?.isReclaimed, false, "亲生托管：非认领")
    }
}
