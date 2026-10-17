# 当前工作队列 · DeepSeek 接续

2026-10-17更新。详细文件、步骤、测试和完成标准统一在 [DeepSeek交接](deepseek-handoff-20261017.md)。完整目标与W01–W14不缩减；以下顺序不等于只有这些工程小项需要验收。用户已明确交接后暂停原Codex，交给DeepSeek。

| 顺序 | 当前状态 | 本体任务 / Owner | 下一步 |
| --- | --- | --- | --- |
| DS-01 | 已完成（源码/测试/安装/静态复核） | task:qualitative-evidence / Futures | 非数值说明已绑定留存原文并安装；转入 DS-02，DS-03 真实内容复核仍待做 |
| DS-02 | 已完成（双产物安装，默认 v7；DS-03 已在 v7 上跑通真实任务） | task:finalization-recovery / Harness、Runtime、Worker、业务方法 | v6 任务 continuation context=`manual_review`/`unsupported_checkpoint`，保留重放/读取但不能直接续跑；不得删 v6 runner 或改旧任务；真实恢复/故障重放归 DS-07 |
| DS-03 | 已完成（真实四问报告 + 独立内容复核 ACCEPT） | task:research-quality / Agent 22、Skill 10、Futures 检查器 | 仅覆盖库存/区域/合同三份资料；旧供给/进口/压榨失败任务未回填；保留 s1 引文拼接 minor；下一步 DS-04 |
| DS-04 | 浏览器矩阵通过；业务入口已修复安装；Console 运行详情“查看源任务”与 Futures 同品种历史任务均已浏览器验证；精确跨任务证据链仍开放 | task:continuation-ui / Console、Futures、Runtime | 跟进 v6 失败任务“不足以直接续跑”的评估；在 Futures 记录页补精确来源任务/证据链；补浏览器自动化可重复入口；不把启发式同品种入口写成自动溯源 |
| DS-05 | 正式 ACL 已收缩；撤权后合成任务/双 Worker 接管通过；临时 Telemetry 导出 3,992 事件到 mock；真实 Langfuse/managed 实例、旧实现/Linux 未完成 | task:service-retirement / 各Owner及集成 | 接真实 Langfuse 或受控 OTLP 并验证 managed 实例；逐行删除旧实现；最终 CI 另做 |
| DS-06 | 部分完成（笔记修订/过期/并发 200+409/撤回 + 128–8192 步 Compact/重放（8192 步 168.1MB heap/339.5MB RSS）+ 32k/64k/最大限制下 20/40/80 轮强杀/接管/完成 + 20 轮 RSS 采样；8k/16k step 13/19 失败；40/80 轮无可见 Compact，请求体线性增长） | task:storage-lifecycle / Harness、Runtime、Worker、Storage | 从 token/交换记录确认 Compact 是否触发；定位 8k/16k 与 32k 差异；补真实 Compact 点强杀续跑、10M 分块/生产 RSS 上界；不删权威资料，不以合成基准代替生产容量 |
| DS-07 | 部分完成（8 并发 8/8、30.1 分钟 24/24 soak、8 秒锁恢复、30 秒锁失败、15/30 秒锁内取消、杀 owner 后取消、终止 3 个 Worker DB 会话后完成、PG 快速重启后完成、Runtime stop/start 在 Worker 19 秒同 operation 退避下完成；超过 19 秒停机仍会失败；网络分区/慢查询/死锁/异步补偿/内存趋势未做） | task:faults-and-resources / 集成及相关Owner | 补网络分区、更长 Runtime 停机/任务级恢复、慢查询计划/死锁注入、超过 60 秒锁的异步取消、外部副作用补偿、内存趋势和整平台资源口径 |
| DS-08 | 已完成（当前版本快照备份 + 隔离恢复 passed） | task:latest-recovery / 原Windows集成 | 备份 `ds08-final-20261017c`（Worker 1ac65212/Futures fdc9a7/Console 94f118 后）：46 表/序列、10 服务登录、5 密封凭据、2 Worker bundle、离线 Harness 重建全部通过；不替代服务器/HA 或外部服务恢复 |
| DS-09 | 本机全套扫描通过（Runtime/Console/Worker/Futures/Telemetry/Harness；40+27 Web、16+31 Harness，0 skip）；最终 hosted CI 未执行 | task:final-ci / 集成 | 全部本机验收后唯一一次集中 hosted CI 及独立逐条完工审查；本机扫描不能替代 Actions |

已完成不重做：Mac成果接回、接续回执迁移/安装、final-v5确定性成稿协议、guarded-v6工具参数纠正、Futures v7精确引用诊断、DS-01非数值说明绑定与v8检查器、DS-02双引擎v7单次续接安装、15仓同步。它们不等于最终业务和平台验收通过。

task:fresh-windows-bootstrap仍保留为用户以后要求新Windows时的条件任务；新维护者可先在独立环境做便携代码测试，不能把环境不同当作伪造原Windows验收的理由。服务器/机器HA/最终全量容量和全品种后续范围见objective.md。

原队列及2026-10-15/17的逐次历史保存在 [旧队列](backlog-before-deepseek-20261017.md)，其中Agent v17、默认native/final、尚未迁移/安装等旧状态不再是当前开工指令。查证据需要时再读，不把全部历史塞入模型上下文。
