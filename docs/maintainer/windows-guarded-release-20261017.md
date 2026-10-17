# guarded-v6 工具参数恢复

## 问题与边界

正式 final-v5 研究任务中，模型请求 `document_read limit=2400/1600` 超出冻结工具 Schema 的 1200，导致任务终止。供应商原生输入输出能力保持不变：本次没有缩小模型 Token 配额，也不把错误参数自动裁剪成另一请求。

guarded-v6 在 DSH 调用工具前验证冻结 JSON Schema，将确定的参数错误作为可纠正的工具反馈。未知效果、远端鉴权错误、租约失效和 RPC 异常继续中止；重放可见的改动使用新引擎，旧 v1–v5 产物保持。

## 已验证

- Harness：29 项实际 Node/DSH 测试，覆盖修正、错误检查点丢回复重放和远端异常；正式研究冻结的 15 个工具 Schema 均可编译。
- Runtime：85 项隔离 PostgreSQL 测试事件通过，包含 v6 成稿原子性、重放、领取隔离和幂等；vet/构建通过。
- Worker：69 项相关测试零跳过；依赖固定 Runtime execution `6774494b61ec35d79852f0148b590a4c64f18365`，不新增本地 Runtime API/迁移访问。
- 联调：实际独立 Worker、Node、Runtime HTTP 和受限 PostgreSQL；合成 TLS 供应商/校验器/存储。9 个场景通过：成稿、非法参数纠正、两种进程中断、两种 SQL 中断、取消、不完整响应、503 后续执行。原始输出逐字节保持，校验器仅执行一次。
- 发布：25 项新引擎准入/回滚检查通过；原五引擎发布策略、实际 PostgreSQL 元数据探测及产物导出/还原回归通过。缺失 v6 产物/协议拒绝；历史 v6 任务阻止 Runtime 降级，可恢复任务阻止撤掉最后一个兼容 Worker。
- 独立静态评审：Runtime 无阻断；集成入口漏传 GuardedArtifact 已修复。

初次联调的测试环境变量拼接错误已修正；五引擎测试枚举新 profile 时误取不存在资产的问题已修正。失败证据保留，只有修正后通过的记录计入以上结果。

## 发布状态

源码已进入独立仓库；本文件初次提交时尚未安装 v6、尚未执行真实供应商重跑。正式默认仍为 final-v5，历史失败记录保留。安装与业务验收结果随后追加，不能将上述合成供应商验证写成真实研究完成。

私有证据入口：`ops/guarded-v6.path`、`ops/guarded-runtime.path`、`ops/guarded-worker-joint.path`；路径属于原 Windows。Actions 继续关闭。完整 P0–P5/P2.5 和未验收 UI/平台项目保持，不因本次修复缩减。

发布前独立评审补充：旧 Console 无法识别 v6 的接续及工作状态。已新增显式 UI 支持和 guarded_transport 能力，默认/留存任务阻止回滚到旧 Console；新增 4 项门禁检查，总计 29 项。14 项 Console Web 测试及 Go/TypeScript 检查通过。
