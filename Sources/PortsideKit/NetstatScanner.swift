import Foundation

/// 降级扫描器：`netstat -anv -p tcp` + ps 组合兜底（GLOSSARY：扫描器）。
/// lsof 不存在或受限（macOS 15+ 收紧对他人/root 套接字的访问）时可用；
/// 工作目录拿不到、进程名带内核 16 字符截断——缺失字段一律 nil 显式标记，
/// 且结果恒为 partial（清单可能不完整，UI 必须明示）。
public final class NetstatScanner: PortScanner {
    public static let netstatPath = "/usr/sbin/netstat"
    public static let netstatArguments = ["-anv", "-p", "tcp"]

    /// 降级形态的明示文案：UI 直接展示（spec §1：列表可能不完整时 UI 明示）。
    public static let partialNotice =
        "lsof 不可用或受限，已降级为 netstat 兜底：清单可能不完整，且工作目录等字段拿不到。"

    static let fallbackSource = ScanSource.netstatFallback

    private let runner: ProcessRunner

    public init(runner: ProcessRunner) {
        self.runner = runner
    }

    public func scan() async throws -> ScanResult {
        let output = try await runner.run(
            launchPath: Self.netstatPath, arguments: Self.netstatArguments
        )
        var services = NetstatParser.parse(output.stdout)
        if !services.isEmpty {
            let details = await ProcessDetailFetcher(runner: runner)
                .fetch(pids: services.compactMap(\.pid))
            services = services.map(details.apply(to:))
        }
        return ScanResult(
            services: services,
            source: .netstatFallback,
            isPartial: true,
            partialNotice: Self.partialNotice
        )
    }
}

/// netstat -anv -p tcp 输出解析。
/// 监听行形如：`tcp4 0 0 127.0.0.1.7265 *.* LISTEN 0 0 131072 131072 node:50926 00100 …`，
/// 进程列是 `名字:pid`，名字可含空格与非 ASCII 且被内核截断——按 token 扫描定位，不切列。
enum NetstatParser {
    /// 解析监听行，按 (pid, port) 去重（双栈 tcp4/tcp46 各一行只算一个服务），按端口升序。
    static func parse(_ text: String) -> [ListeningService] {
        var byKey: [String: ListeningService] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let service = parseLine(String(rawLine)) else { continue }
            let key = "\(service.pid ?? -1):\(service.port)"
            byKey[key] = service
        }
        return byKey.values.sorted { $0.port < $1.port }
    }

    /// 解析单行；非 LISTEN 行返回 nil。
    static func parseLine(_ line: String) -> ListeningService? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // tcp4/tcp46 收发队列 本地地址 远程地址 状态 …
        guard tokens.count >= 6 else { return nil }
        guard tokens[0].hasPrefix("tcp") else { return nil }
        guard tokens[5] == "LISTEN" else { return nil }
        guard let port = Self.port(fromLocalAddress: tokens[3]) else { return nil }
        guard let (name, pid) = Self.process(in: Array(tokens[6...])) else { return nil }
        return ListeningService(port: port, pid: pid, processName: name)
    }

    /// 本地地址 `127.0.0.1.7265` / `*.4523` → 端口取最后一个 `.` 之后（IPv6 同样以点结尾）。
    static func port(fromLocalAddress address: String) -> Int? {
        guard let lastDot = address.lastIndex(of: ".") else { return nil }
        let portText = address[address.index(after: lastDot)...]
        guard !portText.isEmpty, let port = Int(portText), port > 0 else { return nil }
        return port
    }

    /// 在状态列之后的 token 里找 `名字:pid`：跳过开头的纯数字列，
    /// 名字可含空格（如 `Code Helper (Plu:19658`），直到以 `:数字` 结尾的 token 收口。
    static func process(in tokens: [String]) -> (String?, Int?)? {
        var index = 0
        // 跳过状态后的纯数字列（收发队列/缓冲区大小等）。
        while index < tokens.count, Int(tokens[index]) != nil { index += 1 }
        guard index < tokens.count else { return nil }
        // 从起点向后收名，直到某个 token 以 ":数字" 结尾——即 名字:pid 的尾巴。
        var nameTokens: [String] = []
        var pid: Int?
        while index < tokens.count {
            let token = tokens[index]
            if let colonIndex = token.lastIndex(of: ":"),
               let candidate = Int(token[token.index(after: colonIndex)...]) {
                nameTokens.append(String(token[token.startIndex..<colonIndex]))
                pid = candidate
                break
            }
            nameTokens.append(token)
            index += 1
        }
        guard pid != nil || !nameTokens.isEmpty else { return nil }
        let name = nameTokens.joined(separator: " ")
        return (name.isEmpty ? nil : name, pid)
    }
}
