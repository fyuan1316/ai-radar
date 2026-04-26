# AI 系统论文周报 2026-04-26

窗口:2026-04-19 → 2026-04-26

## 本周精选

- **[FASER: Fine-Grained Phase Management for Speculative Decoding in Dynamic LLM Serving](https://arxiv.org/abs/2604.20503)** — 面向动态在线 LLM serving 的 speculative decoding 细粒度阶段管理。
  - 核心思路:现有 SD 系统通常用粗粒度策略决定是否启用 speculative decoding,FASER 把不同负载阶段拆开管理,适配在线请求的动态性。
  - 对我们的启示:推理平台不应只暴露“是否开启 speculative decoding”开关,而应按 workload 阶段、队列压力、接受率、latency SLO 自动切换策略。
- **[SparKV: Overhead-Aware KV Cache Loading for Efficient On-Device LLM Inference](https://arxiv.org/abs/2604.21231)** — 面向端侧 LLM 的 overhead-aware KV cache loading。
  - 核心思路:端侧硬件资源受限,prefill 构造 KV cache 成本高,SparKV 试图按开销感知方式加载/复用 KV。
  - 对我们的启示:KV cache 管理不只属于数据中心推理,端侧/边缘推理同样需要 cache 成本模型。我们的边缘推理能力应记录 cache 加载开销而不是只看模型权重大小。
- **[Scalable AI Inference: Performance Analysis and Optimization of AI Model Serving](https://arxiv.org/abs/2604.20420)** — 从部署和推理侧分析 AI model serving 的性能优化。
  - 核心思路:论文把研究视角从模型算法拉回 serving 性能,关注真实部署中的吞吐、延迟和优化因素。
  - 对我们的启示:产品 benchmark 要覆盖模型服务端到端路径:网关、runtime、batching、autoscaling、冷启动、存储和网络,而不是只测 engine tokens/s。
- **[Continuous Semantic Caching for Low-Cost LLM Serving](https://arxiv.org/abs/2604.20021)** — 面向低成本 LLM serving 的连续语义缓存。
  - 核心思路:通过复用语义相近请求的结果降低推理成本和延迟。
  - 对我们的启示:语义缓存适合作为企业知识问答/RAG 网关能力,但需要租户隔离、隐私边界和缓存命中解释,否则会带来数据泄漏风险。
- **[FEPLB: Exploiting Copy Engines for Nearly Free MoE Load Balancing in Distributed Training](https://arxiv.org/abs/2604.19654)** — 利用 copy engines 降低 MoE 分布式训练中细粒度负载均衡成本。
  - 核心思路:细粒度 per-micro-batch MoE load balancing 往往引入额外通信,FEPLB 尝试利用硬件 copy engine 隐藏成本。
  - 对我们的启示:MoE 训练/推理的瓶颈不仅是 GPU 算力,还包括通信和数据搬运引擎。容量评估器应显式考虑 copy/NVLink/RDMA 资源。

## 值得泛读

- [Cross-Session Threats in AI Agents](https://arxiv.org/abs/2604.21131) — 跨 session 攻击与 agent guardrails benchmark,适合放到 TrustyAI/Garak 路线里评估。
- [X-Cache: Cross-Chunk Block Caching for Few-Step Autoregressive World Models Inference](https://arxiv.org/abs/2604.20289) — world model inference 的跨 chunk cache,可作为 KV/cache 思路外延参考。
- [Forget, Then Recall: Learnable Compression and Selective Unfolding via Gist Sparse Attention](https://arxiv.org/abs/2604.20920) — 长上下文压缩/展开方向,与 KV cache selection/compression 有关联。
- [GRASPrune: Global Gating for Budgeted Structured Pruning of Large Language Models](https://arxiv.org/abs/2604.19398) — 面向服务成本的结构化剪枝,适合放进模型上线前优化链路。

## 趋势观察

- 本周 AI 系统论文集中在 **KV/cache、speculative decoding、serving 成本、MoE 数据搬运、安全评测**。这与工程侧 vLLM v0.20.0、KServe v0.18 rc、SGLang PD 分离方向高度同频。
- 论文信号和产品决策的映射很清晰:推理平台要从“部署模型”升级为“动态优化服务”。需要的产品旋钮包括 speculative decoding 策略、KV cache 放置、语义缓存隔离、MoE 通信/搬运观测、端到端 SLO。

## 原始材料

- [FASER](https://arxiv.org/abs/2604.20503)
- [SparKV](https://arxiv.org/abs/2604.21231)
- [Scalable AI Inference](https://arxiv.org/abs/2604.20420)
- [Continuous Semantic Caching](https://arxiv.org/abs/2604.20021)
- [FEPLB](https://arxiv.org/abs/2604.19654)
- [Cross-Session Threats in AI Agents](https://arxiv.org/abs/2604.21131)
