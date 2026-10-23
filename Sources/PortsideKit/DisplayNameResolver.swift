import Foundation

/// 显示名解析（spec §1 优先级）：**用户别名 > 清洗后的识别名 > 未知 + 端口**。
/// 别名的持久化载体是服务定义（工单 05）——本票先用注入的别名查询闭包占位：
/// 工单 05 落地时按「端口 + 启动命令」匹配服务定义返回别名即可，本接口不动。
public struct DisplayNameResolver: Sendable {
    /// 别名查询：入参服务实例（进程事实齐全，供匹配用），出参用户设置的别名（无则 nil）。
    public typealias AliasLookup = @Sendable (_ service: ListeningService) -> String?

    /// 默认无别名（工单 05 接入持久化前的空实现）。
    public static let noAliases: AliasLookup = { _ in nil }

    public let aliasLookup: AliasLookup

    public init(aliasLookup: @escaping AliasLookup = DisplayNameResolver.noAliases) {
        self.aliasLookup = aliasLookup
    }

    /// 「未知 + 端口」文案，与面板行 `名称 :端口` 的排版一致（spec 用户故事 1）。
    public func displayName(for service: ListeningService, identity: ServiceIdentity) -> String {
        if let alias = aliasLookup(service)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !alias.isEmpty {
            return alias
        }
        if let name = identity.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return "未知 :\(service.port)"
    }
}
