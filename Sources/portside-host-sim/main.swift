import Foundation
import PortsideKit

// 工单 08 集成测试替身（adr/0001 解耦验证的"可测等价物"）：
// 模拟 Portside 宿主进程——自成进程组、真跑 ShellProcessController 起一个托管服务、
// 之后原地挂起且**没有任何退出清理路径**（无 atexit、无信号处理器、无终止钩子）。
// 测试对它的整组 kill -9 即等价「kill -9 Portside」，不必让测试进程自杀。

// 自成进程组：Portside 本身也是一组领袖（GUI app 常态）。setpgid 让测试能对
// 「宿主这一组」发信号（kill -<宿主pid>），等价杀掉整个 app 及其同组附属。
let groupResult = setpgid(0, 0)
guard groupResult == 0 else {
    FileHandle.standardError.write("setpgid 失败：errno=\(errno)\n".data(using: .utf8)!)
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("用法：portside-host-sim <logs-dir> <launch-command...>\n".data(using: .utf8)!)
    exit(2)
}
let logsDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let launchCommand = arguments[2...].joined(separator: " ")

let controller = ShellProcessController(
    shellPath: "/bin/sh",
    logsDirectory: logsDirectory,
    startupWindow: .milliseconds(300),
    runner: nil
)
let definition = ServiceDefinition(
    id: "host-sim-service",
    name: "宿主替身服务",
    launchCommand: launchCommand,
    port: 0,
    createdAt: Date()
)

// 起服务 → 向 stdout 报告 pid → 原地挂起。报告协议（测试按行解析）：
//   STARTED pid=<n>  —— 服务已起且被追踪
//   START-FAILED …   —— 启动失败（stderr，退出码 3）
Task {
    do {
        try await controller.start(definition)
        let pid = controller.runningProcessID(definitionID: definition.id)
            .map(String.init) ?? ""
        FileHandle.standardOutput.write("STARTED pid=\(pid)\n".data(using: .utf8)!)
    } catch {
        FileHandle.standardError.write("START-FAILED: \(error)\n".data(using: .utf8)!)
        exit(3)
    }
}
dispatchMain()
