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

/// 测试替身：start 可配置抛错的进程控制器（stop/restart 记录调用）。
private final class ThrowingProcessController: ProcessController, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var startError: Error?

    init(startError: Error?) {
        self.startError = startError
    }

    func start(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append("start") }
        if let startError { throw startError }
    }

    func stop(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append("stop") }
    }

    func restart(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append("restart") }
    }
}
