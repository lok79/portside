import Foundation

/// 托管服务生命周期控制接缝（GLOSSARY：托管服务——启动/停止/重启全量可用）。
/// 本票（05）只定义接缝并把按钮动作送达这里；真实现（进程组、信号、孤儿清理）
/// 归工单 06——届时生产装配注入实现即可，UI 与 ViewModel 零改动。
public protocol ProcessController: Sendable {
    /// 按定义启动服务（落盘日志归工单 06/07）。
    func start(_ definition: ServiceDefinition) async throws
    /// 按定义停止服务（对进程组发信号，工单 06）。
    func stop(_ definition: ServiceDefinition) async throws
    /// 按定义重启服务（工单 06）。
    func restart(_ definition: ServiceDefinition) async throws
}
