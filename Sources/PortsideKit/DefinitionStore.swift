import Foundation

/// 定义文件的读写接缝（工单 05）：DefinitionStore 只经此触碰文件系统，
/// 生产注入 FileManager 实现，测试可注入临时目录或内存替身。
public protocol DefinitionFileIO: Sendable {
    /// 读文件原始数据；nil = 文件不存在。
    func contents(at url: URL) -> Data?
    /// 原子写入（先写临时文件再改名，不留半截文件）。
    func writeAtomically(_ data: Data, to url: URL) throws
    /// 确保目录存在（含中间目录）。
    func ensureDirectory(for url: URL) throws
    /// 把文件挪到同目录下的指定新名（损坏副本归档用）；目标已存在或文件不存在时抛错。
    func move(_ from: URL, to: URL) throws
    /// 列目录内容（测试与诊断用）。
    func contentsOfDirectory(at url: URL) throws -> [String]
}

/// 生产实现：FileManager（零第三方依赖）。
public struct FileManagerDefinitionIO: DefinitionFileIO {
    public init() {}

    public func contents(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func ensureDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
    }

    public func move(_ from: URL, to: URL) throws {
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.moveItem(at: from, to: to)
    }

    public func contentsOfDirectory(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
}

/// 服务定义持久化（GLOSSARY：服务定义——停止/重启等托管能力以定义为依据）。
/// - JSON 数组落盘到注入目录的 `definitions.json`（应用容器：`~/Library/Application Support/Portside/`）。
/// - 原子写；损坏文件**降级为空集合并把损坏内容归档为 `definitions.json.corrupt-<时间戳>`**，
///   不崩、可重建（工单 05 验收）。
/// - 读写全走注入的 `DefinitionFileIO`；线程安全（PanelViewModel 主线程调用为主，防御性加锁）。
public final class DefinitionStore: @unchecked Sendable {
    /// 定义文件名。
    public static let fileName = "definitions.json"
    /// 损坏副本前缀：`definitions.json.corrupt-<unix时间戳>`。
    static let corruptPrefix = "definitions.json.corrupt-"

    private let directory: URL
    private let io: DefinitionFileIO
    private let lock = NSLock()

    /// 生产默认目录：`~/Library/Application Support/Portside/`。
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Portside", isDirectory: true)
    }

    /// - Parameters:
    ///   - directory: 定义文件所在目录（注入；测试走临时目录）。
    ///   - io: 文件读写边界（注入；默认 FileManager）。
    public init(directory: URL, io: DefinitionFileIO = FileManagerDefinitionIO()) {
        self.directory = directory
        self.io = io
    }

    /// 定义文件完整路径。
    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    /// 加载全部定义。文件不存在或损坏 → 空集合（损坏时先归档副本，尽力而为）。
    public func load() -> [ServiceDefinition] {
        lock.withLock {
            guard let data = io.contents(at: fileURL) else { return [] }
            do {
                return try Self.decode(data)
            } catch {
                archiveCorrupt()
                return []
            }
        }
    }

    /// 保存全部定义（全量覆写，原子写）。目录不存在自动创建；
    /// 写失败不抛出——内存态已成立，下次变更再落盘（持久化尽力而为，不崩）。
    public func save(_ definitions: [ServiceDefinition]) {
        lock.withLock {
            do {
                try io.ensureDirectory(for: directory)
                try io.writeAtomically(Self.encode(definitions), to: fileURL)
            } catch {
                // 写盘失败不致崩：定义仍在内存中生效（与损坏降级同一口径：可重建、不装死）。
            }
        }
    }

    // MARK: - 编解码（内部静态，纯函数）

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func encode(_ definitions: [ServiceDefinition]) -> Data {
        (try? encoder.encode(definitions)) ?? Data("[]".utf8)
    }

    private static func decode(_ data: Data) throws -> [ServiceDefinition] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ServiceDefinition].self, from: data)
    }

    /// 损坏归档：当前文件挪为 `definitions.json.corrupt-<unix时间戳>`（保留原始内容，
    /// 供用户/后续版本抢救）；重名（同秒两次损坏）追加序号，绝不覆盖旧副本。
    /// 挪动失败也不影响降级返回空集合。
    private func archiveCorrupt() {
        try? io.ensureDirectory(for: directory)
        let siblings = (try? io.contentsOfDirectory(at: directory)) ?? []
        let timestamp = Int(Date().timeIntervalSince1970)
        var candidate = "\(Self.corruptPrefix)\(timestamp)"
        var counter = 2
        while siblings.contains(candidate), counter <= 99 {
            candidate = "\(Self.corruptPrefix)\(timestamp)-\(counter)"
            counter += 1
        }
        try? io.move(fileURL, to: directory.appendingPathComponent(candidate))
    }
}
