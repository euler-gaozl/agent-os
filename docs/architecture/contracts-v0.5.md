# v0.5 服务边界与恢复契约

这是服务生产化的一个实施增量；生产上线验收以 `docs/production-readiness.md` 和 CI 原始记录为准。

## 所有权

| 服务 | 独立入口与状态 | 调用关系 |
| --- | --- | --- |
| Console | `cmd/control`；无数据库账号 | 聚合各服务；单个目录不可用时明确显示部分结果 |
| Futures | `cmd/futures`；无数据库账号 | 读取发布的 Agent、提交 Runtime 业务任务、读取结果 |
| Registry | `cmd/registry`；资源版本和加密凭证 | Agent/提示词/知识库配置；MCP/Skill 的权威是 ToolHub |
| ToolHub | `services/toolhub`；独立 `toolhub` schema/账号 | MCP/Skill 版本、包、检测、启停、验活、审计；执行请求转交 Runtime 的原子回执边界 |
| Runtime / Worker | 各自入口和账号；运行、租约、回执、DSH 记录 | Worker 使用固定 DSH；Runtime 保持本地效果和回执的事务原子性 |
| Knowledge / Indexer | `services/knowledge`；独立 `knowledge` schema、各自账号 | 原文件、正文、分块、索引队列；通过 HTTP 解析配置、凭证和运行绑定 |
| Storage | 独立入口/账号；运行资料读取与引用管理 | 与 Runtime 共用运行资料表，尚未形成独立数据库的事务协议 |
| Sandbox | 独立入口/账号；sandbox_jobs | 保留 Runtime fencing 检查；容器 daemon 需要专门隔离部署 |
| Telemetry | 独立入口/账号；事件导出游标 | 异步 Langfuse 适配；故障不阻塞 Agent 执行 |

一个仓库和 Go 模块便于原子修改接口，不等于一个部署进程。每个服务可单独构建、发布、停止和替换；基础服务镜像没有 Node、前端资产或 Docker CLI，只有 Worker 带 DSH/Node，只有业务和中台镜像带各自前端。迁移使用独立作业，服务进程不持有管理员数据库账号或 DDL 权限。

**现存耦合**：Runtime/Worker、Storage 和 Sandbox 仍共享部分执行事务表，部分实现还在 `internal/platform`；Registry 暂时保管知识库配置。不能宣称所有服务均可任意拆库。把本地效果与回执拆到不同数据库前，需要 outbox/inbox、资源 fencing 和恢复核对协议；本版优先保持原子性。

## ToolHub

- MCP/Skill 不可变版本；修改创建新 revision，绑定使用明确版本。
- 新登记资源先禁用；检测通过后需写入启用原因。停用立即阻止后续授权检查，不承诺撤销已发出的外部请求。
- MCP 仅支持固定的 2025-11-25 Streamable HTTP profile。验活执行 initialize/notifications/initialized/tools/list，不执行业务工具。发现的 schema 与已固定定义比较，定义变化或检查过期会阻断调用。
- 公网 endpoint 要求 HTTPS；私网/HTTP 要求 `MCP_ALLOWED_HOSTS` 精确 host:port 白名单。登记、发现、探测、实际执行均使用同一网络策略；拨号时解析并检查 IP，拒绝跳转和 URL 内嵌凭证。白名单由部署管理员维护，不由模型决定。
- Skill ZIP 在内存中有界解析，不解压到宿主目录。拒绝路径穿越、符号链接、可执行标志、压缩膨胀、重复路径和可疑凭证；要求根目录 SKILL.md。静态检查不能证明指令安全，启用前可分页审阅引用文件。
- 包内引用清单进入新任务快照，模型通过 `skill_file_read` 按绑定版本分页读取，并保留调用回执。包内脚本不会自动执行；任意执行仍须沙箱协议。
- 检测任务用数据库领取、30 秒租约和 fencing；10 秒探测超时，过期可接管。健康 MCP 每分钟检查，失败退避至最多 5 分钟；超过 5 分钟的健康结果不作为调用许可。静态 Skill 检查一次及手工复查，避免空转。审计记录状态变化和启停，最近检查时间持久化。
- `read_only` 是管理员对外部服务的声明，不是 MCP 自证安全。外部写调用回执未知时进入核对流程，不能盲目重试。

## 身份与资源边界

迁移为服务生成不同的随机 Token；入站配置仅保存各调用方 Token 的 SHA-256。每个容器只挂载自己的配置文件。业务 BFF 不能登记工具、修改平台资源、读取凭证明文或直接执行工具。运行服务仍是受信任核心，允许解析命名凭证；这不是按租户、用户、资源实例划分的完整 RBAC。

只有 Registry 获得 MASTER_KEY 和凭证表权限。其他数据库角色按表授权，ToolHub/Knowledge 使用各自 schema。传输当前适用于隔离网络，跨节点应加 TLS/mTLS 和网络策略，不能直接暴露内部端口。

HTTP 默认每实例 16 个并发请求；ToolHub、Knowledge、Storage 默认 4 个，限制解析/上传的瞬时内存；饱和立即 429，避免无界排队，可用 `HTTP_MAX_CONCURRENT` 显式调整。连接、响应头和整体请求有超时，JSON 请求 2 MiB。每实例数据库池默认 3（可设 2–16）连接；SQL 和空闲事务超时 15 秒。`/healthz` 仅表示进程活着；`/readyz` 验证本服务依赖的数据库；`/metrics` 提供请求/拒绝/异常/堆/协程指标。就绪不代表所有下游或模型余额可用。

## 知识库

每次上传最多 1 MiB；原文、正文、分块和元数据在同一库事务中保存。批量插入减少往返；文件列表支持 after 游标，无 N+1 读取。文件解析/Embedding 都有输入上限，暂不支持 PDF/OCR。外部导入保留 durable 状态；Milvus 使用稳定分块 ID；LightRAG 丢失回执进入 unknown，不能冒充可安全重试。

本地检索改为 PostgreSQL GIN + tsvector。中文用二字片段，拉丁文/数字用词；所有词 AND 匹配，并包含知识库版本范围。它是有界词法检索，尚无语义排序/复杂中文分词；单字中文查询明确拒绝。检索最多 8 条、64 个词、2 秒预算，版本与来源在数据库再次核对。原始文档读取需核对运行绑定的知识库 revision。旧分块每批 128 条增量回填，事务回滚可重试，不把全部资料载入模型内存。

## 部署与高可用边界

Linux Compose 具有非 root、只读根目录、进程/内存/CPU 上限、日志轮换和崩溃重启；Worker 默认两个。CI 额外运行 Runtime、ToolHub 的双实例，并注入实际进程 SIGKILL 和 PostgreSQL 停机。请求取消、租约丢失与优雅退出沿用 v0.4 的持久化协议。

常驻平台容器 CPU 上限合计 2 核，内存上限合计低于 4 GiB；构建、迁移作业、测试夹具、可选 Sandbox/Telemetry 和外部检索/模型不计入该合计。**设置上限不是容量验收**，每次 CI 保存真实内存样本。不能从单任务、小样本推出百万文档或生产并发能力。

Compose 的 PostgreSQL、宿主机及磁盘仍是单点。真正多节点上线还需数据库复制/故障转移、入口负载均衡、跨机密钥与制品分发、备份及恢复演练、网络分区测试。服务器未提供前保持“未验收”。

## 兼容性与升级

先备份并停旧服务，再运行 migrate-services；原 public 资料保留，Knowledge 以一次性 marker 导入，ToolHub 按原 ID/revision 导入并校验 hash。旧 MCP 重新检查后启用；旧 Skill 保留既有授权。新服务使用独立账号，禁止混跑拥有旧管理员连接的单体进程。

无 bundle 引用的历史 Skill 快照保持原有工具定义；新增 `skill_file_read` 只出现在包含文件清单的新快照中。DSH 内核依赖仍锁定 0.2.0-rc.2，旧任务不静默切换执行器。容器更新不得删除待恢复任务、版本或原始回执。
