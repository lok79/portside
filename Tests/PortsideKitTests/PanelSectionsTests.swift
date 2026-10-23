import XCTest
import PortsideKit

/// 工单 01：面板四区目录（spec §2 分区）。
/// 接缝：PortsideKit.PanelSections —— UI 装配唯一消费的公共接口。
final class PanelSectionsTests: XCTestCase {
    func test四区按规格顺序排列() throws {
        XCTAssertEqual(
            PanelSections.all.map(\.kind),
            [.mine, .backend, .frontend, .other]
        )
    }

    func test紧凑主窗宽度按规格为620() throws {
        // 独立事实来源：spec「形态 A」——紧凑主窗约 620px。
        XCTAssertEqual(PanelLayout.windowWidth, 620)
    }

    func test各区标题遵循GLOSSARY() throws {
        // 独立事实来源：spec §2 与 GLOSSARY——四区名称固定。
        XCTAssertEqual(PanelSections.all.map(\.title), ["我的服务", "后端", "前端", "其他"])
    }

    func test每区空状态都有文案() throws {
        // 空状态文案是工单 01 验收项：空白区必须对用户解释它为什么是空的。
        for section in PanelSections.all {
            XCTAssertFalse(
                section.emptyStateMessage.trimmingCharacters(in: .whitespaces).isEmpty,
                "分区 \(section.title) 缺少空状态文案"
            )
        }
    }
}
