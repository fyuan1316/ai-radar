# AI 系统论文周报 2026-11-02

> 覆盖窗口:2026-10-26 ~ 11-02(arxiv API 本期仍返 "Rate exceeded",按既定 fallback 走 arxiv.org cs.DC / cs.PF recent 列表 + WebSearch 查漏,逐篇读 abs 页核实日期与数据)。筛选口径见 `tasks/arxiv-ai-systems.md`:只收系统/调度/服务化/集群且有实验验证的,纯模型结构/纯应用/纯理论不收。上周(10-26)已覆盖的 HAWK / PairSight / KVCompass / SARIA / BaGuaLu-2 / Gandalf / RISK-KV 等不再重复。
>
> 说明:InferScale 提交于 10-25,严格说贴着 7 天窗口下沿、上周 digest 未覆盖,本周经 cs.DC recent 浮现,因与我们产品高度相关(K8s 原生)按"新且相关且未收录"纳入,日期已标注,不冒充本周新作。

## 本周精选(5 篇)

- **[Governing Enterprise AI Traffic at Scale: Design and Operation of a Policy-Driven, Multi-Vendor LLM Gateway on Envoy](https://arxiv.org/abs/2610.35509)**(10-26)— PayPal 把全公司 LLM 流量收口到一个基于 Envoy 的多厂商网关 Cosmos,用 OPA 做声明式治理。这是本期最贴我们产品的一篇。
  - 核心思路:企业接多家模型(自建 + 公有云 API)会陷入"凭证散落、格式锁定、花费不可控、治理口径不一"。Cosmos 做拆分处理:延迟敏感的操作(鉴权、策略评估、预算检查)放外置服务,低延迟操作(格式转换、token 计量)用 Rust WebAssembly filter 在 proxy 内就地做;治理面用 Open Policy Agent 管声明式策略,控制面支持按角色撰写策略、审批流、灰度(shadow)发布。
  - 关键数据点:截至 2026-09 已服务 12,000+ 开发者、数百个业务场景,日处理约 2000 亿 token、横跨 100+ 模型,可用性 99.999%;网关引入的中位延迟开销仅 4ms、P99 11ms,两台 4-vCPU 实例扛 2200+ req/s。明确标注为"工业界案例研究 / 生产实测"。
  - 对我们的启示:这篇给出了"AI 网关/模型路由"作为企业级平台一等模块的完整生产参照,直接对标我们对标 OAI 时最该补的控制面能力。产品决策级动作:(1) 推理平台之上必须有一层独立的"模型网关",承担统一鉴权、多厂商适配、token 计量/配额、审计;(2) 治理用 OPA 这类声明式策略引擎而非硬编码,且要有审批流 + 灰度发布,把"谁能用哪个模型、花多少钱"做成可审计策略而非工单;(3) 性能上验证了"控制面外置 + 数据面 WASM 就地处理"能把网关开销压到个位数毫秒,我们自研网关可直接采这套分层。这是可以立项的平台能力,不是纯研究。

- **[InferScale: Kubernetes-Native Predictive Autoscaling for SLO-Aware AI Inference](https://arxiv.org/abs/2610.34006)**(10-25)— K8s 默认 HPA 对推理负载失效(pod 冷启动几十秒、反应式扩容追不上,多租共享下互相拖垮 SLO),InferScale 做预测式扩缩。
  - 核心思路:不改 K8s 核心调度器,叠加五个机制——推理专属性能信号、短时程需求预测、SLO 感知的状态控制、尖峰快速响应、基于优先级的资源余量(headroom)预留。核心是"预测 + 优先级抢占余量"替代纯反应式。
  - 关键数据点:ResNet-50 ONNX(21s 冷启动)场景,SLO 达标率从外置指标 HPA 的 47.8%±1.5% 提到 65.3%±9.0%;多租争用场景下 Gold 档 SLO 波动从 16.1 个百分点压到 1.2;消融显示去掉任一组件掉 6–8 个百分点。AKS 生产级环境实测。
  - 对我们的启示:这篇几乎是我们推理平台弹性模块的 spec。产品动作:(1) 推理的自动扩缩不能沿用 CPU/QPS 阈值的 HPA,必须引入"冷启动时长感知 + 短时程负载预测 + SLO 反馈"的专用控制器;(2) 多租户下要把"优先级分档 + 为高优负载预留 headroom"做进调度,否则共享集群里高优租户 SLO 会被低优尖峰击穿——论文证明这是从 16.1→1.2pp 的量级差异;(3) 它刻意不改 K8s 调度器、以旁路控制器形式叠加,这个工程路径对我们在客户现有 K8s 上做增量交付特别友好。

- **[ConfluxServe: Reconciling Resource Utilization and Parallelism Efficiency across Prefill and Decode in LLM Serving](https://arxiv.org/abs/2610.37810)**(10-27)— prefill 与 decode 资源需求互补但并行偏好冲突:分开跑浪费资源、合批跑又被迫用统一并行度,ConfluxServe 让两者在同一 batch 内各用各的并行度。
  - 核心思路:提出 Conflux Parallelism(XP)执行抽象,允许 prefill 和 decode 在同一个 batch 里"用不同的并行配置协同执行"。利用 Transformer 的算子级结构,为不同阶段构造异构执行路径(不同的 batching 与并行策略),同时满足 TTFT 与 TBT 两类 SLO。
  - 关键数据点:生产负载上相比最强基线,服务 goodput 提升 1.26–1.62x。
  - 对我们的启示:这是对"PD 分离 vs PD 合批"之争的一个新答案——不必二选一,而是在同批内解耦并行度。产品动作:我们的推理引擎若在做 PD 分离/合批策略选型,应把"同批异构并行"作为第三条路纳入评估,尤其是中小规模部署无法为 prefill/decode 各开独立实例池时,XP 这种"一个池子里两种并行"能把利用率和 SLO 同时吃下。可作为我们推理引擎与 vLLM/SGLang 差异化的一个候选特性跟踪。

- **[FlatCake: A Flat KVCache Storage Architecture for LLM Serving](https://arxiv.org/abs/2610.38355)**(10-28)— 把 host DRAM 与 NVMe SSD 当成统一 64-bit 地址空间里的"对等介质"而非分层,KV block 创建时就直接落到目标介质、免迁移。
  - 核心思路:反直觉地抛弃"DRAM→SSD 分层搬运"范式。不可变的 KV block 在生成时就按会话连续顺序直接写到它该待的介质上,从源头消除 migration;SSD 读走 GPUDirect Storage 直通。
  - 关键数据点:Claude Code trace + DeepSeek-V4-Flash 上对比 Mooncake,缓存命中率 94% vs 64%,消除 6.5–6.7x 的 SSD 读放大,峰值负载平均 TTFT 降 1.6x、吞吐升 1.6x;Llama-3.1-70B 更长上下文上 TTFT 比 Mooncake 最多降 2.4x、比 Mooncake-GDS 降 1.8x。
  - 对我们的启示:上周 digest 的 SARIA/Gandalf 是"精细化分层搬运 + 磨损控制",本周 FlatCake 给出相反路线——"一开始就放对地方、根本不搬"。KV 存储架构正在出现路线分叉。产品动作:我们的 KV 分层栈在选型时要把"免迁移的扁平寻址 + GPUDirect 直通"和"分层搬运 + 选择性落盘"两条路线做 A/B,关键变量是读放大与命中率(FlatCake 的 94% vs 64% 说明"放对位置"对命中率的影响可能大过"搬得聪明");Mooncake 已被当作公认基线,我们对接存储层时应以 Mooncake 为对照系做实测。

- **[PDScope: Breaking the Prefill-Decode Seesaw for Memory-Bound MoE Inference](https://arxiv.org/abs/2610.39216)**(10-29)— GPU 显存放不下 MoE 的大部分 expert、只能留在 CPU 内存时,prefill(算力密集、要激进加载)与 decode(I/O 密集、要保守传输)需求打架,PDScope 按相位分治。
  - 核心思路:三件套——(1) expert 激活预测指导数据放置与预取;(2) 相位专属成本模型,prefill 和 decode 各自按自己的瓶颈(compute vs I/O)选策略;(3) 把缓存预取 + 异步 I/O 编译进静态计算图,做成"零额外开销"的流水线。
  - 关键数据点:主流 MoE 模型上,prefill 吞吐比现有系统高 2.5–10.3x,decode 吞吐高 2.1–6.1x,并能推广到多 batch。
  - 对我们的启示:私有化/边缘盒子显存小但客户要跑 DeepSeek/Qwen-MoE 量级模型,"expert 放 CPU、HBM 装不下"是常态。PDScope 证明这种 CPU-GPU offload 场景下,prefill/decode 必须用不同的 I/O 策略,一刀切会两头吃亏。产品动作:我们若要支撑"小显存跑大 MoE",offload 引擎要做相位感知(prefill 激进预取、decode 保守按需),并引入 expert 激活预测来降 I/O——这是把"能加载"做到"能用"的关键,和本周 DualPace/DeepInfer-Mac 同属"CPU 内存/SSD 当一等执行资源"的热潮。

## 值得泛读(9 篇)

- [DualPace: Decoupled Scheduling and Cooperative GPU–CPU Decoding for LLM Serving](https://arxiv.org/abs/2610.33501)(10-24)— GPU 管 prefill 与 GPU 常驻 decode、AMX CPU 引擎独立管 CPU 常驻 decode,两引擎按离线 profile 选择性协同。对比 vLLM 吞吐提升 11.5–90.6%、对比 CPU-offload 基线 NEO 提升 6.9–43.2% 且同等时延。CPU-GPU 协同解码路线的代表作。
- [INC-MoE: Overlapping In-Network Collectives and Expert Computation for Expert-Parallel MoE Inference](https://arxiv.org/abs/2610.36339)(10-26)— 把 MoE 的 dispatch/combine 通信卸载到交换机做在网计算(switch-side multicast AllGather + 交换机侧 ReduceScatter),与 FFN 计算三段流水重叠。OLMoE prefill 4-way EP 上 TTFT 最多降 33%、吞吐升 50%(vs vLLM)。多节点 MoE 的通信瓶颈新解法。
- [DeepInfer-Mac: Running a 750B-Class MoE on a 24 GB Laptop](https://arxiv.org/abs/2610.36564)(10-27)— 混合低比特量化把权重压到 338 GiB 放 SSD、内存只常驻 7.6 GiB 动态加载,24GB 笔记本上跑 750B MoE,0.21–0.72 tok/s、峰值内存 16.73 GiB,下一层预取带来 21% 提升。极端边缘推理的可行性验证。
- [EdgePace: Deadline- and Freshness-Aware LLM Scheduling on Unified-Memory Platforms](https://arxiv.org/abs/2610.37307)(cs.PF)— 面向统一内存平台(如 Apple/Grace 一类)的 LLM 调度,同时感知任务截止时间与数据新鲜度。边缘/端侧统一内存调度参考。
- [The Endgame of FSDP Communication: Layout-Aware Collectives on Copy Engines, RDMA, and NVSwitch](https://arxiv.org/abs/2610.38228)(10-28)— FSDP 训练通信的布局感知集合通信优化,把 collective 下沉到 copy engine / RDMA / NVSwitch。大规模训练通信底层榨性能的工程参考。
- [LRMoE: Demand-Side Load Re-Calibration for Efficient MoE Training on Memory-Constrained Nodes](https://arxiv.org/abs/2610.37720)(10-27)— 内存受限节点上的 MoE 训练负载再校准,呼应上周 BaGuaLu-2 的"MoE 显存动态波动"议题,面向中小集群训练 MoE。
- [Only Accepted Tokens Count: An Energy Accounting of Speculative Decoding Under Latency Targets](https://arxiv.org/abs/2610.40287)(cs.PF)— 在延迟约束下给 speculative decoding 做能耗核算,指出只有被接受的 token 才该计入能效账。延续上周 Token-Energy Law,给能效调度/TCO 测算补数据。
- [Speculative Decoding for Mixture-of-Experts Models: Expert Bytes, Kernel Bandwidth and the Best Draft Length](https://arxiv.org/abs/2610.34440)(cs.PF)— 针对 MoE 的 speculative decoding 刻画,给出 expert 字节量、kernel 带宽与最优 draft 长度的关系。MoE 服务调优参考。
- [TAO: Tool-Aware Joint Scheduling for LLM-Based Agentic Serving](https://arxiv.org/abs/2610.37230)(10-27)— 面向 agentic serving 的工具感知联合调度,把工具调用(外部 I/O 等待)纳入 LLM 请求调度一起优化。agent 工作负载调度方向。

## 趋势观察

- **本周最强信号:serving 论文从"把推理跑快"上移到"把推理当企业服务来治理"**。Cosmos(PayPal 多厂商网关,200B token/day 生产)与 InferScale(K8s 原生 SLO 感知扩缩)两篇一起,把平台控制面能力——统一网关、多厂商适配、token 计量/配额、OPA 声明式治理、优先级 headroom、SLO 反馈扩缩——直接做成了论文主题。这是对标 OAI 的我们最该抄作业的一期:差异化不在"引擎快 10%",而在网关/配额/多租 SLO 这层企业治理能力。
- **"CPU 内存 / SSD 当一等执行资源"成明确热潮**。PDScope、DualPace、DeepInfer-Mac、COPE、WorldPager 扎堆:当 MoE 大到 HBM 装不下,系统层的答案不再是"堆更多卡",而是把 CPU 内存与 SSD 纳入执行/存储主路径,并按 prefill(算力/预取)与 decode(I/O/按需)相位分别优化。对我们做私有化/小显存盒子跑大 MoE 是直接利好与方法库。
- **KV 存储架构出现路线分叉**。上周(SARIA/Gandalf)是"精细分层搬运 + 磨损控制",本周 FlatCake 反其道——DRAM/SSD 做成统一 64-bit 对等地址空间、创建即落位、根本不搬,命中率 94% vs Mooncake 64%。"搬得聪明" vs "放对就不搬"两条路线并存,我们选型时要以 Mooncake 为基线做 A/B,别预设分层一定对。
- **MoE 推理的系统难题从"显存"扩展到"并行冲突 + 通信"**。ConfluxServe(同批异构并行破 PD 并行度冲突)、INC-MoE(交换机在网计算破 all-to-all 通信墙)、PDScope(破 PD 相位 I/O 跷跷板)三篇从三个不同接缝切 MoE 服务,说明 MoE 已是系统论文的主战场,且瓶颈在从单机显存转向并行配置与跨节点通信。
- **能效继续作为一等指标沉淀**。Only Accepted Tokens Count、Speculative Decoding for MoE 两篇把 speculative decoding 的能效账算清("只有被接受的 token 才算数"),延续上周 Token-Energy Law——给客户算 TCO/能效调度的量化底座在持续变厚,我们的调度器宜把"每 token 能耗"做成可观测与可优化目标。
