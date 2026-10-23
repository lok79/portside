import XCTest
@testable import PortsideKit

/// 工单 05：服务定义持久化（spec §3：定义持久化，重启后仍有效）。
/// 接缝 = `DefinitionStore.load()/save()`，文件 IO 走临时目录（路径注入），
/// 验证：往返一致、缺文件空集合、损坏降级不崩并保留损坏副本、目录自动创建。
final class DefinitionStoreTests: XCTestCase {
    /// 每个用例独立临时目录，互不污染。
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func definition(
        name: String = "user-service", port: Int = 8081,
        command: String = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar",
        prefix: String = ""
    ) -> ServiceDefinition {
        ServiceDefinition(
            id: "def-1", name: name, launchCommand: command,
            port: port, pathPrefix: prefix,
            createdAt: Date(timeIntervalSince1970: 1_761_000_000)
        )
    }

    // MARK: - 往返与编码兼容

    func test保存后重读定义集合一致() throws {
        let directory = makeDirectory()
        let store = DefinitionStore(directory: directory)
        let originals = [
            definition(prefix: "/swagger-ui"),
            definition(name: "前端", port: 5173, command: "node vite --port 5173"),
        ]

        store.save(originals)
        let reloaded = store.load()

        XCTAssertEqual(reloaded, originals, "落盘→重读往返一致（含中文名与路径前缀）")
    }

    func test落盘为可读JSON数组格式() throws {
        let directory = makeDirectory()
        let store = DefinitionStore(directory: directory)
        store.save([definition()])

        let fileURL = directory.appendingPathComponent("definitions.json")
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"user-service\""), "定义以 JSON 数组落盘，字段可读")
        XCTAssertTrue(raw.contains("8081"))
    }

    // MARK: - 降级

    func test文件不存在时返回空集合不崩() {
        let store = DefinitionStore(directory: makeDirectory())

        XCTAssertEqual(store.load(), [], "首次启动无定义文件：空集合")
    }

    func test损坏文件降级为空集合并保留损坏副本() throws {
        let directory = makeDirectory()
        let fileURL = directory.appendingPathComponent("definitions.json")
        let garbage = "{\"definitions\": [{ broken"
        try garbage.data(using: .utf8)!.write(to: fileURL)

        let store = DefinitionStore(directory: directory)
        XCTAssertEqual(store.load(), [], "损坏文件降级为空集合，不崩")

        // 损坏副本保留（.corrupt-时间戳），原始内容不丢。
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backups = siblings.filter { $0.hasPrefix("definitions.json.corrupt-") }
        XCTAssertEqual(backups.count, 1, "损坏副本恰好一份")
        let backupContent = try String(
            contentsOf: directory.appendingPathComponent(backups[0]), encoding: .utf8
        )
        XCTAssertEqual(backupContent, garbage, "损坏副本内容与原文件一致")
    }

    func test重复加载损坏文件不覆盖已有损坏副本() throws {
        let directory = makeDirectory()
        let fileURL = directory.appendingPathComponent("definitions.json")
        try "not json".data(using: .utf8)!.write(to: fileURL)
        let store = DefinitionStore(directory: directory)

        _ = store.load()
        try "still not json".data(using: .utf8)!.write(to: fileURL)
        _ = store.load()

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertGreaterThanOrEqual(
            siblings.filter { $0.hasPrefix("definitions.json.corrupt-") }.count, 2,
            "两次损坏各留一份副本，互不覆盖"
        )
    }

    func test降级后可正常重建定义() {
        let directory = makeDirectory()
        let fileURL = directory.appendingPathComponent("definitions.json")
        try? "broken".data(using: .utf8)!.write(to: fileURL)
        let store = DefinitionStore(directory: directory)

        _ = store.load()
        let fresh = [definition()]
        store.save(fresh)

        XCTAssertEqual(store.load(), fresh, "降级为空集合后保存即重建，可继续用")
    }

    // MARK: - 目录与原子写

    func test目录不存在时保存自动创建() {
        let root = makeDirectory()
        let store = DefinitionStore(directory: root.appendingPathComponent("Portside"))

        store.save([definition()])

        XCTAssertEqual(store.load().count, 1, "嵌套目录自动创建，保存成功")
    }

    func test保存不残留临时文件() throws {
        let directory = makeDirectory()
        let store = DefinitionStore(directory: directory)

        store.save([definition()])

        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(
            siblings.filter { !$0.hasPrefix("definitions.json") }, [],
            "原子写收口：目录里只有 definitions.json 及其损坏副本，无 .tmp 残留"
        )
    }
}
