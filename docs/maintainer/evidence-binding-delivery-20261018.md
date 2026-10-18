# 修订报告证据链交付 · 2026-10-18

环境是原所有者 Windows。私有证据和访问权限不随 GitHub 克隆转移。

| 服务 | 已推送并安装的源码 | 正式发布 ID |
| --- | --- | --- |
| Runtime | `76237d34993cf26d91a7bec65765623fdf220034` | `runtime-d15b05d4f47840b9883567c44ccfd59e` |
| Futures | `f3c25eaf30282c177db505f1a6d58c3601b1104f` | `futures-bb58c4f2bf6949cdb0358a7128084d28` |

集成 pin 在 `76a4f22f0bc794b17ddac7aa0ee06d5cde11596d` 更新。干净源码独立构建、两个服务分别受管升级、readiness 通过，非目标发布未改变。Worker 的 Runtime owner module 仍固定原 `69b9e62`，没有因 HTTP 新接口而升级执行依赖。默认引擎仍是 `dsh-source-687f282e-guarded-v7`。

## 契约

Runtime 拥有新增 `app_evidence_bindings` 表、`app_runs.evidence_source_run` 字段；增加结构的迁移保留原有 46 个关系内容，新表后为 47 个关系。绑定表 Runtime 只有 SELECT/INSERT，Worker 无权访问。Futures 只经 HTTP，不读写执行库。

- 每个目标最多关联一个同应用、较早、整棵树均终态的源任务。固定原/目标报告哈希、原阅读 run ID、request/response 版本、回执清单及哈希、关联时间、模式、理由。
- 最多 256 个成功 document_read 回执；继承链展平，后续新增阅读不被静默纳入。读取时重新验证权限和版本，变化/丢失拒绝使用；SQL 同时限定 operation、run 和版本。
- 不继承草稿、模型上下文、笔记及其他任意工具结果。原任务输入、输出、状态、步数、回执不改写。
- 新修订提交与绑定原子完成，幂等重试不能换来源。旧报告补关联明确标为 retrospective，不声称当时模型曾读取。

Runtime `POST /v1/apps/{app}/runs` 可带 `evidence_source_run`、`expected_source_result_sha256`；`POST /v1/apps/{app}/runs/{id}/evidence-binding` 给既有终态补关联，要求源 ID、预期哈希和理由。读取任务返回 `result_sha256`、`evidence_binding`。

Futures `POST /api/tasks` 接收 `evidence_source_run`，通过同应用 HTTP 读取源报告并固定哈希；`POST /api/tasks/{id}/evidence-binding` 为受限代理。页面提供“基于此报告发起修订”、补关联预览、固定源任务、原阅读来源标识；绑定变化刷新报告检查与来源视图。

代码：Runtime `runtime/evidence_bindings.go`、`.sql`、`_test.go`；Futures `futures/` 任务代理与 `web/src/evidence-binding.tsx`。

## 验证

- 隔离 PostgreSQL 定向回归 **15 项通过、0 skip**：授权、原子提交、重试/并发、版本、子任务/再修订、活跃/空/超量拒绝、旧应用证据与草稿回执、Owner 迁移/权限退役。Go vet、独立构建通过。
- Futures `go test ./futures ./cmd/...` 通过；Web **29/29**，TypeScript/Vite 和正式发布构建通过。
- 原最终修订 `3c059635c274cdcf766554c868452012`：补关联前 0/11 事实、0/5 说明，之后 11/11、3/5。剩两条确有引用拼接/空格问题，未改写历史掩盖。
- 真实浏览器点击修订，新任务 `e15e8f85a1af0d0dfd9cff1b23f31aea` completed step 6，**11/11 事实、9/9 说明逐字匹配**；实际打开原文与来源定位。来源/口径仍有待核提示，不能把匹配当内容全部正确。
- 两个独立服务升级、迁移指纹、旧结果不变已验证。本轮没有 Actions；此前 13/13 hosted CI 属于上一轮，不冒充新增代码的 CI。

原电脑证据相对 `D:\workspace\agent-platform`：

- `local/evidence/evidence-binding-runtime-1189e87d3cc24e5f9e31dbc00250643e/`：15 项回归。
- `local/evidence/evidence-binding-install-20261018/`：迁移、安装、前后指纹、升级前备份及隔离恢复。
- `local/evidence/evidence-binding-live-20261018/`：旧绑定、新修订、来源回读、`source-readback.png`。
- `local/evidence/review-close-20261018/`：最终备份恢复、远端审计；公开摘要见 `review-close-evidence-20261018.json`。

最终备份名 `post-evidence-binding-20261018`；必须以恢复报告 passed 为准。私有 ops 一次性助手已执行，不盲目重放迁移/提交/绑定。
