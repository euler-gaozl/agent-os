# Windows final-v5 受管发布兼容

本轮接通确定性交付候选的受管构建、配置、启动与回滚；不改变历史任务引擎，不把测试中的合成服务写成真实模型验收。完整单机 Goal、报告内容缺陷和其余平台验收继续保留。

## 固定组合

| 服务 | 候选源码 |
| --- | --- |
| Runtime | `92d105ad27534c81b0a0675eb1c8a354d3c72f68` |
| Worker | `c828bbccbb9903ff20c47e6b0e5201124d810f2b` |
| Registry | `6053f9cb5201c42ecef78c702a9c9be6f320c9f6` |
| Console | `6baf4e03820e35c00666e5b49a6a942f893edf8f` |
| Futures | `8b948636e10bc0d435aed21cd8f3843b6f669f23` |

Worker execution 固定 `7805a48`，Harness final-v5 固定 `696c019`。Runtime 的后续提交只增加管理接续和发布声明；此前完整独立进程联调使用同一 Worker，不能因为 Runtime HEAD 改变就擅自更新执行依赖。`deploy/service-sources.json` 记录候选构建组合，正式安装以本机受管 catalog 为准。

## 发布边界

- `build -FinalArtifact` 必须与 Worker 编译 pin 的 manifest、上游和每个文件摘要一致。五个源码引擎各自进入资产清单、备份、恢复和启动配置；`DSH_FINAL_RUNNER` 不能从服务配置任意覆盖。
- Runtime final 能力必须保留 v1–v4、模型回执协议 2、`receipt-field-v1` 与显式 final 模型接续。完整 final 默认还要求 Worker 带 native-v4、budget-v3，分别承接无交付策略和历史 Agent 树。
- 每个保留 final 任务阻止 Runtime 回退；失败和未知状态仍视为可恢复，阻止移除最后可用 Worker。配置切换和非 Worker 更新检查实际运行的每个实例、固定 runner/Node、同域独立账号、Runtime 地址和服务身份。Worker 更新仍要求旧实例及后代全部停止。
- Registry/Console CLI 声明必须与清单完整一致，不能用旧两字段声明掩盖新写能力。存在 Runtime 时，新 Registry 必须先配套 final Runtime，避免查询时还没有 final Agent、随后却写入首个策略的窗口。独立 Registry 无 Runtime 的部署仍允许。
- Registry 查询全部保留 Agent 版本，不只最新版本。旧 reader、旧 Console 和 Runtime 的不兼容回退会拒绝；Registry 停机后排空后台事务，再读取事实，客户端退出不等于事务已终止。
- 零实例更新/恢复同样在停机后重查任务事实，不能只靠启动脚本检查。原 pending journal、DPAPI 配置恢复、旧版本和文件篡改检查继续使用。

顺序为 Runtime → Worker → Registry → Console/Futures，再发布固定业务资源、核对实际实例并切换默认。Runtime/Worker 的既有模型修订 guard 与 Owner 回执迁移仍是前置条件。配置切换不会改旧任务或替换旧 Agent 快照。

## 验证与状态

`Test-SourceExecutionRelease.ps1`：147 项通过；真实五套固定 Harness 复制/导出/还原及篡改拒绝、合成绑定策略、真实 PostgreSQL 最小权限查询与 Owner DDL。不是 Agent 业务执行。证据 `source-release-policy-2dba3391a65a4ffba258b8f9f641b7db`，隔离库停止成功。

`Test-ModelManagement.ps1`：68 项通过；实际新旧 Registry/Console CLI、受限 PostgreSQL 与发布维护入口，覆盖历史版本、独立 Registry、完整声明、备份恢复、冷启动、回滚、pending 恢复、停机后晚写，以及客户端被结束而数据库仍完成延迟 COMMIT。证据 `final-release-81cc547c587540d5a3cae53d775e9665/model-98a20c4d49e347af98863c8ec50080be`。测试中的拒绝保留 pending 是预期结果，非正式服务故障。

`Test-DefaultEngine.ps1 -Candidate final`：53 项通过；Windows 合成 Runtime HTTP 服务和两个 Worker 进程、实际数据库、DPAPI 配置事务，在 prepared、stopped、configuration_replaced、configuration_written、started、ready、committed 及恢复三个阶段强制结束后检查 journal/配置/进程。覆盖无就绪 Worker、错误端点/身份、活跃/晚到任务、不可解密恢复材料与无关配置漂移。证据 `default-engine-ad29ef0f1538475aaf9af9d4c5b5574c`。这是发布生命周期验证，未执行实际 DSH/供应商；该联合执行见前轮记录。28 项旧接续发布兼容检查也保持通过。

测试前正式执行中任务为零，暂停售 Runtime/两个 Worker；结束后恢复原发布号、配置和三个实例，非目标实例不变。测试进程记录归零，隔离数据库停止成功。初次 fixture URL/缺少回执表等测试准备失败及正式实例阻止隔离同角色启动的记录保留；修正夹具并通过正式停止/恢复入口重测，没有绕过进程隔离限制。

当前未安装候选，未新增付费模型或 Actions。私有证据入口为原 Windows 的 `ops/final-release.path`，不适用于其他电脑。

独立 Agent 发现并关闭 `final_harness` 资产白名单遗漏和 final Registry/Runtime 写能力顺序两项问题，收尾静态复核未发现新的 P1/P2。其未运行数据库或真实进程测试，不能代替下面的本机记录。

后续为完整受管包构建、最新备份/隔离恢复、正式升级及浏览器，随后按内容缺陷离线预检再安排一次有界真实研究。此前临时 Vite 浏览器夹具启动的自动审批拒绝仍保留；没有绕过，也未把该轮浏览器验收算通过。其余权限退役、生命周期、资源/故障、全貌 UI 和最终一次统一 CI 保持原范围。
