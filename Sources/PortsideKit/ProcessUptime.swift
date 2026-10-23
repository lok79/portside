import Foundation

/// 运行时长文案（工单 04：行内「运行时长」，来源 = 进程启动时间）。
/// 解析 `ps -o etime=`（POSIX 格式 `[[dd-]hh:]mm:ss`）与生成展示文案，均为纯函数。
public enum UptimeText {
    /// 解析 etime 片段；格式不认识返回 nil（留空，不猜）。
    public static func parse(etime: String) -> Duration? {
        let trimmed = etime.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var remainder = Substring(trimmed)
        var days = 0
        if let dash = remainder.firstIndex(of: "-") {
            guard let parsedDays = Int(remainder[remainder.startIndex..<dash]), parsedDays >= 0 else {
                return nil
            }
            days = parsedDays
            remainder = remainder[remainder.index(after: dash)...]
        }

        let numbers = remainder.split(separator: ":").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let parts = numbers.map { $0! }
        let (hours, minutes, seconds): (Int, Int, Int)
        switch parts.count {
        case 2: (hours, minutes, seconds) = (0, parts[0], parts[1])
        case 3: (hours, minutes, seconds) = (parts[0], parts[1], parts[2])
        default: return nil
        }
        return Duration.seconds(days * 86400 + hours * 3600 + minutes * 60 + seconds)
    }

    /// 展示文案：天段「1天2小时」、小时段「12小时34分」、分段「3分27秒」、秒段「45秒」。
    public static func format(_ duration: Duration) -> String {
        let total = max(0, Int(duration.components.seconds))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if days > 0 { return "\(days)天\(hours)小时" }
        if hours > 0 { return "\(hours)小时\(minutes)分" }
        if minutes > 0 { return "\(minutes)分\(seconds)秒" }
        return "\(seconds)秒"
    }
}

/// 进程运行时长采集器：一轮扫描对所有 pid 发**一次** `ps -o pid=,etime= -p <清单>`
/// （低资源硬约束）。失败（工具不可用/受限）降级为空映射——运行时长留空、不丢服务。
public struct ProcessUptimeFetcher: Sendable {
    public let runner: ProcessRunner

    public init(runner: ProcessRunner) {
        self.runner = runner
    }

    /// 批量采集：pid → 运行时长。坏行/取不到的 pid 不入映射（调用方落 nil 留空）。
    public func fetch(pids: [Int]) async -> [Int: Duration] {
        let sortedPids = PidList.normalized(pids)
        guard !sortedPids.isEmpty else { return [:] }
        let pidList = sortedPids.map(String.init).joined(separator: ",")
        guard let output = try? await runner.run(
            launchPath: LsofScanner.psPath,
            arguments: ["-o", "pid=,etime=", "-p", pidList]
        ) else { return [:] }

        var uptimes: [Int: Duration] = [:]
        for (pid, rest) in PsParser.parse(output.stdout) {
            guard let token = rest.split(separator: " ").first,
                  let duration = UptimeText.parse(etime: String(token)) else { continue }
            uptimes[pid] = duration
        }
        return uptimes
    }
}
