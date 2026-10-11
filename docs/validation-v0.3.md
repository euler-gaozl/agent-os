# v0.3 验证记录

日期：2026-10-11，Windows amd64，AMD Ryzen 9 5900X；Go 1.27.2、PostgreSQL 18.6、Node 24.19.0、pnpm 11.25.0。实现位于本 PR；本文和测试随实现一起提交，不能据此外推后续版本。

## 已执行

`go vet ./...` 和带真实 `TEST_DATABASE_URL` 的 `go test -count=1 -v ./...` 通过。共 **32 个实际场景**，另有 1 个启动故障测试子进程的 helper test。最近一次核心回归用时约 6.9 秒，不含编译。每个数据库测试用随机独立 schema，未把虚构行情、模型回复或模拟服务结果写入正式资料库。

| 场景 | 实际证据 | 限制 |
| --- | --- | --- |
| 资源与绑定版本 | SnapshotPinsResourceVersions | 配置版本冻结，不代表 Go 代码或供应商模型可复现 |
| 并发领取 / 旧 Worker | ConcurrentClaimsAndFencing | 同一真实 PostgreSQL，未测跨地域或网络分区 |
| 本地效果 / 回执原子性 | AtomicToolEffectAndReceipt、RecoveryAfterToolCommitBeforeCheckpoint | 受控数据库事务，不保证外部服务 exactly-once |
| 真进程故障 | RealProcessKillAndTakeover | 启动两个真实 Go 子进程；杀掉 A，B 在租约过期后接管；检查完成记录和 abandoned attempt；模型为本地 HTTP fixture |
| 外部未知效果 | UnknownExternalIsNotBlindlyRetried、CancellationPreservesUnknownExternalOutcome、ConnectorPrefixCannotEnableMutationRetry | 受控外部调用 fixture，检查重复调用边界 |
| 取消 / 子任务 / 约束 | CancellationAndChildSpawn、ConstraintRevisionRejectsOldPlan、ParentCancellationWaitsForChildReconciliation、ConstraintChangesReachActiveChildren | 限定任务树和事务并发，未做任意规模模型协作 |
| 模型结果提交 | ModelTruncationCannotDriveTools、FinalOutputCheckpointResumesWithoutModel | 截断 fixture 不执行工具，完成 checkpoint 不重复问模型 |
| Compact | CompactionRetainsOriginalAndConstraints、ToolSchemasCountTowardContextBudget | 固定摘要 fixture 验证记录、约束、引用和预算；不证明真实语义质量 |
| 存储 / 记忆 / 凭证 | ImmutableArtifactsAndGC、ArtifactPagingRetainsReadableContent、MemoryScopeAndExpiry、EncryptedCredentialsAndNameBinding | 真实数据库；未测磁盘损坏或大型资料库 |
| 协议与认证 | MCPHandshakeAndSSE、SchemaRejectsExternalReferences、LocalAuthenticationRejectsRebinding | MCP/HTTP fixture；非外部供应商验收 |
| 观测 | TelemetryFailureDoesNotBlockExecution、TelemetryAcknowledgement | 模拟接收端失败和确认结果，未连接真实 Langfuse |
| 原文件与知识版本 | KnowledgeUploadRetentionDedupAndVersionIsolation | 真实 PG，哈希/去重/库版本隔离 |
| Milvus / Embedding | MilvusEmbeddingAndSourceBackreference、EmbeddingRejectsDimensionDrift | 模拟 REST 与 embedding；没有真实 Milvus 或模型性能结果 |
| LightRAG | LightRAGTracksAsynchronousCompletionAndUnknownOutcome | 模拟异步 track 状态和上传中断；没有真实图谱质量结果 |
| Agent 使用知识服务 | AgentUsesBoundKnowledgeService | 真 PG + HTTP 服务调用 + fixture 模型，检查绑定库与来源 |
| 应用隔离 / 幂等 | BusinessUsesRuntimeAndHidesPlatformConfiguration、ControlProxyPreservesSubmissionIdempotency | 真实 HTTP 路由，业务接口不提供资源目录；中台代理保留幂等键 |

测试可从 `internal/platform/*_test.go` 重现。Linux `-race` 由 GitHub Actions 运行，远端结果见 PR Checks；此文不将待运行配置写成 CI 已通过。

## 浏览器与本地多实例

本机实际运行 11 个进程：control、registry、runtime、toolhub、storage、sandbox、knowledge、indexer、futures 和 2 个 worker。`/api/status` 返回 v0.3.0，DeepSeek 凭证未配置。sandbox 服务启动不代表 Docker 执行可用。

实际浏览器完成：上传研究方法 Markdown → 文件状态可检索 → 用“核心问题”检索得到正文与来源 → 在 Agent 编辑页绑定该知识库和文档回读工具 → 保存为期货 Agent v2。三个业务动作更新为绑定该确定版本。该文件来自仓库的研究方法，不是市场数据。已检查中台编辑器右侧 Playground、独立期货首页、390 像素窄屏期货布局；浏览器 error/warn 为空。

前端 `tsc --noEmit` 和两个 Vite 构建通过。构建有 lucide 模块 `use client` 指令的 Rolldown 提示；这是纯客户端应用，未出现运行错误。浏览器截图留在本机忽略目录 `.state/screenshots/`，不上传个人资料。

## 备份实际恢复

备份：`.state/backups/20261011-143220.dump`。验证脚本创建本次独有的临时数据库，执行 pg_restore，再检查并清理该临时数据库，正式库未被覆盖。

```text
resources=11
documents=1
artifacts=1
artifact_hash_mismatches=0
dangling_artifact_refs=0
```

这是小数据量恢复验证；未验证 MASTER_KEY 异地恢复、真实外部索引或大规模备份时长。备份仍在同一个物理盘，不能宣称抗整盘损坏。

## 小规模性能测量

真实本机 PostgreSQL：`BenchmarkDurableTaskLifecycle-24`，50 次，约 **1,333,464 ns/op**（1.33 ms）、13,025 B/op、172 allocs/op。仅测提交/领取/完成的持久化事务路径；不含模型、工具网络、Embedding、图谱、并发扩容或 UI 延迟。没有用语言标签或这个微基准宣称生产吞吐。

## 尚未验证 / 尚未完成

没有真实 DeepSeek、Embedding、Milvus、LightRAG、Langfuse 端到端调用；没有 Docker/Compose 实机部署。没有真实长任务 Compact 保全率、模型研究正确率、全品种采集覆盖、独立服务数据库隔离、多租户/RBAC、硬费用预算、数据库 HA、磁盘满/断电测试或确定的 RPO/RTO。v0.1 评审由用户指定的独立 Agent 完成，本版实现没有重新进行独立 Agent 代码审计。
