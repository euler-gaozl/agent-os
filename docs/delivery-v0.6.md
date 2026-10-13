# 端到端交付账本

## 2026-10-13 DSH 历史内存测量

Harness 新增长历史/新进程回放基准，正式源码引擎和部署未改。128 / 512 / 2,048 步固定工作集、真实 DSH 自动 Compact 仍出现保留堆增长（13.1 / 19.7 / 48.1 MiB）；新进程重放为 0.8 / 2.6 / 10.1 秒。六次运行完成，逐帧语义请求、事件数量/类型与冻结回包 hash 链核对通过。原始事件资料仍完整保留；不把此结果写成内存有界通过。模型/工具/Runtime 状态都是测试夹具，未用正式数据库或供应商。原始证据 `local/evidence/dsh-memory-baseline-0e3b3a7a0b56427b94e138b75dae77f4`，设计边界见 Harness `docs/resident-history-design.md` 及[存储决策](architecture/dsh-source-and-storage-decision.md)。P2.5 继续实现 Session 核心驻留结构、消费者水位和控制状态；不能直接删除日志数组。Actions 未运行。

## 2026-10-13 源码执行器发布增量

最新：已正式激活源码 DSH、新 Runtime/双 Worker/Console，13 次实际升级回退与默认配置往返通过；官方 DeepSeek 合成资料任务完成工作状态落盘、真实来源回执和笔记回读。新基线备份实际隔离恢复通过 44 个关系及全部 3,008 个发布文件，正式 12 实例重启后状态仍可读。首次失败、预算触顶和剩余限制见[实际激活记录](source-engine-activation-20261013.md)。完整 Goal 仍未完成，GitHub Actions 保持禁用。

Windows 构建新增固定源码 Harness 完整资产；Runtime/Worker 的启动、升级、回滚及 pending 恢复先核对实际生效配置、工作状态表与保留任务。新增默认执行器配置事务，48 项真实合成进程/数据库检查覆盖配置及恢复中断、双 Worker 绑定、超时清理和程序回退。源码锁选择三项新候选，正式部署尚未改变。独立评审发现的问题及原始测试、实际构建包、剩余验收见[源码发布记录](source-engine-release-20261013.md)；正式备份迁移、实际激活及后续 P2.5–P5 仍继续。

## 2026-10-12 P2 第二批服务源码

后续实际更新暴露旧配置默认地址遗漏，已自动恢复旧版并修复六个 Owner。修正版五个启用服务各 update → rollback → update，旧资料/接口字节哈希不变，Runtime 当前 PID/实例 ID/10 秒内心跳验证通过；Telemetry 仍为零实例。失败与成功报告均保留于 [P2 记录](independent-sources-p2.md)。不能把首次仅 readiness 的成功称为服务状态全链路通过；本次已补这项缺口。六个剩余服务、源码 DSH、完整 UI 与真实 Agent/业务验收继续执行。

ToolHub、Storage、Sources 的私有源码仓库与 draft PR 已建立，SDK 固定依赖随库保存；独立 clone 在空模块缓存且关闭网络依赖条件下，真实数据库测试、vet、构建通过。ToolHub 应用身份能够注册/检测/启用/写审计；Storage 不再携带文档/笔记 SQL；各域迁移及失败回滚通过。集成源码锁新增三仓，拒绝缺映射回退旧源码。原始证据与评审边界见 [P2 记录](independent-sources-p2.md)，新 CI 和实际更新回滚分别验收，目标保持 active。

## 2026-10-12 P2 首批独立仓库与发布接线

Registry、Sandbox、Telemetry 的独立私有仓库及 PR 已建立，规范固定 SDK/vendor 的单仓隔离检出测试与三仓 Linux/Windows CI 通过。集成按精确 Owner 提交构建，完整协议和二进制来源经核验；源码选择 10 项拒绝边界、污染 Go 环境及 StrictMode 构建通过。独立服务实际更新/回滚正在验收，其他九个服务和 P2.5–P5 尚未完成，完整 Goal 继续 active。详见 [P2 源码/发布证据](independent-sources-p2.md)。

集成 Registry `bb9a693` 的凭证边界修复已部署，本机保留两个 Worker，非目标 11 个进程未替换；内部配置名请求被拒绝，未读取敏感响应正文。不能再将旧漏洞版本作为回滚目标。随后固定三个 Owner 的实际版本切换完成：Registry/Sandbox 各 update → rollback → update 就绪且其他进程不变；Telemetry 为零实例 catalog 切换，不算真实导出联调。四个 Registry 只读接口哈希一致，最终 Doctor 通过，见上述 P2 证据。

## 2026-10-12 P2 起步与凭证边界修复

正式 SDK、Registry、Sandbox、Telemetry 源码已在分组 `repos` 下建立；SDK 的跨域 SQL、角色权限表和 schema 探针已归回服务，服务具有自己的事务迁移和测试。SDK 首个私有仓库已发布，其他服务的独立仓库、最终依赖锁和实际发布验收仍在进行，不能将提取源码写成 P2 完成。

独立评审发现旧 Registry 凭证接口会读取任意同名进程环境变量，合法服务身份可能据此获取内部配置。主仓和新 Registry 均已修正：拒绝内部配置保留名，仅保留三项明确的供应商凭证环境变量兼容，其他凭证从加密表解析。合成服务身份 HTTP 越权测试通过，未使用真实秘密值。运行版本部署核验随后单独记录；仅修改源码不代表正在运行的进程已修好。

隔离 PostgreSQL 的 `local/evidence/p2-first-services-85be4f84e89f47ad935b6ed8882093c0/result-v2.json` 记录三域迁移、重复迁移、失败事务回滚、逐项 DML 授权/应用身份就绪/跨域拒绝，以及 Registry 旧版本和加密资料回读、Telemetry 丢确认重投。验证集群已停止，模型调用为 0。这批使用最初的 SDK 构建；最终规范模块/vendor 的单仓验收需要再次记录。

拆分过程发现自制本地模块 ZIP 与 Go 规范校验不一致（Windows 换行及目录项）；已废弃该生成脚本和代理，保留失败缓存并标注 INVALID，改用 Go 官方模块下载器从固定 Git tag 获取，核对 commit/module checksum 后 vendor。没有将错误校验发布为依赖契约。旧集成提交 `400afaea` 的五项 CI 均已成功，新版本仍分别验收。

## 2026-10-12 P1 独立发布与完整恢复关卡完成

统一 Windows 维护入口已包含 build/update/rollback/release-recover，候选完整包不修改当前版本；唯一 format2 catalog 记录 current/previous/pending，进程中断后可恢复。Knowledge、两个 Worker、Console、Futures 真实逐个更新和回滚，非目标实例不变，Web 返回所选资源。兼容标签来自经版本核验的构建，配置变化、依赖篡改和跨协议发布在替换前拒绝；不承诺任意历史版本可回滚。

16 项真 Windows 发布夹具和原 8 项进程夹具在 [CI 38246524804](https://github.com/euler-gaozl/agent-os/actions/runs/38246524804) 全部通过。首次 CI 的 D 盘目录错误、三次本地失败、独立评审七项修复均保留，见[发布恢复记录](windows-release-recovery-20261012.md)。评审仅静态复核，没有冒充独立运行验证。

新备份 `local/backups/release-catalog-20261012-v1` 经全新 PostgreSQL 集群恢复：43 个表/序列及结构权限、10 个身份、2 个加密凭证和身份索引一致；17 个当前/上一版发布引用的 3,182 个文件及 470 个内部链接完成还原校验，两份 Worker 的 Harness 可从恢复目录加载。原 12 个服务冷启动后 Doctor 正常，验证库已停止。维护测试未发起付费模型调用。

P0/P1 完成，完整 Goal 继续 active。下一步 P2 正式独立仓库和每域迁移责任；P2.5 源码 DSH/存储，P3 UI、P4 实际 Agent 故障、P5 真实研究样例尚未结项。服务器、跨机 HA 和最终容量仍为后续范围，不能将本批维护闭环写成全部交付。

## 2026-10-12 P1 Windows 进程恢复

12 个实际进程已切换到原子 Job 启动方式，保留两个 Worker。启动前保存最终配置与 intent，根进程持有只读保活句柄，根退出后卡住的 Node 由 Windows 清理；启动器在 PID 落盘前退出时可重新识别并停止实例。没有增加常驻守护进程，没有改变模型配置、业务二进制或数据库。

八组 Windows 进程夹具通过；真实 Control 启动器退出 197、另一进程恢复、非目标 11 个实例身份不变，以及完整停止/启动已验收。失败、评审与限制见[进程恢复记录](windows-process-recovery-20261012.md)。供应商调用为 0，Sandbox 执行仍不可用；单服务 update/rollback 与后续目标继续执行。

上一提交 `6fe1dda` 四项 Linux CI 已全部通过：[Platform](https://github.com/euler-gaozl/agent-os/actions/runs/38236708663)、[Storage](https://github.com/euler-gaozl/agent-os/actions/runs/38236708586)、[Retrieval](https://github.com/euler-gaozl/agent-os/actions/runs/38236708589)、[Langfuse](https://github.com/euler-gaozl/agent-os/actions/runs/38236708602)。新 Windows CI 待运行，二者不混为同一测试版本。

## 2026-10-12 P1 源码与数据库物理迁移

有效源码已切换为 `D:\workspace\agent-platform\repos\agent-os`，原 PostgreSQL 为 `local\data\postgres`，旧 `.state` 原样归档于 `local\legacy-state\20261012-102142`。最终停机搬迁前后 1,948 个数据库文件 SHA-256 一致；重启 Worker 前完整数据、结构和权限指纹一致；12 个所属进程及四个业务只读响应哈希验证通过。稳定维护入口 `ops\Platform.ps1` 已实际使用。没有重新初始化数据库或调用付费模型。

迁移预检发现此前恢复集合遗漏服务身份索引，已补入加密备份并新建 v3 备份；隔离集群实际还原和服务 Token 交叉检查通过。记录过的停止进程误判在本次真实复现为已退出对象残留于 Windows 枚举，守卫仅忽略明确 `HasExited=true` 的对象；活进程拒绝测试通过。更早缺失 PID 的那次拒绝仍不倒填根因。

实际覆盖数据库移动后中断、源码移动后中断、逆向恢复再次中断。也真实遇到重复 ACL 修改失败、`Move-Item` 对 pnpm 联接点递归移动导致部分源码迁移失败；失败未掩盖，后者经精确人工回退保留依赖缓存，改用同盘目录重命名并重新验收。独立评审承认漏检原移动假设，最终审查与实际运行证据分列于[迁移验收](windows-workspace-migration-20261012.md)。P1 单服务更新/回滚、P2 拆仓、P2.5 源码 Harness 等剩余目标继续执行。

上批 `24a7514` 四项 Linux CI 全部通过：[Platform](https://github.com/euler-gaozl/agent-os/actions/runs/38232606486)、[Storage faults](https://github.com/euler-gaozl/agent-os/actions/runs/38232607032)、[Retrieval](https://github.com/euler-gaozl/agent-os/actions/runs/38232606495)、[Langfuse](https://github.com/euler-gaozl/agent-os/actions/runs/38232606596)。它们不替代本批 Windows 原生故障测试。

## 2026-10-12 P1 运行路径切换

配置、日志、进程记录和固定发布依赖已真实切换到 `D:\workspace\agent-platform\local`；源码及 PostgreSQL 数据目录尚未移动。增加唯一布局快照、共同维护锁、所有登记部署的停写检查、PostgreSQL 身份核对及统一 start/stop/status/doctor/build/backup/restore-check 入口。

五项实际故障检查覆盖切换中途停止、缺失 Web、新布局 readiness、Windows 拒绝替换 pointer、统一备份中途停止。均恢复 12 个原角色进程和两 Worker；Agent/资料/笔记/运行列表四个响应内容哈希不变。新路径备份重新恢复到独立新集群，43 个关系、权限/结构、10 个账号、2 条加密凭证和离线 Harness 检查通过。

首次新路径备份停写保护拒绝时缺少进程身份诊断，原因未定位；后续成功不抹去该失败，已补进程名/PID 诊断。原始报告、静态评审意见、未完成的物理搬迁与 update/rollback 见 [单机计划](windows-single-machine-plan.md)。本批不包含真实付费模型请求。

## 2026-10-12 P0 完整恢复基线

正式维护窗口停止并重启 12 个本平台进程；新的协调备份保存全部实际权威数据、配置密钥、固定二进制/Node/Web/Harness 和离线依赖。独立新建 PostgreSQL 集群真实恢复：43 个表/序列内容、数据库与对象权限/结构一致，10 个原服务账号登录、2 个加密凭证解密通过；42 个 Harness 包离线重建，3 项接口特征测试通过。验证集群确认停止，原平台重新检查正常。未启动恢复库 Worker、未请求供应商，未更改原库。

实现与独立评审边界、原始报告路径见 [单机计划 P0 记录](windows-single-machine-plan.md)。P0 关卡通过，P1 开始；这不是全部目标完成。维护锁只覆盖管理入口，DPAPI 恢复依赖同一 Windows 用户配置文件。

提交 `990f739` 的四项 CI 均通过：[Platform checks](https://github.com/euler-gaozl/agent-os/actions/runs/38225832597)、[Persistent storage faults](https://github.com/euler-gaozl/agent-os/actions/runs/38225832553)、[Real retrieval](https://github.com/euler-gaozl/agent-os/actions/runs/38225832564)、[Real Langfuse](https://github.com/euler-gaozl/agent-os/actions/runs/38225832551)。这些检查不包含本批尚未提交的 Windows 恢复脚本；本批以上述本机真实恢复为运行证据。

## 2026-10-12 单机交付重新规划与 DSH 评估

用户确定先交付 Windows 单机版，再考虑服务器。实施权威改为 [完整单机计划](windows-single-machine-plan.md)，涵盖 12 个服务独立仓库、分组工作区、本机维护、UI、真实业务与恢复验收。DSH 的 [源码与存储决策](architecture/dsh-source-and-storage-decision.md) 纳入同一个新 Goal：源码纳管确定实施，持久化/上下文优先通过插件，必要的 Session/Loop 修改以压力和恢复证据决定，不另写决策循环。用户删除旧 Goal 后，新 Goal 已真实创建并处于 active。

独立评估 agent 已做源码与规划只读评审，意见和职责边界见 [评审记录](reviews/windows-plan-and-harness-20261012.md)。完整恢复集合、扩展能力与服务交付分开验收、真实研究指标以及 Windows 故障动作已补入计划。

本轮 P0 实际新增并执行只读 `Doctor-Local.ps1` 和 `Get-RecoveryInventory.ps1`：12 个已有进程身份符合记录，所有有 HTTP 端口的核心服务 health/readiness 检查通过；Sandbox 未配置隔离执行环境，明确列 warning，没有以 API 存活冒充执行可用。前两份诊断因脚本未完整复现 Futures 的令牌 fallback 报 readiness 未验证，修正探针后第三份通过；未修改运行配置，失败报告保留。恢复清单发现当前服务实际使用 1 个权威数据库，列出 13 个配置文件、13 个固定二进制及 Harness 输入 hash；这不是已完成的新备份恢复。原始报告在 `D:\workspace\agent-platform\local\evidence\`，不提交秘密值。

当前固定 DSH 发布包的三项特征测试全部实际通过：flush 等待插件、flush 失败传播、surface 替换保留原始事件。没有付费模型调用，没有将这些特征测试称为新持久化实现、内存稳定或完整故障验收。

早先抽取的 11 个源码目录没有通过独立构建，私有 SDK 解析和共享边界尚需修正，未建立新的远端服务仓库、未切换本机运行版本。草稿已归入 `D:\workspace\agent-platform\local\source-split-draft\repos`，正式 `repos` 目录留待分仓验收。当前有效代码和数据库仍在 `D:\workspace\agent-os`，没有直接搬运行中数据库。P0 仍在进行，不能把本轮规划完成写成整个平台已交付。

## 2026-10-12 工作记忆生命周期增量

新增显式 note_revise/note_retire、不可变原文和版本链、撤回/过期有效视图、原因与可信身份审计，以及中台“工作记忆”目录和原文/版本/修改记录详情。协议、分页、权限及已知限制见[生命周期契约](architecture/notes-lifecycle.md)。不改变旧 note_save schema，不自动清理正式资料。

代码提交 `5bfc84c` 的 [Platform 38212539710](https://github.com/euler-gaozl/agent-os/actions/runs/38212539710) 已全部通过：Go race/Web、新生命周期回归、Docker 隔离与故障恢复、独立 Storage 数据库、十二个服务部署单位及混合负载。平台容器限额合计 2 CPU、2944 MiB，12 个任务全部完成，最长 83.482 秒；四个读取客户端各持续至少 90 秒，实际任务/读取重叠 84.407 秒；3199 次读取全部成功，P95 88.89 ms，采样内存峰值 347.41 MiB，无 OOM 或异常重启。外部模型/MCP/OTLP 为受控夹具，外部检索及沙箱代码负载不在预算内；百万容量本轮未重复，不外推目标资料量上的全平台吞吐或物理 HA。

同代码的 [磁盘满恢复 38212539847](https://github.com/euler-gaozl/agent-os/actions/runs/38212539847)、[真实检索 38212539635](https://github.com/euler-gaozl/agent-os/actions/runs/38212539635)、[Langfuse 38212539743](https://github.com/euler-gaozl/agent-os/actions/runs/38212539743) 均通过。已下载并核对原始报告至 `.state/notes-ci/`：磁盘测试实际观察 ENOSPC/53100，保留同卷重启后旧笔记/回执/产物；Milvus 重启保持向量及来源隔离；Qwen 真实推理四题通过，LightRAG 是真实后端加受控模型/Embedding，不能把它称为真实供应商图谱质量测试。Langfuse 符合至少一次投递重复语义。

最终本机全部服务二进制按已提交 `5bfc84c` 重新构建（vcs.modified=false），十二进程逐个替换，原有笔记响应及全部配置 hash 不变；证据 `notes-upgrade-proof.json`。独立业务 API 已返回供给库存 v7、交叉核对/时间线 v6，模型配置与资料服务就绪。当前四份索引文档是已有链路样本，不能当作全品种资料覆盖。

本机真实 PostgreSQL 回归通过：同根 revise/revise、revise/retire、旧管理接口/模型写入的真实锁争用均只有一次效果；事务提交前注入失败没有部分修改，提交后丢回复及换 fence 只重放原回执，旧 fence 拒绝。覆盖跨 Agent/global/父子权限、到期不复活旧版、历史分叉原样迁移、原文/旧回执不变、Knowledge 独立库以及旧复制资料只读。实际 Runtime/Worker SQL 角色验证了审计序列与表权限；测试通过管理员连接 SET ROLE，未声称用单独登录凭证连接。真实 DSH + HTTP 受控模型遇到已知版本冲突可继续完成，并在任务重放时不增加模型调用。

独立评估 agent 只读复审发现并促成修正：审计序列授权遗漏、HTTP 冲突被误当 UNKNOWN、关闭弹窗/刷新丢幂等编号，以及鉴权 4xx 误清待确认请求。最后一项改为只有 Runtime 查过原回执并明确拒绝同一个 request_id，Web 才清除待确认请求；鉴权/网关/网络状态码本身不代表旧操作结果。Go 全量真实数据库测试及 vet、Web 五项测试/类型检查/双入口构建、五项发布脚本测试通过。首个新增分页测试编译失败（误把连接池作为事务），已修正为实际事务后全量重跑通过，未忽略失败。

真实浏览器在回环故障代理下完成：修订已在 Runtime 提交，代理故意丢回复；关详情、重开、刷新后使用相同 request_id，返回同一新文档，没有重复版本。随后原文 42 和修订 35 可分别回读，撤回只改变有效状态，历史与三条审计保留。证据 `.state/ui-review/notes-ui-recovery.json`、`notes-audit-browser.png`。恢复保证覆盖当前标签会话的刷新/关闭详情，不包括关闭标签或清除 sessionStorage；401 等网关错误保留请求的新增场景另由 Web/API 回归测试验证，不冒充已执行的浏览器故障场景。

真实 DeepSeek Flash 运行 `3dd44bf5ea196f76f6e7a37471a2db83` 完成 note_save → note_revise → 原文回读 → note_retire → 有效检索 → 撤回后回读，核对两份版本、三条审计及关联运行。七次供应商请求、21078 输入/1973 输出 tokens，17664 缓存输入，无未知用量尝试。样本 42 更正为 35、计划 9 均为受控非市场资料。测试前后余额接口 49.90 元，可能延迟计费，不能称免费。原回答错误地把检索范围说成只有本 Agent，实际含全局共享和本 Agent；原输出完整保留在 `.state/live-e2e/notes-detail.json`，已补默认约束，未用同一条通过结果证明新约束消除了语言推断问题。

本机先停止所有旧 Runtime/Worker，迁移执行域、替换双 Worker 及 Runtime，确认旧消费者退出后启用新界面和绑定；最终补丁仅替换执行域三进程，其余九进程身份及全部配置 hash 不变。五个默认 Agent 新建不可变版本，研究员 v7、通用 v5、供给库存 v7、交叉核对/时间线 v6，重复执行升级脚本变更数为零。发布前备份 `20261012-134052.dump` 已恢复核验；发布后 `20261012-141301.dump` 恢复到独立库：59 资源版本、12 文档、179 产物，哈希错误/悬空引用均零，新版本链/审计引用检查通过。升级及原资料证据均保存在 D 盘忽略提交的 `.state/`。

前一提交 `f03111b` 的 [Platform 38207063244](https://github.com/euler-gaozl/agent-os/actions/runs/38207063244) 首轮在混合负载报一个 Agent 失败，旧脚本没有保存该失败任务的回执/事件和服务日志，根因未定位；同代码仅重跑失败作业通过，12 任务完成、3176 次读取全部成功、P95 91.56 ms、采样峰值约 377.48 MiB。不能用重跑通过抹除首轮失败。新脚本在断言失败前保存任务/回执/事件与有关服务日志，资源限额和验收阈值未放宽。该提交的磁盘故障、真实检索、Langfuse 检查均通过。本次生命周期代码另由上面的 `5bfc84c` 检查验证，没有沿用旧提交的通过结果；首轮未定位的问题仍保留，不宣称已找到根因。

## 长任务事件与证据回查增量

新增固定 `evidence-v1` 执行协议：首次事件批次与调用意图同事务落盘，经 Storage 分段和清单确认后才执行模型/工具；`run_recall` 可在摘要遗失来源 ID 后重新找到本任务及后代的工具回执和事件目录。旧任务保持原 engine/协议，具体预算与边界见[存储契约](architecture/storage-evidence-v1.md)。

本机真实 PostgreSQL + 官方 DSH 压力验收通过：18,873,986 事件字节、40 批、16 次 Compact；受控摘要省略来源，真实 DSH 子进程中断后由新 fence 恢复，回查原回执并重读资料。已完成模型调用未增加尝试，留存产物 18,895,143 字节，未重复存全部前缀。其他测试覆盖丢失 Storage 确认、取消保留暂存、失败末批、旧协议重放、跨任务权限、分页与回执重放。压力测试使用受控模型，付费请求为零；真实供应商另见下条。

代码 `45bfb18` 的 [Platform 38205614232](https://github.com/euler-gaozl/agent-os/actions/runs/38205614232) 全部通过，包含 Go race、真实 Docker 沙箱、Worker SIGKILL 接管、独立数据库和 12 个部署单位。Registry/ToolHub/Runtime 的不兼容工具镜像、Worker 的不兼容引擎镜像在替换前被真实发布入口拒绝，原容器 ID 不变。2 核、2944 MiB 平台容器总限额下，12 个受控任务均完成，最长 84.106 秒；4 个读客户端各至少 90 秒，共 3199 次读取全部成功，P95 89.34 ms，采样内存峰值 358.292 MiB。外部模型/MCP/OTLP 为夹具；外部检索和沙箱代码工作负载不在预算内，不外推目标资料量或物理 HA。原报告 `.state/platform-45bfb18/linux-service-evidence/`。同提交的 [磁盘满 38205614200](https://github.com/euler-gaozl/agent-os/actions/runs/38205614200)、[真实检索 38205614176](https://github.com/euler-gaozl/agent-os/actions/runs/38205614176)、[Langfuse 38205614169](https://github.com/euler-gaozl/agent-os/actions/runs/38205614169) 也通过。

本机备份 `20261012-125311.dump` 已恢复到隔离库，46 个资源版本、6 份笔记和 111 个产物，无哈希错误或悬空引用。停止旧 Runtime/全部 Worker、执行域迁移、确认双 Worker 均为新构建后再启动新 Runtime；最终 12 个进程升级完成，原有笔记响应与全部服务配置 hash 不变。受控任务 `860d85640e95b3fb2f24d332146e372e` 经真实 Web API 完成 note_save → run_recall 列表/原回执 → document_read，逐段核验 10 份 manifest。证据 `.state/ui-review/evidence-upgrade-proof.json`、`evidence-recall-local.json`。

真实 DeepSeek 运行 `3997c8df87d562b954a0225393da440c` 使用新协议，5 次模型请求、4 次工具调用，通过原回执重读受控文档；核对撤回 42、修订 35、基准 40、减少 5、未来计划 9 和文档 ID。供应商报告输入 7655/output 988 tokens，测试前后余额接口均为 49.91 元，不能将可能延迟记账解读为免费。本次未强制触发 Compact；不替代上面的压力恢复测试。模型末段把回执分页结束用于补充资料的范围说明，仍需限制此类推断；默认 Agent 新增固定约束，明确回执目录结束不证明外部资料覆盖完整。详细回执和原输出在 `.state/live-e2e/evidence-recall-*`，未修改原回答。

页面新增回查勾选项并纠正下载文案：新协议下载执行记录清单，旧协议仍下载完整 JSON。真实浏览器下载文件与运行记录 SHA-256 一致，截图与下载件仅保留在 D 盘 `.state/ui-review/`。补测事件目录的翻页、未确认批次排除、跨树拒绝和取消后读拒绝；全部 Go 回归、Web 四项测试/双入口构建通过。`enable-evidence-recall.mjs --apply` 给五个默认 Agent 新建版本，保留原版本和其他配置；再次执行变更数为零。三个业务入口分别指向供给与库存 v6、交叉核对 v5、时间线 v5。此页面/默认绑定与补充测试增量另走后续提交检查，不冒充 `45bfb18` 已包含。

独立只读复审发现 Builtin 固定下标使沙箱校验错用 schema，已改成按名称查找并补回归；同时补了 Worker 引擎、Runtime/ToolHub/Registry/Worker 工具集合的发布/回滚前置检查。必须全部更新 Worker 后才启用新 Runtime，旧 Runtime 也不能服务绑定新工具的任务。评审仅读源码，不作为运行测试。

## 持久化故障验收增量

[复测 CI 38192907000](https://github.com/euler-gaozl/agent-os/actions/runs/38192907000)（`bf81f7b`）已通过：192 MiB 卷真实 ENOSPC，笔记写入 SQLSTATE 53100，Storage 上传返回 503；释放填充文件并强停/重启同卷 PostgreSQL 后，先只读核对旧笔记全文/元数据/回执/事件和旧产物字节/引用，再接管与重试。旧 fence 被拒、重复新笔记只保留一份、两个产物及引用完整。测试执行 3.54 秒；这是受控磁盘容量故障与数据库进程恢复，不是物理断电、数据损坏或跨节点 HA。原始报告 `.state/disk-full-bf81f7b/test.txt`。

同提交的 [Platform 38192907004](https://github.com/euler-gaozl/agent-os/actions/runs/38192907004)、[检索后端 38192907010](https://github.com/euler-gaozl/agent-os/actions/runs/38192907010) 与 [Langfuse 38192907009](https://github.com/euler-gaozl/agent-os/actions/runs/38192907009) 均通过。包含 Go race/Web、沙箱、数据库边界、Worker 强杀接管、12 个独立部署单位及混合负载。受控 12 任务全部完成，最长 79.306 秒；4 个读取客户端各至少 90 秒，共 3390 请求全部成功，P95 26.99 ms，采样内存峰值 345.42 MiB。平台 CPU 上限合计 2 核、内存上限 2944 MiB；外部模型/MCP/OTLP 为夹具，外部检索推理及沙箱代码工作负载不在预算内。这个小负载不代表目标资料量下的全平台容量。原始报告 `.state/platform-bf81f7b/linux-service-evidence/`；百万容量未在本次重复运行。

本机全部 11 类服务、12 个进程逐个升级到本次构建；每个单位更新时核对其他进程身份未变，所有配置 hash 和原有 5 份笔记响应 hash 相同。升级前备份 `20261012-094229.dump` 恢复到隔离库：45 个资源版本、5 份笔记、103 个产物，无哈希错误/悬空引用。升级后受控 DSH 运行 `d3ba055d81006f826acfd26781b19796` 再次完成 note_save → document_read → artifact_read（4 次模型协议夹具请求、3 个工具回执），无付费请求。证据 `.state/ui-review/http-upgrade-proof.json` 与 `notes-boundary-local.json`。本次未改 DDL、工具 schema 或 DSH 协议。

新增 `Persistent storage faults` 独立工作流：PostgreSQL 位于容器内 192 MiB tmpfs，运行库和产物库分开；写满只作用于这个一次性卷，不挂载宿主目录。先保存笔记/回执和旧产物，再观察实际 ENOSPC 与零剩余空间，验证新写入没有虚报成功。移除专门的填充文件后，用 pg_ctl 在原数据目录强制停止并重新启动 PostgreSQL；不重启容器，避免 tmpfs 被清空后冒充恢复。随后检查旧资料、旧 fence 拒绝、重复操作唯一效果、回执/事件一致和产物哈希/引用。

本机只完成编译、全量 Go 回归和 vet；因无 Docker，此新磁盘场景明确跳过，不能计为运行通过。代码检查同时修复容量/连接类 PostgreSQL 错误被当成 HTTP 400 的问题：已识别的数据库不可用返回 503 与 Retry-After，查询超时返回 504，消息不暴露内部路径和连接配置。约束/输入错误仍为客户端错误，不能自动重试未知外部效果。错误分类回归已通过，实际磁盘场景与新提交 Linux 全链路仍须验收。

独立只读评审发现并修正三个问题：旧资料必须在任何重放/补写前按原 ID/哈希核对全文、元数据、回执及引用；pgx 的 UnexpectedEOF/ErrConnClosed 也要按可解包错误分类；工作流触发范围要包括持久化实现与依赖。复核确认代码修正，未把评审当作运行证据。

首次实际 [CI 38192770170](https://github.com/euler-gaozl/agent-os/actions/runs/38192770170) 已观察到 ENOSPC、零剩余空间及两种新写入失败，但恢复阶段失败：只等待 Runtime 连接池就绪，Storage 的旧连接在首次只读核验时报告 UnexpectedEOF。增加 Storage 独立连接池的有界重连检查；不重置连接池或改写资料，待重测。失败原文保存在 `.state/ui-review/disk-full-first.log`。

后续独立交付审计（只读代码/日志）指出仍需解决的两个运行资料问题：DSH 每次桥接留存全量事件前缀，累计超过单产物 4 MiB 会失败且产生重复存储；摘要遗失哈希时缺少按运行重新发现证据的稳定入口。原有 Compact 样本和本次磁盘结果不覆盖这两项。下一增量采用版本化的分段事件与证据目录，保留旧任务重放路径；不自动清理正式资料。

## 2026-10-12 已完成的 Web 批次与后续存储边界

- 新 Storage 独立数据库的 [CI 38191397498](https://github.com/euler-gaozl/agent-os/actions/runs/38191397498)（`bcd568c`）通过。运行库实际移除了旧产物表；Storage 的独立库没有 documents/runs/calls；旧 SQL 越权被拒绝。完整 DSH 强杀接管、笔记在 Storage 停机期间由 Runtime 管理、单服务部署及混合负载通过。12 个任务全部完成，4 个读取客户端各至少 90 秒，真实执行重叠 80.755 秒，3311 次读取中 3310 成功/1 次 429、无异常响应，P95 52.08 ms，最长任务 79.604 秒，采样内存峰值 349.71 MiB。约束及不能外推的范围与下条相同；这是同一 PostgreSQL 服务器内的独立数据库，不是物理节点 HA。

- 提交 `be5be64` 的 [Platform 38188937114](https://github.com/euler-gaozl/agent-os/actions/runs/38188937114) 两作业通过：Go race、两套 Web 测试/构建、沙箱故障、独立服务部署和混合负载。受控模型/MCP/OTLP，不消耗用户 API。所有平台容器（含 PostgreSQL、双 Runtime/ToolHub/Worker、Sandbox broker、Telemetry）CPU 限额合计 2 核，内存限额 2944 MiB；4 个读取客户端各持续至少 90 秒，12 个任务全部完成，实际执行区间与读取重叠 81.366 秒。3311 次读取中 3310 成功、1 次 429、无异常响应，P95 52.20 ms；内存采样峰值 341.71 MiB，最长任务 80.988 秒。无 OOM/异常重启。外部模型/检索和沙箱工作负载不在平台预算内，这不是生产并发或目标资料量下的混合负载验收。
- 同提交 [真实检索 38188937085](https://github.com/euler-gaozl/agent-os/actions/runs/38188937085) 和 [Langfuse 38188937089](https://github.com/euler-gaozl/agent-os/actions/runs/38188937089) 通过。Langfuse 实际接收、原始身份与名称回读、私密内容排除，以及确认丢失后的两次观察符合 v4 至少一次契约；没有承诺第三方观测去重。
- 本机先发布 Storage，再发布 Runtime/两个 Worker，撤销后两者的产物 SQL 权限后，受控 DSH 运行 `b45209c6a5814e6e173c85325f511a79` 完成两次模型协议请求和 artifact_read。旧/新原始事件产物哈希均一致；其他 8 个经进程身份核实的服务及全部配置 hash 未变。进程清单中另有 7 条历史失效记录，未当作活进程通过项。备份 `20261012-084117.dump` 恢复到隔离库：43 个资源版本、4 份笔记、89 个产物，无产物哈希错误/悬空引用。
- 当前后续修改把 Agent 持久化笔记归到 Runtime，移除生产 Storage 的 documents DDL/API/权限/readiness；Console 管理入口改走 Runtime。已有 note_save 事务、scope 和模型协议不变。真实独立数据库测试、提交前回滚/提交后重放、DSH 恢复、管理权限、旧角色授权退役和原资料保留通过；本机全量 Go 测试通过。独立只读评审发现旧入口漏路由和旧授权残留，两项已修正并单独测试。此项本机正式服务升级及 Linux 全链路仍待执行，不沿用 be5be64 的通过结果。

- 笔记所有权修改 `8cdb613` 已在本机按 Runtime → Console → Storage 发布，然后执行独立退役命令；旧 Storage 账号查询 documents 实际得到 PostgreSQL 42501。升级前后原有 4 份笔记的完整管理响应 SHA-256 相同，其他 9 个经身份核实的运行进程及全部配置 hash 不变。受控 DSH 任务 `ab4ac313db387dfc71cae9f1919501a3` 执行 note_save → document_read → artifact_read，共 4 次模型协议夹具请求、3 个完成回执，无付费调用；产物哈希独立核验通过。
- 发布后备份 `20261012-091334.dump` 已恢复到隔离库：45 个资源版本、5 份笔记、103 个产物，无哈希错误或悬空引用，其他服务原资料完整性检查通过。
- 新边界 [CI 38190664443](https://github.com/euler-gaozl/agent-os/actions/runs/38190664443) 的 Go race/Web 作业通过，但容器作业在隔离环境初始化失败：旧 public.knowledge_files 的外键阻止移除空的 public.artifacts。修正夹具，先核对历史知识文件/块也全部为空，再按依赖顺序显式删除指定旧表；不使用 CASCADE，不涉及 Knowledge 自有 schema，也不用于本机资料。该修正待重新运行，不将失败记为通过。同代码的真实 Langfuse 和检索后端作业已通过。

## 2026-10-12 Web 与接口增量

- 中台六页、Agent 五个配置页、独立业务工作台完成整体视觉和交互调整。桌面/390px 窄屏、弹窗键盘操作、真实资料回读、受控 12 秒乱序响应检查见 [UI 验收](ui-validation-v0.6.md)。独立评估 agent 只读指出的七项问题均已修正并复核，评审没有冒充运行测试。
- Skill 编辑新增指定 `base_revision` 的附件复制，更新 SKILL.md 后新版本需要重新检测和审阅。真实 PostgreSQL 测试通过；浏览器保存独立验收 Skill 新版本后，引用校验标记仍可读取。
- Storage 产物写入/分页改为 HTTP，新增独立 schema 边界测试且真实删除测试 Runtime 的产物表后继续通过。资料 documents 的事务耦合仍未关闭，不能称为全部拆库。此增量本机 Go 全量测试/vet 已通过；部署升级与新提交 Linux 检查待完成。
- 前一提交 `71b85a1` 的 [Platform 38155931895](https://github.com/euler-gaozl/agent-os/actions/runs/38155931895) 和 [真实检索 38155931894](https://github.com/euler-gaozl/agent-os/actions/runs/38155931894) 通过。压测完整 90 秒读窗口已执行，但任务重叠仍按客户端发现完成的时刻计量；本次改用已落盘 claimed/completed 事件区间的并集，并剔除空隙和轮询延迟，新指标待 CI。
- [Langfuse 38155931897](https://github.com/euler-gaozl/agent-os/actions/runs/38155931897) 实际接收与回读通过，模拟上游成功但本地确认丢失后失败：预期 2 条，实际 4 条。Langfuse v4 [官方契约](https://langfuse.com/faq/all/tracing-data-updates)明确同 ID 的再次写入也会产生重复观察。本次测试要求原始身份/名称/私密内容排除，并验证重投后每个身份各有两条，而非错误宣称去重。外部观测为至少一次，重复可能放大 Langfuse 指标，不能将其作为权威费用账本。该修改仍须真实上游 CI 复验。

以下为按发生时间保留的交付记录；“待执行”状态以较新的明确复验条目为准。

2026-10-11 用户授权真实 DeepSeek API 联调与持续完成端到端交付。凭证仅通过本机凭证 API 写入加密数据库；不提交 GitHub，不写入脚本、测试夹具或报告。首轮真实测试支出上限 5 元，逐批读取余额，正常使用余额留给用户。

验收以任务实际结果与调用回执为准，不能仅以返回 HTTP 200 为准。真实模型与可控夹具分别记录。

## 当前执行顺序

**新增硬性目标（用户 2026-10-11 补充）**：服务拆分与独立交付。每个服务具备自己的构建产物、配置、发布/回滚入口和依赖契约，共用中台 Web；期货业务前端维持独立。验收单独升级、回滚、扩容或停用服务时的真实行为。当前独立二进制/镜像只是已有基础；全局迁移和执行域共享表的耦合继续处理，未完成前不能称全服务解耦完成。

1. 官方模型兼容、输出/调用预算、用量与凭证保护；真实 DSH 工具调用、资料回读与结果留存。
2. 中台编辑/试运行/发布与独立业务入口的浏览器闭环；失败、取消、重试、跨版本与中断恢复。
3. 实用的数据采集能力、MCP/Skill 的完整绑定；研究结果必须回到原文，不把测试资料混入正式资料库。
4. 服务/知识库/沙箱/观测的 Linux 集成、故障与资源测试；容量报告写清实际数据量、指标和未覆盖范围。
5. 回归、迁移/备份、凭证扫描、CI 和使用文档；逐项修复问题后再记录通过。

物理多节点故障切换仍待用户提供服务器。其余缺口按实现与证据推进，不能笼统归因于缺服务器。未完成项保持未完成，不用本文件替代验收。

## 已取得的真实模型证据

- 官方 `/models` 返回 `deepseek-flash` 与 `deepseek-v4-pro`；已把本机旧模型配置迁移为新不可变版本。按[官方思考模式文档](https://api-docs.deepseek.com/guides/thinking_mode/)显式配置开关，保留历史快照的默认请求格式。
- 真实 Flash 非思考模式：知识库检索 → 原文回读 → 同口径计算 → note_save，4 次模型/3 次工具调用；来源 ID、样本标记、计划与实绩区分均通过断言。
- 真实思考模式：工具往返及 reasoning_content 回传，3 次模型调用通过。
- 真实父子 Agent：子任务读取绑定知识库，父任务等待后汇总，6 次模型调用通过；整项任务用量可汇总。
- 真实 DeepWiki 公开 MCP + Skill ZIP 引用回读，2 次模型调用通过；只读取公开 `golang/go` 目录，不发送私有仓库内容。端点与只读用途核对自[官方文档](https://docs.devin.ai/work-with-devin/deepwiki-mcp)。
- 上述原始回执保存在忽略提交的 `.state/live-e2e/`；测试资料属于独立验收 Agent/知识库，没有混入期货资料库。余额接口本批读取为 49.99 元；账单可能延迟，不把即时差额当作最终费用。
- Go 本机全量测试、vet 和两套前端构建通过；新加并发父子预算争用、未知用量重试、缓存重放和 MCP 响应关联校验。Linux CI 结果另行记录。

## 浏览器与公开资料链路

- 中台浏览器首次检索文件名失败；检查发现词法索引只有正文。已增加独立文件名 GIN 索引、每批 128 个文件的旧资料回填及版本隔离测试。同题重跑成功，原失败运行保留，不能因运行状态为 completed 就计为验收通过。
- 中台“保存版本 → 试运行 → 真实模型 → 检索 → 原文回读”通过；修复后运行 `0bad3f4b3a320818f0aa8f9bdf9fc50f` 正确返回受控样本编号、实绩差值和计划性质。
- 独立期货业务入口运行 `acba52f7a66dc0396ec6137f778b9b80`：通过发布 Agent 和公开资料 MCP 读取国家统计局一篇能源生产原文；归档、分页读取、查找、事实留存通过。独立校验原始响应 SHA-256 和六项产量数字，不仅采用模型自述的“通过”。这是单篇采集链路验收，不是完整行业研究或全品种数据库验收。
- 新增 Sources 独立 Go 服务及 schema/账号，提供白名单公开 HTTPS 采集、不可变原文和文本分页/定位。单响应原始内容上限 1 MiB；默认不执行网页脚本、不处理 PDF/OCR，不绕过登录和付费限制。后台可通过认证接口下载原始内容并核验哈希。
- Agent 回答用安全 Markdown/GFM 渲染，表格可横向滚动；禁止原始 HTML、脚本 URL 和自动远程图片加载，增加渲染安全测试。业务记录刷新后可回读，并导出 Markdown。
- 修复产物按哈希读取时缺少运行归属校验的问题；当前任务和其子任务之外的产物拒绝读取，增加跨运行拒绝测试。
- 本机凭证未进入源码；本批余额接口为 49.96 元（可能存在计费延迟）。公开资料原文和浏览器截图只保存在忽略提交的 `.state/live-e2e/`。

## Linux 检查

提交 `746a19c` 的 [CI 38142273408](https://github.com/euler-gaozl/agent-os/actions/runs/38142273408) 两个作业通过：Go race/构建及既有容器故障链路。后续 Sources/文件名索引/页面渲染变更必须重新通过对应检查后才计入结果。

提交 `aeebd4a` 的 [CI 38145694276](https://github.com/euler-gaozl/agent-os/actions/runs/38145694276) 两个作业通过，包含真实 Docker 沙箱隔离、缓存回放、执行服务 SIGKILL、容器自行超时停止及孤儿作业回执恢复。此前两次检查分别暴露 JSONB 字节比较测试错误、容器 PID 1 导致超时失效；修复后重新验收，没有删除失败记录。[Docker 官方进程说明](https://docs.docker.com/reference/cli/docker/container/run/)是增加 init 的依据。后续 Sandbox HTTP 授权解耦需在新提交上重测。

## Compact 的真实模型验收

- 运行 `14f7a3de5acfe02e01a912aeec0f3b86` 读取独立的 10 页受控资料，触发 2 次真实模型 Compact；核对 10 个不同分页偏移、初报撤回、修订值 108、差值 -12、未来计划 20 与资料末页标记，关键字段均保留。完整 DSH 事件产物 SHA-256 已独立核验。
- 原始资料和事件记录不靠压缩摘要保存；存于本机忽略提交的 `.state/live-e2e/compaction-*` 和数据库产物。
- 质量局限：答案对同仓库初值多加了不必要的口径疑问，不能称为完全语义保真。首次运行因模型一次请求 10 个工具超过 8 个的上限而失败；改为每轮至多 4 个后重跑成功，保留失败运行。
- 本批余额接口 49.91 元，可能存在延迟计费。此测试不是期货事实，不混入正式研究资料。

## 独立发布和迁移

- 已增加单服务 Compose、镜像 ID 固定、配置摘要验证、单服务升级/回滚/副本调整及失败后恢复入口；Console 仍为统一中台。数据库升级选择服务所有者，不重写其他服务身份或配置。
- 本机仅迁移并重启 Knowledge 和 Sandbox；其余 10 个进程 PID 保持不变，全部服务配置文件内容摘要不变。备份 `20261011-221516.dump` 保留；本次只是 dump 目录检查，恢复验证另行执行。
- [CI 38146316990](https://github.com/euler-gaozl/agent-os/actions/runs/38146316990) 已通过 Knowledge 的真实旧版本二进制部署、升级、回滚、两副本和错误镜像失败后的恢复；全部配置文件字节和其他容器 ID 不变。
- [CI 38147567156](https://github.com/euler-gaozl/agent-os/actions/runs/38147567156) 已通过其余 11 个服务的独立部署入口：Registry、ToolHub、Storage、Runtime、Indexer、Sources、Sandbox、Telemetry、Worker、Console、Futures。每次断言其他容器 ID、启动时间和重启计数不变，统一中台目录/知识检索/业务历史仍可用。独立双 Worker 真实执行 DSH，完成 4 项工具调用；模型与 OTLP 接收端为夹具，不冒充真实 Langfuse 联调。这个部署场景包含额外可选服务和副本，不作为整个平台 2 CPU 容量结果。
- Sandbox 独立作业库 + Runtime HTTP 授权 + 真实容器强杀恢复已在 [CI 38147321703](https://github.com/euler-gaozl/agent-os/actions/runs/38147321703) 通过；本机先更新 Runtime，再更新 Sandbox，并撤销 Sandbox 的 public.runs SQL 权限，验证权限拒绝。其他 10 个进程未更换。
- 备份 `20261011-221516.dump` 已恢复到隔离数据库：41 个资源版本、4 份执行域文档、89 个产物；产物 hash 不符和悬空引用均为 0。没有用恢复覆盖用户数据库。
- 共享执行表的剩余耦合仍未关闭，见[独立部署契约](independent-deployment.md)。

## 补充的浏览器与可用性检查

- 从中台打开 Skill 包引用文件，显示受控标记 SKILL-REF-284；点击重新检测后检查时间实际更新。截图保存在 `.state/live-e2e/toolhub-skill-browser.jpg`。
- 从页面上传 UI-KB-609 受控文本，检索命中，下载原文与上传前 SHA-256 完全一致。原文件、下载副本和 `.state/live-e2e/knowledge-browser.jpg` 均保存在 D 盘，资料属于独立验收知识库。
- ToolHub 后台探测改为有界并发（默认 2，可配置 1–8）、错误退避，不因一次数据库探测错误关闭目录 HTTP API。慢 MCP 与快速 Skill 检查并行、取消及错误存储测试通过；一次测试夹具未读完 HTTP 请求体导致退出挂起，修正夹具后重新跑完整 ToolHub 测试通过。
- 增加各服务所需表/字段/权限的零行 SQL 就绪检查，防止只因数据库可连接就接收未迁移版本的流量；Console/Futures 仍无数据库依赖。新提交需继续通过对应 Linux 检查。

## 下一批必须关闭的代码问题

- 目录已改为每页最多 100 项摘要、服务端搜索、进入编辑后读取精确版本全文；绑定选择独立分页，保留页外历史绑定。Registry 和 ToolHub 在 SQL 投影时就省略正文/工具 schema；Console 每个来源只请求一页。210 个长提示词 Agent 的完整分页、205 个大 Skill 的摘要、跨服务合并/故障、前端精确版本读取与误写拒绝测试通过。此前复查发现运行列表已返回最多 100 项摘要，无需重复修改。
- 目录变更 `0a2d0e0` 已在本机分别迁移/更新 Registry、ToolHub、Console，其余进程和全部服务配置 hash 不变。浏览器输入大写 ID 搜索成功，打开并保存独立验收 Agent 后，1054 字提示词、末尾标记和绑定等完整 spec 语义相同；仅 JSON 对象字段序导致最初的字符串相等检查失败，改为语义比较后通过。搜索无结果时已有绑定仍显示勾选。证据在 `.state/live-e2e/catalog-*`，新版本 Linux CI 待完成。
- Runtime/Storage 的资料效果与回执尚未通过跨库协议解耦；独立部署检查不代替数据边界验收。
- Telemetry 已实现 Runtime outbox → HTTP 租约/fence → 本域 inbox 提交 → Runtime ack → 独立批量 OTLP 导出，移除部署服务对 events 的 SQL 权限。独立 schema 无执行表、丢失确认后的重投、旧 fence 拒绝、同序号内容变化拒绝、晚提交事件、多导出实例和 Runtime 故障后继续导出的本机测试通过。新 Linux CI 将另建完全没有 runs/events 的数据库验收；通过前不列为容器独立数据库已验收。
- 沙箱截止进程与工作负载同 UID 是本次代码审查发现的风险；先前死循环测试不覆盖代码主动发送信号。新增独立 Go guard 工作负载镜像：可信守护程序保留独立 UID，仅用于子进程降权，执行代码仍为 UID 65534 且零 capabilities。Linux CI 增加 SIGSTOP/SIGKILL 干扰 guard 与 broker SIGKILL 联合检查；本机只能交叉编译，未验收前不能声称攻击测试通过。
- 真正 Milvus/LightRAG/Embedding/Langfuse 服务联调、目标规模结果、长期资料生命周期与真实跨机 HA 继续分别记录，不能合称全部生产化完成。

### 本批复验

- [CI 38152175266](https://github.com/euler-gaozl/agent-os/actions/runs/38152175266)（`b7fd421`）两个作业通过。Telemetry 使用另建的 `agentos_telemetry_ci` 数据库，库中没有 runs/events，旧执行库读取权限被真实拒绝；Runtime 事件通过 HTTP 接收、落盘并导出。12 个部署单位仍可单独运行，共用 Console，其他容器和配置不变。原始证据在 `.state/isolated-telemetry-ci-b7fd421/`。
- 同一 CI 的 Go race 和真实 Docker 沙箱检查通过，包含工作负载对 guard 的 SIGSTOP/SIGKILL 均遭 EPERM、执行服务 SIGKILL 后容器仍自行截止、孤儿作业恢复。没有用只编译或普通死循环代替主动干扰测试。
- LightRAG 返回值新增本地来源校验：限定知识库 revision、索引状态和上游 endpoint；实体/关系的每个来源都必须属于当前版本，混合未授权来源的条目被丢弃；文本片段还必须在保留原文中出现。返回固定字段和本地 document_id，远端引用表、调试字段不直接进入上下文。跨版本、混合来源、伪造片段、未完成索引和其他 endpoint 的本机测试通过，真实 LightRAG 联调仍待完成。
- 新增独立的真实 Milvus CI：固定 v2.6.24，使用生产索引/检索代码，Embedding 为明确标记的受控向量；验收写后丢失回执的幂等恢复、来源回查、版本隔离及后端重启。该作业尚待执行，不能计为通过。

2026-10-12 追加：

- [CI 38153838660](https://github.com/euler-gaozl/agent-os/actions/runs/38153838660) 的真实 Milvus v2.6.24 和 LightRAG v1.5.7 均通过。Milvus 真实 upsert 后故意丢失响应，重试后向量数量仍与本地分块一致；重启后可继续检索。LightRAG 真实异步处理、图谱实体/关系与原文片段回查、未绑定 revision 排除通过。两项模型输入为明确标记的夹具，没有消耗用户 API。首次 Milvus 作业因 CPU 上限超过 runner 实际 2 核而未能启动，降低其配置上限后重跑；失败记录保留。
- Git HTTPS 连续连接失败时，通过 GitHub Git Data API 上传已提交对象，逐个核对 blob/tree/commit SHA 与本地完全一致后，仅对原私有分支做非强制快进。没有更改凭证、扩大仓库访问或重写已发布历史。
- 本机分别升级 Knowledge 与 Runtime：Knowledge 可检索原有浏览器上传材料；Runtime 仅执行本域迁移，事件 outbox 已可用。每次其余 11 个进程和全部配置 hash 不变。升级前备份 `20261012-000512.dump` 已恢复到隔离库；43 个资源版本、4 份执行资料、89 个产物，产物 hash 错误/悬空引用均为 0，Knowledge/ToolHub/Sources 自有资料完整性检查通过。
- Embedding 输入校验新增拒绝 null、float32 溢出、零向量及转换成 float32 后全零的向量，避免无效 COSINE 索引。针对真实 Qwen 推理 + Milvus 的中文标注样本 CI 待执行。
- 上述真实 Qwen + Milvus 在 [CI 38154474531](https://github.com/euler-gaozl/agent-os/actions/runs/38154474531) 通过：四份中文原文、四个预标注问题均 top-1 命中原文，实际 1024 维推理，索引 3.77 秒、单次查询 0.82–0.88 秒。原始日志与两次 Docker stats 样本在 `.state/real-embedding-e172095/`。采样太少，不用它宣称稳定内存峰值或并发容量。
- 容器回归 `38153838427` 在强杀 Worker 时测试 exec shell 同时被容器 init 结束，返回 137；修复故障注入脚本，仅允许这个退出码，并额外要求 Worker RestartCount 实际增加，后续仍要验证 fence 接管和唯一效果。不是忽略任意故障。
- 已增加全平台混合负载测试：全部 12 类平台服务、PostgreSQL、两个 DSH Worker，包含 Sandbox broker/Telemetry，合计容器 CPU 限额 2 核、内存小于 4 GiB。预设验收为 12 个任务、4 个读请求客户端持续 90 秒、任务 180 秒内完成、读请求成功率至少 95%、P95 小于 1 秒、无意外 5xx/OOM/重启。模型/MCP/OTLP 为外部受控夹具；沙箱执行容器与外部检索推理不在平台预算内。该新增负载检查待 CI 完成。
- 真实自托管 Langfuse v4.56.0 联调作业已编写：独立 disposable 项目、生产 Telemetry exporter、上游 observations API 回读和重复投递身份验证；只有 CI 夹具凭证。尚待实际执行，不能把受控 OTLP 的成功代替此项。

## 容量实测和失败

本轮独立只读评审（基线 `062e188`）发现两项问题，均已补代码和回归：LightRAG 合法文件名可携带未校验实体描述；全平台压测把提交任务耗时计入了 90 秒读窗口。现在图谱逐字段匹配本地原文并标为检索线索；读客户端与任务并行，每客户端独立计时，断言完整 90 秒以及至少 10 秒混合负载重叠。本机图谱反例测试通过，新版本 Linux 检查待执行。评审没有执行运行测试，不能作为运行通过证据。

真实 Langfuse 首次 [CI 38155105420](https://github.com/euler-gaozl/agent-os/actions/runs/38155105420) 启动失败：Next 服务已启动，但回环地址健康检查始终失败。根据日志中的容器主机名监听，显式设置 `HOSTNAME=0.0.0.0` 并增加健康检查原始诊断后重跑；这是待验证修复，不能计为联调成功。失败日志保存在 `.state/langfuse-first-062e188/`。

- 10,000 文档 / 100,000 分块、有界 CPU/内存、4 并发 200 次检索：[基线 38144602314](https://github.com/euler-gaozl/agent-os/actions/runs/38144602314) P95 1501.45 ms。定位 PostgreSQL 候选集联接计划后，增加有界候选 CTE；[修复后 38145136016](https://github.com/euler-gaozl/agent-os/actions/runs/38145136016) P95 51.73 ms、最大 57.28 ms、0 次错误，表与索引约 178 MB。
- 这是 SQL 合成资料的本地词法检索测试，原文较分块总量更短，重复内容可压缩；不是上传吞吐、真实语料召回率或全平台容量验收。PostgreSQL 1.5 CPU / 3 GiB，测试客户端 0.5 CPU / 512 MiB；其他常驻服务不计入。
- 百万文档 / 千万分块首次测试耗尽 GitHub runner 磁盘，日志/报告未能上传。已从 GitHub check annotation 确认 `No space left on device`，不能将其算为通过；增加 CI 临时 VM 空间预检和低空间提前停止，继续重测。小样本成功不能替代目标规模验收。
- [百万规模 38147319771](https://github.com/euler-gaozl/agent-os/actions/runs/38147319771)（`1306722`）已完成：1,000,000 文档 / 10,000,000 分块，装载 2330.09 秒，表与索引 17,379,991,552 字节，4 并发 / 200 次检索，P50 57.832 ms，P95 1435.712 ms，最大 1734.651 ms，0 错误。原始报告在 `.state/capacity-million-1306722/capacity.json`。版本隔离检查通过。仍沿用上方合成资料、预热/混合缓存和仅检索客户端 + PostgreSQL 的限制。
- 本次资源采样文件为空：采样早于测试容器启动，`docker stats` 的非零返回使后台脚本提前退出，未取得 CPU/内存/磁盘趋势，也未真正运行低空间停止分支。容器创建时的资源限制和检索报告仍有效，但不能声称已经观测过资源峰值。已增加采样容错、非空断言和容器限制留档，下次容量运行必须补齐。
- 百万规模未命中首次查询 1376.775 ms；报告中的文件名计划为顺序扫描。将文件名匹配规划与 64 条候选限制分开，两层 MATERIALIZED CTE 保留有界联接；本机 20,000 文件的 `EXPLAIN ANALYZE` 检查通过，未命中使用 GIN 索引，广泛命中也只消费最多 64 条候选。尚待相同百万规模复测；没有全局关闭顺序扫描。语义依据见 [PostgreSQL 18 CTE 文档](https://www.postgresql.org/docs/18/queries-with.html#QUERIES-WITH-CTE-MATERIALIZATION)。
- [复测 38150855499](https://github.com/euler-gaozl/agent-os/actions/runs/38150855499)（`d36c5c2`）通过：同样 1,000,000 文档 / 10,000,000 块，装载 2477.72 秒，表与索引 17,380,761,600 字节；4 并发 / 200 查询，P50 17.150 ms、P95 752.473 ms、最大 1115.620 ms、0 错误。未命中首次查询降至 12.011 ms，文件名未命中计划使用 GIN。广泛命中文件名仍较慢（该组 P95 1107.492 ms），不能只展示最快查询。
- 本次每个容器 335 个资源样本、336 个磁盘样本，采样内存峰值：PostgreSQL 484.9 MiB、客户端 8.426 MiB；最低磁盘余量 14,230,396 KiB。保留创建时的 cgroup 限制、完整查询样本/计划及观测原文于 `.state/capacity-million-d36c5c2/`。采样值不是连续峰值，仍不包括全平台其他服务，数据分布和缓存限制与前次相同。
