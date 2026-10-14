# 交接状态快照

2026-10-14 核对。**整体未完成，不能报一个没有分母的完成百分比。** P0/P1 已按当时范围完成；P2/P2.5/P3/P4 部分完成；P5 真实研究质量未通过。以下是原维护者留存的结果，接手者尚未复验的部分应保持该标记。

## 已经落地

- 源码分为 15 仓：12 个服务、SDK、源码 Harness、集成入口。源码、状态和维护脚本已迁入 `D:\workspace\agent-platform`，旧库保留，没有通过清空重建伪造迁移成功。
- Windows 受管启停、状态、诊断、独立构建/安装/回滚、发布恢复、备份与隔离恢复已有真实证据。P1 完成不代表最新资料已做最终备份。
- Registry 资源固定版本；ToolHub 的 MCP/Skill 注册、包校验、验活、漂移、启停；Knowledge 上传/正文/索引/搜索/原文附件；Sources 受限公开资料采集；Storage 不可变产物与回读；Runtime/Worker 多实例执行、回执、工作状态、记忆与恢复均有实现及分项测试。
- 官方 DSH 的固定源码已纳管并构建安装。旧任务继续原引擎；全原生能力 Agent 树的新任务使用 native-v4，全 legacy 树仍回落 budget-v3，混合树拒绝。没有把决策循环换成自写 Go loop。
- 统一中台和独立 Futures 页面已运行；真实网页采集入库与原文回读、官方 DeepSeek 多步调用已发生。报告内容质量仍未通过，不能把“调用成功”当端到端验收。
- 最新增量已安装 Runtime `e6c8b93`、Futures `f40a8f8`，业务页能选择失败任务的两份历史草稿、读检查反馈和原文，明确显示无最终回答。

分项证据见 [草稿投影验收](../research-draft-visibility-20261014.md)、[中台采集](../console-capture-acceptance-20261014.md)、[源码执行器激活](../source-engine-activation-20261013.md) 和 [完整单机计划](../windows-single-machine-plan.md)。

## 最后一次本机观测

核心就绪，11 类服务共 12 个实例，其中 Worker 两个；发布 pending 为 0。Sandbox API 有实例，但 Windows 没有执行后端；Telemetry 零实例。该描述是一次观测，不保证电脑关机或换机后依然在线。中台 `http://127.0.0.1:8090`，业务端 `http://127.0.0.1:8098`。

| 服务/角色 | 集成选定提交 | 实际安装提交 | 仓库最新开发提交 |
| --- | --- | --- | --- |
| Console / control | 00bc628 | 00bc628 | 00bc628 |
| Futures | f40a8f8 | f40a8f8 | f40a8f8 |
| Registry | 755b8de | 755b8de | 755b8de |
| Runtime | e6c8b93 | e6c8b93 | e6c8b93 |
| Worker | ff9a2f0 | ff9a2f0 | ff9a2f0 |
| ToolHub | 98f8fec | 98f8fec | 448f449 |
| Knowledge | ed54550 | ed54550 | ed54550 |
| Indexer | ccbfbd2 | ccbfbd2 | 30ed978 |
| Storage | ded5920 | ded5920 | ded5920 |
| Sources | 29fe086 | 29fe086 | 76511f1 |
| Sandbox | 9348b8e | 9348b8e | b7a2cdf |
| Telemetry | c2a02e2 | fcaca2e | cf73e7f |

完整 SHA、分支与核对来源见 [repositories.json](repositories.json)。15 个开发分支在交接前均核对为本地/远端一致，Actions 均禁用。集成代码基线是 `4b8074c`；此交接文档在该基线之后提交。**不要一键把所有服务替换为仓库 HEAD。**

Worker 编译依赖 Runtime execution `v0.1.0-rc.5` / `4ce5132`；Indexer 编译依赖 Knowledge indexing `v0.1.0-rc.1` / `e26584d`。固定共享包与所连接服务的当前提交不是同一概念，升级要验证兼容与未完成任务恢复。

## 当前最重要的失败

真实任务 `4bdf967d35ab0b92ae43c38dc87a5947` 使用 `published-supply-inventory` revision 17、`china-futures-research` revision 6，固定十份资料、四个供给/库存问题、分类基准日 2026-10-09。任务在第 13 步因 `DSH model request budget exhausted` 失败，最终结果为空。12 次模型请求已消费；输入输出不是人为 4096 限制，问题在任务轮次分配与成稿质量。

冻结供应商配置记录为官方 DeepSeek `deepseek-flash`、thinking disabled、context 1,048,576 / output 393,216。这里只记录原任务元数据，不保证未来供应商规格不变。12 次调用统计：prompt 519,134、completion 20,169、总计 539,303；cache hit 460,160 是 prompt 中的子集，不能再相加；未知计量为 0。这不是费用估算。

最后两次检查留下 15,307 字和 22,109 字草稿。较早版本未结构化，较新版本仍需核验，历史反馈含 148 项问题；该数不是 148 个独立事实错误。留存草稿包含 30 条事实、7 个 AI 摘要候选、23 个推断日期、16 个 findings。引用错位、统计口径和日期、缺口表述等问题见 [待办](backlog.md)。当前回读检查与历史送检反馈分开，不能覆盖历史记录。

本次交接没有新付费请求、没有改研究预算、没有实现自动继续，也没有再次触发 GitHub Actions。

## 测试的实际边界

最新草稿显示增量：Runtime 7 项相关测试、Futures 87 项 Go 与 13 项 Web 测试通过，无跳过；配置事务最终 60 项通过，network 策略此前 74 项通过。正式浏览器实际回读两份草稿，哈希与留存一致。独立评审为静态审查，不能替代动态证据。详情与中途失败保留在对应验收文档。

这不是“所有测试全通过”：完整页面矩阵、最新备份恢复、旧覆盖/权限退役、剩余故障/资源与研究质量仍未关闭。历史 Linux CI/真实外部后端验证不代表当前 15 仓组合已做最终 CI。百万文档千万分块、2 核 4 GB 整个平台长稳上界、物理节点 HA 均未验收。

## 本机私有证据定位

以下只是位置索引，未提交其内容：

| 入口/位置 | 内容 |
| --- | --- |
| `ops/maintainer-handoff.path` | 本次 15 仓远端/分支/Actions 核对及交接检查 |
| `ops/draft-projection.path` | 最新安装、生产状态、草稿和浏览器证明，含配置恢复失败/成功记录 |
| `ops/research-report-contract.path` | 实际 calls、研究输入、草稿、反馈、任务状态与 usage |
| `local/evidence/mcp-config-507e84a0f3464cb0a543533987cbbaf8/result.json` | 最新 60 项配置回归与测试环境清理 |
| `local/releases/current.json` 及其 manifest | 当前固定发布、源码/SDK/Owner 协议、实际引擎包 |

原电脑资料和加密凭证不能从 GitHub 重新获得。资源库当前 Agent/Skill 内容也不等于 `packs/futures` 初始种子；需要脱敏导出并核对固定版本，不能把种子覆盖进正式库。
