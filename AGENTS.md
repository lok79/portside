# portside · Agent 指南

Portside · 服务码头——macOS 菜单栏应用：自动发现本机开发服务（Java 后端 / 前端 dev server），随手看名称、端口、存活，管启动/停止/重启/打开/日志。术语见 [GLOSSARY.md](./GLOSSARY.md)；v1 规格见 [.scratch/v1/spec.md](.scratch/v1/spec.md)；立项决策 D-004 与公司级判断住公司仓库 [lok79/handbook](https://github.com/lok79/handbook) 的 `docs/decisions/`，产品级技术决策记 `docs/adr/`（已有 0001、0002）。

## 技术栈与形态

- 原生 SwiftUI 菜单栏应用（NSStatusItem + SwiftUI），Swift。
- 非沙箱运行：沙箱禁止扫描/管理其他进程，与产品本质冲突（见 D-004 No-gos）；分发走官网直发 + 公证。
- 硬约束：低内存、低功耗、低资源占用——扫描用退避策略不做死轮询，实现取舍拿不准时以占用为先（具体指标见 spec 验收标准）。

## 红线（改前先读）

- 托管服务 vs 外部服务的能力边界（见 GLOSSARY）：任何新功能必须先回答"对外部服务的降级形态是什么"，不得假装两者能力一致。
- 识别不出名称的服务显示"未知 + 端口"，禁止靠猜。
- 识别器可扩展：Java/前端只是首批识别器，引擎不得写死单一技术栈假设（D-005）。
- v1 零遥测：不收集、不上报任何使用数据；未来引入必须默认关闭且明示（TidyPorts 信任事故教训，见 D-005）。
