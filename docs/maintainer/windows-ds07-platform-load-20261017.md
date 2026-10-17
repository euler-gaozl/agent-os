# DS-07 整平台与 PostgreSQL 短并发负载（2026-10-17）

日期：2026-10-17。状态：**部分完成**。已用撤权后的真实 Runtime/Worker/PostgreSQL 和两个 Worker 跑 8 个并发合成任务，全部完成；这是短并发烟测，不是持续负载、真实供应商或容量验收。

## 负载

- 合成 `evidence-recall-fixture`（本机 8112，非真实供应商），每任务 `note_save` + `run_recall` + 最终回答，3 步。
- 通过 Console `/api/runs` 同时提交 8 个任务；两个 Worker 各接 4 个。
- 结果：**8/8 completed**，0 failed，0 cancelled；从最早 `created_at` 到最晚 `updated_at` 墙钟 **1.50 s**（同一批提交和完成，不代表稳定吞吐）。
- 证据：`local/evidence/ds07-platform-load-2026-10-17T10-25-37-835Z/`（`submitted.json`、`final.json`、`load.json`）。

## 资源快照

| 对象 | 负载前 | 负载后 | 差 |
| --- | --- | --- | --- |
| PostgreSQL `xact_commit`（累计） | 208,024 | 209,635 | +1,611 |
| PostgreSQL `blks_read`（累计） | 4,787 | 4,804 | +17 |
| PostgreSQL 连接数 | 22 | 24 | +2 |
| PostgreSQL temp_files / deadlocks | 0 / 0 | 0 / 0 | 0 |
| Runtime RSS | 23.9 MB | 25.4 MB | +1.5 MB |
| 两个 Worker RSS 合计 | 38.9 MB | 42.3 MB | +3.4 MB |
| PostgreSQL RSS（22/24 后端合计） | 422.4 MB | 481.4 MB | +59.0 MB |
| Control RSS | 20.1 MB | 20.8 MB | +0.7 MB |
| Futures RSS | 18.0 MB | 18.1 MB | +0.1 MB |

统计口径：`pg_stat_database` 为自上次统计重置以来的累计值，差值只是本窗口；RSS 是 Windows `WorkingSet64`，不是 PSS/峰值；CPU 为进程累计秒数，短窗口不适合作吞吐结论。

## 持续 32 秒的双 Worker 负载

- 两个合成任务同时提交，每任务连续 5 轮 `run_recall`（每轮模型延迟 6 秒）再最终回答；两个 Worker 各接 1 个，均 `completed`（step 6），墙钟 **32.6 秒**。
- 采样 30 次、覆盖约 61 秒（`local/evidence/ds07-sustained-samples.json`）：
  - PostgreSQL 连接数 18→18，峰值 18；`xact_commit` +1,471；`blks_read` +1；deadlocks 0。
  - Runtime RSS 24.3→25.1 MB；两个 Worker RSS 峰值 44.9 MB（结束 43.5 MB）；PostgreSQL RSS 峰值 540.2 MB（结束 525.7 MB）。
  - Runtime/Worker/PostgreSQL CPU 累计增量分别为 0.65/0.33/0.92 秒。
- 证据：`local/evidence/ds07-sustained-2026-10-17T10-27-59-840Z/`。
- 首次同形负载因夹具使用 `run_recall(kind=events, query=sustained-load)` 被 Runtime 400 拒绝，任务 step 1 失败；改为 `kind=tools` 后成功。这是夹具参数问题，不是平台容量/权限问题；失败目录保留为证据。

## 结论与边界

- 8 个并发合成任务没有触发连接耗尽、死锁、临时文件或 Worker 分配失衡；两个 Worker 均实际接单。32 秒双 Worker 负载同样 2/2 完成，连接数稳定、无死锁。
- 该负载没有真实模型延迟、工具网络、外部 Storage/Knowledge 或长历史，不能替代持续 30–60 分钟负载、10 万/百万级任务或服务器容量。
- 未做 PG 慢查询/锁等待、内存增长趋势、故障注入组合；这些仍是 DS-07 的缺口。32 秒只是短持续样本，不是生产 soak。
- 双 Worker 杀 owner 接管已在 DS-05 真实执行（合成模型，20 秒 lease 后接管），不等同于本负载的持续故障矩阵。
- 无付费模型调用、无 CI、无任务删除；合成任务产生了受控笔记与运行记录，保留供复核。
