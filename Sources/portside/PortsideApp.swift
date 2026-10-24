import SwiftUI
import PortsideKit

/// Portside · 服务码头入口。
/// 形态（D-004 修正注记 2026-10-24）：菜单栏 + 常规独立窗口双入口。
/// 启动即显示常规独立主窗（约 620px 紧凑面板原样承载 PanelView 四区，标题「Portside · 服务码头」）；
/// 关闭主窗 app 不退出（菜单栏图标仍在），点 Dock 图标或菜单栏「打开主窗口」重新打开/聚焦。
/// 菜单栏锚形图标保留并继续承载汇总态（全绿锚形 / 有已知服务挂了变警示），点击弹出菜单
/// （打开主窗口 / 退出 Portside）。本可执行目标只做 UI 装配，业务逻辑一律在 PortsideKit。
@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("打开主窗口") {
                appDelegate.showMainWindow()
            }
            Divider()
            Button("退出 Portside") {
                NSApp.terminate(nil)
            }
        } label: {
            // 汇总态映射：全绿 → 锚形；有已知服务挂掉 → 警示三角（红）。
            // 菜单栏图标按模板渲染，颜色可能被系统抹平——符号形状差异保底可辨
            //（实机视觉待人工确认，见工单 04 验收 Comments）。
            switch appDelegate.model.health {
            case .normal:
                Image(systemName: "anchor")
            case .alert:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 常规激活应用（.regular：Dock 出现锚形图标，关闭主窗不退出——swift run 裸可执行没有
/// Info.plist 可放策略，用激活策略声明；原 .accessory「不占 Dock」口径随 D-004 修正注记废止）。
/// 主窗与面板 ViewModel 都挂在 AppDelegate（SwiftUI App struct 的 init 可能被多次执行，
/// delegate 只创建一次——调度器不可重复起多份，低资源硬约束）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelViewModel.production()

    /// 常规独立主窗。关闭仅收窗不释放（isReleasedWhenClosed = false），
    /// 重开即 makeKeyAndOrderFront——PanelView 及其模型状态原样保留。
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        // 启动即显示主窗（发现性兜底：Dock 图标 + 常规窗口，见 D-004 修正注记）。
        showMainWindow()
        // 扫描调度独立于面板开合启动：图标汇总态在主窗关闭时也要随扫描更新（GLOSSARY：
        // 菜单栏图标——不开面板也能感知）。面板可见性经 panelDidAppear/Disappear 记录活动，
        // 隐藏时调度自然退避（低资源硬约束）。
        model.start()
    }

    /// 关闭主窗后点 Dock 图标：重新打开/聚焦主窗。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    /// 打开或聚焦主窗：已存在则激活 + 前置聚焦，否则创建。
    /// 宽度钉死 spec 的约 620px（contentMin/Max 同值），高度可调（列表区 ScrollView 吸收）。
    func showMainWindow() {
        NSApp.activate()
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: PanelLayout.windowWidth, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Portside · 服务码头"
            window.contentMinSize = NSSize(width: PanelLayout.windowWidth, height: 400)
            window.contentMaxSize = NSSize(width: PanelLayout.windowWidth, height: 10_000)
            window.contentView = NSHostingView(
                rootView: PanelView(model: model)
                    .frame(width: PanelLayout.windowWidth)
            )
            window.isReleasedWhenClosed = false
            window.center()
            // 首启居中；此后位置/尺寸记住（autosave），重开与下次启动恢复原位。
            window.setFrameAutosaveName("PortsideMainWindow")
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}
