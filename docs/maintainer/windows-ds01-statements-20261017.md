# DS-01 非数值论据绑定原文：源码、复核与安装记录

日期：2026-10-17。执行环境：原 Windows，工作根 `D:\workspace\agent-platform`，主仓 `repos\agent-os`。本记录只描述 Futures BFF/Web 的 DS-01 增量；不代表 DS-02、DS-03 或 P5 已完成。

## 交付内容

- `futures-evidence-v1` 增加可选 `statements`：每项含 `id`、`text`（≤800 字符）、`document_id`、逐字 `quote`（≤2400 字符）、`content_kind`（`publisher_text` / `ai_summary` / `unverified`）和 `limitations`（≤8 项，每项 ≤500 字符）。
- `questions[].statement_ids` 与 `findings[].statement_ids` 引用本问题已列说明；仅由说明支持的 finding 允许 `fact_ids` 为空。
- 新检查器 `futures-report-check-v8`。结构检查仍为 `structure_only`；`ready` 只表示没有结构修订项，不证明解释、样本定义、正文覆盖或事实真实。
- 非数值说明和市场报数分开：说明文字、说明限制和引用说明的 finding 不能夹带市场数量（统计日期、页码、期数、样本家数等非报数计数可以保留）；数值报数仍进入 `facts` 并接受原有数值、单位、统计期、性质和比较检查。带说明的 finding 即使借用事实 ID 也不能夹带市场数量。
- 说明引文复用本任务冻结回执和既有 `quoteReader`：同一文档、同一 `original_hash`、相邻区间、48 次请求 / 256 KiB 共用预算；不从当前知识库或别的任务补证据。`join` 规则与事实引用相同。
- Web 显示说明卡、来源性质、限制、逐字引文和“回查任务当时保存的资料”按钮；保留“引文匹配不等于解释已验证”。旧报告无新字段仍可读，旧送检回执不被覆盖。
- 新任务成稿说明与 `packs/futures/research-reading.md`、`research-finalization.md` 增加 `statements` / `statement_ids` 用法。

## 源码与安装

| 项目 | 值 |
| --- | --- |
| 仓库 | `agent-os-futures` |
| 分支 | `feat/native-task-transport` |
| 主提交 | `72d8e3631fb2d872b38c5c977d7f5049d56e60b8`（前一提交 `4b32fd37c54d3f7bfe840547794feccb6a03936d`） |
| 集成 pin | `deploy/service-sources.json` → `72d8e36…` |
| 构建集 | `local/releases/staged/23872d3fbb644b72be65e806a278d5f1.json` |
| 安装 manifest | `descriptors/futures-4d6499a45f204bd281feca5caa650bf7.json` |
| 安装结果 | `outcome=committed`、`readiness=verified`、`non_target_unchanged=true`；前版 `futures-f62fd89042604ec889a5fba607d571f1` 保留为 previous |
| 安装证据 | `local/evidence/release-fdb63e628b214d7e9ab557e732bf992c-update.json` |

构建与安装使用受管入口 `scripts/Platform.ps1 build/update -Service futures`，未直接覆盖运行中的 exe，未修改正式数据库。

## 离线验证

- `go test -mod=vendor ./futures ./cmd/...`：通过。
- `go vet -mod=vendor ./futures ./cmd/...`：通过，exit 0。
- Web：`node --import tsx --test` 全部 26 项通过；TypeScript `--noEmit` 与 Vite `--mode futures` 构建通过。Vite 只出现既有 `lucide-react` `"use client"` 非阻断警告。
- 新增 Go 测试覆盖：纯说明支持 finding、数值/全宽数字/倍数/说明限制的数量拦截、引用存在性与重复、问题归属、非法说明编号、来源性质与限制、回执身份与分段、旧报告兼容、说明数量上限、比较只允许数值事实、`reportInstructions` 字段、严格 JSON。
- 新增 Web 测试覆盖：说明卡渲染、说明引文回查、AI 摘要警示、非法说明编号问题仍显示在卡片、旧报告无说明区。

## 独立静态复核

两次独立只读复核（不是实机验收）：第一次读完 9 个文件及相邻实现，结论无 blocker/high；第二次聚焦 6 个文件，结论 MEDIUM。复核指出的问题已处理：

1. 数字规则过宽，误伤 `2026/10/09`、`2026.10.09`、`2026-10`、`10月9号`、`2026年Q4`、`第3期周报`、`正文只覆盖前3页`：日期规则和计数后缀已扩展，这些说明不再触发 `statement_quantity`。
2. 说明 `limitations` 可绕过数量检查：现在同样检查，页码/期数等非报数计数仍允许。
3. 带事实 ID 的说明型 finding 可夹带数量：现在只要 finding 引用说明就检查市场数量，不再以 `fact_ids` 为空为前提。
4. 说明编号非法时问题路径为 `statements[0]`，Web 只按 `statements.<id>` 过滤：卡片现同时匹配索引路径。
5. README 仍写 v7、缺少 20 项说明上限：已更新。
6. 说明状态按数组下标绑定：Web 先按 `id` 查找，找不到才回落索引。

复核同时确认：说明不能进入 `facts` 或比较算术；说明编号/重复/事实编号冲突、问题归属均有校验；草稿仍是空 `quoteReader` 的 `structure_only`；旧报告和旧草稿可读；AI/未确认/限制只进入 `source_review`；引文匹配只证明存在性。

## 安装后只读检查

- `Platform.ps1 status`：`core_ready=true`，futures `health=true`、`ready=true`，futures current 为 `futures-4d6499a45f204bd281feca5caa650bf7`，non-target 服务版本未变。
- `GET /api/tasks/2bc11ddab7473a1e2ee29fd499330558/report-check`：返回 `validator=futures-report-check-v8`、`status=unstructured`、`format` 待核；旧失败任务结果为空，未改写。
- 已安装 `POST /mcp/research` 合成草稿：纯说明 draft 返回 `ready=true`、`scope=structure_only`、`status=source_review_required`、`validator=futures-report-check-v8`、`revise=0`、`source_review=3`；把说明文字改为“本周库存为100”后返回 `ready=false`、`revision_required`、`revise=[statement_quantity @ statements.s1]`。
- 未进行真实供应商调用、未创建新研究任务、未跑浏览器点击/窄屏验收。

## 仍开放

- 说明 `quote` 是逐字原文，可能本身含数字；页面把它放在原文面板，不把它当事实主表。来源限制与解释成立性仍需人工/独立复核。
- 中文数词（如“两家油厂”“库存约一百”）不走阿拉伯数字守卫；带计量单位的中文数量由既有 `proseQuantity` 拦截。说明文本仍可能包含非报数计量词，结构检查不作语义验证。
- 说明较多时可能耗尽共用回执预算，结果为待核而非静默通过。
- DS-02 未就绪草稿提前结束未修复；DS-03 真实研究验收未执行；P5/W06 仍未通过。
