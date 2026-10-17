# DS-08 最终备份与隔离恢复（2026-10-17）

日期：2026-10-17。状态：**通过**。在 DS-05 正式权限收缩与 Telemetry inbox 迁移之后创建最终备份，并在随机端口、独立 PGDATA 的临时 PostgreSQL 集群完成真实恢复、权限/身份/凭据/依赖校验；临时集群已停止。**仍不是服务器/跨机 HA、八物理库或外部 Langfuse/Milvus/LightRAG 验收。**

## 备份

- 目录：`local/backups/ds08-final-20261017b`（不提交 Git）。
- 创建时间：DS-05 ACL 收缩之后；备份中包含 46 张表/序列指纹（比撤权前多 `telemetry_inbox`）。
- 备份过程会停止并重启正式服务；本次停止 12 个进程、PostgreSQL 保持运行，随后恢复 12 个进程。
- 备份只证明“捕获完成”，恢复验证在独立集群执行，不覆盖正式实例。

## 隔离恢复

入口：

```text
Platform.ps1 restore-check -BackupDirectory local/backups/ds08-final-20261017b -Pnpm <pnpm>
```

结果文件：`local/restore-checks/8aadcb287d5f4ac2a3be8488428bd912/result.json`（`status=passed`）。

| 检查 | 结果 |
| --- | --- |
| 备份 manifest 与逐文件 SHA-256 | 通过 |
| 临时 PostgreSQL | `initdb` 新目录、随机 loopback 端口、独立管理角色；启动后核对 `data_directory` 所有权 |
| 恢复数据库 | `agentos` 1 个数据库，46 个表/序列关系 |
| 内容指纹 | 每张表/序列的 schema、kind、行数、SHA-256 全部匹配 |
| 元数据/ACL | 数据库 owner、权限、设置匹配；schema 与对象权限匹配 |
| 服务账号登录 | 10 个角色实际登录成功 |
| 身份索引 | `services/identities.json` 与 12 份服务配置的 SERVICE_TOKEN 一致 |
| 密封凭据 | 3 条 Registry 密封凭据成功用恢复的 MASTER_KEY 解密（不输出明文） |
| 归档发布/Worker 依赖 | 2 个归档 Worker bundle 的 Node/Harness 检查通过 |
| Harness 离线重建 | 仅用备份的 pnpm store 重建依赖，3 项 Node 接口测试通过 |
| 临时集群停止 | `isolated_cluster_stopped=true` |

## 边界

- 当前正式库是**一个**物理 `agentos` 数据库（含各域 schema），不是八个独立物理库；本次恢复验证不能写成“跨物理库恢复”。
- 恢复验证在临时集群内完成，不启动正式服务、不调用模型、不访问 Milvus/LightRAG/Langfuse；外部服务恢复另需能力验收。
- 备份/恢复证明 SQL 数据、权限、身份和固定依赖可重建；不证明真实任务在恢复后成功、不证明服务器/HA、不证明百万文档/千万块容量。
- 临时集群保留在 `local/restore-checks/8aadcb287d5f4ac2a3be8488428bd912`（已停止），未递归删除；保留策略需单独确认。
- 本次没有 GitHub Actions、付费模型调用或正式库写入；正式服务在备份/恢复期间短暂停止后恢复。

## 结论

DS-08 的“最终备份 + 隔离恢复”已由真实 PostgreSQL 集群验证通过。它关闭的是备份恢复项，不是 DS-05 剩余的双 Worker 接管、DS-06 存储生命周期、DS-07 整平台故障/资源或 DS-09 集中 CI。

## 当前版本复验：ds08-final-20261017c

- 在 Worker `1ac65212…`（19 秒 Runtime 中断恢复）、Futures `fdc9a7…`（同品种历史任务）和 Console `94f118…` 安装后重新创建备份 `local/backups/ds08-final-20261017c`；备份期间停止并重启 12 个正式进程，PostgreSQL 保持运行。
- 隔离恢复 `local/restore-checks/77c551dec1784f66bc185be671124352/result.json`：`status=passed`。
  - **46** 个表/序列关系指纹、schema/ACL 匹配；
  - **10** 个服务角色实际登录成功；
  - **5** 条密封凭据成功解密（不输出明文）；
  - 2 个归档 Worker bundle（`worker-1ac65212…`、`worker-8e77e8cb…`）检查通过；
  - 离屏 Harness 重建 3 项测试通过；
  - 完整发布 186 代、25 引用、3,073 文件全部校验；
  - `isolated_cluster_stopped=true`，`provider_calls=0`。
- 边界仍同前：单物理库、临时集群、不启动业务/不调用模型/不访问外部服务；不证明恢复后真实任务成功、服务器/HA 或百万文档容量。

## 最新复验：ds08-final-20261017d

- 在 Worker `79f0e9d1…`（60 秒 Runtime 中断退避）、Futures `fdc9a7…`、Console `94f118…` 后重建 `local/backups/ds08-final-20261017d`。
- 隔离恢复 `local/restore-checks/604dcdf48dbe4dc0a834d991228dba67/result.json`：`status=passed`。
  - **46** 个关系、**10** 个角色登录、**5** 条密封凭据解密；
  - 2 个归档 Worker bundle（`worker-1ac65212…`、`worker-79f0e9d1…`）检查通过；
  - 完整发布 **187 代 / 25 引用 / 3,073 文件**；
  - 离线 Harness 3 项通过，`isolated_cluster_stopped=true`，`provider_calls=0`。
- 仍不证明恢复后真实任务成功、服务器/HA、八物理库或外部服务恢复。
