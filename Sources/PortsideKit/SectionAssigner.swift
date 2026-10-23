import Foundation

/// 服务定义查询接缝（GLOSSARY：服务定义——收编产生的持久配置）。
/// 入参运行中实例的进程事实（端口、命令行，按「端口 + 启动命令」匹配），
/// 出参该实例是否有服务定义。工单 05 起生产注入 `ServiceDefinitionCenter.hasDefinition`
/// （DefinitionMatcher 实现）；测试注入任意闭包，本接口与分区逻辑零改动。
public typealias DefinitionLookup = @Sendable (_ service: ListeningService) -> Bool

/// 分区归属器（spec §2 四区规则）：IdentifiedService → ServiceSectionKind。
/// - 我的服务：有服务定义的（含已停止实例，spec §2）。
/// - 后端：识别为 Java、尚未收编的。
/// - 前端：识别为 dev server 的。
/// - 其他：未识别的（含类型开放值对照不上的，D-005——不写死栈集合）。
public struct SectionAssigner: Sendable {
    /// 空定义集合（工单 04 兼容形态/测试基线）：没有任何服务有定义。
    public static let noDefinitions: DefinitionLookup = { _ in false }

    public let hasDefinition: DefinitionLookup

    public init(hasDefinition: @escaping DefinitionLookup = SectionAssigner.noDefinitions) {
        self.hasDefinition = hasDefinition
    }

    /// 单个服务实例的分区归属。
    public func section(for service: IdentifiedService) -> ServiceSectionKind {
        if hasDefinition(service.service) { return .mine }
        switch service.identity.type {
        case .java: return .backend
        case .frontend: return .frontend
        // 已知值只对照 Java/前端；其余（未知与未来新栈）一律落「其他」。
        default: return .other
        }
    }

    /// 批量分组：`[分区: 该区服务列表]`，区内顺序 = 输入顺序（扫描输出按端口升序）。
    /// 每个服务恰落一区，分组后总数与输入一致。
    public func group(_ services: [IdentifiedService]) -> [ServiceSectionKind: [IdentifiedService]] {
        var grouping: [ServiceSectionKind: [IdentifiedService]] = [:]
        for kind in ServiceSectionKind.allCases { grouping[kind] = [] }
        for service in services {
            grouping[section(for: service), default: []].append(service)
        }
        return grouping
    }
}
