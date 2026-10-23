# 06: 进程管理——启动/停止/重启与进程组

**What to build:** 「我的服务」里能启动/停止/重启：启动经用户登录 shell（继承 nvm 等环境，LocalPorts 教训）、输出直写落盘日志文件、独立进程组；停止对整组先 SIGTERM 超时再 SIGKILL；停止/重启前有二次确认（显示服务名与解释）；失败启动错误可见不崩 app。

**Blocked by:** 05

**Status:** done（4 项待人工实机确认，见 Comments）

- [x] 启动 shell 命令服务：进程进独立组，落盘日志文件出现且持续写入（脚本循环输出验证）
- [x] 启动环境继承登录 shell：测试脚本里 `echo $PATH`/nvm 场景可用
- [x] 停止：SIGTERM → 超时 → SIGKILL 整组；用 fork 子进程的测试脚本验证无孤儿残留（ps 对照）
- [x] 重启 = 停止 + 启动，UI 状态按 已运行→已停止→运行中 迁移
- [x] 停止/重启前确认弹窗：显示服务名/端口与动作解释
- [x] 启动失败（命令不存在/立即退出）：错误信息在行内可见，app 不崩

## Comments

- 2026-10-23（agent）：完成。Kit 新增 `ShellProcessController`（ProcessController 真实现）：**启动**经登录 shell（`$SHELL -l -c "<命令>"`，shell 路径与环境可注入）；进程组建组选 **posix_spawn + `POSIX_SPAWN_SETPGROUP`（pgroup=0，子进程即新组领袖）**——取舍：macOS 不自带 `setsid`（违反零依赖）、Foundation `Process` 无 setpgid 挂钩（子进程留 app 自己组，`kill -pgid` 等于自杀）、`sh -c 'exec …'` 只替换不建组；posix_spawn 内核侧原子建组无竞态。**落盘通道**（adr/0001）：stdout/stderr 经 spawn file actions 直写 `~/Library/Application Support/Portside/logs/<定义id>.log`（追加，不毁历史），句柄由子进程持有——Portside 死了日志继续写；stdin 接 /dev/null；`CLOEXEC_DEFAULT` 不漏宿主描述符。**停止**：`kill -pgid` 整组 SIGTERM → 宽限期（默认 8s 可配，注入时钟单次挂起与退出信号竞速，无忙等轮询）→ 存活则 SIGKILL 补刀；无注册条目（收编的外部服务/重启后未认领）按定义端口兜底（lsof 找占用者逐个发信号，占用者与 Portside 同组时只发该 pid 绝不发组信号）。**退出感知**：后台 reaper 阻塞 `waitpid`（恰好收尸一次防僵尸）；注册表内存态（pid/pgid，`isRunning`/`runningProcessID`/`runningProcessGroupID` 查询面），认领归 08。**重启 = stop + start**。**启动失败**：秒退（判定窗默认 2s 可配）抛 `ProcessStartError.exitedImmediately(退出码, 日志末尾)`，行内文案含原因与日志末尾，不崩 app。`PanelViewModel`：`requestStopService`/`requestRestartService` → `pendingConfirmation`（服务名/端口/解释，Identifiable）→ `confirmPendingManagedAction` 才送达控制器（钉住"确认前不杀、确认后才杀、取消不杀"）；`startService` 失败写 `managedStatusMessages` 行内状态、成功清除；动作后 `refreshOnce` 立即反映。`production()` 装配注入真实现。UI：`ManagedActionSheet` 确认弹窗（sheet(item:) 派生 binding，关弹窗=取消）；行内红色错误文案；停止/重启按钮改走确认流。三个测试实证修复的产品级 bug：① **spawn 线程的阻塞信号掩码跨 exec 继承**（Swift 并发池/Dispatch 线程阻塞信号）——不清零子进程的 SIGTERM 永远 pending、停止永远杀不死，用 `POSIX_SPAWN_SETSIGMASK` 空掩码修复；② `logTail` 小文件 UInt64 下溢（SIGTRAP 崩溃）；③ `logTail` seekToEnd 后未定位游标读到空。TDD 七切片均先红后绿；async teardown 在 @MainActor 测试宿主会自锁（XCTWaiter 同步等 vs 任务要主 actor）——teardown 一律同步杀（`killAllForTesting`，SIGKILL 终局不等收尸）。`swift test` 全绿（138 tests, 0 failures），连跑 3 次 + 评审修补后 1 次共 4 轮无 flaky；测试脚本全放临时目录、tearDown 同步必杀兜底、所有 await 有界、每轮结束 ps 对照无残留进程。
- 待人工确认（无 GUI 环境）：
  - 确认弹窗（ManagedActionSheet）在 MenuBarExtra 面板里的实机呈现与文案观感（确认状态机已由测试钉住：确认前不杀/确认后才杀/取消不杀）；
  - 行内启动失败错误（红色小字）的实机视觉与截断效果（文案内容已由测试钉住）；
  - 真实 nvm 场景：测试以注入 HOME + `.zprofile` 钉住「登录 shell 读 profile」机制本身，用户真机 nvm/node 继承待实机走一遍；
  - 真实 Java fat jar 的 fork 子进程停止（测试用 sh fork 两个 sleep 验证整组全灭，JVM 实际行为待实机 ps 对照）。
- 备注：托管服务的状态迁移（已运行→已停止→运行中）以扫描轮为准（active 档 5s 内反映）；`isRunning`/`runningProcessGroupID` 查询面已就位，供工单 08 认领复用；日志查看（tail 落盘文件）归工单 07。
