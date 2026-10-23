# 04: 四区列表 UI 与菜单栏汇总态

**What to build:** 主窗显示真实扫描数据的四区列表：我的服务（有定义的）/ 后端（Java 未收编）/ 前端（dev server）/ 其他（未识别进程按名聚合、默认折叠、「隐藏其他」开关）。行含状态点、名称、端口、运行时长；菜单栏图标汇总态（全绿 / 有挂变色）；行内「打开」按钮浏览器直达 `http://localhost:{port}`。

**Blocked by:** 03

**Status:** done（3 项待人工实机确认，见 Comments）

- [x] 真实数据下四区渲染正确；QQ/微信等未识别进程聚合成单行（如「QQ（5 个端口）」）默认折叠，展开可见明细
- [x] 「隐藏其他」开关生效且数据不丢（重开可见）
- [x] 图标汇总态：任一已知服务挂掉图标变色，恢复变回（状态注入可测）
- [ ] 「打开」用系统默认浏览器开 `http://localhost:{port}`
- [x] 服务上下线时列表自动刷新（扫描器驱动，无手动刷新按钮）

## Comments

- 2026-10-23（agent）：完成。Kit 新增：分区归属器 `SectionAssigner`（我的服务=有定义者，本票注入空定义集合、留 `DefinitionLookup` 接缝给工单 05；未知类型开放值一律落「其他」，D-005）；行模型 `PanelRow`/`PanelRowFactory`（状态点/显示名/类型/端口/运行时长 + 「其他」按进程名聚合「名（N 个端口）」、默认折叠、展开明细走「未知 + 端口」不猜）；运行时长 `ProcessUptimeFetcher`/`UptimeText`（`ps -o pid=,etime=` 一次调用取全部 pid，取不到留空）；汇总态 `MenuBarBadge`（挂=有定义未在监听，定义集合为空恒 normal，纯函数注入可测）；持久化接缝 `KeyValueStore` + `UserDefaultsStore`；`PanelViewModel`（@MainActor ObservableObject：RefreshScheduler 驱动 CompositeScanner → 识别 → 分区 → 行模型，partial/失败顶部明示、失败保留上次数据，「隐藏其他」写穿持久层且模型层数据不丢，start 即首刷、在途刷新防堆积、面板可见才记活动——隐藏后自然退避）。UI 装配：`PortsideApp`（ViewModel 挂 AppDelegate 保单实例，图标随汇总态切锚形/警示三角）+ `PanelView`（四区装配消费 `PanelSections.all`、partial 横幅、聚合行折叠展开、「隐藏其他」开关、「打开」= `NSWorkspace.open(row.openURL)` 一行胶水）。TDD 五切片均先红后绿；`swift build`/`swift test` 全绿（80 tests, 0 failures；`PORTSIDE_SMOKE=1` 下 80 全过含真 lsof 对照无缺失）。实机数据管线冒烟：真机扫出 Java 后端（fat jar 清洗名）、vite 前端（package.json 项目名）、QQ（4 个端口）/企业微信（5 个端口）聚合行、真实运行时长（4天13小时）、macOS 26 lsof 受限 partial 横幅，全部符合预期。
- 待人工确认（无 GUI 环境）：
  - 「打开」按钮：`NSWorkspace.open` 调用与默认浏览器实际跳转 `http://localhost:{port}`（URL 构造已由测试钉住）；
  - 菜单栏图标 alert 态视觉：模板渲染下红色可能被系统抹平，已用形状差异（锚形 → 警示三角）保底，请实机确认辨识度；
  - 四区布局/聚合折叠展开/「隐藏其他」开关的实机观感（宽 620px 紧凑主窗）。
