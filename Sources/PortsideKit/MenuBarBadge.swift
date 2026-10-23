import Foundation

/// 已知服务（GLOSSARY：服务定义）：汇总态判定的输入。工单 05 起生产由
/// `ServiceDefinitionCenter.knownDefinitions()` 提供（真实持久化定义），测试注入任意集合。
public struct KnownServiceDefinition: Sendable, Equatable {
    /// 定义的服务名（显示用与诊断用；汇总态判定只看端口）。
    public let name: String
    /// 定义的端口：有定义的服务按此端口判「在监听/挂掉」。
    public let port: Int

    public init(name: String, port: Int) {
        self.name = name
        self.port = port
    }
}

/// 菜单栏汇总态（GLOSSARY：菜单栏图标——全部正常 / 有服务挂了，不开面板也能感知）。
public enum MenuBarBadgeState: Equatable, Sendable {
    /// 全部已知服务正常（或没有任何已知服务）。
    case normal
    /// 任一已知服务挂掉。
    case alert
}

/// 汇总态计算（纯函数，状态注入可测）：
/// 「挂掉」= 有服务定义但该端口未在监听（工单 04 口径）。定义集合为空 → 恒 normal
/// （本票无定义来源）；工单 05 落地定义后，「已停止的托管服务」自然进入判定。
public enum MenuBarBadge {
    public static func state(
        knownServices: [KnownServiceDefinition], listeningPorts: Set<Int>
    ) -> MenuBarBadgeState {
        let hasDownService = knownServices.contains { !listeningPorts.contains($0.port) }
        return hasDownService ? .alert : .normal
    }
}
