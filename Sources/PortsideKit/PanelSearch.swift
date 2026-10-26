import Foundation

/// 端口搜索（GLOSSARY：端口搜索）的纯过滤函数：把「端口号 → 行」的匹配语义
/// 从 UI 剥离为可测纯函数。匹配规则以 spec（.scratch/port-search/spec.md 定稿
/// 决策 1–5）为唯一事实来源：只按端口、精确匹配；聚合行命中子端口时收窄子行；
/// 已停止定义行按定义端口参与匹配；查询为空（非搜索态）原样返回。
public enum PanelSearch {
    /// 按端口号过滤面板行。`port` 为 nil = 非搜索态，原样返回（不过滤）。
    public static func filtered(rows: [PanelRow], port: Int?) -> [PanelRow] {
        guard let port else { return rows }
        return rows.compactMap { row in
            guard row.isAggregated else { return row.ports.contains(port) ? row : nil }
            // 聚合行（spec 决策 5）：任一子行命中 → 保留标题行、子行收窄为命中者；
            // 自身字段（含端口事实）原样，不重写不猜。无命中 → 整行落榜。
            let matched = row.children.filter { $0.ports.contains(port) }
            guard !matched.isEmpty else { return nil }
            return PanelRow(
                id: row.id, section: row.section, isUp: row.isUp, isManaged: row.isManaged,
                definitionID: row.definitionID, displayName: row.displayName,
                typeLabel: row.typeLabel, ports: row.ports, uptimeText: row.uptimeText,
                commandLine: row.commandLine, pid: row.pid,
                workingDirectory: row.workingDirectory, pathPrefix: row.pathPrefix,
                children: matched
            )
        }
    }
}
