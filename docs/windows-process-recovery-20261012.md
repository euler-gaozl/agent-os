# Windows 进程启动与中断恢复验收

这是 P1 单服务发布的进程基础，不是 update/rollback 已完成。运行服务仍使用 `5bfc84c` 的固定二进制、Node、Harness 与 Web；本次修改维护脚本，没有迁移数据库或调用模型。

## 实现与边界

每个实例先保存受保护的最终配置快照与启动 intent，再创建受限 DACL 的全局唯一 Windows Job。成功创建的标记必须持久化后，才用 JOB_LIST 原子启动进程。同名 Job 直接拒绝，不能在失败候选清理时结束原对象。启动只继承显式系统环境，维护终端的业务环境变量不会覆盖配置。命令行只有可执行路径与配置路径，没有秘密值。

根服务在同次创建中继承一个只有 QUERY 权限的 Job 保活句柄；维护锁不继承。Job 设置 kill-on-close，Go 启动 DSH 的显式句柄名单不转交这个保活句柄。根进程及维护者的临时句柄全部关闭后，Windows 结束剩余成员，包括不处理 stdin close 的 Node。正常停止保持同一个 Job 句柄完成终止及成员归零检查，没有新增常驻守护服务。

启动器在 CreateProcess 后、PID 落盘前退出时，下一次维护通过已确认创建的 Job、唯一配置路径、exe、命令行与创建时间恢复身份。停止支持此未登记 PID 的分支。身份或配置无法核实、退出未完成时保留记录并拒绝宣称成功。

旧实例只作一次转换：持有原父进程句柄，记录已有 Node/系统 conhost，父退出后再次核对。旧父已消失且没有可信退出边界时，不按历史 ParentProcessId 自动认领新子进程；仅处理已持久化的精确身份，并保留未解决记录、阻止替代启动。这是明确的保守限制。本次所有旧根仍存活，已完成转换。配置快照是受保护的运行记录，本批不自动删除它们或正式资料。

## 实际结果

`scripts/Test-WindowsProcesses.ps1` 使用真实 Windows Go/Node 进程和故意忙循环的 Node，数据库连接及供应商调用均为 0。本机报告：`local/evidence/windows-processes-2406c880eb5c455f8a2b4639aac4d7f2/result.json`。

八组通过：维护锁不继承；根/子原子入组及环境隔离；同名 Job 拒绝且原实例不受影响；根退出后忙子进程自动终止、另一实例不变；另一维护进程找回 PID 未保存的启动；旧父前后两次子进程核对；旧父退出边界未知时拒绝自动发现/替代而不误杀 Node；Job 创建标记写入失败时不启动进程。

真实服务验证与夹具分列，原始证据均在 `local/evidence/`：

- `managed-control-start.json`：只停止/启动 Control，故意污染维护者的 LISTEN、Token、数据库和 Web 环境变量，Control 正常就绪；其他 11 个根进程的 PID、创建时间、二进制不变。
- `managed-control-crash-recovery.json`：真实 Control 已启动、记录仍为 `pid=0` 时，维护器实际退出 197。下一进程找回身份，Doctor 提示恢复且核心就绪；随后 Stop 与 StrictMode 下的 Start 成功。
- `all-services-managed-jobs.json`、`post-managed-cold-start.json`：停止原 12 个根进程，再用新机制启动原角色及两个 Worker；12 个实例全部纳入 Job，HTTP 就绪通过。数据库保持原实例，没有初始化。Sandbox 隔离执行仍不可用。

这些结果不代替 Agent 任务的 lease/fence、效果回执、模型断连与 Compact 验收。单服务完整发布包、原子版本状态、兼容检查与失败回滚仍是 P1 下一项。新增 Windows CI 重复原生进程测试；本文提交时尚未取得 CI 结果。

## 失败与独立评审

首次错误地认为“Job 对象仍存在”意味着“名字还能重开”。最后句柄关闭后名称已删除，夹具失败、清理未完成：`windows-processes-e9fe809afa3144a3a31ff22b9d6fb7da`。随后按记录的 PID、exe、创建时间及测试目录精确清理，保留失败与清理报告。评审者承认其最初相同推论错误。微软说明了[临时对象名称随句柄数归零删除](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/wdm/nf-wdm-zwmaketemporaryobject)，不能只根据 [Job 对象寿命](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) 推出可重开。

修正保活句柄后，下一次测试错误地要求恰好两个成员；实际还包含 conhost。改为核对目标根和 Node 均属于 Job，并保存完整成员。旧转换最初拒绝该系统子进程，补入严格路径/参数/时间核对。随后测试回调的 `$root` 被函数局部同名变量遮蔽，产生清理报告失败，已改名；意外测试目录原样归档于 evidence，没有删除失败记录。

独立评审又发现：Start 可绕过旧实例未完成停止；无退出上界时历史 PID 复用可能误认子进程；StrictMode 下空 if 输出不保证数组。三项已修复并经静态复核，补测拒绝条件与实际 StrictMode 启动。评审只读源码和脱敏报告，没有执行测试或读取凭证；以上运行结果由主 agent 实际取得。
