# 解读月份角色修复 · 2026-10-18

用户授权直接修复并推送。Futures 源码为 `84c17f2ca4e271c8ef1d25f4ab3404efce0124a6`，main 与开发分支已同步，Actions 保持关闭。

## 修正

旧实现排除少数发布日期写法后，把带年份且未被事实期间覆盖的日期一律硬拦。现在先按相邻日期和分句限定上下文，再区分明确统计用途、发布/采集等元数据用途和不确定用途。

- `2026年10月的材料提到，2026年9月大豆到港预估1018.55万吨。`：10 月进入 source review，不硬拦。
- `2026年10月8日对外发布的报告披露，2026年9月大豆到港预估1018.55万吨。`：发布日期不参与统计期间比较。
- `2025年9月库存情况`：不能借用 2026 年 9 月事实；`6月末库存`、`六月末库存` 也不能借用 9 月事实。
- 发布/采集标签不能越过相邻日期或分句，掩盖后面真正的统计期间错误；同月多次出现按各自用途处理。

这些是有限语言规则。无法识别且未覆盖的日期保留人工复核，不承诺通用语义验证或研究内容正确。

## 验证与安装

- 新增 15 个场景及原有月份回归通过；独立 `go test ./... -count=1` 和 `go vet ./...` 通过。
- 受管发布构建完成 Go 二进制、Web TypeScript 检查与 Vite 构建。Web 源码未改，本轮未重复 Web 单元测试。
- 原 Windows 安装为 `futures-f2821dd46b8f490b8fa1d25c580b8ff8`，来源上述 Futures 提交、dirty=false；构建集成提交 `4675894955028546bfc4712d651f62ddcf475dff`。
- 单服务更新成功、readiness=verified、non_target_unchanged=true。原安装 `futures-8900799e0a64431aabbdc5824a87c6d1` 保留为前一版本。
- 安装后只读检查 R3d：completed、26 facts / 12 statements、draft-match=matched；无 retained / receipt_budget / quote_normalized / finding_period 类问题。结果哈希仍为 `893e78c08cceee72f84414691e7cfe150ab2301e3dfa7df1832ffec0c11ce4b6`。
- Git HTTPS 连接被重置后，使用 GitHub Git Data API 上传同一组 Git 对象，核对 blob/tree/commit 哈希，并以非强制方式更新 main 与开发分支。没有改变提交内容或触发 CI。

## 剩余范围

原 R3d 报告措辞问题仍待下一次明确的新修订，见 [DeepSeek 接续记录](deepseek-followup-20261018.md)。本次没有追改历史报告、发起付费模型任务或改变全平台验收范围。按用户要求，在保存和上传结果后停止原 Windows 服务与数据库并关机；上述安装和端点验证是关机前观测，不代表另一台机器已安装或服务始终在线。
