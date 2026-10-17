# DSH 源码与 Agent 存储系统决策

2026-10-12；服务于 Windows 单机交付。此文区分已核实事实、当前决定和待实现内容。

2026-10-13 最新补充：正式 resident-v2 已完成真实 DeepSeek 工作状态/原文/笔记/历史回读。已发布 Runtime/Worker/Node/Storage 的八场景联合运行与活跃 Node 全局超时清理通过；实际请求为 19/49/99，100 预算任务自然接管后约 0.66 秒进入新请求。决定在当前步骤预算下保留完整冻结回执恢复，原生 Session 快照暂不作为单机交付前置；归档确认不等于快照，不清理恢复回执。数据生命周期、测量口径、明确未覆盖项见[联合验收](../resident-joint-acceptance-20261013.md)。下段“正式 v2 尚未执行”为此前接入/发布时的历史状态，不覆盖本段。

2026-10-13 后续状态：resident-v2 已接到 Runtime/Worker 的独立版本选择和双编译 pin；旧接口保持 v1-only，Exchange 在写意图前及行锁内拒绝 engine 错配。实际进程中断、丢回复及旧 Worker 的 v1 接管通过，完整包搬迁后同七项复验通过。发布控制器已实现逐版本兼容/回退及配置事务检查，双版本完整发布实际安装、六次升级/回退、默认往返及备份隔离还原通过，见[接入验收](../resident-engine-integration-20261013.md)和[发布控制记录](../windows-resident-release-20261013.md)。默认仍 v1，正式 v2 供应商任务、原生快速恢复和缓存生命周期尚未完成。下文内核候选段保留其阶段边界。

## 2026-10-13 驻留历史候选的实现与边界

Harness `439b9086155383a4b4cb19c261ac6690ab02a352` 已实现 `dsh-source-639ed015-resident-v2`，单独构建到 `.work/resident-candidate`；生产默认仍为 state-v1。七处受哈希约束的转换修改 Session、Surface、tool history、Compact 边界读取、TokenMeter、Projection registry 和 RuntimeContext；不重写 AgentLoop、不编辑上游基线。ResidentEventLog 用 Map 保存绝对序号，最多 16 MiB 编码事件 / 8,192 项；归档确认水位取发出批次的尾部，等待回包时新产生的事件不被提前释放。

释放前同步实际五个内置投影、TokenMeter、header/context/tool folds，拒绝未知投影（按定义对象身份判断）、迟注册、自定义 message projection 或消费者替换/卸载。投影和 TokenMeter 分别有 8 MiB 编码状态保护，工具声明系列有 8,192 更新 / 8 MiB 保护；不能把这些局部保护推成总 RSS 上界。原始事件只退出 Node 驻留内存，Runtime 归档仍是权威；完整历史读取不能伪装成部分结果，也不删除归档。

最终证据 `local/evidence/dsh-resident-candidate-a3dbb9f031714241a2b3e0dc8d734b3b` 绑定 12 份源码/脚本/测试哈希及内核 `be1b87c92a7b9b1dae332a10115ef04ddd676a2aa82e90d02c2943e296c9932c`。候选 19 项、旧版 16 项检查全部通过，无跳过；128 / 512 / 2,048 / 4,096 步记录及重放全通过。2,048 步记录回收后堆 11,425,952 字节，旧版同夹具为 50,417,120；4,096 步约 12.8 MB，完整重放仍为 22.6 秒。三档旧新夹具请求/事件类型/非 checkpoint 回复一致，不构成旧任务可以换引擎的许可。强制 GC、固定工作集、合成回复和单次样本的限制保留。

独立评审先发现未知预注册投影可能绕过有效状态大小检查，修为实际定义白名单后再次复核无阻断；评审核对源码/哈希/现有报告，没有自行执行测试。初版 Cordis wrapper 身份误判的失败证据保留，实际实例 Symbol 修复后再验证。详见 Harness `docs/resident-history-design.md`。下一步真实 Worker/Runtime 接入必须同时保留 v1/v2 的固定产物选择；候选尚未部署，原生 Session 快速恢复、缓存回收及实际进程故障验收继续，不以本增量宣布 P2.5 完成。

## 2026-10-13 长历史测量后的核心修改决定（实现前基线）

固定源码 v1 的真实 DSH 循环，在固定工作集、8,192 token 窗口和 4 KiB 合成工具内容下，执行 128 / 512 / 2,048 步；各自另起 Node 从逐帧落盘的冻结回包重放。六次正常结束，实际发生 127 / 511 / 2,047 次 Compact，最大模型 JSON 一直是 9,795 字节，但回收后的堆分别为 13,718,896 / 20,609,896 / 50,417,120 字节。重放耗时 805 / 2,590 / 10,132 毫秒。证据为 `local/evidence/dsh-memory-baseline-0e3b3a7a0b56427b94e138b75dae77f4`，脚本在独立 Harness 仓库 `benchmarks/`。这是带 GC 仪器的单次合成 supervisor 测量，没有 Runtime/Worker/正式数据库/付费模型；不是生产延迟分位数或完整恢复验收。事件 hash 链、请求语义哈希、数量和类型已核对，未声称重建事件的时间戳/ID 与原始字节相同。

此结果和源码读取共同支持：已有 flush/Compact 扩展点不足以释放 Session 全部历史，**需要最小核心补丁**。改动对象是 Session 的驻留事件索引与绝对序号分离、SurfaceManager、header/tool-history、TokenMeter、Projection 注册和 Compact 控制状态读取；继续沿用原 AgentLoop。尤其 `compaction-basic/region.ts` 当前每次倒扫历史查找 seed/turn/compaction 边界，无 seed 时会到起点；Projection 的首次/迟注册和 TokenMeter 首次访问也需要先确定消费水位。不能将旧日志槽清空后让 `snapshotEvents()` 返回不完整的“全历史”。

释放前必须同时满足 Runtime 归档已确认、所有已挂载消费者推进到释放水位、无 surface/工具定义/开放控制状态引用、无正在提交的 append。失败确认保留待存事件并阻止后续效果。新引擎候选先保持原 Exchange 重放权威并测量其历史成本；可跳过前缀的原生 Session 快照另行定义版本/归档绑定，不能创建第二个效果状态机。具体候选契约在 Harness 的 `docs/resident-history-design.md`。正式 v1 与现有任务没有改变；目前只完成问题测量和修改边界，尚未实现或部署驻留历史释放。

独立评审只读核对脚本、六次报告和产物哈希，未执行测试，认可本夹具趋势结论。补充边界已写入 Harness：RuntimeContextProjection 的“从未存在/已压缩”状态、晚注册或重注册拒绝、被遮蔽消息的投影引用，以及仅释放捕获批次 `start + count`（不能用回包时最新 seq）。测量与设计代码已保存到私有 Harness 分支 `feat/source-owned-harness` 的 `f4c005e`，未修改固定生产 tag 或集成发布锁；两个仓库 Actions 均保持禁用。

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

### 源码 Harness 存储/上下文插件增量（协议夹具已验，真实 Worker 待接）

本地 Harness 候选提交 `ec21432a91ad1b5b8081aed6aea854363080a6b7` 新增 `source-runner.mjs` 与 `src/source-platform.ts`。源码 DSH 继续负责完整循环；插件只接 `session/event`、`session/flush`、Prompt assembly 和受支持的 Compact 扩展点。旧 runner 文件及正式 npm 引擎不改，新 runner 要求明确的新 engine/evidence 协议。

插件只在创建时获取一次事件前缀，之后增量序列化；传输队列最多 16 MiB，确认后释放，等待确认期间新增事件留到下一批。每次 flush 都发 checkpoint，即使无新事件也不省略，防止重建时事件数量改变桥接帧顺序。观察者错误被上游吞掉也会进入持续失败状态；自动 Compact 替换完整结束后 flush，模型/工具/状态/结束调用前再次检查并等待屏障。这里不建立第二套 JSONL 或数据库权威，也没有解决 Session 自身全历史内存增长。

每次组装读取 Runtime 冻结回包，固定 format=1/字段顺序/read operation ID，投影完整 task、读取时约束、版本/失效标志和 WorkingSet。WorkingSet 保留来源 operation ID；完整响应哈希清单仍留在 Runtime，不在模型里重复。操作号变化使同内容也重新进入已记录、可计量的上下文，避免自动 Compact 恰好删除上一份状态。模板替换只做一次，`{{...}}` 原文保持字面值。可信系统提示明确派生 state/引用原文没有指令权，并区分读取时约束与 Runtime 后续冻结进请求的新规则。

独立评审发现初版固定 64 KiB 保护会拒绝合法大回包，已改为去除重复哈希列表、按最终编码字节匹配 Worker 4 MiB 传输上限及少量封装空间，不截断任务/事实。实际 Node 夹具以含转义 tab 的 39,600 字节任务、14,400 字节约束、32 条观察/256 个来源引用、32 KiB 内工作集请求运行；在足够大的上下文下正常结束，新进程从冻结回复重放得到相同请求。低上下文窗口的另一个测试确认溢出会在模型调用前停止。Node 只检查自身实际消息及输出预留的启发式 token 预算；Runtime 最后追加的权威约束及真实模型请求仍需在 Worker 接入时核算，不能称总预算已闭合。

最终证据 `local/evidence/dsh-source-baseline-446401e918bb4385ac340ab24a127fdf/result.json`：独立 Git 克隆离线安装、193 输入源码构建、16 项 Node 检查零跳过，两处 kernel/manifest/许可证字节一致，篡改上游拒绝构建。kernel SHA-256 为 `6f37d28cd08268fe29304b472a736efd0fe83fd5266d5b5902077395231fd121`。运行产物测试完全位于仓库外，无祖先 node_modules/package.json，实际执行自动 Compact；压缩摘要故意漏关键事实，但下一请求工作集完整，持久化失败后没有新的模型/工具调用。第一轮 `p25-source-runner-d13772ef594643f896a6ad17e7e5a998` 发现退出事件把失败码覆盖成 0，已修，失败记录保留。独立静态评审核对候选/克隆提交、7 份源码和3份构建哈希及 TAP，原两个评审问题关闭；评审代理没有执行测试。

上述父进程仍为明确协议夹具，模型/状态/产物确认都是合成响应，不是 Runtime 数据库持久化或真实 Worker 强杀接管。下一项是发布固定 Runtime 模块及 Harness 包，Worker 校验 manifest 后才启用新引擎，接 Runtime 专用状态 HTTP，并在 Windows 真实进程/数据库中验证丢回复、取消、Compact 后接管和完整供应商请求预算。当前无付费模型、无 Actions、无部署切换；Session 长历史有界化、缓存清理和完整 P2.5 验收仍未完成。

## 数据分层与责任

### 2026-10-13 Worker 实接与固定发布包

候选版本已保存到私有仓：Runtime `35660bf039afb2b826b179246a39b814bf3dcf83`、Worker `70d45cd1ef2e08def4450f3be8b003b51401b72f`、[Harness](https://github.com/euler-gaozl/agent-os-harness) `ec21432`（tag `v0.1.0-rc.1`）。新仓先禁用 Actions 再导入。Git HTTPS 重置后使用 Git Database API 逐 tree/commit 验证相同 SHA，没有覆盖用户历史。Worker 固定执行依赖 Runtime `v0.1.0-rc.2`（`870a4dd`），经 Go canonical module 再生成 vendor，无本地 replace。旧 SDK 缓存曾被 checksum 拒绝，使用已有验证的独立 module cache 后通过，未绕过校验。

Worker 默认仍领取历史三种引擎。显式 `DSH_SOURCE_RUNNER` 必须通过编入程序的 manifest/upstream/runner/kernel/许可证锁；每次运行再次校验。源码 Node 从固定产物目录启动，禁止全局模块搜索，无模型或服务凭证。完整离线包可同时携带旧 npm 与新源码产物，二者不互换。最终模型 JSON 在追加当前约束、子任务结果和应用输出上限后计入预算；仍是 DSH UTF-16 字符/4 启发式加封装余量，不承诺供应商分词器的精确上限，尤其是中文。

已修复评审发现的回复丢失收敛缺口：同一状态 Invocation 最多三次有界重试；耗尽后保留 `waiting_unknown`。Runtime 新增 control 专用 `resume-source-state`，在事务中校验最新整体 Exchange 为已归档状态读/更新、未取消且没有未决 calls，再保留原请求/规则/回执入队。取消只在没有未知外部效果时结束；有活动子任务则等待收尾，不执行被取消的状态更新。这个 `source-state-recovery-v1` 管理增量**不在** Runtime `v0.1.0-rc.2` 内，正式部署必须匹配新的 Runtime 服务版本，不能仅看 Worker 依赖 tag。

| 本机证据（`local/evidence/` 下） | 实际结果与边界 |
| --- | --- |
| `p25-worker-package-cb02167fdc5540079faf5997f4d05843` | 干净提交离线打包；搬离原目录后核对所有文件/链接，两个历史 DSH 协议继续运行 |
| `p25-worker-source-3ad9be3805e54fbb91773f42ade1e18e` | 直接运行搬迁包的 Worker、Node 和源码 runner；37 个 Worker 与 19 个 Runtime 集成通过记录（含子测试），零跳过；vet/所有权检查通过 |
| `p25-working-state-cef60464478e4b93963c83202f219c75` | 扩大 Runtime 回归 61 个通过记录，vet/build 通过；5 个可执行集成 opt-in 本批跳过，其中3个源码场景由上一行实际覆盖，两个历史用例本轮未重跑 |

三个实际 Worker 场景分别为状态提交后强杀并 fence=2 接管、断 HTTP 回复且原 Worker 存活、三次断回复耗尽后管理恢复；各有1次实际 Compact、69个归档批次、475,098字节事件。摘要故意遗漏日期/数值/来源，后续工作集保持完整，没有重复已提交模型/工具/状态效果。活动子任务取消与未知工具保护也通过。固定包 Worker SHA-256 为 `EC279257D68F2FBA13F3A357EDCC819CF2ECA0183F4F10F62B06550F2D1C00EB`。临时 PostgreSQL 均已停止。初版 `p25-worker-source-e44de4051bc8461b860af97d3f7029c9` 因测试构造的未确认归档违反表 CHECK 失败；已修合法夹具，失败日志保留。

模型、ToolHub 路由、不可变 Storage 仍为显式夹具，不是 Storage 磁盘耐久或付费 DeepSeek 业务验收。独立评审读取源码和证据，没有代替执行测试。本轮零付费调用、零 Actions、未切换正式部署。剩余：任务提交与恢复 UI、部署兼容/回滚保护、Session 全历史内存和恢复耗时测量/必要核心补丁、缓存生命周期、真实研究交付；P2 的旧覆盖及权限退役缺口也继续保留。

### 权威数据与清理规则

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

### 2026-10-14 真实长草稿暴露的执行器缺口（v3候选已实现，未安装）

[研究反馈实测](../research-feedback-20261014.md)已经证明现有源码引擎仍有三个
需要协调修改的问题，不能继续仅调整 Agent 提示词或扩大预算：

- `source-runner.mjs` 创建 Agent 时硬编码 `maxTokens:4096`，没有使用 Agent
  配置的6144。真实任务第2次模型回复在4096处被供应商截断。
- Node逐消息估算与Worker最终JSON估算不同；Runtime还会补入权威约束和
  子任务信息。Worker的预发送上下文拒绝直接退出监督循环，未落可恢复的
  exchange.response，也未传到DSH的context-overflow处理入口。
- 供应商usage已在Runtime回执留存，但适配器finish事件未传入usage，DSH
  无法用已发生的prompt计量校准后续压力。扩大窗口还可能先触及共享的
  保守总预算预留；unknown用量为0也可能发生，错误文案不能误导为未知计费。

下一固定版本暂名 `dsh-source-639ed015-budget-v3`，保持官方AgentLoop与
已有持久化权威。先做下列协议和夹具，不修改已激活v1/v2的runner或回放字节：

1. init传递不可变快照的有效输出上限；普通生成与压缩分别使用对应上限，
   两者都纳入上下文及总预算预留。不因增加回复额度取消总预算门禁。
2. 对**已知尚未发送供应商请求**的上下文拒绝生成有版本的结构化结果，
   在原fence下持久化后再答复Node。网络错误、未知效果、租约失效、数据库
   错误不能伪装成该结果。已发送请求的原回执仍是唯一计费/结果权威。
3. Node将此结果交给DSH已有的CONTEXT_WINDOW_EXCEEDED恢复钩子；只在
   持久化的上下文替换确实推进后有界重试，无可压缩内容就明确失败。
   不新增平台决策循环，不对超限请求反复付费试探。
4. 实际usage随持久化模型回复、以独立usage chunk在finish前反馈至DSH，回放用相同计量；最终完整
   序列化请求仍经过Worker预检。压缩请求同样受预算约束，不能形成递归循环。
5. 至少验收：大于4096且不超过配置上限的普通输出；转义和中文长输入；
   动态约束导致的Worker端拒绝；拒绝提交前/后丢回复与强杀接管；压缩提交
   前/后中断；真实usage驱动压力；不可压缩任务有界终止；同一家族预算不
   因重放/拒绝重复消耗；v1/v2已完成与未完成任务兼容；完整包独立发布回退。

新版本已实现并独立固定构建，完整包搬迁与真实Worker/Node/受限PostgreSQL联合验收
18项通过，见[当前候选证据](../budget-engine-acceptance-20261014.md)。本机仍为v1默认，
部署切换/回滚、正式安装和真实供应商成稿还需完成。不能把直接MCP回包变短或
历史测试当作P5通过；其余P2.5存储/缓存要求仍保留。

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
