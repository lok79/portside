import Foundation
import Darwin

/// 探活结论（GLOSSARY：健康探测——轻量短超时，不做重探测）三态如实区分：
/// - `listening`：TCP connect 成功 = 存活（确定性）。
/// - `refused`：连接拒绝 = 端口无监听者，服务挂了（确定性）。
/// - `noResponse`：超时/不可达 = 无响应——**探测失败 ≠ 服务挂**，不据此翻状态。
public enum PortProbeOutcome: Equatable, Sendable {
    case listening
    case refused
    case noResponse
}

/// 探测边界（GLOSSARY：健康探测）：端口 → 探活结论。测试注入假实现。
public protocol PortProbing: Sendable {
    func probe(port: Int) async -> PortProbeOutcome
}

/// 真实短超时 TCP connect 探测（spec §7「短超时 TCP 探活」）：
/// 非阻塞 connect + poll（超时默认 ~0.8s，spec 口径），零常驻连接、零第三方依赖。
/// IPv4（127.0.0.1）与 IPv6（::1）各试一次（dev server 常只绑单栈）：
/// 任一连通 = listening；两栈都拒绝 = refused（确定性挂）；其余（超时/不可达）= noResponse。
public struct TCPConnectProber: PortProbing {
    public let timeout: Duration

    public init(timeout: Duration) {
        self.timeout = timeout
    }

    public func probe(port: Int) async -> PortProbeOutcome {
        let timeoutMs = Int32(clamping: timeout.components.seconds * 1000
            + timeout.components.attoseconds / 1_000_000_000_000_000)
        let v4 = await Self.connectOffMain(family: AF_INET, address: "127.0.0.1", port: port, timeoutMs: timeoutMs)
        if v4 == .listening { return .listening }
        let v6 = await Self.connectOffMain(family: AF_INET6, address: "::1", port: port, timeoutMs: timeoutMs)
        if v6 == .listening { return .listening }
        return v4 == .refused && v6 == .refused ? .refused : .noResponse
    }

    /// 阻塞式 connect/poll 放到协作池之外（utility 队列），不占 Swift 并发线程。
    private static func connectOffMain(
        family: Int32, address: String, port: Int, timeoutMs: Int32
    ) async -> PortProbeOutcome {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: connectBlocking(
                    family: family, address: address, port: port, timeoutMs: timeoutMs
                ))
            }
        }
    }

    /// 非阻塞 connect + poll（POLLOUT）+ SO_ERROR：短超时由我们控制，不挂死。
    private static func connectBlocking(
        family: Int32, address: String, port: Int, timeoutMs: Int32
    ) -> PortProbeOutcome {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return .noResponse }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return .noResponse }

        var rc: Int32 = -1
        switch family {
        case AF_INET:
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return .noResponse }
            rc = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case AF_INET6:
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(port).bigEndian
            guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { return .noResponse }
            rc = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        default:
            return .noResponse
        }

        if rc == 0 { return .listening }
        guard errno == EINPROGRESS else {
            return errno == ECONNREFUSED ? .refused : .noResponse
        }
        var pollSet = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollSet, 1, timeoutMs) > 0 else { return .noResponse }   // 超时/中断 = 无响应
        var soError: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &size) == 0 else { return .noResponse }
        switch soError {
        case 0: return .listening
        case ECONNREFUSED: return .refused
        default: return .noResponse
        }
    }
}

/// 周期探活器（评审修复 F2，spec 验收 #2）：对**已知定义端口**独立 5s 节奏做短超时
/// TCP connect 探测，结果喂 PanelViewModel（行状态 + 菜单栏汇总态）——
/// 面板关闭（扫描空闲退避 30s 档）时 kill -9 已知服务，图标 ≤10s 变色。
/// - 只探已知定义端口（低资源红线：未识别端口不探）；无定义端口时探活轮空转、零连接。
/// - 与扫描调度解耦：自带 RefreshScheduler（realtime 恒 5s，注入时钟与扫描共用），
///   上一轮未落定跳过本轮（在途闸，低资源纪律与 PanelViewModel 扫描同款）。
public final class PortProbe: @unchecked Sendable {
    /// 探测节奏（独立于扫描档位：spec 验收 #2 的 10 秒线由 5s 节奏 + ~0.8s 超时保证）。
    public static let probeInterval = Duration.seconds(5)
    /// 单端口 connect 超时（spec §7 短超时口径）。
    public static let connectTimeout = Duration.milliseconds(800)

    private let ports: @Sendable () -> [Int]
    private let prober: PortProbing
    private let clock: PortsideClock
    private let onOutcome: @Sendable (Int, PortProbeOutcome) -> Void

    private let lock = NSLock()
    private var probing = false
    /// lazy：创建时才捕获 self（初始化完成后），避免 init 两阶段限制。
    private lazy var scheduler = RefreshScheduler(
        mode: .realtime, clock: clock, idleThreshold: Self.probeInterval
    ) { [weak self] _ in
        Task { [weak self] in await self?.probeRound() }
    }

    /// - Parameters:
    ///   - ports: 当前应探测的端口清单（生产 = 已知定义端口；每轮现取，收编后自动生效）。
    ///   - prober: 探测边界（生产 = TCPConnectProber；测试注入假实现）。
    ///   - clock: 时钟（与扫描调度共用注入时钟，测试虚拟时间驱动）。
    ///   - onOutcome: 每端口结论回执（任意线程到达；消费方自行落主 actor）。
    public init(
        ports: @escaping @Sendable () -> [Int],
        prober: PortProbing,
        clock: PortsideClock,
        onOutcome: @escaping @Sendable (Int, PortProbeOutcome) -> Void
    ) {
        self.ports = ports
        self.prober = prober
        self.clock = clock
        self.onOutcome = onOutcome
    }

    /// 开始周期探测；重复调用无副作用。
    public func start() {
        scheduler.start()
    }

    /// 停止；探测不再触发。
    public func stop() {
        scheduler.stop()
    }

    /// 一轮探测：在途闸 → 现取端口清单（空清单零连接）→ 并发探测、结论逐个送达。
    private func probeRound() async {
        let acquired: Bool = lock.withLock {
            if probing { return false }
            probing = true
            return true
        }
        guard acquired else { return }
        defer { lock.withLock { probing = false } }

        let targets = ports()
        guard !targets.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for port in targets {
                group.addTask { [prober, onOutcome] in
                    let outcome = await prober.probe(port: port)
                    onOutcome(port, outcome)
                }
            }
            await group.waitForAll()
        }
    }
}
