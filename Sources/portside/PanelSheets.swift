import SwiftUI
import PortsideKit

/// 收编弹窗草稿（工单 05）：三字段预填 + 路径前缀。
/// 预填来源 = 行模型（名称=当前显示名/清洗名、启动命令=该进程 argv 原样、端口=当前端口），
/// 全部可改；取消（直接关弹窗）不产生任何定义。
struct AdoptDraft: Identifiable {
    let id = UUID()
    var name: String
    var command: String
    var port: String
    var pathPrefix: String

    /// 从行模型预填（argv 原样照搬，不做加工——spec §3：它怎么起的就怎么还给你）。
    init(from row: PanelRow) {
        name = row.displayName
        command = row.commandLine ?? ""
        port = row.primaryPort.map(String.init) ?? ""
        pathPrefix = ""
    }
}

/// 别名编辑草稿：改定义名称（即显示名别名槽位）与路径前缀。
struct EditDraft: Identifiable {
    /// 定义 id（保存时路由）。
    let id: String
    var name: String
    var pathPrefix: String

    init(from row: PanelRow) {
        id = row.definitionID ?? ""
        name = row.displayName
        pathPrefix = row.pathPrefix
    }
}

/// 收编弹窗（spec §3）：名称 / 启动命令 / 端口 三字段全部预填可改 + 路径前缀（默认空）。
struct AdoptSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String
    @State private var port: String
    @State private var pathPrefix: String
    /// 保存回调（PanelView 里转 `model.adoptService`）；取消 = 不回调，不产生定义。
    let onSave: (_ name: String, _ command: String, _ port: Int, _ pathPrefix: String) -> Void

    init(draft: AdoptDraft, onSave: @escaping (String, String, Int, String) -> Void) {
        _name = State(initialValue: draft.name)
        _command = State(initialValue: draft.command)
        _port = State(initialValue: draft.port)
        _pathPrefix = State(initialValue: draft.pathPrefix)
        self.onSave = onSave
    }

    private var portValue: Int? {
        Int(port.trimmingCharacters(in: .whitespaces))
    }

    /// 三要素齐备才可保存（端口必须是数字、命令非空）。
    private var canSave: Bool {
        portValue != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("收编服务").font(.headline)
            Text("补记启动命令后，该服务升级为托管：停止/重启/日志解锁。命令按该进程当前 argv 原样预填。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("名称", text: $name)
                TextField("启动命令", text: $command)
                TextField("端口", text: $port)
                TextField("路径前缀（可选，如 /swagger-ui）", text: $pathPrefix)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let portValue else { return }
                    onSave(name, command, portValue, pathPrefix)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// 别名/路径前缀编辑弹窗：改名即时生效（= 改定义名称）。
struct EditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var pathPrefix: String
    let onSave: (_ name: String, _ pathPrefix: String) -> Void

    init(draft: EditDraft, onSave: @escaping (String, String) -> Void) {
        _name = State(initialValue: draft.name)
        _pathPrefix = State(initialValue: draft.pathPrefix)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("编辑服务").font(.headline)
            Form {
                TextField("名称", text: $name)
                TextField("路径前缀（如 /swagger-ui）", text: $pathPrefix)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(name, pathPrefix)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
