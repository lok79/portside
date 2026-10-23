import Foundation

/// 托管服务生命周期控制接缝（GLOSSARY：托管服务——启动/停止/重启全量可用）。
/// 本票（05）只定义接缝并把按钮动作送达这里；真实现（进程组、信号、孤儿清理）
/// 归工单 06——届时生产装配注入实现即可，UI 与 ViewModel 零改动。
/// 工单 08（adr/0001）扩认领两件：登记（reclaim）与身份查询（isReclaimedInstance）。
public protocol ProcessController: Sendable {
    /// 按定义启动服务（落盘日志归工单 06/07）。
    func start(_ definition: ServiceDefinition) async throws
    /// 按定义停止服务（对进程组发信号，工单 06）。
    func stop(_ definition: ServiceDefinition) async throws
    /// 按定义重启服务（工单 06）。
    func restart(_ definition: ServiceDefinition) async throws
    /// 认领登记（工单 08）：把按服务定义匹配到的运行中实例纳回运行态追踪
    /// （受管外部实例）。返回 false = 未能登记（实例已退出 / 与在追条目冲突）。
    /// 注意：必须是协议要求（而非仅 extension 默认实现）——存在量词调用才动态
    /// 分派到真实现，extension 默认体只服务桩/替身形态。
    func reclaim(definitionID: String, pid: pid_t) -> Bool
    /// 该定义当前是否为认领的受管外部实例（日志视图「输出未接管」兜底形态的依据）。
    func isReclaimedInstance(definitionID: String) -> Bool
}

// 工单 08：认领要求的默认实现（桩/替身形态零改动；ShellProcessController 覆写为真登记）。
extension ProcessController {
    public func reclaim(definitionID: String, pid: pid_t) -> Bool { false }
    public func isReclaimedInstance(definitionID: String) -> Bool { false }
}
