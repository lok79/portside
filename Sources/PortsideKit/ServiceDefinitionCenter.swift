import Foundation

/// 服务定义中枢（GLOSSARY：服务定义）：定义集合的内存态 + 持久化协调 + 查询面。
/// - 收编（adopt）是定义的唯一产生入口（spec §3：v1 无手动登记）；
///   编辑（edit）改名称（= 别名槽位）与路径前缀，不动命令与端口。
/// - 查询面三件套接到既有接缝：`hasDefinition` → SectionAssigner（分区）、
///   `alias` → DisplayNameResolver（显示名）、`knownDefinitions` → MenuBarBadge（汇总态）。
/// - 每次变更全量落盘（DefinitionStore 原子写）；线程安全。
public final class ServiceDefinitionCenter: @unchecked Sendable {
    private let store: DefinitionStore
    private let matcher: DefinitionMatcher
    private let lock = NSLock()
    private var definitions: [ServiceDefinition]

    /// 从持久层加载启动（杀掉 app 重开后定义仍在）。
    public init(store: DefinitionStore, matcher: DefinitionMatcher = DefinitionMatcher()) {
        self.store = store
        self.matcher = matcher
        self.definitions = store.load()
    }

    // MARK: - 查询

    /// 当前全部定义（收编顺序）。
    public func all() -> [ServiceDefinition] {
        lock.withLock { definitions }
    }

    /// 按 id 取定义（行动作路由用）。
    public func definition(id: String) -> ServiceDefinition? {
        lock.withLock { definitions.first { $0.id == id } }
    }

    /// 运行中实例匹配到的定义；无匹配 nil（SectionAssigner「我的服务」区依据）。
    public func matchedDefinition(for service: ListeningService) -> ServiceDefinition? {
        lock.withLock { matcher.definition(matching: service, in: definitions) }
    }

    /// 分区接缝（DefinitionLookup）：该实例是否有服务定义 →「我的服务」区。
    public func hasDefinition(for service: ListeningService) -> Bool {
        matchedDefinition(for: service) != nil
    }

    /// 别名接缝（DisplayNameResolver.AliasLookup）：匹配定义的名称即用户别名。
    public func alias(for service: ListeningService) -> String? {
        matchedDefinition(for: service)?.name
    }

    /// 汇总态接缝（MenuBarBadge）：挂 = 有定义未在监听。
    public func knownDefinitions() -> [KnownServiceDefinition] {
        lock.withLock { definitions.map(\.knownServiceDefinition) }
    }

    // MARK: - 变更（每次全量落盘）

    /// 收编：给正在运行的外部服务补记一条启动命令，生成定义（GLOSSARY：收编）。
    /// - 启动命令保存 argv **原样**；路径前缀保存前规范化。
    /// - 同端口 + 同命令（规范化比较）的定义已存在 → 视为重复收编，更新其名称与前缀
    ///   （保留原 id 与创建时间），不产生重复定义。
    /// - Returns: 生效后的定义。
    @discardableResult
    public func adopt(
        name: String, commandLine: String, port: Int, pathPrefix: String
    ) -> ServiceDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrefix = ServiceDefinition.normalizedPathPrefix(pathPrefix)
        return lock.withLock {
            if let index = definitions.firstIndex(where: {
                $0.port == port && DefinitionMatcher.normalizedCommand($0.launchCommand)
                    == DefinitionMatcher.normalizedCommand(commandLine)
            }) {
                definitions[index].name = trimmedName
                definitions[index].pathPrefix = normalizedPrefix
                persistLocked()
                return definitions[index]
            }
            let adopted = ServiceDefinition(
                id: "def-\(UUID().uuidString)",
                name: trimmedName,
                launchCommand: commandLine,
                port: port,
                pathPrefix: normalizedPrefix,
                createdAt: Date()
            )
            definitions.append(adopted)
            persistLocked()
            return adopted
        }
    }

    /// 编辑定义：名称（别名）与路径前缀；命令与端口不动。id 不存在时无副作用。
    public func edit(id: String, name: String, pathPrefix: String) {
        lock.withLock {
            guard let index = definitions.firstIndex(where: { $0.id == id }) else { return }
            definitions[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            definitions[index].pathPrefix = ServiceDefinition.normalizedPathPrefix(pathPrefix)
            persistLocked()
        }
    }

    /// 落盘当前集合（须持锁调用；写失败由 DefinitionStore 吞掉——内存态已生效，不崩）。
    private func persistLocked() {
        store.save(definitions)
    }
}
