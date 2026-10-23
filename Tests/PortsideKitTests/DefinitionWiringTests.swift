import XCTest
@testable import PortsideKit

/// 工单 05：PanelViewModel 定义接线——收编/编辑即时重算（不等下一轮扫描）、
/// 已停止定义行、汇总态接真实定义、进程控制桩送达。
@MainActor
final class DefinitionWiringTests: XCTestCase {
    /// 与识别测试同源的最小真实数据集。
    private static let services = [
        ListeningService(
            port: 8081, pid: 5011, processName: "java",
            commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"
        ),
        ListeningService(
            port: 5173, pid: 99999, processName: "node",
            commandLine: "/usr/local/bin/node /x/node_modules/.bin/vite --port 5173"
        ),
    ]

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 定义接线版模型：分区/别名/汇总态三接缝全部走同一个定义中枢（生产同构）。
    private func makeWiredModel(
        scanner: PortScanner,
        center: ServiceDefinitionCenter,
        processController: ProcessController? = nil
    ) -> PanelViewModel {
        PanelViewModel(
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
    }

    private func liveScanner() -> FakeScanner {
        FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))])
    }

    private let argv = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"

    // MARK: - 收编：立即迁移，不等下一轮扫描

    func test收编后行立即迁移到我的服务不等下一轮扫描() async {
        let scanner = liveScanner()
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let model = makeWiredModel(scanner: scanner, center: center)

        await model.refreshOnce()
        XCTAssertEqual(model.rows(in: .backend).map(\.displayName), ["user-service"], "收编前在外部区")

        let scansBefore = scanner.callCount
        await model.adoptService(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")

        XCTAssertEqual(model.rows(in: .mine).map(\.displayName), ["用户服务"], "保存后立即移入我的服务")
        XCTAssertEqual(model.rows(in: .mine)[0].isManaged, true, "托管标签")
        XCTAssertNotNil(model.rows(in: .mine)[0].definitionID)
        XCTAssertEqual(model.rows(in: .backend), [], "从后端区移出（spec §2）")
        XCTAssertEqual(scanner.callCount, scansBefore, "定义变更免扫描重算")
    }

    func test取消收编不产生定义() async {
        let scanner = liveScanner()
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let model = makeWiredModel(scanner: scanner, center: center)

        await model.refreshOnce()
        // 取消 = 不调用 adoptService：定义集合与分区保持原样（UI 侧仅关闭弹窗）。
        XCTAssertTrue(center.all().isEmpty)
        XCTAssertEqual(model.rows(in: .backend).count, 1, "无定义生成，行不迁移")
    }

    // MARK: - 已停止定义行（重启 app 后定义仍在）

    func test有定义无实例显示已停止行且汇总态alert() async {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        center.adopt(name: "user-service", commandLine: argv, port: 8081, pathPrefix: "/swagger-ui")
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = makeWiredModel(scanner: scanner, center: center)

        await model.refreshOnce()

        let mineRows = model.rows(in: .mine)
        XCTAssertEqual(mineRows.count, 1, "杀掉 app 重开后定义仍在，无实例 → 已停止行")
        XCTAssertFalse(mineRows[0].isUp)
        XCTAssertTrue(mineRows[0].isManaged)
        XCTAssertEqual(mineRows[0].displayName, "user-service")
        XCTAssertEqual(mineRows[0].typeLabel, "已停止")
        XCTAssertEqual(mineRows[0].openURL, URL(string: "http://localhost:8081/swagger-ui"))
        XCTAssertEqual(model.health, .alert, "有定义未在监听 = 挂（菜单栏汇总态接真实定义）")
    }

    func test定义运行中回运行态不重复显示停止行() async {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        center.adopt(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")
        let scanner = liveScanner()
        let model = makeWiredModel(scanner: scanner, center: center)

        await model.refreshOnce()

        XCTAssertEqual(model.rows(in: .mine).count, 1, "运行中：只显示运行态行，不叠加已停止行")
        XCTAssertTrue(model.rows(in: .mine)[0].isUp, "匹配即托管·运行中")
        XCTAssertEqual(model.health, .normal)
    }

    // MARK: - 别名与路径前缀编辑即时生效

    func test别名编辑即时改显示名() async throws {
        let scanner = liveScanner()
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let model = makeWiredModel(scanner: scanner, center: center)
        await model.refreshOnce()
        let adoptedID = await model.adoptService(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")
        let id = try XCTUnwrap(adoptedID)

        let scansBefore = scanner.callCount
        await model.editDefinition(id: id, name: "订单网关", pathPrefix: "")

        XCTAssertEqual(
            model.rows(in: .mine).map(\.displayName), ["订单网关"],
            "改名即改显示名，即时生效不等扫描"
        )
        XCTAssertEqual(scanner.callCount, scansBefore)
    }

    func test路径前缀编辑影响打开URL() async throws {
        let scanner = liveScanner()
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let model = makeWiredModel(scanner: scanner, center: center)
        await model.refreshOnce()
        let adoptedID = await model.adoptService(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")
        let id = try XCTUnwrap(adoptedID)

        await model.editDefinition(id: id, name: "用户服务", pathPrefix: "swagger-ui")

        XCTAssertEqual(
            model.rows(in: .mine)[0].openURL, URL(string: "http://localhost:8081/swagger-ui"),
            "spec §5：路径前缀影响「打开」URL"
        )
    }

    // MARK: - 进程控制桩（动作送达接缝，实现归 06）

    func test已停止行启动动作走注入的控制器() async {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let id = center.adopt(name: "user-service", commandLine: argv, port: 8081, pathPrefix: "").id
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let controller = FakeProcessController()
        let model = makeWiredModel(scanner: scanner, center: center, processController: controller)

        await model.startService(id)

        XCTAssertEqual(controller.calls.first?.action, "start", "「启动」按钮动作送达控制器（工单 06 实装）")
        XCTAssertEqual(controller.calls.first?.definitionID, id)
    }

    func test托管运行中行停止重启动作走注入的控制器() async {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let id = center.adopt(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "").id
        let scanner = liveScanner()
        let controller = FakeProcessController()
        let model = makeWiredModel(scanner: scanner, center: center, processController: controller)
        await model.refreshOnce()

        await model.stopService(id)
        await model.restartService(id)

        XCTAssertEqual(controller.calls.map(\.action), ["stop", "restart"])
    }

    func test动作对不存在的定义无副作用() async {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: makeDirectory()))
        let scanner = liveScanner()
        let controller = FakeProcessController()
        let model = makeWiredModel(scanner: scanner, center: center, processController: controller)

        await model.startService("def-不存在")

        XCTAssertTrue(controller.calls.isEmpty)
    }
}
