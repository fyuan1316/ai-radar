# AI 系统论文周报 2026-09-14

> 覆盖窗口:2026-09-07 ~ 2026-09-14。数据源:arxiv(cs.DC / cs.LG / cs.PF,系统与基础设施关键词),辅以 WebSearch 查漏。
> 说明:export.arxiv.org API 本周对本 IP 持续 429(Rate exceeded),按惯例改走 arxiv.org 的 cs.DC recent 列表页 + 单篇 abs 页(WebFetch)取数,精选篇均已读 abstract。主结果来自 cs.DC 类目(与"AI 系统/基础设施"最贴合),cs.LG/cs.PF 仅 WebSearch 补扫;serving 侧专项改进可能有遗漏。

## 本周精选(5 篇)

- **[Composable CXL Memory as a Kubernetes-Native Shared Memory for LLM Serving](https://arxiv.org/abs/2609.10790)** — 写了个 K8s DRA 驱动把可组合 CXL 内存变成可调度的集群资源,拿它做 vLLM/llm-d 的跨节点 KV-cache 共享层。
  - 核心思路:驱动按需组合 CXL region,在参与节点上物化为 DAX 设备,并用同一个 CDI(Container Device Interface)名注入到不同节点的 Pod,使跨节点 Pod 访问同一块物理内存。vLLM/llm-d 的共享内存 connector 把这块 region 当 KV-cache tier,内嵌 slot 目录,省掉外部元数据服务。两个副本都跑完整引擎——是"内存池化(memory disaggregation)"而非"prefill/decode 拆分"。
  - 对我们的启示:这几乎是给我们照着抄的架构图。我们对标 OAI 的 KV-cache 复用一直卡在"跨节点前缀命中"——node-local tier 一旦 miss 就得全量重算。这篇证明用 DRA + CDI 就能把 CXL 共享内存做成 K8s 一等调度资源,而且不需要额外的元数据中心。建议把"CXL/共享内存 tier 作为 DRA 资源"列进我们 Serving 平台的 KV-cache 分层路线图,DRA 驱动 + CDI 单名注入这套是可直接复用的落地范式(参见 [[hami-webui-provider-pattern]] 里类似的注解发现/驱动注册思路)。
  - 关键数据点:双节点 + 512 GiB CXL appliance + Qwen2.5-7B-Instruct,跨节点前缀复用把 TTFT 降 5.5×–36.6×,外部命中率 95.4–99.5%;跨节点 vs 同节点复用的延迟差仅 1–4%(池化几乎不额外加延迟)。

- **[Building py-kvcache: A Performance Characterization of External KV Caching for vLLM with NVMe SSDs](https://arxiv.org/abs/2609.11744)** — 系统刻画 vLLM 在 GPU/CPU/NVMe 三级缓存下"外部 KV 缓存 vs 重算"的盈亏平衡点,并给出一个调度器感知的 NVMe offload connector。
  - 核心思路:前缀缓存靠复用 KV 降 TTFT,但短前缀或快 GPU 上,重算可能比从外部缓存加载还快。作者用合成负载 + 长上下文基准 + 生产 trace 测出:缓存性能取决于传输粒度、中间内存占用、传输进入请求调度的时机,而不只是设备带宽。据此做了 py-kvcache——异步 direct I/O + 有界共享 staging + 调度器感知预取(请求还在排队时就开始读盘,与计算重叠)。结论金句:外部 KV 缓存应被当成"因部署而异的准入决策",不是无脑开。
  - 对我们的启示:和上一篇正好互补——CXL 那篇讲"跨节点池化",这篇讲"单节点往 NVMe 下沉"的边界。关键产品动作是把"要不要走外部 KV 缓存"做成 admission 决策而非全局开关:在 H100 上平均请求落在盈亏平衡点以下、GPU 显存自己就够存前缀,盲目开 offload 反而变慢。我们的 Serving 层应内置一个"缓存准入门控",按 GPU 档位/前缀长度/命中率动态决定是否下沉,并把"调度器感知预取"作为 connector 的硬性能力。
  - 关键数据点:80k tokens 时从盘加载比 LMCache 快 2.0×(预取贡献 1.34×);GPU+CPU+盘三级全开比 LMCache 快 1.23×,且与 vLLM 原生 KV Offload 差 ~4%;LongBench/SCBench 上收益延伸到不规则前缀链与多轮负载。

- **[ExaServe: Large-Scale LLM Serving on Exascale HPC Systems](https://arxiv.org/abs/2609.10812)** — 一个 pip 装的框架,把声明式 YAML 编译成超算上可复现的大规模 LLM serving 部署;顺带扒出 Ray Serve 控制面的 O(N²) 瓶颈。
  - 核心思路:云原生 serving 框架在数据中心已成熟,但搬到 leadership-class 超算要处理调度器集成、MPI 启动、加速器选择、node-local 权重 staging、平台补丁一堆工程活。ExaServe 用 YAML 声明这些,在 ALCF Aurora 上从 1 扩到 256 节点(3072 个 vLLM 副本)。非流式推理近线性扩展,但流式因中心化 proxy 在 ~4.7k req/s 触顶(模型服务本身还在 SLO 内);更重要的是发现 Ray Serve 控制面存在 O(N²) 瓶颈,256 节点下集群 bring-up 要 ~30 分钟。
  - 对我们的启示:这是给"用 Ray Serve 做大规模 serving 控制面"的一记警钟。如果我们的推理平台底座依赖 Ray Serve,要提前把"中心化 proxy 的流式吞吐天花板"和"控制面 O(N²) bring-up"列为扩展性风险项,在几百节点规模前就做压测,别等客户上量才发现冷启动 30 分钟。同时"YAML 声明 → 可复现部署"这套抽象值得借鉴到我们的 serving 发布流程。
  - 关键数据点:256 节点非流式达 27.1k req/s(3.8M tokens/s),近线性;流式中心化 proxy 触顶 ~4.7k req/s;256 节点 bring-up ~30 分钟(Ray Serve 控制面 O(N²))。

- **[ContinuumBench: Benchmarking Joint Autoscaling and Placement Across Evaluation Regimes in the Cloud-Edge Continuum](https://arxiv.org/abs/2609.08946)** — 一个把"放置(placement)"和"扩缩容(autoscaling)"联合评测、且用"完成度感知"记账的基准,专治评测里说不清收益到底来自哪。
  - 核心思路:现有云边评测常把 placement 和 scaling 分开研究、把 workload/连通性/校准假设藏起来、用"已完成任务"的指标掩盖没跑完的活。ContinuumBench 用完成度感知记账,把迟到/未完成/丢弃都算成 deadline miss;基于 ECLYPSE 模拟器加入到达、worker 弹性、间歇传输、缓冲、故障来闭合控制环。评测 9 个控制器 × 4 场景 × 2 regime,结论:被测 regime 是容量受限的——是弹性容量而非放置精巧度决定完成率,容量够了之后才轮到自动扩缩策略决定按时率;没有迁移时重新放置几乎无效;记账口径本身会改变控制器排名。
  - 对我们的启示:直接冲着我们做多租户/边云自动扩缩的"评测方法论"来的。最狠的一条是"completion-only 与 completion-aware 记账会得出不同排名"——我们如果只报'平均完成任务'的指标,可能在给自己/客户讲一个虚高的故事。建议把 ContinuumBench 的"完成度感知记账"引入我们的调度回归基准:把迟到和未完成显式计成 miss;同时记住"先保证弹性容量,再谈调度算法精巧"的优先级,别在容量不足时过度投入放置算法。
  - 关键数据点:9 控制器 × 4 场景 × 2 regime;核心为方法学结论(容量优先于放置、迁移是放置生效前提、记账口径改变排名),论文以对比图表为主,无单一加速比。

- **[Analytical Resource Management for Fine-grained MoE Computation-Communication Overlap](https://arxiv.org/abs/2609.07536)** — 用一个"wave 量化"的解析模型 + 启动期资源管理器,解决 MoE 细粒度计算-通信重叠时计算/通信 CTA 争抢 SM 驻留的问题,免 profiling 免重编译。
  - 核心思路:分布式 MoE 推理里,细粒度重叠让通信在部分计算结果就绪时就开始,但做计算和做通信的 CTA 会争抢 SM 上有限的驻留容量。作者不靠离线画像、不靠重编译,而是用解析模型在 launch time 直接算出资源分配,集成进 FLUX 里的 COMET A100 实现,在 3 个 MoE 模型上测。
  - 对我们的启示:MoE 服务栈的通信重叠一直是"调一版画像一版"的体力活,这篇给了个"解析式、亚微秒开销、无需 profiling"的资源分配器思路。对我们做 MoE 推理优化的价值是:重叠调优可以做成运行时自适应而非离线调参,尤其在多模型/多 TP-EP 组合下省掉组合爆炸式的画像。可作为我们 MoE serving 内核层的一个候选组件。
  - 关键数据点:相对 oracle 平均 regret 3.22%、解算器均开销 0.157µs;GEMM2+GatherRS 算子级几何平均 2.528×(最高 4.218×),整个 post-router MoE 层 1.771×(最高 2.584×),整模型 prefill 1.185×(最高 1.439×);在 TP=2/EP=2、序列 ≥4096 上全面优于 COMET / Megatron core-TE / FastMoE。

## 值得泛读(9 篇)

- [Epoch: Compiling Diffusion Blocks for Sparse MoE Serving](https://arxiv.org/abs/2609.09748) — 把扩散语言模型的"block"当编译单元,只让存活/新解码/需刷新的 token 走 routed-expert 计算,避免 dense MoE runtime 每次 forward 重建路由、重算已死 logit;8×H100 上对 LLaDA-MoE/2.0(7B–100B)端到端最高 2.7×,大 batch 下多个 baseline OOM 时仍可行。扩散 LM serving 是新兴方向,值得盯。
- [Entwine: Coordinating Tiled Computation and Fine-Grained Communication across GPUs](https://arxiv.org/abs/2609.11562) — 协调跨 GPU 的分块计算与细粒度通信重叠,和上面 MoE 重叠那篇同一战场的不同切法。
- [Tools-CC-Bench: A Benchmark Suite for Collective Communication with Compression in HPC and AI Workloads](https://arxiv.org/abs/2609.08739) — 面向"带压缩的集合通信"的基准套件,给我们评估通信压缩方案(参见上周 CIERA/BASP 的无损压缩线)一个公开测量工具。
- [A Measurement Study of LLM Inference Trade-offs Across Edge Continuum Hardware](https://arxiv.org/abs/2609.08307) — 跨边缘连续体不同硬件的 LLM 推理权衡实测,边缘部署选型的外部锚点数据。
- [HELIOS: Guardrailed LLM-Driven Evolution of Autonomous Resource Orchestration Policies for Multi-Cloud](https://arxiv.org/abs/2609.09164) — 用 LLM 演化出可执行的 Python 编排策略(而非把 LLM 放在调度关键路径),trace 驱动仿真选优、guardrail 保底;较单云省 45% 成本,无 guardrail 时会退化到 97–98% 高档停机、加了降到 0.17%。注:该篇实际提交日为 2026-07-07,本周在 recent 列表重新出现(疑更新版),仅泛读记录。
- [TFR-GNN: Topology- and Fault-Aware Graph Neural Scheduling for Heterogeneous Distributed Computing Systems](https://arxiv.org/abs/2609.09165) — 拓扑与故障感知的图神经调度,异构集群调度的一种学习式思路。
- [Smart Adaptive Computing Across the Continuum: LLMs in IoT-Edge-Cloud Resource Management](https://arxiv.org/abs/2609.09348) — 把 LLM 用于 IoT-边-云的资源编排,与 HELIOS 呼应的"LLM 做运维大脑"线。
- [MUC-FL: Block-Wise Marginal Utility Contribution for Communication-Efficient Federated Learning](https://arxiv.org/abs/2609.10545) — 按块边际效用做通信高效联邦学习,选择性更新降通信开销。
- [Memory Profiling and Migration for Heterogeneous Memory Architectures](https://arxiv.org/abs/2609.10554) — 异构内存层次下的内存画像与迁移,和 CXL/tiering 那条线底层相关。

## 趋势观察

- **本周主线切到"KV-cache 分层与内存池化"**:精选里 CXL K8s-native 池化(2609.10790)和 py-kvcache 的 NVMe 下沉(2609.11744)是一对镜像——一个横向跨节点共享、一个纵向往盘下沉,共同信号是 KV-cache 正在从"单卡显存里的东西"变成"要跨 GPU/CPU/NVMe/CXL 分层调度的一等资源"。这跟上周"共享/多租户干扰治理"是不同侧面:上周治的是"共跑不塌陷",本周治的是"缓存放哪、值不值得放"。对我们最直接。
- **K8s 原生 + DRA 成为 AI infra 论文的载体**:CXL 那篇直接用 Dynamic Resource Allocation 驱动 + CDI 落地,说明学界也在把创新架在 K8s 调度原语上,而不是另起炉灶。DRA 正在从"设备直通"扩展到"内存/共享资源",值得我们在 DRA 生态上加大投入。
- **MoE 仍是通信优化的集中战场,但从"压缩"转向"重叠/编译"**:上周是 CIERA/BASP 的无损压缩,本周是 MoE 计算-通信重叠的解析式资源管理(2609.07536)、Entwine 的分块重叠、Epoch 的 block 编译——重心从"传更少"转到"算与传重叠得更好 + 编译期消除冗余计算"。
- **serving 控制面的扩展性瓶颈被公开点名**:ExaServe 实测扒出 Ray Serve 控制面 O(N²)、流式中心化 proxy 触顶——这类"控制面而非数据面"的天花板,正是大规模 serving 平台容易忽视的坑,我们做底座选型时应把控制面压测前置。
- **评测方法论开始被单独当研究对象**:ContinuumBench 把"记账口径会改变结论"摆上台面。趋势是学界不再只比谁快,而是质疑"你怎么算的"——我们对外的自动扩缩/多租户 benchmark 要主动采用完成度感知记账,才经得起这波审视。
- **数据质量说明**:export.arxiv.org API 本周持续 429,cs.LG/cs.PF 仅经 WebSearch 补扫、未系统取回;结论以 cs.DC recent 列表(约 23 篇相关)为基础,serving 侧(vLLM/SGLang 专项改进)可能有遗漏,下周 API 恢复后补扫。
