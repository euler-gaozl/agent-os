# 运行回执分页与原文分段交付

本增量已部署到本机正式 Runtime 和 Console：源码分别为 `90e7e9c4721fe238d46da74711105ea1763ef65c` / `937aa6617744b50d0b860a9196911a8fa6110605`，集成构建为 `36fcd4a`，发布集为 `1e41f6f5f9d34caf82b52a97eb122f71`。默认仍 v1，双 Worker/Harness 未升级。本轮完成索引迁移、真实独立升级/回退和已有真实供应商任务的只读 Web/BFF/Runtime/PostgreSQL 验收；没有新增付费模型请求或 GitHub Actions。完整 Goal 保持 active。

## 改动及依据

上一轮 99 请求任务的旧 `/calls` 响应达到 1,220,788 字节。运行详情以前同时加载所有请求和响应，工作状态回查也依赖那份全集。Runtime 新增独立管理投影：按 `(created_at,id)` 倒序 seek 分页，默认 25 条、最多 50 条，只有摘要；`unresolved` 独立筛选 `unknown/inflight`，不因历史分页漏掉待核对调用。两个有序索引由 Runtime 自有迁移负责。

单条回执按输入、输出、错误三个字段读取，默认 8,192、最多 16,384 个 Unicode 字符。续段必须携带首次读到的内容版本，内容变动返回 409；SQL NULL 与保存的 JSON null 区分。浏览器只保留当前页、当前段，关闭、换字段、翻页后迟到响应不能覆盖当前视图。来源编号可以直接读取当前列表页以外的回执。新版 resident-v2 也显示工作状态与归档清单。

分段版本用于保证 PostgreSQL 存储文本的一致性；它不是工作状态中的规范 JSON 内容哈希，也不是供应商原始报文摘要。数据库仍需转换和散列单个字段，未声称数据库有固定内存上限。旧执行回放/Worker 模块及全量历史 API 保留原语义；新 Web 不退回全量 API。

## 本地证据

均位于 `D:\workspace\agent-platform\local\evidence`。

| 证据目录 | 实际范围与结果 |
| --- | --- |
| `call-reads-3f565d3b33f045b38d3881b137d5452c` | 真实受限隔离 PostgreSQL，22 个测试/子测试记录、零跳过，vet/构建通过；并列时间游标、跨任务拒绝、后页待核对、Unicode 重组、409、空值、角色隔离、索引与相关迁移/笔记/工作状态回归 |
| `receipt-console-1a3f9e8ce0794404971f5d3de4873057` | 真正候选 BFF/Web + 合成 Runtime；Go 检查、9 个 Web 测试及构建；桌面/390px、25/25/13 分页、后页未知调用独立核对、来源原文、8192 字符分段、409 后重读、输入输出切换、读取/核对关闭竞态；10 次正文读取、旧全量调用 0 次 |
| `receipt-release-7169e5aead5b4ae5b6cde1338a85e609` | 41 项能力/配置与发布前检查，真实描述符文件/校验/导出还原；不兼容升级或回退在 pending/停服务前拒绝；配置漂移和不同目标 Runtime 拒绝；使用惰性文件资产，未启动服务或修改数据库 |
| `source-runtime-configuration-4542950133b849e59c2b6af37d97c8d3` | 12 项真实 Windows 合成进程配置漂移检查；补充假报 source hash 仍不能隐藏有效 LISTEN 不同；原有默认引擎/待恢复发布语义保留，夹具进程全部清理 |

首轮 PostgreSQL substring 重载的参数类型错误保留在 `call-reads-e4d6dc23902d4c33aa689d308101f477`，显式 integer 类型后复测通过。首轮 UI 夹具因非默认端口拒绝 DEV_LOCAL，改用独立合成管理令牌后验收。发布校验的 PowerShell 布尔优先级、数组类型及单元素管道拆包问题在验收/独立评审中发现并修复，失败记录保留，不计通过。

浏览器最后两处空文本/空页文案修正后重建、重载核验，最终文件哈希见 `final-source-hashes.json`。浏览器证据明确是合成资料，不是新的期货研究结论或真实 Runtime 数据库端到端结果。正式运行的 Runtime/Console 配置、已绑定进程身份和目标匹配另做只读验证，未显示或保存秘密值。

## 发布与后续

Owner 声明 `receipt_management`：Runtime `provides`，Console `requires`，固定协议 `call-receipts-v1`。Windows 完整发布包携带该声明；目标 URL 必须是不含末尾斜杠的有效本机 base URL，避免拼接路径触发被客户端拒绝的重定向。启动、更新、回退、未完成发布恢复在停服务前校验目标组合；对新 Console 还核对配置哈希、当前或待发布版本、受保护 launch 与有效 Runtime URL。本地 catalog 只证明其对应本机 Runtime，不为任意远程地址背书。旧 descriptor 与没有 Console 的独立 Runtime 仍允许。

发布顺序为 Runtime 先、Console 后；回退顺序相反。源码、固定锁、正式迁移与实际升级已完成，证据如下。Linux 发布能力传播和远程目标证明仍需后续验收，不能从这些 Windows 策略测试推导。

## 正式单机验收

更新前备份 `local/backups/pre-bounded-receipts-20261013` 在独立集群还原：44 个关系的内容、schema、ACL/元数据和角色登录核对通过，两个保留的 Worker 包通过恢复检查，临时集群已停止。报告为 `local/restore-checks/11bd86a03b5e4d60b3c9b8714dcf9c50/result.json`。备份包括先前完成的 resident-v2 真供应商验收任务。

本次维护脚本归 `ops/Migrate-BoundedReceipts.ps1`、`receipt-migration-validation.ps1` 与 `Verify-ReceiptMigration.ps1`。写入前绑定受保护备份摘要、配置字节、catalog、实际本机 PostgreSQL 进程/数据库身份、执行域的备份指纹，保存迁移前全库指纹和索引、源版本、二进制哈希与执行阶段。仅允许固定本机连接与明确的 `public` schema，拒绝覆盖目标的 query；迁移 DSN 按检查过的字段重建并排除 PG 环境变量干扰。结果未知或后验不符时保持写服务停机；已有只读复核入口。该中断复核入口完成静态评审，**本轮没有注入迁移提交中断故障**。

首次备份被尚存的测试 Node 阻止，清理经身份核对的两个夹具进程后完成。首次迁移入口误拒绝 Runtime 合法的 `search_path=public`；第二次把 ToolHub 在另一个 schema 内的验活审计变化当作执行域变化。两次均在 DDL 前失败并恢复 12 进程的认证就绪，分别保留 `receipt-migration-ece274abe46c45f288d6c3d5289a995f` / `receipt-migration-5a6048876d934fffbed83d25eb45fff6`。最终备份绑定比较 `public` 执行域（排除心跳表），停机后的即时迁移前后仍比较**所有 schema 的全部 44 个关系**，没有放宽迁移后数据不变条件。

| 正式证据（`local/evidence` 下） | 结果 |
| --- | --- |
| `receipt-migration-32344230d6c945e38269739f52a246a4` | 固定 Runtime owner 迁移只增加 `calls_run_page`、`calls_unresolved_page`；44 关系内容不变、既有索引不变、任务计数不变，原 12 进程恢复并逐角色认证 ready |
| `receipt-live-release-d9f36d6590b548e5ad9390dd607c68ce` | 6 次单服务发布实际通过：Runtime→Console 升级、Console→Runtime 回退、再升级；每次验证目标 ready 与非目标 PID/启动身份不变。错误顺序的 Console 升级、Runtime 回退在停机和写 pending 前拒绝，原 catalog 字节不变 |
| `receipt-live-read-bb58e0b5493942a8bf162cc5c806a9d3` | 正式 Console BFF→Runtime→原数据库，12 个只读 HTTP 请求；按每页 2 条遍历 8 个历史调用，4 页分别 709/684/713/511 字节；17,106 字符输入分 5 段重组、984 字符输出和空错误字段与数据库文本哈希一致；执行域持久数据不变，未调用旧全量 API |

发布报告的 `prior_tasks_unchanged` 仅指任务计数和工作状态结构可用性；不能单凭它宣称全部任务内容逐字节未变。表内容指纹由迁移前后及只读回读阶段分别核验，证据范围不混用。

浏览器对同一 resident-v2 任务实际验证工作状态、按来源编号回读 507 字符原文、17,106 字符输入的 8,192/8,192/722 三段与末段禁用；再打开旧 source-v1 任务，其工作状态仍可见。截图与浏览器检查保存在最后一个目录。这里的模型任务曾调用真实 DeepSeek，但原文明确是**合成验收资料，非市场事实**，本轮没有再次运行 Agent，也不是 P5 真实研究验收。

正式安装引用为 Runtime `runtime-38308cf4e81a4f318eeaa8a266c950e7`、Console `control-10aa08d6fc074483bf96dcba2afcc5c8`。全平台 doctor 核心探测通过，Sandbox 隔离代码执行仍未配置，不能把 API 存活表述为沙箱执行可用。独立代理静态审查并核对证据，修复事项留痕，没有代跑测试。

更新后的完整备份为 `local/backups/bounded-receipts-live-20261013`；隔离恢复报告 `local/restore-checks/717863cfd2dc41cead4c8c2ff8d82b73/result.json` 已通过并停止临时集群，覆盖本次正式版本的发布包、配置和 44 个关系。最终 doctor 核心检查通过；此备份包含新版能力声明，不能用更新前恢复结果代替它。

之后继续取消/失败时资源与保留文件生命周期测量、旧实现与权限退役、其余页面和故障场景、真实期货采集—核验—入库—报告引用回读。当前增量不是 P2.5/P3/P4/P5 全部完成。
