# Agent OS

面向多个业务的 Agent 平台。DeepSeek Harness（DSH）负责 Agent 执行循环与上下文压缩；Go 服务负责持久化调度、工具与资料管理；React / TypeScript 提供统一中台和独立的期货研究工作台。

## 当前可用的两个入口

- 能力中台：<http://127.0.0.1:8090>。管理自定义 Agent、提示词、Skill、MCP、知识库和运行记录；Agent 编辑器右侧试运行，在“发布”页设置业务入口。
- 期货研究工作台：<http://127.0.0.1:8098>。通过“供给与库存”“资料交叉核验”“资料时间线”发起研究，查看任务进度和结果。业务界面不暴露 Skill、MCP 和模型配置。

当前正在进行 **v0.6 端到端交付**。已接入固定版本 DSH 官方核心包；真实 DeepSeek、知识库回读、父子 Agent、MCP/Skill 和业务入口单篇公开资料采集已联调。完整生产化验收仍在进行，具体成功、失败及修复见[交付账本](docs/delivery-v0.6.md)。没有接入全品种基本面数据库，不把单篇联调当作研究覆盖率。

## 已实现

| 模块 | 行为 |
| --- | --- |
| Registry | 不可变资源版本；Agent 绑定指定版本的提示词、Skill、MCP、知识库和子 Agent |
| Runtime + Worker + DSH | Go 多实例领取与 fencing；每个执行任务启动 DSH 0.2.0-rc.2；持久化模型/工具响应重放、父子任务、约束修订、取消与 UNKNOWN 核对 |
| ToolHub | MCP/Skill 不可变版本；包校验、验活、定义漂移检查、启停和审计；Runtime 保持执行效果与回执的事务边界 |
| Storage | 原文、作用域记忆、不可变内容哈希产物、引用根、分页回读；Compact 保留完整原记录和必需约束 |
| Knowledge | 原文件上传与正文提取；有界中文/英文词法索引检索；Milvus 向量检索和 LightRAG 图谱检索适配；后台索引与来源回查 |
| Console | 资源导入、Agent 编辑/试运行/发布、知识库上传/检索测试、运行/服务状态、加密凭证写入 |
| Futures | 独立构建、端口和 BFF；直接调用发布的 Agent 确定版本，返回业务所需的进度与结果 |
| Sources | 独立公开资料 MCP；管理员指定 HTTPS 域名、原始响应哈希留存、文本分页与定位；不绕过授权来源 |

Sandbox 的 Docker JavaScript 执行适配、Langfuse OTLP 事件导出和 Compose 多实例配置已编写；本机没有 Docker，尚未实机验证这些外部部署。知识库不等于已校验事实库，图谱关系和检索结果必须回查原始来源。

## 启动

正式目录：`D:\workspace\agent-os`。Windows 使用 PowerShell 7、Go 1.27.2、Node 24、pnpm 11.25.0、PostgreSQL 18。现有本机工具位于 `D:\workspace\.tools`；不要另建 C 盘副本。

```powershell
Set-Location D:\workspace\agent-os
./scripts/Initialize-Local.ps1
./scripts/Build-Services.ps1
pnpm --dir harness install --frozen-lockfile
pnpm --dir web install --frozen-lockfile
pnpm --dir web run build
./scripts/Start-Local.ps1 -Workers 2
```

启动脚本首次生成独立服务配置；12 个进程包括两个 Worker。升级使用 `Start-Local.ps1 -Migrate`，需先备份并停止旧进程。已有 Agent 不会被初始化脚本覆盖。模型密钥在中台“设置”中保存，Agent 中的凭证名称需与其一致。公开资料适配器可用 `node scripts/enable-public-sources.mjs` 登记到本机 ToolHub 并绑定期货 Agent（可重复执行，不重复生成相同版本）。详细工具路径、配置、停止与恢复见[v0.5 操作手册](docs/operations-v0.5.md)。

## 架构与验收

- [v0.5 服务与数据边界](docs/architecture/contracts-v0.5.md)
- [v0.5 架构图](docs/architecture/agent-os-v0.5.mmd)
- [DSH 执行、恢复与 Agent 发布契约](docs/architecture/contracts-v0.4.md)
- [DSH 适配层与固定依赖](harness/README.md)
- [未变更的服务与存储契约（v0.3）](docs/architecture/contracts-v0.3.md)
- [LightRAG、Milvus 与 Embedding 选择](docs/rag-selection.md)
- [本轮验证记录与未覆盖范围](docs/validation-v0.5.md)
- [后续工作](docs/architecture/next-steps.md)
- [v0.1 独立架构评审原文](docs/architecture/agent-os-v0.1-independent-review.txt)（历史基线，不是本版代码审计）

各服务具有独立二进制、镜像、数据库账号和服务身份。ToolHub/Knowledge 拥有各自 schema；Console/Futures 无数据库权限。Runtime/Worker/Storage/Sandbox 仍共享部分执行事务表，尚未完全拆库。Linux 2 核 / 4 GB、100 万文档 / 1000 万分块以及物理节点 HA 都是验收目标；参见[生产验收账本](docs/production-readiness.md)，不能把小样本 CI 写成生产能力。

期货应用只负责资料收集、校验、分类、留存和客观事实反馈。预测、交易方向与操作决定由用户负责。
