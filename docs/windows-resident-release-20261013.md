# Windows resident-v2 发布控制

后续执行补充：保持本文安装版本，正式 v2 Agent 的真实供应商执行、全部归档回读及联合资源/恢复测量已完成，见[后续验收](resident-joint-acceptance-20261013.md)。下文“没有正式 v2 任务”及备份覆盖范围均指本次发布维护发生时；之后新增的 v2 历史必须保留 Runtime 支持。

2026-10-13。本增量为发布控制器增加独立的 resident-v2 能力声明、产物、启动配置和回退检查。双版本 Runtime/Worker 发布已实际安装并验证独立升级/回退、默认配置往返；最终默认仍为 state-v1，没有创建正式 v2 任务。整体单机交付目标仍在推进。

## 版本策略

旧描述符的 `source_execution` / `source_harness` 继续只代表 state-v1。新增 `resident_execution` / `resident_harness` 只代表 resident-v2，不能以同一个字段同时声称两个版本。Runtime 的两版声明必须包含已支持的提交、工作状态及恢复协议；Worker 的每个声明必须对应独立固定 manifest 和 Harness 提交。旧描述符不会自动获得 v2 能力。

维护前以 Runtime 的已绑定配置访问执行数据库，分别统计每个版本的全部任务及可恢复任务；`completed` / `cancelled` 之外的状态均保留恢复要求，包括 `failed` / `waiting_unknown`。缺少任一版本计数、计数非整数、负数或恢复数大于总数都拒绝维护，不把缺失视作零。

| 现场条件 | 限制 |
| --- | --- |
| 保留任意 v2 任务，包括已经结束的任务 | Runtime 不能回退到只支持 v1 的版本，保留查询、原文与状态回读能力 |
| 默认引擎是 v2，或存在可恢复的 v2 任务 | Worker 不能移除 v2 产物与执行能力 |
| 默认已切回 v1，v2 任务全部结束 | 可以移除 Worker 的 v2 能力；Runtime 仍须保留 v2 支持 |
| 安装的 Worker 声明 v2 能力 | Runtime 必须先支持 v2，即使当前默认仍是 v1 |
| Worker 只安装 v2 产物 | 不宣称能够领取 v1；存在可恢复 v1 任务时拒绝选择该发布 |

`build -Service runtime,worker -SourceArtifact <v1目录> -ResidentArtifact <v2目录>` 分别核对 Worker 编译 pin 并复制完整产物。清单、备份导出和还原包括两套目录。`set-engine -Engine resident` 复用现有加密配置事务，`source` 仍表示 v1，`historical` 仍表示历史 evidence-v1；配置切换不会更改已有任务的 engine。

启动变量只从已验证的发布资产派生，配置文件不能指定其他 source/resident runner。切换默认值时检查实际存活 Worker 的两套路径、Node、数据库、Runtime 端口和服务身份。中断恢复使用原事务记录，不新增另一套状态权威。

## 验证记录

- `local/evidence/source-release-policy-3ac0f04538d041c5bdc75376cfe6cd30`：55 项通过。实际两版固定 DSH 产物复制、完整发布导出/还原及篡改拒绝；实际隔离 PostgreSQL 与受限账号查询版本计数、迁移结构和授权。描述符中的服务二进制为非执行标记，不是实际服务升级。
- `local/evidence/default-engine-08fafa667c1b4c83a5f2b88e5cfaec00`：resident 模式 49 项通过，正式外层维护入口可用；实际 Windows HTTP 夹具 Runtime、两个 Worker、隔离 PostgreSQL、加密配置记录及十个故障位置。进程会真实退出，恢复后实际读取配置；HTTP 服务为夹具，不执行 Agent 或供应商调用。
- `local/evidence/default-engine-fc7b2071907f4f4c84daa3267e68e3e0`：原 source/v1 模式同套 49 项回归通过，配置往返和历史代码回退仍可用，不能将两次参数运行算成 98 种故障。
- `local/evidence/source-runtime-configuration-9c24469517cb47f5a83606e80af0c504`：11 项真实 Windows 夹具进程检查通过；磁盘默认值漂移、只改 catalog、伪造来源 hash 和改写受保护启动快照均在停止服务前拒绝。
- 首次直接运行配置夹具被“其他注册布局仍运行 Runtime”守卫拒绝；证据 `default-engine-5adb5a70abb147f18acc5a64f3baf6ea`，零项通过且清理完成。随后检查正式任务静止，受控停止正式 Runtime/双 Worker，再执行测试；没有移除或绕过该守卫。

上述三套进程检查由本地 `ops/Test-ResidentReleaseControl.ps1` 顺序执行，证据汇总目录 `local/evidence/resident-release-control-282201b04dcd4cc58512e1ca21f804f6`。正式三个执行进程已成功恢复并就绪，但该辅助脚本最后对“返回单个数组的函数”直接管道筛选导致报告失败，原失败 `result.json` 保留。修正辅助脚本的数组展开后，仅重做只读还原验证，没有重跑已经通过的故障测试：`restoration-verification.json` 绑定三份原始结果 hash，确认正式 12 个实例、其他九个实例身份不变、catalog hash 不变、v1 默认及两个已结束 v1 任务不变、v2 任务为零。不能将原辅助脚本的失败改写成全程一次成功。

独立评审确认的 `Set-DefaultEngine.ps1` 参数入口遗漏已修复，并通过外层 `Platform.ps1` 调用验收。静态审查不能替代动态测试或正式激活验收。

## 完整构建与正式安装

源码选择固定为 Runtime `8404f3e0ad3d62c3742a5eba4b996b1f88a6e8b0`、Worker `346c0032921b1f45e3b300c4716ed9551da9c133`，其事务模块为 Runtime `v0.1.0-rc.3`。集成代码 `5a013a270f33e502d974d4f15c665b38eaf4f610` 从干净仓库构建发布集 `local/releases/staged/b037b1e03b794e99abb879408b640b94.json`；Runtime 描述符 `runtime-8e70549e1bab45c98c9c9091ff8b8ab9`，Worker 描述符 `worker-83924222c9dd44268d1c4e3e7adea82d`。实际发布清单包含 Runtime 1 个文件、Worker 1,479 个文件、零链接；三项历史 Harness 接口测试通过。清洁提交、发布协议、窄模块、规范校验和及完整文件清单均通过检查。

- `local/evidence/execution-owner-releases-df1a6aac567c4d3c870f9547670352ca`：真实正式 Runtime、Worker 分别 update→rollback→update，共六次操作。每次独立替换并就绪，14 张执行/工作状态/笔记表指纹不变，`/v1/runs` 与 `/v1/notes` 回读哈希不变，非目标实例不变。没有数据库迁移或新模型任务；不声称覆盖所有历史 HTTP 接口。
- `local/evidence/resident-live-maintenance-127a0df7aee8468cab87f44a5137c659`：已安装服务的真实默认配置 resident→source 往返，通过实际两 Worker 的产物路径、数据库、Runtime 身份和 readiness 检查。v1 默认及 v2 默认下均拒绝不支持 v2 的 Runtime 回退；v2 默认下拒绝移除 v2 Worker。三次拒绝均核对所有进程和 catalog 未改变。最终默认恢复 v1，正式 v1 任务仍为两个且均已结束，v2 为零。
- 完整备份 `local/backups/resident-release-live-20261013` 已在 `local/restore-checks/6af62a28a8c347d68f137e9bac0319e8/result.json` 实际隔离还原通过：44 个关系指纹、schema/ACL、10 个角色登录和两项凭证解密；完整发布档案 25 个引用、3,018 文件、零链接。隔离数据库已停止，没有启动还原后的业务服务、Worker 或供应商调用。正式平台另行重启 12 个实例，核心健康检查通过。

独立代理只读核对维护脚本、两份正式升级/配置证据、完整发布文件哈希和二进制构建元数据，支持上述有限安装结论；没有代跑维护、查询正式数据库或把配置就绪说成 v2 Agent 已执行。实际 v2 供应商任务、长历史联合资源/恢复测量、缓存生命周期与完整 UI/业务验收继续推进。Windows Sandbox 隔离执行仍未配置。没有触发 GitHub Actions 或付费模型调用。
