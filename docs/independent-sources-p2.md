# P2 独立源码与发布验收

2026-10-12。P2 进行中；本记录覆盖正在分批交付的六个服务，不代表 12 个服务或整个平台已完成。

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

每个仓库有独立 Go module、命令、镜像、服务配置例子、事务迁移和 PostgreSQL 测试。正常进程不做 DDL；迁移只改变本域表，在一个事务内提交表结构及授权，锁/语句超时有界。不重写其他服务配置或访问其数据库。Runtime/Worker 和 Knowledge/Indexer 后续保留必要的事务域，不以强拆事务伪造独立性。

## 可重复构建

SDK 固定 `v0.1.0-rc.2` / `f45ca168dee81f864533a8f77f8c203960caad1a`，规范 Go 模块校验值 `h1:SunD5Oyh1le4sv3CMJTpKCa0SsKBQDqXoBoAC0aji98=`。通过 Go 下载器从固定 Git tag 获取，三个消费者提交 vendor，构建时 `GOWORK=off`、`GOPROXY=off`、`-mod=vendor`；不依赖兄弟目录替换或给 CI 配个人跨仓库令牌。先前自制 ZIP 校验失败已保留并废弃，不能使用其缓存重新生成依赖。

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