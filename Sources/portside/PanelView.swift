import SwiftUI
import PortsideKit

/// 紧凑主窗（面板，GLOSSARY）：四区列表 + partial 明示 + 「隐藏其他」开关。
/// 数据全部来自 PanelViewModel（PortsideKit），本文件只负责装配与样式——
/// 隐藏/折叠只影响渲染（视图层判断），模型层数据不丢。
struct PanelView: View {
    @ObservedObject var model: PanelViewModel

    var body: some View {
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

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 四区顺序以 PanelSections.all 为唯一来源；「隐藏其他」只影响渲染：
                    // 其他区数据仍在模型层，关掉开关即回来。
                    ForEach(PanelSections.all, id: \.kind) { section in
                        if !(section.kind == .other && model.isOtherHidden) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        // 面板可见性 ↔ 刷新活动：可见时记录活动（活动档快刷），隐藏后自然退避（低资源）。
        .onAppear { model.panelDidAppear() }
        .onDisappear { model.panelDidDisappear() }
    }

    /// 一个分区：标题行（名称 + 行数）+ 行列表或空状态文案。
    @ViewBuilder
    private func sectionBlock(_ section: PanelSection) -> some View {
        let rows = model.rows(in: section.kind)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.headline)
                Text("\(rows.count)")
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
            if model.isExpanded(row.id) {
                ForEach(row.children) { child in
                    serviceRow(child, indented: true)
                }
            }
        }
    }

    /// 单服务行：状态点 / 显示名 / 类型 / 端口 / 运行时长 / 打开。
    private func serviceRow(_ row: PanelRow, indented: Bool) -> some View {
        HStack(spacing: 6) {
            // 状态点：实心绿 = 监听中；空心灰 = 挂掉（已停止实例，托管定义落地后出现）。
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
            Text(row.typeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let port = row.primaryPort {
                Text(":\(port)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let uptime = row.uptimeText {
                Text(uptime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("运行时长（取自进程启动时间）")
            }
            // 「打开」：浏览器直达 http://localhost:{port}（spec §5）——UI 层一行胶水。
            if let url = row.openURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("在默认浏览器打开 http://localhost:\(row.primaryPort ?? 0)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}
