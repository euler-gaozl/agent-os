# Windows final-v5 受管发布兼容

本轮接通确定性交付候选的受管构建、配置、启动与回滚；不改变历史任务引擎，不把测试中的合成服务写成真实模型验收。完整单机 Goal、报告内容缺陷和其余平台验收继续保留。

## 正式安装完成（最新）

五个完整受管包从干净集成提交 `2d8408d` 构建，staged set `af7048243ec048f5ac2c2c651a0a1b64`。下表五个源码版本已实际安装：Runtime → 两个 Worker → Registry → Console → Futures 的更新均 committed、鉴权就绪通过、非目标实例不变。默认已通过受管配置事务切到 `dsh-source-639ed015-final-v5`；旧引擎任务及可恢复任务计数保持，final 任务仍为 0。doctor 核心探测、status 核心就绪均为 true；Sandbox 隔离执行仍未配置。

安装前备份 `final-release-20261017-144403` 的完整隔离还原 `6c69c0155eea44eba3ec0ea241ec473a` 通过：45 张表/序列、数据库元数据/权限、10 个角色登录、3 项凭证解密、13 份来源归档及离线 Harness 重建通过。隔离库已停止，未启动 Worker 或调用供应商。原失败还原 `647d5aec2e784c7584cbbb0498ec5908` 保留。

该失败只涉及 `run_continuation_receipts_request_id_check`：PostgreSQL 把原 BETWEEN 转成嵌套 AND，重新解析 dump 后合并 AND，故只差一行括号。新兼容分支先比原完整 SHA；不匹配时必须验证真实 catalog 对象、精确约束全文和唯一完整行，仅重构已确认括号，再要求整份 SHA 等于受保护 manifest。没有改变原算法、manifest、ACL、owner 或其他结构；新报告明确标记 `continuation-request-id-and-shape-v1`。旧迁移计划仍使用原精确摘要，后续新迁移若遇到该差异须显式处理，不能跳过或复用旧计划。

`Test-RecoverySchema.ps1` 21 项通过：实际导出/还原、数据/元数据保持；边界、正则、AND/OR、NOT、ACL、授权选项、含 grantor 变化、owner、字段、其他约束、NOT VALID、重复匹配及错误表身份均拒绝。证据 `final-release-81cc547c587540d5a3cae53d775e9665/schema-test-626a2f680feb486cab85ede794365ad3`。初次合成夹具缺末尾逗号的失败保留；修正为实际约束位置后通过。独立静态评审未发现 P1/P2，未代跑数据库。

正式页面已刷新：中台供给与库存 v19 的模型能力/交付方式可显示；切换原文交付后显示 draft 和 structuredContent.ready；无效工具名保存被拒绝，临时输入已丢弃。期货首页及原研究列表可显示。这不是完整页面、窄屏或真实业务验收，未提交新研究或调用付费模型。

**接续重点：** 正式 Agent 仍为 v19、Skill v8，尚未绑定 final_output。先统一旧复制全文提示与新交付机制并发布固定资源，核对历史版本保持；离线修复 R2 内容缺陷后再做一次有界真实研究。原 107 项提示及事实错误保留。完整 UI、Console 业务入口 URL、权限退役、生命周期、故障/资源、升级后新状态备份和一次统一 CI 仍开放，不以服务安装代替完整交付。

用户要求保留约 20–30% 额度，本轮按保留 30% 收紧，只处理交付缺口，不重复已通过的检查。查询时剩余 44%；用户明确要求继续交付，未授权暂停 Goal。私有证据入口仍为原 Windows `ops/final-release.path`，不得提交私有材料或移用为其他电脑状态。

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
