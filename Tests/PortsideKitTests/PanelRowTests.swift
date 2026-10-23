import XCTest
@testable import PortsideKit

/// 工单 04：面板行模型——状态点/显示名/类型/端口/运行时长，
/// 以及「其他」区按进程名聚合成「名（N 个端口）」的规则（spec §2）。
final class PanelRowTests: XCTestCase {
    private func identified(
        port: Int, pid: Int, processName: String?, type: ServiceType, name: String?
    ) -> IdentifiedService {
        IdentifiedService(
            service: ListeningService(port: port, pid: pid, processName: processName),
            identity: ServiceIdentity(type: type, name: name, evidence: "测试"),
            displayName: name ?? "未知 :\(port)"
        )
    }

    // MARK: - 类型标签

    func test类型标签已知值给稳定中文开放值回退原始值() {
        XCTAssertEqual(ServiceType.java.panelLabel, "Java")
        XCTAssertEqual(ServiceType.frontend.panelLabel, "前端 dev server")
        XCTAssertEqual(ServiceType.unknown.panelLabel, "未知")
        XCTAssertEqual(ServiceType(rawValue: "elixir-phoenix").panelLabel, "elixir-phoenix", "开放值回退 rawValue，不猜")
    }

    // MARK: - 单服务行

    func test单服务行携带五要素与打开URL() {
        let row = PanelRowFactory.leafRow(
            for: identified(port: 8081, pid: 5011, processName: "java", type: .java, name: "user-service"),
            section: .backend,
            uptimeText: "3分27秒"
        )
        XCTAssertEqual(row.section, .backend)
        XCTAssertTrue(row.isUp, "扫描发现的行 = 正在监听 = 状态点亮（本票口径）")
        XCTAssertEqual(row.displayName, "user-service")
        XCTAssertEqual(row.typeLabel, "Java")
        XCTAssertEqual(row.ports, [8081])
        XCTAssertEqual(row.uptimeText, "3分27秒")
        XCTAssertEqual(row.openURL, URL(string: "http://localhost:8081"), "spec §5：默认 http://localhost:{port}")
        XCTAssertTrue(row.children.isEmpty, "单服务行无子行")
    }

    func test行id跨扫描稳定不因端口序变化错位() {
        let make = {
            PanelRowFactory.leafRow(
                for: self.identified(port: 8081, pid: 5011, processName: "java", type: .java, name: "user-service"),
                section: .backend,
                uptimeText: nil
            )
        }
        XCTAssertEqual(make().id, make().id, "同一实例两次扫描的行 id 一致，SwiftUI diff 不闪")
    }

    func test运行时长取不到时留空() {
        let row = PanelRowFactory.leafRow(
            for: identified(port: 8787, pid: 832, processName: "Python", type: .unknown, name: nil),
            section: .other,
            uptimeText: nil
        )
        XCTAssertNil(row.uptimeText, "取不到运行时长留空（nil 显式标记），不填占位假数据")
    }

    // MARK: - 「其他」区按进程名聚合（spec §2：QQ（5 个端口））

    func test同名未识别进程聚合为一行含展开明细() {
        let rows = PanelRowFactory.aggregatedRows(from: [
            identified(port: 9883, pid: 101, processName: "QQ", type: .unknown, name: nil),
            identified(port: 9884, pid: 101, processName: "QQ", type: .unknown, name: nil),
            identified(port: 9885, pid: 101, processName: "QQ", type: .unknown, name: nil),
        ], uptimes: [101: .seconds(60)])

        XCTAssertEqual(rows.count, 1, "三个端口聚合成单行")
        let row = rows[0]
        XCTAssertEqual(row.displayName, "QQ（3 个端口）", "工单示例格式：名（N 个端口）")
        XCTAssertEqual(row.section, .other)
        XCTAssertEqual(row.ports, [9883, 9884, 9885])
        XCTAssertEqual(row.children.count, 3, "展开可见明细")
        XCTAssertEqual(row.children.map(\.ports.first), [9883, 9884, 9885], "明细按端口升序")
        XCTAssertEqual(
            row.children.map(\.displayName),
            ["未知 :9883", "未知 :9884", "未知 :9885"],
            "明细行名遵循「未知 + 端口」，不猜（AGENTS.md 红线）"
        )
    }

    func test不同进程名各自成行按首次出现排序() {
        let rows = PanelRowFactory.aggregatedRows(from: [
            identified(port: 5000, pid: 1, processName: "AirPlay", type: .unknown, name: nil),
            identified(port: 8787, pid: 2, processName: "Python", type: .unknown, name: nil),
            identified(port: 8788, pid: 2, processName: "Python", type: .unknown, name: nil),
        ], uptimes: [:])

        XCTAssertEqual(rows.map(\.displayName), ["AirPlay（1 个端口）", "Python（2 个端口）"], "行序 = 输入首次出现序")
        XCTAssertEqual(rows[1].children.map { $0.ports.first }, [8787, 8788])
    }

    func test进程名缺失时聚合为未知进程行() {
        // 降级数据源可能拿不到进程名（nil 显式标记）：聚合行名「未知进程」，不猜名字。
        let rows = PanelRowFactory.aggregatedRows(from: [
            identified(port: 7000, pid: 1, processName: nil, type: .unknown, name: nil),
            identified(port: 7001, pid: 1, processName: nil, type: .unknown, name: nil),
        ], uptimes: [:])

        XCTAssertEqual(rows.map(\.displayName), ["未知进程（2 个端口）"])
    }

    func test聚合行明细各自带运行时长与打开URL() {
        let rows = PanelRowFactory.aggregatedRows(from: [
            identified(port: 9883, pid: 101, processName: "QQ", type: .unknown, name: nil),
        ], uptimes: [101: .seconds(45)])

        XCTAssertEqual(rows[0].children[0].uptimeText, "45秒")
        XCTAssertEqual(rows[0].children[0].openURL, URL(string: "http://localhost:9883"))
    }
}
