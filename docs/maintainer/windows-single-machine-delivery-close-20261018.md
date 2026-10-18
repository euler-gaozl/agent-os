# Windows 单机交付收口（2026-10-18）

用户确认：完成 13/13 集中 CI、最终备份恢复和旧单体入口退役后，**收口当前 Windows 单机交付**；DS-04 自动跨任务证据链、DS-07 任务级死锁/异步补偿/内存趋势作为交付后增强，不再阻塞本次单机交付。

## 已交付

- **DS-01**：非数值原文论据绑定与 v8 检查器已实现、安装、测试。
- **DS-02**：final/guarded 新引擎受控真实任务 `a4063a81…` completed step 2，`final_output_completed done=true`；v6 历史任务保留重放/读取。
- **DS-03**：库存/合同真实四问报告经独立内容复核 ACCEPT。
- **DS-04**：Console/Futures 主要页面、窄屏和交互浏览器矩阵通过；同品种历史与手动“源任务 ID”可用；自动/持久化跨任务证据链保留为增强。
- **DS-05**：执行域 ACL 已收缩；撤权后双 Worker 接管通过；旧单体入口 `cmd/agentos` 已删除；真实 Langfuse 按用户决定放弃。
- **DS-06**：笔记生命周期、长历史 Compact、**Compact 点 kill/resume**（`549c3295…`，fence 2，同一 call_id，COMPACT_DONE）、4 并发新引擎 40 轮任务与 RSS 采样通过。
- **DS-07**：双 Worker 接管、锁/取消/DB 会话/PG 重启/Runtime 停机、**网络分区**（TCP 代理，`waiting_unknown` 后 `resume-source-state`，任务 `cdcf5fe0…` completed step 41）、1M 行查询计划等通过。
- **DS-08**：`ds08-final-20261018l` 隔离恢复通过：46 关系、10 角色、5 条密封凭据、2 Worker bundle、215 代 / 25 引用 / 3,103 文件；隔离集群停止，provider calls 0。
- **DS-09**：最终集中 hosted CI **13/13** 通过（Knowledge collation 修复后定向重跑）；Actions 已再次禁用。
- 平台当前 `core_ready=true`，2 Worker；Runtime `cd1436ca…`，Worker `806b411d…`，Knowledge `e1d6ed1d…`；默认 `dsh-source-687f282e-guarded-v7`。

## 交付后增强（不阻塞本次收口）

- DS-04：Futures 自动/持久化跨任务证据链与可重复浏览器自动化入口。
- DS-07：任务级死锁、超过 60 秒锁的异步取消、外部副作用补偿、长期内存趋势。
- 服务器/跨机 HA、24 小时生产长稳、1000 万块容量：用户明确延后。
- 真实 Langfuse/managed Telemetry：用户明确放弃。

## 边界

- 本收口只覆盖单机 Windows 交付；不声称服务器、跨机 HA、1000 万块或外部 Langfuse 已验收。
- 13/13 CI 是 hosted runner 结果，不是容量或生产长稳。
- 旧兼容库仍保留用于迁移/历史回放；不等于所有旧代码删除。
