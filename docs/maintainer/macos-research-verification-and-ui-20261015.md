# Mac 同题研究验证与 UI 增量（2026-10-15）

环境：维护者独立 macOS 15.3（24D2059）/arm64，Node 24.19.0。第四次新合成研究任务在首次供应商请求 HTTP 503 后失败，没有成稿，当前成稿方法的内容效果仍未验证。它不是原 Windows 私有任务复现。既有 [Runtime Owner ENOSPC](macos-runtime-enospc-20261015.md)、[前三次研究与完整包记录](macos-package-enospc-and-answer-contract-20261015.md) 和历史失败均保留。

## 同题新任务与独立结论

任务 `cfdb8e0a8232bf786a194264cb0bb584` 于 02:13:29.657916 UTC 创建；仍使用原三份本机合成资料、原四问、Agent revision 4 / Skill revision 3、固定 native-v4 引擎、12 步/12 次模型尝试预算；模型上下文 1048576、输出 393216 保持既有配置。实际运行 Futures 源码为 `b805fa9e09ad8c1ecf3feb4ae7c74e77a41029ed`，二进制/匹配 Web 包沿用此前已安装版本，没有为此次调用改预算、换资料或重写旧任务。

原始 native-provider 回执为 HTTP 503、`service_unavailable_error`，消息为 `Service is too busy.`。终态 failed、step=1、result 为空，模型回执 1，工具调用/送检草稿 0。v5 的 unstructured/JSON 未结束来自空结果，不是模型生成了错误 JSON；report_quality_passed=null、六项内容判据均无法评价，不能把执行或格式字段当作内容通过。本轮没有自动重试、同 key reconciliation 或第二个新任务，也没有再发模型。

本次 attempts=1、unknown_usage_attempts=1、max_attempts=12；prompt/completion/cached 的 0 是未取得测量值，accounted_tokens=433491 是保守未知预留，不是实耗或账单。四次 Mac 任务累计 11 attempts：前两次 9 次请求有返回 usage，合计 161007 tokens；后两次各 1 次未知、各预留 433491，必须分列，不能混加为真实消耗。费用仍为 null。

## 提交前判据与来源保护

独立验收判据在 02:04:51.297 UTC 固定，早于 provenance 02:13:29.507、submission-intent 02:13:29.652 与任务创建。它只作事后人工验收：直接回答 q1 方向、差额继续待核、q2/q3 不制造非阻断 missing、q4 保留真实勾稽缺口、限制有据、执行/格式/内容分开。判据未进入模型输入；新 submission body、完整 task/snapshot/constraints 与第三次固定版本相同，首次请求的 task/Skill 与 canonical hash 已独立重算。

三个旧任务的完整 run/calls/usage/result 在 before/pre-submit/after 深等，并与原归档重算 hash 相同。第一次格式失败、第二次格式已接受但内容失败、第三次 503 无稿结论均未覆写。

| 关键记录 | SHA-256 |
|---|---|
| 提交前六项内容判据 | `0e0ed88239183f607f90a840143f698fb1d893847bacd4ef360dc4848c94a969` |
| 实际执行 helper | `d551520597d6048c29700bb1be1292b27b1925a0c45163832db1bcbd25cab754` |
| 冻结 task | `297b6e26fc57c92fc35a0093788130b7dbce01f2d6aa8c8be8633a929c4daf59` |
| 首次请求 canonical JSON | `ae98a94365c3e16be1f89aa451d9a6f1547ae3ce897aa12059b47ba5fac85b0b` |
| 独立终态复核 | `09891dbfde37be064caeaec6d103df69c677e3f9796f1ed6ce6dbd507474b2e8` |

证据在 `local/evidence/macos-research-live-20261015-answer-contract-verification/`：submission-intent、pre-submit-provenance、frozen-instructions、final-*、old-tasks-* 和 audit-summary 相互对应；原始资料、配置、密钥和整份回执不提交。独立检查只读既有证据，无额外 API/模型调用。helper 独立静态审查发现无效私有 JSON 的 parser message 可能泄露输入前缀；执行前已改固定错误出口，并用合成字符串复核，不读取真实配置作测试。

## 任务读取 UI 与匹配包安装

Futures 提交 `f5e7bd21b8f3fcf20bc69c84aee2eede7bf5d2c4` 增加详情 GET 失败提示和只读“重新读取”，同任务已有内容继续显示并标记为上次读回；只有成功 GET 才消除提示。切换任务或离开页面后迟到响应不能覆盖新选择；失败任务的精确 model HTTP 503 显示服务暂不可用、任务已停止，未承诺自动模型重试或费用已知。

独立静态评审曾发现手动重读提前清除旧内容提示，已用实际 reducer/watcher 修复，保留 1 项 red 与修复后新增 8 项 green；它是受控状态回归，非浏览器故障复现。根代理在实际仓库验证 23 项 Web 测试、0 失败/0 skip、TypeScript 和 Vite build 通过；Go 未改，没有重复旧 Go suite。日志位于 `local/evidence/macos-research-read-ui-increment-20261015/root-web-{tests,build}.log`。独立 UI 复核 SHA 为 `dc4965f7dbfc12c91108690cfab454b78c212899344a7c82fdc80beb150b5b78`。

随后从固定 clean commit 的 archive 用 Go 1.27.2、Node 24.19.0/pnpm 锁文件离线构建匹配 BFF/Web，02:22:25.368 UTC 只替换 Futures，自有新 PID 10876 的鉴权 ready 为 200。9 个非目标实例保持不变，含 Console 未重启；终态任务集合未变，安装没有 provider 调用或任务提交。后端二进制与旧包相同，Web 树更新。源码提交、匹配包安装与浏览器验收分开记录：浏览器仍未执行。

| 包来源 | SHA-256 |
|---|---|
| 完整包 manifest | `e97f4d39fd42b72e9e1ee026b434866b49340d464a61ddb732caf7fc9369cb23` |
| Futures 二进制（与旧包相同） | `18b4be2c7a04b77dc6d547e833412b58ea1261110bda1c3e12e7e51570c71ca2` |
| Futures Web tree | `8effbad604254df4930d1c444d6098e690729f7f88d1cfae6b1a53cddd4db1e5` |

原始 prepare/installed 记录在 `local/evidence/mac-bff-package-20261015-task-read-state/`。安装 helper 独立静态评审后仅固定最终 commit 再执行，执行版 SHA 为 `37b5e15feffea6ea29f465d320bdd29bb0da2fbd8dcd272bc44811d22b1aa1dc`；失败恢复路径未被这次成功安装动态触发。配置、token、私有 rollback 文件不进入知识库。根代理另以文件/ps/lsof 只读核对新进程身份、loopback 监听及 9 个非目标实例前后相同，记录在 `local/evidence/macos-research-read-ui-increment-20261015/independent-install-observation.json`；该核对没有额外 HTTP、模型或页面操作。

## 仍开放的工作

研究方向答复、逐问 missing、引用/日期/口径及完整成稿仍待有报告的新任务按固定判据验证；无稿不降低标准。本轮不再发模型。真实浏览器 W03/W04/W05/W13、完整 P0–P5/P2.5 与 W01–W14、服务退役、存储生命周期和剩余资源故障范围均不关闭。Windows DPAPI、受管发布、原库恢复和原任务只能在目标环境单独复验。没有推送或运行 Actions；原 Windows 历史、此前 Mac 记录和集成 pins 未改。
