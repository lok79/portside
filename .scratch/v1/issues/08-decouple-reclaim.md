# 08: 生命周期解耦与自动认领

**What to build:** 退出（或被杀）Portside 时托管服务照常运行、日志继续落盘；重开 Portside 后按服务定义（端口 + 启动命令匹配）自动「认领」回托管态；匹配不上的落回外部态，不误认。

**Blocked by:** 06

**Status:** done

- [x] 托管服务以独立会话启动：`kill -9` Portside 后服务存活、日志继续写入（adr/0001）
  ——解耦审计：app 退出路径零牵挂（无 willTerminate/atexit/信号处理器杀组；reaper 为
  后台线程随 app 死亡，孤儿由 launchd 接管收尸）。可测等价物 `portside-host-sim`：
  自成进程组的宿主替身真跑 ShellProcessController、零清理路径，测试杀其整组 =
  「kill -9 Portside」；集成测试断言服务存活、未变僵尸、日志续写（DecouplingTests）。
- [x] 重开 app：运行中的已定义服务自动显示为托管·运行中；已死的显示托管·已停止（可一键启动）
  ——`ShellProcessController.reclaim(definitionID:pid:)` 登记受管外部实例（非亲生：
  不 waitpid、退出感知走有界存活探询），首轮扫描即认领；停止/重启对认领实例生效，
  重启后回「自己起的」状态（亲生条目）。
- [x] 不误认测试：端口相同但启动命令不同的进程不会被认领为该定义
  ——端到端用例（扫描管线 → 匹配器 → 无登记）+ 控制器层「不覆盖事实」三规则
  （同 pid 幂等不降级亲生身份；存活异 pid 拒绝；死条目可换代）。
- [x] 认领在扫描首轮完成（app 打开几秒内列表即正确），无需手动刷新
  ——PanelViewModel.recompute 在「我的服务」区逐行认领，O(1) 同步登记不阻塞 UI；
  partial 扫描照常按可用数据走（拿不到命令行在匹配器处自然落空，宁漏认不误认）。
