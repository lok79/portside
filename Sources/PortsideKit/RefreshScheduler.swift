import Foundation

/// 刷新三档（spec §1：刷新模式三档可配——Realtime / Balanced（默认）/ Low Resource）。
/// 间隔锚点来自 spec §1：活动期 ~5s、空闲退到 ~30s；Realtime 不退避；
/// Low Resource 把两档都拉大（实现取舍拿不准时以占用为先，见 portside/AGENTS.md）。
public enum RefreshMode: String, CaseIterable, Sendable {
    case realtime
    case balanced
    case lowResource

    /// 默认档（spec §1：Balanced 默认）。
    public static let defaultMode: RefreshMode = .balanced

    /// 活动期扫描间隔。
    public var activeInterval: Duration {
        switch self {
        case .realtime: return .seconds(5)
        case .balanced: return .seconds(5)
        case .lowResource: return .seconds(30)
        }
    }

    /// 空闲退避后的扫描间隔。
    public var idleInterval: Duration {
        switch self {
        case .realtime: return .seconds(5)
        case .balanced: return .seconds(30)
        case .lowResource: return .seconds(120)
        }
    }
}

/// 时钟抽象：调度只经此感知时间与挂起，测试注入虚拟时钟，测试不真睡。
public protocol PortsideClock: Sendable {
    /// 当前时刻（自任意纪元的时长；只用于比较与运算）。
    func now() -> Duration
    /// 挂起 duration；任务被取消时抛 `CancellationError`。
    func sleep(for duration: Duration) async throws
}

/// 生产时钟：ContinuousClock（单调，不受用户改系统时间影响）。
public struct SystemClock: PortsideClock {
    private let clock = ContinuousClock()
    /// 任取的纪元锚点：now() 只用于时长比较，绝对值无意义。
    private let epoch: ContinuousClock.Instant = .now

    public init() {}

    public func now() -> Duration {
        epoch.duration(to: clock.now)
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

/// 刷新调度器：周期发 tick，活动期快、空闲退避（GLOSSARY：扫描器——退避策略避免死轮询）。
/// - 间隔由刷新档位与"距上次活动是否超过 idleThreshold"决定。
/// - "活动"由上层显式 `recordActivity()`（面板打开/用户操作等），引擎不替 UI 猜。
/// - 线程安全：可从任意线程启停/记录活动/切档；tick 回调串行触发。
public final class RefreshScheduler: @unchecked Sendable {
    private let clock: PortsideClock
    private let idleThreshold: Duration
    private let onTick: @Sendable (Duration) -> Void

    private let lock = NSLock()
    private var mode: RefreshMode
    private var lastActivity: Duration = .zero
    private var task: Task<Void, Never>?
    private var running = false

    public init(
        mode: RefreshMode,
        clock: PortsideClock,
        idleThreshold: Duration = .seconds(120),
        onTick: @escaping @Sendable (Duration) -> Void
    ) {
        self.mode = mode
        self.clock = clock
        self.idleThreshold = idleThreshold
        self.onTick = onTick
    }

    /// 开始调度；重复调用无副作用。
    public func start() {
        let now = clock.now()
        lock.withLock {
            guard !running else { return }
            running = true
            lastActivity = now
            task = Task { [weak self] in
                await self?.runLoop()
            }
        }
    }

    /// 停止调度；tick 不再触发。
    public func stop() {
        let stopped: Task<Void, Never>? = lock.withLock {
            running = false
            defer { task = nil }
            return task
        }
        stopped?.cancel()
    }

    /// 记录一次用户活动：空闲退避计时归零。
    public func recordActivity() {
        let now = clock.now()
        lock.withLock { lastActivity = now }
    }

    /// 切换刷新档位；对已在途的一轮不生效，下一轮起用新档。
    public func setMode(_ newMode: RefreshMode) {
        lock.withLock { mode = newMode }
    }

    private func runLoop() async {
        // 每个 tick 记录它对应的调度截止点（planned 单调累加）：观察者看到的
        // tick 节奏与档位/退避的数学严格一致，不受任务苏醒抖动影响。
        var planned = clock.now()
        while !Task.isCancelled {
            let interval = currentInterval(at: clock.now())
            planned += interval
            do {
                try await clock.sleep(for: interval)
            } catch {
                break // 取消即退出，不留残余任务
            }
            onTick(planned)
        }
    }

    private func currentInterval(at time: Duration) -> Duration {
        let (currentMode, lastActivity, idleThreshold) = lock.withLock {
            (mode, lastActivity, idleThreshold)
        }
        let idleFor = time - lastActivity
        return idleFor >= idleThreshold ? currentMode.idleInterval : currentMode.activeInterval
    }
}
