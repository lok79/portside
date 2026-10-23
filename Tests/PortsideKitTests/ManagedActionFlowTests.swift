import XCTest
@testable import PortsideKit

/// 工单 06：托管动作的确认状态机与启动失败行内状态（ViewModel 层，不触 UI）。
/// 关键钉子：**确认前不杀、确认后才杀、取消不杀**（spec §4 危险动作二次确认）；
/// 启动失败错误进行内状态、app 不崩。
@MainActor
final class ManagedActionFlowTests: XCTestCase {
    private let argv = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-action-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 运行中的托管服务接线模型（同 DefinitionWiringTests 的生产同构装配）。
    /// 返回（模型，定义中枢，扫描器）。
    private func makeWiredModel(
        processController: ProcessController? = nil
    ) -> (PanelViewModel, ServiceDefinitionCenter, FakeScanner) {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        center.adopt(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")
        let scanner = FakeScanner([.success(ScanResult(services: [
            ListeningService(port: 8081, pid: 5011, processName: "java", commandLine: argv),
        ], source: .lsof))])
        let model = PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            resolver: DisplayNameResolver(aliasLookup: { center.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { center.hasDefinition(for: $0) }),
            knownDefinitions: { center.knownDefinitions() },
            uptimeFetcher: nil,
            definitions: center,
            processController: processController,
            store: InMemoryKeyValueStore()
        )
        return (model, center, scanner)
    }

    // MARK: - 确认状态机：确认前不杀、确认后才杀

    func test停止需确认确认前不杀确认后才杀() async throws {
        let controller = FakeProcessController()
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.requestStopService(id)

        XCTAssertTrue(controller.calls.isEmpty, "确认前不杀（spec §4 危险动作二次确认）")
        let pending = try XCTUnwrap(model.pendingConfirmation, "请求停止即弹确认")
        XCTAssertEqual(pending.definitionID, id)
        XCTAssertEqual(pending.kind, .stop)
        XCTAssertEqual(pending.serviceName, "用户服务", "弹窗显示服务名")
        XCTAssertEqual(pending.port, 8081, "弹窗显示端口")
        XCTAssertFalse(pending.explanation.isEmpty, "弹窗带动作解释")

        await model.confirmPendingManagedAction()

        XCTAssertEqual(controller.calls.map(\.action), ["stop"], "确认后才送达停止")
        XCTAssertEqual(controller.calls.map(\.definitionID), [id])
        XCTAssertNil(model.pendingConfirmation, "确认后弹窗状态清空")
    }

    func test取消确认不产生任何停止动作() async throws {
        let controller = FakeProcessController()
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.requestStopService(id)
        model.cancelPendingManagedAction()

        XCTAssertTrue(controller.calls.isEmpty, "取消 = 不杀")
        XCTAssertNil(model.pendingConfirmation)
    }

    func test重启需确认确认后送达重启() async throws {
        let controller = FakeProcessController()
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.requestRestartService(id)

        XCTAssertTrue(controller.calls.isEmpty, "确认前不杀")
        XCTAssertEqual(model.pendingConfirmation?.kind, .restart)

        await model.confirmPendingManagedAction()

        XCTAssertEqual(controller.calls.map(\.action), ["restart"])
        XCTAssertNil(model.pendingConfirmation)
    }

    func test不存在的定义不弹确认() async {
        let controller = FakeProcessController()
        let (model, _, _) = makeWiredModel(processController: controller)

        await model.requestStopService("def-不存在")

        XCTAssertNil(model.pendingConfirmation)
        XCTAssertTrue(controller.calls.isEmpty)
    }

    // MARK: - F3(a)：确认弹窗解释带当前实际占用者（spec §4「显示占用者解释」）

    func test停止确认解释带最近扫描的实际占用者pid与进程名() async throws {
        let controller = FakeProcessController()
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()   // 最近一轮扫描：8081 ← pid 5011 java
        let id = try XCTUnwrap(center.all().first?.id)

        await model.requestStopService(id)

        let pending = try XCTUnwrap(model.pendingConfirmation)
        XCTAssertEqual(pending.occupier?.pid, 5011, "占用者 pid 来自最近一轮扫描")
        XCTAssertEqual(pending.occupier?.processName, "java", "占用者进程名来自最近一轮扫描")
        XCTAssertTrue(pending.explanation.contains("5011"), "解释带真实 pid：\(pending.explanation)")
        XCTAssertTrue(pending.explanation.contains("java"), "解释带真实进程名：\(pending.explanation)")
    }

    func test重启确认解释同样带占用者() async throws {
        let controller = FakeProcessController()
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.requestRestartService(id)

        let pending = try XCTUnwrap(model.pendingConfirmation)
        XCTAssertEqual(pending.occupier?.pid, 5011)
        XCTAssertTrue(pending.explanation.contains("5011"))
    }

    func test扫描未及该端口时解释不含占用者不猜() async throws {
        let controller = FakeProcessController()
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        center.adopt(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")
        // 空扫描（服务已不在监听）：无占用者事实 → 解释不带，不猜（AGENTS.md 红线）。
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            definitions: center,
            processController: controller,
            store: InMemoryKeyValueStore()
        )
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.requestStopService(id)

        let pending = try XCTUnwrap(model.pendingConfirmation)
        XCTAssertNil(pending.occupier, "无扫描事实不编占用者")
    }

    // MARK: - F3(b)：端口兜底停止被安全阀拒绝 → 错误走行内显示，不装死

    func test停止被拒错误走行内状态显示() async throws {
        let controller = ThrowingProcessController(
            stopError: ProcessStopError.occupierMismatch(pid: 5099, processName: "python3")
        )
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.stopService(id)

        let message = try XCTUnwrap(model.statusMessage(forDefinitionID: id), "停止被拒行内可见不装死")
        XCTAssertTrue(message.contains("5099"), "带占用者 pid：\(message)")
        XCTAssertTrue(message.contains("python3"), "带占用者进程名：\(message)")
        XCTAssertTrue(message.contains("未停止"), "明确说没停：\(message)")
    }

    func test重启被拒错误同样走行内状态显示() async throws {
        let controller = ThrowingProcessController(
            stopError: ProcessStopError.occupierMismatch(pid: 5099, processName: "python3")
        )
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.restartService(id)

        let message = try XCTUnwrap(model.statusMessage(forDefinitionID: id))
        XCTAssertTrue(message.contains("未停止"))
    }

    // MARK: - 启动失败：错误写进行内状态，app 不崩

    func test启动失败错误写进行内状态含日志末尾() async throws {
        let controller = ThrowingProcessController(
            startError: ProcessStartError.exitedImmediately(
                exitCode: 3, logTail: "Error: Cannot find module 'x'"
            )
        )
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.startService(id)

        let message = try XCTUnwrap(model.statusMessage(forDefinitionID: id), "失败信息行内可见")
        XCTAssertTrue(message.contains("启动失败"), "行内明示失败：\(message)")
        XCTAssertTrue(message.contains("退出码 3"), "带退出码：\(message)")
        XCTAssertTrue(message.contains("Cannot find module"), "带日志末尾：\(message)")
    }

    func test再次启动成功清除行内错误() async throws {
        let controller = ThrowingProcessController(
            startError: ProcessStartError.exitedImmediately(exitCode: 3, logTail: "boom")
        )
        let (model, center, _) = makeWiredModel(processController: controller)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.startService(id)
        XCTAssertNotNil(model.statusMessage(forDefinitionID: id))

        controller.startError = nil   // 第二次启动成功
        await model.startService(id)

        XCTAssertNil(model.statusMessage(forDefinitionID: id), "启动成功清除旧错误")
    }

    func test无控制器时启动不崩且不设错误() async throws {
        let (model, center, _) = makeWiredModel(processController: nil)
        await model.refreshOnce()
        let id = try XCTUnwrap(center.all().first?.id)

        await model.startService(id)

        XCTAssertNil(model.statusMessage(forDefinitionID: id))
    }
}

/// 测试替身：start/stop 可配置抛错的进程控制器（记录调用）。
private final class ThrowingProcessController: ProcessController, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var startError: Error?
    var stopError: Error?

    init(startError: Error? = nil, stopError: Error? = nil) {
        self.startError = startError
        self.stopError = stopError
    }

    func start(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append("start") }
        if let startError { throw startError }
    }

    func stop(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append("stop") }
        if let stopError { throw stopError }
    }

    func restart(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append("restart") }
        if let stopError { throw stopError }
    }
}
