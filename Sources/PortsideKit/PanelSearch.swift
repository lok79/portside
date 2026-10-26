import Foundation

/// 端口搜索（GLOSSARY：端口搜索）的纯函数面：把「端口号 → 行」的匹配语义与
/// 「输入原文 → 规范化查询」从 UI 剥离为可测纯函数。规则以 spec
/// （.scratch/port-search/spec.md 定稿决策 1–5、9）为唯一事实来源。
public enum PanelSearch {
    /// 输入规范化（spec 决策 9）：剔非 ASCII 数字 → 前导零归一（决策 9「前导零
    /// 无害」）→ 限长 5 位（TCP 端口 ≤65535，6 位起必为不可能端口；粘贴超长就地
    /// 截断，顺带杜绝整数溢出的歧义分支）。视图显示与模型查询共用本函数，
    /// 保证所见即所查。空串 = 非搜索态；全零归一为 "0"。
    public static func normalizedQueryText(_ raw: String) -> String {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        let trimmed = digits.drop { $0 == "0" }
        if trimmed.isEmpty { return digits.isEmpty ? "" : "0" }
        return String(trimmed.prefix(5))
    }

    /// 按端口号过滤面板行。`port` 为 nil = 非搜索态，原样返回（不过滤）。
    public static func filtered(rows: [PanelRow], port: Int?) -> [PanelRow] {
        guard let port else { return rows }
        return rows.compactMap { row in
            guard row.isAggregated else { return row.ports.contains(port) ? row : nil }
            // 聚合行（spec 决策 5）：任一子行命中 → 保留标题行、子行收窄为命中者；
            // 自身字段（含端口事实）原样，不重写不猜。无命中 → 整行落榜。
            let matched = row.children.filter { $0.ports.contains(port) }
            guard !matched.isEmpty else { return nil }
            return row.withChildren(matched)
        }
    }
}
