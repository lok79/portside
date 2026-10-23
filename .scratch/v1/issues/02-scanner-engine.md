# 02: 扫描引擎——端口↔进程枚举与刷新策略

**What to build:** 引擎在背后周期拿到本机监听 TCP 端口清单（端口、PID、进程名、命令行、工作目录），刷新三档可配、空闲自动退避；lsof 受限时降级组合数据源并标记缺失。从用户视角：app 开着时服务上下线能在数据层及时反映，且不空转烧 CPU。

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] 对 `lsof -iTCP -sTCP:LISTEN -P -n` 输出的 fixture 解析测试（覆盖 IPv6、`*:端口`、无权限行）
- [ ] 降级数据源：lsof 受限/不可用时用 netstat + ps 组合兜底，缺失字段有显式标记；macOS 15+ 收紧 lsof 的场景纳入测试
- [ ] 刷新三档 Realtime / Balanced（默认）/ Low Resource + 空闲退避；定时器用注入时钟，可测
- [ ] 集成冒烟（可跳过标记）：本机实测扫描结果与手工 `lsof -iTCP -sTCP:LISTEN -P -n` 对照无缺失
