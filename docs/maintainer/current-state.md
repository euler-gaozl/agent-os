# 当前状态 · 2026-10-21 期货 UX 与错误记录交付

本轮已完成 [实施计划](futures-ux-errors-plan-20261020.md) 的 A–E，并在本机 Mac 候选组合上做了浏览器验收和受控安装；结果、提交、测试、截图索引和回滚记录见 [交付记录](futures-ux-errors-delivery-20261020.md)。问题清单中 FUX-001/002/003/005 为“候选已验证、待合并”，FUX-004 仍是独立的执行协议后续项。

- 代码分支：`agent-os-runtime`/`agent-os-futures` 的 `work/futures-ux-errors-20261020`；本机安装 Runtime `780fb23`、Futures `5de3195`（二进制），Web `fafe2d57…`。
- A：改前十次刷新 1→11 个重复证据区；改后 1/1/1，真实父组件动态回归通过。
- B：失败页给出原因/影响/下一步；完成页把执行状态、证据检查和记录分开；单一操作区；0 草稿不显示空大面板；最终与草稿锚点隔离。
- C：Runtime 有界、按应用隔离、脱敏的诊断接口；真实豆粕失败解析为工具参数拒绝（参数“豆”），不以原始 HTTP 400 解释；旧 Runtime 404 时页面保留任务状态。
- D：只读错误记录页按窗口/品种/状态/步骤/分类筛选与游标分页，显示扫描范围，支持导出；API/数据库审计证明零写入。人工复盘只导出文件，不保存处置状态。
- 本机 12/12 进程 ready；安装前完整组合已备份并实际回滚演练（旧组合 12/12、诊断 404），再装回候选后诊断 200。没有数据库迁移，Worker/执行协议和原期货包未改。
- **未合并 main、未推送、未触发 Actions。** Console 管理摘要、持久化人工处置、FUX-004 的有界工具拒绝协议仍待单独安排。

## 原 Windows：2026-10-18 复核收尾

**最新定向修复**：Futures `84c17f2` 已同步 main/开发分支，原 Windows 安装 `futures-f2821dd46b8f490b8fa1d25c580b8ff8`。月份按明确统计/元数据/不确定用途处理，不再以是否带年份决定硬拦；15 个新增场景、Go 全包/vet 和发布构建通过。R3d 原结果哈希未变、26 facts/12 statements 仍可回查，旧报告措辞仍待新修订。见 [修复与验证记录](month-role-fix-20261018.md)。下方旧 SHA/发布是历史快照，以此条及 repositories.json 的 Futures 项为准。用户要求交付后关机，服务在线状态须开机后重新确认。

**2026-10-18 供给四问复核增量**：Futures 报告检查器 `2b729c3` 已安装；真实修订任务 `1949dad2…`、`f223a76f…`、`71c55643…` 均 completed 且 draft-match=matched，R3d 任务 `2434822c…` 已 completed、draft-match=matched，26 facts/12 statements 全部可回查，未再出现 retained_quote/quote_normalized/finding_period_borrow；内容仍需独立复核，不能写成研究已验收。

这是原 Windows 的实测快照，不是接手者机器的可用状态。代码/现场发布优先于文档；本页替换了历史中混杂的“尚未安装/已经安装”，旧内容保存在 [历史快照](current-state-before-review-20261018.md)。

本轮三项：**main 同步完成，固定证据关联完成，原供给四问内容未通过**。详细见 [三项结果](review-followup-20261018.md) 与 [DeepSeek 接续](deepseek-followup-20261018.md)。

- 15 仓源码已上传、main 同步，Actions 关闭；本次未用 hosted CI。上一轮13/13是历史结果。
- Runtime 76237d3 / Futures f3c25ea 已正式安装，其余安装未变；全部完整 SHA、源码/pin/安装差异见 repositories.json。
- 默认 dsh-source-687f282e-guarded-v7，仍保留旧固定引擎及回放能力，两个 Worker。
- 固定证据关联包括原任务和阅读回执版本、提交关联/事后补关联区分；新 UI 修订11/11事实、9/9说明匹配。
- 供给四问6908846d…正常成稿、draft-match一致，22/24事实匹配；内容问题见 DS-R1/R2/R3，不能声称已验收。
- 迁移后47关系，最新备份 post-evidence-binding-20261018 已实际隔离恢复；摘要见 review-close-evidence-20261018.json。
- 备份恢复后 core_ready=true；原 Windows 仍有 sandbox_execution_unavailable 警告（隔离代码执行未配置）。基础 API 就绪不代表此能力已提供，本轮没有改变该限制。

## 完整范围

原 Windows 单机在 [上一轮记录](windows-single-machine-delivery-close-20261018.md) 中收口；本次是后续增量。跨机 HA、服务器部署、千万块容量、24小时生产长稳仍延后；任务级死锁/异步取消/外部副作用补偿等后续增强未被取消。真实 Langfuse 按旧收口记录为用户放弃项。没有把单机验收冒充生产集群验收。

## 开始维护

先确认 OS/目录和授权，读 environment.md、目标服务 AGENTS.md，再做 [当前待办](backlog.md)。不用复读全部历史，不重跑已完成迁移，不从旧路径启动服务，不把原电脑端口/密钥/资料当作接手环境已有资源。

## main 同步

- 2026-10-18：`agent-os` main fast-forward 到 `969fd9a`，`agent-os-futures` main fast-forward 到 `2b729c3`；开发分支与 main 一致。
- Actions 仍全部禁用，未触发 CI。
