# AI 系统论文周报 2026-09-07

> 覆盖窗口:2026-08-31 ~ 2026-09-07。数据源:arxiv API(cs.DC / cs.LG / cs.PF,系统与基础设施关键词),辅以 WebSearch 查漏。
> 说明:本周 arxiv API 对本 IP 限流严重(多次 429/503),cs.LG / cs.PF 补充查询未取回;主结果来自 cs.DC 类目(与"AI 系统/基础设施"最贴合的类目),共 25 篇过去 7 天新论文入池,筛后如下。

## 本周精选(5 篇)

- **[AInfer-PD: Communication-Safe In-Place Prefill-Decode Multiplexing for Distributed MoE Rollouts](https://arxiv.org/abs/2609.00993)** — 把 P/D 原地复用(不做物理拆分)扩展到分布式 MoE,靠通信隔离解决 DeepEP 下 P/D 并发的正确性问题。
  - 核心思路:agentic RL 的 rollout 里,异步轨迹让 prefill(P)和 decode(D)长期共存于同一批设备。P/D 拆分(disaggregation)要独立设备池 + KV 跨池搬运;原地复用省设备省 KV,但大 MoE 下 P 与 D 会在跨 rank 发出次序不一致的集合通信、且共享 DeepEP 可变协议状态,导致死锁/数据错乱。AInfer-PD 做两件事:跨 rank 协调 P/D 集合通信次序;给 DeepEP 的 P、D 两条路径各自独立的通信状态。由此在共享权重与 KV 的前提下让交叉的 ADP/ATP + DeepEP 路径能安全并发。
  - 对我们的启示:这是"P/D 拆分 vs 原地复用"路线之争的关键一票——如果我们的推理平台在为 agentic / 多轮 RL 场景做 P/D 架构选型,原地复用能省掉一整套独立 decode 池和 KV 传输通道,但前提是把 MoE 专家并行下的集合通信次序与状态隔离做对。建议把"通信次序一致性 + per-path 通信状态隔离"列为 MoE 服务栈的硬性设计约束,而不是等 disaggregation 兜底。
  - 关键数据点:单节点固定负载 rollout 完成时间,较关掉复用降 7.1–22.5%、较 SGLang 降 24.8–32.9%;双节点降 18.0–35.3% / 18.3–31.8%;细粒度边界较整 epoch 异步入队再降 8.6–19.8%。

- **[MeanField Surrogate Modeling for Scalable Runtime Scheduling of Concurrent Heterogeneous AI Inference on Shared GPUs](https://arxiv.org/abs/2609.02109)** — 用"均场"代理模型预测共享 GPU 上并发模型的性能,把 profiling 成本从组合爆炸降到线性。
  - 核心思路:多个异构模型(LLM + 视觉)共享一块 GPU 时相互争抢资源,离线代理模型本可避免在线基准测试,但要覆盖所有共跑组合,采样量随模型数组合式增长。作者提出 MeanField 代理:只用"本模型局部配置 + GPU 聚合状态"预测单模型性能,不显式建模两两交互,采样量随并发数 N 近似线性增长(R²≈0.96)。把它塞进遗传算法调度器,在线做布局/并发决策。
  - 对我们的启示:GPU 共享(MPS/MIG/时分)是我们对标 OAI 的核心能力之一,难点从来是"共跑会不会踩 SLA"。这篇给了一个可落地的轻量预测器思路——调度器不需要跑真实 benchmark,也不需要 N² 的画像表,就能在毫秒级预判共跑干扰。可作为我们 GPU 共享调度的准入门控(admission gate)组件原型:决策前先用均场代理估一版,再决定是否让新负载上车。
  - 关键数据点:N=5、78732 种可行共跑组合下,与穷举搜索差 0.10%,8 个动态场景零 SLA 违规;完整 GA 决策中位 26 ms,较穷举代理搜索快约 5×。

- **[Characterizing the Scalability and Performance of Large-Scale AI Training Under Multi-Tenancy](https://arxiv.org/abs/2609.00817)** — 跨 6 套超算、最高 2400 GPU 的多租户训练实证特征化,量化互连与并发干扰的影响。
  - 核心思路:系统性刻画 AI 训练的 scale-up / scale-out / rack-scale 三种配置在不同互连下的通信开销,并设计一个"现实噪声模型"来模拟多个并发训练作业互相干扰的场景。基准套件覆盖 5 种并行策略,跑在 Alps、Leonardo、LUMI、JUPITER、NVL72 GB300、DGX A100 等集群。
  - 对我们的启示:这是难得的、非厂商自吹的多租户实证数据,可直接给我们的集群容量规划与调度策略做外部锚点——尤其"并发作业互扰"这块正是我们多租户 GPU 平台最缺的公开 benchmark。建议把它的噪声模型思路引入我们的调度回归测试:不要只测单作业理想扩展性,要测"隔壁租户在抢网络"时的真实退化,把它作为多租户 SLA 承诺的依据。
  - 关键数据点:规模至 2400 GPU;横评 5 种并行策略 × 6 套集群 × scale-up/out/rack-scale 配置;核心结论为通信开销随互连技术差异显著、多租户干扰不可忽视(论文以特征化图表为主,非单一加速比)。

- **[Latency-Aware Orchestration for Multi-Agent LLM Workflows on Heterogeneous GPUs](https://arxiv.org/abs/2609.03335)** — 用工作流预测驱动的运行时,把逻辑多智能体工作流编译成对异构 GPU 池状态感知的物理执行图。
  - 核心思路:并发多智能体工作流暴露了"未来依赖"和"服务态要求",而底层是负载/模型驻留/资源可用性时变的异构 GPU 池。系统三段式:Predictor 估算设备相关的激活延迟、峰值显存、模型加载成本,并沿工作流依赖传播出"激活就绪时刻"与"未来模型需求";Constructor 构造语义保持的融合与模型生命周期(加载/卸载)备选;Scheduler 基于实时池状态联合优化选择、布局与执行次序。
  - 对我们的启示:agentic 工作流正成为推理平台的主流负载形态,而它对"模型何时该预加载/驻留/卸载"的调度极其敏感。这篇把"模型生命周期动作"当成一等调度对象(而非运行时被动 load),正是我们 Serving 层欠缺的一环。建议把"基于工作流前瞻的模型预热/驻留决策"纳入我们多智能体编排的路线图,而不是靠 KServe 的被动扩缩容兜底。
  - 关键数据点:三类工作流场景、异构 GPU 池上,突发到达下端到端 makespan 最多降 36.8%、总体 p95 完成延迟降 25.9%;每完成一个 session 最多省 24.63 GPU-秒。

- **[Tuning Collective Patterns to Alleviate Congestion in Shared AI Clusters (REACT)](https://arxiv.org/abs/2609.04417)** — 在通信库层(NCCL shim)按拥塞实时调整集合通信拓扑,单方即可部署,无需交换机/全局调度支持。
  - 核心思路:共享云集群里,一个用户的训练作业会被别人的作业或背景流量拖慢,而现有抗拥塞方案要么假设能全局调度所有作业、要么依赖交换机自适应路由——在"你只控制得了自己作业"的共享云里都不适用。REACT 工作在应用(通信库)层:用现成 flow 统计在运行时检测拥塞,在保持信息交换语义不变的前提下调整集合通信模式(如换 AllReduce 树里哪个节点做聚合、改变入射流集合),从而绕开拥塞链路。原型是 NCCL 之上的 shim。
  - 对我们的启示:这条路线对"运行在别人云上的托管训练"特别有价值——我们无法要求底层网络做自适应路由,但可以在自己的通信中间件里单方部署。若我们提供跨云/混合云的训练服务,把 REACT 式的"拥塞感知集合通信重排"做进通信中间件,是不改客户网络就能拿到确定收益的差异化能力。
  - 关键数据点:共享学术 GPU 集群实测,拥塞下算法带宽提升 13%–38%;仿真中多种拥塞场景最高提升 75%。

## 值得泛读(9 篇)

- [CIERA: Cross-Iteration Exponent Reuse for Lossless Allgather in Sharded MoE Training](https://arxiv.org/abs/2609.04609) — 观察到 warmup 后多数权重指数位跨迭代不变,只传符号+尾数、本地缓存指数,做到 bit 级无损的 MoE Allgather 压缩;OLMoE-1B-7B/16 GPU 上较无损基线 3.70×,128 GPU 预计 4.28×。
- [BASP: Communication-Efficient Batch-Aware Sequence Parallelism for LLM Training](https://arxiv.org/abs/2609.03151) — 现有序列并行"batch 无关",按微批大小把 GPU 切成不相交序列并行组以缩小 all-to-all 组、局部化通信;A100 集群上 Llama/Qwen 端到端训练提速 1.17–1.31×,精度显存不变。
- [AceSpec: An Asymmetric Edge-Cloud Collaborative Framework for Communication-Efficient LLM Inference](https://arxiv.org/abs/2609.02514) — 边云投机解码,用空闲边端算力预构概率状态缓存,把网络级流水线冲刷变成 O(1) 本地查表 + 非对称通信协议;50 Kbps WAN 下仍近峰值,吞吐最高 3.52×。
- [DRLM: Deep Reinforcement Learning-Based LLM Query Orchestration in Edge Environments](https://arxiv.org/abs/2609.00442) — 用 PPO 做边缘 LLM 查询编排,含质量估计器+延迟预测器;附 22 万+条测量、8 个模型族/5 量化级的基准数据集;推理延迟降至多 51%、排队延迟降 67%,精度损失 ≤8%。
- [mzCache: On-Device LLM Memory Management under Multitasking](https://arxiv.org/abs/2609.01338) — 移动多任务下 LLM 显存被 OS 驱逐后恢复慢的问题,用细粒度共享缓冲 + 混合 swap/后向驱逐,借统一内存做 GPU 零等待推理;TTFT 较存储回退式部分卸载降 2.1–5.5×。
- [GreenPipe: Power Modeling for Containerized DNN Inference on Kubernetes Edge Nodes](https://arxiv.org/abs/2609.04952) — 无 RAPL 的 ARM 边缘节点上,用外部功率计训练多资源回归模型、按容器比例归因功耗;K3s 测试床上系统级 MAPE 6.3–9.4%,较 CPU-only 基线均降 26.9%。
- [Para-Pipe: Exploiting Hierarchical Operator Parallelism of ML Computational Graphs on SoCs](https://arxiv.org/abs/2609.04168) — 挖掘 ML 计算图的层次化算子并行,面向 SoC 上的调度与流水。
- [Every Kernel Is a Join: Automatic Multi-GPU Parallelism for AI Computations in Einsummable](https://arxiv.org/abs/2609.03905) — 把 AI 计算的每个 kernel 视为 join,自动推导多 GPU 并行方案。
- [Scaling Inference Prefill with High-Radix Photonic Interconnects](https://arxiv.org/abs/2609.01821) — 用高基数光互连扩展推理 prefill 阶段,偏体系结构/互连层前瞻。

## 趋势观察

- **本周主线全在"共享/多租户下的干扰治理",而非单机峰值**:精选 5 篇里 4 篇(AInfer-PD、MeanField、Characterizing、REACT)都在回答同一个问题——当 GPU/网络被多方共享时,如何保证不踩 SLA。这与我们做多租户 AI 平台的痛点高度重合,信号很明确:学界的注意力正从"单作业跑多快"转向"共跑不塌陷"。
- **MoE 成为通信优化的集中战场**:CIERA(Allgather 无损压缩)、BASP(序列并行分组)、AInfer-PD(MoE rollout 的 P/D 复用)三篇都围绕 MoE/大规模并行的通信瓶颈,且不约而同强调"无损/语义保持"——说明大家开始拒绝早期那种牺牲数值精度换带宽的做法。
- **P/D 拆分之争出现"原地复用"反方**:主流 disaggregation(分离 prefill/decode 池)之外,AInfer-PD 代表的"原地复用 + 通信隔离"给出另一条更省资源的路线,尤其贴 agentic/RL rollout 这种 P/D 天然长期共存的负载。值得持续跟踪两条路线的适用边界。
- **边缘/端侧推理是稳定的一条副线**:AceSpec、DRLM、mzCache、GreenPipe 四篇覆盖边云协同投机解码、RL 查询编排、端侧多任务显存、容器化功耗建模——边缘 AI 基础设施的系统问题正在被逐条啃下,和数据中心侧是两套评价体系(带宽免疫、TTFT、功耗 MAPE)。
- **数据质量说明**:本周 arxiv API 限流导致 cs.LG / cs.PF 补充查询未取回,结论以 cs.DC 类目 25 篇为基础;serving 侧(vLLM/SGLang 专项改进)可能有遗漏,下周补扫时留意。
