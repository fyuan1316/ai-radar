# AI 系统论文周报 2026-10-05

> 窗口:2026-09-29 ~ 2026-10-02(arxiv 跨周末无新投稿,实际覆盖到 10-02 Fri)。主抓 cs.DC,关键词围绕 LLM serving / MoE 推理 / 训练容错 / 调度与能效。
> 数据源:arxiv `cs.DC/recent` 列表 + 逐篇 abstract 页(API 端点本周持续 429,走列表页回退)。

## 本周精选(5 篇)

- **[MoE-CORE: Coordinated Expert Offloading and Residency for Memory-Constrained MoE Inference](https://arxiv.org/abs/2610.01950)** — 显存放不下整个 MoE 时,把"哪些专家常驻、哪些 offload"做成协同调度,TPOT 比 vLLM 的 prefetch 基线快 26–33x。
  - 核心思路:prefill 阶段用交替缓冲区整层 stage 专家;decode 阶段靠非均匀分层 cache 容量 + 路由历史感知的替换 + 跨层预取,把专家权重在 device/host 间的搬运藏到计算后面;可选"近似专家替换"再压一截延迟。
  - 关键数据点:DeepSeek-V4-Flash-W4A8 下 TPOT 38–45ms vs vLLM Prefetch 1269ms(~28–33x);GLM-5.2 下 207–221ms vs 5942ms(~26–28x);84GB NPU 上最佳 21.5ms TPOT。
  - 对我们的启示:大 MoE(DeepSeek/GLM 量级)在"显存不够放满权重"的节点上能不能跑,正成为服务化的真实门槛。我们的推理平台要把"专家 offload/常驻策略"做成可配置的一等能力(而非让用户自己堆卡),并把"路由历史感知替换 + 跨层预取"纳入默认调度;这直接决定能否用更便宜的中端卡/NPU 承接大 MoE,是成本竞争力的关键开关。

- **[Leto: Fast In-Place Recovery for LLM Training on Surviving Hardware](https://arxiv.org/abs/2610.00687)** — 训练中硬件故障后不回滚 checkpoint,而是用存活的硬件就地恢复,比 checkpoint 基线快 3.6–6.5x。
  - 核心思路:保留仍可用的模型状态与可复用的进程状态,在 shadow trainer 里预初始化缺失部分;用两级纠删保护 + chunk 级事务更新保证一致性,把"重载 checkpoint + 重建全局状态"这条慢路径砍掉。
  - 关键数据点:恢复快 3.6–6.5x;有效训练时间提升最多 13.7 个百分点;在 131,072-GPU 规模仿真下维持 >95% 有效训练时间;实测在 6/72 卡 A100 集群。
  - 对我们的启示:大规模训练集群里,MTBF 随卡数线性恶化,"故障恢复速度"已是吞吐的一等变量。若我们提供训练平台/Operator,应把"in-place 恢复 + shadow 预热"作为相对朴素 checkpoint 的差异化卖点,并在 SLA/成本模型里显式计入"有效训练时间占比",而不是只报峰值吞吐。

- **[ePACT: Energy-Performance-Aware Commitment Tracking for LLM Serving](https://arxiv.org/abs/2610.01784)** — 当运营商对电网有"每小时用电承诺"(超用/欠用都罚)时,用两级控制器调容量和 GPU 频率去贴合承诺,非对称偏差成本比 vLLM 降 73.8–75.7%。
  - 核心思路:全局 planner 定能耗目标,本地 decision maker 按预测能耗/完成时间/是否误期选配置(调副本容量 + GPU clock),在满足请求级 SLO 的前提下最小化偏差惩罚。
  - 关键数据点:非对称偏差成本降 73.8%(H20)/ 75.7%(H200);每小时平均偏差 2.16%/2.31%;SLO 达成率接近 vLLM。
  - 对我们的启示:电力合同/碳配额正从"事后账单"变成"实时调度约束"。面向有 PPA/峰谷电价/碳指标的大客户,我们可以把"能耗承诺追踪"做成平台级策略(GPU 调频 + 弹性副本联动),作为 FinOps/可持续性模块的卖点——这是纯比吞吐的引擎厂商给不了的运营层价值。

- **[Vosti: Specifying, Implementing, and Verifying Deterministic LLM Inference](https://arxiv.org/abs/2609.38981)** — 给"确定性推理"下形式化定义并形式化验证:固定模型/配置下,同 prompt 同采样状态产出 bitwise 一致的 logits,性能与 vLLM 的 batch-invariant 模式相当。
  - 核心思路:用 Verus 证明调度 + 分页/前缀共享 KV cache 不改变输出 logits;用 Triton 分析器证明 kernel 在不同 batch/query 长度/cache 布局下输出 bit 级一致;并指出现有 vLLM/SGLang 在某些执行变体下会静默破坏确定性。
  - 关键数据点:在所有测试的执行变体下产出 bitwise 一致 logits;decode-heavy 负载下性能与 vLLM batch-invariant 模式相当。
  - 对我们的启示:金融/医疗/政务客户的审计与可复现要求,正把"确定性/可复现推理"从 nice-to-have 变成合规硬指标。我们应提供一个"确定性模式"开关(牺牲部分批处理优化换 bit 级可复现),并在文档里讲清它与批处理优化的取舍——这是面向强监管行业的合规差异点,对标 TrustyAI 路线可直接纳入。

- **[Preserving Provenance in Shared KV Caches for LLM Serving](https://arxiv.org/abs/2609.38706)** — 多租户共享 KV cache 层只用 token 内容 + 粗粒度模型元数据做 key,会让不兼容上下文/不同 adapter 的相同 token 发生"provenance-blind"碰撞,既损正确性又泄隐私;提出 KV provenance 契约修复,热路径开销 <0.34ms。
  - 核心思路:要求共享 key 对"计算来源 + 共享域"单射;用把 per-request/per-worker provenance 绑进存取 key 的 canonical descriptor,再配一个 differential checker 找出哪些维度会改变 KV 状态。
  - 关键数据点:跨 adapter 碰撞使准确率从 0.94 掉到 0.64,不兼容 KV 表示使推理准确率归零;省略 salt 可凭时序实现 93% prompt 识别;修复后命中路径延迟变化 <0.34ms(低于 run-to-run 抖动)。
  - 对我们的启示:我们若做"全集群共享前缀/KV 复用"来省算力,必须把 adapter/权重配置/租户域纳入缓存 key,否则就是正确性 + 侧信道双重隐患。这是多租户 KV 复用的安全底线,应作为设计 review 的强制检查项,并把"provenance-aware 缓存 key + 时序 salt"写进多租户安全基线。

## 值得泛读(8 篇)

- [Cascadia: A Control-Plane-Free Alternative to Hyperconverged AI Infrastructure](https://arxiv.org/abs/2609.38697) — 在 Intel AIPC(CPU+核显+NPU)上用 libp2p/QUIC mesh 做去中心化 LLM 服务,每节点自带调度/路由,无中心控制面;3 节点 Phi-3.5-mini 达单节点 3.10x、4 节点 4.06x 吞吐。边缘/私有化去中心架构的一个激进样本。
- [RapidMoE: Exploiting Cross-Asymmetry via Adaptive Residual Offloading for Large-Scale MoE Inference](https://arxiv.org/abs/2610.01265) — 又一篇大 MoE 推理 offload,思路与 MoE-CORE 互补(自适应残差 offload),印证本周 MoE 显存墙是最热主线。
- [MegaFlux: Skew-Resilient MoE Megakernels via Pipelined Expert Replication](https://arxiv.org/abs/2610.00671) — 用流水化专家复制对抗 MoE 路由负载倾斜的 megakernel,解专家热点不均问题。
- [HAPMoE: Heterogeneity-Aware Automatic Parallelism Planning for Mixture-of-Experts Models Training](https://arxiv.org/abs/2609.39350) — 异构卡上自动规划 MoE 训练并行策略,对口混合卡集群的训练编排。
- [Joint Effects of GPU Server Topology, Parallelism, and Congestion Control on MoE Inference](https://arxiv.org/abs/2609.37828) — 受控仿真研究服务器拓扑 × 并行 × 拥塞控制对 MoE 推理的联合影响,给选型/组网提供实证依据。
- [Argus: A Real-EKS Study of When Predicting Spot Interruptions Beats Simple Checkpointing](https://arxiv.org/abs/2609.39067) — K8s operator 在真实 EKS 上对比"预测 Spot 中断"与"朴素 checkpoint";中断率高时预测可把浪费算力压到零,但前瞻时间过长会过度迁移反而更差。省钱跑 Spot 的实证边界。
- [Characterizing High Bandwidth Flash for LLM Serving](https://arxiv.org/abs/2609.39131) — 用高带宽闪存(HBF)扩 LLM 服务的存储容量,最快方案比纯 HBM 系统缩短完成时间 36.1–87.0%,并用缓存感知调度把闪存寿命从 ~5 年延到近 15 年。KV/权重分层存储的新一层。
- [Taming Speculative Search for Test-Time Scaling in LLM Serving (SpecScale)](https://arxiv.org/abs/2609.39334) — 针对 test-time scaling 的候选推理路径爆炸,用早剪枝 + 去重 + 延迟验证平衡延迟与算力,在 MATH/Olympiad 上吞吐与延迟双升且不掉准确率。推理侧服务化 reasoning 的系统视角。

## 趋势观察

- **本周主线从上周的"引擎→控制面"切换到"MoE 系统工程"。** 上周(09-28)集中在跨副本编排、KV 生命周期、PD 分离弹性;本周 cs.DC 被 MoE 占满——MoE-CORE / RapidMoE / MegaFlux(推理 offload 与倾斜)、HAPMoE(训练并行规划)、Joint Effects(拓扑×并行仿真)、Efficient Expert-Parallel on PCIe 一字排开。信号很清楚:大 MoE 已从"模型创新"下沉为"系统/显存/通信工程"问题,竞争焦点是"用更便宜的卡把放不满权重的大 MoE 跑起来"。
- **"显存墙 + 分层存储"成为服务化的硬约束。** MoE-CORE/RapidMoE 的 expert offload 与 Characterizing HBF 的 HBF 分层,本质都在解同一件事:权重/KV 放不进 HBM 时如何靠 host/flash 兜底而不崩延迟。KV/权重的多级存储(HBM→host→flash)正在定型为标准架构层。
- **能效从上周延续为一等调度目标,并进一步"合同化"。** 上周有 Joule Point / 能耗剖析,本周 ePACT 把"每小时用电承诺 + 非对称罚金"直接写进调度目标。能耗不再只是指标,而是带经济惩罚的实时约束。
- **正确性/合规作为新主题浮现。** Vosti(形式化验证的确定性推理)与 Preserving Provenance(多租户 KV 的正确性 + 侧信道)是本周新增维度:当推理平台堆了批处理/共享 KV 等一堆优化后,"输出可复现"和"缓存不串租户"成了需要被形式化保证的正确性问题。这条线与 TrustyAI/合规路线高度契合,值得我们在产品里预留开关与安全基线。
- **容错/弹性继续走强。** Leto(训练就地恢复)+ Argus(Spot 中断预测)表明:在超大集群与廉价可抢占算力上,"故障/中断下的有效算力占比"正成为与吞吐并列的核心指标。
