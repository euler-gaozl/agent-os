# Mac 接手：独立开发与环境边界

2026-10-15 用户已确认接手者使用她自己的 Mac。本文件取代此前以 Windows/D 盘为默认的新电脑接手指令。

## 三种环境不能混用

| 环境 | 本次用途 | 事实与权限边界 |
| --- | --- | --- |
| `environment:maintainer-macos` | 朋友自己的源码开发、构建、隔离测试、页面验证 | 当前实际开发环境；配置、数据库、账号、端口和证据由她独立建立 |
| `environment:owner-windows` | 原所有者的历史部署记录，以及以后安排的 Windows 专项验收 | 现有资料不授予连接或修改该机器的权限；安装状态和私有路径不是 Mac 现状 |
| `environment:future-linux` | 后续服务器交付目标，或明确建立的 Linux 隔离测试环境 | 当前没有服务器；Mac 上的 Linux VM/容器测试须注明 CPU 架构及覆盖范围 |

可机读边界见 [environments.json](environments.json)。原目标中的 Windows 单机交付仍保留；更换开发机器不等于改为“Mac 产品交付”，也不证明任何平台已验收。

## 默认目录与首次下载

朋友的开发根目录默认 `~/workspace/agent-platform`。若已有她自己的明确工作区，使用那个目录并记录，避免另建重复副本。源码归 `repos`，本机配置/测试库/产物/日志/证据归 `local`，Mac 专用辅助入口归 `ops`。这些同名目录与原电脑没有同步或挂载关系。

先核对 macOS、CPU 架构、可用空间、Git、Go、Node/pnpm 和当前工作区。不从 Windows 复制可执行文件。按各仓 `go.mod`、`package.json`、锁文件选择工具链；缺少 Docker 等可选环境时先完成可做的测试，不假装已安装。

主仓：<https://github.com/euler-gaozl/agent-os/tree/feat/end-to-end-delivery>。先在 Mac 终端克隆交接分支，已有目录时停止并核对，不覆盖：

```sh
(
  set -eu
  project_root="$HOME/workspace/agent-platform"
  mkdir -p "$project_root/repos"
  target="$project_root/repos/agent-os"
  if [ -e "$target" ]; then
    echo "目录已存在，请先核对 remote、分支和未提交修改：$target" >&2
    exit 1
  fi
  git clone --branch feat/end-to-end-delivery \
    https://github.com/euler-gaozl/agent-os.git "$target"
)
```

然后读取 `docs/maintainer/repositories.json`，将其余仓库克隆到同级 `repos`，核对清单分支与 `source_head_at_audit`；在核对过的基线上建立工作分支。主仓保留包含此次更正的交接分支最新提交。默认 main 不保证最新。不要盲目统一升级依赖，也不要把所有仓库 HEAD 当成兼容的安装组合。

`integration_pins` 是一个可审查的源码组合；`installed` 是原 Windows 的历史发布记录，不是 Mac 安装清单。固定 Owner 协议不能因换开发机器而随意更新。

## Mac 可以立即开展的工作

1. 核对代码、依赖、数据库迁移责任和已有测试，重现不依赖私人资料的失败。
2. 构建适配当前 CPU 的 Go/Node/Web 组件；按照实际 package scripts 执行测试。
3. 在自己的 Mac 原生 PostgreSQL，或已确认支持的本地 Linux 隔离环境中创建专用测试库。所有服务 URL、测试 DSN、凭证和输出目录必须来自她自己的配置；不得照抄历史环境地址。
4. 用明确标记的公开/合成资料和新建 Agent/Skill 版本、新任务验证逻辑。数据库测试跳过必须报告；合成模型不算真实供应商验证。
5. 缺少跨平台开发入口时，先补最小、隔离的开发适配并记录，不在开工阶段重造整套部署平台或声称 macOS 全链路已经通过。
6. 提交代码、测试证据和目标环境复验说明；原 Windows 的安装与验证由所有者以后另行安排。

历史 `127.0.0.1:8090/8098` 指向当时的 Windows。在 Mac 上相同地址只会指向 Mac 自己；先确认她自己的进程、监听端口与配置，不能据此宣称原系统在线。不会因知识库存在路径，就获得路径内容或该系统的访问权限。

## 不能作为 Mac 开工步骤的内容

- D 盘路径、`ops/Platform.ps1`、Windows 发布 catalog、DPAPI、旧 `Start -Migrate` 和原数据库目录：仅供理解历史实现。不要直接执行、映射、挂载、同步或寻找原电脑。
- 原任务 ID、真实草稿、历史 Agent revision、私有证据指针：属于旧环境的数据对象。不能在新库假装存在，也不尝试恢复或续跑这些 ID。
- 原 Key、加密配置、备份和完整数据库：不在 GitHub 内，不能从旧聊天或历史提交寻找。确需真实模型时使用专门为当前开发环境安全配置的凭证。
- Windows 受管升级/回滚、DPAPI、原库备份恢复：Mac 不能直接证明这些场景。保留测试计划、可执行条件和待复验状态，不主动连接原电脑完成它们。
- Linux provision 不是已验证的 macOS 引导器。容器里通过 Linux 测试，也不等于通过原生 macOS 或 Windows 验收。

## 知识和验证记录怎么使用

先读 [完整目标](objective.md) 与 [待办](backlog.md)。[状态快照](current-state.md) 是问题线索，不是需要在 Mac 自动执行的运维清单。既有证据可注明“原维护者记录”；自己执行的新证据必须记录环境 ID、OS/CPU、源码版本、依赖、数据来源、命令、结果及 skip。

Mac 工作期间新增的环境文件、库、日志及原始证据留在她的 `local`，不进 Git。可公开的脱敏验收说明和环境差异进入仓库；不要覆盖旧记录，或把 Mac 通过写成 Windows 通过。

15 仓日常 Actions 保持禁用，不为交接或每次提交启动 CI。最后一次统一 CI 仍按完整计划和预算安排。现有旧聊天 Goal 保持暂停，朋友在自己的聊天为接手工作建立 Goal，完整目标与环境依赖不能删除。
