import Foundation
import Darwin

/// 启动失败原因（工单 06：错误写进行内状态，app 不崩）。
/// 秒退错误携带落盘日志末尾——用户不打开日志文件也能看懂为什么没起来。
public enum ProcessStartError: Error, Equatable {
    /// 登录 shell 不可用（$SHELL 不存在等）。
    case shellUnavailable(String)
    /// 日志文件打不开（目录不可写等）。
    case logUnavailable(String)
    /// posix_spawn 失败（负 errno + 描述）。
    case spawnFailed(Int32, String)
    /// 进程在启动判定窗内退出（秒退/命令不存在）。带退出码与落盘日志末尾。
    case exitedImmediately(exitCode: Int32?, logTail: String)

    /// 行内展示文案（GLOSSARY：面板——错误信息可见，不装死）。
    public var userMessage: String {
        switch self {
        case .shellUnavailable(let detail):
            return "启动失败：登录 shell 不可用（\(detail)）"
        case .logUnavailable(let detail):
            return "启动失败：日志文件无法创建（\(detail)）"
        case .spawnFailed(let errno, let detail):
            return "启动失败：进程创建出错（errno=\(errno)，\(detail)）"
        case .exitedImmediately(let code, let tail):
            var message = "启动失败：进程立即退出"
            if let code { message += "（退出码 \(code)）" }
            let trimmedTail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTail.isEmpty { message += "。日志末尾：\(trimmedTail)" }
            return message
        }
    }
}

/// 停止被拒原因（评审修复 F3：端口兜底停止的宁漏杀不误杀安全阀）。
public enum ProcessStopError: Error, Equatable {
    /// 端口当前占用者与定义启动命令不匹配（或命令行无从校验）——一个信号都不发。
    case occupierMismatch(pid: pid_t, processName: String)

    /// 行内展示文案（GLOSSARY：面板——错误信息可见，不装死）。
    public var userMessage: String {
        switch self {
        case .occupierMismatch(let pid, let name):
            return "端口已被 \(pid)（\(name)）占用，未停止"
        }
    }
}

/// 托管服务生命周期真实现（工单 06，GLOSSARY：托管服务——启动/停止/重启全量可用）。
/// - **启动**：经用户登录 shell（`$SHELL -l -c "<命令>"`，继承 nvm 等 profile 环境）；
///   POSIX `posix_spawn` + `POSIX_SPAWN_SETPGROUP` 建独立进程组（新组领袖 = 子进程，
///   `kill -pgid` 不会波及 Portside 自身）。
///   取舍：macOS 不自带 `setsid`（coreutils 才有，违反零依赖）；Foundation `Process`
///   没有 setpgid 挂钩，子进程会留在 app 自己的进程组——对整组发信号等于自杀；
///   `sh -c 'exec …'` 只做替换不做建组，同样不满足。posix_spawn 建组在内核侧原子完成，无竞态。
/// - **落盘通道**（GLOSSARY：落盘通道/adr/0001）：stdout/stderr 经 spawn file actions 直写
///   日志文件，句柄由**子进程**持有——Portside 死了日志继续写，生命周期解耦；stdin 接 /dev/null。
/// - **停止**：对整组（`kill -pgid`）先 SIGTERM，宽限期（注入时钟，不忙等）后仍有存活则
///   SIGKILL 补刀——Java fork 子进程的场景整组全灭。
/// - **退出感知**：后台 reaper 阻塞 `waitpid`（恰好一次收尸，防僵尸；无轮询）；
///   启动判定窗 = 单次注入时钟挂起与退出信号竞速。
/// - 注册表是**内存态**（pid/pgid）；Portside 重开后按定义认领归工单 08（adr/0001）。
public final class ShellProcessController: ProcessController, @unchecked Sendable {
    /// 一个已启动服务的追踪条目（waiters/exitStatus 归条目锁管，reaper 不反查 controller）。
    private final class ProcessEntry {
        let pid: pid_t
        /// 进程组 id（= 领袖 pid：SETPGROUP 且 pgroup=0 时子进程即新组领袖；
        /// 认领条目 = 实例所在组的 id，getpgid 现取）。
        let pgid: pid_t
        /// true = 认领的受管外部实例（工单 08）：非本 app 亲生——**不起 waitpid reaper**
        /// （收尸权不在本进程，waitpid 必 ECHILD），退出感知走有界存活探询。
        let isReclaimed: Bool
        /// 条目自身锁：reaper（任意队列线程）与 controller（任意 actor）都要碰。
        private let stateLock = NSLock()
        private var exitStatus: Int32?
        private var waiters: [ExitWaiter] = []

        init(pid: pid_t, pgid: pid_t, isReclaimed: Bool = false) {
            self.pid = pid
            self.pgid = pgid
            self.isReclaimed = isReclaimed
        }

        /// 记录退出并唤醒全部等待者（reaper 收尸后恰好调用一次）。
        func markExited(_ status: Int32?) {
            let waiters: [ExitWaiter] = stateLock.withLock {
                exitStatus = status ?? 0
                let pending = waiters
                waiters = []
                return pending
            }
            waiters.forEach { $0.resume() }
        }

        /// 读取退出状态（nil = 还没退）。
        func currentExitStatus() -> Int32? {
            stateLock.withLock { exitStatus }
        }

        /// 挂上等待者；返回 false = 已退出/任务已取消（先取消后注册的竞速），
        /// 调用方应立即恢复 continuation。cancelled 读写都在条目锁内，无数据竞速。
        func appendWaiter(_ waiter: ExitWaiter, continuation: CheckedContinuation<Void, Never>) -> Bool {
            stateLock.withLock {
                if exitStatus != nil || waiter.cancelled { return false }
                waiter.continuation = continuation
                waiters.append(waiter)
                return true
            }
        }

        /// 摘除等待者（取消路径）：标记取消并返回待恢复的 continuation（不在名单则 nil）。
        func detachWaiter(_ waiter: ExitWaiter) -> CheckedContinuation<Void, Never>? {
            stateLock.withLock {
                waiter.cancelled = true
                guard let index = waiters.firstIndex(where: { $0 === waiter }) else { return nil }
                let removed = waiters.remove(at: index)
                return removed.continuation
            }
        }
    }

    /// awaitExit 的等待者盒子（continuation 槽位 + 取消标记；仅在条目锁内读写标记）。
    private final class ExitWaiter {
        var continuation: CheckedContinuation<Void, Never>?
        var cancelled = false

        /// 恢复且只恢复一次（幂等：resume 后槽位清空）。
        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// 宽限期默认 8 秒（工单：SIGTERM → 8s → SIGKILL）。
    public static let defaultGracePeriod = Duration.seconds(8)
    /// 启动判定窗默认 2 秒：窗内退出视为启动失败（秒退）。
    public static let defaultStartupWindow = Duration.seconds(2)
    /// SIGKILL 后等待内核收尾的上限。
    public static let defaultKillTimeout = Duration.seconds(2)
    /// 认领实例的存活探询间隔（仅停止/重启竞速期间运行；无空闲开销）。
    public static let reclaimedExitPollInterval = Duration.milliseconds(100)

    /// 生产默认日志目录：`~/Library/Application Support/Portside/logs/`。
    public static func defaultLogsDirectory() -> URL {
        DefinitionStore.defaultDirectory().appendingPathComponent("logs", isDirectory: true)
    }

    private let shellPath: String
    private let logsDirectory: URL
    private let gracePeriod: Duration
    private let startupWindow: Duration
    private let killTimeout: Duration
    private let clock: PortsideClock
    /// 端口兜底停止的外部工具边界（lsof 找占用 pid）；nil = 无兜底。
    private let runner: ProcessRunner?
    private let environment: [String: String]?

    private let lock = NSLock()
    private var entries: [String: ProcessEntry] = [:]

    /// - Parameters:
    ///   - shellPath: 登录 shell 路径；nil = `$SHELL`，再退 `/bin/zsh`（注入可测）。
    ///   - logsDirectory: 落盘日志目录（注入；测试走临时目录）。
    ///   - gracePeriod: SIGTERM 后的宽限期（注入时钟挂起，无忙等）。
    ///   - startupWindow: 启动判定窗；窗内退出 = 启动失败（秒退）。
    ///   - killTimeout: SIGKILL 后等待收尾上限。
    ///   - clock: 时钟（注入；测试用虚拟时钟）。
    ///   - runner: 端口兜底停止的进程工具边界；nil = 不做兜底（测试可关）。
    ///   - environment: 传给子进程的环境；nil = 继承当前进程环境（测试可注入定制环境）。
    public init(
        shellPath: String? = nil,
        logsDirectory: URL,
        gracePeriod: Duration = ShellProcessController.defaultGracePeriod,
        startupWindow: Duration = ShellProcessController.defaultStartupWindow,
        killTimeout: Duration = ShellProcessController.defaultKillTimeout,
        clock: PortsideClock = SystemClock(),
        runner: ProcessRunner? = SystemProcessRunner(),
        environment: [String: String]? = nil
    ) {
        self.shellPath = shellPath
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        self.logsDirectory = logsDirectory
        self.gracePeriod = gracePeriod
        self.startupWindow = startupWindow
        self.killTimeout = killTimeout
        self.clock = clock
        self.runner = runner
        self.environment = environment
    }

    // MARK: - 查询（运行中状态来源：启动后记录 pid/pgid；面板就绪与否仍以扫描为准）

    /// 定义是否处于被追踪的运行态（退出已被 reaper 记录则 false；无条目 = 未启动）。
    public func isRunning(definitionID: String) -> Bool {
        lock.withLock {
            guard let entry = entries[definitionID] else { return false }
            return entry.currentExitStatus() == nil
        }
    }

    /// 被追踪服务的进程 id（领袖）；未追踪/已退出为 nil。
    public func runningProcessID(definitionID: String) -> pid_t? {
        lock.withLock {
            guard let entry = entries[definitionID], entry.currentExitStatus() == nil else { return nil }
            return entry.pid
        }
    }

    /// 被追踪服务的进程组 id；未追踪/已退出为 nil。
    public func runningProcessGroupID(definitionID: String) -> pid_t? {
        lock.withLock {
            guard let entry = entries[definitionID], entry.currentExitStatus() == nil else { return nil }
            return entry.pgid
        }
    }

    /// 落盘日志文件路径（`<logsDirectory>/<定义id>.log`；定义 id 跨改名稳定）。
    public func logFileURL(definitionID: String) -> URL {
        logsDirectory.appendingPathComponent("\(definitionID).log")
    }

    /// 认领登记（工单 08，GLOSSARY：认领；adr/0001）：把按服务定义（端口 + 启动命令）
    /// 匹配到的运行中实例纳回运行态追踪——**受管外部实例**。登记后停止/重启按整组信号
    /// 生效；重启经亲生路径重起，回到「自己起的」状态。
    /// - **非亲生**：不起 waitpid reaper（收尸权不在本进程，孤儿归 launchd 接管），
    ///   退出感知走有界存活探询（仅停止/重启的宽限竞速期间运行，无空闲开销）。
    /// - 幂等与不覆盖事实（「宁漏认不误认」的对偶——不覆盖追踪事实）：
    ///   同 pid 已在追 → 无操作返回 true（亲生/认领身份都保留）；
    ///   该定义已有**存活**的其他 pid 条目 → 拒绝登记返回 false（宁可漏认）；
    ///   旧条目已退出（实例换代）→ 替换为认领条目。
    /// - Returns: false = 未能登记（实例已退出 / 与在追条目冲突）。
    @discardableResult
    public func reclaim(definitionID: String, pid: pid_t) -> Bool {
        guard pid > 0, let pgid = Self.processGroupID(of: pid) else { return false }
        return lock.withLock {
            if let existing = entries[definitionID] {
                guard existing.currentExitStatus() != nil else {
                    // 存活条目：同 pid 幂等（身份保留），异 pid 冲突拒绝（不误认）。
                    return existing.pid == pid
                }
                // 旧条目已退出：实例换代，替换。
            }
            entries[definitionID] = ProcessEntry(pid: pid, pgid: pgid, isReclaimed: true)
            return true
        }
    }

    /// 该定义当前是否为认领的受管外部实例（亲生进程为 false；工单 08 日志视图据此
    /// 决定是否落「认领实例但输出未接管」的发现链兜底形态）。
    public func isReclaimedInstance(definitionID: String) -> Bool {
        lock.withLock {
            guard let entry = entries[definitionID] else { return false }
            return entry.isReclaimed && entry.currentExitStatus() == nil
        }
    }

    /// 进程组 id（pid 无效/已退出返回 nil）。
    private static func processGroupID(of pid: pid_t) -> pid_t? {
        let pgid = getpgid(pid)
        return pgid > 0 ? pgid : nil
    }

    /// 摘除一个追踪条目（按实例身份，非按 id——换代场景 id 相同条目已换）。
    private func removeEntry(_ entry: ProcessEntry) {
        lock.withLock { entries = entries.filter { $0.value !== entry } }
    }

    // MARK: - 启动

    public func start(_ definition: ServiceDefinition) async throws {
        guard FileManager.default.fileExists(atPath: shellPath) else {
            throw ProcessStartError.shellUnavailable("找不到 \(shellPath)")
        }

        let logURL = logFileURL(definitionID: definition.id)
        do {
            try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        } catch {
            throw ProcessStartError.logUnavailable("无法创建 \(logsDirectory.path)：\(error.localizedDescription)")
        }
        // 追加打开：不毁历史；句柄在 spawn 后转交子进程（父进程随即关自己的副本），
        // 此后文件由子进程持有——Portside 死了日志继续写（adr/0001）。
        let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard logFD >= 0 else {
            throw ProcessStartError.logUnavailable("无法打开 \(logURL.path)")
        }
        defer { close(logFD) }
        let nullFD = open("/dev/null", O_RDONLY)
        guard nullFD >= 0 else {
            throw ProcessStartError.logUnavailable("无法打开 /dev/null")
        }
        defer { close(nullFD) }

        let argv = [shellPath, "-l", "-c", definition.launchCommand]
        let env = environment ?? ProcessInfo.processInfo.environment
        let spawnResult = posixSpawn(argv: argv, environment: env, stdoutFD: logFD, stderrFD: logFD, stdinFD: nullFD)
        guard spawnResult > 0 else {
            throw ProcessStartError.spawnFailed(-spawnResult, "posix_spawn 失败（命令或 shell 不可执行）")
        }

        let entry = ProcessEntry(pid: spawnResult, pgid: spawnResult)
        lock.withLock { entries[definition.id] = entry }
        startReaper(entry: entry)

        // 启动判定窗：单次注入时钟挂起，与退出信号竞速（无轮询）。
        // 命令不存在/秒退在此现形，错误带日志末尾（行内可解释，app 不崩）。
        let exited = await raceExit(pid: spawnResult, timeout: startupWindow)
        if exited {
            let status = entry.currentExitStatus()
            lock.withLock { entries[definition.id] = nil }
            throw ProcessStartError.exitedImmediately(
                exitCode: status, logTail: Self.logTail(of: logURL)
            )
        }
    }

    // MARK: - 停止 / 重启（整组信号：SIGTERM → 宽限 → SIGKILL）

    public func stop(_ definition: ServiceDefinition) async throws {
        let entry: ProcessEntry? = lock.withLock { entries[definition.id] }
        if let entry {
            try await stopTrackedGroup(entry)
            return
        }
        // 无注册条目（收编的外部服务 / Portside 重启后未认领）：按定义端口兜底——
        // 只对占用该端口的 pid 发信号（外部服务尽力而为，不猜进程组、绝不碰自己的组）。
        try await stopByPort(definition)
    }

    public func restart(_ definition: ServiceDefinition) async throws {
        // 重启 = 停止 + 启动（状态迁移 运行中→已停止→运行中，UI 由扫描轮呈现）。
        try await stop(definition)
        try await start(definition)
    }

    /// 停止被追踪的进程组：`kill -pgid` 整组 SIGTERM → 宽限期（注入时钟）→ 存活则 SIGKILL。
    private func stopTrackedGroup(_ entry: ProcessEntry) async throws {
        let group = entry.pgid
        // 安全阀：自己的进程组永不被信号（防御：注册表被污染时不自杀）。
        guard group != getpgrp() else {
            removeEntry(entry)
            return
        }
        kill(-group, SIGTERM)

        // 宽限期：领袖退出信号与注入时钟竞速（先到先赢；无轮询忙等）。
        let exited = await raceExit(pid: entry.pid, timeout: gracePeriod)
        if exited && !Self.groupAlive(group) {
            removeEntry(entry)
            return
        }
        // 宽限到仍有存活（或领袖退了但组里还有残余）→ SIGKILL 补刀整组。
        kill(-group, SIGKILL)
        _ = await raceExit(pid: entry.pid, timeout: killTimeout)
        removeEntry(entry)
    }

    /// 端口兜底停止：lsof 找占用定义端口的**监听者**，杀前校验（F3 安全阀，宁漏杀不误杀）：
    /// 每个监听者的命令行必须与定义启动命令经 DefinitionMatcher 规范化匹配，
    /// 任一不匹配（或命令行无从取得）→ 中止并抛「端口已被 … 占用，未停止」，
    /// 一个信号都不发。校验通过后逐个 TERM → 宽限 → KILL（尽力而为）。
    private func stopByPort(_ definition: ServiceDefinition) async throws {
        let pids = await listenerPIDs(port: definition.port)
        guard !pids.isEmpty else { return }
        for pid in pids {
            // 命令行取不到 = 无从校验 = 不杀（与"不匹配"同处置，如实报「未知进程」）。
            let command = await commandLine(of: pid)
            guard let command,
                  DefinitionMatcher.occupierCommandMatches(
                      occupier: command, definitionCommand: definition.launchCommand
                  )
            else {
                let name = command.map { LsofScanner.executableName(of: $0) } ?? "未知进程"
                throw ProcessStopError.occupierMismatch(pid: pid, processName: name)
            }
        }
        let ownGroup = getpgrp()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for pid in pids where pid != ownPID {
            // 组 id 与 pid 不同才按组发（避免误伤同组其他进程）；否则只发该 pid。
            let pgid = getpgid(pid)
            if pgid > 0 && pgid != pid && pgid != ownGroup {
                kill(-pgid, SIGTERM)
            } else {
                kill(pid, SIGTERM)
            }
        }
        // 全部已退出就跳过宽限等待（一次存活检查，非轮询）。
        guard pids.contains(where: { kill($0, 0) == 0 }) else { return }
        try await clock.sleep(for: gracePeriod)
        for pid in pids where kill(pid, 0) == 0 {
            let pgid = getpgid(pid)
            if pgid > 0 && pgid != pid && pgid != ownGroup {
                kill(-pgid, SIGKILL)
            } else {
                kill(pid, SIGKILL)
            }
        }
    }

    /// 占用端口的监听进程清单（lsof `-ti tcp:<port> -sTCP:LISTEN`；只取监听者，
    /// 不含恰好连着该端口的客户进程——误杀客户是比漏杀更坏的结局；失败返回空）。
    private func listenerPIDs(port: Int) async -> [pid_t] {
        guard let runner else { return [] }
        guard let output = try? await runner.run(
            launchPath: LsofScanner.lsofPath, arguments: ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        ) else { return [] }
        return output.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
    }

    /// 进程完整命令行（`ps -ww -o command=`）；取不到返回 nil（调用方无从校验 → 不杀）。
    private func commandLine(of pid: pid_t) async -> String? {
        guard let runner, let output = try? await runner.run(
            launchPath: LsofScanner.psPath, arguments: ["-p", "\(pid)", "-ww", "-o", "command="]
        ) else { return nil }
        let command = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    /// 测试兜底（同步）：SIGKILL 全部被追踪进程组并清空注册表。
    /// 收尸由后台 reaper 完成（不等待——async teardown 在 @MainActor 测试宿主里会自锁：
    /// XCTest 以 XCTWaiter 同步等 async teardown，而任务又要主 actor 才能调度，工单 06 实证；
    /// SIGKILL 本身是终局的，不需要等）。生产路径**绝不调用**——退出不清场（adr/0001）。
    public func killAllForTesting() {
        let all: [ProcessEntry] = lock.withLock {
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }
        for entry in all where entry.pgid != getpgrp() {
            kill(-entry.pgid, SIGKILL)
            kill(entry.pid, SIGKILL)
        }
    }

    // MARK: - 进程原语

    /// posix_spawn：独立进程组（SETPGROUP + pgroup=0）+ 信号复位 + stdio 重定向。
    /// 返回子 pid；失败返回负 errno。
    private func posixSpawn(
        argv: [String], environment: [String: String],
        stdoutFD: Int32, stderrFD: Int32, stdinFD: Int32
    ) -> pid_t {
        // Darwin 导入形态：attr/actions 为不透明类型，经 Optional 指针 + init 函数初始化。
        var attr: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }

        // 新进程组：pgroup=0 → 子进程成为新组领袖（pgid == pid），与 Portside 解耦。
        // CLOEXEC_DEFAULT：除 file actions 明确重定向的 stdio 外，不把宿主的其他描述符漏给子进程。
        // 信号复位：即使宿主忽略了这些信号，子进程也拿默认处置。
        var sigdefault = sigset_t()
        sigemptyset(&sigdefault)
        sigaddset(&sigdefault, SIGINT)
        sigaddset(&sigdefault, SIGTERM)
        sigaddset(&sigdefault, SIGHUP)
        posix_spawnattr_setsigdefault(&attr, &sigdefault)
        // 信号掩码清零：spawn 跑在 Swift 并发池/Dispatch 线程上，这些线程阻塞信号，
        // 阻塞掩码会跨 exec 继承——不清零则子进程收到的 SIGTERM 永远 pending，停止杀不死
        // （工单 06 测试实证）。处置复位（SETSIGDEF）只管 handler，不管掩码。
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(
            &attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        posix_spawn_file_actions_adddup2(&actions, stdinFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO)

        // C 字符串数组：argv 以 null 结尾；env 以 "KEY=VALUE" + null 结尾。
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgv.append(nil)
        defer { for p in cArgv { free(p) } }
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment
            .sorted { $0.key < $1.key }
            .map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer { for p in cEnv { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, &cArgv, &cEnv)
        return rc == 0 ? pid : -rc
    }

    /// 后台 reaper：阻塞 waitpid 收尸（恰好一次、防僵尸、无轮询），记录退出并唤醒等待者。
    private func startReaper(entry: ProcessEntry) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            let reaped = waitpid(entry.pid, &status, 0)
            let exitStatus: Int32? = reaped == entry.pid ? (status & 0xFF00) >> 8 : nil
            entry.markExited(exitStatus)
        }
    }

    /// 挂起直到该 pid 退出（reaper 唤醒 / 认领实例走存活探询）或当前任务被取消
    /// （取消即返回，先取消后注册也覆盖）。
    private func awaitExit(_ pid: pid_t) async {
        let entry: ProcessEntry? = lock.withLock { entries.values.first { $0.pid == pid } }
        if entry?.isReclaimed == true {
            // 非亲生（工单 08 认领实例）：waitpid 收尸权不在本进程（必 ECHILD），
            // 无 reaper 可等——改走有界存活探询。raceExit 超时即取消本任务，
            // 探询只在停止/重启竞速期间运行。
            while Self.isAlive(pid) && !Task.isCancelled {
                try? await clock.sleep(for: Self.reclaimedExitPollInterval)
            }
            return
        }
        let waiter = ExitWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let registered: Bool = lock.withLock {
                    guard let entry = entries.values.first(where: { $0.pid == pid }) else { return false }
                    return entry.appendWaiter(waiter, continuation: continuation)
                }
                // 注册失败（pid 已不在追踪/已退出/任务已取消）：continuation 未入名单，
                // 必须当场恢复——否则本任务永久悬挂（并发双停等场景，工单 06 评审修正）。
                if !registered { continuation.resume() }
            }
        } onCancel: {
            // 取消 = 从等待名单摘除并恢复（竞速败方的任务必须能结束）。
            // 先取消后注册的顺序：detach 先到只标记（名单里还没有）→ appendWaiter 见
            // cancelled 拒注册 → body 立即恢复；两条顺序都恰好恢复一次。
            let entry: ProcessEntry? = lock.withLock { entries.values.first { $0.pid == pid } }
            entry?.detachWaiter(waiter)?.resume()
        }
    }

    /// 退出信号与注入时钟挂起竞速：先到先赢；返回 true = 观察到退出。
    private func raceExit(pid: pid_t, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [clock] in
                try? await clock.sleep(for: timeout)
                return false // 超时先到
            }
            group.addTask { [weak self] in
                await self?.awaitExit(pid)
                return true // 退出先到
            }
            let first = await group.next() ?? false
            group.cancelAll()
            await group.waitForAll()
            return first
        }
    }

    /// 进程是否存活（EPERM 也视为存活——存在但不可信号；ESRCH = 已退出）。
    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// 进程组是否仍有存活成员（EPERM 也视为存活；ESRCH = 全灭）。
    private static func groupAlive(_ pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }

    /// 读日志文件末尾（秒退解释用）；读不到返回空串。
    static func logTail(of url: URL, maxBytes: Int = 2000) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return "" }
        // seekToEnd 后游标在 EOF，读前必须定位（小文件分支不定位=读到空——测试实证）；
        // 偏移先判再减：UInt64 直接相减在 size < maxBytes 时下溢（测试实证 SIGTRAP）。
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readData(ofLength: maxBytes)
        return String(decoding: data, as: UTF8.self)
    }
}
