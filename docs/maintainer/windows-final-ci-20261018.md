# Windows 最终集中 CI（2026-10-18）

## 范围

用户授权在全部本机验收后集中执行一次 hosted CI。本次仅对 13 个独立服务仓的 `verify.yml` 执行一次 `workflow_dispatch`；未开启 push/PR 自动触发，未运行容量工作流。执行后已把各仓 Actions 重新禁用。

## 结果

| 仓库 | 运行 | 结果 |
| --- | --- | --- |
| agent-os-runtime | 39050655421 | success |
| agent-os-worker | 39050658430 | success |
| agent-os-console | 39050661569 | success |
| agent-os-registry | 39050663932 | success |
| agent-os-futures | 39050667129 | success |
| agent-os-knowledge | 39050670297 | **failure** |
| agent-os-indexer | 39050673539 | success |
| agent-os-sandbox | 39050676796 | success |
| agent-os-sources | 39050680230 | success |
| agent-os-storage | 39050683334 | success |
| agent-os-telemetry | 39050686365 | success |
| agent-os-sdk | 39050692756 | success |
| agent-os-toolhub | 39050689343 | success |

- 12/13 通过；knowledge Linux `go test -race` 失败，Windows job 通过。
- 失败断言：`TestArchiveReaderRequirementRejectsIncompleteOrUnknownState` 在删除 marker 后仍被接受（`missing marker accepted at startup`）。
- 这是 CI 暴露的**测试/归档 floor 状态判定问题**，不是编译失败；未在本机用 race 复现（本机 gcc/TSan 链接缺少 WaitOnAddress）。
- 按约束没有自动重跑全套；knowledge 修复后应只重跑该仓一次。

## 证据

- 调度/结果：`local/evidence/final-ci-dispatch-20261018.log`
- knowledge 失败日志：`local/evidence/knowledge-ci-logs.zip`（GitHub API 返回纯文本日志，本地保留，不提交仓库）

## 边界

- 这是 hosted CI，不是服务器/跨机 HA 或 10M 块容量；没有运行 capacity workflow。
- 所有仓库 Actions 已在本次后重新禁用；没有提交触发 CI。

## 修复后定向重跑（2026-10-18）

- 根因：`archiveFloorQuery` 用区域边界 `r.root >= 'knowledge-source:' AND r.root < 'knowledge-source;'`，在 Linux locale 数据库上标点排序与 Windows/C locale 不同，导致 source manifest 被排除，`has_manifest=false`，缺 marker 被接受。
- 修复：边界改为 `COLLATE "C"`，并让 floor 审计在存在任何 source manifest 时拒绝缺 marker；测试显式保留该场景。
- Knowledge 源码 `ff58a037…`，构建安装为 `knowledge-e1d6ed1d618c4c9b87980038afc03473`。
- 定向 CI `39088673132`：**success**（Linux race 与 Windows 均通过）。Actions 随后再次禁用。
- 最终结果：13/13 仓库通过。
