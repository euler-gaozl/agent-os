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

## 三十分钟 24 任务 soak

- 24 个合成任务一次提交，每任务 5 轮 `run_recall`（每轮模型延迟 30 秒）；两 Worker 各接 12 个，**24/24 completed**，step 6，墙钟 **1806.0 秒（30.1 分钟）**。
- 采样 950 次、覆盖约 33 分钟（`local/evidence/ds07-soak30-samples.json`）：
  - PostgreSQL 连接 13–18（结束 14），`xact_commit` +49,992，`blks_read` +1，deadlocks 0。
  - Runtime RSS 27.7→29.2 MB（峰值 30.6）；两个 Worker 46.5→42.0 MB（峰值 48.1）；PostgreSQL 520.4→475.1 MB（峰值 589.1）。
  - Runtime/Worker CPU 累计增量 21.46/3.75 秒；PostgreSQL 聚合 CPU 未作为结论。
- 证据：`local/evidence/ds07-soak30-2026-10-17T10-59-58-319Z/`。
- 这已达到 30 分钟下限，但仍是合成模型/无外部 Storage/Knowledge、无真实模型网络；慢查询/锁等待与故障组合仍未做，不能写成生产容量或长期无泄漏。

## PG 行锁故障

- 合成任务 `8eedffb0…` 在第 2 步时，用真实 PostgreSQL 事务对 `runs` 行执行 `SELECT ... FOR UPDATE` 并 `pg_sleep(8)`，锁退出码 0。
- 任务在锁持有期间停在第 2 步，锁释放后于约 8.2 秒进入第 3 步；最终 **completed**，step 6，总观察时长约 20.5 秒，无死锁、无任务失败。
- 证据：`local/evidence/ds07-pg-lock-2026-10-17T11-34-33-505Z/`。psql 的 `cat` pager 提示是 Windows pager 噪音，SQL 退出码为 0，不是数据库错误。
- 这只验证 8 秒行锁等待/恢复；未验证超过 Worker/DB 超时的锁、慢查询计划、锁升级或死锁注入。

## PG 30 秒行锁：显式失败

- 任务 `91c6581e…` 在第 2 步时对同一 `runs` 行加锁并 `pg_sleep(30)`；锁退出码 0。
- 任务在锁持有期间停在第 2 步，约 **36.9 秒**后才进入第 3 步；继续到第 4 步后，在第 6 步失败：
  `family model attempt budget exhausted (retries included)`。
- owner 未切换、没有静默成功、没有写入成功终态；失败原因来自重试/模型尝试预算耗尽，是长锁的连锁影响。
- 证据：`local/evidence/ds07-pg-lock30-2026-10-17T11-36-18-709Z/`。
- 这说明 30 秒行锁超过当前重试预算，任务会明确失败；8 秒锁可恢复。未做自动重试/补偿策略、锁超时参数调优或死锁注入。

## PG 15 秒行锁 + 取消

- 任务 `6a71a39d…` 在第 2 步时被外部事务锁定 `runs` 行 15 秒；锁定 2 秒后发送 cancel，返回 **202**。
- 锁释放后任务进入 **cancelled**（step 3），`cancel_requested=true`；没有 completed/成功终态，没有静默成功。
- 证据：`local/evidence/ds07-cancel-lock-2026-10-17T11-55-26-316Z/`。
- 这验证“DB 阻塞期间的取消”能落到显式 cancelled；未验证取消与 fence 接管同时发生、取消后的补偿清理或锁超时。

## 接管前取消

- 任务 `bb172a27…` 在第 10 步强杀 owner，随后立即 cancel（**202**）；cancel 事件在第二 Worker 以 fence 2 接管前写入。
- 接管后终态为 **cancelled**（step 0，error `lease expired, cancelled, or worker superseded`），`cancel_requested=true`；已有 10 个工具回执，但没有 completed/成功终态。
- 证据：`local/evidence/ds07-cancel-takeover-2026-10-17T11-57-32-350Z/`。
- 这验证“取消与 lease/fence 接管竞争”不会静默完成；未验证取消后清理外部副作用或取消重试。

## 30 秒行锁 + 取消：复现、修复与复验

- 原失败任务 `904e4c9c…` 在第 2 步被外部事务锁定 30 秒；取消返回 **504 `database operation timed out`**，没有 `cancel_requested`，任务随后 step 6 failed。
- 根因：`Cancel` 继承连接的 15 秒 `statement_timeout`，在 30 秒行锁等待中被 PostgreSQL 取消。
- 修复：Runtime `55dc3cd` 在 cancel 事务内设置 `statement_timeout=60s`、`lock_timeout=60s`；已安装 `runtime-57ce21ba…`，readiness verified。
- 复验任务 `e05fa5ac…`：30 秒行锁、锁定 2 秒后 cancel，返回 **202**；最终 **cancelled step 0**，`cancel_requested=true`，无成功终态。
- 原始失败证据：`local/evidence/ds07-cancel-lock30-2026-10-17T12-01-55-176Z/`；复验证据：`local/evidence/ds07-cancel-lock30-2026-10-17T12-06-26-286Z/`。
- 边界：60 秒上限仍不是异步取消；超过 60 秒的锁仍会超时。15 秒锁、30 秒锁现在均能取消；未验证取消后的外部副作用清理。

## Worker DB 连接中断

- 任务 `b6ad844b…` 在第 2 步运行中，使用本机 PostgreSQL 超级用户终止了 **3 个** `agentos_worker` 后端会话；影响仅限 Worker 角色。
- 任务随后仍 **completed step 6**，owner 未切换，5 个 `run_recall` 回执与最终结果完整；没有成功丢失或静默重做。
- 证据：`local/evidence/ds07-db-connection-loss-2026-10-17T12-34-03-769Z/`。
- 这只验证单次 Worker 连接中断后的恢复；不是 PostgreSQL 重启、网络分区或整机故障，也未测量连接池重连耗时。

## PostgreSQL 重启

- 任务 `d72c345f…` 运行中执行 `pg_ctl restart -m fast`；PostgreSQL 的 `pg_postmaster_start_time()` 为 **20:36:20**，落在任务事件窗口 **20:36:07–20:36:37** 内，证明确实发生重启。
- 任务仍 **completed step 6**，5 个 `run_recall` 回执完整；`Platform.ps1 status` 随后恢复 `core_ready=true`、2 Worker。
- 证据：`local/evidence/ds07-pg-restart-8807c89b9c3449ffb204efc35deebc18/`（`result.json`、`meta.json`）。
- 说明：辅助脚本在重启等待中超时被杀，未捕获 `pg_ctl` 输出；重启事实由 postmaster start time 与任务时间窗共同证明。只验证快速重启，不是网络分区、整机断电或主备切换，也未测量重连/恢复耗时。

## Runtime 服务中断

- 任务 `bd529d74…` 在第 2 步运行中，`Platform.ps1 stop -Service runtime`（退出码 0）后约 4 秒 `start`（退出码 0）。
- 任务在第 3 步 **failed**：`service HTTP 503: {"error":"upstream service unavailable"}`；没有自动续跑或成功终态。
- Runtime 重启后 `Platform.ps1 status` 恢复 `core_ready=true`、2 Worker；这是进程级恢复，不是任务透明续跑。
- 证据：`local/evidence/ds07-runtime-outage-2026-10-17T12-43-04-858Z/`。
- 修复尝试：Worker `0be7f2f` 将 SourceState 5xx 重试扩到 6 次（250ms–3s，总约 6.75 秒），安装为 `worker-894fcadc…`。
- 复验任务 `8f80b4f5…`：同样的 Runtime stop/start 仍在 **step 3 failed**，错误仍为 `service HTTP 503`；该重试没有覆盖实际失败路径或重启窗口仍超预算。
- 复验证据：`local/evidence/ds07-runtime-outage-2026-10-17T12-48-14-410Z/`。
- 第二次修复尝试：Worker `f623f30` 对 ToolHub `/invoke` 的 5xx 做 5 次、250ms–2s 退避（同一 operation ID），安装为 `worker-8e77e8cb…`；复验任务 `e4c57c1f…` 仍 **step 3 failed**，503 未消除。
- 复验证据：`local/evidence/ds07-runtime-outage-2026-10-17T12-52-08-061Z/`。
- 第三次修复：Worker `1802936` 将 ToolHub `/invoke` 5xx 重试扩到 10 次（250ms–3s，总约 19 秒），安装为 `worker-1ac65212…`；复验任务 `d5fbaf41…` 在 Runtime stop/start 后 **completed step 6**，owner 未切换，5 个回执完整。
- 成功证据：`local/evidence/ds07-runtime-outage-2026-10-17T12-55-59-068Z/`。
- 长停机边界：另一次任务 `80c0eef4…` 在 Runtime 停止 **25 秒**后重启，仍 **step 3 failed** `service HTTP 503`；平台恢复 `core_ready=true`、2 Worker，但任务没有恢复。证据：`local/evidence/ds07-runtime-outage-2026-10-17T13-07-06-275Z/`。
- 第四次修复：Worker `e45c9fb` 将 ToolHub `/invoke` 5xx 重试扩到 24 次（约 60 秒），安装为 `worker-79f0e9d1…`；复验任务 `bc43eb95…` 在同样的 **25 秒** stop/start 下 **completed step 6**，owner 未切换，5 个回执完整。
- 成功证据：`local/evidence/ds07-runtime-outage-2026-10-17T13-13-54-136Z/`。
- 结论：约 60 秒的同 operation ToolHub 退避可覆盖 25 秒停机 + Runtime 启动窗口；这修复的是有限窗口，不是网络分区/无限长停机/任务级恢复。超过约 60 秒的停机仍会失败，需要任务级重试或用户重试。

## PostgreSQL 死锁注入

- 用两个外部事务按相反顺序锁定已完成任务 `d5fbaf41…` 的 `runs` 行与文档 `abf31b71…` 的 `documents` 行：一个先 `runs` 后 `documents`，另一个相反。
- 结果：一个事务收到 **`deadlock detected`（40P01）**，另一个成功提交；`pg_stat_database.deadlocks` 从 **0→1**。
- 这是数据库层死锁检测，不涉及 Worker/任务执行；不能写成“任务级死锁恢复”或“平台自动重试”。
- 证据：`local/evidence/ds07-deadlock-2026-10-17T13-02-53-428Z/`。
- 任务级死锁未复现：另两次对 `note_save` 任务在 `documents` 表锁 + `runs` 行锁下尝试注入，任务均 **completed step 3**，psql 未收到 `deadlock detected`；没有取得任务级死锁证据。证据：`local/evidence/ds07-task-deadlock-2026-10-17T13-04-27-994Z/`、`ds07-task-deadlock-2026-10-17T13-04-48-824Z/`。

## 查询计划基线（小数据量）

- 在真实库上对三类查询执行 `EXPLAIN (ANALYZE, BUFFERS)`：
  - `events` 按 `run_id/seq`：走 `events_run` 位图索引，执行 **0.100 ms**；
  - `runs` 按 `status='completed' ORDER BY created_at DESC LIMIT 50`：**Seq Scan**，执行 **0.349 ms**（当时约 166 行）；
  - `calls` 按 `run_id/created_at`：走 `calls_run_page` 位图索引，执行 **0.049 ms**。
- 证据：`local/evidence/ds07-query-plans-926c6486fb484849a429a83c4c9f85a8/plans.txt`。
- 这不是慢查询故障：数据量很小，Seq Scan 仍为亚毫秒；未做大数据量、统计信息偏差、锁等待或 `pg_stat_statements` 长窗口分析。`runs(status, created_at)` 是否需要在规模上升后加索引，需用真实数据量验证。

## 结论与边界

- 8 个并发合成任务没有触发连接耗尽、死锁、临时文件或 Worker 分配失衡；两个 Worker 均实际接单。32 秒双 Worker 负载 2/2 完成；3 分钟 12 任务 soak 12/12 完成；9.1 分钟 36 任务 soak 36/36 完成；30.1 分钟 24 任务 soak 24/24 完成，连接 13–18、deadlocks 0，RSS 峰值受控且结束回落。8 秒 `runs` 行锁使任务等待后恢复并 completed；30 秒行锁使任务在 step 6 显式失败；15 秒锁内取消、杀 owner 后取消、修复后的 30 秒锁内取消均落到 cancelled；终止 3 个 Worker DB 会话后任务仍 completed；PG 快速重启期间任务 completed；Runtime stop/start 在 Worker 19 秒同 operation 退避下也 completed（此前较短退避均失败）。
- 该负载没有真实模型延迟、工具网络、外部 Storage/Knowledge 或长历史，不能替代 10 万/百万级任务或服务器容量。
- 30 分钟下限已达到；修复后 15/30 秒锁内取消均成功，但 60 秒上限仍不是异步取消，超过 60 秒的锁仍可能超时；已完成数据库层死锁检测注入，但未做任务级死锁恢复、网络分区、慢查询计划、取消后的外部副作用清理/异步补偿和内存增长趋势，不能把 30 分钟合成 soak 写成生产容量验收。
- 双 Worker 杀 owner 接管已在 DS-05 真实执行（合成模型，20 秒 lease 后接管），不等同于本负载的持续故障矩阵。
- 无付费模型调用、无 CI、无任务删除；合成任务产生了受控笔记与运行记录，保留供复核。
