# v0.5 构建、部署和恢复

本机正式目录 `D:\workspace\agent-os`，原始资料和配置保持在 D 盘。使用 Go / TypeScript；Worker 加载固定版本的官方 DSH 核心包。

本文件的 v0.5 历史部署示例仍保留；当前服务所有权、单服务升级顺序见[独立部署契约](independent-deployment.md)，最新真实供应商、容量与故障结果见[交付账本](delivery-v0.6.md)。历史“未完成”描述以该账本中较新的明确复验为准。

## Windows

### 当前本机维护入口（2026-10-12 更新）

运行配置、发布文件、进程记录、日志已归入 `D:\workspace\agent-platform\local`。本机源码目前仍在 `D:\workspace\agent-os`，数据库仍在该源码目录的 `.state\postgres`；物理搬迁尚未执行。不要因为新 local 目录存在就手工移动运行中的数据库。

```powershell
./scripts/Platform.ps1 status
./scripts/Platform.ps1 doctor
./scripts/Platform.ps1 start -Workers 2
./scripts/Platform.ps1 stop                 # 保留数据库
./scripts/Platform.ps1 stop -WithDatabase   # 所有登记部署停下后才停本机数据库
./scripts/Platform.ps1 backup -Pnpm $pnpmCommand
./scripts/Platform.ps1 restore-check -BackupDirectory 'D:\workspace\agent-platform\local\backups\<备份名>' -Pnpm $pnpmCommand
```

源码中的 `.local/layout.path` 被 Git 忽略，指向本机 `ops/layout-<uuid>.json`。也可给脚本传 `-LayoutPath`。不要覆盖旧布局文件；切换用 `Activate-WorkspaceLayout.ps1`，准备路径用 `Prepare-WorkspaceLayout.ps1`，二者会验证已恢复备份、固定版本与配置。当前准备脚本是本次从旧目录分离状态的迁移入口，并非新用户的一键安装器。

`backup` 在共同维护锁中停止当前实例，备份全部配置所指向的同一 PostgreSQL 集群内权威数据库，保留 DPAPI 配置密钥和离线运行依赖，再恢复原角色与 Worker 数。失败与重启失败分开报告。`restore-check` 新建隔离集群，核对数据、权限、账号和加密凭证，不启动 Worker、不调用模型。DPAPI 需要原 Windows 用户配置文件；它不覆盖重装系统后恢复。不要在维护期间手工直连写库。

单服务 update/rollback 的本机统一入口仍待实现；下面是保留的历史操作流程，不把手工更换二进制计为已经完成新的发布闭环。

### 历史初始化与发布示例

首次环境初始化仍使用 `Initialize-Local.ps1`；它不覆盖已有密码。先安装 `harness`、`web` 的 lockfile 依赖，构建前端，然后：

```powershell
Set-Location D:\workspace\agent-os
./scripts/Build-Services.ps1
# 升级数据库和权限前先备份、停止旧进程
./scripts/Backup.ps1
./scripts/Stop-Local.ps1
./scripts/Start-Local.ps1 -Migrate -Workers 2
```

普通代码更新可以只替换一个服务：

```powershell
./scripts/Build-Services.ps1 -Service toolhub
./scripts/Stop-Local.ps1 -Service toolhub
./scripts/Start-Local.ps1 -Service toolhub
```

构建目录按 release 分开，成功后更新 `bin/current.json`，不会覆盖 Windows 正在执行的二进制。停止脚本核验 PID、完整路径和启动时间。旧 release 暂时保留用于回退；涉及 schema/协议变更时不能盲目回退二进制。

控制台 8090，业务端 8098；Registry 8096，Runtime 8094，ToolHub 8091，Knowledge 8095，Indexer 8097，Storage 8092，Sandbox 8093。仅绑定本机回环。Windows 开发脚本不提供系统服务级崩溃重启，运行任务可以重新启动后由 Worker 租约接管；Linux Compose 有进程重启策略。

管理员配置 `.state/dev.json` 仅供初始化/迁移；运行进程只读 `.state/services/<role>.json`。`identities.json` 保留受保护的服务 Token 原件，运行服务只获取自己 Token 和入站哈希。**不要打印、上传或提交这些文件**。MASTER_KEY 与数据库 dump、服务配置均需保护和备份；不能直接换 key，否则旧凭证不可解密。

新环境不会自动把种子模板发布为业务服务。在中台导入需要的 `packs/` 资源，完成 Skill 检查/启用后配置和发布 Agent。已有本机 5 个 Agent、3 个发布入口和研究方法知识文件保留。

## Linux Compose

从 `.env.example` 创建私有 `.env`，把占位符替换成各自独立的随机值；数据库密码应使用 URL-safe 字符。安装 Docker Compose 后，在仓库根目录执行：

```sh
sh scripts/Start-Linux.sh
```

脚本构建镜像、启动 PostgreSQL、运行一次迁移、启动常驻服务。原有环境升级前先做 dump 并停服务；禁止正在运行时重写身份配置和跨域迁移。每个容器只挂载自己的私有配置文件，迁移作业拥有初始化权限；平台常驻服务没有管理员数据库权限。

仅把中台和业务端口映射到宿主机回环。远程使用需自行部署 HTTPS 入口；容器内部目前使用隔离网络 HTTP，跨机器需要 TLS/mTLS。Token 是服务身份控制，不等于企业多租户 RBAC。

单服务重建示例：

```sh
docker compose build toolhub
docker compose up -d --no-deps toolhub
# 增加副本前核对连接、CPU和内存总预算
docker compose up -d --scale worker=2 --scale toolhub=2 --scale runtime=2
```

基础配置每个服务独立镜像，只有 Worker 带 Node/DSH。默认双 Worker 的平台常驻 CPU 上限合计 2 核、内存上限合计 2.25 GiB（包括 PostgreSQL）；这只是限制配置，峰值和吞吐以测量为准。增加副本也增加总上限。大规模资料需要另计磁盘、索引、备份和外部 Milvus/LightRAG/Embedding。

Sandbox/Telemetry 默认不启动。Sandbox 必须配置专用隔离 daemon 和带 digest 的镜像；不要为了跑通而直接挂宿主 root Docker socket。Telemetry 需配置 Langfuse URL 和命名凭证，当前是异步事件导出适配，未完成真实供应商联调。

## ToolHub 和知识库

Skill Markdown/JSON/ZIP 上传后先检测、审阅并填写启用原因。ZIP 引用文件可在“检测与启停”面板分页阅读，Agent 通过版本绑定的 `skill_file_read` 回读。包内脚本不直接执行。

MCP 先填写 Streamable HTTP 地址，发现并固定工具 schema，再检测与启用。私网服务需在受保护部署配置 `MCP_ALLOWED_HOSTS` 填精确 host:port；不要使用通配符或关闭 IP 检查。断连、定义变化或健康检查过期会阻止后续调用，结果未知的外部写操作须核对回执。

知识库每文件最多 1 MiB；支持 UTF-8 文本与 DOCX 正文，不支持 PDF/OCR。本地引擎是带 GIN 索引的词法检索，中文采用二字片段。原文、分块、版本和来源一起留存。Milvus/LightRAG 适配与异常回执处理沿用 [v0.4 操作说明](operations.md)，当前没有实测百万文档容量。

## 验证和备份

```powershell
$env:TEST_DATABASE_URL=(Get-Content .state/dev.json -Raw|ConvertFrom-Json).DATABASE_URL
go vet ./...
go test -count=1 ./...
./scripts/Backup.ps1
./scripts/Verify-Backup.ps1 -BackupPath D:\workspace\agent-os\.state\backups\实际备份.dump
```

备份覆盖 PostgreSQL 中的全部 schema 和原文件；不包含 Milvus/LightRAG 外部索引。恢复到隔离数据库验 hash 后再决定切换，不能清空原库。服务配置和 MASTER_KEY 单独保护，PostgreSQL 角色也需要在新集群重建；同盘备份不能抵御磁盘故障。

CI 的 `scripts/smoke-services.mjs` 专用于一次性 Compose 测试项目，里面会终止进程、停止数据库；禁止对正式本机实例或生产数据运行。Linux CI artifact 提供原始检查结果和 Docker 资源采样。真实节点/数据库 HA 仍需服务器环境验收。

## 磁盘容量故障处理（v0.6 增量）

已识别的数据库容量/连接故障返回 503，查询超时返回 504；503 的 Retry-After 是服务恢复提示，不证明刚才的写入没有提交。Runtime 的笔记效果与回执仍以同库事务为权威；Storage 同内容/引用根重传幂等。外部工具 UNKNOWN 必须查证效果后核对，不能因恢复了磁盘就直接重复执行。

处理顺序：暂停受影响域的新写入和批量导入 → 检查实际挂载卷、配额与数据库错误 → 扩容或清理明确归属的临时资料 → 等待每个独立数据库连接池重新就绪 → 在任何重试前只读核对故障前的资料、哈希、引用和回执 → 按原逻辑操作 ID 恢复。不要删除 PostgreSQL 数据文件、WAL、正式来源、仍被引用的产物或未决任务记录来腾空间。Runtime 与 Storage 两个连接池都要重新就绪；只验证其中一个不能代表另一个已经重新连接。

`Persistent storage faults` 工作流使用一次性 192 MiB tmpfs 卷，检查实际 ENOSPC，并在同卷恢复 PostgreSQL 后检查旧资料和重试。这项测试不挂载宿主资料目录，只允许在 disposable GitHub CI 运行。不得在正式数据上复用填充磁盘步骤，也不能将其当作物理断电、数据库损坏、跨机 HA 或特定环境 RPO/RTO 的证据。
