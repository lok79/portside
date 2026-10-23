# 09: 低资源打磨与 v1 验收收口

**What to build:** 刷新三档设置入口、空态/错误态/极端数据打磨；按 spec 验收标准 1-10 逐条实测，结果记入 `portside/docs/acceptance.md`（仿 lurk 的发版前手工清单，以后每次发版过一遍）；README 起草（人味文案、一句话场景、截图占位）。

**Blocked by:** 07, 08

**Status:** done（GUI/实机/长时项待人工：acceptance.md A1-A8，机器项全过）

- [x] 设置区可切刷新三档（Realtime/Balanced/Low Resource），生效即时（模型层验证；实机点击随 acceptance A 项目测）
- [x] 空态（无服务/无定义）、错误态（扫描失败/启动失败）、极端数据（35+ 监听端口的全噪机）下 UI 不挤不崩（模型层钉子；UI 只装配）
- [x] spec 验收 1-10 逐条实测，结果与数值（含 Activity Monitor 内存/CPU）写入 docs/acceptance.md；未过项写明原因与去向（机器项已跑实引用测试名；1 小时挂机等长时项标 ⏳ 并写清步骤）
- [x] README：一句话定位、真实截图占位、构建/运行方式；文案人味、无期货功能
- [x] `swift build` / `swift test` 全绿收口（连跑 3 次：209 tests, 0 failures, 1 skipped）

## Comments

- 2026-10-23（agent）：完成，TDD 六个切片（三档设置 / 删除定义 / 空态与极端数据 / acceptance / README / 收口）均先红后绿、小步提交。
  - **刷新三档设置**：`KeyValueStore` 增字符串存取（UserDefaults 实现 + 测试内存替身）；`PanelViewModel.refreshMode` init 从持久层恢复（存档损坏回落默认 Balanced）、`setRefreshMode` 写穿持久层 + 送达 `RefreshScheduler.setMode`（在途轮不生效、下一轮起新档——调度器既有契约，虚拟时钟实测 t=10 切低资源后 t=15~35 无 tick、t=40 才有）；UI 为面板底栏三选一分段 Picker（实时/均衡/低资源）。
  - **删除定义入口**：`ServiceDefinitionCenter.remove`（落盘，只动定义不碰进程）；确认状态机加 `.delete`（复用工单 06 机制：确认前不删/取消不删/不自动删，弹窗解释写明不停任何进程）；已停止行垃圾桶入口；删除后行内状态清理、汇总态随之恢复 normal、面板免扫描重算。
  - **空态/错误态/极端数据**：模型层钉子——全空机器四区空 + 零误报；三定义全挂出全部已停止行 + alert；38 端口噪机（QQ 35 + WeChat 3）塌缩 2 行、端口升序、明细齐全；重扫聚合行 id 稳定（滚动不跳）；消失行展开记录清理（不无界增长）。扫描失败保留上次数据 + 顶部明示、启动失败行内状态（既有测试已在，未重复）。
  - **docs/acceptance.md**：spec 验收 1-10 逐条建表（编号/内容/结果/证据）+ 维护约定 + 待人工项操作步骤 A1-A8 + 验收记录。机器项 5 条全验（引用测试名；#10 另跑 `PORTSIDE_SMOKE=1` 本机实扫对照真 lsof 无缺失，macOS 26）；待人工 5 条（A1 真服务 5 秒出现、A2 真 kill 图标时机、A3 真收编预填、A4 实机退出重开认领、A5 真 QQ/微信、A6 挂机 1 小时内存 <80MB CPU <1%、A7 真 fork 树 ps 对照、A8 日常机复跑冒烟）。
  - **README**（portside/README.md）：一句话定位、实装能力清单（无期货，D-005）、构建运行、当前限制（未签名未公证未打包 .app、无开机自启、外部日志尽力发现）、v1.x 候选池（归因/MCP server）、截图占位。
  - **收口**：`swift build` + `swift test` 连跑 3 次全绿（209 tests, 0 failures, 1 skipped——skipped 即 PORTSIDE_SMOKE 门控冒烟，单独实跑已过）；`pgrep` 自查无 xctest/swift run 孤儿进程；零网络零遥测零第三方依赖未破。
