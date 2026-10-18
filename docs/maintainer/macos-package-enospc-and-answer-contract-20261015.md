# Mac 完整业务包、Storage ENOSPC 与第三次研究增量

2026-10-15，`environment:maintainer-macos`，macOS 15.3（24D2059）/ arm64。此记录承接 [Mac 研究成稿、页面与真实 Storage 增量](macos-research-and-storage-20261015.md)，保留此前 Mac 观测和 [原 Windows 历史快照](current-state.md)。本次没有连接原 Windows、读取其凭证或恢复其历史任务。完整 P0–P5/P2.5、W01–W14 验收框架继续保留；本条不改变既有已闭项的历史归属，也不关闭仍开放的阶段或任务。

本条记录的集成代码与映射以包含本文件的主仓提交为准，不写入自引用提交 ID；源码版本及本机安装产物另按下文明确记录。

## 逐问答复规则与检查边界

Futures 新提交为 `b805fa9e09ad8c1ecf3feb4ae7c74e77a41029ed`。它调整新任务的 `reportInstructions`，区分直接答复、差额核验和原因解释；`missing` 只列本问题确实缺少、且阻断答复的具体依据。没有事实支持的问题允许 `findings=[]`，不得为满足格式借用或编造事实引用。

来源报数的方向观察要求指标、单位、样本、数量类型和资料性质一致，原文明示两期同口径，统计期明确、互不重叠且前后顺序成立。估计或计划的报数不能被说成实际变化。方向观察不解除来源限制、AI 摘要、未确认来源、推断或未知统计期的现有比较限制，也不把来源报数或未计算差额升级成已验证事实。禁止预测、交易判断、无证据因果断言和全库缺失断言的边界保持不变。

主仓 Skill 将旧句“库存变化需要……勾稽”限定为“解释库存变化原因需要……勾稽”，避免把原因核验扩大成所有事实答复的前提。此处只改变方法文字；实际注册必须产生新 Skill 修订，并由新 Agent 固定引用。旧任务冻结内容、历史反馈、`futures-evidence-v1`、MCP 结构、v5 检查器和比较阈值均未改。

独立静态评审在候选应用前发现“每问必须写 finding”与无事实问题的合法契约冲突，补上空 findings 例外；同时收紧方向观察边界。最终候选不是夹具答案注入，没有加入测试数值、日期、文档或任务 ID。两次草稿检查仍是方法指令，不是执行器的硬性次数限制或稳定成稿保证。

固定 Go 1.27.2 下 39 项顶层、111 项含子项测试通过，0 失败、0 测试跳过；`cmd/healthcheck` 无测试的包级 skip 单列，不计为测试已执行。vet 与 build 通过。证据：`local/evidence/macos-answer-contract-20261015/{result,futures-commit}.json` 及 `candidate/`。本段代码与离线测试不代表供应商已服从规则或真实业务质量通过。

## 完整 BFF 与 Web 包已在本 Mac 安装

此次从两个已提交且 clean 的指定 HEAD 分别归档源码，以固定 Go 1.27.2 vendor 模式和 Node 24 / pnpm 11.25.0 离线锁定依赖构建 BFF 与各自 Web。不是用全部仓库 HEAD 组成新集成版本；其余运行服务继续原固定组合。

| 角色 | 新安装源码提交 | 二进制 SHA-256 | Web 文件清单树 SHA-256 |
| --- | --- | --- | --- |
| Futures | `b805fa9e09ad8c1ecf3feb4ae7c74e77a41029ed` | `18b4be2c7a04b77dc6d547e833412b58ea1261110bda1c3e12e7e51570c71ca2` | `16712d2e588bbd8f5bea119caee14df0028ef7e8864d038a1da9ea514d2229b9` |
| Console / control | `a2bca748d1bd6f0de0e52e1e0a59070e790d5fbc` | `490336bf86cbe97ded80798657e7f839b17cea532e682ac244a27bb80e6a6a17` | `ce9859b6b6f2b7ecda4c2b43636a463cd2b7ca77f45e44e6db766bc6ae947094` |

包清单 SHA-256 为 `c5d2d7dad6190974ac606e8b80a8ecee3325ffdd5cad56d6cc031eead3563586`。2026-10-15 01:16:53 UTC 的 `prepare.json` 只记录构建完成、`installed=false`；01:19:31 UTC 的独立 `installed.json` 记录安装完成。两份证据的清单、源码及二进制哈希一致，Web 树哈希来自对应完整包。先前“新 BFF 配旧 Web、Console 未安装候选”的描述仍是当时的历史观测，本条追加新的安装状态，不将旧记录改写为已经安装。

只替换了本机开发栈自有 Futures 和 Console 两个实例。配置值仅更新 `FUTURES_WEB_DIR`、`WEB_DIR` 及公开入口 `FUTURES_PUBLIC_URL=http://127.0.0.1:18098`；令牌与其他配置保持原值。旧二进制、原始配置字节与进程记录在独立私有 rollback 目录保留，未复制明文配置进证据。新实例使用同一包内匹配的 BFF 与 Web。

安装证据记录两个实例的鉴权 `/readyz` 均为 HTTP 200；Console 鉴权 `/api/ui-config` 只核验预期公开 URL。其余八个实例的进程身份、记录、配置和二进制哈希前后保持不变；研究任务集合未变化，均为终态。部署过程实际提交任务 0、模型调用 0。

一次性本机助手的独立静态评审覆盖准确 PID、完整命令/配置路径、UID、启动时间、固定回环监听及新旧文件哈希。修正了已请求 SIGTERM、但未确认退出时可能误报回滚完成的窗口，并让 SIGINT/SIGTERM 在安全边界进入回滚。隔离模拟验证五种停止流程；这些是函数级检查，不是实际安装失败回滚演练。实际本轮安装成功，没有触发真实 rollback。SIGKILL 或机器故障仍需依据持久 intent 与私有备份检查恢复，不宣称可自动恢复。

证据目录：`local/evidence/mac-bff-package-20261015-answer-contract/`，包括 `prepare.json`、`intent.json`、`installed.json`。执行前审阅的助手 SHA-256 为 `f9ec60340ba5ce03003f5612db94e50a768d35fc298267ab509fb51bb7f949c1`。新目录拒绝覆盖。

## 浏览器与完整页面验收仍未执行

本次没有访问浏览器、静态 HTML 或第三方站点，`installed.json` 明确记录 `browser_verified=false`。安装匹配产物和鉴权就绪不能替代页面验证。此前浏览器安全策略拒绝回环页面后，没有改换浏览器或底层路径绕过。

下一轮仍需在获准的实际浏览器流程中验证 completed 但 unstructured 的任务、草稿当前/历史版本、原始反馈与当前检查器区分、引用回读、同任务状态变化及桌面/窄屏布局；Console 的新入口也需真实点击。W03、W04、W05、W13 的完整 Agent、Skill/MCP、知识资料和所有页面场景继续保留，不将这些增量缩减为单个报告页面验收。

## 真实 Storage ENOSPC 的局部通过

独立测试只使用新建、受限大小的 Mac 磁盘映像、独立 PostgreSQL 18.6 集群与 Storage 实例；不填满宿主磁盘，不读取运行栈配置，不接触原 Windows。Registry、Runtime、Worker、Harness 和真实供应商均不在这个故障样本中，真实模型调用为 0。

第二轮证据 `local/evidence/storage-enospc-5ff4204ff489f2bf463c87acfa3b5df2/` 记录：映像文件系统容量 535,781,376 字节；分三档填充后发生真实 `ENOSPC`，该轮可用块和字节均为 0。Storage 新写入返回 HTTP 503，故障窗口 PostgreSQL 日志出现 `53100` / `No space left on device`，不只凭 HTTP 503 判定磁盘故障。

释放测试自有填充文件、重启同一 PGDATA 后，PostgreSQL 系统标识保持一致。重试前已确认原 baseline 字节及任务保留引用仍在；失败写对应 artifact 与 reference 均为 0。重复提交同一新 payload 后最终为 2 个 artifact、2 个 reference，没有重复效果。`result.json` 标记该限定切片通过；`cleanup.json` 确认测试 Storage/PostgreSQL 已停止、映像已卸载、夹具目录已删除，无证据留存错误。既有开发栈与原集群保持独立。

首轮 `local/evidence/storage-enospc-0c25ebb05d70f300ae411f3dd3bad93a/` 保留失败：1 MiB 写返回 ENOSPC 时文件系统仍报告 38 个可用块，测试在 Storage 故障请求前被边界断言拦截。随后仅修夹具的填充粒度及 PostgreSQL 故障证明；首轮不能算作 Storage ENOSPC 通过，也没有追写成成功。两轮清理结果分别保留。

这仅推进 P2 的 Storage 故障覆盖移交，补充 artifact/reference 原子性与同 PGDATA 恢复观察。该夹具没有 Harness、Compact 或笔记场景，不替代 Runtime 笔记/调用回执的磁盘满原子性、Windows 故障、宿主磁盘耗尽、断电、全平台资源上界或长稳验收。P2.5 与 W08/W09/W12/W14 没有因此关闭。正式脚本、版本、移植 delta 的离线编译/vet 及独立清理观察见[独立 Storage ENOSPC 验收记录](../storage-enospc-macos-20261015.md)。

## 第三次真实研究：供应商忙碌失败，没有内容验收结果

新 Mac 任务 `9e2dc8348c639a093632e0e2914ae9ec` 的终态证据已保存于 `local/evidence/macos-research-live-20261015-answer-contract/`。这是使用 Agent revision 4、Skill revision 3 的新任务，不是修改或续跑前两次任务；原生 `max_steps=12`、`max_model_attempts=12` 保持不变。独立核对确认新规则与固定资源出现在冻结快照和首个实际模型请求中；两项旧任务的 task、run、calls 与 result 在前后核验中的哈希相同。

`final-calls.json` 记录首个供应商响应 HTTP 503，类型 `service_unavailable_error`，消息 `Service is too busy`；任务错误为 model HTTP 503。`final-task.json` 为 `failed`、最终结果为空；`final-drafts.json` 为 0 份草稿；当前 v5 报告检查为 `unstructured`。空结果的检查状态不是新生成报告的格式回归，本次没有可以评价内容质量的成稿，不能据此证明或否定新答复规则的质量效果。

`final-usage.json` 记录 attempts 1、max_attempts 12、unknown_usage_attempts 1、prompt_tokens 0、completion_tokens 0、cached_prompt_tokens 0、accounted_tokens 433,491。433,491 是未知用量的保守记账，不是供应商确认的实际 token 消耗或账单；未知 usage 不能记为 0，也不能把未计量的 prompt/completion 零值解释成没有消耗。前两次任务共 161,007 个已计量 token 的历史合计保持原样，不将本次保守记账混为同一口径的实耗总数。

本次保留一次失败尝试及未知 usage，cost 为 null，没有自动重跑，也没有修改旧任务来消除未知值。后续若安排真实调用，仍应使用明确有界的新任务并单独留证；本次不能记为两次送检、最后草稿一致或质量验收通过。独立冻结请求、用量及旧任务不变性审查保存在同目录 `independent-review.md`；审查只读已有证据，没有额外调用供应商。

## 保留的交付范围

源码实现、离线夹具、独立静态评审、实际包安装、真实供应商调用和真实业务验收分开记录。已有 Windows 和前两次 Mac 证据继续保留，新增成功项不抹去历史失败，新增失败也不推翻不受影响的已闭结果。

研究质量、完整 UI、服务/权限退役、存储生命周期、剩余故障和资源测试及完整期货业务链仍按 P0–P5/P2.5、W01–W14 原计划推进。Windows DPAPI、受管发布/升级回滚、原库最新备份与实际恢复、Windows 双 Worker 等专项仍待目标环境复验；本机测试不替代它们，也不是访问原电脑的授权。最终统一 CI 仍未执行；本次没有 push 或触发 GitHub Actions。
