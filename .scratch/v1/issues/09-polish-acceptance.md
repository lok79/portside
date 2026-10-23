# 09: 低资源打磨与 v1 验收收口

**What to build:** 刷新三档设置入口、空态/错误态/极端数据打磨；按 spec 验收标准 1-10 逐条实测，结果记入 `portside/docs/acceptance.md`（仿 lurk 的发版前手工清单，以后每次发版过一遍）；README 起草（人味文案、一句话场景、截图占位）。

**Blocked by:** 07, 08

**Status:** ready-for-agent

- [ ] 设置区可切刷新三档（Realtime/Balanced/Low Resource），生效即时
- [ ] 空态（无服务/无定义）、错误态（扫描失败/启动失败）、极端数据（35+ 监听端口的全噪机）下 UI 不挤不崩
- [ ] spec 验收 1-10 逐条实测，结果与数值（含 Activity Monitor 内存/CPU）写入 docs/acceptance.md；未过项写明原因与去向
- [ ] README：一句话定位、真实截图占位、构建/运行方式；文案人味、无期货功能
- [ ] `swift build` / `swift test` 全绿收口
