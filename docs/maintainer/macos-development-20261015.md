# Mac 接手与首轮研究增量（2026-10-15）

本记录属于 `environment:maintainer-macos`，日期按 Asia/Shanghai；证据时间按文件自带时区保留（UTC或+08:00）。它不覆盖 [原 Windows 交接快照](current-state.md)，也不代表 P0–P5/P2.5 或 W01–W14 已全部完成。当前聊天已建立完整 Goal，保持进行中。

## 本机与源码

工作根为 `~/workspace/agent-platform`；首次检查时不存在，随后新建独立 repos/local/ops。Mac 为 macOS 15.3（24D2059）、arm64，Git 2.52.0、Apple clang 17.0.0。原 PATH 的 Node 25.3.0 保留；测试显式使用已存在的 Node 24.19.0 / pnpm 11.25.0。Go 1.27.2 的官方 darwin-arm64 压缩包通过官方 SHA-256 核对，解压到 local/toolchains。

15 仓均按 repositories.json 的开发分支取得，已有修改未被覆盖。主仓交接分支为 `f426218e61d42293395f73e26256f77421ac7bd8`；其余 14 仓的远端与 `source_head_at_audit` 一致。均在核对过的干净基线上建立 `codex/macos-research-quality`。完整分支、SHA 和集成固定版本见 [Mac 源码核对](macos-source-audit-20261015.json)。此清单是本轮开发起点，后续工作提交和补丁另行记录，不将各仓 HEAD 拼成部署组合。

Worker 的 Runtime execution 仍为 v0.1.0-rc.5 / 4ce5132；Indexer 的 Knowledge indexing 仍为 v0.1.0-rc.1 / e26584d。未更改 go.mod、锁文件、集成 pins 或任何历史引擎。Harness 上游固定 639ed015；核对342个源码文件，native-v4构建 manifest SHA-256 为 `d76588bae0edd1d7f13cdb4d01423ac8fc14da240fba682bcec4a1fb08f8ba7f`，与 Worker 编入的固定值一致。

PostgreSQL 18.6 官方源码经 SHA-256 核对后原生编译；独立测试集群位于 local/data/mac-test-postgres，仅监听本机127.0.0.1:55432，UTF8/C，TCP使用SCRAM，Unix socket位于受限本机目录。未注册全局自启；连接串与随机测试密码只在local/config，ops/mac-test-db-env.sh仅按需加载。临时表写读及事务回滚通过。此数据库没有原 Windows 数据或历史任务。

## 本轮实现

1. Futures 检查器 v4 修复推断年份被当成明确日期触发 future_actual 的误报，独立评审后本地提交为 `febd31569b66078995d54822c12552f5887cbeab`。推断日期仍标为来源待核、暂不归类且不可自动比较；明确未来实绩、非法日期和引文检查保持。原报告、引文和历史检查反馈不改写。合成回归实际先失败、修复后通过。
2. [研究成稿策略](../research-completion-plan-20261015.md)新增离线候选生成器；只从明确 Agent revision 生成待登记的新版本请求，保留原额度与精确绑定。12/12合成例为6轮取证、4轮成稿、2次Compact/重试余量；读取策略及Skill同步减少重复导航并保留问题证据索引。它是静态提示，不是动态剩余预算或执行器保证；原 Windows revision17/Skill6未导入，本机没有续跑原任务。

## 已执行验证及边界

| 检查 | 当前 Mac 实际结果 | 不证明的范围 |
| --- | --- | --- |
| Futures Go | 88项含子测试通过、0跳过；vet、独立构建通过 | 不代表真实来源或研究质量验收 |
| Futures Web | 13项通过、0跳过；TypeScript/Vite构建通过 | 未做全部真实页面交互；构建保留lucide-react use client告警 |
| Harness native-v4 | 17项合成协议测试通过、0跳过；官方源码哈希及固定manifest匹配 | 模型/持久化对端为夹具，非供应商业务证明 |
| 研究候选工具 | 固定Node24的5项测试通过、0跳过；合成CLI生成、拒绝覆盖、资源不变性通过 | 未登记真实Agent/Skill或执行研究任务 |
| Runtime核心协议 | 37个顶层测试、156条含子测试pass记录，race开启；0跳过/失败 | 定向Native/Budget/Source/WorkingState范围，非全平台全测 |
| Mac Worker/Runtime联调 | 新构建arm64 Worker、Node、Runtime HTTP、受限PG与TLS供应商夹具：大输出、完成后强杀、拒绝后强杀、Compact后强杀、取消、部分回复六场景通过 | 不是正式打包/搬迁发布，也不是Windows进程验收或真实供应商 |
| 供应商准备 | 独立提供的开发凭证已限制于仓库外；官方/models返回200和原生模型能力 | 本轮生成请求为0，无付费业务验收 |

Worker强杀场景由fence=2接管，已完成回执未重复执行。大输出归档27,001,260字节；拒绝/Compact场景各9次合成模型请求、1次摘要。供应商TLS、ToolHub路由和不可变Storage对端均为明确夹具；实际运行的是Mac Worker/Node、Runtime HTTP与受限PostgreSQL。这些是有限样本，不是Storage磁盘耐久、全平台资源上界或任意长任务承诺。

两位独立代理交叉评审：研究候选作者静态阅读Futures差异、日期/比较/历史反馈路径，未发现阻断问题；Futures作者静态核对候选工具与Runtime计数语义，另用Node25运行早期4项夹具。候选工具最终Node24的5项结果由实现代理执行，评审追加核对null字段兼容。独立审查不替代真实模型或业务验收。

本机证据保存在local/evidence下：macos-bootstrap-20261015、macos-toolchains-20261015、macos-research-quality-20261015、macos-research-completion-20261015-v2、macos-web-20261015、macos-harness-20261015、macos-runtime-native-20261015及macos-provider-metadata-20261015。早期失败/旧证据目录不覆盖。原始配置、数据、日志、密钥均不提交；文档只保留脱敏结论与版本映射。未push或启动GitHub Actions。

## 仍需推进

研究完成与质量两项仍开放：在当前Mac登记新固定资源，用新任务和公开/合成资料进行一次有界真实验证，记录完整usage、最终稿与最后送检draft哈希、四问题覆盖及未解决证据问题。没有原私有十份资料不能声称复现原任务。随后继续完整UI（W03/W04/W05/W13）、服务退役（P2/W02/W12）、存储生命周期（P2.5/W08/W09/W14）、剩余故障及全平台资源（P4/W07–W12/W14）。

Windows受管启停/发布回滚、DPAPI、原库最新备份及实际恢复、Windows双Worker等目标环境复验继续保留；当前未获连接原电脑授权，Mac结果不代替这些验收。最终一次统一CI仅在完整本机计划与预算关卡满足后执行。服务器HA、百万文档千万块全平台容量及全品种覆盖保留后续范围。
