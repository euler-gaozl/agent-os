# 接手后的工作队列

**最新断点：** [final-v5 真实业务验证](windows-final-research-20261017.md)：已安装 MCP 绑定 ID 修复，正式 Agent v20/Skill v9/MCP v2 已发布并回读。唯一新真实任务在第 4 次模型请求后因 document_read 参数超出单页上限而失败，未知 usage 0、无报告。下一步是可纠正参数错误与分页处理，不盲目重跑模型；模型输入输出已按供应商原生能力。完整 Goal 保留，用户要求留下 20–30% 额度，最近查询剩余 39%。

**2026-10-17 当前下一步：** [受管发布记录](windows-final-release-20261017.md)文首为最新状态：五个服务正式升级、双 Worker/默认 final-v5、最新备份隔离还原完成，旧任务保持。147/68/53/28 项既有门槛及新增还原 21 项通过，无需重跑。当前先发布固定业务 Agent/Skill 新版本，统一原文交付规则、修正已确认内容缺陷并完成一次有界真实研究；正式资源尚为 Agent v19/Skill v8，不能宣称已用 final-v5 成稿。完整 UI/权限/生命周期/资源故障/最终统一 CI 仍开放。用户要求至少留约 20–30% 额度并继续交付，未授权暂停。

**2026-10-17 R2 后续：** [跨回执修复](windows-cross-receipt-20261017.md)已正式安装、同步 GitHub。真实任务 27/27 引文匹配，页面两份原回执可回读；只消除一项核验器误报，其余 107 项提示和送检后改稿问题保持。下一步按[确定性成稿协议](../architecture/receipt-finalization.md)做新引擎通用回执引用，不再用提示词要求模型复制长稿。旧任务/引擎不改，内容质量和平台剩余项保持开放。

**2026-10-17 R2 最新结果：** [真实研究记录](windows-research-20261017.md)。一次官方 DeepSeek 任务完整成稿，12 次模型请求、未知计量 0；最终稿仍在最后送检后改动，并有独立确认的内容错误，R2 不关闭。本轮不追加付费重跑。下一步处理确定性成稿、同版本相邻页引用核验及内容核对缺陷；不要重复迁移/部署已通过组合或覆盖这次原结果。

**2026-10-17 当前执行顺序：** Mac 源码已接回，Windows 的两个 Worker、Futures、Runtime、Console 已升级，接续回执表已正式迁移。下一项主线是 R2 真实研究成稿/质量验收，随后处理平台剩余项及一次统一 CI。源码、安装和测试的具体范围见 [Windows 接回记录](windows-resumption-20261017.md)；不要重复已通过的迁移和同版本升级。

**同日后续已完成：** Runtime Owner 回执迁移、Runtime `cda132d` 和 Console `34094b1` 已正式安装，12 个实例恢复且核心就绪。44 个旧表/序列和原权限保留、新表最小权限及迁移恢复通过；正式浏览器可读取原任务的接续判定。真实 React/hook + 合成 HTTP 的丢回复、刷新回读、延迟回复切换任务、双标签回读及 360px 容器检查已执行，不能称作真实供应商接续成功。R2 真实研究是下一项主线；保留完整窄屏/逐页流程、正式 Console 的 `FUTURES_PUBLIC_URL` 未配置等具体 UI 缺口。不要重新迁移回执表或再次升级相同包。

先核对本机与仓库，不再从零扩展架构。按下列顺序推进；任务顺序不删减完整目标。证据不足的项目保持未关闭。

**2026-10-15：这里的执行者在自己的 Mac。** 先核对 Mac 和下载的源码，不去核对或操作原电脑。能做的代码修复、协议/夹具/独立数据库测试、Web 页面验证先完成；原 Windows 的真实任务、DPAPI、发布恢复等依赖原环境的项目保留为待专项复验。本文件后续“原电脑执行”仅指定最终验证所需环境，不是给朋友远程连接或修改它的指令。Mac 上建立全新测试数据与新任务，不尝试恢复历史任务 ID。

## Mac 首轮增量（2026-10-15）

[Mac增量记录](macos-development-20261015.md)：15仓已核对，独立Go/Node/PostgreSQL已建立；候选成稿轮次策略和推断日期误报修复完成夹具及独立审查。研究完成、质量、全部原验收项仍开放，下一步在Mac登记新固定资源并做有界真实验证。历史私有任务未复现，Windows专项未执行。

## Mac 后续增量（2026-10-15）

[第二轮记录](macos-research-and-storage-20261015.md)：独立开发栈完成两次真实供应商的合成资料任务，分别 5/4 次模型请求，终态未知 usage 均为 0，最终稿与最后送检稿逐字一致。首轮格式失败；v5 检查器及方法修订后结构和引用改善，但库存方向仍未直接回答，部分缺口分层及日期关系解释不当，研究完成与质量任务仍开放。它们不是原 Windows 私有任务复现。

完成任务草稿与 Console 业务入口已修复，Go/Web 测试、构建及独立静态评审通过；真实浏览器流程未执行，未关闭 W03/W13。真实 Runtime/Worker/Storage 加新 PostgreSQL 的[归档提交后丢确认测试](../native-storage-reply-loss-20261015.md)已通过，含重启后回读、自然租约接管及实际保留引用；不覆盖 ENOSPC、数据库重启或全平台资源上界。

## Mac 完整包与故障增量（2026-10-15）

[第三轮记录](macos-package-enospc-and-answer-contract-20261015.md)：Futures `b805fa9e` 与 Console `a2bca748` 的匹配 BFF/Web 包已安装，鉴权就绪和明确业务入口通过；真实浏览器流程仍未执行，完整 W03/W04/W05/W13 不关闭。逐问答复规则和因果边界最小修订通过既有 Go 回归与独立静态审查。新研究任务首请求收到供应商 HTTP 503，failed、无稿、unknown usage 1；433,491 为保守记账而非已确认实耗，不能据此形成新内容质量结论，不自动重跑。

[Storage 有界卷 ENOSPC](../storage-enospc-macos-20261015.md)实际验证 artifact/reference 原子性、同 PGDATA 恢复和重试前留存；只推进 P2 的 Storage 故障覆盖移交。Runtime 笔记/调用回执 ENOSPC、P2.5 生命周期及完整故障资源要求仍开放，旧覆盖继续保留。前两次 Mac 成稿结果与旧 Windows 历史均不覆盖。

## Mac Runtime Owner 故障增量（2026-10-15）

[独立记录](macos-runtime-enospc-20261015.md)：1 项真实故障测试通过（1.21 秒，非 race，零 skip）。note_save 的 INSERT documents 与 EndModel 的 UPDATE calls 分别得到 53100，并有各自新日志窗口内同后端 PID 的目标 SQL。释放唯一填充文件后重启相同 PGDATA；任何重试前，10 张 Owner 表完整行摘要和两运行 usage 不变。失败笔记无文档/回执/审计/事件，未完成模型保持 inflight、一次 unknown usage 与预算预留。自然租约到期后 fence 提高，旧 owner 被拒，已完成回执重放不重复合成结果；同 operation 笔记重试幂等。

只推进 P2 的 Runtime Owner 笔记/本地工具回执移交，并新增模型账本故障覆盖；未启动独立 Runtime/Worker/Node/Storage，归档是内存夹具。P2.5、Compact、W09 完整生命周期、W12/W14 全平台资源与目标环境验收继续开放；旧主仓测试与工作流保留。研究质量、完整 UI、服务/权限退役及最终统一 CI 状态不变。

[第四次同题验证](macos-research-verification-and-ui-20261015.md)在原 Agent 4/Skill 3、固定 native-v4 引擎及 12 步/12 次模型尝试预算下首请求 503、无稿，usage 未知 1、费用 null。独立判据预先固定且未进入输入，旧三任务不变；研究完成/质量无新通过结论，本轮不再发模型。详情读取 UI 已完成组件/状态测试与匹配包安装，真实浏览器及完整阶段、W01–W14 继续按原范围推进。

以下原 Windows 失败及资源 revision 为历史定位线索；Mac 最新证据以以上各增量及链接为准，不变更历史任务。

## 1. task:research-completion — 先让研究稳定成稿

Owner：Futures 业务协议/检查器和集成业务包；涉及 Runtime/Worker/Harness 的变更要遵守冻结重放协议。

最新真实任务在 12 次模型请求后失败，两次检查发生在最后两轮，因此没有再留一次最终输出机会。当前 Agent `published-supply-inventory` revision 17、Skill revision 6，`max_steps=12` 与 `max_model_attempts=12`；这是实现配置，不是用户指定的输入输出上限。不要直接恢复预算已耗尽的旧任务或偷偷改旧快照。

交接前刚完成只读定位，尚未修改预算或发新任务：留存 calls 已核对，共 12 次模型请求、28 次 document_read、1 次 kb_search、2 次检查工具调用；前 10 轮用于资料读取，后两轮送检。应减少重复或无关导航读取，安排读取/修订/最终输出预算。新 Agent 适当增加明确调用预算是候选办法，**尚未实现、未验证**；不要一边加额度一边无休止重跑。若向模型注入动态剩余预算，必须随模型意图冻结，不能重放时用当前值重新生成历史请求。

完成证据：同一固定问题得到完整最终结果；最后送检草稿与最终结果一致，失败可见；真实 usage 有记录且没有未知计量。只有执行完成仍不能关闭下面的内容质量任务。

## 2. task:research-quality — 报告真实可用

Owner：Futures `futures/report.go`、`report_evidence.go` 等检查与展示，集成 `packs/futures` 方法和真实资料流程。

固定豆粕、分类基准 2026-10-09、相同四问题和十份输入资料。核心问题是进口/到港/压榨衔接、同来源两期库存、最近周实绩与预估、10–12 月估计及长期背景。保留实际来源冲突和获取限制；网址发现此前由 Codex 辅助，不宣称 Agent 自主全网搜索。

现存草稿问题：重新编号导致问题文字引用错位；指标/样本名混入统计月份；部分 document_id/引文不完整；不同口径比较；把已经有的九月到港资料列成缺口；AI 摘要和推断日期未充分区分。规则匹配失败也可能是检查器覆盖有限，不能将所有 warning 当原数据为假，更不能改写引文或删重要资料换绿灯。

建议先审查完整草稿、原文与检查反馈，区分真正内容错误、协议负担和规则误报，最小修正，再只做一次有界真实验收。不要把几十条重复规则说明当最终业务答案。完成证据：四个问题都有相关实质证据和清楚边界，来源可回读，样本/日期/性质正确，至少成立的同口径对比可复算，未取得数据有实际补数过程而非一串空缺。

## 3. task:continuation-ui — 继续任务与页面收尾

Owner：Console、Futures、Runtime。阶段草稿回读已完成，**失败任务自动接续没有实现**。明确哪些中断可原任务恢复、哪些须固定新版本新建任务；不要把“再提交”伪装成不会重复效果的恢复。逐页完成 Agent 编辑/试运行/发布、ToolHub 检测、资料上传/检索、工作记忆、运行详情、服务状态和业务页的桌面/窄屏/空/加载/失败流程。先参考已有 UI 验证，避免重复已关闭场景。

## 4. task:service-retirement — 拆仓最后的迁移与旧覆盖退役

Owner：各服务及集成。读取 [旧覆盖移交矩阵](../p2-linux-cutover.md)、[独立部署](../independent-deployment.md)、[Runtime 权限退役](../runtime-access-retirement-20261013.md)。不能直接删除主仓历史业务实现而丢测试，也不能因旧二进制回滚需要权限就宣称已撤权。尤其检查 ENOSPC、Sandbox、Telemetry、Knowledge live 后端覆盖的新 Owner 版本。各 Owner 承担 DDL；Worker/Runtime 和 Indexer/Knowledge 保留窄事务协议。

## 5. task:storage-lifecycle — 明确存储生命周期并补测

Owner：Harness/Runtime/Worker/Storage。已有驻留事件释放、工作状态、归档/回查、Compact 和恢复证据；参见 [存储决策](../architecture/dsh-source-and-storage-decision.md)、[联合测量](../resident-joint-acceptance-20261013.md)、[生命周期](../resident-lifecycle-20261013.md)。补剩余缓存策略、失败/取消时资源退出及当前引擎的必要测量。永久资料、恢复回执、发布包、备份不可当缓存自动删。原生 Session 快速快照不是当前前置要求：已有完整冻结回放测量，只有新证据表明必要再做核心修改。

## 6. task:faults-and-resources — 关闭剩余故障与资源验收

依据 W07–W12/W14 和已有故障报告列缺口，只补受本轮变更影响或尚未覆盖的场景。检查双 Worker 接管、取消、丢回复、未知效果、Compact、数据库暂失、磁盘空间、单服务回退；测整个平台+数据库的连续任务资源，说明样本、口径和限制。历史单进程/部分服务样本不能当整个平台上界。

## 7. task:latest-recovery — 最新完整状态备份和实际恢复

在原电脑维护窗口执行统一 backup 与 restore-check；不能只看 dump 文件。须覆盖最新资料、任务、Agent/Skill/凭证版本、配置和发布组合。当前已验证备份早于最近资料与草稿投影安装。恢复到隔离环境，不启动旧任务或真实外部效果；核对资料/权限/引用/受保护凭证可解密。DPAPI 依赖原 Windows 用户，不保证朋友机器可解密。

## 8. task:final-ci — 最后一次统一验收与交付

本机核心验收完成后再执行。检查 15 仓触发器，保留一次手动/reusable 汇总，明确 runner 预算；不要全部启用 push/PR CI。收集固定源码/安装版本、真实测试与失败、入口/运维手册、未配置扩展和下一阶段事项，由独立评审逐要求复核后才可完成 Goal。

## 新环境额外缺口

`task:fresh-windows-bootstrap`：仅在以后明确要初始化新 Windows 时适用，不是朋友 Mac 开工的前提。当前 Windows 操作链主要服务已有 catalog；Linux provision 不能直接当新 Windows 的一键初始化。未来重建时仍须检查受保护身份、Owner 迁移和固定发布登记。朋友当前先按 [Mac 环境说明](environment.md) 做独立开发与验证，不照搬原用户的密钥或执行旧 `Start -Migrate`。

[Mac Telemetry/Runtime Owner 增量](macos-telemetry-owner-20261015.md)补本域事务/投递协议覆盖与确认回包边界，不代表真实 Langfuse、持续循环、独立登录或完整组合通过。服务退役、最终统一 CI、七阶段和 W01–W14 均保持原范围。

## Mac 原生笔记与未知效果增量（2026-10-15）

[本次记录](macos-native-notes-and-unknown-20261015.md)推进 W09 的自然过期、冻结回执、续订/撤回和两类并发 head 冲突，以及 W10/W14 的独立 native-v4 未知效果保留、取消后显式核对、同 Worker 后续任务及 Node 退出/Storage 留存。Owner 笔记 2 顶层与 2 子场景通过（race，10.533 秒，零 skip）；独立进程 1 项通过（仅测试驱动 race，5.417 秒，零 skip）。前者是内存 archive/合成回执/本地回调丢返回，后者是真实服务/Node/Storage 与受控外部效果，不能合并成全平台生命周期或资源验收。首轮 ToolHub resolver 夹具遗漏导致提交 403 的失败继续留存。

P0/P1/P2/P2.5/P3/P4/P5 与 W01–W14 全范围和既有状态不变；旧测试/权限退役、长历史 Compact、永久资料生命周期、持续资源上界、完整 UI、研究完成与内容质量、最终统一 CI 均继续按原计划。没有自动核对未知效果或重新执行原未知任务的授权机制变化；Windows DPAPI、受管发布、原库恢复仍待目标环境复验。

## Mac Console 原生面板与受限恢复增量（2026-10-15）

[本次记录](macos-console-native-and-state-recovery-20261015.md)修复 budget-v3/native-v4 工作状态面板与归档清单识别，27 项 Web 检查和 TypeScript 通过，匹配 Console BFF/Web 包已安装；只更新 control，九个非目标实例保持。Runtime 新增 3 个顶层/4 个子场景的 Owner PostgreSQL/HTTP 恢复验证，零 fail/skip。回执丢失由回调夹具实现，归档为内存；既有 source-state 受限恢复协议、failed 通用 /resume 和自动 continuation 状态不变。

它不等于浏览器真实流程、官方 Node 端到端恢复、供应商失败后续写或研究质量通过。P0/P1/P2/P2.5/P3/P4/P5、W01–W14 全范围与既有状态保留；完整 UI、旧覆盖/权限退役、存储生命周期、持续资源、研究交付、Windows 专项及最终统一 CI 继续按原计划。

## Mac 失败任务只读接续预览（2026-10-15）

[本次记录](macos-continuation-preview-20261015.md)增加 Runtime control 专用 GET 预览，固定 read_only=true/action_available=false；对严格保留 native HTTP503 回执、全族未决状态、冻结配置/归档元数据和原预算作一致快照分类。Owner 7 顶层（6 新增、1 既有 peer）及 17 子项通过、零 fail/skip；已独立安装本机 Runtime 包并只读观察既存 Mac 任务，九个非目标实例保持。

同帧候选不是执行许可，也不证明供应商已恢复、归档字节当前可读或研究可成稿。旧 failed /resume 与当前 Console 按钮未被此 GET 加上守卫，仍须执行时锁内重验、幂等动作回执/丢回复核对、受控自动接续与完整 UI。P0/P1/P2/P2.5/P3/P4/P5、W01–W14 及全部旧范围保持；研究质量、服务/权限退役、生命周期/持续资源、Windows 专项和最终统一 CI 继续按原计划。

## Mac native 新模型尝试修订守卫（2026-10-15）

[本次记录](macos-native-attempt-revision-20261015.md)修复native冻结旧intent在正常规则更新后仍能取得新attempt的窗口。Owner旧码2 fail/2 pass、修复4 pass；相邻32顶层38子场景race通过，零skip。Worker固定精确execution模块，独立旧/新Worker与官方Node、合成TLS模型3场景通过，首轮JSON键序断言失败保留。成功缓存/冻结回复继续重放，原失败账单和未知usage保留。两个常驻Worker已实际替换，Runtime HTTP与其余七实例保持原版本；观察中的标量计数相同不代表整库不可变。

该 guard 不是完整 continuation action：还需写动作事务内重验、幂等回执与丢回复回读、受控自动接续、配置变更后的新任务承接与 UI。P0/P1/P2/P2.5/P3/P4/P5、W01–W14 全范围及旧状态保持；研究质量、服务/权限退役、生命周期/持续资源、Windows 专项和最终统一 CI 按原计划继续。

## Mac 显式接续动作与Console恢复源码（2026-10-15）

[本次记录](macos-continuation-action-20261015.md)推进受限native失败任务的手动同任务接续：事务内重新核验、幂等接受/拒绝回执、失联后按原ID回读/重发及Console持久化待确认请求已实现源码。Focused19顶层/42子项通过（新增Owner7/11）；广泛Runtime112/195通过并保留27显式skip，另一次独立Worker/官方Node/合成TLS验证1/3通过；Console Web36项及Go/TypeScript/构建通过。

本轮没有常驻库迁移或Runtime/Console部署，现装组合不变；组件/客户端检查不能代替真实hook、多标签和浏览器流程。PG COMMIT网络回包丢失、独立SQL账号登录、其他opt-in故障、Futures业务流、真实供应商成稿及自动策略仍开放。新永久回执也纳入生命周期工作。P0/P1/P2/P2.5/P3/P4/P5与W01–W14的完整范围和旧状态保持；研究质量、服务权限退役、持续资源、Windows专项及最终统一CI继续按原计划。
