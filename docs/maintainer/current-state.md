# 当前进度 · DeepSeek 交接

2026-10-17 原 Windows 最新观测，接手者的执行环境已确认为原 Windows。整体未完成。**DS-01 非数值论据已实现、测试、独立静态复核并受管安装**（futures `72d8e36`，检查器 `futures-report-check-v8`）；DS-02 未就绪草稿提前结束、DS-03 真实研究复核仍未完成。首读 [DS-01 记录](windows-ds01-statements-20261017.md) 与 [详细接续任务](deepseek-handoff-20261017.md)，旧状态保存在 [历史快照](current-state-before-deepseek-20261017.md)，不得把历史“当前”覆盖本页。

## 阶段状态

| 阶段 | 当前结论 | 已有证据与仍缺内容 |
| --- | --- | --- |
| P0 基线 | 历史范围通过 | 旧库/数据和发布基线保留；不代表最终交付版本已做新备份 |
| P1 本机运维 | 原 Windows 已落地 | 统一启停、诊断、单服务发布/回退、备份实际还原；最新 Futures v7 独立升级已验证非目标实例不变 |
| P2 拆分服务 | 部分完成 | 12个服务独立仓库/构建/安装，加 SDK/Harness/集成共15仓；旧测试覆盖/权限退役和最终组合验收仍开放 |
| P2.5 DSH与存储 | 部分完成 | 固定源码、持久化、工作状态、Compact回查、冻结重放、guarded参数恢复已实现并有分层证据；完整生命周期及整平台资源仍待收尾 |
| P3 UI与功能 | 部分完成 | 中台/业务独立，Agent/ToolHub/知识库/任务/草稿/来源可用部分已测；全部桌面/窄屏/错误流程未逐项验收 |
| P4 故障恢复 | 部分完成 | 接管、丢回复、SQL故障、取消、备份恢复等多项证据；仍须对照W07–12/14核对缺口，不能以合成供应商证明真实服务成功 |
| P5 真实研究 | 未通过 | DS-01 非数值说明通道已安装，但最新实际任务仍失败于第 8/12 次请求；DS-02 提前结束、DS-03 内容复核和四问真实验收未完成 |

## 当前安装与工程验证

默认引擎 guarded-v6，两个 Worker，最近只读 core_ready=true。Runtime 1e17aae、Worker 029cc2b、Console a5f8c59、Registry 2f7f836、Futures 72d8e36；Futures 报告检查器为 `futures-report-check-v8`。其他安装及完整 SHA 以 [仓库清单](repositories.json) 的 installed 为准。其来源是原 Windows release catalog，不是远端用户的可用服务。

核对发现Telemetry源码HEAD为6f9f539、集成pin为c2a02e2、正式安装为fcaca2e；Indexer/Sandbox/Sources/ToolHub也有HEAD领先pin的情况。清单分别保留，DS-05先调查差异再决定部署，不能用全量build/update把当前安装静默换成pin。Harness产物随Worker固定，SDK随编译依赖固定，不按独立进程计数。

guarded-v6：29项Harness测试、85项Runtime测试事件、69项Worker相关测试、实际进程/隔离PG的9个联合场景，以及发布/回滚检查通过；供应商为合成夹具的场景明确不是真实模型。Futures v7：Go futures/cmd回归和vet、独立Go/Web构建、引用位置及改错解读的回归通过，独立静态复核无阻断。真实末稿只读检查精确定位第三条finding第一处引用；旧v6反馈与原稿哈希不变。详见 [发布、验证及失败记录](windows-guarded-release-20261017.md)。

DS-01 增量（2026-10-17）：Futures `72d8e36` 增加可选 `statements` 与问题/解读 `statement_ids`，检查器升级为 `futures-report-check-v8`；说明只能绑定本任务留存原文，不能夹带市场报数（日期、页码、期数、样本家数等非报数计数除外），数值仍由 `facts` 检查。Go 测试/vet、27 项 Web 测试、TypeScript/Vite 构建通过；两次独立只读静态复核（无 blocker/high，第二次 MEDIUM）提出的日期误伤、说明限制数量、借用事实 ID、非法编号路径、README 版本等问题已修复。受管发布安装后 `Platform.ps1 status` 为 futures ready，旧任务 report-check 返回 v8，已安装 MCP 的纯说明草稿 `ready=true`/`revise=0`，含裸数量的说明草稿 `ready=false`/`statement_quantity`。详见 [DS-01 记录](windows-ds01-statements-20261017.md)。这不是 DS-03 真实研究通过。

DS-02 增量（2026-10-17）：已从私有调用回执确认“未就绪稿 → 误提成稿 → Runtime 拒绝 → 模型以正文结束 → runner 失败”的完整序列；Harness 提交 `c5d4e4e2d5` 已实现 guarded-v7 单次续接，31 项本地测试通过，含“拒绝后正文结束 → 一次续接 → 成功”和“第二次文本结束即终止”。**尚未接入 Runtime/Worker/Console、未安装、未改任务**；不能写成已修复。方案见 [DS-02 调查](windows-ds02-finalization-investigation-20261017.md)。

guarded安装前完整备份已在隔离库实际恢复：1数据库、10角色、3项凭证解密和历史产物验证通过，隔离库已停。但该备份早于最新失败研究和v7安装，最终DS-08仍需捕获新的交付状态。

## 最新业务失败与下一步

Agent v20 / Skill v9 / MCP v2；任务 2bc11ddab7473a1e2ee29fd499330558，第8/12次模型请求失败，无最终报告，22次阅读、两份草稿留存。已确认三类问题：引用归属错误（检查器v7已能精确提示）；非数值来源说明借用不支持论点的数字事实；模型对未就绪稿提前提交并直接返回不同正文。另有日期覆盖解释自相矛盾。DS-01 已实现并安装（`statements`/`statement_ids`，检查器 v8，说明通道不能夹带市场数量），但尚未在该真实四问任务中复验；DS-02 提前结束尚未修复，DS-03 真实研究内容复核未执行。不能把结构 ready 或安装完成写成 P5 通过。

官方DeepSeek保留原生上下文/输出能力，未增加人为token限制。研究需要通过逐问、来源、日期/样本/性质、可比性、最终稿一致性和原文回读的联合验收；结构ready与终态completed都不是内容质量证明。

## 扩展与延后范围

Sandbox隔离执行仍未配置；Milvus、LightRAG、Embedding、Langfuse的服务实现和实际后端配置按各自证据验收，不统称全部可用。Linux 2核4GB整平台长稳、100万文档/1000万块、物理机器HA、主备数据库和全品种覆盖均未完成，其中服务器与最终容量是用户允许后续推进的范围。

15仓main/开发分支/干净工作区/公开状态/Actions禁用已于本次交接核对；主仓随后交接提交单独推送。日常CI仍关闭，本次没有付费模型调用、正式数据迁移或新的服务安装。
