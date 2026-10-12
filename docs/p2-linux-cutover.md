# P2 Linux 集成切换与旧覆盖退役清单

2026-10-13，实施中。Windows 已部署十二仓中的十一个启用服务，Linux 旧集成 CI 仍从原业务源码构建。本清单记录切换条件，不声明新组合已经通过。

## 独立评审发现

受用户授权的 architecture_reviewer 对现有 Compose、迁移、发布及故障测试做了静态检查；本轮未运行测试或部署，也未读取机密配置。评审认为拆仓路线可继续，但指出以下实际阻塞：

- 健康检查路径分为 `/app/healthcheck` 与 `/usr/local/bin/healthcheck`；容器 UID 分为 10001 与 65532。旧编排及故障脚本固定旧值，可能将命令不存在误认为正确拒绝。必须核对真实进程退出、重启和 fence，配置不能改成公开可读。
- Registry/Runtime/ToolHub 新镜像缺 builtin-tools 标签；现有回滚兼容守卫会按历史六工具处理并拒绝升级。必须用 Owner 合约生成/验证元信息，不能删除守卫。
- 旧 migrate-services 包含全部业务 DDL、跨域导入及宽授权，不能作为新初始化器保留。集成只负责数据库、登录身份、配置和编排；业务迁移与表授权归八个 Owner。
- ci-isolate-storage 假设先建立旧公共表再删除；新空库应从起点独立分域。旧权限退役必须另留升级夹具，不能用空库成功替代。
- 故障和真实后端测试还有主仓独有覆盖。迁移前不能直接删除业务目录，让 CI 因少跑测试而变绿。

## 实施顺序

1. 固定十二个 Owner 完整提交与协议，逐个验证镜像启动、用户、健康检查、工具/引擎标签与镜像身份。私有读取使用每仓单独只读身份，构建阶段不带 Git 凭证。
2. 实现仅部署用途的 provision，持久化且幂等恢复 identities；数据库角色不重跑换密钥。依次调用 Registry、Runtime、Knowledge、ToolHub、Storage、Sandbox、Telemetry、Sources 的独立 migrator。Runtime 同时授权 Worker，Knowledge 同时授权 Indexer；两个 BFF 没有数据库。
3. Registry 就绪后用授权 HTTP 写必要凭证引用和样例版本，比较已有内容，重跑不无条件创建新 revision。
4. 全新一次性分域数据库运行真实组合、独立发布回滚、故障接管及预算测试。报告实际 Owner SHA 和镜像 digest；SQL 故障观察如仍存在，明确是只读测试观察，不宣称纯 HTTP 黑盒。
5. 下表覆盖全部移交并执行后，退役集成业务源码/构建入口。历史固定提交仍可构建兼容夹具；当前版本不得缺 Owner 就回退主仓实现。

## 不能丢失的覆盖

| 旧场景/位置 | 目标归属 | 新覆盖及执行状态 |
| --- | --- | --- |
| 真实 ENOSPC 后笔记、回执、产物恢复；internal/platform/disk_full_test.go、storage-faults.yml | 集成真实 Runtime/Storage 故障测试 | 待迁移；旧工作流保留 |
| 超过 4 MiB 历史、摘要遗漏来源、中断后证据回查；dsh_evidence_test.go | Runtime/Worker 真实进程与受控模型 | 待迁移；二进制交接测试不替代 |
| Storage 丢归档确认、取消保留首批、末批失败；harness_archive_test.go | Runtime 协议与 Storage HTTP 夹具 | 待核对/移交全部场景 |
| 真实 Langfuse 接收、回读和重投；telemetry_live_test.go | Telemetry live CI | 待迁移；普通 inbox 测试不替代 |
| Docker 沙箱隔离、broker 强杀；sandbox_integration_test.go | Sandbox 真实 Docker CI | 待迁移；Windows broker 就绪不替代 |
| 旧 Storage 笔记授权退役；cmd/migrate-services/retire_test.go | Runtime 历史升级测试 | 待迁移；保留本机旧版本回滚所需授权 |
| Knowledge 的 Milvus/LightRAG/Embedding 三个 live 测试；rag-integration.yml | Knowledge 已有源码、接入真实后端工作流 | 源码已移交；执行工作流待切换 |
| 百万文档/千万分块；cmd/capacity | Knowledge 容量工具及专用工作流 | 待移交；不重复冒充全平台规模验证 |

每项最终记录新文件、工作流、固定提交和运行结果。未找到等价覆盖就保持未完成。旧版本已通过的结果仍是历史证据，不随源码移动成为新版本证据。

## 独立镜像关卡实现及 Linux 验证

新增 `owner-images.yml` 按固定仓库白名单和完整 SHA 检出各 Owner。每个仓库配置单独只读 deploy key，私钥只保存于集成仓库的对应 Actions secret；本机初始化暂存私钥均已删除。检出后不保留 Git 认证，Docker context 只取 `git archive` 中的普通已提交文件。构建从 Owner 合约生成标签，记录实际 image ID、来源归档哈希、UID、健康检查和迁移入口；不再默认所有镜像均使用旧 /app 路径。

独立评审指出“跳过 fork 作业仍可能成为绿灯”和“声明的依赖不等于实际编译依赖”，均已修正：固定名汇总任务 always 执行并要求十二份完全匹配的成功报告；提取镜像实际 service/healthcheck/migrate，读取 Go build info 校验模块/包、SDK/事务模块、目标与无 Replace。未把该检查名称配置为仓库强制合并规则，不能宣称已具备分支保护。

本机 179 项合成镜像/二进制合约用例通过，十二个真实源码的 SDK 声明/go.sum/vendor 校验通过。实际 Linux 交叉编译 Runtime/Worker 二进制的 build info 检查通过：`local/evidence/owner-buildinfo-e962ae1188f844ed948408a7600dc3ee/result.json`。评审只做静态核对。

首次真实 [Linux 独立镜像 CI 38280726971](https://github.com/euler-gaozl/agent-os/actions/runs/38280726971) 在集成提交 `fd89eee96559e0bca62b7f85e3608d28efa8345c` 全部通过：十二个 Owner 镜像在各自固定源码上下文构建，并提取实际二进制核对版本、运行真实入口帮助命令。十二份报告已下载至 `local/evidence/linux-owner-images-38280726971-a432cc2af8434c5380ee8e88062faf5f`。同提交的旧 Platform CI `38280726840` 也通过，但仍从旧主仓业务代码构建，不能把它写成新组合全链路验证。

仅部署用途的 [provision 初始化器](fresh-deployment-provision.md) 已实现，并通过本机隔离 PostgreSQL 恢复和权限测试；Linux PostgreSQL/race 专项 CI `38283706152` 已通过。

独立镜像工作流新增 composition：通过镜像 ID 和归档哈希装载同次构建的十二个镜像，在全新八库执行各 Owner migrator 两次，再通过 Registry HTTP 比较/写入夹具凭证。使用不同 UID 的 0640 部署副本，原始配置和 checkpoint 保持 0600。新的服务测试逐角色、逐副本核对心跳，并检查真实跨库连接拒绝、Worker 提交后强杀接管、其他服务强杀、依赖停机降级和数据库断连恢复；模型和 MCP 均为受控样本。完整组合首次结果待执行，不能预先写成通过。

旧 Compose、独立升级回滚和上表独有覆盖仍保留，尚未完成退役；新组合不会自动替换 Windows 运行版本。
