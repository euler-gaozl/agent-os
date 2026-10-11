# 独立服务部署与版本边界

每个后端服务有独立镜像、身份、配置和发布单位，共用 Console 中台 Web。Futures 是独立业务入口。代码在同一仓库中维护；一次服务发布不要求构建或替换其他镜像。以下流程已实现，实际验收以 Linux CI 的 `independent-release.json` 为准。

## 服务和状态归属

| 服务 | 端口 / Docker 构建 target | 状态及迁移责任 | 运行依赖 |
| --- | --- | --- | --- |
| Registry | 8096 / service | resources、secrets | 本域 PostgreSQL；解析 MCP/Skill 时调用 ToolHub |
| ToolHub | 8091 / service | toolhub schema | 本域 PostgreSQL；命名凭证由 Registry 解析；业务执行转交 Runtime |
| Knowledge | 8095 / service | knowledge schema | 本域 PostgreSQL、Registry 配置/凭证；原文授权需要 Runtime |
| Indexer | 8097 / service | 消费 Knowledge 的 schema，不能自定不兼容迁移 | Knowledge 数据、Registry；按选型调用外部 RAG |
| Sources | 8101 / service | sources schema | 本域 PostgreSQL、管理员白名单中的公开网站 |
| Runtime | 8094 / service | 运行、调用、事件、业务任务与实例 | 执行库、Registry、按工具绑定调用下游 |
| Worker | 8099 / worker | 消费 Runtime 运行状态；固定 DSH 和 Node | 执行库、Registry、ToolHub、所绑定的工具与模型 |
| Storage | 8092 / service | documents、artifacts、artifact_refs | 执行库；这些表当前仍参与 Runtime 的本地事务 |
| Sandbox | 8093 / sandbox | sandbox_jobs | Runtime 授权 HTTP API、专用隔离 Docker daemon |
| Telemetry | 8100 / service | 本域 telemetry_inbox、telemetry_exports | Runtime 事件投递 API、Registry 中的凭证、Langfuse |
| Console | 8090 / control | 无数据库 | 聚合服务 HTTP API |
| Futures | 8098 / futures | 无数据库 | Registry 发布目录和 Runtime 任务 API |

所有服务的实例心跳写入 Runtime；心跳失败不阻止其他服务提供本域功能。端口不代表必须映射到公网。独立部署允许不同主机和不同服务版本，但必须保留上表的依赖与兼容性。

**尚未完成的数据解耦**：Runtime/Worker 直接读写执行库；Storage 资料效果与 Runtime 回执共用事务。当前拆分了部署和 DDL 所有权，不能因此宣称这些服务可分别迁到任意数据库。后续拆库必须先实现效果 outbox/inbox 和恢复核对协议。ToolHub、Knowledge、Sources 已有独立 schema 及 HTTP 边界，可以为它们配置独立 PostgreSQL，但迁移历史资料和跨库灾备还需专项验收。

Telemetry 新版无跨域 SQL：Runtime 的事务事件行同时是 outbox，`POST /v1/telemetry/claim` 每次最多 32 条、租约 30 秒并递增 fence；接收端在自己的 inbox 提交后才调用 ack。逐行投递标记避免序号较小的晚提交事件被最大游标跳过。重复 inbox 必须具有相同事件身份；过期实例回执会被拒绝。事件接收与批量导出各有一个有界循环、超时和错误退避，Runtime 故障不阻止导出已接收事件。外部 OTLP 为至少一次投递，使用稳定 trace/span ID；不能承诺第三方端恰好一次。导出的内容仅为事件标识、类型和时间。

先升级 Runtime schema 和 Runtime，再迁移 Telemetry schema、部署 Telemetry，最后撤销其旧 `events` SQL 权限；全新初始化已采用最小权限。历史 `telemetry_exports` 保留并用于跳过已导出的记录；迁到独立数据库时必须搬迁这张表与完整 inbox。回滚到旧跨域 SQL 导出器需要恢复旧数据库连接和只读需求对应的权限，不属于无需准备的普通回滚。独立库灾备必须协调 outbox/inbox 恢复点：单独恢复较旧的 inbox 备份会缺少 Runtime 已确认的事件，需要从保留的执行事件重新投递；本版不自动 GC 事件或回执。

Sandbox 新版只需要自己的作业表，通过 Runtime 的 `POST /v1/sandbox/authorize` 校验持久化调用意图、参数摘要、绑定工具、fence、规则版本和取消状态。等待作业锁后再次校验；Runtime 不可用时拒绝启动新执行。部署顺序是先升级 Runtime，再升级 Sandbox，最后撤销 Sandbox 对 `public.runs` 的旧权限；初始化作业已采用新权限。回滚到使用跨域 SQL 的旧 Sandbox 前需要恢复对应旧配置/权限，不能把协议迁移当作普通兼容发布。实际独立库迁移时要保留完整 sandbox_jobs 和确定性容器 ID，不得丢弃待核对作业。

Sandbox 的工作负载镜像与 HTTP 服务镜像分开。使用 `deploy/sandbox-runtime.Dockerfile`，将可信 Node 基镜像 digest 作为 `NODE_BASE` 构建，然后把生成的不可变 `sha256:…` image ID（仅同一 daemon 有效）或推送仓库后的 `repo@sha256:…` 配置为 `SANDBOX_IMAGE`。普通 Node 镜像不再满足新版运行契约；缺少 guard 会失败，不能回退到宿主机执行。

guard 为容器内可信 Go 程序，UID 0，仅有 SETUID/SETGID 用于启动 UID/GID 65534、无额外组权限和零 capabilities 的 Node 子进程；不授予 CAP_KILL。执行代码与守护程序不同身份，不能向 guard 发 SIGSTOP/SIGKILL。guard 在 30 秒退出容器主进程，init 退出时整个 PID namespace 的后代被销毁；broker 仍保留 35 秒持久化截止与恢复器。只读根目录、网络关闭、128 MiB/0.5 CPU/64 PID 及 16 MiB 临时目录继续约束整个容器。此前同 UID 的 BusyBox timeout 仅验证了普通死循环，不能用于证明抵抗主动干扰截止进程；新版必须通过 Linux 容器信号攻击与 broker SIGKILL 联合验收。Docker 共享宿主内核，仍不是面向恶意多租户的虚拟机隔离。

## 构建和发布单个服务

以 Knowledge 为例；`release-service.mjs` 接收已经构建或拉取到本机的镜像，将标签解析为本机不可变 image ID 后部署。发布记录只保存路径、配置摘要和镜像 ID，不保存凭证。

```sh
docker build --target service --build-arg SERVICE=knowledge -t agent-os-knowledge:release-1 .
node scripts/release-service.mjs deploy \
  --project agentos-knowledge-prod --service knowledge \
  --image agent-os-knowledge:release-1 \
  --config /srv/agent-os/config/knowledge-v1.json \
  --network agentos-private --replicas 1
node scripts/release-service.mjs status --project agentos-knowledge-prod
node scripts/release-service.mjs rollback --project agentos-knowledge-prod
node scripts/release-service.mjs stop --project agentos-knowledge-prod
```

网络、数据库、下游地址和服务身份由运维预先配置。启动入口仅使用 `deploy/service.compose.yaml`，没有数据库容器或 `depends_on`；不会隐式启动、升级其他服务。`--network` 是已存在的私有 Docker 网络；跨宿主机网络及 TLS/mTLS 由部署基础设施提供，这个 Compose 文件本身不是跨机集群。

配置文件必须让运行容器的 UID 10001 可读，并让发布操作员可读以校验摘要；不授予其他用户读取权限。配置内容参照初始化生成的每服务配置，HTTP 下游使用服务 DNS 或负载均衡地址。控制台还需 `SOURCES_URL`。运行配置不得包含数据库管理员账号；只有 Registry 获得 MASTER_KEY。

相同项目名再次 deploy 可以换镜像、配置路径、实例数量。使用不可变的版本配置文件，保留前一版本；修改原配置文件后脚本会拒绝自动回滚，避免拿旧二进制配未知配置。发布先等待 `/readyz`，失败自动恢复前一镜像及副本数；初次发布失败只清理本发布单位。并发发布有文件锁。操作员进程被强杀时锁会保留，须确认进程已退出、检查容器和发布记录后解除；尚不承诺操作员断电时发布控制器自动续传。

只有 Console/Futures 可通过 `--publish 8090` / `--publish 8098` 映射宿主机回环端口；单机固定端口只支持一个实例。多个网关实例应使用独立负载均衡。增加副本会增加连接数、CPU 和内存总预算。单服务 Compose 替换有短暂切换窗口；**不是零停机或物理节点 HA 的证明**。

## 数据库迁移

首次初始化/历史跨域导入仍使用 `migrate-services --output`，需要维护窗口。日常单服务升级改为：

```sh
# 专用迁移容器，只挂载所需的管理员/DDL 配置；不挂载所有服务配置目录。
docker run --rm --network agentos-private --read-only --cap-drop=ALL \
  -v /srv/agent-os/config/knowledge-ddl.json:/run/ddl.json:ro \
  --entrypoint /app/service agent-os-migrate:release-1 \
  --config /run/ddl.json --service knowledge
```

迁移配置仅需 DATABASE_URL；`--service` 不重写配置、不生成/轮换身份、不重导历史数据。Knowledge/Indexer 对应同一个数据域；Runtime/Worker 也是同一个域。Registry、Storage、Sandbox、Telemetry 的 SQL 已按所有权拆分，Bootstrap 仍按依赖顺序执行全部 SQL。Sources/Knowledge/ToolHub 迁移各自加数据库锁；执行域升级与历史初始化互斥。

迁移设置 3 秒锁等待、单语句 120 秒、总计 3 分钟预算，不能无界阻塞在线服务。新增大索引可能超过该预算，需要为该版本安排独立索引构建/维护流程；不能通过取消超时硬顶生产负载。升级采用先兼容扩展、再发布消费者、最后单独清理旧字段的步骤。自动回滚只回滚程序，不逆向删除 schema 或用户资料；破坏性 schema 变更不适用该流程。

Windows 可在备份后直接执行新的迁移二进制 `--config .state/dev.json --service knowledge`，不必经过要求全停的历史 `Start-Local.ps1 -Migrate`。然后使用 `Build-Services.ps1 -Service knowledge`、`Stop-Local.ps1 -Service knowledge`、`Start-Local.ps1 -Service knowledge` 单独替换。

## 验收范围

新增 Linux CI 使用真实旧版本 Knowledge 二进制 `a0d6c81` 验证迁移后的数据读取、单服务升级、回滚、两副本、错误镜像发布失败后恢复。断言其他服务容器 ID 不变，所有身份配置字节不变。模型使用受控夹具，不消耗真实 API。共享执行库拆分、跨机故障转移、每个历史版本的兼容矩阵仍单列未完成；不能用 Knowledge 一项结果代替所有服务的版本兼容验收。
## 有界资源目录升级

中台使用 `GET /api/catalog`，Registry 提供 `/v1/catalog`，ToolHub 提供 `/v1/assets/catalog`。支持 `kind`、名称/ID 子串 `q`、`after` 和 `limit`（1–100），返回 `items`、`next_cursor`；中台另返回各来源的 `services` 状态。摘要带 `summary:true`，不能提交为资源定义。完整版本继续通过既有按 kind/id/revision 的详情接口读取。

先分别执行 Registry、ToolHub 的 scoped migration，再更新这两个服务，最后更新 Console。索引迁移不改正文与资源版本，旧服务仍可读；回滚只回滚镜像，保留兼容的新增索引。目录短暂不可用会明确显示来源状态，部分结果不能推进游标，防止跳过离线服务的数据。

兼容的 `/api/resources` 完整定义列表也已停止自动读取全部页，返回 `next_cursor`；旧调用方须逐页读取，最后可能需要一次空页请求。单次来源列表最多 100 项并按 2 MiB 总预算停止（至少允许一个完整资源）；它用于旧管理脚本，新 UI 必须使用摘要接口。资源目录翻页不是数据库快照：并发修改名称或新增资源时应刷新第一页；执行仍绑定明确版本。
