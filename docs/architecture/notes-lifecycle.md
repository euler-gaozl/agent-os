# 持久化笔记的修订与撤回

2026-10-12 实现。验证状态以[交付账本](../delivery-v0.6.md)为准。这是 Runtime 执行域的长期笔记协议，Knowledge 原文、索引和 Storage 产物分别由原服务管理。

## 状态和来源

`documents` 保留不可变原文。新增 `note_versions` 把每个版本关联到根，`note_roots` 保存唯一当前版本及 active/retired/conflict 状态。到期根据当前版本 `valid_until` 计算，不依赖后台定时任务。搜索只返回全局共享或本 Agent 范围内尚未到期的 active 当前版本；新版本到期或被撤回不会让旧版重新出现。

修订创建后继，继承 kind/scope。撤回保留原文及版本，不允许隐式恢复。修订可更新到期时间，**省略 valid_until 会清除原到期时间**。文档回读增加 lifecycle 旁置字段，原文及分页不变；已提交的旧回执原样重放，不被最新状态改写。

历史分叉迁移为 conflict，不按时间选赢家。管理页可查各分支，但没有自动或人工合并入口；冲突不能修订/撤回，也不进入有效检索。旧 Knowledge 复制资料（knowledge: scope）仍可按 ID 回读，但不出现在工作记忆目录，不能在 Runtime 修订或撤回，应到 Knowledge 管理原资料。

## 写入与授权

- 旧 `note_save` schema 和描述保持不变。新 `note_revise`/`note_retire` 必须显式绑定 Agent。
- 两种新工具都要求 `expected_current_id` 和理由。修订标题最多 300 字符、正文 20000 字符、来源及理由各 2000 字符，metadata 最多 32 KiB；有效期须为 1970–9999 年 RFC3339。旧超长文档保持原样，但修订需符合新接口上限。
- 模型身份来自持久化 Agent 快照。只允许修改本 Agent 非全局笔记；全局资料只读，父任务对后代的回读权限不构成跨 Agent 写权限。
- 管理入口记录可信服务身份 control；当前单管理员部署没有独立的人类用户身份，不能把该审计称为实名审计。客户端不能自报 actor/scope。
- 所有 INSERT，包括旧管理 POST documents，均由 Runtime 专有触发器校验。同一根加锁，等待后在新语句中核对当前状态；只有一个并发修改能够成功。Knowledge 的独立库导入不依赖这些表或触发器。

效果、审计、回执同一事务。先查相同逻辑调用的已提交回执，再检查当前版本，避免丢回复重试被自己的修改拒绝。跨 fence 重放仍核对调用参数；旧 fence 不再能写。

模型遇到版本竞争时得到已完成的 `outcome: conflict, changed: false` 工具回执，可重新读取后另起逻辑操作。Runtime 通过事务 savepoint 回滚该次无效效果，再提交已知冲突回执，不把明确拒绝误记为 UNKNOWN。管理 API 的并发冲突则返回 HTTP 409。

`note_audits` 保存来源变更理由、服务/Agent 身份、run_id、operation_id/request_id。效果早于回执插入，故外键使用事务末检查；重复回执不重复审计。旧资料迁移不会伪造过去的修改原因；触发器遇到旧协议无身份/理由时明确记为未提供。

## 管理接口与界面

Console `/api/notes` 转发到 Runtime `/v1/notes`，仅 control 身份可调用：

| 接口 | 用途 |
| --- | --- |
| GET /notes?q=&state=&after= | 当前工作记忆目录，状态为 active/expired/retired/conflict |
| GET /notes/{id}/history?after= | 根下全部版本元数据，原文通过 documents/{id} 回读 |
| GET /notes/{id}/audit?after= | 修改记录与可信调用关联 |
| POST /notes/revise | request_id + 修订内容、预期当前 ID、理由 |
| POST /notes/retire | request_id + 预期当前 ID、理由 |

每页最多 25 条。目录和版本按不透明 ID 排序，修改记录按序号；都是实时分页，不承诺并发写入期间的一致快照或按时间完整排序。参数错误拒绝，分页游标有界。

管理写入的 request_id、参数摘要、响应与效果一起提交。同 ID 同参数返回原响应，同 ID 不同参数拒绝。Web 在发送前将待确认请求存到 sessionStorage；服务端成功但响应丢失时，关闭详情、重新打开和刷新页面后仍可用原请求重试。待确认期间冻结编辑内容，防止替换参数。**关闭浏览器标签或清理会话存储不在此恢复保证内**；服务器原文/回执不受影响，管理者可查询修改记录核对。该存储中有草稿正文，不包含服务凭证。

## 迁移、资源与边界

新增四表和两个索引，迁移按执行域运行，角色需要 note_audits_seq_seq 的序列权限。readiness 检查新表存在。恢复校验新增版本归属、当前版本及审计回执引用检查。

启用新写入前，必须升级所有 Runtime 读取实例、全部 Worker 及工具消费者。旧 Runtime 不认识 retired 状态，会错误检索撤回记录。镜像工具集合标签只能检查单次发布，不证明整个集群已更新；具体屏障见[部署契约](../independent-deployment.md)。

当前是有界分页的笔记管理查询，不把全表 ILIKE 宣称为千万块检索方案；大规模业务资料使用独立 Knowledge。不自动 GC 原文、审计、回执，不基于 Compact 丢弃长期事实。不提供已撤回记录恢复、历史分叉合并或跨域级联删除。本增量不引入通用事件溯源平台。
