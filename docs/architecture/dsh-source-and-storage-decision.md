# DSH 源码与 Agent 存储系统决策

2026-10-12；服务于 Windows 单机交付。此文区分已核实事实、当前决定和待实现内容。

## 决定

建立独立的私有 `agent-os-harness` 源码维护仓库，记录上游来源、精确提交、许可证、依赖锁及本平台补丁，提供 Worker 消费的固定版本构建。维护的是可复现的 DSH 内核组合和本平台插件，不另造一个模型/工具决策循环，也不导入 DSH 整套 Web/CLI 作为本平台前端。

存储与恢复是 Runtime/Harness 的明确职责，不能仅由提示词让模型“记得保存”。优先在 DSH 已有 SessionPersistence、flush、Compaction 和 Projection 扩展点实现；只有扩展点无法满足经测试确定的持久化顺序、内存边界或恢复条件时，才改 Session/AgentLoop 内部，并保留最小、可独立测试的补丁。**源码纳管确定纳入计划；大幅改写 Loop 不作为前提，也尚未获证据支持。**

## 已核实事实

1. 当前 `harness/package.json` 固定官方内核包 `0.2.0-rc.2`，`runner.mjs` 直接组合官方 AgentLoop、Session、Tools、Projection 和 Compaction；Go 管租约、模型/工具 HTTP、持久化回执。它不是完整官方 CLI，也不是自行重写 DSH Loop。
2. 现有适配器每次 model/tool/finish/failed 桥接前保存新增事件，执行域提交意图/暂存后才确认 Storage 并执行外部调用。已有约 18.9 MB、16 次 Compact 和进程中断回放测试，但原始会话事件仍在 DSH 内存中，不能称内存有界。
3. 本机固定包的 `Session.append` 将事件追加到内存日志；`session/event` 是追加后的通知，异步观察者失败不能撤回 append。`ctx.sessions.flush(session)` 是可等待、可拒绝的扩展点。仅监听事件不等于已持久化。
4. 当前 `runner.mjs` 未接入完整的原生 SessionPersistence 后端或相应 checkpoint 插件；`snapshotEvents()` 仍物化全历史数组，再选增量。我们已有桥接回执保护，不能据此声称所有 DSH 内存事件都已立即落盘。
5. 压缩模型消息投影会遮蔽旧消息，但不从原始事件日志删除它。上下文 token 占用、Node 的内存事件集合、数据库/文件资料是三个不同问题。
6. 实际执行 `node --test harness/session-seams.test.mjs` 三项均通过：flush 等待持久化参与者、持久化失败向等待者报错、消息投影替换后原事件仍保留。这是固定包扩展接口的特征验证，无模型调用、无磁盘持久化，不冒充完整存储实现或内存压力测试。

上游目前明确处于开发预览，可能破坏兼容；它的设计允许替换包括 loop 在内的插件。上游文档提供持久化、flush、spill 和 compaction 的职责说明。[官方仓库](https://github.com/deepseek-ai/deepseek-harness)、[架构](https://deepseek-harness.github.io/deepseek-harness/reference/)、[持久化](https://deepseek-harness.github.io/deepseek-harness/reference/subsystems/persistence)、[Spill](https://deepseek-harness.github.io/deepseek-harness/reference/subsystems/spill)、[压缩](https://deepseek-harness.github.io/deepseek-harness/reference/subsystems/compaction)。当前文档和 master 不自动等于已安装 rc.2。

npm 对该 Session 版本的元数据没有 `gitHead`，相应版本标签查询未返回结果，因此尚未证明哪一个上游 commit 与已安装包字节对应。保留当前锁定包作为旧任务执行器；新源码版本必须记录真实基线并单独验收，不能把当前 master 冒称原 rc.2 源码、直接替换未完成任务。分发保留上游 MIT 许可与必要第三方声明；不是把公开 fork 当私有仓库。

### 2026-10-13 源码基线增量

重新核对官方 tag API，现可定位 `dsh-v0.2.0-rc.2` 到 `639ed015397290b3745d163aafe02ffee4aa3f84`。这里补充新的查询证据，不把同版本文本当作 npm 包字节等价证明。官方固定提交 ZIP SHA-256 为 `add3d2079092810d682bdda5a18fa3b4c76cb595137067b8928b34b07d46375f`，本机缓存保留。

`repos/agent-os-harness` 已建立本地独立 Git 仓库，源码候选提交 `d39fc3b`。导入实际内核依赖路径涉及的 21 个完整包目录及根许可证/说明，共 342 个上游文件；`upstream-lock.json` 逐文件记录哈希。固定 esbuild 0.28.2 和 Zod 4.6.5，从 TypeScript 编译，没有把 DSH npm 产物换个目录冒充源码。没有导入上游 Web、CLI、Desktop 或 Python SDK；原上游字节保留，本平台代码与打包转换分开。

独立评审发现上游 attribution 用 `createRequire(import.meta.url)('../package.json')` 读取版本，初版组合产物借用了平台 manifest，脱离源码目录实际失败。已用 `patches/inline-package-version.mjs` 精确内联锁定的原 LLM 包版本，构建清单记录转换代码、原文件、元数据与转换后哈希；不改写上游基线。失败复现保留于 `local/evidence/dsh-source-baseline-733f4828a9db469f91c2ff80c2764d97/missing-package-repro.tap`。

初次源码基线报告 `local/evidence/dsh-source-baseline-53985dbcc54240a297df266faba7d74e/result.json` 的 5 项检查通过，但评审发现产物夹具仍在 checkout 内，祖先依赖与工作目录可能掩盖文件查找。随后提交 `6f018a2` 将夹具移至仓库外，逐祖先拒绝 node_modules/package.json，子进程以产物目录工作、关闭全局模块查找并不继承 NODE_PATH。复验 `local/evidence/dsh-source-baseline-bb2d255e83dd4fd0830e67e51354a337/result.json`：独立克隆离线安装、两个绝对目录编译产物和清单/许可证字节一致，5 项真实 Node 检查零跳过；实际覆盖模型→工具→结束回执、flush 失败、surface 替换后原事件保留和修改上游字节拒绝构建。独立静态复核确认该隔离缺口关闭。独立性结论只覆盖此受控桥接路径，不是沙箱或全框架证明；没有运行上游全量单测或完整类型检查。

另以现有真实 Worker `b07b739` 加载该隔离源码候选，长历史中断测试 `local/evidence/p2-worker-evidence-a2e180f890724de1ac1620c60335fea8/result.json` 通过：18,874,181 事件字节、40 批、16 次 Compact；回查回执提交后杀死进程，fence=2 接管、找回摘要遗漏的来源、重新读原文，已提交模型/回查无重复。实际 PostgreSQL、Worker 和 DSH；模型、ToolHub 路由与 Storage HTTP 为夹具，零付费调用，测试集群已停止。两个进程都使用源码候选，不是旧 npm 与源码间的跨版本重放验证。

本增量没有正式部署、注册新引擎、完成持久化插件、结构化工作状态或有界内存。旧 npm 引擎和运行版本仍固定；P2 尚有覆盖退役条件，P2.5 的后续实现与验收继续按下文推进。

### 结构化工作状态后端增量（尚未接 Agent）

Runtime 新增独占 `run_working_states` 追加表。不能把它嵌入 `runs.state`：旧 Worker 的 Save 会用旧结构整体覆盖该字段。新表只给 Runtime SELECT/INSERT，Worker 没有直接权限。用户 task/constraints 从现有运行表投影；工作集只保存派生问题、观察/计划/第三方预测、冲突和待办。提交限定 32 KiB、条目和文本上限、严格字段/枚举并拒绝重复 JSON 键；没有“模型写入即已验证”的状态。

写原语复用运行行锁，校验 owner/fence、取消、当前 rule_revision，再做 expected_revision CAS；原版本、稳定回执及不含正文的审计事件同事务。按 run+operation_id 幂等，哈希针对已验证结构且不包含可变 owner/fence。接管/取消后可单独找回回执，不因此取得写权限。观察引用在同一事务核对 calls 的本 run、tool、completed 与非空结果，并保存结果的规范化 SHA；完成回执不等于工具成功或内容真实。按版本保留历史，约束变更时旧工作集明确 stale；仍不声称总磁盘历史或 Node 内存有界。

HTTP 只向 control 提供当前/历史版本及指定操作回执读取，显式阻断 ToolHub/Knowledge 原来的通配 run-read 权限。当前没有管理端写接口，也没有向旧 builtin 或 DSH 引擎开放该写方法。下一阶段必须连同新版工具授权、工作集上下文注入、人工修改计划失效、持久化/Compact 屏障和恢复一起验收，不能把后端原语写成端到端能力。

本机首轮真实 PostgreSQL 受限 SET ROLE + HTTP、40 项/vet/build 通过，两项 opt-in Worker 二进制测试未执行。独立评审发现重复 JSON 键在结构体与 map 解析中不同，可能让同操作不同内容得到相同哈希；保留真实失败复现后，已改为局部拒绝重复键并对已校验结构哈希，没有修改旧 invocationHash 协议。修后证据 `local/evidence/p25-working-state-1f39c61b846f454697d7b6b2e98c0ffe`：7 项新工作状态 + 3 项迁移测试零跳过，vet/build 通过，临时数据库确认停止。未运行付费模型、未部署候选，Runtime 候选发布元数据已显式标记需协调迁移的新 HTTP/data 版本。

最终将来源验证改为单个有界批量 SQL，避免最多 256 次往返；核对数量完整匹配，再按排序引用记录哈希。新增多有效来源的顺序/哈希与混合有效/跨任务来源拒绝断言，最终源码证据 `local/evidence/p25-working-state-2a0e4c65288e4b0897fac9830d551760` 同样 10 项零跳过、vet/build 通过，临时数据库确认停止。没有用减少查询次数冒充实际生产延迟测量。

### 源码引擎状态桥接增量（Runtime 已实现，Harness 尚待接入）

Runtime 候选引擎 `dsh-source-639ed015-state-v1` 新增 checkpoint、工作状态读和更新帧，沿用已验证的增量事件暂存与不可变产物确认。默认 Worker facade 仍只领取三个旧引擎；新入口 `NewSourceEnabled` 必须由后续 Worker 在核验固定 runner 后显式启用。当前无新任务提交入口、无新版 Node runner、无正式部署切换。

独立设计评审指出两类丢回复风险：工作状态与外层 Exchange 分别落盘会留下成功回执间隙；拒绝本身不落盘，则一次 CAS 拒绝可能在版本追上后重试成成功。本次把工作状态版本、审计与 Exchange 最终响应合并到 Runtime 同一事务。只读快照和确定拒绝也冻结为各自操作的响应。外层 Exchange 只核对已存响应再保存运行检查点，不做第二个响应写者。更新 intent 固定原模型计划的 rule revision，不能用重试时的新约束重新授权旧计划。

Worker 专用 HTTP 要求有效租约/fence、新引擎、同运行数字操作号、已登记且内容匹配的 intent，以及已确认的归档 manifest。身份/归档/intent 错误和数据库异常不能伪装成已完成的业务拒绝。取消后不通过 Worker 写路径恢复执行；管理端仍能读成功工作状态回执，但当前管理接口不提供所有否决/读取帧的响应查询。

新引擎普通工具结果带平台生成的 operation ID 和 committed 标志，规则变化导致的 skipped 结果标记为未提交；大结果的归档引用仍保留真实来源回执。这里证明可回查，不证明来源真实。checkpoint 确认的是事件证据归档，不是原生 Session 快照恢复，也不代表内存已经有界。

本机报告 `local/evidence/p25-working-state-f5cb819206ed4b3caf269903b8440401`：45 个通过记录（含子测试），vet/build 通过；真实临时 PostgreSQL、受限角色和 Runtime HTTP，5 个新增桥接测试覆盖事务回滚、读取/拒绝/成功丢回复、规则变更后接管、旧 owner/取消拒绝、归档屏障、响应篡改、引擎选择和工具来源标记。两项 opt-in Worker 二进制测试未在本次重复执行，尚无新 Node runner 参与。第一次测试因夹具 INSERT 缺非空 attempt 失败，原始报告 `p25-working-state-e590ad43f079449c802d4c2be00c4d65` 保留。没有 Actions、付费模型调用或部署变更。

下一步必须把源码 DSH 的 `session/event` 增量队列、`session/flush` 和上下文投影接到该协议。上游自动 Compact 不自带完整 flush，而且会捕获异常继续循环；必须在替换完成后等待持久化，并在每次模型/工具调用前再次强制屏障、保留失败状态。工作集应进入 DSH 可计量的上下文投影，不能在 provider 内无预算追加；冻结读帧的顺序和内容也是重放协议的一部分。仍需实际 Node/Worker 中断验证、长历史内存测量与缓存回收，不能把本增量写成 P2.5 已完成。

最终注释/公开类型别名调整后定向复验 `local/evidence/p25-working-state-1375e48e8b0b435db9f8a9c857d4b2b1`：15 项状态/桥接/迁移测试零跳过，vet/build 通过，15 份记录的源码哈希全部匹配，临时数据库已停止。独立代理完成静态复核，未发现新增阻断问题；代理没有运行测试。丢回复测试是在实际 HTTP 成功后主动丢弃返回结果，不是实际断网或新引擎进程强杀；这两类实测仍留给后续 Node/Worker 联合验收。Runtime 本地候选提交为 `870a4dddc8174443b557b9e5fdb62a8e3af0bb3a`，尚未推送、发布模块或修改集成 source lock。

## 数据分层与责任

| 信息 | 模型当前上下文 | 必须持久化的地方与时机 | 失效/清理规则 |
| --- | --- | --- | --- |
| 用户目标、纠正、约束、任务阶段 | 保留经过版本固定的精简当前状态 | Runtime 的结构化任务状态；接受修改时先提交，再进入后续模型步骤 | 版本历史和生效记录保留，不能被摘要覆盖 |
| 已验证事实、冲突、未知问题、下一步 | 当前问题所需的工作集；带来源 ID | 独立工作状态/证据引用账本，不能只埋在自然语言摘要 | 失效不等于删除；修订有来源和审计，不能由模型自行认定事实真伪 |
| 模型/工具调用意图与实际结果 | 必要的短结果和回查引用 | 执行域先记调用意图，实际效果和本地回执原子提交；跨服务未知效果保留待核对状态 | 未核对调用、活跃任务和恢复依赖不得清除 |
| 网页、文件、长工具结果、完整事件 | 只读相关片段和稳定引用 | 原文/事件先进入持久化暂存，再发布不可变产物与可查目录；进入下一有副作用步骤前确认 | 被事实、报告、运行或备份引用的资料保留；引用检查前不做 GC |
| Compact 摘要和上下文投影 | 保留当前有效摘要与固定状态 | 摘要输入范围、输出、引用、版本和提交点落盘；失败时不替换有效检查点 | 摘要是可重建派生物，不能成为唯一证据 |
| 解析缓存、重复下载缓存、临时分片 | 需要时短暂使用 | 仅为性能而持久化，不作为唯一权威 | 明确 TTL/预算、无活跃租约/引用、持久化确认后才可回收；正式资料默认不自动删除 |
| API Key、数据库密码、服务身份 | 不进入模型上下文 | Registry/受保护的本机配置；按身份解析 | 不进入日志、摘要、事件原文或 Git；轮换与备份单独管理 |

DSH 管模型请求组装、工具调度、会话投影与压缩调用；平台存储策略插件决定哪些状态固定、哪些输出转为引用、在哪些边界等待持久化。Runtime 执行域仍是租约/fence、事务和回执的权威；Storage 管不可变字节与引用；Knowledge 管检索索引；这些权威不能再被 DSH 的本地 JSONL 形成另一套可写副本。

## 分批实现

1. **源码与版本基线。** 保留原依赖锁和原引擎恢复路径；源码仓库保留 upstream remote、commit 与许可；本平台插件与上游修改分目录，产出固定构建清单。先跑原行为回归，再启用新引擎 ID。
2. **结构化工作状态与存储策略。** 定义目标/约束/问题/证据/冲突/待办账本的 schema、版本、权限、更新回执和引用。模型可以提出修改，服务负责合法性和来源检查；不可用摘要字符串替代这个账本。
3. **持久化插件与检查点。** 通过事件/flush 扩展接口对接已有执行域暂存/产物协议；队列有界、后台失败可见；模型/工具外部调用前、Compact 提交前、暂停和正常退出时有明确落盘屏障。进程被强杀前尚未确认的数据不能声称已保存。统一恢复权威，避免原生 Session 恢复与桥接回放各自推进同一任务。
4. **上下文与进程内存边界。** 按来源引用分页取资料，长输出外置；固定工作状态在 Compact 后重新装配。测量长任务的 token、Node heap/RSS、持久化字节和恢复耗时。若现有扩展仍保留不受控全历史，再为 Session 查询/分页加载或检查点恢复做最小源级补丁；不能直接 `splice` 日志破坏 seq、消息投影、工具恢复或回放。
5. **受控回收。** 首版只回收可重建且无引用的缓存/临时数据，先 dry-run 清单。正式原文、运行回执、未决效果、版本历史和被引用产物不自动删。以后独立验收可达性与保留策略。

## 必须通过的测试

- 断点：持久化提交前、提交后丢回复、模型完成后、工具效果提交后、Compact 摘要后/检查点前分别中断，再由新 Worker 接管。
- 顺序：持久化失败时不能越过屏障去执行下一个有副作用工具；旧 fence 不能确认检查点；已提交回执不重做。
- 内容：即使摘要刻意漏掉关键来源，固定目标/约束、冲突和来源目录仍可恢复；事实/计划/第三方预测不能串类。
- 内存：在固定并发/工作集下递增长历史，测量真实 heap/RSS 和恢复耗时；既有 192 MiB Node heap 上限不算“内存稳定”证据，超过预算不能丢资料冒充通过。
- 兼容：旧引擎继续恢复旧任务，新源码引擎只接新任务；回滚拒绝不支持正在运行协议的版本。上游升级、插件变化与协议变化分别记录。
- 清理：活跃引用、未确认写入和未决调用保护；删除临时缓存后能从权威存储重建；不能清除用户正式证据。

结论是把源码控制和存储工程放入本次计划，按这些测试决定底层补丁范围；没有证据就不承诺已经解决所有 Compact 遗忘或可以无限长运行。
