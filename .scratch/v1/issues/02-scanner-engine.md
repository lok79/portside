# 02: 扫描引擎——端口↔进程枚举与刷新策略

**What to build:** 引擎在背后周期拿到本机监听 TCP 端口清单（端口、PID、进程名、命令行、工作目录），刷新三档可配、空闲自动退避；lsof 受限时降级组合数据源并标记缺失。从用户视角：app 开着时服务上下线能在数据层及时反映，且不空转烧 CPU。

**Blocked by:** 01

**Status:** done

- [x] 对 `lsof -iTCP -sTCP:LISTEN -P -n` 输出的 fixture 解析测试（覆盖 IPv6、`*:端口`、无权限行）
- [x] 降级数据源：lsof 受限/不可用时用 netstat + ps 组合兜底，缺失字段有显式标记；macOS 15+ 收紧 lsof 的场景纳入测试
- [x] 刷新三档 Realtime / Balanced（默认）/ Low Resource + 空闲退避；定时器用注入时钟，可测
- [x] 集成冒烟（可跳过标记）：本机实测扫描结果与手工 `lsof -iTCP -sTCP:LISTEN -P -n` 对照无缺失

## Comments

- 2026-10-23（agent）：完成。TDD 五个切片均先红后绿，`swift build` / `swift test` 全绿（25 tests, 1 skipped, 0 failures；skipped 项即默认关闭的集成冒烟）。
  - 接缝（PortsideKit 新增公共 API）：`PortScanner` 协议 + `ScanResult`/`ListeningService` 模型（`Sources/PortsideKit/ListeningService.swift`、`PortScanner.swift`）；`LsofScanner`（解析 `lsof -iTCP -sTCP:LISTEN -P -n`，从行尾固定列倒推，进程名不按空白切列，含空格/非 ASCII 不截断错位；无权限行不伪造服务）；`NetstatScanner`（`netstat -anv -p tcp` 兜底解析 `名字:pid`，恒标 partial）；`CompositeScanner`（引擎门面：lsof 抛错整体降级；lsof 成功仍用 netstat 交叉核对，缺口合并 + partial 明示）；`RefreshScheduler` + `RefreshMode` + `PortsideClock`/`SystemClock`（`RefreshScheduler.swift`）。
  - 命令行与工作目录采集：`ps -p <pids合并> -ww -o pid=,command=` 一次调用 + `lsof -a -p <pids> -d cwd -Fn` 一次调用（低资源硬约束）；采集不到落成 nil 显式标记（工单 07 依赖 cwd，已随扫描采集，含中文/空格路径 fixture）。ps 可执行名替换 lsof 9 字符截断列。
  - 刷新三档（spec §1 锚点：活动期 ~5s、空闲 ~30s）：Realtime 5s/5s（不退避）、Balanced 5s/30s（默认）、Low Resource 30s/120s；空闲阈值 120s 可配；活动由上层 `recordActivity()` 显式记录；tick 带调度截止点，注入 `PortsideClock`，测试用虚拟时钟不真睡。
  - macOS 15+ 收紧场景：本机（macOS 26.6）实测复现——端口 16067（AweSun）netstat 可见而 lsof 静默遗漏（exit 0 无告警）；组合扫描器经 netstat 交叉核对补齐并标 partial。此场景已落 fixture 测试。
  - 集成冒烟 `PORTSIDE_SMOKE=1` 开启，默认 CI 跳过；本机实跑通过（40 个监听端口对照无缺失）。
  - 零网络、零遥测、零第三方依赖，全程未出 portside/ 目录与工单文件。
