# Windows 本机集中验收扫描（2026-10-17）

日期：2026-10-17。状态：**本机全套扫描通过；不是 GitHub Actions，也不是最终集中 CI**。这是 DS-09 的本机前置证据，仍保留外部依赖/容量/旧实现退役等开放项。

## 执行环境

- 原 Windows 本机，Go 1.27.2、Node 24.19.0、pnpm 11.25.0。
- Runtime 已安装 `runtime-57ce21ba…`（cancel 60 秒等待修复）；Console 已安装 `control-94f118…`（运行详情“查看源任务”）。
- 全部测试在本机运行，`GOWORK=off` 等由仓库自身脚本控制；未调用付费模型，未启用或触发 GitHub Actions。

## 结果

| 仓库/层 | 命令 | 结果 |
| --- | --- | --- |
| Runtime | `go test -mod=vendor ./...` | `cmd/migrate`、`cmd/runtime`、`internal/runstate`、`runtime` 全部 `ok`，无失败 |
| Console Go | `go test -mod=vendor ./...` | `cmd/control`、`console`、`internal/webproxy` 全部 `ok` |
| Console Web | `pnpm test` + `pnpm build` | **40/40** 测试通过，0 跳过；Vite/TypeScript 构建通过 |
| Worker | `go test -mod=vendor ./...` | `cmd/worker`、`worker` 全部 `ok` |
| Futures Go | `go test -mod=vendor ./...` | `cmd/futures`、`futures`、`internal/webproxy` 全部 `ok` |
| Futures Web | `pnpm test` | **27/27** 通过，0 跳过 |
| Telemetry | `go test -mod=vendor ./...` | `cmd/telemetry`、`telemetry` 全部 `ok` |
| Harness | `pnpm test` | **16/16** 通过，0 跳过 |
| Harness guarded | `pnpm test:guarded` | **31/31** 通过，0 跳过 |
| Go vet | Runtime/Console/Worker/Futures/Telemetry 各 `go vet -mod=vendor ./...` | 五仓全部无输出（通过） |

## 覆盖含义

- Runtime 测试包含 cancel 事务、笔记生命周期、continuation、worker 归档/恢复、执行协议等；Console Web 测试包含业务入口、运行详情、continuation、证据/回执分页、恢复指针等；Futures Web 包含报告投影、草稿/失败语义、轮询竞态等。
- Harness core/guarded 测试覆盖 source loop、Compact、冻结策略、重放和错误持久性。
- 这些都是**本机测试/构建**，不能替代 GitHub Actions 的独立 runner、真实 Langfuse、服务器/跨机 HA、10M 分块或旧实现删除验收。

## 未覆盖

- 真实 Langfuse/managed Telemetry、真实外部 OTLP 端点。
- Go `-race` 未执行：本机 `gcc.bat`（Anaconda）链接 Go race runtime 时缺少 `WaitOnAddress/WakeByAddress*`，构建失败；这是本机 C 工具链限制，不计为 race 通过，也不计为代码竞态失败。
- DSH Compact 点的真实强杀续跑（本机只有 32k/64k 长任务接管与 8192 步合成基准）。
- 慢查询计划、死锁注入、锁内异步取消、长期/生产 RSS 上界。
- 旧主仓业务实现的逐行退役与 Linux 组合。
- 最终 GitHub Actions 集中 CI（仅在全部本机验收后执行一次）。

## 结论

本机全套扫描通过，可作为 DS-09 前置证据；但整体目标仍未完成，不能把本记录写成最终 CI 或全平台交付通过。
