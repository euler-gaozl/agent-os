# Mac 失败任务只读接续预览（2026-10-15）

Runtime 已实现并在本机安装只读接续预览。Owner 回归通过；对本机两个历史 HTTP503 失败任务仅返回候选分类，未执行续跑。完整接续和业务验收仍开放。

环境：维护者独立 macOS 15.3（24D2059）/arm64、Go 1.27.2、Node 24.19.0、PostgreSQL 18.6。延续[Console 与受限工作状态恢复](macos-console-native-and-state-recovery-20261015.md)，不改原 Windows 和旧 Mac 历史。

## 新增观察接口

Runtime 新增 control 专用 `GET /v1/runs/{id}/continuation`，协议 `failed-run-continuation-preview-v1`。`read_only=true`、`action_available=false` 固定；`same_run_candidate` 只表示本次保留证据符合窄范围条件，不是续跑许可。现有 failed `/resume` 与 waiting_unknown 的 `/resume-source-state` 仍是其他入口，均未由新GET加上执行守卫；Console/Futures 未接入新预览，也未新增执行动作或自动调度。

正向范围仅 native-v4 根任务：failed、未取消、全族无未决外部效果/模型调用、子任务终态，整个冻结配置有效、归档确认元数据及连续冻结帧齐备，最后未回答模型帧的 call/当前 attempt 与完整保留 HTTP503 native 回执相符，规则修订未变。重试同一失败帧仍是同一轮，因此模型帧数允许等于原 MaxSteps；全族所有状态的模型尝试数须严格小于冻结 MaxModelAttempts。没有新增额度或把未知 usage 清零。

其他情况按证据分类 blocked、manual_review 或 not_applicable；manual_review 不等于旧引擎不可恢复或必须新建任务。所有读取来自一个10秒有界 REPEATABLE READ READ ONLY事务，不加执行锁或保留预算，不访问Registry/Storage/供应商。SQL在传输前对snapshot/input/request按32MiB、receipt envelope按64MiB设界，解码body仍限32MiB；JSONB文本极限可能保守转人工分析，不改变native协议。实际Storage字节、当前工具治理/供应商状态和费用均未探测。

## Owner 实际验证

本轮新增6个顶层测试，加1个既有peer权限测试，共7顶层及17子项通过，0fail/skip；race包结构化 elapsed 4.327秒、命令exit0。受测5个Go文件的source-set SHA-256为 `2c49c04472b5b9a32f28959e7a1c91776b3839c480628a6c27cea75e5d45a313`。正常API产生正向失败和预算边界，5个坏记录负向场景明确使用损坏注入。重复预览核对12张相关表、usage和外部回调计数不变；一致性测试由另一参与者用旧显式resume/Claim制造新尝试，首个GET保持旧快照，随后GET看到新预算状态，不能把该参与者动作写成GET副作用。

这是进程内Owner、真实隔离PG/HTTP授权、NOLOGIN SET ROLE池、合成模型回执和内存归档。没有官方DSH/Node、独立Worker/Storage或真实供应商调用；静态字节界限不等于已测并发峰值内存。历史引擎、超限记录、畸形族谱和全部冻结回复组合未穷举，完整接续仍开放。

## 来源、安装与观察

Runtime 本地提交 `879c5034ad556e37f1c987312eb4124b3c4806b6` 归档5个Go文件及README；受测源摘要与归档对应。 包来源从旧安装 `e6c8b935` 单独追溯：到受审基线 `606fbc8a` 只有README和4个测试文件差异，本轮生产变化为4个Go文件的新增预览/路由/权限实现。`go vet -mod=vendor ./...` 和 `go build -mod=vendor ./...` 已实际exit0，`root-go-checks-attestation.json` 是随后记录原工具退出结果，不以空日志冒充回执，未补跑或追记耗时。`root-source-verification.json` 将源码、测试、14跨仓guard和清理摘要绑定；其首次核验错误比较了含时间戳的整个服务快照，在写出前停止，随后只修正为十个实例身份/文件摘要比较。

仅 Runtime 更新为 `879c5034` 的本机 darwin/arm64 包 `20261015-continuation-preview`，包 manifest SHA-256 为 `1942749e2442092c5643cb3b0f8fe08c97b670d14af42d02c26951cb648cfca2`。07:26:06Z 安装回执记录 PID28052、control 认证 readiness 200；随后十实例存活快照核对其余九实例逐对象相同，Runtime 配置及固定 Harness 摘要相同。四个命令均构建，但 migrate、retire-access、healthcheck 未执行；没有迁移、权限退役或配置改写。Runtime 启动会正常自注册/心跳写入 instances，不能声称整库无写。

`live-v3-before.json` 与 `live-v3-after.json` 记录安装前后及各观察段两端的12张指定任务/笔记表全行摘要与完整4项终态任务列表相同。安装后4次预览GET中，2项 completed 为 `not_applicable/already_completed`，2项本机 failed 为 `same_run_candidate/retained_transient_model_failure`；后者均为逻辑轮次1/12、家族尝试1/12、保留HTTP503。观察器该段另做2次任务列表GET和2个只读SQL事务；没有模型调用、任务提交或resume。比较排除 instances 及其他表，HTTP和SQL快照不是一个原子窗口，也无提交锁；只证明这些观察点摘要相同，不证明全程没有瞬态变化。接口自身只读另由READ ONLY事务和Owner测试约束。候选不证明供应商恢复、归档原文现时可读或报告完成。

观察器失败证据保留：v1因守卫遗漏已固定的 `search_path=public` 在任何HTTP/SQL事务前退出；v2修正参数后，psql确有连接尝试，但PGDATABASE中的URI未展开，误走默认5432的缺失socket，未连目标55432，不能称零连接尝试。v3仅把连接参数拆为固定本机host/port/database与私有环境凭证，保留readonly/public及全部pin守卫；未修改服务配置。两次失败属于本机观察脚本，不是新预览接口或供应商故障。

隔离 Owner 夹具清理后库、角色及连接残留均为0；测试前后原十服务身份/文件摘要一致。设计、代码、实际测试、包来源和安装/观察分别经过独立审查；最终审查只复核保存的执行记录、控制脚本及实际二进制摘要，没有重新连接PG/HTTP、读取私有配置或再次安装。最终报告 `continuation-live-execution-independent-review.md` SHA-256 为 `3bbcfa0c808b6e6c60bad6d42874a6fe91251aee1211804a63e11a498814eeed`。证据集中在本机 `local/evidence/macos-continuation-preview-20261015`，安装回执另在 `local/evidence/mac-runtime-package-20261015-continuation-preview`；旧失败与各阶段审查记录保留，未提交本机证据或配置。

## 保留范围

P0/P1/P2/P2.5/P3/P4/P5、W01–W14全部原范围与既有状态保留。仍需执行时加锁重验、幂等动作回执与丢回复回读、受控自动接续策略、配置变更后的新任务承接、前端交互与真实业务验收；预览不是这些任务的替代。研究成稿/质量、完整UI、服务/权限退役、生命周期和持续资源、最终统一CI继续按计划。没有浏览器或新真实模型验证，不宣称供应商恢复；Windows DPAPI、受管发布、原库恢复待目标环境复验。旧快照、固定DSH/Worker编译协议、部署pins和历史证据不变，未推送、未运行Actions。
