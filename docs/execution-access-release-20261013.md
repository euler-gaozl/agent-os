# 执行库权限兼容的 Windows 发布保护

2026-10-13。继[Owner 权限退役候选](runtime-access-retirement-20261013.md)，本轮实现启动、更新、回退及 pending 恢复的数据库权限保护，已通过隔离数据库与真实进程故障测试。**正式权限尚未收缩，新服务二进制尚未安装**；这是正式收缩前的发布控制增量，不是完整 P2 或 Goal 完成。

## 兼容声明与实际配置

Worker 和 Telemetry 独立仓库新增配置无关的 `--execution-access-profile` 入口，分别报告 `worker-minimal-v1`、`telemetry-http-v1`。仅精确的单参数调用生效，在读取配置、连接数据库、启动 Node 或请求下游之前返回。`deploy/release-contract.json` 保存同一协议；原引擎、Harness pin 和事务模块依赖不变。

候选源码锁选择 Runtime `8bbcc6d`、Worker `80c64ff`、Telemetry `c2a02e2`；完整提交见 `deploy/service-sources.json`。这只是后续干净构建的来源，未修改正式 catalog 的安装引用。

集成 Build 先验证 Owner 原始 JSON，再核对实际程序报告，写入受文件清单/哈希保护的描述符。维护时再次运行受校验资产中的程序报告。字段缺失才按旧版处理；显式 null、空数组、单元素数组、未知版本和错误类型全部拒绝，不能借 PowerShell 管道展开变成合法能力。

权限预检用实际服务账号 LOGIN，在只读事务中确认 session_user/current_user/current_database 与受绑定配置一致，查询有效权限而非仅读直接 ACL。探针清空继承环境，只接受明确的本机 IPv4 PostgreSQL URL、端口、sslmode=disable 和单个 search_path schema；拒绝连接串中的数据库、账号、服务或 PGOPTIONS 重定向。Worker 的地址、端口、数据库、schema 必须与 Runtime 相同，账号必须不同。这是本机发布策略，不能当作远程连接认证方案。

配置文件哈希必须对应 catalog；活跃进程还要对应受管 Job、发布二进制和受保护 launch 快照，其实际 DATABASE_URL 必须一致。没有运行实例时仍验证配置、账号和权限。

| 消费者 | 权限条件 |
| --- | --- |
| 声明 `worker-minimal-v1` | schema USAGE、非管理叶子账号、执行六表的所需 SELECT/INSERT/UPDATE 组合及事件序列 USAGE/SELECT |
| 未声明能力的 Worker | 上述最小执行权限，外加旧 readiness 所读十四表的 SELECT；撤权后不能回退 |
| 声明 `telemetry-http-v1` | schema USAGE、非管理叶子账号；inbox 的 SELECT/INSERT/UPDATE、exports 的 SELECT/INSERT |
| 未声明能力的 Telemetry | 上述本域权限，额外需要 execution events 的 SELECT/UPDATE。某些旧程序可能已采用 HTTP，但未声明时保守拒绝无旧授权的启动 |

Telemetry 的权限条件覆盖真实写入需求，避免只通过 SELECT 就绪检查、却无法落盘或确认收件。预检不创建表或恢复授权，也不保证外部 Langfuse 已配置。

`Start-Local` 在创建服务 launch/进程记录前检查选中的消费者；更新和回退在写 pending、停服务前检查候选；恢复检查实际 prior，不兼容则保留 pending 与当前进程。零实例同样检查。Runtime 自身权限本次没有被削减，原 source/receipt 发布守卫继续保留。

## 已执行验证

全部原始目录位于 `D:\workspace\agent-platform\local\evidence`。

| 报告 | 结果与实际范围 |
| --- | --- |
| `execution-access-build-1e387f7fc44c40e094e2ce0491f0ada7` | Worker/Telemetry 各两项入口测试、vet、原生程序构建；八份 Owner 源码哈希保留 |
| `execution-access-release-fdce72a63e154c74a34c70f8caf37a2a` | 44 项检查通过：真实受限 PostgreSQL LOGIN、实际 Runtime migrator/retire-access 程序、能力报告核对、错误原始 JSON、连接重定向拒绝、PG 环境覆盖隔离、schema USAGE、本域写权限缺失、正式维护入口的零实例更新/回退/启动拒绝、pending 原样保留 |
| `windows-releases-f291a96fc6ea4987a3f63ed58877a43c` | 17 项真实 Windows 进程检查通过，含活跃服务 launch DB 漂移拒绝、实际更新/回退和 readiness 失败恢复；保留 prepared/stopped/started/ready/committed/observer 退出/reverting/recovery_ready 八处进程强退出覆盖 |
| `source-runtime-configuration-5e9f86856cf14b81883f50d4f4246937` | 原 Runtime/Worker 实际配置漂移 12 项回归通过，最终无剩余进程；本组在连接数据库前拒绝 |
| `receipt-release-d064c0138dd64315bb707c2aaa5de026` | 原回执管理协议和发布兼容 41 项回归通过 |
| `execution-access-regression-fcb117d3085041c08a001b00965e7a59` | 上述三组回归的八份源码哈希、日志和 PostgreSQL 停止结果 |

发布故障测试的健康 HTTP 服务仍是合成程序，没有假装成实际 Telemetry/Langfuse。新增 SQL 夹具只提供真实权限预检；原发布覆盖没有改为 mock，也没有删除崩溃场景。备份包回读原有 current/previous、Worker 依赖链接和 Web 检查继续执行，因加入 Runtime 绑定夹具，发布引用从四份增为五份。新增活跃 launch 漂移用例实际保持进程存活，并证明拒绝前后 catalog 不变。

首次 helper 数组表达式错误、schema USAGE 夹具漏撤直接授权、无 schema USAGE 时 regclass 探针报错、测试未透传全局维护锁、上层误判遗留 LASTEXITCODE、发布夹具角色数组拼接错误均有原始失败记录。修正后最终两组报告才计为通过；没有将中间失败覆盖。测试数据库、角色与合成进程已清理，临时 PostgreSQL 已停止。

独立评审先指出 Telemetry 的写权限不能由 readiness 推断，又指出 Owner 原始 JSON 会被管道展开；均已加入实现和反例。评审只读核对源码/哈希/结果及完整发布回归后未发现新增阻断，确认原覆盖未缩小，没有代跑测试。没有 GitHub Actions 或付费模型调用。

## 正式环境预检发现

只读报告 `execution-access-formal-read-d152012d0f1b4feba96b41653d60468b`：当前双 Worker 的最小及旧版权限检查通过；Telemetry 当前零实例，配置指向的库只有 `public.telemetry_exports`，缺少 `telemetry_inbox`。因此新保护正确拒绝将该 Telemetry 配置当作可发布状态。catalog 哈希前后相同，数据库写入为零；没有读取消息或业务行内容。

同目录 `guard-assertions.json` 另记录实际守卫调用：Worker 通过、Telemetry 返回预期的本域权限缺失拒绝；catalog 和进程清单前后哈希均相同，绑定守卫源码哈希。不是仅由权限布尔值推测拒绝行为。

这项缺口需要 Telemetry Owner 的事务迁移，不能通过放松 guard 或跳过零实例解决。先前零实例 catalog 切换不构成 Telemetry 可启动验收。

## 下一步

1. 按固定干净 Owner 提交构建完整发布包；本轮单独构建的测试程序不直接当正式发布资产。
2. 补齐正式撤权协调器，封住受管入口对旧 `migrate-services` 的重新扩权路径。低层显式管理员命令仍须遵守维护窗口，发布 guard 不替代管理员权限控制。
3. 在已验证恢复的备份保护下，用 Telemetry Owner migrator 补本域表，保留旧 exports；部署兼容 Worker/Telemetry 版本，再停消费者并核对会话、数据与 ACL，执行 Runtime Owner 收缩。
4. 实际撤权后的独立升级/拒绝旧版/双 Worker 任务与历史回读验收后，才把正式权限退役记为完成。Linux 发布传播、剩余旧实现覆盖、UI、故障、真实业务及最终统一 CI 继续推进。
