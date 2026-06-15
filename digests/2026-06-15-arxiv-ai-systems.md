# AI 系统论文周报 2026-06-15

> 数据源:arxiv API(cs.DC / cs.PF / cs.LG),提交时间 2026-06-08 ~ 2026-06-15,六组关键词检索去重后共命中 24 篇新论文,剔除纯模型/纯算法/无系统实现后,挑出与"做产品"相关的方向如下。

## 本周精选(5 篇)

- **[FMplex: Model Virtualization for Serving Extensible Foundation Models](https://arxiv.org/abs/2606.09643)** — 把基础模型 backbone 当成"虚拟化底座",让多个下游任务共享一份物理 backbone。
  - 核心思路:现有 serving 把每个定制任务都部署成独立模型实例,heavyweight backbone 被反复复制,既浪费显存又丧失跨任务 batching/加载的摊销机会。FMplex 给每个任务一个 virtual foundation model(vFM)——逻辑上私有、物理上共享一份 backbone,同时保留任务各自的扩展(adapter/head)、独立生命周期与任务级隔离;再配一个 batch-aware 公平队列调度器,把加权任务级共享与跨任务/任务内 batching 结合起来。
  - 对我们的启示:这正击中我们企业级"一份大模型 + 多业务定制"的成本痛点。我们当前在 KServe 上多是一任务一 InferenceService、一份权重一块显存,FMplex 证明"backbone 即虚拟化底座 + vFM 抽象"能把同一集群承载的任务数量级抬上去。建议把它作为我们多租户模型托管的参考架构评估:重点看 vFM 的隔离边界(显存/故障域/QoS)在企业多租户下是否站得住,以及它的公平队列能否对接我们现有的租户配额体系。
  - 关键数据点:7 个 backbone(16 个变体)、92 个下游任务上,相比空间分区(spatial partitioning)延迟最多降 80%、相比 best-effort co-location 降 33.3%;集群规模下可多托管最多 6 倍任务。

- **[M*: A Modular, Extensible, Serving System for Multimodal Models](https://arxiv.org/abs/2606.12688)** — 用统一的数据流图抽象去 serving 由 vision encoder / LLM backbone / diffusion head / audio codec / action generator / world model 拼装而成的复合模型。
  - 核心思路:新一代模型是"组件拼装"的复合架构(unified multimodal、omni、speech-language、VLA 策略、world model),而现有 serving 框架都建立在"模型结构很窄"的假设上,装不下这种多样性。M* 把模型表示成 dataflow graph,请求处理就是在图上的遍历(Walk Graph 抽象),支持组件任意组合、灵活放置到物理集群、以及运行时里与模型无关的优化。
  - 对我们的启示:我们的推理平台迟早要接 omni / VLA / 世界模型这类多组件负载,届时"一个 runtime 装一个单体模型"的假设会崩。M* 给了一个干净的工程方向——把推理图作为一等公民,组件级放置 + 图级优化。建议在我们的推理网关/编排层做技术预研:评估能否用类似 Walk Graph 的抽象统一表达"encoder→LLM→head"这种多阶段异构 pipeline,这比逐个为新模态写专用 runtime 可扩展得多。
  - 关键数据点:text-to-image(BAGEL)端到端延迟平均比 vLLM-Omni 低 20%;text-to-speech(Qwen3-Omni)实时因子最高低 2.9x、吞吐高 2.7x;机器人规划上比 V-JEPA 2-AC rollout 基线最高快 12.5x。

- **[Fairness-Aware and Latency-Controllable Scheduling for Chunked-Prefill LLM Serving](https://arxiv.org/abs/2606.09061)** — 针对已成主流的 chunked-prefill 架构,直面 FCFS + 静态 token 预算带来的队头阻塞、请求饿死与延迟抖动。
  - 核心思路:三件套——(1) 轻量 aging 调度策略,用累计等待时间 + 剩余 prefill 工作量动态算优先级,替代刚性 FCFS;(2) Latency-Prediction-Based Request Scheduling(LPRS),用目标时间约束替代静态 token 预算;(3) Active Prefill Control(APC),主动调节 prefill 并发、抑制 prefill 碎片化。论文强调"结构性 prefill 控制"与"时间性延迟约束"二者互补。
  - 对我们的启示:多租户推理的公平性与尾延迟是我们企业级卖点的硬指标,这篇把 chunked-prefill 下的 HoL blocking / 饿死问题工程化并给了可落地方案,而且**同时在 NVIDIA GPU 和昇腾 accelerator 上用真实负载验证、代码已开源**——对我们昇腾路线尤其友好。建议把"aging 优先级 + 目标延迟约束替代静态预算"纳入我们调度器的演进路线,作为 SLO 可控性的标准能力对外讲。
  - 关键数据点:aging 策略相比 FCFS 平均端到端延迟降超 10%;LPRS + APC 显著降 P99 尾延迟并抑制 prefill 碎片化;NVIDIA + 昇腾双平台验证,代码已在 GitHub 开源。

- **[MiniPIC: Flexible Position-Independent Caching in <100LOC](https://arxiv.org/abs/2606.13126)** — 用不到 100 行核心引擎改动,在 vLLM 里实现灵活的位置无关 KV 复用,专治 RAG/agent 里重复 prefill 的"span"。
  - 核心思路:RAG/agentic 负载反复 prefill 结构化、可预测的输入片段(文档、代码文件,称为 span),但 vLLM 的 prefix cache 只有在前缀完全相同才能复用,而生产级 PIC 实现要么大改服务端代码、要么把 KV 放到服务器外导致 host-to-device 传输开销。MiniPIC 两个原料:不带位置编码的 KV cache(存 unrotated K,attention 内按 per-request 逻辑位置对 K tile 施加 RoPE)+ 三个用户可控的 token 级原语(块对齐 padding、span separator、prompt depend)。靠这些原语就能在同一个运行中的 vLLM 实例里实现 Block-Attention / EPIC / Prompt Cache 等多种 PIC 方法,且原生兼容 KV cache 的 CPU offload。
  - 对我们的启示:这是本周工程可用性最高的一篇。我们做企业 RAG/agent,文档与代码片段跨请求高度复用,prefix-only 缓存命中率受限是真实瓶颈。MiniPIC 证明"位置无关 KV 复用"可以做成 <100 行的 vLLM 增量、免训练、可叠加 CPU offload。建议直接纳入我们推理引擎的评测项,优先验证它与我们现有 prefix cache / KV offload 的兼容性和命中率收益。
  - 关键数据点:2WikiMultihopQA 上,prefill 吞吐相比原生 vLLM +49%;已缓存 span 的 TTFT 最多降两个数量级;保持未缓存 span 的线性 prefill 扩展;最坏情况仅 5.7% 开销。

- **[ITME: Inference Tiered Memory Expansion with Disaggregated CXL-Hybrid Memories](https://arxiv.org/abs/2606.12556)** — 用 CXL 混合内存做 TB 级字节可寻址的远程内存扩展,承接 agentic/长上下文的共享 context 状态。
  - 核心思路:agentic/长上下文负载把 context 状态推到 TB 级,单机装不下,业界转向 disaggregated 共享存储 + 专门的"共享 context 层"。基于 DPU/JBOF 的 NVMe-oF 卸载虽能加速,但软件优化与成本负担重。ITME 改用 CXL-hybrid 内存呈现一块巨大、字节可寻址的远程内存扩展,靠直接字节寻址简化软件栈;关键洞察是模型权重与 prefix cache 的访问模式是确定性的,系统可据此在内存-存储层级间主动预取/搬运。用产线级 SK Hynix CMM + PCIe Gen5 NVMe SSD 评估,并用 FPGA 原型验证可行性。
  - 对我们的启示:长上下文/agent 的 KV 与权重内存压力,正把战场从"单卡显存"推向"内存-存储分级"。ITME 代表了 CXL 这条比 NVMe-oF 卸载更省软件、更省成本的路线。这对我们规划下一代推理节点的内存架构是重要信号:建议把"CXL 分层内存 + 确定性预取"纳入我们对长上下文/agentic infra 的硬件选型与成本建模,作为对标超大 KV footprint 的方案之一(注意目前还是原型阶段,生态成熟度需跟踪)。
  - 关键数据点:相比传统 CPU-offloading,为超出主机内存上限的大 KV cache 提供额外远程内存扩展,吞吐最高提升 35.7%。

## 值得泛读(7 篇)

- [Piper: A Programmable Distributed Training System](https://arxiv.org/abs/2606.11169) — 把"并行策略"与"运行时实现"解耦:用少量模型标注 + 调度指令声明完整分布式策略,经统一 IR(全局训练 DAG)编译出每设备执行计划;常见策略(ZeRO)性能持平,组合策略(如 DeepSeek-V3 DualPipe)还能靠 compute/comm 联合调度再拿收益。
- [ScaleAcross: Designing Multi-Data-Center Infrastructure for Geo-Distributed AI Training](https://arxiv.org/abs/2606.12963) — 用 EVPN–VXLAN 做跨数据中心 AI 训练的基础设施底座,配 ECMP/BFD/队列对感知流量分发;基于 ContainerLab+FRR 的可复现 WAN 仿真框架,刻画 AllReduce/Parameter Server 在广域条件下的通信与韧性行为,对应数据主权驱动的地理分布式训练趋势。
- [Resource-aware Computation-Communication Overlap for multi-GPU ML Workloads](https://arxiv.org/abs/2606.09200) — 两个可移植运行时控制(共享内存驱动的计算 kernel 占用整形 + 提升通信 kernel 调度优先级)实现计算/集合通信重叠,A40/A100/H100/MI250X 上总执行时间最多降 25.5%,且不改厂商库与 kernel 实现。
- [End-to-End Context Compression at Scale (LCLM)](https://arxiv.org/abs/2606.09659) — 重新审视 encoder-decoder 压缩,做架构搜索后训练 0.6B-encoder/4B-decoder 家族(1:4/1:8/1:16 压缩比),在通用任务性能、压缩速度、峰值内存三维上推进 Pareto 前沿,作为长程 agent 的"先略读压缩上下文、按需展开"的高效 backbone,是 KV cache 压缩之外的另一条路线。
- [Efficient On-Device Diffusion LLM Inference with Mobile NPU (llada.cpp)](https://arxiv.org/abs/2606.13740) — 首个面向手机 NPU 的 dLLM 推理框架,三招(多块投机解码补late-stage 缩水的 workload、双路渐进修订、swap 优化内存运行时)对齐 NPU 执行特征,LLaDA-8B 端到端延迟比 CPU 基线降 17x–42x 且保质量,边缘/端侧推理参考。
- [BUDDY: Budget-Driven Dynamic Depth Routing for Adaptive LLM Inference](https://arxiv.org/abs/2606.09514) — 预算驱动的动态深度路由:轻量决策模块按输入打分、确定性执行 top-k 层以满足给定算力预算,复用首层 KV 做全局上下文支持 decode 时重路由;单一训练模型即支持严格预算控制与多预算,适合按 SLA/成本档位动态降本。
- [Eidola: Modeling Multi-GPU Network Communication Traffic in Distributed AI Workloads](https://arxiv.org/abs/2606.12638) — gem5 的可扩展扩展,用真实应用的标注 timing profile 以 cycle 级精度仿真 GPU 间 P2P 写,研究 kernel fusion / 通信计算重叠引入的不规则瞬态流量,支持大规模多 GPU 互连的架构探索。

## 趋势观察

- **"共享/虚拟化"成为 serving 层效率的新主线**:本周 FMplex(backbone 虚拟化 + vFM)、M*(复合模型的统一数据流图抽象)都不再纠结单请求优化,而是从抽象层重新组织——把昂贵的 backbone 当共享底座、把异构组件拼装成可调度的图。相比上几周以 PD 拆分/co-location 为主战场,本周明显转向"serving 抽象与资源共享",这对我们多租户托管的成本结构是直接利好信号。
- **内存/上下文层级化,被 agentic + 长上下文逼出来**:ITME(CXL 分层内存)、LCLM(encoder-decoder 上下文压缩)、MiniPIC(位置无关 KV 复用)三篇从硬件、模型、引擎三个层面同时攻 KV/上下文内存瓶颈,且都点名 agentic/长上下文是驱动力。结论:KV footprint 正取代单卡显存成为长上下文 infra 的成本中枢,值得我们在推理节点选型与缓存策略上提前布局。
- **调度延续上周热度,但焦点从"估不准"转到"公平性与尾延迟"**:上周三篇调度论文攻"准入估计不准",本周 Fairness-Aware Chunked-Prefill 把矛头对准 chunked-prefill 下的 HoL blocking / 饿死,用 aging + 目标延迟约束替代 FCFS + 静态预算,且首次在昇腾上一并验证。多租户公平性正成为调度器的下一个必答题。
- **复合/多模态 serving 开始独立成题**:M* 明确把 omni / VLA / world model 这类多组件负载作为一等公民,说明 serving 系统的假设正在从"单体文本 LLM"扩展到"多模态组件拼装",我们的推理平台需要为这种架构多样性预留抽象空间。
- **工程可用性导向延续**:MiniPIC(<100 行 vLLM 增量)、Resource-aware Overlap(不改厂商库)、Fairness 调度(已开源、双平台)都强调 drop-in / training-free / 不改底层,延续上周"透明落地"的工程取向——学术成果正越来越快地以可直接评测的形态交付。
