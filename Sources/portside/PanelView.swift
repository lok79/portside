import SwiftUI
import PortsideKit

/// 紧凑主窗（面板，GLOSSARY）：四区列表 + 端口搜索（工单 13）+ partial 明示 +
/// 「隐藏其他」开关 +
/// 收编/托管动作（工单 05：外部行「收编」入口；托管行 启动/停止/重启/日志/编辑）。
/// 数据全部来自 PanelViewModel（PortsideKit），本文件只负责装配与样式——
/// 隐藏/折叠只影响渲染（视图层判断），模型层数据不丢。
struct PanelView: View {
    @ObservedObject var model: PanelViewModel
    /// 收编弹窗（非 nil 即弹出）；取消 = 置 nil，不产生定义。
    @State private var adoptDraft: AdoptDraft?
    /// 别名/路径前缀编辑弹窗。
    @State private var editDraft: EditDraft?
    /// 端口搜索框原文（工单 13，渲染态；规范化事实在 model.searchPort）。
    @State private var searchText = ""
    /// Cmd+F 聚焦目标（spec 决策 7）。
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let context = model.logContext {
                // 日志视图（工单 07，形态 A）：与列表同窗切换，无独立浮动小窗。
                LogStreamView(
                    context: context,
                    status: model.logStatus,
                    text: model.logText
                ) {
                    model.closeLog()
                }
            } else {
                listContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 收编 / 编辑弹窗（工单 05）：保存走 ViewModel（立即重算），取消仅关弹窗。
        .sheet(item: $adoptDraft) { draft in
            AdoptSheet(draft: draft) { name, command, port, prefix in
                Task { await model.adoptService(
                    name: name, commandLine: command, port: port, pathPrefix: prefix
                ) }
            }
        }
        .sheet(item: $editDraft) { draft in
            EditSheet(draft: draft) { name, prefix in
                Task { await model.editDefinition(id: draft.id, name: name, pathPrefix: prefix) }
            }
        }
        // 危险动作确认弹窗（工单 06）：binding 派生自 ViewModel 状态——
        // 关弹窗（Esc/点外面）= binding 置 nil = 取消，不杀；确认按钮显式送达。
        .sheet(item: Binding(
            get: { model.pendingConfirmation },
            set: { newValue in
                if newValue == nil { model.cancelPendingManagedAction() }
            }
        )) { confirmation in
            ManagedActionSheet(confirmation: confirmation) {
                Task { await model.confirmPendingManagedAction() }
            }
        }
        // 面板可见性 ↔ 刷新活动：可见时记录活动（活动档快刷），隐藏后自然退避（低资源）。
        // 隐藏同时经 model.panelDidDisappear() 停日志 tail（工单 07：面板隐藏即停）。
        .onAppear {
            // 重开面板 = 干净列表（spec 决策 8）：搜索原文是视图层渲染态，重开清一次。
            searchText = ""
            model.panelDidAppear()
        }
        .onDisappear { model.panelDidDisappear() }
    }

    /// 列表形态（日志视图关闭时的主内容）：partial 明示 + 四区列表 + 底栏。
    private var listContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = model.scanNotice {
                // spec §1：清单可能不完整时 UI 明示（列表顶部一行）。
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(notice)
                        .multilineTextAlignment(.leading)
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }

            // 端口搜索（工单 13，spec 决策 6）：列表顶部常驻，通知行之下、四区之上。
            searchField
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 全局空态（spec 决策 3）：搜索态且各分区皆空 → 一句明示，
                    // 不空屏不装死；措辞限定「没有发现」，不承诺「不存在」。
                    if model.isSearching, !hasVisibleRows, let port = model.searchPort {
                        Text(verbatim: "没有发现监听端口 \(port) 的服务")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                    // 四区顺序以 PanelSections.all 为唯一来源；「隐藏其他」只影响渲染：
                    // 其他区数据仍在模型层，关掉开关即回来。搜索态（工单 13）下：
                    // 「隐藏其他」暂不生效（决策 10），无匹配分区整个隐藏（决策 3）。
                    ForEach(PanelSections.all, id: \.kind) { section in
                        if sectionVisible(section) {
                            sectionBlock(section)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Toggle("隐藏其他", isOn: $model.isOtherHidden)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                // 刷新三档设置区（工单 09，spec §1）：主窗内三选一，切换即时生效（下一轮起用新档），
                // 持久化（KeyValueStore）。档位语义见 RefreshMode——实时：5s 常驻不退避；
                // 均衡：活动 5s / 空闲 30s；低资源：30s / 120s。
                Text("刷新")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("刷新档位", selection: Binding(
                    get: { model.refreshMode },
                    set: { model.setRefreshMode($0) }
                )) {
                    Text("实时").tag(RefreshMode.realtime)
                    Text("均衡").tag(RefreshMode.balanced)
                    Text("低资源").tag(RefreshMode.lowResource)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                .help("扫描频率：实时 5s 常驻；均衡 活动 5s / 空闲 30s；低资源 30s / 120s")
                Button("退出 Portside") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// 分区可见性：搜索态 = 有匹配才显（「隐藏其他」暂不生效，spec 决策 10）；
    /// 非搜索态 = 除「隐藏其他」外全显（现行为不变）。
    private func sectionVisible(_ section: PanelSection) -> Bool {
        if model.isSearching {
            return !model.rows(in: section.kind).isEmpty
        }
        return !(section.kind == .other && model.isOtherHidden)
    }

    /// 搜索态下是否有任一匹配行（全局空态判定用）。
    private var hasVisibleRows: Bool {
        ServiceSectionKind.allCases.contains { !model.rows(in: $0).isEmpty }
    }

    /// 搜索框（spec 决策 6–7、9）：放大镜 + 数字输入 + 清空 ×；Cmd+F 聚焦、
    /// 聚焦态 Esc 清空退出；未聚焦时 Esc 不接管（onExitCommand 仅聚焦态触发，
    /// 系统关窗行为不受影响）。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("搜端口号", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onChange(of: searchText) { _, newValue in
                    // 输入层只放行数字（决策 9），规则与模型共用（所见即所查）。
                    let cleaned = PanelSearch.normalizedQueryText(newValue)
                    if cleaned != newValue { searchText = cleaned }
                    model.applySearchQuery(cleaned)
                }
                .onExitCommand {
                    if !searchText.isEmpty {
                        searchText = ""
                        model.clearSearch()
                    }
                    searchFieldFocused = false
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    model.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
            // Cmd+F 聚焦（决策 7）：零尺寸隐藏按钮把快捷键注册进窗口。
            Button("聚焦搜索") { searchFieldFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// 一个分区：标题行（名称 + 行数）+ 行列表或空状态文案。
    @ViewBuilder
    private func sectionBlock(_ section: PanelSection) -> some View {
        let rows = model.rows(in: section.kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.headline)
                Text(verbatim: "\(rows.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            if rows.isEmpty {
                Text(section.emptyStateMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
            } else {
                ForEach(rows) { row in
                    rowBlock(row)
                }
            }
        }
        .padding(.vertical, 10)
        Divider()
    }

    /// 一行：聚合行（可展开）或单服务行（状态点/名称/类型/端口/运行时长/打开）。
    @ViewBuilder
    private func rowBlock(_ row: PanelRow) -> some View {
        if row.isAggregated {
            aggregatedRow(row)
        } else {
            serviceRow(row, indented: false)
        }
    }

    /// 「其他」区聚合行：「QQ（5 个端口）」默认折叠，点开见明细（spec §2）。
    private func aggregatedRow(_ row: PanelRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.toggleExpanded(row.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.isExpanded(row.id) ? 90 : 0))
                    Text(row.displayName)
                        .font(.callout)
                    Spacer()
                    Text("未识别")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .rowHoverHighlight()
            // 搜索态下聚合行自动展开（spec 决策 5）：children 已被过滤收窄为命中者。
            if model.isExpanded(row.id) || model.isSearching {
                ForEach(row.children) { child in
                    serviceRow(child, indented: true)
                }
            }
        }
    }

    /// 单服务行：状态点 / 显示名 / 托管标签 / 类型 / 端口 / 运行时长 / 动作区
    /// （+ 行内状态：启动失败等错误信息，工单 06——可见不装死）。
    /// 点行任意空白处 = 切日志视图（工单 07：点任意服务行看日志，托管与外部统一）。
    private func serviceRow(_ row: PanelRow, indented: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // 状态点：实心绿 = 监听中；空心灰 = 挂掉（托管·已停止，工单 05 起）。
                Image(systemName: row.isUp ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(row.isUp ? Color.green : Color.gray)
                if indented {
                    Color.clear.frame(width: 8)
                }
                Text(row.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .help(row.displayName)
                if row.isManaged {
                    Text("托管")
                        .font(.caption2)
                        .foregroundStyle(.teal)
                        .help("有服务定义：停止/重启/日志全量可用")
                }
                Text(row.typeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let port = row.primaryPort {
                    // verbatim（工单 11）：字面量会进 LocalizedStringKey，整数插值
                    // 按 locale 加千分位（实机显示 :23,030）；端口是原始数字，不走本地化。
                    Text(verbatim: ":\(port)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let uptime = row.uptimeText {
                    Text(uptime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("运行时长（取自进程启动时间）")
                }
                actions(row)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .rowHoverHighlight()
            .contentShape(Rectangle())
            .onTapGesture {
                model.openLog(rowID: row.id)
            }
            .help("点按查看日志流")
            if let id = row.definitionID, let message = model.statusMessage(forDefinitionID: id) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, indented ? 32 : 16)
                    .padding(.trailing, 16)
                    .padding(.bottom, 2)
            }
        }
    }

    /// 行尾动作区（工单 05/06/07）：托管行全量动作——停止/重启经确认流（工单 06，
    /// 确认前不杀）；启动直达；日志 = 同窗日志视图（工单 07）。外部行降级形态
    /// （spec §4）——停止/重启灰置 + 「收编」入口；日志尽力而为（发现链，工单 07）。
    @ViewBuilder
    private func actions(_ row: PanelRow) -> some View {
        if row.isManaged {
            if row.isUp {
                iconButton("stop.fill", "停止") {
                    if let id = row.definitionID { model.requestStopService(id) }
                }
                iconButton("arrow.clockwise", "重启") {
                    if let id = row.definitionID { model.requestRestartService(id) }
                }
            } else {
                iconButton("play.fill", "启动") {
                    if let id = row.definitionID { Task { await model.startService(id) } }
                }
            }
            iconButton("doc.text", "日志流") {
                model.openLog(rowID: row.id)
            }
            iconButton("pencil", "改名 / 路径前缀") {
                editDraft = EditDraft(from: row)
            }
            if !row.isUp, let id = row.definitionID {
                // 删除服务定义（工单 09）：定义的服务永久消失后的清理入口，
                // 带确认（不自动删）；只删定义不碰进程。
                iconButton("trash", "删除服务定义") {
                    model.requestDeleteDefinition(id)
                }
            }
            if row.isUp, let url = row.openURL {
                openButton(url, port: row.primaryPort ?? 0)
            }
        } else if !row.isAggregated {
            // 外部服务降级形态：停止/重启灰置（能力以定义为准，收编后解锁）+
            // 日志（尽力发现）+「收编」入口 +「打开」（spec §5 浏览器打开不限托管）。
            iconButton("stop.fill", "外部服务：收编后可用") {}
                .disabled(true)
            iconButton("arrow.clockwise", "外部服务：收编后可用") {}
                .disabled(true)
            iconButton("doc.text", "日志流（尽力发现）") {
                model.openLog(rowID: row.id)
            }
            Button("收编") {
                adoptDraft = AdoptDraft(from: row)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(row.commandLine == nil)
            .help(row.commandLine == nil
                  ? "扫描受限：未取得启动命令，暂无法收编"
                  : "补记启动命令，升级为托管服务")
            .buttonHoverHighlight()
            if let url = row.openURL {
                openButton(url, port: row.primaryPort ?? 0)
            }
        }
    }

    /// 图标小按钮（plain 风格，悬停提示；hover 圆角底衬见 HoverHighlight，工单 11）。
    private func iconButton(
        _ systemImage: String, _ help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 14)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .buttonHoverHighlight()
    }

    /// 「打开」：浏览器直达 http://localhost:{port}{路径前缀}（spec §5）。
    private func openButton(_ url: URL, port: Int) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Image(systemName: "arrow.up.forward")
                .frame(width: 14)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        // verbatim（工单 11）：tooltip 里的端口同样不吃本地化千分位。
        .help(Text(verbatim: "在默认浏览器打开 http://localhost:\(port)\(url.path)"))
        .buttonHoverHighlight()
    }
}

/// hover 高亮（工单 11，纯 View 层）：悬停时在内容底下垫圆角浅色底衬，
/// 移开即恢复；底衬用 `Color.primary` 按透明度调，深浅色模式都可见。
/// `respectEnabled` = 跟随禁用态（按钮惯例：禁用 hover 不高亮）；行高亮传 false。
private struct HoverHighlight<Content: View>: View {
    let cornerRadius: CGFloat
    let opacity: Double
    let respectEnabled: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.primary.opacity(
                        isHovered && (!respectEnabled || isEnabled) ? opacity : 0
                    ))
            )
            .onHover { isHovered = $0 }
    }
}

private extension View {
    /// 行内按钮 hover 底衬（禁用态不高亮）。
    func buttonHoverHighlight() -> some View {
        HoverHighlight(cornerRadius: 4, opacity: 0.08, respectEnabled: true) { self }
    }

    /// 整行 hover 微亮（聚合行头同样适用）。
    func rowHoverHighlight() -> some View {
        HoverHighlight(cornerRadius: 6, opacity: 0.04, respectEnabled: false) { self }
    }
}
