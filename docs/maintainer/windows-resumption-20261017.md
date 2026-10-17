# Windows 接回与交付续做（2026-10-17）

用户要求接回朋友 Mac 上未推送的成果，在原 Windows 继续完整单机目标，并及时更新 GitHub。本文件更新执行顺序与环境归属，不重新定义或缩小 P0–P5、P2.5 和 W01–W14。

当前开发根为 `D:\workspace\agent-platform`，集成仓为 `repos\agent-os`。Mac 是本次恢复来源；它的通过记录不能代替 Windows 安装、浏览器、DPAPI 或备份恢复验收。旧 `D:\workspace\agent-os` 仍只作迁移提示。Goal 卡片的旧文字属于历史目标，当前路径和用户后续约束以这里和 [objective.md](objective.md) 为准。

## 已接回并保全

- 15 个仓库均保存完整 Git bundle、HEAD、分支、前后状态及暂存/未暂存差异；Mac 采集时均为干净工作区，采集前后 HEAD 与状态相同。
- 6 个仓库有合计 29 个新提交；全部从 Windows 基线快进，无分叉、无覆盖用户修改。保留 `recovery/windows-before-mac-20261017` 和 `recovery/macos-20261017` 本地引用。
- 压缩包 128,205,385 字节，SHA-256 为 `596f4209c110dbfd6c0a6742b872227b5f99d4919e6f4f41ff2957084c135697`。两端校验一致；本机安全解包 2,189 个文件，没有路径越界或特殊条目跳过。
- 项目相关会话、测试及安装证据已接回受保护的 `local\recovery`；它们可能包含私有内容，不能提交。私有恢复入口为 `ops\mac-recovery.path`。没有复制整个 Codex 账号、登录凭证或无关会话。
- 6 个新增提交范围通过 gitleaks 扫描；已推送原开发分支与 `codex/macos-research-quality`，并将各仓 `main` 按祖先关系快进，经 GitHub API 核对提交号。没有强制覆盖历史，Actions 保持关闭。源码恢复不是部署完成。
- 传输结束后已删除 Mac 上本次增加的临时公钥，确认原密钥登录被拒，再删除本机对应私钥；Mac 原始仓库和导出备份保留。

| 仓库 | 新提交数 | 接回 HEAD |
| --- | ---: | --- |
| agent-os | 11 | `5465cc2eb9132d73e3bad9fc055dd8199a2539b2` |
| agent-os-console | 3 | `8e8186c07467897410f5a94973c7c4d36d99490e` |
| agent-os-futures | 5 | `f5e7bd21b8f3fcf20bc69c84aee2eede7bf5d2c4` |
| agent-os-runtime | 8 | `dbf99dca784c849f0386da1c3de219aa10142a8e` |
| agent-os-telemetry | 1 | `6f9f539125431bebbf88ddbdbb6840f3dd426068` |
| agent-os-worker | 1 | `94d605910e0c3da011bb1213b516150ecb5fe1ba` |

其余 9 仓与 Windows 基线相同。完整清单见 [本次源码恢复清单](windows-source-recovery-20261017.json)。Worker 仍固定 execution `v0.1.0-rc.5.0.20261015080014-1f6c4c29c62b`；恢复 Runtime 最新 HEAD 不等于自动改变 Worker 编译依赖。

## 补上 Mac 最后一轮尚未入文档的安装事实

最后已提交的 [接续动作记录](macos-continuation-action-20261015.md) 写的是“尚未部署”。其后会话与 `macos-continuation-install-20261015` 证据记录了实际迁移和安装：

- 2026-10-15 10:00:41Z：Runtime 迁移提交；14 张旧业务表、序列和原权限比较不变，新接续回执表为空。迁移前后文件哈希已在接回后重新核对。
- 10:04:26Z：Mac Runtime 安装 `dbf99dc`；10:19:46Z：Console 安装 `8e8186c` 的匹配 BFF/Web 包。
- 10:19:58Z 最后观察记录十个服务、八个非目标实例不变、旧数据与接续回执保留；该轮模型调用和任务提交为 0，`browser_verified=false`。
- 最后观察文件 SHA-256 为 `d5ae0b53a9835fd8c309aa3796f3211d2a19377cbf9ddb72e17ca2ae534a5bbb`。这是已接回原始证据的复核，不是今天重新运行 Mac 数据库/服务验收；也不证明重启后仍在运行。

原测试 JSONL 重新统计：接续 focused 19 顶层/42 子项通过、零 skip；广泛 Runtime 112/195 通过、27 显式 skip；独立 Worker 1/3 通过、零 skip。保留合成模型、内存归档、非完整浏览器及真实供应商两次 503 的限制。

## 下一段执行顺序与完成条件

| 顺序 | 工作及 Owner | 必须交出的结果 |
| --- | --- | --- |
| R0 | 接回与发布：集成及六个变更仓 | 源码/证据保全、密钥扫描、远端 SHA 核对；正在记录收尾，不重做已完成测试 |
| R1 | Windows 接续交付：Worker → Runtime → Console，另升级 Futures | 定向本机测试；核对固定版本与受管发布能力；最新备份及隔离恢复；迁移前后旧数据/权限核对；只更新目标服务；真实浏览器覆盖点击、丢回复核对、切换任务及窄屏。不能直接运行 Mac 安装脚本 |
| R2 | 一次完整业务验收：Futures、业务方法、知识库资料 | 固定豆粕供给/库存四问、分类日期及已有真实原文；先离线审查缺陷，再做一次有界真实 DeepSeek 任务；最终稿/最后检查稿一致、引用可回读、统计期/样本/性质正确、逐问反馈。供应商失败保留证据，不能连续盲重跑 |
| R3 | 既定平台收尾：各服务及 Harness | 按 backlog 关闭旧实现/权限退役、存储生命周期、尚缺故障和整机连续任务资源测量、其余页面。每项复用已成立证据，只补缺口；不能为了通过而删除原验收项 |
| R4 | 最新状态恢复及一次统一 CI：集成 | 完整备份实际隔离恢复；固定源码/安装清单；一次有预算的集中 CI 和独立最终复核；结果足够才完成 Goal |

原完整待办见 [backlog.md](backlog.md)，验收矩阵见 [Windows 单机计划](../windows-single-machine-plan.md)。服务器 HA、最终百万文档/千万块及全品种覆盖仍为后续阶段；它们不阻塞当前 Windows 核心交付。

## 本机复测

2026-10-17：Console 36 项、Futures 23 项 Web 测试及研究配置 5 项测试通过，零 skip；两个 Web 的 TypeScript 和 Vite 构建通过。使用本机固定 Node 和已有依赖直接执行，没有调用 pnpm 隐式安装。真实浏览器与正式安装尚未由这些测试证明。

Windows Go 复测使用新建的隔离 PostgreSQL，测试后已停止。Runtime 定向 27 顶层/52 子项、Console 13/26、Futures 39/72、Worker 22/47、Telemetry 10/0 通过，五仓 vet/build 均成功。这轮没有开启 race；Runtime 覆盖接续动作、预览、规则修订、工作状态恢复及遥测投递。Worker 有 9 个需要显式 Harness 产物的测试事件跳过，Telemetry 真正 Langfuse 测试 1 项跳过；无测试文件的包不计入专项跳过数。Mac 新增的独立 Worker revision 测试仅编译于 Darwin/Linux，不能将 Windows 的选择性测试视作已执行该项，R1 需补目标环境验证。新增永久回执的 Windows 迁移/安装仍待完成。

重启后首次只读 status 显示服务均未启动、`core_ready=false`。随后用统一维护入口启动原有已安装版本和原 PostgreSQL，12 个服务实例恢复，status 为 `core_ready=true`；唯一提示是既有 Sandbox 隔离执行未配置。没有用 Mac 候选包替换 Windows 服务，没有重新初始化正式数据库。测试与接回过程没有迁移正式任务、凭证或发布 catalog；没有新增研究提交或 GitHub Actions。

独立评审 Agent 对 Runtime 接续事务/权限、Console 请求恢复和本次计划进行了只读静态检查，在该范围未发现阻断 Windows 安装的 P1/P2 问题；提出的旧环境文档入口歧义已修正。评审未运行测试、操作正式数据库或访问 Mac，不替代 R1 的部署与浏览器验收。

## R1 发布准备增量

接回后发现 Worker 的 go.mod/go.sum/vendor 已升级 execution 固定版本，但来源清单仍指向旧 rc.5。已修正来源元数据，并把 vendored Owner 的 11 个文件与 `1f6c4c29` 的 Git 对象逐一核对一致，没有再变更 Worker 执行依赖。Windows 构建选定的新来源为 Worker `03b1794`、Runtime `217f2ae`、Console `34094b1`、Futures `f5e7bd2`。

新增独立的接续管理发布能力，未更改历史引擎名或固定回放协议。受管启动、更新、回滚及未完成发布恢复都检查 Worker → Owner 迁移 → Runtime → Console 的组合。Runtime 启用新动作前，逐实例检查全部 Worker 的进程归属、配置、二进制、实际 current/pending 引用及规则守卫。任一永久接续回执（含拒绝）阻止降级到不能查询它的 Runtime；Runtime 停止后先排除同账号残留数据库连接，再重新读取回执，避免预检查之后晚提交被遗漏。旧完整组合仍保持兼容。

本机检查：接续发布 28 项通过，使用真实描述文件/catalog/操作前置检查及显式受控进程、数据库观测；另在新建隔离 PostgreSQL 上使用实际 Owner DDL 和非 Owner Runtime 账号，7 项检查通过，覆盖缺表、最小权限、已保留拒绝、撤权、错误表结构、存活/关闭的 Runtime 连接。原回执发布 41 项和来源锁检查也通过。数据库夹具已经停止，没有访问正式任务正文、迁移正式数据库或调用供应商。独立 Agent 复核修复后未发现新的 P1/P2 阻断；其为只读静态评审，不替代后续安装和浏览器验收。

上述是构建前准备；最新 Windows 包的构建、备份/隔离恢复、正式迁移、激活及页面实测仍须继续，不能由源码同步或本节测试推断已交付。Actions 继续禁用。
