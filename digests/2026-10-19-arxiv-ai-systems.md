# AI 系统论文周报 2026-10-19

> 覆盖窗口:2026-10-12 ~ 10-19(cs.DC / cs.PF recent 列表 + WebSearch 查漏;周末 arxiv 无 listing)。筛选口径见 `tasks/arxiv-ai-systems.md`:只收系统/调度/服务化且有实验验证的,纯模型结构/纯应用不收。

## 本周精选(5 篇)

- **[Simulate Before You Scale: High-Fidelity LLM Inference Planning Without GPUs (BLIS)](https://arxiv.org/abs/2610.14255)** — 一个纯 CPU 的离散事件仿真器,不占 GPU 就能把整条推理服务流水线(准入/路由/调度/prefill-decode/KV 管理/抢占)建模出来做容量规划。
  - 核心思路:解析基函数 + 一次性全局拟合的学习型缩放系数/开销项,无需 per-model、per-GPU profiling 即可预测单步时延;把配置搜索从"烧 GPU 跑"变成"CPU 上 200x 速度扫"。
  - 关键数据点:跨 6 模型 × 3 种 GPU 共 36 组实验,端到端中位误差 6.7%,比真机快约 200x;在 420 个 Llama-2-70B 配置里选出满足 300ms 平均 TTFT SLO 的 4-GPU 方案(对手工具要么翻倍用 8 GPU、要么选出的配置在负载下崩)。两条纯仿真里"进化"出来的策略已合入开源 llm-d:准入策略把关键租户 TTFT P90 降最多 82%,流控策略把过载时 E2E P50 降 32–48%。
  - 对我们的启示:这正是我们做"部署前容量/SLO 规划"工具缺的那块——给客户报价/定容时不该靠拍脑袋或烧集群试。它还证明了"仿真器选出的策略能回灌到 llm-d 生产"这条路走得通;我们如果在控制面接 llm-d,可以直接复用它合入的准入/流控策略,并考虑把 BLIS 式仿真做成 pre-flight 校验器挂在调度器前面。

- **[FastEEP: Fast Intra-Instance Elastic Scaling for Expert-Parallel MoE Serving](https://arxiv.org/abs/2610.18451)** — MoE 的专家并行(EP)实例要扩缩容时,不再整实例销毁重建,而是实例内部分复用运行时状态做快速 resize。
  - 核心思路:"Partial Reuse"——把可复用的执行结构(worker 执行态、GPU 显存、通信)与当前 EP 配置激活的资源解耦,扩缩容时只回收/重配后者,保留重建代价高的前者,从而在不 teardown 整个实例的前提下改 EP group 大小。
  - 关键数据点:相比现有 vLLM 的实例级扩缩容,扩缩速度快 4.5x–11.7x(不同模型)。
  - 对我们的启示:大 MoE(DeepSeek/Qwen-MoE 这类)上生产后,弹性伸缩的"冷启动/重建"开销会直接决定能不能跟随流量峰谷省成本。我们的自动伸缩控制器若只会加减 Pod(实例级),面对 EP 部署就是 FastEEP 批判的那种低效路径;产品上应把"实例内 EP resize"作为 MoE 服务的一等伸缩原语纳入 HPA/自研 autoscaler 的设计。

- **[JointServe: Serving Multi-Model Agents on Memory-Constrained GPUs](https://arxiv.org/abs/2610.19822)** — 面向 agent 编排多个专家模型的场景,把权重分片和 KV block 当成争抢同一显存预算的"驻留对象"统一调度,解决私有化/边缘小显存上切模型即丢会话态的问题。
  - 核心思路:利用 agent 工作负载的三个结构特性——有向调用(从调用方输出流里解析 intent 信号,在生成期就预取下一个模型)、间隙执行(部分层驻留把切换降为增量加载)、双态驻留(抢占式传输调度用保底带宽保护在线会话的 KV);再加一个动态 carve-out 控制按需调整权重/KV 配比。
  - 关键数据点:比最强的整模型 swap 基线把会话完成时间降 21.7%;在所有整模型 swap 基线都跑不完的"崩溃区间"仍可用(46x 差距);在 SWE-bench / tau-bench / OSWorld 回放上会话时间最多降 49%,SLO 达成率从 2.8–24.5% 提到 76.8–100%。
  - 对我们的启示:私有化交付和边缘盒子是我们的主战场,客户显存永远不够。agentic 多模型编排不能假设"工作集全进显存"。产品侧要把"权重+KV 统一显存预算 + intent 驱动预取 + 会话 KV 保护"做进推理网关,而不是让底层引擎各管各的 swap;这也是跟纯云端大显存玩家(靠堆卡)差异化的点。

- **[CacheSmith: Accurate RAG Serving under Latency SLOs with Adaptive KV Reuse](https://arxiv.org/abs/2610.18925)** — RAG prefill 复用检索 chunk 的预算 KV 会丢跨 chunk 注意力,CacheSmith 做可动态配置的选择性重算,在 SLO 下最大化"质量达标"的请求数。
  - 核心思路:把选择性重算拆成 WarmUp / Probe / Patch 三阶段工作流,可按 cost-accuracy 权衡动态配置;服务期一个 SLO-aware 调度器组 batch 抑制逐层 prefill 的请求间干扰,一个 budget-aware planner 在 batch 内配置各请求的重算阶段;两者都基于预先 profile 的 cost-accuracy band 做免求解器的快速决策。
  - 关键数据点:4 个 benchmark、不同到达率与突发度下,相比 4 个 SOTA 基线,质量门控 SLO 达成率最高提升 27.5%。
  - 对我们的启示:RAG 是企业客户最高频落地的形态,而"缓存 KV 省延迟 vs. 答案质量掉"的张力目前多数产品是静态配死的。CacheSmith 证明按请求异质性/实时延迟预算动态调重算能同时保质量和 SLO——我们的 RAG 服务应把重算档位做成随 SLO 预算自适应的旋钮,而非全局开关。

- **[Architecting for Hardware Diversity: Meta's End-to-End Co-Design for High-Performance AI Training on AMD GPUs](https://arxiv.org/abs/2610.22230)** — 首个超大厂把 AMD GPU(MI350X)productionize 做大规模训练的报告,主题是"降成本 + 去 NVIDIA 锁定"的异构算力落地方法论。
  - 核心思路:三条可复用原则——(1) 硬件-模型协同设计,不照搬 NVIDIA 模型而是改模型结构/软件 recipe 去吃 MI350X 的强项(如相对 B200 的 1.6x HBM 容量);(2) 解析性能模型做 zero-warmup 的最优 kernel 选择,免去繁重调优;(3) 用 agentic workflow 降低从 CUDA 生态迁移的门槛,扩展到微架构感知的 kernel 优化和 shim 自动生成。
  - 关键数据点:相比"直接移植"基线,端到端训练吞吐最高提升 1.5x;成果已上游到 PyTorch / Triton / ROCm。
  - 对我们的启示:这跟我们纳管多厂商加速卡(NV/昇腾/HAMi 生态)的方向高度同频——"直接移植会很慢,必须协同设计 + 自动化迁移"是被超大厂验证过的结论。可借鉴把"解析性能模型做 kernel 选择"和"agentic 迁移/shim 生成"作为我们多芯支持的工程范式;另外它反复强调 HBM 容量差异决定最优并行/batch 策略,提示我们的调度器在跨厂商排布时不能只看算力(TFLOPS),要把显存容量/带宽当一等约束。

## 值得泛读(8 篇)

- [Quota-Based Aging for Prediction-Guided Scheduling in LLM Serving](https://arxiv.org/abs/2610.17795) — 用配额老化机制缓解预测引导调度里的饥饿问题,偏调度算法。
- [Prorsa: Unleashing the Potential of Prefill-Decode Disaggregation in Agentic Reinforcement Learning](https://arxiv.org/abs/2610.16592) — 把 PD 分离的思想延伸到 agentic RL 训练/采样链路。
- [Compositional Performance Modeling of LLM Inference Clusters with Hierarchical KV Caching](https://arxiv.org/abs/2610.15366) — 分层 KV 缓存下的推理集群性能建模(与 BLIS 同一赛道,偏建模)。
- [Scaling LLM Inference via Parallelism: Throughput-Latency Trade-off](https://arxiv.org/abs/2610.19405) — 并行度 vs. 吞吐/时延权衡的系统性分析。
- [Efficient KV Cache Migration for Geo-Distributed LLM Inference in Collaborative Edge Computing](https://arxiv.org/abs/2610.22172) — 跨地域/边缘协同下的 KV cache 迁移,边缘部署相关。
- [When the KV Cache Is Slower Than the GPU: Scaling Remote KV Tiers for Context-Parallel Prefill](https://arxiv.org/abs/2610.21500) — 远端 KV 分层在上下文并行 prefill 下成为瓶颈的实证与扩展。
- [AlignPred: Error-Controlled KV Cache Compression via Alignment and Predictive Coding](https://arxiv.org/abs/2610.17970) — 误差可控的 KV cache 压缩。
- [Dissecting the Carbon-SLO Tension in Geo-Distributed LLM Serving](https://arxiv.org/abs/2610.14571) — 跨地域服务里碳排放与 SLO 的张力分析,绿色算力调度视角。

## 趋势观察

- **主线从"训练"明显滑向"服务化系统工程"**:本周高质量论文集中在推理服务的弹性伸缩(FastEEP)、多模型 agent 驻留调度(JointServe)、RAG SLO 下的 KV 复用(CacheSmith)、以及部署前容量仿真(BLIS)。都是"怎么把模型稳定、省钱地跑在生产"的问题,而非"模型本身怎么变强"——跟我们做基础设施产品的关注点高度重合。
- **KV cache 仍是绝对主角,且在"分层/远端/迁移"方向继续深化**:本周一口气出现 KV 迁移(2172)、远端 KV 分层瓶颈(21500)、分层缓存性能建模(15366)、误差可控压缩(17970),说明 KV 已从"单机优化"走向"跨层级存储体系(HBM/host/远端)"的系统问题——我们的推理存储栈设计要把 KV 当作一等公民的分层对象。
- **PD 分离(prefill-decode disaggregation)外溢到 RL / agentic 场景**(Prorsa),不再只是在线推理的专利;agentic 工作负载(多模型编排、工具调用、长会话)正成为新的系统设计驱动力(JointServe、Prorsa、Quota-aging)。
- **"成果直接上游到开源平台"成为高质量系统论文的标配信号**:BLIS 合入 llm-d,Meta AMD 工作上游到 PyTorch/Triton/ROCm。对我们的提示是——跟紧 llm-d 这类上游平台,学术界最新的调度/准入/流控策略会先在那里落地,是低成本获取前沿能力的入口。
- **多厂商/异构算力去锁定从"口号"进入"超大厂实证"阶段**(Meta AMD MI350X),与我们纳管昇腾/HAMi 多芯的路线互为印证:协同设计 + 自动化迁移 + 把显存容量当一等调度约束,是被验证的方法论。
