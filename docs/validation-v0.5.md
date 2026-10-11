# v0.5 验证记录

目标与未验收项目见 `production-readiness.md`。以下测试使用真实 PostgreSQL/服务进程；模型和 MCP 数据均为明确标记的夹具，不是期货事实。

## 本机已执行

- Windows + PostgreSQL 18，`go vet ./...`、`go test -count=1 ./...` 通过；Web TypeScript 检查和中台/业务两套构建通过。
- 11 个独立可执行进程启动，包含两个 Worker；Registry、Runtime、ToolHub、Knowledge、Indexer 的带认证就绪接口通过。
- 单独停止 ToolHub：中台显示该目录不可用，但 Registry 仍返回 5 个 Agent，业务仍返回原有 3 个发布入口。重新启动单个 ToolHub 成功。
- Runtime、Worker、Storage、Sandbox、Telemetry、ToolHub、Knowledge、Indexer 的数据库账号读取 public.secrets 均收到 PostgreSQL 42501 权限拒绝；Futures 的服务 Token 调用 Registry 凭证解析接口得到 HTTP 403。
- 完整 dump 恢复到隔离数据库；15 个资源版本、1 个 ToolHub 版本、1 个知识文件/分块及知识正文摘要匹配。这是迁移恢复验证，不是目标容量恢复耗时证明。
- 2026-10-11 Windows 空闲状态 11 个服务进程 Private Bytes 合计约 570.5 MiB，未包含 PostgreSQL、浏览器或运行中的 DSH。Windows Private Bytes 不能替代 Linux cgroup 常驻/峰值测量。

## Linux CI

PR #2 配置两个独立作业：

1. PostgreSQL + Go vet + `go test -race -count=1 ./...` + 两套前端构建。
2. 构建独立镜像，初始化服务身份，启动容器；Runtime/ToolHub/Worker 各两实例；检查数据库/API 拒绝、知识库版本隔离、MCP/Skill 检查、原文回读、Worker SIGKILL 接管、工具效果不重复、依赖停机降级、服务重启和数据库重连。保留 `linux-service-evidence` artifact 中的机器可读检查和资源样本。

第一次容器运行在进程重启测试处失败。前面的 Worker 接管与调用链检查已通过；失败原因是测试使用 `docker kill`，被 Docker 视为人工停用。已改为在容器内 SIGKILL 应用进程，并要求 RestartCount 增加及 health 恢复，不能只因原健康状态尚未刷新就判定成功。

[2026-10-11 Linux CI 38135670055](https://github.com/euler-gaozl/agent-os/actions/runs/38135670055) 两个作业全部成功，包含上述 9 组容器检查。该次小样本单任务测量共 25 个采样点，平台容器 Docker stats 内存口径的采样峰值合计 **194.2 MiB**，含 PostgreSQL 与 DSH，排除模型/MCP 夹具；CPU 上限配置合计 2 核、内存上限合计 2560 MiB。采样峰值不是连续测量峰值，不能据此外推生产容量。后续提交的状态以 [PR #2 检查](https://github.com/euler-gaozl/agent-os/pull/2/checks) 为准。

## 不在本轮证明范围内

- 多台物理服务器/VM 的节点宕机、数据库主备切换、跨机网络分区和灾备 RTO/RPO。
- 100 万文档 / 1000 万块的导入吞吐、检索 P95、索引磁盘空间与重建时间；当前小样本不外推。
- 真实 DeepSeek/OpenRouter 费用和输出质量；真实 Milvus/LightRAG/Embedding、生产 MCP、Docker sandbox daemon 和 Langfuse 联调。
- 完整租户/用户 RBAC、mTLS、细粒度凭证授权和安全扫描覆盖率。静态 Skill 扫描不证明代码或指令安全。
