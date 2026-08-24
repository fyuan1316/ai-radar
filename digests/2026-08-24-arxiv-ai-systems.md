# AI 系统论文周报 2026-08-24

> 数据源:arxiv(cs.DC / cs.LG / cs.PF),覆盖过去 7 天(约 2026-08-17 ~ 08-24)提交、面向 AI 基础设施/系统方向的论文。
> 说明:本期 `export.arxiv.org` API 全程 429(Rate exceeded),改走 arxiv.org 搜索/摘要页(WebFetch)按提交时间倒序抓取;arxiv 有公告延迟,当前已公告的最新批次到 ~08-20,08-21~24 的提交多数尚未进入公告队列。精选论文均已通读 abstract(含方法/实验数据),非仅看标题。

## 本周精选(4 篇)

- **[Beyond Binary Priorities: Multi-Tier SLA Scheduling for LLM Serving](https://arxiv.org/abs/2608.16336)** — 把 Llumnix 只有"高/普通"两档的优先级模型扩成任意多档 SLA 分级调度。
  - 核心思路:在 Llumnix 统一的 "freeness" 迁移调度框架上增加 per-tier headroom(带指数衰减的每档预留)+ tier-aware 派发排序,并把整条迁移流水线接进 Vidur 分层调度里;支持 1~10 档优先级不崩。
  - 对我们的启示:这正是多租户 LLM 平台"两档不够用"的痛点——生产上要区分交互式 API、内部批处理、免费/付费租户等多级 SLO。实验里"4 档"是成本-效果最佳点,可以直接作为我们产品优先级模型的默认档位设计;headroom 预留机制值得抄进我们的 GPU 排队/准入层。
  - 关键数据点:prefill 相比 INFaaS 最高 8.3x,端到端 P99 最高 3.1x,单位延迟成本改善 46%~68%;对比基线含 vLLM/Orca/Sarathi-Serve。

- **[Pallas: Proactive KV Cache Migration Framework for LLM Inference in AI-RAN](https://arxiv.org/abs/2608.16477)** — 面向"推理实例会漂移"的场景,在切换发生前把 KV cache 提前搬到目标节点。
  - 核心思路:触发预备时把 token 序列切成"稳定历史前缀"+"演进后缀";目标节点本地 prefill 重建前缀,源节点流式推送后缀的 KV blocks;切换瞬间目标端拼装成最新 KV cache 继续解码。一个在线调度器按移动性预测+运行时遥测决定 prefetch 窗口(提前量)。
  - 对我们的启示:虽然论文背景是蜂窝 AI-RAN 基站切换,但"前缀本地重算 + 后缀增量传输"的拆分,对我们做实例调度/故障迁移/弹性缩扩容时的 KV cache 搬迁是通用范式——能显著压低迁移期的服务中断,比"整块传 KV"或"到目标端再重算"都强。可作为我们 serving 层做 live migration / 无损缩容的设计参考。
  - 关键数据点:基于 vLLM 原型,3 个 LLM、100~500 Mbps 互联链路下,平均服务中断时间(SIT)比"目标端恢复"快 2.28x~89.68x,平均 inter-token latency(ITL)比"源端转发"低 16%~50%。

- **[FlashPrefill V2: Block-Sparse Prefill Attention for Long-Context LLM Serving](https://arxiv.org/abs/2608.19758)** — 把上一代 FlashPrefill 从算法原型推进到"能进生产 serving"的稀疏 prefill 注意力后端。
  - 核心思路:三条改进——(1)加 mean correction 项抑制近似误差,极端稀疏下也能控住精度掉点;(2)算子按 FlashAttention-3/4 重写(PackGQA 访存、warp specialization、pingpong 流水),支持 FP8;(3)原生支持 paged KV cache + continuous batching,可直接作为 SGLang 等框架的 attention backend。
  - 对我们的启示:长上下文 prefill 是我们 serving 成本的大头,这篇给出的"稀疏 prefill 算子 + 原生兼容 paged KV/连续批处理"路线,意味着可以在不改上层调度的前提下换 attention backend 拿到长文收益。值得在我们基于 vLLM/SGLang 的推理栈上做一次长上下文(128K)的 backend 替换评测。
  - 关键数据点:H20、128K 上下文下,FP8 相比 FlashAttention-2 提速 47.26x,BF16 提速 27.19x,相比对齐 FA3/4 的 dense 基线(FP8)提速 30.49x。

- **[Pre-Compiled Pipeline Shards for Distributed LLM Inference on Intel AI PC Fleets](https://arxiv.org/abs/2608.19147)** — 用一小撮联网的 Intel AI PC(闲置算力)拼出单机放不下的大模型推理。
  - 核心思路:按层切分做 pipeline parallelism,每个 stage 预编译成 OpenVINO 图,每台机器跑一个 shard 传激活。三招提速:(1)往每个 shard 注入 beam_idx Gather 触发 OpenVINO 的 IndirectKVCache fusion,把分片速度拉回单体水平;(2)在 stateful OpenVINO 模型上做 speculative decoding;(3)跨 stage 交错多用户请求做 micro-batching。
  - 对我们的启示:这是"边缘异构算力池化"的一个具体样本——对我们做私有化/边缘部署、把闲置 NPU/iGPU 组成推理集群有直接参考价值;"预编译分片 + 微批交错"能在不靠高端 GPU 的前提下跑起 70B。可关注其 pipeline 切分与激活传输在广域网延迟下的退化曲线。
  - 关键数据点:两节点 Llama 3.1 8B INT4 服务 2 个并发用户,吞吐是单用户不切分的 1.79x;四节点 Lunar Lake(Intel Tiber Cloud)可服务单机放不下的 70B 达到交互速度,且输出与非投机解码逐 token 一致。

## 值得泛读(6 篇)

- [CoRun: Padding is Simple and Efficient for Deterministic LLM Inference](https://arxiv.org/abs/2608.14376)(08-14)— 靠位置无关 kernel + 固定 shape 批处理实现确定性推理,对复现性/合规评测有用。
- [Collective Communication for Distributed LLM Systems: Planning, Runtime Adaptation, and Computation Coordination](https://arxiv.org/abs/2608.15118)(08-15)— AllReduce/ReduceScatter/AllGather 的规划与运行时自适应,训练/serving 集群通信优化。
- [Flama: Python framework for production APIs, ML, and LLM services](https://arxiv.org/abs/2608.18733)(08-19)— 多后端(vLLM / MLX)LLM 服务框架,支持多种 wire protocol,工程落地向。
- [OpRAG: A Resource-Deterministic Runtime for GPU-Backed Multi-Stage RAG Workflows](https://arxiv.org/abs/2608.08340)(08-08)— 把 embedding/检索/生成三段做确定性调度编排的 RAG 运行时,对标我们 RAG 系统化方向。
- [OasisKV: Scaling In-Decode KV Cache Beyond HBM with Lookahead Sparse Prefetching](https://arxiv.org/abs/2608.08097)(08-08)— KV cache 溢出 HBM,用前瞻稀疏预取扩容,dense vLLM 上 1.69x。
- [ElastiCo: Elastic Configuration and Interference-Aware Orchestration for GPU Clusters](https://arxiv.org/abs/2608.07971)(08-08)— 训练/推理共置的干扰预测与弹性编排,和我们 GPU 复用/超卖直接相关。

## 趋势观察

- 本期是本 task 首期,暂无上周基线对比;以下为本周(截至已公告的 ~08-20 批次)横向观察。
- **调度层"细粒度化"是最集中的方向**:Multi-Tier SLA(2608.16336)、确定性推理 CoRun(2608.14376)、干扰感知共置 ElastiCo(2608.07971)都在把"粗粒度分档/尽力而为"往"多级 SLO + 可预测/可复现"推——生产化信号很强,和我们做多租户 QoS/超卖治理的路线高度重合。
- **KV cache 成为"可迁移/可扩展的一等资源"**:Pallas 做迁移(2608.16477)、OasisKV 做溢出扩容(2608.08097)、FlashPrefill V2 原生 paged KV(2608.19758)——KV 不再只是显存里的临时状态,而是被当作要搬、要分层、要预取的对象来系统化管理。
- **异构/边缘算力池化在升温**:Intel AI PC 分片(2608.19147)、AI-RAN 基站侧推理(2608.16477)都在探索"非数据中心 GPU"的推理组网,对私有化/边缘部署有参考。
- **口径提示**:因 arxiv API 限流 + 公告延迟,08-21~08-24 提交的论文多数尚未进入公告队列,下期(约 08-31)会自动回补这批;本期未见对 vLLM/SGLang 直接做端到端性能剖析的独立评测论文,多为可插入现有栈的组件级改进。
