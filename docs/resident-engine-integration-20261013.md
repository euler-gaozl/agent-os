# Resident DSH 双版本接入与独立包验收

2026-10-13。Runtime/Worker 已接入并完成本机真实进程测试，后续完整双版本发布已实际安装，默认执行器仍为 state-v1。集成发布控制器的双版本校验、六次实际升级/回退、默认 resident→source 往返及完整备份隔离还原通过，见[Windows 发布控制验收](windows-resident-release-20261013.md)。尚无正式 v2 供应商任务，完整 Windows 单机目标仍未完成。

## 版本与边界

| 项目 | 固定身份 |
| --- | --- |
| Runtime 执行模块 | `v0.1.0-rc.3` / `3fbbb52b37c91c042c8fb9a12b1ab69692a76d5a` |
| Runtime 后续进程测试记录 | `8404f3e0ad3d62c3742a5eba4b996b1f88a6e8b0`；模块实现未再变更 |
| Worker 独立包 | `346c0032921b1f45e3b300c4716ed9551da9c133`，干净构建 |
| resident-v2 Harness | `439b9086155383a4b4cb19c261ac6690ab02a352` |
| resident-v2 内核 SHA-256 | `be1b87c92a7b9b1dae332a10115ef04ddd676a2aa82e90d02c2943e296c9932c` |
| resident-v2 manifest SHA-256 | `c48cb0675e30d4be6fc00d42a4f6ebff78487ac36eef54761991b197ee139ba4` |
| 保留的 state-v1 Harness | `ec21432a91ad1b5b8081aed6aea854363080a6b7` / 原有 manifest pin 不变 |
| 升级接管测试中的旧 Worker | 已有正式包的 `70d45cd1ef2e08def4450f3be8b003b51401b72f`，构建记录干净 |

Runtime `execution.New` 仍只领取三个历史引擎，`NewSourceEnabled` 仍只额外领取 state-v1。新增 `NewSourceVersions` 只接受明确的 v1/v2 版本，拒绝未知及重复项，不保留调用者的可变切片。Worker 只有在相应产物校验通过后才启用该版本的领取；支持 source 协议不等于授权领取所有 source 版本。

Worker 保留 `DSH_SOURCE_RUNNER`，新增独立的 `DSH_RESIDENT_RUNNER`。两个编译 pin、目录与验证句柄分开，按任务的固定 engine 选取，每次启动 Node 前再验，缺失、互换或篡改均拒绝，无隐式回退。普通模型请求最终序列化预算、失败末批归档、工作状态和工具来源回执覆盖两版。Node 仍没有数据库、服务或模型凭证。

Runtime 同时覆盖两版的增量归档、checkpoint、工作状态冻结回包、未知状态恢复与取消。Exchange 在首次读取及行锁内核对调用者 engine 与数据库原值，错配在意图/归档/效果前拒绝；不静默改写。根任务部署选项可识别 v2，但原任务幂等重试及子任务保持既有版本。无新增数据库迁移。

Worker 使用 Go 根据远端已核对的提交/tag，通过隔离 Git 镜像生成的规范 Runtime 模块；`go.mod`、`go.sum`、provenance 和窄 vendor 一致，没有本地 replace 或复制 Runtime HTTP/迁移实现。模块原始记录为 `local/evidence/runtime-canonical-module-rc3.json`；Go module sum 为 `h1:hiYj7qbNcoJ6IkXW3ux00alzJ0eUB6Krgx1phgRr1sw=`。

## 实际检查

| 证据目录（相对于 local/evidence） | 已执行与范围 |
| --- | --- |
| `p25-resident-runtime-75cd1e2ff8a64746b2cb17ba67b59999` | 79 条通过记录（含子用例）、零测试跳过、vet/build；实际隔离 PostgreSQL、受限角色和 Runtime HTTP。两版状态/归档/丢回包/恢复/取消、领取集合、engine 错配、提交幂等和子任务继承。归档/effect 为夹具。 |
| `p25-worker-resident-unit-b847ca3ea20c4d378c241b948badb6e2` | 53 条通过记录、零测试跳过；错 pin、产物互换、验证后篡改、版本缺失、最终预算及已有 Worker 回归。verification.json 绑定测试日志与源码哈希。 |
| `p25-worker-resident-6a61fe5d1e7f4e9ebf2c71de2f2eaf36` | 七个实际 Worker/Node 进程场景，vet/build 与窄依赖检查通过；实际 PostgreSQL/Runtime HTTP，尚从开发产物路径运行。 |
| `p25-resident-worker-package-b5d8deaceba94d3ea098393154fe9add` | 离线生成完整 Worker/Node/npm 历史 Harness/v1/v2 包；清单保存文件哈希，两 source 版本分别核对编译 pin；实际搬迁后原包根目录不存在，历史两种 npm 协议 smoke 通过。 |
| `p25-worker-resident-9646a337349a4343b6568d2a7c5fa408` | 从搬迁后的完整包再次运行同七个进程场景，全部通过且零跳过；不是新增七类故障。包文件清单、Worker clean commit、两个 source manifest、旧二进制 hash 和进程日志均留存。 |

七个场景是：v1/v2 各自的“状态 revision 2 与 Exchange 回复已提交、发送回复前强杀 Worker”“断开 HTTP 回复但不杀 Worker”“连续三次丢回复后进入 waiting_unknown，经受控恢复继续”，以及旧 `70d45cd` Worker 的 v1 任务强杀后由新双版本 Worker 接管。最后一项证明旧任务继续跑原 v1，不能称为跨引擎迁移。

各场景实际发生一次 DSH Compact，保存 69 批归档、475,098 字节事件，工作状态仍有两条版本；归档链连续、无未确认暂存，已提交模型/工具/状态操作未重复。强杀接管 fence=2，存活重试 fence=1，重试耗尽恢复 fence=2。摘要故意省略的日期/数量仍通过冻结工作集进入后续请求。原模型和工具源内容都是合成验收资料，不是期货事实。

模型、ToolHub 路由和不可变 Storage HTTP 是受控夹具；数据库、Runtime HTTP、Worker/Node、强杀和 HTTP 连接中断为真实本机动作。两个测试集群运行结束均已停止；开发候选 Node 进程检查为零。没有付费供应商调用或 GitHub Actions。首个 `go mod edit` 命令因 PowerShell 未引用完整参数失败，修正引用后规范依赖生成成功；该命令解析失败没有被计入测试通过。

独立代理只读审查版本路由、代码及报告，确认 v1 pin 未变、规范模块/vendor 一致、故障位置确在提交后回复前、未重复效果断言存在；没有代跑测试或调用供应商。发布包复核记录另存本地证据，不能把静态审查称为运行验收。

最终发布包只读复核确认：1,483 个清单文件哈希全部匹配，无链接或重解析点，原目录不存在；Worker 为干净 `346c003` 的 Windows/amd64、CGO=0 构建，Runtime 固定 rc.3；联合报告的包路径和二进制哈希匹配。没有阻止未部署候选分支发布的问题。Runtime/Worker 均已推送，Actions 禁用状态已复核。

## 未完成部分

集成发布控制器已实现 v2 独立能力、固定产物、按版本历史与配置守卫，完成 55 项策略检查、v1/v2 各 49 项配置中断检查和 11 项配置漂移回归；完整包实际安装、六次独立升级/回退、默认配置往返和隔离备份还原均通过。Runtime 保留已有版本的回读；Worker 根据默认值及可恢复任务限制回退。下一步实际 v2 Agent/供应商任务与业务验收，当前正式默认仍是 v1。

原生 Session checkpoint 快速恢复、可重建缓存生命周期、联合服务的长历史资源测量仍待完成。此前内核强制 GC 固定负载测量不能与这次小型故障夹具拼成全平台内存硬上界或生产性能证明。P2 旧源码/权限退役、P3 逐页完整 UI、P4 剩余故障与 P5 真实供给库存研究仍按完整计划推进。
