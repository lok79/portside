import Foundation

/// 实例 ↔ 定义匹配器（GLOSSARY：认领的匹配依据；ADR/0001）：
/// 按「端口一致 + 启动命令一致（规范化比较）」匹配运行中实例。
/// - 纯函数、无状态，SectionAssigner 的定义查询、工单 08 的自动认领复用同一实现。
/// - 匹配不上的实例一律不认（落回外部态）；实例命令行缺失（降级数据源）无从比对 → 不匹配，
///   宁可漏认不误认（AGENTS.md 红线的不猜口径）。
public struct DefinitionMatcher: Sendable {
    public init() {}

    /// 命令规范化：去首尾空白 + 连续空白折叠为单个空格。
    /// 只用于比较；落盘的定义保存 argv 原样。
    public static func normalizedCommand(_ command: String) -> String {
        command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 「同实例」判定（端口 + 规范化命令）——实例匹配（认领/分区）与收编去重
    /// （ServiceDefinitionCenter.adopt）共用的**单一事实来源**，两处不各自拼规则。
    public static func isSameInstance(
        port: Int, commandLine: String, as definition: ServiceDefinition
    ) -> Bool {
        port == definition.port
            && normalizedCommand(commandLine) == normalizedCommand(definition.launchCommand)
    }

    /// 在定义集合中找与运行中实例匹配的定义；无匹配返回 nil。
    public func definition(
        matching service: ListeningService, in definitions: [ServiceDefinition]
    ) -> ServiceDefinition? {
        definitions.first { matches(service, $0) }
    }

    /// 反向判定：某定义是否被给定实例集合中的任一实例运行（工单 08 认领复用）。
    /// 否则该定义处于「已停止」（GLOSSARY：服务定义——托管能力以定义为依据）。
    public func isRunning(_ definition: ServiceDefinition, instances: [ListeningService]) -> Bool {
        instances.contains { matches($0, definition) }
    }

    /// 单对匹配规则：端口一致 + 规范化命令一致；实例命令行缺失一律不匹配。
    private func matches(_ service: ListeningService, _ definition: ServiceDefinition) -> Bool {
        guard let command = service.commandLine else { return false }
        return Self.isSameInstance(port: service.port, commandLine: command, as: definition)
    }
}
