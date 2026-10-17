# 项目群维护知识库

**2026-10-17 最新交接：** 用户要求交给 DeepSeek，交接后暂停原 Codex Goal。先读 [DeepSeek详细接续](deepseek-handoff-20261017.md) 和 [开工提示词](deepseek-start-prompt.txt)。进度、仓库清单、本体已按本次现场核对更新；执行机器尚未指定，先识别环境。下方早期“当前Mac/继续Windows”均按时间作为历史，不构成本次环境选择。

**2026-10-17 后续增量：** [DS-01 非数值论据绑定原文](windows-ds01-statements-20261017.md) 已实现并安装；[DS-02 未就绪成稿](windows-ds02-finalization-investigation-20261017.md) 的 guarded-v7 单次续接与 v6+v7 双产物已安装，默认 v7，v6 失败任务保留重放能力；[DS-03 库存/合同真实四问](windows-ds03-inventory-20261017.md) 已产出报告并通过独立内容复核（ACCEPT）；[DS-04 中台/业务浏览器矩阵](windows-ds04-ui-browser-20261017.md) 已通过主要页面/窄屏/交互检查并修复本地业务入口；[DS-05 执行域权限退役](windows-ds05-access-retirement-20261017.md) 已正式收缩 ACL，Worker 最小权限与 Telemetry inbox/HTTP 能力就绪，撤权后合成任务完成 note_save/run_recall，双 Worker 杀 owner 后接管完成；临时 Telemetry 实例把 3,992 条事件导出到本机 mock Langfuse（非真实供应商/managed）；[DS-06 存储生命周期](windows-ds06-storage-lifecycle-20261017.md) 已完成真实笔记修订/过期/并发写者（200+409）/撤回、Windows 128/512/2048 步 Compact/重放测量，以及 20 轮长任务强杀/接管（step 8→21 完成）；[DS-07 整平台负载](windows-ds07-platform-load-20261017.md) 已跑 30.1 分钟 24 任务 soak（24/24），并完成 8 秒行锁恢复与 30 秒行锁显式失败（model attempt budget exhausted）；[DS-08 最终备份与隔离恢复](windows-ds08-restore-20261017.md) 已用 post-DS05 快照在独立 PostgreSQL 集群通过 46 个关系、10 个角色、3 条凭据、2 个 Worker bundle 与离线 Harness 校验。整体目标仍未完成；Telemetry 实际导出/旧实现删除、DS-06 长任务中断/并发写者/RSS 上界、DS-07 30–60 分钟 soak/慢查询/故障组合、DS-09 集中 CI 仍待做。

**当前入口（2026-10-17）：[Windows 接回与交付续做](windows-resumption-20261017.md)。** 用户已让原 Windows 接回并继续；以下 Mac 开工说明保留为环境隔离历史。最新源码已恢复并同步开发分支，完整产品仍待交付。

这是一份随 Git 版本维护、可直接由 Codex 读取的知识库，以及 JSON 形式的概念/关系映射。它不依赖额外数据库、Embedding、向量库或模型服务。以后可作为 RAG 输入；目前没有宣称已经建立在线知识图谱服务。

## 先读这四份

**接手者先识别实际机器，再读 [environment.md](environment.md) 和 [environments.json](environments.json)，不要从旧Mac交接推断当前环境。** 原电脑的可用状态不能推导出 Mac 的可用状态，路径和 localhost 地址也不能跨机器解释。

1. [objective.md](objective.md)：原 Goal 全文、有效用户约束和验收矩阵入口。
2. [current-state.md](current-state.md)：目标进度与原 Windows 的历史观测；不是 Mac 现场。
3. [backlog.md](backlog.md)：具体下一步、Owner、环境依赖及完成证据。
4. [architecture.md](architecture.md)：可跨环境理解的逻辑架构和数据所有权。

之后按任务读取 [architecture.md](architecture.md)、[repositories.json](repositories.json)、[ontology.json](ontology.json)，以及各仓库 AGENTS.md / README。不要一次把全部历史日志塞进上下文。

## 权威与冲突处理

当前代码、实际数据库/发布 catalog、运行观测和对应版本的原始证据优先。本目录是带时间的交接快照；它定位权威来源，不替代权威来源。原始证据在原电脑，GitHub 上的 Markdown 只是验收说明，朋友未拿到证据时应标为“原维护者已记录，尚未独立复验”。

[Windows 单机计划](../windows-single-machine-plan.md) 的目标和 W01–W14 是完整验收范围。历史文档中“当前”“未安装”经常只针对当时那次增量；先读文档最新状态段，再比较提交和安装版本。发现冲突要记录并核对，不能挑容易完成的那一版。

| 内容 | 权威位置 |
| --- | --- |
| 工作规则 | 主仓及目标服务的 AGENTS.md、用户后续明确指令 |
| 开发源码 | 各独立仓库；交接基线见 repositories.json |
| 集成构建选择 | ../../deploy/service-sources.json；不等于各仓库 HEAD |
| 实际安装 | 原电脑 local/releases/current.json 及固定发布 manifest |
| 真实任务状态和结果 | Runtime；Futures 只做业务展示，不直接写运行库 |
| 研究事实依据 | 任务实际读取并留存的原文；模型摘要不是权威事实 |
| 当前剩余工作 | backlog.md 对照原计划逐条关闭，不自动删原要求 |

## 本体映射怎么用

`ontology.json` 提供类型、实体和有方向的关系。实体包括项目、仓库、服务、数据域、执行器、能力、阶段、验收项、待办和证据说明。关系说明“谁实现什么、谁依赖谁、谁拥有数据、用什么验收、还缺什么”。

`repositories.json` 提供实际 URL、分支、交接基线提交、集成 pin、安装提交。`ontology.json` 不复制密钥或数据库内容；机器处理时以实体 ID 连接上述文件。关系是人工依据代码与文档核对的架构索引，不是运行时自动发现或证明。

`environments.json` 区分 `environment:maintainer-macos`（朋友的独立开发环境）、`environment:owner-windows`（原电脑的历史部署与后续专项验收）和 `environment:future-linux`（后续服务器目标）。仓库 `installed`、服务部署观测、历史真实任务与私有证据均带原 Windows 的环境归属。源码/接口可跨平台阅读，安装事实和访问授权不可继承。Mac 的测试结果单独记录，不覆盖原证据，也不把未运行的 Windows 用例写成通过。

例如：`task:research-completion → affects → service:futures / service:runtime / service:worker`；`service:worker → consumes_fixed_protocol → service:runtime`；`service:runtime → owns → domain:execution`。沿关系找到 Owner 后，读取该仓库实际接口再改。

## 以后如何更新

每完成一个有意义的增量，更新对应待办状态、源码提交、安装情况、验证范围和证据位置。把失败、未执行和第三方夹具保留下来；测试“通过”不能覆盖尚未验收的更大范围。资料与代码是否公开分别管理。`ontology.json` 的实体 ID 稳定，删除或更名时同步修正关系；不得出现悬空引用。

新维护者首次接手先核对远端、干净工作区及本机环境，然后建立自己的完整 Goal。旧聊天的 Goal、权限、内存、后台工具会话和 Windows 用户加密上下文不会随着 Git 仓库转移。

## Mac 接手进展（2026-10-15）

已在独立 Mac 核对 15 仓，见[首轮环境与源码记录](macos-development-20261015.md)和[源码核对](macos-source-audit-20261015.json)。后续[真实供应商合成研究、页面与 Storage 增量](macos-research-and-storage-20261015.md)记录两次新任务、格式修复和仍未通过的回答质量，以及本地 UI 代码验证、真实 Storage 丢确认恢复。各记录按时间保留；不覆盖下面的原交接检查或 current-state.md 中的 Windows 历史。

随后[完整 BFF/Web 包、Storage ENOSPC 与第三次研究记录](macos-package-enospc-and-answer-contract-20261015.md)追加匹配产物实际安装、仍未执行的浏览器验收，以及供应商 HTTP 503 导致无成稿且 usage 未知的新任务。独立 [Storage ENOSPC 验收](../storage-enospc-macos-20261015.md)仅推进 P2 的产物/引用故障覆盖，完整阶段和 W01–W14 范围继续保留。

最新 [Runtime Owner ENOSPC 增量](macos-runtime-enospc-20261015.md)：1 项真实故障测试通过（1.21 秒，非 race，零 skip）。仅推进 P2 自有事务故障覆盖；内存归档与合成回执不代表独立 Worker/Storage 联调，完整阶段、W01–W14 和旧覆盖仍保留。

[第四次同题研究验证与 UI 增量](macos-research-verification-and-ui-20261015.md)：提交前独立判据已固定；新任务首请求仍为供应商 503、无稿，不能形成新内容质量结论。三个旧任务和历史范围保持；详情读取 UI 已安装匹配包，浏览器待验收。

## 本次交接检查

15 仓开发分支与远端核对、Actions 禁用状态、知识库相对链接、JSON 实体/关系及本地提交可解析性已检查；新增文件与暂存差异经 gitleaks 扫描未发现秘密值。独立评估 Agent 做了文档和相关源码的静态审查，指出知识库定义归 Registry、legacy 引擎兼容分支及 Telemetry claim/ack 调用方向三处问题，已修正。仓库节点的 `inventory` 用 `file` 和 `repository_id` 连接版本清单，不冒充 JSON Pointer。

本次没有重新运行平台测试，没有模型付费调用，没有触发 CI；静态交接审查不能代替原目标的剩余验收。检查证据保存在原电脑 `ops/maintainer-handoff.path` 指向的目录。

[Telemetry/Runtime Owner 局部移交](macos-telemetry-owner-20261015.md)记录有界确认缺陷 red-green、隔离 PostgreSQL/HTTP 夹具及保留的真实后端验收；未部署服务，旧覆盖与完整目标继续保留。

[原生笔记与未知外部效果增量](macos-native-notes-and-unknown-20261015.md)分别记录 Owner 自然过期/撤回/并发冲突与实际 native-v4 进程的 TCP 丢回包、取消和显式核对。两层范围不同，首轮夹具失败保留；真实供应商、业务、完整生命周期/资源及目标环境验收仍开放。

[Console 原生引擎面板与工作状态恢复边界](macos-console-native-and-state-recovery-20261015.md)记录固定四引擎显示修复、匹配本机 Console 包，以及单独的 Runtime Owner 恢复/拒绝验证。组件检查与 HTTP 夹具各自限界，浏览器、官方 Node 恢复和完整 continuation 仍待验收。

[失败任务只读接续预览](macos-continuation-preview-20261015.md)记录 Runtime 新增 control GET 契约、Owner 测试、本机 Runtime 包及既存 Mac 失败任务的只读观察。candidate 不代表执行许可；旧 /resume、前端接入和完整续跑仍开放，未重试供应商或改变旧任务。

[native 模型新尝试规则修订守卫](macos-native-attempt-revision-20261015.md)记录旧冻结intent在约束更新后错误准入的修复、Owner red-green、旧/新Worker的3场景实测及两个本机Worker实际更新。Runtime HTTP安装、execution模块与测试源码分别记录；完整接续动作及UI仍开放。

[显式接续动作与Console回执恢复](macos-continuation-action-20261015.md)记录Runtime长期幂等回执、原生旧恢复入口的源码变更、Console待确认请求流程及分层实测。新源码尚未迁移或部署到常驻环境；浏览器、多标签、真实供应商/业务和完整自动接续仍待验收。
