# Mac Telemetry / Runtime Owner 覆盖移交（2026-10-15）

环境：维护者独立 macOS 15.3（24D2059）/arm64、Go 1.27.2、PostgreSQL 18.6；仅本机新隔离数据库夹具。延续 [旧覆盖退役矩阵](../p2-linux-cutover.md) 与 [前次研究/UI 记录](macos-research-verification-and-ui-20261015.md)，不改原 Windows 历史、旧任务或数据。

## Telemetry 真实缺陷与局部移交

旧导出器只读取确认回包的前 4096 字节。合成 HTTP 200 回包前 4096 字节为有效 JSON 加空白，第 4097 字节使完整回包无效；旧实现接受了截断前缀。先在真实隔离 PG 上运行 `TestTelemetryRejectsOversizedAcknowledgement`，实际失败、0 skip：观察到 exportOne 错误返回成功；沿旧生产路径对应成功标记提交，red 分支没有另行查询两表。再最小修正为读 4097 字节并明确拒绝超过 4096 字节的确认。green 实际查询确认拒绝后 inbox 保持待导出，成功重试才写标记，恰好 4096 字节的有效回包仍接受。这是合成 OTLP 回包发现的程序缺陷，不是假称真实 Langfuse 曾发生该故障。

本次定向 race 检查 7 项全部通过、0 失败/0 skip，package elapsed 2.267 秒：5 项新回归覆盖并发导出只发送一次已确认事件、Runtime receive 失败仍能导出已落盘 inbox、partialSuccess 拒绝后重试，以及超限/边界确认；另 2 项为既有 Inbox 与 Owner migration 检查。vet/build `./...` 通过。Runtime receive 失败这一项是顺序调用 receiveTelemetry/exportOne 的独立性测试；没有证明持续后台循环活性或真实 Runtime 进程故障恢复。

新增 5 项导出回归使用 Owner 迁移创建的 telemetry_inbox/telemetry_exports，每条应用池连接通过 NOLOGIN/SET ROLE 访问。既有 Inbox 测试仍使用 fixture 数据库的所有者池；既有 migration 测试另有显式 SET ROLE 权限检查，不能把全部 7 项说成受限应用池执行。Registry 凭证解析、Runtime 故障、OTLP 接收均为本机 HTTP 协议夹具，不含真实供应商密钥。它不是独立账号登录、真实 Langfuse、Worker 或跨 Owner 联调验收。

## Runtime 权威侧覆盖

Runtime 2 项实际测试通过、0 失败/0 skip；使用 race，package elapsed=31.795 秒，租约场景为 30.15 秒。低序号晚提交与身份拒绝、生产 30 秒租约自然到期和新 fence、旧 owner/旧 fence 拒绝、混合批次原子回滚及重复 ack 已验证。vet `./runtime`、build `./...` 均通过，退出码来自根代理实际执行回执，不以空日志证明成功。原始 JSON 测试日志为 `local/evidence/macos-telemetry-owner-20261015/runtime-green.jsonl`。

两个 Owner 各守自己的数据域，没有把 Runtime 实现导入 Telemetry，也没有在 Runtime 测试中引入 exporter。Runtime 测试使用实际生产 Handler/Authorize 和 loopback HTTP，检查 wire 仅有 sequence/run_id/kind/created_at/fence 五字段；晚提交事务与完整行比对均在 Runtime 本域。NOLOGIN/SET ROLE 不等于独立登录。生产 Runtime/固定 DSH 决策循环、旧快照和引擎协议均未修改。

## 来源、失败留存与评审

| 仓库 | 本轮本地源码 | 安装状态 |
|---|---|---|
| Telemetry | `6f9f539125431bebbf88ddbdbb6840f3dd426068` | 未部署/未启用 |
| Runtime | `ff3fa220df331f698c99b260005cc222d0dcdb1c` | 运行版本未替换 |

测试在原基线加审查后的工作树执行；本地提交后以受测源文件 SHA 核对归档提交，README 只补实际观测，没有重跑 commit tree。`verification.json` 记录两仓精确测试名、race、退出码来源、受测源文件与日志摘要。`fixture-cleanup.json` 记录专用 Mac 夹具集群中 p2_runtime_/p2_telemetry_ 数据库和角色前缀剩余均为 0，是根代理只读核对，不是额外删除。15 仓 5146 文件对已提供 API 密钥作精确匹配为 0，不称为 gitleaks 或所有秘密的全面扫描。

证据目录 `local/evidence/macos-telemetry-owner-20261015/` 保留 `telemetry-red.jsonl`、`telemetry-green.jsonl`、vet/build 日志。首次 green 命令误从聊天目录运行，未执行测试，原失败 `telemetry-green-wrong-cwd.jsonl` 保留，不计测试失败或通过。最初 workflow 候选因 JS replacement 的 dollar-apostrophe 展开尾文而损坏，在应用前被根代理发现；原文 `workflow-v1-invalid.yml` 保留。修订后整块写入，通过 YAML 解析、4 段 bash -n 与 5 组 jq 合成事件关卡验证，未运行工作流。

`langfuse.yml` 移除 PR 自动触发，只保留 workflow_dispatch/workflow_call；Go JSON 测试事件必须有指定 live 测试 pass 且零 skip，空运行/其他目标/跳过不会变绿。真实 Langfuse 4.56.0 的接收/回读/重投仍待最终统一 Linux 验收。日常不运行 Actions。

独立静态评审与实际 green 只读复核分别留存，没有由作者自评冒充独立通过。同一证据目录保存 `telemetry-owner-independent-review.md`、`runtime-telemetry-independent-review.md` 及两份 `*-green-independent-delta.md`。Telemetry green 复核 SHA-256 为 `3f68d36e2b7fe662af2507c7dd1e8db8d4c5712f2c598cad0d34bacb8a4a6953`，Runtime 为 `02e84da22a78ad2084fad5b8cf11b05b00a3e7ec03c3928805fb02c5c21f6d03`。

## 保留的验收范围

旧主仓 Telemetry/Runtime 测试与 live 工作流继续保留；两个 Owner 局部切片不等价于完整组合或旧覆盖全部退役。未做真实 Langfuse、Docker Sandbox、Milvus/LightRAG/Embedding、实际服务发布/回滚、浏览器、付费模型、Actions 或 Windows 验收。Sandbox 的 Runtime 权威授权失败分支仍是另一个待移交项，扩展未配置不阻断无须该扩展的核心。

P0–P5/P2.5 七阶段和 W01–W14 全范围保持；P2/P2.5、服务退役、存储生命周期、剩余故障/资源、UI 与研究质量都不因本切片关闭。未推送，未更新部署 pins、编译协议或任何旧证据。
