import Foundation

/// 日志上下文（工单 07）：日志视图打开时的服务事实——发现链的输入。
/// 托管 = 定义 id（落盘通道已知路径）；外部 = pid + 工作目录（发现链输入，均可缺失）。
/// 工单 08：`isReclaimed` 标记认领的受管外部实例——已纳管但**输出未接管**
/// （外部时代起的进程，输出仍流向原处），日志发现按「标准路径有文件则用 →
/// 外部发现链兜底 → 明示」走，不装死。
public struct LogContext: Equatable, Sendable {
    /// 服务显示名（日志视图头部）。
    public let serviceName: String
    /// 端口（日志视图头部；降级数据源可能缺失）。
    public let port: Int?
    /// true = 托管服务（GLOSSARY：落盘通道已知）；false = 外部服务（走发现链）。
    public let isManaged: Bool
    /// 服务定义 id（托管路径的文件名）；外部为 nil。
    public let definitionID: String?
    /// 进程 id（fd 扫描输入）；降级数据源拿不到为 nil。
    public let pid: Int?
    /// 工作目录（目录兜底输入）；采集不到为 nil。

    public let workingDirectory: String?
    /// true = 认领的受管外部实例（工单 08）；亲生托管/外部服务为 false。
    public let isReclaimed: Bool

    public init(
        serviceName: String, port: Int?, isManaged: Bool,
        definitionID: String?, pid: Int?, workingDirectory: String?,
        isReclaimed: Bool = false
    ) {
        self.serviceName = serviceName
        self.port = port
        self.isManaged = isManaged
        self.definitionID = definitionID
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.isReclaimed = isReclaimed
    }
}

/// 日志发现结果（GLOSSARY：日志流——托管与外部统一为"发现文件 → tail"）。
/// 托管即使文件未建也返回路径（tail 等待出现）；`.notFound` 由 UI 明示，不装死。
public enum LogAvailability: Equatable, Sendable {
    case available(URL)
    case notFound
}

/// 日志定位接缝：PanelViewModel 只认此协议，测试注入假实现。
public protocol LogLocating: Sendable {
    func locate(_ context: LogContext) async -> LogAvailability
}

/// lsof `-Fatn` 字段输出解析（工单 07 fd 扫描）：
/// 每个文件描述符一组 `f`（fd）/`a`（访问模式）/`t`（类型）/`n`（路径）行。
/// 只认**写/追加模式**（`w`/`u`；`r`=只读、空=无访问语义）打开的 `.log`/`.out` 文件
/// （spec §6：进程正在写的文件，命中即正确）；REG 类型排前，其余类型为次选。
/// 路径可含中文与空格，整行取字段字母之后的内容，不按空白切。
public enum LsofFdParser {
    /// 一个候选：路径 + 是否 REG 类型（locator 据"REG 优先 → 最近修改"取舍）。
    public struct Candidate: Equatable, Sendable {
        public let path: String
        public let isRegularFile: Bool
    }

    /// 解析全部写/追加模式打开的 .log/.out 候选（不排序——取舍归 locator）。
    static func parse(_ text: String) -> [Candidate] {
        var candidates: [Candidate] = []
        var mode: String?
        var fileType: String?
        var name: String?
        func flush() {
            if let mode, let name,
               mode == "w" || mode == "u",
               name.hasSuffix(".log") || name.hasSuffix(".out") {
                candidates.append(Candidate(path: name, isRegularFile: fileType == "REG"))
            }
            mode = nil
            fileType = nil
            name = nil
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first else { continue }
            let field = String(line.dropFirst())
            switch first {
            case "f": flush()   // 新的 fd 条目开始，先结清上一条
            case "a": mode = field.trimmingCharacters(in: .whitespaces)
            case "t": fileType = field.trimmingCharacters(in: .whitespaces)
            case "n": name = field
            default: break      // p/d/o/s 等其余字段与发现无关
            }
        }
        flush()
        return candidates
    }
}

/// 日志发现链（spec §6：托管与外部统一"发现文件 → tail"）：
/// - 托管服务：直接返回落盘通道已知路径（`<目录>/<定义id>.log`）——文件还没建也返回，
///   tail 侧等待出现（GLOSSARY：托管服务——Portside 持有它的输出通道）。
/// - 外部服务：① `lsof -a -p <pid> -Fatn` 查进程以写/追加模式打开的 .log/.out
///   （REG 优先，多个取最近修改）→ lsof 失败或无命中 →
///   ② 工作目录惯例兜底（nohup.out、*.out、logs/*.log、log/*.log，取最近修改）→
///   ③ 都没有 → `.notFound`（UI 明示「外部启动，未发现日志文件」）。
public struct LogLocator: LogLocating {
    /// ③未发现的明示文案（GLOSSARY：日志流——不装死）。
    public static let externalLogNotFoundNotice = "外部启动，未发现日志文件"
    /// 认领实例未发现的明示文案（工单 08：已纳管但输出未接管，也不装死）。
    public static let reclaimedLogNotFoundNotice =
        "已认领为托管，但未接管其输出，也未发现它正在写的日志文件"

    private let runner: ProcessRunner?
    private let managedLogsDirectory: URL
    /// 修改时间读取（注入可测）：生产 = 文件属性；测试 = 预制日期。
    private let fileModificationDate: @Sendable (URL) -> Date?

    /// - Parameters:
    ///   - runner: lsof 执行边界；nil = 跳过 fd 扫描（测试可关，直接走目录兜底）。
    ///   - managedLogsDirectory: 托管落盘日志目录（与 ShellProcessController 一致）。
    ///   - fileModificationDate: 修改时间读取（注入；缺省读真实文件属性）。
    public init(
        runner: ProcessRunner?,
        managedLogsDirectory: URL,
        fileModificationDate: @escaping @Sendable (URL) -> Date?
    ) {
        self.runner = runner
        self.managedLogsDirectory = managedLogsDirectory
        self.fileModificationDate = fileModificationDate
    }

    /// 简便装配：修改时间读真实文件属性。
    public init(runner: ProcessRunner?, managedLogsDirectory: URL) {
        self.init(
            runner: runner, managedLogsDirectory: managedLogsDirectory,
            fileModificationDate: { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                    as? Date
            }
        )
    }

    /// 生产装配：真实 lsof + 真实文件属性。
    public static func production(managedLogsDirectory: URL) -> LogLocator {
        LogLocator(runner: SystemProcessRunner(), managedLogsDirectory: managedLogsDirectory)
    }

    public func locate(_ context: LogContext) async -> LogAvailability {
        if context.isManaged {
            let managedURL = managedLogsDirectory.appendingPathComponent(
                "\(context.definitionID ?? "").log"
            )
            if context.isReclaimed {
                // 认领实例（工单 08）：标准落盘路径有文件 = 解耦真身——前一世 Portside
                // 落的盘，句柄仍在子进程手里，命中即正确；无文件 = 该实例输出从未经
                // Portside 落盘（外部时代起的），落下方 07 外部发现链兜底，明示不装死。
                if Self.isFile(managedURL.path) { return .available(managedURL) }
            } else {
                // 亲生/本会话启动：已知路径，无条件返回（文件未建 = tail 等待出现，工单口径）。
                return .available(managedURL)
            }
        }
        // ① fd 扫描：进程正在写的 .log/.out（命中即正确）。
        if let pid = context.pid, let candidates = await scanOpenFiles(pid: pid), !candidates.isEmpty {
            if let best = pickRecent(candidates) {
                return .available(URL(fileURLWithPath: best))
            }
        }        // ② 目录惯例兜底：lsof 失败/无命中时，工作目录下找最近修改的惯例文件。
        if let cwd = context.workingDirectory,
           let best = pickRecent(conventionalFiles(cwd: cwd)) {
            return .available(URL(fileURLWithPath: best))
        }
        // ③ 都没有：明示未发现。
        return .notFound
    }

    /// ①进程打开的 .log/.out 写/追加候选（保留 REG 标记，取舍在 pickRecent）；
    /// lsof 失败返回 nil（调用方落 ②）。
    private func scanOpenFiles(pid: Int) async -> [LsofFdParser.Candidate]? {
        guard let runner else { return nil }
        guard let output = try? await runner.run(
            launchPath: LsofScanner.lsofPath, arguments: ["-a", "-p", "\(pid)", "-Fatn"]
        ) else { return nil }
        // 非零退出（受限/无此进程）可能伴随部分输出：有候选就用候选，没有落 ②。
        let candidates = LsofFdParser.parse(output.stdout)
        return candidates.isEmpty ? nil : candidates
    }

    /// ②工作目录惯例清单（spec §6：nohup.out、logs/、log/；*.out 覆盖别名输出）。
    private func conventionalFiles(cwd: String) -> [String] {
        let manager = FileManager.default
        var files: [String] = []
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        // cwd 顶层：nohup.out、其余 *.out。
        if let entries = try? manager.contentsOfDirectory(atPath: cwd) {
            files += entries
                .filter { $0.hasSuffix(".out") }
                .map { cwdURL.appendingPathComponent($0).path }
        }
        // logs/ 与 log/ 子目录的 *.log。
        for subdirectory in ["logs", "log"] {
            let directory = cwdURL.appendingPathComponent(subdirectory)
            if let entries = try? manager.contentsOfDirectory(atPath: directory.path) {
                files += entries
                    .filter { $0.hasSuffix(".log") }
                    .map { directory.appendingPathComponent($0).path }
            }
        }
        return files.filter { Self.isFile($0) }
    }

    /// REG 优先，再按最近修改降序取首个（同类型多候选取最近修改；日期缺省视为最旧）。
    private func pickRecent(_ candidates: [LsofFdParser.Candidate]) -> String? {
        let regular = candidates.filter(\.isRegularFile)
        let pool = regular.isEmpty ? candidates : regular
        let best = pool.max { lhs, rhs in
            modified(URL(fileURLWithPath: lhs.path)) < modified(URL(fileURLWithPath: rhs.path))
        }
        return best.map(\.path)
    }

    /// 字符串路径版本（目录兜底共用同一取舍规则）。
    private func pickRecent(_ paths: [String]) -> String? {
        pickRecent(paths.map { LsofFdParser.Candidate(path: $0, isRegularFile: true) })
    }

    private func modified(_ url: URL) -> Date {
        fileModificationDate(url) ?? Date(timeIntervalSince1970: 0)
    }

    private static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
