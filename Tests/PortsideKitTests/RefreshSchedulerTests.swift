import XCTest
@testable import PortsideKit

/// 可注入的虚拟时钟：测试不真睡（工单 02：定时器用注入时钟，可测）。
/// - `sleep(for:)` 挂起直到 `advance(to:)` 越过截止时间，或任务被取消。
/// - `waitForSleepRegistration()` 等到被调度方真的挂到下一次 sleep 上
///   （注册计数在挂进队列那一刻增加，粘性，观察者晚到也不错过）。
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
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []

    func now() -> Duration {
        lock.withLock { virtualNow }
    }

    func sleep(for duration: Duration) async throws {
        let request = SleepRequest(deadline: now() + duration)

        try await withTaskCancellationHandler {
            try await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // body 同步执行：挂 sleeper、计数、唤醒观察者必须都发生在挂起之前，
                // 否则 advance(to:) 找不到 sleeper、观察者永远等不到。
                let state = self.lock.withLock { () -> (resumeSleeper: Bool, waiter: CheckedContinuation<Void, Never>?) in
                    if request.cancelled {
                        return (true, nil)
                    }
                    request.continuation = continuation
                    self.sleepers.append(request)
                    self.pendingRegistrations += 1
                    return (false, self.registrationWaiters.popLast())
                }
                state.waiter?.resume()
                if state.resumeSleeper { continuation.resume() }
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
    func waitForSleepRegistration() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = self.lock.withLock {
                if self.pendingRegistrations > 0 {
                    self.pendingRegistrations -= 1
                    return true
                }
                self.registrationWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
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
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(at time: Duration) {
        lock.withLock {
            times.append(time)
            waiters = waiters.filter { waiter in
                if times.count >= waiter.count {
                    waiter.continuation.resume()
                    return false
                }
                return true
            }
        }
    }

    func waitForCount(_ count: Int) async {
        let alreadyThere: Bool = lock.withLock { times.count >= count }
        if alreadyThere { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = self.lock.withLock {
                if times.count >= count {
                    return true
                }
                waiters.append((count, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var recorded: [Duration] {
        lock.withLock { times }
    }
}

/// 工单 02：刷新三档 Realtime / Balanced（默认）/ Low Resource + 空闲退避。
/// 独立事实来源：spec §1——活动期 ~5s、空闲退到 ~30s。
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
    private func armNextTick() async {
        await clock.waitForSleepRegistration()
    }

    /// 拨到指定时刻并等这个 tick 真正记完（调用前必须先 armNextTick）。
    private func fireTick(at time: Duration, tick number: Int) async {
        clock.advance(to: time)
        await recorder.waitForCount(number)
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

    func testBalanced活动期按5秒间隔刷新() async {
        await armNextTick()
        await fireTick(at: .seconds(5), tick: 1)
        await armNextTick()
        await fireTick(at: .seconds(10), tick: 2)
        await armNextTick()
        await fireTick(at: .seconds(15), tick: 3)

        XCTAssertEqual(recorder.recorded, [.seconds(5), .seconds(10), .seconds(15)])
    }

    func test空闲超过阈值后退避到30秒() async {
        // 前 6 轮都在 30s 阈值内 → 5s 一跳；空闲满 30s 后 → 30s 一跳。
        for (index, time) in [5, 10, 15, 20, 25, 30].enumerated() {
            await armNextTick()
            await fireTick(at: .seconds(time), tick: index + 1)
        }
        await armNextTick()
        await fireTick(at: .seconds(60), tick: 7)
        await armNextTick()
        await fireTick(at: .seconds(90), tick: 8)

        XCTAssertEqual(
            recorder.recorded,
            [.seconds(5), .seconds(10), .seconds(15), .seconds(20), .seconds(25), .seconds(30), .seconds(60), .seconds(90)]
        )
    }

    func testrecordActivity重置空闲退避() async {
        await armNextTick()
        await fireTick(at: .seconds(5), tick: 1)
        await armNextTick()
        await fireTick(at: .seconds(10), tick: 2)
        await armNextTick()
        await fireTick(at: .seconds(15), tick: 3)

        // 第 4 轮 sleep 已挂上（armNextTick 保证，截止 20s）；
        // 先空拨到 19s 记录一次活动，再越过分界。
        clock.advance(to: .seconds(19))
        scheduler.recordActivity()

        await armNextTick()
        await fireTick(at: .seconds(20), tick: 4)
        await armNextTick()
        await fireTick(at: .seconds(25), tick: 5)
        await armNextTick()
        await fireTick(at: .seconds(30), tick: 6)
        await armNextTick()
        await fireTick(at: .seconds(35), tick: 7)
        await armNextTick()
        await fireTick(at: .seconds(40), tick: 8)
        await armNextTick()
        await fireTick(at: .seconds(45), tick: 9)
        await armNextTick()
        await fireTick(at: .seconds(50), tick: 10)
        // 19s 之后 30s 无活动（t=49 起超阈值）→ 退避 30s。
        await armNextTick()
        await fireTick(at: .seconds(80), tick: 11)

        XCTAssertEqual(
            recorder.recorded,
            [.seconds(5), .seconds(10), .seconds(15), .seconds(20), .seconds(25), .seconds(30), .seconds(35), .seconds(40), .seconds(45), .seconds(50), .seconds(80)]
        )
    }

    func testsetMode影响下一轮间隔() async {
        await armNextTick()
        await fireTick(at: .seconds(5), tick: 1)
        // 循环已用旧档（Balanced）挂上第 2 轮 sleep（上面的 armNextTick），切换对在途轮次不生效。
        scheduler.setMode(.lowResource)

        // 第 2 轮（在途）仍按旧档 5s 触发；第 3 轮起用 Low Resource 活动档 30s。
        await fireTick(at: .seconds(10), tick: 2)
        await armNextTick()
        await fireTick(at: .seconds(40), tick: 3)

        XCTAssertEqual(
            recorder.recorded,
            [.seconds(5), .seconds(10), .seconds(40)],
            "切换模式对在途轮次不生效，下一轮起改用新档间隔"
        )
    }

    func teststop后不再刷新() async {
        await armNextTick()
        await fireTick(at: .seconds(5), tick: 1)
        scheduler.stop()
        clock.advance(to: .seconds(500))
        // 给取消留出落定时间（毫秒级真实等待，不参与调度语义）。
        try? await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(to: .seconds(600))
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(recorder.recorded, [.seconds(5)], "stop 后虚拟时间再推进也不该有新 tick")
    }

    func teststart幂等不重复刷() async {
        scheduler.start()
        scheduler.start()

        await armNextTick()
        await fireTick(at: .seconds(5), tick: 1)
        await armNextTick()
        await fireTick(at: .seconds(10), tick: 2)

        XCTAssertEqual(recorder.recorded, [.seconds(5), .seconds(10)])
    }
}
