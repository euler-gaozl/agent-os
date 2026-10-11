# 检索引擎与 Embedding 选择

核验日期：2026-10-11。用户确认图谱方案指 LightRAG，向量库指 Milvus，业务交互参考 Manus。

## 决策

知识库是独立服务，中台统一配置，Agent 只绑定库版本。原文件与出处留在 PostgreSQL，远端图谱/向量索引是可重建的派生数据。三种引擎并存，不默认要求每份文件同时建图谱和向量。

| 引擎 | 首版用途 | 成本与限制 | 本项目证据 |
| --- | --- | --- | --- |
| local | 导入、原文回溯、字面关键词匹配 | 无 Embedding 费用；不能理解同义词或做语义排名 | 本机上传/检索实测 |
| Milvus | 中文长资料的语义检索 | 需要 Milvus 和 Embedding 推理服务；还需调分片/召回 | REST 适配及模拟协议验证，未实机运行 |
| LightRAG | 跨文档实体与关系查询 | 需要生成模型、Embedding、抽取和索引；图谱可能含抽取误差 | 异步导入/状态/查询适配及模拟验证，未实机运行 |

Milvus 适配采用 REST v2.6、字符串主键、稳定 chunk id、COSINE 距离与 upsert。LightRAG 使用服务接口查询图谱与上下文，再由当前 Agent 回答，避免默认另起一层答案生成器。其源码主要是 Python，作为可选外部服务使用；项目 Runtime、ToolHub、Knowledge 和业务代码是 Go/TypeScript。[Milvus Create](https://milvus.io/api-reference/restful/v2.6.x/v2/Collection%20(v2)/Create.md)、[Upsert](https://milvus.io/api-reference/restful/v2.6.x/v2/Vector%20(v2)/Upsert.md)、[Search](https://milvus.io/api-reference/restful/v2.6.x/v2/Vector%20(v2)/Search.md)、[LightRAG 官方仓库](https://github.com/HKUDS/LightRAG)、[API Server 文档](https://github.com/HKUDS/LightRAG/blob/main/docs/LightRAG-API-Server.md)。

## Embedding 候选

中台提供可编辑配置，不把模型名写死在服务中：base URL、model、credential name、dimensions、query prefix。

- **Qwen3-Embedding-0.6B**：作为轻量中文/多语言候选，默认完整维度 1024。模型卡提供查询 instruction 用法；可在 query prefix 配置检索任务说明。0.6B/4B/8B 不能混用同一索引，升级模型须重建并评估。[官方模型卡](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)
- **BGE-M3**：多语言候选，dense 维度 1024。模型还支持 sparse / multi-vector，但本项目当前只接 dense embedding，不声称已实现其混合检索能力。[官方模型卡](https://huggingface.co/BAAI/bge-m3)

这些是候选和界面预设，没有下载模型、启动推理服务或比较本机性能。Qwen 0.6B 的选择基于模型规模与多语言定位，属于工程初选，不是“最适合期货”的实测结论。Embedding API 必须实际符合 OpenAI-style `/embeddings`；网关模型别名需要和配置一致。

## 上线验收方法

选择真实中文研究资料，人工标注至少一组包含实体别名、时间修订、单位差异、样本范围变化及跨文档问题的检索目标。固定原始文件版本，对比关键词、dense 和图谱检索的 Recall@k、证据来源准确率、日期/口径误匹配、p50/p95 延迟、索引成本和内存。保留错误样本，不用生成答案的流畅程度代替召回正确性。该评估尚未执行。

对期货研究，原始实绩、计划、第三方预测和统计口径必须保留在资料与业务事实层；Embedding 相似度和图谱关系都不能自动证明事实已校验，更不能据此给出价格预测。
