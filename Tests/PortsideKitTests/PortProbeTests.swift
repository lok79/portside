import XCTest
import Darwin
@testable import PortsideKit

/// 周期探活器（F2，spec §7 短超时 TCP 探活）：对已知定义端口独立 5s 节奏探测；
/// 只探清单内端口、无定义不发起连接、在途不叠加。
final class PortProbeTests: XCTestCase {
    /// 线程安全记录盒（onOutcome 从探测任务线程到达）。
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(port: Int, outcome: PortProbeOutcome)] = []
        func record(_ port: Int, _ outcome: PortProbeOutcome) {
            lock.withLock { items.append((port, outcome)) }
        }
        var all: [(port: Int, outcome: PortProbeOutcome)] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
    }

    /// 测试替身：按序返回预制探活结论，耗尽后重复最后一个；记录调用次数；可注入延迟。
    private final class FakeProber: PortProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [PortProbeOutcome]
        private(set) var callCount = 0
        var delay: Duration = .zero

        init(_ outcomes: [PortProbeOutcome]) { queued = outcomes }

        func probe(port: Int) async -> PortProbeOutcome {
            if delay > .zero {
                try? await Task.sleep(nanoseconds: UInt64(delay.components.seconds) * 1_000_000_000
                    + UInt64(delay.components.attoseconds / 1_000_000_000))
            }
            return lock.withLock {
                callCount += 1
                let first = queued.first
                if first != nil { queued.removeFirst() }
                return first ?? .noResponse
            }
        }
    }

    func test按5秒节奏只探清单内端口() async throws {
        let clock = ManualClock()
        let prober = FakeProber([.listening])
        let box = OutcomeBox()
        let probe = PortProbe(
            ports: { [8081, 9090] },
            prober: prober,
            clock: clock,
            onOutcome: { port, outcome in box.record(port, outcome) }
        )
        probe.start()
        addTeardownBlock { probe.stop() }

        try await clock.waitForSleepRegistration()
        clock.advance(to: .seconds(5))
        let deadline1 = Date().addingTimeInterval(5)
        while box.count < 2 && Date() < deadline1 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(box.count, 2, "一轮探完清单内全部端口")
        XCTAssertTrue(box.all.allSatisfy { [8081, 9090].contains($0.port) }, "只探清单内端口")

        try await clock.waitForSleepRegistration()
        clock.advance(to: .seconds(10))
        let deadline2 = Date().addingTimeInterval(5)
        while box.count < 4 && Date() < deadline2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(box.count, 4, "独立 5s 节奏：第二轮共 4 次结论")

        probe.stop()
        clock.advance(to: .seconds(600))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(box.count, 4, "stop 后不再探测")
    }

    func test无定义端口时不发起任何探测() async throws {
        let clock = ManualClock()
        let prober = FakeProber([.listening])
        let probe = PortProbe(
            ports: { [] },
            prober: prober,
            clock: clock,
            onOutcome: { _, _ in XCTFail("无定义端口绝不发起连接（低资源红线）") }
        )
        probe.start()
        addTeardownBlock { probe.stop() }

        try await clock.waitForSleepRegistration()
        clock.advance(to: .seconds(15))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(prober.callCount, 0, "无定义：探活轮空转，零连接")
    }

    func test上一轮未落定时跳过下一轮不叠加() async throws {
        let clock = ManualClock()
        let prober = FakeProber([.listening])
        prober.delay = .milliseconds(200)
        let probe = PortProbe(
            ports: { [8081] },
            prober: prober,
            clock: clock,
            onOutcome: { _, _ in }
        )
        probe.start()
        addTeardownBlock { probe.stop() }

        try await clock.waitForSleepRegistration()
        // 一次拨到 10s：5s 与 10s 两个 tick 背靠背触发；第一轮 200ms 未落定时第二个 tick 跳过。
        clock.advance(to: .seconds(10))
        let deadline = Date().addingTimeInterval(3)
        while prober.callCount < 1 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(prober.callCount, 1, "在途闸：重叠轮不叠加（低资源）")
    }
}

/// PanelViewModel 接线（F2）：探活结论喂行状态与菜单栏汇总态——
/// 面板关闭（空闲档 30s 扫描不跑）kill -9 已知服务 ≤10s 图标变色（验收 #2）。
@MainActor
final class ProbeWiringTests: XCTestCase {
    private let argv = "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"

    /// 按序返回预制结论、耗尽后重复 .noResponse。
    private final class ScriptedProber: PortProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [PortProbeOutcome]
        init(_ outcomes: [PortProbeOutcome]) { queued = outcomes }
        func probe(port: Int) async -> PortProbeOutcome {
            lock.withLock {
                let first = queued.first
                if first != nil { queued.removeFirst() }
                return first ?? .noResponse
            }
        }
    }

    private func makeWiredModel(
        prober: PortProbing?,
        scanner: FakeScanner,
        clock: ManualClock,
        idleThreshold: Duration = .seconds(0)
    ) -> (PanelViewModel, ServiceDefinitionCenter) {
        let center = ServiceDefinitionCenter(store: DefinitionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("portside-probe-tests-\(UUID().uuidString)")
        ))
        center.adopt(name: "用户服务", commandLine: argv, port: 8081, pathPrefix: "")
        let model = PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            resolver: DisplayNameResolver(aliasLookup: { center.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { center.hasDefinition(for: $0) }),
            knownDefinitions: { center.knownDefinitions() },
            definitions: center,
            store: InMemoryKeyValueStore(),
            clock: clock,
            idleThreshold: idleThreshold,
            prober: prober
        )
        return (model, center)
    }

    private func waitUntil(
        timeout: TimeInterval = 5, _ what: String, _ condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if condition() { return true }
        print("⚠️ [ProbeWiringTests] 等待超时(\(timeout)s)：\(what)")
        return false
    }

    /// 空闲档形态：idleThreshold=0 → 扫描恒走 30s 档（模拟面板关闭无活动），探活恒 5s。
    func test面板关闭空闲档kill后10秒内图标变色恢复变回() async throws {
        let clock = ManualClock()
        let up = ScanResult(services: [
            ListeningService(port: 8081, pid: 5011, processName: "java", commandLine: argv),
        ], source: .lsof)
        let scanner = FakeScanner([.success(up)])
        let prober = ScriptedProber([.refused, .listening])
        let (model, _) = makeWiredModel(prober: prober, scanner: scanner, clock: clock)

        model.start()
        addTeardownBlock { model.stop() }
        _ = await waitUntil("首刷落定") { scanner.callCount >= 1 }
        XCTAssertEqual(model.health, .normal)
        try await clock.waitForSleepRegistration()   // 扫描循环挂上 30s
        try await clock.waitForSleepRegistration()   // 探活循环挂上 5s

        // t=5s：kill -9 后端口拒绝连接 → 图标变色；扫描仍挂在 30s 档没跑。
        clock.advance(to: .seconds(5))
        _ = await waitUntil("探活发现拒绝连接 → alert") { model.health == .alert }
        XCTAssertEqual(scanner.callCount, 1, "空闲档：变色不依赖扫描轮（探活独立节奏）")

        // t=10s：服务回来 → 变回全绿。
        clock.advance(to: .seconds(10))
        _ = await waitUntil("探活发现恢复监听 → normal") { model.health == .normal }
        model.stop()
    }

    func test连接拒绝翻托管行状态无响应不翻恢复翻回() async throws {
        let clock = ManualClock()
        let up = ScanResult(services: [
            ListeningService(port: 8081, pid: 5011, processName: "java", commandLine: argv),
        ], source: .lsof)
        let scanner = FakeScanner([.success(up)])
        let prober = ScriptedProber([.refused, .noResponse, .listening])
        let (model, _) = makeWiredModel(prober: prober, scanner: scanner, clock: clock)
        await model.refreshOnce()
        XCTAssertEqual(model.rows(in: .mine).first?.isUp, true, "初始：扫描发现运行中")
        model.start()
        addTeardownBlock { model.stop() }
        try await clock.waitForSleepRegistration()
        try await clock.waitForSleepRegistration()

        // 拒绝 = 挂：行状态点翻灰。
        clock.advance(to: .seconds(5))
        _ = await waitUntil("refused → 行翻灰") { model.rows(in: .mine).first?.isUp == false }

        // 无响应 = 不确定：不翻状态（探测失败 ≠ 服务挂）。
        clock.advance(to: .seconds(10))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.rows(in: .mine).first?.isUp, false, "noResponse 保持原状态不翻")

        // 恢复监听：翻回绿。
        clock.advance(to: .seconds(15))
        _ = await waitUntil("listening → 行翻回") { model.rows(in: .mine).first?.isUp == true }
        model.stop()
    }

    func test已停止行不因端口连通翻状态身份由扫描匹配() async throws {
        let clock = ManualClock()
        // 空扫描：定义无匹配实例 → 托管·已停止行。探活却发现端口连通（别人占了端口）。
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let prober = ScriptedProber([.listening])
        let (model, _) = makeWiredModel(prober: prober, scanner: scanner, clock: clock)
        await model.refreshOnce()
        let stoppedRow = try XCTUnwrap(model.rows(in: .mine).first)
        XCTAssertTrue(stoppedRow.id.hasPrefix("def:"), "前置：这是已停止定义行")

        model.start()
        addTeardownBlock { model.stop() }
        try await clock.waitForSleepRegistration()
        try await clock.waitForSleepRegistration()
        clock.advance(to: .seconds(5))
        try? await Task.sleep(nanoseconds: 150_000_000)

        let row = try XCTUnwrap(model.rows(in: .mine).first)
        XCTAssertFalse(row.isUp, "端口连通 ≠ 定义匹配：已停止行的「无匹配实例」语义不因探活翻转")
        XCTAssertEqual(model.health, .normal, "但端口确有监听者：汇总态如实回绿")
        model.stop()
    }

    func test探活结论在定义变更重算后不丢() async throws {
        let clock = ManualClock()
        let up = ScanResult(services: [
            ListeningService(port: 8081, pid: 5011, processName: "java", commandLine: argv),
        ], source: .lsof)
        let scanner = FakeScanner([.success(up)])
        let prober = ScriptedProber([.refused])
        let (model, center) = makeWiredModel(prober: prober, scanner: scanner, clock: clock)
        await model.refreshOnce()
        model.start()
        addTeardownBlock { model.stop() }
        try await clock.waitForSleepRegistration()
        try await clock.waitForSleepRegistration()
        clock.advance(to: .seconds(5))
        _ = await waitUntil("refused → 行翻灰") { model.rows(in: .mine).first?.isUp == false }

        // 定义变更触发免扫描重算：行从扫描事实重建，探活结论必须重新叠加（不回跳假绿）。
        let id = try XCTUnwrap(center.all().first?.id)
        await model.editDefinition(id: id, name: "用户服务改名", pathPrefix: "")

        XCTAssertEqual(model.rows(in: .mine).first?.isUp, false, "重算后探活结论仍生效")
        XCTAssertEqual(model.rows(in: .mine).first?.displayName, "用户服务改名", "重算本身生效")
        model.stop()
    }

    func test无探活器时零开销行为不变() async throws {
        let clock = ManualClock()
        let up = ScanResult(services: [
            ListeningService(port: 8081, pid: 5011, processName: "java", commandLine: argv),
        ], source: .lsof)
        let scanner = FakeScanner([.success(up)])
        let (model, _) = makeWiredModel(prober: nil, scanner: scanner, clock: clock)
        model.start()
        addTeardownBlock { model.stop() }
        _ = await waitUntil("首刷落定") { scanner.callCount >= 1 }
        try await clock.waitForSleepRegistration()
        clock.advance(to: .seconds(5))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.health, .normal, "未接探活器：行为与既有扫描驱动完全一致")
        model.stop()
    }
}

/// 真实 TCP 连接探测（集成面：真 nc 监听者，SystemClock 真超时）。
final class TCPConnectProberIntegrationTests: XCTestCase {
    private static func startListener(port: Int) throws -> Process {
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "\(port)"]
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        return listener
    }

    func test真监听探活listening真拒绝refused() async throws {
        let prober = TCPConnectProber(timeout: .milliseconds(800))
        let listener = try Self.startListener(port: 18141)
        defer { if listener.isRunning { kill(listener.processIdentifier, SIGKILL) } }

        // nc 就绪前可能先拿到 refused——有界重试到 listening（nc 启动毫秒级）。
        var outcome = await prober.probe(port: 18141)
        let deadline = Date().addingTimeInterval(5)
        while outcome != .listening && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            outcome = await prober.probe(port: 18141)
        }
        XCTAssertEqual(outcome, .listening, "真实监听端口：TCP connect 成功")

        kill(listener.processIdentifier, SIGKILL)
        _ = await Self.waitExit(listener.processIdentifier)
        let refused = await prober.probe(port: 18141)
        XCTAssertEqual(refused, .refused, "kill -9 后无人监听：连接拒绝 = 挂（确定性）")

        let closed = await prober.probe(port: 18143)
        XCTAssertEqual(closed, .refused, "从未有监听者的本地端口：同样拒绝")
    }

    private static func waitExit(_ pid: pid_t) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while kill(pid, 0) == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return kill(pid, 0) != 0
    }
}
