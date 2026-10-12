# P2 独立源码与发布验收

2026-10-12。P2 进行中；本记录只覆盖首批三个服务，不代表 12 个服务或整个平台已完成。

## 所有权

`repos/agent-os-sdk` 只提供固定 DTO、工具协议、有界传输及服务传入策略的启动设施。SQL、迁移、路由权限和 schema readiness 归服务；SDK 不包含 recordstore、业务 SQL 或全平台角色权限表。

| 仓库 | 自有数据 | 跨服务依赖 | 当前状态 |
| --- | --- | --- | --- |
| [agent-os-registry](https://github.com/euler-gaozl/agent-os-registry/pull/1) | resources、secrets | HTTP ToolHub；可选 Runtime 心跳 | 独立源码、构建、迁移和 CI 通过；本机切换待验收 |
| [agent-os-sandbox](https://github.com/euler-gaozl/agent-os-sandbox/pull/1) | sandbox_jobs | HTTP Runtime；执行另需 Linux Docker | 同上；本机无隔离执行环境，明确不可用 |
| [agent-os-telemetry](https://github.com/euler-gaozl/agent-os-telemetry/pull/1) | telemetry_inbox、telemetry_exports | HTTP Runtime claim/ack、Registry 命名凭证、Langfuse | 同上；本机 exporter 尚未配置，不自动启用 |

每个仓库有独立 Go module、命令、镜像、服务配置例子、事务迁移和 PostgreSQL 测试。正常进程不做 DDL；迁移只改变本域表，在一个事务内提交表结构及授权，锁/语句超时有界。不重写其他服务配置或访问其数据库。Runtime/Worker 和 Knowledge/Indexer 后续保留必要的事务域，不以强拆事务伪造独立性。

## 可重复构建

SDK 固定 `v0.1.0-rc.2` / `f45ca168dee81f864533a8f77f8c203960caad1a`，规范 Go 模块校验值 `h1:SunD5Oyh1le4sv3CMJTpKCa0SsKBQDqXoBoAC0aji98=`。通过 Go 下载器从固定 Git tag 获取，三个消费者提交 vendor，构建时 `GOWORK=off`、`GOPROXY=off`、`-mod=vendor`；不依赖兄弟目录替换或给 CI 配个人跨仓库令牌。先前自制 ZIP 校验失败已保留并废弃，不能使用其缓存重新生成依赖。

`deploy/service-sources.json` 固定已拆服务的仓库和提交。集成构建要求 Owner HEAD 与锁一致、目录干净、完整 HTTP/data/tools/engines 合约一致；缺映射直接拒绝。构建时清理继承的 Go flags、环境文件、workspace、目标平台；生成后核验 Go 模块、SDK 版本、VCS 提交与 clean 标志，再次检查源码未变化。发布描述使用 Owner 合约及来源。其余未拆角色明确仍从集成仓库构建，不能宣称已经拆仓。

`scripts/Build-Services.ps1` 只创建候选完整包；激活仍由唯一发布 catalog 与维护事务完成。当前/上一版本保持 HTTP 和数据兼容才可自动回滚；跨 schema/config/协议变更仍需协调迁移。

## 已执行证据

- 三仓独立检出、空模块缓存、关闭网络依赖及 go.work：真实 PostgreSQL 18 隔离数据库、测试、vet、构建通过。`local/evidence/p2-isolated-checkouts-b32a6c1eab6944069bc621f042996e3b/result.json` 记录精确源码提交；验证集群已停止。仅有 3 个本模块 VCS 元信息缓存文件，没有下载依赖包。模型调用 0。
- 数据库验证包含重复迁移、事务 DDL 失败回滚、逐项 SELECT/INSERT/UPDATE/DELETE 授权、应用账号 readiness、跨域拒绝；Registry 旧资源版本与加密资料；Telemetry inbox 提交先于 ack，丢 ack 重投及身份漂移拒绝。Sandbox 测试用 HTTP Runtime 夹具，不冒充完整 Docker 执行。
- 独立仓库 CI（Linux PostgreSQL/race/vet/build/Docker，Windows unit/build）：[Registry 38251866324](https://github.com/euler-gaozl/agent-os-registry/actions/runs/38251866324)、[Sandbox 38251875960](https://github.com/euler-gaozl/agent-os-sandbox/actions/runs/38251875960)、[Telemetry 38251884643](https://github.com/euler-gaozl/agent-os-telemetry/actions/runs/38251884643) 全部成功。随后仅修改 release-contract 的新提交另行复验。
- 10 项源码选择/拒绝夹具通过，报告 `local/evidence/service-sources-3f7c444f20b04386b40dbe49050de974/result.json`；包含缺锁/映射、脏目录、错误提交、数据/工具/引擎协议漂移及路径逃逸。这是合成源码边界测试，不包含服务激活。
- 三个真实 Owner 在故意污染 GOENV/GOFLAGS/GOWORK/GOROOT/GOOS/GOARCH 的环境构建成功，调用方环境恢复，当前 catalog 字节未变：`local/evidence/owner-build-environment-66a9f1acb4384648a3f4850a0fa34cfa/result.json`。修复可选 JSON 属性访问后，在 StrictMode Latest 下再次构建三仓通过，候选 `4aa0d6cdbc074a8dbd1a6fe35a87fac8`。这两批明确标记 development，未激活。
- 独立评审仅做静态复核。发现并修复凭证环境泄露、Telemetry 默认端口冲突、SQL 权限测试 OR 语义、缺锁静默回退、合约字段遗漏、构建环境污染和 StrictMode 可选字段问题；评审不替代上述实测。

## 已部署的安全修复

旧集成 Registry 的凭证解析会接受任意同名进程环境变量；新旧源码均已限制保留名，只允许明确的三个旧供应商环境变量兼容，其余使用加密凭证表。集成 `bb9a693` 已单独部署，非目标 11 个进程不变，Doctor 正常；真实内部配置名请求返回 400，未读取响应正文。证据 `local/evidence/credential-rpc-live-bb9a693.json`。本次 Owner 发布回滚基线必须是这个安全版本，不能退回此前版本。

独立 Owner 实际更新/回滚证据随后追加。服务端 HA、真实跨节点故障和未配置扩展不在本批证明范围内。
