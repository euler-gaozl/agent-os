# Mac 研究成稿、页面与真实 Storage 增量

2026-10-15，`environment:maintainer-macos`，macOS 15.3（24D2059）/ arm64。此记录承接 [Mac 首轮开发](macos-development-20261015.md)，不覆盖 [原 Windows 历史快照](current-state.md)。下面的数据库、服务、任务和证据均来自维护者自己的独立 Mac；没有连接原 Windows、导入原私有资料或恢复旧任务。P0–P5/P2.5、W01–W14 的完整目标仍未完成。

## 本机开发栈与版本边界

复用本 Mac 的 PostgreSQL 18.6 隔离测试集群，建立新的开发数据域。9 类服务及第二个 Worker 共 10 个进程完成鉴权就绪检查；8 个数据库、10 个应用账号，Registry、Runtime、Knowledge、Storage、ToolHub 的 Owner 迁移各执行两次。应用账号没有超级用户等特权；仅用于隔离恢复测试的临时高权限账号已删除。没有改动系统全局自启。

这是一次性的本机开发辅助入口，不是新的受管发布体系。它从集成固定版本归档源码，使用 Go 1.27.2、Node 24.19.0 / pnpm 11.25.0 构建本机 arm64 产物；没有把 15 仓各自 HEAD 拼成部署组合，也没有复制 Windows 二进制。初始 Futures 是明确例外 `febd31569b66078995d54822c12552f5887cbeab`，其余服务沿用当时集成 pins。当前仅配置固定 native-v4 执行器，历史执行器产物未在这个新栈启用。

| 固定来源 | 版本 |
| --- | --- |
| Registry | `755b8de85531f0b9620a98beaf1e3a9dccc9d6b0` |
| Runtime | `e6c8b935e5e0a00e6bfab14aa099eb8aaf0436d9` |
| Worker | `ff9a2f07f397bf0b408256e8a71644b3d2976376` |
| Knowledge / Indexer | `ed54550f15e115956fc30e08e0e8121b976ee796` / `ccbfbd206f13e10619898ddb52b84e5c1109c7f8` |
| Storage / ToolHub | `ded5920e1e684cb07f0789bf33f77aec3a0afa5c` / `98f8fecc5a139b3f1b0e4d76f4a11c9d8e0c0d07` |
| Console 初始构建 | `00bc6280d13e5b1bb57276b0dedef90ea2226c68` |
| Harness | 上游固定 `639ed015397290b3745d163aafe02ffee4aa3f84`；native-v4 manifest SHA-256 `d76588bae0edd1d7f13cdb4d01423ac8fc14da240fba682bcec4a1fb08f8ba7f` |

开发栈只监听 Mac 回环地址；Console / Futures 的本机端口为 18090 / 18098，PostgreSQL 为 55432。Sources、Sandbox、Telemetry 没有迁移或启动，不能将预留配置说成能力可用。配置、凭证及数据只保存在仓库外，私有配置权限为 0600。

证据：`local/evidence/macos-dev-stack-20261015/` 的 `sources.json`、`builds.json`、`provision-and-migrations.json`、`running.json`、`final.json`。独立静态评审要求补齐数据库连接身份校验与启动失败清理登记，均在实际初始化前修复。首轮 provision 测试因 Mac 临时目录经过符号链接被物理私有目录保护拒绝；改用新的物理私有临时目录后，3 项顶层 race 测试通过、0 跳过，没有关闭保护。该阶段观察到任务及模型尝试均为 0，不能把这个早期观察用于描述随后研究调用后的数据库状态。

## 两次有界真实供应商调用

两次均使用官方 DeepSeek `deepseek-flash`、固定 `dsh-source-639ed015-native-v4`，读取同一组三份新建合成资料，回答四个研究问题。资料是明确的测试数据，不是市场事实，也不是原 Windows 的十份私有资料。每项新任务固定最多 12 次模型尝试，方法指令要求至多两次草稿检查（后者不是执行器硬限制）；没有自动重跑或续跑旧快照。第二次发生在程序和方法修正之后，另建固定 Agent/Skill 版本。

| 新 Mac 任务 | 实际请求与用量 | 最终结果 |
| --- | --- | --- |
| `06a124402c71426a0ec4525adfc2d93d` | 5 次模型请求；提示 84,703、输出 8,296、其中缓存提示 63,360，合计计量 92,999 token；未知用量 0 | `completed`，两次送检；最终 8,803 字节与最后送检草稿逐字、哈希一致，但 JSON 格式错误，v4 返回 `unstructured`，研究质量失败 |
| `c74f59013af4a953454b7368b83b5105` | 4 次模型请求；提示 61,193、输出 6,815、其中缓存提示 45,440，合计计量 68,008 token；未知用量 0 | `completed`，两次送检；最终 7,746 字节与最后送检草稿逐字、哈希一致，v5 接受格式，结果仍为 `needs_review` |

两次合计实际 9 次请求、161,007 个计量 token；缓存提示已经包含在提示 token 内，不能重复相加。这里只记录供应商返回的 usage，不将估价当作实际账单。每次均有三条完成的原文读取及两条完成的草稿检查回执，最终状态没有未确认用量。

第二次首次送检指出问题 q3 的事实引用不属于本问题集合，最后送检已没有结构修订项。最终四条事实全部匹配任务留存引文，但四条来源限制、四项资料解读复核及一项比较操作数限制仍保留，比较未自动计算。库存变化的实质解读仍不完整，不能用 `completed`、格式通过或引用逐字匹配关闭 `task:research-quality`。模型本次同时采用新方法与新检查器，改善不能单独归因于某一项改动，更不能推导稳定成稿保证或真实期货业务验收通过。

独立内容复核进一步确认：q1 尚未直接说明两期库存方向；q1–q3 的部分缺口属于原因解释、外部背景或未来跟踪，而不阻断当前问题。q4 缺少出入库、调拨、损耗及修正记录才是真正的勾稽缺口。模型新增的“库存时点与产量区间起止日不完全对齐”判断缺少原文支持，不能仅凭时点与期间的表达不同作此判断。差额仍按现有比较门槛待核，不为通过而移除合成来源限制。

首轮与次轮证据分别为 `local/evidence/macos-research-live-20261015/`、`local/evidence/macos-research-live-20261015-format-v5/`：`audit-summary.json`、`final-usage.json`、`final-task.json`、`final-report-check.json`、`final-drafts.json`、`draft-record-*.json`、`final-sources.json`、`final-complete.json`。次轮 `checker-preflight.json` 确认实际服务返回 v5；原任务、原始结果、v4 历史送检反馈均保留。

准备流程第一次因 JSON 对象键顺序比较误报而在模型调用前停止；改用结构相等比较后复用已创建资源。独立审查同时修正了证据秘密字段覆盖与终态证据逐项保存顺序；最终完成标记在所有证据落盘后才写入。没有把中途失败追写成成功，也没有把预期答案混入送给模型的资料。

## 格式反馈和研究方法

Futures 格式诊断提交为 `9dd0b031eddfde172516479afa63ebbd6e34ced9`，检查器显式升级为 `futures-report-check-v5`。保留 `futures-evidence-v1`、MCP 输入/输出结构及 `format` 问题代码；分别指出语法/未闭合位置、未知字段、类型、重复字段、深度/大小、schema 和必需数组。位置从 1 起算，明确采用 UTF-8 字节、行与字节列。未知的 `comparison.basis` 仍拒绝，不自动修稿、不放宽严格契约，不回显字段值或整段输入。

合成回归先在旧代码上失败，修复后通过；全仓 Go 测试 107 项含子项通过、0 测试跳过，vet / build 通过。另补中文前缀下错闭合、缺逗号、缺冒号三项位置回归。评审最初怀疑 Token 偏移存在一位误差，随后查明引用的是被构建标签排除的旧标准库实现；固定 Go 1.27.2 实际启用 jsonv2，新增反例在不改生产代码时均通过，因此明确撤回该问题，没有伪造 red 或加入无依据修补。证据分别在 `macos-report-format-20261015/` 与 `macos-report-format-offset-20261015/`，包含失败记录、检查日志、源码摘要和撤回结论。

主仓研究方法补充完整年月的 explicit 日期归类、稳定指标/样本名称、问题与 finding 的引用成员关系、比较对象的固定字段、客观变化回答与证据缺口分层。独立规则文本与嵌入 Skill 的内容一致，没有写入本次合成数值、日期、文档或任务标识；四份 Agent seed 与预算候选生成器保持不变。方法核对与差异记录在 `local/evidence/macos-research-method-contract-20261015/`。这仍是方法指令，不能替代执行器保证、来源复核或完整业务验收。

## 页面增量与未执行的浏览器验收

Futures UI 提交：`2482bcbbee7f5535ad73d7a0dea3f9ff96293331`。修复完成且有非空结果的任务无法查看阶段草稿的问题；历史草稿不再误称“任务仍未完成”。当时反馈与当前检查器分别展示，不混改历史版本。同任务从待核对/失败进入完成时重新读取草稿，防止保留旧任务状态；有最终结果时不重复绘制资料列表。

完成任务文案回归先红后绿；最终 15 项 Web 组件测试通过、0 跳过，TypeScript 与独立 Vite 构建通过。独立评审发现状态转换可能保留旧草稿缓存，已修复并静态复核。曾尝试的 element-key 断言只检查组件身份，不足以证明真实生命周期，已移除；其日志与限制说明保留，不计动态状态转换验收。最终证据为 `local/evidence/macos-completed-drafts-20261015-v2/`，首轮 `macos-completed-drafts-20261015/` 不覆盖。

Console 业务入口提交：`a2bca748d1bd6f0de0e52e1e0a59070e790d5fbc`。桌面和移动导航复用显式配置的浏览器地址，不再硬编码旧端口。未配置、读取中或读取失败时入口不可操作。鉴权接口仅返回一个经校验的公开导航地址，不暴露内部服务配置或令牌、不探测业务站点、不把中台身份附加到跳转中。HTTP(S)、地址长度、账号密码、查询和片段等限制均有回归。11 项顶层 Go race 测试、22 项 Web 测试及 vet / 独立 Go/Web 构建通过，测试跳过为 0；独立静态审查无剩余阻断。证据：`local/evidence/macos-console-business-entry-20261015-first/` 的 `summary.json`、`checks.json` 和日志。

上述两个 UI 提交目前仅完成源码与构建验证，候选尚未安装。运行中的 Futures 后端为 `9dd0b03`，Web 仍是此前固定 bundle；运行中的 Console 仍为初始 pin。不能把仓库 HEAD、构建成功或新配置支持写成当前页面已生效。

本轮尝试打开 Mac 本地业务页面时，浏览器安全策略拒绝访问并要求不改用其他浏览器或底层方式绕过；已停止浏览器操作。真实页面中的当前/历史草稿切换、引用回读、状态转换、桌面/390px 布局和配置入口跳转均不能记为本轮浏览器通过。组件渲染和构建结果不能替代这些验收。

W03 的 Agent 固定绑定、编辑/试运行/发布，W04 的 Skill/MCP 校验验活及在用工具停用，W05 的上传/重传/索引/权限/失效后检索，W13 的全部中台和业务页面继续保留。原 Windows 已闭且不受改动影响的引用分页、回执关闭竞态、失败任务草稿和采集幂等场景保留原证据；本 Mac 的新端口、安装组合和新增 completed 流程只补必要增量，不重复付费调用替代页面操作。Sources 未启用，所以本栈不能声称完成真实网页采集流程。

## 真实 Storage 确认丢失与自然接管

详见 [真实 Storage 验收记录](../native-storage-reply-loss-20261015.md)。实际运行独立 Runtime、Worker、Node、Storage 二进制及两个新建、受限 PostgreSQL 数据库；Registry、ToolHub 路由和 TLS 模型供应商仍为明确夹具，真实供应商调用为 0。故障代理在一条合成笔记已提交、Storage 已提交 manifest 后扣留成功确认，随后仅终止测试 Worker 的独立进程组并重启测试 Storage。

接管前通过真实 Storage HTTP 重读 manifest 与分片，核对 781 字节原始 batch；从 Storage 数据库只读确认 manifest 和唯一分片各有任务保留引用。替代 Worker 等自然租约到期，以 fence 2 接管；不修改任务、租约或回执来促成恢复。最终模型夹具请求 2 次、工具路由 1 次、笔记 1 条；12 份 manifest、12,120 字节事件全链回读一致，未确认暂存 batch 为 0；旧 fence 的原工具调用返回固定协议的 HTTP 412，笔记与回执未变。

最终第三轮在 race 下 1 项顶层测试通过、0 跳过；故障至结果观察约 20,075 ms，仅为该受控样本的时间。第一轮缺提交幂等键、第二轮把 ErrFence 的状态误断言为 409，均保留失败，只修测试、不改服务协议。独立评审要求补充实际保留引用断言，第三轮包含该断言。只读清理复查确认三轮新建的 6 个数据库、9 个角色、相关连接、临时配置、测试服务和孤儿 native 进程全部清除，没有停止开发栈。

证据：`local/evidence/native-archive-20261015-third/`、同级 `native-archive-20261015-third.jsonl`；包括 `inputs.json`、`fault.json`、`before-retry.json`、`usage.json`、`result.json`、`cleanup.json`。失败轮目录分别为 `native-archive-20261015-first`、`native-archive-20261015-second`。这不是 ENOSPC、PostgreSQL 重启、断电、外部工具未知效果、全平台资源上界或 Windows 进程/受管发布验收。

## 继续保留的交付范围

研究完成链路在这两个合成样本中得到最终结果，但稳定性、真实资料覆盖、库存变化解读与完整期货业务质量仍开放。先处理已有证据指出的质量问题；后续真实调用仍须小额有界，不能为了通过而反复重跑、删除限制或改写原文。

P2 服务/权限退役，P2.5 存储生命周期与长历史资源测量，P3 全页面，P4 其他故障与全平台资源，P5 真实采集—核验—入库—成稿—引用回读均继续按完整计划推进。Windows 受管启停/独立升级回滚、DPAPI、原库最新备份与实际恢复、Windows 双 Worker 等仍是目标环境专项待复验，不由 Mac 结果代替，也不是连接原电脑的授权。最终统一 CI 尚未执行；本轮没有 push 或触发 GitHub Actions。
