# v0.4 验证记录

日期：2026-10-11。环境：Windows、Go 1.27.2、Node 24.19.0、pnpm 11.25.0、PostgreSQL 18.6、DSH 核心包 0.2.0-rc.2。工作目录 `D:\workspace\agent-os`。

## 已实际执行

- `pnpm --dir harness install --frozen-lockfile`：通过。运行固定版本官方 DSH 核心包，未用模拟 Harness。
- `go vet ./...`：通过。
- `go test -count=1 -v ./...`：41 个测试入口通过，其中 40 个验收场景、1 个供进程故障测试启动的 helper。数据库测试使用真实 PostgreSQL 的独立临时 schema。
- `pnpm --dir web run build`：TypeScript 检查、中台构建、独立业务端构建通过。lucide 的 `use client` 有构建提示，没有构建失败。
- 11 个正式本机服务进程已启动，包括两个 Worker。模型 Key 未配置，没有伪造真实供应商执行结果。

## 本次新增关键验收

| 场景 | 实际结果 |
| --- | --- |
| DSH 实际调用工具、保存资料并返回结果 | 真实 DSH 子进程 + 本地模型 HTTP 夹具 + 真实 PostgreSQL；保存 1 条夹具资料 |
| 完成回执后、最终状态提交前重放 | 已完成模型结果直接复用，模型请求总数不增加，资料不重复写入 |
| 工具事务已提交、桥接响应未保存时中断 | 从工具账本恢复回执；没有再次请求 ToolHub，没有重复资料 |
| Worker 进程被强制杀死，第二进程接管 | 真实进程终止与跨进程领取；旧模型 attempt abandoned，新 attempt completed |
| 外部工具效果未知 | DSH 任务停在 waiting_unknown；核对真实夹具回执后继续，外部效果仅 1 次 |
| 模型返回旧计划时用户修订约束 | 旧工具被跳过，下一模型请求包含新约束，没有写入被禁止的资料 |
| 父任务等待子 Agent | 父任务落盘为 waiting_children 并释放执行槽；子任务完成后替代 Worker 重放父任务并读取子结果 |
| DSH 自动 Compact 与随后重放 | 实际 DSH 压缩发生；完整原证据和 compaction/end 事件可从产物回查；重放不增加摘要或普通模型调用 |
| 旧 action 迁移 | 合并专用指令和约束，保留绑定版本、原 action；第二次迁移不重复 |
| 发布/撤下与版本校验 | 业务目录只显示最新已发布 Agent；撤下或过期版本不能新建任务；业务响应不暴露平台配置 |

其余测试继续覆盖 fencing、工具效果与回执原子性、幂等键、MCP 协议、来源/作用域/版本、取消、知识服务与遥测边界。以 Legacy 命名的测试专门验证历史 Go 任务兼容，不作为 DSH 测试证据。

模型、Milvus、Embedding、LightRAG、MCP 和 Langfuse 外部端点仍是协议夹具；DSH 和 PostgreSQL 是真实组件。摘要保真测试检查留存和结构，不证明真实模型能准确识别每个重要研究事实。

## 本机界面与数据

浏览器验证中台侧栏无独立“业务能力”；Agent 编辑器有提示词、资源绑定、知识库、模型与执行、发布五页和右侧试运行。实际点击“保存并发布”后，供给与库存 Agent 从 v1 变为 v2，业务 API 返回相同 v2。业务端仍呈现三个研究按钮及任务输入，未暴露 Skill/MCP 配置。

本机迁移后 5 个 Agent，其中 3 个已发布；知识文件 1 份，仍是研究方法资料，没有市场基本面数据。旧 action 版本仍在数据库，管理 API 不再把它们作为可编辑资源列出。

截图：`.state/screenshots/agent-publication-v0.4.png`，仅在本机留存，不提交私人工作区截图。

迁移前备份：`.state/backups/20261011-151836.dump`。迁移与发布验证后备份：`.state/backups/20261011-153816.dump`。后者已通过 `Verify-Backup.ps1` 恢复到本次独有的隔离数据库：resources=15、documents=1、artifacts=1、artifact_hash_mismatches=0、dangling_artifact_refs=0；原库未覆盖。这是小数据恢复核验，不是容量或 RTO 测试。

## 未验收边界

真实 DeepSeek 模型的工具质量、费用和长上下文语义保真；真实 Milvus/LightRAG/Embedding；Docker 镜像构建与沙箱；跨 DSH 版本迁移；长任务存储开销、并发吞吐与企业规模；全品种期货采集和业务研究质量。当前模型连接为非流式 HTTP，DSH 的流式块由适配层从完整持久化响应构建，不是上游 token 实时流。

GitHub Actions 已更新为先安装固定 DSH 依赖，再运行 Linux + PostgreSQL + Go race 检查及两套前端构建。远端结果以 PR 的实际检查状态为准。
