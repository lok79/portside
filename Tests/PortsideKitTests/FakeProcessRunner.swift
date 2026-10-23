import Foundation
@testable import PortsideKit

/// 测试替身：按完整命令（launchPath + arguments 空格拼接）路由到预制输出。
/// 子进程是系统边界，按 tdd 技能在此处伪造合法；无路由时抛错（模拟工具不存在）。
final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    struct RouteError: Error, CustomStringConvertible {
        let command: String
        var description: String { "FakeProcessRunner 无路由：\(command)" }
    }

    private let lock = NSLock()
    private var routes: [String: ProcessOutput] = [:]
    private(set) var calls: [String] = []

    init() {}

    func on(_ launchPath: String, _ arguments: [String], stdout: String, exitCode: Int32 = 0, stderr: String = "") {
        lock.withLock {
            routes[Self.key(launchPath: launchPath, arguments: arguments)] = ProcessOutput(
                exitCode: exitCode, stdout: stdout, stderr: stderr
            )
        }
    }

    func run(launchPath: String, arguments: [String]) async throws -> ProcessOutput {
        let key = Self.key(launchPath: launchPath, arguments: arguments)
        let route: ProcessOutput? = lock.withLock {
            calls.append(key)
            return routes[key]
        }
        guard let output = route else { throw RouteError(command: key) }
        return output
    }

    static func key(launchPath: String, arguments: [String]) -> String {
        ([launchPath] + arguments).joined(separator: " ")
    }
}
