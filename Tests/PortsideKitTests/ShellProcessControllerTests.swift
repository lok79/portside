import XCTest
import Darwin
@testable import PortsideKit

/// 工单 06：ShellProcessController 真实进程集成测试。
/// 接缝 = ProcessController 公共接口；可观察面 = 真实进程效果：
/// 独立进程组（pgid 对照）、落盘日志文件（子进程持有句柄）、整组信号无孤儿、错误抛出。
/// 教训（工单 02/04）：所有 await 有界（waitUntil 超时即失败并说明在等什么）；
/// tearDown 必杀干净——任何可能残留的子进程/句柄都有兜底。
@MainActor
final class ShellProcessControllerTests: XCTestCase {
    private var controller: ShellProcessController?
    private var logsDirectory: URL?

    override func tearDown() {
        // 必杀兜底（同步）：SIGKILL 全部本测试启动的进程组。
        // 教训（工单 06 实证）：async teardown 在 @MainActor 测试宿主里会自锁——
        // XCTest 以 XCTWaiter 同步等待 async teardown，而任务又要主 actor 才能调度；
        // SIGKILL 是终局的，同步杀完即走，收尸交给后台 reaper。
        controller?.killAllForTesting()
        controller = nil
        if let logsDirectory {
            try? FileManager.default.removeItem(at: logsDirectory)
        }
    }

    // MARK: - 测试辅助

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-proc-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 测试用控制器：/bin/sh 作"登录 shell"（快、无 profile 副作用；环境继承单测覆盖），
    /// 启动判定窗 0.5s（sh 秒退在 ~10ms 内，判定窗不拖慢也够覆盖）。
    private func makeController(
        gracePeriod: Duration = .seconds(8),
        startupWindow: Duration = .milliseconds(500),
        killTimeout: Duration = .milliseconds(500),
        clock: PortsideClock = SystemClock(),
        runner: ProcessRunner? = nil
    ) -> ShellProcessController {
        let logs = makeDirectory()
        logsDirectory = logs
        let controller = ShellProcessController(
            shellPath: "/bin/sh",
            logsDirectory: logs,
            gracePeriod: gracePeriod,
            startupWindow: startupWindow,
            killTimeout: killTimeout,
            clock: clock,
            runner: runner
        )
        self.controller = controller
        return controller
    }

    private func definition(
        id: String = "def-test", command: String, port: Int = 8081
    ) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: "测试服务", launchCommand: command, port: port, createdAt: Date()
        )
    }

    /// 轮询直到条件成立或超时（有界 + 说明在等什么；竞态=秒级失败，不挂死）。
    private func waitUntil(
        timeout: TimeInterval = 5, _ what: String, _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TestWaitTimeout(what: what, timeout: timeout) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func logContents(_ controller: ShellProcessController, id: String) -> String {
        guard let data = try? Data(contentsOf: controller.logFileURL(definitionID: id)) else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: - S1 启动：登录 shell + 独立进程组 + 落盘日志

    func test启动后落盘日志出现且持续写入() async throws {
        let controller = makeController()
        let def = definition(command: #"while true; do echo tick-$RANDOM; sleep 0.05; done"#)

        try await controller.start(def)

        // 日志文件出现且增长：循环输出脚本持续写（直写落盘，非收口后一次性倾倒）。
        try await waitUntil("落盘日志累计写入 3 行 tick") {
            self.logContents(controller, id: def.id).components(separatedBy: "tick-").count >= 4
        }
        XCTAssertTrue(controller.isRunning(definitionID: def.id))
    }

    func test启动的进程在独立进程组() async throws {
        let controller = makeController()
        // $$ = 登录 shell 进程自身 pid；打印它所在进程组。
        let def = definition(command: #"echo "PGID=$(ps -o pgid= -p $$)"; while true; do sleep 1; done"#)

        try await controller.start(def)

        try await waitUntil("日志里打印出 PGID") {
            self.logContents(controller, id: def.id).contains("PGID=")
        }
        let leader = try XCTUnwrap(controller.runningProcessID(definitionID: def.id))
        let line = logContents(controller, id: def.id)
            .components(separatedBy: "\n")
            .first { $0.contains("PGID=") } ?? ""
        let pgid = try XCTUnwrap(
            line.split(separator: "=").last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            "解析 PGID 输出失败：\(line)"
        )
        XCTAssertEqual(pgid, Int(leader), "进程组 = 启动进程自身（新组领袖）")
        XCTAssertNotEqual(pgid, Int(getpgrp()), "独立于 Portside 自己的进程组（kill -pgid 不误伤 app）")
    }

    /// stderr 与 stdout 同写一个落盘日志（spec §6：托管服务 stdout/stderr 直写）。
    func test标准错误也直写落盘日志() async throws {
        let controller = makeController()
        let def = definition(command: #"echo "ERR-MARK" >&2; while true; do sleep 1; done"#)

        try await controller.start(def)

        try await waitUntil("日志里出现 stderr 内容") {
            self.logContents(controller, id: def.id).contains("ERR-MARK")
        }
    }

    // MARK: - S2 登录 shell 环境继承

    /// `sh -l` 走登录 shell 读 profile（LocalPorts 教训：nvm 等环境靠这个继承）。
    /// 用注入 HOME + .zprofile 钉住「profile 被执行」这一机制本身，不依赖用户机器的 nvm。
    func test启动经登录shell继承profile环境() async throws {
        let fakeHome = makeDirectory()
        try "export PORTSIDE_TICKET6_MARKER=hello-login\n".write(
            to: fakeHome.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8
        )
        let logs = makeDirectory()
        logsDirectory = logs
        let controller = ShellProcessController(
            shellPath: "/bin/zsh",
            logsDirectory: logs,
            runner: nil,
            environment: ["HOME": fakeHome.path, "PATH": "/usr/bin:/bin"]
        )
        self.controller = controller
        let def = definition(command: #"echo "MARK=$PORTSIDE_TICKET6_MARKER"; while true; do sleep 1; done"#)

        try await controller.start(def)

        try await waitUntil("日志里出现 profile 注入的 marker（登录 shell 读了 .zprofile）") {
            self.logContents(controller, id: def.id).contains("MARK=hello-login")
        }
    }

    // MARK: - S3 停止：整组 SIGTERM → 宽限 → SIGKILL

    /// 起停盒：跨并发任务记录 start/stop 是否落定（供有界轮询）。
    private final class StepBox: @unchecked Sendable {
        var done = false
    }

    /// TERM 后进程自己退出：stop 由退出信号完成，不消耗整个宽限期（低资源，无忙等）。
    func test停止时进程自己退出则不等满宽限期() async throws {
        let clock = ManualClock()
        let controller = makeController(gracePeriod: .seconds(8), clock: clock, runner: nil)
        let def = definition(command: #"while true; do sleep 1; done"#)
        // ManualClock 下启动判定窗也是虚拟的：等窗口 sleep 注册后推进过窗
        // （先推进后注册会让 deadline 按推进后的虚拟时间计算，永远追不上——工单 06 实证）。
        let startBox = StepBox()
        let startTask = Task { try await controller.start(def); startBox.done = true }
        try await clock.waitForSleepRegistration(timeout: 5)
        clock.advance(to: clock.now() + .seconds(1))
        try await waitUntil(timeout: 5, "start 落定（判定窗已推进）") { startBox.done }
        let pgid = try XCTUnwrap(controller.runningProcessGroupID(definitionID: def.id))

        let box = StepBox()
        let stopTask = Task {
            try await controller.stop(def)
            box.done = true
        }
        // 关键断言：进程收到 TERM 即死，退出信号赢过宽限 sleep——不推进虚拟时钟，
        // stop 也必须在真实 5s 内落定（若实现错误地等满 8s 宽限，这里会超时失败）。
        try await waitUntil(timeout: 5, "stop 由退出信号完成（未等满宽限）") { box.done }

        XCTAssertFalse(controller.isRunning(definitionID: def.id), "停止后不再追踪")
        try await waitUntil("进程组全灭（kill -pgid 返回 ESRCH）") {
            kill(-pgid, 0) != 0
        }
        _ = startTask
        _ = stopTask
    }

    /// TERM 被忽略（trap '' TERM）：宽限期满注入时钟到期 → SIGKILL 补刀整组。
    func test停止宽限期满仍有存活则SIGKILL补刀() async throws {
        let clock = ManualClock()
        let controller = makeController(gracePeriod: .seconds(8), clock: clock, runner: nil)
        let def = definition(command: #"trap '' TERM; while true; do sleep 1; done"#)
        let startBox = StepBox()
        let startTask = Task { try await controller.start(def); startBox.done = true }
        try await clock.waitForSleepRegistration(timeout: 5)
        clock.advance(to: clock.now() + .seconds(1))
        try await waitUntil(timeout: 5, "start 落定") { startBox.done }
        let pgid = try XCTUnwrap(controller.runningProcessGroupID(definitionID: def.id))

        let box = StepBox()
        let stopTask = Task {
            try await controller.stop(def)
            box.done = true
        }
        // 宽限期 sleep 注册后推进到期 → SIGKILL 补刀（注册-推进节拍，同上）。
        try await clock.waitForSleepRegistration(timeout: 5)
        clock.advance(to: clock.now() + .seconds(8))
        try await waitUntil(timeout: 5, "宽限到期后 stop 落定（SIGKILL 补刀）") { box.done }

        XCTAssertFalse(controller.isRunning(definitionID: def.id))
        try await waitUntil("SIGKILL 后整组全灭") {
            kill(-pgid, 0) != 0
        }
        _ = startTask
        _ = stopTask
    }

    /// 工单验收：脚本 fork 子进程（sleep 30），停止后整组无孤儿残留（pgid 对照，ps 语义）。
    func test停止杀干净fork子进程无孤儿残留() async throws {
        let controller = makeController(gracePeriod: .milliseconds(300), runner: nil)
        let def = definition(command: #"sleep 30 & sleep 30 & echo READY; while true; do sleep 1; done"#)
        try await controller.start(def)
        let pgid = try XCTUnwrap(controller.runningProcessGroupID(definitionID: def.id))

        try await waitUntil("子进程已就位（READY 写进日志）") {
            self.logContents(controller, id: def.id).contains("READY")
        }

        try await controller.stop(def)

        // 组里曾有 3 个成员（sh 领袖 + 2 个 sleep）；停止后必须全灭。
        try await waitUntil(timeout: 5, "整组无残留（kill -pgid ESRCH，无孤儿）") {
            kill(-pgid, 0) != 0
        }
        XCTAssertFalse(controller.isRunning(definitionID: def.id))
    }

    /// 无注册条目（收编的外部服务形态）：按定义端口兜底停止（lsof 找占用者，尽力而为）。
    func test无注册条目时按端口兜底停止() async throws {
        let controller = makeController(gracePeriod: .milliseconds(300), runner: SystemProcessRunner())
        // 外部监听者：不经 controller 启动（Foundation Process，留在 xctest 自己的组里——
        // 兜底路径的安全设计：占用者与 Portside 同组时只杀该 pid，绝不发组信号）。
        let listener = try Self.startListener(port: 18123)
        defer { if listener.isRunning { kill(listener.processIdentifier, SIGKILL) } }
        // 等 nc 真的在监听（lsof 能看到）。
        try await waitUntil("nc 已监听 18123") {
            let pids = Self.lsofPids(port: 18123)
            return pids.contains(pid_t(listener.processIdentifier))
        }

        let def = definition(id: "def-无条目", command: "nc -l 18123", port: 18123)
        try await controller.stop(def)   // 无注册条目 → 端口兜底路径

        try await waitUntil("占用端口的进程被终止") {
            kill(pid_t(listener.processIdentifier), 0) != 0
        }
    }

    /// F3(b) 宁漏杀不误杀：占用者与定义启动命令不匹配 → 中止并抛错，一个信号都不发。
    /// 真实进程：nc 占着端口，定义却写着另一个命令——停止必须拒绝且 nc 活着。
    func test占用者与定义命令不匹配时兜底停止中止且不杀() async throws {
        let controller = makeController(gracePeriod: .milliseconds(300), runner: SystemProcessRunner())
        let listener = try Self.startListener(port: 18131)
        defer { if listener.isRunning { kill(listener.processIdentifier, SIGKILL) } }
        try await waitUntil("nc 已监听 18131") {
            Self.lsofPids(port: 18131).contains(pid_t(listener.processIdentifier))
        }

        let def = definition(id: "def-占用者换人", command: "java -jar ghost-service.jar", port: 18131)
        do {
            try await controller.stop(def)
            XCTFail("占用者换人必须拒绝停止（宁漏杀不误杀）")
        } catch let error as ProcessStopError {
            guard case .occupierMismatch(let pid, let name) = error else {
                XCTFail("错误类型不对：\(error)")
                return
            }
            XCTAssertEqual(pid, pid_t(listener.processIdentifier), "错误带真实占用者 pid")
            XCTAssertEqual(name, "nc", "错误带占用者进程名")
        }

        XCTAssertTrue(kill(listener.processIdentifier, 0) == 0, "不匹配：一个信号都不发，nc 仍存活")
    }

    /// F3(b) 命令行取不到（ps 失败）= 无从校验 → 宁漏杀不误杀，同样拒绝。
    func test占用者命令行取不到时兜底停止拒绝() async throws {
        // FakeProcessRunner 无 ps 路由 → commandLine(of:) 必然失败。
        let runner = FakeProcessRunner()
        runner.on(LsofScanner.lsofPath, ["-ti", "tcp:18133", "-sTCP:LISTEN"], stdout: "4242\n")
        let controller = makeController(gracePeriod: .milliseconds(300), runner: runner)
        let def = definition(id: "def-命令不可得", command: "nc -l 18133", port: 18133)

        do {
            try await controller.stop(def)
            XCTFail("命令行不可得必须拒绝（无从校验 = 不杀）")
        } catch let error as ProcessStopError {
            guard case .occupierMismatch(let pid, let name) = error else {
                XCTFail("错误类型不对：\(error)")
                return
            }
            XCTAssertEqual(pid, 4242)
            XCTAssertEqual(name, "未知进程", "进程名取不到也明示，不猜")
        }
    }

    /// 测试内直接查 lsof（与 controller 同源工具，独立事实来源）。
    private static func lsofPids(port: Int) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-ti", "tcp:\(port)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 起一个真实 nc 监听者（兜底停止路径的占用进程；调用方负责 defer 必杀）。
    private static func startListener(port: Int) throws -> Process {
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        listener.arguments = ["-l", "\(port)"]
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        return listener
    }

    // MARK: - S4 重启 = 停止 + 启动

    func test重启换新进程旧的死服务仍在运行() async throws {
        let controller = makeController()
        let def = definition(command: #"echo "RUN=$$"; while true; do sleep 1; done"#)

        try await controller.start(def)
        let oldPid = try XCTUnwrap(controller.runningProcessID(definitionID: def.id))

        try await controller.restart(def)

        let newPid = try XCTUnwrap(controller.runningProcessID(definitionID: def.id), "重启后重新注册运行态")
        XCTAssertNotEqual(newPid, oldPid, "重启 = 停止 + 启动（新进程）")
        XCTAssertTrue(controller.isRunning(definitionID: def.id))
        XCTAssertTrue(controller.runningProcessGroupID(definitionID: def.id) == newPid,
                      "新进程也是独立组领袖")
        try await waitUntil("旧进程已终止") {
            kill(oldPid, 0) != 0
        }
    }

    // MARK: - S5 启动失败：命令不存在 / 秒退（错误可见，app 不崩）

    func test命令不存在抛启动失败且日志末尾解释原因() async throws {
        let controller = makeController(startupWindow: .milliseconds(800))
        let def = definition(command: "definitely-not-a-command-xyz-12345")

        do {
            try await controller.start(def)
            XCTFail("命令不存在应当抛 ProcessStartError")
        } catch let error as ProcessStartError {
            guard case .exitedImmediately(let code, let tail) = error else {
                return XCTFail("应当是秒退错误，实际：\(error)")
            }
            XCTAssertEqual(code, 127, "shell 对命令不存在返回 127")
            XCTAssertTrue(
                tail.lowercased().contains("not found"),
                "落盘日志末尾应含 shell 报错（秒退可读日志解释）：\(tail)"
            )
        }
        XCTAssertFalse(controller.isRunning(definitionID: def.id), "失败后不留追踪条目")
    }

    func test秒退抛错带退出码与日志末尾() async throws {
        let controller = makeController(startupWindow: .milliseconds(800))
        let def = definition(command: #"echo boom-reason; exit 3"#)

        do {
            try await controller.start(def)
            XCTFail("秒退应当抛 ProcessStartError")
        } catch let error as ProcessStartError {
            guard case .exitedImmediately(let code, let tail) = error else {
                return XCTFail("应当是秒退错误，实际：\(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(tail.contains("boom-reason"), "日志末尾可见失败原因：\(tail)")
        }
    }

    /// 行内文案（工单：错误写进行内状态）——纯函数断言，不依赖进程。
    func test启动失败文案含原因与日志末尾() {
        let message = ProcessStartError.exitedImmediately(
            exitCode: 3, logTail: "Error: Cannot find module 'x'\n"
        ).userMessage
        XCTAssertTrue(message.contains("启动失败"), "明示失败：\(message)")
        XCTAssertTrue(message.contains("退出码 3"), "带退出码：\(message)")
        XCTAssertTrue(message.contains("Cannot find module"), "带日志末尾：\(message)")

        let spawnMessage = ProcessStartError.spawnFailed(8, "exec 格式错误").userMessage
        XCTAssertTrue(spawnMessage.contains("errno=8"), "spawn 失败带 errno：\(spawnMessage)")
    }
}
