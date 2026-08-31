# AI 系统论文周报 2026-08-31

覆盖窗口:2026-08-24 ~ 2026-08-31(按 arxiv `submittedDate` 过去 7 天)。
检索类目 cs.DC / cs.LG / cs.PF / cs.AI,关键词组:LLM/model serving、inference optimization、GPU scheduling/cluster/sharing、distributed training、pipeline/tensor parallelism、KV cache、speculative decoding、continuous batching、MLOps/model registry/feature store。
去重后 185 篇命中,落在 7 天窗口内 31 篇,按"做产品/做系统"标准筛出以下。

## 本周精选

- **[More GPUs or a Smaller Cache? Tensor Parallelism versus KV Compression for Memory-Bound LLM Serving](https://arxiv.org/abs/2608.23962)** — 首次把张量并行和 KV 压缩放到同一条"每百万 token 成本 vs 时延"轴上比,结论是绝大多数场景压缩更划算。
  - 核心思路:用 A100/A40/H100 校准的 profiled simulator,把 TP(degree 1~8)与 KV 压缩(16/8/4-bit、keep-ratio 到 0.25)统一成成本轴,寻找成本等价交叉点——结果没找到交叉点。
  - 关键数据点:所有档位下压缩都便宜 1.20x~2.00x;决定策略的分界是"模型大小相对显存",80GB 卡上约 36B 参数是墙。墙以下压缩每美元容量 16.5x,而八倍 GPU 只换来 1.21x;墙以上 TP 不是选项而是入场券(Llama-2-70B 单 A100 任何 KV 设置都跑不起来,瓶颈是权重不是 KV)。但只有 TP 能降时延,压缩反而让单 token 时延恶化 8%~93%。
  - 对我们的启示:给我们平台的"显存不够怎么办"决策树一个可落地的默认规则——`模型参数 < 显存拐点(80GB≈36B)` 时首选 KV 量化/压缩而不是加卡扩 TP,把成本咨询做成产品内的自动建议;超过拐点则 TP 是硬门槛,不必再纠结压缩。可直接进我们的容量规划/推荐配置模块。

- **[Launch-Bound and Substitutable: Why Three Inference Optimizations Fail to Pay Off in Mixture-of-Experts Models](https://arxiv.org/abs/2608.26612)** — 对 MoE 推理三大"常识优化"做实测证伪,提醒别照搬 dense 模型的优化直觉。
  - 核心思路:在 OLMoE-1B-7B、DeepSeek-V2-Lite、Qwen3-30B-A3B 上逐 token dump 路由,测融合 kernel、INT4 量化、消除 graph break 的真实收益。
  - 关键数据点:融合 Triton kernel 孤立看 5.6x~9.0x,端到端只有 0.999x(天花板仅 1.07x),因为每次前向被约一千次 kernel launch 拖住;INT4 平均只改 0.53/8 个专家,但重放这些变化仅复现 2.7% 质量损失(专家可替代非专精);移除全部 23 个 graph break 反而慢 3 倍。
  - 对我们的启示:我们如果向企业客户宣传"MoE 推理已量化/已融合 kernel 加速",要重新校准话术和 benchmark——这些优化在 MoE 上端到端几乎无收益甚至有害。产品的自动调优/优化开关面板应对 MoE 与 dense 区分默认值,MoE 上优先解决 launch overhead(CUDA graph 整体化)而不是堆 kernel 融合。

- **[VPP: Virtual Pipeline Parallelism for Efficient Chunked Prefill in Long-Context LLM Inference](https://arxiv.org/abs/2608.26523)** — 固定 chunk 大小、靠虚拟流水阶段消气泡,在 Ascend 910C 上实现,和我们的国产算力路线直接相关。
  - 核心思路:chunked prefill 里等大 chunk 因后段 attend 更长前缀而时延失衡形成气泡;已有做法靠动态调 chunk 大小(DCPP)但长序列上调度开销划不来。VPP 保持 chunk 固定,用 V 形虚拟阶段遍历,让每个 chunk 的重中间阶段与邻居的轻头尾阶段重叠,配异步通信和流水打包。
  - 关键数据点:在 vLLM-Ascend 上、16 张 Ascend 910C、三个 MoE 模型、序列到 1M token;长序列吞吐比 DCPP 高最多 13.1%,混合负载 6.7%,短序列不退化;512K DeepSeek-V3.1 prefill 把气泡比从 6.4% 降到 0.1%(相对 DCPP 降 98.0%)。
  - 对我们的启示:实现基座是 vLLM-Ascend,和我们跟进的昇腾/HAMi 生态同一条链路,可直接评估把 VPP 长上下文 prefill 优化纳入我们的国产卡推理栈;尤其面向 1M 长上下文/RAG 场景的差异化卖点。值得让算力团队复现其气泡消除方案。

- **[Elastic KV Cache for LLM Serving: A Working Reclamation Mechanism, and Why Chunked Prefill Already Closes the Gap](https://arxiv.org/abs/2608.23658)** — 造了个 userspace 弹性 KV 显存回收机制,却诚实报告了负结果,值得当"别做什么"的参考。
  - 核心思路:serving 引擎启动时为最坏情况 prefill 永久预留一块显存,decode 阶段闲置。作者用 CUDA 虚拟内存把两个物理句柄映射到同一连续虚拟区间,调度器看下一批一步预判,decode 时把预留借给 KV 池、prefill 前归还;纯 userspace、不改 attention kernel、不打驱动补丁,毫秒级 decommit、十毫秒级 recommit。
  - 关键数据点:诚实负结果——只有当小 prefill chunk 严重伤 prefill 时延时才划算,而实测该惩罚很小(chunk 8192 vs 32768,中位 TTFT 只差约 1%,因 prefill 计算受限、decode 每步每序列仅约 1 token);直接调低 `max_num_batched_tokens` 回收的 KV 比控制器还多、时延几乎相同;预留在 TP 下被稀释(TP1 占 KV 16% → TP4 仅 2.7%)。
  - 对我们的启示:省下一条弯路——不要为"回收 prefill 预留显存"投入复杂的弹性 VMM 控制器,现有 chunked prefill + 调低 batched token 上限已基本吃掉收益。但其开源的 userspace elastic-VMM allocator 可作为我们做显存超分/多租户共享的底层组件复用。

- **[Simthesizer: An Agent-Driven Simulation Framework for LLM Serving Systems](https://arxiv.org/abs/2608.24650)** — 用编码 agent 驱动的可组合 serving 模拟器,应对模拟器跟不上真实系统演进的问题。
  - 核心思路:现有 serving 模拟器是单体管线,每加一种新机制(agentic workflow、disaggregated serving)都要侵入式重写。Simthesizer 把完整 serving workflow(含控制决策)统一表达成一张动态图,再用带护栏和保真校验的编码 agent 把自然语言特性请求"降解"到该抽象上,演进同一个共享模拟器而非每个特性建一个新的。
  - 关键数据点:同一 coding agent 下,基于 Simthesizer 的扩展相对 vLLM 真机平均吞吐误差 2.51%(现有模拟器 6.03%);同负载下比 LLMServingSim2.0 / Vidur 分别快最多 284.96x / 23.19x。
  - 对我们的启示:我们做容量规划、SLA 预估、调度策略验证时,与其维护自研模拟器,不如评估这种"agent 演进单一模拟器"的路子——用 LLM 把产品需求直接映射成模拟场景,降低跟进新推理机制(PD 分离、agentic)的维护成本。可作为内部性能预测/配置推荐工具的候选底座。

## 值得泛读

- [Characterization of Request and Token Energy Costs for LLM Inference Workloads on GPU Platforms](https://arxiv.org/abs/2608.28044) — H100/H200 上分解 prefill/generation 能耗模型;token 能耗随输出变长下降但整批请求能耗上升,MoE 放大该效应,主张 serving 同时优化请求能耗与 token 能耗。做能耗计费/绿色调度可参考。
- [Understanding the Energy Scaling of LLM Inference Across Context Lengths and Attention Architectures](https://arxiv.org/abs/2608.25096) — 实测 MHA/GQA/GQA+SWA decode 能耗随上下文的缩放:MHA 增长最陡,GQA+SWA 近乎恒定;batching 把每 token 能耗和时延降最多 87%。选型/配置能效指南。
- [Minima-KV: Retention-Preserving KV Cache Compression with Mixed-Format Paged Attention](https://arxiv.org/abs/2608.23834) — 混合格式分页 attention,近期/受保护 anchor 页 FP8、老页打包 TQ3,不驱逐在用页;单卡 RTX PRO 6000 上相对 BF16 3.50x 压缩,长上下文质量几乎无损。
- [psRL: Efficient Training for Agentic AI via Training-Time Prefix Sharing](https://arxiv.org/abs/2608.25683) — agentic RL 训练瓶颈从 rollout 转向 update,利用样本间前缀冗余做前缀共享 + 自研 KV 管理,生产 trace 上吞吐比现有系统高最多 5.2x。做 RL 训练平台可关注。
- [A Probabilistic Interpretation of KV Cache Eviction](https://arxiv.org/abs/2608.28293) — 把 KV 驱逐形式化(证明其计算困难),用概率视角化约为期望估计并做 decode-time 修正,现有启发式方法被解释为零方差有偏估计,鲁棒性更好。理论性偏强但对 KV 系统设计有指导。

## 趋势观察

- **主线依旧是"推理侧成本/显存工程",且本周明显转向证伪与实测**。多篇不是提新招而是把老招放到统一成本轴/端到端上打假:TP vs KV 压缩没有交叉点(压缩恒赢显存墙以下)、MoE 上 kernel 融合/INT4/去 graph-break 端到端不赚甚至亏、弹性 KV 回收被 chunked prefill 抢先。信号:这一波推理优化红利进入"边际收益递减 + 需要诚实 benchmark"阶段,产品侧宣传口径要跟着校准。
- **能耗/能效成显性议题**:一周内两篇独立的 GPU 能耗特征化(请求 vs token 能耗、attention 架构对 decode 能耗缩放),把"每 token 计费 vs 按能耗消耗"的账算清。对做计费、绿色/成本调度是新的产品切入点。
- **KV cache 仍是绝对热点但在分化**:压缩(Minima-KV 混合格式分页)、驱逐(概率化形式)、显存回收(弹性 VMM)、长上下文 chunked prefill 流水(VPP)四个子方向并行推进;长上下文(到 1M token)和 MoE 是共同放大器。
- **国产算力开始出现在系统论文里**:VPP 直接在 vLLM-Ascend + 910C 上做且针对 DeepSeek-V3.1,和我们跟进的昇腾/HAMi 生态同链路,值得持续盯这条线。
- 相比典型周,本周纯 GPU 集群调度/MLOps/feature store 类几乎空窗,重心高度集中在单机~小规模并行的推理内核与显存层。
