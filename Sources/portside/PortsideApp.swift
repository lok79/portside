import SwiftUI
import PortsideKit

/// Portside · 服务码头入口。
/// 形态 A · 紧凑主窗（spec「形态」）：MenuBarExtra 常驻锚形图标（汇总态直接上图标：
/// 全绿锚形 / 有已知服务挂了变警示），点开紧凑主窗（约 620px），再点图标隐藏，
/// 失焦自动隐藏（.window 样式语义）。本可执行目标只做 UI 装配，业务逻辑一律在 PortsideKit。
@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: appDelegate.model)
                .frame(width: PanelLayout.windowWidth)
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
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏应用：不占 Dock（swift run 裸可执行没有 Info.plist 可放 LSUIElement，用激活策略声明）。
/// 面板 ViewModel 挂在 AppDelegate（SwiftUI App struct 的 init 可能被多次执行，
/// delegate 只创建一次——调度器不可重复起多份，低资源硬约束）。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PanelViewModel.production()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // 扫描调度独立于面板开合启动：图标汇总态在面板关闭时也要随扫描更新（GLOSSARY：
        // 菜单栏图标——不开面板也能感知）。面板可见性经 panelDidAppear/Disappear 记录活动，
        // 隐藏时调度自然退避（低资源硬约束）。
        model.start()
    }
}
