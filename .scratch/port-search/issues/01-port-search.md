# 01 · 端口搜索：过滤纯函数 + ViewModel + 面板接线

Status: ready-for-agent

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
