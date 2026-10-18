# DeepSeek 接续：供给四问的内容质量

## 当前结论

三项中，GitHub main 同步和持久化证据关联已交付。第三项完成了真实执行，但**研究内容没有通过**。不要把 completed、结构 ready、逐字匹配任一项当作研究正确。见 [证据链交付](evidence-binding-delivery-20261018.md)、[当前状态](current-state.md)。

先识别实际机器，读 AGENTS.md、environment.md。原 Windows 根为 `D:\workspace\agent-platform`；自己的 Mac 用自己的 `~/workspace/agent-platform`。原电脑端口、DPAPI、数据库、任务 ID、资料及访问授权不随克隆转移，不自动远程连接。没有原资料时先做合成夹具，真实复验标待原环境执行。密钥、原始资料和私有数据库不提交。

主要仓库：[agent-os](https://github.com/euler-gaozl/agent-os)、[agent-os-futures](https://github.com/euler-gaozl/agent-os-futures)，main 已同步。按 repositories.json 仅在需要协议改动时再取 Runtime/Harness；不重写现有证据链。不复活全平台无限目标，Actions 仍关闭，不重复 13 仓 CI。

## 复现

原题四问是：进口不同版本及到港/压榨衔接；两期库存、机构样本、地区分布和合同；最近周实绩与下周预估；逐月未来到港及长期背景。as_of=`2026-10-09`，固定十份已有资料。不能用仅库存/合同的四问替代。

| 任务 | 结果 | 原电脑 local/evidence/ 下目录 |
| --- | --- | --- |
| `e3317f1441ceff16c3541d48a0105351` | 原题未改；failed step 11，四版草稿后普通正文结束，没有成功 final_output_commit | `original-supply-review-20261018/` |
| `6908846d5d9684999371ca19a2192b6f` | 同四问、同十资料，仅澄清 finding 引用及提交协议；completed step 10 | `original-supply-review-20261018-retry/` |

第二个任务 draft-match=matched，final 与检查稿 SHA-256 均为 `c765bbce9dd65dd23d17a673be56ffd472f038d995fe86ba3e85d84d2f536052`；24 事实中 22 匹配，10/10 说明匹配，report-check=needs_review。输入、终态、检查、稿件匹配均已保存；首轮还有四版草稿及末轮模型输出。

原机器只读入口：业务 `GET /api/tasks/{id}`、`/report-check`、`/draft-match`、`/sources`、`/drafts?limit=20`，端口 8098。原文从实际来源视图或有版本分页接口读取；粘贴文本不能替代阅读回执。私有 `ops/Run-OriginalSupplyReview.mjs`、`Retry-OriginalSupplyReview.mjs` 已执行，不直接重跑制造重复付费任务，先看 created.json。

## DS-R1：提示与结构诊断，P0

Owner 为 Futures：`futures/report.go` 的 `reportInstructions`、`report_evidence.go` 及相关测试。先对照原题和通用提示，不改 Runtime 去补业务事实。

1. **跨月借事实**：f9 只有十月，却被 q4 用来承载十一、十二月。各月需独立 fact，期间、性质、值分别固定；quote 有多个数字不表示该 fact 代表全部数字。
2. **跨指标借事实**：f18 只有全国库存，q2 第六条引用它支持华东占比及六月末变化。地区数量、占比、历史基数等直接使用的量须各自落到正确 fact/期间/原文，不借全国库存引用证明地区占比。
3. **AI 摘要冲突**：原题要求正文支持事实，f14–f17 却来自 AI 摘要。核对通用提示的优先级矛盾；摘要作为待核线索，不能伪装发布者确认值，也不能删该核心问题逃避。
4. **统计日期错位**：q2 第三条说同一时点9月25日，引用 f15.period 实为9月28日。发布日不能替代统计日，未证实就留待核；核对 explicit/inferred 和 period_note 一致性。
5. s10 将压榨误写成“压缩机”；正文有缺口却全部 missing=[]，需一致表达。不把未取得写成客观不存在。

验收：最小合成反例覆盖跨月、跨指标和发布日期借用；合法同来源同期间案例仍能通过。诊断要指出具体引用，不以简单数字匹配声称证明语义。复杂支持范围仍由复核承担。

## DS-R2：原文与说明支持范围，P0

- f10/f11 在文档 `bcb1b3d77696aeb994c81c8d06f29e66` 未匹配。回查本任务实际片段及版本，区分空格、拼接、读错、未读取。修订新报告，不改原文来迎合引用，不关校验。
- s1/s2 只引用日期/发布者行，却声称海关转引和无详文；s5 只引用来源行，却断言机构样本/方法不同。发布者不同只支持独立性待核，不能自动证明调查方法不同。补足支持整句的原文，或缩小陈述。
- 不因两条引用失败就删两期比较；读原文、保留时点和报数，同口径关系未核实仍待核，不编造官方修订原因。
- 新库存修订 `e15e8f85a1af0d0dfd9cff1b23f31aea` 虽全部匹配，q4“只有一个时点”的范围仍需对照六月末基数；它是证据链验收，不是推论一律正确。

验收：所有 fact/statement 引用可定位，另外检查原文是否支持整句、量是否属于正确期间/样本。缺原始来源允许明确待核，禁止伪造完美报告。

## DS-R3：完整真实闭环，P0，在 R1/R2 后执行

1. 先跑 Futures 相关 Go/Web 测试、类型检查、构建；只有涉及关联协议才扩展 Runtime DB 测试，不因文案全量重跑。
2. 正式环境用受管 build/update，保存发布差异；不直接替换服务文件。冻结引擎和旧输入/结果不能原地修改。
3. 从本轮报告“基于此报告发起修订”，保留四问、资料及截止日，给具体缺陷反馈，不塞完整预制答案；需要新 Agent 配置则发布新 revision 并记录。
4. 真实 reading receipts、结构检查、成功 final_output_commit、draft-match=matched、浏览器回读和逐问题内容复核全部具备才关闭。再失败就保存定位并定向修复，不循环碰运气。
5. 更新 current-state、repositories、ontology 及本页；提交并同步 main/开发分支，Actions 关闭。未安装、未执行、失败必须分别记录。

## 不重做和延后范围

Runtime `76237d3`、Futures `f3c25ea` 已在原 Windows 安装，DB 15 项/Web 29 项和真实修订已验收。证据仅继承固定的原文阅读，不含旧草稿/模型消息；不建重复记忆系统或重写 DSH。

本次不需要服务器。多机 HA、千万块、24小时长稳仍属原计划的延后阶段；任务级死锁/异步取消/外部副作用补偿等旧增强见 backlog 历史。真实 Langfuse 在单机收口记录中为用户放弃项，不自动配置购买。

原 Windows doctor 仍报 sandbox_execution_unavailable：隔离代码执行尚未配置。不要因 API 存活或此次研究通过就宣称沙箱隔离运行已验收；这项旧限制没有在本轮被实现。

## DS-R1/R2 代码修复（Futures 939e9b6）

- 新增检查：AI 摘要不得标为 reported 实绩；说明中的转引/调查方法/暂无详文断言必须有支持句。
- 收紧提示：一个 fact 一个独立观测；累计区间可一个 fact；同一连续原文可支持已拆分的多个事实；缺正文保留 missing，不得补句；发布日/标题日不当统计日；讨论大豆压榨不得写成压缩机。
- 测试：Go 全包通过、vet 通过；Web 29/29、构建 exit 0。独立审查提出的 quote-wide 多月、地区关键词、压缩机硬拦截已移除，避免误伤已拆分比较和合法设备文本。
- 已安装 `futures-8dfe9e178eee4c3ea441b8523907fe91`（源码 `939e9b6`）。

## DS-R3 真实修订结果（未通过内容验收）

- 任务 `1949dad2…`：基于 690 的修订，completed；report-check 仍有 **2 条 retained_quote**（f14/f15，均指向 `bcb1b3d…` 的 9月18日 869/113）。
- 任务 `f223a76f…`：基于 1949 再次修订，completed step 8，draft-match=matched；report-check 仍是同样 2 条 retained_quote，内容未通过。
- 任务 `71c55643…`：在问题中明确要求 bcb1 页面未读到 869/113 正文时放入 missing；completed，但 f14/f15 仍保留相同 quote，retained_quote=2，另有 6 条 retained_statement_quote；仍未通过。
- 证据：`local/evidence/original-supply-review-20261018-r3-2026-10-18T03-27-41-199Z/`、`...r3b-...`、`...r3c-...`。
- 根因：`bcb1...` 的本任务读取页只含导航/标题/出处，未读到库存正文；模型仍把“监测显示…”拼接成引用。最终 `check_research_draft_v2` 没有任务 read receipt，只做结构检查，无法在 final 前阻止该引用。
- 下一修复方向：让最终检查或 Runtime final policy 能按 run_id 读取本任务 receipt，或在任务完成前拒绝未匹配 quote；当前不能宣称供给四问内容通过。
