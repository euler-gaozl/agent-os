# Mac 原生笔记与未知外部效果增量（2026-10-15）

环境：维护者独立 macOS 15.3（24D2059）/arm64、Go 1.27.2、Node 24.19.0、PostgreSQL 18.6；仅新隔离库、新任务和合成输入。延续 [Owner 局部移交](macos-telemetry-owner-20261015.md)与[旧覆盖退役矩阵](../p2-linux-cutover.md)，不修改原 Windows 历史。两层测试分别证明下述范围，不能合并为完整业务或资源验收。

## 笔记 Owner：自然过期、重放和并发冲突

新增 Runtime `runtime/notes_native_test.go`：2 个顶层测试及 2 个并发子场景全部通过，0 fail/skip；`-race -json -count=1 -timeout=120s` 的结构化 package elapsed 为 10.533 秒，exit 0。控制台包文本为 10.532 秒，是同次输出表示差异。`go vet -mod=vendor ./runtime` exit 0。

通过正常 Submit/Claim 提交带未来有效期的修订后，丢弃已提交的本地回调返回；数据库时钟自然越过有效期，当前读视图变为 expired，历史回执不变。正常 Heartbeat 设置 250ms 租约，待自然过期再 Claim 得到 fence 1→2；旧 owner 被拒，重放返回冻结的历史 effective 回执，新查询显示 expired。显式续订、撤回和撤回后拒绝隐式复活均有已提交回执。没有用 SQL 改写时间、fence 或运行状态来制造恢复。

同根 revise/revise、revise/retire 两组实际观察到两个数据库锁等待者，释放锁后每组一项成功、另一项为 completed 且 changed=false 的 conflict；审计、事件、版本和冻结历史行按结果核对。此次第二组胜出为 retire，不声称已穷举全部交错。

这层为 Go 进程内真实 Owner/隔离 PG，应用池通过 NOLOGIN/SET ROLE 连接；每任务独立内存 archive、合成 NativeReceipt。丢失的是 Store.LocalTool 回调返回，不是真实 TCP；没有独立 Worker/官方 Node/Storage。冻结回执按 JSON 语义比对，不宣称网络原始字节相同。

## 独立 native-v4 进程：未知效果、取消和明确核对

新增 [native_unknown_test.go](../../scripts/acceptance/nativearchive/native_unknown_test.go)，第二次执行 1 项通过、0 fail/skip，package elapsed 5.417 秒、exit 0；命令 `-race -json -count=1 -timeout=3m` 仅对 Go 测试驱动启用 race，独立服务使用普通构建。真实 Runtime/Worker/Storage、固定官方 DSH/Node 使用两个新数据库与三个 LOGIN 角色；Registry、ToolHub 路由、TLS 模型和 MCP 接收端为本机协议夹具。

MCP 接收端写入唯一合成效果并 fsync 文件及父目录；在 Runtime 调用仍 inflight、真实 Storage 已保存调用链时关闭 TCP。Runtime 返回 409，任务进入 waiting_unknown。取消后连续观测仍保留未知效果且没有重发；测试独立回读效果文件、核对调用身份，再通过 control reconcile 提交明确 completed 决定及证据哈希。原任务转为 cancelled、工具回执 completed、恰好一条 reconciled 审计；原模型/attempt/Exchange 行和 usage 不变，原工具 Exchange 的 response 仍为 NULL。它是受控操作者显式核对，不是平台自动推断外部效果。

同一 Worker 身份继续完成另一新任务。两个实际 Node 均以进程身份、ps 缺席和 kill(pid,0)=ESRCH 连续 6 次观测确认退出；这是短窗口退出证据，不是长期资源上界。原任务与新任务各 6 个 manifest，分别 8219/7610 字节、pending=0，manifest/part 均有本任务引用；原归档在取消/核对前后不变。测试当时通过 Storage GET 回读校验原文，留存为摘要和 manifest ID；独审未在清理后重读原文。工具效果共 1 次，模型夹具请求共 2 次，各任务合成计量 1900 tokens、unknown model usage=0、cost=null；真实供应商调用为 0。

## 来源、失败留存、清理和独立评审

| 内容 | 来源与边界 |
|---|---|
| Runtime 测试归档 | `c02e12307e214b59dc02e18ca807a3c1ae762023`，仅新增测试和 README，未替换运行版本 |
| 本次独立二进制 | Runtime `ff3fa220df331f698c99b260005cc222d0dcdb1c`；Worker `ff9a2f07f397bf0b408256e8a71644b3d2976376`；Storage `ded5920e1e684cb07f0789bf33f77aec3a0afa5c` |
| Harness | 源码 `a8a18e41de719901dbef4513faf898af95822d7a`；固定 native-v4 manifest SHA-256 `d76588bae0edd1d7f13cdb4d01423ac8fc14da240fba682bcec4a1fb08f8ba7f` |

受测源码 SHA：notes 为 `5413703e61005d17fb75c36d5ee17d0261b83016234471f1a69015f2a37e590c`，unknown 最终版为 `317ca63f5c5a31dcba4dea44348efe49a55912d1bc45e37eca7d40ecda453ef7`。测试在对应基线加审查后的工作树执行，再以源 SHA 核对本地归档；不宣称重新测试了提交树。五个二进制与固定 runner 文件哈希见 `build.json`，原 archive acceptance helper 未改、未重复执行。生产逻辑、Worker 编译 pin、冻结协议、旧快照和部署 pins 均未改。

证据根为 `local/evidence/macos-native-lifecycle-20261015/`。`unknown-first` 因 ToolHub 夹具遗漏 SDK Connector resolver，在提交阶段 HTTP 403，Test FAIL 2.08 秒、包 FAIL 2.422 秒、exit 1。首次静态审查亦漏查此分支；首版候选和失败日志保留，修订只补夹具解析路由/断言，另存 `unknown-second`。第一轮未进入效果或恢复阶段，不证明生产恢复缺陷。

`notes-first.*`、`unknown-{first,second}.*` 与 `verification.json` 保留实际调用、退出、JSON 事件和摘要；`cleanup.json` 为根代理只读核对：两次进程尝试合计 4 个新库/6 个 LOGIN 角色及连接、临时配置、测试服务/runner 均无残留，notes 的 p2_runtime_ 库/角色前缀也为 0。`before-services.json`/`after-services.json` 确认已安装 10 实例身份与相关文件哈希不变；未借清理删除其他运行。

独立静态、断言增量与执行复核分别留存，作者没有以自评冒充独立通过。执行复核报告：`native-notes-execution-independent-review.md`（SHA-256 `83cf0190a4537ee1fcc0dfaf76d3c8d1fadbfbd8dbfd869ed2e451163e766f67`）、`native-lifecycle-execution-independent-review.md`（SHA-256 `64a4d69c7eaae2d800c231fa7ca1cad79b65e7b4eb03eaf3f52492193e0ffbee`）。评审者只读源码与已有证据，没有再次运行数据库、服务或模型。控制脚本及摘要另存 `controllers/manifest.json`。

## 保留范围

只推进 W09/W10/W14 相关局部证据；P0/P1/P2/P2.5/P3/P4/P5、W01–W14 全部原范围及既有状态不变。旧测试/工作流、服务和权限退役、完整存储生命周期、长历史 Compact、全平台持续资源上界、完整 UI、研究成稿与质量、最终统一 CI 继续按原计划。没有新增真实供应商、浏览器或真实业务验收，没有 Windows DPAPI、受管发布或原库恢复结论。永久资料和未决恢复回执不能按缓存删除。未推送，未运行 Actions。
