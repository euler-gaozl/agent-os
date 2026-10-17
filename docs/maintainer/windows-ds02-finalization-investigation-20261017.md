# DS-02 未就绪草稿提前结束：失败序列、修复与双引擎安装

日期：2026-10-17。状态：**已实现并安装 v6+v7 双产物，默认 guarded-v7；v6 失败任务仍可恢复**。Harness `c5d4e4e2d5`、Runtime `fb5a5c1`、Worker `76485b6`、Console `c6081ab` 已推送并受管安装；`Test-GuardedRelease.ps1` 42 项通过；平台 `core_ready=true`、两个 Worker。DS-02 安装过程没有真实供应商调用；DS-03 已在 v7 上执行有区别的库存/合同四问真实任务并通过独立内容复核（ACCEPT），见 [DS-03 记录](windows-ds03-inventory-20261017.md)。DS-01 已独立完成并安装，见 [DS-01 记录](windows-ds01-statements-20261017.md)。

## 已确认失败序列

私有证据：`local/evidence/windows-guarded-research-4a2b3304f7e84e5bb139fed492d1edb0/`（原 Windows，不进 Git）。任务 `2bc11ddab7473a1e2ee29fd499330558`，引擎 `dsh-source-639ed015-guarded-v6`，8/12 次模型请求，未知用量 0。

1. 第 5、6 次请求分别送检两份草稿（`.../dsh/66`、`.../dsh/72`），末稿 `ready=false`，仍有结构待修订项。
2. 第 7 次请求调用 `final_output_commit`，参数为 `operation_id=.../dsh/72` 和该草稿的输入 SHA-256。Runtime `final_output_select` 返回：
   `{"continue":"Final delivery rejected: latest candidate is not ready for delivery. Recheck the latest candidate under current constraints.","selected":false}`。
3. 第 8 次请求模型没有调用检查器或再次提交，而是把一份完整 JSON 报告作为**普通文本**返回；该轮没有 `final_output_commit` 工具调用。
4. `FinalTurnSelection.completed` 只接受成功的 `selected:true` 回执；本轮返回 `null`。`guarded-runner.mjs` 随即发送 `failed`：
   `DSH turn did not end with a successful final output selection`，进程以失败结束。
5. 运行用量为 8/12，不是预算耗尽；模型在正文中声称“剩余请求不足”是错误判断，不能写成实际达到上限。

## 根因

- Runtime 已经给出可操作的拒绝原因和 `continue` 文本，但 DSH 只在同一轮内把工具结果交回模型；模型选择以文本结束该轮后，runner 没有把 `continue` 作为下一次输入，也没有给模型一次按拒绝原因修订的机会。
- runner 把“本轮没有 `selected:true`”直接等同于终态失败，未区分“模型放弃了成稿”和“模型提交了未就绪稿、Runtime 已明确拒绝、仍可修订”。
- 没有新增决策循环的必要：Runtime 仍拥有尝试次数、步骤、取消和未知效果边界；修复只是在固定 DSH loop 内把一次**确定的、可修订的**拒绝返回给模型。

## 修复：guarded-v7 单次续接

1. `FinalTurnSelection` 记录“有效的 `selected:false` + 有界 `continue`”拒绝，绑定其 `turn`；新增 `rejected(end)`。
2. runner 在 `completed(end)` 为空且同一轮存在有效拒绝时，**只续接一次**：把 Runtime 的 `continue` 加上固定说明（不得以自由正文结束；修订后重新送检；仍无法完成则如实失败）作为下一条 user message，继续同一 AgentLoop。
3. 第二次仍无成功选择时直接失败；不增加 harness 自己的重试计数或第二个循环。Runtime 的 12 次尝试和步骤预算仍是唯一预算权威。
4. 拒绝文本来自 Runtime 的冻结响应，不注入动态剩余次数；恢复不得用新的剩余数改写旧请求。
5. 因为改变了重放可见的 loop 行为，使用新引擎 `dsh-source-639ed015-guarded-v7`；v6 产物与旧任务语义不变。

Harness 提交 `c5d4e4e2d5` 实现上述行为；31 项本地 guarded 检查通过，新增“拒绝后模型以正文结束 → 一次续接 → 重新检查并成功”和“第二次文本结束即终止、不死循环”，原有强杀/丢回包重放、坏参数和远端错误用例保持通过。

## 双引擎发布

安装前运行库有一个可恢复的 guarded-v6 失败任务（`guarded_v6_runs=1`、`resumable_guarded_v6_runs=1`）。单产物替换会移除 v6 runner，使该历史任务无法恢复，因此没有采用替换方案；集成 pin/策略曾实现后回退（主仓 `3ca9556`），最终改为 v6+v7 双产物：

- Runtime `fb5a5c1`：`NewSourceVersions` 同时准入 v6/v7；v7 为新默认，v6 仅恢复历史。
- Worker `76485b6`：同时打包 v7 与 v6 harness（另含 source/resident/budget/native/final）；`DSH_GUARDED_RUNNER` 与 `DSH_GUARDED_V6_RUNNER` 分别启用。
- Console `c6081ab`：`guarded_transport=guarded-v7`，同时允许 v6/v7 接续；v6 归档仍显示。
- 集成：新增 `guarded_v6_execution`/`guarded_v6_harness` profile，发布策略分别检查两引擎；`Test-GuardedRelease.ps1` 42 项通过。

## 安装结果

| 服务 | 版本 | 提交 | 关键内容 |
| --- | --- | --- | --- |
| Runtime | `runtime-4aa22b35076b48d2b9645fe78a4c20f4` | `fb5a5c1` | 同时准入 v6/v7 |
| Worker | `worker-47166229da304bb694f17813b3e7ac69` | `76485b6` | 同时打包 v6/v7 harness |
| Console | `control-70c8d97eef2645f0a093e3d965b1c8f3` | `c6081ab` | `guarded_transport=guarded-v7`，v6/v7 接续 |
| 默认引擎 | `dsh-source-639ed015-guarded-v7` | — | `set-engine guarded`，non-target unchanged |

安装后只读验证：

- `Platform.ps1 status`：`core_ready=true`，两个 Worker；Runtime/Worker/Console 均为上表版本。
- 运行库事实：`guarded_v6_runs=1`、`resumable_guarded_v6_runs=1`、`guarded_v7_runs=0`；v6 历史任务未被修改。
- Worker launch 同时含两个 guarded runner 环境变量；Console Web 包同时包含 v6/v7 引擎字符串。
- 未启动 v6 恢复任务，避免无授权的真实模型调用。

## 验证边界与仍未完成

- 合成 Harness 测试和发布策略不代表真实供应商成功；DS-03 已用有区别的真实四问研究及独立内容复核验证 v7，结论 ACCEPT（见 DS-03 记录），但该研究只覆盖库存/合同三份原文，不等同于旧供给/进口/压榨问题已修复。
- “让模型获得准确当前尝试信息”只通过提示层“不得自行声称预算耗尽”缓解；未新增 Runtime 动态剩余次数注入。
- v7 真实任务已由 DS-03 验证；v6 恢复动作、取消/数据库故障与双 Worker 接管仍需在 DS-07/P4 范围验收。
- 没有触发 CI、没有付费模型调用、没有修改旧任务或正式数据库。

## 推送与提示层缓解

- 相关仓库分支已与远端同步：`agent-os`、`agent-os-futures` `d0e2efc`、`agent-os-runtime` `fb5a5c1`、`agent-os-worker` `76485b6`、`agent-os-console` `c6081ab`、`agent-os-harness` `c5d4e4e2d5`。
- GitHub Git transport 间歇失败；提交通过 Git data API 上传，逐 blob/tree/commit/ref 校验 SHA，Actions 保持禁用；没有 force push。
- Futures `d0e2efc`（安装 `futures-7ddefba00ef2477983e240fee1dfd75e`）已在新任务说明中要求：`final_output_commit` 返回 `selected:false`/`continue` 时必须继续修订并重新送检，不得以普通正文结束或自行声称预算耗尽。此提示不改变执行器语义，不能替代 guarded-v7 的循环修复。
