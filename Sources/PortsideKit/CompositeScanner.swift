import Foundation

/// 组合扫描器（引擎的对外门面）：lsof 主路径 + netstat 降级的策略层。
/// - 主路径抛错（工具不可用）→ 整体降级 netstat 兜底结果（恒为 partial）。
/// - 主路径成功 → 仍用 netstat 交叉核对：macOS 15+ 收紧 lsof 时它 exit 0 但
///   静默漏掉他人/root 套接字（spec §1，实机验证过），补齐缺口并标记 partial，
///   让 UI 有机会明示"清单可能不完整"。
public final class CompositeScanner: PortScanner {
    private let primary: PortScanner
    private let fallback: PortScanner

    public init(primary: PortScanner, fallback: PortScanner) {
        self.primary = primary
        self.fallback = fallback
    }

    public convenience init(runner: ProcessRunner) {
        self.init(primary: LsofScanner(runner: runner), fallback: NetstatScanner(runner: runner))
    }

    public func scan() async throws -> ScanResult {
        let primaryResult: ScanResult
        do {
            primaryResult = try await primary.scan()
        } catch {
            // 主路径不可用：整个降级到 netstat（其结果自带 partial 标记与文案）。
            return try await fallback.scan()
        }

        let fallbackResult: ScanResult
        do {
            fallbackResult = try await fallback.scan()
        } catch {
            // netstat 也拿不到：主路径结果照常返回，不因核对失败而丢数据。
            return primaryResult
        }

        let coveredPorts = Set(primaryResult.services.map(\.port))
        let extras = fallbackResult.services.filter { !coveredPorts.contains($0.port) }
        guard !extras.isEmpty else { return primaryResult }

        return ScanResult(
            services: (primaryResult.services + extras).sorted { $0.port < $1.port },
            source: primaryResult.source,
            isPartial: true,
            partialNotice: "lsof 受限：有端口仅经 netstat 补齐，清单可能不完整。"
        )
    }
}
