# Windows 交付状态审计（2026-10-17）

日期：2026-10-17。状态：**整体未完成**。本页是交接/验收用的差距清单，不替代任何单项证据，也不把本机通过写成 hosted CI 或生产验收。

## 已完成或已取得真实证据

| 项 | 状态 | 主要证据 | 仍缺 |
| --- | --- | --- | --- |
| DS-01 非数值原文论据 | 完成并安装 | `windows-ds01-statements-20261017.md` | 无新增 |
| DS-02 未就绪草稿提前结束 | v7 单次续接 + v6/v7 双产物已安装 | `windows-ds02-finalization-investigation-20261017.md` | v6 失败任务不能直接续跑；保留重放/读取 |
| DS-03 真实四问研究 | 报告通过独立内容复核 ACCEPT | `windows-ds03-inventory-20261017.md` | 更正任务本身 0 阅读资料，证据在原始任务 |
| DS-04 中台/业务 UI | 页面矩阵、Console 父任务链接、Futures 同品种历史任务均浏览器验证 | `windows-ds04-ui-browser-20261017.md`、`local/evidence/ds04-*` | Futures 精确跨任务证据链仍是启发式入口；v6 续跑评估 |
| DS-05 权限退役/旧覆盖 | 正式执行域 ACL 已收缩；双 Worker 接管通过；临时 Telemetry mock 导出 3,992 条 | `windows-ds05-access-retirement-20261017.md` | 真实 Langfuse/managed Telemetry；旧主仓实现删除 |
| DS-06 存储生命周期 | 笔记修订/过期/并发 200+409/撤回；128–8192 步 Compact/重放；32k/64k/1M 20 轮及 40/80 轮完成 | `windows-ds06-storage-lifecycle-20261017.md` | 8k/16k 失败；40/80 轮无可见 Compact；真实 Compact 点强杀续跑、10M 分块、长期 RSS 上界 |
| DS-07 故障/资源 | 30.1 分钟 24/24 soak；锁/取消/DB 会话中断/PG 快速重启/Runtime 4 秒与 25 秒停机（60 秒退避）均完成；DB 层死锁 0→1 | `windows-ds07-platform-load-20261017.md` | 超过约 60 秒停机、网络分区、任务级恢复、任务级死锁、大数据量慢查询、长期 RSS/生产容量 |
| DS-08 备份恢复 | `ds08-final-20261017d` 隔离恢复通过：46 关系、10 角色、5 凭据、2 Worker bundle、187 代/3,073 文件 | `windows-ds08-restore-20261017.md`、`local/restore-checks/604dcdf48dbe4dc0a834d991228dba67/` | 服务器/跨机 HA、八物理库、外部服务恢复 |
| DS-09 集中 CI | 本机五 Go 仓全绿；Console 40、Futures 27、Harness 16+31，0 skip | `windows-local-acceptance-20261017.md`、`local/evidence/ds09-local-suite-ff7f6d242fba4d25ad73d855d8bebf6c/` | **hosted GitHub Actions 一次集中 CI 未执行** |

## 明确阻塞/不可在本机关闭

1. **真实 Langfuse/managed Telemetry**：2026-10-17 用户明确表示没有真实凭据、不要在本机部署 Langfuse（其需独立部署）；现有只有临时 Telemetry 实例 + 本机 mock，作为**显式延后的独立部署项**，mock 不得写成真实接收。
2. **旧主仓实现删除**：P2 清单中仍有未完全移交的独有覆盖（ENOSPC、归档丢确认、真实 Langfuse、Docker 沙箱、旧权限升级等）；在等价覆盖执行前删除会降低覆盖，不能做。
3. **真实 Compact 点强杀续跑**：受控 OpenAI 夹具走 budget-v3，40/80 轮没有可见 Compact；带 Compact 的 source 基准是合成 journal，不是真实 Worker/DSH 任务。需要 native/guarded 协议夹具或真实供应商，当前没有。
4. **网络分区**：本机非管理员，无法用防火墙制造 loopback 分区；不能把停 Runtime/PG 写成网络分区。
5. **任务级死锁**：两次外部锁注入任务均 completed，未复现 40P01；只有 DB 层死锁证据。
6. **大数据量慢查询/长期 RSS**：当前库约 166 行，查询亚毫秒；没有百万级数据或长窗口 `pg_stat_statements`，不能外推生产容量。
7. **最终 hosted CI**：Actions 日常禁用，只在全部本机验收后执行一次；上述第 1–3 项未关闭，不能把本机复跑写成最终 CI。

## 结论

当前交付已覆盖大部分本地功能、页面、权限、备份与故障恢复，但**整体目标仍未完成**。下一步必须先在真实 Langfuse/managed、旧覆盖退役/删除、真实 Compact 夹具三者中取得外部条件或明确产品决策，然后才能执行唯一一次 hosted CI 和逐条完工审查。
