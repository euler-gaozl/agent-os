# Windows 独立发布与恢复

2026-10-12，P1 增量。当前覆盖同一数据/HTTP/执行协议下的程序更新；跨协议或配置变化必须另做协调迁移，不能用程序回滚假装撤销数据库写入。

## 发布单位与权威

`build` 生成不可变候选包和 staged 清单，不切换正在运行的版本。普通 Go 服务包含二进制；Worker 还包含固定 Node、Harness 与已安装依赖；Control/Futures 分别包含自身 Web。纯 Go 构建不依赖 Worker 或 Node。

`local/releases/current.json` 是唯一提交权威：每个服务记录 current、previous 和 pending，更新使用一次原子文件替换提交。描述符记录相对路径、文件摘要、包内链接、源码来源和兼容契约；部署引用另绑定实际配置摘要。回滚不接受已修改配置、缺失依赖或不兼容协议。

更新顺序是验证候选与旧版完整性、持久化操作意图、只停止目标实例、启动候选、验证所属 PID 的带认证就绪接口、核对非目标实例，再提交指针。Worker 保留原副本数；原来停用的服务不因更新被启动。就绪前服务可能已写数据，因此新旧版本必须双向理解相同的数据/引擎/工具协议。

维护进程中断后，`release-recover` 根据 pending 恢复旧版。提交已完成时不能按旧日志倒退。若其他服务在此期间独立退出，恢复目标后清除 pending，并报告其他服务的漂移和待修复状态；不要求历史 PID 复活，也不假报其他服务正常。文件原子替换验证的是进程中断恢复，不是断电持久化证明。

## 基线与备份

首次登记核验此前认证备份的实际隔离恢复结果、配置、二进制、Node 和 Web；Go 构建信息必须是已审查的干净提交，使用该提交对应的历史契约。Harness 从备份离线重建后比较所有安装文件与规范化链接，仅归一化 pnpm 安装时间/缓存位置及生成 shim 中的本树绝对路径；包代码不豁免比较。已有安装的登记不是一次重新编译。

备份保存所有 current/previous 引用的完整包、描述符和 catalog，禁止有 pending 时捕获。隔离恢复重建文件和包内链接，校验全部包，再执行已有数据库、身份、加密凭证和离线 Harness 恢复检查。生成的 pnpm 管理元数据和命令 shim 保留原字节；平台直接执行固定 Node/runner，恢复测试不通过旧路径上的 shim 启动 CLI。

## 实际验证和修复

- 真 Windows 合成服务的更新/回滚、候选 readiness 失败、配置变化与缺失、协议不兼容、依赖篡改、路径穿越/上层 junction、停用实例保持停用，均有实际测试。
- 在 prepared/stopped/started/ready/committed 中断维护进程，以及恢复自身的 reverting/recovery_ready 再次中断，均由后续进程按 catalog 处理。
- 持续运行的 observer 核对非目标身份；另一次有意终止 observer，确认报告漂移且不永久锁死 pending。
- 完整 Worker 依赖链接与 Web 内容在另一路径恢复验证。夹具不连接数据库、不调用模型，不冒充完整 Agent 故障验收。
- 16 项最新原始结果：`local/evidence/windows-releases-f40fa0056880423793a09e4ff2bd7f1f/result.json`。末项旧标签的“所有事务身份保持”不含有意终止 observer 的场景，代码已将标签改得明确；原始报告未篡改。

首次失败保留：`92253cf410d046b0aeffbd8ed052bceb` 是空数组被额外包装后的测试计数误判；`35e10d5173ce4d8aa269a44271039e84` 暴露 JSON 日期自动转换导致恢复比对失败，现固定读取字符串；`056635c929a449dc8c4534073bf8588f` 是夹具重启 observer 复用日志名，被正确的 CreateNew 保护拒绝，现生成新的实例身份。

独立评审只做源码复核，没有独立执行测试；发现并修复了依赖基线未经验证、历史契约未绑定产物、纯 Go 构建依赖 Node、旧格式回退、根上方 junction、非目标退出导致恢复死锁、缺配置触发全量迁移。最新版未再确认阻断问题。测试运行由主执行器完成。

13 个原安装单元已登记为 format2，登记本身未替换进程。随后从干净提交 `bd25195927263d963e11be6d8f9348361f84c7b1` 构建 Knowledge、Worker、Control、Futures 完整候选，各自实际更新后回滚，共八次切换通过；Worker 保持两个实例，各次非目标进程身份不变，两套 Web 响应入口摘要均等于所选包。报告：`local/evidence/real-releases-09729a36aaac4112be7f316e2fae68a0.json`。没有通过这些维护测试发起模型调用或 schema 迁移。

新备份 `local/backups/release-catalog-20261012-v1` 已在停写窗口捕获，包含 current 和 previous 的完整发布集合。随后按 format2 冷启动原 12 个实例，Doctor 核心检查通过，无 pending，catalog generation=9；报告 `local/evidence/post-release-backup-bd25195.json`。隔离整库恢复正在另行执行，其结果未被本段提前标记为通过。

首次新增 Windows CI [38246029224](https://github.com/euler-gaozl/agent-os/actions/runs/38246029224) 在发布夹具启动前失败：Actions 默认检出路径为 `D:\a`，不符合已明确的 `D:\workspace` 布局约束。已让 CI 将固定检出克隆到受支持目录，并在夹具启动任何进程前校验 layout；后续 CI 结果另记。没有放松本机路径检查来掩盖差异。

## 本机入口

```powershell
& D:\workspace\agent-platform\ops\Platform.ps1 build -Service knowledge
# 使用 build 输出的完整 staged 路径
& D:\workspace\agent-platform\ops\Platform.ps1 update -Service knowledge -ReleaseSet D:\workspace\agent-platform\local\releases\staged\<build-id>.json
& D:\workspace\agent-platform\ops\Platform.ps1 rollback -Service knowledge
& D:\workspace\agent-platform\ops\Platform.ps1 release-recover -Service knowledge
```

Schema/configuration 的协调迁移仍随 P2 独立仓库交付。旧 `Start-Local -Migrate` 在 format2 明确拒绝；缺配置应恢复备份，不能偷偷运行管理员迁移。以上命令不执行自动 GC，不清理旧资料或历史发布文件。
