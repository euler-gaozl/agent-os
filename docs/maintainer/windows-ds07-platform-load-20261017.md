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

## 三分钟 12 任务 soak

- 12 个合成任务一次提交，每任务 5 轮 `run_recall`（每轮模型延迟 6 秒）；每 Worker 接 6 个，**12/12 completed**，step 6，墙钟 **183.1 秒**（约 3 分钟）。
- 采样 120 次、覆盖约 248 秒（`local/evidence/ds07-soak-samples.json`）：
  - PostgreSQL 连接 16–18（结束 16），`xact_commit` +8,068，`blks_read` +15，deadlocks 0。
  - Runtime RSS 24.8→26.2 MB（峰值 26.8）；两个 Worker 42.9→42.1 MB（峰值 49.4）；PostgreSQL 528.9→512.1 MB（峰值 556.3）。
  - Runtime/Worker/PostgreSQL CPU 累计增量 2.92/1.78/4.08 秒。
- 证据：`local/evidence/ds07-soak-2026-10-17T10-32-22-458Z/`。
- 这是 3 分钟合成 soak，不是 30–60 分钟、真实模型/工具网络或容量验收；没有观察到连接泄漏、死锁或 RSS 单调增长，但不能据此断言长期无泄漏。

## 九分钟 36 任务 soak

- 36 个合成任务一次提交，每任务 5 轮 `run_recall`（每轮模型延迟 6 秒）；两 Worker 各接 18 个，**36/36 completed**，step 6，墙钟 **548.6 秒**（约 9.1 分钟）。
- 采样 300 次、覆盖约 623 秒（`local/evidence/ds07-soak10-samples.json`）：
  - PostgreSQL 连接 13–18（结束 16），`xact_commit` +27,637，`blks_read` +5，deadlocks 0。
  - Runtime RSS 25.3→27.2 MB（峰值 27.6）；两个 Worker 41.2→41.9 MB（峰值 49.0）；PostgreSQL 535.4→503.2 MB（峰值 583.1）。
  - Runtime/Worker CPU 累计增量 9.52/4.30 秒；PostgreSQL 聚合 CPU 因后端进程 churn 出现负差值，未作为结论。
- 证据：`local/evidence/ds07-soak10-2026-10-17T10-40-45-513Z/`。
- 仍未达到 30–60 分钟；没有真实模型/工具网络、慢查询/锁等待或故障组合，不能写成生产容量/长期无泄漏。

## 结论与边界

- 8 个并发合成任务没有触发连接耗尽、死锁、临时文件或 Worker 分配失衡；两个 Worker 均实际接单。32 秒双 Worker 负载 2/2 完成；3 分钟 12 任务 soak 12/12 完成；9.1 分钟 36 任务 soak 36/36 完成，连接 13–18、deadlocks 0，RSS 峰值受控且结束回落。
- 该负载没有真实模型延迟、工具网络、外部 Storage/Knowledge 或长历史，不能替代持续 30–60 分钟负载、10 万/百万级任务或服务器容量。
- 未做 PG 慢查询/锁等待、内存增长趋势、故障注入组合；这些仍是 DS-07 的缺口。9.1 分钟仍短于要求的 30–60 分钟 soak。
- 双 Worker 杀 owner 接管已在 DS-05 真实执行（合成模型，20 秒 lease 后接管），不等同于本负载的持续故障矩阵。
- 无付费模型调用、无 CI、无任务删除；合成任务产生了受控笔记与运行记录，保留供复核。
