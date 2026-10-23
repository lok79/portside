import SwiftUI
import PortsideKit

/// 紧凑主窗（面板）：四区列表占位 + 空状态文案。
/// 数据全部来自 PortsideKit.PanelSections，本文件只负责装配与样式。
struct PanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(PanelSections.all.enumerated()), id: \.element.kind) { index, section in
                if index > 0 {
                    Divider()
                }
                SectionBlock(section: section)
            }

            Divider()
            HStack {
                Spacer()
                Button("退出 Portside") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一个分区：标题行 + 该区空状态文案。
private struct SectionBlock: View {
    let section: PanelSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(section.title)
                    .font(.headline)
                Text("0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(section.emptyStateMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
