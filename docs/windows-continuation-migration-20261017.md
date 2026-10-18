# Windows 接续回执迁移

此流程仅适用于原 Windows 的受管部署。Mac 接手者不能复制本机路径、DPAPI 配置或恢复状态执行。服务先后顺序是匹配 Worker → Runtime Owner 迁移 → Runtime → Console。

## 入口

1. 用 `scripts/Platform.ps1 backup` 捕获当前 catalog、配置和数据库，再用 `restore-check` 实际隔离恢复。之前发布过服务的旧备份不能直接冒充当前部署。
2. `scripts/Test-RuntimeContinuationMigrationPlan.ps1 -BackupDirectory <备份目录> -RestoreReport <恢复 result.json>` 编译固定且干净的 Runtime Owner 提交，在已停止的恢复副本执行真实迁移，生成受保护的 `plan.json`。
3. `scripts/Migrate-RuntimeContinuation.ps1 -PlanPath <plan.json>` 停服务、固定数据基线并执行正式迁移。计划要求备份/恢复校验、当前配置和 catalog 完全匹配；Runtime/Worker 必须分别绑定预演账号及同一数据库。
4. 若中断，继续使用同一计划：`scripts/Migrate-RuntimeContinuation.ps1 -PlanPath <plan.json> -Action recover`。若已完成迁移、仅服务重启未完，另加结果中的 `-Operation <id>`。不能删除 pending 日志绕过恢复。

旧 schema、ACL、所有旧表和序列的摘要必须保持不变；仅新增空接续回执表。Runtime 对它只能 SELECT/INSERT，Worker 无权。Owner 二进制由源码提交、构建元数据及文件哈希固定，连接信息通过受保护文件传入，不放进命令行。

恢复先停止本次 Owner 的 Windows Job，再排除数据库客户端。旧 schema 可以重放同一个事务，新 schema 只核验，其他状态保持停止。验证后的完成日志先归档，再重启原服务；此后恢复不重放 DDL，也不拿已经恢复写入的数据比较迁移前摘要。

## 验证边界

`Test-OwnerMigrationJournal.ps1 -MigrationOperation runtime-continuation-v1` 检查实际协调进程退出后的日志、互斥和维护入口拦截，不执行 SQL。迁移排练使用真实 Owner 二进制、恢复数据库及异常检查点覆盖提交前、提交后和 schema 漂移；异常检查点不应称为进程崩溃或机器断电。

正式安装事实与证据索引见 [Windows 续做记录](maintainer/windows-resumption-20261017.md)。以上入口和设计本身不代表正式库已迁移或完整目标已完成。所有测试及发布均保持 Actions 禁用，供应商调用为零。

2026-10-17 本机验证：Runtime `cda132d` 的配置解析 1 顶层/10 子项通过；新 operation 的 journal 73 项通过。最新备份 `runtime-continuation-20261017-120409` 已实际恢复（`30d95d79b71440c08216d04f67e3e9a0`），恢复副本排练 `ce40c6b5026445ac9f3f048811705dda` 通过：44 张旧表/序列及旧 schema/ACL 不变、重复 Owner 迁移不变、四项恢复检查通过。两次独立静态评审未发现 P1/P2；恢复副本已停止。正式迁移仍以独立执行结果为准。
