# 独立 Storage：Mac 有界卷真实 ENOSPC 与同库恢复

2026-10-15，维护者自己的 macOS 15.3 arm64 环境完成一次独立 Storage 真实磁盘空间故障验收。它推进 P2 的 Storage 故障覆盖移交；没有执行 W08 的 Compact 或 W09 的笔记修订场景，不替代 Runtime 笔记/调用回执 ENOSPC、Windows 验收或 W12/W14 的全平台资源与剩余故障测试。

## 实现与运行边界

入口是 `scripts/acceptance/storagefault/run-macos.mjs`，Go 夹具是同目录 `storage_enospc_test.go`。Go 只依赖标准库与固定 pgx，通过独立 Storage HTTP 接口验证，不导入服务实现。Storage 的 Owner 迁移创建表与应用账号权限；不把集成仓迁移当作 Owner 迁移。

控制器只创建新的随机目录、新的磁盘映像、新的 PostgreSQL 集群和应用账号、独立 loopback 端口及新 Storage 进程。不读取开发栈配置、旧数据库、供应商密钥或 Windows 资料。Runtime/Registry URL 显式指向夹具自己的 Storage 地址，使后台心跳不访问其他 localhost 服务。没有模型调用、Harness 或供应商夹具。

- 工作根由命令参数明确给出，必须是规范绝对路径、物理目录且不含空白；不接受已有挂载路径或数据库地址。
- 新目录固定为工作根下 `local/data/storage-enospc-<随机nonce>`；证据在对应的 `local/evidence/storage-enospc-<nonce>`。目录权限 0700，新凭证与配置 0600，不提交。
- 创建 511 MiB UDIF 映像，文件和卷容量均验证不超过 512 MiB。创建前两次检查宿主至少有 2 GiB 可用空间。不用 sudo、稀疏 bundle、宿主填充文件或系统服务设置。
- 外部 owner marker、卷内 marker、nonce、物理路径、设备号、PGDATA、PID 与完整 PostgreSQL 命令必须对应本夹具。Go 通过控制器提供的 `STORAGE_ENOSPC_WORKSPACE` 再次绑定全部路径；没有该明确工作根不能触发故障。
- 填充文件以 exclusive/no-follow 创建并校验设备；按 1 MiB、文件系统块、1 字节逐级写入，每级都要求真实 ENOSPC，累计写入有 512 MiB 上界。只删除此前创建的同一 inode。
- Go 失败或超时后，外部控制器仍执行限定清理。仅确认自身 PID 身份后停止进程，凭精确 image-path 解析设备并卸载；只有映像已不存在于挂载信息、挂载点设备回到宿主后才删除自己的随机根目录。身份无法确认时拒绝不安全操作并保留失败状态。留证失败不会跳过清理。

## 本次实际版本与条件

独立 Storage 源码固定为 `ded5920e1e684cb07f0789bf33f77aec3a0afa5c`。实际二进制 SHA-256：

| 产物 | SHA-256 |
|---|---|
| Storage | `ea1fe73fb69859180d6c0bba35cc7f932d0a3818e591809d7e7d0f8556dd1131` |
| Storage Owner migrator | `5acbc82e170e29352ae6a53076961afbc61d07e1471395c206190e4ef12e7412` |
| 实际执行的 Go 夹具 | `29af6846466a82a76deadc3849f76028cbda89cf48f53035639c564d4691f8b7` |
| 实际执行的控制器 | `a77adf24e1c068c304156577cc07ff98fbbb8a33b493684bcac589ed47e8f9f0` |

工具链是 Go 1.27.2、Node 24.19.0、PostgreSQL 18.6；使用 Owner 仓固定 vendor 离线编译夹具。宿主初始可用空间为 37,265,592,320 字节。实际映像文件为 535,822,336 字节，卷容量 535,781,376 字节，均小于 536,870,912 字节上界。PostgreSQL 与 Storage 分别使用新端口 54942、54943。

当前提交版本仅将上述已执行版本的个人绝对路径改为明确的工作根参数，并相对控制器定位 Go 文件。这一移植 delta 已做 Go 格式、Node 语法、固定 Owner vendor 下 Go 编译/vet 和独立逐行静态审阅，无剩余阻断；没有再次执行磁盘故障。控制器保留已验证二进制哈希；其他重建产物需要先核对来源与哈希，不自动改用仓库 HEAD 或跳过校验。

## 真实结果

`TestStorageDiskFullRetainsArtifacts` 一项通过，耗时 0.97 秒；本次未启用 race detector。不是 skip，也不是模拟 HTTP 失败。

1. 先通过 Storage 保存合成 baseline，读取精确字节，并验证实际 `artifacts` 和对应 `run:<nonce>` 的 `artifact_refs` 各一条。
2. 1 MiB 写入遇到真实 ENOSPC 后仍有 38 个可用块（155,648 字节）；4 KiB 写入继续消耗这些块并再次 ENOSPC；1 字节写入也 ENOSPC。累计填充 465,723,392 字节，最终本次实际可用块为 0。测试记录真实统计值，不把“必须为零”当作跨文件系统前提。
3. 新的 1 MiB 随机合成产物上传返回 HTTP 503。故障窗口内 PostgreSQL 明确记录 SQLSTATE `53100`、`No space left on device`，对应语句为 `INSERT INTO artifacts(...)`。503 与数据库磁盘错误共同证明故障实际到达 Storage 持久化路径。
4. 仅移除自己的填充 inode，立即停止新 postmaster，再从相同 PGDATA 启动。日志包含真实 WAL recovery；PostgreSQL system identifier 保持一致，没有重建数据库。
5. 在任何重试前，baseline 原字节与保留引用均存在；失败写入的 artifact/ref 均为 0，没有只提交一边。此断言发生在重传之前，重传不能掩盖已有数据丢失。
6. 对相同新 payload 连续上传两次后，原文均可精确回读，最终只有 2 个 artifacts、2 个 refs，没有重复保留效果。
7. Storage 与 PostgreSQL 全部停止，映像卸载，随机夹具目录移除。四个 cleanup 标志均为 true，无超时、无留证错误；证据目录独立保留。随后独立只读核对确认 Storage、初始及恢复后的 PostgreSQL PID 均不存在，映像不再挂载，随机根已删除，见 `cleanup-observation.json`。真实供应商调用为 0。

## 证据、失败保留与复跑入口

本机证据以工作根相对路径表示，不把私有日志作为源码提交：

- 首轮：`local/evidence/storage-enospc-0c25ebb05d70f300ae411f3dd3bad93a/`。已触发大块写 ENOSPC，但夹具错误要求可用块为 0，因剩余 38 块提前失败，尚未请求 Storage；清理完整。保留该失败，不计通过。
- 第二轮：`local/evidence/storage-enospc-5ff4204ff489f2bf463c87acfa3b5df2/`。`inputs.json`、`volume.json`、`processes.json`、`test.log`、`fault.json`、`before-retry.json`、`result.json`、`postgres.log`、`commands.json` 与 `cleanup.json` 相互对应。

两版故障逻辑与清理边界均由独立代理静态审阅；第二轮证据另经只读独立核对。无凭证/DSN进入上述证据，测试配置与账号只存在于已清理的隔离环境。

在已准备相同工具链及已核对产物的独立 Mac 工作区中，从集成仓根目录显式执行：

```sh
node scripts/acceptance/storagefault/run-macos.mjs \
  --run-reviewed-fixture "$HOME/workspace/agent-platform"
```

控制器读取工作根下 `local/toolchains/go1.27.2/bin/go`、`local/toolchains/postgresql-18.6/bin` 和 `local/mac-dev-stack/bin/{storage,storage-migrate}`。它只读取这两个已固定哈希的可执行文件，不读取运行栈配置。缺少精确工具或产物时应先完成独立构建与版本核对，不连接旧电脑补齐。

常规 `go test` 在没有专用 `STORAGE_ENOSPC_FIXTURE` 时明确 skip；不要把该 skip 算作故障通过。控制器为每次显式执行产生新 nonce，不复用此前集群或恢复旧任务。

## 尚未关闭的验收

本次只验证真实 Storage 产物/引用事务在有界卷写满后的保留、恢复和重试幂等。Runtime 笔记与调用回执的真实 ENOSPC 移交仍未完成；`internal/platform/disk_full_test.go`、`storage-faults.yml` 及其他旧覆盖继续保留。Windows 受管发布、DPAPI、原库恢复、正式权限撤销仍待目标环境复验。全平台加数据库的连续任务资源上界、Linux 2 核/4 GiB 与生产容量也未因此通过。
