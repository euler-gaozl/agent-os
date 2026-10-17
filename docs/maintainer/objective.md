# 完整目标与有效约束

## 当前执行版本（2026-10-17）

用户要求接回朋友 Mac 的未推送成果、回到原 Windows 继续，并及时同步 GitHub。执行主仓 `D:\workspace\agent-platform\repos\agent-os`；新顺序见 [接回与续做计划](windows-resumption-20261017.md)。下面原 Goal 全文作历史保留；路径、公开仓库和当前环境按后续指令修正。此前交接暂停要求已被“继续”覆盖，Goal 卡片的恢复需用户点击；这不影响已授权的当前工作。目标范围仍完整保留。

## 原 Goal 全文

按 D:\workspace\agent-os\docs\windows-single-machine-plan.md 与 docs\architecture\dsh-source-and-storage-decision.md 的完整规划，交付可日常使用的 Windows 单机 Agent 平台。顺序：P0 固定现有可恢复基线与所有权威数据库/密钥配置/构建产物的恢复清单；P1 建立 start/status/stop/doctor/backup/restore-check/update/rollback 本机维护闭环，将源码和状态安全归入 D:\workspace\agent-platform（repos/local/ops），不移动运行中数据库、不丢旧资料；P2 将12个服务分别置于独立私有 GitHub 仓库，agent-os 只管集成部署，各仓库独立构建/配置/迁移/发布/回滚，Runtime/Worker 和 Knowledge/Indexer 保持必要事务域与固定共享协议；P2.5 纳管固定 DSH 源码至 agent-os-harness，实现持久化/checkpoint 插件、结构化任务工作状态、Compact 信息保留与原文回查、长输出引用、可重建缓存清理和有界内存/恢复测量，已有扩展点优先，必要的 Session/Loop 核心补丁以证据决定，保留旧引擎任务兼容，不另造决策循环；P3 完整中台 Web 管理 Agent/提示词/Skill/MCP 检测验活/资料/记忆/运行，独立期货业务 Web，真实官方 DeepSeek+DSH 端到端跑通并逐页优化UI；P4 Windows 双Worker接管、取消、丢回复、未知效果、Compact、数据库中断、备份还原与独立升级回滚故障验收；P5 固定品种/日期/供给库存问题完成采集校验入库研究引用回读的真实业务验收。每阶段记录真实证据与未解决缺陷并接受独立评审，不以目录数量或绿色CI代替交付。凭证和私有数据不得进入GitHub/日志/模型上下文，付费调用小额有界。先以本机PostgreSQL词法检索及现有Windows环境完成核心链路，Sandbox/Milvus/LightRAG/Langfuse等扩展的服务交付与实际配置可用性分别验收，未配置不假报可用。服务器/跨机器HA、主备数据库、公网生产部署、最终百万文档千万块全平台规模验收和全品种业务资料覆盖进入后续阶段，不阻塞本次单机目标；机器宕机HA和未执行测试不得宣称完成。

## 后续用户指令对原文字的修正

- 2026-10-15 明确：接手者使用自己的 Mac。开发工作根默认 `~/workspace/agent-platform`，独立配置和数据；D 盘路径和 Windows 运维规则只适用于原电脑。知识库应隔离可移植知识与环境观测，禁止将原电脑的运行状态/路径/凭证当作 Mac 现状。接手工作默认不连接、不修改原电脑。详见 [环境边界](environment.md)。这不抹去原 Windows 验收要求，也不代表已经验收 macOS 部署；暂时无法执行的目标环境用例继续保留。
- 旧 `D:\workspace\agent-os` 只是迁移提示。有效主仓是 `D:\workspace\agent-platform\repos\agent-os`；配置、数据库、日志、发布、证据和备份归 `local`，机器维护入口归 `ops`。
- 原 Goal 中“私有 GitHub 仓库”已被后续明确公开请求覆盖。此项目群 15 仓目前公开；个人 `obsidian` 保持私有且不属于本交接。不要再次改仓库可见性。
- 先交付 Windows 单机版，服务仍保持独立构建/部署/升级/回滚和多实例设计；服务器阶段后续验收。
- 优先 Go / Rust / TypeScript，按工作负载选择，原则上不用 Python。正式项目不放 C、H、J 盘。
- 中台共用 Web；期货业务端独立，参考任务式研究交互。Skill/MCP/提示词等基础设施配置不应占据业务端。
- 使用官方 DeepSeek 配置和固定 DSH 源码。DSH 拥有决策循环与 Compact；不能自己再造第二个循环。旧任务不得静默切换引擎、提示词、工具、预算或重放输入。
- 用户明确不要人为压低输入/输出长度。当前已按模型原生能力配置。模型本身上下文/输出能力、HTTP/单工具传输容量和任务调用次数预算是不同边界，不能混称“无限”。
- 期货研究只收集、校验、分类、反馈事实及留存，用户做预测和交易判断。不用价格倒推基本面，不制造全品种已覆盖的假象。
- 密钥不进 Git、日志、报告或模型上下文。真实供应商调用小额有界，不能靠连续付费重跑掩盖程序错误。
- 日常提交不跑 GitHub Actions。15 仓 Actions 已禁用；本机交付完成后仅集中执行一次统一 CI，先控制 runner 分钟和触发器，不重复每仓全套。
- 既有证据不受修改影响时不重复全测。独立审查要明确是静态阅读还是实际执行，不伪造评估 Agent。
- 用户已明确要求交接完成后暂停原聊天 Goal，避免双边同时修改；接手 Codex 应新建等价完整 Goal，继续未完成项。

## 验收范围不能缩小

完整阶段 P0、P1、P2、P2.5、P3、P4、P5，以及 W01–W14 的每一项仍在 [原计划](../windows-single-machine-plan.md#5-核心验收矩阵)。本次只交接，没有宣布项目完成。

W01 启停、W02 独立发布、W03 Agent 配置、W04 ToolHub 检测、W05 资料索引、W06 真实模型业务、W07 双 Worker 接管、W08 Compact 恢复、W09 笔记生命周期、W10 异常/未知效果、W11 实际恢复、W12 安全资源、W13 全页面、W14 源码 Harness 存储与内存，均要以适合其范围的当前证据核对。部分测试或历史基线不能代替整体验收。

暂停不是完成，不应删除原缺陷或把目标改成仅修好报告。后续明确延后的服务器 HA、全量容量与全品种覆盖也应保留下一阶段清单。
