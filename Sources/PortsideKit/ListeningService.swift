import Foundation

/// 一个监听中的服务实例（GLOSSARY：服务实例）：端口 ↔ 进程的最小映射。
/// 字段为 nil 即"采集不到"的显式标记——UI 应显示占位并说明，禁止拿猜测值填充
/// （AGENTS.md 红线：识别不出显示"未知 + 端口"，不猜）。
public struct ListeningService: Sendable, Equatable, Hashable {
    /// 监听的 TCP 端口。
    public let port: Int
    /// 占用进程的 PID；nil = 降级数据源拿不到。
    public let pid: Int?
    /// 进程名。可能带 lsof 列宽截断；ps 可用时会替换为完整可执行名。
    public let processName: String?
    /// 完整命令行（该进程怎么起的就长什么样，收编弹窗预填的依据）。
    public let commandLine: String?
    /// 工作目录（工单 07 外部日志发现依赖此项，务必随扫描采集）。
    public let workingDirectory: String?

    public init(
        port: Int, pid: Int?, processName: String?,
        commandLine: String? = nil, workingDirectory: String? = nil
    ) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.commandLine = commandLine
        self.workingDirectory = workingDirectory
    }
}

/// 一次扫描的数据来源。
public enum ScanSource: String, Sendable, Equatable {
    /// 主路径：lsof。
    case lsof
    /// 降级路径：netstat + ps 组合（lsof 不可用/受限）。
    case netstatFallback
}

/// 一次扫描的结果。
/// `isPartial == true` 表示清单可能不完整（如 macOS 15+ 收紧 lsof 对他人/root 套接字的
/// 访问，见 spec §1）——UI 必须明示，不得假装列表齐全；`partialNotice` 是给 UI 直接
/// 展示的解释文案。单个服务的缺失字段看 ListeningService 的 nil 字段。
public struct ScanResult: Sendable, Equatable {
    public let services: [ListeningService]
    public let source: ScanSource
    public let isPartial: Bool
    public let partialNotice: String?

    public init(
        services: [ListeningService], source: ScanSource,
        isPartial: Bool = false, partialNotice: String? = nil
    ) {
        self.services = services
        self.source = source
        self.isPartial = isPartial
        self.partialNotice = partialNotice
    }
}
