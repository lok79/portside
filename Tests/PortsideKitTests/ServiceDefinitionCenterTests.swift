import XCTest
@testable import PortsideKit

/// 工单 05：定义中枢——内存集合 + 持久化协调 + 查询面（分区/别名/汇总态共用）。
final class ServiceDefinitionCenterTests: XCTestCase {
    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeCenter(_ directory: URL) -> ServiceDefinitionCenter {
        ServiceDefinitionCenter(store: DefinitionStore(directory: directory))
    }

    private func service(port: Int, commandLine: String?) -> ListeningService {
        ListeningService(port: port, pid: 1, processName: "proc", commandLine: commandLine)
    }

    // MARK: - 收编

    func test收编生成定义并落盘重启后仍在() {
        let directory = makeDirectory()
        let center = makeCenter(directory)

        center.adopt(
            name: "user-service",
            commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar",
            port: 8081, pathPrefix: ""
        )
        XCTAssertEqual(center.all().count, 1, "收编即生成定义")
        XCTAssertEqual(center.all()[0].launchCommand, "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar", "启动命令保存 argv 原样，不做任何加工")

        // 杀掉 app 重开：新建中枢从同一目录加载，定义仍在（工单验收）。
        let reopened = makeCenter(directory)
        XCTAssertEqual(reopened.all().map(\.name), ["user-service"])
    }

    func test收编同端口同命令替换旧定义不产生重复() {
        let directory = makeDirectory()
        let center = makeCenter(directory)
        let command = "java -jar user-service.jar"

        center.adopt(name: "旧名", commandLine: command, port: 8081, pathPrefix: "")
        center.adopt(name: "新名", commandLine: command, port: 8081, pathPrefix: "/ui")

        XCTAssertEqual(center.all().count, 1, "同端口同命令重复收编 = 更新，不产生重复定义")
        XCTAssertEqual(center.all()[0].name, "新名")
        XCTAssertEqual(center.all()[0].pathPrefix, "/ui")
    }

    func test收编路径前缀保存前规范化() {
        let center = makeCenter(makeDirectory())
        center.adopt(name: "svc", commandLine: "java -jar x.jar", port: 8081, pathPrefix: "swagger-ui/")

        XCTAssertEqual(center.all()[0].pathPrefix, "/swagger-ui")
    }

    // MARK: - 查询面（分区/别名/汇总态共用）

    func test别名与定义查询走匹配器() {
        let center = makeCenter(makeDirectory())
        center.adopt(name: "user-service", commandLine: "java -jar user-service.jar", port: 8081, pathPrefix: "")

        // 空白差异不碍匹配（规范化比较）。
        XCTAssertEqual(
            center.alias(for: service(port: 8081, commandLine: " java  -jar user-service.jar ")),
            "user-service"
        )
        XCTAssertTrue(center.hasDefinition(for: service(port: 8081, commandLine: "java -jar user-service.jar")))
        XCTAssertNotNil(center.matchedDefinition(for: service(port: 8081, commandLine: "java -jar user-service.jar")))

        // 端口或命令对不上、命令行缺失：一律不认（不误认）。
        XCTAssertNil(center.alias(for: service(port: 8082, commandLine: "java -jar user-service.jar")))
        XCTAssertFalse(center.hasDefinition(for: service(port: 8081, commandLine: "java -jar order.jar")))
        XCTAssertFalse(center.hasDefinition(for: service(port: 8081, commandLine: nil)))
    }

    func test已知定义映射给汇总态() {
        let center = makeCenter(makeDirectory())
        center.adopt(name: "user-service", commandLine: "java -jar u.jar", port: 8081, pathPrefix: "")
        center.adopt(name: "vite", commandLine: "node vite", port: 5173, pathPrefix: "")

        XCTAssertEqual(
            center.knownDefinitions(),
            [
                KnownServiceDefinition(name: "user-service", port: 8081),
                KnownServiceDefinition(name: "vite", port: 5173),
            ],
            "菜单栏汇总态的真实定义来源（挂 = 有定义未在监听）"
        )
    }

    // MARK: - 编辑（别名/路径前缀）

    func test改名与路径前缀编辑即时生效且落盘() {
        let directory = makeDirectory()
        let center = makeCenter(directory)
        let adopted = center.adopt(name: "user-service", commandLine: "java -jar u.jar", port: 8081, pathPrefix: "")

        center.edit(id: adopted.id, name: "  用户服务  ", pathPrefix: " /swagger-ui/ ")

        let edited = center.definition(id: adopted.id)
        XCTAssertEqual(edited?.name, "用户服务", "别名即定义名称，编辑即时生效（去首尾空白）")
        XCTAssertEqual(edited?.pathPrefix, "/swagger-ui", "路径前缀规范化后保存")
        XCTAssertEqual(edited?.launchCommand, "java -jar u.jar", "编辑不动启动命令")
        XCTAssertEqual(edited?.port, 8081, "编辑不动端口")

        XCTAssertEqual(makeCenter(directory).definition(id: adopted.id)?.name, "用户服务", "编辑落盘，重启后仍在")
    }

    func test编辑不存在的定义无副作用() {
        let directory = makeDirectory()
        let center = makeCenter(directory)
        let adopted = center.adopt(name: "svc", commandLine: "java -jar u.jar", port: 8081, pathPrefix: "")

        center.edit(id: "def-不存在", name: "x", pathPrefix: "/y")

        XCTAssertEqual(center.all().count, 1)
        XCTAssertEqual(center.all()[0].name, "svc", "不存在的 id：集合不动")
    }

    // MARK: - 删除（工单 09：定义的服务永久消失后，用户手动删掉残留定义）

    func test删除定义移除并落盘重启后不在() {
        let directory = makeDirectory()
        let center = makeCenter(directory)
        let id = center.adopt(name: "user-service", commandLine: "java -jar u.jar", port: 8081, pathPrefix: "").id

        center.remove(id: id)

        XCTAssertTrue(center.all().isEmpty, "删除即从集合移除")
        XCTAssertNil(makeCenter(directory).definition(id: id), "删除落盘，重启后不在")
    }

    func test删除只删目标定义其余不动() {
        let center = makeCenter(makeDirectory())
        let first = center.adopt(name: "user-service", commandLine: "java -jar u.jar", port: 8081, pathPrefix: "")
        let second = center.adopt(name: "vite", commandLine: "node vite", port: 5173, pathPrefix: "")

        center.remove(id: first.id)

        XCTAssertEqual(center.all().map(\.name), ["vite"], "只删目标，其余定义原样")
        XCTAssertEqual(center.definition(id: second.id)?.port, 5173)
    }

    func test删除不存在的定义无副作用() {
        let center = makeCenter(makeDirectory())
        center.adopt(name: "svc", commandLine: "java -jar u.jar", port: 8081, pathPrefix: "")

        center.remove(id: "def-不存在")

        XCTAssertEqual(center.all().count, 1, "不存在的 id：集合不动")
    }
}
