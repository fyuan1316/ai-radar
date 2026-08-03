# AI 系统论文周报 2026-08-03

> 覆盖窗口:约 2026-07-27 ~ 08-03,arxiv cs.DC / cs.LG / cs.PF。
> 数据源:arxiv API(本次多次 429/503 限流,分批取回 cs.DC/cs.PF/cs.LG 提交流水后人工筛选)。因周末 arxiv 无新 listing,最新一批停在 07-31。精选论文均读过 abstract/intro/experiments 再落笔。

## 本周精选(5 篇)

- **[DeltaServe: Host-Agnostic Co-Serving of Inference and Fine-Tuning for LLMs](https://arxiv.org/abs/2607.28848)** — 把"为峰值预留、平时闲置"的推理算力,在不违反 SLO 的前提下回收去跑 LoRA 微调。
  - 核心思路:推理服务按峰值配置,低谷时大量 GPU 算力空转。DeltaServe 利用"推理 prefill 前向"与"LoRA 微调前向"共享执行结构,通过一个只要求引擎支持 multi-LoRA batching 的极简 hook 接入;用 SLO 感知调度器,只在推理有余量时准入并执行微调,调度由离线标定、在线细化的 CUDA-graph 感知时延模型驱动。已接入 vLLM、SGLang、S-LoRA。
  - 关键数据点:在某公司生产 trace 上,DeltaServe(vLLM)相比 LLMStation 微调吞吐 **2.9x** 且推理 SLO 达标率 100%(LLMStation 只有 85%);相比 vLLM+torchtune 基线微调吞吐高 **39%**,零额外硬件、SLO 全达标。
  - 对我们的启示:这条"推理/微调同池共serving"路线直接命中我们的两块企业级卖点——GPU 利用率经济性 + 模型生命周期(持续微调/对齐)。产品上应把"闲时算力回收跑微调作业"做成调度器的一等能力,而不是把训练池和推理池物理隔离硬编码;接入面做成 multi-LoRA hook 这种轻量适配,才能同时兼容 vLLM/SGLang 而不绑死单一引擎。

- **[Queue-Theoretic Admission Control for Multi-Tenant GPU Clusters](https://arxiv.org/abs/2607.28223)** — 给多租户 GPU 集群的"作业还要排多久"一个可证明的排队论上界,而不是拍脑袋的贪心启发式。
  - 核心思路:现有系统用贪心准入、对等待时间无任何形式化保证。本文把 GPU 集群准入建成多类、多资源排队网络,证明待处理队列可分解为"可报价作业"(稳态下等待时间有界)与"不可行作业"(不重配就无有限上界);对可报价作业,把每条集群队列建成 M/G/k,有效服务台数 k 由向量装箱归约确定,在随机占优假设下给出 O(1/(1-ρ)) 的等待时间标度;并证明多维资源需求下的最优准入排序是 NP-hard(从向量装箱归约)。在 Kueue(K8s 标准作业排队器)+ CPU/内存/GPU(经 DRA)上实测验证:有效 k 能正确识别瓶颈资源维度,Little 定律精确成立,Erlang-C 近似一致地偏保守高估等待。
  - 关键数据点:验证平台就是 Kueue + Kubernetes Dynamic Resource Allocation(DRA);等待时间标度 O(1/(1-ρ)),Erlang-C 上界方向偏保守(利于给用户报 SLA)。
  - 对我们的启示:这是我们做多租户 GPU 配额/排队产品能力时可以直接落的理论骨架——把 Kueue + DRA 当准入基座(与我们 npu-dra-plugin 的 DRA 路线一致),给租户"预计排队时长"这种可承诺 SLA 而非黑箱。可报价/不可行的二分,天然对应控制台里"能排上 vs 必须扩容或降配"的用户提示;NP-hard 结论也提醒我们别追求最优排序,做保守可证明的近似即可。

- **[InferScale: GPU-Native KV Injection for Personalized LLM Serving](https://arxiv.org/abs/2607.27090)** — 面向"带持久记忆的个性化/Agent 请求",把反复 prefill 同一段记忆换成可复用的 KV 状态直接注入。
  - 核心思路:Mem0/MemGPT/Zep 这类记忆系统检索出相关记忆再拼进 prompt,迫使服务引擎对同样内容反复 prefill,检索预算越大 TTFT 越高。InferScale 预计算每条记忆事实的 KV 表示 + 语义 embedding 存在 GPU,serving 时检索并把 KV 直接注入 vLLM 的 paged cache;用 Chunked RoPE(存旋转前的 key、注入时按实际位置施加 RoPE)解决动态拼装记忆的位置编码问题;再用 Context-Window Encoding(编码时带一小段前文上下文、只缓存目标事实 KV)补回独立编码丢失的跨事实上下文。全程走 vLLM 的 KV-connector 接口,无需改引擎、无需微调模型。
  - 关键数据点:LoCoMo 上三个开源权重模型,k=50 检索预算时 TTFT 降 **72-79%(3.6-4.8x)**,准确率 60.3% vs Mem0 的 63.3%(几乎持平但省掉 serving 时重算),并发下吞吐 **3.7-4.5x**。
  - 对我们的启示:Agent/记忆型负载正把"重复 prefill"变成新的成本大头。我们的推理网关应把"记忆/知识片段的 KV 预计算 + 缓存复用"做成平台能力,而不是让每个应用各自在 prompt 层拼接。关键工程点是走引擎的 KV-connector 扩展面(不 fork 引擎)+ 解决位置编码错位(Chunked RoPE),这决定了能否与上游 vLLM 长期共存;与上周 Talaria 的"会话亲和/KV 局部性"合起来看,KV 状态正在从引擎内部缓存升级为可被平台调度、复用、放置的一等资产。

- **[SmartGen: Seamless Disaggregated LLM Inference with Selective KV Cache Transfer](https://arxiv.org/abs/2607.28150)** — PD 分离部署在租用云实例上时,别整份搬 KV,只选关键 KV 条目跨节点传,绕开网络瓶颈。
  - 核心思路:prefill/decode 分离已是主流,但自托管跑在租用云实例上时,节点间搬运巨大 KV cache 极易打满有限的内部网络带宽。SmartGen 只选择性传输关键 KV 条目,用三条数据通路:1) 基于 profile 的主动通路,在 prefill 阶段识别并推送关键 KV 到 decode 节点;2) 并行按需通路,decode 时同时抓远端与本地 KV;3) 投机通路,最终把全部 KV 补齐到 decode 节点。
  - 关键数据点:相比典型的"全量 KV 传输",time-to-second-token 最多降 **4.3x**,后续 decode 性能与准确率相当。
  - 对我们的启示:如果我们的产品要支持客户在通用云/裸租实例上跑 PD 分离(而非自建高带宽 RDMA 集群),KV 传输就是隐形瓶颈。选择性/分级 KV 传输应作为分离式推理的默认策略,并把它和网络拓扑(节点间带宽)一起纳入调度决策——在低带宽环境自动退化为"选择性传 + 投机补齐",而不是假设人人都有 InfiniBand。

- **[Rethinking AI Cloud Infrastructure for Agentic Serving Systems with the Aries Experimentation Framework](https://arxiv.org/abs/2607.29069)** — 用一套全栈实验框架实测"Agent 负载到底卡在哪",给出面向 Agent 原生服务系统的设计主张。
  - 核心思路:自治 Agent 把"反复推理 + 持久上下文 + 沙箱工具执行"耦合在一起,冲击传统 LLM serving 假设。Aries 把任务语义与执行配置解耦,能跨异构沙箱基底重建带系统遥测的跨组件 Agent 轨迹,并用商用平台的生产 trace 佐证。
  - 关键数据点(实测结论而非加速倍数):1) 以 token 为中心的指标会漏掉非推理瓶颈;2) 保留更多上下文对准确率收益递减、却明显吃掉服务容量;3) 工具沙箱在长空闲与短资源爆发间交替,而当前基于快照的状态管理让激进挂起代价很高;附带安全分析强调需收缩沙箱攻击面。
  - 对我们的启示:这几乎是给"Agent 原生基础设施"写的需求文档。三条对产品的直接指令:计量与计费别只按 token(要按轨迹级/工具执行计量);上下文管理要做自适应裁剪(不是无脑保留全历史);工具沙箱要做弹性资源管理 + 轻量可挂起(快照太重)+ 最小攻击面。我们若要把产品从"模型推理平台"升级到"Agent 运行平台",这四条是调度层和安全层必须新增的能力维度。

## 值得泛读(10 篇)

- [SLIM: Saturation-Aware Lightweight Performance Modeling for LLM Serving](https://arxiv.org/abs/2607.29575) — 半解析性能模型定位吞吐饱和源于 decode 阶段 attention kernel 的近乎恒定算术强度(而非单纯 batch 变大);配套 Batching Configuration Advisor 在时延约束下选最优 batch,并省出最多 55GB 显存分配。适合做容量规划/自动 batch 调参。
- [DualDecoder: Accelerate Long Context LLM Inference by Predictive Prefetch](https://arxiv.org/abs/2607.26475) — 长上下文稀疏 KV 卸载到主存时,辅助状态成新瓶颈;用"下一 token 关键 KV 可由投机 token 预测"做主动预取并与计算重叠,解码吞吐最高 2.62x。
- [KAP: Bridging the Knowledge Selection-Runtime Consumption Gap in LLM Systems](https://arxiv.org/abs/2607.24260) — 把 RAG/图检索产出的结构化先验编译成"运行时访问计划" IR,治理物理 KV 访问而不改 prompt 语义;128K 长上下文下把 proposal 期 KV 访问降到源 KV 的 5.5%。KV 从"token 感知"转向"计划/知识感知"消费。
- [Back from the Future: Key-Value Cache Management by Counter-Causal Surprise](https://arxiv.org/abs/2607.27600) — 用反因果注意力掩码(每个位置只看未来)给 KV 条目打分,能被近期 token 良好预测的旧 token 即冗余可逐出;免训练、有单层快速近似。
- [Denial of Deadline: Network-Driven Accuracy Collapse in Distributed Inference Pipelines](https://arxiv.org/abs/2607.24692) — 快路径+慢路径+协调层的分级推理架构暴露新攻击面:Yo-Yo 突发流量把良性用户的慢路径预测挤过截止时间被丢弃,导致"精度崩塌"(自动驾驶多目标跟踪 p99 92ms→2s,HOTA 掉 7 点)。提醒路由/合并/隔离层要防 workload 攻击。
- [Characterizing LLM Kernel Access and Memory Interaction in Multi-Partition NUMA GPUs](https://arxiv.org/abs/2607.28824) — 实测多分区 NUMA GPU(如 MI300/GH 这类)上 LLM kernel 的访存与跨分区交互特征,为分区调度提供画像。
- [Incast-Free MoE Rate-Based Scheduling](https://arxiv.org/abs/2607.26340) — MoE all-to-all 的 incast 拥塞用基于速率的调度消解,网络层优化。
- [PowerScale: Energy-Efficient Geo-Distributed Model Training with Federated Datacenter Power](https://arxiv.org/abs/2607.25650) — 地理分布式训练下按联邦数据中心电力做能效调度,绿色算力方向。
- [ServerlessT2I: Efficient Text-to-Image Workflow Serving on a Serverless Platform](https://arxiv.org/abs/2607.26566) — 文生图工作流的 serverless 高效服务,多阶段流水线冷启/调度。
- [A Photonic-CXL Memory Appliance for Scalable KV Cache Management in LLM Inference](https://arxiv.org/abs/2607.27187) — 用光互连 + CXL 内存设备扩展 KV cache 容量,硬件/内存分层方向(与上周 HyMCache 的 CXL 主题呼应)。

## 趋势观察

- **"Agent 原生服务"从愿景变成可测量的工程议题**。本周 Aries(29069)直接实测 Agent 负载,把结论钉在"token 指标失灵、上下文收益递减、沙箱空闲/爆发交替";InferScale(27090)则把 Agent 的记忆 prefill 成本用 KV 复用打下来。合上周的 Talaria,信号很清楚:下一代服务系统的一等公民是"会话/轨迹 + 记忆 KV + 工具沙箱",而不是无状态请求。我们要把产品叙事从"模型推理平台"往"Agent 运行平台"抬,调度、计量、安全三层都要新增维度。
- **GPU 经济性从"共置省地"进到"闲时算力再利用 + 可证明准入"**。上周主线是共置/干扰建模(Roomie),本周 DeltaServe(28848)更进一步:把闲置推理算力回收去跑微调,把利用率从空间维(谁和谁挤)扩到时间维(谷时干什么);而 Admission Control(28223)给多租户排队第一次上了排队论的可证明上界,且直接跑在 Kueue+K8s DRA 上——这与我们的 DRA 路线同频,可直接借鉴。
- **KV cache 研究彻底从"压缩/量化"转向"访问编排与复用"**。本周涉 KV 的多篇(KAP 24260、InferScale 27090、DualDecoder 26475、Counter-Causal 27600、SmartGen 28150)不再比谁压得狠,而是比谁把 KV 当作可预取、可注入、可选择性传输、可跨请求复用的"物理执行资产"来调度。KV 正在从引擎内部缓存,升级为平台级可调度对象——这是我们推理网关值得押注的抽象层。
- **服务层安全/可靠性成稳定支线**。继上周的投机解码对抗(21804)后,本周 Denial of Deadline(24692)把攻击面指向"快慢路径协调层",说明分级/路由式推理架构的鲁棒性开始被系统性审视。我们做推理网关的路由/合并/隔离时,要把"shaped workload 攻击"纳入威胁模型。
- **相较上周**:冷启动/模型下发的密集讨论本周降温(无新强论文),取而代之的是"算力再利用 + 准入保证 + KV 编排"三条更偏日常稳态运营的主线;研究重心从"怎么把模型快速拉起来"进一步下沉到"稳态多租户里怎么把每一分 GPU 榨干且给得出承诺"。
