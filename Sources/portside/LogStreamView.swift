import SwiftUI
import PortsideKit

/// 日志视图（工单 07，spec 形态 A：与列表同窗切换，无独立浮动小窗）。
/// 头部：返回按钮 + 服务名/端口/托管标记；主体按状态三态——
/// 发现中（短暂）/ 未发现明示行（spec §6 ③：不装死）/ 滚动日志区（tail 内容）。
/// 返回 = `model.closeLog()`（停 tail + 退出视图）；面板隐藏同款（panelDidDisappear）。
struct LogStreamView: View {
    let context: LogContext
    let status: LogStreamStatus
    let text: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch status {
            case .locating:
                locating
            case .notFound(let message):
                notFound(message)
            case .found:
                logSurface
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 头部：返回 + 服务名/端口/托管标记（工单验收：含返回按钮与当前服务名/端口头）。
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                onClose()
            } label: {
                Label("返回列表", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .help("返回服务列表（停止日志跟随）")
            Text(context.serviceName)
                .font(.headline)
                .lineLimit(1)
                .help(context.serviceName)
            if context.isManaged {
                Text("托管")
                    .font(.caption2)
                    .foregroundStyle(.teal)
                    .help("Portside 落盘通道日志")
            }
            if let port = context.port {
                Text(":\(port)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 发现中（发现链 = lsof 一次 + 目录兜底，通常一闪而过）。
    private var locating: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("正在发现日志文件…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// 未发现明示行（GLOSSARY：外部服务——stdout 在启动那一刻流向了别处；收编后解锁落盘日志）。
    private func notFound(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
            }
            Text("该服务由外部启动，未找到它正在写的日志文件。收编后由 Portside 接管启动，日志即刻全量可用。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 滚动日志区：等宽小字 + 自动滚到底部（新写入可见，滚动观感待人工确认）。
    private var logSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "（暂无输出，等待新写入…）" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear
                    .frame(height: 1)
                    .id("log-bottom")
            }
            .onChange(of: text) { _, _ in
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("log-bottom", anchor: .bottom)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
