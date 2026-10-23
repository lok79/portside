import XCTest
@testable import PortsideKit

/// 工单 09：删除服务定义入口——定义的服务永久消失后，用户手动删掉残留的「已停止」行。
/// 关键钉子（对齐工单 06 确认状态机）：**确认前不删、确认后才删、取消不删、不自动删**；
/// 删除只动定义，绝不碰进程；删除后面板立即重算、汇总态随之恢复。
@MainActor
final class DefinitionRemovalTests: XCTestCase {
    private let argv = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-removal-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 定义已存在、服务已消失（空扫描）的接线模型：面板上正是那条触发删除入口的「已停止」行。
    /// 返回（模型，定义中枢，扫描器）。
    private func makeWiredModelWithDeadDefinition(
        port: Int = 8081
    ) -> (PanelViewModel, ServiceDefinitionCenter, FakeScanner, String) {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let id = center.adopt(
            name: "user-service", commandLine: argv, port: port, pathPrefix: ""
        ).id
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            resolver: DisplayNameResolver(aliasLookup: { center.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { center.hasDefinition(for: $0) }),
            knownDefinitions: { center.knownDefinitions() },
            uptimeFetcher: nil,
            definitions: center,
            store: InMemoryKeyValueStore()
        )
        return (model, center, scanner, id)
    }

    // MARK: - 确认状态机：确认前不删、确认后才删、取消不删

    func test删除需确认确认前不删确认后才删且行消失() async throws {
        let (model, center, _, id) = makeWiredModelWithDeadDefinition()
        await model.refreshOnce()
        XCTAssertEqual(model.rows(in: .mine).count, 1, "前提：已停止行在面板上")

        model.requestDeleteDefinition(id)

        XCTAssertEqual(center.all().count, 1, "确认前不删（不自动删）")
        let pending = try XCTUnwrap(model.pendingConfirmation, "请求删除即挂确认")
        XCTAssertEqual(pending.kind, .delete)
        XCTAssertEqual(pending.definitionID, id)
        XCTAssertEqual(pending.serviceName, "user-service")
        XCTAssertEqual(pending.port, 8081)
        XCTAssertTrue(pending.actionLabel.contains("删除"), "弹窗动作标题：\(pending.actionLabel)")
        XCTAssertTrue(pending.explanation.contains("不会"), "解释写明不碰进程：\(pending.explanation)")

        await model.confirmPendingManagedAction()

        XCTAssertTrue(center.all().isEmpty, "确认后才删")
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.rows(in: .mine), [], "已停止行随重算消失")
    }

    func test取消删除什么都不发生() async throws {
        let (model, center, _, id) = makeWiredModelWithDeadDefinition()
        await model.refreshOnce()

        model.requestDeleteDefinition(id)
        model.cancelPendingManagedAction()

        XCTAssertEqual(center.all().count, 1, "取消 = 不删")
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertEqual(model.rows(in: .mine).count, 1, "面板不动")
    }

    func test删除不存在的定义不弹确认也无副作用() async {
        let (model, center, _, _) = makeWiredModelWithDeadDefinition()

        model.requestDeleteDefinition("def-不存在")

        XCTAssertNil(model.pendingConfirmation, "不存在的 id 不弹确认")
        XCTAssertEqual(center.all().count, 1)
    }

    // MARK: - 删除后的连带状态：行内错误清空、汇总态恢复

    func test删除定义后汇总态恢复正常() async throws {
        let (model, center, _, id) = makeWiredModelWithDeadDefinition()
        await model.refreshOnce()
        XCTAssertEqual(model.health, .alert, "前提：有定义未在监听 = 挂")

        model.requestDeleteDefinition(id)
        await model.confirmPendingManagedAction()

        XCTAssertEqual(model.health, .normal, "定义删掉后不再计入挂掉判定：图标回全绿")
    }

    func test删除定义清掉该定义的行内状态() async throws {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let id = center.adopt(name: "user-service", commandLine: argv, port: 8081, pathPrefix: "").id
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            resolver: DisplayNameResolver(aliasLookup: { center.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { center.hasDefinition(for: $0) }),
            knownDefinitions: { center.knownDefinitions() },
            uptimeFetcher: nil,
            definitions: center,
            store: InMemoryKeyValueStore()
        )
        await model.refreshOnce()

        // 行内状态先存在（如启动失败的红色文案），删除定义后必须一并清掉。
        await model.startService(id)
        model.requestDeleteDefinition(id)
        await model.confirmPendingManagedAction()

        XCTAssertNil(model.statusMessage(forDefinitionID: id), "定义已删，行内状态不得残留")
    }
}
