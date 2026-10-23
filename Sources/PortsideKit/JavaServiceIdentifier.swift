import Foundation

/// Java 识别器（spec §1 首批）：命令行含 jar 即认 Java，取 jar 文件名清洗版本尾巴
/// 得识别名（`user-service-1.0.0-SNAPSHOT.jar` → `user-service`，spec 验收 7）；
/// 无 jar 的 JVM 启动器（`java com.app.Main`）靠 `jps -l` 认出并取主类尾段。
/// 清洗不出名字就留空（UI 落「未知 + 端口」），禁止猜（AGENTS.md 红线）。
/// jps 只做交叉验证/补证——工具不在、pid 未列出都不推翻命令行结论。
public struct JavaServiceIdentifier: ServiceIdentifier {
    public let identifierName = "Java"

    /// jps 候选调用序（macOS 上 jps 随 JDK 安装位置不定）：按序尝试，
    /// 首个能执行且 exit 0 的生效，全部失败视为 jps 不可用（交叉验证降级）。
    /// 测试注入候选与 ProcessRunner 路由伪造输出，测试进程从不真跑 jps。
    public typealias JpsCandidate = (launchPath: String, arguments: [String])

    /// 生产候选序：/usr/bin/jps（macOS shim）→ java_home 转发 → Homebrew OpenJDK。
    public static let defaultJpsCandidates: [JpsCandidate] = [
        JpsCandidate(launchPath: "/usr/bin/jps", arguments: ["-l"]),
        JpsCandidate(launchPath: "/usr/libexec/java_home", arguments: ["--exec", "jps", "-l"]),
        JpsCandidate(launchPath: "/opt/homebrew/opt/openjdk/bin/jps", arguments: ["-l"]),
    ]

    /// 子进程边界：jps -l 经此执行。
    private let runner: ProcessRunner
    private let jpsCandidates: [JpsCandidate]

    public init(runner: ProcessRunner, jpsCandidates: [JpsCandidate] = JavaServiceIdentifier.defaultJpsCandidates) {
        self.runner = runner
        self.jpsCandidates = jpsCandidates
    }

    public func identify(_ service: ListeningService) async -> ServiceIdentity? {
        guard let commandLine = service.commandLine, !commandLine.isEmpty else { return nil }
        let jarPath = Self.jarPath(in: commandLine)
        // 触发门槛：命令行含 jar，或由 JVM 启动器拉起。门槛之外不发起 jps
        // 子进程（低资源约束：QQ/微信/python 等不做任何额外调用）。
        guard jarPath != nil || Self.launchesJava(commandLine) else { return nil }

        let jpsEntry = await jpsEntry(pid: service.pid)
        return identity(commandLine: commandLine, jarPath: jarPath, pid: service.pid, jpsEntry: jpsEntry)
    }

    /// 组装识别结论。名字优先级：命令行 jar > jps 的 jar/主类；都没有则名字留空。
    /// 证据如实交代 jps 佐证/未命中/不可用三种状态。
    private func identity(
        commandLine: String, jarPath: String?, pid: Int?, jpsEntry: String?
    ) -> ServiceIdentity {
        if let jarPath {
            let name = Self.cleanedServiceName(fromJarPath: jarPath)
            var evidence = "命令行指向 jar：\(jarPath)，清洗版本尾巴得「\(name)」。"
            evidence += jpsNote(pid: pid, jpsEntry: jpsEntry)
            return ServiceIdentity(type: .java, name: name, evidence: evidence)
        }
        if let jpsEntry {
            if jpsEntry.hasSuffix(".jar") {
                let name = Self.cleanedServiceName(fromJarPath: jpsEntry)
                return ServiceIdentity(
                    type: .java, name: name,
                    evidence: "jps -l 报告 jar：\(jpsEntry)，清洗版本尾巴得「\(name)」。"
                )
            }
            // 主类 `com.app.gateway.GatewayApplication` 取尾段展示；不是路径，按 `.` 切。
            let mainClass = jpsEntry.split(separator: ".").last.map(String.init) ?? jpsEntry
            return ServiceIdentity(
                type: .java, name: mainClass,
                evidence: "jps -l 报告主类：\(jpsEntry)，取尾段「\(mainClass)」。"
            )
        }
        // JVM 启动器是事实，但 jar/主类都拿不到——识别类型成立，名字不猜。
        return ServiceIdentity(
            type: .java, name: nil,
            evidence: "命令行为 JVM 启动器（\(commandLine)），未取得 jar/主类名。"
        )
    }

    /// jps 佐证备注：命中/未列出/不可用。
    private func jpsNote(pid: Int?, jpsEntry: String?) -> String {
        if jpsEntry != nil {
            return "jps -l 佐证（pid \(pid.map(String.init) ?? "未知")）。"
        }
        if pid != nil {
            return "jps -l 未列出该 pid（不影响判定）。"
        }
        return "jps -l 不可用，未交叉验证。"
    }

    /// 按候选序跑一次 jps -l，返回该 pid 的 jar 路径/主类；拿不到返回 nil。
    private func jpsEntry(pid: Int?) async -> String? {
        guard let pid else { return nil }
        for candidate in jpsCandidates {
            guard let output = try? await runner.run(
                launchPath: candidate.launchPath, arguments: candidate.arguments
            ), output.succeeded else { continue }
            return PsParser.parse(output.stdout)[pid]
        }
        return nil
    }

    // MARK: - jar 路径提取

    /// 从命令行取 jar 路径：`-jar` 的下一个参数优先（fat jar 标准起法）；
    /// 否则取第一个以 `.jar` 结尾的路径片段（classpath 的 `:` 分隔片段一并切开，
    /// 跳过 `-D` 之类以 `-` 开头的 JVM 参数）。
    static func jarPath(in commandLine: String) -> String? {
        let tokens = commandLine
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        if let flagIndex = tokens.firstIndex(of: "-jar"), tokens.indices.contains(flagIndex + 1) {
            return tokens[flagIndex + 1]
        }
        for token in tokens {
            for fragment in token.split(separator: ":") {
                let piece = String(fragment)
                if !piece.hasPrefix("-"), piece.hasSuffix(".jar") {
                    return piece
                }
            }
        }
        return nil
    }

    /// 命令行首 token 是否 JVM 启动器（…/bin/java）。
    static func launchesJava(_ commandLine: String) -> Bool {
        guard let first = commandLine
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .first else { return false }
        return (first as NSString).lastPathComponent == "java"
    }

    // MARK: - 版本尾巴清洗

    /// 版本尾巴：`-1.0.0` 这类点分数字，可再跟 `-SNAPSHOT/-RELEASE/-FINAL/-beta1/-rc2/-M1/-ea`
    /// 等限定词（大小写不敏感）。锚定结尾，只剥确认是版本号的尾巴——
    /// 剥不出或剥空则显示原名，不猜。
    private static let versionTail = try! NSRegularExpression(
        pattern: "-\\d+(?:\\.\\d+)*(?:-(?:snapshot|release|final|beta|alpha|rc|ea|m)\\d*[0-9.]*)?$",
        options: [.caseInsensitive]
    )

    /// jar 路径 → 识别名：取文件名、去 `.jar` 后缀、剥版本尾巴；剥完为空回退原名。
    static func cleanedServiceName(fromJarPath jarPath: String) -> String {
        let fileName = (jarPath as NSString).lastPathComponent
        let original = fileName.hasSuffix(".jar") ? String(fileName.dropLast(4)) : fileName
        let range = NSRange(original.startIndex..., in: original)
        guard let match = versionTail.firstMatch(in: original, options: [], range: range),
              match.range.location > 0 else {
            return original
        }
        let prefixEnd = original.index(original.startIndex, offsetBy: match.range.location)
        let stripped = String(original[..<prefixEnd])
        return stripped.isEmpty ? original : stripped
    }
}
