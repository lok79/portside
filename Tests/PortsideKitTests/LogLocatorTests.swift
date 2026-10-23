import XCTest
@testable import PortsideKit

/// 工单 07：外部服务日志发现（spec §6 发现链：①lsof fd 扫描 → ②目录惯例兜底 → ③明示未发现）。
/// lsof fixture 与真机 `lsof -a -p <pid> -Fatn` 输出同构（p/f/a/t/n 字段行，实测采样）。
final class LogLocatorTests: XCTestCase {
    private var directory: URL?

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
    }

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-log-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
        return url
    }

    private func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: false, encoding: .utf8)
    }

    /// 注入修改时间（发现链的排序依据）：路径 → 日期，未注册 = 遥远过去。
    private func dateProvider(_ dates: [String: Date]) -> (URL) -> Date? {
        { dates[$0.path] ?? Date(timeIntervalSince1970: 0) }
    }

    // MARK: - LsofFdParser（①fd 扫描输出解析）

    /// 与真机采样同构的 fixture：cwd/txt/chr 干扰项 + 追加写日志 + 只读文件。
    private static let lsofFixture = """
    p5011
    fcwd
    a
    tDIR
    n/Users/dev/订单服务
    ftxt
    a
    tREG
    n/usr/bin/java
    f0
    ar
    tCHR
    n/dev/null
    f1
    aw
    tREG
    n/Users/dev/订单服务/server.log
    f2
    au
    tREG
    n/Users/dev/订单服务/debug.out
    f3
    ar
    tREG
    n/Users/dev/订单服务/readme.log
    f4
    aw
    tFIFO
    n
    f5
    aw
    tREG
    n/Users/dev/订单服务/notes.txt
    """

    func test解析只认写追加模式打开的log与out文件() {
        let paths = LsofFdParser.parse(Self.lsofFixture).map(\.path)

        XCTAssertEqual(Set(paths), [
            "/Users/dev/订单服务/server.log",   // aw：追加写 .log
            "/Users/dev/订单服务/debug.out",    // au：读写 .out
        ], "只认写/追加模式的 .log/.out；只读(f3)、.txt(f5)、FIFO(f4)、cwd/txt 干扰项全部排除")
    }

    func test解析REG类型优先于其他类型() {
        let fixture = """
        p5011
        f1
        aw
        tPIPE
        n/tmp/fallback.log
        f2
        aw
        tREG
        n/tmp/regular.log
        """
        let candidates = LsofFdParser.parse(fixture)

        XCTAssertEqual(candidates.map(\.isRegularFile), [false, true],
                       "PIPE(f1) 在前 REG(f2) 在后：解析保序，不排序")
        XCTAssertEqual(candidates.map(\.path), ["/tmp/fallback.log", "/tmp/regular.log"],
                       "REG 排序与否由 locator 取舍，解析只产出候选")
    }

    func test解析空输出与坏行不崩溃() {
        XCTAssertEqual(LsofFdParser.parse(""), [])
        XCTAssertEqual(LsofFdParser.parse("p5011\nf1\nn无模式无名行\n"), [],
                       "缺写模式或缺路径的条目不成候选")
    }

    // MARK: - 托管：直接返回已知落盘路径（文件未建也等待出现）

    func test托管服务返回已知落盘路径即使文件未建() async {
        let logsDirectory = makeDirectory()
        let locator = LogLocator(runner: nil, managedLogsDirectory: logsDirectory)

        let availability = await locator.locate(LogContext(
            serviceName: "user-service", port: 8081,
            isManaged: true, definitionID: "def-1", pid: nil, workingDirectory: nil
        ))

        XCTAssertEqual(
            availability,
            .available(logsDirectory.appendingPathComponent("def-1.log")),
            "托管 = 已知路径（ShellProcessController 落盘通道）；文件尚未创建也照常 tail 等待出现"
        )
    }

    // MARK: - 外部①：fd 扫描命中

    func test外部fd扫描命中进程正在写的日志() async {
        let cwd = makeDirectory()
        let runner = FakeProcessRunner()
        runner.on(LsofScanner.lsofPath, ["-a", "-p", "5011", "-Fatn"], stdout: Self.lsofFixture)
        let locator = LogLocator(runner: runner, managedLogsDirectory: makeDirectory())

        let availability = await locator.locate(LogContext(
            serviceName: "订单服务", port: 8081,
            isManaged: false, definitionID: nil, pid: 5011, workingDirectory: cwd.path
        ))

        XCTAssertEqual(
            availability,
            .available(URL(fileURLWithPath: "/Users/dev/订单服务/server.log")),
            "①主路径：进程正在写的 .log 命中即正确（fixture 里的 lsof 报告路径为准）"
        )
    }

    func test外部多个fd候选REG类型优先() async {
        let cwd = makeDirectory()
        let regular = cwd.appendingPathComponent("regular.log")
        let fallback = cwd.appendingPathComponent("fallback.log")
        write("a\n", to: regular)
        write("b\n", to: fallback)
        let runner = FakeProcessRunner()
        runner.on(LsofScanner.lsofPath, ["-a", "-p", "5011", "-Fatn"], stdout: """
        p5011
        f1
        aw
        tPIPE
        n\(fallback.path)
        f2
        aw
        tREG
        n\(regular.path)
        """)
        let locator = LogLocator(runner: runner, managedLogsDirectory: makeDirectory())

        let availability = await locator.locate(LogContext(
            serviceName: "s", port: 1, isManaged: false,
            definitionID: nil, pid: 5011, workingDirectory: cwd.path
        ))

        XCTAssertEqual(availability, .available(regular), "REG 类型优先，即使另一候选更新")
    }

    func test外部多个fd候选取最近修改() async {
        let cwd = makeDirectory()
        let older = cwd.appendingPathComponent("older.log")
        let newer = cwd.appendingPathComponent("newer.log")
        write("a\n", to: older)
        write("b\n", to: newer)
        let runner = FakeProcessRunner()
        runner.on(LsofScanner.lsofPath, ["-a", "-p", "5011", "-Fatn"], stdout: """
        p5011
        f1
        aw
        tREG
        n\(older.path)
        f2
        aw
        tREG
        n\(newer.path)
        """)
        let dates = [older.path: Date(timeIntervalSince1970: 100),
                     newer.path: Date(timeIntervalSince1970: 200)]
        let locator = LogLocator(
            runner: runner, managedLogsDirectory: makeDirectory(),
            fileModificationDate: dateProvider(dates)
        )

        let availability = await locator.locate(LogContext(
            serviceName: "s", port: 1, isManaged: false,
            definitionID: nil, pid: 5011, workingDirectory: cwd.path
        ))

        XCTAssertEqual(availability, .available(newer), "同类型多候选取最近修改（注入日期可测）")
    }

    // MARK: - 外部②：lsof 失败 → 目录惯例兜底

    func testlsof失败时目录惯例兜底命中nohupout() async {
        let cwd = makeDirectory()
        let nohup = cwd.appendingPathComponent("nohup.out")
        write("boot\n", to: nohup)
        let runner = FakeProcessRunner()   // 无路由 = lsof 不可用（抛错）
        let locator = LogLocator(runner: runner, managedLogsDirectory: makeDirectory())

        let availability = await locator.locate(LogContext(
            serviceName: "gateway", port: 9000,
            isManaged: false, definitionID: nil, pid: 7001, workingDirectory: cwd.path
        ))

        XCTAssertEqual(availability, .available(nohup), "②兜底：cwd/nohup.out 命中")
    }

    func test目录兜底命中logs子目录最近修改() async {
        let cwd = makeDirectory()
        let appLog = cwd.appendingPathComponent("logs/app.log")
        let stale = cwd.appendingPathComponent("log/old.log")
        write("a\n", to: appLog)
        write("b\n", to: stale)
        let dates = [appLog.path: Date(timeIntervalSince1970: 300),
                     stale.path: Date(timeIntervalSince1970: 100)]
        let locator = LogLocator(
            runner: nil, managedLogsDirectory: makeDirectory(),
            fileModificationDate: dateProvider(dates)
        )

        let availability = await locator.locate(LogContext(
            serviceName: "s", port: 1, isManaged: false,
            definitionID: nil, pid: nil, workingDirectory: cwd.path
        ))

        XCTAssertEqual(availability, .available(appLog), "logs/*.log 与 log/*.log 都扫，取最近修改")
    }

    func test无pid时直接走目录兜底() async {
        let cwd = makeDirectory()
        let nohup = cwd.appendingPathComponent("nohup.out")
        write("x\n", to: nohup)
        let runner = FakeProcessRunner()
        let locator = LogLocator(runner: runner, managedLogsDirectory: makeDirectory())

        let availability = await locator.locate(LogContext(
            serviceName: "s", port: 1, isManaged: false,
            definitionID: nil, pid: nil, workingDirectory: cwd.path
        ))

        XCTAssertEqual(availability, .available(nohup), "pid 采集不到（降级数据源）不跳过发现：直接目录兜底")
        XCTAssertEqual(runner.calls, [], "无 pid 不空跑 lsof")
    }

    // MARK: - 外部③：都没有 → 明示未发现

    func test三步都落空返回未发现() async {
        let cwd = makeDirectory()
        let runner = FakeProcessRunner()
        let locator = LogLocator(runner: runner, managedLogsDirectory: makeDirectory())

        let availability = await locator.locate(LogContext(
            serviceName: "s", port: 1, isManaged: false,
            definitionID: nil, pid: 6001, workingDirectory: cwd.path
        ))

        XCTAssertEqual(availability, .notFound, "lsof 无命中 + 目录无惯例文件 → 未发现（UI 明示，不装死）")
        XCTAssertEqual(runner.calls, [
            FakeProcessRunner.key(launchPath: LsofScanner.lsofPath,
                                  arguments: ["-a", "-p", "6001", "-Fatn"]),
        ], "fd 扫描一次，失败落空不再重复调用")
    }

    func test外部服务无工作目录时lsof无命中则未发现() async {
        let runner = FakeProcessRunner()
        let locator = LogLocator(runner: runner, managedLogsDirectory: makeDirectory())

        let availability = await locator.locate(LogContext(
            serviceName: "s", port: 1, isManaged: false,
            definitionID: nil, pid: 6002, workingDirectory: nil
        ))

        XCTAssertEqual(availability, .notFound, "cwd 缺失：fd 扫描仍执行，目录兜底无从做起")
    }
}
