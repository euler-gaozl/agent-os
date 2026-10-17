# Windows 确定性交付候选（2026-10-17）

## 后续：Worker 完整包与 Registry 已接通

2026-10-17 13:50：本次增加独立 Worker 集成及资源发布校验，正式配置/数据库/运行版本保持原组合。未做付费调用，Actions 仍禁用。此前“尚未接入 Worker”是下方首轮记录的当时状态。

| Owner | 固定源码 | 本次结果 |
| --- | --- | --- |
| Worker | `c828bbccbb9903ff20c47e6b0e5201124d810f2b` | 固定 execution `7805a48`、SDK rc.4、Harness `696c019`；独立 final-v5 pin、显式配置、冻结策略传递、原生传输及完整五源码引擎包 |
| Runtime | `3477714dd70f8a7657eb57219071530a028f27c7` | 增加实际独立进程联合验收；生产 execution 仍为上一提交，Worker pin 无需因测试/文档变化漂移 |
| Registry | `6053f9cb5201c42ecef78c702a9c9be6f320c9f6` | SDK rc.4 保留 final_output；发布前通过 ToolHub HTTP 校验固定 Skill/MCP 绑定；声明支持配置协议 |

Worker 全仓 102 个测试事件通过，零测试跳过（healthcheck 无测试文件不算测试跳过）；vet、依赖所有权检查及泄漏扫描通过。新完整包实际移到新目录，原目录不存在；历史两种包协议及源码 v1–v5 均执行，v5 真正走送检→引用选择→finish_ref。搬迁后的包再次参与真实 PostgreSQL/Runtime HTTP/独立 Worker exe/Node 联调，2 顶层、13 子场景全部通过，零 skip。

其中 v5 的 7 个子场景覆盖 312,021 字节 Unicode/CRLF/尾空白原文、选择后强杀、结束事件落盘后强杀、选择/完成 SQL 写故障后的显式恢复、取消及供应商半包。正常/恢复均两次模型请求、一次检查、唯一完成回执；原文 SHA-256 为 `6a53a44c51653aea8e52d9e4d3852af05a7c6643bd207e8176c309d6cc0bb0f6`。旧 native-v4 六场景保持通过。供应商、检查工具和归档 HTTP 为夹具；接管只对测试任务手动缩短租约，不称作自然超时或真实 Storage 验收。私有入口 `ops/final-worker.path`、`ops/final-worker-package.path`、`ops/final-worker-joint.path`，最终联合证据 `final-worker-joint-81294f9ce4cc42618434ffac6bcf5a14`。

Registry 全仓 39 个测试事件、零测试跳过及 vet/build 通过，实际隔离 PostgreSQL 验证发布/回读不丢策略、新 MCP 版本不改变旧绑定、错误不增加版本、无策略旧 Agent 兼容；独立 ToolHub HTTP 夹具验证精确版本解析与故障关闭。模型能力发现为合成响应。私有入口 `ops/final-registry.path` 指向 `final-registry-2621080b112d49c8a2f00b50f9e58ede`。

独立 Agent 复核 Worker/Registry 未发现新的 P1/P2。它发现的 result_kill 注入条件错误已改为匹配真实冻结回执摘要及完成事件，并通过整套重跑；包冒烟测试的 inputSchema 拼写错误也已修正并以重建搬迁包验证。失败证据保留，未算通过。独立 Agent 未运行 PostgreSQL。

**下一步仍须完成：** Console/Futures 实际读写/编辑字段保留与 UI 配置；业务检查工具显式结构就绪；v5 模型失败的显式接续；受管升级/回滚门槛和完整固定资源发布；再按内容缺陷修复及离线预检安排一次有界真实业务验收。集成 source pins 尚未切换，新 Worker/Registry 尚未安装。P0–P5/P2.5、W01–W14 及其余 UI/生命周期/权限/备份/故障/最终 CI 继续保留。

## 首轮：SDK、Harness 与 Runtime 事务候选

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
