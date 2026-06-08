# AI 系统论文周报 2026-06-08

> 数据源:arxiv API(cs.DC / cs.LG / cs.PF),提交时间 2026-06-01 ~ 2026-06-08,共筛出 27 篇与 AI 基础设施/系统相关的新论文。下面只挑跟"做产品"有关的方向,纯算法/纯模型创新已剔除。

## 本周精选(5 篇)

- **[FlexNPU: Transparent NPU Virtualization for Dynamic LLM Prefill-Decode Co-location](https://arxiv.org/abs/2606.04415)** — 在昇腾 NPU 上做用户态透明虚拟化,把 prefill/decode 的动态 co-location 当一等公民。
  - 核心思路:在 AscendCL API 层做拦截(interpose),把 NPU 操作路由到 per-device daemon,不改模型代码、不改 AI 框架、不改 NPU 驱动,就实现了 NPU 对象虚拟化 + 算子分发控制 + 阶段感知调度。prefill 计算密集、decode 受显存带宽约束,二者资源特征互补,FlexNPU 据此做动态 PD co-location,而非静态 PD 拆分。
  - 对我们的启示:这正是我们在昇腾路线上一直缺的那块——**不侵入框架/驱动就能拿到调度控制权**。我们自家做 GPU/NPU 共享(对标 HAMi)目前多在设备插件/cgroup 层,而 FlexNPU 证明"AscendCL interpose + daemon"这条用户态路线在 384 卡规模上是站得住的。建议把它作为昇腾侧 PD 调度的参考架构评估,尤其评估 daemon 模式对多租户隔离和故障域的影响。
  - 关键数据点:384 卡 Ascend 910C 跑 DeepSeek-R1,相比静态 PD 拆分吞吐 +5.15% 与 +26.33%;Qwen2.5-7B 上相比静态 PD co-location,TTFT 降低超 92% 且 TPOT 基本不变;相比直通(passthrough)无可测量推理开销。

- **[DriftSched: Adaptive QoS-Aware Scheduling under Runtime Token Drift for Multi-Tenant GPU Inference](https://arxiv.org/abs/2606.02982)** — 直面"实际输出长度跑偏于准入时估计"这个多租户调度的老大难。
  - 核心思路:观察到 observed output length 经常偏离 admission-time estimate(称为 runtime token drift),会导致 workload 误分类、队列失衡、尾延迟上升、QoS 下降。DriftSched 组合了 workload 分类 + token 预算估计 + 租户感知队列管理 + 运行时反馈驱动的 drift 补偿,并系统性对比 FIFO/Priority/Weighted/SJF/Aging 五种策略。
  - 对我们的启示:多租户 GPU 推理是我们企业级能力的核心卖点,这篇把"准入估计不准"这个工程痛点形式化并给了可复现 benchmark。建议产品里把 **drift 补偿(运行时反馈纠偏)**作为调度器的标准能力对外讲;同时它实证 SJF 在持续争抢下综合最优,可作为我们调度策略默认值的依据。注意它只在单卡 L4 上验证,规模化与跨租户公平性需我们自己补。
  - 关键数据点:自适应偏置纠正使 workload 估计误差平均降低 38.8%(MAE)/40.5%(RMSE);SJF 相比 FIFO 在持续争抢下中位端到端延迟约 -42%、P99 约 -16%。

- **[Observation, Not Prediction: Conversation-Level Disaggregated Scheduling for Agentic Serving](https://arxiv.org/abs/2606.01839)** — 把调度单元从"单轮"抬到"整段会话",用可观测量取代不可预测量。
  - 核心思路:Agent 工作负载总成本在任务到达时未知,逐轮决定是否 PD 拆分要依赖 decode 长度/工具行为/KV 增长这些"调度时不可观测"的量,被迫去预测。论文指出这种"依赖预测"是调度单元造成的,不是负载本身决定的——把单元从 turn 抬到 conversation,就把逐轮不规则性转化为"turn-1 计算密集 prefill + 长尾内存受限"的稳定两阶段结构,只需读首轮输入长度与各 decoder 的 KV 占用(都直接可观测)。系统 ConServe:首轮 prefill 路由到高吞吐 prefiller,KV 只搬一次,会话整条尾巴钉在单个 decoder。
  - 对我们的启示:Agentic serving 是今年增长最快的负载形态,我们的 KServe/推理网关层迟早要面对"会话级"而非"请求级"的调度抽象。这篇给了一个**无需训练预测模型**就能做 agent 调度的干净原则,工程落地风险低,值得在我们的推理路由层做一版 PoC 对比。
  - 关键数据点:相比逐轮预测基线,p95 首个有效 token 时延(TTFET)-51.08%、能效 +7.51%,且保持末轮 TBT 与 SLO;两阶段映射到异构 GPU tier 再增能效 +22.75%。

- **[Tangram: Unlocking Non-Uniform KV Cache for Efficient Multi-turn LLM Serving](https://arxiv.org/abs/2606.06302)** — 让"非均匀 KV 压缩"在真实 serving 系统里跑得动。
  - 核心思路:非均匀 KV 压缩(按每个 head 重要性差异化保留)能更好保信息,但 KV 异构会带来内存碎片、调度复杂、kernel 利用率下降。Tangram 三招破解:(1) Deterministic Budget Allocation——按 head 内在 pattern 给静态内存足迹,消除动态调度开销与 prefill 停顿;(2) Head Group Page——把保留需求相近的 head 聚类,用独立向量化页表管理,最大化物理内存回收;(3) AOT Load Balancing——用静态预算 profile 保证 GPU 利用率均匀。
  - 对我们的启示:多轮对话是企业 chat/agent 的主场景,KV 内存压力直接决定单卡并发与成本。Tangram 把学术界的"非均匀压缩"工程化成了可上线方案且**完全保模型精度**、已开源,适合我们直接评测纳入推理引擎选型;尤其"静态预算消除运行时调度开销"这一思路对我们追求确定性 SLO 很对味。
  - 关键数据点:相比基线吞吐最高 2.6x,且完全保持模型精度;开源 https://github.com/aiha-lab/TANGRAM

- **[Ekka: Automated Diagnosis of Silent Errors in LLM Inference](https://arxiv.org/abs/2606.04594)** — 给"输出质量悄悄变差但无报错"的静默错误做自动化根因诊断。
  - 核心思路:serving 框架软件栈复杂、优化众多,快速迭代会引入 silent error——输出质量无声退化却无显式错误信号,且高层症状与底层根因语义鸿沟大,极难诊断。Ekka 把它框定为 differential debugging:用语义正确的参考实现做基准,系统性对齐并比对 target 与 reference 框架的中间执行状态来定位根因。还构建了来自主流 serving 框架真实 silent error 的 benchmark。
  - 对我们的启示:这直接对应我们的可观测性/质量保障路线(与 TrustyAI 思路相邻)。当我们叠加量化、PD 拆分、KV 复用等优化时,silent error 风险只增不减。建议把 Ekka 的"差分调试 + 参考实现比对"方法论纳入我们的推理回归/上线门禁,作为"模型行为不变性"测试的工程范式。
  - 关键数据点:silent error 诊断 pass@1 80%、pass@5 88%,优于现有 SOTA;并新诊断出 4 个 serving 框架的 silent error,全部已被开发者确认。

## 值得泛读(7 篇)

- [Scaling LLM Inference Beyond Amdahl's Limits (Albireo)](https://arxiv.org/abs/2606.01927) — 找到经验最优 TP degree,通过重叠调度/IO 与计算缩小不可扩展部分,相比 vLLM 吞吐最高 1.9x、能耗 -54%。
- [Beyond Greedy Chunking: SLO-Aware Sliding-Window Scheduling (SlidingServe)](https://arxiv.org/abs/2606.05933) — 轻量批延迟预测器 + 滑窗动态 chunking + 多级优先级,服务能力最高 +30%、SLO 违约率降 16%–53%。
- [NetKV: Network-Aware Decode Instance Selection for Disaggregated LLM Inference](https://arxiv.org/abs/2606.03910) — PD 拆分下把网络传输代价纳入 decode 实例选择,64-GPU 四层 fat-tree 上平均 TTFT 最高 -21.2%、SLO 达成 +20.1pp。
- [SparseX: Segment-Level KV Cache Sharing for Interleaved LLM Serving](https://arxiv.org/abs/2606.01751) — 段级(非前缀)KV 复用,Sparse-Q 索引 + 单次前向稀疏重算,免训练、兼容 Prefix Cache,统一支持多轮/RAG/agent。
- [Don't Let a Few Network Failures Slow the Entire AllReduce (OptCC)](https://arxiv.org/abs/2606.01680) — 给非对称带宽下 AllReduce 完成时间证下界,四阶段流水算法,50% 带宽损失下仍逼近无故障 ring 的 2–6%(SOTA 高达 57% 开销)。
- [Clairvoyant: Predictive SJF Scheduling for Serial LLM Backends](https://arxiv.org/abs/2606.07248) — 给 Ollama/llama.cpp 这类串行后端做 drop-in sidecar,19 个轻量词法特征预测响应长度做 SJF,短请求 P50 延迟 -70%~76%,适合边缘/本地部署。
- [Demystifying NVSHMEM: System-Level Analysis of GPU Communication](https://arxiv.org/abs/2606.05951) — 系统梳理 NVSHMEM 的 PGAS/对称内存/设备端发起通信模型,并以 DeepEP 为例,定位其作为 GPU 通信运行时构建块的角色与权衡。

## 趋势观察

- **调度的主线从"预测"转向"可观测/反馈纠偏"**:本周三篇调度论文(DriftSched 的 drift 补偿、ConServe 的"观测取代预测"、Clairvoyant 的轻量预测+SJF)不约而同在攻击同一个软肋——准入时对请求成本估不准。方向一致:要么用运行时反馈纠偏,要么抬高调度单元把不可观测量消掉。这对我们调度器设计是明确信号:别再堆更复杂的预测模型,先把运行时反馈通路打通。
- **PD 拆分/co-location 仍是 serving 系统的兵家必争地**:FlexNPU(NPU 虚拟化做动态 co-location)、NetKV(拆分下的网络感知路由)、ConServe(会话级拆分)、Albireo(TP 维度优化)四篇都围绕 prefill/decode 资源特征做文章,且越来越关注异构硬件 tier 与网络拓扑——单机优化红利见顶,战场上移到集群/网络层。
- **昇腾/国产 NPU 开始出现严肃的系统级工作**:FlexNPU 在 384 卡 910C + DeepSeek-R1 上做透明虚拟化,是本周与我们昇腾路线最直接相关的一篇,说明国产卡的系统软件栈正在补齐 GPU 生态的虚拟化/调度能力,值得持续跟踪。
- **可靠性/质量保障(silent error)作为独立方向冒头**:Ekka 把"静默质量退化"做成可自动诊断的工程问题,呼应优化越堆越多后"正确性"取代"性能"成为新瓶颈的趋势,与我们可观测/合规路线契合。
- 相比近几周,本周纯 KV cache 压缩类论文占比下降,调度与可靠性占比上升;系统工作更强调"不改框架/驱动/硬件"的透明落地(FlexNPU、SparseX、Clairvoyant 均强调 drop-in/training-free),工程可用性导向明显。
