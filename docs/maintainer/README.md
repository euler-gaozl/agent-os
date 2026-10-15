# 项目群维护知识库

这是一份随 Git 版本维护、可直接由 Codex 读取的知识库，以及 JSON 形式的概念/关系映射。它不依赖额外数据库、Embedding、向量库或模型服务。以后可作为 RAG 输入；目前没有宣称已经建立在线知识图谱服务。

## 先读这四份

**接手者已确定使用自己的 Mac。先读 [environment.md](environment.md) 和 [environments.json](environments.json)，再读下面四类资料。** 原电脑的可用状态不能推导出 Mac 的可用状态，路径和 localhost 地址也不能跨机器解释。

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

## 本次交接检查

15 仓开发分支与远端核对、Actions 禁用状态、知识库相对链接、JSON 实体/关系及本地提交可解析性已检查；新增文件与暂存差异经 gitleaks 扫描未发现秘密值。独立评估 Agent 做了文档和相关源码的静态审查，指出知识库定义归 Registry、legacy 引擎兼容分支及 Telemetry claim/ack 调用方向三处问题，已修正。仓库节点的 `inventory` 用 `file` 和 `repository_id` 连接版本清单，不冒充 JSON Pointer。

本次没有重新运行平台测试，没有模型付费调用，没有触发 CI；静态交接审查不能代替原目标的剩余验收。检查证据保存在原电脑 `ops/maintainer-handoff.path` 指向的目录。
