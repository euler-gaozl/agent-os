# 检索引擎与 Embedding 选择

核验日期：2026-10-11。用户确认图谱方案指 LightRAG，向量库指 Milvus，业务交互参考 Manus。

## 决策

知识库是独立服务，中台统一配置，Agent 只绑定库版本。原文件与出处留在 PostgreSQL，远端图谱/向量索引是可重建的派生数据。三种引擎并存，不默认要求每份文件同时建图谱和向量。

| 引擎 | 首版用途 | 成本与限制 | 本项目证据 |
| --- | --- | --- | --- |
| local | 导入、原文回溯、字面关键词匹配 | 无 Embedding 费用；不能理解同义词或做语义排名 | 本机上传/检索实测 |
| Milvus | 中文长资料的语义检索 | 需要 Milvus 和 Embedding 推理服务；还需调分片/召回 | v2.6.24 真实容器：索引、查询、来源/版本隔离、写后丢失回执恢复、重启持久化通过；本次向量为夹具 |
| LightRAG | 跨文档实体与关系查询 | 需要生成模型、Embedding、抽取和索引；图谱可能含抽取误差 | v1.5.7 真实容器：异步导入、跟踪、图谱/片段查询、本地原文归属通过；本次 LLM/Embedding 为夹具 |

Milvus 适配采用 REST v2.6、字符串主键、稳定 chunk id、COSINE 距离与 upsert。LightRAG 使用服务接口查询图谱与上下文，再由当前 Agent 回答，避免默认另起一层答案生成器。其源码主要是 Python，作为可选外部服务使用；项目 Runtime、ToolHub、Knowledge 和业务代码是 Go/TypeScript。[Milvus Create](https://milvus.io/api-reference/restful/v2.6.x/v2/Collection%20(v2)/Create.md)、[Upsert](https://milvus.io/api-reference/restful/v2.6.x/v2/Vector%20(v2)/Upsert.md)、[Search](https://milvus.io/api-reference/restful/v2.6.x/v2/Vector%20(v2)/Search.md)、[LightRAG 官方仓库](https://github.com/HKUDS/LightRAG)、[API Server 文档](https://github.com/HKUDS/LightRAG/blob/main/docs/LightRAG-API-Server.md)。

LightRAG v1.5.7 的 WORKSPACE 是服务实例配置，不是本适配器可逐请求切换的 namespace。不同知识库版本应使用隔离的上游 workspace/endpoint，避免实体抽取在远端混合来源。即使部署配置错误，Knowledge 仍逐条核对返回材料的本地文件归属，拒绝跨版本来源、混合来源条目和不在原文中的文本片段；无法证明归属的结果不会传给模型。这个校验不能证明外部服务可信或图谱抽取正确，实体/关系仍为待原文核验的抽取结论。[固定版本环境配置](https://github.com/HKUDS/LightRAG/blob/v1.5.7/env.example)、[查询协议](https://github.com/HKUDS/LightRAG/blob/v1.5.7/lightrag/api/routers/query_routes.py)。

## Embedding 候选

真实检索后端证据来自 [CI 38153838660](https://github.com/euler-gaozl/agent-os/actions/runs/38153838660)，本地副本 `.state/rag-live-b5200e5/`。模型推理和领域召回不能由协议夹具代替。下一项使用官方 Qwen3-Embedding-0.6B Q8_0 GGUF 实际 CPU 推理，固定模型 revision `370f27d7550e0def9b39c1f16d3fbaa13aa67728`、校验权重 SHA-256、固定 llama.cpp 容器 digest；先检查四份中文人工测试材料，不能将小样本写成模型优劣结论。

中台提供可编辑配置，不把模型名写死在服务中：base URL、model、credential name、dimensions、query prefix。

- **Qwen3-Embedding-0.6B**：作为轻量中文/多语言候选，默认完整维度 1024。模型卡提供查询 instruction 用法；可在 query prefix 配置检索任务说明。0.6B/4B/8B 不能混用同一索引，升级模型须重建并评估。[官方模型卡](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B)
- **BGE-M3**：多语言候选，dense 维度 1024。模型还支持 sparse / multi-vector，但本项目当前只接 dense embedding，不声称已实现其混合检索能力。[官方模型卡](https://huggingface.co/BAAI/bge-m3)

Qwen 0.6B 已在 [CI 38154474531](https://github.com/euler-gaozl/agent-os/actions/runs/38154474531) 使用真实 Q8_0 权重和 CPU 推理联调：四份中文测试原文上传至 Milvus，四个预先标注问题均 top-1 命中对应原文；索引总计 3.77 秒，单次查询 0.82–0.88 秒。此为四样本功能检查，没有和 BGE-M3 对比，也不是“最适合期货”的实测结论。模型/容器资源单独计量，本机 Windows 尚未安装这个推理后端。Embedding API 必须实际符合 OpenAI-style `/embeddings`；网关模型别名需要和配置一致。

## 上线验收方法

选择真实中文研究资料，人工标注至少一组包含实体别名、时间修订、单位差异、样本范围变化及跨文档问题的检索目标。固定原始文件版本，对比关键词、dense 和图谱检索的 Recall@k、证据来源准确率、日期/口径误匹配、p50/p95 延迟、索引成本和内存。保留错误样本，不用生成答案的流畅程度代替召回正确性。该评估尚未执行。

对期货研究，原始实绩、计划、第三方预测和统计口径必须保留在资料与业务事实层；Embedding 相似度和图谱关系都不能自动证明事实已校验，更不能据此给出价格预测。
