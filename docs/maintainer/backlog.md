# 当前工作队列 · DeepSeek 接续

2026-10-17更新。详细文件、步骤、测试和完成标准统一在 [DeepSeek交接](deepseek-handoff-20261017.md)。完整目标与W01–W14不缩减；以下顺序不等于只有这些工程小项需要验收。用户已明确交接后暂停原Codex，交给DeepSeek。

| 顺序 | 当前状态 | 本体任务 / Owner | 下一步 |
| --- | --- | --- | --- |
| DS-01 | 已完成（源码/测试/安装/静态复核） | task:qualitative-evidence / Futures | 非数值说明已绑定留存原文并安装；转入 DS-02，DS-03 真实内容复核仍待做 |
| DS-02 | 已完成（双产物安装，默认 v7；DS-03 已在 v7 上跑通真实任务） | task:finalization-recovery / Harness、Runtime、Worker、业务方法 | v6 任务 continuation context=`manual_review`/`unsupported_checkpoint`，保留重放/读取但不能直接续跑；不得删 v6 runner 或改旧任务；真实恢复/故障重放归 DS-07 |
| DS-03 | 已完成（真实四问报告 + 独立内容复核 ACCEPT） | task:research-quality / Agent 22、Skill 10、Futures 检查器 | 仅覆盖库存/区域/合同三份资料；旧供给/进口/压榨失败任务未回填；保留 s1 引文拼接 minor；下一步 DS-04 |
| DS-04 | 浏览器矩阵通过（7 中台页 + 5 编辑器标签 + ToolHub/知识库/运行/服务 + 业务首页/记录/失败/移动端）；业务入口已修复安装；2 项跟进 | task:continuation-ui / Console、Futures、Runtime | 跟进 v6 失败任务“不足以直接续跑”的评估与跨任务证据溯源；补浏览器自动化的可重复入口；不把浏览器通过写成后端恢复/故障通过 |
| DS-05 | 正式 ACL 已收缩；撤权后合成任务完成 note_save/run_recall，双 Worker 接管通过；Telemetry 导出/旧实现/Linux 未完成 | task:service-retirement / 各Owner及集成 | 配置有效导出端点后跑 Telemetry 接收/导出；逐行删除旧实现；隔离恢复已完成，最终 CI 另做 |
| DS-06 | 部分完成 | task:storage-lifecycle / Harness、Runtime、Worker、Storage | 补笔记/缓存/失败退出与长历史内存恢复验收，不删权威资料 |
| DS-07 | 部分完成 | task:faults-and-resources / 集成及相关Owner | 仅补缺失或受改动影响的故障，并测整平台+PG连续负载 |
| DS-08 | 已完成（最终快照备份 + 隔离恢复 passed） | task:latest-recovery / 原Windows集成 | 备份 `ds08-final-20261017b`，46 表/序列、10 服务登录、3 密封凭据、2 Worker bundle、离线 Harness 重建全部通过；不替代服务器/HA 或外部服务恢复 |
| DS-09 | 未执行最终CI | task:final-ci / 集成 | 全部本机验收后唯一一次集中CI及独立逐条完工审查 |

已完成不重做：Mac成果接回、接续回执迁移/安装、final-v5确定性成稿协议、guarded-v6工具参数纠正、Futures v7精确引用诊断、DS-01非数值说明绑定与v8检查器、DS-02双引擎v7单次续接安装、15仓同步。它们不等于最终业务和平台验收通过。

task:fresh-windows-bootstrap仍保留为用户以后要求新Windows时的条件任务；新维护者可先在独立环境做便携代码测试，不能把环境不同当作伪造原Windows验收的理由。服务器/机器HA/最终全量容量和全品种后续范围见objective.md。

原队列及2026-10-15/17的逐次历史保存在 [旧队列](backlog-before-deepseek-20261017.md)，其中Agent v17、默认native/final、尚未迁移/安装等旧状态不再是当前开工指令。查证据需要时再读，不把全部历史塞入模型上下文。
