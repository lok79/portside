import Foundation

/// 面板行模型（工单 04）：状态点/显示名/类型/端口/运行时长（GLOSSARY：面板）。
/// 单服务行 `children` 为空；「其他」区聚合行带展开明细子行（默认折叠是 ViewModel 渲染态，
/// 不在本模型——隐藏/折叠只影响渲染不丢数据）。
public struct PanelRow: Identifiable, Equatable, Sendable {
    /// 跨扫描稳定的行标识（SwiftUI diff 依据）：单服务行按端口+pid，聚合行按进程名，
    /// 已停止定义行按定义 id（`def:<id>`，工单 05）。
    public let id: String
    /// 所属分区（spec §2 四区）。
    public let section: ServiceSectionKind
    /// 状态点：true = 正在监听（正常）；false = 已停止（托管定义无匹配实例，工单 05 起）。
    public let isUp: Bool
    /// 托管标记（GLOSSARY：托管服务）：true = 该行有服务定义（收编产生），
    /// 停止/重启/日志全量可用；false = 外部服务，可见可探活、降级形态（spec §4）。
    public let isManaged: Bool
    /// 匹配到的服务定义 id（托管行动作路由的依据）；外部行 nil。
    public let definitionID: String?
    /// 显示名：单服务行走 DisplayNameResolver 优先级（别名 > 识别名 > 未知+端口）；
    /// 聚合行为「名（N 个端口）」；已停止行 = 定义名。
    public let displayName: String
    /// 类型列文案（ServiceType.panelLabel）；已停止行 =「已停止」。
    public let typeLabel: String
    /// 行涉及的端口：单服务行恰一个；聚合行为该进程名下全部端口（升序）。
    public let ports: [Int]
    /// 运行时长文案；nil = 取不到，留空（显式标记，不填假数据）。
    public let uptimeText: String?
    /// 进程命令行原文（argv 原样，收编弹窗预填依据）；采集不到为 nil，不猜。
    public let commandLine: String?
    /// 进程 id（工单 07 外部日志发现链输入）；降级数据源拿不到为 nil，不猜。
    public let pid: Int?
    /// 工作目录（工单 07 目录兜底发现输入）；采集不到为 nil，不猜。
    public let workingDirectory: String?
    /// 浏览器打开的路径前缀（spec §5，已规范化，如 `/swagger-ui`；外部行空）。
    public let pathPrefix: String
    /// 聚合行的展开明细（单服务行为空）。
    public let children: [PanelRow]

    public init(
        id: String, section: ServiceSectionKind, isUp: Bool, isManaged: Bool,
        definitionID: String?, displayName: String, typeLabel: String, ports: [Int],
        uptimeText: String?, commandLine: String?, pid: Int? = nil,
        workingDirectory: String? = nil, pathPrefix: String, children: [PanelRow]
    ) {
        self.id = id
        self.section = section
        self.isUp = isUp
        self.isManaged = isManaged
        self.definitionID = definitionID
        self.displayName = displayName
        self.typeLabel = typeLabel
        self.ports = ports
        self.uptimeText = uptimeText
        self.commandLine = commandLine
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.pathPrefix = pathPrefix
        self.children = children
    }

    public var isAggregated: Bool { !children.isEmpty }
    /// 行的主端口（聚合行取最小端口；无端口行不存在——扫描行必有端口）。
    public var primaryPort: Int? { ports.first }
    /// 「打开」直达地址（spec §5）：`http://localhost:{port}` + 路径前缀。
    public var openURL: URL? {
        primaryPort.flatMap { URL(string: "http://localhost:\($0)\(pathPrefix)") }
    }

    /// 只翻状态点的副本（探活覆盖用，F2）：其余字段一律原样。
    func withStatus(isUp: Bool) -> PanelRow {
        PanelRow(
            id: id, section: section, isUp: isUp, isManaged: isManaged,
            definitionID: definitionID, displayName: displayName, typeLabel: typeLabel,
            ports: ports, uptimeText: uptimeText, commandLine: commandLine, pid: pid,
            workingDirectory: workingDirectory, pathPrefix: pathPrefix, children: children
        )
    }

    /// 只换展开明细子行的副本（端口搜索收窄用，工单 13）：其余字段一律原样。
    func withChildren(_ children: [PanelRow]) -> PanelRow {
        PanelRow(
            id: id, section: section, isUp: isUp, isManaged: isManaged,
            definitionID: definitionID, displayName: displayName, typeLabel: typeLabel,
            ports: ports, uptimeText: uptimeText, commandLine: commandLine, pid: pid,
            workingDirectory: workingDirectory, pathPrefix: pathPrefix, children: children
        )
    }
}

/// 面板行的构造规则（纯函数）：识别结论 + 运行时长 + 定义上下文 → 各区行。
public enum PanelRowFactory {
    /// 单服务行。`uptimeText` 由 ViewModel 从采集结果格式化后传入；nil 留空。
    /// `definition` 非空 = 托管·运行中（带定义上下文：托管标记、路径前缀、动作路由 id）。
    public static func leafRow(
        for service: IdentifiedService, section: ServiceSectionKind,
        uptimeText: String?, isUp: Bool = true,
        definition: ServiceDefinition? = nil
    ) -> PanelRow {
        PanelRow(
            id: "row:\(service.service.port):\(service.service.pid.map(String.init) ?? "x")",
            section: section,
            isUp: isUp,
            isManaged: definition != nil,
            definitionID: definition?.id,
            displayName: service.displayName,
            typeLabel: service.identity.type.panelLabel,
            ports: [service.service.port],
            uptimeText: uptimeText,
            commandLine: service.service.commandLine,
            pid: service.service.pid,
            workingDirectory: service.service.workingDirectory,
            pathPrefix: definition?.pathPrefix ?? "",
            children: []
        )
    }

    /// 托管·已停止行（工单 05）：有定义无匹配实例（GLOSSARY：服务定义——托管能力以定义为依据）。
    /// 如实展示定义自身数据；无进程事实的字段一律留空，不猜（AGENTS.md 红线）。
    public static func stoppedRow(for definition: ServiceDefinition) -> PanelRow {
        PanelRow(
            id: "def:\(definition.id)",
            section: .mine,
            isUp: false,
            isManaged: true,
            definitionID: definition.id,
            displayName: definition.name,
            typeLabel: "已停止",
            ports: [definition.port],
            uptimeText: nil,
            commandLine: definition.launchCommand,
            pathPrefix: definition.pathPrefix,
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
                isManaged: false,
                definitionID: nil,
                displayName: "\(name)（\(members.count) 个端口）",
                typeLabel: ServiceType.unknown.panelLabel,
                ports: children.compactMap(\.primaryPort),
                uptimeText: nil,
                commandLine: nil,
                pathPrefix: "",
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
