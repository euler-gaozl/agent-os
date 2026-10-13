# 源码执行器的 Windows 发布保护

2026-10-13。本增量接在 [提交与工作状态管理](source-engine-submission-20261013.md) 之后。集成源码锁选择 Runtime `a916ab1`、Worker `70d45cd`、Console `1de4118`；Worker 仍通过固定的 Runtime `v0.1.0-rc.2` 窄执行包保持事务归属。源码锁只是下一次构建输入，不会改动已安装 catalog、数据库或默认执行器。

## 发布行为

`Platform.ps1 build -Service runtime,worker,control -SourceArtifact <已验证的源码产物目录>` 可以打包源码执行器。Worker 的 Node、历史 npm Harness 和新增 `source-harness` 均进入完整文件清单。源码 runner、kernel、第三方声明及 manifest 必须匹配该 Worker 编译时固定的 manifest，包中另保留来源锁；不在构建时追踪上游最新版本。原目录可搬走，备份/恢复只依赖包内文件。普通启动从已校验发布资产设置 `DSH_SOURCE_RUNNER`，拒绝用服务配置覆盖它。

Runtime 的新增 HTTP/数据契约按角色单独固定，其他服务仍保留各自原契约。Windows 只允许明确评审过的 `execution-v0.6-notes-lifecycle` 与 `execution-v0.7-working-state` 之间进入后续兼容检查，不普遍放开不同数据协议。Linux 发布仍要求完整契约一致；本项不是 Linux 迁移已验收。

Runtime/Worker 的启动、更新、回滚、未完成发布恢复在停任何目标进程前检查：

- 发布包真实内容及 Runtime 的 submission/management/preview 协议、Worker 的固定源码产物标识。
- Runtime 配置与 catalog 的 SHA 绑定；每个活实例的所属 current/pending 版本、受保护启动快照、来源配置 SHA、实际默认执行器和数据库地址。磁盘配置已改而进程仍用旧值时拒绝，不能据此撤掉最后一个源码 Worker。
- 应用账号能够读写工作状态表，13 个必需列的类型和 NOT NULL 正确，两个唯一键有效且立即生效。该探针不替代 Owner 的完整迁移、权限/约束测试和启动 readiness。
- 只读查询保留任务。新默认值或仍可恢复的源码任务要求源码 Worker；只要还保留任何源码任务，Runtime 就不能回退到不理解其状态的旧版。失败/未知/等待中的任务均算可恢复；完成/取消的历史允许在默认值恢复旧引擎后降级 Worker，但不能降级 Runtime。

这仍不是一键切换默认执行器：配置与 schema 的协调迁移须单独实现并经过中断恢复测试。先完成可恢复备份、追加迁移、就绪的 Runtime/Worker，再切换新根任务默认值。不能让普通 `start` 暗中跑迁移或重写配置。

## 实际验收与评审

以下目录均在 `D:\workspace\agent-platform\local\evidence`；本批没有付费模型或 GitHub Actions 调用。

| 证据目录 | 范围 |
| --- | --- |
| `source-release-policy-77941329e5dc460f8a1832e0838df880` | 27 项策略/产物/真实 PostgreSQL 检查。实际固定源码文件拷贝及完整清单备份恢复，篡改拒绝；受限数据库账号、Owner 的真实工作状态建表 SQL、缺表/缺权限/残缺列/缺唯一键/错误类型拒绝。发布二进制是明确标记的合成清单，不是实际部署 |
| `source-runtime-configuration-5f721fc4e02d4c259fb59de5eed91f82` | 11 项真实 Windows 合成 Runtime/Worker 进程检查。调用正式启动/回滚/恢复入口，配置错位均在查库或停进程前拒绝，catalog 与进程清单不变；合法 pending.target 进程可读，篡改启动快照被拒绝。最终 0 残留进程 |
| `windows-releases-2ccb25e84a7d4b4eb6e00f0c4caa827b` | 原 16 项真实 Windows 合成服务发布回归，包括 8 个发布/恢复中断点、非目标独立退出、失败回退、完整依赖与 Web 还原 |
| `windows-processes-b7bd4a03b15345bba0afbf2d3d69158c` | 原 8 项进程所有权/Windows Job 回归，包含 PID 尚未保存时启动器退出和忙碌 Node 子进程清理 |

`node --test scripts/owner-release.test.mjs` 的 3 项合同/独立镜像来源检查通过。三项所选 Owner 的干净提交、SDK/vendor、固定事务包与完整契约也已核对。实际已安装旧部署的只读兼容预检通过：源码任务 0、工作状态表尚未迁移；原先数据库停止，检查时短暂启动后恢复停止，未改 schema/config/catalog。

只读评审首次发现两个缺陷：检查只看磁盘默认值、迁移探针只看表存在/权限。上述活实例校验及列/唯一键检查针对这两项修复；同一独立评审 Agent 复读代码和两份报告后确认修复成立，本轮未发现新增必须修复项。评审没有运行测试、读取正式配置或执行 CI，不作为独立动态复测。首次补测有两处夹具错误，失败报告保留：将 body 从 text 改回 jsonb 时 PostgreSQL 的旧 CHECK 表达式重建失败；启动拒绝测试的布局字段不全，在抵达目标检查前失败。现分别重新应用 Owner 建表 SQL、补齐完整隔离布局。不能把这些首次失败算成通过。

## 尚未完成

本批尚未正式激活新 Runtime/Worker/Console，也未切换默认提交执行器。真正配置迁移的断点恢复、新包正式更新/回滚、追加迁移后的全量备份还原和真实 DeepSeek 仍须执行。有界历史内存、恢复耗时/内存测量、缓存回收、运行详情有界分页、完整逐页 UI 与真实供给/库存研究继续属于完整单机目标。
