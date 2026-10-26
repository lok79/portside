import XCTest
@testable import PortsideKit

/// 工单 13:端口搜索——纯函数过滤语义。
/// 独立事实来源:.scratch/port-search/spec.md 定稿决策 1–5
/// (只按端口、精确匹配、聚合行收窄子行、已停止定义行按定义端口命中)。
final class PanelSearchTests: XCTestCase {
    private func leaf(
        id: String, port: Int, section: ServiceSectionKind = .backend,
        isUp: Bool = true, definitionID: String? = nil
    ) -> PanelRow {
        PanelRow(
            id: id, section: section, isUp: isUp, isManaged: definitionID != nil,
            definitionID: definitionID, displayName: "svc:\(port)", typeLabel: "Java",
            ports: [port], uptimeText: nil, commandLine: nil, pathPrefix: "", children: []
        )
    }

    private func aggregated(id: String, name: String, ports: [Int]) -> PanelRow {
        let children = ports.map { leaf(id: "\(id)-child:\($0)", port: $0, section: .other) }
        return PanelRow(
            id: id, section: .other, isUp: true, isManaged: false, definitionID: nil,
            displayName: "\(name)（\(ports.count) 个端口）", typeLabel: "未知",
            ports: ports, uptimeText: nil, commandLine: nil, pathPrefix: "", children: children
        )
    }

    // MARK: - 输入规范化（spec 决策 9：视图显示与查询共用，所见即所查）

    func test规范化剔非数字并归一前导零() {
        XCTAssertEqual(PanelSearch.normalizedQueryText(" :8080 "), "8080")
        XCTAssertEqual(PanelSearch.normalizedQueryText("abc"), "", "无数字 = 非搜索态")
        XCTAssertEqual(
            PanelSearch.normalizedQueryText("0008080"), "8080",
            "前导零无害（决策 9）——评审轮 1 修复的回归钉"
        )
        XCTAssertEqual(PanelSearch.normalizedQueryText("0000000000"), "0", "全零归一为 0")
        XCTAssertEqual(
            PanelSearch.normalizedQueryText("12345678"), "12345",
            "端口 ≤65535：超长粘贴就地截断，杜绝溢出歧义分支"
        )
    }

    // MARK: - 查询为空 = 非搜索态

    func test查询为空原样返回不过滤() {
        let rows = [leaf(id: "a", port: 8080), leaf(id: "b", port: 3000)]
        XCTAssertEqual(PanelSearch.filtered(rows: rows, port: nil), rows)
    }

    // MARK: - 单服务行：精确匹配（spec 决策 1–2）

    func test单服务行按端口精确命中() {
        let a = leaf(id: "a", port: 8080)
        let b = leaf(id: "b", port: 3000)

        XCTAssertEqual(PanelSearch.filtered(rows: [a, b], port: 8080), [a])
        XCTAssertTrue(
            PanelSearch.filtered(rows: [a, b], port: 80).isEmpty,
            "精确匹配：输 80 不中 8080（决策 2）"
        )
    }

    // MARK: - 聚合行：命中子端口收窄，无命中落榜（spec 决策 5）

    func test聚合行命中子端口时收窄为命中子行() {
        let qq = aggregated(id: "agg:QQ", name: "QQ", ports: [61234, 61235])
        let web = leaf(id: "w", port: 8080)

        let result = PanelSearch.filtered(rows: [qq, web], port: 61234)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "agg:QQ", "标题行保留，进程名上下文不丢")
        XCTAssertEqual(result.first?.children.map(\.primaryPort), [61234], "只留命中子行")
        XCTAssertEqual(
            result.first?.ports, [61234, 61235],
            "聚合行自身端口事实不重写（标题文案与事实一致，不猜）"
        )
    }

    func test聚合行无命中子端口时整行落榜() {
        let qq = aggregated(id: "agg:QQ", name: "QQ", ports: [61234, 61235])

        XCTAssertTrue(PanelSearch.filtered(rows: [qq], port: 8080).isEmpty)
    }

    // MARK: - 已停止定义行：按定义端口命中（spec 决策 4）

    func test已停止定义行按定义端口命中() {
        let stopped = leaf(
            id: "def:def-1", port: 8080, section: .mine,
            isUp: false, definitionID: "def-1"
        )

        XCTAssertEqual(
            PanelSearch.filtered(rows: [stopped], port: 8080), [stopped],
            "「8080 怎么没响应」正是最需要反查的时刻（决策 4）"
        )
    }
}

/// 工单 13:搜索态在 ViewModel 的组合(复用 PanelViewModelTests 的
/// FakeScanner / InMemoryKeyValueStore 同模块替身)。
@MainActor
final class PanelSearchViewModelTests: XCTestCase {
    private static let services = [
        ListeningService(
            port: 8081, pid: 5011, processName: "java",
            commandLine: "/usr/bin/java -jar /apps/user-service-1.0.0-SNAPSHOT.jar"
        ),
        ListeningService(
            port: 5173, pid: 99999, processName: "node",
            commandLine: "/usr/local/bin/node /x/node_modules/.bin/vite --port 5173"
        ),
    ]

    private func makeModel() -> PanelViewModel {
        PanelViewModel(
            scanner: FakeScanner([.success(ScanResult(services: Self.services, source: .lsof))]),
            engine: .defaultEngine(runner: FakeProcessRunner()),
            store: InMemoryKeyValueStore()
        )
    }

    // MARK: - 输入规范化（spec 决策 9）+ 行过滤组合（spec 决策 3）

    func test输入规范化并过滤行() async {
        let model = makeModel()
        await model.refreshOnce()
        XCTAssertEqual(model.rows(in: .backend).count, 1, "前提:未搜索时行齐全")

        model.applySearchQuery(" :8081 ")
        XCTAssertEqual(model.searchPort, 8081, "粘贴清洗:剔非数字取数字部分")
        XCTAssertEqual(model.rows(in: .backend).count, 1)
        XCTAssertEqual(model.rows(in: .frontend).count, 0, "搜索态:无匹配分区滤空")

        model.applySearchQuery("abc")
        XCTAssertNil(model.searchPort, "纯字母:无数字可取 = 非搜索态")
        XCTAssertEqual(model.rows(in: .backend).count, 1, "非搜索态不过滤")
    }

    // MARK: - 搜索态生命周期（spec 决策 8:面板隐藏再开即清空）

    func test面板隐藏清空搜索() async {
        let model = makeModel()
        await model.refreshOnce()
        model.applySearchQuery("8081")
        XCTAssertEqual(model.searchPort, 8081)

        model.panelDidDisappear()

        XCTAssertNil(model.searchPort, "面板隐藏 = 搜索清空(重开即干净列表)")
        XCTAssertEqual(model.rows(in: .backend).count, 1)
    }
}
