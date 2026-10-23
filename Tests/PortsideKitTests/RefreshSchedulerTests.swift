import XCTest
@testable import PortsideKit

/// 有界等待超时（安全网）：任何"等通知"的测试辅助，超时都抛它并说明在等什么——
/// 竞态从此表现为秒级失败 + 清晰信息，而不是 xctest 孤儿进程无限挂起。
struct TestWaitTimeout: Error, CustomStringConvertible {
    let what: String
    let timeout: TimeInterval
    var description: String { "等待超时(\(timeout)s)：\(what)" }
}

/// 可注入的虚拟时钟：测试不真睡（工单 02：定时器用注入时钟，可测）。
/// - `sleep(for:)` 挂起直到 `advance(to:)` 越过截止时间，或任务被取消。
/// - `waitForSleepRegistration(timeout:)` 等到被调度方真的挂到下一次 sleep 上
///   （注册计数在挂进队列那一刻增加，粘性，观察者晚到也不错过）；有界，超时即抛。
/// - `registrationGate`：sleep 的可控调度点（deadline 计算后、挂载前），
///   供测试确定性复现 advance 与注册的竞速；生产路径无此钩子。
final class ManualClock: PortsideClock, @unchecked Sendable {
    private final class SleepRequest: @unchecked Sendable {
        let deadline: Duration
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false
        var finished = false

        init(deadline: Duration) { self.deadline = deadline }
    }

    private let lock = NSLock()
    private var virtualNow: Duration = .zero
    private var sleepers: [SleepRequest] = []
    private var pendingRegistrations = 0
    /// 测试注入点：nil = 无注入。
    var registrationGate: (@Sendable () -> Void)?

    func now() -> Duration {
        lock.withLock { virtualNow }
    }

    func sleep(for duration: Duration) async throws {
        let deadline = now() + duration
        // 可控调度点：advance 可以恰在此处越过 deadline（复现竞速窗口）。
        registrationGate?()
        let request = SleepRequest(deadline: deadline)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // body 同步执行：挂 sleeper、计数、唤醒观察者必须都发生在挂起之前，
                // 否则 advance(to:) 找不到 sleeper、观察者永远等不到。
                let resumeSleeper: Bool = self.lock.withLock {
                    if request.cancelled { return true }
                    self.pendingRegistrations += 1
                    // 丢唤醒自愈：deadline 计算与挂载之间 advance 可能已越过截止点——
                    // sleeper 会以"已到期"状态挂入，但 advance 的扫描已经过去，无人再唤醒
                    // （调度循环永睡）。当场视为到期：不入 sleepers、立即 resume——注册即到期即刻醒。
                    // 注册计数照常 +1：观察方的 arm-then-advance 节拍对齐不破。
                    if request.deadline <= self.virtualNow {
                        request.finished = true
                        return true
                    }
                    request.continuation = continuation
                    self.sleepers.append(request)
                    return false
                }
                if resumeSleeper { continuation.resume() }
            }
        } onCancel: {
            self.finish(request)
        }

        try Task.checkCancellation()
    }

    /// 推进虚拟时间，唤醒所有到期的 sleep。
    func advance(to newTime: Duration) {
        let due: [SleepRequest] = lock.withLock {
            virtualNow = max(virtualNow, newTime)
            let due = sleepers.filter { $0.deadline <= virtualNow && !$0.finished }
            let dueIDs = Set(due.map(ObjectIdentifier.init))
            sleepers.removeAll { dueIDs.contains(ObjectIdentifier($0)) }
            due.forEach { $0.finished = true }
            return due
        }
        due.forEach { $0.continuation?.resume() }
    }

    /// 等到下一次 sleep 注册完成（确认循环已推进到下一轮，消除测试竞态）。
    /// - 粘性：注册先于观察也计数，观察者晚到不错过。
    /// - 有界：超时抛 `TestWaitTimeout`。循环被 stop 取消时注册**永远不会来**——
    ///   旧实现无界 waiter 正是 xctest 孤儿进程 0% CPU 死锁的根因。
    /// - 用短轮询而非长驻 waiter：等待点自身不得再成为"永不恢复的 continuation"
    ///   （0.2ms 真实轮询只影响观测粒度，不参与虚拟时间语义）。
    func waitForSleepRegistration(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let got: Bool = lock.withLock {
                if pendingRegistrations > 0 {
                    pendingRegistrations -= 1
                    return true
                }
                return false
            }
            if got { return }
            guard Date() < deadline else {
                throw TestWaitTimeout(
                    what: "sleep 注册（调度循环可能已被 stop 取消或未启动，注册永远不会来）",
                    timeout: timeout
                )
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000)
        }
    }

    private func finish(_ request: SleepRequest) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            request.cancelled = true
            guard let continuation = request.continuation, !request.finished else { return nil }
            request.finished = true
            sleepers.removeAll { $0 === request }
            return continuation
        }
        continuation?.resume()
    }
}

/// 记录 onTick 的触发时刻（调度截止点的虚拟时间），并支持"等到第 N 个 tick 落盘"。
final class TickRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [Duration] = []

    func record(at time: Duration) {
        lock.withLock { times.append(time) }
    }

    /// 等第 `count` 个 tick 记完。有界：超时抛 `TestWaitTimeout`（advance 后 tick
    /// 没发生=调度语义被破坏，必须秒级失败而非无限挂起）。
    func waitForCount(_ count: Int, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while lock.withLock({ times.count >= count }) == false {
            guard Date() < deadline else {
                let recorded = lock.withLock { times.count }
                throw TestWaitTimeout(
                    what: "第 \(count) 个 tick 落盘（已记录 \(recorded) 个）——advance 后 tick 未发生",
                    timeout: timeout
                )
            }
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 200_000)
        }
    }

    var recorded: [Duration] {
        lock.withLock { times }
    }
}

/// 工单 02：刷新三档 Realtime / Balanced（默认）/ Low Resource + 空闲退避。
/// 独立事实来源：spec §1——活动期 ~5s、空闲退到 ~30s。
/// @MainActor（工单：间歇性死锁）：非 MainActor 的 async 测试任务跑在协作池上；
/// 实测（40+ 轮 sample 抓栈）在全套件快速推进、池线程批量退休后，下一个池任务
/// （测试任务）的唤醒会概率性丢失 → 测试永挂（xctest 孤儿 0% CPU，主线程停在
/// XCTWaiter）。MainActor 测试任务由 XCTest 主线程 runloop 泵驱动，不依赖池，
/// 对照实验 150 轮 0 挂（同代码不标注：13/255 挂）。本类不触 UI，锚到主 actor 无副作用。
@MainActor
final class RefreshSchedulerTests: XCTestCase {
    private let clock = ManualClock()
    private var recorder: TickRecorder!
    private var scheduler: RefreshScheduler!

    override func setUp() {
        super.setUp()
        recorder = TickRecorder()
        scheduler = RefreshScheduler(
            mode: .balanced, clock: clock, idleThreshold: .seconds(30)
        ) { [recorder] time in
            recorder.record(at: time)
        }
        scheduler.start()
    }

    override func tearDown() {
        scheduler.stop()
        super.tearDown()
    }

    /// 等循环把下一轮 sleep 挂上（此后它睡到被 advance 唤醒，状态稳定）。
    /// 有界：循环已死（被 stop 取消）时秒级失败，不再无限挂起。
    private func armNextTick() async throws {
        try await clock.waitForSleepRegistration()
    }

    /// 拨到指定时刻并等这个 tick 真正记完（调用前必须先 armNextTick）。
    private func fireTick(at time: Duration, tick number: Int) async throws {
        clock.advance(to: time)
        try await recorder.waitForCount(number)
    }

    func test三档模式的间隔符合规格() {
        // spec §1 锚点：活动期 ~5s、空闲退到 ~30s；Realtime 不退避；Low Resource 更省。
        XCTAssertEqual(RefreshMode.defaultMode, .balanced)
        XCTAssertEqual(RefreshMode.realtime.activeInterval, .seconds(5))
        XCTAssertEqual(RefreshMode.realtime.idleInterval, .seconds(5), "Realtime 空闲也不退避")
        XCTAssertEqual(RefreshMode.balanced.activeInterval, .seconds(5))
        XCTAssertEqual(RefreshMode.balanced.idleInterval, .seconds(30))
        XCTAssertEqual(RefreshMode.lowResource.activeInterval, .seconds(30))
        XCTAssertEqual(RefreshMode.lowResource.idleInterval, .seconds(120))
    }

    func testBalanced活动期按5秒间隔刷新() async throws {
        try await armNextTick()
        try await fireTick(at: .seconds(5), tick: 1)
        try await armNextTick()
        try await fireTick(at: .seconds(10), tick: 2)
        try await armNextTick()
        try await fireTick(at: .seconds(15), tick: 3)

        XCTAssertEqual(recorder.recorded, [.seconds(5), .seconds(10), .seconds(15)])
    }

    func test空闲超过阈值后退避到30秒() async throws {
        // 前 6 轮都在 30s 阈值内 → 5s 一跳；空闲满 30s 后 → 30s 一跳。
        for (index, time) in [5, 10, 15, 20, 25, 30].enumerated() {
            try await armNextTick()
            try await fireTick(at: .seconds(time), tick: index + 1)
        }
        try await armNextTick()
        try await fireTick(at: .seconds(60), tick: 7)
        try await armNextTick()
        try await fireTick(at: .seconds(90), tick: 8)

        XCTAssertEqual(
            recorder.recorded,
            [.seconds(5), .seconds(10), .seconds(15), .seconds(20), .seconds(25), .seconds(30), .seconds(60), .seconds(90)]
        )
    }

    func testrecordActivity重置空闲退避() async throws {
        try await armNextTick()
        try await fireTick(at: .seconds(5), tick: 1)
        try await armNextTick()
        try await fireTick(at: .seconds(10), tick: 2)
        try await armNextTick()
        try await fireTick(at: .seconds(15), tick: 3)

        // 第 4 轮 sleep 已挂上（armNextTick 保证，截止 20s）；
        // 先空拨到 19s 记录一次活动，再越过分界。
        clock.advance(to: .seconds(19))
        scheduler.recordActivity()

        try await armNextTick()
        try await fireTick(at: .seconds(20), tick: 4)
        try await armNextTick()
        try await fireTick(at: .seconds(25), tick: 5)
        try await armNextTick()
        try await fireTick(at: .seconds(30), tick: 6)
        try await armNextTick()
        try await fireTick(at: .seconds(35), tick: 7)
        try await armNextTick()
        try await fireTick(at: .seconds(40), tick: 8)
        try await armNextTick()
        try await fireTick(at: .seconds(45), tick: 9)
        try await armNextTick()
        try await fireTick(at: .seconds(50), tick: 10)
        // 19s 之后 30s 无活动（t=49 起超阈值）→ 退避 30s。
        try await armNextTick()
        try await fireTick(at: .seconds(80), tick: 11)

        XCTAssertEqual(
            recorder.recorded,
            [.seconds(5), .seconds(10), .seconds(15), .seconds(20), .seconds(25), .seconds(30), .seconds(35), .seconds(40), .seconds(45), .seconds(50), .seconds(80)]
        )
    }

    func testsetMode影响下一轮间隔() async throws {
        try await armNextTick()
        try await fireTick(at: .seconds(5), tick: 1)
        // 循环已用旧档（Balanced）挂上第 2 轮 sleep（上面的 armNextTick），切换对在途轮次不生效。
        scheduler.setMode(.lowResource)

        // 第 2 轮（在途）仍按旧档 5s 触发；第 3 轮起用 Low Resource 活动档 30s。
        try await fireTick(at: .seconds(10), tick: 2)
        try await armNextTick()
        try await fireTick(at: .seconds(40), tick: 3)

        XCTAssertEqual(
            recorder.recorded,
            [.seconds(5), .seconds(10), .seconds(40)],
            "切换模式对在途轮次不生效，下一轮起改用新档间隔"
        )
    }

    func teststop后不再刷新() async throws {
        try await armNextTick()
        try await fireTick(at: .seconds(5), tick: 1)
        scheduler.stop()
        clock.advance(to: .seconds(500))
        // 给取消留出落定时间（毫秒级真实等待，不参与调度语义）。
        try? await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(to: .seconds(600))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recorder.recorded, [.seconds(5)], "stop 后虚拟时间再推进也不该有新 tick")
    }

    func teststart幂等不重复刷() async throws {
        scheduler.start()
        scheduler.start()

        try await armNextTick()
        try await fireTick(at: .seconds(5), tick: 1)
        try await armNextTick()
        try await fireTick(at: .seconds(10), tick: 2)

        XCTAssertEqual(recorder.recorded, [.seconds(5), .seconds(10)])
    }
}

/// ManualClock 自身协议的回归测试（工单：全量测试间歇性死锁）。
/// 两个确定性用例分别锁死曾经的"永等"与"丢唤醒"窗口：
/// 等待方等一个永远不会来的事件时，必须秒级失败并说明在等什么，不得无限挂起。
/// @MainActor：同 RefreshSchedulerTests——async 测试任务不依赖协作池（池退休丢唤醒）。
@MainActor
final class ManualClockTests: XCTestCase {
    /// 窗口一（工单现场）：调度循环被 stop 取消在首次注册之前时，注册永远不会来。
    /// 旧实现 waiter 入队后永不被唤醒 → 测试任务永挂 → xctest 孤儿进程 0% CPU。
    /// 新契约：有界等待，秒级抛 `TestWaitTimeout`。
    func test等待注册有界_注册永不来时秒级超时() async {
        let clock = ManualClock()   // 不启动任何调度器：无人注册 sleep
        let started = Date()
        do {
            try await clock.waitForSleepRegistration(timeout: 0.5)
            XCTFail("没有任何调度器在注册 sleep，不该等到来")
        } catch {
            XCTAssertTrue(error is TestWaitTimeout, "超时应抛带说明的 TestWaitTimeout，实际：\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "必须秒级失败，而不是挂起")
    }

    /// 窗口二（丢唤醒）：deadline 计算后、挂载前，advance 把时钟拨过截止点。
    /// 旧实现：sleeper 以"已到期"状态挂入却无人再唤醒 → 调度循环永睡。
    /// 新契约：挂载点发现已到期，当场醒来（注册即到期即刻醒），注册计数不丢。
    func test注册时deadline已被advance越过则立即醒来() async throws {
        let clock = ManualClock()
        let woke = WakeBox()
        clock.registrationGate = { clock.advance(to: .seconds(100)) }
        let sleeper = Task { try await clock.sleep(for: .seconds(1)); woke.mark() }
        defer {
            clock.registrationGate = nil
            sleeper.cancel()   // 收尾：无论断言成败都取消挂着的 sleeper，不留悬挂任务
        }

        let deadline = Date().addingTimeInterval(2)
        while !woke.value && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        clock.registrationGate = nil
        XCTAssertTrue(woke.value, "注册时 deadline 已被 advance 越过的 sleep 必须立即醒来（旧实现永睡=丢唤醒）")
        // 注册计数不丢：这次"到期即醒"的挂载仍被计为一次注册（arm-then-advance 对齐）。
        try await clock.waitForSleepRegistration(timeout: 1)
    }

    private final class WakeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var woken = false
        var value: Bool { lock.withLock { woken } }
        func mark() { lock.withLock { woken = true } }
    }
}
