# AI 系统论文周报 2026-07-27

> 覆盖窗口:约 2026-07-20 ~ 07-27,arxiv cs.DC / cs.LG / cs.PF。
> 数据源:arxiv API(本次 IP 被限流,主用 arxiv recent listing + WebSearch 补漏);精选论文均读过 abstract/intro/experiments 再落笔。

## 本周精选(5 篇)

- **[Cold-Start Model Delivery in Kubernetes Inference Serving: An Empirical Study of OCI-Based Distribution and Its Integrity](https://arxiv.org/abs/2607.16596)** — 把"下发模型权重"这件事从对象存储裸下载,升级成 K8s 原生的 OCI 镜像分发(带 pull 缓存 + 摘要寻址 + 校验)。
  - 核心思路:在 KServe 里落两条新下发路径——`oci+native://`(用 K8s image volume / KEP-4639 挂载模型镜像,已上游合并)和 `oci+fetch://`(storage-initializer 内拉 OCI artifact,评审中);对 s3/gs/hf 这类不可信源,提出下发时校验(digest pinning + OpenSSF model-signing 强制)。
  - 关键数据点:70B 模型热缓存下发 11.7s vs 对象存储 40.7 分钟,约 **208x**;首次冷拉因 containerd「先写 blob 再解包」比裸下载贵约 2x;流式哈希校验只加 <0.1% 时延,而下载后再校验最高加 53%。
  - 对我们的启示:这篇几乎是给我们(对标 OAI/KServe)的路线图。scale-to-zero / 弹性扩缩的经济性瓶颈就在模型加载,应把模型 artifact 走 OCI 分发 + 节点级 pull 缓存作为默认路径,而不是每个 pod 从 S3 重新拉;校验要做成流式(边下边算哈希),别做成下载后二次遍历。这直接影响我们"模型生命周期 + 供应链安全(签名/校验)"两个企业级卖点的实现选型。

- **[ExpertPlex: A High-Goodput Disaggregated Serving System for MoE LLMs with Adaptive Persistent Kernels](https://arxiv.org/abs/2607.18002)** — MoE 服务不再按实例整机拆 prefill/decode,而是"共享专家权重、只拆轻量 attention"。
  - 核心思路:instance-level 的 PD 分离会把几十上百 GPU 的 MoE 权重整份复制,导致 prefill/decode 配比错配、一头过供一头挨饿;ExpertPlex 让 prefill/decode 共享同一份 MoE 专家(消除 >95% 重复权重),只把轻量 attention 模块分离,配 tile 粒度的 adaptive persistent kernel 做隔离执行,并用 attention 驱动 MoE 通信实现跨阶段计算通信重叠。
  - 关键数据点:相比 instance-level PD 分离 goodput **2.01x**;相比 PD 共置 **1.66x**(在 MiniMax-M2.7、GLM-5.1-FP8 上)。
  - 对我们的启示:我们做 MoE 服务的调度抽象时,"prefill/decode 二分 + 整机复制"这个默认模型要打问号。对超大 MoE,权重共享 + 细粒度 kernel 调度是更省显存的路子,值得在我们 GPU 调度层预留"专家权重共享池"的概念,而不是把 PD 分离当唯一形态硬编码进 CRD。

- **[Talaria: Session-Aware Serverless Serving of Hundred-Billion-Parameter LLMs](https://arxiv.org/abs/2607.17181)** — 面向"带会话的工具调用 Agent",把 serverless 多模型复用做成"放置 + 准入"联合决策,保住会话与它的 KV/权重不失联。
  - 核心思路:纯按负载路由会把一次续写和它的模型/KV 状态拆散;轮转式模型复用又会把已正确放置的续写拖到下一个时隙。Talaria 按"模型驻留 + KV 局部性 + 实例压力"排序放置,用软预留为可能回流的会话留准入预算,session-prefill 在模型时隙关闭前提前准入续写,并用稳定 HMM 地址 + 可恢复 KV + 跨模型切换时预暂存权重兜底。
  - 关键数据点:单台 TP=8 服务器、3 个 100B+ 模型、30 个 SWE-Bench 会话(960 次调用):p50 会话完成时间 1000s→189s(**5.3x**),p95 2296s→867s(2.6x)。
  - 对我们的启示:Agent workload 正成为主流负载形态,"会话亲和"必须进我们的推理网关/路由层——不能只按 GPU 负载做无状态 LB。KV 局部性 + 软预留是可直接借鉴的路由信号;对多模型共享 GPU 池的产品能力,这是一份可落地的准入策略参考。

- **[Roomie: Interference-Aware Colocation for Efficient Model Serving](https://arxiv.org/abs/2607.16784)** — GPU 超卖共置多模型时,用"kernel 时间重叠"而非聚合资源画像来预测干扰。
  - 核心思路:共置能不能不违反 SLO,取决于并发模型 kernel 的时间重叠,而现有系统要么忽略干扰、要么用聚合资源画像抓不住时序。Roomie 离线抽取每 kernel 资源配置,在线用"占用率解析模型"(不受 profiler 计时失真影响)预测干扰,配对贪心把多模型干扰近似成多项式复杂度,在线放置选预测 slowdown 最小的 GPU。
  - 关键数据点:SLO 违规(推理时延)最多降 **3x**,goodput 与现有方法相当或更优;在云端服务器集群和嵌入式边缘设备上都验证。
  - 对我们的启示:我们做 GPU 共享/超卖(对标 HAMi、MPS/MIG 分片)时,调度器不能只看显存/算力配额,得引入 kernel 级时序干扰模型。这是"GPU 分享"从粗粒度配额走向 SLO 感知的关键一步,值得在我们的共置准入里加一个干扰预测门控。

- **[LMEdge: QoS-Aware LLM Inference Orchestration on Edge Clusters](https://arxiv.org/abs/2607.17175)** — 在异构边缘 K8s 集群上,把"选哪个模型族/多大尺寸/几比特量化 + 放哪台设备"做成 QoS 约束下的联合优化。
  - 核心思路:边缘设备异构且资源受限,需同时满足时延、精度、带宽、资源约束。LMEdge 把放置建成二进制整数线性规划(最小化响应时间、约束精度/网络/资源),用 5 个轻量 ML 模型预测每个"模型-设备"组合的时延/精度/资源/响应大小,再用启发式近似求解支撑在线调度。
  - 关键数据点:K8s 测试床 57 实例、5.9 万行 benchmark;相比 baseline 降时延、保精度、提资源利用率与并发服务率(论文给的是相对提升,未列绝对倍数)。
  - 对我们的启示:"模型尺寸/量化级别作为可调度维度"这个思路值得吸收——同一请求可以按 QoS 动态选 7B/70B 或 int4/fp8。对我们做边缘/分级推理的产品,调度对象不应只是 pod,而应是"(模型变体, 设备)"组合;ILP + 轻量预测器的两段式(离线建模 + 在线启发式)是可复用的工程范式。

## 值得泛读(9 篇)

- [HyMCache: A KV Cache Framework for Multi-Turn LLM Serving with CXL-Hybrid Memory](https://arxiv.org/abs/2607.18141) — 用 CXL 混合内存扩 KV cache 容量,面向多轮会话服务。
- [InstantInfer: Enabling Fast LLM Cold Start with Communicating Finite Automata](https://arxiv.org/abs/2607.18957) — 又一篇冷启动加速,用通信有限自动机建模启动流程(与本周"模型下发/冷启"主题呼应)。
- [ARBITER: Guarded Agentic Control for SLO-Oriented Kubernetes Remediation](https://arxiv.org/abs/2607.19182) — 用带护栏的 Agent 做面向 SLO 的 K8s 自动修复,AIOps 方向。
- [Searching for Plans You Can Actually Build: A Realizability-Aware Full-Space Optimizer for MoE Training and Serving](https://arxiv.org/abs/2607.18631) — MoE 训练/服务并行方案的"可落地性感知"全空间优化器。
- [Controlled Periodic Synchronization for Efficient Data-Parallel Training](https://arxiv.org/abs/2607.21224) — 数据并行训练的可控周期性同步,降通信开销。
- [A Training-Memory Regression in MLA Sequence Parallelism: Why Megatron-Core Forbids Absorption, and LAGA](https://arxiv.org/abs/2607.17644) — 剖析 Megatron-Core 里 MLA 序列并行的训练显存回退问题并给方案。
- [Keeping the Cache Warm Pays: Keepalive Economics for Agentic Workloads](https://arxiv.org/abs/2607.19214) — Agent 负载下"保温缓存"的经济性分析,和 Talaria/冷启主题一脉。
- [Windowed-MTP: Removing the Full-Context Draft-KV Tax at Million-Token Context](https://arxiv.org/abs/2607.21535) — 百万 token 上下文下削减投机解码 draft 的全上下文 KV 开销。
- [An Auto-Scaling Approach for Serverless Environments Based on Multi-Expert Consensus](https://arxiv.org/abs/2607.15511) — serverless 环境多专家共识式自动扩缩。

## 趋势观察

- **主线从"训练"彻底转到"服务弹性经济学"**。本周最密集的三个信号——模型冷启动/下发(16596、18957)、会话感知 serverless(17181、19214)、共置与干扰(16784、18002)——本质是同一个问题:大模型太重,scale-to-zero / 弹性复用的成本卡在"权重加载 + KV 状态搬迁"上。谁能把"加载/切换/共置"做便宜,谁就能把 GPU 利用率打上去。对我们:这正是产品差异化的战场,而不是再去卷推理内核。
- **Kubernetes 正在成为默认服务基座**。16596(KServe/OCI)、17175(边缘 K8s ILP 编排)、19182(K8s SLO 自动修复)三篇都直接把 K8s 当一等公民,且开始用 K8s 原生机制(image volume、OCI 分发)解决 AI 特有问题。这利好我们"云原生 AI 基础设施"的定位——上游正在把我们要的能力补进 K8s/KServe。
- **MoE 服务成独立子赛道**。18002、18631 都在专门解 MoE 的显存复制与并行方案落地性,说明 MoE 已从"模型创新"下沉为"系统工程"问题。我们的调度/服务层需要把 MoE(专家权重共享、expert 级放置)当作和稠密模型并列的一等形态对待。
- **相较此前**:纯 KV cache 压缩/量化的论文仍在出(21535、18141),但已从"主角"退成"泛读"档;系统级的放置、准入、下发、干扰建模明显上位——研究重心从"单机推理更快"转向"集群里更省地服务"。
