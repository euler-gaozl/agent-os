# Sources 本域迁移与正式发布

2026-10-14。Sources `29fe086` 已完成正式本域迁移和独立部署，发布为 `sources-9097b5984dcb4f37a76ad198a9bf4a44`。control 身份读取 `/capture-capabilities` 返回 `source-capture-v1`；Knowledge 的导入能力为 configured。**这只证明两个服务的能力与授权入口可用，尚未完成新网页采集、保存、研究的真实端到端验收，Console 表单也仍待实现。**

## 数据迁移和恢复规则

- 原始捕获记录新增 `extraction_version`，历史记录标记 `unrecorded`，不补造历史提取算法版本。迁移只由 Sources 自己的 Go 程序执行，服务启动不做 DDL。
- 停第一个实例之前，持久化原角色及 Worker 数量、发布 catalog、配置全集摘要、受保护的演练计划及数据库/角色身份。停机后再固定全部关系的数据指纹，摘要写入同一迁移记录，随后才允许发出 SQL。
- 迁移程序使用与服务一致的具名 Windows Job，记录启动意图、配置和二进制摘要；每次尝试单独保留日志。恢复先停止登记的进程，再等待对应数据库的客户端退出，避免把客户端退出误当成数据库已经结束提交。
- 数据库与旧状态相同才执行；与演练后的状态相同则校验而不重跑；其他状态保持启动阻断。原捕获字段以去掉新增列后的逐行指纹比较，其他关系完整比较，结构及权限必须与隔离演练一致。
- 备份后只容忍实例心跳和列明的 ToolHub 健康探测变化。Skill/MCP 定义、附件、启停状态与非检测审计仍须匹配备份；迁移前后即时指纹则覆盖所有表，包括这些健康数据。
- SQL 校验完成后先归档完成记录，再恢复服务。此后的恢复不会用旧停机指纹拒绝合法新写入，也不会重新执行 DDL。迁移配置清理可重复执行；配置、数据库和凭证没有进入仓库。

维护入口位于 `scripts/Test-SourcesMigrationPlan.ps1`、`scripts/Migrate-SourcesCapture.ps1`。先用标准 `Platform.ps1 backup` 和 `restore-check` 得到实际通过的备份，再传入备份目录与恢复报告生成演练计划。正式执行使用该计划：

```powershell
./scripts/Test-SourcesMigrationPlan.ps1 -BackupDirectory <backup-directory> -RestoreReport <restore-result.json>
./scripts/Migrate-SourcesCapture.ps1 -PlanPath <protected-plan.json>
# 未完成记录仍在时：
./scripts/Migrate-SourcesCapture.ps1 -Action recover -PlanPath <same-plan.json>
# 已归档 SQL 结果、启动或清理阶段中断时，额外给出已记录的操作 ID：
./scripts/Migrate-SourcesCapture.ps1 -Action recover -Operation <operation-id> -PlanPath <same-plan.json>
```

这些命令绑定本机既有受管 PostgreSQL，不能用于任意服务器。已验证的迁移完成后，Sources 程序仍通过正常 `Platform.ps1 build/update/rollback` 单独发布。

## 已执行的验证

主要本机证据：`local/evidence/sources-migration-1791911695844`。

- Sources 13 项 Go 测试通过，无跳过，vet 和独立构建通过。新增受保护配置输入有 64 KiB 上限，拒绝未知字段、额外 JSON 与环境/参数覆盖歧义。
- `sources-migration-recovery-c996269c604e4af48b701bfccbd89b30/result.json`：30 项通过，清理成功。使用真实迁移二进制、隔离 PostgreSQL 和真实 PowerShell 父进程强杀，覆盖发 SQL 前、迁移子进程仍存活时、提交后尚未验证时；确认存活子进程可找到、旧记录及其他表保持、提交后不重放、未知结构/替换二进制拒绝、重复凭证清理，以及 ToolHub 正式数据漂移拒绝。
- `owner-migration-journal-f89edf903f414b289a251fcb31b4e444/result.json`：73 项通过，覆盖全局未完成记录对启动、发布、配置与备份入口的阻断。这些记录不是物理断电测试。
- 新正式备份 `local/backups/pre-sources-owner-20261014-0145`；恢复报告 `local/restore-checks/f030716f9c0841f4a5c3cbd40496edc1/result.json` 通过 44 关系、结构/权限及既有凭证/发布文件核验，隔离集群已停止。
- `sources-migration-plan-5214bd4ee070490a81cb17e6e126b713/plan.json`：在上述真实恢复副本执行固定 Owner 程序两次，原数据、其他域结构权限和数据库设置不变，重复执行结构不变；隔离集群停止后才将计划标为通过。
- 正式操作 `71e8782c24b942509037150d79743b7d` 正常完成；`sources-migration-live-ca5dae2bf53341dbaa9d5c6f72851f65/result.json` 确认 44 关系的历史数据不变、结构权限匹配、应用账号通过，12 实例含 2 Worker 恢复认证就绪。
- 完成后再次执行 `recover -Operation` 成功，12 个实例身份保持，没有重跑 DDL；证据为 `completed-recovery.json` 和 `sources-migration-live-461718edb1e54036bf4ec6cb6700a317/result.json`。
- 正式 Sources 更新后回退旧程序、再更新新程序均认证就绪，非目标实例保持。旧版捕获能力返回 403，新版返回固定协议；证据 `installed-sources-release.json`、`sources-rollback.log`、`sources-reinstall.log`。该回退只替换程序，保留新增列。

测试实际发现并修复 Windows PostgreSQL 子进程中文编码未显式固定、迁移重试复用日志名导致启动失败。标准 PostgreSQL 工具调用现在固定 UTF-8 并清理继承的 libpq 环境覆盖。早期失败报告均保留。

## 明确未通过的故障场景

正式协调器的“已登记 → 停机阶段强杀 → 尚无 stopped.json 的 recover”仍未动态验收。第一次监控脚本读取正在写入的日志遭遇共享锁错误，实际协调器继续运行；再次检查时已越过预定强杀窗口，保护检查拒绝延迟强杀，协调器随后正常完成。`formal-stop-interruption.json` 保存失败结果，不能把正常迁移或 SQL 三断点测试写成这个强杀场景通过。

独立评审仅检查源码和已保存的报告，没有代跑测试。评审指出的凭证清理幂等、停机前缺少持久恢复清单、ToolHub 豁免范围过宽均已修改；最后一项协调器断点动态验证按上段继续保留。

Sources 之外的迁移/旧权限退役、完整 UI、生命周期与负载测量、其他故障场景、实际新来源及研究成稿质量均仍在总目标中。本轮无模型调用、无 GitHub Actions；不因此宣称生产 HA 或整个平台已交付。
