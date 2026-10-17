# DS-03 真实四问研究：库存、区域分布与未执行合同

日期：2026-10-17。状态：**已通过独立内容复核（ACCEPT）**。最终报告基于任务 `a526d178ba61f74114d11e0384762741` 的真实四问研究，经 `634a5052…`（7 项复核更正）和 `3c059635…`（仅 s5）两次更正，最终 `report-final.json` 18,925 字节；检查器 `futures-report-check-v8` 结构可交付（`needs_review`，无 `finding_quantity`/`finding_reference` 结构项）。旧任务 `2bc11dd…` 仍是失败记录，未回填为已修复；本次是**有区别的库存/合同四问**，不是旧供给/进口/压榨问题的重跑。

## 与失败任务的区别

此前 `2bc11ddab7473a1e2ee29fd499330558` 研究的是豆粕**供给、进口、压榨、到港预估**；本任务改为**豆粕库存、区域分布与未执行合同**，使用 2026-09-18 至 2026-09-29 的库存/合同原文，不重复旧问题。资源版本：

- Agent `published-supply-inventory` revision 21（首次运行）/ revision 22（修正提示后）
- Skill `china-futures-research` revision 10（含 statements/statement_ids 读取策略）
- Connector `futures-research` revision 4（Futures v8 重新发现后激活；旧 revision 2 已 drifted）
- 旧 Agent 20/Skill 9 未改：已读回校验。

## 第一次运行（任务 6067619cd03233fc61752c4f668e3927）

只读证据：`local/evidence/windows-ds03-inventory-2b3a2813269d4fd290da38c892d13bba/`（原 Windows，不进 Git）。

- 结果：`failed`，step 13，错误 `DSH model request budget exhausted`，`result` 为空。
- 用量：12/12 次模型请求，prompt 659,720，completion 38,646，1 次早期 unknown usage（随后归零）。
- 实际动作：12 次模型请求；9 个文档读取（5+4）；3 次 `check_research_draft_v2`（均 `ready=false`）；1 次 `final_output_commit`（seq 86）；1 次普通正文（18,047 字符）。
- `final_output_commit` 返回：
  `{"continue":"Final delivery rejected: latest candidate is not ready for delivery. Recheck the latest candidate under current constraints.","selected":false}`。
- 模型没有立即结束回合，而是在 seq 92 又检查了一次，seq 98 以普通正文结束；guarded-v7 的“拒绝后一次续接”需要第 13 次模型请求，预算已耗尽，因此失败。

### 根因

1. 方法提示要求“按拒绝原因在本轮继续修订”，与 guarded-v7 runner 的“回合结束后注入 continue”语义冲突。模型在同一回合继续调用检查工具并最终输出正文，烧掉了最后一次尝试。
2. 任务给了 7 个核心文档 + 3 个背景文档，模型读了 9 个；12 次预算不足以覆盖“多轮读取 + 两次检查 + 提交 + 纠正续接”。
3. 这不是 DS-02 runner 的单次续接错误，而是**纠正续接没有预算可用**：runner 逻辑正确，但模型在拒绝后没有让出回合。

### 已修复

- `packs/futures/research-finalization.md` 与 Futures `reportInstructions` 改为：`final_output_commit` 返回 `selected=false` 时**立即结束当前回合，不再调用工具或输出正文**；执行器会把 `continue` 作为下一条消息送回。
- Futures 提交 `5be0b1a`（`feat/native-task-transport`），主仓提交 `47f53d1`（`feat/end-to-end-delivery`），已推送。
- 新 Agent 22 使用修正后的 finalization pack，绑定 Skill 10/Connector 4；旧 Agent 21 保留为失败证据，不覆盖。

## 第二次运行（任务 294a7c48a5de5f53d3ce3f0b2506f04b）

输入：Agent 22，固定 12 次模型请求；只读 5 个库存/合同文档（`cf89…`、`4ac91…`、`2b357…`、`26e551…`、`bcb1…`），禁止 `kb_search` 扩展，最多两轮批量读取；最多两次检查；第二次检查后立即提交；拒绝后立即让出回合。

- 结果：`failed`，step 9，错误 `DSH turn ended after a rejected final output selection without a committed selection`，`result` 为空；9/12 次模型请求，仍有 3 次预算，不是预算耗尽。
- 实际动作：9 次文档读取；3 次检查（seq 32/38/54，均 `ready=false`）；seq 42 和 seq 58 两次 `final_output_commit` 均被拒；seq 48/64 两次普通正文（15k/14.9k 字符）。
- 检查反馈：`revise` 主要是 `finding_quantity`（只引用 statements 的 findings 夹带市场数量）和 `finding_reference`（问题列表遗漏实际引用的 ID）；`source_review` 大量 `period_inferred`、`source_limitations`、`anchor`、`ai_summary`。
- 根因：任务提示写了“第二次检查后立即提交，无论 ready 与否”，迫使模型提交未就绪稿；模型没有先按 `revise` 修正 `finding_quantity`，第二次提交仍 `ready=false`。guarded-v7 只提供一次纠正续接，第二次拒绝后按设计失败。
- 结论：v7 的纠正续接确实执行了，但**未就绪稿不应提交**；提交前必须 `ready=true`。

## 第三次运行（任务 a526d178ba61f74114d11e0384762741）

输入：Agent 22；只读 3 份短原文（`cf89…` Mysteel 选段、`bcb1…` 国粮 9/18 转载、`26e551…` 国粮 9/25 转载）；四问聚焦“Mysteel 9/18 库存/合同”“国粮同一监测口径 9/18→9/25”“两个样本能否混算”“合同能否解释库存/提货”；明确要求数值进 facts、statements 不夹带数量、按 `revise` 修正、只有 `ready=true` 才提交。

- 结果：`completed`，step 6，6/12 次模型请求，`result` 17,708 字节；报告已提取为 `report.json`。
- 检查器：`futures-report-check-v8`，`status=needs_review`（结构可交付，但要求来源/解释复核）；无 `revise` 结构项；`source_review` 标出日期推断、来源限制、引用锚点与 `finding_review`。
- 报告结构：11 facts、5 statements、0 comparisons；四问均有 findings/missing；核心数字：Mysteel 6月末 74.29、9/18 117.32、华东 43.7（37.3%，6月末 37.2）、合同 609.4→459.91；国粮 9/18 大豆 869、豆粕 113，9/25 873、124（周环比 +4/+11）。
- 已避免的旧错误：没有把 Mysteel 117.32 与国粮 113 相减；没有把合同减少直接说成提货；没有把两份转载说成独立调查；没有把 AI 摘要当事实。

## 独立内容复核（子代理 92297136）

复核只读 `report.json` 与 `sources.md`，结论 **REVISE**，不是 ACCEPT：

| 级别 | 位置 | 问题 | 要求更正 |
| --- | --- | --- | --- |
| blocker | f1/f5 | 原文只写“6月末”，报告登记 2026-06-30 且标 `period_basis=explicit`，把月末代理当成精确统计日 | 改 `inferred`，说明 2026-06-30 只是月末代理，不能用于严格日度比较 |
| blocker | q2 finding 3 | 声称“指标名称、单位、样本范围与数量类型一致”，与 q2 limitation“样本是否完全一致未见原文声明”矛盾；两篇原文均未给样本家数 | 删除样本一致性断言，只保留指标/单位/数量类型相同、样本范围原文未展开、无法核验 |
| blocker | q4 finding 2 | “现有资料中 Mysteel 库存序列止于 2026-09-18”是库级断言；库内另有 9/28、10/02 的 Mysteel 资料，本次任务未纳入 | 限定为“本任务采信的三份资料范围内”，不得断言库内不存在更晚数据 |
| blocker | s3 | 引文只有“2026年09月22日 15:12 黑龙江省大豆协会”，不能支持“消息来自国家粮食和物资储备数据中心” | 引文改为正文来源句“国家粮食和物资储备数据中心9月22日消息:监测显示，9月18日……豆粕库存113万吨……” |
| blocker | q2 finding 3 / limitation / q4 finding 1 | “同一发布机构”过度断言：前一期署数据中心，后一期署局，原文未声明发布主体同一 | 改为“同一监测口径路线下的两期数据（前一期署数据中心、后一期署局），原文未声明发布主体同一” |
| minor | s5 | “行情与评论栏目不在采信范围”在来源包中无依据 | 删除该句，只保留发布日不等于统计时点 |
| minor | s3 | “页面采集时间晚于…”缺少该文采集时间依据 | 删除该表述 |

数值、百分比与 58.0%/24.5%/17.5% 的复算未发现问题；四问结构、facts/statements 引用关系基本成立。复核结论是**报告内容需要更正后才能验收**。

## 第四次运行：基于复核的更正任务（634a5052c3f302d320e81b7a497c8d9b）

输入为原报告 JSON + `sources.md` 来源包 + 上述复核意见；只做指定的 7 项更正，不重新检索、不新增事实。结果：`completed`，3 次模型请求，18,829 字节；`needs_review`，无结构 `revise`。f1/f5 已改 `inferred`，q2 样本一致性断言已删除，q4 已限定为本任务三份资料，s3 引文已含数据中心来源句，s5 被误改为范围声明（新回归）。

## 第五次运行：仅修 s5（3c059635c274cdcf766554c868452012）

只恢复 s5 的“发布日晚于统计时点”文本和发布行引文，其他内容逐字不变。结果：`completed`，2 次模型请求，18,925 字节，`report-final.json`；`needs_review`，无结构 `revise`；s5 文本/引文与来源包一致。

## 最终独立复核（子代理 92297136）

对 `report-final.json` 的复核结论 **ACCEPT**：

- f1/f5 已标 `inferred`，明确 2026-06-30 是月末代理，不是原文精确日。
- q2 已删除“样本范围一致”，改为样本范围未展开、无法核验，两期仅按“同一监测口径路线（前一期署数据中心、后一期署局）”方向并列；finding 与 limitation 一致。
- q4 已限定“本任务采信的三份资料范围内”，并明确未检索/未采信其他 Mysteel 发布、不据此断言其不存在。
- s3 引文已含“国家粮食和物资储备数据中心9月22日消息:监测显示，9月18日……豆粕库存113万吨……”，来源归属有正文支持。
- s5 已恢复发布日/统计时点区分（2026-09-29 09:46 发布，统计时点 9/25；发布日不能替代统计日）。
- 其余 facts、百分比与 58.0%/24.5%/17.5% 复算未发现问题；`comparisons` 为空，未把不同来源/样本直接相减。
- 唯一未修正的 minor：s1 的 quote 拼接了两段不相邻原文（资料类型 + 统计范围）；两段均逐字、语义有支持，不影响事实/来源判断。保留为已记录 minor，不伪称完美。

## 证据

`local/evidence/windows-ds03-inventory-2b3a2813269d4fd290da38c892d13bba/`（原 Windows，不进 Git）：

- `research-input-focused2.json`、`run-created-focused2.json`、`terminal-focused2.json`：第三次真实四问任务。
- `research-input-corrected.json`、`terminal-corrected.json`、`report-corrected.json`：7 项更正。
- `research-input-corrected2.json`、`terminal-corrected2.json`、`report-final.json`：s5 更正后的最终报告。
- `sources.md`：三份原文的来源包；`calls-terminal-focused2.json`、`calls-terminal-corrected*.json`：调用轨迹。

## 边界

- 本任务只使用 3 份库存/合同原文，不覆盖进口/压榨/到港；旧供给问题的失败任务仍未修复成功。
- 检查器 `needs_review` 的来源项（日期推断、来源限制、引用锚点）是待人工复核提示；独立复核已逐项确认，但不能写成“自动检查证明事实真实”。
- 未触发 CI、未修改旧任务、未把私有原文/密钥写入 Git。
