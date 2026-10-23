import XCTest
@testable import PortsideKit

/// 工单 05：实例 ↔ 定义匹配器（ADR/0001：按端口 + 启动命令匹配，匹配不上不误认；
/// 工单 08 认领复用同一匹配器）。
final class DefinitionMatcherTests: XCTestCase {
    private let matcher = DefinitionMatcher()

    private func definition(
        port: Int, command: String, name: String = "user-service"
    ) -> ServiceDefinition {
        ServiceDefinition(
            id: "def-\(port)-\(name)", name: name, launchCommand: command,
            port: port, createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func service(
        port: Int, commandLine: String?
    ) -> ListeningService {
        ListeningService(port: port, pid: 1, processName: "proc", commandLine: commandLine)
    }

    // MARK: - 匹配规则

    func test端口与命令一致即匹配() {
        let matched = matcher.definition(
            matching: service(port: 8081, commandLine: "java -jar user-service.jar"),
            in: [definition(port: 8081, command: "java -jar user-service.jar")]
        )
        XCTAssertEqual(matched?.id, "def-8081-user-service")
    }

    func test命令空白差异规范化后匹配() {
        // ps 输出与用户手敲之间的空白差异不应妨碍认领（规范化：去首尾 + 多空白折叠）。
        let matched = matcher.definition(
            matching: service(port: 8081, commandLine: "  java   -jar  user-service.jar "),
            in: [definition(port: 8081, command: "java -jar user-service.jar")]
        )
        XCTAssertNotNil(matched, "空白差异规范化后视为同一条命令")
    }

    func test端口不符不匹配() {
        let matched = matcher.definition(
            matching: service(port: 8082, commandLine: "java -jar user-service.jar"),
            in: [definition(port: 8081, command: "java -jar user-service.jar")]
        )
        XCTAssertNil(matched, "端口不一致：不匹配，不误认（ADR/0001）")
    }

    func test命令不符不匹配() {
        // 同端口换了个起法（用户改了命令）：定义不认领该实例——它落回外部态。
        let matched = matcher.definition(
            matching: service(port: 8081, commandLine: "java -jar order-service.jar"),
            in: [definition(port: 8081, command: "java -jar user-service.jar")]
        )
        XCTAssertNil(matched)
    }

    func test实例命令行缺失不匹配() {
        // 降级数据源拿不到命令行：无从比对 → 不匹配（不误认，AGENTS.md 红线的不猜口径）。
        let matched = matcher.definition(
            matching: service(port: 8081, commandLine: nil),
            in: [definition(port: 8081, command: "java -jar user-service.jar")]
        )
        XCTAssertNil(matched)
    }

    func test多定义取端口命令都符合的那条() {
        let definitions = [
            definition(port: 8082, command: "java -jar order-service.jar", name: "order"),
            definition(port: 8081, command: "java -jar user-service.jar", name: "user"),
        ]
        let matched = matcher.definition(
            matching: service(port: 8081, commandLine: "java -jar user-service.jar"),
            in: definitions
        )
        XCTAssertEqual(matched?.name, "user")
    }

    func test反向判定定义是否在运行() {
        // 工单 08 认领复用面：给定义 + 实例集合，判定该定义是否被任一实例运行。
        let definitions = [definition(port: 8081, command: "java -jar user-service.jar")]
        let instances = [
            service(port: 5173, commandLine: "node vite"),
            service(port: 8081, commandLine: "java -jar user-service.jar"),
        ]
        XCTAssertTrue(matcher.isRunning(definitions[0], instances: instances))
        XCTAssertFalse(matcher.isRunning(definitions[0], instances: [instances[0]]))
        XCTAssertFalse(matcher.isRunning(definitions[0], instances: []), "无实例 = 已停止")
    }

    // MARK: - 规范化（纯函数）

    func test命令规范化() {
        XCTAssertEqual(DefinitionMatcher.normalizedCommand("  a   b  "), "a b")
        XCTAssertEqual(DefinitionMatcher.normalizedCommand("java\t-jar\n x.jar"), "java -jar x.jar", "制表/换行同样折叠")
        XCTAssertEqual(DefinitionMatcher.normalizedCommand("javafoo"), "javafoo", "无空白原样")
        XCTAssertEqual(DefinitionMatcher.normalizedCommand("   "), "", "纯空白 → 空")
    }

    // MARK: - 「同实例」规则（F5：收编去重与实例匹配共用的单一事实来源）

    func test同实例判定端口命令规范化一致才算同一实例() {
        let def = definition(port: 8081, command: "java -jar user-service.jar")
        XCTAssertTrue(DefinitionMatcher.isSameInstance(
            port: 8081, commandLine: "  java  -jar user-service.jar ", as: def
        ), "规范化后一致 = 同一实例（与实例匹配同规则）")
        XCTAssertFalse(DefinitionMatcher.isSameInstance(
            port: 8082, commandLine: "java -jar user-service.jar", as: def
        ), "端口不同 = 不同实例")
        XCTAssertFalse(DefinitionMatcher.isSameInstance(
            port: 8081, commandLine: "java -jar order-service.jar", as: def
        ), "命令不同 = 不同实例")
    }
}
