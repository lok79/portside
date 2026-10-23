import Foundation

/// 识别类型（GLOSSARY：识别）。开放值而非封闭枚举：新增技术栈用新原始值即可，
/// 扫描引擎与识别引擎不写死栈集合（D-005：识别器可扩展，Java/前端只是首批）。
/// 面板分区映射（spec §2）只对照已知值，未知值一律落「其他」。
public struct ServiceType: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Java 后端（spec §1：jar 文件名清洗版本尾巴 / 主类，辅助 jps -l）。
    public static let java = ServiceType(rawValue: "java")
    /// 前端 dev server（spec §1：vite/next/vue-cli 进程特征）。
    public static let frontend = ServiceType(rawValue: "frontend")
    /// 未识别。显示名走「未知 + 端口」，禁止猜（AGENTS.md 红线）。
    public static let unknown = ServiceType(rawValue: "unknown")

    public var description: String { rawValue }
}

/// 一次识别的结论：类型 + 清洗后的识别名 + 证据。
/// `name == nil` 表示没清洗出可展示的名字——UI 落「未知 + 端口」，
/// 不得拿进程名之类的弱信号凑数（不猜）。
public struct ServiceIdentity: Sendable, Equatable {
    public let type: ServiceType
    /// 清洗后的识别名（如 fat jar 剥掉版本尾巴后的服务名）；nil = 识别不出名字。
    public let name: String?
    /// 识别证据：命中哪条识别器、依据什么进程事实。UI 详情与收编弹窗可直接引用。
    public let evidence: String

    public init(type: ServiceType, name: String?, evidence: String) {
        self.type = type
        self.name = name
        self.evidence = evidence
    }

    /// 未知身份：所有识别器都没给出建议。
    public static func unknown(evidence: String) -> ServiceIdentity {
        ServiceIdentity(type: .unknown, name: nil, evidence: evidence)
    }
}

/// 识别器（GLOSSARY：识别）：输入扫描采集到的进程事实，输出识别建议。
/// 新增技术栈 = 新加一个实现并注册进引擎的识别器列表，引擎本身零改动（D-005）。
public protocol ServiceIdentifier: Sendable {
    /// 识别器名（证据与诊断展示用，如「Java」「前端 dev server」）。
    var identifierName: String { get }
    /// 对一个服务实例给出识别建议；不命中返回 nil，交给下一个识别器。
    /// 实现自行决定是否采集辅助证据（如 jps -l），拿不到就基于已有事实收敛，不猜。
    func identify(_ service: ListeningService) async -> ServiceIdentity?
}

/// 识别引擎：按序尝试识别器，首个命中即采纳；都不中落未知（spec §1）。
/// 引擎对技术栈零假设——它只负责「按序问、取第一个、兜底未知」这一件事。
public struct ServiceIdentificationEngine: Sendable {
    /// 按优先级排列的识别器（顺序即语义：先命中先赢）。
    public let identifiers: [ServiceIdentifier]

    public init(identifiers: [ServiceIdentifier]) {
        self.identifiers = identifiers
    }

    /// v1 默认引擎：Java、前端首批识别器按序装配（spec §1；新栈在装配处追加实现即可，引擎零改动）。
    public static func defaultEngine(runner: ProcessRunner) -> ServiceIdentificationEngine {
        ServiceIdentificationEngine(identifiers: [
            JavaServiceIdentifier(runner: runner),
            FrontendServiceIdentifier(),
        ])
    }

    /// 识别单个服务实例；无识别器命中时落未知。
    public func identify(_ service: ListeningService) async -> ServiceIdentity {
        for identifier in identifiers {
            if let suggestion = await identifier.identify(service) {
                return suggestion
            }
        }
        let tried = identifiers.map(\.identifierName).joined(separator: "、")
        let evidence = tried.isEmpty ? "没有可用识别器。" : "所有识别器均未命中（已尝试：\(tried)）。"
        return .unknown(evidence: evidence)
    }

    /// 批量识别并解析显示名。保持输入顺序与条数——同名不同端口各占一行，
    /// 模型层不按名去重（spec §1：同名多实例并存）。
    public func identifyAll(
        _ services: [ListeningService], resolver: DisplayNameResolver
    ) async -> [IdentifiedService] {
        var identified: [IdentifiedService] = []
        identified.reserveCapacity(services.count)
        for service in services {
            let identity = await identify(service)
            identified.append(IdentifiedService(
                service: service,
                identity: identity,
                displayName: resolver.displayName(for: service, identity: identity)
            ))
        }
        return identified
    }
}

/// 面板行模型：服务实例 + 识别结论 + 按优先级解析出的显示名。
public struct IdentifiedService: Sendable, Equatable {
    public let service: ListeningService
    public let identity: ServiceIdentity
    public let displayName: String

    public init(service: ListeningService, identity: ServiceIdentity, displayName: String) {
        self.service = service
        self.identity = identity
        self.displayName = displayName
    }
}
