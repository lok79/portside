# Spec：v1 发布（免签直发）

Status: **已发布**（2026-10-27）：仓库已转公开，Release https://github.com/lok79/portside/releases/tag/v1.0.0（Portside-1.0.0.zip，633KB，arm64，ad-hoc 签名）
产品：portside · 目标版本 1.0.0
前置：v1 验收通过（仓库主人 2026-10-26 人审确认）；分发路线 D-004（非沙箱 → 无 App Store，直发）+ 用户拍板免签先行（公证 $99/年 暂缓，有下载量再上）

## 一句话定位

把验收过的 v1 打成发布包挂 GitHub Release：下载 zip + README 首开指引，零公证成本先见真实用户。

## 范围

1. `scripts/package-app.sh`：版本 0.1.0 → 1.0.0（Info.plist 双键）；新增 `--zip` 发布模式（ditto 保留签名元数据 + keepParent）。
2. README：新增「下载安装」节（Release 下载 + **首次打开指引**：右键打开 / `xattr -cr`，二选一）+ 架构标注 Apple Silicon；限制节指回首开指引。
3. tag v1.0.0（合回 main 后打）。
4. GitHub Release：`Portside-1.0.0.zip` + 发布说明（见下）。

## 不做（本工单）

- 公证 / Apple Developer 账号（$99/年，待有下载量再拍板）
- Intel 构建（构建机为 Apple Silicon，fat binary 留待有需求）
- 官网（README + Release 即分发页）
- 仓库公开化决策（发布前置，仓库主人拍板：私有仓的 Release 外部不可下载）

## 发布说明草稿

> 首个公开版本。自动发现本机开发服务（Java / 前端 dev server），四区列表、收编托管、日志流、三档刷新、退出不清场。macOS 14+，Apple Silicon。未公证：首次打开右键 → 打开，或 `xattr -cr /Applications/Portside.app`。

## 验收

- [x] README 首开指引就位
- [x] package-app.sh --zip 产出 .build/Portside-1.0.0.zip
- [x] swift test 全套通过（240 用例，0 失败 1 跳过）
- [x] zip 解压验证 .app 结构 + codesign 校验（ad-hoc，arm64，版本 1.0.0）
- [x] 合回 main + tag v1.0.0
- [x] 仓库公开化拍板（主仓转公开，泄密扫描：无硬编码凭据、无个人邮箱于代码）→ push + Release 发布（2026-10-27）

## 坑位（回灌上架员工手册）

- **构建产物在 worktree 的 .build 里，worktree remove 会连产物一起删**——删 worktree 前先把 zip 拷出去（本次已踩：首发 zip 重打了一遍）。
- 泄密扫描口径：精确凭据赋值模式（key/secret/password/token = 值）+ 非 md 文件里的个人邮箱；词命中（argv token 等）人工过一眼即可。
