# 07: 日志统一管道——托管 tail + 外部发现

**What to build:** 点任意服务行，同窗切到日志视图：托管服务 tail 自家落盘日志；外部服务走发现链——lsof 查该进程以写/追加模式打开的 .log/.out 文件 → 工作目录惯例兜底（nohup.out、logs/、log/ 取最近修改的一个）→ 都失败明示「外部启动，未发现日志文件」。命中则 tail 末尾 500 行并跟随；视图关闭即停止跟随。

**Blocked by:** 06

**Status:** done

- [x] 托管服务日志实时滚动（新写入 <1s 出现）；返回列表后停止跟随，无残留句柄
  - 真实时钟测试：新写入 <1s 出现（默认 0.5s 轮询）；lsof 实证 stop 后句柄关闭；VM `closeLog`/`panelDidDisappear` 停 tail
- [x] fd 扫描：`lsof -p <pid>` 输出 fixture 解析，只认写/追加模式打开的 .log/.out
  - `LsofFdParser`（`lsof -a -p <pid> -Fatn` 字段输出，与真机采样同构）：只认 `a=w/u` 模式的 .log/.out；REG 类型优先、多候选取最近修改（注入日期可测）
- [x] 外部三场景测试：nohup.out 命中 / logs/app.log 命中 / 纯 stdout 未落盘 → 明示文案，不装死
  - `LogLocator`（发现链：①fd 扫描 → ②目录惯例兜底 → ③`.notFound`），VM 层明示文案 = `LogLocator.externalLogNotFoundNotice`
- [x] 日志视图与列表同窗切换（形态 A），含返回按钮与当前服务名/端口头
  - `LogStreamView`：返回按钮 + 服务名/端口/托管标记头 + 三态（发现中/未发现明示/滚动日志区）；**滚动观感与同窗切换手感待人工确认（GUI 实机项）**
- [x] 跟随实现资源安全：切换服务/关窗后旧 tail 停止（句柄数测试或注入验证）
  - VM 注入验证：切换/返回/隐藏/过期发现竞速，旧 tail 恰好 stop 一次、同一时刻最多一个活跃；`LogTail.stop` 幂等
