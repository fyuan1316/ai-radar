# AI 系统论文周报 2026-09-28

覆盖窗口:约 2026-09-21 ~ 2026-09-28(arxiv cs.DC / cs.LG / cs.PF 新提交)。
数据源:arxiv 官方 listing(export.arxiv.org API 本周返 406,走 arxiv.org/list 页 + WebSearch 补漏)+ 逐篇读 abstract/intro/experiments。
本周方向高度集中在**推理服务的"控制面"化**:PD 分离弹性、KV cache 全生命周期管理、跨模型编排与故障快恢——都是产品可直接落地的方向。

---

## 本周精选(5 篇)

- **[Cross-Model Autoscaling for Shared LLM Serving](https://arxiv.org/abs/2609.29160)** — 固定 GPU 预算下多模型共享集群的跨模型自动扩缩容框架 TRE。
  - 核心思路:提出 Token Service Share(TSS)这一"需求归一化"指标,让异构模型、不同 SLO 等级之间的健康度可横向比较;控制面把"快速救火"(rescue)和"慢速再平衡"(rebalance)拆成两条路径,在总预算不变的前提下把活跃副本从富余模型挪给赤字最大的模型。构建在 Kubernetes 热切换服务栈上,**不改推理调度器**。
  - 对我们的启示:这正是多租户 model-as-a-service 平台缺的一层。我们现在的 HPA/KPA 只看单模型本地信号(队列、KV 占用),没有跨模型的"全局预算再分配"。TSS 这种归一化健康度可以直接做成我们控制面的调度输入;"救火/再平衡分离"值得抄进产品的 autoscaler 状态机,避免抖动。
  - 关键数据点:P95 端到端延迟相比"基于 KV cache 的反应式自动扩缩容"降低 11.9%~79.0%,P99 降低 12.5%~72.6%;生产 trace 上 P95/P99 分别降 50.8%/63.7% 与 79.0%/72.6%。

- **[Crossflow: Prefill-Decode Elasticity for Agentic LLM Serving](https://arxiv.org/abs/2609.27085)** — Meta 团队,给 PD 分离服务加"细粒度弹性",不改节点角色。
  - 核心思路:观测到生产集群 prefill/decode token 比值波动极大(分钟级峰均比达 4.7x,agentic trace 单日小时级跨度中位 24.5x);静态按 P95 配比会浪费高达 17% 集群容量。Crossflow 让每个 decode 节点发布一个"短时、可撤销的租约(lease)",约束本地 prefill 计算、KV 容量、传输与产出上限,从而在比"重新分配副本(需数十分钟)"细得多的时间尺度上动态互借 prefill/decode 资源。
  - 对我们的启示:如果我们要上 PD 分离(对标 Dynamo/llm-d),静态配比一定会踩容量浪费的坑。lease 机制比"重排副本"轻量,适合做成我们数据面里的一个短周期控制回路;而且它对 agentic/多轮长上下文场景收益最大——正是企业客户最关心的负载。
  - 关键数据点:token 吞吐相比静态 PD 几何均值提升 16.2%~17.4%,高负载下最高 +43.4%;各测试点平均 TTFT 均下降。

- **[Fast Recovery for LLM Serving via Decoupled Device Memory Lifetime in Dynamo](https://arxiv.org/abs/2609.25451)** — NVIDIA,把"引擎故障恢复"从分钟级压到秒级。
  - 核心思路:关键观察是绝大多数故障是"设备保留型"——引擎进程挂了但 GPU 显存里的权重还在。GPU Memory Service(GMS)把显存所有权与引擎进程解耦,多个引擎只读共享常驻权重、各自持有私有可变执行态;再用待机 GPU 上的预初始化 Shadow Engine 走"晋升(promotion)"而非"重建"来恢复。
  - 对我们的启示:企业级 SLA 里恢复时间(MTTR)和为容灾预留的冗余产能是真金白银。GMS 这种"权重与进程生命周期解耦"能显著砍掉冷启动重初始化,值得作为我们推理运行时的弹性/容灾能力规划项;固定 4-8 GiB 的开销与模型大小无关,成本可控。
  - 关键数据点:恢复时间 < 7 秒,相比 warm restart 基线快 13~29 倍(在 vLLM 与 SGLang 上跨 4 个模型验证);回放分析显示可挽回 79% 因恢复损失的 GPU-hours;每 GPU 固定 4-8 GiB 显存开销。

- **[When Fancy Eviction Fails: Rethinking Cache Replacement for LLM Prefix Reuse](https://arxiv.org/abs/2609.28870)** — Harvard(Minlan Yu / Juncheng Yang),用生产 trace 打脸"花哨淘汰策略"。
  - 核心思路:在生产 trace 上评测 14 种淘汰算法,结论是——为传统缓存设计的复杂策略相比 LRU 几乎没有额外收益,因为 prefix 复用遵循"会话节律",recency(最近性)是异常强的预测信号。作者不主张替换 LRU,而是给 LRU 打三个补丁:一次性 prefix 快速降级、面向"昂贵 miss"的计算感知部分淘汰、随容量变化的淘汰粒度。
  - 对我们的启示:直接省掉我们在 prefix cache 淘汰策略上的过度工程——别上复杂 ML/启发式淘汰,把工程量投到"计算感知淘汰(优先保住重算代价高的前缀)"和"一次性前缀快速降级"上。这是能立刻写进 KV cache 组件需求文档的结论。
  - 关键数据点:14 种算法横评;复杂策略相比 LRU 收益甚微,但与 Belady 最优仍有显著 gap(说明优化空间在别处,不在"更聪明的淘汰")。

- **[SARA: SLO-Aware Resource Allocation for Disaggregated Agentic LLM Services](https://arxiv.org/abs/2609.26763)** — 用排队论给 PD 分离服务做"可解析"的资源配置。
  - 核心思路:把 prefill/decode 建模为 M/G/k 与广义生灭过程、KV cache 传输建模为 M/G/1 队列,推导轻尾/重尾负载的尾延迟特征,把"负载+硬件参数"显式映射到各阶段 SLO 约束与最小资源需求;摆脱现有系统靠硬件 profiling / 配置枚举 / 启发式调度的做法。
  - 对我们的启示:给容量规划提供白盒公式而非黑盒调参——对做成本核算、SLO 报价、售前容量评估的产品化场景很有用。结论"prefill 受算力约束、decode 受 HBM 约束"应作为我们 PD 硬件选型(算力型 vs 大显存型)的默认假设。
  - 关键数据点:阶段级 SLO 预测平均误差 < 5%;同等部署成本下相比 SOTA 平均 goodput 提升 26.6%。

---

## 值得泛读(8 篇)

- [The KV Cache Working Set: Online Capacity Planning for LLM Inference Systems](https://arxiv.org/abs/2609.27746) — KVSET 用 Mattson stack 算法在线估算不同容量下的 cache 命中率,求"达到目标命中率所需最小 KV 容量",免去逐配置仿真;可直接做 KV 容量规划工具。
- [From Inference Engine to Inference Control Plane: Connecting vLLM, llm-d, and the Evolution of Efficient Distributed LLM Serving](https://arxiv.org/abs/2609.23130) — 综述/立场论文,把 vLLM(执行层:PagedAttention/连续批处理)与 llm-d(控制面:where/when/policy)分层,提"推理执行规划器"概念;适合对齐我们的产品架构叙事,无新实验。
- [EMA: Elastic and Performance Transparent Memory Across GPUs](https://arxiv.org/abs/2609.27040) — Ion Stoica 组,跨 GPU 的弹性、性能透明显存抽象,和 KV/权重跨卡共享方向相关。
- [KREX: Concurrent Kernel Benchmarking on Shared GPUs via Region-Granular Exclusivity](https://arxiv.org/abs/2609.30057) — 共享 GPU 上按 region 粒度做互斥的并发 kernel benchmark,GPU 共享/多租隔离评测方法。
- [An Approximate Queueing Model of LLM Inference Serving for SLO-Driven Autoscaling](https://arxiv.org/abs/2609.20957) — 用近似排队模型驱动 SLO 感知自动扩缩容,和 SARA 互为补充。
- [Decomposing Predictive Kubernetes Autoscaling for LLM Serving Under Long Startup Delays](https://arxiv.org/abs/2609.20874) — 针对 LLM 副本冷启动慢(拉权重、初始化)的 K8s 预测式扩缩容,直击我们线上扩容延迟痛点。
- [Who Pays for the KV Cache? Attributing Shared AI Inference Spend Across Kubernetes and LLM Provider Bills](https://arxiv.org/abs/2609.24991) — 把共享推理成本(尤其 KV cache)在 K8s 与模型账单间做归因,多租户计费/FinOps 参考。
- [Profiling LLM Agent Inference on Blackwell GPUs](https://arxiv.org/abs/2609.29707) — 在 Blackwell 上剖析 agent 推理的能耗去向,新硬件选型与能效评估参考。

---

## 趋势观察

- **"引擎 → 控制面"是本周最强主线。** 多篇论文(TRE 跨模型自动扩缩、Crossflow PD 弹性、Inference Control Plane 立场文、两篇 K8s/排队自动扩缩)都在说同一件事:单机推理引擎(vLLM/SGLang)已趋成熟,竞争与价值正上移到"跨副本/跨模型的编排、放置、状态管理、SLO 决策"这一层。对我们意味着:产品差异化不该再卷单引擎吞吐,而要做好这层控制面。
- **KV cache 从"怎么算"转向"怎么管、谁付钱"。** 本周 KV 相关论文覆盖容量规划(KVSET)、淘汰策略(Fancy Eviction)、故障恢复(Dynamo GMS)、成本归因(Who Pays)、动态编辑恢复(PatchKV)——已是一个完整的"生命周期 + 经济学"话题,而非单点优化。
- **PD 分离进入"弹性/可解析配置"阶段。** 上一波是"要不要分离",本周是 Crossflow(细粒度弹性)、SARA(排队论解析配置)、Power-Aware Provisioning(2609.24639)在解决"分离之后怎么动态配比、怎么按 SLO 定量配资源"。静态按 P95 配比被明确判定为浪费。
- **agentic 负载成为系统设计的新默认假设。** 多篇(Crossflow、SARA、Blackwell profiling)把"多轮、长上下文、突发"的 agent 流量作为主要 target workload,而非传统单轮问答——我们的负载建模与压测基线也应跟进。
- **能效/成本作为一等指标出现。** Joule Point、Blackwell 能耗剖析、Learning to Route for Energy-Efficient Serving 等表明能耗/单位成本正从"事后统计"变成"调度目标"。
