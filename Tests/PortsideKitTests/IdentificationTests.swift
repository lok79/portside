import XCTest
@testable import PortsideKit

/// 工单 03：识别器（GLOSSARY：识别）。
/// 接缝：PortsideKit.ServiceIdentificationEngine 公共引擎——按序尝试识别器、
/// 都不中落未知；识别器子进程一律经 ProcessRunner 边界伪造，测试不真跑 jps；
/// package.json 经注入读取闭包伪造，测试不碰真实文件系统。
final class IdentificationTests: XCTestCase {
    // MARK: - 切片 A：识别器协议与未知兜底

    func test无识别器命中时落未知且不带名字() async {
        let engine = ServiceIdentificationEngine(identifiers: [])
        let service = ListeningService(
            port: 8787, pid: 832, processName: "Python",
            commandLine: "/usr/bin/python3 -m http.server 8787",
            workingDirectory: "/Users/lok/demo"
        )

        let identity = await engine.identify(service)

        XCTAssertEqual(identity.type, .unknown)
        XCTAssertNil(identity.name, "识别不出不得给名字（红线：未知 + 端口，不猜）")
        XCTAssertFalse(identity.evidence.isEmpty, "未知也要说清楚依据")
    }

    /// 引擎对技术栈零假设：测试里的自定义识别器不改引擎一行即被采纳（工单验收 4）。
    private struct AlwaysMatchIdentifier: ServiceIdentifier {
        let identifierName = "测试栈"
        let identity: ServiceIdentity
        func identify(_ service: ListeningService) async -> ServiceIdentity? { identity }
    }

    private struct NeverMatchIdentifier: ServiceIdentifier {
        let identifierName = "不命中栈"
        func identify(_ service: ListeningService) async -> ServiceIdentity? {
            nil
        }
    }

    func test识别器按序尝试首个命中即采纳() async {
        let first = ServiceIdentity(type: ServiceType(rawValue: "测试栈A"), name: "甲", evidence: "第一识别器命中")
        let second = ServiceIdentity(type: ServiceType(rawValue: "测试栈B"), name: "乙", evidence: "第二识别器命中")
        let engine = ServiceIdentificationEngine(identifiers: [
            AlwaysMatchIdentifier(identity: first),
            AlwaysMatchIdentifier(identity: second),
        ])
        let service = ListeningService(port: 9000, pid: 1, processName: "x", commandLine: "x")

        let identity = await engine.identify(service)

        XCTAssertEqual(identity, first, "先注册的识别器先命中先赢")
    }

    func test都未命中时未知证据列出已尝试的识别器() async {
        let engine = ServiceIdentificationEngine(identifiers: [
            NeverMatchIdentifier(), NeverMatchIdentifier(),
        ])
        let service = ListeningService(port: 9000, pid: 1, processName: "x", commandLine: "x")

        let identity = await engine.identify(service)

        XCTAssertEqual(identity.type, .unknown)
        XCTAssertTrue(identity.evidence.contains("不命中栈"), "证据应交代问过哪些识别器")
    }

    // MARK: - 切片 C：Java 识别——fat jar 清洗版本尾巴

    /// jps 路由未注册 → 伪造器抛错（模拟 jps 不在/不可用）：
    /// 命令行里的 jar 本身就是硬证据，识别结论不因佐证缺失而丢。
    func testJavaFatJar命令行清洗出版本尾巴后的名字() async throws {
        let identifier = JavaServiceIdentifier(runner: FakeProcessRunner())
        let service = ListeningService(
            port: 8081, pid: 5011, processName: "java",
            commandLine: "/Library/Java/JavaVirtualMachines/jdk-17/Contents/Home/bin/java -jar /Users/lok/apps/user-service-1.0.0-SNAPSHOT.jar",
            workingDirectory: "/Users/lok/apps/user-service"
        )

        let suggestion = await identifier.identify(service)
        let identity = try XCTUnwrap(suggestion)

        XCTAssertEqual(identity.type, .java)
        XCTAssertEqual(identity.name, "user-service", "spec 验收 7：user-service-1.0.0-SNAPSHOT.jar → user-service")
        XCTAssertTrue(identity.evidence.contains("user-service-1.0.0-SNAPSHOT.jar"), "证据保留原始 jar 路径")
    }

    /// 清洗规则表（工单验收 2）：已知版本形状剥尾巴；形状不认识/剥空显示原名，不猜。
    func test版本尾巴清洗规则表与清洗失败显原名() async {
        // (jar 文件名, 期望识别名, 说明)
        let cases: [(String, String, String)] = [
            ("user-service-1.0.0-SNAPSHOT.jar", "user-service", "SNAPSHOT 限定词"),
            ("order-service-2.3.1.jar", "order-service", "纯点分版本"),
            ("pay-gateway-1.0.0-RELEASE.jar", "pay-gateway", "RELEASE 限定词"),
            ("admin-web-2.0.0-beta.1.jar", "admin-web", "beta 带小版本"),
            ("APP-14.jar", "APP", "单个数字版本"),
            ("my-app.jar", "my-app", "没有版本尾巴，原名即识别名"),
            ("1.0.0.jar", "1.0.0", "剥空回退原名，不猜"),
        ]
        for (fileName, expected, note) in cases {
            let identifier = JavaServiceIdentifier(runner: FakeProcessRunner())
            let service = ListeningService(
                port: 8080, pid: 1, processName: "java",
                commandLine: "/usr/bin/java -jar /apps/\(fileName)"
            )

            let identity = await identifier.identify(service)

            XCTAssertEqual(identity?.name, expected, "\(fileName)：\(note)")
        }
    }

    // MARK: - 切片 E：jps -l 交叉验证（jar / 主类）

    /// XCTUnwrap 的 autoclosure 不支持 await，经此收口。
    private func required(_ identity: ServiceIdentity?) throws -> ServiceIdentity {
        try XCTUnwrap(identity, "识别器应命中")
    }

    /// 首个候选无路由（抛错，模拟该 JDK 不存在）→ 落到第二个候选：候选序即降级序。
    func testjps佐证jar起法且命令行jar名优先() async throws {
        let runner = FakeProcessRunner()
        runner.on("jps备用", ["-l"], stdout: "  5011 /srv/other-path/another-name-9.9.9.jar\n  777 org.gradle.gradle.GradleDaemon\n")
        let identifier = JavaServiceIdentifier(
            runner: runner,
            jpsCandidates: [("jps缺失", ["-l"]), ("jps备用", ["-l"])]
        )
        let service = ListeningService(
            port: 8081, pid: 5011, processName: "java",
            commandLine: "/usr/bin/java -jar /apps/gateway-2.0.0.jar"
        )

        let identity = try required(await identifier.identify(service))

        XCTAssertEqual(identity.type, .java)
        XCTAssertEqual(identity.name, "gateway", "命令行 -jar 指向的 jar 优先于 jps 报告的路径")
        XCTAssertTrue(identity.evidence.contains("jps -l 佐证"), "命中 jps 时证据要交代")
    }

    func testjps主类在无jar命令行时给出识别名() async throws {
        let runner = FakeProcessRunner()
        runner.on("jps", ["-l"], stdout: "  8323 com.app.gateway.GatewayApplication\n")
        let identifier = JavaServiceIdentifier(runner: runner, jpsCandidates: [("jps", ["-l"])])
        let service = ListeningService(
            port: 8082, pid: 8323, processName: "java",
            commandLine: "/Library/Java/Home/bin/java com.app.gateway.GatewayApplication --server.port=8082"
        )

        let identity = try required(await identifier.identify(service))

        XCTAssertEqual(identity.type, .java)
        XCTAssertEqual(identity.name, "GatewayApplication", "无 jar 起法取 jps 主类尾段")
    }

    func testjps不可用时java启动器仍识别但不给名字() async throws {
        // 无 jps 路由 → 伪造器抛错。命令行是 JVM 启动器（java 事实）但无 jar、
        // 无主类来源 → 类型成立、名字留空（UI 落「未知 + 端口」，不猜）。
        let identifier = JavaServiceIdentifier(runner: FakeProcessRunner())
        let service = ListeningService(
            port: 8083, pid: 9, processName: "java",
            commandLine: "/usr/bin/java -Xmx512m -cp conf com.app.Main"
        )

        let identity = try required(await identifier.identify(service))

        XCTAssertEqual(identity.type, .java)
        XCTAssertNil(identity.name)
        XCTAssertFalse(identity.evidence.isEmpty)
    }

    func testjps未列出该pid时命令行jar仍作数() async throws {
        let runner = FakeProcessRunner()
        runner.on("jps", ["-l"], stdout: "  777 org.gradle.gradle.GradleDaemon\n")
        let identifier = JavaServiceIdentifier(runner: runner, jpsCandidates: [("jps", ["-l"])])
        let service = ListeningService(
            port: 8081, pid: 5011, processName: "java",
            commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0.jar"
        )

        let identity = try required(await identifier.identify(service))

        XCTAssertEqual(identity.type, .java)
        XCTAssertEqual(identity.name, "user-service", "jps 没列出（版本错位等）不影响命令行判定")
        XCTAssertTrue(identity.evidence.contains("未列出"), "证据如实交代 jps 未命中")
    }

    func test非java命令行不识别也不触发jps调用() async {
        let runner = FakeProcessRunner()
        let identifier = JavaServiceIdentifier(runner: runner, jpsCandidates: [("jps", ["-l"])])
        let service = ListeningService(
            port: 8787, pid: 832, processName: "Python",
            commandLine: "/usr/bin/python3 -m http.server 8787"
        )

        let suggestion = await identifier.identify(service)

        XCTAssertNil(suggestion)
        XCTAssertTrue(runner.calls.isEmpty, "低资源约束：非 Java 命令行不得发起 jps 子进程")
    }

    // MARK: - 切片 F：前端 dev server 识别（进程特征 + package.json 佐证）

    func testvite命令行packageJson读得到时用项目名() async {
        let identifier = FrontendServiceIdentifier(packageNameReader: { _ in "我的后台管理前端" })
        let service = ListeningService(
            port: 5173, pid: 99999, processName: "node",
            commandLine: "/usr/local/bin/node /Users/lok/web/node_modules/.bin/vite --port 5173",
            workingDirectory: "/Users/lok/web"
        )

        let identity = await identifier.identify(service)

        XCTAssertEqual(identity?.type, .frontend)
        XCTAssertEqual(identity?.name, "我的后台管理前端", "package.json name 是项目自报名，优先于工具名")
        XCTAssertTrue(identity?.evidence.contains("vite") ?? false, "证据交代命中的进程特征")
    }

    func testpackageJson读不到时回退工具名不猜项目名() async {
        let identifier = FrontendServiceIdentifier(packageNameReader: { _ in nil })
        let service = ListeningService(
            port: 5173, pid: 99999, processName: "node",
            commandLine: "/usr/local/bin/node /Users/lok/web/node_modules/.bin/vite",
            workingDirectory: "/Users/lok/web"
        )

        let identity = await identifier.identify(service)

        XCTAssertEqual(identity?.type, .frontend)
        XCTAssertEqual(identity?.name, "vite", "读不到 package.json 用工具名（事实），不猜项目名")
        XCTAssertTrue(identity?.evidence.contains("不猜") ?? false)
    }

    /// 工单验收 1 的特征表：vite / next dev / vue-cli / webpack；无 cwd 时跳过佐证。
    func test前端进程特征表识别() async {
        let cases: [(String, String, String)] = [
            ("/usr/local/bin/node /x/.bin/next dev -p 3000", "next", "next dev"),
            ("/usr/local/bin/node /x/.bin/vue-cli-service serve", "vue-cli-service", "vue-cli"),
            ("/usr/local/bin/node /x/.bin/webpack serve --port 9090", "webpack", "webpack"),
            ("/usr/local/bin/node /x/.bin/webpack-dev-server --port 9090", "webpack-dev-server", "webpack-dev-server"),
            ("/usr/local/bin/node /x/vite.js --port 5173", "vite", "vite.js 归一为 vite"),
        ]
        for (commandLine, expectedName, note) in cases {
            let identifier = FrontendServiceIdentifier(packageNameReader: { _ in nil })
            let service = ListeningService(port: 3000, pid: 7, processName: "node", commandLine: commandLine)

            let identity = await identifier.identify(service)

            XCTAssertEqual(identity?.type, .frontend, note)
            XCTAssertEqual(identity?.name, expectedName, note)
        }
    }

    func testnode普通脚本不识别为前端() async {
        let identifier = FrontendServiceIdentifier(packageNameReader: { _ in "不该被用到" })
        let service = ListeningService(
            port: 7265, pid: 50926, processName: "node",
            commandLine: "/usr/local/bin/node server.js",
            workingDirectory: "/Users/lok/dev"
        )

        let suggestion = await identifier.identify(service)

        XCTAssertNil(suggestion, "node 普通脚本不是 dev server，落未知")
    }

    // MARK: - 切片 G：显示名优先级与同名多实例

    func test显示名优先级别名大于清洗名大于未知端口() {
        let resolver = DisplayNameResolver { service in service.port == 8081 ? "我的用户服务" : nil }
        let named = ListeningService(port: 8081, pid: 1, processName: "java", commandLine: "java -jar /a.jar")
        let userJar = ServiceIdentity(type: .java, name: "user-service", evidence: "e")

        // 别名（工单 05 持久化前的注入槽位）最高。
        XCTAssertEqual(resolver.displayName(for: named, identity: userJar), "我的用户服务")

        // 无别名 → 清洗后的识别名。
        let other = ListeningService(port: 8082, pid: 2, processName: "java", commandLine: "java -jar /b.jar")
        XCTAssertEqual(resolver.displayName(for: other, identity: userJar), "user-service")

        // 无别名无名 → 未知 + 端口。
        let stranger = ListeningService(port: 8787, pid: 3, processName: "Python", commandLine: "python3 -m http.server")
        XCTAssertEqual(
            resolver.displayName(for: stranger, identity: .unknown(evidence: "无命中")),
            "未知 :8787"
        )
    }

    func test同名不同端口各占一行不合并() async {
        let engine = ServiceIdentificationEngine(identifiers: [JavaServiceIdentifier(runner: FakeProcessRunner())])
        let resolver = DisplayNameResolver()
        let instances = [
            ListeningService(port: 8081, pid: 101, processName: "java", commandLine: "java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"),
            ListeningService(port: 8082, pid: 102, processName: "java", commandLine: "java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"),
        ]

        let identified = await engine.identifyAll(instances, resolver: resolver)

        XCTAssertEqual(identified.count, 2, "同名多实例各自成立，模型层不按名去重（spec §1）")
        XCTAssertEqual(identified.map(\.displayName), ["user-service", "user-service"])
        XCTAssertEqual(identified.map { $0.service.port }, [8081, 8082], "端口逐行保留")
    }

    /// 工单验收 1 的引擎级综合 fixture：Java fat jar、vite、next、vue-cli、
    /// python 脚本（未知）、node 普通脚本（未知）一次走完整默认识别管线。
    func test默认识别器序列综合fixture() async {
        let engine = ServiceIdentificationEngine.defaultEngine(runner: FakeProcessRunner())
        let services = [
            ListeningService(port: 8081, pid: 5011, processName: "java", commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar", workingDirectory: "/apps/user-service"),
            ListeningService(port: 8082, pid: 5012, processName: "java", commandLine: "/usr/bin/java -jar /apps/order-service-2.3.1.jar", workingDirectory: "/apps/order-service"),
            ListeningService(port: 5173, pid: 99999, processName: "node", commandLine: "/usr/local/bin/node /x/node_modules/.bin/vite --port 5173", workingDirectory: "/x"),
            ListeningService(port: 3000, pid: 10001, processName: "node", commandLine: "/usr/local/bin/node /x/.bin/next dev -p 3000", workingDirectory: nil),
            ListeningService(port: 4173, pid: 10002, processName: "node", commandLine: "/usr/local/bin/node /x/.bin/vue-cli-service serve", workingDirectory: nil),
            ListeningService(port: 8787, pid: 832, processName: "Python", commandLine: "/usr/bin/python3 -m http.server 8787", workingDirectory: nil),
            ListeningService(port: 7265, pid: 50926, processName: "node", commandLine: "/usr/local/bin/node server.js", workingDirectory: nil),
        ]

        let identified = await engine.identifyAll(services, resolver: DisplayNameResolver())

        // (端口, 期望类型, 期望显示名)
        let expected: [(Int, ServiceType, String)] = [
            (8081, .java, "user-service"),
            (8082, .java, "order-service"),
            (5173, .frontend, "vite"),
            (3000, .frontend, "next"),
            (4173, .frontend, "vue-cli-service"),
            (8787, .unknown, "未知 :8787"),
            (7265, .unknown, "未知 :7265"),
        ]
        XCTAssertEqual(identified.map { $0.service.port }, expected.map(\.0), "输入顺序与条数保持")
        for (row, want) in zip(identified, expected) {
            XCTAssertEqual(row.identity.type, want.1, "端口 \(want.0) 类型")
            XCTAssertEqual(row.displayName, want.2, "端口 \(want.0) 显示名")
        }
    }
}
