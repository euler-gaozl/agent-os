# DeepSeek 接续交接 · 2026-10-17

本文件是当前开工入口。用户要求把进度、待办、维护知识库和本体同步 GitHub，交接完成后暂停原 Codex Goal，由 DeepSeek 接续。**产品整体未交付，不能把修复报告校验器当作完成全部平台。** 原目标保留在 [objective.md](objective.md)，逐项验收为 [P0–P5/P2.5、W01–W14](../windows-single-machine-plan.md)。

**2026-10-17 后续增量：DS-01 已实现并受管安装；DS-02 的 guarded-v7 单次续接与 v6+v7 双产物也已安装，默认 v7，v6 任务保留重放/读取但不能直接续跑；DS-03 库存/合同真实四问已产出报告并通过独立内容复核 ACCEPT；DS-04 中台/业务浏览器矩阵已通过主要页面/窄屏/交互检查并修复本地业务入口，Console 运行详情新增“查看源任务”并浏览器验证；Futures 业务记录新增同品种历史任务入口（人工核对，非精确证据链）；DS-05 正式 ACL 已收缩，撤权后合成任务/双 Worker 接管通过，临时 Telemetry 实例把 3,992 条事件导出到本机 mock Langfuse（非真实/managed）；DS-06 已完成笔记修订/过期/并发写者/撤回、Windows 128–8192 步 Compact/重放（8192 步 168.1 MB heap/339.5 MB RSS）、32k/64k/最大限制下 20 轮强杀/接管及 40/80 轮完成；40/80 轮请求体线性增长、无可见 Compact，8k/16k 仍失败；DS-07 已做 30.1 分钟 24 任务 soak（24/24），并完成 8 秒行锁恢复、30 秒行锁失败、15/30 秒锁内取消、杀 owner 后取消、终止 3 个 Worker DB 会话后完成、PG 快速重启后完成、Runtime stop/start 4 秒/25 秒在 60 秒退避下完成；DB 层死锁注入 0→1（不涉及任务执行），任务级死锁两次未复现，小数据量查询计划基线（runs 状态 Seq Scan 0.35ms）；30 秒 cancel 504 已由 Runtime `55dc3cd` 修复并安装复验；DS-08 最终快照 `ds08-final-20261017b` 已在隔离 PostgreSQL 集群真实恢复通过；随后在 Worker `79f0e9d1`/Futures `fdc9a7`/Console `94f118` 后重建 `ds08-final-20261017d` 并复验通过（46 关系、10 角色、5 凭据、2 Worker bundle、完整发布 187 代/3,073 文件）。** 详见 [DS-01 记录](windows-ds01-statements-20261017.md)、[DS-02 记录](windows-ds02-finalization-investigation-20261017.md)、[DS-03 记录](windows-ds03-inventory-20261017.md)、[DS-04 记录](windows-ds04-ui-browser-20261017.md)、[DS-05 记录](windows-ds05-access-retirement-20261017.md)、[DS-06 记录](windows-ds06-storage-lifecycle-20261017.md)、[DS-07 记录](windows-ds07-platform-load-20261017.md) 与 [DS-08 记录](windows-ds08-restore-20261017.md)。下一步完成真实 Langfuse/managed Telemetry、旧实现删除、DS-06 Compact 点续跑/RSS 上界、DS-07 慢查询/故障组合；DS-09 本机全套扫描已通过（当前 Worker 1ac65212 复跑：Go 五仓、40/27 Web、16+31 Harness），最后再执行唯一一次 hosted CI；不能把单项通过当作整个目标完成。

## 先拿到正确的源码与环境

1. 克隆主仓 `https://github.com/euler-gaozl/agent-os.git`，读本文件、`current-state.md`、`repositories.json`、`ontology.json`，再读实际要改的仓库 AGENTS.md/README。主仓管集成与业务方法包，各服务实现归独立仓库；不要继续修改主仓历史同名业务代码。
2. 15 仓完整 URL、开发分支、2026-10-17 远端核对提交、集成 pin、原 Windows 实际安装在 [repositories.json](repositories.json)。所有仓库 `main` 和开发分支已核对一致，Actions 禁用。主仓 baseline 是交接前提交，最新交接文件从 main 获取，避免自引用提交号。
3. 首个业务修复需要 `agent-os`、`agent-os-futures`；调查提前结束再读 `agent-os-harness`、`agent-os-runtime`、`agent-os-worker`、`agent-os-registry`。独立源码测试使用固定 vendor/锁文件，不用 `replace ../其他仓库` 绕过协议。整平台构建需按清单取得全部 15 仓。
4. **DeepSeek 执行机器尚未指定。** 先检查 OS、架构、当前目录、Git 状态和工具链，再决定路径。若确在原 Windows，用 `D:\workspace\agent-platform\repos`、`local`、`ops`；禁止另在 C/H/J 盘建项目。若在另一台 Mac/Linux，使用自己的 `~/workspace/agent-platform` 和独立配置/测试库，不能使用原机 localhost、DPAPI、数据库、凭证或备份，也不能把 Mac 的旧安装当作当前机器状态。
5. `go.mod`/锁文件是工具版本依据；当前 Windows 为 Go 1.27.2、Node 24.19.0、pnpm 11.25.0。本机已有工具路径在下文，不代表别的机器存在。配置秘密从运行环境读取，不能让用户把 API Key 贴进公开 issue、提示词或代码。拥有 GitHub 源码不意味着拥有原机数据。

## 当前最重要的事实

- 默认引擎 `dsh-source-639ed015-guarded-v6`；DSH 官方固定源码基线 `639ed015397290b3745d163aafe02ffee4aa3f84`。v1–v5 及旧 Go 历史任务兼容仍保留，不能重命名覆盖既有执行语义。
- Runtime `1e17aae`、Worker `029cc2b`、Console `a5f8c59`、Registry `2f7f836`、Futures `fc080b6` 已安装。Worker 的固定 execution Owner 是 `6774494`，与 Runtime 服务提交不同是正常的，不能强行改为 HEAD。完整 SHA 见清单。
- 现场清单还显示 **Telemetry 的源码 HEAD `6f9f539`、集成 pin `c2a02e2`、安装 `fcaca2e` 三者不同**；Indexer/Sandbox/Sources/ToolHub 的源码 HEAD 也领先于 pin/安装。DS-05 必须先按 Git diff 和发布记录区分文档、候选实现和正式版本，不能直接全量 build/update 覆盖现网，也不能把清单中的 HEAD 冒充已安装。Harness 没有独立服务 installed 条目，实际冻结产物归 Worker 包，并不表示未安装。
- 两个 Worker；最新只读状态 core_ready=true。服务目录有 12 个 Owner，但 Indexer 等启用情况以实际 catalog/processes 为准，不能用仓库数推断进程数。Sandbox 隔离执行仍未配置，扩展可用性单列。
- 官方 DeepSeek 的模型能力为上下文 1,048,576 / 最大输出 393,216 tokens；没有额外人为 token 预算。12 次模型尝试/步骤是任务策略，HTTP/工具容量是传输边界，都不是模型输入输出限制。用户不希望为节省 DeepSeek 成本压缩模型能力。
- 真实任务 `2bc11ddab7473a1e2ee29fd499330558` 使用 Agent `published-supply-inventory/20`、Skill `china-futures-research/9`、MCP `futures-research/2`。它失败于第 8/12 次模型请求，22 次文档阅读、两份送检草稿留存、没有正式报告；输入 348467、输出 26291，输入中缓存 301312 已包含，未知用量 0。不能写成预算耗尽。
- Futures v7 已把最后草稿结构问题定位为 `questions.q1.findings[2].fact_ids[0]`：该事实存在于报告，但没有归入问题。历史反馈仍是 v6，原稿哈希不变。这个定位修复已测试、安装、同步，**不要重复实现**。
- 独立内容复核还有证据错配及日期覆盖自相矛盾，不能只补一个 ID 就声称研究通过。最新进展见 [guarded 发布与失败记录](windows-guarded-release-20261017.md)。

## DS-01 非数值论据与来源绑定（第一优先级，尚未实现）

**问题**：当前 `facts` 必须含数值/单位/统计期，但来源是否为 AI 摘要、样本定义是否变化、正文覆盖范围等论据并不是数值事实。模型为了给 finding 绑定 ID，引用了不能支持论点的库存/合同报数。引用存在只能证明结构，不能证明语义支持。

**Owner/入口**：Futures `futures/report.go`（类型、parseReport、checkReport、reportInstructions）、`report_evidence.go`、`research_mcp.go`、`drafts.go`、`web/src/report.tsx`，测试 `futures/report*_test.go`、`web/test/report.test.tsx`、`web/test/evidence.test.tsx`；集成方法包 `packs/futures/research-reading.md`、`research-finalization.md`。先确认实际文件，类型及工具能力以源码为准。

**建议实现步骤（字段设计仍需评估，不是已冻结协议）**：

1. 用合成资料复现“有正文支持的非数值说明，无法在不捏造数字、不借无关 ID 的情况下表达”。增加可选的原文论据对象与独立 ID，例如 `statements`，以及问题和 finding 的 `statement_ids`。也可选更简单的等价结构，但必须能逐条回查，不仅放一段自由文本。
2. 每项至少有说明、文档 ID、逐字引文、来源性质及限制；无需伪造数值/日期。未确定日期不能自动成为基准日之前已知事实。AI 摘要保持线索，不因为新增字段变成实绩。
3. 校验 ID、重复、问题归属、引用范围及字段边界；仅非数值论据的 finding 不应被强迫绑定数值 fact。不能借新通道绕开真实报数的数值/口径/计划实绩校验。比较依然只作用于合适的数值 facts。
4. 原文回读复用本任务的冻结回执和现有 quoteReader；不得读当前知识库替换历史，不从另一任务借证据。段间拼接仍需同文档同 original_hash、相邻无冲突。所有请求/容量合并计量，不给新字段开无界读取旁路。
5. 草稿检查依然是 structure_only；`ready` 不能代表语义、真实性、完整性通过。新报告检查器使用新版本号，旧送检回执不覆盖；旧报告无新字段仍可读。
6. Web 显示非数值论据、支持的 finding、来源限制与原文按钮，并保留“引文匹配不等于解释已验证”。修改新任务成稿说明和通用方法，不往提示词注入当前考题答案或硬编码某个 fact ID。
7. 先离线测试，再独立静态复核，提交独立仓及集成 pin；通过受管发布安装整个 BFF/Web 包。当前交接没有进行上述修改，只完成了代码阅读。

**验收**：纯非数值说明可独立引用；不存在/重复/跨问题 ID 拒绝；缺失或错误原文不会匹配；AI/未知来源警示保留；相邻回执证明可回读；旧报告兼容；数值事实不能靠新字段规避检查；草稿大小/输出截断不改变 ready；页面可点击原文。结构测试通过后仍需 DS-03 内容复核。

## DS-02 未就绪草稿提前结束（第二优先级，尚未修复）

**已确认序列**：第 5、6 次模型请求分别送检两稿；末稿 `ready=false`。第 7 次尝试 final_output_commit 并声称预算不足，实际尚未用完 12 次；第 8 次直接返回另一份正文、未成功选定成稿回执，最终失败。不要把无效正文当 final，也不要修改原任务状态。

**Owner/调查**：Harness 的 `guarded-runner.mjs`、`src/guarded-kernel.ts`、`src/guarded-tools.ts`、`src/final-kernel.ts`、`src/final-protocol.ts` 和 runner 的实际依赖；Runtime/Worker 固定 execution、成稿回执及模型意图；研究方法包。通过 `git grep` 定位 `final_output_commit` 和 `did not end with a successful final output selection` 的真正实现，不能只看入口脚本。

1. 从私有调用回执重现实际序列，区分模型误判、可纠正错误反馈、工具协议拒绝和执行器终态行为；不能预设“换模型/加步骤即可”。没有原机证据时写合成复现并明确范围。
2. 评估最小修复：让具体错误可修订、让模型获得准确的当前尝试信息、或在固定 DSH 内合理处理未选择成稿。若加入动态预算信息，必须在调用前随模型 intent 固定，恢复不得用新剩余数改写旧请求。
3. 保留明确终止条件、取消和未知效果边界，不增加第二个决策循环或无穷重试，不把 source_review 警告错误当结构阻断。
4. 若改变重放可见 loop 行为，必须新引擎 ID/不可变产物，并同步 Runtime/Worker 准入、Console 识别、构建/回滚兼容和恢复测试；若仅业务提示/工具字段改变，不要无依据新造引擎。
5. 成稿必须选定已提交且 ready 的最新草稿回执，字节哈希一致。新正文未经重新检查不能复用旧批准。

**验收**：合成供应商先返回未就绪稿、误提 final、修订后成功；断点/丢回包重放不重做已完成效果；错误哈希/旧稿/未就绪稿拒绝；取消/权限/数据库错误不伪装可重试；无无限循环；准确报告已用尝试；旧引擎任务语义不变。失败事实和成功证据分别保留。

## DS-03 一次真实研究验收（依赖 DS-01/02）

使用相同豆粕、分类日 2026-10-09、四个问题和同十份已留存资料：进口/到港/压榨衔接、同来源两期库存、近期周实绩和预估、10–12 月估计及长期背景。四问原始输入和正文只在原机私有证据目录；不能在别的机器凭摘要伪造原题复现。可先用公开合成资料完成工程验证，明确不是 P5 真实通过。

发布新的固定 Agent/Skill/工具版本，不修改 v20/v9/v2 或旧任务快照。若 MCP schema/description 变化，按注册、发现、检测、启用、绑定流程产生新 revision；只改内部诊断不应自动改历史资源。记录运行前判据、资料范围、版本和费用策略。独立检查者不把评审答案塞进输入。

真实验收必须同时满足：四问实质回答；引文逐字和对应论点支持关系；日期/样本/实绩计划正确；来源冲突/摘要/正文受限诚实表达；成立的同口径比较可复算；不足资料确有补数过程；最终稿等于最后就绪草稿；业务页面回读原文和失败/继续路径可用；真实 usage 有记录。一次失败先分析根因，不能原样重复烧模型或 Codex 额度。没有完整证据不关闭 P5/W06。

## DS-04 至 DS-09：平台余项不能遗漏

| 编号 / 本体任务 | 文件与步骤 | 完成证据 |
| --- | --- | --- |
| DS-04 `task:continuation-ui` | Console/Futures 各自 `web`；按 W03/04/05/13 逐页操作 Agent 新建/绑定/发布/试运行，ToolHub Skill 好坏包、MCP 验活/漂移/停用，资料上传/重传/检索/回读，记忆、任务、服务页面。先查正式 Console `FUTURES_PUBLIC_URL` 是否配置。接续动作已经实现，不要依据旧文重新造一套 | 真实桌面/窄屏、空/加载/失败/成功；刷新/双标签/切换任务不串结果；引用可回读。组件静态渲染不能代替浏览器，历史部分页面通过不能关闭全部 W13 |
| DS-05 `task:service-retirement` | `docs/p2-linux-cutover.md`、`independent-deployment.md`、`runtime-access-retirement-20261013.md`；逐行核对独立 Owner 是否已接住旧主仓测试、DDL、权限、构建和部署。Mac ENOSPC/遥测覆盖有新证据，先定位再补缺口 | 独立构建/配置/发布/回退的版本和非目标实例不变；旧业务实现/宽权限仅在覆盖移交、兼容回退和验收完成后退役。不得直接删目录造成少跑测试的绿灯 |
| DS-06 `task:storage-lifecycle` | `docs/architecture/dsh-source-and-storage-decision.md`、`resident-lifecycle-20261013.md`、`resident-joint-acceptance-20261013.md`；Runtime/Worker/Harness/Storage 分清模型上下文、权威状态、证据、笔记、缓存。补失败/取消退出、缓存重建/清理及必要的当前引擎复验 | W08/09/14：长输出引用、Compact 遗漏仍可回查、笔记修订/撤回/过期/冲突可审计、递增长历史内存和恢复耗时。正式资料/回执/备份/旧产物不可当缓存删；没有测量依据不做核心快照大改 |
| DS-07 `task:faults-and-resources` | 对 W07–12/14 列证据覆盖表，只补新改动或仍缺场景。使用隔离库和合成供应商做 Worker 接管、取消、丢回复、未知效果、数据库中断、磁盘故障和独立回退；最后测整套服务+PG连续负载 | 每项记录输入、SHA、故障点、进程/租约/fence、回执与真实结果；不用 Owner 单元测试冒充独立进程，不用局部 RSS 冒充全平台上界。2核4GB、机器HA和最终容量仍未证明 |
| DS-08 `task:latest-recovery` | 有新的最终运行/安装组合后，在原 Windows 用统一 backup/restore-check。最近 guarded 安装前完整备份已经实际恢复通过，别重复把它写成未测试；但它早于最新失败任务与 Futures v7，不是最终快照 | 独立库恢复，资料/哈希/任务/引用/角色/凭证可解密核对，隔离库不启动旧 Worker/真实外部效果；源库不变。跨机 DPAPI 不承诺可恢复 |
| DS-09 `task:final-ci` | 本机整体验收通过后按原计划做唯一一次集中 CI，核对 15 仓自动触发器、固定 SHA 和 runner 分钟；收集最终发布清单、运维入口、页面证据和独立逐要求评审 | 原完整 P0–P5/P2.5、W01–14 逐项有证据；明确未配置扩展、下一阶段和风险；才可完成 Goal。日常提交继续不跑 CI，不能为了交接打开 Actions |

新 Windows 一键初始化 `task:fresh-windows-bootstrap` 仅在用户要求新机器部署时实施，不阻塞当前原机交付；服务器/跨机 HA、数据库主备、百万文档千万块、全品种覆盖属于后续阶段。Sandbox/Milvus/LightRAG/Langfuse 的代码服务交付与真实配置可用性须分别报告，不能将“未配置”写成“全部完成”。

## 原 Windows 执行入口与私有证据

仅在识别为原 Windows 且有本机访问授权时使用：`repos/agent-os/scripts/Platform.ps1 status|doctor|start|stop|build|update|rollback|backup|restore-check`；先看脚本参数。升级单服务用受管 release set，不直接覆盖运行 exe，不使用旧 `Start -Migrate`，不重新初始化正式 PostgreSQL。

- Go `D:\workspace\.tools\go\bin\go.exe`；隔离检查 `GOENV=off GOWORK=off GOPROXY=off GOTOOLCHAIN=local`，GOPATH/GOCACHE 用 `D:\workspace\.tools\gopath` / `gocache`。
- Node `local/releases/node/baseline/node.exe`，pnpm 由本机已安装工具提供；不要把这个 Windows 可执行路径作为 macOS 命令。
- Futures 基本验证：`go test -mod=vendor ./futures ./cmd/...`、`go vet -mod=vendor ./futures ./cmd/...`；Web `pnpm --dir web test`、`pnpm --dir web run check`、构建。其他服务遵守本仓 README 的真实依赖和测试变量，跳过项列明。
- 本机 `ops/windows-guarded-research.path` → `calls-terminal.json`、`draft-66.json`、`draft-72.json`、`independent-outcome.md`、`terminal.json`。`ops/finding-diagnostics.path` → v7 真实只读回查、原稿哈希及独立复核。`ops/guarded-install.path` → 安装/备份/隔离恢复。只读取任务所需内容，绝不上传整目录。
- `local/releases/current.json` 及描述文件是安装权威；`deploy/service-sources.json` 是下一次构建 pin，两者不是同一个概念。`ops/Publish-ExactCommit.mjs` 是原机 Git 传输故障时的本地回退，要求单个干净提交、父提交匹配远端、Actions 关闭并核对所有对象 SHA；不是跨机必需工具。普通 `git push` 可用时直接使用，不 force push。

## 交付与维护纪律

每项完成后更新当前状态、backlog 对应项、仓库清单和本体的状态/证据关系；保留失败记录和环境归属。提交前检查 diff 和秘密；推送独立 Owner 分支/main 后更新集成 pin。代码提交、安装、模拟验证、真实业务验证分开记录。一次完成一个可验收增量，避免把相同全量测试反复跑。不要给出没有验收分母的完成百分比。

本次交接只更新维护资料、清单和本体，没有实现 DS-01，没有重跑模型、CI 或改正式数据库。原 Codex 在交接完成后暂停；DeepSeek 继续的是完整原目标，不是只修两处报告问题。
