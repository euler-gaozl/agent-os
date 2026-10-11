# v0.4：DSH 执行与 Agent 发布

日期：2026-10-11。本文替代 v0.3 中的自研循环和业务动作定义；未变更的服务、知识库和工具契约沿用 v0.3。历史架构与独立评审不改写。

## 分层

中台管理 Agent 和独立资源；一个 Agent 版本包含提示词、Skill、MCP、知识库、固定约束、模型配置及发布设置。期货 BFF 从最新 Agent 版本中筛选 `publication.enabled=true, app=futures` 的入口，直接提交该 Agent 的确定版本。业务端只显示名称、说明、任务参数和结果。

不再创建独立 action 资源。`publication` 包含 enabled、app、name、description；当前期货参数为品种、资料时间范围和研究问题，尚不是可配置的通用表单引擎。保存已开启发布的版本立即更新业务入口；关闭并保存撤下入口；过期或未发布版本不能创建新业务任务。已提交任务继续使用自己的快照。

## 执行所有权

| 层 | 唯一职责 |
| --- | --- |
| Go Runtime / Worker | 数据库领取、租约与 fencing、子任务队列、约束版本、取消、UNKNOWN 核对、回执与模型 HTTP 传输 |
| DSH 0.2.0-rc.2 / Node 24 | Agent 循环、模型消息投影、工具分派、会话与自动 Compact |
| ToolHub | 工具授权、参数检查、效果和调用回执；本地效果与回执同事务 |
| PostgreSQL | `runs` 任务状态、`harness_exchanges` 重放输入/响应、`calls/model_attempts` 外部调用账本、引用保护的 DSH 原事件产物 |

采用 DSH 官方核心包的公开编程接口；没有使用独立发布的旧版 SDK client，也不是启动全套 CLI 再暴露宿主 shell。适配层协议为本项目的 stdin/stdout 桥接协议。Go 的模型 HTTP 客户端保留，不再决定新任务下一步调用哪个模型或工具。默认所有新任务记录 engine=`dsh-0.2.0-rc.2`。

每个在执行任务拥有一个 Node 子进程，退出或失去 Worker 管道后结束。仅注册 Agent 快照允许的工具；模型密钥、服务 Token、数据库凭证不传入 Node。Node 自身不是恶意代码沙箱。子 Agent 仍是平台独立子任务，也由 DSH 执行；父任务落为 waiting_children 后释放 Worker，避免占满执行槽。

## 恢复协议

1. 每次 DSH 请求模型、工具或提交最终结果，都带连续序号和规范化参数哈希；先登记请求，再进行外部工作。
2. 选中的模型结果和工具回执落盘后才返回 DSH。工具 operation id 由 run id 和桥接序号确定。
3. 新 Worker 重新启动固定版本 DSH，重放已提交响应，构建会话与 Compact 后的视图；有记录的模型结果不重新请求，有完成回执的工具不重新执行。哈希不匹配停止，防止框架升级或适配修改造成错误重放。
4. 没有完成的模型请求可创建新 attempt，旧 attempt 标 abandoned；上游可能已经计费。外部工具的 inflight/unknown 按原账本核对，不盲目重试。
5. 当前用户约束在每次新请求中单独注入；旧计划未执行的工具会跳过并重新考虑。固定 Agent 约束保留在快照和运行约束中。最终结果提交也校验约束版本。

这是**持久化响应重放**，不是恢复 Node 堆或从供应商 token 中点续传。完整 DSH 事件流在后续外部工作前保存为内容哈希产物，最新引用位于 `state.harness_artifact`；Compact 不会删去这些原记录。摘要使用 DSH 的受支持 summarizer hook，保留来源、日期、单位、冲突、用户纠正与未完成工作。语义保真尚未经真实模型验证。

DSH 上下文预算使用 `context_tokens`，默认 32000，按 DSH 估算器触发压缩；旧 `context_bytes` 只用于历史 Go 执行。模型请求总数包含摘要请求；当前普通输出上限 4096 tokens，摘要 2048。供应商真实 tokenizer、推理输出预算和成本仍需实测。单条桥接消息最多 32 MiB；当前完整快照方式增加存储开销，未声称支持无限长任务。

## 数据与部署兼容

迁移 v4 在事务内把旧 action 的最新版本复制为 `published-<action id>` Agent：继承当时绑定的 Agent 版本，合并专用指令与约束，附带发布设置。原 action、Agent、历史任务和资料保留；重复迁移不生成重复版本。新环境能力包直接提供已发布 Agent。

旧 runs 标为 legacy-go，只有这些历史任务使用 `legacy_worker.go` 恢复；新任务不能通过接口选择旧执行器。升级 v0.3 到 v0.4 必须停止旧 Worker 后迁移，再启动新实例，不能混跑旧代码领取新任务。共享 schema、RBAC、费用预算和独立服务数据库所有权的限制仍存在。
