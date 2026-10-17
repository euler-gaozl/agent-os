# DS-06 存储生命周期与长历史资源：Windows 增量（2026-10-17）

日期：2026-10-17。状态：**部分完成**。已完成真实 Runtime 笔记修订/过期/冲突/撤回，以及 Windows 本机 source-Harness 长历史 Compact/重放的内存与耗时测量。仍缺真实长任务强杀后的续跑、真正并发写者竞争、Runtime/Worker/DB 长期 RSS 上界和生产容量。

## 一、长历史 Compact/重放测量

入口：`repos/agent-os-harness/benchmarks/source-memory.mjs`，对已安装 Worker 的 `source-harness`（固定 manifest 哈希校验通过）运行：
- 步数：128、512、2048；
- 每步先记录，再用 fresh Node 进程按 journal 哈希链重放；
- 子进程 `--max-old-space-size=192 --expose-gc`，强制 GC 采样；
- 合成供应商，零付费调用。

结果（`local/evidence/ds06-long-history-aeb187b79033421b84e179ececf6703c/result.json`）：

| 步数 | 事件 | 事件字节 | Compact | 记录耗时 | 重放耗时 | 最大 heap | 最大 RSS |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 128 | 1,415 | 1.56 MB | 127 | 1.3 s | 0.88 s | 13.7 MB | — |
| 512 | 5,639 | 6.24 MB | 511 | 4.65 s | 2.85 s | 21.8 MB | — |
| 2048 | 22,535 | 25.0 MB | 2,047 | 18.6 s | 11.4 s | 50.5 MB | 222.5 MB |

- 六次 run 全部 `completed`，journal 哈希链在记录与 fresh-process 重放间一致；最大 heap 50.5 MB、最大 RSS 222.5 MB（2048 步）。
- 工作状态中的关键事实在 Compact 后仍被模型请求看到；摘要故意省略数量/日期，证明“摘要遗漏不造成唯一证据丢失”。
- 这是 **source-Harness 合成基准**，不是 Runtime/Worker/DB 的真实任务，也不是 192 MB 内绝对安全或生产容量结论。RSS 超过 192 MB 的 heap 参数，需在 DS-07 用真实服务测量。

## 二、真实笔记生命周期（W09）

使用已安装 Runtime `8094` 和 Console 的 control 服务身份（`/v1/notes/revise`/`retire` 仅授权 control peer），对一个受控 fixture 笔记执行：

1. 初始：`b17bc3fc…` active/current/effective。
2. 修订：新版本 `ce154d51…`，旧版本 `is_current=false`、`effective=false`，旧正文保留；新版本 `valid_until` 设在过去。
3. 过期：新版本 `expired=true`、`effective=false`，但不是自动删除。
4. 冲突：对旧 head 再次修订返回 **409**，返回 `note_rejected_request_id` 和明确错误；未任意选择分支、未改写历史。
5. 撤回：当前 head 撤回后 `state=retired`、`effective=false`、`retired_at` 与 reason 保留；正文仍可读，未删除。

证据：`local/evidence/ds06-note-lifecycle-251bec3dd12644829ffeefee2a0c61d4/result.json`；真实 PostgreSQL、零模型调用。

## 三、真正并发写者

- 对同一 active head `a58a4695…` 同时发出两个 `POST /v1/notes/revise`（不同 request_id、不同标题/正文，相同 expected_current_id）。
- 结果：一个 **200** 成功，另一个 **409** `note is no longer the active head...`（带 `note_rejected_request_id`）；旧 head 的 `current_id` 更新到唯一新版本 `7aecbc9e…`，`is_current=false`、`effective=false`，没有产生第二个分支。
- 该唯一新版本随后被撤回，`state=retired`、`effective=false`；正文保留。零模型调用。
- 证据：`local/evidence/ds06-note-concurrency-2026-10-17T10-30-42-489Z/result.json`。
- 这是两个并发 HTTP 写者的真实 PostgreSQL 竞争，不是只靠 stale expected head 的顺序冲突；仍未做多进程/多实例下的更高并发或 resolver 分支策略。

## 四、真实长任务中断/接管

- 新建受控 Agent `ds06-long-task`（revision 2）：`run_recall` 单工具、20 轮、`max_steps=45`、`max_model_attempts=80`、`model_token_budget=2,000,000`；模型为本机合成 `evidence-recall-fixture`，每轮 1 秒。
- 任务 `9d8ff9e3…` 在第 8 步时强杀首任 owner `worker-cde4b1c1…`（PID 2636）；约 18 秒 lease 到期后 `worker-f55e948e…` 以 fence 2 接管。
- 接管后继续到第 **21** 步 **completed**，20 个 `run_recall` 工具回执全部存在，最终 checkpoint `result=LONG_TASK_OK: 20 recall rounds completed.`；从接管到完成约 12 秒。
- 首轮 revision 1（预算 200,000）在同一位置接管后到第 13 步失败：`family model token budget exhausted (accounted=188857, next_reservation=22232, limit=200000)`。这是预算门禁生效，不是接管丢任务；失败证据保留。
- 证据：`local/evidence/ds06-long-task-takeover-2026-10-17T10-57-37-128Z/`；首轮失败 `local/evidence/ds06-long-task-takeover-2026-10-17T10-52-56-844Z/`。
- 这是 20 轮长任务的中断/接管，**不是 DSH Compact 的长历史强杀续跑**；也没有证明 10 万步或生产内存上界。

## 五、8k context 长任务 Compact/接管失败

- 为逼近 Compact，将同一 Agent 的 revision 3 设为 `context_tokens=8192`、`context_bytes=16000`，仍为 20 轮 `run_recall`。
- 任务 `45050b17…` 在第 10 步强杀首任 owner；第二 Worker 以 fence 2 接管，继续到第 17 个工具回执后，在第 **19** 步失败：
  `DSH failed: {"error":"DSH turn did not complete"}`。
- 没有静默成功、没有写入成功终态；失败发生在收紧上下文后的长任务接管阶段，疑似 Compact/上下文边界问题，**未定位根因**。事件中没有显式 Compact 成功标记。
- revision 4（16k）的第一次尝试因测试脚本杀掉了当时唯一剩余 Worker 而无效；任务 `8da83469…` 已取消，**不计入证据**。之后已恢复 2 Worker。随后又做了 **16k 不杀 Worker** 的对照，任务 `02baa5d8…` 仍在第 **13** 步失败（`DSH turn did not complete`）；**8k 不杀** 的 `907625b3…` 在第 **19** 步失败。两者与接管无关，说明是收紧上下文后的 Compact/上下文路径失败。
- 证据：`local/evidence/ds06-long-task-compact-2026-10-17T11-38-52-176Z/`（8k+杀）、`local/evidence/ds06-compact-no-kill-2026-10-17T11-44-40-259Z/`（8k 不杀）、`local/evidence/ds06-compact16-nokill-...`（16k 不杀）；`...compact16...` 仅作无效尝试保留。
- 这说明“20 轮长任务接管”在 64k 上下文下通过，但在 8k/16k 收紧上下文时失败（杀与不杀都失败）；不能把 W08 Compact 续跑写成通过。

## 六、移除测试上下文限制后的复验

- 按维护者要求，把**受控测试 Agent** `ds06-long-task` 的 revision 5 调到 schema 允许的最大值：`context_tokens=1,000,000`、`context_bytes=1,000,000`、`max_steps=100`、`max_model_attempts=500`、`model_token_budget=10,000,000`、`max_tokens=32768`。没有删除权限/CI/安全门禁，也没有改产品默认预算。
- 不杀 Worker：任务 `736cb0a5…` **completed**，step 21，20 个工具回执，最终 `LONG_TASK_OK`。
- 第 10 步强杀首任 owner：任务 `91eb1ab5…` 由第二 Worker 以 **fence 2** 接管，**completed**，step 21，20 个工具回执，最终 `LONG_TASK_OK`；从接管到完成约 10 秒。
- 证据：`local/evidence/ds06-maxlimits-nokill-2026-10-17T11-48-14-327Z/`、`local/evidence/ds06-maxlimits-takeover-2026-10-17T11-48-50-399Z/`。
- 结论：先前 8k/16k 失败由过紧的上下文/预算限制触发；放宽到 schema 上限后，同一 20 轮任务在杀/不杀两种情况下都通过。这个复验**绕过了 Compact**（1M 上下文不会触发），所以仍不能替代 DSH Compact 点续跑验收。

## 七、32k 上下文边界

- 再用 revision 6：`context_tokens=32768`、`context_bytes=65536`，其余为 100 steps/500 attempts/10M budget。
- 任务 `19c8f1fd…` 在第 10 步强杀首任 owner，第二 Worker 以 fence 2 接管，最终 **completed step 21**，20 个工具回执，`LONG_TASK_OK`。
- 证据：`local/evidence/ds06-32k-takeover-2026-10-17T11-51-53-245Z/`。
- 与 8k/16k 失败、32k/64k/1M 通过合起来看，失败集中在过小上下文，而不是接管；但 32k 是否真正触发 Compact 仍无显式证据，不能替代 Compact 点验收。

## 边界与仍未完成

- 并发写者已完成两客户端真实竞争；未做更多写者、跨进程/跨实例或自动分支 resolver。
- 已完成 32k/64k/最大限制下 20 轮长任务的强杀/接管；8k/16k 收紧上下文会失败，失败集中在过小上下文，但 Compact 点仍无显式成功证据。
- 长历史基准使用合成 source-Harness/受控 journal，不是 Runtime/Worker/DB 进程 RSS，也不是 10M 分块或服务器容量。
- 自动 GC/删除策略未启用；不删除权威笔记/回执。
- DS-07 仍需真实整平台资源、PG 连续负载和故障矩阵；DS-09 最后统一 CI。

## 结论

DS-06 的“真实笔记修订/过期/并发冲突/撤回”“Windows 长历史 Compact/重放测量”“32k/64k/最大限制下 20 轮长任务中断/接管”已取得可复核证据；8k/16k 收紧上下文在 step 13/19 失败（`DSH turn did not complete`），32k 起通过，但 Compact 点仍无显式成功证据，生产级内存上界也未验，不能把本记录写成 DS-06 全部完成。
