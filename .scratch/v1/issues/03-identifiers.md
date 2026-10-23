# 03: 识别器——Java/前端/未知与显示名

**What to build:** 扫描结果带上名称与类型：fat jar 清洗版本尾巴（`user-service-1.0.0-SNAPSHOT.jar` → `user-service`）、vite/next/vue-cli 识别为前端、认不出的标「未知 + 端口」。显示名优先级 = 用户别名 > 清洗识别名 > 未知。识别器接口化，新增技术栈不改引擎。

**Blocked by:** 02

**Status:** ready-for-agent

- [ ] fixture 命令行用例：Java fat jar / `jps -l` 交叉验证、vite、next dev、vue-cli、python 脚本（未知）、node 普通脚本（未知）
- [ ] 版本尾巴清洗规则测试（-1.0.0-SNAPSHOT、-布尔版本等），清洗失败显示原名不猜
- [ ] 显示名优先级（别名 > 清洗 > 未知）与同名多实例并存（同名不同端口各占一行）测试
- [ ] 识别器协议定义：新增识别器只加实现不改扫描引擎
