# AI 系统论文周报 2026-09-22

窗口: 2026-09-15 -> 2026-09-22

筛选关键词: LLM serving, model serving, inference optimization, GPU scheduling, GPU cluster, GPU sharing, distributed training, sequence parallelism, pipeline parallelism, tensor parallelism, KV cache, speculative decoding, continuous batching, MLOps, model registry, feature store, RAG system, retrieval augmented generation system, AI infrastructure, inference serving, model deployment.

筛选口径: 只收录与 AI 基础设施/系统直接相关、且从 arXiv abstract / introduction / evaluation 或 experiments 能看到系统设计与实验验证的论文；剔除纯模型结构、纯应用型 RAG、纯 NLP/CV 任务论文。

## 本周精选(3-5 篇)

- **[PipeSwift: Revisiting Pipeline Parallelism for Large-Scale Completion-Oriented Agentic LLM Serving](https://arxiv.org/abs/2609.16491)** — 面向 agentic / completion-oriented serving，把优化目标从 TTFT/TPOT 转到 job completion time(JCT)，重新证明 pipeline parallelism 在大模型 agent 工作负载里有价值。
  - 核心思路: 论文指出 SWE-Bench、BrowseComp 这类 agentic serving 不只是一次交互，而是多 turn 轨迹；单纯满足 TTFT 或提高 decode throughput 并不等于降低整体 JCT。PipeSwift 用 JCT-aware scheduling 协调 prefill/decode，并用 pipeline parallelism 的 prefill/decode 平衡特性改善 completion-oriented workloads。
  - 对我们的启示: 面向代码 agent、浏览 agent、长任务推理时，平台指标不能只给 TTFT/TPOT。产品上应增加 job/trajectory-level JCT、turn-level P99 JCT，并允许不同 workload 选择不同并行策略，而不是默认 expert parallel / engine 默认调度。
  - 关键数据点: 在 64 张 H800、GLM-4.7-360B 与 Qwen3.5-397B、SWE-Bench/BrowseComp 轨迹上，PipeSwift 相比 SGLang overall JCT 降低 1.21-1.45x；相比使用双倍 GPU 的 2P2D baseline，在完成的测试格中仍快 1.14-1.54x；P99 turn-level JCT 低于最佳 baseline 的一半。

- **[Decomposing Predictive Kubernetes Autoscaling for Large Language Model Serving Under Long Startup Delays](https://arxiv.org/abs/2609.20874)** — 把 LLM on Kubernetes 的扩缩容问题拆成 token-aware demand、启动延迟 lookahead、UCB margin、plant-state observation 四个因素，结论很直接: delay-aware lookahead 是最该先做的控制面能力。
  - 核心思路: 论文指出 LLM pod 启动要加载 14-140GB 权重、初始化 CUDA/graph，常见 2-10 分钟延迟，reactive HPA/KEDA 天然晚到；同时 QPS 不能表达 prompt/output token 和 KV cache 压力。因此用 EWMA 预测 token demand，并按启动延迟提前扩容，再加 bounded UCB margin。
  - 对我们的启示: OAI/推理平台的 autoscaling 指标不应停留在 QPS 或 queue length。产品层面应把 vLLM 的 waiting/running、prefill/decode token rate、KV cache utilization 暴露成一等指标，并支持「按模型冷启动时间配置 lookahead」的预测扩缩容策略。
  - 关键数据点: 在 ServeGen 重尾负载中，QPS reactive 的 TTFT SLO violation 为 53%，token-aware reactive 降到 20.9%，加入 startup-delay lookahead 降到 1.44%，EWMA-UCB 降到 0.54%；真实 Kubernetes + Qwen2.5-7B + A100 + vLLM 验证中，predictive lookahead 相比 KEDA reactive 将 TTFT violation 从 63.5% 降到 3.7%。

- **[DeepShare: Assurance-Driven Deep Learning Job Scheduling for Multi-Tenant Clusters](https://arxiv.org/abs/2609.16682)** — Kubernetes-native GPU 多租户调度器，用连续的 tenant assurance 信号统一 quota、排队、抢占和 GPU sharing 决策。
  - 核心思路: DeepShare 观察到多租户 GPU 集群里经常出现「租户排队很久但 GPU 利用率低」的问题，根因是 quota、queue ordering、preemption 和 colocation 各自看局部信号。它用 Quota Assurance Degree(QAD)驱动 deficit-aware reclaimable allocation、best-effort preemption 和 interference-aware colocation，并通过 runtime prediction 判断共享风险。
  - 对我们的启示: 训练平台的 GPU 利用率提升不能只靠 MIG/MPS 或简单超卖。产品需要把 tenant guarantee、best-effort 回收、队列公平、可抢占窗口、GPU sharing 干扰预测放进同一个调度闭环，否则 QoS 和利用率会互相打架。
  - 关键数据点: 在 23,859 个 Venus jobs 和 3,200 个内部 jobs 的 trace-driven 模拟中，DeepShare GPU 利用率达到 70.58%，比最强 non-intrusive sharing baseline Lucid 高 29.5%，平均 queueing delay 降低 46%；在 16-GPU Kubernetes testbed 上，平均 JCT 降低 34%，queueing delay 降低 66%，guaranteed tenants QoS compliance 为 93%。

- **[Token Latency Fairness: Performance Isolation for Multi-Tenant LLM Serving](https://arxiv.org/abs/2609.18112)** — 面向多租户 LLM serving 的延迟隔离定义与调度系统，不再只做吞吐公平，而是约束每个 token 相对隔离运行的额外延迟。
  - 核心思路: FairInference 提出 delta-token fairness: 如果一个 well-behaved client 的某个 token 在隔离环境中 d 时间生成，多租户环境中应在 d + delta 内生成。系统用 per-token deadline、deadline-aware prefill/decode scheduling，以及保护 well-behaved client 的 KV cache reservation 来同时控制调度延迟和 KV eviction 延迟。
  - 对我们的启示: 企业版共享推理池不能只提供 namespace 级 quota 和吞吐公平。面向多租户 SLA，需要把「token latency isolation」作为产品指标，并在调度器中显式处理 KV cache eviction 对低负载租户的影响。
  - 关键数据点: 论文在 SGLang 上观察到单个高需求租户可让其他租户 TTFT 增加超过 60x；与 plain SGLang、VTC、DLPM 相比，FairInference 把 well-behaved client 的 TTFT/TBT/TTLT 干扰压到基准水平，同时通过 deadline + fair KV cache 策略维持整体吞吐。

- **[NSP: Accelerating Variable-Length LLM Training via Nested Sequence Parallelism](https://arxiv.org/abs/2609.22755)** — 针对长上下文训练里「少量超长样本 + 大量短样本」的 sequence parallelism 低效问题，提出在同一批次内嵌套不同 SP degree。
  - 核心思路: Static SP 用一个 SP degree 会在通信开销和负载均衡之间二选一；FlexSP 这类 dynamic SP 把 batch 切成 disjoint group，又带来 group imbalance 和 micro-batch 开销。NSP 用 SP tree 让不同长度样本映射到不同层级的 SP group，同一 GPU 可在一次 forward/backward 里参与多个嵌套 group，并用 planner + cost model + tree-level recomputation 控制内存和通信。
  - 对我们的启示: 训练平台如果要支持 192K/384K 这类长上下文任务，调度粒度不能只到 job/GPU，也需要暴露 batch 内序列长度分布、SP degree、通信拓扑和重计算策略。对产品来说，这是长上下文训练「数据分桶 + 并行策略自动选择」能力的强信号。
  - 关键数据点: 在内部 64-GPU NVIDIA production cluster 上，Qwen3-MoE-30B/235B、192K/384K context、三组长尾数据集实验中，NSP 相比 Static SP 最高 1.48x speedup，相比 FlexSP 最高 1.16x speedup；online planner 在毫秒级运行，可提前为即将到来的 batch 生成 routing plan。

## 值得泛读(5-10 篇)

- [ASPIRE: Asynchronous Batched Self-Speculative Decoding for Long-Context LLM Inference](https://arxiv.org/abs/2609.17943) — 在同一个 batched forward 里允许部分请求 draft、部分请求 verify，避免 batch-wide 同步 speculative schedule；三种模型、五个 reasoning/long-context workload 上，相比 autoregressive decoding 达到 1.70-4.58x decoding throughput speedup。

- [FlashVector: Agent for Hierarchical Model Serving Stack Optimization](https://arxiv.org/abs/2609.17391) — Unity 生产广告 serving 栈里的 agentic 全栈优化系统，覆盖 GPU kernel、PyTorch graph、Triton model server、feature preprocessing 和 serving 参数；部署后 model server 最高 2x throughput increase、1.98x latency speedup，feature store 最高 1.6x throughput increase。

- [The Inference Engineering Pareto Atlas: Which Optimizations Dominate the Cost, Quality, and Latency Frontier?](https://arxiv.org/abs/2609.17863) — 用 54 个 Qwen2.5-7B + vLLM anchor 配置校准 cost-quality-latency atlas；结论是不能只看 speedup，naive FP8 KV cache 吞吐正常但 GSM8K 0/200，FP8 weights 则保持 99.4% baseline accuracy 且 latency ratio 0.61-0.65。

- [JustFit: 200K-Token LLM Serving on a 24 GiB Laptop with Just-in-Time State Management](https://arxiv.org/abs/2609.17475) — MLX 本地推理 runtime 通过压缩 KV execution、component residency 和 state-preserving transitions，把 24GiB M4 Pro 上的单请求完成上下文从 30,720 positions 提到 212,992 positions(6.93x)。

- [TierKV: Long-Context On-Device LLMs via Predictive Multi-Tier KV Caching](https://arxiv.org/abs/2609.21172) — 移动端 LLM KV cache 预测式分层管理，prefill hidden states 预测未来 cache demand 后在 exact/low-rank/flash-offload tier 间分配；8 个模型、3 个 mobile SoC 上内存节省 12.5-34%，prefill throughput 最高 17.6x。

- [Hybrid GPU-CPU Retrieval for Personalized Search at Ultra-Large Scale](https://arxiv.org/abs/2609.21281) — Meta 的生产级 GPU/CPU hybrid retrieval: GPU 路径做 billion-scale 高深度个性化，CPU 路径做约 20x 更大 inventory 的高广度轻量检索；九天线上 A/B 中 hybrid 相比 legacy CPU-only 提升 DCG@20 4.51%、GSRR 2.01%。

- [Zero-I/O Fault Recovery for Sharded Deep Learning via Dynamic Framework Dependency Rebinding](https://arxiv.org/abs/2609.18178) — AccelPact 利用 optimizer boundary 的内存状态未损坏事实，重绑 FSDP cached process-group references，实现通信故障后无 checkpoint replay 继续训练；16 GPU Mistral-7B 实验中 checkpoint age 18 时 whole-run goodput 最高 1.698x。

- [AutoTuneBench: Trustworthy Measurement for Agent Auto-Tuning of LLM Serving Engines](https://arxiv.org/abs/2609.18123) — 给 agent 自动调优 vLLM/SGLang 和 GPU kernel 的测量协议，重点防 strawman baseline、跨机器绝对时间误用、任务饱和和基础设施缺陷；同一优化可从 naive 10.6x 变成 honest 2.03x，说明自动调优产品必须先产品化测量可信度。

- [Shared-Prefix KV Reuse Across Standard LoRA Adapters: Quality and Serving Tradeoffs](https://arxiv.org/abs/2609.17109) — 研究同一 backbone 多个标准 LoRA adapter 共享 prefix KV 的质量/成本边界；8K QA warm-cache TTFT 从 486ms 降到 30ms，但 GSM8K/QA 存在小幅质量损失，且实现并未真正物理共享 KV storage。

- [Accurate Simulation of Distributed Training Jobs with Network Contention Modeling](https://arxiv.org/abs/2609.23278) — 分布式训练 trace-driven simulator 显式建模 network contention，避免把调度决策导致的 NIC/link 争用当成固定 penalty；论文报告 MOSIM 在 144 个实验上 MAPE 8.63%，输入构造成本降低 44.6x，适合训练调度器离线评估方向跟进。

## 趋势观察

- LLM serving 正从单机 engine 优化转向控制面问题: 本周 PipeSwift、autoscaling、multi-tenant fairness、serving stack auto-optimization、Pareto profiling 都把核心矛盾放在「调度、SLO、JCT、成本、可测量性」而非单个 kernel。
- KV cache 仍是系统论文主轴: autoscaling 用 KV pressure 解释 TTFT，FairInference 把 KV eviction 纳入租户隔离，JustFit/TierKV/LoRA KV reuse 都围绕长上下文状态生命周期做文章。
- 训练系统的焦点继续向长上下文、多租户调度和故障恢复移动: NSP 处理 long-tail sequence length 下的 SP degree 选择，DeepShare 处理 guaranteed/best-effort tenant 下的 GPU sharing，AccelPact 处理 FSDP/NCCL 故障后的零 I/O 恢复，MOSIM 则服务于训练调度器离线验证。
- 工程测量可信度开始成为论文主题: Pareto Atlas 和 AutoTuneBench 都在提醒，只有 speedup 的 benchmark 会误导产品决策；质量门槛、同机 baseline、审计 trail、成本轴需要进入平台能力。

## 未覆盖风险

- arXiv API 可用，但检索仍主要依赖关键词和 cs.DC/cs.PF/cs.LG/cs.AI/cs.IR 交集；如果论文标题/摘要没有出现 serving、KV、GPU、training、RAG system 等词，可能漏掉。
- 2026-09-20 附近少数新编号 PDF 端点短时返回 404/406；本稿优先收录已能读取 PDF 并核对 abstract/introduction/evaluation 的论文，可能漏掉刚发布但 PDF 尚未稳定分发的条目。
- 对泛读条目的阅读深度低于精选，主要核对 abstract、introduction 和 evaluation 关键段；若后续要推飞书或做产品方案，应优先复读精选 5 篇 PDF 全文。
