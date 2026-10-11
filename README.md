# Agent OS

面向多个业务的 Agent 平台。Go 服务负责持久化执行、工具与资料管理；React / TypeScript 提供统一能力中台和独立的期货研究工作台。

## 当前可用的两个入口

- 能力中台：<http://127.0.0.1:8090>。管理自定义 Agent、提示词、Skill、MCP、知识库、业务能力和运行记录；Agent 编辑器右侧可以提交真实测试任务。
- 期货研究工作台：<http://127.0.0.1:8098>。通过“供给与库存”“资料交叉核验”“资料时间线”发起研究，查看任务进度和结果。业务界面不暴露 Skill、MCP 和模型配置。

这是 **v0.3 本地可运行实现**。核心恢复机制已在真实 PostgreSQL 上测试，外部模型和 RAG 引擎仍需要配置服务与凭证。没有接入真实行情或全品种基本面数据库，也没有把示例模型输出当作研究结果。

## 已实现

| 模块 | 行为 |
| --- | --- |
| Registry | 不可变资源版本；Agent 绑定指定版本的提示词、Skill、MCP、知识库和子 Agent |
| Runtime + Worker | 持久化任务、模型请求/尝试/结果、检查点；多实例领取与租约接管；过期 Worker 提交隔离；父子任务、约束修订、取消与核对 |
| ToolHub | JSON Schema 参数校验、稳定 operation id、事务内效果与回执；Streamable HTTP MCP 发现与调用；未知外部效果停止重试 |
| Storage | 原文、作用域记忆、不可变内容哈希产物、引用根、分页回读；Compact 保留完整原记录和必需约束 |
| Knowledge | 原文件上传与正文提取；本地关键词检索；Milvus 向量检索和 LightRAG 图谱检索适配；后台索引与来源回查 |
| Console | 资源导入、Agent 编辑与右侧试运行、知识库上传/检索测试、业务能力配置、运行/服务状态、加密凭证写入 |
| Futures | 独立构建、端口和 BFF；发布的业务动作调用 Runtime，返回业务所需的进度与结果 |

Sandbox 的 Docker JavaScript 执行适配、Langfuse OTLP 事件导出和 Compose 多实例配置已编写；本机没有 Docker，尚未实机验证这些外部部署。知识库不等于已校验事实库，图谱关系和检索结果必须回查原始来源。

## 启动

正式目录：`D:\workspace\agent-os`。Windows 使用 PowerShell 7、Go 1.27.2、Node 24、pnpm 11.25.0、PostgreSQL 18。现有本机工具位于 `D:\workspace\.tools`；不要另建 C 盘副本。

```powershell
Set-Location D:\workspace\agent-os
./scripts/Initialize-Local.ps1
go build -trimpath -o bin/agentos.exe ./cmd/agentos
pnpm --dir web install --frozen-lockfile
pnpm --dir web run build
./scripts/Start-Local.ps1 -Workers 2
```

启动脚本运行迁移、登记不存在的能力包，然后启动 11 个进程，包括两个 Worker。已有 Agent 不会被初始化脚本覆盖。模型密钥在中台“设置”中保存，Agent 中的凭证名称需与其一致。详细工具路径、配置、停止与恢复见[本地操作手册](docs/operations.md)。

## 架构与验收

- [v0.3 分层架构](docs/architecture/agent-os-v0.3.mmd)
- [服务边界与执行/存储契约](docs/architecture/contracts-v0.3.md)
- [LightRAG、Milvus 与 Embedding 选择](docs/rag-selection.md)
- [验证记录与未覆盖范围](docs/validation-v0.3.md)
- [后续工作](docs/architecture/next-steps.md)
- [v0.1 独立架构评审原文](docs/architecture/agent-os-v0.1-independent-review.txt)（历史基线，不是本版代码审计）

服务是独立进程，但首版共享一个 Go 模块、镜像和 PostgreSQL schema。它支持个人本地使用和受控开发部署，尚不具备企业多租户、细粒度 RBAC、数据库高可用、完整的费用预算治理或独立服务数据库隔离。

期货应用只负责资料收集、校验、分类、留存和客观事实反馈。预测、交易方向与操作决定由用户负责。
