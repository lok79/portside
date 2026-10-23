import Foundation

/// 面板行模型（工单 04）：状态点/显示名/类型/端口/运行时长（GLOSSARY：面板）。
/// 单服务行 `children` 为空；「其他」区聚合行带展开明细子行（默认折叠是 ViewModel 渲染态，
/// 不在本模型——隐藏/折叠只影响渲染不丢数据）。
public struct PanelRow: Identifiable, Equatable, Sendable {
    /// 跨扫描稳定的行标识（SwiftUI diff 依据）：单服务行按端口+pid，聚合行按进程名。
    public let id: String
    /// 所属分区（spec §2 四区）。
    public let section: ServiceSectionKind
    /// 状态点：true = 正在监听（正常）。扫描发现的行恒为 true；
    /// 「我的服务」的已停止实例（工单 05 起）为 false。
    public let isUp: Bool
    /// 显示名：单服务行走 DisplayNameResolver 优先级（别名 > 识别名 > 未知+端口）；
    /// 聚合行为「名（N 个端口）」。
    public let displayName: String
    /// 类型列文案（ServiceType.panelLabel）。
    public let typeLabel: String
    /// 行涉及的端口：单服务行恰一个；聚合行为该进程名下全部端口（升序）。
    public let ports: [Int]
    /// 运行时长文案；nil = 取不到，留空（显式标记，不填假数据）。
    public let uptimeText: String?
    /// 聚合行的展开明细（单服务行为空）。
    public let children: [PanelRow]

    public var isAggregated: Bool { !children.isEmpty }
    /// 行的主端口（聚合行取最小端口；无端口行不存在——扫描行必有端口）。
    public var primaryPort: Int? { ports.first }
    /// 「打开」直达地址（spec §5）：`http://localhost:{port}`。
    public var openURL: URL? {
        primaryPort.flatMap { URL(string: "http://localhost:\($0)") }
    }
}

/// 面板行的构造规则（纯函数）：识别结论 + 运行时长 → 各区行。
public enum PanelRowFactory {
    /// 单服务行。`uptimeText` 由 ViewModel 从采集结果格式化后传入；nil 留空。
    public static func leafRow(
        for service: IdentifiedService, section: ServiceSectionKind,
        uptimeText: String?, isUp: Bool = true
    ) -> PanelRow {
        PanelRow(
            id: "row:\(service.service.port):\(service.service.pid.map(String.init) ?? "x")",
            section: section,
            isUp: isUp,
            displayName: service.displayName,
            typeLabel: service.identity.type.panelLabel,
            ports: [service.service.port],
            uptimeText: uptimeText,
            children: []
        )
    }

    /// 「其他」区聚合行（spec §2）：未识别进程按进程名聚合为「名（N 个端口）」，
    /// 展开明细为各端口的单服务行（升序）。行序 = 输入首次出现序（扫描输出按端口升序，
    /// 故聚合行整体也按最小端口有序）。进程名缺失（降级数据源）聚合为「未知进程」，不猜。
    public static func aggregatedRows(
        from services: [IdentifiedService], uptimes: [Int: Duration]
    ) -> [PanelRow] {
        var order: [String] = []
        var byName: [String: [IdentifiedService]] = [:]
        for service in services {
            let name = service.service.processName ?? "未知进程"
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(service)
        }
        return order.map { name in
            let members = byName[name]!.sorted { $0.service.port < $1.service.port }
            let children = members.map { service in
                leafRow(
                    for: service, section: .other,
                    uptimeText: service.service.pid.flatMap { uptimes[$0] }.map(UptimeText.format)
                )
            }
            return PanelRow(
                id: "agg:\(name)",
                section: .other,
                isUp: true,
                displayName: "\(name)（\(members.count) 个端口）",
                typeLabel: ServiceType.unknown.panelLabel,
                ports: children.compactMap(\.primaryPort),
                uptimeText: nil,
                children: children
            )
        }
    }
}

/// 类型列文案（GLOSSARY：识别）。已知类型给稳定中文标签；类型是开放值（D-005），
/// 对照不上的回退 rawValue 展示——如实展示证据，不猜。
extension ServiceType {
    public var panelLabel: String {
        switch self {
        case .java: return "Java"
        case .frontend: return "前端 dev server"
        case .unknown: return "未知"
        default: return rawValue
        }
    }
}
