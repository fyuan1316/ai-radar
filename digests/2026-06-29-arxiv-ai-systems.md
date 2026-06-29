# AI 系统论文周报 2026-06-29

> 数据源:arxiv API,提交时间窗 2026-06-22 ~ 2026-06-29,类目 cs.DC 为主(cs.LG/cs.PF 关键词查询因 export.arxiv.org 对沙箱出口 IP 的 "Rate exceeded" 持续限流未取到,本期以 cs.DC 命中为准)。精选论文均已读 abstract;实验数据点来自各论文 abstract 自报。

## 本周精选(5 篇)

- **[Moebius: Serving Mixture-of-Expert Models with Seamless Runtime Parallelism Switch](https://arxiv.org/abs/2606.26607)** — 让 MoE 推理引擎在不重启、不丢在途请求的前提下,在 TP 与 EP 两种并行布局间秒级热切换。
  - 核心思路:TP 和 EP 不是两个模型,而是同一份专家权重 + KV cache 的两种"切片归属"布局;切换的唯一不可省成本只是把 owner 变了的切片在 GPU 间搬一次。Moebius 用 fused GPU-to-GPU 传输 kernel 在 decode step 之间重分片,两种布局常驻、固定显存地址。
  - 对我们的启示:这是给"弹性 serving"补的一块关键拼图。我们做托管推理时,低并发用 TP 省延迟、高并发用 EP 提吞吐的取舍现在通常被迫静态绑定一种;Moebius 证明运行时切换可行后,产品侧应把"并行布局"从部署期固定参数升级为由 autoscaler/调度器按实时并发动态调的运行时旋钮——尤其 RL rollout(高并发起、长尾收)和在线突发流量两类负载收益最大。值得在 vLLM/SGLang 之上做 PoC 评估接入成本。
  - 关键数据点:8×H200 跑 Qwen3-235B-A22B,匹配每个工作点上更优的静态并行;RL rollout 场景比静态最优快 1.16-1.25x;单次切换 215-434 ms;双布局常驻仅 2.4% 额外显存。

- **[CrossPool: Efficient Multi-LLM Serving for Cold MoE Models through KV-Cache and Weight Disaggregation](https://arxiv.org/abs/2606.24506)** — 把 FFN 权重池和 KV-cache 池在 GPU 显存里拆开管理,专治"一台机器上托管很多冷门 MoE 模型"的显存浪费。
  - 核心思路:权重是稳定的、模型决定的;KV-cache 是瞬时的、需求决定的。冷模型很少同时打满各自的 KV 峰值,按最坏情况给每个模型预留 KV 必然浪费。CrossPool 把跨冷模型的 FFN 权重合并进一个权重池,KV-cache 进另一个动态池按活跃请求供给,attention 保持本地化;再加 KV 规划器/虚拟化器、逐层流水调度隐藏 hidden-state 传输、persistent kernel 降 CPU-GPU 控制开销。
  - 对我们的启示:这正是"模型即服务 / 多租户模型市场"形态的核心痛点。当平台要在有限 GPU 上托管成百上千个长尾自定义/微调模型时,单租户独占显存的旧账算不过来。权重与 KV 分池是我们多模型托管层应当采纳的架构方向,直接决定单卡能塞多少冷模型、能不能撑长上下文。建议对标其参照系 kvcached,纳入我们 serving 平台的显存管理 roadmap。
  - 关键数据点:相比 SOTA 的 kvcached 多 LLM serving 系统,P99 TBT(token-between-time)最高降 10.4x。

- **[The Serialized Bridge: Recovering LLM Serving Performance under Blackwell GPU Confidential Computing](https://arxiv.org/abs/2606.23969)** — 系统拆解了"机密计算"开启后 LLM serving 掉性能的真正瓶颈,并给出可恢复大部分损失的工程手段。
  - 核心思路:Blackwell 上 GPU 本地算力在机密模式下几乎无损(B300 BF16 matmul 0.998x),但 Intel TDX + GPU-CC 下整体吞吐仍掉 13-27%、KV-cache restore 延迟翻倍以上。根因不是计算,而是 CVM↔GPU 之间的"串行化桥":安全拷贝拿不到 CUDA stream 并发、异步传输在 runtime 边界阻塞、小数据搬运付固定高额开销(小 alloc-and-copy 慢约 44x)。一个调度 flag 恢复 57%,worker 线程 drain 在高并发下恢复最高 92%。
  - 对我们的启示:企业级合规(尤其金融/政企客户)迟早要求"模型与数据在使用中加密(confidential inference)"。这篇给了我们三个直接可用的产品判断:(1) 机密推理的性能税主要在数据搬运而非算力,选型应盯 host-device 通道而非比拼 GPU;(2) 现成推理 runtime(论文实测 vLLM)对机密模式的 DMA 假设不成立,我们若提供机密推理选项需要在 runtime 层打补丁/调度旗标,不能直接套用默认配置;(3) B300 NVSwitch 下可做多 GPU 机密租户(CVM 内 510 GB/s NVLink P2P),但 fabric 证明仍有缺口——多卡机密大模型暂不能承诺生产级。
  - 关键数据点:吞吐损失 13-27%;调度 flag 恢复 57%、worker drain 恢复至 92%;KV-restore 惩罚 +131%;模型加载慢 34x;CVM 内 NVLink P2P 510 GB/s。

- **[Concordia: JIT-Compiled Persistent-Kernel Checkpointing for Fault-Tolerant LLM Inference](https://arxiv.org/abs/2606.23521)** — 用一个常驻 GPU 的 persistent kernel 做 checkpoint 底座,在框架与库之下给长跑 LLM agent 做故障恢复,不让 host CPU 卡在关键路径。
  - 核心思路:长跑 agent 把宝贵状态(KV cache、调度器、通信状态、在线 adapter)常驻 GPU,GPU/通信器故障会丢掉数分钟到数小时的工作。现有方案要么重启整个栈,要么要求每个 attention/runtime 组件内嵌专用 checkpoint 逻辑。Concordia 拦截 GPU 模块加载,支持 PTX/SASS 级插桩,把 checkpoint/pause hook 插到框架代码之下;对每个注册的状态区域 JIT 编译专用 delta-checkpoint handler(KV-block 扫描器、adapter-page 扫描器、recovery applier)热插进 persistent kernel 的算子表;靠 lock-free ring buffer 串起计算/checkpoint/日志/恢复任务,把已提交记录追加到 CXL 内存或 host DRAM 上的 CPU 可见日志。
  - 对我们的启示:Agent / 长上下文会话正在把"推理"从无状态请求变成有状态长跑任务,这改变了可靠性 SLA 的定义——丢一次 GPU 不该等于丢掉整段会话。我们的推理平台若要支持 agentic 工作负载,需要把容错从"重启 Pod"升级到"GPU 状态级增量 checkpoint"。这条路线(框架无关、库下插桩、CXL/host 落盘)值得纳入可靠性架构选型;也提示我们关注 CXL 内存在 AI 基础设施里作为 checkpoint 落点的价值。
  - 关键数据点:abstract 侧重机制描述,未给统一加速比;定位为"框架/库边界之下的 GPU 驻留容错执行上下文"。

- **[Speculation at a Distance: Where Edge-Cloud Speculative Decoding Actually Pays Off](https://arxiv.org/abs/2606.25091)** — 用闭式不等式厘清"草稿模型放边缘、目标模型在云端"的分布式投机解码到底什么时候划算,给了反直觉的结论。
  - 核心思路:co-located 投机解码能把 LLM 推理加速 1.5-3x;把草稿模型挪到边缘的分布式变体(DSD)在 WAN 通信下单请求延迟收益有限。若服务器能同时放下两个模型,co-located SD 在延迟和通信上都优于同步 DSD;流水化只有在 RTT 极低(往返短于边缘 drafting 时间窗)时才能追平。DSD 真正的价值不在单请求延迟,而在多租户容量:跨客户重叠下,把草稿计算卸载到边缘能让饱和的云端服务器在同样的单客户速率下多撑 (1 + γ·t_d/t_v) 倍并发客户。
  - 对我们的启示:这是一篇"帮产品避坑"的分析。如果有人提议做边缘-云协同投机解码来降延迟,这篇直接告诉你:在 WAN 场景下别指望降单请求延迟,且对闭源 API(无 verifier-only 接口)根本做不了。真正该用它的卖点是"提升云端集群的多租户并发承载量",评估指标应换成服务器吞吐/并发客户数,而非 P50 延迟。给我们对边缘推理特性做需求定义时一个清晰的边界条件。
  - 关键数据点:co-located SD 加速 1.5-3x;DSD 多租户容量增益 (1 + γ·t_d/t_v) 倍并发;均为闭式模型推导结论。

## 值得泛读(3 篇)

- [Simulating Unified Tensor Resharding in Heterogeneous AI Systems (Xsim)](https://arxiv.org/abs/2606.26633) — 异构感知的分布式 LLM 训练模拟器,支持非均匀负载划分、异构 ring 集合通信、非均匀 tensor resharding,可插 NS-3/htsim;真实异构部署训练时间预测误差 <5%(流水并行约 2%),暴露 pipeline bubble、straggler 等待等可执行指标。对做异构 GPU 集群容量规划/调度仿真有参考价值。
- [Power-Flexible AI Data Centers: A New Paradigm for Grid-Responsive Compute](https://arxiv.org/abs/2606.25098) — 把 GPU 数据中心当成"电网交互资产":整合电网信号、负载调度、功率遥测做细粒度集群功率控制,130 kW 真实集群实测可做快速降载、持续削峰、碳感知运行并保住优先级作业 SLA,还能跨地域集群按电网压力迁移负载。指向"功率/碳"作为调度新维度。
- [The Energy Consumption of Transformer Fine-Tuning: A Roofline-Inspired Scaling Model](https://arxiv.org/abs/2606.23546) — 用 roofline 思路把训练能耗拆成 compute/memory-traffic/硬件效率代理量,引入基于 speedup 的硬件效率因子刻画 TP 与 FSDP 的影响,导出可跨异构配置预测训练能耗的 scaling law。对成本/能耗预估、绿色 AI 报告有用。

## 趋势观察

- **MoE 成为 serving 研究的默认假设。** 本周两篇最硬核的系统论文(Moebius、CrossPool)都把 MoE 当作主要服务对象,围绕"专家权重 + KV-cache 在多 GPU/多模型间如何重分片、如何分池"做文章。serving 系统的优化重心正从 dense 模型的 batching/调度,转向 MoE 特有的并行布局弹性与显存解耦。我们的 serving 平台若仍按 dense 假设设计显存与并行,会逐步落后于上游研究风向。
- **从"跑得更快"转向"在约束下安全/可靠/可持续地大规模运行"。** 本周一半的命中(机密计算性能恢复、GPU 状态级容错、电网响应功率调度、训练能耗建模)讨论的不是吞吐峰值,而是安全合规、故障恢复、功率与能耗这些非功能性约束。这是 serving 系统研究走向成熟的信号:吞吐红利吃得差不多后,企业级落地的瓶颈变成了"机密、可靠、省电"。这恰好对齐我们对标 OpenShift AI 的企业级能力主线——机密推理、agent 容错、功率/碳感知调度都可能成为下一阶段差异化点。
- **"显存解耦/池化"是贯穿多篇的底层主线。** Moebius 在固定地址重分片单份权重与 KV、CrossPool 把权重池与 KV 池拆开、Concordia 把状态落到 CXL/host——三篇都在重新设计 GPU 显存的归属与生命周期。把 GPU 显存当成可拆分、可迁移、可持久化的分层资源(而非单块铁板),正在成为新一代推理基础设施的共识抽象。
- **与上周对比:** 上周(06-22 之前)digest 聚焦在调度器/集群侧(KAI-Scheduler GitOps 化、ascend 抢占接入网络故障感知、HAMi 等),属于"集群编排层";本周 arxiv 命中则下沉到"单引擎/单卡显存与执行层"。两层叠起来看,上游正同时在编排层(调度策略)和执行层(显存/并行/容错)推进,产品侧需要两条线都跟。
- **数据局限说明:** 本期 cs.LG / cs.PF / MLOps / RAG 方向的补充查询因 arxiv API 对沙箱 IP 持续 "Rate exceeded" 未取到,实际系统论文产出可能多于本期收录的 8 篇;cs.DC 命中已覆盖 serving/MoE/投机解码/机密计算/容错/异构训练/功率能耗等核心方向,趋势判断可信,但泛读篇数偏少不代表本周大盘清淡。
