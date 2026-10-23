import XCTest
@testable import PortsideKit

/// 工单 02 验收项：集成冒烟——本机实测扫描结果与手工 lsof 输出对照无缺失。
/// 默认跳过（CI 不跑真 lsof、不依赖环境）；设 `PORTSIDE_SMOKE=1` 才执行。
final class ScannerSmokeTests: XCTestCase {
    private static let smokeEnabled = ProcessInfo.processInfo.environment["PORTSIDE_SMOKE"] == "1"

    func test本机实扫与手工lsof对照无缺失() async throws {
        guard Self.smokeEnabled else {
            throw XCTSkip("集成冒烟需真跑 lsof/netstat：设 PORTSIDE_SMOKE=1 开启（默认 CI 跳过）")
        }
        #if os(macOS)
        // 手工对照组：与扫描器无关的独立解析，作为独立事实来源。
        let manual = Process()
        manual.executableURL = URL(fileURLWithPath: LsofScanner.lsofPath)
        manual.arguments = LsofScanner.listenArguments
        let pipe = Pipe()
        manual.standardOutput = pipe
        try manual.run()
        let manualData = pipe.fileHandleForReading.readDataToEndOfFile()
        manual.waitUntilExit()
        let manualPorts = Set(
            String(decoding: manualData, as: UTF8.self)
                .split(separator: "\n")
                .filter { $0.hasSuffix("(LISTEN)") }
                .compactMap { $0.split(separator: " ").dropLast(1).last }
                .compactMap { $0.split(separator: ":").last }
                .compactMap { Int($0) }
        )
        guard !manualPorts.isEmpty else {
            throw XCTSkip("本机 lsof 没有可解析的监听行，无法对照")
        }

        let scanner = CompositeScanner(runner: SystemProcessRunner())
        let result = try await scanner.scan()
        let scannedPorts = Set(result.services.map(\.port))

        let missing = manualPorts.subtracting(scannedPorts)
        XCTAssertTrue(
            missing.isEmpty,
            "扫描结果缺失以下端口（手工 lsof 可见）：\(missing.sorted())；\(result.partialNotice ?? "")"
        )
        #else
        throw XCTSkip("仅 macOS 有 lsof/netstat")
        #endif
    }
}
