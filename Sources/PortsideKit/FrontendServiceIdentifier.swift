import Foundation

/// 前端 dev server 识别器（spec §1 首批）：命令行命中 vite / next / vue-cli-service /
/// webpack 等进程特征即认前端。识别名用 cwd 下 package.json 的 `name` 字段佐证——
/// 读得到用项目自报名，读不到回退工具名（事实），不猜项目名（AGENTS.md 红线）。
public struct FrontendServiceIdentifier: ServiceIdentifier {
    public let identifierName = "前端 dev server"

    /// package.json 读取边界：入参是服务的工作目录，出参是 `name` 字段（读不到为 nil）。
    /// 生产实现读真实文件系统；测试注入闭包伪造，测试进程不碰磁盘。
    public typealias PackageNameReader = @Sendable (_ directory: String) -> String?

    /// 生产读取：<cwd>/package.json → JSON → name 字段（缺失/坏 JSON/空名一律 nil）。
    public static let defaultPackageNameReader: PackageNameReader = { directory in
        let url = URL(fileURLWithPath: directory).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// dev server 进程特征：命令行里某个 token 的文件名（可执行/脚本名）精确匹配。
    /// 精确匹配防误伤——路径里出现 `invite` 之类含 `vite` 字样的片段不算命中。
    static let signatures: Set<String> = [
        "vite", "vite.js", "next", "vue-cli-service", "webpack", "webpack-dev-server",
    ]

    private let packageNameReader: PackageNameReader

    public init(packageNameReader: @escaping PackageNameReader = FrontendServiceIdentifier.defaultPackageNameReader) {
        self.packageNameReader = packageNameReader
    }

    public func identify(_ service: ListeningService) async -> ServiceIdentity? {
        guard let commandLine = service.commandLine, !commandLine.isEmpty else { return nil }
        guard let signature = Self.matchingSignature(in: commandLine) else { return nil }
        // vite.js 这类脚本名归一成工具名做展示。
        let tool = signature.hasSuffix(".js") ? String(signature.dropLast(3)) : signature

        if let directory = service.workingDirectory,
           let projectName = packageNameReader(directory), !projectName.isEmpty {
            return ServiceIdentity(
                type: .frontend, name: projectName,
                evidence: "命令行命中 dev server 特征「\(tool)」；package.json name：\(projectName)。"
            )
        }
        return ServiceIdentity(
            type: .frontend, name: tool,
            evidence: "命令行命中 dev server 特征「\(tool)」；package.json 读不到，用工具名，不猜项目名。"
        )
    }

    /// 命令行里命中的特征名：逐 token 取文件名（末段路径分量）精确比对。
    static func matchingSignature(in commandLine: String) -> String? {
        for token in commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let base = (token as NSString).lastPathComponent
            if signatures.contains(base) {
                return base
            }
        }
        return nil
    }
}
