# Windows 工作区物理迁移验收

日期：2026-10-12。此记录只证明本次本机目录与维护增量，不表示 P1 发布闭环、P2 拆仓或 P2.5 源码 Harness 已完成。运行服务二进制仍为功能基线 `5bfc84c9e7507156184c337354eef2674694763b`，迁移时源码 HEAD 为 `24a7514`，本批维护脚本修改尚未包含于该 HEAD。

## 当前布局

| 内容 | 当前真实路径 |
| --- | --- |
| 有效源码仓库 | `D:\workspace\agent-platform\repos\agent-os` |
| 原 PostgreSQL 集群 | `D:\workspace\agent-platform\local\data\postgres` |
| 配置与服务身份 | `local\config`，严格本机权限，不进 Git |
| 进程清单、日志、固定发布文件 | `local\run`、`local\logs`、`local\releases` |
| 旧 `.state` 资料 | `local\legacy-state\20261012-102142`，原样保留；旧报告中的 `.state/...` 在此查找 |
| 原 `bin` 文件 | `local\releases\legacy-20261012-102142`，实际精确目录以迁移 journal 的 `legacy_builds` 为准 |
| 固定维护入口 | `D:\workspace\agent-platform\ops\Platform.ps1` |

源码里的 `.local/layout.path` 指向 `ops\layout-4e6d8ab760f34f728b621ed37a0345b3.json`。不要手工覆盖历史布局。旧 `D:\workspace\agent-os` 只留迁移提示，不是第二份项目。新的 JS 本机配置辅助函数读取同一 pointer，付费验收继续沿用原留存的预算，不因新目录而重置预算。

## 实际通过的验收

- 完整备份 `local\backups\separated-layout-20261012-v3` 在全新隔离 PostgreSQL 集群还原。43 个表/序列、DDL、权限及数据库元数据一致；10 个服务数据库身份登录、2 条 Registry 加密凭证解密、12 个服务 Token 与身份索引一致；固定依赖离线安装和 3 个 Session 特征测试通过。报告：`local\restore-checks\c611c8ab503e48bab690d272ee5de52b\result.json`，验证集群已停止。
- 最终迁移 journal：`local\evidence\workspace-move-a4ed9a373d2949a9aa2c18f10e4855df.json`。先停所有服务及原数据库，核对所属进程和路径，再同盘重命名。1,948 个 PostgreSQL 文件逐个 SHA-256 一致；启动数据库后、启动 Worker 前，43 个表/序列及数据库元数据/结构/权限一致。数据库没有重新初始化。
- 12 个所属进程恢复，包括两个 Worker；HTTP 存活/就绪检查通过。四个业务只读响应的 SHA-256 与迁移前一致：Agent、文档、笔记、运行记录。证据为 `post-physical-move-api-fingerprints.json`，不保存原始响应到 Git。
- 旧 `.state` 的访问权限确实包含宽泛用户组；已收紧并逐项核验为当前用户、System、Administrators。回退保留这个收紧，不恢复宽泛权限。已经符合要求的条目只核验，不重复修改 ACL。
- 全过程没有模型调用。当前 Windows 未配置 Docker Sandbox 执行；服务就绪不能表述为隔离执行已可用。
- 新源码目录按原 lockfile 重建开发依赖，3 项 DSH Session 特征测试及两个 Web 的 TypeScript/Vite 构建通过；这不改变正在运行的固定发布文件。通过稳定入口只停止/启动 Console，其余 11 个实例的 PID、启动时间及二进制路径不变。迁移后 3,065 个数据库、归档、配置目录/文件权限再次核验，无宽泛组授权。证据为 `stable-entry-control-restart.json`、`post-move-private-acl.json`、`post-move-doctor.json`。

## 中断与失败记录

1. **数据库重命名后、完成日志前退出。** 本机夹具真实退出码 197，journal 仍为 `moves=0`，但目标目录已经存在。独立恢复入口从四对精确路径推导完成一步，原路回退，在重新启动服务前核对数据库内容并恢复 12 个进程。journal：`workspace-move-67dff6df7073472faaf01ab0df29af39.json`。
2. **源码重命名后退出，回退途中再退出。** 修正后的同盘重命名夹具退出码 197；journal 记录三步完成，第四步 intent 存在，旧源码目录已不存在。首次恢复在逆向源码重命名后真实退出码 198；第二次恢复根据目录存在性继续剩下三步，数据核对通过、服务恢复。journal：`workspace-move-85003c971a3c4b308d8ddeabe5bc311d.json`，`move-recovery-crash.json`。回退也在重新启动服务前持久化“可能已启动”标志，避免下次恢复将合法心跳写入误判为资料变化。
3. **迁移预检发现备份遗漏身份索引。** 旧备份包含各服务配置，但未包含初始化时保留 Token 的 `services/identities.json`。配置集合核对在停机前拒绝。已补 DPAPI 备份、清单和恢复交叉验证，并生成上述 v3 备份；旧备份的实际恢复结果保留，但不能再称完整配置集合。对应首次拒绝 journal：`workspace-move-702e4416d26c458bb9ef1efbdffde2c9.json`。
4. **停止后枚举到已退出的进程对象。** 新一次备份曾被守卫拒绝；随后实际记录到 11 个匹配对象 `HasExited=true`。现在只忽略明确已退出的对象，状态读取失败仍拒绝。真正存活且没有 manifest 的实例仍被拒绝，见 `live-orphan-guard.json`；已退出对象见 `terminated-process-enumeration-*.json`。最早那次没有进程身份的历史拒绝仍无法逐 PID 追认原因。
5. **重复设置 ACL 失败。** 第二轮夹具在任何目录搬动之前发生 `SeSecurityPrivilege` 错误，自动恢复原服务和数据指纹。改为先验证权限，仅在确有宽泛授权时收紧；后续重跑通过。journal：`workspace-move-5cb2114e3e9e40deb9fb1f0328871ed5.json`。不声称获得了系统权限。
6. **原 Move-Item 发生部分移动。** 它在处理 pnpm 目录联接时递归搬动，失败后新旧源码根同时存在。自动恢复正确拒绝歧义状态，但原“整体重命名”假设错误，独立评审也明确承认漏检。人工逐项核对后，将互不冲突源码项原路重命名；两份部分依赖树归档到 `local\source-move-repair-62dafefc`，未删除资料。Git 完整性检查和回退后的数据核对通过。journal：`workspace-move-62dafefc7d7a438aad1c0b6a27b61bb5.json`。正向、逆向现均使用验证了同盘和无祖先联接点的 `Directory.Move`；修正后重新执行了第 2 项，不沿用失败前的审查结论。

本机故障夹具保存在 `ops\test-workspace-move-crash.ps1`、`ops\test-workspace-recovery-crash.ps1`；使用 PowerShell 断点在真实重命名之后退出，不替换底层移动动作。它们针对一次性旧布局，当前已迁移的部署不得直接重跑。自动恢复拒绝两边都在/都不在的路径，不自动合并或覆盖资料。没有验证整机断电和磁盘损坏，本次进程退出结果不能替代这些场景。

## 仍需完成

P1 统一单服务 update/rollback（固定版本、兼容检查、非目标实例不变、失败恢复）后再进入正式拆仓。Windows 数据恢复、DSH flush 接口特征、真实长任务恢复和物理机器 HA 是不同验收项目，不相互替代。
