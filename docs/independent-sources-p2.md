# P2 独立源码与发布验收

2026-10-13。P2 进行中；已有十二个服务独立仓库，九个启用服务已切换到 Owner 版本（包含双 Worker，共十个进程），Telemetry 保持停用。Console/Futures 已通过独立构建与搬迁夹具，CI/本机切换待验收；集成业务源码退役尚未完成。

## 所有权

`repos/agent-os-sdk` 只提供固定 DTO、工具协议、有界传输及服务传入策略的启动设施。SQL、迁移、路由权限和 schema readiness 归服务；SDK 不包含 recordstore、业务 SQL 或全平台角色权限表。

| 仓库 | 自有数据 | 跨服务依赖 | 当前状态 |
| --- | --- | --- | --- |
| [agent-os-registry](https://github.com/euler-gaozl/agent-os-registry/pull/1) | resources、secrets | HTTP ToolHub；可选 Runtime 心跳 | 独立源码/构建/迁移/CI、本机更新回滚通过 |
| [agent-os-sandbox](https://github.com/euler-gaozl/agent-os-sandbox/pull/1) | sandbox_jobs | HTTP Runtime；执行另需 Linux Docker | broker 更新回滚通过；本机隔离执行不可用 |
| [agent-os-telemetry](https://github.com/euler-gaozl/agent-os-telemetry/pull/1) | telemetry_inbox、telemetry_exports | HTTP Runtime claim/ack、Registry 命名凭证、Langfuse | 构建/CI 和零实例 catalog 切换通过；exporter 未配置 |
| [agent-os-toolhub](https://github.com/euler-gaozl/agent-os-toolhub/pull/1) | toolhub 的 assets/state/files/audit | HTTP Registry 命名凭证、Runtime 回执 | 独立检出/数据库/本机更新回滚/修复版 CI 通过 |
| [agent-os-storage](https://github.com/euler-gaozl/agent-os-storage/pull/1) | artifacts、artifact_refs | Runtime 提交授权根；不读执行库 | 同上；源码移除所有文档/笔记 SQL |
| [agent-os-sources](https://github.com/euler-gaozl/agent-os-sources/pull/1) | sources 的 blobs/captures | 受限 HTTPS 公开来源 | 同上；正文格式限制如 README，不代表全品种覆盖 |
| [agent-os-knowledge](https://github.com/euler-gaozl/agent-os-knowledge/pull/1) | knowledge schema；唯一迁移者 | HTTP Registry、Runtime；可选外部检索后端 | 独立源码、角色权限、CI、本机更新回滚通过 |
| [agent-os-indexer](https://github.com/euler-gaozl/agent-os-indexer/pull/1) | 通过固定 Knowledge indexing 模块消费同域队列 | 固定 indexing 协议；外部索引 HTTP | 同上；旧/新二进制丢回复/轮询恢复通过 |
| [agent-os-runtime](https://github.com/euler-gaozl/agent-os-runtime/pull/1) | 执行域 14 表；唯一迁移者 | HTTP Registry、ToolHub、Storage、Knowledge、Sandbox | 固定 execution 模块、受限角色、CI/旧新 Worker 接管、本机更新回滚通过 |
| [agent-os-worker](https://github.com/euler-gaozl/agent-os-worker/pull/1) | 固定 Runtime execution 模块，自己不写迁移/SQL | DSH/Node、模型 HTTP、ToolHub、Storage、Registry | 独立构建/可搬迁包、Linux/Windows CI、六组接管、本机更新回滚通过 |

每个仓库有独立 Go module、命令、镜像和配置例子。拥有数据域的服务负责事务迁移和 PostgreSQL 测试；Worker/Indexer 只消费固定的窄事务模块，没有迁移入口。正常进程不做 DDL；迁移只改变本域表，在一个事务内提交结构及授权，锁/语句超时有界。Runtime/Worker 和 Knowledge/Indexer 保留必要事务域，不以强拆事务伪造独立性。

## 可重复构建

SDK 固定 `v0.1.0-rc.2` / `f45ca168dee81f864533a8f77f8c203960caad1a`，规范 Go 模块校验值 `h1:SunD5Oyh1le4sv3CMJTpKCa0SsKBQDqXoBoAC0aji98=`。通过 Go 下载器从固定 Git tag 获取，各消费者提交 vendor，构建时 `GOWORK=off`、`GOPROXY=off`、`-mod=vendor`；不依赖兄弟目录替换或给 CI 配个人跨仓库令牌。先前自制 ZIP 校验失败已保留并废弃，不能使用其缓存重新生成依赖。

`deploy/service-sources.json` 固定已拆服务的仓库和提交。集成构建要求 Owner HEAD 与锁一致、目录干净、完整 HTTP/data/tools/engines 合约一致；缺映射直接拒绝。构建时清理继承的 Go flags、环境文件、workspace、目标平台；生成后核验 Go 模块、SDK 版本、VCS 提交与 clean 标志，再次检查源码未变化。发布描述使用 Owner 合约及来源。其余未拆角色明确仍从集成仓库构建，不能宣称已经拆仓。

`scripts/Build-Services.ps1` 只创建候选完整包；激活仍由唯一发布 catalog 与维护事务完成。当前/上一版本保持 HTTP 和数据兼容才可自动回滚；跨 schema/config/协议变更仍需协调迁移。

## 已执行证据

- 三仓独立检出、空模块缓存、关闭网络依赖及 go.work：真实 PostgreSQL 18 隔离数据库、测试、vet、构建通过。`local/evidence/p2-isolated-checkouts-b32a6c1eab6944069bc621f042996e3b/result.json` 记录精确源码提交；验证集群已停止。仅有 3 个本模块 VCS 元信息缓存文件，没有下载依赖包。模型调用 0。
- 数据库验证包含重复迁移、事务 DDL 失败回滚、逐项 SELECT/INSERT/UPDATE/DELETE 授权、应用账号 readiness、跨域拒绝；Registry 旧资源版本与加密资料；Telemetry inbox 提交先于 ack，丢 ack 重投及身份漂移拒绝。Sandbox 测试用 HTTP Runtime 夹具，不冒充完整 Docker 执行。
- 独立仓库 CI（Linux PostgreSQL/race/vet/build/Docker，Windows unit/build）：[Registry 38251866324](https://github.com/euler-gaozl/agent-os-registry/actions/runs/38251866324)、[Sandbox 38251875960](https://github.com/euler-gaozl/agent-os-sandbox/actions/runs/38251875960)、[Telemetry 38251884643](https://github.com/euler-gaozl/agent-os-telemetry/actions/runs/38251884643) 全部成功。随后仅修改 release-contract 的新提交另行复验。
- 10 项源码选择/拒绝夹具通过，报告 `local/evidence/service-sources-3f7c444f20b04386b40dbe49050de974/result.json`；包含缺锁/映射、脏目录、错误提交、数据/工具/引擎协议漂移及路径逃逸。这是合成源码边界测试，不包含服务激活。
- 三个真实 Owner 在故意污染 GOENV/GOFLAGS/GOWORK/GOROOT/GOOS/GOARCH 的环境构建成功，调用方环境恢复，当前 catalog 字节未变：`local/evidence/owner-build-environment-66a9f1acb4384648a3f4850a0fa34cfa/result.json`。修复可选 JSON 属性访问后，在 StrictMode Latest 下再次构建三仓通过，候选 `4aa0d6cdbc074a8dbd1a6fe35a87fac8`。这两批明确标记 development，未激活。
- 独立评审仅做静态复核。发现并修复凭证环境泄露、Telemetry 默认端口冲突、SQL 权限测试 OR 语义、缺锁静默回退、合约字段遗漏、构建环境污染和 StrictMode 可选字段问题；评审不替代上述实测。

## 已部署的安全修复

旧集成 Registry 的凭证解析会接受任意同名进程环境变量；新旧源码均已限制保留名，只允许明确的三个旧供应商环境变量兼容，其余使用加密凭证表。集成 `bb9a693` 已单独部署，非目标 11 个进程不变，Doctor 正常；真实内部配置名请求返回 400，未读取响应正文。证据 `local/evidence/credential-rpc-live-bb9a693.json`。本次 Owner 发布回滚基线必须是这个安全版本，不能退回此前版本。

## 本机切换实绩

从干净集成提交 `f6ebe47` 构建，固定 Owner 为 Registry `98c8990`、Sandbox `241abe5`、Telemetry `93f18c5`。候选包 `511577a97c1245e8bf254ec4ab776047` 经实际 update → rollback → update：Registry 和 Sandbox 各三次进程替换全部就绪，非目标实例/配置不变；Registry 四个资源/目录/业务发布/凭证配置状态只读响应哈希一致。Registry 回滚的确是修复后的 `bb9a693`。最终 Doctor 核心通过，模型调用 0。

Telemetry 三次为 **零实例的 catalog 切换**，报告明确 `readiness=not_started`；没有启动未配置 exporter，不能算作真实导出恢复。Sandbox 仅验证 broker，仍没有本机隔离执行能力。完整原始报告 `local/evidence/first-owner-releases-e4ac4db7ea6e4ef8b6c4cca98542a15d/result.json` 和同目录 Doctor；每个事务还有独立 release 报告。

首批更新/回滚关卡已通过上述边界，服务端 HA、真实跨节点故障和未配置扩展不在本批证明范围内。P2 其余服务继续实施。

## 第二批源码与数据库关卡

ToolHub `3186161`、Storage `772a972`、Sources `6ac8500` 已在各自私有仓库的 draft PR。独立 clone、关闭 go.work/网络依赖、空模块缓存、真实 PostgreSQL 测试、vet 和服务/migrate/healthcheck 构建全部通过：`local/evidence/p2-second-isolated-dad92f76a0fb493cb01ac03aa3fdded1/result.json`，集群已停止，模型调用 0。首次未提交版本测试也保留于 `p2-second-services-fdba9f4c3431490fb45218f2f3341d1c`。

ToolHub 保留注册/检查/启停/版本漂移/监视租约原行为，用受限应用账号实测注册→检查→启用→审计，验证序列权限。Storage 只提取产物方法，验证受限账号 HTTP 保存与重试、Unicode 分页、引用采用、不可见根拒绝、引用保护和内容损坏拒绝。Sources 保留真实响应字节、分页与 UTF-8；响应是合成夹具，不声称真实供应商可用。三域都验证重复迁移、DDL 失败事务回滚和外域拒绝。Sources 默认并发从原通用值 16 收窄为 4，减少解码时同时驻留的数据，配置仍可显式调整。

独立评审静态比较确认 ToolHub 业务/租约逻辑未被拆分改变，Storage 无执行 SQL，授权未放宽；没有执行测试。集成选源测试已扩至 13 项，明确拒绝这三个已拆角色缺映射时回退主仓，报告 `service-sources-a99ec03ed69548808e0270f41c1e7359/result.json`。实际切换随后验收。

### 首次实际切换失败与兼容修正

第二批首次 ToolHub 更新失败，报告 `local/evidence/second-owner-releases-729d2497557748698e49ee81fdd381e9/result.json` 保留。旧配置省略 Registry/Runtime 地址，依赖原通用启动器的 loopback 默认值；新 SDK 正确移除业务默认值，但 Owner 没有接手默认值，启动立即退出。发布事务自动恢复旧版本，pending 清空，未推进其他两个角色。该失败说明只验证数据/HTTP 合约还不足以证明入口兼容，前次静态评审也未发现此项。

继续核查发现，六个新 Owner 在省略 Runtime 地址时都不再发送心跳；首批 readiness/读取通过不覆盖这一缺口，不能视为界面服务状态已验证。修正在各自入口配置加载后、创建客户端和任何后台任务前填入原有本机默认地址；显式配置永不覆盖，配置文件不改写，默认值不放回 SDK。六仓补 Runtime，ToolHub/Telemetry 补 Registry，Registry 补 ToolHub；各入口默认值/显式覆盖测试通过。

修正版选源锁记录全部六仓新提交。第一批先恢复原兼容基线，再重新进行发布验收；最终另需核对 Runtime 中当前进程 PID、实例 ID 与新鲜 heartbeat，不能读旧实例冒充正常。Telemetry 仍保持零实例，未配置不启用。修复后的实测记录随后追加，不把一次成功重跑覆盖原失败。

### 修正版真实复验

集成 `beb1fd3`、完整候选 `363b589bf3664ffe98b1550487ac5f52` 已实际部署：Registry `6deeab6`、Sandbox `9348b8e`、Telemetry `fcaca2e`、ToolHub `98f8fec`、Storage `f1efbf9`、Sources `82a90ce`。前五个启用角色（不含 Telemetry）各执行 update → rollback → update，共 15 次进程切换全部就绪，每次非目标实例不变；Telemetry 另有 3 次零实例 catalog 切换。

第一批报告 `local/evidence/first-owner-releases-0f074c2819f847f2bbbc7e4397176755/result.json`；第二批报告 `local/evidence/second-owner-releases-607867e55e8c41e4b8611745e7048f7e/result.json`。第二批使用各自受限数据库账号，在数据库内计算所有现有不可变产物/引用、原始捕获、工具资源/文件及启用状态的行哈希；每次切换前后相同。还通过真实认证 HTTP 回读原有产物、采集原文和工具目录，字节哈希不变。没有清库、造一套空数据替代迁移，未读取/输出凭证值。

随后验证每个当前进程的 PID、启动配置 INSTANCE_ID 与 Runtime 的新鲜心跳（10 秒内）一致，且实际发布描述的 Owner commit 等于源码锁：`local/evidence/owner-heartbeats-650bb28c1b8f49cc84979c7d29d86256.json`。最终 Doctor 核心通过，保留两个 Worker，模型调用 0。Telemetry 没有实例，不声称心跳/导出已验证；Sandbox 仍仅为 broker。这些是 Windows 单机实绩，不替代物理节点 HA、真实 Agent 故障和后续业务验收。

六个修正后的固定 Owner CI 全部成功（Linux PostgreSQL/race/vet/build/Docker、Windows unit/build）：[Registry 38257018318](https://github.com/euler-gaozl/agent-os-registry/actions/runs/38257018318)、[Sandbox 38257037210](https://github.com/euler-gaozl/agent-os-sandbox/actions/runs/38257037210)、[Telemetry 38257055443](https://github.com/euler-gaozl/agent-os-telemetry/actions/runs/38257055443)、[ToolHub 38257072335](https://github.com/euler-gaozl/agent-os-toolhub/actions/runs/38257072335)、[Storage 38257088118](https://github.com/euler-gaozl/agent-os-storage/actions/runs/38257088118)、[Sources 38257104366](https://github.com/euler-gaozl/agent-os-sources/actions/runs/38257104366)。独立 Owner 的 CI 不等于 Linux 集成已切换到全部新仓；后者需等其余六个服务抽离后接入统一编排验收。

下一批先确定 Knowledge/Indexer 与 Runtime/Worker 两个必要共享事务域的窄库归属、迁移拥有者和版本固定方式；禁止把索引/执行 SQL 放回通用 SDK，也不能在两仓复制整套业务存储逻辑。最后拆两个 BFF/Web 并移除集成仓库的业务源码构建路径，再进入 P2.5 DSH 源码和存储改造。

## Knowledge / Indexer source increment (2026-10-12, activation pending)

Knowledge now owns its source, HTTP API, private provider/lexical helpers and sole knowledge-domain migration. The public `indexing` package exposes pending IDs, complete file processing, and bounded backfills, with no exported database field, upload/retrieval routes, DDL or scheduler. Indexer owns a separate process/scheduler and vendors only that narrow dependency closure. Each process retains a separate account and deployment. Sequential file processing and a minimum two-connection pool preserve the existing session advisory-lock behavior; this is not a new persistent fenced lease.

Current source locks: Knowledge `a8afac70934ffefc6dbcf20bf2b3e71678ed4ea0`; Indexer `467fcb990fcb0416ef6cf76e99a4e15752296845`. Indexer compiles Knowledge module `v0.1.0-rc.1` at `e26584df4f1df22da6f3ee9101933dae8f48d164`, canonical sum `h1:HZnGpJI81snXYP0mLiI+Wim+IGDrKXnONVhCsqsHG8M=`. Later Knowledge commits only add grant-rollback tests and correct deployment metadata; the pinned indexing source is unchanged. The tag was not overwritten.

Git HTTPS transport failed, so exact committed blobs/trees/commits were verified and uploaded with GitHub's Git Database API. Canonical module generation used Go's Git transport through a temporary local mirror of the exact remote-verified SHA/tag. No hand-created module ZIP or source replacement is used. Independent consumers build entirely from committed vendor. This verifies the selected source and declared canonical checksums, not an independent audit of every upstream dependency.

Local evidence:

- `local/evidence/p2-knowledge-isolated-cbc4298a01054b41aab72f43a7e4713f/result.json`: fixed e26584d clone, initially empty module cache, GOWORK/GOPROXY off, actual PostgreSQL tests, vet, three executable builds.
- `local/evidence/p2-indexer-isolated-d0c94ff895ec428fac2c6ef75555d5b9/result.json`: fixed 8477abf clone, same offline isolation, scheduler cancellation/failure tests, vet, two builds and narrow dependency-closure check. Later commit only fixes release metadata.
- Restricted PostgreSQL roles exercise upload/dedup/source retention, chunk/name backfill and original read. Real child-process termination after a synthetic LightRAG upload reaches the server causes recovery to `unknown` without a second upload. Saved track IDs are polled without reuploading. The Milvus synthetic endpoint records an upsert then returns HTTP 502; retry preserves IDs. This is not a real Milvus deduplication or TCP-loss test. Optional real RAG backend tests remain skipped.
- A disposable PostgreSQL event trigger fails the first Indexer table GRANT after the Knowledge grants ran; the transaction rolls earlier grants back while retaining pre-existing tables. Normal runtime accounts do no DDL. The migration grants only necessary Indexer permissions on fresh roles; existing broader legacy grants are not silently revoked or claimed retired.
- `local/evidence/p2-knowledge-a3a05bdffa754a1e8623e4a92f61beb8/result.json` retains the first failed test: the child fixture did not inherit its parent's changed database name from pgx ConnString. The corrected helper passes the isolated database explicitly; full rerun is `result-v2.json`. A Windows fixture launcher also waited for the PostgreSQL child tree; only its verified launcher was stopped, and no test had started at that point. The fixture cluster was later stopped normally.
- Review caught an incorrect inherited builtin-tool list in both new release descriptors before activation. They now match the actual knowledge/indexer contracts (`tools=[]`). Review also required checksum comparison with both go.sum lines, beyond agreement of lock/provenance declarations. Both were fixed. Twenty-three synthetic source-selection cases and all eight actual owner contracts/checksums pass: `local/evidence/service-sources-826b2ac9aa224d5f9b262e7d8b19f167/result.json`, `local/evidence/p2-eight-real-owner-contracts.json`.

The integration selects these exact commits and verifies the actual compiled owner-module version without Replace. Release provenance records both consumer and transaction-owner dependencies. The two new source PRs remain drafts: [Knowledge](https://github.com/euler-gaozl/agent-os-knowledge/pull/1), [Indexer](https://github.com/euler-gaozl/agent-os-indexer/pull/1). Live Windows activation/rollback is not yet proven by this entry. Existing five enabled extracted services remain deployed; Telemetry remains a zero-instance release selection. Runtime/Worker, both Web repositories, Harness source/storage work and remaining end-to-end stages are unfinished.

The previously pending integration Platform run for `beb1fd3` subsequently completed successfully: [38257134307](https://github.com/euler-gaozl/agent-os/actions/runs/38257134307). Platform and services jobs passed; optional capacity job was skipped. This is not a new scale claim.
### Knowledge / Indexer Windows release and real executable handoff

The staged set `local/releases/staged/f7e70e089a7f489bb25e55999cb959c5.json` built from integration `66c117e` selected the verified independent Knowledge `a8afac7` and Indexer `467fcb9`. Each role completed update → rollback → update on the actual Windows platform. All six knowledge-domain table fingerprints and the existing status/file listing/original byte hashes stayed identical; non-target processes stayed unchanged. Doctor passed. Evidence: `local/evidence/knowledge-owner-releases-848ef9757e9d4004ac2c48d4b7bfb976/result.json`. Seven enabled independent-owner processes then matched current instance ID, PID and a heartbeat less than ten seconds old: `local/evidence/owner-heartbeats-e4a7b0b063f146f7bb6fcb34acd83287.json`. Telemetry is still not started.

A separate test launched the actual archived baseline Indexer and actual selected new Indexer against disposable PostgreSQL and a synthetic LightRAG peer. Old → new: wait for the POST to arrive and `running` to persist, kill the old executable, and let the new executable set `unknown`; uploads=1, polls=0. New → old: save a track receipt, kill the new executable, and let the old executable poll that same receipt to `ready`; uploads=1, polls=1. The fixture cluster was stopped afterward. Evidence: `local/evidence/p2-indexer-binary-handoff-66206b4475d94e33a26233b086a4a287/result.json`. This does not stop the deployed instances, invoke a real RAG backend, or spend model credits.

The first executable test failed because the old monorepo Indexer's startup readiness probe reads artifacts/artifact_refs; the new minimal migration deliberately does not grant those reads. PostgreSQL confirmed permission denied on artifacts. Failure retained: `local/evidence/p2-indexer-binary-handoff-fbb0eb7437c74440bd2d24cd2d7b979b/result.json`. The corrected compatibility fixture retains these two SELECT grants, as the actual Windows legacy role already does. Fresh new-only roles remain restricted and their earlier tests are unchanged. Do not revoke these reads while still offering rollback to that old executable. This is a concrete permission/rollback condition, not a transport flake or a claim that legacy privileges were retired.

Owner CI at the deployed source passed Linux PostgreSQL/race/vet/build/Docker and Windows unit/build: [Knowledge 38262172316](https://github.com/euler-gaozl/agent-os-knowledge/actions/runs/38262172316), [Indexer 38262181267](https://github.com/euler-gaozl/agent-os-indexer/actions/runs/38262181267). The actual cross-version binary test is explicit opt-in and was executed locally, not by those CI runs.

Knowledge `9d24da4` adds the now-executed binary fixture and rollback documentation; Indexer `ccbfbd2` adds documentation only. No production Go source or fixed indexing module changed. The source lock advances to those documentation/test commits; build metadata must be refreshed before describing them as selected runtime sources. P2 now has eight independent service repositories, seven enabled owner processes and one disabled optional Telemetry process. Runtime/Worker and Console/Futures still require extraction. The overall goal, including DSH source/storage and complete business/UI/failure validation, remains active.
The independent review of the first binary fixture then identified two test-hardening gaps: PostgreSQL URI query identity keys could override its rewritten user/database, and the fault path ignored Kill/Wait outcomes. The helper now removes user/password/dbname/database overrides, validates the parsed scope, connects to assert actual current_user/current_database, and distinguishes tolerant cleanup from explicit fault injection. Injection requires a live process, a successful Kill, a failed exit, and unchanged durable state/track before the replacement starts. The unknown branch asserts zero polls. Both real executable scenarios passed again with these assertions: `local/evidence/p2-indexer-binary-handoff-99bccde24a924fed87e5af5b2fdef767/result.json`. The fixture cluster was stopped. The earlier report remains available; no evidence indicated it actually used overriding query parameters, but it is superseded by this stricter proof. These changes are tests only; the pinned indexing protocol is unchanged.
The final test/documentation source selections were rebuilt from clean integration `752c908` and activated for both roles: Knowledge `5ba230c`, Indexer `ccbfbd2`, staged set `cf140e83082547b8b2395598f98d79cb`. This metadata refresh again preserved all knowledge table/readback hashes and non-target processes: `local/evidence/knowledge-owner-releases-9ea6a6fb428d47ef8d65127facb23fb7/result.json`. All seven enabled owners then had matching current PID/instance/fresh heartbeat: `local/evidence/owner-heartbeats-565967f3ec8e4d19adc84b6468f848e6.json`. Latest owner CI passed: [Knowledge 38264013356](https://github.com/euler-gaozl/agent-os-knowledge/actions/runs/38264013356), [Indexer 38264023759](https://github.com/euler-gaozl/agent-os-indexer/actions/runs/38264023759). Independent static review accepted the fixture identity and explicit-kill corrections without claiming to have executed them. The fixed indexing module remains rc.1/e26584d. The latest platform backup/isolated restore still predates these owner releases; a new checkpoint is required before claiming the eight-owner installation is covered by that recovery proof.

## Runtime / Worker 独立源码与恢复关卡

Runtime 固定事务模块 `v0.1.0-rc.1` 对应 `03bee5165d30708b9e68c76a51a0c4fde2713666`，规范 Go checksum `h1:eg1C7/5XjRmYFnD8XwBvhYc8i1EuwnicjBqfZPCJAyA=`；Worker 只 vendor `execution` 和 `internal/runstate` 两个包，不能引用 Runtime HTTP、工具实现或迁移。Runtime 的 `Exchange` 保留原意图/首次事件事务、归档确认、模型/工具回执、fence 及重放顺序；Worker 保留原 DSH 管道和历史 Go 恢复循环。模型/ToolHub HTTP 属于 Worker，业务效果及笔记事务属于 Runtime。没有重写 DSH 决策循环，P2.5 源码纳管与存储增强仍未完成。

- Runtime 独立 clone、空模块缓存、真实 PostgreSQL 18、受限角色、并发/笔记/丢确认/模型预算/治理检查、vet 和三个程序构建通过：`p2-runtime-source-251793afc8d7478b88b8232c12668eca`；[固定模块 CI 38268513538](https://github.com/euler-gaozl/agent-os-runtime/actions/runs/38268513538) 通过。当前 Owner 选择推进到仅新增测试/说明的 `971949d`，其 CI 另行核对；事务模块 tag 不变。
- Worker `014f577` 独立 clone、空模块缓存、Go 测试/vet/build 通过：`p2-worker-isolated-340dc02f99ad40d2a952f7ba78b111af/result.json`。使用完整固定 DSH 内核及合成模型/ToolHub HTTP，内存 ledger 仅供传输测试；不以此宣称 SQL 恢复。真实 Node 子进程的凭证环境隔离、传输失败与回执拒绝均测试。
- Windows 离线完整包搬迁通过，旧根目录不存在、1473 个文件哈希一致，无目录链接：`p2-worker-package-1fbde8c4c2994decb07d82e9372110ee/result.json`。故意污染 GOOS/GOARCH/GOFLAGS 仍构建本机平台，打包核对 Node/Go 目标及干净源码身份。独立评审只读复核了产物，不冒充自己执行测试。
- 首次 Worker CI `38271844739` Windows 通过，Linux 在包内相对命令文件链接处被全禁链接规则拒绝。`b07b739` 改为允许在包内解析的相对文件链接并记录/核对其目标；仍拒绝目录、绝对或越界链接。修正后的 [38272420124](https://github.com/euler-gaozl/agent-os-worker/actions/runs/38272420124) 两个平台均通过，包含真正搬迁后跑 DSH、Linux race 与 Docker build；本机新固定二进制来自独立 clone `p2-worker-fixed-build-57186b153e294ce6b9687c6d0ae98ba2`。
- 六组实际二进制接管通过：旧 Windows Worker `5bfc84c9` 与新 `b07b739`，legacy-go、DSH 原协议、evidence-v1 各做旧→新和新→旧。工具经真实 Runtime HTTP 提交笔记和回执后，代理阻止回复，此时成功 Kill 且退出失败，再由另一版本领取。新 owner/fence=2 仍在 running 时检查旧请求必须返回 ErrFence，资料无变化后放行。每组恰好一条笔记、一条工具 HTTP、两条模型 HTTP。最终证据 `p2-worker-binary-handoff-3b30a659311644a9aaa476619ea0f654/result.json`；集群已停止，无付费调用。模型、ToolHub 代理、Storage HTTP 是明确夹具，不能算完整部署链路或 Node 进程树清理验收。
- 第一版二进制测试遗漏 Worker 自身身份配置而退出，失败保留 `4da23e3...`。后续评审指出旧 fence 断言位于 completed 后且接受任意错误；最终版已改为 active running 窗口与精确 ErrFence，复验六组通过，评审核对源码/二进制哈希后关闭缺口。原失败/较弱证据不覆盖最终报告。

Worker 新账号仅需执行权限，但旧 monorepo Worker readiness 会 SELECT 全部 Runtime 表。因此本机保留旧 SELECT 授权，不能把新角色最小权限测试当作旧版本回滚证明。没有执行 REVOKE 或拆开笔记/效果/回执的原子事务。

集成的 33 项选源/拒绝测试通过：`service-sources-d2a595f2b39c4406a4942e9b17fc522d/result.json`；十个真实 Owner 合约及 checksum 选择核对通过：`p2-ten-real-owner-contracts.json`。Runtime/Worker 缺锁不再回退主仓；Worker 的 runner/lockfile 必须来自同一个 Owner 提交，Windows 发布包用 hoisted 安装且拒绝目录链接。以上条目还没有执行正式 Runtime/Worker update/rollback；当前七个启用 Owner 与原 Worker/Runtime 继续运行。

### Runtime / Worker 本机切换与真实模型复验（2026-10-13）

干净集成 `57e477a` 构建候选 `local/releases/staged/63eecfdc63664e14aaff9714deab9d32.json`，实际选择 Runtime `971949d`、Worker `b07b739`。两角色各完成 update → rollback → update，共六次发布事务；Worker 每次包含两个实例，所有事务 readiness 通过，非目标进程不变。13 个执行/笔记表的内容哈希以及原运行/笔记 HTTP 响应哈希保持一致；instances 表因真实心跳变化明确不纳入不可变内容断言。报告 `local/evidence/execution-owner-releases-4d6da83314944914857f026bd1dfed0f/result.json`。最终九个启用 Owner 的十个进程逐一核对 PID、实例和新鲜心跳：`owner-heartbeats-e1045fe693434e67b889e338358601b6.json`；Doctor 核心通过。两仓 CI 均成功：[Runtime 38273111646](https://github.com/euler-gaozl/agent-os-runtime/actions/runs/38273111646)、[Worker 38272420124](https://github.com/euler-gaozl/agent-os-worker/actions/runs/38272420124)。

切换前执行维护窗口完整备份 `local/backups/p2-before-execution-owners-20261012`，停止并恢复全部 12 个平台进程；实际独立集群恢复通过，验证 43 个关系/序列及结构权限、受保护凭证解密、当前/上一发布集合和离线 Harness 重建，验证集群已停止。报告 `local/restore-checks/2d5d3b201a46429095b2adf74fee3ec5/result.json`。该恢复点涵盖当时八仓状态，不包含随后新 Runtime/Worker 选择与新增模型验收笔记，不宣称它是十仓最终备份。

随后对真实部署服务调用官方 DeepSeek：固定 DSH evidence-v1 完成 kb_search → document_read → note_save，并通过 HTTP 回读保存笔记；实际 4 次模型请求、6,069 tokens、0 次未知用量。报告 `local/evidence/p2-execution-live-dc31a23d-f065-4541-aedc-26a57b9c76ed/result.json`，run `7eea8469ca9ecd6aa88f093172759c09`。调用前后余额接口均显示 49.89；这只是该接口精度下的结果，不代表调用免费。使用明确标记的合成验收文档，不能当成真实期货数据、完整 UI 验收或 P5 研究。这条路径验证真实独立执行服务与现有 Registry/ToolHub/Knowledge/Storage 的联通；不覆盖所有 MCP/子任务/故障组合。

发布检查还发现集成 Worker 包把 Node 许可证放在资产清单之外。构建脚本已调整为放在被 inventory 的 harness 目录；后续候选包需验证许可证进入导出/恢复清单。旧发布包保持不可变，不能修改其已登记哈希。

## Console / Futures 独立源码与完整包（2026-10-13，激活前）

两个独立私有仓库已建立：[Console PR1](https://github.com/euler-gaozl/agent-os-console/pull/1)、[Futures PR1](https://github.com/euler-gaozl/agent-os-futures/pull/1)。分别固定 `ea0a2553a876686a17f129c33d841df29a12dce4`、`777d9a6392eb4a2315679cfed5dcfe9ed92caf0c`。Console 的兼容服务角色仍为 control；两者数据与 migration_owner 均为 none。Futures 不再导入 Console 实现；少量基础样式/React helper 和有界代理复制为各自维护的源码，来源提交已记录。Web 入口、源码、锁与构建属于各 Owner，没有兄弟目录依赖。外观本批保持原样，完整页面设计与真实浏览器工作流仍属 P3。

独立 clone、空 Go 模块缓存、GOPROXY=off、固定 vendor、Go tests/vet、Web tests/typecheck/build 均通过；完整 native 包搬到新 sibling、原路径消失后，启动实际 BFF 和 Web，验证用户/服务身份区别、当前 PID 心跳、操作接口鉴权、目录缺服务状态、原文字节与下载头，以及业务任务提交/查询/取消和禁止管理 API 转发。下游为合成 HTTP peers，没有数据库或模型调用。报告 `local/evidence/p2-web-isolated-a0418187b5ca4a07be8da1ec6d33dd53/result.json`；两个实际进程已停止。每包 11 个清单文件哈希匹配。DEV_LOCAL 的非本机访问、Host/Origin 和未标记写入在 owner handler 反例测试中拒绝；没有声称此 smoke 执行了完整浏览器页面。

独立静态评审发现并关闭三项问题：旧 SDK 缺用户令牌时退回服务令牌，owner 启动前现拒绝这种回退（Futures 仍兼容独立 ADMIN_TOKEN）；发布包示例原路径与实际输出不符，现改为包内 web 且 smoke 从输出示例读取；测试终止失败时可能漏关上游，现独立 finally 清理。评审核对源码、日志和哈希，没有另跑测试。

集成选择器现在覆盖全部 12 个服务，control 显式映射 agent-os-console；已拆角色缺映射一律拒绝，Web 构建来自同一 Owner 的 web 目录，不能回退集成源码。39 项选源/拒绝夹具通过：`service-sources-a12b76e4f18546ec890f681809fc8a48/result.json`。旧 migrate-services 仍暂留显式历史协调迁移；集成仓库业务源码和 Linux 全链路编排的最终退役尚未完成，不能以 12 个仓库数量宣称 P2 已关卡通过。

前一集成 `57e477a` 的 Platform CI 已确认成功：[38273456738](https://github.com/euler-gaozl/agent-os/actions/runs/38273456738)，platform/services 通过，optional capacity 未运行。Worker Node notices 新候选 `6ef52dbe0e2548ee91c22bcfefa0e4b9` 验证已进入哈希资产清单，报告 `local/evidence/worker-notice-inventory.json`，当时尚未激活；旧已登记包未就地修改。两个 Web Owner 的 Linux/Windows CI 和本机更新回滚结果在通过后补记。
