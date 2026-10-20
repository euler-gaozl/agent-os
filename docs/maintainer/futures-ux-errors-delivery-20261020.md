# 期货任务页面与错误记录 · DSH 交付记录

日期：2026-10-21（Asia/Shanghai）。状态：**候选分支已实现、本机候选已浏览器验收并在本机受控安装；代码分支与交付文档已推送，尚未合并 main，没有触发 GitHub Actions。**

本轮按 [实施计划](futures-ux-errors-plan-20261020.md) 完成 A–E。产品源码只改 `agent-os-futures` 与 `agent-os-runtime`；原期货业务包、Worker、执行协议、Harness、预算和模型设置都未改。错误记录保持手动复盘，没有定时任务、自动修复、自动重试或自动重跑。

## 1. 提交与分支

| 仓库 | 分支 | 提交 | 内容 |
| --- | --- | --- | --- |
| agent-os-futures | `work/futures-ux-errors-20261020` | `26988f1` | A：兄弟 key 修复、真实父组件动态回归 |
| agent-os-runtime | `work/futures-ux-errors-20261020` | `780fb23` | C：有界、安全、按应用隔离的诊断与失败分页 |
| agent-os-futures | 同上 | `fb1c2e6` | C：BFF 诊断/失败记录投影与旧 `task.error` 固定映射 |
| agent-os-futures | 同上 | `9ca2d3b` | B：成功/失败页面层级、单一操作区、草稿空态、锚点命名空间 |
| agent-os-futures | 同上 | `ff80a5b` | D：错误记录页、筛选/分页/导出/手动复盘入口 |
| agent-os-futures | 同上 | `5de3195` | B/D 收口：失败页单一操作区、暂停/取消文案 |
| agent-os | `docs/futures-ux-errors-20261020` | 本文提交 | 计划状态、问题清单、集成 pin、交付记录 |

主仓 `deploy/service-sources.json` 已把 `runtime` 固定到 `780fb23a697feb3049dcbd88fbe80e6cd4c54f9c`、`futures` 固定到 `5de319587300e2ee5d5b084761886c459cdb0040`。该 pin 更新随本文档分支推送，只代表本机验收组合，不代表已在其他机器安装。

## 2. A–E 交付与验收

浏览器验收使用本机独立数据域：两个真实只读任务（甲醇 `6e4971d0…` completed、豆粕 `dd80cadf…` failed）加明确标注“（样例）”的 SQL 夹具，夹具在验收后已删除（`fixture_runs=0, fixture_calls=0`）。未调用模型，未重跑付费研究。

### A. 重复渲染

- 原因：`TaskEvidenceBinding` 用 `result.id`、`TaskRetainedWork` 用 `result.id + manifest` 作兄弟 key；没有证据关联时两者相同。父级六秒刷新持续重渲染，节点累积。
- 修复：`taskSectionKeys()` 按职责生成带前缀且互不相同的 key；证据 key 含 manifest，留存工作 key 含终态，任务切换或关联变化时重置必要状态。报告子树使用独立命名空间 key。
- A1：改前在已安装基线实测：初始 1 个证据区，十次 6.2 秒刷新后 11 个（`a1-before.json`，截图 `before/`）。改后真实父组件动态回归十次刷新保持 1/1/1，Console 无重复 key 警告；同一 jsdom 回归在旧 key 上失败（`refresh-0 must not append a section`），证明测试有效。
- A2：豆粕 → 甲醇 → 首页 → 快速双击切换，共十次循环，每次只有一个当前任务；迟到响应不会覆盖下一次选择；无旧按钮、报告、来源或错误残留。
- A3：失败无报告、完成有报告、0 草稿（甲醇真实任务）、2 份草稿（样例）、旧 Markdown（样例）都有明确页面状态。0 草稿只显示一行“本次没有保存的检查草稿”，不显示空的“阶段草稿”大面板。

### B. 成功/失败页面

- 顶部只保留品种、研究范围、分类基准日、提交时间（`created_at` 是提交时间，没有伪造生成时间）、执行状态和独立的证据检查状态。
- 主区直接是记录；报数、引用、检查项按需展开；导出保留。
- 单一主操作区：报告任务为“补充问题，生成新报告 / 导出记录 / 查看生成过程”；失败页为“查看错误详情 / 查看生成过程 / 修改问题并新建研究”。暂停（`waiting_unknown`）不提供“新建研究”，避免在外部效果未核实时引导重复执行。
- 人工补证据关联只在有报告的任务、默认关闭的“关联已有研究资料（高级：按编号查找）”里；失败无报告不显示；候选必须同品种且有留存阅读记录，保存前提示会固定来源、原报告不变。
- 0 份原文时资料回查明确写“0 份已加载的阅读资料”/“没有可展示的文档阅读记录”，不把笔记或空检索结果说成来源已核实。
- 最终记录与每份历史草稿的 fact/statement 锚点都带实例命名空间；浏览器验证最终锚点全部以 `#report-final-` 开头且目标存在；单元测试验证 final 与 draft 同名 fact 生成不同 id。
- B2：甲醇页显示“记录已生成”、证据检查“13 项待核”、执行状态备注“执行已结束；研究核验见证据检查”；没有“研究已核验”或“多轮修订”的表述。草稿夹具让 draft-match 显示“最终回答在最后送检后被改动”，这是对不匹配夹具的真实提示，不是声称产品自动修订过。
- B5：1440×900、1024×768、390×844 实际截图；三种宽度都没有横向溢出；Tab 焦点为可见 `solid/2px` 轮廓；Enter 激活跳转链接、Space 激活聚焦按钮；Escape 关闭移动导航对话框；暂停与失败不只靠颜色区分，有文字状态。

### C. 失败诊断

- Runtime 新增 `GET /v1/apps/{app}/runs/{id}/diagnostics` 与 `GET /v1/apps/{app}/run-failures`；Futures 新增 `GET /api/tasks/{id}/diagnostics`、`GET /api/task-failures`。均为 GET、`no-store`、零写入。
- 只关联“终止检查点之前、且之后没有成功完成”的最后一个工具/模型异常；已恢复的错误不计为原因；无法建立对应时返回 `unknown` 且 `cause_confirmed=false`。`failure_version` 绑定终止检查点、异常事件、操作和错误摘要。
- 白名单分类：参数校验、配置/鉴权、下游暂不可用、效果未知、协议异常、预算限制、执行持久化/租约、取消、原因未知。分类来自固定回执状态码前缀或精确的固定文案，不从任意异常正文提取并回显。
- 真实豆粕失败解析为：stage `tool`、code `parameter_rejected`、`cause_confirmed=true`、operation `…/dsh/14`、tool `kb_search`、参数 `query=豆`、events 24/25、attempts 2、tokens 23667/218、预算 200000。页面显示“资料检索未完成 / 检索词“豆”未通过资料库的查询校验”，不以原始 HTTP 400 作唯一解释。
- C2：单测覆盖已恢复工具错误、最终失败、503/预算/取消/效果未知/无确认原因；浏览器另看真实参数拒绝及样例的取消、待核对、预算耗尽、旧 Markdown 页面。
- C3：跨应用、非应用身份、伪造/转义路径、旧 Runtime 404、5xx、普通 Go error 都有拒绝或固定安全响应；C3 注入测试把 `PRIVATE`、URL、模型内容和原始错误塞进真实字段，业务响应不含它们。BFF 还独立限制 code/stage/action/usage、操作 ID 必须属于该任务、参数必须短且不含 URL/凭证样式。
- C4：两种混合组合都做了端到端检查。新 BFF + 旧 Runtime：诊断 200 `{available:false, reason:"diagnostics_not_supported"}`，失败页保留任务状态并提示“当前执行服务尚未提供错误详情”，错误记录页显示固定“暂时无法读取”；旧 BFF + 新 Runtime：两个任务正常读取，详情 `error` 仍是字符串且只有通用 `upstream request rejected`，旧 BFF 没有诊断路由（404）。其他读取失败 → 固定 503/502；旧 `task.error` 由新 BFF 映射到固定集合（`model HTTP 503`、`credential unavailable`、预算/截断文案、`upstream request rejected`、`execution failed`），不再原样透传。回滚演练实际验证了旧组合下诊断 404、任务页仍可用。

### D. 错误记录与手动复盘

- 错误列表只包含 failed / cancelled / waiting_unknown 的已受理应用任务；时间窗口、品种、状态、步骤、分类在返回页之前执行；游标绑定 app/窗口/筛选；`has_more` 与 `coverage{scanned,scan_limit,truncated,complete}` 明确说明扫描范围，不冒充全库总数。
- D1：数据库测试创建 120 个更新的成功任务和 5 个跨时间失败，仍能分页查到旧失败；每页 2 条走完 3 页无重复无漏页；分类/步骤/品种/状态筛选、窗口上限、游标跨筛选复用均被覆盖。真实服务重启和回滚后，旧失败仍能查到。
- D2：`readonly-audit.json` 在整轮浏览前后比较 runs/app_runs/calls/model_attempts/events 行数与内容摘要，全部不变；浏览器只发出 GET；实际生成 3 个导出文件（错误记录 Markdown、研究记录 JSON、错误复盘 JSON）。导出不写产品状态，人工“已复盘/已解决”只存在于本地文件。
- 查看、筛选、展开、导出都不创建任务、不调用模型；接口 GET-only，数据库中无人工处置表。

### E. 集成、候选与回滚

- E1：`agent-os-runtime` 全包 `go test -mod=vendor ./...`（`TEST_DATABASE_URL` 指向本机独立测试夹具）exit 0；`go vet` 通过。`agent-os-futures` 全包 Go 测试与 vet 通过；Web 35 个测试通过、`tsc --noEmit` 通过、`vite build` 通过。Go/Web 构建产物来自固定提交。
- E2：本机受控安装与回滚均实际执行，见第 5 节和 `install-rollback.json`。安装前保存前一完整组合（runtime/futures 二进制、上一版 Web、`installed.json`、配置）到 `local/evidence/futures-ux-20261020/rollback/`，记录 SHA-256；安装后 12/12 进程 ready、诊断 200、两个历史任务不变；回滚后 12/12 ready、诊断 404、旧 Web 资源、任务不变；再装回候选后 12/12 ready、诊断 200。未做数据库迁移，未改 Worker。

## 3. 接口与数据边界

最小诊断字段（`app-run-diagnostics-v1`）：`protocol`、`run_id`、`status`、`failure_version`、`stage`、`code`、`safe_message`、`cause_confirmed`、`related_event_ids`、`operation_id`、`related_role`、`tool`、`safe_parameter`、`recommended_action`、`retry_policy`、`usage`。`safe_message` 是固定非插值文案；业务中文解释归 Futures。

失败分页（`app-run-failures-v1`）：`since`、`until`（默认 90 天，最大 366 天）、`status`、`category`、`stage`、`commodity`、`limit`（1–50）、`after`；返回 `items`、`next_cursor`、`has_more`、`coverage`。筛选在分页前执行；单次最多扫描 200 条候选，达到上限明确 `truncated`。

权限：Runtime 策略要求 futures 身份只能读 `/v1/apps/futures/…`，control 可读任意 app；处理器再核对 `app_runs(app, run_id)` 所有权。子任务、关联来源任务和用量都不跨应用。原始模型请求/响应、供应商 URL、headers、凭证名、异常正文都不进入投影。旧应用详情仍返回结构化记录的必要字段，但 `error` 已经固定映射。

## 4. 测试与证据

命令与结果（本机 macOS 15.3 / arm64，Go 1.27.2，Node 24.19.0）：

```text
agent-os-runtime:  TEST_DATABASE_URL=… go test -mod=vendor -count=1 ./...   exit 0
agent-os-runtime:  go vet -mod=vendor ./...                                exit 0
agent-os-futures:  go test -mod=vendor -count=1 ./...                      exit 0
agent-os-futures:  go vet -mod=vendor ./...                                exit 0
agent-os-futures/web: pnpm test                                            35 pass / 0 fail
agent-os-futures/web: pnpm run check                                       exit 0
agent-os-futures/web: pnpm run build                                       exit 0
```

Runtime 全包测试包含本机 PostgreSQL 隔离夹具；`TEST_DATABASE_URL` 未配置时会 skip 的用例不在“通过”口径内。需要额外 Worker/DSH 二进制与 runner 的可选接力测试在本轮没有配置，不能算已通过。定向诊断/失败分页测试 6 个、零 skip、全部通过。

浏览器证据在本机 `local/evidence/futures-ux-20261020/`（不提交到 GitHub，避免私有任务与截图进入公开仓库）：

- `a1-before.json`、`before/`：改前复现（1 → 11）。
- `after/acceptance.json`：改后验收通过；十次刷新样本、十次切换、锚点、筛选、三视口、键盘；0 重复 key、0 错误、0 非 GET。
- `after/failed-desktop.png`、`failed-details-desktop.png`、`failed-generation-desktop.png`、`failed-after10-refreshes.png`、`failed-390.png`
- `after/completed-desktop.png`、`completed-drafts-desktop.png`、`completed-1024.png`、`completed-390.png`
- `after/records-desktop.png`、`records-filtered-desktop.png`、`records-1024.png`、`records-390.png`
- `after/states/states-old-markdown.png`、`states-cancelled.png`、`states-effect-unknown.png`、`states-budget.png`、`states.json`
- `after/readonly/readonly-audit.json`、`after/readonly/downloads/`（3 个脱敏导出）
- `after/mixed/mixed-check.json`、`mixed-old-runtime-failed.png`、`mixed-old-runtime-records.png`（新 BFF + 旧 Runtime 降级）
- `after/installed/installed-check.json` 与三张安装后截图
- `runtime-go-test.log`、`futures-go-test.log`、`futures-web-test.log`、`futures-web-check.log`、`futures-web-build.log`
- `seed-fixtures.mjs`、`cleanup-fixtures.mjs`、`acceptance.mjs`、`states.mjs`、`readonly-audit.mjs`、`installed-check.mjs`：夹具可复现且已清理。

验收夹具使用“（样例）”品种名和 `fixture*` 标识；验收后 `fixture_runs=0, fixture_calls=0`，真实任务仍为甲醇 completed、豆粕 failed，错误记录只剩真实参数拒绝。测试没有上传真实结果全文、密钥、数据库或用户截图。

## 5. 本机候选、安装与回滚

本机 `mac-platform.mjs` 没有通用升级/回滚器；`start` 会校验 `local/run/installed.json` 中的二进制摘要。本轮按“先备份、再受控安装、再回滚演练、最后装回验收候选”执行：

| 项目 | 前一组合 | 安装候选 |
| --- | --- | --- |
| Runtime | `cfdd6643…` | `6123c0c3…`（commit `780fb23`） |
| Futures | `2f12f521…` | `366f2734…`（commit `5de3195`，Web-only 收口后二进制未变） |
| Web index | `68bc25b2…`（`index-D7uEr_xz.js`） | `fafe2d57…`（可复现重建） |
| 备份 | `local/evidence/futures-ux-20261020/rollback/` | — |

观察：

- 安装后 12/12 进程 ready，诊断 200，两个历史任务状态和内容不变。
- 回滚后 12/12 ready，旧 BFF 的诊断路由 404，旧 Web 资源生效，任务页仍可用；再安装候选后 12/12 ready、诊断 200。
- 切换时没有在途任务（两个任务都是终态）；没有数据库迁移；Worker 与执行模块未重建。
- `mac-platform.mjs stop` 在停止时报告 `Process PID changed while waiting for exit`，每次只停一个服务，需要重复执行到 `stopped:0`。这是本次改动之前就存在的启停脚本行为，本轮没有修改它，也没有把它当成产品验收通过。
- 安装清单的 `binary_sha256`/`commit` 是作为受控安装的一部分显式更新的；配置摘要保持不变。没有用改摘要的方式绕过校验。
- Runtime 的提交最初落在本地 `main`；发现后把 `780fb23` 建到 `work/futures-ux-errors-20261020` 分支，并把本地 `main` 恢复为 `76237d3`。`main` 没有推送，远端 main 未变。

## 6. FUX-004 仍单独跟踪

可修正的参数拒绝是否应作为持久化工具拒绝结果返回执行器，仍是独立的执行协议变更。本轮只把它诊断清楚、在页面上如实说明，**没有**吞掉 HTTP 400、放宽 Knowledge 校验、无界重试、改 Worker 编译依赖、改 Harness 回放或改原包预算/提示词。旧任务保持 failed，不自动重跑。后续若实施，需要单独评估 typed rejection、授权/fence/未知效果区分、有界修正、模块版本与两个 Worker、旧引擎回放和恢复语义。

## 7. 未完成与后续

- 代码分支与主仓交付文档已推送到 origin，但尚未合并 main；合并需要用户确认。日常 GitHub Actions 保持关闭，本轮没有触发 CI。
- Console 管理诊断摘要未做（计划列为另计范围）。
- 持久化人工“已复盘/已解决/备注”未做；首版只在导出文件里保留空模板。
- 失败列表的候选分类由 Runtime 在分页前投影并受 200 条扫描预算限制；若未来错误量显著增大，需要由 Runtime 评估索引或物化投影，不能由前端过滤最近 100 条。
- 真实模型付费端到端没有为截图重跑；本轮验收使用两个既有真实任务和脱敏夹具，研究内容质量仍未被本轮证明。
- 旧 Runtime + 新 BFF 的降级只验证了“诊断 404 时页面保留任务状态”；完整混合版本矩阵仍需在发布组合中复核。
