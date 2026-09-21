# AI 系统论文周报 2026-09-21

> 检索窗口:2026-09-14 ~ 2026-09-21(arxiv submittedDate 过去 7 天)
> 类目:cs.DC / cs.PF / cs.LG,关键词覆盖 LLM serving、GPU 调度/集群、分布式训练、KV cache、投机解码、自动扩缩容等
> 窗口内命中 53 篇,按"做产品相关"筛选后精选 5 篇、泛读 10 篇

## 本周精选(5 篇)

- **[An Approximate Queueing Model of LLM Inference Serving for SLO-Driven Autoscaling](http://arxiv.org/abs/2609.20957)** — 用三参数排队模型预测 TTFT/ITL,驱动 SLO 感知的推理副本自动扩缩容,且直接在 OpenShift 上验证。
  - 核心思路:把 prefill/decode 复用执行建模成马尔可夫排队系统,只用三个参数刻画"模型-加速器"对——每轮基础开销、每 token 计算成本、每 token KV cache 访问成本;这三参数可直接从线上观测到的延迟反推出来。用它做闭环控制器按 SLO 调副本数。
  - 关键数据点:H100 上 ITL 平均相对误差 Llama-3.1-8B 约 5%、Qwen2.5-14B 约 8%,TTFT 误差 14%/16%。在 OpenShift H100 集群跟踪 4 倍负载爬坡,127 个控制周期下 SLO 命中显著优于对照;作为对照的 decode 吞吐分析器(无延迟目标)在 128 个周期里错过 27 次,且少配 4%~28% 副本。控制器在环预测的 TTFT/ITL 中位误差分别 ≤5% 与 ≤9%。
  - 对我们的启示:这是"可解释的白盒扩缩容"路线,和 KEDA/HPA 那种纯指标反应式扩容形成对比。我们的推理平台如果要做 SLO 保障级弹性,应当内置一个"模型-加速器 profiling → 排队模型 → 控制器"的三段式组件;三参数可在线拟合意味着不需要离线压测每个模型,能显著降低接入新模型的运维成本。作者已在 OpenShift 跑通,可作为对标 OAI 弹性能力的直接参照。

- **[Decomposing Predictive Kubernetes Autoscaling for LLM Serving Under Long Startup Delays](http://arxiv.org/abs/2609.20874)** — 拆解预测式 K8s 自动扩缩容的四个因子,给出"冷启动 2-10 分钟"场景下到底哪个因子真正有用的实证答案。
  - 核心思路:LLM 副本启动要加载多 GB 权重、耗时 2-10 分钟,纯反应式扩容结构性滞后。把预测式扩容拆成四因子——token 感知需求追踪、启动延迟前瞻(lookahead)、有界不确定性余量(UCB)、被控对象状态观测,逐一隔离测贡献。结论:一个简单 EWMA + 延迟前瞻 + UCB 余量就能拿到绝大部分收益,Kalman 滤波变体并不稳定改善成本-SLO 权衡。
  - 关键数据点:TTFT SLO 违约率从反应式(基于 QPS)的 53% 降到 0.5%(5 个随机种子);其中 lookahead 单独就是最大因子,带来 14 倍下降。真实 K8s 集群(Qwen2.5-7B / A100 / vLLM)验证:相对 KEDA 反应式扩容,延迟感知前瞻控制器把 TTFT 违约从 63.5% 降到 3.7%。作者还明确区分了哪些结论是 K8s actuation 特有、哪些对所有 LLM serving 通用。
  - 对我们的启示:直接回答了"预测式扩容值不值得做、要做哪部分"的产品决策。给出一个高性价比最小实现:EWMA 预测 + 按副本启动时长做前瞻 + UCB 上界余量,不用上重的 Kalman。context length(经 KV cache 压力)比请求速率更能拖垮 TTFT——这提示我们的扩容指标必须 token 感知,不能只看 QPS。与上一篇搭配,构成本周"LLM 弹性"双子星。

- **[Token Latency Fairness: Performance Isolation for Multi-Tenant LLM Serving (FairInference)](http://arxiv.org/abs/2609.18112)** — 提出 δ-token 公平性保证,给多租户 LLM 服务做 token 级延迟隔离。
  - 核心思路:现有隔离方案(排队/批处理公平)只均衡长期吞吐,不保证延迟,行为良好的租户仍会被"吵闹邻居"拖慢 token 级延迟。FairInference 给出 δ-token 保证:某 token 在独占下 d 时间生成,多租户下保证在 d+δ 内生成。实现上调度器强制每 token 截止时间,同时对 GPU 算力共享延迟和共享 KV cache 显存引入的额外延迟做界定与核算——关键在于不依赖细粒度硬件调度/资源分配就能限住延迟尖峰。
  - 关键数据点:有效限住良好租户的 token 级延迟尖峰,同时相对 SOTA serving 系统整体吞吐还有提升(论文以隔离保证 + 吞吐不降为主要卖点)。
  - 对我们的启示:多租户是企业级 AI 平台的核心诉求,也是对标 OAI 的关键差异点。这篇给出的是"SLA 可承诺"的隔离原语——我们可以把 δ-token 作为对外可售卖的 QoS 等级(如"金牌租户额外延迟不超过 δ")。它不需要 MPS/MIG 级硬件切分即可实现软隔离,落地成本低,适合先在调度层做。

- **[DeepShare: Assurance-Driven Deep Learning Job Scheduling for Multi-Tenant Clusters](http://arxiv.org/abs/2609.16682)** — 用统一的"租户保障信号"作为运行时控制回路,协调配额、排队、抢占、GPU 共享四类决策。
  - 核心思路:多租户 GPU 集群常常"利用率低但租户还在排队",根因是配额、队列排序、抢占、GPU 共享各自被不同局部信号驱动、互相打架。DeepShare 用一个连续的 tenant-assurance 信号统一协调:弹性配额借用、租户级运行时预测、成本感知的 best-effort 抢占、干扰感知的 MPS 共置,并用同一信号决定何时回收借出容量、何时收紧共享。
  - 关键数据点:23,859 个 Venus 作业 + 3,200 内部作业的 trace 实验中平均 GPU 利用率 70.58%(比最强非侵入式共享 baseline +29.5%),平均排队延迟 -46%;16 卡 K8s 测试床上平均 JCT -34%,保障型租户 QoS 达成率 93%。
  - 对我们的启示:直击我们调度器"配额/抢占/共享各管一段"的通病。产品化方向是引入一个跨模块的租户保障 SLI 作为总控信号,而非继续堆各自独立的策略旋钮。弹性配额借用 + 到点回收的模式,能把"给足配额但利用率低"和"利用率高但租户饿死"两难同时缓解,是多租户售卖的直接卖点。

- **[DLB: Distributed Load Balancing at Scale for Generative AI Inference](http://arxiv.org/abs/2609.21079)** — Google 生产环境跑了 22 个月的分布式负载均衡器,面向异构服务时间的生成式 AI 推理。
  - 核心思路:生成式 AI 推理服务时间高度异构、多阶段,传统负载均衡靠过量预留保 SLO,成本高。DLB 用可扩展的分布式设计 + 点对点探测(peer-to-peer probing)维持对全局服务器容量的实时视图,并持续在线学习延迟模型来估计路由决策的延迟影响,从而适配异构硬件与多样模型架构;论文还给了路由算法稳定性与全局性能的理论保证。
  - 关键数据点:在 Google 部署 22 个月,服务数千个模型、每秒百万级请求;生产迁移分析显示相对旧 baseline 中位延迟 -17%、p95 尾延迟 -13%(统计显著)。
  - 对我们的启示:难得的超大规模生产实证。要点一是"路由决策要基于在线学习的延迟模型而非静态权重/轮询",对我们跨异构 GPU(不同代次/不同厂商)混部的推理网关尤为关键;要点二是 P2P 探测的去中心化架构可避免中心化 LB 成为瓶颈。可作为我们推理流量入口层演进的参考架构。

## 值得泛读(10 篇)

- [PipeSwift: Revisiting Pipeline Parallelism for Large-Scale Completion-Oriented Agentic LLM Serving](http://arxiv.org/abs/2609.16491) — agentic 负载以完成时间(JCT)而非 token 级 SLO 为目标,重估流水线并行;360B+ MoE / 64×H800 上 JCT 比 SGLang wide-EP 快至多 1.45x、比 vLLM PP2 快 2.33x。
- [PrefixBench-H100: Characterizing Prefix Reuse and Time-to-First-Token in H100 LLM Serving](http://arxiv.org/abs/2609.19657) — 可复现基准,系统刻画 vLLM/TensorRT-LLM 前缀复用(system prompt/RAG/agent 场景)何时真正降 TTFT、何时被 cache 压力吃掉,结论:剩余跨运行时差异出在调度层而非 cache 本身。
- [COMPASS-ABS: Reducing Fragmentation in Shared GPU Clusters for Deep Learning Training](http://arxiv.org/abs/2609.18519) — 提出不依赖历史负载分布的碎片度量 SIF,调度器把集群状态约束在锚定空间内,证明 SIF 有界(2/N),物理+仿真集群上降 DLT 作业完成时间。
- [Zero-I/O Fault Recovery for Sharded Deep Learning via Dynamic Framework Dependency Rebinding (AccelPact)](http://arxiv.org/abs/2609.18178) — 网络瞬断时设备显存其实完好,靠重绑 FSDP 缓存的通信句柄实现零 I/O 内存内恢复;免 checkpoint 回放,goodput 相对冷重启提升 1.197x~1.698x,零代码改动。
- [Validating Hybrid-State Cache Recovery for GLM-5.3-Flash with vLLM and LMCache](http://arxiv.org/abs/2609.15030) — vLLM+LMCache 四路 TP 下外部 KV cache 命中恢复的一致性坑(调度器少记一个 token),给出严格前缀查找修复;CPU 重载降 TTFT 46-64%。生产用 LMCache 的团队值得一看。
- [Weave: Fine-Grained Dynamic SM Scheduling in an MoE Megakernel for Compute-Communication Overlap](http://arxiv.org/abs/2609.21483) — MoE 专家并行下按每层/每 GPU 路由结果动态切分 SM(通信 vs 计算),4×H100 上 MoE 层几何平均加速 2.89x、端到端 1.33x。
- [Accelerating Sharded Data Parallelism at Scale with Federated Learning](http://arxiv.org/abs/2609.20359) — 借联邦学习思路把大规模分片 DP 拆成松耦合联邦组降通信;Llama3.1-8B/512×A100 上数据处理快至多 8.04x、评估困惑度更低。
- [Not All AI Agents Are Equal: Characterizing Resource and Performance Dynamics](http://arxiv.org/abs/2609.19947) — 实测 RAG/web 搜索/编码三类 agent 的资源动态,发现更快的 LLM 或更多 CPU 不一定加速 agent;CPU 感知的工具准入 + 任务感知 CPU 分配使 CPU 敏感任务延迟改善约 5.4x。
- [Rosetta: Automating First-Principles Performance Modeling Using Multi-Agent LLMs](http://arxiv.org/abs/2609.19376) — 用多智能体 LLM 自动化第一性原理性能建模,和上面几篇"性能模型驱动调度/扩容"是同一趋势的工具侧。
- [ETCInfer: An Energy-efficient Thermal-aware Cooling-joint Scheduler for LLM Inference in AI Datacenters](http://arxiv.org/abs/2609.15230) — 把散热/能耗纳入 LLM 推理调度联合优化,数据中心 TCO/绿色算力方向的信号。

## 趋势观察

- **"性能模型驱动的弹性/调度"成为本周最集中的方向**:精选里两篇自动扩缩容(2609.20957 排队模型、2609.20874 K8s 四因子拆解)、一篇多租户调度(DeepShare)、一篇生产负载均衡(DLB),外加泛读的 Rosetta,共同指向一个模式——不再靠静态阈值/QPS,而是用可在线拟合的延迟/排队模型闭环控制。对我们产品的直接含义:推理平台的弹性与调度组件应从"指标反应式"升级到"模型预测式",且模型参数要能在线估计以降低新模型接入成本。
- **token 感知 + KV cache 压力成为共识性的一等指标**:多篇不约而同指出 context length(经 KV cache 压力)比请求速率更能决定 TTFT/延迟(2609.20874、2609.20957、2609.18112、2609.19657)。我们的 SLO 指标体系、扩容触发器、多租户隔离都应把 KV cache 占用/上下文长度显式建模,而非停留在 QPS/并发数。
- **多租户隔离从"吞吐公平"走向"延迟保证"**:FairInference 的 δ-token 保证 + DeepShare 的租户保障信号,标志企业级卖点从"公平共享"升级到"可承诺的 QoS/SLA"。这正是对标 OAI 的差异化机会点。
- **agentic 负载正在改写 serving 目标函数**:PipeSwift 与 agent 资源刻画论文都在说,agent 场景的一等目标是完成时间(JCT)与工具/CPU 资源动态,而非传统的 TTFT/TPOT。若我们要支撑 agent 平台,serving 层调度目标需要重新定义。
- **训练侧本周聚焦"容错与通信降本"**:AccelPact(零 I/O 内存恢复)、FL+FSDP(联邦式降通信)、COMPASS-ABS(降碎片)三篇,反映大规模训练的痛点仍是断点续训成本与互联带宽,而非算法本身。
