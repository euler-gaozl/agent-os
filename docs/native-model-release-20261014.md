# 原生模型能力的 Windows 发布检查

当前四个服务已正式安装，默认已切为 native-v4。既有旧 Agent 配置仍走 budget-v3。此文件记录可重复检查与实际安装的边界，不代表真实研究已经验收。

## 最新增量：Futures 已安装，真实研究仍未整体通过

Futures `e7b1c8e511e9374f029bd195784301a7666dd5cc` 已通过标准入口完成更新→回退→重新更新，三次均 `committed`、`readiness=verified`、`non_target_unchanged=true`。证据为 `ops/native-futures.path` 下的 `managed-install.json` 和 `doctor-installed.json`。当前本机状态再次确认核心就绪、12 个实例、没有 pending 发布。

研究 Agent 的原生能力 revision 15、16 均已正式发布。两次使用相同问题 SHA `8cd87684a404817f4ca9e784accbf8f890217636fa87ee97a7831243155f9cf1` 和原有五份留存资料，通过正式业务入口调用官方 DeepSeek；没有缩小原问题来换取通过。

| 任务 | 实际执行 | 结果与限制 |
| --- | --- | --- |
| `856b4d1d3679e15185c7fd0998a462f0`，revision 15 | completed，3 次模型调用，54150 计量 token | 21664 字节最终稿，24 条引文匹配；仍有无效比较和不存在的事实引用，研究质量不通过 |
| `f272fd4c8f65383383a660df8296e6a0`，revision 16 | completed，4 次模型调用，81534 计量 token | 12093 字节最终稿，20 个事实、0 个比较、5 个问题；预设 20 项关键报数均保留，20 条引文匹配；最终结构、引用及比较规则没有错误，但仍有 45 项日期/性质定位待核 |

第二次调整了 Agent 的检查反馈与修订提示词，并实际调用检查工具两次。最终稿只相对最后一次检查稿移除了一个问题的两个事实引用，其中一个原引用不存在；因此最终稿并非已检查稿的严格副本，不能把提示词约定写成系统强制保证。

原始证据在 `ops/native-research.path`，第二次位于 `checked-final-repair/`，包括任务/用量、两份实际检查稿和反馈、`checked-final-evidence.json`、`quality-audit.json`。两次共 7 次付费模型调用、135684 计量 token，未知用量 0；没有运行 Actions。

此处只验证固定资料集的执行和成稿。尚无新的主动采集或独立交叉核验，若干年份取自发布日期推断，原资料截断缺口仍需处理；20 项报数匹配不等于完整研究或外部真实性核验。P5 保持未通过。升级前备份恢复证据仍有效，但还不能覆盖新增的原生 Agent、任务和 Futures 发布记录，需补最新备份及实际恢复。

以下记录保留各增量当时的安装状态，以上述最新记录为准。

## 正式安装与实际回退

本次通过标准维护入口安装：Registry `755b8de85531f0b9620a98beaf1e3a9dccc9d6b0`、Runtime `7d1926162dd8b6e8296963d9b486e7b26fa9c475`、Worker `ff9a2f07f397bf0b408256e8a71644b3d2976376`、Console `00bc6280d13e5b1bb57276b0dedef90ea2226c68`。发布集 `11a632f5be3a4d968ccd469590571a02` 从干净、固定源码构建，保留四份 Harness 及 Node。

- 升级前标准备份实际还原至隔离 PostgreSQL：44 关系指纹/结构权限、10 个账号登录、3 条凭证解密及 6 份来源归档验证通过；未启动 Worker 或调用供应商，隔离集群确认停止。还原报告 `local/restore-checks/f10b99db44364e86aed4f30d3a148649/result.json`。
- 依序对 Registry、Runtime、Worker、Console 执行更新→回退→重新更新，12 次均 `committed`、`readiness=verified`、`non_target_unchanged=true`。Console 回退前单独停止 Registry，回退后重新启动，保留独立操作日志。
- 标准 `set-engine -Engine native` 配置事务提交成功，默认 `dsh-source-639ed015-native-v4`，非目标实例不变。随后 doctor 核心检查通过，12 个正式实例，pending 为 0；隔离代码执行未配置的状态仍明确显示。
- 原始安装/配置事务、版本及 doctor 报告集中于 `ops/native-activation.path` 指向的 `local/evidence/native-activation-66a146b7b1a144588b4d16750787f5ba`。

本次零付费调用、零 Actions。尚未发布研究 Agent 的原生能力新 revision，也未以该新版本执行真实研究；Futures 业务端的旧输入和回包边界仍待对齐。完整 P2–P5 余项不因本次成功安装关闭。

## 服务与历史兼容

### Futures 长文本候选

独立候选 `e7b1c8e511e9374f029bd195784301a7666dd5cc` 取消问题 20,000 字节旧上限，任务请求/正文/单任务响应与 Runtime 对齐为 32/16/64 MiB 传输容量；不设置新的模型 token 配额。通用代理不再把超过边界或中断的回复按 200 静默截断。单任务详情及报告检查可读取完整长结果，结构检查仍有独立的工作量边界，超出时保留全文与准确 SHA，标为待核。

全仓 Go 74 个测试、Web 10 个测试零跳过，vet/独立构建通过。完整发布包搬离原路径后启动实际 BFF/Web，与受控下游 HTTP 验证 5,250,018 字节输入、9,750,012 字节输出和完整原结果 SHA；实际心跳/鉴权通过，进程确认停止。`ops/native-futures.path` 指向 `native-futures-583e7fe04edb4630b43c099599acc6e1`，搬迁结果 `bff-fixture-iu7Ld4/result.json`。独立评审核对源码和测试日志无阻断；评审未亲自执行测试，不将合成下游写为真实供应商。本节先记录候选，实际安装另记。

- Runtime 保留 v1/v2/v3，native-v4 使用完整的供应商能力快照；全旧 Agent 树回落固定 budget-v3，因此 Worker 必须同时保留该版本。
- Worker 发布包独立携带四份固定 Harness 和 Node，构建、备份、恢复均保留各自内容摘要；新协议不能覆盖旧任务使用的文件。
- Registry 声明 `agent-model-native-v1`，Console 在保存前向已绑定 Registry 探测，失败时不发送写入。Windows 发布器另核对声明、实际二进制、受保护配置和存活进程的绑定目标。
- Registry 的全部历史 Agent 版本均参与降级检查，不能只检查最新版本。停止 Registry 后，还要等待该数据库账号遗留会话退出，再用新事务快照检查迟到提交；异常、未知形状或权限不符时拒绝。
- 即使单独部署 Registry，也执行自身历史检查。新 Console 需要匹配的 Registry 和 Runtime；旧 Console 不允许读取已有原生 Agent 或原生任务。
- **回退旧 Console 前须先通过独立维护动作停止 Registry。** 仅停止中台不能阻止此前保存请求在 Registry 完成。发布器不会自动停止另一个服务；等写入结束后若存在原生 Agent，旧版回退仍被拒绝。无法安全恢复旧版本时保留 pending，不删除资料或伪造回退成功。

## 已执行证据

- Runtime 历史 Agent/子树、幂等重试、实际 Snapshot 展开长绑定提示词等：46 项、零跳过，真实隔离 PostgreSQL，vet/build 通过；`ops/native-legacy.path`。
- Registry/Console 能力鉴权、探测失败不保存及完整正文转发：37 / 30 项、零跳过；独立程序无需配置的声明探测通过；`ops/native-management.path`。
- 四版本安装策略与固定产物：107 项通过；`source-release-policy-5b480012fa4c47f28ae03f6650d06926`。
- native 默认切换：53 项真实 Windows 夹具进程和数据库检查，包含进程中断及恢复；正式 Runtime/双 Worker 已恢复，发布目录与 14 份配置指纹不变；`ops/native-default-managed.path`。模型管理守卫随后另行收紧，纯执行布局的提前返回语义保持不变。
- 模型管理发布保护：41 项通过；实际二进制声明、隔离 PostgreSQL/受限账号、合成资源表、零服务副本的正式维护入口。包含 Registry-only 历史检查、冷启动、回退、pending 恢复、迟到写入、客户端强杀后的延迟 COMMIT，以及元数据导出/还原；`ops/native-model-release.path`。
- 既有回执管理发布检查：41 项通过；`receipt-release-9fbb6e27c8e14584b73ddc0869599422`。

第一次模型管理外层 runner 误读 `pg_ctl status` 遗留退出码，虽然内部 30 项通过仍报告失败；该记录保留。修正 runner 并扩展检查后重新执行。独立评审指出的 Registry-only 跳过检查、旧 Console 迟到提交窗口及原始元数据数组展开均已修复，本轮后续复审以实际结论为准。

上述检查均无付费模型请求、无 Actions。完整正式包安装、备份实际恢复和服务升级回退已补齐本页前述证据；同一真实期货任务的成稿质量与 Futures 业务端输入/回复容量仍待完成，不能把 Console 的大消息验证外推为业务端已经完成。
