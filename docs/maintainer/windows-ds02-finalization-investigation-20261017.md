# DS-02 未就绪草稿提前结束：失败序列与修复方案（调查记录）

日期：2026-10-17。状态：**v7 源码已在 Harness/Runtime/Worker/Console 实现并推送，但未安装**。运行库中仍有一个可恢复的 guarded-v6 失败任务，单产物替换会移除其恢复 runner；因此集成 pin 已回退到 v6，下一步需要双产物/双 profile 发布。Harness `c5d4e4e2d5` 的 31 项本地 guarded 检查通过；没有真实供应商调用、没有服务安装或任务变更。DS-01 已独立完成并安装，见 [DS-01 记录](windows-ds01-statements-20261017.md)。

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

## 候选修复 A（推荐，新引擎）

1. `FinalTurnSelection` 记录“有效的 `selected:false` + 有界 `continue`”拒绝，绑定其 `turn`；新增 `rejected(end)`。
2. runner 在 `completed(end)` 为空且同一轮存在有效拒绝时，**只续接一次**：把 Runtime 的 `continue` 加上固定说明（不得以自由正文结束；修订后重新送检；仍无法完成则如实失败）作为下一条 user message，继续同一 AgentLoop。
3. 同一轮第二次仍无成功选择时直接失败；不增加 harness 自己的重试计数或第二个循环。Runtime 的 12 次尝试和步骤预算仍是唯一预算权威。
4. 拒绝文本来自 Runtime 的冻结响应，不注入动态剩余次数；恢复不得用新的剩余数改写旧请求。若以后加入当前尝试信息，必须在模型调用前随 intent 冻结。
5. 因为改变了重放可见的 loop 行为，必须使用新引擎 `dsh-source-639ed015-guarded-v7`，v6 产物与旧任务语义不变。

### 验收（候选）

- 合成供应商：返回未就绪稿 → 误提 `final_output_commit` → Runtime 拒绝 → 模型返回文本 → runner 续接一次 → 模型修正并送检 → 成功选择；不得把文本稿当最终结果。
- 拒绝后模型再次只返回文本：一次续接后终止，不死循环。
- 错误哈希、旧稿、未就绪稿仍拒绝；取消、权限、数据库/RPC、未知效果仍走原有失败屏障，不被包装成可重试。
- 断点/丢回包重放不重复已完成的检查或模型效果；准确记录尝试次数；旧 v6 任务重放字节语义不变。
- 真实供应商调用不在本候选的离线验收内。

## 已实现候选（Harness）

Harness 提交 `c5d4e4e2d5`：
- `src/final-protocol.ts` 的 `FinalTurnSelection` 记录 Runtime 返回的有效 `selected:false` + 有界 `continue` 拒绝，绑定其 turn；`rejected(end)` 只在当前 turn 已结束时返回它。成功选择或新 turn 会清除拒绝。
- `guarded-runner.mjs` 在没有成功选择但存在有效拒绝时，**只续接一次**：把 Runtime 的 `continue` 和固定说明交回同一 DSH loop；第二次仍无成功选择则明确失败，不增加 harness 重试计数。
- `src/guarded-kernel.ts` 与 `scripts/build-guarded.mjs` 使用 `dsh-source-639ed015-guarded-v7`；v6 产物保留在历史提交和发布包中。
- 本地 31 项 guarded 检查通过，新增：拒绝后模型以正文结束 → 一次续接 → 重新检查并成功；以及第二次文本结束即终止、不死循环。强杀/丢回包重放测试仍通过。
- README 明确 v7 是候选；Runtime/Worker/Console 源码已接入但未安装，原因是可恢复 v6 任务。

Runtime 提交 `934b856`（已推送）：`IsFinalEngine` 识别 v7 以便历史回放/只读，`NewSourceVersions` 只准入 v7；v6 进入历史识别。Worker 提交 `bbfdbfe`（已推送）只打包 v7 产物并固定 Runtime execution `934b856`；Console 提交 `0350682`（已推送）声明 `guarded_transport=guarded-v7` 并保留 v6 归档显示。集成 pin、发布策略和 profiles 的 v7 改动已实现并测试（`Test-GuardedRelease.ps1` 37 项通过），但因下述可恢复 v6 任务阻断，已在主仓 `3ca9556` 回退到已安装 v6 pin；v7 源码仍保留为候选，未安装。

## 单产物替换被可恢复 v6 任务阻断

安装前只读查询运行库：

```text
dsh-source-639ed015-guarded-v6|failed|1
```

该失败任务 `2bc11ddab7473a1e2ee29fd499330558` 仍可由显式 continuation 动作恢复，按发布策略的 `resumable_guarded_v6_runs` 计为可恢复。单产物替换会移除 v6 runner，使该历史任务无法恢复，违反“旧任务不被静默改语义”。因此没有安装 Runtime/Worker/Console v7；平台仍为已安装 v6，`core_ready=true`，未改任务状态。

下一步必须做**双产物/双 profile**：Worker 同时打包 v6 与 v7 harness；Runtime 同时准入两种引擎（新任务默认 v7，v6 仅恢复历史）；Console 同时识别两种引擎并允许 v6 任务接续；集成发布策略分别检查 `guarded_execution` 与 `guarded_v6_execution`。只有在双产物验收通过后才可切换默认并保留 v6 恢复能力。

## 需要同步的 Owner 与入口（尚未修改）

| 层 | 入口 | 需要的工作 |
| --- | --- | --- |
| Harness | `src/final-protocol.ts`、`guarded-runner.mjs`、`src/guarded-kernel.ts`、`scripts/build-guarded.mjs`、`tests/guarded/*` | 记录拒绝、单次续接、新引擎 ID、构建/测试/README |
| Runtime | `internal/runstate/harness_archive.go`、`deploy/release-contract.json` | v7 回放识别与领取准入已完成（`934b856`）；未安装，单产物替换被 v6 可恢复任务阻断 |
| Worker | `worker/source_harness.go`、`guarded-harness-lock.json`、`scripts/Package-Worker.ps1`、`scripts/kernel-smoke.mjs`、`deploy/release-contract.json` | 需要 v7 artifact/lock 与 v6 历史策略；未修改，v7 不可领取 |
| Console | `web/src/working-state.tsx`、`web/src/continuation-client.ts`、`deploy/release-contract.json`、`console/model_capabilities.go` | 识别 v7，保留 v6；发布能力/回滚门禁 |
| 集成 | `scripts/lib/platform-source-execution.ps1`、`platform-model-management.ps1`、`scripts/Test-GuardedRelease.ps1` | 默认引擎、候选枚举、发布/回滚检查 |
| 业务方法 | `packs/futures/research-finalization.md`、`reportInstructions` | 拒绝后必须修订并重新送检，不得以正文结束或自行声称预算耗尽 |

## 为什么没有安装

- Harness、Runtime、Worker、Console 的 v7 源码和发布策略测试已完成；`Test-GuardedRelease.ps1` 37 项通过。
- 运行库有一个可恢复的 guarded-v6 失败任务。若用 v7 单产物替换，旧任务将无法恢复，违反历史语义；发布策略的 `resumable_guarded_v6_runs` 也正确拒绝该替换。
- 集成 pin/发布 profiles 的 v7 改动已在主仓 `3ca9556` 回退到已安装 v6；平台仍 `core_ready=true`，没有服务被替换、没有任务被修改。
- 下一步是双产物/双 profile：v6 与 v7 同时可运行，新任务默认 v7，v6 仅用于恢复历史。

## 本轮推送与验证

- 相关仓库的分支已与远端同步：`agent-os` `3ca9556`（含本记录后续提交）、`agent-os-futures` `d0e2efc`、`agent-os-runtime` `934b856`、`agent-os-worker` `bbfdbfe`、`agent-os-console` `0350682`、`agent-os-harness` `c5d4e4e2d5`。
- GitHub Git transport 间歇失败；提交通过 Git data API 上传，逐 blob/tree/commit/ref 校验 SHA，Actions 保持禁用。没有 force push，没有改写历史。
- 本轮没有触发 CI、没有付费模型调用、没有修改旧任务或正式数据库。

## 提示层缓解（已随 Futures `d0e2efc` 安装，但不能替代 A）

Futures `d0e2efc`（安装 `futures-7ddefba00ef2477983e240fee1dfd75e`）已在新任务 `reportInstructions` 和 `packs/futures/research-finalization.md` 中明确：`final_output_commit` 返回 `selected:false`/`continue` 时，必须按拒绝原因在本轮继续修订并重新送检；不得改以普通正文结束，也不得自行声称预算耗尽。此缓解只影响新任务提示，不改变 v6 执行器语义，不能把真实任务的提前结束标记为已修复；guarded-v7 候选仍未安装。
