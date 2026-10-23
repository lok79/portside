import Foundation

/// 主路径扫描器：解析 `lsof -iTCP -sTCP:LISTEN -P -n` 输出。
/// - `-P -n` 必带（spec 技术要点）：否则端口名/DNS 反解慢到不可用。
/// - 解析从行尾固定字段数倒推，进程名（首列）不按空白切列截断——
///   进程名可含非 ASCII 与空格（AGENTS 工单要求）。
/// - 无权限行（lsof 拿不到套接字信息，行尾不是 `(LISTEN)`）直接跳过，不伪造服务。
public final class LsofScanner: PortScanner {
    public static let lsofPath = "/usr/sbin/lsof"
    public static let listenArguments = ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]
    public static let psPath = "/bin/ps"

    private let runner: ProcessRunner

    public init(runner: ProcessRunner) {
        self.runner = runner
    }

    public func scan() async throws -> ScanResult {
        let output: ProcessOutput
        do {
            output = try await runner.run(launchPath: Self.lsofPath, arguments: Self.listenArguments)
        } catch {
            throw error
        }

        var services = LsofParser.parse(output.stdout)
        // lsof exit 1 可伴随部分可用输出（部分文件无法检查），只在拿不到任何行时报失败。
        if services.isEmpty && !output.succeeded {
            throw ScanError.scanFailed(tool: "lsof", detail: "exit=\(output.exitCode) \(output.stderr)")
        }
        await enrich(&services)
        return ScanResult(services: services, source: .lsof)
    }

    /// 为服务补齐命令行与工作目录。采集不到就留 nil 显式标记，
    /// 绝不因补采失败丢弃服务。
    private func enrich(_ services: inout [ListeningService]) async {
        let pids = Array(Set(services.compactMap(\.pid))).sorted()
        guard !pids.isEmpty else { return }
        let details = await ProcessDetailFetcher(runner: runner).fetch(pids: pids)
        services = services.map(details.apply(to:))
    }

    /// 命令行首 token 的文件名部分：`/usr/libexec/rapportd` → `rapportd`。
    static func executableName(of commandLine: String) -> String {
        let first = commandLine.split(separator: " ", omittingEmptySubsequences: true).first
        guard let first else { return commandLine }
        return (first as NSString).lastPathComponent
    }
}

/// 按 pid 批量采集进程明细：命令行与工作目录各一次子进程调用（低资源硬约束）。
/// 调用失败（工具不可用/受限）降级为空映射，由调用方落成 nil 显式标记。
struct ProcessDetailFetcher {
    let runner: ProcessRunner

    func fetch(pids: [Int]) async -> ProcessDetails {
        let sortedPids = Array(Set(pids)).sorted()
        guard !sortedPids.isEmpty else { return ProcessDetails(commandLines: [:], workingDirectories: [:]) }
        let pidList = sortedPids.map(String.init).joined(separator: ",")

        var commandLines: [Int: String] = [:]
        if let output = try? await runner.run(
            launchPath: LsofScanner.psPath,
            arguments: ["-p", pidList, "-ww", "-o", "pid=,command="]
        ) {
            commandLines = PsParser.parse(output.stdout)
        }
        var workingDirectories: [Int: String] = [:]
        if let output = try? await runner.run(
            launchPath: LsofScanner.lsofPath,
            arguments: ["-a", "-p", pidList, "-d", "cwd", "-Fn"]
        ) {
            workingDirectories = LsofCwdParser.parse(output.stdout)
        }
        return ProcessDetails(commandLines: commandLines, workingDirectories: workingDirectories)
    }
}

/// 采集到的进程明细，按 pid 归位；负责把缺失字段落成 nil、把截断进程名换成完整可执行名。
struct ProcessDetails {
    let commandLines: [Int: String]
    let workingDirectories: [Int: String]

    func apply(to service: ListeningService) -> ListeningService {
        guard let pid = service.pid else { return service }
        let commandLine = commandLines[pid]
        return ListeningService(
            port: service.port,
            pid: pid,
            // ps 命令行的可执行名比 lsof/netstat 首列完整（lsof 默认截 9 字符），
            // 拿得到就替换，拿不到回退原列。
            processName: commandLine.map(LsofScanner.executableName(of:)) ?? service.processName,
            commandLine: commandLine,
            workingDirectory: workingDirectories[pid]
        )
    }
}

/// `ps -o pid=,command=` 输出解析：pid 右对齐首列，命令行原样保留（含空格/非 ASCII）。
enum PsParser {
    static func parse(_ text: String) -> [Int: String] {
        var byPid: [Int: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard let spaceIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            guard let pid = Int(trimmed[trimmed.startIndex..<spaceIndex]) else { continue }
            let commandLine = String(trimmed[trimmed.index(after: spaceIndex)...])
                .trimmingCharacters(in: .whitespaces)
            if !commandLine.isEmpty { byPid[pid] = commandLine }
        }
        return byPid
    }
}

/// `lsof -a -p <pids> -d cwd -Fn` 输出解析：`p<pid>` 开块，块内 `n<路径>` 即工作目录。
/// 路径可含中文与空格，整行取 `n` 之后的内容，不按空白切。
enum LsofCwdParser {
    static func parse(_ text: String) -> [Int: String] {
        var byPid: [Int: String] = [:]
        var currentPid: Int?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("p"), let pid = Int(line.dropFirst()) {
                currentPid = pid
            } else if line.hasPrefix("n"), let pid = currentPid, byPid[pid] == nil {
                byPid[pid] = String(line.dropFirst())
            }
        }
        return byPid
    }
}

/// lsof 输出解析。行结构（自右向左固定 10 列）：
/// `COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME`，NAME = `地址 (LISTEN)`。
enum LsofParser {
    /// 解析监听行，按 (pid, port) 去重（双栈监听 v4/v6 各一行只算一个服务），按端口升序。
    static func parse(_ text: String) -> [ListeningService] {
        var byKey: [ServiceKey: ListeningService] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let service = parseLine(String(line)) else { continue }
            byKey[ServiceKey(pid: service.pid, port: service.port)] = service
        }
        return byKey.values.sorted { $0.port < $1.port }
    }

    /// 解析单行；非监听行（表头/无权限/截断行）返回 nil。
    static func parseLine(_ line: String) -> ListeningService? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // 自右向左：地址 (LISTEN) NODE SIZE/OFF DEVICE TYPE FD USER PID COMMAND —— 至少 10 列。
        guard tokens.count >= 10, tokens.last == "(LISTEN)" else { return nil }
        guard tokens[tokens.count - 3] == "TCP" else { return nil }
        guard let port = Self.port(fromAddress: tokens[tokens.count - 2]) else { return nil }
        guard let pid = Int(tokens[tokens.count - 9]) else { return nil }
        let processName = tokens[0..<(tokens.count - 9)].joined(separator: " ")
        return ListeningService(port: port, pid: pid, processName: processName.isEmpty ? nil : processName)
    }

    /// `*:51927` / `127.0.0.1:8787` / `[::1]:8081` → 端口；不合法返回 nil。
    static func port(fromAddress address: String) -> Int? {
        guard let lastColon = address.lastIndex(of: ":") else { return nil }
        let portText = address[address.index(after: lastColon)...]
        guard !portText.isEmpty, let port = Int(portText), port > 0 else { return nil }
        return port
    }

    private struct ServiceKey: Hashable {
        let pid: Int?
        let port: Int
    }
}
