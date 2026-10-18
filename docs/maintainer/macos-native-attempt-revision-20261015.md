# Mac native 模型新尝试的规则修订守卫（2026-10-15）

已修复 native 旧冻结模型意图在规则变更后仍可新增尝试的缺口，并升级本机两个 Worker。Owner 与实际旧/新 Worker 对照验证通过；完整接续动作及 UI 仍开放。

环境为维护者独立 macOS 15.3（24D2059）/arm64，Go 1.27.2、Node 24.19.0。延续[只读接续预览](macos-continuation-preview-20261015.md)，保留此前 Mac 及原 Windows 记录。

## 缺陷与执行位置

旧 native model exchange 在失败或尚未发送时已冻结规则 R1；模型意图冻结后，正常 Constraints 将约束修订为R2。再执行该意图时，Exchange 刷新内存 Run 修订，却保留R1请求，使原有 BeginModel 当前修订比较仍能通过，错误准入一个新的旧规则attempt。实际Worker夹具在resume之前修改约束；同类窗口也可出现在排队后，不能由此前只读preview分类关闭。

Runtime 源码提交 `1f6c4c29c62bac3ad6d674b7797a7410f373bf00` 仅增加16行生产 guard：在持有运行行锁、completed cache 返回之后、预算预留与任何新 attempt/call/event 写入之前，核对 native exchange 原修订与锁内当前修订。过时返回普通错误 `native model intent constraint revision is outdated`，不是 ErrFence 或外部效果未知；失败重试与第一次尚未发送的旧 intent 同样受限。旧请求、成功缓存、已冻结回复、原失败回执及未知 usage 不改写，旧引擎与固定 DSH 协议不变。

准入事务是判定时点。守卫不能撤回已提交准入的 HTTP，也不承诺 Constraints 返回后绝无旧在途请求；这些调用的回执与费用仍须保留。它也没有新增幂等接续动作、自动调度或 UI。

## Owner 实际证据

四个新测试使用正常 Submit/Claim/Exchange/BeginModel/EndModel/CheckpointFailure、旧显式 resume 与 Constraints 构造，SQL仅读取证。旧源码2 fail/2 pass（race，1.089秒）；唯一生产 guard 加入后4 pass（2.090秒）。两个旧失败为过时失败重试和过时未发送 intent 错误地继续准入，不是构建或环境失败。两个兼容场景为成功 cache 后续冻结/重放，以及同修订重试保留原503与 unknown usage。

相邻回归32顶层、38子场景通过，race 34.000秒，零 fail/skip；这不是全仓全测。`go vet -mod=vendor ./...` 与 `go build -mod=vendor ./...` 均实际exit0。保存的十实例对象与基线相同，隔离夹具库、角色、连接均清零。

Owner 使用真实隔离 PostgreSQL、NOLOGIN/SET ROLE 与 execution API，但模型为合成 callback、archive 为内存；没有实际 Worker/官方 Node/供应商 HTTP。modelCalls 是合成发送计数。成功 cache 测试验证 PlanRevision 不得提升到新修订，没有单独精确断言旧数值。独立审查解析实际 JSONL、核对源清单与摘要，没有重新连接 PG 或重跑测试。

## Worker 编译来源与实际环境

Worker 在本进程使用版本化 execution 包直接执行 BeginModel/Exchange；Runtime HTTP 换包不会替换该代码。本轮 Runtime 源码 `1f6c4c29` 是 Worker 编译依赖；Runtime HTTP 实例继续使用已安装 `879c5034`、包 manifest `1942749e2442092c5643cb3b0f8fe08c97b670d14af42d02c26951cb648cfca2`，本轮不重新安装它。

新模块固定为 `v0.1.0-rc.5.0.20261015080014-1f6c4c29c62b`；模块ZIP、Go校验和、vendor与精确Git来源已逐项核对，没有replace或在rc.5标记下暗改vendor。固定图元数据经第三方 goproxy.cn 获取，随后 verify/vendor/build 才离线执行，不能宣称全流程离线或checksum database认证。首轮缺已锁 testify1.3.mod 元数据的失败保留。

Worker 本地提交 `94d605910e0c3da011bb1213b516150ecb5fe1ba` 相对 `ff9a2f07` 为六项依赖文件及README，SDK及第三方vendor字节保持。Runtime传递差异包括16行新guard、既有只读preview及store.go原有29行native/legacy提交分流，不能把整个模块升级简写成只改16行。verify/vendor/build实际成功；Worker vet exit0来自随后记录的原工具结果，不冒充原始命令回执。

Mac包 `20261015-native-attempt-revision` manifest SHA-256为 `384952564182170e6d12ff4bebf6bc4967d133413f2916a73cabf347f9ac1766`。独立审查绑定源码归档、vendor及实际二进制build-info，确认darwin/arm64、Go1.27.2与精确execution依赖。构建helper首轮误判Runtime根有LICENSE，在创建包/编译前停止；修正真实文件集合后成功，原失败保留。healthcheck仅构建，未执行。

另以真正独立的旧/新Worker可执行文件、其内嵌execution与固定官方Node Harness运行3个场景。Runtime HTTP/隔离PG是真实执行，模型为有界loopback TLS，归档为fixture；没有真实供应商或真实Storage服务验收。所有状态由正常API产生；每场景先自然HTTP503失败并退出首Worker，再通过旧显式resume与正常Claim由第二Worker接管。该resume只用作测试参与者，不是新接续动作。

| 场景 | 合成模型HTTP / attempt / unknown-usage attempt | 结果 |
| --- | --- | --- |
| 旧rc.5 Worker，规则已变 | 2 / 2 / 2 | 原冻结请求仍被重新发送，任务failed，证明缺陷 |
| 新Worker，规则已变 | 1 / 1 / 1 | 拒绝第二次准入，任务failed，原call/attempt保留 |
| 新Worker，规则未变 | 2 / 2 / 1 | 正常重试completed，原503未知usage保留 |

首轮三个子项1 pass/2 fail，原因是将JSON原始键序当作不变要求；原始线字节确实不同，失败没有删除。v2只修测试为完整JSON值规范比较，并与冻结exchange及所有call/attempt请求绑定；不删除字段、不改变数组顺序，原始哈希照存，未改生产源码、pin或二进制。v2为1顶层/3子项通过，测试驱动race，包4.917秒、命令exit0、零fail/skip；独立Worker产物并非race构建。十个常驻实例与基线仍相同，6个夹具PID已消失，夹具DB/role/connection均0。

该夹具及README随后归档到Runtime测试提交 `5017de09c37f50da270b1873c2dcf73439330653`；它不是Worker依赖提交或Runtime HTTP安装版本，Worker仍固定依赖 `1f6c4c29`，HTTP仍为 `879c5034`。

08:38:46Z 两个常驻 Worker 已按该包逐个替换，PID为35532/35795，安装命令exit0。配置及固定Harness保持；其余八实例包括Runtime HTTP未替换。安装中的8个只读SQL观察均为runs4、nonterminal0、calls21、model_attempts11、exchanges70、archives70，另有8次认证ready GET。标量计数与进程检查不是原子快照，不证明行内容或整库不变；正常instances心跳仍会写入。没有迁移、任务修改或模型调用，这仍是Mac开发包而非Windows受管发布。

08:40:20Z 的独立一轮本机观察再次确认十实例存活、两个新Worker认证ready200及build-info对应该包，原两个PID消失，八个非目标对象与基线相同。实际探测由root执行；独立审查只复核保存的源/归档/运行回执及摘要，没有另行连接PG/HTTP、读私有配置或重复安装。最后安装独审报告 `worker-install-execution-independent-review.md` SHA-256为 `c93ca4214d5c4df4580096328473beba0e33256c13d4f7fe233b9ba69cb170d5`。本机证据集中于 `local/evidence/macos-native-attempt-revision-20261015`，包括首次失败、v2实测、逐目标安装和最终观察；未提交配置、数据库或私人证据。

## 保留范围

完整 P0/P1/P2/P2.5/P3/P4/P5、W01–W14 的原范围与状态保持。接续仍需事务内重验、幂等写动作与丢回复回读、受控调度及真实 UI 流程；本 guard 不能代替这些工作。研究成稿、引用/日期/统计口径质量、服务与权限退役、存储生命周期、持续资源、Windows DPAPI/受管发布/原库恢复和最终统一 CI 继续保留。没有新的真实供应商或业务验收，不推送、不触发 Actions，不覆盖旧安装组合。
