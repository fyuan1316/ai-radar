# AI 系统论文周报 2026-07-20

> 窗口:2026-07-13 ~ 2026-07-20(arxiv 已编入索引至 07-17)。检索类目 cs.DC / cs.PF / cs.LG,按 submittedDate 倒序拉取后本地按关键词(serving / scheduling / GPU / KV cache / MoE / agent / multi-tenant / diffusion 等)筛选。cs.LG/cs.PF 补充检索因 arxiv API 限流未取回(不影响主结论,系统方向论文绝大多数落在 cs.DC)。窗口内命中系统方向论文约 16 篇,下面精选 5 篇、泛读 8 篇。

## 本周精选(5 篇)

- **[JoyNexus: Service-Oriented Multi-Tenant Post-Training for VLA Models](https://arxiv.org/abs/2607.16074)** — 把"微调 / RL / 评测"做成多租户共享底模的服务,而不是给每个租户独占一堆卡。
  - 核心思路:传统算力服务(整卡租赁或批作业)给单租户独占 GPU/CPU,租户要自己做基础设施适配,固定 card-hour 计费对短/突发作业既贵又低效。JoyNexus 把 **Training Model Service / Inference Model Service / Environment Service 三层解耦**,各自暴露 API,后端是**常驻共享底模 + 租户专属 slot**:租户既能直接调高层语义 API(train/rollout/eval),也能用低层 API 自己拼算法;多租户并发提交,各自的 action module、优化器、rollout 记录、policy 版本互相隔离,由全局 Training Queue / Inference Queue 调度。关键优化是 **group batching**:对 model-facing prefix 兼容的异构 VLA 数据 schema 分组,一次共享 backbone 前向覆盖一组样本。
  - 对我们的启示:这正是"模型生命周期即服务"的多租户参考架构,直接对标 OAI 的 fine-tuning/评测管线。产品决策:我们做训练/微调平台时,不应把每个租户的作业当独占资源池,而应走"常驻共享底模 + 租户 slot + 全局队列"路线,把短/突发作业的排队与共享 backbone 复用做进底座;计费也要从 card-hour 转向利用率导向,否则对客户的短作业没有价格竞争力。三服务解耦(训练/推理/环境各自 API)也是我们把 SFT+RL+eval 拼成产品的清晰边界。
  - 关键数据点:相比单租户独占执行,跨租户调度共享资源使聚合 GPU 时间下降、服务利用率提升(论文以 workload 仿真 + group-batching 管线在具身场景实测,未给单一倍数,主张来自 cross-tenant scheduling + 共享 backbone 前向)。

- **[AAFLOW+: Stateful Operator Abstraction with Zero-Copy Distributed KV Cache Orchestration for Multi-Agent Workflows](https://arxiv.org/abs/2607.10987)** — 把 KV cache 提升为一等的分布式系统对象,让多智能体workflow 里的共享上下文靠传输而非重算复用。
  - 核心思路:多智能体系统(检索+规划+推理)本质仍是"文本中心",智能体反复对共享上下文做昂贵 prefill。单请求推理的 KV 复用早已成熟,但通常局限在单机 serving 范围。AAFLOW+ 把 agentic workflow 算子做成**有状态**扩展,把流程编译成通信感知图,同时优化数据、prompt 与可复用模型状态,并提供 KV 的 **materialize / transfer / fork / compose / evict** 算子;运行时做**零拷贝、传输感知执行**,让智能体跨机复用长上下文而不重算。核心判断:在中高带宽网络上,KV 传输优于重算。
  - 对我们的启示:这是"Agent 流量重写服务系统假设"的下一步——从上周 SMetric 的会话调度,推进到把 KV 当集群级共享资源来编排。产品决策:我们的推理平台若要支撑多智能体应用,网关不能只做单机 prefix cache,要引入**跨实例的全局 KV tier + 传输/fork/驱逐算子**,并把"传输 vs 重算"的决策做成带宽感知的运行时策略;这决定多 Agent 场景下的 TTFT 与单位算力成本,是与"只做单机 vLLM"竞品的分水岭。
  - 关键数据点:TTFT 最高降 **50.2x**;16-Agent 规模下多智能体计算成本降 **7.63x**;KV 内存降 **1.72–6.10x**;吞吐提升 **>7.74x**(基于经硬件微基准标定的解析成本模型)。

- **[Scalable LLM Agent Tool Access in the Cloud(云规模 MCP 网关)](https://arxiv.org/abs/2607.15593)** — 把 MCP 从"智能体直连工具"改成"经网关中转",在网关侧统一做工具推荐、访问控制与会话路由。
  - 核心思路:MCP 已成智能体调用外部系统的事实接口,但在云规模下两头都难:工具侧,legacy 服务不能直接被 MCP 调用,协议快速演进带来持续兼容成本;智能体侧,可挂载工具数受 context window 与推理开销限制,工具越多 token 与延迟越高、成功率反而下降;有状态 MCP 后端多副本时维持 session 亲和又把复杂度推给客户端。方案是**云规模 MCP 网关**:打破数据面直连模型,把 legacy 服务接入、异构 MCP 变体归一、访问控制、工具推荐、会话感知路由都收到网关;用**混合检索**做工具选择。
  - 对我们的启示:MCP 网关正在成为 Agent 平台的必备基础设施,和我们做 API 网关/服务网格的能力高度同源。产品决策:我们应把"MCP 网关"作为 Agent 平台的一等组件,提供工具注册/发现、语义工具推荐、会话亲和路由、legacy 服务适配(把现有 REST/gRPC 服务自动包成 MCP);这既解决"工具太多撑爆 context"的真实痛点,也是把我们既有网关能力迁移到 Agent 时代的顺势卡位。
  - 关键数据点:混合检索 Top-15 召回 **98%**;工具规模扩到 **3,000+** 仍保持高选择准确率;工具选择耗时降 **8.9x**、token 用量降 **23.8x**,per-call 开销低且 scale-out 下稳定;含生产部署经验教训。

- **[Don't Predict, Prioritize: Rethinking GPU Reliability Assessment(HeaRank)](https://arxiv.org/abs/2607.15115)** — 放弃"预测 GPU 何时坏",改成"给节点按相对故障风险排序",给风险感知调度一个能落地的信号。
  - 核心思路:大规模 AI 集群里单节点故障会打断同步训练、造成重大损失。作者用生产集群 telemetry 分析发现:双比特错误(DBE)、GPU Lost 等重大故障在时序遥测上**强随机、信噪比低**,精确预测发生时刻本质困难。于是范式转向——不预测绝对时刻,而用 **Learning-to-Rank(HeaRank)** 基于稳定的历史故障模式给全体 GPU 节点算全局风险排名。
  - 对我们的启示:这给"风险感知调度 / 主动运维"提供了一个务实且可评估的抓手,正好补我们多租户 GPU 平台在可观测性/可靠性上的短板(上周昇腾 field study 也把弱可观测性单列为一类痛点)。产品决策:与其承诺"预测故障",不如在调度器里引入**节点故障风险排名**,把高风险节点从关键同步训练作业中优先排空/降级、把可抢占作业往高风险节点放;把 HeaRank 式风险分做成调度插件的输入信号,是比"预测性维护"更能兑现的可靠性卖点。
  - 关键数据点:数千 GPU 生产集群上 AUC **0.83**,优于启发式与 SOTA 排序基线;线上部署中排名前 5% 的节点捕获了 **64%** 的未来故障,而现网系统仅 21%。

- **[Less Experts, Faster Decoding: Cost-Aware Speculative Decoding for MoE(EcoSpec)](https://arxiv.org/abs/2607.12696)** — 给 MoE 的投机解码加"专家激活成本"这一维,别让高概率 draft token 把专家打散、拖垮显存带宽。
  - 核心思路:投机解码(SD)靠并行验证多个 draft token 加速,但现有 draft 选择只优化接受率。在大规模 MoE 上,选哪些 draft token 还决定了验证时**被激活专家的并集**;作者观察到 confidence-driven SD 会引发 **expert scattering**——高概率 draft token 路由到互不相交的专家,增加专家权重的显存搬运、抵消投机收益。EcoSpec 把**预测的边际专家激活成本**并入 draft 选择,用轻量专家预测器 + 动态专家 buffer,偏好那些既保住接受率、又复用当前验证集已覆盖专家的 draft 路径,且不改目标模型验证规则。
  - 对我们的启示:客户上 MoE(DeepSeek/Qwen/GPT-OSS 系)做推理时,投机解码的收益强依赖专家布局与显存带宽——这是"MoE 推理优化不止于算子"的又一证据(呼应上周 UBEP/CAP 的通信/放置主线)。产品决策:我们的推理栈若默认开投机解码,对 MoE 模型要把"专家激活成本"纳入 draft 策略,并在服务层暴露"专家 buffer 大小 / 接受率-带宽权衡"的调优旋钮,而非套用 dense 模型的 SD 默认值。
  - 关键数据点:在 DeepSeek-V3.1(671B)、Qwen3-235B-A22B、GPT-OSS-120B 上,跨推理/编码/QA/对话基准端到端解码最高提速 **1.62x**,同时持续降低活跃专家足迹。

## 值得泛读(8 篇)

- [Every Microsecond Matters: Achieving Near Speed-of-Light Latency in GPU Collectives](https://arxiv.org/abs/2607.16100) — 面向长上下文、decode-heavy 推理里位于 token 生成关键路径上的众多小集合通信,基于 NCCL device-side API 做无屏障同步 + 对称内存/多播,微基准把开销压到硬件 Speed-of-Light 下界的 7% 以内,并提升真实 LLM 推理的 inter-token 延迟与吞吐。对我们做低延迟推理的通信层选型是硬证据。
- [FlashDiff: Efficient Regional Execution and Scheduling for Diffusion Model Serving](https://arxiv.org/abs/2607.12121) — 利用扩散模型"不同 latent 区域收敛速率不同、相邻 step 强相关",只对需要细化的区域执行并把省下的算力在并发请求间再分配;图像/视频/音频实测端到端延迟降 30–97%、吞吐 1.2–2.2x。扩散serving 正在成为独立赛道。
- [Xema: Efficient Diffusion Serving through Fine-Grained Memory Management and Auto-Configuration](https://arxiv.org/abs/2607.11136) — 扩散 serving 的另一路:利用张量生命周期可预测做 trace 引导的显存优化 + 静态布局,只在短时显存压力区间做 offload,并用离线 planner 联合选并行/并发/显存控制;Flux.2/CogVideoX-5B/LTX-2 上 SLO 达成率 +3.7x,规划成本从 6.3 小时降到 197 秒。
- [Agora: Collective and Permissionless Internet-Scale Pretraining of LLMs](https://arxiv.org/abs/2607.13332) — 用带宽高效的流水并行 + 多方容错集合通信,在互联网级链路上做去中心化、无许可预训练(每方只持一段权重);330 个多为消费级 GPU 的节点、40 天训出 8.6B 的 Pluralis-8B,达到集中式 H100 基线 63% 的效率。对"训练算力来源"的边界是个信号。
- [ADASCALE: An Adaptive Scaling and Placement Framework for Microservices Under Dynamics](https://arxiv.org/abs/2607.15681) — cloud-edge 上用 MAPE 环从分布式 trace/service-mesh 指标提取每边每服务需求,联合做 SLO 感知扩缩容 + 最小化"需求加权延迟"的放置;DeathStarBench 上响应时间最多降 1.93x、吞吐最高 2.16x。方法论对我们做 AI 服务网格的自动扩缩容有参考。
- [HeteroMosaic: Heterogeneous Execution for Energy-Efficient Edge LLM Inference](https://arxiv.org/abs/2607.12839) — 边缘 SoC 上把推理拆成保依赖的 micro-batch 暴露 iGPU/NPU 跨加速器重叠,并用异构 roofline 判断何时该混合执行;AMD Ryzen AI 上最高 2.35x 提速、能耗降 45.3%。端侧多芯片协同的落地样本。
- [LongStraw: Long-Context RL Beyond 2M Tokens under a Fixed GPU Budget](https://arxiv.org/abs/2607.14952) — 面向 Agent 长轨迹,把 GRPO 的共享 prompt 无 autograd 前向、只保后续 token 所需状态、逐条 replay 短响应分支,把百万 token 级 RL 后训练塞进固定 GPU 预算;8×H20 上跑到 2.1M 位置、压测达 4.46M(论文明确这是"执行容量"验证而非完整训练正确性)。
- [Overcoming Orchestration Bottlenecks at Exascale: A Decentralized, Policy-Driven Approach for Sim-AI Ensembles](https://arxiv.org/abs/2607.12211) — 面向 exascale 上 sim+AI 集成工作流,用去中心化、策略驱动的编排替代中心调度瓶颈。对超大规模作业编排的架构取向有参考。

## 趋势观察

- **"Agent-native 基础设施"从调度扩到整条栈**:上周还是 SMetric/SiFAR 在会话/通信层做调度,本周直接冒出三件成体系的 Agent 基础设施——AAFLOW+ 把 KV cache 做成跨机一等对象、MCP 网关把工具访问收到统一控制面、LongStraw 专攻 Agent 长轨迹的 RL 后训练。信号很清楚:服务系统正在被"多智能体 + 长上下文 + 工具调用"重写,竞争点从"单机 vLLM 快不快"转向"跨实例 KV 编排 + 工具网关"这层平台能力。
- **"模型生命周期即服务 + 多租户"成为显性主题**:JoyNexus 把 SFT/RL/eval 做成三服务解耦、共享底模 + 租户 slot 的多租户平台,并用 group batching 复用共享 backbone。这与我们对标 OAI 的"微调/对齐/评测管线"高度重合,且给出了"别再整卡独占、按利用率计费"的明确架构与商业取向。
- **扩散(图像/视频/音频)serving 独立成簇**:FlashDiff 与 Xema 同周出现,分别从"区域自适应执行/调度"和"生命周期可预测的显存管理 + 离线 planner"两条路优化扩散 serving。此前 serving 优化几乎全在自回归 LLM,本周扩散被当成一等 serving 负载来做——多模态生成服务的系统层正在成型。
- **GPU 集群可靠性/运维被当成一等系统问题**:HeaRank 把"预测故障时刻"改成"排风险",给风险感知调度一个可评估信号;呼应上周昇腾 field study 把弱可观测性单列痛点。可靠性正从"事后告警"走向"进调度器的输入"。
- **MoE 推理优化继续深化,且都强调"不止算子"**:本周 EcoSpec 把专家激活成本并入投机解码,延续上周 UBEP/CAP(集合通信/专家放置)的判断——MoE 的系统收益要在专家布局、显存带宽、通信这些"算子之外"的维度上抢。
- **去中心化/异构训练算力来源被认真对待**:Agora 用消费级 GPU + 互联网链路做无许可预训练达集中式 63% 效率,HeteroMosaic 做端侧 iGPU/NPU 协同。与上周 ETC/BiDiRL 的"共享集群弹性"合看,"训练算力从哪来、如何在异构且不稳定的资源上不浪费"正成为持续主线。
