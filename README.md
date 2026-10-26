# Portside · 服务码头

macOS 菜单栏应用：自动发现本机正在运行的开发服务（Java 后端、前端 dev server），随手看名称、端口、存活状态，管启动/停止/重启、浏览器打开、查看日志。

你每天在终端里 nohup、`npm run dev`、`java -jar`，服务都活在后台——它们没有前台。Portside 给它们一个码头：启动即弹出主窗，所有正在跑的服务谁活着、谁挂了、跑多久了一眼看完；菜单栏锚形图标常驻（有服务挂了变警示三角），随时点回主窗——全程不开终端。

> 截图占位：主窗（列表形态 + 日志形态各一张），发版前补真实截图。

## 它能做什么（v1 实装）

- **自动发现**：周期扫描本机监听端口 ↔ 进程映射（lsof 主路径 + netstat 交叉核对），识别 Java（jar 文件名清洗版本尾巴）、前端 dev server（vite/next/vue-cli）；识别不出的显示「未知 + 端口」，不猜。
- **四区列表**：我的服务（托管）/ 后端 / 前端 / 其他。未识别进程按进程名聚合成单行（「QQ（35 个端口）」默认折叠，展开见明细），「隐藏其他」一键收起，数据不丢。
- **收编**：给外部起的服务补记一条启动命令（弹窗三字段预填，argv 原样），升级为托管——停止/重启/日志立刻解锁。v1 没有手动登记新服务的入口：服务的第一次启动永远由你自己做，Portside 负责发现。
- **托管操作**：启动/停止/重启（整组发信号，fork 的子进程一并杀干净）；危险动作二次确认，解释写给你看。
- **退出不清场**：Portside 退出时你的服务照常跑；重开后按定义（端口 + 启动命令）自动「认领」回托管态，匹配不上的落回外部态，不误认。日志、定义全部持久化。
- **日志流**：托管服务输出直写落盘日志；外部服务尽力发现（进程正在写的 .log/.out → 工作目录 nohup.out、logs/ 兜底）→ 都没有就明说「未发现日志文件」，不装死。面板同窗切换查看，末尾 500 行起、实时跟随。
- **刷新三档**：实时（5s 常驻）/ 均衡（活动 5s、空闲 30s，默认）/ 低资源（30s / 120s），面板底栏切换即时生效，选择记住。
- **汇总态上图标**：收编过的服务挂了，图标变红警示三角——不开面板也知道。

## 构建与运行

需要 macOS 14+ 和 Swift 6 工具链（Xcode 16+）。零第三方依赖。

**开发**（改代码时）：

```bash
cd portside
swift run portside
```

启动即弹出主窗（Dock 出现 Portside 图标、菜单栏出现帆船图标）即启动成功；关掉主窗它仍在菜单栏待命，点 Dock 或菜单栏图标随时调回。测试：

```bash
swift test                                # 全套（200+ 用例）
PORTSIDE_SMOKE=1 swift test --filter ScannerSmokeTests   # 另加：本机实扫对照真 lsof
```

**安装**（日常使用，工单 12）：

```bash
./scripts/package-app.sh --install
```

打包成 `Portside.app`（帆船应用图标，Info.plist 完整，ad-hoc 签名）装进「应用程序」（无权限自动回退 `~/Applications`），之后从 Launchpad / Spotlight / Finder 直接打开，不用开终端。图标由 `scripts/render-icon.swift` 渲染生成（产物 `Packaging/AppIcon.icns` 已入库，重生成才需要跑脚本）。

发版前过一遍 [docs/acceptance.md](docs/acceptance.md)（spec 验收 1-10 逐条，机器项 + 人工项）。

## 当前限制（v1 自用版）

- 未签名、未公证（仅 ad-hoc 签名）——首次运行 macOS 可能拦一次。
- 无开机自启。
- 外部服务的日志是尽力发现：进程的 stdout 在它启动那一刻就流向了别处，Portside 只能找落盘文件；真 PTY（交互 stdin，flutter/expo 场景）不支持。
- 包装命令的服务定义（如收编 `npm run dev`，实际监听者是 node/vite）在端口兜底停止路径受限：杀前命令校验宁漏杀不误杀，会拒绝停止并明示；Portside 亲生启动/重启不受影响（v1.x 候选：进程树归因兜底）。
- 零网络、零遥测、零第三方依赖——它不往外发任何东西，以后引入遥测也必须默认关闭且明示。

## v1.x 路线（候选池，未拍板）

按调研后的优先级排序，做之前重新评估：

- **agent 归因**：每行显示这个服务是谁/哪个 agent 启动的。
- **MCP server**（先只读）：让 coding agent 列服务/查端口/看日志。
- 分组整组启停、挂掉通知、健康历史。

## 文档

- 术语表：[GLOSSARY.md](GLOSSARY.md)（服务实例/托管/外部/收编/认领……一切歧义以此为准）
- 发版验收清单：[docs/acceptance.md](docs/acceptance.md)
- 架构决策：[docs/adr/](docs/adr/)（ADR 0001：托管服务与 Portside 生命周期解耦）
- v1 规格：[../.scratch/portside/v1/spec.md](../.scratch/portside/v1/spec.md)
