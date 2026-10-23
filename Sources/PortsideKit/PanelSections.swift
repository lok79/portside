import CoreGraphics

/// 面板分区（spec §2 四区）：我的服务 / 后端 / 前端 / 其他。
/// 顺序即面板自上而下的展示顺序，是 spec 固定行为。
public enum ServiceSectionKind: String, CaseIterable, Sendable {
    /// 我的服务：有服务定义（收编产生）的，含已停止实例。
    case mine
    /// 后端：识别为 Java、尚未收编的。
    case backend
    /// 前端：识别为 dev server 的。
    case frontend
    /// 其他：未识别进程按进程名聚合。
    case other
}

/// 面板里一个分区的展示信息：标题与空状态文案。
public struct PanelSection: Sendable {
    public let kind: ServiceSectionKind
    public let title: String
    public let emptyStateMessage: String

    public init(kind: ServiceSectionKind, title: String, emptyStateMessage: String) {
        self.kind = kind
        self.title = title
        self.emptyStateMessage = emptyStateMessage
    }
}

/// 面板形态常量（spec 形态 A · 紧凑主窗）。
public enum PanelLayout {
    /// 紧凑主窗宽度，spec：约 620px。
    public static let windowWidth: CGFloat = 620
}

/// 面板四区目录：UI 装配消费的唯一接缝。
public enum PanelSections {
    public static let all: [PanelSection] = [
        PanelSection(
            kind: .mine,
            title: "我的服务",
            emptyStateMessage: "尚无托管服务——把外部服务收编后，它会住进这里。"
        ),
        PanelSection(
            kind: .backend,
            title: "后端",
            emptyStateMessage: "暂未发现 Java 后端服务。"
        ),
        PanelSection(
            kind: .frontend,
            title: "前端",
            emptyStateMessage: "暂未发现前端 dev server。"
        ),
        PanelSection(
            kind: .other,
            title: "其他",
            emptyStateMessage: "没有未识别的进程。"
        ),
    ]
}
