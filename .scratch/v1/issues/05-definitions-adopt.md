# 05: 服务定义持久化与收编

**What to build:** 点外部服务行的「收编」，弹三字段预填表单（名称=清洗识别名、启动命令=该进程当前 argv 原样、端口=当前端口），可改可取消；保存后生成服务定义，服务移入「我的服务」并升级托管标签。定义持久化到应用容器（JSON），重启 app 后仍在（含已停止态与「启动」按钮）。别名可编辑；定义含浏览器打开的路径前缀字段（默认空）。

**Blocked by:** 04

**Status:** done（4 项待人工实机确认，见 Comments）

- [x] 收编弹窗三字段预填正确（argv 原样）、可改、取消不产生定义
- [x] 保存后：服务从后端/前端移入「我的服务」，显示托管标签；停止/重启/日志按钮解锁态变化
- [x] 定义 JSON 落盘；杀掉 app 重开后「我的服务」仍在（运行中的回运行态、已死回已停止态展示，认领逻辑归 08）
- [x] 别名编辑即时改显示名；路径前缀影响「打开」URL
- [x] JSON 编码兼容与损坏文件降级（不崩、可重建）测试

## Comments

- 2026-10-23（agent）：完成。Kit 新增：`ServiceDefinition`（id/名称=别名槽位/启动命令 argv 原样/端口/路径前缀/创建时间，Codable；含路径前缀规范化与 openURL 拼接）；`DefinitionStore`（JSON 全量落盘 `~/Library/Application Support/Portside/definitions.json`，路径与文件 IO 双注入，原子写，损坏降级为空集合并归档 `definitions.json.corrupt-<时间戳>` 副本（重名追加序号绝不覆盖）、可重建、不崩）；`DefinitionMatcher`（端口 + 规范化命令（去首尾/多空白折叠）匹配；实例命令行缺失一律不匹配——宁可漏认不误认（ADR/0001）；`isRunning` 反向判定留作工单 08 认领复用的干净接缝）；`ServiceDefinitionCenter`（定义中枢：收编=唯一产生入口，同端口同命令重复收编更新不重复；改名/路径前缀编辑不动命令与端口；`hasDefinition`/`alias`/`knownDefinitions` 三查询面分别接 SectionAssigner/DisplayNameResolver/MenuBarBadge）；`ProcessController` 协议桩（start/stop/restart，本票只送达动作，工单 06 实装）。既有接缝按 04 预留替换注入：`PanelViewModel` 增 `definitions`/`processController` 注入，管线重构为「扫描→缓存 lastScan→recompute」，收编/编辑走 recompute **免扫描立即重算**；有定义无匹配实例 → 托管·已停止行（isUp=false、「已停止」、端口升序）；`PanelRow` 增 `isManaged`/`definitionID`/`commandLine`/`pathPrefix`，`PanelRowFactory` 增 `stoppedRow`，openURL 拼路径前缀。UI 装配：`PanelSheets`（收编弹窗三字段预填（名称=显示名/命令=argv 原样/端口）+ 路径前缀、编辑弹窗；取消=不回调不产生定义）+ `PanelView`（外部行灰置按钮 + 「收编」入口（命令行缺失时禁用并明示，不猜）；托管行 启动/停止/重启/日志/编辑/打开，「托管」标签）。TDD 六切片均先红后绿；`swift build` 0 warning、`swift test` 全绿（118 tests, 0 failures, 1 skipped；`PORTSIDE_SMOKE=1` 下 118 全过）。
- 待人工确认（无 GUI 环境）：
  - 收编/编辑弹窗在 MenuBarExtra（.window 样式）里的实机呈现与表单观感（预填数据流已由测试钉住：argv 原样、可改、取消不产生定义）；
  - 「托管」标签 / 外部行灰置按钮 / 已停止行（空心点 +「已停止」）的实机视觉与辨识度；
  - 杀掉 app 重开后「我的服务」仍在、运行中回运行态/已死回已停止态（落盘与重载逻辑已由临时目录测试钉住，真机流程待走一遍）；
  - 「打开」带路径前缀（如 `/swagger-ui`）的实际浏览器跳转。
- 备注：托管行的停止/重启/日志按钮已解锁，但动作送达的是 `ProcessController` 桩与日志桩——无实际进程效果，工单 06/07 实装（验收第 3 条的「立即可用」以 06/07 合入为准）。
