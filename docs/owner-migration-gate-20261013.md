# Windows Owner 迁移中断门禁

本增量完成迁移中断后的维护入口保护、消费者候选完整构建和新备份隔离恢复。**没有执行正式 Telemetry DDL 或执行域撤权，没有升级安装版本；完整单机 Goal 仍 active。**

## 实现和边界

`scripts/lib/platform-migration-journal.ps1` 在固定的
`D:\workspace\agent-platform\ops\owner-migration.pending.json` 保存迁移意图。
它与全平台维护锁采用同一个稳定位置。`-LayoutPath` 或直接备份的
`-StateRoot` 无法换一个运行目录绕过门禁。恢复必须使用 journal 记录的
原运行目录，baseline 内容绑定 SHA-256。

内部原语包括 prepared、mutation_requested、validating、validated 四个阶段。
baseline 和 journal 写临时文件、Flush(true)、同卷替换；进程退出后标记
仍保留。普通 Start、独立更新/回滚/恢复、默认引擎修改/恢复、构建、初始化、
基线登记和备份会先拒绝；Doctor 报告 owner_migration_pending，Stop 和
数据库启动仍可供检查。损坏的 journal 不会被当作“没有迁移”。

只有持有全局锁、匹配 operation ID 且处于 validated 阶段，内部协调代码才
能将 journal 归档至 `local/run/migrations/<id>/completed.json`。这不是
SQL 验收本身，也不是提供给用户的“强制解锁”接口。**正式协调器尚未接入**：
它仍需对备份、数据库身份、实际 SQL 提交结果、ACL、原文指纹及恢复后的
实例就绪负责；进入恢复启动阶段后，要区分合法新写入与停机前基线。

标准构建不再产出 `migrate-services`；Start 移除了显式 `-Migrate` 和
缺配置时隐式调用共享 migrator 的分支。归档发布包仍可读以供历史还原，
独立旧 CLI 源码/历史夹具仍未退役。任意管理员直接执行旧归档二进制，
不受本门禁限制，不能声称旧迁移工具已完全封口。

## 实际证据

全部证据在 `D:\workspace\agent-platform\local`，不提交真实配置、数据库或密钥。

- `evidence/owner-migration-journal-3c154d71cbc14704b834553b2e363f1f/result.json`：
  73 项检查，四阶段实际 PowerShell 子进程 Exit(198)、锁释放、普通入口拒绝、
  catalog/进程清单不变、跨布局拒绝、备份 StateRoot 覆盖拒绝、类型/内容损坏
  和显式验证后归档。12 份最终源码哈希匹配。没有数据库写入或服务激活，
  不是机器断电验收。测试制造的损坏 journal 已移入该证据目录，正式全局无 pending。
- `evidence/execution-access-regression-cdc0df9df4814de99f628fe24b6e5e2b/result.json`：
  最终源码的发布/配置/回执回归通过，临时 PostgreSQL 已停止。子报告：
  `windows-releases-ce2feac128f64967ae758e16e978c7ca`（17 项，原八处进程故障保留）、
  `source-runtime-configuration-b7dd8963cc9240b4bda2b17483f901af`（12 项）、
  回执报告位置记录在该目录 receipts.log（41 项）。
- `evidence/execution-access-bundles-fecf7cc191654a76b21a6bc55dcefa13`：
  干净集成提交 f457ff9 构建 Runtime 8bbcc6d、Worker 80c64ff、Telemetry c2a02e2，
  发布集 `releases/staged/d41fbfea60a14d179a7524dc09e31d52.json`。
  Worker 包含固定 Node、旧 Harness、source-v1 和 resident-v2，三项接口检查通过；
  配置及 current catalog 未切换。此发布集在本门禁源码提交前构建，不能把它
  写成包含尚未提交协调脚本的构建。
- 新备份 `backups/pre-execution-access-20261013-172058`，实际隔离恢复报告
  `restore-checks/f0c4b5a18b02478c8e07e75606319cc7/result.json`：44 个关系/序列
  内容与结构权限、25 个发布引用、3,018 文件、零链接、10 个账号登录、两项
  凭证解密通过，隔离集群已停止；零模型调用、零 Worker 启动。
- 备份后正式 `Doctor`：`evidence/owner-migration-post-backup-55f5eeb31b224d37b610be69ca246987.json`，
  核心探针通过、12 个所属实例运行、零错误、无全局 pending，current catalog 摘要与构建前一致。

独立评审真实发现并要求修复“修改 state_root 可绕过门禁”；修复后重新执行
73 项，评审核对所有 12 份源码哈希，未发现本增量新增阻断。此前 55/58 项
报告和中间回归保留，但不作为最终源码完整验收。

## 下一步

复用现有维护锁、发布事务和备份原语，接入具体 Owner 协调操作，不再另造
通用迁移框架。先补 Telemetry inbox：预期变化还包括删除 exports 旧 FK、
新增 pending 索引和本域两表 CRUD，原 exports 与其他关系内容必须保持。
消费者升级保持 Telemetry 零实例。随后停机记录精确角色身份/原 LOGIN，
冻结登录并确认没有残存连接，再执行 Runtime 退役；未知 COMMIT 结果靠
实际 ACL/内容判定，禁止自动恢复旧授权。恢复 LOGIN 后执行真实身份探针，
按原实例数恢复服务并验证，再归档 journal 和做新基线备份/还原。

本轮未运行 GitHub Actions，未调用付费模型。UI、其余故障和真实业务研究
继续属于完整目标；本增量不能代替 P2 或整个平台验收。
