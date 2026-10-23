import XCTest
@testable import PortsideKit

/// 工单 04：分区归属器（spec §2 四区归属规则）。
/// 规则：我的服务 = 有服务定义的（收编产生）；后端 = Java 未收编；前端 = dev server；
/// 其他 = 未识别。本票定义集合为空（注入接口留给工单 05）。
final class SectionAssignerTests: XCTestCase {
    /// 造一个已识别服务：类型可指定，端口/进程名可指定。
    private func service(
        port: Int, type: ServiceType, name: String? = "svc", processName: String? = "proc"
    ) -> IdentifiedService {
        IdentifiedService(
            service: ListeningService(port: port, pid: port * 10, processName: processName),
            identity: ServiceIdentity(type: type, name: name, evidence: "测试"),
            displayName: name ?? "未知 :\(port)"
        )
    }

    // MARK: - 单个归属

    func test有定义的进我的服务优先于类型() {
        let assigner = SectionAssigner(hasDefinition: { _ in true })
        // 即使识别为 Java，有定义也进「我的服务」（spec §2：收编后从后端移入我的服务）。
        XCTAssertEqual(assigner.section(for: service(port: 8081, type: .java)), .mine)
        XCTAssertEqual(assigner.section(for: service(port: 5173, type: .frontend)), .mine)
    }

    func test本票默认无定义Java落后端() {
        // 默认注入 = 空定义集合（工单 05 之前）：Java 不进「我的服务」。
        let assigner = SectionAssigner()
        XCTAssertEqual(assigner.section(for: service(port: 8081, type: .java)), .backend)
    }

    func test前端devServer落前端区() {
        let assigner = SectionAssigner()
        XCTAssertEqual(assigner.section(for: service(port: 5173, type: .frontend)), .frontend)
    }

    func test未识别落其他区() {
        let assigner = SectionAssigner()
        let unknown = service(port: 8787, type: .unknown, name: nil)
        XCTAssertEqual(assigner.section(for: unknown), .other)
    }

    func test未知类型开放值一律落其他() {
        // D-005：类型是开放值。未来新增栈在本票的分区映射里对照不上 → 落「其他」，
        // 不崩、不猜（ServiceType 文档即如此约定）。
        let assigner = SectionAssigner()
        let future = service(port: 9999, type: ServiceType(rawValue: "elixir-phoenix"))
        XCTAssertEqual(assigner.section(for: future), .other)
    }

    // MARK: - 分组

    func test分组保持区内输入顺序且各区独立() {
        let assigner = SectionAssigner(hasDefinition: { $0.port == 7000 })
        let services = [
            service(port: 8081, type: .java, name: "user-service"),
            service(port: 5173, type: .frontend, name: "vite"),
            service(port: 7000, type: .java, name: "收编过的"),   // 有定义 → 我的服务
            service(port: 8787, type: .unknown, name: nil),
            service(port: 8082, type: .java, name: "order-service"),
            service(port: 3000, type: .frontend, name: "next"),
        ]

        let grouping = assigner.group(services)

        XCTAssertEqual(grouping[.mine]?.map(\.service.port), [7000])
        XCTAssertEqual(grouping[.backend]?.map(\.service.port), [8081, 8082], "区内顺序 = 输入顺序（扫描按端口升序）")
        XCTAssertEqual(grouping[.frontend]?.map(\.service.port), [5173, 3000])
        XCTAssertEqual(grouping[.other]?.map(\.service.port), [8787])
        // 每个服务只落一区，不重复不丢失。
        XCTAssertEqual(
            grouping.values.reduce(0) { $0 + $1.count }, services.count,
            "分组后总数与输入一致"
        )
    }
}

/// 工单 04：菜单栏汇总态（GLOSSARY：菜单栏图标——全部正常 / 有服务挂了）。
/// 本票「挂掉」的唯一来源：有服务定义但未在监听。定义集合为空 → 恒 normal。
final class MenuBarBadgeTests: XCTestCase {
    private func defined(_ port: Int) -> KnownServiceDefinition {
        KnownServiceDefinition(name: "svc:\(port)", port: port)
    }

    func test无已知服务时恒为normal() {
        // 本票状态：定义集合为空（工单 05 才落地），汇总态恒 normal。
        XCTAssertEqual(MenuBarBadge.state(knownServices: [], listeningPorts: []), .normal)
        XCTAssertEqual(MenuBarBadge.state(knownServices: [], listeningPorts: [8081]), .normal)
    }

    func test已知服务全部在监听时为normal() {
        let state = MenuBarBadge.state(
            knownServices: [defined(8081), defined(8082)],
            listeningPorts: [8081, 8082, 5173]
        )
        XCTAssertEqual(state, .normal)
    }

    func test任一已知服务未在监听时为alert() {
        let state = MenuBarBadge.state(
            knownServices: [defined(8081), defined(8082)],
            listeningPorts: [8081]
        )
        XCTAssertEqual(state, .alert, "order-service 挂了 → 图标 alert（spec 用户故事 1）")
    }

    func test已知服务恢复监听后回到normal() {
        // 挂 → alert；恢复 → normal（工单验收 3「恢复变回」）。
        let services = [defined(8081)]
        XCTAssertEqual(MenuBarBadge.state(knownServices: services, listeningPorts: []), .alert)
        XCTAssertEqual(MenuBarBadge.state(knownServices: services, listeningPorts: [8081]), .normal)
    }

    func test未识别端口的存活不影响汇总态() {
        // 只有未识别进程在跑（无定义）不算「已知服务挂掉」——汇总态只看已知服务。
        let state = MenuBarBadge.state(
            knownServices: [defined(8081)],
            listeningPorts: [8787, 9883]
        )
        XCTAssertEqual(state, .alert, "8081 未在监听，未知端口的存活不抵消")
    }
}
