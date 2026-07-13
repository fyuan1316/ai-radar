# AI 系统论文周报 2026-07-13

> 窗口:2026-07-06 ~ 2026-07-13(arxiv 已编入索引至 07-10)。检索类目 cs.DC / cs.PF / cs.LG,按 submittedDate 倒序拉取后本地按关键词(serving / scheduling / GPU / KV cache / MoE / elastic training 等)筛选。窗口内命中系统方向论文约 20 篇,下面精选 5 篇、泛读 9 篇。

## 本周精选(5 篇)

- **[SMetric: Rethink LLM Scheduling for Serving Agents with Balanced Session-centric Scheduling](https://arxiv.org/abs/2607.08565)** — 面向"Agent 发起请求"的服务场景重做调度,用会话粒度平衡负载而非一味追缓存命中。
  - 核心思路:Agent 负载与人类聊天有两点本质差异——(1) Agent 只在拿到完整响应后才行动,集群 TPS 成为首要目标,单 token 延迟约束被放松;(2) 同一 session 内 KV 复用率极高。作者据此提出 session-centric 调度:每个会话的**首个请求**纯按负载均衡路由,后续请求按缓存亲和性路由,既保住本地 KV 复用又不把少数实例打爆。调度指标只用 session turn 信息,可从用户输入直接推出,调度器保持无状态。
  - 对我们的启示:我们的推理网关/路由层若还在用"chat 时代"的 prefix-cache 亲和路由,面对 Agent 流量会出现"少数实例过载、其余空转、TPS 封顶"的问题。产品决策:在 KServe/网关路由策略里区分"会话首请求 vs 续请求"两类,首请求走负载均衡、续请求走缓存亲和,并引入 global KV tier 兜底;这套改动无需模型侧配合,可作为路由中间件独立落地。
  - 关键数据点:生产 trace(BAILIAN)Agent 负载 KV 复用 >80%,而 chat 仅 54–62%;PD 共置 + 全局缓存下集群 TPS 提升 10–16%,PD 分离下 prefill TPS 提升 2–34%,且单 token 延迟更优。

- **[On the Limitations of Non-GPU AI Accelerators for Large-Model Inference: A Field Study on Huawei Ascend](https://arxiv.org/abs/2607.08215)** — 16 卡昇腾 910 上跑 MoE 判官模型 + 多模态医疗基准的实战踩坑记录,给"去 CUDA 化"算一笔真实工程账。
  - 核心思路:在 Ascend 910(CANN + vLLM-Ascend)上部署两类真实负载——W8A8 MoE 的 LLM-as-a-judge 安全对齐评测流水线(DeepSeek-V4-Flash),以及多模态医疗 VLM 基准(MMMU / MMMU-Pro)。为跑通,团队给厂商推理插件打了 **12 个源码级 patch**,并**主动关掉若干高吞吐特性以保数值正确**,还要为反复出现的设备级故障加运维兜底。把平台限制归纳为八类:算子/特性支持不全、并行脆弱、低层 kernel 数值故障、图编译不成熟、高级特性不稳、扩展性受限、可观测性弱、生态碎片化。
  - 对我们的启示:这正对标我们 compute-ascend-watch 关注的迁移成本。产品决策:昇腾适配不能只承诺"支持 vLLM-Ascend",要把"为保数值正确需关闭哪些高吞吐特性""哪些算子缺失需回退"做成显式的能力矩阵与降级预案;对企业客户的多芯片纳管方案,应默认提供"数值正确性优先/吞吐优先"两档 profile,并把可观测性(设备级故障自愈)作为差异化卖点——论文把弱可观测性单列为一类痛点。
  - 关键数据点:16 卡 Ascend 910;12 处源码 patch 才跑通;八类平台限制逐项给了症状/证据/成因,是一份可复现的非 GPU 加速器评估参考。

- **[Direct Model State Migration for Elastic Training of Large Language Models (ETC)](https://arxiv.org/abs/2607.04749)** — 共享集群里做弹性训练时,用 P2P 直传替代 checkpoint 落盘,消除迁移期全体 GPU stall。
  - 核心思路:共享集群的弹性训练(被动抢占 / 乐观扩容)在改变混合并行配置时需要跨设备迁移模型状态。现有方案靠 checkpoint 落盘再恢复,迁移期所有 GPU 停摆,数据要穿越多级存储层次,延迟高。ETC 是 checkpoint-free 迁移框架:利用状态局部性最小化跨 GPU 数据搬运,用**直接 P2P 通信替代存储持久化**,并通过通信合并消除节点碎片。已集成进 Megatron-LM。
  - 对我们的启示:多租户 GPU 集群做抢占/弹性调度时,checkpoint 迁移延迟是"敢不敢抢占大训练作业"的关键阻力。产品决策:我们的调度器(类 Kueue/Volcano 场景)若要支持"训练作业弹性缩扩容 + 抢占",应把 ETC 式 P2P 状态迁移作为底座能力,而非依赖对象存储 checkpoint;这直接决定弹性调度的抢占代价能否降到可接受区间。
  - 关键数据点:相比 checkpoint 方案,跨多种并行配置迁移开销降低 **2.33x ~ 6.37x**。

- **[UBEP: Re-architecting Expert Parallelism Communication Library for Production Superpods](https://arxiv.org/abs/2607.06202)** — 为 NVL72/576、CloudMatrix384 这类超节点重写 MoE 的 All-to-All 通信原语。
  - 核心思路:MoE 部署在高带宽超节点上,瓶颈已不是裸带宽,而是三点:(1) 粗粒度 BSP 编排导致的严格串行;(2) 无法随带宽扩展的同步开销;(3) 距离无关调度带来的负载不均。UBEP(Unified-Bus Expert Parallelism)针对超节点统一地址空间重做 All-to-All,是"production-ready"的通信库。
  - 对我们的启示:客户上 MoE(DeepSeek 系、Qwen MoE)做大规模推理时,EP 通信库的成熟度决定实际吞吐。产品决策:超节点/大 NVLink 域场景下,EP 通信层要作为独立可替换组件对待,并同时覆盖 NVIDIA NVL 与华为 CloudMatrix 两类 fabric(论文明确点名两者);对我们多芯片战略,这是"MoE 推理不只是算子适配,还要重写集合通信"的证据。
  - 关键数据点:All-to-All 延迟最高降 **52.4%**,MoE 推理 TPOT 最高降 **11.1%**。

- **[Bidirectional Resource Scheduling for Disaggregated and Asynchronous RL Post-Training (BiDiRL)](https://arxiv.org/abs/2607.09207)** — 用时空复用把 RL 后训练里 rollout 与 training 两个资源池的空泡填掉。
  - 核心思路:RL 后训练(提升推理能力)采用 disaggregated + 异步 rollout 架构(如 StreamRL、AReaL),但在不同硬件/模型规模/staleness/超参下,rollout 与 training 两个资源池仍频繁互相空转。BiDiRL 提出混合时空复用:(1) hot-switch 运行时,rollout↔training 资源近零开销切换;(2) 基于时间-性能建模的静态规划器,粗粒度平衡两阶段时长;(3) 运行时双向调度器,细粒度让瓶颈阶段临时借用对方空闲资源。
  - 对我们的启示:企业级"模型生命周期"正在从 SFT 走向 RL 后训练(RLHF/RLVR),而 RL 训练的资源利用率是成本核心。产品决策:若我们要提供 RL 后训练能力(对标 OAI 的 fine-tuning/对齐管线),调度层不能把 rollout 集群和 training 集群当两套静态资源,应支持二者动态借用;这也意味着我们的 GPU 配额/抢占模型要能表达"同一作业内两类可互换角色"。
  - 关键数据点:两个 32-GPU 测试床上,相比 veRL / AReaL / ROLL,RL 训练吞吐最高提升 **1.94x**,且不影响收敛。

## 值得泛读(9 篇)

- [SiFAR: Synchronization-Free All-Reduce for Low-Latency LLM Inference](https://arxiv.org/abs/2607.08973) — 面向 reasoning/agent 的低延迟推理,协同设计通信与执行去掉 All-Reduce 屏障;All-Reduce 延迟降最高 52%,Llama-3.1-8B 端到端吞吐 +18.6%(TP=8)。
- [Think Before You Grid-Search: Floor-First Triage for LLM Serving](https://arxiv.org/abs/2607.05876) — 主张"先估算再 profiling",把每步 decode 建成五维资源向量算出性能上下界,只在残差超阈值时才开 profiler;案例分析 671B MoE/MLA 在 16×H20 上为何 TP 与 EP 布局会走向相反结论。方法论对我们做容量规划工具很有参考。
- [Towards Efficient LLM Serving: A Survey on System-Aware KV Cache Optimization](https://arxiv.org/abs/2607.08057) — 把 KV cache 系统工作按时间(调度)/空间(放置迁移)/结构(表示保留)三维梳理,适合作为我们 KV 分层缓存设计的 landscape 参考。
- [BlockServe: Block-Grained Continuous Batching for High-Throughput Diffusion LLM Serving](https://arxiv.org/abs/2607.08930) — 针对 diffusion LLM 的收敛异构性做块粒度连续批处理,块边界即时驱逐已完成请求,缓解 stragglers 造成的计算气泡。
- [Attention to Detail: Evaluating Energy, Performance, and Accuracy Trade-offs Across vLLM Configurations](https://arxiv.org/abs/2607.09172) — 对 vLLM 的 attention kernel 类型、prefix caching、chunked prefill 三项配置做大规模受控实验,量化其对能耗/性能/输出质量的影响,可作我们默认调优模板的证据。
- [Communication-Aware Placement and Pruning for Efficient MoE Inference (CAP)](https://arxiv.org/abs/2607.05116) — 把计算/通信/精度联合考虑做专家放置与剪枝,按共激活分组减少跨设备/跨节点通信。
- [Elastic Gang: Per-Token Membership Change for a Hard-Barriered LLM Inference Gang Co-Scheduled with OS Processes](https://arxiv.org/abs/2607.04668) — 裸机 Rust 内核里把推理 gang 做成一等调度实体,核成员可在两 token 间变化,用 ACK-latched epoch 协议避免屏障死锁;端侧/CPU 推理与 OS 抢占共存的极端案例。
- [Empirical Analysis of GPU Frequency Behavior Under ML Workloads](https://arxiv.org/abs/2607.08307) — NVIDIA GPU 频率受近 ~80ms 负载历史影响,挑战了"逐 kernel 延迟独立可加"的假设,对延迟预测/SLO 建模是个警示。
- [Memory Scarcity, Open Models, and the Restructuring of the AI Industry, 2026-2030](https://arxiv.org/abs/2607.07207) — 用 $/PB 带宽建模 DRAM/HBM 涨价、开放权重前沿模型、KV 压缩逼近香农极限等四股力量对推理经济学的重构;非纯系统论文,但对我们判断硬件成本走向与"推理即带宽"的定价逻辑有参考。

## 趋势观察

- **调度重心从"人类聊天"转向"Agent / reasoning 负载"**:SMetric、SiFAR 都以"Agent 只看完整响应、生成大量不给人看的中间 token"为出发点,把优化目标从单 token 延迟切到集群 TPS 与端到端时延。这类工作正在成为主线——服务系统的假设正在被 Agent 流量重写。
- **MoE 的瓶颈全面转移到"集合通信 / 专家放置",而非算子本身**:UBEP、CAP 都在做 All-to-All 与专家布局,且明确覆盖 NVIDIA NVL72/576 与华为 CloudMatrix384 两类超节点。对我们的多芯片战略,信号很清楚:MoE 推理适配不止于算子对齐,还要重写集合通信层。
- **"弹性 / 共享集群"成为训练侧关键词**:ETC(弹性训练状态迁移)、BiDiRL(RL 后训练资源双向复用)都在解决"资源动态变化下如何不浪费也不停摆"。抢占代价与资源利用率正被当成一等问题,与我们做多租户 GPU 调度的痛点高度一致。
- **非 GPU 加速器进入"实测算账"阶段**:昇腾 field study 用 12 个 patch 的真实代价,把"去 CUDA 化"从口号拉回工程现实——数值正确性、可观测性、生态碎片化是比峰值算力更现实的门槛。
- **方法论层面出现"估算优先于暴力 benchmark"的苗头**:Floor-First 主张先用解析模型定资源墙、再决定是否开 profiler,配套还给了 agent skill。容量规划/自动调优正从 grid search 走向可解释的分析层。
