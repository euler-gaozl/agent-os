# 源码执行器的 Windows 发布保护

后续实际部署已完成：13 次升级/回退、真实 DeepSeek 工作状态任务及追加状态的完整隔离恢复见[激活验收](source-engine-activation-20261013.md)。下文记录发布保护实现时的先后顺序，其中“尚未激活”描述当时状态。

2026-10-13。本增量接在 [提交与工作状态管理](source-engine-submission-20261013.md) 之后。集成源码锁选择 Runtime `a916ab1`、Worker `70d45cd`、Console `1de4118`；Worker 仍通过固定的 Runtime `v0.1.0-rc.2` 窄执行包保持事务归属。源码锁只是下一次构建输入，不会改动已安装 catalog、数据库或默认执行器。

## 发布行为

`Platform.ps1 build -Service runtime,worker,control -SourceArtifact <已验证的源码产物目录>` 可以打包源码执行器。Worker 的 Node、历史 npm Harness 和新增 `source-harness` 均进入完整文件清单。源码 runner、kernel、第三方声明及 manifest 必须匹配该 Worker 编译时固定的 manifest，包中另保留来源锁；不在构建时追踪上游最新版本。原目录可搬走，备份/恢复只依赖包内文件。普通启动从已校验发布资产设置 `DSH_SOURCE_RUNNER`，拒绝用服务配置覆盖它。

Runtime 的新增 HTTP/数据契约按角色单独固定，其他服务仍保留各自原契约。Windows 只允许明确评审过的 `execution-v0.6-notes-lifecycle` 与 `execution-v0.7-working-state` 之间进入后续兼容检查，不普遍放开不同数据协议。Linux 发布仍要求完整契约一致；本项不是 Linux 迁移已验收。

Runtime/Worker 的启动、更新、回滚、未完成发布恢复在停任何目标进程前检查：

- 发布包真实内容及 Runtime 的 submission/management/preview 协议、Worker 的固定源码产物标识。
- Runtime 配置与 catalog 的 SHA 绑定；每个活实例的所属 current/pending 版本、受保护启动快照、来源配置 SHA、实际默认执行器和数据库地址。磁盘配置已改而进程仍用旧值时拒绝，不能据此撤掉最后一个源码 Worker。
- 应用账号能够读写工作状态表，13 个必需列的类型和 NOT NULL 正确，两个唯一键有效且立即生效。该探针不替代 Owner 的完整迁移、权限/约束测试和启动 readiness。
- 只读查询保留任务。新默认值或仍可恢复的源码任务要求源码 Worker；只要还保留任何源码任务，Runtime 就不能回退到不理解其状态的旧版。失败/未知/等待中的任务均算可恢复；完成/取消的历史允许在默认值恢复旧引擎后降级 Worker，但不能降级 Runtime。

默认执行器现有独立的配置事务入口（见下节）；schema 迁移仍属于 Owner 管理动作。先完成可恢复备份、追加迁移、就绪的 Runtime/Worker，再切换新根任务默认值。不能让普通 `start` 暗中跑迁移或重写配置。

## 实际验收与评审

以下目录均在 `D:\workspace\agent-platform\local\evidence`；本批没有付费模型或 GitHub Actions 调用。

| 证据目录 | 范围 |
| --- | --- |
| `source-release-policy-77941329e5dc460f8a1832e0838df880` | 27 项策略/产物/真实 PostgreSQL 检查。实际固定源码文件拷贝及完整清单备份恢复，篡改拒绝；受限数据库账号、Owner 的真实工作状态建表 SQL、缺表/缺权限/残缺列/缺唯一键/错误类型拒绝。发布二进制是明确标记的合成清单，不是实际部署 |
| `source-runtime-configuration-5f721fc4e02d4c259fb59de5eed91f82` | 11 项真实 Windows 合成 Runtime/Worker 进程检查。调用正式启动/回滚/恢复入口，配置错位均在查库或停进程前拒绝，catalog 与进程清单不变；合法 pending.target 进程可读，篡改启动快照被拒绝。最终 0 残留进程 |
| `windows-releases-2ccb25e84a7d4b4eb6e00f0c4caa827b` | 原 16 项真实 Windows 合成服务发布回归，包括 8 个发布/恢复中断点、非目标独立退出、失败回退、完整依赖与 Web 还原 |
| `windows-processes-b7bd4a03b15345bba0afbf2d3d69158c` | 原 8 项进程所有权/Windows Job 回归，包含 PID 尚未保存时启动器退出和忙碌 Node 子进程清理 |
| `source-managed-build-27e7720ed35f4c62a8246597e6f7c28f` | 从干净集成提交 `d191a28` 构建实际 Runtime/Worker/Console 发布包，校验 Owner Go 二进制提交、固定依赖、Web 类型/构建及旧 Harness 接口 3 项测试。选定三包实际归档还原，1,484 文件全部哈希一致、0 链接；Worker 二进制及 4 项源码资产与此前故障验收包完全一致。当前 catalog 未改变；未启动候选服务 |

`owner-release.test.mjs`、`owner-build-matrix.test.mjs`、`owner-stack.test.mjs` 合计 6 项契约/独立来源/编排检查通过。三项所选 Owner 的干净提交、SDK/vendor、固定事务包与完整契约也已核对。实际已安装旧部署的只读兼容预检通过：源码任务 0、工作状态表尚未迁移；原先数据库停止，检查时短暂启动后恢复停止，未改 schema/config/catalog。

待激活发布集为 `local/releases/staged/8ff9cc8011e0400ca565a4c472839613.json`，Runtime `runtime-b83cd7488cda457181e9113b81e10828`、Worker `worker-58d52abf2c8d49a29a79825cfe20cd5d`、Console `control-69522f6425694600816927734108e5b4`。Worker 二进制 SHA-256 为 `ec279257d68f2fba13f3a357edcc819cf2eca0183f4f10f62b06550f2d1c00eb`。机器上的 `ops/Platform.ps1` 已同步 `SourceArtifact` 参数。

只读评审首次发现两个缺陷：检查只看磁盘默认值、迁移探针只看表存在/权限。上述活实例校验及列/唯一键检查针对这两项修复；同一独立评审 Agent 复读代码和两份报告后确认修复成立，本轮未发现新增必须修复项。评审没有运行测试、读取正式配置或执行 CI，不作为独立动态复测。首次补测有两处夹具错误，失败报告保留：将 body 从 text 改回 jsonb 时 PostgreSQL 的旧 CHECK 表达式重建失败；启动拒绝测试的布局字段不全，在抵达目标检查前失败。现分别重新应用 Owner 建表 SQL、补齐完整隔离布局。不能把这些首次失败算成通过。

## 尚未完成

本批尚未正式激活新 Runtime/Worker/Console，也未切换默认提交执行器。新包正式更新/回滚、追加迁移后的全量备份还原和真实 DeepSeek 仍须执行。配置事务已通过下列合成服务测试，不能代替实际旧/新业务二进制的兼容验收。有界历史内存、恢复耗时/内存测量、缓存回收、运行详情有界分页、完整逐页 UI 与真实供给/库存研究继续属于完整单机目标。

## 默认执行器配置事务

维护入口新增 `Platform.ps1 set-engine -Engine source|historical`，只改变 Runtime 的 `DEFAULT_RUN_ENGINE`，不更换二进制或修改既有任务引擎。切换要求没有活跃任务、一个已就绪的本机 Runtime；启用源码引擎还要验证实际 Worker 使用的固定 runner/Node、数据库、Runtime 地址和服务身份一致，不能只靠各自的 `/readyz` 返回正常。

原配置和目标配置以 DPAPI 加密快照保存，唯一提交记录复用 Runtime 的 `pending` 发布记录。停止 Runtime 后再检查一次任务，原子替换配置，启动并验证候选及非目标进程，最后一次 catalog 写入提交。失败或进程中断可以使用 `Platform.ps1 release-recover -Service runtime` 恢复原配置；快照损坏、未知人工配置修改会在停进程前拒绝。提交后不能通过残留恢复请求倒退配置。仅变更这一字段且契约兼容的上一版程序同步配置哈希绑定，source 历史与 Worker 能力守卫仍决定能否真正回退程序。

本机证据 `default-engine-8bc9a073cd0a434ea1d8a286d2fb71bb` 的 **48 项检查通过**：真实 Windows 合成 Runtime/双 Worker、真实隔离 PostgreSQL 与 Owner 工作状态表；十个配置/恢复中断点、写配置后尚未更新阶段时中断、提交后拒绝重退、迟到任务保留、候选不健康、不同数据库/端点/身份的 Worker 拒绝、损坏快照/人工配置漂移保护、切换往返后的程序回退。另实际挂住持锁子进程以触发超时，确认精确子进程退出后取得锁，保留数据库并完成恢复，两个 Worker 不重启。最终临时数据库正常停止，进程记录为零。这里没有运行真实 Agent 或调用供应商。

原配置绑定 11 项复测见 `source-runtime-configuration-8176cb78106840e5a1490c6d8a8fcf6c`，原发布故障 16 项复测见 `windows-releases-7dc1026c0a184423b08b1e2fd4393347`，均通过。PowerShell 语法与 Go 格式检查通过。首次配置事务 45 项报告 `default-engine-8a14c85e1cc946e9ab769221a5b5877f` 仍保留。

独立评审发现并复核了三项修复：实际 Worker 的依赖绑定校验；默认值往返导致上一版程序配置哈希失效；故障测试子进程超时但仍继续删除数据库。最后一项现在要求确认子进程退出、取得维护锁并停止全部合成服务后才清理数据库；无法确认时保留现场并报告未完成。评审只做静态复核，没有冒充独立动态测试。配置快照暂不自动删除；正式资料/恢复材料的保留策略属于后续存储生命周期验收。
