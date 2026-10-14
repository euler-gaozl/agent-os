# 原生模型能力的 Windows 发布检查

当前为安装候选，正式默认仍为 budget-v3。此文件记录可重复检查的边界，不代表真实研究已经验收。

## 服务与历史兼容

- Runtime 保留 v1/v2/v3，native-v4 使用完整的供应商能力快照；全旧 Agent 树回落固定 budget-v3，因此 Worker 必须同时保留该版本。
- Worker 发布包独立携带四份固定 Harness 和 Node，构建、备份、恢复均保留各自内容摘要；新协议不能覆盖旧任务使用的文件。
- Registry 声明 `agent-model-native-v1`，Console 在保存前向已绑定 Registry 探测，失败时不发送写入。Windows 发布器另核对声明、实际二进制、受保护配置和存活进程的绑定目标。
- Registry 的全部历史 Agent 版本均参与降级检查，不能只检查最新版本。停止 Registry 后，还要等待该数据库账号遗留会话退出，再用新事务快照检查迟到提交；异常、未知形状或权限不符时拒绝。
- 即使单独部署 Registry，也执行自身历史检查。新 Console 需要匹配的 Registry 和 Runtime；旧 Console 不允许读取已有原生 Agent 或原生任务。
- **回退旧 Console 前须先通过独立维护动作停止 Registry。** 仅停止中台不能阻止此前保存请求在 Registry 完成。发布器不会自动停止另一个服务；等写入结束后若存在原生 Agent，旧版回退仍被拒绝。无法安全恢复旧版本时保留 pending，不删除资料或伪造回退成功。

## 已执行证据

- Runtime 历史 Agent/子树、幂等重试、实际 Snapshot 展开长绑定提示词等：46 项、零跳过，真实隔离 PostgreSQL，vet/build 通过；`ops/native-legacy.path`。
- Registry/Console 能力鉴权、探测失败不保存及完整正文转发：37 / 30 项、零跳过；独立程序无需配置的声明探测通过；`ops/native-management.path`。
- 四版本安装策略与固定产物：107 项通过；`source-release-policy-5b480012fa4c47f28ae03f6650d06926`。
- native 默认切换：53 项真实 Windows 夹具进程和数据库检查，包含进程中断及恢复；正式 Runtime/双 Worker 已恢复，发布目录与 14 份配置指纹不变；`ops/native-default-managed.path`。模型管理守卫随后另行收紧，纯执行布局的提前返回语义保持不变。
- 模型管理发布保护：41 项通过；实际二进制声明、隔离 PostgreSQL/受限账号、合成资源表、零服务副本的正式维护入口。包含 Registry-only 历史检查、冷启动、回退、pending 恢复、迟到写入、客户端强杀后的延迟 COMMIT，以及元数据导出/还原；`ops/native-model-release.path`。
- 既有回执管理发布检查：41 项通过；`receipt-release-9fbb6e27c8e14584b73ddc0869599422`。

第一次模型管理外层 runner 误读 `pg_ctl status` 遗留退出码，虽然内部 30 项通过仍报告失败；该记录保留。修正 runner 并扩展检查后重新执行。独立评审指出的 Registry-only 跳过检查、旧 Console 迟到提交窗口及原始元数据数组展开均已修复，本轮后续复审以实际结论为准。

上述本机增量无付费模型请求、无 Actions。完整正式包安装、最新备份实际恢复、服务升级回退，以及同一真实期货任务的成稿质量仍需后续证据；Futures 业务端原有输入/回复容量也尚需对齐原生执行链，不能把 Console 的大消息验证外推为业务端已经完成。
