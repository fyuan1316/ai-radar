# AI 系统论文周报 2026-06-22

> 覆盖窗口:2026-06-15 ~ 2026-06-22(arxiv submittedDate)
> 数据源:arxiv API,类目 cs.DC / cs.LG / cs.PF,关键词组合(LLM serving / KV cache / GPU scheduling / 调度 / 容错 / 路由等)。本期共筛出近 7 天内系统相关论文 21 篇,精选 5 篇(逐篇读过 abstract + intro + experiments),泛读 8 篇。
> 说明:精选 5 篇均已读到 HTML 全文的 intro 与 evaluation 章节;ShuntServe 全文尚未在 arxiv 放出 HTML(仅 abstract),故放入泛读。

## 本周精选(5 篇)

### 1. [Tropical:用 SLO-aware 多路复用提升分离式 LLM Serving 的 SLO 达成率](https://arxiv.org/abs/2606.16264)
把"合并部署 vs 分离部署"之争,变成运行时按 SLO 余量动态切换的调度问题。

- **核心思路**:分离式(prefill/decode 各占独立 worker,DistServe 路线)消除了相互干扰但 prefill 排队时间高;合并式(vLLM/chunked-prefill)排队短但 prefill 与 decode 互相抢资源。Tropical 监控每个 decode worker 的 "TPOT slack"(当前 decode 实际耗时与 TPOT SLO 之间的余量),当余量足够吸收一个 prefill 时,把**短 prefill** 临时复用到 decode worker 上跑——短 prefill 是"排队主导",长 prefill 才是"干扰主导",据此做选择性复用,同时拿到低 TTFT 和低 TPOT。
- **关键数据点**:8×A100-80G(组成 4 个 TP=2 worker),InternLM-20B,Mooncake 长上下文 trace。相对 DistServe,P90 TTFT 改善 9×、P90 TPOT 仅降 15%;相对 vLLM,P90 TPOT 改善 2.8× 且 P90 TTFT 持平;在 90% SLO 达成率下可多承接 2.09× 请求。
- **对我们的启示**:我们的推理平台不必在"全分离"和"全合并"两条产品形态里二选一。可在调度层引入 SLO-slack 驱动的动态复用策略,把 prefill/decode 放置从"部署期静态决策"下沉为"运行时按租户 SLO 动态决策"——这正好是对标 OAI / KServe 静态 disaggregation 的差异化卖点。需要在我们的 router/scheduler 里暴露 per-request TPOT SLO 与实时 slack 信号。

### 2. [ReMP:面向 LLM Serving 的低停机运行时模型并行重配置](https://arxiv.org/abs/2606.18741)
让 TP/PP 拓扑像扩缩容一样可以在线改,而不是重启服务。

- **核心思路**:现有系统把 TP/PP 拓扑当成启动期静态配置,改配置只能重启 → 几分钟中断 + KV cache 全丢 + 重算。ReMP 四件套:(1) 启动时把整模型放进 CPU 共享内存(Shared Weight Store),重配时各 worker 直接重建目标分片,不重新读 checkpoint;(2) 二维 KV cache 迁移,沿 PP 的层归属和 TP 的 head 切片归属重映射,按层流式迁移降峰值显存;(3) 预建候选拓扑的并行状态快照(MPU State Space),切换通信组时套用快照而非销毁重建 NCCL group;(4) active/standby worker 复用进程。模型分片重载与 KV 迁移并发,把 T_model+T_kv 压到约 max(T_model,T_kv)。
- **关键数据点**:H100×8 与 RTX5090×8;Llama-7B/70B、DeepSeek-R1-Distill-Qwen-32B、Qwen3-30B-A3B(MoE)。多数拓扑切换 1–7 秒完成(Llama-7B 约 1–2s),较重启快"数十倍到 100×+";动态选配在 TTFT/TPOT/吞吐上全面优于固定 TP1PP8、TP2PP4。
- **对我们的启示**:这是"弹性推理"的关键缺失件。我们若想在潮汐流量下做并行度自动调优(白天高并发用 TP2PP4、夜间长上下文切 TP1PP8),目前业界普遍要重启 → 体验断崖。把"在线重配 + KV 迁移"作为平台能力,可与 HPA/自研 autoscaler 联动,做到"调拓扑不掉会话"。Shared Weight Store 的 CPU 内存成本需评估(整模型常驻 host 内存)。

### 3. [LUMEN:分布式 LLM Serving 的协同式故障恢复](https://arxiv.org/abs/2606.17787)
把容错从"单点 checkpoint + 从头重跑"升级为"负载感知的三点协同恢复"。

- **核心思路**:worker 挂掉会同时丢 GPU 上的 KV cache 和服务容量,幸存 worker 既要接管流量又要从头重算被打断的请求。LUMEN 在三个决策点协同:(1) 故障前——按请求粒度把 KV checkpoint 分散到多个 worker(选预期恢复负担最小者),而非固定塞给某个邻居;(2) 故障时——先把被打断请求路由到 checkpoint 持有者复用 KV,再把一部分重定向到更空闲的 worker(主动用重算换负载均衡),避免恢复热点;(3) 重载模型时——recovering worker 先起一个轻量 draft 模型,用投机解码立刻贡献产能,而不是干等大模型加载完。
- **关键数据点**:原型 4-worker(Qwen3-32B)/ 8-worker(Qwen3-14B),ShareGPT 10–12 QPS;模拟 10–64 worker(Llama-3-70B)。4-worker 下平均 TTFT 较 Stop-and-Restart 降 44.4%、恢复时间快 50%;8-worker 恢复时间快 64.1%;5 个并发故障时 TTFT 较 Stop-and-Restart 降 63.6%;4–64 worker、25% 故障率下稳定保持 46.8–51.2% TTFT 改善,稳态零额外开销。
- **对我们的启示**:企业级是我们对标 OAI 的核心战场,而"推理集群故障恢复"目前在开源栈(KServe/vLLM)里非常薄弱。这套"负载感知 checkpoint + 投机解码补产能"可以直接定义我们的差异化 SLA(故障期间 TTFT 不爆)。三个决策点都需要全局调度视图——和上面 Tropical/ReMP 共用同一套"中心化、状态感知调度器"基建,值得作为统一 roadmap。

### 4. [RouteBalance:异构 LLM Serving 中融合的模型路由与负载均衡](https://arxiv.org/abs/2606.17949)
把"选哪个模型"和"派到哪个实例"合成一次决策,直击 inference gateway 的真实瓶颈。

- **核心思路**:现有异构栈两层割裂——模型 router 按质量/成本选模型却不看实例负载,serving 负载均衡器优化队列却不看质量。RouteBalance 融合成一次"对具体模型实例"的在线分配,联合权衡质量/延迟/成本。工程上靠:批量预测(embedding 算一次,质量/长度预测在候选实例间复用)、dead-reckoning 跟踪批内已选实例状态防"羊群效应"、按预测输出长度最长优先(LPT)贪心分配。热路径决策仅 ≈32ms@12req/s。
- **关键数据点**:13 实例 / 28 GPU 异构集群,Qwen2.5 四档(3B/7B/14B/72B)+ 三种 GPU;3534 prompt,DeepEval G-Eval 评质量。质量峰值 0.419(+0.013 优于最强基线 BEST-Route 0.406);30 req/s 下 2.8s 端到端,较增强版 BEST-Route 领先 2.6–4.1×;吞吐 27.6 vs 21.8 req/s;成本最低档与最便宜基线持平(1.67e-5 USD/req)。关键归因:在"选模型"时把延迟也定价进去,贡献了 26–31% 端到端改善——这是解耦式路由拿不到的跨档位混合收益。**注**:作者特别澄清"published BEST-Route 在负载下崩 23× 到 63s"是其每请求串行打分的部署架构问题,与路由算法本身无关——评估很克制。代码:https://github.com/AKafakA/route-balance
- **对我们的启示**:我们做的 inference gateway / 模型路由,如果还是"router 选模型 → LB 派实例"两段式,在高负载和异构 GPU 下会同时损失质量、延迟和成本。应把路由与负载均衡合并为单层实例级分配,并在路由打分里显式纳入实例实时负载与延迟定价。32ms 热路径开销说明这在生产可承受。这条直接对应我们网关层的架构选型。

### 5. [CacheWise:面向 LLM 编码 Agent 的 KVCache 管理(基于 vLLM 实现)](https://arxiv.org/abs/2606.16824)
第一份系统性刻画"编码 Agent"serving 负载的工作,且改在 vLLM 上落地。

- **核心思路**:编码 Agent 是长生命周期闭环会话(LLM 生成与外部工具调用交替),负载特征与 chat 截然不同:大前缀反复复用、KVCache 持续高压。实测发现:工具完成触发的请求比用户发起的多 20×(以自动化闭环为主);会话很长(中位 36 分钟,尾部 2.6 小时+),多会话争抢有限显存;工具耗时跨数量级,recency-based 驱逐策略预测不准。CacheWise 两件套:(1) prefix-aware 调度——优先调度"需要新增 KVCache block 最少"的请求,最大化复用已驻留状态;(2) reuse-aware 驱逐——用基于工具元数据(名字/参数/历史耗时)的轻量预测器估计哪些会话的 block 最快被复用,据此驱逐,而非纯 recency。
- **关键数据点**:在 vLLM 上实现,真实编码助手 trace。KVCache 驱逐减少 2–2.6×;整会话完成时间降至 1/3.5(≈3.5× 提速);token goodput 提升 1.64–2×;接近"已知工具真实耗时"的理论上限。
- **对我们的启示**:Agent / 编码助手正成为头号 LLM 应用,而它的 serving 模式(超长会话 + 大前缀复用 + 工具驱动的请求间隔)和我们现有按 chat 假设设计的调度/驱逐策略不匹配。值得在我们的 vLLM 接入层加一层"会话/前缀感知"的调度与驱逐,并把工具调用元数据作为预测信号引入平台。由于它就是 vLLM patch,集成成本可控,适合做一个早期差异化特性。

## 值得泛读(8 篇)

- [ShuntServe:异构 Spot GPU 集群上的低成本 LLM Serving](https://arxiv.org/abs/2606.18600) — roofline 性能估计 + DP 模型放置优化(联合定 node 配置/并行策略/层分配),用 output-preserving 请求迁移 + 共享 tensor store 把 spot 抢占的迁移停机降到最低。AWS L4/A10G/L40S 异构集群跑 Llama-3.1-70B、Qwen3-32B,吞吐较 SOTA 高 1.42×/1.35×,较 on-demand 省 31.9%/31.2% 成本。**与我们成本叙事强相关,全文 HTML 暂未放出。**
- [ARGUS:万卡级 GPU 集群的生产级 tracing 与性能诊断](https://arxiv.org/abs/2606.20374) — 永远在线、细粒度训练可观测,总开销 <2%,kernel 事件压缩约 3700×(10MB→2.7KB/rank/step),逐级(迭代→阶段→kernel)自动定位 straggler/慢链路/pipeline 气泡。已在万卡集群线上跑 6 个月。对我们做训练/推理平台的可观测产品有直接参考。
- [Tangram:对并行规划隐藏 GPU 异构性](https://arxiv.org/abs/2606.16907) — 让"异构无感知"的并行规划器(Metis/Sailor)也能在异构集群用:把批量采购形成的"同构 GPU 岛"暴露给规划器,再把模型切片组合成均衡流水线。训练吞吐较现有异构规划器高至多 2.3×。异构集群规划思路可复用。
- [SwiftCache:多轮对话的异构模型 KV cache 共享](https://arxiv.org/abs/2606.16135) — 同机内低 KV 需求模型把空闲显存捐给高需求模型,经 NVLink 跨模型共享前缀 cache(绕开慢 PCIe);只在本地 GPU 留当前活跃层的 KV 以延长上下文。较 vLLM/SGLang 降 P99 TTFT 至多 69%,最大上下文扩 3.98×。多模型共置的显存复用思路值得借鉴。
- [TurboServe:流式视频生成的高效经济 serving](https://arxiv.org/abs/2606.19271) — 面向"长生命周期、逐块产出、紧延迟"的流式视频生成新负载:迁移感知放置 + 负载驱动自动扩缩,配合 chunk 合并批处理、GPU-CPU 卸载挂起/恢复、NCCL GPU-GPU 在线迁移。64×B300 上最坏 per-chunk 延迟降 37.5%、GPU 成本降 37.2%。新模态 serving 的会话调度范式。代码开源。
- [Beyond Prediction:面向尾延迟的 LLM 推理调度](https://arxiv.org/abs/2606.18431) — 指出"预测 decode 长度近似 SJF/SRPT"的调度在分布漂移/突发/显存压力下脆弱,且即便完美预测也难控 P90–P99 尾延迟。改用免预测、靠轻量统计信号做"软优先级提升"+ cache 感知抢占。生产/开源 trace 上 P99 TTLT 较"完美长度预测的 SRPT"降 35–50%,TTFT 降 34–47%。对我们调度器"是否要押注长度预测"是重要反向证据。
- [SAC:面向稀疏注意力 LLM、基于 CXL 的分离式 KV Cache 系统](https://arxiv.org/abs/2606.19746) — 长上下文把瓶颈从算力推向显存容量;传统 RDMA 分离内存池做粗粒度整取。SAC 用 CXL 针对稀疏注意力做更细粒度的 KV 取用。CXL 内存扩展用于 KV 池化,是值得跟踪的硬件方向。
- [SpecGen:用投机生成加速 Agentic Kernel 优化](https://arxiv.org/abs/2606.17518) — 把"用推理 LLM 迭代生成/验证/profile 自动调 GPU kernel"视作反馈引导搜索,刻画其系统级低效并用投机生成加速。和我们关心的"AI 自动优化算子/编译"链路相关。

## 趋势观察

- **本周是压倒性的 "LLM serving 系统周"**:21 篇近 7 天系统论文里,过半直接做推理服务,且高度集中在少数几个产品级痛点上,几乎没有纯算法味道。
- **KV cache 已成为 serving 的中心资源**,本周至少 6 篇围绕它做文章,且视角各异:跨模型共享(SwiftCache)、编码 Agent 的复用与驱逐(CacheWise)、重配时的迁移(ReMP)、故障时的 checkpoint 分散(LUMEN)、CXL 硬件分离(SAC)。信号很明确——谁管好 KV cache,谁就管好了推理成本与延迟。
- **"运行时弹性 + 可靠性"集体上分**:ReMP(在线改并行拓扑)、LUMEN(负载感知故障恢复)、TurboServe(在线迁移 + 自动扩缩)都在把过去的"部署期静态决策"下沉为"运行时动态决策"。三者共同前提是一个中心化、状态感知的调度器——这与我们做企业级推理平台的架构方向一致,值得作为统一基建投入。
- **分离式(disaggregation)开始从"静态切分"走向"动态复用"**:Tropical 不再争论 prefill/decode 该不该分,而是按 SLO slack 在运行时选择性复用,代表 disaggregation 的下一阶段成熟度。
- **成本与异构是贯穿主线**:ShuntServe(spot)、Tangram(异构训练)、RouteBalance(异构推理路由)、SwiftCache(同机异构模型共享显存)都在回答"如何在杂牌/可被抢占的 GPU 上把单位成本压下来"——这正是企业客户最痛的点。
- **新负载形态在涌现**:编码 Agent(CacheWise/SpecGen)、流式视频生成(TurboServe)、端侧 Physical-AI(Execution-State Capsules)都在挑战"为 chat 设计的 serving 假设"。建议把"Agent 负载"作为我们调度/缓存策略下一个重点适配对象。
- **可观测下沉到万卡级**:ARGUS 说明大规模训练/推理的 always-on、低开销 tracing 正在成为生产刚需,可作为我们平台可观测能力的对标基线。
