# 端到端交付账本

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
