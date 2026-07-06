# AI 系统论文周报 2026-07-06

> 数据源:arxiv API(https://export.arxiv.org/api/query),提交时间窗 2026-06-29 ~ 2026-07-06,类目 cs.DC 为主 + cs.LG/cs.PF 关键词交叉,去重后窗口内命中 58 篇,系统方向约 20 篇。本期 http 端点已 301 强制跳 https,改用 `curl -L https://...` 后取数正常(上期的沙箱限流问题解除)。精选论文均已读 abstract;实验数据点来自各论文 abstract 自报。

## 本周精选(5 篇)

- **[Towards Load-Aware Prefill Deflection for Disaggregated LLM Serving](https://arxiv.org/abs/2607.02043)** — 拆解式(PD 分离)serving 里,让 decode 节点在自己空闲算力上顺手把请求的 prefill 也做了,消掉跨节点 KV 搬运。
  - 核心思路:PD 分离本意是让 prefill/decode 互不干扰,却制造了新的不对称——突发重尾负载下 prefill 节点被打满、decode 节点算力闲置。作者在 2P2D 的 A100 生产集群上实测发现:prefill 计算本身只占 P95 TTFT 的 2–23%,剩下全是排队 + 跨节点 GPU-GPU KV-cache 传输。方案是"prefill 偏转"调度器:对每个排队请求估算它在 prefill 节点上会看到的 TTFT,再在每个 decode 节点上搜索"能塞进去且不破坏在途 decode 的 TBT SLO 的最大 chunk 调度",划算就把 prefill 就地插进 decode 节点做 chunked-prefill。因为偏转请求的 prefill 就地跑,跨节点 KV 传输被彻底消除。
  - 对我们的启示:这直接修正了一个正在被行业当默认最佳实践的东西——"PD 分离 = 更好"。它给出的产品判断是:disaggregated serving 的瓶颈往往不是算力配比,而是 KV 传输与排队,盲目分离反而在突发负载下拉高尾延迟。我们的 serving 平台如果已经或计划上 PD 分离,调度器不能只做静态角色绑定,应当支持"角色借用/偏转"这类动态跨池调度;而且评估 PD 分离收益时,基线要盯 P95 TTFT 分解(排队 vs 传输 vs 计算),而非只看吞吐。实现基于 vLLM,接入成本可控,值得做 PoC。
  - 关键数据点:相比 SOTA 拆解式调度器,P95 TTFT 最高降 81%,SLO 达成率最高提升 79%,每请求路由开销亚毫秒;DeepSeek-V2-Lite + 生产 trace。

- **[HYPIC: Accelerating Hybrid-Attention LLM Serving with Position-Independent Caching](https://arxiv.org/abs/2607.01299)** — 第一个让"位置无关缓存(PIC)"和"混合注意力(线性+全注意力)"两条降本路线共存的 serving 系统,专打 RAG/agent 的长拼接 prompt。
  - 核心思路:RAG 和 agentic serving 里,prompt 由多段独立片段拼成长上下文,prefill 成为主成本。此前两条降本路线各走各的——PIC 允许非连续、跨请求共享片段复用 KV;混合注意力用线性注意力替掉大部分全注意力层降复杂度——但二者无法叠加:PIC 的逐 token KV 复用原语套不到线性注意力的逐请求递归状态上。HYPIC 找到缺失的代数原语"段累积转移算子",连同每段的零起点终态一起缓存,实现独立缓存片段的近乎精确、常数时间状态组合;对剩下的全注意力层,只在段边界重算一个很小的 seam 窗口就能恢复跨段回看;再利用段级自包含把 cache-miss 的冷长请求并行化,把过去的尾延迟大户变成可加速负载。
  - 对我们的启示:这是 RAG/agent 平台的核心引擎级优化。行业正同时押注"混合注意力模型"(降算力)和"前缀/位置无关缓存"(降 prefill),而这篇证明二者此前互斥、现在可合。产品含义:(1) 我们若在 serving 层做 RAG 知识库片段缓存,要意识到一旦底层模型换成混合注意力(线性注意力占主),现成 PIC 会失效,需要 HYPIC 这类新原语;(2) "冷长请求并行化"这一手直接对着我们最难的尾延迟场景。建议把它作为 RAG serving 的缓存层选型参照。
  - 关键数据点:4 个混合注意力模型 + 5 个负载上,TTFT 平均降 2.45x,峰值吞吐最高提升 2.0x,精度较全重算仅差 3.3 个百分点内。

- **[HBM Is Not All You Need: Efficient Disaggregated LLM Serving across Memory-heterogeneous Accelerators](https://arxiv.org/abs/2606.29986)** — 把 prefill 放在便宜的 GDDR 加速器、decode 放在贵的 HBM GPU 上,甚至跨厂商配对,专攻 goodput-per-dollar。
  - 核心思路:prefill 是算力受限、decode 是带宽受限,而今天数据中心 GPU 全靠昂贵 HBM,其带宽在 prefill 阶段几乎全程闲置。MemHA 思路是用 GDDR 加速器跑 prefill、HBM GPU 跑 decode;推到最省钱形态必然跨厂商,这打破单厂商分离的两个前提——两端原生共享的 KV 格式、共享软件栈。HMA-Serve 用三招解决:(1) 分阶段量化,prefill 用厂商原生低精度冲吞吐、decode 保持 BF16 高精度;(2) compute-transfer 流水,把每层 KV 传输和后续层 prefill 重叠降 TTFT;(3) 延迟反量化,网上只传原始量化字节、在 decode GPU 上惰性重建,省网络带宽和 HBM。
  - 对我们的启示:这条线正中"成本"这个企业级客户最痛的神经。产品判断:硬件选型不必全 HBM——prefill 池可以用更便宜甚至异厂商的 GDDR 卡,单位成本吞吐大幅改善。但代价是要在 serving 层自己解决"跨厂商 KV 格式不兼容 + 软件栈不统一",这恰是平台厂商的价值点(客户自己搞不定)。我们做多云/异构 GPU 供给时,可以把"混合内存/混合厂商 PD 分离"作为差异化的降本卖点,尤其对预算敏感、又不追求极致延迟的批量推理客户。
  - 关键数据点:4 个 Qwen3 模型(4B–32B)+ 3 条生产 trace,相比同构内存方法 goodput 最高 3.2x、goodput-per-dollar 最高 4.8x,生成质量无可测损失。

- **[DeadPool: Resilient LLM Training with Hot-Swapping via Zero-Overhead Checkpoint](https://arxiv.org/abs/2607.01646)** — 大规模训练里用"热插拔备用节点 + 无开销内存 checkpoint"同时干掉容错的两个代价:无故障期开销和恢复延迟。
  - 核心思路:万卡级训练跑数月,软硬件栈到处出故障;现有容错要么无故障期就有不小开销,要么恢复慢,尤其少数节点永久失效时。DeadPool 靠热插拔——用备用节点替换失效节点、不终止整个 job:(1) 用非关键路径的内存 checkpoint 做空间冗余,与计算重叠,因此无故障执行零开销;(2) 一套通信器重建协议在运行时把失效节点换成备用节点。永久失效时靠内存 checkpoint 以最小重算重建内存状态。
  - 对我们的启示:训练平台的可靠性 SLA 正在从"能恢复"升级到"恢复几乎不停机、且日常不交税"。对我们托管训练(尤其给客户跑长周期大模型预训练/微调)是直接可用的架构方向:传统"周期性写盘 checkpoint + 失败重启"在大规模下既慢又占带宽,热插拔 + 内存增量是更优 Pareto 点。值得对标其通信器重建协议,评估在我们训练编排层(配合备用节点池 / spare 容量管理)落地的路径。与上期 Concordia(推理侧 GPU 状态级容错)呼应:训练与推理的容错都在向"节点/状态级热恢复"演进。
  - 关键数据点:最高 512 张 A100、模型至 65B,无故障期零 checkpoint 开销,热插拔恢复在 40 秒内完成。

- **[TraceLab: Characterizing Coding Agent Workloads for LLM Serving](https://arxiv.org/abs/2606.30560)** — 公开了一份真实编码 agent(Claude Code / Codex)负载 trace,并给出 serving 侧优化机会,数据集开源。
  - 核心思路:编码 agent 正成为 agentic LLM 的主力应用,但高效 serving 缺真实负载数据。作者采集并公开约 4,300 个编码 agent 会话(约 35 万次 LLM step、43 万次工具调用,来自自己日常用 Claude Code 和 Codex)。分析发现编码 agent 负载的鲜明特征:长自主循环、长上下文短输出、工具调用种类多且重尾、prefix cache 命中率高但不完美。据此指出四个具体优化方向:更低开销的工具调用、感知追加长度的 prefill、语义感知的工具延迟预测、以及围绕"人类节奏间隙"的 KV-cache 管理。
  - 对我们的启示:这是一篇"帮产品定需求"的实测数据论文,直接刻画了我们自己的核心负载形态(agent + 工具调用)。产品含义:(1) 编码 agent 的 serving 优化重心不在生成吞吐,而在长上下文管理、prefix 缓存命中和工具调用开销——我们的 serving SLA 和自动扩缩容指标应据此调整(TTFT/prefix 命中率优先于 output tokens/s);(2) "人类节奏间隙"意味着会话有可预测的空窗,可用于 KV-cache 分层驻留/淘汰策略;(3) 开源 trace(github.com/uw-syfi/TraceLab)可直接拿来做我们 serving 基准和调度器压测的负载源,省去自采成本。
  - 关键数据点:约 4,300 会话 / 35 万 LLM step / 43 万工具调用;定性刻画为主(长循环、长上下文短输出、重尾工具调用、高但不完美的 prefix 命中);数据集、采集管线、分析代码全开源。

## 值得泛读(9 篇)

- [OmniPilot: An Uncertainty-Aware LLM Inference Advisor for Heterogeneous GPU Clusters](https://arxiv.org/abs/2607.01579) — 异构 GPU 集群上"下单前"帮你选 GPU 型号/TP degree/精度的顾问:分位数成本模型 + OOD 弃权层,超出测量支持域时诚实地"不建议"。460 组基准上吞吐预测 MAPE 6.2%、top-1 准确率 95%;OOD 样本上误差飙到 24–46% 但弃权层能全部标为低置信。对做"配置推荐/容量建议"产品功能很对味。
- [Festina: Energy-Aware Scheduling for Serverless LLM Serving on Shared GPUs](https://arxiv.org/abs/2606.30391) — 能耗优先的 serverless LLM serving 控制面,联合调度请求放置、SM 分区、GPU 工作点,在 TTFT/TBT SLO 下把集群能耗最高降 56%、SLO 达成基本持平(2% 内)。功率/能耗作为调度维度的又一实证。
- [Spandana: Reconciling Strict SLOs with Low Cost under Fine-Grained Load Fluctuations](https://arxiv.org/abs/2606.30533) — 把 SLO 执行和成本优化解耦:每个 VM 旁挂轻量控制器,能达标的请求留 VM、其余转发到现成 FaaS(如 Lambda)。CPU 利用率 76–86%,成本较三个 SOTA 降 5–44%。VM/FaaS 混合弹性的参考架构。
- [MosaicKV: Serving Long-Context LLM with Dynamic Two-D KV Cache Compression](https://arxiv.org/abs/2607.00760) — 同时压 KV cache 的序列维和通道维(此前多只压一维),按段选压缩策略避免精度崩。H800 上 attention 最高 16x 加速、decode 延迟降 4.8x、吞吐 7.3x、显存降 3x,LongBench/RULER 精度仅损 1.76%。
- [ELDR: Expert-Locality-Aware Decode Routing for PD-Disaggregated MoE Serving](https://arxiv.org/abs/2607.00466) — MoE 的 decode 路由不能只看负载:同样满载的 worker 因每步要加载各自 batch 激活的专家权重而延迟不同。ELDR 从 prefill 激活构建"专家签名"预测生成期激活的专家,做局部性感知路由。vLLM 实现、至 40 GPU,中位 TPOT 降 5.9–13.9%,输出不变。
- [Omni-Flow: Unified Workflow Orchestration and Distributed KV Cache Sharing for Multimodal Inference](https://arxiv.org/abs/2606.31093) — 多模态推理的三层抽象框架(Control/Data/Compute Flow):Python DSL 编排异构单元、跨角色分布式 KV cache 抽象(GPU/CPU/SSD 三级分页)、让 diffusion 直接复用 LLM 前向路径。对做"文本+图像+语音"统一推理流水的平台抽象有参考。
- [Mixture-of-Parallelisms (MoP): Memory-Efficient Training Stack for MoE Models](https://arxiv.org/abs/2607.01844) — 在 MoE 训练各层/各阶段组合并特化多种并行技术 + 新的 optimizer step 策略,不到 12 个 8×H200 节点无损预训练万亿参数、百万上下文。每 GPU 吞吐较强调优 FSDP2 基线 4.7–8.2x,基线在 64–128K 上下文外即 OOM。
- [SMART-MIG: A Learning Framework for Scalable and Energy-Efficient GPU Scheduling](https://arxiv.org/abs/2606.29775) — 用 Mean-Field 多智能体强化学习做大规模 MIG 重分区 + 启发式作业调度,重分区复杂度随规模保持常数。能耗-延误效率较静态分区提升 18%,距能耗理论下界 27%。对 MIG 切分 + 调度的联合优化有参考。
- [WattGPU: Predicting Inference Power and Latency on Unseen GPUs and LLMs](https://arxiv.org/abs/2607.02391) — 只用公开的 LLM 元数据 + GPU 规格预测未见过的 GPU/LLM 组合的功耗与 ITL,无需实机 profiling。42 个开源 LLM × 8 GPU 上,离线功耗预测中位误差 ≤3.4%、server 场景延迟 ≤8.5%,较 TDP/roofline 基线误差降约 2–4x。对"选卡/能耗预估"工具化有用,代码开源。

## 趋势观察

- **拆解式(PD 分离)serving 从"是否分离"进入"如何精细化分离"的深水区。** 本周至少 4 篇(Prefill Deflection、HMA-Serve、ELDR,以及上周延续的 heterogeneous PD 综述 2606.29708)都在 PD 分离这个既定前提上做二阶优化:偏转/借用角色消 KV 传输、跨内存跨厂商配对省钱、按 MoE 专家局部性路由 decode。信号很明确——PD 分离已是生产默认,但"静态两池 + 只均衡负载"的第一代实现正被证明在突发负载、MoE、异构硬件下有明显浪费。我们的 serving 平台若已上 PD 分离,下一步竞争力在调度器的动态性(角色借用、局部性感知、跨池 KV 生命周期管理),而非分离本身。
- **RAG / agent 负载正在重写 serving 的优化目标函数。** HYPIC(RAG 长拼接 + 位置无关缓存 + 混合注意力)、TraceLab(编码 agent 真实 trace)、SmoothAgent(2607.00151,agent 上下文变换 lookahead 预执行,TTFT 最高降 11.9x)三篇共同表明:agentic 负载的成本大头是"长上下文的 prefill / KV 复用 / 上下文反复变换",而非生成吞吐。这直接改变产品的 SLA 与扩缩容指标——TTFT、prefix 命中率、上下文变换开销取代 output tokens/s 成为一线指标。对我们(自身就是 agent 平台)尤其贴身。
- **"混合注意力模型"开始给 serving 系统提要求。** HYPIC 明确指出:一旦底层模型从全注意力转向线性/混合注意力,现成的前缀缓存/PIC 原语会失效,需要新的代数抽象。这是一个前瞻信号——模型架构演进(线性注意力降本)会反过来要求 serving 层重构缓存原语。我们的 serving roadmap 需要预留"缓存层随模型架构可插拔"的弹性,不能把 KV-cache 复用逻辑写死在全注意力假设上。
- **能耗/成本继续作为独立调度维度固化。** Festina(能耗降 56%)、SMART-MIG(能耗-延误联合、MIG 切分)、WattGPU(免 profiling 预测功耗选卡)、HMA-Serve(goodput-per-dollar)四篇从不同角度把"每瓦/每美元产出"当一等目标。延续上期(功率响应数据中心、训练能耗建模)的判断:吞吐红利吃尽后,企业级差异化转向机密/可靠/省电省钱,这条主线本周进一步坐实,且工具化(WattGPU 免实机预测)在推进。
- **与上期(06-29)对比:** 上期 cs.LG/cs.PF 交叉查询因沙箱限流未取到、泛读偏少,趋势判断偏"MoE serving + 非功能性约束(机密/容错/功率)"两条线;本期取数恢复正常、命中 58 篇,主线从"MoE 显存解耦"进一步细化到"PD 分离的二阶动态优化",并新增了一条清晰的"agent/RAG 负载重塑 serving 目标"主线(上期只有边缘投机解码一篇沾边)。容错线从上期的推理侧(Concordia)扩展到本期训练侧(DeadPool),两侧都在向"节点/状态级热恢复"收敛。整体看,上游 serving 研究正从"单卡/单引擎显存优化"上移到"多池调度动态性 + 负载特性驱动的目标重定义"。
