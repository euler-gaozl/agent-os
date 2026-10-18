# Mac 显式接续动作与 Console 回执恢复（2026-10-15）

Runtime 与 Console 已提交显式手动接续和结果未知后的回执恢复源码，并完成分层测试。本轮没有迁移或部署到常驻环境，没有浏览器、真实供应商或业务验收；完整目标仍未完成。

环境：维护者独立 macOS15.3（24D2059）/arm64，Go1.27.2、Node24.19.0。延续[只读预览](macos-continuation-preview-20261015.md)和[Worker准入修订守卫](macos-native-attempt-revision-20261015.md)，保留原Windows及旧Mac历史。

## 动作与长期回执

新增命名control专用接口：

| 接口 | 意义 |
| --- | --- |
| GET `/v1/runs/{id}/continuation/request-context` | 观察当前条件，仅候选带failure_version；不是许可或预算预留 |
| POST `/v1/runs/{id}/continuation` | 提交原request_id与expected_failure_version；排队202或持久化确定拒绝409 |
| GET `/v1/runs/{id}/continuation/requests/{request_id}` | 200回读原持久化决定；404仅表示本次未观察到匹配回执 |

同ID、同任务及版本重放原结果；冲突不改旧回执。新请求锁请求ID、按父先顺序锁任务族，取得预算锁后用新语句快照复核原生完整503失败、冻结规则、原轮次/全族尝试预算及无未决效果。正向族容量上限128；超限转人工复核。成功在同一事务重新排队并追加事件/回执，不消费模型尝试，不改旧快照、帧、回执或预算。BeginModel仍是实际发送前的最终准入守卫，不能撤回已准入的在途调用。

回执记录历史接受/拒绝，不代表当前任务状态。首次POST、同ID重发与GET均使用保存的JSONB表示。HTTP失联、超时、数据库错误及未知COMMIT结果不能伪造拒绝；应回读或重发原ID/版本，不能以404认定未提交而换ID补偿。请求体封闭为两个字符串且有界；共享单token模式不替代命名control身份。

新增Owner表 `run_continuation_receipts`，Runtime仅SELECT/INSERT，Worker无新增权限。它是长期审计记录，不做TTL缓存清理；外键约束任务删除，后续生命周期纳入该历史。普通迁移不执行权限退役，readiness及既有权限退役清单纳入新表，不代表已执行常驻环境迁移或权限收缩。`cmd/migrate`会重放既有schema/notes/working_state及新continuation SQL，含旧app_runs回填、笔记补全和trigger更新；未来常驻升级须核对迁移前后旧任务、账本及笔记摘要，不能视为只建新表。

新Runtime源码把native旧 `/resume` 改为锁内409 `explicit_continuation_request_required`，历史引擎旧行为保留。既有只读preview协议及 `action_available=false`、`/resume-source-state`、`/reconcile`、固定execution/DSH协议和Worker编译pin不变；旧文描述的是对应旧版本，不覆盖其历史结论。

## Console 的待确认请求

Console BFF新增限定路径与容量的代理，原生任务面板在首次POST前用每请求独立localStorage键保存ID及失败版本。回复丢失、404、登录失效或回执不匹配均保留原请求，提供查回执和显式重发同一请求；匹配持久化回执才清除对应项。多标签可能生成不同ID，最终排队权威是Runtime的版本与事务，localStorage不是跨标签原子锁。

界面区分历史“已接受排队”与执行详情当前状态，提示沿用原快照/剩余预算及可能产生新模型用量。不自动提交、换ID补偿或回退旧native恢复入口。此次是Console源码流程，未扩展为Futures完整业务UI或自动接续。

## 实际验证与限制

| 验证层 | 实际结果 |
| --- | --- |
| focused Runtime race | 19顶层/42子项通过，零fail/skip；其中新增Owner7顶层/11子项，另含2纯HTTP、6已有preview及4已有guard顶层 |
| Runtime广泛回归 | 112顶层及195子项pass，零fail；14顶层及13子项显式skip，共27，包104.443秒 |
| 独立Worker/官方Node | 1顶层/3子项pass，零skip；通过新动作排队后，旧pin改规则仍发2次、新pin改规则仅1次、新pin同规则2次后完成 |
| Console | Go各包race、vet/build成功；Web36项（新增9）零skip，TypeScript/Vite成功 |

Runtime另有internal/runstate纯测试race及全仓vet/build通过。广泛回归的顶层pass含子项全skip的分组，不能当作叶子用例全覆盖；27个显式skip保留。其中独立Worker修订用例由另一有配置的命令实际运行，不能改写原命令的skip记录。独立Worker测试驱动使用race，实际Worker产物非race构建。原始请求键序可不同，完整规范JSON仍与冻结exchange和call/attempt绑定；合成模型HTTP次数不是新增真实供应商调用。Vite保留lucide-react的“use client”及超过500KB chunk非致命警告，构建成功不等于无警告。

新增Owner用真实隔离PG/HTTP与正常API测试同ID/跨ID并发、失败版本、取消/约束/Claim、锁超时和回滚、家族预算、权限及再迁移；成功旧效果重放与原未知usage保留。HTTP回包丢失发生在Handler已提交后断开客户端连接，没有注入PG COMMIT网络回复丢失。权限夹具NOLOGIN/SET ROLE不等于独立数据库账号登录验证。

独立Worker执行其真实execution模块与固定官方Node；Runtime HTTP/PG真实执行，模型TLS及归档是有界夹具。Console检查覆盖客户端/组件及代理逻辑，不证明真实挂载hook、跨标签事件顺序、浏览器断网或登录恢复流程。129成员容量、坏持久化回执数据库处理、专门的子任务/历史引擎动作拒绝及全部边界组合未据此宣称穷举。没有真实供应商、真实Storage全链路或业务成稿验收。

## 来源、现装状态与剩余工作

| 组件 | 本轮源码提交 | 常驻安装状态 |
| --- | --- | --- |
| Runtime | `dbf99dca784c849f0386da1c3de219aa10142a8e` | 仍为 `879c5034`，新表与动作尚未部署 |
| Console | `8e8186c07467897410f5a94973c7c4d36d99490e` | 仍为 `58c511f3`，新面板尚未部署 |
| Worker | 本轮不改 | `94d60591`，execution固定 `1f6c4c29`/既有pseudo-version |

隔离夹具后十个常驻实例对象与基线完全相同；按本轮p2_runtime_前缀核对的临时库、角色、连接残留均0，6个夹具Worker PID消失，不宣称Mac上所有临时对象都已清理。未操作常驻任务或迁移部署，真实模型调用0。源码已本地提交且clean，未推送、未运行Actions。

Runtime候选、实际Owner/Worker执行、Console源码及最终构建证据分别经过独立审查。执行审查核对原JSONL、13个受测文件/source-set、固定产物、清理记录和全部skip；Console审查核对实际六组日志，并保留mounted hook/多标签缺口。审查者未另行连接PG/HTTP、操作服务或重复模型调用。本机证据为 `local/evidence/macos-continuation-action-20261015`；执行独审报告SHA-256为 `dadcd41f9130676d5160e7f2d40f637908ce0e3b47ba65a15ce2ddbf1ff6cba4`，候选首版和已修正的路径/身份边界、Console查询标记与晚到刷新问题保留于相应评审，不伪装为本轮已通过的浏览器测试。

完整P0/P1/P2/P2.5/P3/P4/P5与W01–W14保留。接续仍需常驻环境迁移/部署、真实浏览器与业务流程、受控自动策略及后续失败恢复验收；研究成稿/引用日期统计口径质量、服务权限退役、永久资料与回执生命周期、持续资源、Futures全流程、Windows DPAPI/受管发布/原库恢复和最终统一CI继续按原计划。新增动作和部分UI源码不等于Goal完成。
