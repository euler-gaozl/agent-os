# 当前交接入口 · 2026-10-20

新增有界任务：[期货任务页面与错误记录实施计划](docs/maintainer/futures-ux-errors-plan-20261020.md)、[问题清单](docs/maintainer/futures-ux-errors-register-20261020.json)、[给 DSH 的开工指令](docs/maintainer/dsh-futures-ux-prompt-20261020.txt)。目前仅完成评估，未改产品代码；先修复重复入口，再整理报告与诊断，错误按需手动复盘，不创建自动化。下方 2026-10-18 为原 Windows 的独立历史交接，不能代替本轮范围和环境。

## 2026-10-18 交接记录

先读 [当前状态](docs/maintainer/current-state.md)、[DS-R1/R2/R3详细任务](docs/maintainer/deepseek-followup-20261018.md)，复制 [开工提示词](docs/maintainer/deepseek-followup-prompt-20261018.txt)。15仓main已同步；证据链已实现、安装和验证；原供给四问成稿但内容未通过。环境先确认，凭据与原电脑私有证据不随克隆转移。Actions关闭，不复活旧无限Goal。

以下为历史交接，不是本轮待办：

# Agent Platform 接手入口

**最新：交给 DeepSeek。** 直接读 [2026-10-17接续任务](docs/maintainer/deepseek-handoff-20261017.md)，复制 [开工提示词](docs/maintainer/deepseek-start-prompt.txt)。用户要求交接后暂停原Codex。15仓远端和当前安装已重新核对，整体仍未完成；下方较早的交接内容保留作历史。

**2026-10-17 更新：Mac 成果已接回原 Windows，6 仓 29 个新增提交已同步 GitHub。** 当前从 [Windows 续做记录与顺序](docs/maintainer/windows-resumption-20261017.md) 开始；下文是原交接背景。Mac 最后一轮 Runtime/Console 安装证据已找回，不能继续按旧文“尚未安装”判断 Mac，也不能当作 Windows 已安装。

交接日期：2026-10-14。维护者交接知识库已整理，原所有者要求完成交接后暂停本聊天 Goal，由朋友的 Codex 继续。**整体目标尚未完成。**

**2026-10-15 环境更正：接手者在自己的 Mac 上开发。** 原所有者的 Windows 路径、已安装状态、私有资料与本机地址均为历史部署记录。先读 [Mac 接手及环境边界](docs/maintainer/environment.md) 和 [可机读环境映射](docs/maintainer/environments.json)。默认不连接、不修改原电脑，也不尝试在 Mac 上照搬 Windows 运维脚本。

请从 [项目群知识库](docs/maintainer/README.md) 开始；不要把历史交付日志、仓库数量或绿色测试当成当前完成证明。

- [可直接发给接手 Codex 的提示词](docs/maintainer/continue-prompt.txt)
- [完整目标和不可丢失的要求](docs/maintainer/objective.md)
- [交接快照：目标进度及原 Windows 的部署状态](docs/maintainer/current-state.md)
- [按优先级排列的后续工作](docs/maintainer/backlog.md)
- [15 个仓库、开发分支、核对过的提交](docs/maintainer/repositories.json)
- [架构、数据所有权和存储规则](docs/maintainer/architecture.md)
- [可机读的本体与关系映射](docs/maintainer/ontology.json)
- [Mac 下载、开发和环境隔离方法](docs/maintainer/environment.md)

优先处理真实期货研究的完整成稿与证据质量，再关闭既定平台余项。最近失败任务已有两份可回读的草稿；预算耗尽和内容缺陷尚未修复。**不要再次从零规划或重造 Agent 框架。**

这套交接仅包含可公开源码、方法、状态和证据索引，不包含 API Key、数据库、配置秘密值或完整私有研究资料。朋友在新电脑可以先继续源码开发及隔离测试；原电脑的真实任务验收需要原受保护环境，不能假称克隆 GitHub 就恢复了它。
