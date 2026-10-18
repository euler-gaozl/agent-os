# Resident-v2 实际执行、资源与恢复验收

2026-10-13。双版本 Runtime/Worker 的正式安装不变；本轮补足实际 v2 供应商执行及已发布进程的联合测量。完整 Windows 单机目标仍未完成。

## 真实供应商链路

正式运行 `0d60c9ba1b84082e6e850d018069dbf8` 使用 `dsh-source-639ed015-resident-v2` 完成官方 DeepSeek 调用、知识检索、原文回读、结构化工作状态保存、笔记落盘及历史版本回读。资料明确标为合成验收材料，不是期货研究。

- 五次模型调用；计量 prompt 20,015、completion 924，合计 20,939 token；其中 cached prompt 16,512。上限为八次调用、64,000 token、每次输出 1,024 token。
- 三类工具 `kb_search`、`document_read`、`note_save` 的已提交回执存在；工作状态 revision 1 引用实际原文回执，历史回读和笔记原文均一致。
- 随后只读遍历真实 Console→Storage，30 份 manifest、30 份分段、46,693 字节事件内容的哈希、事件数量及链边界全部匹配；没有重复供应商调用。
- 测试前后观察到余额差为零，不能据此推断调用免费或最终费用为零。

证据：`local/evidence/resident-provider-af79ed2e8ad4447890689f4ae665c160/result.json`；原始运行、回执、usage、历史工作状态及后补只读 `archive-readback.json` 在 `local/evidence/source-execution-live-5e67f2ef-de6c-4a92-9fd4-4c7f56a3044d/`。

测试结束已恢复默认 state-v1。正式任务现为两个已结束 v1、一个已完成 v2；保留此 v2 历史后，Runtime 不得回退到不支持 v2 的版本。上轮备份 `resident-release-live-20261013` 产生于该任务之前，不能当作包含本次新资料的备份。

## 已发布服务的联合测量

`scripts/Test-ResidentJoint.ps1` 验证正式 catalog 及完整发布清单，使用其固定 Runtime、Worker、Node、两版 Harness 和 Storage 文件；不修改正式默认值、进程或数据库。迁移程序由对应干净 owner 提交构建；Runtime/Worker 与 Storage 使用不同的临时数据库及受限角色。模型、Registry 和 ToolHub 路由是本地受控夹具，不冒充真实模型性能或真实 MCP。

固定 8,192 token 上下文、每次最多 2,048 输出 token、约 4 KiB 普通响应、25ms 夹具供应商延迟。Compact 是 DSH 自己触发，摘要故意遗漏来源和数量，后续请求仍须从权威工作状态恢复来源回执、实际 17 与计划 20 的区分。模型 usage 数字为夹具数据，不用于估计真实费用。

最终普通证据：`local/evidence/resident-joint-6ee133d52a454480bcf52b58ba101fba/`。八场景完成，109 个进程样本覆盖 15 个阶段，没有强制 GC。

| 场景 | 请求预算 | 实际模型请求 / Compact | 验证 |
| --- | ---: | ---: | --- |
| 单 Worker 短任务 | 20 | 19 / 8 | 原文、工作状态与回执回读 |
| 同一 Worker 较长任务 | 50 | 49 / 23 | 完成后 Node 退出 |
| 已提交工具效果后强杀 Worker | 100 | 99 / 48 | 自然租约到期、另一 Worker 接管，fence 只增加一次 |
| 双 Worker 同时执行两任务 | 每个 50 | 每个 49 / 23 | 首请求共同屏障、不同 owner 同时 running，采到两个 Node |
| 连续三任务 | 每个 20 | 每个 19 / 8 | 每次结束后的空闲采样无残留 Node |

每个任务均检查全部 manifest/分段真实 HTTP 回读、哈希及连续边界、历史工作状态、已提交工具数量、未确认 archive batch 为零、重复 model attempt 为零。故障发生在真实 Runtime 工具事务已提交、HTTP 回复尚未交给 Worker 时；没有修改数据库租约来加速接管。

100 次预算场景：强杀到观察到新 owner 约 **15.410 秒**；观察到接管到第一个新模型请求约 **664 毫秒**。后一个区间包含完整回执重放、轮询误差和传输，不是原生快照载入时间，也不是延迟分位数。

Windows `WorkingSet64` 采样峰值：单 Node **64.2 MiB**，Runtime **27.5 MiB**，Storage **19.8 MiB**，单 Worker 最大 **25.0 MiB**。双任务阶段所采 Runtime、Storage、两个 Worker 和两个 Node 的同一时刻合计峰值约 **201.5 MiB**。`PrivateMemorySize64`、阶段样本及 Go 最终 heap/goroutine 指标另存原始报告。未测 Node heap；排除 PostgreSQL、夹具/测试进程及其他正式服务，不能称整个平台内存上界、泄漏证明或 Linux 2 核 4 GB 容量验收。

## 全局超时与现场清理

验收根进程复用现有 Windows Job 的原子归属和 `KILL_ON_JOB_CLOSE`。所有服务及 Node 都在该 Job 中，采样也仅接受该 Job 成员和预期执行文件；不以历史父 PID 作为终止授权。外层确认 Job 清空后才删除本次生成的两库/角色并停止夹具 PostgreSQL；采样收尾失败仍执行清理，维护锁由最外层 finally 释放。

`-TimeoutFault` 在首个真实模型请求处持有屏障，要求屏障之后确有活跃 Node 样本，再让 Go 测试发生四秒全局超时。最终证据 `local/evidence/resident-joint-10540fe979b54c5f8bef5028a5547993/`：明确测试退出码 1、真实 timeout panic、故障前活跃 Node、根退出后 Job 成员为零、两库删除、PostgreSQL 停止、正式 catalog 不变。这里的“通过”是预期故障及清理通过，不是该 Agent 任务完成。

普通测量之后仅修正了 `TimeoutFault` 分支的 UTC/+08 时间比较；普通路径未改变。普通报告与最终故障报告分别绑定其实际源码哈希，不将后者的完整阶段缺失当作普通测量通过。

首次夹具曾因短 token、请求预算计入 Compact、采样字典序列化等问题失败；报告原样保留。早期无 Job 的八场景记录仅说明当时有限功能，不作为最终子树清理证据；`3a12...` 的退出码缺失、`932de...` 的空闲超时及 `f400...` 的时区误判，也不替代上述最终故障记录。独立评审指出的并发屏障、登记竞态、完成时间、采样覆盖和进程归属问题均已据此修正。

## 存储决定与下一步

当前 Agent 的 `max_steps` 上限为 100，本次也将总模型尝试限制为 100；已发布链路在接管后约 0.66 秒进入新请求。结合此前大幅超出正常任务长度的内核夹具，不再把原生 Session 快照作为单机交付前置条件；暂保留完整冻结回执重放，扩大任务预算或出现实测恢复瓶颈时重新评估。checkpoint 当前是持久化确认点，不是可跳过前缀的快照。

| 数据 | 当前生命周期 |
| --- | --- |
| 原始资料、不可变事件归档、calls/model attempts/exchanges、工作状态历史 | 持久保留；是回查或恢复依据，不能因 Compact、完成任务或 TTL 自动删除 |
| `harness_archives.batch` 暂存 | manifest 与有效 fence 确认同事务完成后置空；本次全部确认 |
| Node 驻留历史、投影、TokenMeter、解析缓存 | 已确认事件按消费者水位释放；当前进程恢复时完整重建，进程结束回收；不能随意 TTL 清空投影/计量状态 |
| 无引用 Storage 内容 | 现有显式管理 GC 仅针对超过 24 小时且无保留引用的内容，无周期自动删除 |
| 发布包、备份、保护配置、验收及运维日志 | 不属于模型缓存；后续按引用和保留策略分类，不能混入通用删除任务 |

实测 `/runs/{id}/calls` 在 99 次请求场景一次返回 **1,220,788 字节**。中台仍一次加载完整回执，需要改为有界摘要分页及单条原文按需读取，保留未知效果核对和来源回执定位。这是下一项明确 UI/资源缺口。取消和失败任务的专门资源退出测量、旧权限/代码退役、完整逐页 UI、剩余故障矩阵及真实期货研究链路继续推进；不能把本轮八场景算作 P2–P5 全部完成。GitHub Actions 未触发。
