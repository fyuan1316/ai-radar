# AI 系统论文周报 2026-10-12

> 窗口:arxiv 2026-10-05 ~ 10-09 提交(cs.DC / cs.PF 为主,cs.LG 关键词查漏)。本周 AI 基础设施方向产出密集,尤其 GPU 共享/算力隔离一类工程论文扎堆。
> 来源:arxiv.org `list/cs.DC`、`list/cs.PF` 列表页 + 逐篇 abs 页(export API 本沙箱被限流,走前端页抓取)。

## 本周精选(5 篇)

- **[Mosaic: GPU Sharing with Latency Guarantees through Kernel-Level Interference Prediction](https://arxiv.org/abs/2610.07504)** — 用 kernel 级干扰预测器把"GPU 共置"从拍脑袋启发式升级成可给 SLO 的调度。(ETH Klimovic 组)
  - 核心思路:现有共置方案要么靠粗粒度启发式、要么靠 simulator 专用的粗指标,都看不清真实干扰来源。Mosaic 显式建模三类干扰机制——thread-block 放置、访存层级争用、SM 内资源争用——用"解析模型 + 轻量学习模型"组合做预测;配套调度器 MosaicSched 做在线 kernel 准入,并在"整卡共置"与"SM 切分"两种策略间择优,最大化 best-effort 吞吐同时守住延迟 SLO。
  - 对我们的启示:这是多租户 GPU 池化里最硬的一块——要让 best-effort 训练/批处理和在线推理共置又不踩 SLO。我们产品若要做超越 MIG/MPS 静态切分的"带延迟保证的动态共置",这套"干扰预测 + SM 切分/整卡二选一"的准入模型可以直接作为调度器插件的设计蓝本,比纯时间片或静态 MIG 的利用率上限高得多。
  - 关键数据点:跨四种 GPU 架构,预测误差比既有预测器最多降一个数量级;所有负载下 p99 延迟保持在目标 SLO 之下或非常接近。

- **[MOLT: Fine-Grained GPU Memory Sharing for LLM Serving](https://arxiv.org/abs/2610.05748)** — 把推理副本的"空闲显存"借给 PEFT 微调,且能在秒级安全收回而不丢弃训练步。(Seoul National Univ. Jae W. Lee 组)
  - 核心思路:推理副本按请求负载扩缩,但副本内显存常年闲置;加副本要分钟级,显存需求却秒级波动,即使瞬时扩缩也只能整副本增减、收不回这块闲显存。共置 PEFT 微调能吃掉它,但推理必须能在请求超时前秒级收回。既有共置系统要么把训练显存常驻、要么只能按"整个训练样本"粗粒度回收且会丢弃正在跑的训练步。MOLT 做 activation 级细粒度回收:推理只收回某个运行中训练步为反向传播保存的单个 activation,训练步继续、反向传播时重算这些 activation;在 CPU-GPU 异步和张量并行下也只回收"没有在途 GPU 任务还会访问"的显存。
  - 对我们的启示:这直击"GPU 利用率"与"模型生命周期(微调/持续训练)"两条产品线的交叉点。我们若把在线推理池和微调任务放同一批卡,MOLT 的 activation 级回收语义给出了"推理 SLO 优先、微调见缝插针且不作废"的正确实现范式——比我们当前多数产品"微调与推理分池"的做法在成本上有量级改善。可作为"统一算力池 + 推理优先抢占"特性的技术参照。
  - 关键数据点:4 个部署(24B–70B)、H100 SXM 与 B200、trace 驱动负载下,推理 SLO 达成率 ≥99.7%,完成的微调工作量是"丢弃式共享"的 1.9–3.3 倍。

- **[TRANSIT: Transparent Scale-in for Multi-Node LLM Training](https://arxiv.org/abs/2610.07593)** — 用户态拦截层把 CPU DRAM 当显存扩展,让多节点训练透明缩到更少 GPU 上跑,应用/框架/调度器/驱动全不改。(IBM Research + UIUC)
  - 核心思路:在用户态做 interposition,透明地把超出显存容量的数据 offload 到 CPU DRAM,零拷贝数据通路做 CPU-GPU 搬运;对应用、训练框架、集群调度器、设备驱动、OS 全部零改动。本质是给"GPU 资源波动时如何不中断、不改代码地弹性缩容训练"一个透明方案。
  - 对我们的启示:企业集群里训练任务被抢占/降配是常态。TRANSIT 的"用户态透明 offload + 零拷贝"路线意味着我们可以在调度层做"缩容而非杀任务"的弹性策略,而不要求用户改 TorchTitan/DeepSpeed 配置。对标我们产品的训练编排,这是"抢占式调度 + 透明降配续跑"的可落地形态,且性能明显优于框架自带 offload。
  - 关键数据点:最多 64×H100、RoCE 网络、dense 与 MoE 模型。每 GPU 吞吐比 TorchTitan / ZeRO-Offload / ZeRO-Infinity 分别高 68% / 59% / 42%;用一半 GPU 仍保留 >90% 基线每卡吞吐;每节点网络流量最多降 33%;通信受限场景每卡吞吐最多提升 35%。

- **[HALO: Multi-SLO Enforcement for LoRA-Assisted LLM Deployment](https://arxiv.org/abs/2610.04956)** — 面向本地化部署,在一张卡上同时服务多个 LoRA 服务且各自守住异构 SLO。
  - 核心思路:医院/政府等隐私敏感场景偏好本地化(on-premise)LLM 服务器,但资源受限、同时服务多个 LoRA adapter 时,LoRA 层的计算开销 + 刚性批调度导致严重 SLO 违约。HALO 两招:(1) 空间复用——切分 GPU SM 让 Base 与 LoRA 计算重叠执行;(2) SLO 感知调度——按"请求级 slack"解耦请求执行,优先紧急请求、用空闲预算做流量整形,缓解资源争用。
  - 对我们的启示:多租户 LoRA/adapter 服务 + 异构 SLO 正是企业私有化部署的刚需场景(一套底座服务多个业务线、各自延迟要求不同)。HALO 的"SM 空间复用 + 请求级 slack 调度"给我们的多 adapter 推理网关提供了明确的 SLO 保障机制设计,而非简单的共享批处理。与 Mosaic/MOLT 一起,本周三篇都在收敛到"SM 级空间切分"这条主线。
  - 关键数据点:abstract 只给了方向性结论(相比 SOTA baseline 显著降低 SLO 违约并提升吞吐),具体数值在正文(未在摘要披露)。

- **[vLLM-Omni Technical Report: A Unified Serving Runtime for Omni-Modality Generation](https://arxiv.org/abs/2610.09307)** — vLLM 官方团队把服务运行时从"单一文本 decode 循环"扩成统一编排多模态(文本/语音/图像/视频/动作)的多阶段流水线。
  - 核心思路:交互正从文本 chatbot 扩到语音助手、视觉生成、world-model、机器人动作环,这些模型执行模式差异大(自回归 omni/TTS、迭代 diffusion/flow-matching、带状态的长生命周期 loop),服务不再是单 decode 循环而是带跨阶段传输/流式/会话形态的异构多阶段工作流。既有推理栈各自只优化一类架构(LLM server 深耕自回归调度与 KV 管理,diffusion 栈深耕去噪并行),没有共享控制面。vLLM-Omni 用单一 orchestrator 把每个负载组织成多阶段 pipeline:准入请求、推进跨阶段、解复用流式输出;专用 engine + stage 副本池提供算力,connector 在数据面搬重载荷,会话控制支撑长生命周期 duplex/world-model/机器人负载。提供 OpenAI 兼容 + OpenPI API。
  - 对我们的启示:我们的推理底座若绑死在"文本 LLM 服务"模型上,面对语音/多模态/agent 会碰到和论文描述一样的"多运行时拼凑"困境。vLLM-Omni 作为上游 vLLM 的官方演进方向,其"统一 orchestrator + stage 副本池 + 数据面 connector"的分层应纳入我们下一代推理控制面的架构评审——这决定了我们未来接多模态/机器人负载时是复用上游还是自造轮子。
  - 关键数据点:技术报告型,评测侧重 H100 上多模态 nightly CI、Qwen3-Omni 等;摘要未给定量加速比。

## 值得泛读(8 篇)

- [Beaver: Elastic GPU Sharing(AI-RAN,vRAN 与 ML 共卡)](https://arxiv.org/abs/2610.02522) — SM 分配按时隙重划 + 改写 ML kernel 让出 HBM 带宽;H200 上守住 vRAN 1.5ms 上行 p99.9 的同时保留 74% 的 Llama-3.3-70B 吞吐。延迟临界与尽力而为共卡的又一力证。
- [Zepp: Accelerating Distributed MoE Serving under Relaxed Balance Constraints](https://arxiv.org/abs/2610.11158) — 放松专家负载均衡约束来加速分布式 MoE 推理。
- [Democratizing MoE inference on commodity GPUs with CoMoE](https://arxiv.org/abs/2610.09424) — 让 MoE 推理跑在普通商用 GPU 上,降低 MoE 部署门槛。
- [Lachesis: Lifetime-Aware KV Cache Placement](https://arxiv.org/abs/2610.08378) — 按生命周期把 KV cache 在 HBM 与高带宽 flash 之间分层放置,KV 分级存储新思路。
- [OrigaMIG: MIG-Aware VM Placement with Live Migration](https://arxiv.org/abs/2610.06646) — MIG 分区感知的虚机放置 + 支持热迁移,GPU 分区在虚拟化层的管理。
- [ServeTwin: Benchmark-Validated Simulator for Distributed LLM Architecture](https://arxiv.org/abs/2610.02732) — 经基准校验的分布式 LLM 服务架构仿真器,做容量规划/架构选型的工具。
- [Reproducible LLM Inference Benchmarking: A Sequential Isolation Protocol](https://arxiv.org/abs/2610.09778) — LLM 推理基准可复现性协议(顺序隔离),评测方法论,对标我们做性能验收有参考价值。
- [Read What Matters: Query-Adaptive Quantization for KV Caches](https://arxiv.org/abs/2610.11245) — 按 query 自适应量化 KV cache,降显存压力。

## 趋势观察

- **本周绝对主线:带 SLO 保证的 GPU 空间共享(SM 级切分)**。Mosaic、HALO、Beaver、MOLT、OrigaMIG 五篇不约而同在做"如何在一张卡上安全叠加多种负载"——而且技术收敛点高度一致:**SM 级空间复用 + 延迟/SLO 感知的准入或抢占**,而非传统时间片或静态 MIG。这对我们产品的信号很强:静态 MIG/MPS 切分已被学界视为利用率天花板,下一代差异化点在"动态、带干扰预测、带 SLO 保证"的共置调度。
- **MoE 服务/训练的工程化加速成为稳定赛道**。Zepp、CoMoE(服务侧)与 RailWave、Expert Coupling、Memory-Efficient Expert Routing(训练侧,cs.DC 列表)共 5+ 篇,围绕专家并行通信开销、负载不均、commodity GPU 可达性展开——MoE 已从模型创新转向系统落地。
- **KV cache 从"单卡管理"走向"跨存储层/跨量化精度的分级"**。Lachesis(HBM↔flash)、Query-Adaptive Quantization、Request Order Matters(KV 复用的历史敏感性)都在把 KV 当成需要分层/压缩/调度的一等资源。
- **弹性训练强调"透明、不改栈"**。TRANSIT 代表的方向是:弹性缩容不该要求用户改框架配置,而应在用户态/调度层透明完成。
- **服务基础设施在"成熟化"**:上游 vLLM 推出统一多模态运行时(vLLM-Omni)、出现专用仿真器(ServeTwin)和可复现基准协议(Reproducible LLM Inference Benchmarking),说明 LLM serving 正从"调优单点"进入"平台化 + 工程规范"阶段。
- 说明:本归档目录内无上一期 arxiv-ai-systems digest,故不做严格的周环比;上述为本窗口(10-05~10-09)内部的方向分布观察。
