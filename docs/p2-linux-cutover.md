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
| 超过 4 MiB 历史、摘要遗漏来源、中断后证据回查；dsh_evidence_test.go | Runtime/Worker 真实进程与受控模型 | 已迁 Runtime `worker_evidence_test.go`，Windows 实际独立 Worker 被杀后接管通过；见下方证据。最终统一 Linux 验证待执行 |
| Storage 丢归档确认、取消保留首批、末批失败；harness_archive_test.go | Runtime 协议与 Storage HTTP 夹具 | 已迁 Runtime `archive_retention_test.go`，五项本机通过，含上传中接管；Storage 是 HTTP 内存夹具，磁盘持久化仍由 ENOSPC 等独立验证覆盖 |
| 真实 Langfuse 接收、回读和重投；telemetry_live_test.go | Telemetry live CI | 已迁 Telemetry `telemetry/live_test.go`，提交 `0df5f8f`；实际 Owner CI 因额度取消，未通过最终验证；旧覆盖保留 |
| Docker 沙箱隔离、broker 强杀；sandbox_integration_test.go | Sandbox 真实 Docker CI | 已迁 Sandbox `docker_integration_test.go` 和手动/reusable `isolation.yml`；本机三项授权/真实受限账号检查通过，Linux 测试交叉编译通过。实际 Docker 尚未执行 |
| 旧 Storage 笔记授权退役；cmd/migrate-services/retire_test.go | Runtime 历史升级测试 | 已迁 Runtime 显式 `retire-access` 与真实登录/撤权回滚测试，Windows 23 项通过；见[审计与候选](runtime-access-retirement-20261013.md)。正式撤权待启动/发布/回退守卫；旧覆盖及回滚所需授权仍保留 |
| Knowledge 的 Milvus/LightRAG/Embedding 三个 live 测试；rag-integration.yml | Knowledge 已有源码、接入真实后端工作流 | 独立 `retrieval.yml`、Milvus 配置与模型夹具已移交；固定后端、拒绝跳过。新 Owner 工作流未执行 |
| 百万文档/千万分块；cmd/capacity | Knowledge 容量工具及专用工作流 | 独立容量命令/手动工作流已移交；新库上 1000 文档/10000 块、零查询错误、版本隔离和已有库拒绝通过。百万规模未重跑；不冒充全平台规模验证 |

每项最终记录新文件、工作流、固定提交和运行结果。未找到等价覆盖就保持未完成。旧版本已通过的结果仍是历史证据，不随源码移动成为新版本证据。

早间移交证据 `local/evidence/p2-owner-coverage-58d357e0cd7b4e71bb4ea51cf7661743`：Sandbox 三项实际授权/账号检查零跳过；独立容量工具新 PostgreSQL 上写入 1000 文档/10000 块并查询，重复采用已有测试库被拒绝。查询使用 Knowledge 的受限 SET ROLE，报告明确不代表独立登录或 Windows 资源限额验收。临时集群已停止。独立评审补强 SIGKILL 退出状态、先停止 broker 后清理容器、正确 daemon 日志来源，以及缺失关键词必须零命中的断言。首轮 fixture 操作 ID 不匹配 run ID 的失败留存于 `p2-owner-coverage-10f9fb80717a484199d37edb9c9f5471`。新工作流只有手动/reusable 入口，未启用或运行 Actions；旧覆盖尚不删除。

2026-10-13 夜间本机补充：Runtime 五项归档测试通过，原始报告 `local/evidence/p2-runtime-archive-5a53f17d08a24ac48b4f78c874061621/result.json`。真实临时 PostgreSQL、受限 SET ROLE 和 SDK HTTP 验证，Storage 为内存夹具。独立评审指出首版旧 owner 调用在入口就被拒绝，不能证明上传期间接管；已增加在 manifest 接受后/返回前改变 fence 的测试并通过。旧主仓测试尚未删除。

独立 Worker 长历史测试通过，报告 `local/evidence/p2-worker-evidence-54cef5d09d3f4caabe0b0bd3804351b3/result.json`：真实独立 Worker `b07b739`、固定 DSH、Runtime HTTP 和临时数据库；回查回执已提交但 HTTP 回复未返回时杀死 Worker，接管 fence=2 后完成。18,874,181 事件字节、40 批、16 次 Compact，摘要确实遗漏来源后仍能回查原文，模型与已提交回查没有重复。测试使用合成资料和受控模型，无付费调用；两次运行后临时数据库均已停止。首轮身份配置遗漏导致 Worker 启动失败，原始失败保留于 `p2-worker-evidence-cdba9b3545f2447bad0a6953d406bb42`。不据此宣称 Node 内存有界或子进程清理已完整验收。

## 独立镜像关卡实现及 Linux 验证

早间续做修复了 Worker 测试 cleanup 从可变 config 读取实例名、覆盖 replacement 日志的问题。定向复验 `p2-worker-evidence-ecfcca442b6d46548ac29750099b4e77` 通过，零跳过；两个实例日志独立保存并记录哈希，原有恢复断言和数据量不变，临时库已停。此前单个日志不能作为 replacement 专属过程证据；原始报告仍保留。本次没有 CI、付费调用或正式部署变化。

新增 `owner-images.yml` 按固定仓库白名单和完整 SHA 检出各 Owner。每个仓库配置单独只读 deploy key，私钥只保存于集成仓库的对应 Actions secret；本机初始化暂存私钥均已删除。检出后不保留 Git 认证，Docker context 只取 `git archive` 中的普通已提交文件。构建从 Owner 合约生成标签，记录实际 image ID、来源归档哈希、UID、健康检查和迁移入口；不再默认所有镜像均使用旧 /app 路径。

独立评审指出“跳过 fork 作业仍可能成为绿灯”和“声明的依赖不等于实际编译依赖”，均已修正：固定名汇总任务 always 执行并要求十二份完全匹配的成功报告；提取镜像实际 service/healthcheck/migrate，读取 Go build info 校验模块/包、SDK/事务模块、目标与无 Replace。未把该检查名称配置为仓库强制合并规则，不能宣称已具备分支保护。

本机 179 项合成镜像/二进制合约用例通过，十二个真实源码的 SDK 声明/go.sum/vendor 校验通过。实际 Linux 交叉编译 Runtime/Worker 二进制的 build info 检查通过：`local/evidence/owner-buildinfo-e962ae1188f844ed948408a7600dc3ee/result.json`。评审只做静态核对。

首次真实 [Linux 独立镜像 CI 38280726971](https://github.com/euler-gaozl/agent-os/actions/runs/38280726971) 在集成提交 `fd89eee96559e0bca62b7f85e3608d28efa8345c` 全部通过：十二个 Owner 镜像在各自固定源码上下文构建，并提取实际二进制核对版本、运行真实入口帮助命令。十二份报告已下载至 `local/evidence/linux-owner-images-38280726971-a432cc2af8434c5380ee8e88062faf5f`。同提交的旧 Platform CI `38280726840` 也通过，但仍从旧主仓业务代码构建，不能把它写成新组合全链路验证。

仅部署用途的 [provision 初始化器](fresh-deployment-provision.md) 已实现，并通过本机隔离 PostgreSQL 恢复和权限测试；Linux PostgreSQL/race 专项 CI `38283706152` 已通过。

独立镜像工作流新增 composition：通过镜像 ID 和归档哈希装载同次构建的十二个镜像，在全新八库执行各 Owner migrator 两次，再通过 Registry HTTP 比较/写入夹具凭证。使用不同 UID 的 0640 部署副本，原始配置和 checkpoint 保持 0600。

首次真实组合 [CI 38284809396](https://github.com/euler-gaozl/agent-os/actions/runs/38284809396)，提交 `dd28c2d92eae437b805702716cf9d7b73db8424a`，已通过：十五个实例逐角色/逐副本心跳、十个本域账号实际登录和七十次跨域 CONNECT 明确拒绝、知识版本隔离、MCP/Skill 检测启用、Worker 在笔记提交后实际 SIGKILL 并以更高 fence 恢复、唯一笔记和四个工具回执、其他十一类服务实际强杀后重启且非目标容器不变、Storage/ToolHub 降级、数据库停机时同一健康程序返回 1 并在恢复后返回 0。Telemetry 接收端实际接受的 trace 包含本次任务 ID，不只检查发送端标记。

八个 Owner 迁移各执行两次，目标库 schema/表授权重复哈希一致；七个非目标库和配置摘要不变。这项 pg_dump 比较排除 owner/comment，不冒充完整数据库元数据恢复测试。模型、MCP 和 OTLP 均为受控夹具，无付费调用。原始通过报告：`local/evidence/owner-composition-38284809396-bd5e9e9a51ed49e794838a3edf1d0ecc`。它不替代历史升级、真实模型、正式容量、Docker 沙箱执行或独立发布控制器故障验收。

旧 Compose、独立升级回滚和上表独有覆盖仍保留，尚未完成退役；新组合不会自动替换 Windows 运行版本。

## 独立发布入口适配（实际 Owner 发布 CI 待执行）

`release-service.mjs deploy --owner-report <result.json>` 使用已验证构建报告登记 Owner：镜像 ID、仓库与完整提交、角色、完整 HTTP/data/工具/引擎合约、UID、程序与健康检查路径都必须一致。配置只使用该 UID 拥有的 0640 部署副本，内容摘要固定；报告摘要和必要公开合约保存在发布记录中，不保存明文配置。报告是管理员提供的构建证据，不是第三方签名证明。

Owner 更新和回滚要求双向完整合约相等，原工具/引擎守卫仍保留。未知合约的 legacy 与 Owner 之间均不自动切换；旧 legacy→legacy 测试继续保留。历史 Windows 更新回滚不受这个 Linux CLI 增量影响。

新增十二角色独立 unit 验收检查非目标容器身份/启动时间/重启数及配置摘要不变、原知识资料回读、错误 Owner 在替换前拒绝，并检查 Knowledge 从 1 扩到 2 再回到 1。这里的 rollback 是同镜像副本数量回滚，不能写成不同版本二进制回滚。原不同版本回滚覆盖暂未退役；Linux 发布进程被强杀后的 pending 恢复尚未提供。本段新增元数据/协议拒绝单测已通过，容器结果另记。
