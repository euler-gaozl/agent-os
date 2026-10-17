# DSH 上游更新到 0.2.1-rc.2（候选，未部署）

日期：2026-10-17。状态：**源码基线已更新、全部构建/测试通过；尚未安装/激活**。平台仍运行旧 `dsh-source-639ed015-*` 引擎，以保证历史任务重放。

## 上游

- 官方 tag：`dsh-v0.2.1-rc.2`。
- commit：`687f282e8625c6b8d11ff58211a90524be2e4317`。
- GitHub codeload zip SHA-256：`7605af60cdd2918e9183bf80af1cf80ed3caed23298f7dfccc2f747122cc059c`（45,624,372 bytes）。
- 导入 21 个依赖图包目录，共 **357** 个文件；相对旧基线 **207 files changed, 6,778 insertions, 4,413 deletions**。
- 上游发布说明的主要变化：DeepSeek-V4.1-Flash-1017、Search/Fetch API、Session 格式/插件记录、移除 invariant 导出等；本平台内核只导入固定包，不导入 CLI/Desktop/Web/SDK。

## 构建与测试

| 引擎 | 新 engine 名 | 结果 |
| --- | --- | --- |
| core/source | `dsh-source-687f282e-state-v1`（源码常量） | 16/16 |
| guarded | `dsh-source-687f282e-guarded-v7` | 31/31 |
| budget | `dsh-source-687f282e-budget-v3` | 15/15 |
| final | `dsh-source-687f282e-final-v5` | 19/19 |
| native | `dsh-source-687f282e-native-v4` | 17/17 |
| resident | `dsh-source-687f282e-resident-v2` | 19/19 |

- `pnpm verify:upstream`：357 files from `687f282e…` 通过。
- 全部为本地 source-Harness 测试；无付费模型、无 GitHub Actions。
- 构建产物在 `agent-os-harness/.work/*-candidate`；证据审计目录 `local/evidence/dsh-v0.2.1-rc.2-audit/`。

## 为什么没有直接安装

- 现有任务（DS-01/02/03/05/06/07 等）的 engine 字段固定为 `dsh-source-639ed015-*`；直接把 Worker 换成新引擎会让历史任务找不到旧 runner，违反“旧任务可重放/读取”。
- 需要先做 **双版本 Worker bundle**：同一发布同时携带 `639ed015` 旧引擎和新 `687f282e` 引擎，默认新任务用新引擎、旧任务仍用旧引擎；再做 replay/activation 验收和备份。
- 在新引擎默认切换前，旧 `worker-52356bed…`/`runtime-57ce21ba…` 继续运行。

## 双版本注册脚手架（未启用）

- Runtime `69b9e62`：识别新 `687f282e` 六种 engine、增加 claim/reap 成员和 budget 路由；旧 engine 路径保持不变。`go test ./internal/runstate ./execution ./runtime` 通过。
- Worker `f499e2a`：生成/嵌入六个 V2 compiled lock，增加 `DSH_*_V2_RUNNER` 启动 wiring、`sourceForEngine` 映射和 budget 路由；`go test ./worker ./cmd/worker` 通过。**平台发布脚本尚未打包这些 V2 目录/环境变量，所以线上仍无法启用新引擎。**
- 下一步仍需：给 Build-Services/Platform 增加 V2 artifact 参数和 release 描述字段、打包同时含旧/新目录的 Worker release，再做 replay/activation。

## 双版本打包（已生成，未安装）

- 平台脚本已支持 `-SourceV2Artifact`/`-ResidentV2Artifact`/`-BudgetV2Artifact`/`-NativeV2Artifact`/`-FinalV2Artifact`/`-GuardedV2Artifact`，把新旧目录放进同一 Worker release，并写入六个 `*_v2_execution` 描述。
- 已实际生成 staged Worker `worker-76038f18…` / `worker-26bb66a5…`：同时含旧 `639ed015` 资产和六个 `687f282e` V2 资产；描述中的 manifest/engine/protocol 均正确。
- Worker `64a31b9` 已把 vendored Runtime 更新到 `69b9e62`（新引擎识别），`go test ./worker ./cmd/worker` 通过；`64a31b9` 同步 source provenance。
- Runtime 已生成并安装 `runtime-cd1436ca…`（含六个 V2 descriptor）；双版本 Worker 已安装 `worker-806b411d…`（staged 26bb66a5，含旧/新目录与六个 V2 环境变量），2 副本 readiness verified。
- `DEFAULT_RUN_ENGINE` 已切到 `dsh-source-687f282e-guarded-v7`。
- 旧引擎回归：任务 `59a78329…` 仍用 `dsh-source-639ed015-budget-v3` 完成 step 6，证明旧任务路径未断。
- **新引擎任务已跑通**：把默认临时切到 `dsh-source-687f282e-budget-v3` 后，任务 `da77e711…` **completed step 6**，5 个工具回执，engine 为 `dsh-source-687f282e-budget-v3`；证据 `local/evidence/dsh-0.2.1-new-engine-smoke-c63c82b360d54063b14a50e5f6a1e095/`。随后默认恢复为 `dsh-source-687f282e-guarded-v7`。
- guarded-v2 的 final-capable Agent 任务尚未跑（现有 final Agent 使用真实 provider/MCP，未调用付费模型）。这不能写成 guarded-v2 已验收，但新引擎的 budget-v3 路径已有真实 Runtime/Worker/DB 证据。
- 新引擎 40 轮：任务 `7ceb0cf2…` 在 `dsh-source-687f282e-budget-v3` 上 **completed step 41**（40 个 recall 回执）；证据 `local/evidence/ds06-80round-nokill-2026-10-17T14-47-34-495Z/`（文件名沿用旧脚本，内容为 40 轮 COMPACT40_OK）。这验证了新引擎的长历史路径，但不等于 guarded-v2/final 验收。
- 安装后已生成 `ds08-final-20261017f` 并隔离恢复通过（46 关系、10 角色、5 凭据、2 Worker bundle、192 代/3,103 文件）；临时集群停止。

## 下一步

1. 设计并实现双版本 Worker 打包（旧/新 engine 目录+manifest 列表）。
2. 用新引擎跑 DS-01/02/03/05/06/07 的 replay/fixture 回归；确认旧任务仍用旧引擎。
3. 切换默认 engine 前再做一次 DS-08 备份/隔离恢复。
4. 任何新引擎激活都要新版本号，不能覆盖旧引擎产物。
