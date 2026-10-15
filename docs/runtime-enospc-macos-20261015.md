# 独立 Runtime Owner：Mac 笔记与模型账本 ENOSPC

2026-10-15，维护者自己的 macOS 15.3（24D2059）arm64 环境完成一次独立 Runtime Owner 的真实 PostgreSQL 磁盘故障验收。第二轮 `TestRuntimeDiskFullPreservesNotesAndModelReceipts` 通过，1.21 秒，非 race、零 skip。首轮在工具参数校验阶段失败，原始失败与夹具修订另行保留。

本轮推进 P2 旧笔记/本地工具回执故障覆盖向 Runtime Owner 移交，并新增模型账本真实 ENOSPC 覆盖。旧主仓磁盘测试没有 BeginModel/EndModel 或 model_attempts 断言，不能把新增账本覆盖称为旧测试移交。相邻的 [Storage ENOSPC 记录](storage-enospc-macos-20261015.md) 独立留存；两个 Owner 切片不是同一次 Runtime/Storage 故障联调。

## 实现与环境边界

Runtime Store 与执行协议在 Go 测试进程内运行，数据库是新建有界卷中的真实 PostgreSQL。没有启动独立 Runtime 服务、Worker、Node/DSH 执行宿主或真实 Storage；Node 控制器仅管理隔离夹具。归档为内存夹具，模型响应、usage 与回执是合成协议数据，没有供应商 HTTP 请求。

测试先验证专用 fixture、物理工作根、双 marker、nonce、卷设备与容量、PID、PGDATA、loopback 端口与 PostgreSQL system identifier，再把本次新管理员连接交给 Runtime Owner 的既有 fixtureDatabase/Migrate/rolePool。应用与 Worker 测试角色为 NOLOGIN，通过管理员连接后 SET ROLE；这验证角色权限，不是独立应用账号登录或独立 Worker 进程验收。没有使用旧数据库、开发栈配置、供应商密钥或 Windows 资料。

控制器沿用 `scripts/acceptance/storagefault/run-macos.mjs`，仅增加封闭的 `--runtime` 分支。默认 Storage 入口、固定二进制哈希及原生命周期保留。Runtime 分支不读取 Storage 产物；只接受明确物理工作根，不接受已有 DSN、挂载点、任意命令或测试路径。

- 每次新建 `local/data/runtime-enospc-<nonce>`，证据保存在对应的 `local/evidence/runtime-enospc-<nonce>`。新目录 0700，私有 fixture/凭证 0600；证据不复制配置或 DSN。
- 511 MiB UDIF 映像，文件与卷均不得超过 512 MiB；创建前两次检查宿主至少 2 GiB 可用空间。只填充本次独占创建、同设备、同 inode 的文件。
- 固定 Go 1.27.2、PostgreSQL 18.6、Node 24.19.0，vendor 离线编译；先编译，再创建映像。只运行固定 Owner 测试，测试/子进程/控制器上限分别为 150/170/240 秒。
- 失败或超时仍由控制器限定清理；测试进程必须确认消失，PG 必须匹配本次 PID/完整命令/PGDATA，才可停止、卸载并删除本次随机根。身份不确定时保留失败，不用不安全删除补齐成功标志。

## 实际版本与归档版本

| 项目 | 版本或 SHA-256 |
|---|---|
| 控制器基线主仓 | `94ab2dc976c491aff9dbd8ff8fd1bee37750252f` |
| 实际执行 Runtime 源码 | `e6c8b935e5e0a00e6bfab14aa099eb8aaf0436d9` 加唯一未跟踪的 `runtime/disk_full_darwin_test.go`；不是干净已提交的测试版本 |
| 第二轮实际 Go 测试 | `985da500f2d93462f564536fdfaf8597b897feb704f914f8f6e15ac6f52aece5` |
| 第二轮实际控制器 | `c84fcb0335d642df59ebc6bc98df139f839c64229cae24b75091298a0be97ac9` |
| 第二轮实际测试二进制 | `8be221564fd43612c20c72f299a226ef6f8252b5ee4ac19759bd934b600bc338` |
| Runtime 后续归档提交 | `c4d1785dbbb0445f57f1bd5f5b2de079ee9c43fe`；仅新增上述测试和 README，测试 SHA 不变 |
| 提交用控制器 | `d2b47c6d3b2832640569b263478a3c24d274c5c306b131d986588c19978e758d` |

成功后的控制器仅将源码门收紧为固定 Runtime 归档提交加 clean worktree，保留编译前后检查和相同测试 SHA。该守卫/来源文字 delta 通过 Node 语法、逆向字节还原和独立静态审阅；没有重复执行故障，不能把归档版本另算一次通过。没有更新 Runtime 已安装服务二进制、编译依赖版本或集成 pins。

`inputs.json` 记录实际 Go 路径/版本、go.mod/vendor 摘要、源码状态与控制器摘要，`build.json` 记录测试二进制摘要。第二轮宿主初始可用空间为 37,076,537,344 字节；映像文件 535,822,336 字节，卷容量 535,781,376 字节，均在 536,870,912 字节上界内。

## 第二轮真实结果

证据目录：`local/evidence/runtime-enospc-e0b40ab2f466dcff6c4cd91ad0d3f4d2/`。故障日志时间为 2026-10-15 09:51:27（Asia/Shanghai），最终测试 1.21 秒通过。

1. 填盘前先提交基线 note、工具回执、事件和已完成 native 模型回执；另一个新运行通过归档屏障并成功 BeginModel，保存 inflight call/attempt 后才填盘。没有直接插入账本来模拟执行协议。
2. 1 MiB 写入遇到 ENOSPC 后仍有 80 块；继续 4 KiB 和 1 字节写入均得到真实 ENOSPC。累计填充 448,069,632 字节，最终本次实际可用块为 0。
3. note_save 的 `INSERT INTO documents(...)` 返回 PgError 53100。该新日志窗口中后端 PID 9156 的 ERROR 为 `No space left on device`，同 PID 的 STATEMENT 对应目标 INSERT。EndModel 的 `UPDATE calls SET ...` 也返回 PgError 53100；另一个窗口由后端 PID 9157 对应 ERROR 与 UPDATE。两窗口偏移分别为 1355、1777，不能把前一条日志当作第二个操作的证据。
4. 只释放自己的填充 inode，立即停止后启动同一 PGDATA，验证 system identifier 不变与真实恢复。**任何 heartbeat、接管、重试或重放前**，比较 `documents`、`note_roots`、`note_versions`、`note_audits`、`calls`、`model_attempts`、`events`、`runs`、`harness_exchanges`、`harness_archives` 的完整 JSON 行集合；实际十表 SHA-256 全部一致，两运行 usage 也保持一致。
5. 两个操作都明确收到 53100，本次不覆盖 commit-ack-unknown 分支。失败 note 的 documents/calls/audits/events 均为 0。待完成模型的 call 与 attempt 仍为 inflight，响应为空、没有完成时间，也没有伪造 model_completed；原 unknown attempt 及预算预留保留。
6. 初始租约为 120 秒。完成上述恢复前核对后，使用公开 Heartbeat 将 A 的租约设为 200 毫秒，再等待自然到期并 Claim 新 owner；没有 SQL 改 lease/engine/snapshot。fence 从 1 增至 2，旧 fence 的 LocalTool、EndModel 与 Exchange 均拒绝。
7. 已完成 note、native exchange 与模型缓存回执经 `jsonEqual` 验证 JSON 内容不变，合成模型完成回调仍为 1 次；这不是任意原始 JSON 编码字节的逐字节比较。失败 note 以同 operation 重试两次，最终 documents/roots/versions/audits/工具回执/完成事件各 2；model_attempts 共 2，model_completed 事件 1，unknown attempt 保留 1。没有对未完成模型响应自动重传。
8. 控制器记录测试进程停止、PG 停止、映像卸载、随机根删除均为 true，无超时、无留证错误。独立只读 `cleanup-observation.json` 确认初始 PG PID 9139 与恢复后 PID 9168 均不存在，映像和根目录不存在；测试 PID 消失依据控制器自身归属检查，未另造外部观测证明。

A 的 prompt/completion/cached/accounted 为 200/50/120/250，都是合成响应中的 usage 字段。B 的 attempts=1、unknown_usage_attempts=1、accounted_tokens=393970 是本合成请求的保守未知预算预留，不是供应商实耗或费用；prompt/completion/cached 的 0 不代表已知免费。全程真实供应商调用为 0。

原始 `inputs.json`、`build.json`、`baseline.json`、`fill.json`、`note-fault.json`、`model-fault.json`、`before-retry.json`、`result.json`、`commands.json`、`test.log`、`postgres.log` 与 `cleanup.json` 相互对应。独立代理只读复核代码和第二轮证据，通过结论限于上述 Owner 事务范围。

## 首轮失败与评审漏检

首轮证据：`local/evidence/runtime-enospc-9c3bd97247d6e7bc83edfdf79483781d/`。实际 Go 测试 SHA 为 `e4c1425c2aadc6aa9cdc598486ea52ef9f007b7dc5ca6c4167d8f32622cd0509`，控制器 SHA 为 `a443e7f56450fb56f319e733fda27fbc0f7e9b8b5fd895bcd25ef8e7de77f35f`，2.78 秒失败。

该轮同样填充 448,069,632 字节至本次实际可用块为 0，但 note 操作 SQLSTATE 为空、目标 SQL 未命中，没有对应 PostgreSQL 磁盘错误；尚未到达 EndModel 故障和恢复/重放阶段。

源码与工具契约复核发现夹具按底层文档存储上限选择 128 KiB 内容，忽略 note_save.content 的更早 `maxLength: 20000`，导致 INSERT 前被拒。初次静态评审漏检该约束；原日志未记录该非 PgError 的原文，因此此归因是源码/契约判断，不伪造为日志原句。这是夹具缺陷，不是生产 Runtime 磁盘缺陷。

修订只将内容设为 8 KiB 随机字节转成 16,384 个 ASCII hex 字符，填盘前对实际 Invocation 调用现有 authorize，并增加故障 error_type 留证；模型响应仍为 2 MiB。没有放宽生产限额或 53100/目标 SQL 断言。修订经独立复核后重新执行产生第二个 nonce，未覆写首轮证据。

首轮 cleanup 四项均 true，整体 passed=false，无超时或留证错误；独立观察确认当次 PG PID、映像和随机根均不存在。失败轮和对应源码摘要继续留存，不计通过。

## 复跑与尚未关闭范围

在已准备固定工具链与固定 clean Runtime 提交的独立 Mac 工作区内，显式执行：

```sh
node scripts/acceptance/storagefault/run-macos.mjs \
  --run-reviewed-fixture "$HOME/workspace/agent-platform" --runtime
```

控制器只接受本次固定提交与测试 SHA，缺少精确来源时拒绝执行；不要跳过校验或把未知 HEAD 当作兼容组合。常规 Go 测试没有专用 `RUNTIME_ENOSPC_FIXTURE` 时明确 skip，该 skip 不是磁盘验收通过。

本切片没有覆盖非空有效期、改版或撤回：基线笔记 `valid_until` 和 `supersedes` 都为 NULL。没有 Compact、远程工具回执、独立服务/Worker/DSH 接管、真实 Storage 同时故障、宿主盘耗尽、Linux Docker 资源/OOM 边界或全平台连续任务资源测试。旧 `internal/platform/disk_full_test.go`、`storage-faults.yml` 和既有 Linux 组合覆盖继续保留。

Windows 受管发布、DPAPI、原库恢复及目标环境权限/资源验收仍待复验。完整 P0–P5/P2.5 与 W01–W14 不由本次局部结果关闭，尤其 P2 全量覆盖移交、P2.5、W08/W09/W12/W14 仍有未完成范围。没有推送或触发 Actions，也没有以本机测试覆盖原 Windows 历史证据。
