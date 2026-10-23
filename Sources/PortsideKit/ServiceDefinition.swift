import Foundation

/// 服务定义（GLOSSARY：服务定义）：持久保存的服务配置。
/// 只由收编产生（spec §3：v1 没有手动登记入口）；名称即用户别名槽位
/// （DisplayNameResolver 优先级第一位）；停止/重启等托管能力以定义为依据。
public struct ServiceDefinition: Codable, Equatable, Sendable, Identifiable {
    /// 定义标识（收编时生成，跨重启稳定——行 id 与动作路由的依据）。
    public let id: String
    /// 服务名（= 用户别名；改名即改这里，spec §1 显示名优先级：别名 > 识别名 > 未知+端口）。
    public var name: String
    /// 启动命令：收编时取进程 argv **原样**字符串（它怎么起的就怎么还给你，spec §3）。
    /// 匹配时经 `DefinitionMatcher` 规范化比较，落盘保存原样。
    public var launchCommand: String
    /// 定义的端口。
    public var port: Int
    /// 浏览器打开的路径前缀（spec §5，如 `/swagger-ui`）；空 = 默认根路径。保存前已规范化。
    public var pathPrefix: String
    /// 创建时间（收编时刻）。
    public let createdAt: Date

    public init(
        id: String, name: String, launchCommand: String,
        port: Int, pathPrefix: String = "", createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.launchCommand = launchCommand
        self.port = port
        self.pathPrefix = pathPrefix
        self.createdAt = createdAt
    }
}

extension ServiceDefinition {
    /// 路径前缀规范化（spec §5）：`swagger-ui` → `/swagger-ui`、`/a/` → `/a`、空白 → 空。
    /// 保存（收编/编辑）时统一收敛，行模型与打开动作直接拼接、不再各自猜测。
    public static func normalizedPathPrefix(_ raw: String) -> String {
        var prefix = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return "" }
        if !prefix.hasPrefix("/") { prefix = "/" + prefix }
        while prefix.count > 1 && prefix.hasSuffix("/") {
            prefix.removeLast()
        }
        return prefix == "/" ? "" : prefix
    }

    /// 打开地址（spec §5）：`http://localhost:{port}` + 规范化路径前缀。
    public var openURL: URL? {
        URL(string: "http://localhost:\(port)\(pathPrefix)")
    }

    /// 汇总态判定输入（GLOSSARY：菜单栏图标——有定义未在监听 = 挂）。
    public var knownServiceDefinition: KnownServiceDefinition {
        KnownServiceDefinition(name: name, port: port)
    }
}
