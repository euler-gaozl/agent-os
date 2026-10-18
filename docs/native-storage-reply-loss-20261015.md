# Mac native-v4 真实 Storage 归档确认丢失验收

2026-10-15，维护者独立 Mac，macOS 15.3 / arm64。此增量补 P2.5、W08/W14 的一个真实服务故障场景，不关闭整个阶段。没有访问原 Windows、运行 Actions、调用真实模型或更换开发栈服务。

## 场景与范围

入口是 `scripts/acceptance/nativearchive/native_archive_test.go`。测试只依赖标准库与固定 pgx，不导入 Runtime、Worker 或 Storage 实现。实际运行独立 Runtime、Worker、Node、Storage 二进制，以及两个新建、受限账号访问的 PostgreSQL 数据库；Registry、ToolHub 路由和 TLS 模型供应商是本机 HTTP 夹具。

模型只返回一条合成笔记工具调用和固定最终结果。经过真实 Storage 的每个上传先正常提交；代理在一条笔记已提交后的 manifest PUT 成功返回时扣留确认。此时必须观察到 Runtime 中原始 `batch` 仍在、`manifest_hash` 为空，模型请求及工具路由各一次。

随后只终止该测试 Worker 的独立进程组，重启测试 Storage。启动接管 Worker 之前，通过真实 Storage HTTP 回读已提交 manifest 与全部分片，并核对哈希、长度、偏移、原始 batch 和笔记/回执内容不变。另从 Storage 自己的数据库只读核对 manifest 和每个唯一分片都有 `run:<新任务ID>` 保留引用；管理下载成功本身不作为引用存在的证据。

替代 Worker 等待正常租约到期，以新 fence 接管。测试不修改任务状态、租约、回执或归档行。最终要求模型两次、工具路由一次、笔记一条，旧 fence 的 HTTP 调用按固定协议返回 412；全部归档按链关系回读，已确认暂存 batch 才清空，原笔记与原回执保持不变。

这不是 ENOSPC、数据库进程重启或断电测试，不证明磁盘满恢复；没有测全平台资源上界，也不替代 Windows Job、受管发布包或 DPAPI 验收。故障发生在 Worker 向真实 Storage 上传归档的确认阶段，不是工具外部效果未决场景。

## 固定产物与执行条件

- Runtime：`e6c8b935e5e0a00e6bfab14aa099eb8aaf0436d9`。
- Worker：`ff9a2f07f397bf0b408256e8a71644b3d2976376`；其 Runtime execution 固定依赖未改。
- Storage：`ded5920e1e684cb07f0789bf33f77aec3a0afa5c`。
- Harness：`a8a18e41de719901dbef4513faf898af95822d7a`，上游 `639ed015397290b3745d163aafe02ffee4aa3f84`，native-v4 manifest SHA-256 `d76588bae0edd1d7f13cdb4d01423ac8fc14da240fba682bcec4a1fb08f8ba7f`。
- Go 1.27.2、Node 24.19.0、PostgreSQL 18.6，均为本 Mac 的当前架构产物；二进制、runner 的实际 SHA-256 写入每轮 `inputs.json`。

测试只接受独立 Mac PostgreSQL 的 `127.0.0.1:55432/postgres?sslmode=disable` 管理连接和专用 `agentos_mac_test` 身份。新资源以随机 `native_archive_` 数据库名、`na_` 角色名创建，随机密码与服务 Token 不入仓。所有测试服务监听动态 loopback 端口，不读开发栈配置或供应商凭证；子进程环境白名单不继承模型密钥、代理或 `NODE_OPTIONS`。配置文件权限 0600，正常测试退出时删除配置、停止自己创建的进程并移除新库/角色。

## 复验入口

显式设置 `TEST_DATABASE_URL` 和下列 `NATIVE_ARCHIVE_` 环境变量：`EVIDENCE`（必须尚不存在的绝对目录）、`RUNTIME`、`WORKER`、`STORAGE`、`RUNTIME_MIGRATOR`、`STORAGE_MIGRATOR`、`NODE`、`RUNNER`（其余均为固定产物绝对路径）。不要打印连接串或 Token。

当前集成主仓没有 vendor；本轮从已固定的 Runtime 仓工作目录，使用其 pgx vendor 离线编译这一个测试文件：

```sh
GOWORK=off GOTOOLCHAIN=local GOPROXY=off go test -mod=vendor -race -count=1 -json -timeout=3m \
  "$HOME/workspace/agent-platform/repos/agent-os/scripts/acceptance/nativearchive/native_archive_test.go"
```

没有借用 Runtime 包的测试或服务实现，也没有改变模块、锁文件或源码版本。未配置 `NATIVE_ARCHIVE_EVIDENCE` 时明确跳过；跳过不算通过。此入口仅有 Darwin/Linux 编译约束，实际执行证据仅来自上述 Mac。

## 本轮结果与证据

最终第三轮 `TestNativeArchiveCommittedReplyLoss` 在 `-race` 下通过：1 项顶层测试，0 失败、0 跳过，测试 21.13 秒（包总计 22.513 秒）。实际场景结果如下：

| 观察 | 结果 |
| --- | --- |
| 扣留确认时 | 1 次模型请求、1 次工具路由；Runtime 未确认 manifest，原 batch 留存 |
| 重启 Storage 后、开始重试前 | 故障 manifest 与其单分片共 781 字节原始 batch 回读一致；笔记、回执及 `run:` 保留引用不变 |
| 自然租约接管 | fence 从 1 到 2，owner 为新测试 Worker；故障到结果观察约 20,075 ms |
| 最终模型/工具/笔记 | 2 次模型夹具请求、1 次工具路由、1 条笔记、2 条模型尝试 |
| 原始归档 | 12 份 manifest，共 12,120 字节事件；全链与保留引用验证通过，未确认暂存 batch 为 0 |
| 旧 fence | 原工具调用 HTTP 412，已提交笔记和回执没有改变 |
| 夹具 usage | 已计量 3,800 token，其中提示 3,600、输出 200、缓存提示 1,800；未知用量尝试 0；真实供应商调用 0 |

时间是这一受控样本的观察值，不能作为普遍恢复上限；本轮不是大分片压力测试。保留首次缺少提交幂等键的失败和第二次把固定 ErrFence 状态误写成 409 的测试断言失败；两项均只修测试，不改服务协议。第二次已到达真实故障和自然租约接管，但不能计为完整通过。

最终证据是 Mac 的 `local/evidence/native-archive-20261015-third/` 及同级 `native-archive-20261015-third.jsonl`：保存固定产物输入哈希、Owner 创建资源清单、独立进程日志、`fault.json`、`before-retry.json`、`usage.json` 与 `result.json`。第一、二轮失败分别保留在 `native-archive-20261015-first` 和 `native-archive-20261015-second`，没有追写成通过。原 Windows 历史记录保持不变。

主代理独立只读评审发现需要补充实际保留引用断言；候选已补强，第三轮执行包含该断言。作者随后核对第三轮 JSONL、所有摘要和当前候选源码，确认报告与实际结果一致、临时配置文件已移除；工作副本与仓库测试文件 SHA-256 同为 `f93a1f94194ea3d4333598db71378ffa67c3c6a58e1cb3431c3c3fef1670f94c`。主代理复核原始逻辑和引用断言增量后，没有剩余阻断。

主代理另执行只读目录、数据库系统目录及进程快照检查，结果保存在最终证据目录的 `cleanup.json`：三轮创建的 6 个数据库、9 个角色及相关数据库连接全部为 0；配置文件、按测试配置路径识别的服务进程和孤儿 native Node 均为 0。该检查只读取状态，没有停止开发栈或其他进程。不以场景 `result.json` 替代这个清理结果；未执行全局测试超时/断电下的清理验收。
