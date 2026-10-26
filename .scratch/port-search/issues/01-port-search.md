# 01 · 端口搜索：过滤纯函数 + ViewModel + 面板接线

Status: ready-for-human

Spec: [../spec.md](../spec.md)（定稿决策与验收标准的唯一来源）

## 切片说明

单票完成（轻路径）：PortsideKit 纯函数过滤 → ViewModel 状态组合 → PanelView UI 接线，TDD 推进。

- **纯函数（PortsideKit，主测试面）**：`(rows, query: Int?) → rows`——单服务行按唯一端口精确匹配；已停止定义行按定义端口参与匹配；聚合行任一子行命中则保留、children 只留命中子行；查询为 nil（空）时原样返回。
- **ViewModel**：searchQuery 数字规范化（非数字剔除、粘贴清洗、整数比较）、isSearching 派生、rows(in:) 组合过滤、「隐藏其他」搜索期失效、panelDidDisappear 清空搜索。
- **PanelView**：顶部常驻搜索框（扫描提示行之下、四区之上）；搜索态无匹配分区隐藏；全局空态「没有发现监听端口 N 的服务」；Cmd+F 聚焦、聚焦态 Esc 清空退出、清空 ×。

## 边界与红线对照

- 不触发新扫描（低资源）；搜索词不出进程（零遥测）。
- 外部服务一视同仁可搜，行内动作区在搜索态下行为不变。

## 验收

按 spec 验收标准 1–6；spec「关键假设与实测」两条接线假设的实测结果回填本文件 Comments。

## Comments

### 2026-10-26 · 实现与评审记录

- 实现：PanelSearch 纯函数（过滤语义 + 规范化共用规则）、PanelViewModel 搜索态（searchPort / applySearchQuery / clearSearch / 面板隐藏即清）、PanelView 接线（顶部常驻框、Cmd+F、聚焦态 Esc、分区可见性、全局空态、聚合行自动展开）。测试 8 例全绿；全量 238 例 0 失败（1 例既有 skip）。
- spec「关键假设与实测」回填：
  1. Cmd+F 经隐藏 Button + `.keyboardShortcut` 注册窗口——编译通过、无警告；**交互级实测待人工**（开发实例未启动：生产实例 `.build/release/portside` 在跑，避免双状态栏实例与共享持久层冲突）。
  2. 聚焦态 Esc 经 `.onExitCommand` 接管（不影响系统关窗）——同上，待人工。
- 待人工验收（验收 5 + 冒烟）：Cmd+F 聚焦；聚焦态 Esc 清空；重开面板搜索为空；起本地服务按端口搜到 → 行内日志/停止照常。
- 评审轮 1 修复：①前导零 bug（`prefix(5)` 先截断破坏决策 9，`0008080` 误查 80）→ 规范化改为「剔非数字 → 前导零归一 → 限长 5 位」，视图与模型共用 `PanelSearch.normalizedQueryText`，所见即所查，附带消除了双处重复清洗；②行重建搬 `PanelRow.withChildren`（与 withStatus 同住）；③ `rows(in:)` 重复过滤判不修——行数量级个位到低双位、微秒级开销，与低资源硬约束（扫描/轮询/内存）不同量纲，profiler 说事再收。
