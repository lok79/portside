import XCTest
@testable import PortsideKit

/// 工单 02：扫描引擎（数据层）。
/// 接缝：PortsideKit.PortScanner 公共协议——lsof/降级解析行为全部经 scan() 观察，
/// 子进程经 ProcessRunner 边界伪造，测试不真跑 lsof。
final class ScannerTests: XCTestCase {
    /// 真实 lsof 输出节选（macOS 26 实机采集）+ 工单要求的边界行。
    /// - 首行表头；rapportd 双栈同一 (pid,端口) 各一行
    /// - `企业 微信`：进程名含非 ASCII 且带空格，验证不按空白切列截断
    /// - `ControlCe`：lsof 默认 9 字符截断的进程名
    /// - 最后一行：无权限行——lsof 拿不到套接字信息时行尾不是 (LISTEN)，不得伪造服务
    static let lsofFixture = """
    COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    rapportd    457  lok   10u  IPv4 0x862506078ce16c7e      0t0  TCP *:51927 (LISTEN)
    rapportd    457  lok   11u  IPv6 0x4d1b2c3387fd8307      0t0  TCP *:51927 (LISTEN)
    ControlCe   477  lok    9u  IPv4 0x6fa247dd8f6a1de4      0t0  TCP *:7000 (LISTEN)
    Python      832  lok    4u  IPv4 0x7515a9a05c69068f      0t0  TCP 127.0.0.1:8787 (LISTEN)
    jav        5011  lok  100u  IPv6 0xabc123def456789a      0t0  TCP [::1]:8081 (LISTEN)
    企业 微信   18923  lok  300u  IPv4 0x0f0e0d0c0b0a0908      0t0  TCP 127.0.0.1:9883 (LISTEN)
    cloudflared  837  lok    5u  IPv4 0x916570b9f0e7e55        0t0  TCP *:20241 (Permission denied)
    """

    private func scanner(lsofStdout: String) -> (LsofScanner, FakeProcessRunner) {
        let runner = FakeProcessRunner()
        runner.on(
            LsofScanner.lsofPath, LsofScanner.listenArguments,
            stdout: lsofStdout
        )
        return (LsofScanner(runner: runner), runner)
    }

    // MARK: - 切片 A：lsof fixture 解析

    func test从lsof输出解析出监听服务清单按端口排序() async throws {
        let (scanner, _) = scanner(lsofStdout: Self.lsofFixture)

        let result = try await scanner.scan()

        XCTAssertEqual(result.services.map(\.port), [7000, 8081, 8787, 9883, 51927])
        XCTAssertEqual(result.services.map(\.pid), [477, 5011, 832, 18923, 457])
        XCTAssertEqual(
            result.services.map(\.processName),
            ["ControlCe", "jav", "Python", "企业 微信", "rapportd"]
        )
    }

    func test双栈监听同一服务只占一行() async throws {
        let fixture = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        rapportd    457  lok   10u  IPv4 0x862506078ce16c7e      0t0  TCP *:51927 (LISTEN)
        rapportd    457  lok   11u  IPv6 0x4d1b2c3387fd8307      0t0  TCP *:51927 (LISTEN)
        """
        let (scanner, _) = scanner(lsofStdout: fixture)

        let result = try await scanner.scan()

        XCTAssertEqual(result.services.map(\.port), [51927], "IPv4+IPv6 双栈应去重为一行")
        XCTAssertEqual(result.services.count, 1)
    }

    func test无权限行不伪造服务() async throws {
        let (scanner, _) = scanner(lsofStdout: Self.lsofFixture)

        let result = try await scanner.scan()

        XCTAssertFalse(
            result.services.contains { $0.port == 20241 },
            "无权限行（非 (LISTEN) 结尾）不得解析成服务"
        )
        XCTAssertTrue(result.services.contains { $0.port == 8787 }, "同 fixture 中的正常行仍应解析")
    }

    func test本机没有监听端口时返回空结果() async throws {
        let (scanner, _) = scanner(lsofStdout: "COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME\n")

        let result = try await scanner.scan()

        XCTAssertTrue(result.services.isEmpty)
        XCTAssertEqual(result.source, .lsof)
        XCTAssertFalse(result.isPartial)
    }

    // MARK: - 切片 B：命令行与工作目录采集（工单 07 日志发现依赖 cwd）

    /// ps 输出：pid 右对齐首列，`-ww` 下命令行不截断，可含空格与非 ASCII。
    static let psFixture = """
      457 /usr/libexec/rapportd
      477 /usr/libexec/ControlCenter
      832 /Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python .venv/bin/tapd-workflow run
    18923 /Applications/企业微信.app/Contents/MacOS/企业微信 --工作目录=副本
    99999 /usr/bin/vite dev --port 5173
    """

    /// lsof cwd 输出：`p<pid>` 开块，`fcwd`，`n<路径>`。路径含中文与空格。
    static let cwdFixture = """
    p457
    fcwd
    n/
    p477
    fcwd
    n/usr/libexec
    p832
    fcwd
    n/Users/lok/Desktop/副本/日志 目录
    p18923
    fcwd
    n/Users/lok/Desktop/副本
    p99999
    fcwd
    n/Users/lok/dev/前端
    """

    private func scannerWithEnrichment(lsofStdout: String) -> (LsofScanner, FakeProcessRunner) {
        let runner = FakeProcessRunner()
        runner.on(LsofScanner.lsofPath, LsofScanner.listenArguments, stdout: lsofStdout)
        // 实现按 lsof 清单里实际出现的 pid 升序合并成一次调用。
        let pids = [457, 477, 832, 5011, 18923].map(String.init).joined(separator: ",")
        runner.on(
            LsofScanner.psPath, ["-p", pids, "-ww", "-o", "pid=,command="],
            stdout: Self.psFixture
        )
        runner.on(
            LsofScanner.lsofPath, ["-a", "-p", pids, "-d", "cwd", "-Fn"],
            stdout: Self.cwdFixture
        )
        return (LsofScanner(runner: runner), runner)
    }

    func test命令行与工作目录随扫描采集() async throws {
        let (scanner, _) = scannerWithEnrichment(lsofStdout: Self.lsofFixture)

        let result = try await scanner.scan()

        let python = try XCTUnwrap(result.services.first { $0.port == 8787 })
        XCTAssertEqual(
            python.commandLine,
            "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python .venv/bin/tapd-workflow run"
        )
        XCTAssertEqual(python.workingDirectory, "/Users/lok/Desktop/副本/日志 目录", "中文与空格路径不得截断")
    }

    func test进程名用ps完整可执行名替换lsof截断列() async throws {
        let (scanner, _) = scannerWithEnrichment(lsofStdout: Self.lsofFixture)

        let result = try await scanner.scan()

        // lsof 列宽截断成 "ControlCe"；ps 命令行可执行名还原为 ControlCenter。
        let controlCenter = try XCTUnwrap(result.services.first { $0.port == 7000 })
        XCTAssertEqual(controlCenter.processName, "ControlCenter")
        // 命令行本身原样保留（收编弹窗预填依据：它怎么起的就怎么还给你）。
        XCTAssertEqual(controlCenter.commandLine, "/usr/libexec/ControlCenter")
    }

    func testps没覆盖的pid回退lsof进程名且缺失字段显式为空() async throws {
        let (scanner, _) = scannerWithEnrichment(lsofStdout: Self.lsofFixture)

        let result = try await scanner.scan()

        // 5011 在 lsof 清单里但 ps 输出里没有（扫描间隙退出）：服务不丢，
        // 命令行/工作目录显式为 nil（UI 标记"采集不到"），进程名回退 lsof 列。
        let ghost = try XCTUnwrap(result.services.first { $0.port == 8081 })
        XCTAssertEqual(ghost.pid, 5011)
        XCTAssertEqual(ghost.processName, "jav")
        XCTAssertNil(ghost.commandLine)
        XCTAssertNil(ghost.workingDirectory)
    }

    func testps与cwd采集工具都失败时服务仍在且字段为空() async throws {
        let runner = FakeProcessRunner()
        runner.on(LsofScanner.lsofPath, LsofScanner.listenArguments, stdout: Self.lsofFixture)
        // ps 与 cwd 路由未注册 → 伪造器抛错（模拟工具不可用）。
        let scanner = LsofScanner(runner: runner)

        let result = try await scanner.scan()

        XCTAssertEqual(result.services.count, 5, "采集降级不影响服务清单本身")
        XCTAssertEqual(result.source, .lsof)
        for service in result.services {
            XCTAssertNil(service.commandLine)
            XCTAssertNil(service.workingDirectory)
        }
    }

    // MARK: - 切片 C：降级数据源 netstat + ps（lsof 受限/不可用兜底）

    /// 真实 netstat -anv -p tcp 输出节选（macOS 26 实机采集）：
    /// - `Code Helper (Plu:19658`：进程名含空格，内核截断
    /// - `企业微信:18923`：非 ASCII 进程名
    /// - rapportd tcp4+tcp46 双栈两行
    /// - 最后一行 ESTABLISHED，必须忽略
    static let netstatFixture = """
    tcp4       0      0  127.0.0.1.7265         *.*                    LISTEN                 0            0  131072  131072             node:50926  00100 00000106 000000000061a686 00000001 00000800      1      0 000000
    tcp46      0      0  *.51927                *.*                    LISTEN                 0            0  131072  131072         rapportd:457  00100 00000106 00000000005f9f57 00000001 00000800      1      0 000000
    tcp4       0      0  *.51927                *.*                    LISTEN                 0            0  131072  131072         rapportd:457  00100 00000000 0000000000000000 00000001 00000800      1      0 000000
    tcp4       0      0  127.0.0.1.52413        *.*                    LISTEN                 0            0  131072  131072   Code Helper (Plu:19658  00100 00000106 00000000005fdd2e 00000001 00000800      1      0 000000
    tcp4       0      0  127.0.0.1.9883         *.*                    LISTEN                 0            0  131072  131072     企业微信:18923  00000 00000206 00000000005fcfc2 00000000 00002800      1      0 000000
    tcp4       0      0  127.0.0.1.16067        127.0.0.1.60481        ESTABLISHED            1148            0  407808  146988           AweSun:55679  00182 00000004 00000000004efa01 00000080 01000800      2      0 000000
    """

    func test从netstat输出解析出监听服务并标记partial() async throws {
        let runner = FakeProcessRunner()
        runner.on(NetstatScanner.netstatPath, NetstatScanner.netstatArguments, stdout: Self.netstatFixture)
        let scanner = NetstatScanner(runner: runner)

        let result = try await scanner.scan()

        XCTAssertEqual(result.services.map(\.port), [7265, 9883, 51927, 52413])
        XCTAssertEqual(result.services.map(\.pid), [50926, 18923, 457, 19658])
        XCTAssertEqual(
            result.services.map(\.processName),
            ["node", "企业微信", "rapportd", "Code Helper (Plu"],
            "含空格与非 ASCII 的进程名不得截断错位"
        )
        XCTAssertEqual(result.source, .netstatFallback)
        XCTAssertTrue(result.isPartial, "netstat 兜底清单可能不完整，必须显式标记")
        XCTAssertNotNil(result.partialNotice)
        // 未提供 ps 路由 → 命令行采集不到，显式为空。
        for service in result.services {
            XCTAssertNil(service.commandLine)
        }
    }

    func testnetstat兜底也采集命令行() async throws {
        let runner = FakeProcessRunner()
        runner.on(NetstatScanner.netstatPath, NetstatScanner.netstatArguments, stdout: Self.netstatFixture)
        runner.on(
            LsofScanner.psPath, ["-p", "457,18923,19658,50926", "-ww", "-o", "pid=,command="],
            stdout: " 50926 /usr/local/bin/node server.js\n"
        )
        let scanner = NetstatScanner(runner: runner)

        let result = try await scanner.scan()

        let node = try XCTUnwrap(result.services.first { $0.port == 7265 })
        XCTAssertEqual(node.commandLine, "/usr/local/bin/node server.js")
        XCTAssertEqual(node.processName, "node")
    }

    /// macOS 15+ 收紧 lsof（实机验证过）：lsof exit 0 但静默漏掉他人/root 套接字，
    /// netstat 仍看得见——组合扫描器合并补齐并标记 partial。
    static let lsofRestrictedFixture = """
    COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
    rapportd    457  lok   10u  IPv4 0x862506078ce16c7e      0t0  TCP *:51927 (LISTEN)
    Python      832  lok    4u  IPv4 0x7515a9a05c69068f      0t0  TCP 127.0.0.1:8787 (LISTEN)
    """

    func testlsof受限时合并netstat补齐并标记partial() async throws {
        let runner = FakeProcessRunner()
        runner.on(LsofScanner.lsofPath, LsofScanner.listenArguments, stdout: Self.lsofRestrictedFixture)
        runner.on(NetstatScanner.netstatPath, NetstatScanner.netstatArguments, stdout: Self.netstatFixture)
        let scanner = CompositeScanner(
            primary: LsofScanner(runner: runner),
            fallback: NetstatScanner(runner: runner)
        )

        let result = try await scanner.scan()

        // lsof 只看到 8787/51927；7265/9883/52413 由 netstat 补齐。
        XCTAssertEqual(result.services.map(\.port), [7265, 8787, 9883, 51927, 52413])
        XCTAssertTrue(result.isPartial)
        XCTAssertNotNil(result.partialNotice)
    }

    func testlsof清单完整时不标记partial() async throws {
        let runner = FakeProcessRunner()
        runner.on(
            LsofScanner.lsofPath, LsofScanner.listenArguments,
            stdout: """
            COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
            node      50926  lok    4u  IPv4 0x7515a9a05c69068f      0t0  TCP 127.0.0.1:7265 (LISTEN)
            """
        )
        runner.on(
            NetstatScanner.netstatPath, NetstatScanner.netstatArguments,
            stdout: "tcp4       0      0  127.0.0.1.7265         *.*                    LISTEN                 0            0  131072  131072             node:50926  00100 00000106 000000000061a686 00000001 00000800      1      0 000000\n"
        )
        let scanner = CompositeScanner(
            primary: LsofScanner(runner: runner),
            fallback: NetstatScanner(runner: runner)
        )

        let result = try await scanner.scan()

        XCTAssertFalse(result.isPartial)
        XCTAssertNil(result.partialNotice)
        XCTAssertEqual(result.services.map(\.port), [7265])
    }

    func testlsof完全不可用时整体降级netstat() async throws {
        let runner = FakeProcessRunner()
        // lsof 路由未注册 → 抛错（工具不存在）。
        runner.on(NetstatScanner.netstatPath, NetstatScanner.netstatArguments, stdout: Self.netstatFixture)
        let scanner = CompositeScanner(
            primary: LsofScanner(runner: runner),
            fallback: NetstatScanner(runner: runner)
        )

        let result = try await scanner.scan()

        XCTAssertEqual(result.services.map(\.port), [7265, 9883, 51927, 52413])
        XCTAssertEqual(result.source, .netstatFallback)
        XCTAssertTrue(result.isPartial)
        XCTAssertNotNil(result.partialNotice)
    }

    // MARK: - 扫描子进程 locale(工单12 修复:Finder 拉起无 LANG,ps/lsof 把
    // CJK 进程名按字节转义成 M-x 记号 → 面板乱码;根层在 Process 环境注入)。

    func test扫描子进程环境强制UTF8Locale其余继承() {
        let env = SystemProcessRunner.localeEnvironment(base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/x"])
        XCTAssertEqual(env["LC_ALL"], "en_US.UTF-8", "强制 UTF-8,不依赖启动方环境")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin", "其余环境继承不丢")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }
}
