import XCTest
@testable import PortsideKit

/// 工单 09：空态 / 错误态 / 极端数据（35+ 监听端口的全噪机）的模型层打磨。
/// UI 不挤不崩的根基在模型：极端输入下行的数量、形状、标识必须可预期。
/// 扫描失败降级已由 PanelViewModelTests 覆盖（保留上次数据 + 顶部明示）。
@MainActor
final class EmptyAndExtremeStateTests: XCTestCase {
    private func makeModel(_ results: [Result<ScanResult, Error>]) -> PanelViewModel {
        PanelViewModel(
            scanner: FakeScanner(results),
            engine: .defaultEngine(runner: FakeProcessRunner()),
            store: InMemoryKeyValueStore()
        )
    }

    // MARK: - 空态：一台什么都没起的机器

    func test全空机器四区皆空汇总态正常() async {
        let model = makeModel([.success(ScanResult(services: [], source: .lsof))])

        await model.refreshOnce()

        XCTAssertTrue(model.allRows.isEmpty, "无任何监听端口：零行")
        for section in PanelSections.all {
            XCTAssertTrue(model.rows(in: section.kind).isEmpty, "\(section.title) 区为空")
            XCTAssertFalse(section.emptyStateMessage.isEmpty, "\(section.title) 区空态文案就绪（UI 不留白板）")
        }
        XCTAssertNil(model.scanNotice, "完整扫描不误报 partial")
        XCTAssertEqual(model.health, .normal, "空机器不误报「有服务挂了」")
    }

    // MARK: - 全挂态：定义过的服务全部消失

    func test全挂机行全为已停止汇总态alert端口区不受牵连() async {
        let center = ServiceDefinitionCenter(store: DefinitionStore(directory: Self.makeDirectory()))
        center.adopt(name: "user-service", commandLine: "java -jar u.jar", port: 8081, pathPrefix: "")
        center.adopt(name: "vite", commandLine: "node vite", port: 5173, pathPrefix: "")
        center.adopt(name: "gateway", commandLine: "java -jar g.jar", port: 9000, pathPrefix: "")
        let model = PanelViewModel(
            scanner: FakeScanner([.success(ScanResult(services: [], source: .lsof))]),
            engine: .defaultEngine(runner: FakeProcessRunner()),
            resolver: DisplayNameResolver(aliasLookup: { center.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { center.hasDefinition(for: $0) }),
            knownDefinitions: { center.knownDefinitions() },
            definitions: center,
            store: InMemoryKeyValueStore()
        )

        await model.refreshOnce()

        let mineRows = model.rows(in: .mine)
        XCTAssertEqual(mineRows.count, 3, "三个定义各出一行已停止行，一个不少")
        XCTAssertTrue(mineRows.allSatisfy { !$0.isUp && $0.isManaged && $0.typeLabel == "已停止" })
        XCTAssertEqual(mineRows.map(\.primaryPort), [5173, 8081, 9000], "端口升序（同区稳定排序）")
        XCTAssertTrue(model.rows(in: .backend).isEmpty && model.rows(in: .frontend).isEmpty
            && model.rows(in: .other).isEmpty, "全挂机无运行实例：外部三区皆空")
        XCTAssertEqual(model.health, .alert, "全部挂掉：菜单栏汇总态警示（GLOSSARY）")
    }

    // MARK: - 极端数据：35+ 监听端口的全噪机（spec 验收 6 的压力面）

    /// QQ 35 个端口 + 微信 3 个端口：塌缩成每进程名一行（共 2 行），端口升序，明细齐全。
    /// 扫描器契约：输出按端口升序（LsofScanner 排序），测试输入照契约构造。
    func test38端口噪机聚合为每进程名单行不膨胀() async {
        var services = (1000...1002).map {
            ListeningService(port: $0, pid: 778, processName: "WeChat", commandLine: nil)
        }
        services += (9000...9034).map {
            ListeningService(port: $0, pid: 777, processName: "QQ", commandLine: nil)
        }
        let model = makeModel([.success(ScanResult(services: services, source: .lsof))])

        await model.refreshOnce()

        let otherRows = model.rows(in: .other)
        XCTAssertEqual(otherRows.count, 2, "38 个端口塌缩为 2 行（每进程名一行），面板不挤爆")
        XCTAssertEqual(
            otherRows.map(\.displayName),
            ["WeChat（3 个端口）", "QQ（35 个端口）"],
            "聚合行按首次出现序（端口升序输入 → 微信在前）；文案带端口数"
        )
        let qq = otherRows[1]
        XCTAssertEqual(qq.ports, Array(9000...9034), "聚合行端口升序、一个不丢")
        XCTAssertEqual(qq.children.count, 35, "展开明细行数与端口数一致")
        XCTAssertEqual(qq.children.map(\.primaryPort), qq.ports, "明细与聚合端口一致")
        XCTAssertTrue(model.rows(in: .backend).isEmpty && model.rows(in: .frontend).isEmpty
            && model.rows(in: .mine).isEmpty, "噪机不影响其余分区")
        XCTAssertEqual(model.health, .normal, "无定义：噪声不误报挂掉")
    }

    /// 噪机重扫（QQ 少了一个端口）：聚合行 id 稳定——SwiftUI diff 不误判，滚动位置不跳。
    func test噪机重扫聚合行id稳定明细id只随事实变() async {
        var first = (9000...9034).map {
            ListeningService(port: $0, pid: 777, processName: "QQ", commandLine: nil)
        }
        first.append(ListeningService(port: 8081, pid: 5011, processName: "java",
            commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"))
        var second = (9000...9033).map {
            ListeningService(port: $0, pid: 777, processName: "QQ", commandLine: nil)
        }
        second.append(ListeningService(port: 8081, pid: 5011, processName: "java",
            commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"))
        let model = makeModel([
            .success(ScanResult(services: first, source: .lsof)),
            .success(ScanResult(services: second, source: .lsof)),
        ])

        await model.refreshOnce()
        let aggIDBefore = model.rows(in: .other)[0].id
        let javaIDBefore = model.rows(in: .backend)[0].id

        // 重扫：QQ 从 35 端口变 34 端口，Java 不变。
        await model.refreshOnce()

        XCTAssertEqual(model.rows(in: .other)[0].id, aggIDBefore, "聚合行 id 不随端口增减漂移")
        XCTAssertEqual(model.rows(in: .backend)[0].id, javaIDBefore, "单服务行 id 稳定")
        XCTAssertEqual(model.rows(in: .other)[0].children.count, 34, "明细随事实更新")
        XCTAssertEqual(
            model.rows(in: .other)[0].displayName, "QQ（34 个端口）",
            "端口数文案随事实更新，不残留旧数"
        )
    }

    /// 折叠状态在重扫后不误继承：旧聚合行消失后其展开记录被清理，不留增长态泄漏。
    func test重扫后消失行的展开记录被清理() async {
        let qq = (9000...9034).map {
            ListeningService(port: $0, pid: 777, processName: "QQ", commandLine: nil)
        }
        let gone = [ListeningService(port: 80, pid: 778, processName: "httpd", commandLine: nil)]
        let model = makeModel([
            .success(ScanResult(services: qq + gone, source: .lsof)),
            .success(ScanResult(services: qq, source: .lsof)),
        ])

        await model.refreshOnce()
        let httpdID = model.rows(in: .other).last!.id
        model.toggleExpanded(httpdID)
        XCTAssertTrue(model.isExpanded(httpdID))

        await model.refreshOnce()

        XCTAssertFalse(model.isExpanded(httpdID), "行消失后展开记录清理（expandedRowIDs 不无界增长）")
        XCTAssertEqual(model.rows(in: .other).count, 1, "只剩 QQ")
    }

    /// 临时目录（全挂机用例的定义落盘处）。
    private static func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("portside-extreme-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
