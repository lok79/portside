import Foundation

/// 键值持久化接缝（工单 04：面板偏好如「隐藏其他」开关；工单 09：刷新档位）。
/// Kit 只依赖此协议；生产注入 UserDefaults 实现，测试注入内存替身。
public protocol KeyValueStore: Sendable {
    /// 读取布尔值；键不存在时返回 false。
    func bool(forKey key: String) -> Bool
    /// 写入布尔值。
    func set(_ value: Bool, forKey key: String)
    /// 读取字符串；键不存在时返回 nil。
    func string(forKey key: String) -> String?
    /// 写入字符串；nil = 删除该键。
    func set(_ value: String?, forKey key: String)
}

/// 生产实现：UserDefaults（线程安全，进程重启后仍在）。
public final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    public func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
