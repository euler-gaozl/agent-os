# 研究成稿轮次：Mac 离线候选

环境：`environment:maintainer-macos`。本增量基于公开源码和新建合成 Agent 夹具，不读取原 Windows 的草稿、任务或配置。交接记录中的 revision 17 / Skill 6 / 12 次失败是原维护者历史观测，没有在 Mac 复现该任务。

## 源码定位与最小改动

- Runtime `internal/runstate/harness.go` 每次 `model` 请求增加 `Step`，包括 Compact；`model_budget.go` 根据根任务快照统计真实模型尝试（含重试），通过同一家族锁预留。两种计数不能混为工具调用数。
- Futures `futures/report.go:reportInstructions` 要求至多两次检查及逐字最终稿，但没有具体成稿截止。集成 `packs/futures/research-reading.md` 原先也只有笼统预留要求。仅提高请求上限不能纠正十轮浏览后才开始送检的安排。
- 旧种子包是 `max_steps=12/max_model_attempts=40`，不是历史运行 revision 17 的 `12/12`，也不是本机安装状态。本次不改种子 Agent 上限、不改 Runtime/Worker/Harness、固定引擎或历史快照。

`scripts/prepare-research-agent.mjs` 从明确的、含 revision 的 Agent 资源生成离线候选，仅追加静态约束，保留全部模型参数、额度、发布设置、工具以及 Skill/MCP/知识库的精确绑定。输入不得是无版本种子或任务记录；只支持无子任务的研究 Agent，以免把家族额度当成本 Agent 独占额度。原有计划拒绝叠加，额度不足拒绝生成，不自动放大。

以合成的 12/12 为例，规划普通生成至多十轮：前六轮集中取证，第七轮完整首次送检，第八轮定向回查，第九轮修订后最后送检，第十轮逐字最终输出；保留两次 Compact/重试余量。一次模型回复可以包含多个独立读取工具，工具执行本身不会凭空获得新的模型轮次。任一阶段可提前结束，不用满两次检查。未取得的证据与未解决的反馈如实保留。

这是**静态提示策略，不是执行器强制配额或动态剩余预算**。模型可能不遵守计划，Compact/重试可能超过预留，旧 token 配额也可能更早耗尽。生成器不证明检查器已绑定或健康，不保证最后送检与最终输出一致。不得把夹具通过写成研究成稿问题关闭；真实有界模型和业务质量仍待验证。若后续需要动态计数，应另设计随模型意图冻结的版本化协议及恢复测试，不能重放时按当前值重写历史请求。

## 准备、固定及验证

1. 从当前 Mac 自己的 Registry 选择明确 Agent revision，保存其资源 JSON 到 `local`。若需新方法 Skill，先通过正常资源登记取得新 Skill revision，再明确绑定并重新读取 Agent；生成器不会猜“最新”版本。
2. 离线执行（输出目录必须不存在）：

   ```sh
   node scripts/prepare-research-agent.mjs /absolute/local/exact-agent.json /absolute/local/new-candidate
   node --test scripts/prepare-research-agent.test.mjs
   ```

3. 审阅 `agent.json` 与 `plan.json`：后者记录源 ID/revision、源和候选 spec 的 `JSON.stringify` 字节 SHA-256、原预算及阶段安排。输出 Agent **不含 revision**；它仅是 Registry 新建版本的请求，绝不能伪装成已登记版本。
4. 在本机正常登记为新 Agent revision 后，核对返回 spec、原 revision 未变、精确绑定未漂移；使用新 revision 创建全新任务，保持旧任务原快照及状态。检查工具是否存在/健康需另行核对；未绑定不得声称送检通过。离线工具不会发 HTTP、登记资源、创建或恢复任务。
5. 在后续最小真实验证中记录精确 Agent/Skill/MCP/引擎版本、完整 usage（含 unknown）、普通生成/Compact/重试与工具调用的分开计数、最终文本和最后送检 draft 的哈希，以及未解决的内容质量问题。无当前开发环境凭证时继续夹具，不寻找原电脑密钥。

本测试只证明候选转换不改原资源、保持精确绑定与额度、安排不会越过两个固定次数上限、拒绝有歧义输入且不覆盖文件。不验证 Registry 的实际登记、任务执行、模型行为、来源真实性、Windows 发布/DPAPI/备份恢复。新的 Mac 证据应单独保存，历史 Windows 记录保持原样。
