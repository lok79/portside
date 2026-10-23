import Foundation

/// 扫描器（GLOSSARY）：枚举"监听端口 ↔ 进程"映射。
/// 引擎对识别器可扩展（AGENTS.md 红线/D-005）：这里只产出原始进程事实
/// （命令行、工作目录），识别成 Java/前端是工单 03 识别器的事，本协议不写死任何栈假设。
public protocol PortScanner: Sendable {
    /// 扫一次本机监听端口清单。
    /// - Throws: `ScanError.toolUnavailable`——工具不存在/无法执行，调用方可降级。
    func scan() async throws -> ScanResult
}

/// 一次子进程执行的输出。
public struct ProcessOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// 子进程执行边界——扫描器只经此跑系统工具（lsof/netstat/ps），
/// 测试在此边界伪造输出，测试进程从不真跑这些工具。
public protocol ProcessRunner: Sendable {
    func run(launchPath: String, arguments: [String]) async throws -> ProcessOutput
}

/// 扫描错误：区分"工具不可用"（可降级）与"工具在但扫描失败"。
public enum ScanError: Error, Sendable, Equatable {
    case toolUnavailable(tool: String, detail: String)
    case scanFailed(tool: String, detail: String)
}

/// 生产用子进程执行器：Foundation Process，零第三方依赖。
/// 启动失败（工具不存在等）抛 `ScanError.toolUnavailable`；能启动则返回退出码与输出，
/// 非零退出不抛——由调用方结合输出判断语义（如 lsof exit 1 可伴随部分输出）。
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(launchPath: String, arguments: [String]) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        // 管道收口 stdout/stderr，避免子进程直连终端；不用 shell，杜绝注入面。
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 阻塞式读放到协作池之外，等待退出走 terminationHandler，不占并发线程。
        let stdoutTask = Task.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try process.run()
        } catch {
            throw ScanError.toolUnavailable(tool: launchPath, detail: String(describing: error))
        }

        let exitCode: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { terminated in
                continuation.resume(returning: terminated.terminationStatus)
            }
        }
        let stdout = String(decoding: await stdoutTask.value, as: UTF8.self)
        let stderr = String(decoding: await stderrTask.value, as: UTF8.self)

        return ProcessOutput(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
