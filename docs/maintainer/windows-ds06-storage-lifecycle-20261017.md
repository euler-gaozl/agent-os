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

## 边界与仍未完成

- 未做两个真正并发写者的同时提交；409 是 stale expected head 的顺序冲突，不是并发 race。
- 未做真实长任务在 Compact 中被强杀后由另一 Worker 续跑；DS-05 的接管是短任务，不是 W08 长历史。
- 长历史基准使用合成 source-Harness/受控 journal，不是 Runtime/Worker/DB 进程 RSS，也不是 10M 分块或服务器容量。
- 自动 GC/删除策略未启用；不删除权威笔记/回执。
- DS-07 仍需真实整平台资源、PG 连续负载和故障矩阵；DS-09 最后统一 CI。

## 结论

DS-06 的“真实笔记修订/过期/冲突/撤回”和“Windows 长历史 Compact/重放测量”已取得可复核证据；W08 的长任务中断续跑、真正并发写者与生产级内存上界仍需补测，不能把本记录写成 DS-06 全部完成。
