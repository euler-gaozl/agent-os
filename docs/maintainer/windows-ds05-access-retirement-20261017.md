# DS-05 执行域旧权限退役：正式撤权与兼容发布（2026-10-17）

日期：2026-10-17。状态：**正式 PostgreSQL 已执行 Runtime 旧权限收缩；Worker 最小权限、Telemetry inbox/HTTP 能力已就绪。** 仍保留“撤权后的真实双 Worker 完整任务、Telemetry 实际启动/导出、旧实现删除、Linux 与最终 CI”待验收，不能写成 P2.5/P5 全部完成。

## 前置与回滚保护

- 先尝试 `local/backups/ds05-pre-telemetry-20261017`，因备份命令未带 pnpm 在依赖导出阶段失败；该目录保留，不当作可用备份。
- 重新执行成功：`local/backups/ds05-pre-telemetry-20261017b`（协调备份、45 张表指纹、依赖导出）。该 pre-DS05 快照本身未单独做隔离恢复；DS-08 另用 post-DS05 的 `ds08-final-20261017b` 恢复通过。
- 撤权前只读审计：Runtime/Worker/Telemetry 均为非管理叶子角色，无 public schema CREATE、无成员关系、无默认 ACL、无 prepared transaction；Worker/Telemetry 无活跃会话。

## Telemetry 本域迁移

正式库原先只有 `telemetry_exports`，缺 `telemetry_inbox`，发布保护因此拒绝 Telemetry 作为可发布状态。

- 用 Telemetry `6f9f539` 源码构建 `cmd/migrate`，对正式库执行 `--role agentos_telemetry`：`telemetry migration committed`。
- 验证：`telemetry_inbox` 存在；`agentos_telemetry` 对 inbox 有 SELECT/INSERT/UPDATE，对 exports 有 SELECT/INSERT。
- 该迁移只创建本域表并授权，不删除旧 exports，不触碰 Runtime 表。

## 兼容版本安装

| 服务 | 版本 | 能力 | 状态 |
| --- | --- | --- | --- |
| Worker | `worker-47166229da304bb694f17813b3e7ac69`（`76485b6`） | `worker-minimal-v1` | 已运行 2 实例 |
| Telemetry | `telemetry-d243b05fc74b416aa4c164561e3099be`（`6f9f539`） | `telemetry-http-v1` | 已安装，**0 实例**；可执行 `--execution-access-profile` 返回声明 |

Telemetry `service-sources.json` 已 pin 到 `6f9f539`；旧 Telemetry `fcaca2e` 无 profile，不能作为回退目标。

## 正式撤权

停止 Worker 与 Runtime 后，使用 Runtime `6f9f539` 同源的 `cmd/retire-access` 构建程序，以维护管理员连接执行：

```text
retire-access --role agentos_runtime --worker-role agentos_worker --foreign-roles agentos_telemetry
runtime legacy access retired: runtime-access-v1
```

首次尝试失败原因 `selected consumers still have database sessions`——Runtime 自身仍在运行；停止 Runtime 后成功，这不是 ACL 内容错误。事务只处理 Runtime 的 16 张表和两个序列，不改业务行、外域表或登录配置；失败会整体回滚。

撤权后有效权限（只读查询）：

| 角色 | 对象 | 结果 |
| --- | --- | --- |
| Worker | `runs` | SELECT,UPDATE |
| Worker | `documents` | 无 |
| Worker | `events` | SELECT,INSERT |
| Worker | `events` UPDATE/DELETE | 无 |
| Worker | `events_seq_seq` | USAGE,SELECT |
| Worker | `note_audits_seq_seq` | 无 |
| Telemetry | `events` | 无 |
| Telemetry | `telemetry_inbox` | SELECT,INSERT,UPDATE |

Worker 仍可领取任务、写心跳/回执；Runtime 自身权限未缩减；Telemetry 不再直读执行事件。

## 发布门禁

- 当前 Worker/Telemetry：`Assert-ExecutionAccessDeployment` 通过。
- 旧 Worker `worker-1122e37…`：**通过**——该二进制已声明 `worker-minimal-v1`，不是无能力旧版；因此不能把它当作“旧版必须拒绝”的证据。
- 旧 Telemetry `telemetry-8bc472b…`：**拒绝**：`Unattested Telemetry may require retired events permissions; start or rollback refused.` 这是预期门禁。

## 撤权后真实进程检查

- `Platform.ps1 status`：`core_ready=true`，2 Worker；Runtime/Control/Futures 均在线。
- 第一次无付费夹具任务 `090fa7a3…`：Worker `worker-184a74…` 成功 **claim** 并写入 `claimed`、`checkpoint`、`model_started`、`model_failed`；第 1 步因合成模型 `127.0.0.1:8112` 未运行而失败（连接被拒绝），不是数据库权限拒绝。该次只证明领取/事件写入。
- 启动本机合成模型夹具 `127.0.0.1:8112`（OpenAI-compatible，非真实供应商）后，重新提交同一无付费 Agent 任务 `3fa0b9b7…`：**completed**，step 3，owner `worker-41c7b1b4…`；工具回执包含 `note_save`（写入 `POST_RETIREMENT_NOTE`）与 `run_recall`（读回该记录），最终模型回答 `POST_RETIREMENT_OK: note_save and run_recall completed.`。这证明撤权后 Worker 最小 `runs`/`calls`/`events` 权限、Runtime 笔记原子写入与回读、工具回执链路可用。
- 该任务使用合成 `evidence-recall-fixture`，不是 DeepSeek/真实供应商；不能写成真实模型任务通过。
- 证据：`local/evidence/ds05-access-retirement-4a1fe16c53504a7b8764b0fc9cd558a8/result.json`、`local/evidence/post-retirement-worker-fixture-2026-10-17T10-10-27-213Z/terminal.json`、`local/evidence/post-retirement-worker-2026-10-17T10-01-42-905Z/`。

## Telemetry 启动检查

- 已安装 `telemetry-http-v1`，但尝试启动时服务退出：`valid HTTP(S) endpoint without credentials required`。当前 Telemetry 配置没有可用的 `LANGFUSE_URL`/导出端点，因此保持 **0 实例** 是配置缺口，不是 ACL 或程序能力失败。
- 未执行实际接收/导出；不能把 profile 声明或 inbox 授权写成 Telemetry 端到端通过。

## 仍待完成

1. 撤权后的**双 Worker 接管**（杀 owner、lease 过期后另一 Worker 完成同一任务）与历史回读；本次已完成单 Worker 完整任务与笔记回读，但未做接管。
2. Telemetry 配置有效导出端点后实际启动/接收/导出（Langfuse 或受控 OTLP），不能只凭 profile 声明。
3. 旧实现覆盖逐行移交与删除（P2 清单）、Linux 组合、W01–W14 剩余项。
4. DS-08 已用 post-DS05 快照 `ds08-final-20261017b` 通过隔离恢复；本 pre-DS05 快照保留为历史保护点，未单独恢复。
5. 最终统一 CI 仅在全部本机验收后执行一次。

## 边界

- 本次是正式本机 PostgreSQL 的权限收缩，不是服务器/跨机 HA、Linux 或容量验收。
- 没有付费模型调用、没有 GitHub Actions；没有删除旧任务或业务行。
- 备份存在不等于恢复已验证；DS-08 已用 post-DS05 快照恢复通过，但本 pre-DS05 快照未单独恢复，不能把两者混为同一次恢复。
