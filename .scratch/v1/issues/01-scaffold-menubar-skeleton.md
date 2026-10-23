# 01: 项目脚手架与菜单栏骨架

**What to build:** Portside 成为可运行的 Swift 包应用：`swift run` 后菜单栏出现锚形图标，点开出现紧凑主窗（空的四区列表占位），再点图标或失焦即隐藏。业务逻辑全部放 PortsideKit 库目标（可测试），可执行目标只做 UI 胶水。全程无任何网络行为。

**Blocked by:** None (can start immediately)

**Status:** done（1 项待人工实机确认，见 Comments）

- [x] `swift build` 与 `swift test` 全绿；包结构 = PortsideKit 库目标 + portside 可执行目标 + 测试目标
- [ ] `swift run` 后菜单栏图标出现；点开紧凑主窗（约 620px），再点图标隐藏；窗口失焦自动隐藏
- [x] 主窗含四区占位（我的服务 / 后端 / 前端 / 其他）与空状态文案
- [x] 代码零网络请求、零遥测（产品红线）；terms 遵循 portside/GLOSSARY.md

## Comments

- 2026-10-23（agent）：完成。SwiftPM 包（`portside/Package.swift`，tools 6.0 / 语言模式 Swift 5 / macOS 14+，零第三方依赖）：`PortsideKit` 库目标（四区目录 `PanelSections`、面板宽度 `PanelLayout.windowWidth`）+ `portside` 可执行目标（`MenuBarExtra(.window)` 锚形图标 + 620px 紧凑主窗四区装配 + 失焦隐藏 + 退出按钮）。TDD 四个切片均先红后绿；`swift build` / `swift test` 全绿（4 tests, 0 failures）。
- 待人工确认（无 GUI 环境）：第 2 项 `swift run` 后图标出现/点开/失焦隐藏的实机行为。宽度 620 已由测试钉住，图标语义 `.menuBarExtraStyle(.window)` 自带「点开/再点隐藏/失焦隐藏」；另以 `NSApp.setActivationPolicy(.accessory)` 保证不占 Dock。
