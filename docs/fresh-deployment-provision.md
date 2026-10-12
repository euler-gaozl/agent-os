# 全新部署的数据库与身份初始化

`cmd/provision` 是集成层的 Linux 初始化工具，只建立八个数据域数据库、十个应用登录角色、一个 NOLOGIN 数据库拥有者和十二份独立服务配置。它不导入业务包，不创建业务表，也不调用模型。Worker 与 Runtime 共用执行域，Indexer 与 Knowledge 共用索引域；两个 Web BFF 无数据库身份。迁移和表级授权仍由各 Owner 的 `migrate` 执行。

本入口仅支持全新部署。现有 Windows 安装继续使用 `ops/Platform.ps1` 和已记录的发布、升级及恢复流程。CLI 在读取计划和写文件前拒绝非 Linux；Windows 上的内部隔离测试使用生成的测试身份，不表示提供了 Windows DACL 支持。

## 输入与输出

先准备仅当前管理员可读写的计划文件（0600）及输出目录（0700），然后执行：

```sh
go build -trimpath -o provision ./cmd/provision
./provision --plan /private/deployment-plan.json --output /private/bootstrap
```

计划固定为 format=1，包含 `prefix`、`admin_database_url`、不同的 `admin_token` / `business_token`、32 字节十六进制 `master_key`、十二个服务的 `endpoints` 及可选的按服务白名单配置 `options`。计划最多 64 KiB；必须是私有普通文件，拒绝符号链接、多 JSON 对象、未知字段和连接身份覆盖参数。管理连接必须显式指向 `/postgres` 维护库，带明确 `sslmode`；管理员需有创建角色、数据库和检查集群身份的权限。

`prefix` 限制为 `agentos_` 开头的短标识。所有数据库和角色都带这个前缀。独立随机服务 Token 及数据库密码先持久化到 `provision.json`，再执行对应数据库操作。输出还包括各服务配置、`identities.json`、`migration-targets.json`；均含机密，不能提交、上传 CI artifact 或作为诊断日志打印。

`ready.json` 只证明身份、数据库、连接权限和实际密码认证已核验，明确记录 `application_migrations: "not performed"`。它不是应用就绪证明。当前 Owner migrator 编排和 Registry HTTP 初始化仍待接入；不能仅运行此命令就声称服务已可用。

## 恢复规则

- 输出目录独占文件锁与固定维护库的部署锁共同串行化运行。检查点绑定计划摘要、PostgreSQL 集群标识及角色/数据库对象 ID。
- 意图先落盘，角色创建及归属注释原子提交；数据库先以专有 NOLOGIN 拥有者创建且禁止连接，收紧权限后才开放。阶段退出可用同一计划、同一检查点重试。
- 已确认的对象消失、换了对象 ID、密码或权限漂移，均拒绝继续。不会重新建库、轮换身份、悄悄撤销额外授权或解除管理员暂停。
- 无检查点时不接管已有同名前缀对象。输出配置被修改时拒绝覆盖；缺失的派生配置可从保留的身份恢复。原始检查点及计划必须纳入受保护备份。
- 每个应用身份实际登录自己的数据库，再用错误密码验证 PostgreSQL 确实拒绝认证。连接只授予本数据域，不以 PUBLIC 默认 CONNECT 为前提。

## 已执行证据及边界

2026-10-13，Windows 上启动全新隔离 PostgreSQL 18（55592），执行内部数据库恢复套件通过。最新报告 `local/evidence/provision-fixture-5b7fbee6ff654623bff5b9f9f43f4dbf/result.json`；数据库测试 13.70 秒，隔离集群已停止，供应商调用 0 次。覆盖阶段回调退出、真实终止 PostgreSQL 维护会话、同目录/同前缀并发、80 项数据域 CONNECT 对比、十个身份认证、密码/角色/数据库替换、额外授权及管理员暂停的拒绝行为。八个数据库均无业务表。

独立评审静态复核并关闭了数据库权限漂移和 Windows 私有文件权限两项阻断；评审者没有代跑上述测试。[Linux 初始化 CI 38283706152](https://github.com/euler-gaozl/agent-os/actions/runs/38283706152) 在提交 `12666112f7941039f7c2a64b7d16ab64e5149fe4` 已通过：真实 PostgreSQL、race、Linux 文件权限及实际 CLI 构建。现有故障证据是阶段退出及数据库会话终止，不是应用 SIGKILL 或断电恢复，亦不是八个 Owner 迁移后的完整服务链路。
