import XCTest
@testable import PortsideKit

/// 工单 04：行内运行时长——取自进程启动时间（`ps -o etime=`，注入 runner），
/// 取不到留空。解析与格式化为纯函数，采集经 ProcessRunner 边界伪造。
final class ProcessUptimeTests: XCTestCase {
    // MARK: - etime 解析（POSIX 格式 [[dd-]hh:]mm:ss）

    func testetime解析规则表() {
        let cases: [(String, Duration?, String)] = [
            ("03:27", .seconds(207), "分:秒"),
            ("45:10", .seconds(2710), "45 分钟"),
            ("12:34:56", .seconds(45296), "时:分:秒"),
            ("1-02:03:04", .seconds(93784), "天-时:分:秒"),
            ("0-00:00:30", .seconds(30), "天段为 0 照常"),
            ("abc", nil, "非数字不猜"),
            ("", nil, "空串"),
            ("12", nil, "单段不是合法 etime 格式"),
            ("1:2:3:4", nil, "段数超界"),
            ("-5:30", nil, "负数非法"),
        ]
        for (input, expected, note) in cases {
            XCTAssertEqual(UptimeText.parse(etime: input), expected, note)
        }
    }

    // MARK: - 展示格式（行内「运行时长」列）

    func test运行时长展示格式() {
        let cases: [(Duration, String, String)] = [
            (.seconds(0), "0秒", "刚启动"),
            (.seconds(45), "45秒", "不足 1 分钟"),
            (.seconds(207), "3分27秒", "分钟段"),
            (.seconds(45296), "12小时34分", "小时段"),
            (.seconds(93784), "1天2小时", "天段"),
        ]
        for (duration, expected, note) in cases {
            XCTAssertEqual(UptimeText.format(duration), expected, note)
        }
    }

    // MARK: - 批量采集（一次 ps 调用取全部 pid，低资源约束）

    /// 无路由 → 抛错（模拟 ps 不可用）→ 空映射，调用方落 nil 留空。
    func testps不可用时返回空映射不丢服务() async {
        let fetcher = ProcessUptimeFetcher(runner: FakeProcessRunner())

        let uptimes = await fetcher.fetch(pids: [101])

        XCTAssertTrue(uptimes.isEmpty, "采集失败降级为空，运行时长留空")
    }

    func test批量pid一次ps调用并按pid归位() async throws {
        let runner = FakeProcessRunner()
        // 独立事实来源：ps 固定参数形态 -o pid=,etime= -p <逗号清单>（/bin/ps）。
        runner.on("/bin/ps", ["-o", "pid=,etime=", "-p", "101,102"],
                  stdout: "  101        03:27\n  102    1-02:03:04\n")

        let fetcher = ProcessUptimeFetcher(runner: runner)
        let uptimes = await fetcher.fetch(pids: [102, 101])

        XCTAssertEqual(uptimes[101], .seconds(207))
        XCTAssertEqual(uptimes[102], .seconds(93784))
        XCTAssertEqual(runner.calls.count, 1, "一次扫描一轮只发一次 ps（低资源）")
    }

    func test空pid清单不发子进程() async {
        let runner = FakeProcessRunner()
        let fetcher = ProcessUptimeFetcher(runner: runner)

        let uptimes = await fetcher.fetch(pids: [])

        XCTAssertTrue(uptimes.isEmpty)
        XCTAssertTrue(runner.calls.isEmpty, "没有 pid 不发起 ps 调用")
    }

    func testetime坏行跳过不影响好行() async {
        let runner = FakeProcessRunner()
        runner.on("/bin/ps", ["-o", "pid=,etime=", "-p", "101,102"],
                  stdout: "  101   garbage\n  102   00:30\n")

        let uptimes = await ProcessUptimeFetcher(runner: runner).fetch(pids: [101, 102])

        XCTAssertEqual(uptimes[101], nil, "坏行留空不猜")
        XCTAssertEqual(uptimes[102], .seconds(30))
    }
}
