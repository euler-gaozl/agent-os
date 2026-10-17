# Mac Console 原生引擎面板与工作状态恢复边界（2026-10-15）

环境：维护者独立 macOS 15.3（24D2059）/arm64、Go 1.27.2、Node 24.19.0、PostgreSQL 18.6。延续[前次笔记与未知效果记录](macos-native-notes-and-unknown-20261015.md)，原 Windows 历史及完整目标保持。

## Console 的实际修复

Console 旧判定仅识别固定 state-v1/resident-v2，遗漏 Runtime 已支持的 budget-v3/native-v4，导致工作状态/修订面板隐藏、归档下载文案错误。本轮精确补齐四个固定引擎，不按前缀接受未来协议；evidence-v1 仍只提供清单，历史与未知引擎保留原分支。RunEvidence 组件由实际 Console 页面使用，下载参数与任务/产物绑定、异常提示和面板刷新重置行为保留。

作者将旧判定代回新回归测试，得到 3 fail/2 pass；修正后定向 7 pass/0 skip。根代理全 Web 27 pass、0 fail/skip，TypeScript exit 0。初次 pnpm build 因外部 node_modules 符号链接保护失败，原日志保留；同一锁定依赖的直接 TypeScript/Vite 构建通过，Vite 的 use-client 警告如实保留。新回归是 SSR 初始渲染与直接下载回调检查，waiting_unknown 仅确认尚未取得许可时不显示执行按钮，不是实际 DOM/fetch 交互或浏览器点击验收。

既有 WorkingStatePanel 读取/历史/预览/显式恢复和迟到响应处理未改。source-state 受限恢复依然由 Runtime allowed 预览与 POST 锁内重检决定；failed 的通用 /resume 是另一个入口。本轮没有实现自动接续或证明失败研究能够继续成稿。

## Runtime Owner 的恢复证据

Runtime 新增 `runtime/source_state_native_recovery_test.go`，受测 SHA-256 `cfc3899decd622b0b74d85efc2dfc0e8c3a1878a07af19fc74dd3438f9091c0e`。3 个顶层测试及 4 个子场景实际通过、0 fail/skip，`-race -json -count=1 -timeout=120s`，包结构化 elapsed 2.427 秒、exit 0；控制台文本 2.426 秒是同次输出表示差异。

测试采用正常 native Submit/Claim、合成模型/笔记和真实 SourceState HTTP，丢弃已提交处理器的三次成功回调返回，再按 Worker 的不确定错误分类调用 CheckpointFailure 到达 waiting_unknown；没有 SQL 改写运行状态。read/update 分别验证 control 预览和显式恢复、约束修订后旧冻结回执与新 stale 视图的区分、新 Claim 的 fence 递增、旧 owner 拒绝与无重复回调/账本变化的重放。预览后实际取消、inflight 模型以及 Worker/ToolHub/Futures/Knowledge 身份均按正式 API 拒绝恢复。

这层是进程内 Owner、真实隔离 PG 和 HTTP 权限协议，NOLOGIN/SET ROLE 应用池、合成回执、每任务独立内存 archive；不是实际 TCP 断连、Worker 重试实现或官方 DSH/Node/Storage 联调。归档丢确认自然进入 failed/not_waiting，不等价于已独立覆盖 archive_unconfirmed 分支；未知外部工具效果也不是本次新样本。

## 本机完整包和证据

Console 源码提交 `58c511f3f2a29ca5a99a121e2197e74e5272ac90`；包含修复、测试和 README 五文件。Runtime `606fbc8a0e785d013f39e2cadcfca2fb1fb268f3` 只归档新测试和 README，受测源码摘要一致；生产 Runtime 与已安装版本未替换。

完整 BFF/Web 包 `20261015-console-native` 从明确提交的干净源码构建，manifest SHA-256 为 `3a95458362ff8145e36b4a3a63e03027f3b8703fbc1946265c11e9539d56798a`。首次安装在 SIGTERM 后读取进程身份报 `process-ownership-mismatch`，脚本未继续等待消失，保存 failed/rollback-incomplete，不能称自动回滚成功。随后显式核对原 PID 6011 已不存在、端口空闲，按原配置/二进制恢复旧版 control 为 PID 24104，并确认鉴权就绪、九个非目标实例及所观察任务 ID/状态集合不变。停止确认改为有界等待消失后，用独立 attempt2 完成安装；首轮记录没有覆盖。首轮没有记录确定的中间进程状态。

第二次安装 UTC `2026-10-15T06:33:13.746Z` 成功，control PID 24265，鉴权就绪 HTTP 200。BFF/Web 源码一致，binary/Web tree SHA 由 prepare 和完整包 manifest 核对；九个非目标实例与观察到的终态任务集合不变，未向已安装开发栈提交任务。它是独立 Mac 开发包更新，不是 Windows 受管发布或浏览器验收。

原始日志、静态与实际结果独审保存在 `local/evidence/macos-console-native-20261015/`。`root-test-verification.json` 只汇总测试，不把其中当时 pending 的安装描述改写为已验；安装、显式恢复和首轮失败分别以 `local/evidence/mac-bff-package-20261015-console-native{,-attempt2}/` 下的独立记录为准。`fixture-cleanup.json` 只读确认专用 PG 中 Runtime 夹具库/角色/连接均为 0；`after-fixtures-services.json` 证明 Owner 测试后原十实例不变，随后只有 control 更新。最终 `after-install-services.json` 核对十实例仍存活、九个非目标实例完整对象不变，配置仅 control.WEB_DIR 改变。独立的 `reviews/console-native-execution-independent-review.md` 核验代码/测试/准备包，`reviews/console-native-installation-delta-independent-review.md` 另核首轮失败、显式恢复和第二次安装；前者的“尚未安装”历史结论保持，不被后者覆盖。评审者只读现存证据，没有再次连接服务或 PG；停止检查另有 5 项隔离 VM 夹具验证，未发送真实信号。所有报告与摘要留在证据目录。

## 仍开放的范围

P0/P1/P2/P2.5/P3/P4/P5 与 W01–W14 全范围、既有状态和旧覆盖保留。当前增量不关闭完整 continuation、真实供应商恢复、研究质量、完整 UI、长历史 Compact、持续资源或全部生命周期。浏览器未执行，没有真实模型调用；就绪与组件测试不能代替页面验收。Windows DPAPI、受管发布和原库恢复继续待目标环境复验。部署 pins、固定 DSH、旧快照和 Worker 编译协议不变；未推送、未运行 Actions。
