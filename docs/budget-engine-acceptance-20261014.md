# budget-v3 执行器候选验收

2026-10-14。本增量修复真实研究暴露的执行问题，仍不代表 P5 研究质量通过。
正式新根默认仍为 state-v1，budget-v3 尚未安装。没有新增付费模型请求或 GitHub Actions。

## 修复与固定版本

| 部分 | 固定来源 | 行为 |
| --- | --- | --- |
| Harness | `437bb440a849ecfc49971f7fa96afe9fb4f7aa29` | 新引擎 `dsh-source-639ed015-budget-v3`；生成使用快照输出上限，摘要使用 `min(2048, 上限)`；保持官方 AgentLoop 与已有源码补丁 |
| Runtime execution | `v0.1.0-rc.4` / `e8d3b4fb5cf6975d5a3417c9f2b33789dee4e938` | 拒绝结果与已提交模型回执在原 fence 下冻结；最终模型、消息、工具和参数绑定原意图；拒绝与调用登记互斥 |
| Runtime 服务验收源码 | `b2d0ed0dc9ef2de0a7ed195a4c1db6e8b27fcfa4` | 在上述实现上增加真实独立 Worker/Node/PostgreSQL 故障测试；未改 rc.4 模块实现 |
| Worker | `c6e9555db243bf5be051d369c55cbf56b9b59ce3` | 固定 rc.4 vendor，无本地 replace；分别验证 v1/v2/v3 产物；供应商身份留在 Go 宿主 |

最终 JSON 预检包含 Runtime 加入的当前约束、子任务结果、工具定义与转义文本。
已知未发送的超限请求产生正常的持久化 `context_rejected` 结果，随后 Node 将其交给
DSH 的现有上下文溢出处理。网络、401、未知效果、截断、预算、存储和 fence 错误仍失败，
不能借压缩重试掩盖。预检仍为 UTF-16 字符/4 加封装预留的启发式，不等于供应商 tokenizer。

usage 来自已落盘供应商原回执，作为独立 usage chunk 在 finish 前交给 DSH；重放使用同一计量。
必需计数字段缺失、负值、分数、不一致或溢出，使用保守预留而非零计费；累计使用饱和加法。
缓存命中不重复算入 DSH 输入。历史任务的缺失 usage 因严格解析可能占用更多预算预留，
但不重写旧回执、旧 runner 或旧的桥接返回格式。

## 实际验收与证据

下表目录均位于本机 `D:\workspace\agent-platform\local\evidence`；不向 GitHub 上传原始本机状态。

| 范围 | 结果 | 证据目录 |
| --- | --- | --- |
| 源码 DSH + 合成监督端 | 新协议 15、旧协议 16、resident 19 项通过，零跳过 | `p25-budget-harness-d826a2cae0b54a428096d87f92115329` |
| Runtime + 受限真实 PostgreSQL | 146 条测试通过记录；vet/build/临时数据库停止通过；效果和供应商为夹具 | `p25-budget-runtime-3b19b4580d294202a63588197cad7877` |
| Worker Go/HTTP/Node 检查 | 71 条通过、零跳过；含 6144 上限、5000 计量 token 的合成回复；这一开发测试报告未单独绑定全部源码哈希，不能单独作为发布身份依据 | `p25-budget-worker-91381194e4794679ae261e93f37e69f5` |
| 干净 Worker 完整包与搬迁 | 1488 个文件哈希匹配；原目录实际移走；包内 Node、两种历史协议及三种源码引擎均运行 | `p25-budget-package-37672bc621054683b6cafbe76f452c0f` |
| 固定完整包 + Runtime HTTP + 受限 PostgreSQL | 18 条通过、零跳过；报告绑定 Worker c6e9555、Runtime b2d0ed0 和测试源码哈希；临时数据库停止成功 | `p25-worker-budget-a9031c7f278a444095d1fc531b4fdc97` |
| 发布版本/回退门禁 | 81 项通过；真实 SQL 统计、三套产物复制、导出恢复及篡改拒绝；未启动正式候选服务 | `source-release-policy-2b8d0d3e422a4158ba241374079cc4cd` |
| 默认引擎配置与进程中断 | 53 项通过；真实维护入口、DPAPI配置日志、临时HTTP进程、受限PG；覆盖10个中断位置、超时子进程收尾、错误Worker拒绝、配置漂移保护和回退 | `default-engine-0f7cd8070342418daa7b0b78c4d9ab76` |

完整 Worker 二进制 SHA-256：
`e5632b0264b5e2cf887bb3e2a10b86666f66eca123953e5120d20ac548199fa0`。
包内 v3 清单 SHA-256：
`b28323de11cd1bd51f3cdd5fe087bd8806b307fac526a28da25526c330100e4a`。

联合故障测试使用真实 Windows Worker.exe、Node、源码 DSH、受限 PostgreSQL 和 Runtime HTTP。
模型、ToolHub 路由与不可变 Storage 为明确夹具；不能据此宣称实际 Storage 服务磁盘耐久。
接管测试强杀真实 Worker，然后用夹具 SQL 加速租约过期，未测自然等待租约耗时。

| 联合场景 | 实际结果 |
| --- | --- |
| 最终转义 JSON 超限 | 一次已落盘、未发送的生成拒绝；一次摘要；继续完成；共14次合成供应商请求 |
| 拒绝后强杀 | 拒绝已提交，下一批归档回复被夹具阻断时强杀；fence=2接管；仍14次请求，无重复计费记录 |
| 压缩归档时强杀 | 摘要已提交，包含 compaction/end 的归档尚未确认；重放恢复后完成，无重复摘要/工具效果 |
| usage 压力与对照 | 相同历史，带28000 prompt计量的用例压缩一次；普通计量的对照不压缩；数据库用量与供应商原回执精确一致 |
| 不可压缩首轮输入 | 两次未发送拒绝后明确失败；供应商调用0次 |
| 摘要请求也超限 | 一次生成拒绝、一次 purpose=compaction 的拒绝；没有供应商摘要请求，无递归压缩循环 |
| v1/v2/v3 状态恢复 | 压缩后状态提交、回复丢失、强杀接管、三次重试耗尽后人工恢复；保留原日期/数量/来源回执，无重复已提交效果 |
| 历史 Worker 接力 | 旧 source-v1 Worker 与新包恢复同一任务，未替换旧引擎回放字节 |

初版联合夹具曾把两个服务身份设为同一 token，触发403；已改为独立身份，没有放宽生产权限。
较大的转义数据使摘要本身也超限，曾错误期待成功；现在将它保留为明确失败场景，
并对摘要拒绝单独断言。所有失败报告保留。独立评审读取代码、日志及包字节，未代替测试执行。

默认切换测试的早期夹具未满足现行ACL要求，已补独立数据库身份和所需权限，不改变生产检查。
独立评审发现 `budget` 漏进切换前、启动后两处实际Worker检查；已补齐，并经真实
`Set-DefaultEngine` 停机、错误endpoint/身份反例重跑。最终53项报告才代表修复后的验证。
这些进程使用合成HTTP可执行程序，不能替代上表真正Worker/DSH联合测试。

为让出全局同角色启动门禁，测试期间短暂停止正式Runtime及两个Worker；原数据库持续运行，
结束后恢复原程序。`budget-default-managed-5e4e3d2ac4bd479fbc6b2739ccb6c3a6` 绑定维护源码哈希，
并核对正式catalog和13份服务配置共14文件哈希不变。临时数据库已停止、临时实例记录为0。

## 部署与剩余关卡

集成维护器新增 `budget_execution`、`budget_harness` 和 `budget-model-receipt-v1` 标记。
Runtime 先于 Worker 升级；新 Worker 未携带 v3 产物时不能选择该默认引擎。
存在可恢复 v3 任务时拒绝最后一个 Worker 降级；存在任何 v3 历史时拒绝移除 Runtime 支持。
失败任务和 waiting_unknown 仍算可恢复，不能为允许回滚而当作已结束。

默认切换的维护流程/进程退出测试已通过。正式安装、实际供应商小额验证与真实研究成稿
仍未完成；其余 P2–P5 目标保持开放。v3 不会让已经失败的 v1 任务自动更换引擎。
下一步完成发布包准备、备份还原和正式安装，再对同一研究问题作有界付费验证。
