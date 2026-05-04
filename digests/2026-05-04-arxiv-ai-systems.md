# AI 系统论文周报 2026-05-04

窗口:2026-04-27 → 2026-05-04(7 天)
来源:arxiv API (cs.DC / cs.LG / cs.PF / cs.AR + LLM serving / GPU sched / KV cache 等关键词)

## 本周精选(5 篇)

- **[SAGA: Workflow-Atomic Scheduling for AI Agent Inference on GPU Clusters](http://arxiv.org/abs/2605.00528v1)** — 把 agent workflow 整体作为调度单位
  - 核心思路:作者观察到 GPU scheduler 把 agent 的每次 LLM 调用当作独立请求,导致每步丢弃 GB 级中间状态,端到端时延膨胀 3-8×;提出"程序级调度"(program-level scheduling),把整个 agent workflow 当作一等公民调度对象
  - 对我们的启示:OAI / KServe / Ray Serve 的调度抽象都还是请求级的;若我们做 agent-aware 推理平台,workflow-level scheduling 是一条可设计的差异化路径,与 Pythia(下条)是同一思想的两个实现
  - 关键数据点:相比 baseline 端到端时延降低 3-8×

- **[Pythia: Toward Predictability-Driven Agent-Native LLM Serving](http://arxiv.org/abs/2604.25899v1)** — agent-native 多智能体推理服务系统
  - 核心思路:基于一个 agent 服务平台 + 内部 coding assistant 的生产 trace 分析,识别出 prefix cache 命中率低、长上下文资源争用、scaling 不当导致排队。系统通过简单接口在 serving 层捕获 workflow 语义,以此优化吞吐与 JCT
  - 对我们的启示:Pythia 与 SAGA 同一周提交,印证"agent-aware serving"是新研究主轴;关键设计抓手是"workflow 接口在 serving 层暴露语义",这与 KServe llmisvc 当前 API 抽象差距明显;设计自家 LLM serving API 时要给 agent workflow 留接入点
  - 关键数据点:相比 SOTA baseline 在吞吐与 JCT 上有显著提升(论文摘要未给具体倍率)

- **[CacheFlow: Efficient LLM Serving with 3D-Parallel KV Cache Restoration](http://arxiv.org/abs/2604.25080v1)** — KV cache 跨 token / 层 / 分布式多源的并行恢复
  - 核心思路:将 KV cache restoration 视为多轮对话 / RAG / agent pipeline 的核心瓶颈;现有方法在"重算 vs IO 传输"二选一里做单点权衡,CacheFlow 跨 token、层、分布式来源做 3D 并行恢复
  - 对我们的启示:llm-d / hermes-router / Dynamo 现在的 KV cache pool 主要解决"远端获取 vs 本地命中",但实际并行恢复仍是单线程;若我们做长上下文 / 多轮服务,CacheFlow 的 3D 并行思路值得在自家 KVCache 路由层试做 PoC
  - 关键数据点:论文摘要未具体给出加速倍率,但定位为"打破现有 restoration 的瓶颈"

- **[PolyKV: A Shared Asymmetrically-Compressed KV Cache Pool for Multi-Agent LLM Inference](http://arxiv.org/abs/2604.24971v1)** — 多 agent 共享 KV cache 池
  - 核心思路:多个 agent 并发推理时,不再每 agent 独立 KV cache,而是写入一次"非对称压缩"池(Keys 走 int8 q8_0 保留 softmax 稳定性,Values 走 TurboQuant MSE 即 Fast Walsh-Hadamard),通过 HuggingFace DynamicCache 注入到 N 个独立 agent context
  - 对我们的启示:与 vLLM v0.20.0 的 TurboQuant 2-bit KV cache 是同一技术血脉;在多 agent / 多租户场景,共享 pool 可以把 KV 容量再放大若干倍;hermes-router(OpenFuyao)/ llm-d 路由层下一步要做的就是这个;直接的产品化机会
  - 关键数据点:Keys int8、Values TurboQuant MSE 压缩;共享池替代 per-agent allocation

- **[LLM-Emu: Native Runtime Emulation of LLM Inference via Profile-Driven Sampling](http://arxiv.org/abs/2605.00616v1)** — vLLM 的"无 GPU"原生 emulator
  - 核心思路:保留 vLLM 真实生产路径(HTTP / scheduling / KV-cache / output processing),只把 GPU forward 替换成基于 profile 的延迟采样 + 合成 token
  - 对我们的启示:做 LLM serving 系统时,容量规划、调度参数调优、突发流量演练都需要 GPU 测试床,昂贵且排期长;LLM-Emu 把这一步去 GPU 化,对我们做 SLO 演练 / 排队策略验证 / 多 ServingRuntime 对比有直接价值;开源(github.com/AKafakA/llm-emu),可立刻试用
  - 关键数据点:TPOT/ITL 误差 <4.8%、E2E 延迟误差 <5.3%、吞吐误差 <1.9%、TTFT 误差 <10.4%

## 值得泛读(~10 篇)

- [Unifying Sparse Attention with Hierarchical Memory for Scalable Long-Context LLM Serving](http://arxiv.org/abs/2604.26837v1) — 不同稀疏注意力方法的统一抽象层,KV 跨 GPU/CPU 内存层级
- [DAK: Direct-Access-Enabled GPU Memory Offloading with Optimal Efficiency for LLM Inference](http://arxiv.org/abs/2604.26074v1) — GPU 直接访问远端内存,避开 prefetch + HBM 争用
- [DUAL-BLADE: Dual-Path NVMe-Direct KV-Cache Offloading for Edge LLM Inference](http://arxiv.org/abs/2604.26557v1) — 边缘场景 KV 通过 NVMe 直读,绕过 page cache 抖动
- [Rethinking KV Cache Eviction via a Unified Information-Theoretic Objective](http://arxiv.org/abs/2604.25975v1) — 用信息瓶颈给 KV eviction 一个理论闭式解
- [Folding Tensor and Sequence Parallelism for Memory-Efficient Transformer Training & Inference](http://arxiv.org/abs/2604.26294v1) — TP+SP 折叠到单个 device 维度,降低 layout 复杂度
- [AutoSP: Unlocking Long-Context LLM Training Via Compiler-Based Sequence Parallelism](http://arxiv.org/abs/2604.27089v1) — 编译器自动选择 SP 策略
- [Efficient Training on Multiple Consumer GPUs with RoundPipe](http://arxiv.org/abs/2604.27085v1) — 解决 PP weight binding 不均的 schedule
- [TACO: Efficient Communication Compression of Intermediate Tensors for Scalable Tensor-Parallel LLM Training](http://arxiv.org/abs/2604.24088v1) — FP8 压缩 TP 中间张量
- [CommFuse: Hiding Tail Latency via Communication Decomposition and Fusion for Distributed LLM Training](http://arxiv.org/abs/2604.24013v2) — 通信分解 + 融合解决 overlap 长尾
- [ZipCCL: Efficient Lossless Data Compression of Communication Collectives for Accelerating LLM Training](http://arxiv.org/abs/2604.27844v1) — 训练 collective 通信的无损压缩
- [Accelerating RL Post-Training Rollouts via System-Integrated Speculative Decoding](http://arxiv.org/abs/2604.26779v1) — speculative decoding 用到 RL 后训练 rollout
- [SpecFed: Accelerating Federated LLM Inference with Speculative Decoding and Compressed Transmission](http://arxiv.org/abs/2604.25777v1) — 联邦推理的投机解码

## 趋势观察

- **agent-native serving 集中爆发**:SAGA + Pythia + PolyKV 同周三篇,主题统一为"agent workflow 是新一类 serving primitive";与生态侧的 Kueue agent skills、Feast agent skills、garak v0.15 Agent Breaker probe 完全同步,说明从底层调度到上层评测都开始把 agent workload 当一等公民;这是 cloud-native AI 基础设施的下一个分歧点
- **KV cache 仍是核心战场**:本周 KV 主题论文 ≥7 篇,从压缩(PolyKV / TurboQuant)→ 跨设备恢复(CacheFlow / DAK / DUAL-BLADE)→ eviction 理论(Information Bottleneck)→ 边缘卸载(DUAL-BLADE / NVLLM)全覆盖,与 vLLM v0.20.0 的 TurboQuant 路径形成上下游
- **训练侧通信瓶颈在被多角度切**:ZipCCL / TACO / CommFuse 同周登场,分别走"无损压缩"、"FP8 中间张量"、"通信分解+融合"三条路;若我们做训练 / 微调平台,通信优化"已经不是 NCCL/NVLink 单一答案"
- **专用硬件论文(AMMA / NVLLM / VitaLLM / Salca)继续多发**:这些是芯片设计层面的 KV / attention 加速,与我们 K8s 上层产品基本无直接接口,可忽略
