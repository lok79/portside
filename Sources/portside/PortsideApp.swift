import SwiftUI
import PortsideKit

/// Portside · 服务码头入口。
/// 形态 A · 紧凑主窗（spec「形态」）：MenuBarExtra 常驻锚形图标，
/// 点开紧凑主窗（约 620px），再点图标隐藏，失焦自动隐藏（.window 样式语义）。
/// 本可执行目标只做 UI 装配，业务逻辑一律在 PortsideKit。
@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Portside · 服务码头", systemImage: "anchor") {
            PanelView()
                .frame(width: PanelLayout.windowWidth)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏应用：不占 Dock（swift run 裸可执行没有 Info.plist 可放 LSUIElement，用激活策略声明）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
