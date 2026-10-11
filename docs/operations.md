# 本地运行与恢复

当前工作目录是 `D:\workspace\agent-os`。数据库、日志、备份、构建产物均在此目录的忽略路径中。要求 PowerShell 7；脚本使用现代 .NET 随机数 API。

## 本机工具与启动

已安装的 Go：`D:\workspace\.tools\go\bin\go.exe`，PostgreSQL：`D:\workspace\.tools\postgresql\pgsql\bin`。Node 与 pnpm 使用 Codex 现有运行环境，未复制项目到 C 盘：

```powershell
Set-Location D:\workspace\agent-os
$env:GOPATH = 'D:\workspace\.tools\gopath'
$env:GOCACHE = 'D:\workspace\.tools\gocache'
$env:PATH = 'D:\workspace\.tools\go\bin;C:\Users\MSI\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin;' + $env:PATH
$pnpmCommand = 'C:\Users\MSI\.cache\codex-runtimes\codex-primary-runtime\dependencies\bin\fallback\pnpm.cmd'
./scripts/Initialize-Local.ps1
go build -trimpath -o bin/agentos.exe ./cmd/agentos
& $pnpmCommand --dir harness install --frozen-lockfile
& $pnpmCommand --dir web install --frozen-lockfile
& $pnpmCommand --dir web run build
./scripts/Start-Local.ps1 -Workers 2
```

`Initialize-Local` 只在不存在时创建配置和集群，不覆盖已有密码。配置保存在 `.state/dev.json`，不要打印或提交。数据库绑定 `127.0.0.1:55432`，使用 SCRAM。`Start-Local` 自动迁移、登记缺失资源，拒绝端口冲突或重复启动；进程清单记录 PID、路径和启动时间。

`Stop-Local.ps1` 仅停止清单中路径/时间匹配的本项目进程，保留 PostgreSQL 和资料。关闭任务进程相当于中断执行，重新启动后等待租约过期接管。Windows 强制结束不会假装业务已撤销。若需停止数据库，确认没有其他正在使用该集群的任务后运行 PostgreSQL 的 `pg_ctl -D .state/postgres -m fast stop`。

## 配置 Agent 和业务入口

1. 中台 ToolHub 导入 Skill Markdown/文本或 JSON 资源。MCP 需填 Streamable HTTP endpoint，可发现工具 schema；仅把真实只读服务标为只读。
2. 知识库选择本地、Milvus 或 LightRAG；上传资料，等待状态变为“可检索”，先用检索测试确认来源正确。
3. 自定义 Agent 绑定资源，写角色提示词，配置模型 base URL、模型名称和凭证名称。保存产生新版本。
4. 右侧试运行使用真实服务；无模型凭证会明确失败，不返回演示答案。试运行会保存版本和任务记录。
5. 在 Agent 的“发布”页填写业务显示名称和说明，开启期货工作台发布并保存。已开启发布时按钮为“保存并发布”，业务入口立即使用新版本；关闭并保存撤下入口。任务参数为品种、时间范围和研究问题。
6. 运行详情显示实际执行器，并可下载完整 DSH 事件记录。中断后从持久化响应重放，已完成工具不重复执行。

DSH 使用 Node 24；可通过 `AGENTOS_NODE` 指定完整可执行文件路径，已有本机配置已写好。依赖固定在 `harness/pnpm-lock.yaml`，升级前必须验证重放兼容。v0.3 升级时先停止旧 Worker，再执行迁移与启动；不要混跑新旧 Worker。

第一批业务包位于 `packs/`。启动只补缺失资源，避免覆盖用户编辑。当前本机通过界面上传了研究方法文档，并把期货 Agent 保存为 v2；这不是市场基本面资料库。新环境种子包为 v1，不携带个人本地数据。

## 模型和凭证

中台“模型与凭证”写入命名凭证，例如 `DEEPSEEK_API_KEY`。凭证在数据库中 AES-GCM 加密；环境变量优先于存储凭证，`MASTER_KEY` 只在本机配置。API 不回显明文。更换 MASTER_KEY 前必须设计重加密迁移，不能直接换值，否则已有凭证无法解密。

新环境默认模型是 `deepseek-flash`；迁移保留用户已有模型配置。传输为 DeepSeek 的 OpenAI-compatible chat/completions；没有内置账户或 API Key。可换兼容服务，但模型调用、工具 schema 与返回结构需要实际验证。默认 readiness 只检查 DeepSeek 凭证是否存在，不代表服务网络、余额或某个自定义模型已经可用。

本地使用 `DEV_LOCAL=1` 时入口限回环并校验来源；不要改成公开地址。远端部署用独立 `SERVICE_TOKEN`、`ADMIN_TOKEN`、`BUSINESS_TOKEN`（至少 32 个随机字符），以及 HTTPS 反向代理。当前没有企业账号/RBAC，不能直接作为多人公网平台。

## 知识库导入与恢复

支持 UTF-8 TXT、Markdown、CSV、JSON 和 DOCX 正文，单文件 1 MiB；不支持 PDF/OCR 或表格结构化抽取。原文件、正文、来源、分片都保留。默认本地引擎是字面关键词检索，不是语义 RAG。

Milvus 配置 REST endpoint、Embedding `/embeddings` 兼容服务、模型、维度和可选 query prefix；导入后检查维度与来源回查。模型/维度改变应创建新知识库版本并重新导入。失败 upsert 可以调用中台代理 `POST /api/knowledge/files/{id}/retry`，因为 chunk id 稳定。

LightRAG 自己配置生成模型和 Embedding，本平台通过 `/documents/text`、`/documents/track_status/{track_id}` 和 `/query/data` 接入。每个库版本必须专用 endpoint/workspace；不要将两个版本别名路由到同一个实际工作区。图谱提取结果是派生信息，检索仍需回查来源。上传回执丢失会标为 unknown，核实外部 track id 后调用 `POST /api/knowledge/files/{id}/reconcile`，JSON 为 `{"track_id":"已核实的ID","evidence":"核对方法与出处"}`。当前这些异常操作提供 API，界面显示状态/错误但没有专用核对表单。

模型任务的 unknown 需要从中台运行详情按实际外部回执核对。不要因为界面看不到结果就直接重复执行外部写工具。

## 备份与恢复验证

```powershell
./scripts/Backup.ps1
./scripts/Verify-Backup.ps1 -BackupPath D:\workspace\agent-os\.state\backups\实际文件名.dump
```

备份是 PostgreSQL custom dump，包含原文件 bytea、引用、资源和运行记录。验证脚本创建本次独有的 `agentos_restorecheck_<UUID>` 数据库、恢复并检查原文件 SHA-256 和引用，再只清理自己创建的验证库，不覆盖正式数据库。

把备份和 MASTER_KEY 的保护副本放到独立介质；同盘备份不能抵抗整盘故障。Milvus/LightRAG 存储不在 dump 内，可从保留原文重建，但还需要相应服务自身的备份策略。此次验证数据量很小，不代表容量或 RTO 承诺。正式灾备应先恢复到新数据库并核验，再显式切换 DATABASE_URL；不要直接清空现有库。

## 多实例与容器

本地 `-Workers 2` 已运行；`-Workers 1..16` 改变 Worker 数量。每个服务连接池最多 8 个连接；增加实例前应按 PostgreSQL 连接上限和实际负载调整，16 个进程并不意味着数据库可承受满池连接。

提供 Compose 服务和 Nginx 网关。配置 `.env.example` 中的独立随机值后，可在装有 Docker 的环境使用 `docker compose up --build --scale worker=2 --scale control=2 -d`。共享数据库仍是单点，Compose 未在本机验证。不要把占位符当有效凭证。

Sandbox 使用可选 `sandbox` profile，必须设置带 `@sha256:` 的 Node 镜像和专用 Docker socket；容器网络禁用、只读、非 root、资源受限，broker 本身仍有 Docker 管理权限。所有 sandbox 副本必须共用同一个 daemon。未配置时返回不可用，不运行宿主命令。

Langfuse 使用可选 `telemetry` profile，配置 URL 与 `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY`。当前导出持久化事件为 OTLP spans，不是完整 SDK 会话、费用分析或在线监控。

## 验证命令

```powershell
$env:TEST_DATABASE_URL = (Get-Content .state/dev.json -Raw | ConvertFrom-Json).DATABASE_URL
go vet ./...
go test -count=1 -v ./...
```

测试每次使用随机独立 schema 并清理。没有 TEST_DATABASE_URL 时数据库测试会跳过，不能把该结果写成真实数据库测试通过。GitHub Actions 配置 Linux + PostgreSQL + `-race`；远端运行状态以实际 CI 为准。
