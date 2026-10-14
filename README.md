# Agent OS

面向多个业务的 Agent 平台。DeepSeek Harness（DSH）负责 Agent 执行循环与上下文压缩；Go 服务负责持久化调度、工具与资料管理；React / TypeScript 提供统一中台和独立的期货研究工作台。

## 当前可用的两个入口

- 能力中台：<http://127.0.0.1:8090>。管理自定义 Agent、提示词、Skill、MCP、知识库、工作记忆和运行记录；Agent 编辑器右侧试运行，在“发布”页设置业务入口。
- 期货研究工作台：<http://127.0.0.1:8098>。通过“供给与库存”“资料交叉核验”“资料时间线”发起研究，查看任务进度和结果。业务界面不暴露 Skill、MCP 和模型配置。

当前正在进行 **v0.6 端到端交付**。Windows 新根任务已使用固定源码构建的 DSH，历史任务保留原包与引擎。真实 DeepSeek 的知识库回读、结构化工作状态、来源回执与笔记落盘已联调，并经过完整备份还原，见[源码执行器激活验收](docs/source-engine-activation-20261013.md)。父子 Agent、MCP/Skill 和业务入口的其他历史成果见[交付账本](docs/delivery-v0.6.md)。完整内存边界、UI 和真实研究验收仍在进行；没有接入全品种基本面数据库，不把单篇联调当作研究覆盖率。

**最新核对：整体尚未交付。** 双 Worker 在内的 12 个实例运行、核心就绪。原生模型能力和 Knowledge/Storage 读取修复已安装；Runtime `e6c8b93`、Futures `f40a8f8` 已支持在正式页面切换失败任务的阶段草稿、查看检查反馈和回查原文，见[实际安装与验证](docs/research-draft-visibility-20261014.md)。最新真实研究任务在两轮草稿检查后耗尽 12 次模型请求额度，没有最终答复，草稿仍有日期、引用及比较问题，研究质量未通过。旧实现/权限退役、完整 UI、剩余故障与资源测量、最新状态备份恢复及最终一次统一 CI 仍有工作。详见[当前交付状态](docs/windows-single-machine-plan.md#当前交付状态最新核对)。下面各时间段保留实施时的历史状态。

**2026-10-14 当前进度**：Console 网页采集、原文预览和保存已安装。一份真实国家统计局网页已在浏览器完成采集、入库、下载及检索；重复保存不新增文件，包含新资料的完整备份已实际隔离恢复，见[中台采集与恢复验收](docs/console-capture-acceptance-20261014.md)。Sources/Knowledge 独立迁移、发布兼容及旧资料恢复见[Sources 记录](docs/sources-owner-migration-20261014.md)和[Knowledge 记录](docs/capture-import-bridge-20261014.md)。这不等于“采集 → 入库 → 研究报告”全部完成：已有真实模型报告仍存在时间分类和事实表述问题，研究质量验收未通过。其余页面、服务退役和故障缺口见[单机交付计划](docs/windows-single-machine-plan.md)。

下午增量：关机后原库及12进程已恢复，Runtime 修复回查参数与 MCP 执行期限，原豆粕任务恢复完成。结构化报告的17处原句可定位到任务留存记录，比较和字段质量仍不通过；待核提示不代表原文数据为假。见[原任务恢复与具体缺陷](docs/structured-research-acceptance-20261014.md)，不将执行完成写成研究验收完成。

最新研究检查工具已正式安装、验活并绑定 Agent；相同原稿的62条检查问题可在5,576字节的完整MCP结果内返回。随后真实成稿暴露执行器的上下文拒绝、预算预留和固定输出上限问题，见[真实失败记录](docs/research-feedback-20261014.md)。新的 budget-v3 候选已修复对应协议，完成固定包搬迁与真实 Worker/Node/PostgreSQL 联合恢复验收；[证据和边界](docs/budget-engine-acceptance-20261014.md)明确列出夹具范围。已正式安装并完成实际备份还原、单服务升级回滚及官方供应商验证；同一研究任务未再被4096截断，但JSON前的多余说明仍使报告格式检查不通过。用户新增的[按模型能力管理长度](docs/architecture/model-native-limits.md)已纳入计划，尚未部署。

## 源码仓库与交付状态

各服务的源码、构建和维护说明已拆到独立仓库。本仓库是平台总入口，负责版本组合、本机运维、业务包及整体验收；下面的链接均指向仓库默认分支。各项目首页统一使用中文，说明职责、部署方法、验证范围和未完成项。`main` 保存已提交的开发成果，不表示整个平台已经通过最终交付验收，也不自动替换本机安装版本。新改动继续使用开发分支；未提交的迁移草稿、密钥、数据库和研究私有资料不上传。

2026-10-14 按所有者要求整理对外展示：本仓库及下方 14 个仓库同步默认分支与开发分支，保留固定依赖和历史验收记录。各仓库 Actions 日常保持禁用；本次文档和源码同步不触发 CI，最终统一 CI 按整体验收计划执行。

| 仓库 | 职责 |
| --- | --- |
| [Console](https://github.com/euler-gaozl/agent-os-console) | 共用中台 Web 与 BFF |
| [Futures](https://github.com/euler-gaozl/agent-os-futures) | 独立期货研究工作台与 BFF |
| [Registry](https://github.com/euler-gaozl/agent-os-registry) | Agent、提示词与资源固定版本 |
| [ToolHub](https://github.com/euler-gaozl/agent-os-toolhub) | Skill/MCP 登记、检测、验活和启停 |
| [Runtime](https://github.com/euler-gaozl/agent-os-runtime) | 执行状态、回执、约束和任务恢复 |
| [Worker](https://github.com/euler-gaozl/agent-os-worker) | 多实例任务执行与固定 Harness 包 |
| [Knowledge](https://github.com/euler-gaozl/agent-os-knowledge) | 资料、检索与索引协议 |
| [Indexer](https://github.com/euler-gaozl/agent-os-indexer) | 独立后台索引进程 |
| [Storage](https://github.com/euler-gaozl/agent-os-storage) | 不可变产物、引用与分页读取 |
| [Sources](https://github.com/euler-gaozl/agent-os-sources) | 有边界的公开资料采集和留存 |
| [Sandbox](https://github.com/euler-gaozl/agent-os-sandbox) | 隔离执行服务；本机执行后端尚未配置 |
| [Telemetry](https://github.com/euler-gaozl/agent-os-telemetry) | 事件接收与遥测导出；本机当前零实例 |
| [Harness](https://github.com/euler-gaozl/agent-os-harness) | 固定 DSH 源码、持久化适配和上下文管理 |
| [SDK](https://github.com/euler-gaozl/agent-os-sdk) | 固定公共协议与传输设施 |

当前未关闭项见 [Windows 单机交付计划](docs/windows-single-machine-plan.md)：完整页面流程、真实研究成稿质量与采集证据闭环、剩余迁移/旧权限退役及故障验收。各仓库 Actions 日常保持禁用，本机交付验收完成后集中运行一次最终 CI；代码同步不等于 CI 或生产验收通过。集成候选源码固定在 [service-sources.json](deploy/service-sources.json)，实际安装版本以本机 `ops/Platform.ps1 status` 和发布 catalog 为准。

## 已实现

| 模块 | 行为 |
| --- | --- |
| Registry | 不可变资源版本；Agent 绑定指定版本的提示词、Skill、MCP、知识库和子 Agent |
| Runtime + Worker + DSH | Go 多实例领取与 fencing；固定源码 DSH 执行新任务，保留历史引擎；持久化工作状态、模型/工具回执重放、父子任务、约束修订、取消与 UNKNOWN 核对 |
| ToolHub | MCP/Skill 不可变版本；包校验、验活、定义漂移检查、启停和审计；Runtime 保持执行效果与回执的事务边界 |
| Storage | 独立管理不可变内容哈希产物、引用根和分页回读；Agent 持久化笔记归 Runtime，与执行回执原子提交 |
| Knowledge | 原文件上传与正文提取；有界词法检索及 Milvus/LightRAG 适配；后台索引、来源回查；[历史原网页/全文附件与备份恢复](docs/knowledge-source-archives-20261013.md) |
| Console | 资源导入、Agent 编辑/试运行/发布、知识库上传/检索测试、运行/服务状态、加密凭证写入 |
| Futures | 独立构建、端口和 BFF；直接调用发布的 Agent 确定版本，返回业务所需的进度与结果 |
| Sources | 独立公开资料 MCP；管理员指定 HTTPS 域名、原始响应哈希留存、文本分页与定位；不绕过授权来源 |

“工作记忆”保留 Agent 记录的事实、来源和有效状态。修订生成新版本，撤回只影响有效检索，原文、理由和修改记录可追溯；同一操作在丢回复后使用原请求重试。具体权限、旧版本升级屏障和历史分叉限制见[笔记生命周期契约](docs/architecture/notes-lifecycle.md)。

Sandbox 的真实 Docker 隔离、主动干扰截止进程和执行服务强杀恢复已通过 Linux CI；本机没有 Docker，执行功能保持停用。Telemetry 已通过独立数据库接收和受控 OTLP 导出，真实 Langfuse v4.56 后端已通过接收、回读和重投契约测试（至少一次投递可能产生重复观测）。知识库不等于已校验事实库，图谱关系和检索结果必须回查原始来源。

## 启动

正式源码目录：`D:\workspace\agent-platform\repos\agent-os`。运行配置、数据库、日志和固定发布文件位于 `D:\workspace\agent-platform\local`，与源码分开。Windows 使用 PowerShell 7、Go 1.27.2、Node 24、pnpm 11.25.0、PostgreSQL 18。共享工具位于 `D:\workspace\.tools`；不要另建 C 盘副本。

```powershell
& D:\workspace\agent-platform\ops\Platform.ps1 status
# 已停止时启动现有数据库及固定发布版本
& D:\workspace\agent-platform\ops\Platform.ps1 start -Workers 2
```

本机保留 12 个进程，包括两个 Worker。兼容程序更新使用 `Platform.ps1 build/update/rollback`，中断的发布使用 `release-recover`；构建只生成候选包，不改变当前版本。完整依赖、配置和协议检查见 [Windows 发布恢复](docs/windows-release-recovery-20261012.md)。版本化部署不会因配置丢失自动运行管理员迁移；跨 schema/配置变更需单独协调。模型密钥在中台“设置”中保存，Agent 中的凭证名称需与其一致。公开资料适配器可用 `node scripts/enable-public-sources.mjs` 登记到本机 ToolHub 并绑定期货 Agent（可重复执行，不重复生成相同版本）。历史服务配置说明见[v0.5 操作手册](docs/operations-v0.5.md)。

## 架构与验收

- [v0.5 服务与数据边界](docs/architecture/contracts-v0.5.md)
- [独立服务发布、迁移与回滚](docs/independent-deployment.md)
- [Web 设计](docs/ui-design.md)与[页面及异步交互验收](docs/ui-validation-v0.6.md)
- [v0.6 服务与数据域架构图](docs/architecture/agent-os-v0.6.mmd)
- [DSH 执行、恢复与 Agent 发布契约](docs/architecture/contracts-v0.4.md)
- [DSH 适配层与固定依赖](harness/README.md)
- [未变更的服务与存储契约（v0.3）](docs/architecture/contracts-v0.3.md)
- [LightRAG、Milvus 与 Embedding 选择](docs/rag-selection.md)
- [本轮验证记录与未覆盖范围](docs/validation-v0.5.md)
- [后续工作](docs/architecture/next-steps.md)
- [v0.1 独立架构评审原文](docs/architecture/agent-os-v0.1-independent-review.txt)（历史基线，不是本版代码审计）

各服务具有独立二进制、镜像、配置、服务身份和发布入口，12 个部署单位已通过 Linux CI 的单独部署检查，共用中台 Web。ToolHub/Knowledge/Sources 拥有各自 schema；Sandbox/Telemetry 通过 HTTP 对接 Runtime；Console/Futures 无数据库权限。Runtime/Worker 属于同一执行数据域，包含持久化笔记；Storage 已移除笔记表依赖，产物通过 HTTP 读写，独立数据库及 Linux 容器全链路测试通过。百万文档 / 千万分块已有受限检索实测；平台 2 核 / 4 GB 下的受控 12 任务混合负载已通过，物理节点 HA 仍待验收；参见[交付账本](docs/delivery-v0.6.md)，不能将一次容量测试写成全部生产能力。

期货应用只负责资料收集、校验、分类、留存和客观事实反馈。预测、交易方向与操作决定由用户负责。
