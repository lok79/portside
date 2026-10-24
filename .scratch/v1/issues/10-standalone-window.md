# 10: 常规独立窗口形态（菜单栏 + 主窗，D-004 修正注记）

**What to build:** 启动 Portside 即弹出常规独立主窗（有标题栏、可拖动、可关闭），Dock 出现锚形图标（点 Dock 调出主窗）；菜单栏锚形图标保留并继续承载汇总态变色，点击改为「打开/聚焦主窗」。引擎与业务逻辑零改动——本票只换入口壳层（D-004 修正注记，2026-10-24）。

**Blocked by:** None (can start immediately)

**Status:** done（GUI/实机项待人工：见 Comments）

- [x] 启动即显示主窗（620px 紧凑面板原样搬进常规窗口，标题「Portside · 服务码头」）
- [x] Dock 出现 Portside 图标；关闭主窗后 app 不退出（菜单栏图标仍在），点 Dock 或菜单栏图标重新打开/聚焦主窗
- [x] 菜单栏图标点击打开菜单（打开主窗口 / 退出 Portside），图标汇总态变色逻辑不变
- [x] 激活策略改 .regular（Dock 可见）；`.accessory` 相关注释同步修正
- [x] spec「形态」节与 README 与实现对齐（一行级修正）；`swift build` + `swift test` 连跑 3 次全绿
- [x] 实机项（弹窗观感、Dock 行为）标注待人工确认

## Comments

- 2026-10-24（agent）：完成，只换入口壳层——`PanelViewModel` 与 PortsideKit 一行未改（本票无模型层逻辑变更，无新测试可写：按票面口径保留既有 230 测试全绿作回归门）。
  - **主窗**（PortsideApp.swift）：`NSWindow` 托管（App 侧全控关闭/重开路径，不用 WindowGroup 免赌 SwiftUI 的 reopen 行为）——`NSHostingView` 承载现有 `PanelView`（收编/编辑/确认 sheet 全部原样，PanelView/PanelSheets/LogStreamView 零改动），宽 620 钉死（`contentMin/Max` 同值 = `PanelLayout.windowWidth`）、高可调（400 起，列表区 ScrollView 吸收）；标题「Portside · 服务码头」；`isReleasedWhenClosed = false` 关窗仅收窗不释放，重开 `makeKeyAndOrderFront` 模型状态原样；`setFrameAutosaveName` 记住位置/尺寸（首启居中）。
  - **启动即显示主窗**：`applicationDidFinishLaunching` 里 `setActivationPolicy(.regular)` + `showMainWindow()`（`NSApp.activate()` + `makeKeyAndOrderFront`）+ `model.start()`（扫描调度原样独立于面板开合，注释同步）。
  - **关闭不退出**：常规 NSApplication 语义（末窗关闭不终止）+ MenuBarExtra scene 保活；点 Dock 图标经 `applicationShouldHandleReopen(hasVisibleWindows == false)` 重开；菜单栏「打开主窗口」与 Dock 殊途同归走 `showMainWindow()`（已开则仅聚焦前置，不重复建窗）。
  - **菜单栏**：`MenuBarExtra` 改 `.menu` 样式，两项「打开主窗口」「退出 Portside」（Divider 分隔）；label 汇总态切换（anchor ↔ 警示三角红）原样未动。
  - **文档对齐**：spec「形态」节改两行级（启动即显示主窗 / Dock 图标 / 菜单栏点击=打开聚焦主窗，原「再点或失焦隐藏」口径随 D-004 修正注记废止并注明）；README 三处（首段场景、截图占位、启动成功判据 + 关窗待命一句）；GLOSSARY 两词条（面板=主窗里的列表界面、菜单栏图标点击弹菜单）。acceptance.md 的 A1-A8 人工步骤中「面板」一词仍指主窗列表 UI，语义不变未动。
  - **机器验证**：`swift build` + `swift test` 连跑 3 次全绿（230 tests, 1 skipped = PORTSIDE_SMOKE 门控冒烟, 0 failures）；`pgrep -fl "xctest|swift run"` 自查无孤儿。
  - **待人工确认（无 GUI 实机验证环境）**：
    1. 弹窗观感：620px 常规窗内四区/日志视图/三个 sheet（收编/编辑/危险确认）实机观感，标题栏与拖动行为；
    2. Dock 行为：关闭主窗后 app 不退、Dock 图标仍在；点 Dock 重开/聚焦；多屏 + 自动隐藏菜单栏环境下菜单栏图标可达性（D-004 修正注记的原始痛点）；
    3. 菜单栏菜单：点图标弹菜单两项文案与行为、「打开主窗口」在主窗已开/已关两种状态下分别表现为聚焦/重开；
    4. 汇总态变色在 .menu 样式 label 下渲染不回退（原工单 04 待人工项顺延）。
