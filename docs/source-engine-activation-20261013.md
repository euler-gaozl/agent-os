# 源码执行器实际激活与恢复验收

2026-10-13。Windows 当前已启用源码构建的 DSH，默认新根任务为 `dsh-source-639ed015-state-v1`。Runtime `a916ab1`、Worker `70d45cd`、Console `1de4118` 使用此前已构建并完整校验的发布集 `8ff9cc8011e0400ca565a4c472839613`。运行 12 个实例，其中两个 Worker；独立期货入口仍为 8098，中台为 8090。历史任务保留原引擎，不自动重写。

本次是源码执行器的实际单机激活验收，不是完整 Goal、全部 UI、真实期货研究或生产容量交付。所有原始报告、备份和截图在 `D:\workspace\agent-platform\local`，以下相对路径从该目录起算。维护代码提交为 `dff13ed`；Actions 保持禁用。

## 数据与发布

迁移前备份 `backups/pre-source-engine-20261013` 已实际恢复到全新 PostgreSQL 实例。报告 `restore-checks/48df995b874849da9a69386bcfc50e48/result.json`：43 个表/序列的内容、结构和权限一致，10 个账号登录、2 个加密凭证解密、25 个发布引用与 3,002 个文件核验通过，隔离库已停止。

Owner 的固定源码独立编译出 `runtime-migrate.exe`，使用受保护管理员连接仅执行追加迁移。正式数据库的原 43 个关系内容哈希均未改变，新增一张空的 `run_working_states`，Runtime 应用账号结构/权限检查通过。证据根为 `evidence/source-engine-activation-6485a2de87d948e4bd2d80d175599750`。首次迁移后的核验脚本把返回数组再次包了一层，导致错误报“找不到关系”；迁移本身已提交。保留 `migration-result.json` 和日志，修正辅助脚本后只读核对备份基线，得到 `migration-verification.json`，没有重复迁移、回滚数据或清库。

真实发布验证共 13 次成功操作：

| 证据目录（`evidence/` 下） | 实际行为 |
| --- | --- |
| `execution-owner-releases-5d66a48553ad497b94fed21c6b9c4fd9` | Runtime、双 Worker 分别 update → rollback → update，共六次；14 个执行/笔记/工作状态表内容和旧运行/笔记 HTTP 回读一致，非目标进程不变。实例心跳表按设计变化 |
| `web-owner-releases-188e3c9ec0cb4b30b563ded13994157f` | Console update → rollback → update，共三次；旧 API 内容、四个所选 Web 文件字节、数据和非目标进程核验通过；本项不是浏览器交互测试 |
| `execution-owner-releases-ba4872d0c54f47b2b41a4df2522ea3b0` | 源码默认值切回历史值后，先回退 Worker，再回退 Runtime，验证配置哈希迁移没有破坏旧程序启动 |
| `execution-owner-releases-972ebd4e875149a9b9cd2f2169236cd4` | 再依次升级 Runtime 和 Worker，保持上述数据/进程检查，随后恢复源码默认值 |

辅助脚本最初误用“先 Runtime 后 Worker”的回退次序，被源码 Worker 兼容守卫拒绝，零发布动作，失败报告 `execution-owner-releases-0f390db095e745249beafc902841ba50` 保留。正确顺序是先降 Worker 后降 Runtime；升级反向。现在正式库已经保留源码任务，即使切回历史默认值，也不能再回退到不理解这些记录的旧 Runtime。

配置实际执行 source → historical → source 三次事务，均验证当前 Runtime 与两个 Worker 的配置/依赖/身份、就绪状态及其他进程不变。最终操作 `e0ee9c0775d74cc5a46676ece4d7e357`；当前无 pending。前序 48 项合成故障检查及加密恢复机制见[配置事务记录](source-engine-release-20261013.md)。

## 真实模型与页面

验收使用显式标注为合成样本的知识库，连接官方 DeepSeek `deepseek-flash`。未把测试库存数字当作市场资料。成功任务 `24c93e8413c9c83c5875625fcf22926b` 完成检索、原文读取、带该任务真实回执引用的工作状态写入、笔记保存与最终回答；随后通过中台 API 核对历史工作状态版本和笔记原文。五次真实模型请求共报告 20,679 tokens，未知用量为零；报告为 `evidence/source-execution-live-735adfcf-5ac7-42b9-b7da-9430aeac5dbb/result.json`。

首次任务并未完成：32,000 总预算在第五次模型请求前触发保守预留守卫；此前四次实际用量 14,663 tokens、工作状态和笔记均已保存，失败后测试脚本取消该任务。请求预算按 UTF-8 请求字节及输出上限预留，不能把本次拦截解释为已经消费 32,000 tokens，也不是未知模型效果。失败报告及部分回执在 `source-execution-live-193c8d96-d2e6-4900-94e5-ce55c0276d02`。新建的第二个验收任务设 64,000 总预算、最多八次请求，原预算守卫不变；不是重写旧任务快照或无限重试。两次合计九次真实请求、35,342 tokens。供应商余额接口显示均为 49.89 元；显示未变不能证明免费或精确费用为零。

浏览器中已查看成功任务的执行器、结果、工作状态 v1 和展开的 `document_read` 来源回执。备份维护停止并重新启动全部 12 个实例后，再通过页面刷新和带认证 API 核对：工作状态、历史任务结果和笔记均保持一致。截图 `source-receipt-ui.png`、`restart-readback.json` 在上述激活证据根内。这一轮仅验收该真实运行详情，不能替代全部页面及移动端验收。

工作状态是 Agent 按进展保存的派生快照。本例在写笔记前保存 v1，因此“下一步”仍显示待写笔记，尽管最终任务完成；运行终态不会自动伪造 Agent 的工作集修订。后续提示词/交互应明确快照时点并提醒完成时复核，不把快照当作自动同步的任务清单。预算触顶文案仍过于笼统，现有提示中的“unknown attempts reserved”不能作为实际存在未知请求的证据；后续预算体验需要区分已报告用量和下一次预留。

## 新的可恢复基线

`backups/source-engine-live-20261013` 已包含新的工作状态、模型/工具回执、原文产物、配置及完整当前/上一版发布包。实际隔离还原报告 `restore-checks/44c9f2937dae455db880f5a6534717d8/result.json` 全部通过：**44 个表/序列及结构权限、10 个账号、2 个加密凭证、25 个发布引用、3,008 个文件、零链接**。隔离 PostgreSQL 已停止，恢复检查没有调用供应商，也没有在还原库启动 Worker，不能据此称为还原库任务接管验收。备份结束后正式 12 个实例（11 个服务角色、其中两个 Worker）已重新启动，Doctor 核心检查通过；两个源码 Worker 的实际绑定再次核对通过，正式库保留两个源码任务，均已终结。最终摘要为激活证据根的 `activation-result.json`。

同一独立评审 Agent 只读核对迁移、13 次发布、首次失败与真实模型、两份还原报告及重启回读，确认可以支持本批 Windows 激活/恢复结论；没有重新执行这些验收，也没有将它们扩张为全部 Goal、真实研究、2 核/4 GB 性能或有界内存通过。

Windows Sandbox 的隔离代码执行仍未配置，Doctor 如实报 warning；这不等于 Sandbox API 已具备本机容器执行能力。P2 的旧实现/权限退役、P2.5 的完整 Session 历史内存上限/恢复耗时/缓存生命周期、运行详情有界分页、全部 Web 交互、P4 其他故障以及 P5 真实日期/供给库存研究尚未完成。下一项优先处理源码 Session 的历史保留与内存边界，必须保留当前引擎任务兼容和恢复证据；最后才按约定统一运行一次 Linux CI。
