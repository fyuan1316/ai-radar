# AI 系统论文周报 2026-05-25

窗口:2026-05-18 → 2026-05-25(7 天,UTC v1 提交时间)
来源:arxiv cs.DC / cs.PF 全量 5 月列表(逐页扫到本周尾部)+ cs.LG/cs.AR 定向检索;每篇精选/泛读均逐条核对了 v1 提交日期(arxiv ID 与提交日期并不单调对应,本周已多次踩到“ID 高但其实是上周提交”的坑,凡入选都按 abs 页 published 时间二次确认)。
抓取说明:本周 arxiv API(export.arxiv.org/api)在本环境出口被持续限流(Rate exceeded / 429),改走 arxiv 列表页 + abs 页逐篇核读。cs.DC(本月 357 篇)、cs.PF(本月 68 篇)已扫到窗口尾,cs.LG 仅做关键词定向补充——若有只挂 cs.LG 的训练/RL 系统论文,本周可能漏网,下周用 API 复查时回补。

## 本周精选(5 篇)

- **[OSCAR: Offline Spectral Covariance-Aware Rotation for 2-bit KV Cache Quantization](http://arxiv.org/abs/2605.17757)** — 把 KV cache 压到 INT2 还能直接上 vLLM/SGLang 生产栈
  - 核心思路:长上下文服务里 KV cache 是显存与带宽的主瓶颈,大家想压到 2-bit 但一直“准了不能用、能用不够准”。简单的 Hadamard 旋转能削 outlier,可到 INT2 仍然崩,因为旋转方向跟下游 attention 实际消费的协方差结构没对齐。OSCAR 离线估计 attention-aware 的协方差结构,据此推导出固定旋转矩阵和 clipping 阈值,让量化方向对齐 attention 真正用到的子空间;关键是它不止给理论,还配了一个自定义 INT2 attention kernel,兼容 paged KV cache 和 fused kernel pipeline,能无缝塞进 vLLM/SGLang。
  - 对我们的启示:上周 KVServe 验证的是“在线选压缩档位”,OSCAR 把另一条腿——“超低位宽落地”——补齐了,而且明确点名兼容 paged attention + fused kernel,等于给我们 ServingRuntime 提供了一个可直接评估的 INT2 KV 方案。具体产品动作:把 OSCAR 的 INT2 kernel 纳入 KServe/llm-d 的 KV 压缩候选,做一次长上下文(≥32K)场景的精度-吞吐回归;若精度损失(8B 上仅 1.42 点)在我们 MaaS SLA 内,“2-bit KV”可作为长上下文租户的一档显式 serving 配置,而不是等引擎默认。
  - 关键数据点:KV cache ~8× 压缩;大 batch 下吞吐最高 7×,batch=1 解码最高 3×;Qwen3-8B 相对 BF16 精度差仅 1.42 点、Qwen3-4B 3.78 点

- **[PALS: Power-Aware LLM Serving for Mixture-of-Experts Models](http://arxiv.org/abs/2605.21427)** — 把 GPU 功率帽从“静态约束”变成与 batch size 联调的一等调度旋钮
  - 核心思路:现有 serving 系统把 GPU 功率当成固定上限,只在 batch/调度/并行层做文章。PALS 把功率帽当成可动态调的控制变量,和 batch size 等软件参数联合优化:用轻量离线 power-performance 模型刻画“功率档 × 软件参数 → 吞吐/能效”关系,再用一个反馈控制器在线选配置,既满足吞吐目标又最大化能效。实现直接做进 vLLM,不改模型不改 API,dense 和 MoE 都覆盖。
  - 对我们的启示:这正面回答了上周“The Illusion of Power Capping 证明 decode 阶段 power cap 是伪杠杆”留下的产品问题——单看功率没用,但把功率帽和 batch 联调就能拿到真实能效收益。对我们做企业级 MaaS:能耗/FinOps 不该只是 dashboard 上的只读数,功率帽应该接进 Inference Gateway 的调度面,作为“吞吐 SLA 下的能效旋钮”。短期 action:在我们 vLLM ServingRuntime 上复现 PALS 的离线建模 + 反馈控制,验证在 MoE(DeepSeek/Qwen3-MoE)上的 4–7× QoS 违例下降是否成立,这会直接变成对标 OAI 的差异化卖点(“同 SLA 下更省电”)。
  - 关键数据点:能效最高 +26.3%;功率受限下 QoS 违例下降 4×–7×;可跟踪动态功率预算;dense 与 MoE 多 GPU 均验证

- **[Understanding Inference Scaling for LLMs: Bottlenecks, Trade-offs, and Performance Principles](http://arxiv.org/abs/2605.19775)** — 给“并行度 × 模型规模”画了一张可操作的甜区图谱
  - 核心思路:推理型(长 CoT)负载把推理推进到“容量受限”区间,和传统单轮负载的瓶颈结构完全不同。作者在 GPU 集群上把 8B–671B 的模型按 Data/Tensor/Pipeline 并行的交互做了系统刻画,给出三条可直接用的原则:(1) 数据并行虽对小模型吞吐友好,但在推理负载上会触发 KV cache 碎片化,形成“容量陷阱”;(2) 张量并行在 ~32B 这个拐点附近才真正解锁显存、收益转正;(3) 前沿规模上,dense 模型(如 405B)受互联与显存带宽约束、偏好高 TP,而稀疏 MoE(如 DeepSeek-R1)受路由与同步延迟约束、偏好混合策略。
  - 对我们的启示:这是少有的“配置即性能”实证,直接能改我们平台的默认调度与推荐配置。产品动作:把这三条原则固化进 KServe/llm-d 的“模型规模 → 推荐并行配置”推荐器(尤其是“<32B 别盲目上 TP、推理负载下慎用纯 DP”这两条),避免用户用默认配置踩 KV 碎片陷阱;对 MoE 默认推混合并行而非纯 TP。这种“开箱即最优配置”比再快 10% 的 kernel 对企业客户体感更强。
  - 关键数据点:刻画范围 8B–671B;识别出 ~32B 的 TP 拐点;DP 在推理负载下的 KV 碎片“容量陷阱”;dense vs MoE 前沿规模瓶颈分野(带宽 vs 路由/同步)

- **[High-speed Networking for Giga-Scale AI Factories (Spectrum-X)](http://arxiv.org/abs/2605.21187)** — 十万卡级“AI 工厂”的网络长什么样、跨租户隔离怎么做
  - 核心思路:NVIDIA 把 Spectrum-X Ethernet 的多平面(multiplane)架构、设计原则、评测方法和大规模部署/调试踩坑公开。核心是用“拓扑并行”替代传统的层级深度,把负载均衡硬件化下沉到 NIC 和交换机,在微秒级对高度动态的网络状况快速反应(这正是 AI 训练 all-reduce 流量需要的时间尺度)。评测强调三个生产维度:接近线速的利用率、并发负载的跨租户隔离、以及链路故障下的优雅降级。
  - 对我们的启示:我们不造网络,但这篇是“企业级 AI 基础设施门槛”的对标参照系——客户问“你们平台能不能撑多租户大规模训练”,答案不只在调度器,还在网络的可预测性、跨租户隔离和故障降级。两个可落地点:(1) 把“跨租户网络隔离 + 链路故障优雅降级”列进我们多租户训练平台的能力清单与验收用例(10% 链路故障仅 7% 延迟上升是个可引用的标杆);(2) 我们的 Distributed Workload/Training Operator 在做拓扑感知调度时,应假设底层是这种多平面 + NIC 内负载均衡的结构,而不是经典 fat-tree。
  - 关键数据点:98% 理论线速、低抖动;10% fabric 链路故障下延迟仅 +7%、带宽容量成比例降级;并发负载下强跨租户隔离;面向数十万 GPU

- **[Energy per Successful Goal: Goal-Level Energy Accounting for Agentic AI Systems (A-LEMS)](http://arxiv.org/abs/2605.22883)** — 给 agent 工作流定义了“每完成一个目标耗多少能”的新计量单位
  - 核心思路:现有 AI 能耗基准都按“单次模型调用/单次训练”计量,但 agentic 系统里一个用户目标会触发多步编排、工具调用、重试、失败恢复,“调用次数”是实现细节而非任务属性,按 per-inference 归一会严重失真。A-LEMS 把计量单位从“每次推理能耗”改成“每个成功目标能耗(EpG)”:聚合一个目标全部尝试(含失败/重试)的总能耗,再按成功完成的目标数归一;配套五层观测管线把 RAPL 信号映射到 workflow 级能耗,并定义 Orchestration Overhead Index(OOI)分离“编排本身”相对线性执行的额外能耗。
  - 对我们的启示:随着我们平台往 agentic/工作流方向走,能耗/计费/SLA 的计量口径必须跟着从“token/调用”升级到“目标/工作流”。两条产品启示:(1) 我们的可观测与 FinOps 模块要支持“按工作流/按成功目标”归集能耗与成本,否则给客户的 agent 报价会系统性低估真实成本(本文测得推理类 agent 工作流是线性基线的 4.33×);(2) OOI 这个“编排开销指数”可以直接做成平台指标,帮客户判断“某个 agent 编排到底值不值这份额外能耗”——而且本文发现工具增强类任务 OOI 会反转到 <1(agent 反而更省),说明这是个能区分场景的真指标,不是一律加码。
  - 关键数据点:推理类任务 agentic 工作流 888.1 J/目标 vs 线性基线 205.3 J/目标(4.33×);工具增强类任务 OOI 反转到 <1.0×(agent 更省);覆盖 5 类推理 + 3 类工具增强任务族

## 值得泛读(7 篇)

- [Towards Multi-Model LLM Schedulers: Empirical Insights into Offloading and Preemption](http://arxiv.org/abs/2605.19593)(05-19)— 多模型共享异构硬件时,CPU-GPU offload 导致的解码吞吐下降是强非线性且模型相关的(小模型对 GPU 驻留更敏感),抢占开销主要来自模型权重重载而非 KV 搬运;给“多模型调度器该看哪些特征”列了清单,对我们做多租户多模型平台的调度器设计是直接输入
- [Protection Is (Nearly) All You Need: Structural Protection Dominates Scoring in Globally Capped KV Eviction](http://arxiv.org/abs/2605.18053)(05-18)— 在全局封顶的 KV 淘汰下,7 种主流策略(LRU/H2O/SnapKV/StreamingLLM/Ada-KV/QUEST/Random)都因为没有“提示边界结构保护”而质量崩塌(F1≤0.064);只要在边界保留 10% cache 就能恢复 69–90% 质量——结论是“保护结构边界”比“用什么打分算法”重要得多,前缀缓存/KV 淘汰的实现优先级要重排
- [Asymmetric Virtual Memory Paging for Hybrid Mamba-Transformer Inference (AVMP)](http://arxiv.org/abs/2605.22416)(05-21)— 混合架构(Jamba 类:attention 层的 KV cache 随长度线性增长,SSM 状态每层固定)用统一内存池会把 SSM 状态 pad 到 attention 页大小、浪费最高 7.3× 容量;AVMP 把两类 cache 拆成物理独立池、共享统一虚拟地址、仅在分配失败时迁移容量,吞吐提升 1.83×–13.3×。信号:SSM/混合架构正在要求 serving 层做专门内存管理,不能再假设“纯 Transformer KV”
- [ModeSwitch-LLM: A Lightweight Phase-Aware Controller for Cross-Mode LLM Inference on a Single GPU](http://arxiv.org/abs/2605.23057)(05-21)— 按 workload 相位把单条请求动态路由到 FP16/量化/投机解码/混合等不同运行模式,单 GPU 上相对 FP16 延迟 2.10×、能耗降 51.7%、精度仅 +0.17pt。又一篇“能耗当一线目标 + 运行时相位调度”的证据
- [CompPow: A Case for Component-level GPU Power Management](http://arxiv.org/abs/2605.21847)(05-21)— 不在数据中心层、而在 GPU 内部按组件做功率管理,对多种 ML 算子有 ~10% 能效 / 5% 性能潜力;和 PALS、EpG 一起把“能耗治理”同时往组件级(向下)和目标级(向上)两端延伸
- [LongLive-2.0: An NVFP4 Parallel Infrastructure for Long Video Generation](http://arxiv.org/abs/2605.18739)(05-18)— 基于 NVFP4 的并行基础设施(序列并行自回归训练 + 推理优化),训练 2.15×、推理 1.84×、5B 模型 45.7 FPS。视频生成是窄场景,但 NVFP4(FP4 精度)落地到训练+推理全栈这一点,对我们关注的“FP4 serving/training 精度趋势”有参考
- [Modeling the Impact of Fiber Latency on Compute-Communication Overlap in Geo-Distributed Multi-Datacenter AI Training](http://arxiv.org/abs/2605.19169)(05-18)— 离散事件仿真量化光纤时延对跨数据中心数据并行训练的影响,结论是两个 AI 集群最优间距 10–100km、空芯光纤可多拿 25% 计算-通信重叠。对“多 DC / 跨地域训练”规划是个具体的物理边界参考

## 趋势观察

- **能耗/功率从“二线指标”升级为本周主轴,而且同时向“上”和向“下”双向延伸**:本周至少 4 篇直接以能耗为一等目标——PALS(把功率帽当调度旋钮、与 batch 联调)、ModeSwitch-LLM(按相位切运行模式省能)、CompPow(GPU 组件级功率管理)、A-LEMS/EpG(goal 级能耗计量)。值得注意的是延伸方向:CompPow 把治理粒度压到 GPU 组件级(向下),EpG 把计量单位抬到“每个成功目标”(向上),PALS/ModeSwitch 则在运行时把功率/模式做成可调度变量。这是上周(MARLIN 四目标联合、The Illusion of Power Capping)能源主题的显著加深——从“开始关注”变成“成体系”。对我们:能耗必须从只读 dashboard 变成调度面的一等输入 + 计费口径的一部分。
- **KV cache 从“在线选压缩档位”推进到“2-bit 可部署”和“淘汰语义重构”两个深水区**:OSCAR 把 INT2 KV 做到带自定义 kernel、可塞进 vLLM/SGLang;Protection KV Eviction 证明全局封顶下“结构边界保护”压倒“打分算法”。延续上周 KVServe(service-aware 在线压缩)的主线,但落点更靠近工程落地——一个解决“位宽下限”,一个解决“淘汰该先保什么”。我们家 KV 路由/前缀缓存的实现优先级应据此重排:先做边界保护,再调打分。
- **“配置即性能”被实证化,平台层的价值从“堆系统”转向“给对默认配置”**:Understanding Inference Scaling(并行度×模型规模甜区、32B 拐点、DP 的 KV 碎片陷阱)和 Multi-Model Schedulers(多模型 offload/抢占代价非线性)都在说同一件事——同样的硬件,配置选错性能差一个量级,而这套配置知识可以沉淀成调度器/推荐器。对标 OAI,“开箱即最优并行配置”比再快 10% 的 kernel 更打动企业客户。
- **新架构开始要求 serving 栈做专门适配,“纯 Transformer + BF16”不再是默认假设**:AVMP 为 Hybrid Mamba-Transformer 做双内存池,LongLive-2.0 把 NVFP4 落到训练+推理全栈。SSM/混合架构与 FP4 精度正在从“模型创新”外溢成“serving 基础设施要求”,我们的 ServingRuntime 抽象需要预留“非均质 cache 管理 + 低精度数值”的扩展位。
- **本周相对沉寂的两条线:大规模训练容错 / RL 后训练系统**。上周(ReCoVer、EEP、MinT、DualKV)很热的“容错升级为不变式 + RL 后训练进系统层”,本周在窗口内(05-18→05-25)未见同量级新作——但这部分高度依赖 cs.LG 单挂论文,而本周 arxiv API 被限流、cs.LG 只做了关键词补充,存在漏网可能。下周 API 恢复后优先用 `(cat:cs.LG) AND (训练容错/RL 系统)` 复查回补,不据此下“该方向降温”的结论。
