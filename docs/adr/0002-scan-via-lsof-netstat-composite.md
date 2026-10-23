# 扫描经 lsof+netstat 组合而非 libproc

spec 技术要点写「端口↔进程：libproc（proc_pidinfo）优先，lsof 与 netstat 组合兜底」。v1 实测后决定：**扫描直接以 `lsof -iTCP -sTCP:LISTEN -P -n` 为主路径、netstat 交叉核对补缺的组合实现**（CompositeScanner），不引入 libproc。

status: accepted

## Considered Options

- **A 按 spec 字面先做 libproc（proc_pidinfo）**：拒绝——libproc 是私有 C 接口，互操作（不透明结构体、缓冲区约定、跨 macOS 版本行为差异）复杂度显著；且实测（2026-10-23，macOS 26 / Darwin 25.6.0 arm64）组合方案与手工 `lsof -i -P -n` + netstat 对照无缺失，已达 spec 验收 #10 的实际门槛（`PORTSIDE_SMOKE=1` 冒烟通过）。
- **B lsof 单一数据源**：拒绝——macOS 15+ 收紧 lsof 对他人/root 套接字的访问后会静默漏行（实测复现）；netstat 交叉核对补齐缺口并标 partial，UI 明示「清单可能不完整」。

## Consequences

- 数据源组合（lsof 主路径 + netstat 降级/补齐）封装在 CompositeScanner 一处；未来若要换 libproc（或任何新数据源），CompositeScanner 是唯一改点——扫描协议（PortScanner）与下游识别/分区/行管线零改动。
- `-P -n` 必带的 spec 约束不变（否则 DNS/端口名反解慢到不可用）。
- 低资源红线不受影响：组合只在每轮扫描多一次 netstat 子进程调用，节奏仍由刷新档位约束。
