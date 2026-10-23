# Portside · 发版验收清单

v1 发版（以及之后每次发版）前的唯一验收清单：spec 验收标准 1-10 逐条实测，结果与证据记在本页。
定位：把「低资源、可托付」从口号变成发版门槛——每条要么有机器证据（测试名），要么写清人工步骤；不凭印象放行。

## 维护

- **何时跑**：发新版本号前全跑；改扫描器/进程管理/日志管道后至少跑对应条目的机器项；机器项每次 `swift test` 全绿即是重跑。
- **怎么记**：文末「验收记录」追加一行（日期/范围/结果/备注）；未过项到 `.scratch/portside/<slug>/` 开工单再修，修完复跑。
- **怎么长**：自用撞到的新破绽、v1.x 新能力落地 → 追加新行（只增不删；过时的行划掉并注明日期）。
- **机器项怎么跑**：`swift test`（全套 200+ 用例，引用名见「证据」列）；条目 10 的实机对照另需 `PORTSIDE_SMOKE=1 swift test --filter ScannerSmokeTests`（默认跳过，真跑 lsof/netstat）。
- **环境**：机器项在本仓库 `swift test` 即可；人工项需要日常开发机 + 真实服务（Java fat jar、vite、nohup 起的进程、QQ/微信）。

## 验收表（spec 验收标准 1-10）

结果口径：✅ = 机器验证（本次发版已跑，测试名为证）；⏳ = 待人工（步骤见下节）；✅⏳ = 机器已验 + 仍需人工目测实机形态。

| # | 内容（spec 原文压缩） | 结果 | 证据 |
|---|---|---|---|
| 1 | 起 2 个 Java 服务（含 1 个 fat jar）+ 1 个 vite dev server，5 秒内全部出现、端口正确、分区正确 | ✅⏳ | 机器：`IdentificationTests.testJavaFatJar命令行清洗出版本尾巴后的名字`、`test默认识别器序列综合fixture`、`SectionAssignerTests.test同名不同端口各占一行不合并`、`test有定义的进我的服务优先于类型`、`PanelViewModelTests.test扫描识别分区串成四区行`（识别→分区→行全链路、端口与分区判定）。人工：真实进程 + 真面板的「5 秒内出现」目测（见下节步骤 A1） |
| 2 | `kill -9` 一个后端，10 秒内菜单栏图标变「有挂」 | ✅⏳ | 机器：判定口径 `MenuBarBadgeTests.test任一已知服务未在监听时为alert`、`test已知服务恢复监听后回到normal`、`test未识别端口的存活不影响汇总态`；**空闲档（面板关闭、扫描退避 30s）下 10 秒线由探活保证**（评审修复 F2）：`ProbeWiringTests.test面板关闭空闲档kill后10秒内图标变色恢复变回`（探活独立 5s 节奏发现挂掉/恢复，不依赖扫描轮）、`test连接拒绝翻托管行状态无响应不翻恢复翻回`（拒绝=挂、超时=无响应不误报）、`PortProbeTests.test按5秒节奏只探清单内端口`/`test无定义端口时不发起任何探测`（低资源红线）；活动档另有 `RefreshSchedulerTests.testBalanced活动期按5秒间隔刷新`。人工：真 kill 后图标变色时机目测（步骤 A2） |
| 3 | 收编一个 nohup 起的外部服务：弹窗三字段预填正确，保存后停止/重启/日志立即可用，服务行移入「我的服务」 | ✅⏳ | 机器：`DefinitionWiringTests.test收编后行立即迁移到我的服务不等下一轮扫描`（保存即迁移、免扫描）、`test托管运行中行停止重启动作走注入的控制器`（动作解锁）、`ServiceDefinitionCenterTests.test收编生成定义并落盘重启后仍在`（argv 原样保存）。人工：弹窗三字段预填值与真进程对照目测（步骤 A3） |
| 4 | 托管服务全量操作可用；重启 Portside，托管服务不死、自动认领回托管态、日志完整 | ✅⏳ | 机器：`DecouplingTests.test杀掉宿主整组后服务存活且日志继续落盘`（真进程等价「杀掉 Portside」）、`ReclaimTests.test首轮扫描后自动认领匹配实例`、`test认领实例标准落盘日志存在则直接用`、`test认领幂等同pid不降级亲生身份`。人工：真实 Portside 退出重开整流程目测（步骤 A4） |
| 5 | 外部日志三场景：nohup.out 命中、logs/app.log 命中、纯 stdout 未落盘 → 明示「未发现日志文件」 | ✅ | 机器全验：`LogLocatorTests.testlsof失败时目录惯例兜底命中nohupout`、`test目录兜底命中logs子目录最近修改`、`test外部fd扫描命中进程正在写的日志`、`test三步都落空返回未发现`、`LogViewModelTests.test未发现明示文案不启动tail`（三场景 + 明示不装死） |
| 6 | QQ/微信等聚合成单行折叠，「隐藏其他」开关生效，且数据不丢 | ✅⏳ | 机器：`EmptyAndExtremeStateTests.test38端口噪机聚合为每进程名单行不膨胀`（38 端口塌缩 2 行、明细齐全）、`test噪机重扫聚合行id稳定滚动不跳`、`PanelViewModelTests.test隐藏其他持久化且数据不丢`、`test聚合行默认折叠可展开收起`。人工：真 QQ/微信进程目测一次（步骤 A5） |
| 7 | fat jar `user-service-1.0.0-SNAPSHOT.jar` 显示为 `user-service` | ✅ | 机器全验：`IdentificationTests.testJavaFatJar命令行清洗出版本尾巴后的名字`、`test版本尾巴清洗规则表与清洗失败显原名`、`test显示名优先级别名大于清洗名大于未知端口`（不猜红线同验） |
| 8 | 空闲挂机 1 小时：常驻内存 < 80MB，CPU 平均 < 1% | ⏳ | 机器佐证低资源设计已验：`PanelViewModelTests.test面板可见快刷隐藏后退避`（隐藏不加速）、`RefreshSchedulerTests.test空闲超过阈值后退避到30秒`、`LogViewModelTests.test超长日志截断保尾部对齐行首`（日志内存上限）。1 小时实测只能人工：步骤 A6 |
| 9 | 重启一个 fork 了子进程的 Java 服务：无残留孤儿进程（ps 对照） | ✅⏳ | 机器：`ShellProcessControllerTests.test停止杀干净fork子进程无孤儿残留`、`test停止宽限期满仍有存活则SIGKILL补刀`、`test启动的进程在独立进程组`、`test无注册条目时按端口兜底停止`（真进程 + ps 断言）。人工：真 Java 服务（自身 fork 子进程）实机对照（步骤 A7） |
| 10 | 在日常开发机（macOS 26）上对照手工 `lsof -i -P -n` + netstat：扫描端口列表无缺失；人为制造 lsof 受限时 UI 出现明示 | ✅⏳ | 机器：`PORTSIDE_SMOKE=1 swift test --filter ScannerSmokeTests`——`test本机实扫与手工lsof对照无缺失`（2026-10-23 于 macOS 26 本机实跑通过）；`ScannerTests.testlsof受限时合并netstat补齐并标记partial`、`testlsof完全不可用时整体降级netstat`、`PanelViewModelTests.testpartial扫描时列表顶部明示`（明示链路）。人工：日常机复跑冒烟 + 步骤 A8。补记（2026-10-24 评审修复 F4）：数据源 v1 取 lsof+netstat 组合而非 spec 原文首选的 libproc——实测对照无缺失已达标，取舍记录见 [adr/0002](adr/0002-scan-via-lsof-netstat-composite.md) |

## 待人工项操作步骤

每项 2-5 分钟；全部只读观测，不改机器状态（除 A2/A7 的 kill/重启对象服务）。

### A1 · 真服务 5 秒内出现（#1）

1. 终端起 2 个 Java 服务（其一用 fat jar，如 `java -jar user-service-1.0.0-SNAPSHOT.jar`）+ 1 个 `npm run dev`（vite）。
2. `swift run portside` 打开 Portside，盯面板：5 秒内三行全部出现。
3. 核对：fat jar 行显示清洗名（不带版本尾巴）、端口与 `lsof -i -P -n` 一致、Java 在「后端」、vite 在「前端」。

### A2 · kill -9 后 10 秒内图标变挂（#2）

1. 先收编一个 Java 服务（或用已有定义），确认图标全绿。
2. `kill -9 <该服务pid>`，秒表计时：10 秒内菜单栏图标从锚形变红色警示三角。
3. 重启该服务，图标 30 秒内（空闲退避档）或打开面板后（活动档）回全绿。

### A3 · 收编弹窗预填对照（#3）

1. `nohup python3 -m http.server 8787 &` 起一个外部服务。
2. 面板「其他」区找到它 →「收编」→ 核对三字段预填：名称=显示名、启动命令=与 nohup 命令一致（argv 原样）、端口=8787。
3. 保存后该行立即移入「我的服务」并带「托管」标签；停止/重启按钮可用；点行日志视图打开（未落盘则明示，见 #5）。

### A4 · 重启 Portside 托管不死、自动认领（#4）

1. 用 Portside 启动（或收编后重启）一个托管服务，确认日志流有输出。
2. 完全退出 Portside（面板底栏「退出 Portside」）；确认服务进程仍存活（`ps`）。
3. 重新 `swift run portside`：面板打开几秒内该服务即在「我的服务」且为托管·运行中；点开日志，历史输出完整接上。

### A5 · 真 QQ/微信聚合目测（#6）

1. 登录 QQ 与微信（两者都会开大量本地端口）。
2. 面板「其他」区：各自一行「QQ（N 个端口）」「WeChat（M 个端口）」，默认折叠；展开明细逐行有端口。
3. 勾「隐藏其他」→ 其他区整区消失；取消勾选 → 原样回来（数据不丢）；关闭重开面板，开关状态保持。

### A6 · 挂机 1 小时资源实测（#8，硬指标）

1. 空载基线：打开活动监视器（Activity Monitor），筛 `portside`，记录内存（MB）。
2. 打开面板后收起，让机器闲置 1 小时（期间不点面板；中间可开一次面板看日志再收起）。
3. 结束时记录：内存 < 80MB 且 1 小时内无持续上涨趋势（泄漏）；CPU%（平均）< 1%，瞬时尖峰允许（扫描轮）。
4. 数值记入文末「验收记录」备注列。不达标即发版阻塞项。

### A7 · fork 子进程的 Java 服务重启无孤儿（#9）

1. 起一个会 fork 子进程的 Java 服务（典型：Spring Boot 内嵌 Tomcat 场景或任何 fork worker 的服务），经 Portside 托管。
2. 记录进程树：`ps -eo pid,ppid,pgid,command | grep -E "<主pid>|java"`。
3. 面板点「重启」→ 二次确认。等新实例监听后对照 ps：旧进程组的所有 pid（含 fork 出的子进程）全部消失，无 `ppid=1` 的孤儿。
4. 若服务自身换端口/多端口，Portside 按端口兜底停止的行为以不误杀为准（评审修复 F3 后机器已验：`ShellProcessControllerTests.test占用者与定义命令不匹配时兜底停止中止且不杀`、`test占用者命令行取不到时兜底停止拒绝`、`DefinitionMatcherTests.test占用者命令与定义一致才算匹配`）。

### A8 · 日常开发机扫描对照 + 受限明示（#10）

1. 日常开发机上跑 `PORTSIDE_SMOKE=1 swift test --filter ScannerSmokeTests`（真 lsof/netstat 对照，无缺失才过）。
2. 另开终端手工跑 `lsof -i -P -n | grep LISTEN`，随机抽 3 个端口在面板里能找到。
3. 人为制造 lsof 受限（如对本应可见的会话限制 / 或在受限账号下跑）→ 面板顶部出现橙色明示「lsof 受限：有端口仅经 netstat 补齐，清单可能不完整」，列表不空。
4. macOS 升级后重跑本项（lsof 政策随系统版本变）。

## 已知取舍

- **探活恒 5s，不随 Low Resource 档退避**（2026-10-24 评审收尾 G4）：spec 验收 #2 的 10 秒线无档位限定——面板关着（Low Resource 空闲档扫描 120s）时若探活同档退避，kill 后要等下一轮扫描才发现，验收即破。占用代价可控：只探已知定义端口（未识别端口不探，零连接轮空）、单端口 ~0.8s 短超时 connect、在途闸不叠加。三档「以占用为先」的口径经此评估后稀释接受。

## 验收记录

| 日期 | 范围 | 结果 | 备注 |
|---|---|---|---|
| 2026-10-23 | v1 收口：机器项全套（`swift test` 209 用例 0 失败，含 `PORTSIDE_SMOKE=1` 冒烟） | ✅ 机器项通过（待人工收尾） | 本机 macOS 26（Darwin 25.6.0/arm64）实跑 lsof 对照无缺失。人工项待跑：A1（真实 Java×2+vite）、A2（真 kill 图标时机）、A3（真 nohup 预填目测）、A4（实机退出重开认领）、A5（真 QQ/微信）、A6（1 小时挂机内存/CPU）、A7（真 fork 树 ps 对照）、A8（日常机复跑冒烟） |
| 2026-10-24 | 评审修复轮 F1-F10：`swift test` 227 用例 0 失败（基线 209 + 新增 18），3 连跑无 flaky | ✅ 机器项通过（待人工收尾同上） | F2 探活落地后 #2 的 10 秒线在空闲档由机器证据覆盖（ProbeWiringTests/PortProbeTests，见验收表 #2）；F3 停止安全阀与占用者解释（ShellProcessControllerTests/ManagedActionFlowTests，见 A7）；F4 数据源取舍见 adr/0002（验收表 #10 补记）；F1 外部行「打开」补齐（工单 04 验收项补勾） |
