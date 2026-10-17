# Windows 确定性交付候选（2026-10-17）

完整 P0–P5/P2.5、W01–W14 继续执行。本轮关闭的是确定性交付的 SDK、DSH 候选和 Runtime 事务实现，不是整个 R2 或单机 Goal。正式安装组合保持，未重跑真实研究，也没有新增付费模型调用。

## 源码增量

| Owner | 固定源码 | 已实现内容 |
| --- | --- | --- |
| SDK | `4022ca5e86168b1d5f748b72a8483cd7ff5a73e8` / `v0.1.0-rc.4` | 可选不可变 `Agent.final_output`；旧 JSON 不增加字段 |
| Harness | `696c01972afbf73f5ce21947f16253913070323d` | 独立 `dsh-source-639ed015-final-v5`，提交工具独占批次，官方 concludeTurn，真实结束事件及落盘屏障后 finish_ref |
| Runtime | `7805a48` | 最新已提交候选/原字符串/就绪/策略/约束/模型决定校验；完成状态、结果和回执同事务；错误与丢回复恢复；普通文本与篡改 Run 均不能绕过 |

新候选没有安装，集成 `deploy/service-sources.json` 没有推进到它。旧 native-v4 的 runner、kernel、构建脚本、上游、补丁和依赖锁未修改；旧任务原结果保持。

SDK 与 Harness 已推送并核对 GitHub main、原开发分支及 SDK tag。普通 Git HTTPS 本轮失败，使用已授权 GitHub Git Data API 上传，逐个核对 blob、tree、commit 原始 SHA，再非强制更新引用；没有重写提交。Runtime 和本文件所在集成仓按同样方式同步，最终远端核对记录在本机证据。Actions 始终关闭。

## 检查及其限制

- SDK 单元测试与 vet 通过。Runtime 使用标准 Go 下载的固定模块和 vendor；SDK module sum 为 `h1:bzAa7Zt82pETqEcifNMqP5qMO3BdpKPEoHZGOo9vOM4=`。
- 实际源码 DSH + 独立 Node 子进程：v5 19 项、旧 v4 17 项通过，零 skip。覆盖长 Unicode 原文只提交一次、短引用结束、混合工具批次预先拒绝、错误参数纠正、拒绝后重检、持久化失败、选择/结果落盘/完成处强杀及重放、官方压力 Compact。供应商和监督器为夹具。
- 实际 PostgreSQL + Owner DDL + 独立 Runtime/Worker 权限：27 顶层 / 45 子场景通过，零 skip；新最终化为 10 顶层 / 24 子场景。包括事务内故障无部分完成、选择及完成丢回复、fence 接管、冻结事件投影、当前约束/未决调用/取消、实际 CheckpointFailure→control 恢复→新 Worker 领取。同场景合成模型请求不增加。
- Runtime internal/runstate 单元测试、全仓 vet、服务 build 通过。数据库已停止，正式库和正式进程未变。私有入口 `ops/final-output.path` 指向 `local/evidence/final-output-814c36c0b41e4a35951d29cd74bfa1c6`；完整 JSONL、构建及数据库停止日志留存。
- 独立 Agent 找到并关闭错误参数永久失败、调用者策略绕过、legacy 接续绕过、普通错误恢复缺口及 checkpoint 取消卡住等问题。该评审的数据库部分是静态检查，Harness 有定向独立复测；不能称作独立 Agent 运行过全部测试。

Node 协议夹具与 Owner 数据库测试没有合成尚未执行的独立 Worker exe + Harness + Runtime HTTP 联合验收。它们也不证明报告事实正确。原真实研究的内容缺陷、最后送检后改稿事实和待核记录仍保留。

## 下一步按依赖顺序执行

1. Worker 固定 Runtime execution 新提交和 Harness v5，传递冻结 final_output；加入引擎/完整发布包/历史兼容。真实进程联合测试后才推进安装 pins。
2. Registry / Console / Futures 等实际 Agent 读写路径升级 SDK，并通过注册→重读→快照→Worker 证明字段未被旧 DTO 静默丢弃。业务检查工具明确返回结构就绪布尔，来源待核不伪装成事实正确。
3. 补齐 v5 其他模型失败的显式接续、管理 UI、受管升级/回滚门槛；当前只打通内部最终化交换的安全恢复，legacy 路径明确拒绝 v5。
4. 固定资源并正式安装；修正已独立发现的通用研究方法缺陷后，再做一次有界真实业务验收，验证最终字符串及内容。不得把旧稿改写为新结果。
5. 继续原 backlog 的逐页 UI、服务/权限退役、生命周期、Windows 故障/资源、最新备份实际恢复及一次预算内统一 CI。未经验证的不关闭，服务器 HA 等既定后续范围不倒灌为本次阻塞。
