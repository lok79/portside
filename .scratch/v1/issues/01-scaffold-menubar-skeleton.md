# 01: 项目脚手架与菜单栏骨架

**What to build:** Portside 成为可运行的 Swift 包应用：`swift run` 后菜单栏出现锚形图标，点开出现紧凑主窗（空的四区列表占位），再点图标或失焦即隐藏。业务逻辑全部放 PortsideKit 库目标（可测试），可执行目标只做 UI 胶水。全程无任何网络行为。

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] `swift build` 与 `swift test` 全绿；包结构 = PortsideKit 库目标 + portside 可执行目标 + 测试目标
- [ ] `swift run` 后菜单栏图标出现；点开紧凑主窗（约 620px），再点图标隐藏；窗口失焦自动隐藏
- [ ] 主窗含四区占位（我的服务 / 后端 / 前端 / 其他）与空状态文案
- [ ] 代码零网络请求、零遥测（产品红线）；terms 遵循 portside/GLOSSARY.md
