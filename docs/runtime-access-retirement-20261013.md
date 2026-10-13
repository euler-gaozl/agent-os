# 执行数据域旧权限退役：审计与 Owner 候选

2026-10-13，Windows 本机。Runtime 独立仓库已有显式权限收缩入口和真实 PostgreSQL 测试；**正式数据库尚未执行撤权，完整 P2 未完成**。启动、发布、回退和 pending 恢复守卫是下一项前置工作。本轮没有更新正式服务、修改源码锁、调用付费模型或运行 Actions。

后续增量：[Windows 权限发布保护](execution-access-release-20261013.md)已实现并完成本机验收，正式预检发现 Telemetry 缺 inbox；以下保留退役候选阶段的原始事实，正式收缩仍待迁移与协调器。

## 实际审计结果

入口为本机 `ops/Inspect-ExecutionPrivileges.ps1`，维护锁内验证正式 PostgreSQL 的本机地址、端口和数据目录，使用只读事务查询目录。配置和凭证仅在进程内读取；公开证据不包含连接串。报告目录为 `local/evidence/execution-access-audit-df7e8ce500494654980bdff4b02e3886`，catalog 前后哈希相同，报告写入数为零。

- Worker 仍持有旧执行表的宽授权，包括 `documents`、笔记生命周期表及其序列；最新 `run_working_states` 没有 Worker 授权。
- Telemetry 是仍有执行域直读写权限的外域账号：`public.events` 的 SELECT/INSERT/UPDATE/DELETE。
- Storage/Sandbox 已没有执行域直接授权，不应根据旧文档假定这些权限仍存在。
- 未发现账号成员关系或默认 ACL；已审计账号的 superuser、CREATEROLE、CREATEDB、BYPASSRLS 均为 false。该次报告没有采集 REPLICATION 属性，正式执行前必须按新检查重新验证。

这些是当前物理库的权限事实，不表示正式环境已经拆成八个物理数据库。正式库仍有执行 public 表及各域 schema，历史资料和回执保持原位。

## Runtime Owner 的显式入口

Runtime Owner 提交 `8bbcc6ddb975475ce384a91be502f19654c44f70`。新文件：`runtime/retire_access.go`、`runtime/retire_access_test.go`、`cmd/retire-access/main.go`。Owner Windows 构建新增 `retire-access`，Dockerfile 也加入构建目标；本轮实际只验证了 Windows 四个程序的构建，未运行 Docker 构建。集成正式发布包尚未采用新程序。

普通 `migrate` 保持扩展型迁移。显式退役事务使用原迁移锁 8843921，锁等待 3 秒、语句 15 秒；只处理 Runtime 的 15 张表和两个序列，不改业务行、外域表或登录配置。

对 Worker 与明确指定的外域账号执行 `REVOKE ... RESTRICT`，然后只给 Worker 恢复其必要权限：runs 的 SELECT/UPDATE；calls、model_attempts、harness_exchanges、harness_archives 的 SELECT/INSERT/UPDATE；events 的 SELECT/INSERT 和事件序列 USAGE/SELECT。Runtime 自身权限不在本次收缩范围。

提交前检查有效的表、列、序列权限和 grant option，而非仅看一份直授 ACL。选中账号必须是存在、相互独立的非管理叶子角色；包括拒绝 REPLICATION、public schema CREATE、继承或 SET ROLE 通道。受影响表和序列必须由独立迁移身份持有。活跃账号会话、prepared transaction、危险默认 ACL、PUBLIC 遗留权限、下游依赖授权均导致拒绝；不使用 CASCADE 替其他数据域做决定。

连接检查不阻止未来新连接，外层维护窗口仍必须阻止消费者进入。客户端没有收到确认时不假定事务已回滚：服务保持停止，先只读核验实际 ACL 再重试。CLI 错误不打印连接串、服务端细节或凭证。

## 本机验收与评审修复

最终报告：`local/evidence/runtime-access-retirement-99de620b214440499ff4b38b1a683271/result.json`，入口 `ops/Test-RuntimeRetirement.ps1`。使用隔离 PostgreSQL 55591、每项独立随机数据库和账号；正式 PostgreSQL 55432 未执行写操作。

| 验证 | 实际结果与边界 |
| --- | --- |
| 定向数据库测试 | 23 条测试/子测试通过、零跳过；包含原 Owner 迁移及其失败回滚测试 |
| 收缩后的真实登录 | 独立 Runtime、Worker、外域账号实际 LOGIN；Worker 可领取任务、保存模型调用、心跳和结束；Runtime 本地笔记/回执原子执行与重放正常 |
| 资料和边界 | 原始笔记未变，重放无重复；外域哨兵数据和授权保留；Worker/外域账号越权操作返回 42501 |
| 十五种拒绝 | PUBLIC 表/列、INHERIT、SET-only、对象所有权、两类默认 ACL、下游授权、中途 REVOKE 失败、缺表、活跃登录、管理角色、复制角色、身份混用、缺角色；失败前后表/列/序列 ACL 相同 |
| 正常迁移与重复 | 退役前正常迁移不提前收权，退役后不重新扩权；退役两次结果一致 |
| CLI | 构建实际程序、确认真实 current_database 为随机夹具库，再执行；丢弃第一次成功输出后重试；失败错误经脱敏。没有模拟 COMMIT 网络断开 |
| 构建与静态边界 | vet、四个 Windows 程序构建、Worker execution 包依赖边界检查通过 |
| 清理和版本 | 七份源码及 helper 哈希保留；前后夹具数据库/角色清单一致；测试 PostgreSQL 已停止。不是宣称该集群原来没有其他夹具对象 |

首轮 `runtime-access-retirement-210faa9ad12946568b1d5cec910fa364` 的三处失败保留：JSONB 字段顺序导致错误的字节比较、依赖授权角色的清理顺序、复制 pgx 配置后 ConnString 仍指向原库。已改为语义 JSON 比较、先删除随机夹具库再删除该夹具角色、显式构造并核验 CLI 的目标库。首轮遗留的一个明确夹具角色已在维护锁下定点移除，清理记录保留；未批量删除预先存在的其他测试对象。

第二轮 `runtime-access-retirement-b23998c1c4c042b2861b983bae489368` 21 项通过。独立评审随后发现 URL 的 dbname/database 查询参数可覆盖路径，角色检查还遗漏 REPLICATION。最终版清除查询参数覆盖、按 pgx 实际解析复核并查询 current_database；新增复制角色反例，并让 INHERIT/SET-only 先移除直接授权再证明间接路径。最终 23 项包含这些修复。第二轮使用的固定 URL 不含覆盖参数，原始结果仍保留，不把其源码哈希替换成最终版。

评审代理只读审查代码和报告，核对七份源码/helper 哈希、23 条通过/零失败/零跳过日志、构建/边界结果及停止记录，最终未发现剩余候选阻断；没有代跑测试。测试结果不能冒充正式发布、物理节点 HA 或 Linux 验收。

## 正式收缩前还要完成什么

1. 增加独立的执行库权限兼容能力声明，绑定实际二进制来源。现有 HTTP/data 合约相同，无法区分旧 Worker readiness 的全表 SELECT 与新 Worker 最小权限；Telemetry 也必须区分直读 events 的旧程序与只用 Runtime HTTP 的新程序。
2. 在启动、更新、回退及 pending 恢复的产生副作用前，核对实际绑定数据库/账号的 ACL 与目标程序能力。零 Telemetry 实例时也检查未来可启动的版本；不能只检查默认引擎或信任元信息。回退不得自动重新授予宽权限。
3. 使用已经验证可恢复的正式备份，冻结新连接并停消费者；核验进程退出、数据库会话、权限/资料指纹、迁移身份和完整发布绑定后再执行收缩。提交结果不确定时保持停止并只读核验。
4. 正式收缩后以真实服务验收双 Worker、笔记和历史回执；确认不兼容旧版在停服务前被拒绝。旧实现删除还须补齐 ENOSPC 等未移交覆盖及最终统一 CI，不能通过少跑测试来完成退役。

当前下一步从第 1、2 项开始，随后才执行正式撤权。单机完整目标中的其余页面、故障、真实品种研究与最终统一 CI 继续保留。
