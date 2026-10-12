# Windows 单机规划与 DSH 源码方案独立评审记录

日期：2026-10-12。评审者为本聊天独立评估 agent `architecture_reviewer`。以下为其报告的整理；评审只读源码/文档，没有修改代码、读取凭证或运行测试。主 agent 的运行验证另列，不冒充评审者验证。

## 单机规划评审

结论：方向合理，可以进入 P0；正式迁移前需补两处关卡。

1. 现有备份只读一个 DATABASE_URL，不能保证覆盖分离的服务数据库或恢复 Registry 加密凭证所需的 MASTER_KEY。P0 需完整恢复清单、受保护配置/密钥、固定构建及多库一致性窗口；隔离恢复禁止真实外部写入。
2. 分别记录服务交付与实际扩展可用性。12 个服务都要有独立源码/构建/发布，Sandbox HTTP 存活不证明隔离执行，Telemetry 存活不证明 Langfuse 导出。
3. 本机核心检索可使用现有 PostgreSQL Engine=local，不能把未装 Docker 当整个资料工作流阻塞，也不能静默把语义检索失败降级后称原引擎成功。
4. 真实研究验收要固定品种、时间和问题，核对原始来源、统计口径、单位、冲突及引用回读，不以模型接口调用成功代替业务结果。
5. Windows 故障注入要写清实际动作、旧 fence、孤儿 Node/Harness 和回执检查，不以 Linux SIGKILL 结果替代本机动作。

上述意见已纳入 `windows-single-machine-plan.md`。完整恢复集合的实现与恢复演练仍待 P0/P1 执行。

## DSH 评审

结论：纳管固定上游源码，采用自有插件和必要的窄补丁；现有接口足以实现多数持久化和 Compact 策略，同一 Session 的有界内存/快速恢复才涉及更深修改。

本地 rc.2 证据：Session 使用内存 log，seq=log.length，恢复种子从 0 连续；AgentLoop.resume 全量读取日志并补 interruptedTurnClosers。已有 tool/call 没有 tool/result 时会补 TOOL_OUTCOME_UNKNOWN。因此不能直接 native resume：Runtime 若已提交成功回执，必须先协调该权威结果，避免已知成功被错误转成未知。

SessionPersistence、session/flush、session-checkpoint-policy 是正式扩展点。插件后端至少需要：Session/序号/内容校验、有界缓冲、lease/fence、持久化水位、失败时阻止后续效果、先核对 Runtime 回执的恢复协议。当前桥接从 exchange 1 重放，直接挂上原生 Session 后端会涉及同名 create、随机事件 ID/时间、重复归档等冲突；必须新 engine/protocol，保留旧任务行为。

真正逐块保存供应商响应还涉及 Go 模型传输和 bridge，单改 DSH 持久化插件不能解决。原始事件内存释放需要审查 Session、SurfaceManager、工具历史、Projection 和 AgentLoop；不能用 log.splice 破坏序号/引用，也不能把投影快照冒充完整执行检查点。

Harness 是 Worker 的版本化运行依赖，不增加一个后端服务。来源纳管要记录上游 commit、发布包 integrity、补丁、锁和 engine，保留许可证，不得未经核实就把 master 当成 rc.2。

主 agent 另外实际运行了三项固定包特征测试：flush 等待、flush 失败传播、投影替换保留原事件。三项通过，没有付费请求，没有替代原生持久化、内存压力或故障恢复验收。

## P0 备份恢复实现复审

同一独立评审者只读检查新 PowerShell 脚本，确认三项问题：手动 createdb 加普通 pg_restore 遗漏数据库级 owner/ACL/settings；逐库前后指纹不足以证明共同停写基线；隔离集群停止失败仍可能返回 passed。修订后再复核，确认改用 `--create` 并核对数据库/DDL 权限；加入共同管理锁和所有库最终复核；清理失败改为 `cleanup_failed` 和非零退出，未发现新的阻断。

评审者先前关于双反斜杠路径判断的意见源于误读工具 JSON 转义，检查原始字符后主动撤回。它不是实际缺陷，不能计为修复。评审者没有访问真实配置、执行数据库操作或代跑验证。

主 agent 随后独立完成真实停写备份、全新集群恢复、43 个关系的内容及权限核对、10 个角色登录、2 个加密凭证解密、离线 Harness 重建及原服务重新启动。实际记录和边界见 `../windows-single-machine-plan.md` 的 P0 验收。管理锁不覆盖手工直连，DPAPI 依赖同一用户配置文件；离线接口测试不替代 Worker 恢复链路。
