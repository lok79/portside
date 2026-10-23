import XCTest
@testable import PortsideKit

/// 工单 05：托管行（带定义上下文）、已停止定义行、收编预填上下文与进程控制桩。
final class ManagedRowTests: XCTestCase {
    private func identified(
        port: Int, pid: Int = 5011, commandLine: String?, type: ServiceType = .java, name: String? = "user-service"
    ) -> IdentifiedService {
        IdentifiedService(
            service: ListeningService(
                port: port, pid: pid, processName: "java", commandLine: commandLine
            ),
            identity: ServiceIdentity(type: type, name: name, evidence: "测试"),
            displayName: name ?? "未知 :\(port)"
        )
    }

    private func definition(
        id: String = "def-1", port: Int = 8081, prefix: String = ""
    ) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: "user-service",
            launchCommand: "java -jar user-service.jar",
            port: port, pathPrefix: prefix,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - 托管·运行中行

    func test带定义的行标记托管且路径前缀进入打开URL() {
        let row = PanelRowFactory.leafRow(
            for: identified(port: 8081, commandLine: "java -jar user-service.jar"),
            section: .mine, uptimeText: nil,
            definition: definition(prefix: "/swagger-ui")
        )

        XCTAssertTrue(row.isManaged, "匹配到定义 = 托管·运行中")
        XCTAssertEqual(row.definitionID, "def-1", "动作路由依据")
        XCTAssertEqual(
            row.openURL, URL(string: "http://localhost:8081/swagger-ui"),
            "spec §5：路径前缀影响打开 URL"
        )
    }

    func test无定义的行保持外部形态打开URL为根路径() {
        let row = PanelRowFactory.leafRow(
            for: identified(port: 8081, commandLine: "java -jar user-service.jar"),
            section: .backend, uptimeText: nil, definition: nil
        )

        XCTAssertFalse(row.isManaged)
        XCTAssertNil(row.definitionID)
        XCTAssertEqual(row.openURL, URL(string: "http://localhost:8081"), "外部行默认根路径")
    }

    // MARK: - 托管·已停止行（定义在、实例没了）

    func test已停止定义行如实展示不猜() {
        let row = PanelRowFactory.stoppedRow(for: definition(prefix: "/swagger-ui"))

        XCTAssertEqual(row.id, "def:def-1", "跨重启稳定的行 id")
        XCTAssertEqual(row.section, .mine)
        XCTAssertFalse(row.isUp, "已停止：空心状态点")
        XCTAssertTrue(row.isManaged, "托管标签")
        XCTAssertEqual(row.definitionID, "def-1")
        XCTAssertEqual(row.displayName, "user-service", "显示定义名（= 别名）")
        XCTAssertEqual(row.ports, [8081])
        XCTAssertEqual(row.typeLabel, "已停止")
        XCTAssertNil(row.uptimeText, "无进程，无运行时长")
        XCTAssertEqual(row.openURL, URL(string: "http://localhost:8081/swagger-ui"))
        XCTAssertTrue(row.children.isEmpty)
    }

    func test已停止行id随定义不同而不同() {
        let a = PanelRowFactory.stoppedRow(for: definition(id: "def-a"))
        let b = PanelRowFactory.stoppedRow(for: definition(id: "def-b"))
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - 收编预填上下文

    func test行携带命令行原文供收编预填() {
        let argv = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"
        let row = PanelRowFactory.leafRow(
            for: identified(port: 8081, commandLine: argv),
            section: .backend, uptimeText: nil
        )
        XCTAssertEqual(row.commandLine, argv, "argv 原样带到行上（收编弹窗预填依据）")

        let noCommand = PanelRowFactory.leafRow(
            for: identified(port: 9883, commandLine: nil),
            section: .other, uptimeText: nil
        )
        XCTAssertNil(noCommand.commandLine, "采集不到显式为 nil，不猜")
    }
}

/// 工单 05：进程控制桩接缝——本票只钉「按钮动作送达控制器」，实现归工单 06。
@MainActor
final class ProcessControllerStubTests: XCTestCase {
    private func definition(port: Int = 8081) -> ServiceDefinition {
        ServiceDefinition(
            id: "def-1", name: "user-service", launchCommand: "java -jar u.jar",
            port: port, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    func test启动停止重启动作送达注入的控制器() async {
        let controller = FakeProcessController()
        let def = definition()

        try? await controller.start(def)
        try? await controller.stop(def)
        try? await controller.restart(def)

        XCTAssertEqual(controller.calls, [
            FakeProcessController.Call(action: "start", definitionID: "def-1"),
            FakeProcessController.Call(action: "stop", definitionID: "def-1"),
            FakeProcessController.Call(action: "restart", definitionID: "def-1"),
        ])
    }
}

/// 测试替身：记录调用的进程控制器（工单 06 的真实现接缝；工单 08 扩认领记录）。
final class FakeProcessController: ProcessController, @unchecked Sendable {
    struct Call: Equatable {
        let action: String
        let definitionID: String
    }

    private let lock = NSLock()
    /// 生命周期动作（start/stop/restart）——「杀」语义的记录（确认状态机断言依据）。
    private(set) var calls: [Call] = []
    /// 认领登记（工单 08）：与杀动作分开记——认领不是杀，确认前不杀的断言不受影响。
    private(set) var reclaims: [(definitionID: String, pid: pid_t)] = []
    /// 认领实例标记（工单 08：`isReclaimedInstance` 查询的注入回值）。
    var reclaimedDefinitionIDs: Set<String> = []

    func start(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append(Call(action: "start", definitionID: definition.id)) }
    }

    func stop(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append(Call(action: "stop", definitionID: definition.id)) }
    }

    func restart(_ definition: ServiceDefinition) async throws {
        lock.withLock { calls.append(Call(action: "restart", definitionID: definition.id)) }
    }

    /// 认领登记记录（不进 `calls`：认领不是杀，不搅既有确认状态机断言）。
    func reclaim(definitionID: String, pid: pid_t) -> Bool {
        lock.withLock { reclaims.append((definitionID, pid)) }
        return true
    }

    func isReclaimedInstance(definitionID: String) -> Bool {
        lock.withLock { reclaimedDefinitionIDs.contains(definitionID) }
    }
}
