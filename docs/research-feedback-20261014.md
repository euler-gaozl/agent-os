# 任务内研究检查与 MCP 配置维护

完整单机目标仍 active；P5 未通过。本增量为真实报告暴露的字段/比较问题
增加任务内反馈，不把校验器或任务完成状态当成研究事实正确的证明。

## 业务边界

Futures `86a5ac4` 提供固定工具 `check_research_draft_v2`，入口
`POST /mcp/research`。它只接收草稿和调用者给定的分类日期，没有 run_id、
URL、数据库、模型请求或出站读取。结果包含草稿哈希、检查器版本、需修订
与需原文核对两类问题，UTF-8 JSON 限制 8 KiB；超限保留总数和截断标志。
输入最大 96 KiB 草稿，传输 envelope 最大 512 KiB，并发最多 2。

MCP 独立服务鉴权只允许 Futures 身份；业务用户令牌、DEV_LOCAL、静态资源
白名单均不能访问。凭证由 Registry 命名保存，ToolHub 探测、固定版本后
绑定新 Agent；旧任务不换配置。通用 Runtime 不增加期货规则或决策循环。
草稿检查不能证明 as_of 与任务固定日期相同、引用确实读过、来源可靠或
覆盖完整；最终报告仍通过本任务不可变阅读回执核对。两轮修订是 Agent
指令，不是硬性工具次数限制；执行仍受已有步骤/模型预算限制。

新增 ratio 与 commitment，区分比率、产能、未执行合同和实物库存；百分比
相减显示百分点。先反馈比较口径、性质和期间冲突，再处理引用限制，避免
错误被有限句式匹配失败掩盖。指标/样本不应夹带统计月份；问题文字不应
夹带没有事实引用的报数，计划表述也不能把预估改称计划。规则仍是有限检查，
不能覆盖所有中文数量、语义、时间解释或正文关联错误，不能要求改原文或
删除关键资料以获得通过。旧原始报告不改写。

## 配置维护

Runtime/ToolHub 已登记配置含精确 MCP 私网 host:port 白名单，新工具不能
通过手改文件或取消配置哈希门禁接入。`scripts/Set-MCPHosts.ps1` 复用全局
维护锁和服务 pending journal；仅变更 `MCP_ALLOWED_HOSTS`，不更换代码。
原/新配置由当前 Windows 用户的 DPAPI 加密保存；只在新进程就绪后提交。
失败恢复原配置，提交后不倒退；`Platform.ps1 release-recover -Service ...`
可以处理未完成配置事务。与代码回退兼容的前版配置绑定同时更新。

维护前需停止所有登记布局中的 Console、Futures 和 Worker，确认执行域
无 queued/running/waiting_children；operator 还须排除未受管直接 API 写入，
与现有备份维护窗口一致。仅接受本机 PostgreSQL 的明确身份及
sslmode/search_path 参数，拒绝 query 中的主机/数据库覆盖。比较真实目标
launch 与源配置（唯一允许额外的派生键 INSTANCE_ID）；恢复允许 journal
里的 prior/target，拒绝未知版本。未知磁盘配置不覆盖。恢复同样检查停写。

示例维护入口（先停止任务生产者，空闲检查通过后逐服务执行）：

```powershell
./scripts/Set-MCPHosts.ps1 -Service toolhub -Hosts '127.0.0.1:8101','127.0.0.1:8098'
./scripts/Set-MCPHosts.ps1 -Service runtime -Hosts '127.0.0.1:8101','127.0.0.1:8098'
```

## 本机候选验证

- Futures：53 条 Go 测试记录通过，测试零跳过；另两个包没有测试。
  Go vet、两个原生程序构建、10 项 Web 测试和 TS/Vite 构建通过。
  覆盖服务鉴权、无出站访问、请求/回包上限、重复字段与非法参数、失配类型、
  比较以及未伪造留存引用；包含超长 ID 放大和“一手资料/万吨单位”误报回归。
- `mcp-config-9264631f8ee5493db5f14e04378b8983`：41 项通过；真实 Windows
  合成 HTTP 进程、DPAPI、隔离 PostgreSQL 和子进程退出验证准备/替换配置/
  启动/提交/恢复中断，覆盖启动失败自动回退、未知配置拒绝、同/跨布局入口
  拒绝、query 数据库覆盖、源配置缺键以及恢复时 launch 漂移。测试生命周期
  使用独立临时端口，登记目录枚举注入隔离测试目录，不改正式目录注册表；
  不是正式入口部署成功的替代证据。合成进程及隔离数据库已停止。
- `source-runtime-configuration-a089de564eac41c98daa24cc05e2a0f6`：已有
  Runtime/Worker 配置绑定 12 项实际进程回归通过。
- 前两次测试因夹具 DSN 缺 search_path、清理脚本空数组处理失败而失败，
  已记录并修正；确认原测试 PG 后停止，再运行成功结果，不覆盖失败证据。

此处只记录已完成候选验证；正式发布、MCP 验活、新 Agent 调用及新报告
质量应追加实际证据。零 Actions。P2 退役、P2.5 剩余生命周期/测量、P3
其他页面、P4 剩余故障和最终一次统一 CI 仍待完成。
