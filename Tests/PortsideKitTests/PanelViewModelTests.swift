import XCTest
@testable import PortsideKit

/// 测试替身：内存键值存储（工单 04：「隐藏其他」持久化的注入点）。
final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var bools: [String: Bool] = [:]

    func bool(forKey key: String) -> Bool {
        lock.withLock { bools[key] ?? false }
    }

    func set(_ value: Bool, forKey key: String) {
        lock.withLock { bools[key] = value }
    }
}

/// 测试替身：扫描器——按序返回预制结果，队列耗尽后重复最后一个
/// （调度测试里多轮 tick 不崩）；记录调用次数供调度断言。
final class FakeScanner: PortScanner, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<ScanResult, Error>]
    private var last: Result<ScanResult, Error>?
    private(set) var callCount = 0

    init(_ results: [Result<ScanResult, Error>]) {
        queued = results
    }

    func scan() async throws -> ScanResult {
        let outcome: Result<ScanResult, Error> = lock.withLock {
            callCount += 1
            if queued.isEmpty { return last! }
            let outcome = queued.removeFirst()
            last = outcome
            return outcome
        }
        return try outcome.get()
    }
}

/// 工单 04：面板 ViewModel——扫描 → 识别 → 分区 → 行模型 → 发布 的串接。
/// 独立事实来源：spec §1（partial 明示）、§2（四区/聚合/隐藏开关）、GLOSSARY（汇总态）。
@MainActor
final class PanelViewModelTests: XCTestCase {
    /// 与识别测试同源的最小真实数据集：Java fat jar / vite / 两个未识别进程。
    private static let services = [
        ListeningService(
            port: 8081, pid: 5011, processName: "java",
            commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"
        ),
        ListeningService(
            port: 5173, pid: 99999, processName: "node",
            commandLine: "/usr/local/bin/node /x/node_modules/.bin/vite --port 5173"
        ),
        ListeningService(
            port: 8787, pid: 832, processName: "Python",
            commandLine: "/usr/bin/python3 -m http.server 8787"
        ),
        ListeningService(port: 9883, pid: 18923, processName: "QQ", commandLine: nil),
    ]

    private func makeModel(
        scanner: PortScanner,
        assigner: SectionAssigner = SectionAssigner(),
        knownDefinitions: @escaping @Sendable () -> [KnownServiceDefinition] = { [] },
        uptimeFetcher: ProcessUptimeFetcher? = nil,
        store: KeyValueStore = InMemoryKeyValueStore(),
        clock: PortsideClock = SystemClock(),
        idleThreshold: Duration = .seconds(120)
    ) -> PanelViewModel {
        PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            assigner: assigner,
            knownDefinitions: knownDefinitions,
            uptimeFetcher: uptimeFetcher,
            store: store,
            clock: clock,
            idleThreshold: idleThreshold
        )
    }

    /// 轮询直到条件成立或超时（VM 的 refresh 在主 actor 异步落定，测试不猜时机）。
    /// 有界 + 超时说明（安全网）：竞态表现为秒级失败并打印在等什么，而非无限挂起。
    private func waitUntil(
        timeout: TimeInterval = 5, what: String, _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if condition() { return true }
        print("⚠️ [PanelViewModelTests] 等待超时(\(timeout)s)：\(what)")
        return false
    }

    // MARK: - 管线：扫描 → 识别 → 四区行

    func test扫描识别分区串成四区行() async {
        let scanner = FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))])
        let model = makeModel(scanner: scanner)

        await model.refreshOnce()

        XCTAssertEqual(model.rows(in: .backend).map(\.displayName), ["user-service"])
        XCTAssertEqual(model.rows(in: .frontend).map(\.displayName), ["vite"])
        XCTAssertEqual(
            model.rows(in: .other).map(\.displayName),
            ["Python（1 个端口）", "QQ（1 个端口）"],
            "未识别按进程名聚合成行（spec §2）"
        )
        XCTAssertEqual(model.rows(in: .mine), [], "本票无定义：我的服务为空区")
        XCTAssertEqual(model.scanNotice, nil, "完整扫描不显 partial 提示")
        XCTAssertEqual(model.health, .normal, "无已知服务：汇总态恒 normal")
    }

    func test有定义的进我的服务() async {
        let scanner = FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))])
        let model = makeModel(
            scanner: scanner,
            assigner: SectionAssigner(hasDefinition: { $0.port == 8081 })
        )

        await model.refreshOnce()

        XCTAssertEqual(model.rows(in: .mine).map(\.displayName), ["user-service"], "收编后移入我的服务")
        XCTAssertEqual(model.rows(in: .backend), [], "从后端区移出")
    }

    func test运行时长取自注入的ps采集取不到留空() async {
        let runner = FakeProcessRunner()
        // 采集器对 pid 去重升序（独立事实），路由按 sorted 形态注册。
        runner.on("/bin/ps", ["-o", "pid=,etime=", "-p", "832,5011,18923,99999"],
                  stdout: "  5011     03:27\n  832   garbage\n")
        let scanner = FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))])
        let model = makeModel(
            scanner: scanner,
            uptimeFetcher: ProcessUptimeFetcher(runner: runner)
        )

        await model.refreshOnce()

        XCTAssertEqual(model.rows(in: .backend)[0].uptimeText, "3分27秒")
        XCTAssertNil(model.rows(in: .frontend)[0].uptimeText, "ps 未报该 pid：留空")
        XCTAssertNil(model.rows(in: .other)[0].uptimeText, "坏行留空")
        XCTAssertNil(model.rows(in: .other)[0].children[0].uptimeText, "聚合明细同样留空")
    }

    // MARK: - partial 明示与扫描失败降级

    func testpartial扫描时列表顶部明示() async {
        let scanner = FakeScanner([.success(ScanResult(
            services: [], source: .netstatFallback, isPartial: true,
            partialNotice: NetstatScanner.partialNotice
        ))])
        let model = makeModel(scanner: scanner)

        await model.refreshOnce()

        XCTAssertEqual(model.scanNotice, NetstatScanner.partialNotice, "spec §1：清单可能不完整必须明示")
    }

    func test扫描失败保留上次数据并明示() async {
        let scanner = FakeScanner([
            .success(ScanResult(services: Self.services, source: .lsof)),
            .failure(ScanError.scanFailed(tool: "lsof", detail: "boom")),
        ])
        let model = makeModel(scanner: scanner)

        await model.refreshOnce()
        let backendBefore = model.rows(in: .backend)
        await model.refreshOnce()

        XCTAssertEqual(model.rows(in: .backend), backendBefore, "扫描失败不清空列表（低资源产品不折腾用户）")
        XCTAssertNotNil(model.scanNotice, "失败要明示，不装死")
    }

    // MARK: - 汇总态（注入可测）

    func test汇总态任一已知服务挂掉变alert恢复变回() async {
        let defs = KnownDefinitionsBox()
        let down = ScanResult(services: [], source: .lsof)
        let up = ScanResult(services: Self.services, source: .lsof)
        let scanner = FakeScanner([.success(down), .success(up)])
        let model = makeModel(scanner: scanner, knownDefinitions: { defs.value })

        defs.value = [KnownServiceDefinition(name: "user-service", port: 8081)]
        await model.refreshOnce()
        XCTAssertEqual(model.health, .alert, "有定义的 8081 未在监听 = 挂掉（工单口径）")

        await model.refreshOnce()
        XCTAssertEqual(model.health, .normal, "恢复监听变回全绿")
    }

    /// 闭包可变捕获载体（@Sendable 闭包不能抓 var）。
    private final class KnownDefinitionsBox: @unchecked Sendable {
        var value: [KnownServiceDefinition] = []
    }

    // MARK: - 「隐藏其他」开关：持久化 + 渲染级（数据不丢）

    func test隐藏其他持久化且数据不丢() async {
        let store = InMemoryKeyValueStore()
        let scanner = FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))])
        let model = makeModel(scanner: scanner, store: store)

        await model.refreshOnce()
        model.isOtherHidden = true

        XCTAssertTrue(store.bool(forKey: PanelViewModel.hideOtherKey), "开关写入持久层")
        XCTAssertEqual(
            model.rows(in: .other).map(\.displayName),
            ["Python（1 个端口）", "QQ（1 个端口）"],
            "隐藏只影响渲染：模型层数据不丢"
        )

        model.isOtherHidden = false
        XCTAssertFalse(store.bool(forKey: PanelViewModel.hideOtherKey), "关掉开关即恢复可见（重开可见）")
    }

    func test重开app恢复上次的隐藏状态() async {
        let store = InMemoryKeyValueStore()
        store.set(true, forKey: PanelViewModel.hideOtherKey)
        let scanner = FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))])
        let model = makeModel(scanner: scanner, store: store)

        XCTAssertTrue(model.isOtherHidden, "启动时从持久层恢复")
    }

    // MARK: - 聚合行折叠态（默认折叠，展开可见明细）

    func test聚合行默认折叠可展开收起() async {
        let scanner = FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))])
        let model = makeModel(scanner: scanner)
        await model.refreshOnce()

        let rowID = model.rows(in: .other)[0].id
        XCTAssertFalse(model.isExpanded(rowID), "默认折叠")

        model.toggleExpanded(rowID)
        XCTAssertTrue(model.isExpanded(rowID), "展开可见明细")

        model.toggleExpanded(rowID)
        XCTAssertFalse(model.isExpanded(rowID), "再点收起")
    }

    // MARK: - 调度：扫描器驱动、无手动刷新、面板隐藏不加速

    func teststart即做首次刷新不等第一个tick() async {
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = makeModel(scanner: scanner)

        model.start()
        // 兜底（stop 幂等）：后面任何断言失败导致用例中止，也保证停掉调度器。
        addTeardownBlock { model.stop() }
        let refreshed = await waitUntil(what: "首刷落定（scanner.callCount >= 1）") { scanner.callCount >= 1 }
        model.stop()

        XCTAssertTrue(refreshed, "启动先刷一次，面板打开即有数据")
    }

    /// 调度行为（复用 ManualClock 虚拟时钟）：面板可见期间活动档 5s；
    /// 消失后不记录活动 → 空闲退避 30s（低资源：面板隐藏不加速刷新）。
    func test面板可见快刷隐藏后退避() async throws {
        let clock = ManualClock()
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = makeModel(scanner: scanner, clock: clock, idleThreshold: .seconds(30))

        model.panelDidAppear()
        model.start()
        addTeardownBlock { model.stop() }
        _ = await waitUntil(what: "初始刷新（scanner.callCount >= 1）") { scanner.callCount >= 1 }

        func fireTick(at time: Duration, expectCalls: Int) async throws {
            try await clock.waitForSleepRegistration()
            clock.advance(to: time)
            _ = await waitUntil(what: "第 \(expectCalls) 次扫描（tick 已 advance 到 \(time)）") {
                scanner.callCount >= expectCalls
            }
        }

        try await fireTick(at: .seconds(5), expectCalls: 2)
        try await fireTick(at: .seconds(10), expectCalls: 3)
        try await fireTick(at: .seconds(15), expectCalls: 4)

        model.panelDidDisappear()
        // 5s 节奏走完退避阈值前的剩余轮次。
        try await fireTick(at: .seconds(20), expectCalls: 5)
        try await fireTick(at: .seconds(25), expectCalls: 6)
        try await fireTick(at: .seconds(30), expectCalls: 7)
        // 隐藏后：30s 内不再刷（t=40 无 tick）。循环此刻已 parked 在睡到 t=60 的那轮
        // sleep 上（tick-30 落定时的注册）——不再 arm，直接拨时间。
        try await clock.waitForSleepRegistration()
        clock.advance(to: .seconds(40))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(scanner.callCount, 7, "面板隐藏：空闲期内不加速刷新")
        // 退避档：下一个 tick 在 30s 后。
        clock.advance(to: .seconds(60))
        _ = await waitUntil(what: "退避档 tick（advance 到 60s 后第 8 次扫描）") { scanner.callCount >= 8 }
        model.stop()
    }

    func teststop后不再刷新() async {
        let clock = ManualClock()
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = makeModel(scanner: scanner, clock: clock)

        model.start()
        addTeardownBlock { model.stop() }
        _ = await waitUntil(what: "首刷落定（scanner.callCount >= 1）") { scanner.callCount >= 1 }
        model.stop()
        // 工单死锁点：旧版这里 `await clock.waitForSleepRegistration()`——CPU 忙时
        // stop 可能先于 runLoop 首次挂 sleep 到达，注册永远不会来，旧实现无界等待
        // → xctest 孤儿进程 0% CPU 死锁。stop 已取消任务：无论循环当时是否已挂上
        // sleep（已挂=取消即醒退出；未挂=启动即取消路径），都不可能再有 tick，
        // 无需（也不能）等注册，直接拨时间断言。
        clock.advance(to: .seconds(500))
        try? await Task.sleep(nanoseconds: 150_000_000)
        clock.advance(to: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(scanner.callCount, 1, "stop 后无新扫描")
    }
}

/// 工单 04：UserDefaults 持久化实现（生产KeyValueStore）。
final class UserDefaultsStoreTests: XCTestCase {
    func testbool读写与缺省false() throws {
        let suite = "portside.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStore(defaults: defaults)

        XCTAssertFalse(store.bool(forKey: "k"), "未写入时缺省 false")
        store.set(true, forKey: "k")
        XCTAssertTrue(store.bool(forKey: "k"))
        store.set(false, forKey: "k")
        XCTAssertFalse(store.bool(forKey: "k"))
    }
}
