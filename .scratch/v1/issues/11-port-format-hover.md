# 11: 实机反馈修复——端口千分位逗号 + 行内按钮 hover

**What to build:** 两处实机反馈修复：① 端口显示 `:23,030` 的千分位逗号消失（根因：`Text(":\(port)")` 字面量被 SwiftUI 当本地化键，整数插值按中文 locale 加了分组符；改 `Text(verbatim:)`）；② 行内图标按钮与行本身获得 macOS 惯例的 hover 反馈（用户实机确认缺失）。

**Blocked by:** None (can start immediately)

**Status:** done

- [x] 两处端口文本改 `Text(verbatim:)`：主行 chip（PanelView.swift ~L221）与聚合明细行（~L222）；全文件排查其他 `Text` 字面量里的整数/数值插值一并处理（uptime 等已构字符串不动）
- [x] 行内图标按钮（打开/日志/重启/停止/收编/删除/垃圾桶）hover 时显示圆角浅色底衬（`Color.primary.opacity(~0.08)`），禁用态 hover 不高亮
- [x] 行整体 hover 微亮（`Color.primary.opacity(~0.04)` 圆角背景），移开恢复；聚合行头部同样生效
- [x] 纯 View 层改动，`swift build` + `swift test` 连跑 3 次全绿（230 基线不破）
- [x] 实机观感（hover 手感、底衬深浅）标待人工确认（见 Comments ④）

**Comments:**
- 2026-10-24 agent：① 工单点名的"两处"实为一处——聚合明细行经 `serviceRow(child, indented: true)` 复用主行的同一个 `Text(":\(port)")`，改一处即两处生效。② 全文件排查另发现同类插值 3 处，一并 verbatim：分区标题行数 `Text("\(rows.count)")`、「打开」tooltip 的 `localhost:\(port)`（改 `.help(Text(verbatim:))`）、LogStreamView.swift 头部端口 `Text(":\(port)")`（日志视图同款 bug，实机同样会显示 `:23,030`）。Kit 预构造 String（displayName / uptimeText / notice 等）走 String 重载，不受影响，未动。③ hover 走统一 `HoverHighlight` 修饰器（本文件私有）：按钮底衬 `Color.primary.opacity(0.08)` 圆角 4，行微亮 `0.04` 圆角 6，底衬用 primary 调透明度保证深浅色模式可见；禁用态经 `@Environment(\.isEnabled)` 门控不高亮（外部行灰置的停止/重启、未收编的「收编」均覆盖）；`.help` tooltip 不受影响。「收编」文本按钮同款底衬。④ **待人工确认**：hover 手感与底衬深浅（0.08 / 0.04 为起点值，实机过亮或过暗直接调这两个数）；图标按钮命中区从 14pt 加宽到 20pt（padding 3/2，顺手改善可点性），若嫌占宽可回调。
