# 12: 最小 .app 打包与安装（自用版，不签名公证）

**What to build:** 一条命令把 Portside 打包成可双击的 `Portside.app`（锚形图标、常规 Dock 图标、Info.plist 完整）并安装到 /Applications（无权限则 ~/Applications），从此不用开终端 `swift run`。不签名公证（自用口径，D-005），仅 ad-hoc 签名保证 Apple Silicon 可运行。**Finder 启动环境**（最小 PATH、`$SHELL` 可能为空、无终端）下全部功能照常。

**Blocked by:** None (can start immediately)

**Status:** ready-for-human

- [ ] `portside/scripts/package-app.sh`：`swift build -c release` → 组装 `Portside.app/Contents/{MacOS,Resources}` + Info.plist（CFBundleName Portside、DisplayName「Portside · 服务码头」、Identifier `app.portside.Portside`、Executable、IconFile、Version 0.1.0、LSMinimumSystemVersion 14.0、NSHighResolutionCapable；**无 LSUIElement**——保持工单 10 的常规 Dock 形态）→ ad-hoc `codesign` → 可选 `--install` 拷到 /Applications（失败回退 ~/Applications 并提示）
- [ ] 图标：AppIcon.icns 由脚本从 SF Symbol「anchor」渲染生成（深色圆角底 + 白色锚形，1024 源图经 iconset → iconutil），生成物 `portside/Packaging/AppIcon.icns` 入库以便打包不依赖渲染步骤；渲染脚本也入库可复现
- [ ] Finder 启动环境加固（Kit）：`$SHELL` 为空时回退 `/bin/zsh`（再回退 /bin/sh）；所有外部命令（lsof/netstat/ps/jps 候选）确认用绝对路径或不依赖登录 PATH；测试：注入空环境验证启动命令仍能跑
- [ ] 实测：打包到临时目录 → `open Portside.app` → 进程存活、窗口出现、扫描有数据（面板非空）、Dock 显示锚形图标 → 退出；`pgrep` 无残留
- [ ] README「构建运行」改为两段：开发（swift run）/ 安装（`./scripts/package-app.sh --install`）；「当前限制」去掉"未打包 .app"，保留"未签名公证、无开机自启"；acceptance.md 验收记录补一行
- [ ] `swift build` + `swift test` 连跑 3 次全绿

## Comments

### 2026-10-26 · 工单重建与执行记录

- **重建**:本工单原居公司库 `.scratch/portside/v1/issues/12-app-bundle.md`(039686d,2026-10-26 08:32),D-008 拆仓时遗失在老库,内容原样归位本仓 v1 工单列表,编号沿用 12。
- **偏差一处(已记录)**:图标工单原文写「锚形 anchor」,实机运行时该 SF Symbol 不可用(实测 nil,anchor/anchor.fill 均缺),改用 `sailboat`(码头停船,语义不变);渲染脚本 `scripts/render-icon.swift` 内有注记。
- **Finder 加固核对**:lsof/ps/netstat 已绝对路径(`/usr/sbin/lsof`、`/bin/ps`、`/usr/sbin/netstat`),jps 已是降级候选链(工单 03 起);本次补 shell 兜底层——`$SHELL` 空 → `/bin/zsh` → 缺失退 `/bin/sh`(`ShellProcessController.defaultShellFallback`,测试 `testshell兜底层_macOS上取zsh`)。
- **验证实录**:`swift test` 239 例 0 失败(1 既有 skip);`package-app.sh --install` 装入 **/Applications/Portside.app**(未回退);退裸实例后 `open -a Portside` 拉起,进程跑自 bundle、`mdfind` 已索引、codesign ad-hoc `app.portside.Portside`。
- **待人工**:Launchpad 图标与检索目测、Dock 常驻形态目测(acceptance.md 验收记录同日行)。
