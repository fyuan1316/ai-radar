# AI 系统论文周报 2026-08-17

> 采集窗口:arxiv 提交日 2026-08-10 ~ 2026-08-17(过去 7 天)
> 数据源:arxiv.org 全文检索(export API 当日持续 "Rate exceeded",按惯例走 arxiv.org 检索页 via WebFetch)。检索维度覆盖 LLM/model serving、inference optimization、GPU scheduling/cluster、distributed training、KV cache、speculative decoding、MLOps、RAG system。
> 精选论文均已读 abstract + intro 要点 + 实验数据后撰写。

## 本周精选(5 篇)

- **[OpScale: Operator-level Provisioning and Autoscaling for LLM Serving](https://arxiv.org/abs/2608.13499)** — 把弹性伸缩的粒度从"整模型"下沉到"算子级",在满足 SLO 的前提下省 36% GPU。
  - 核心思路:现有 serving(含 KServe/vLLM 那套)都把整个模型当成一个不可分的伸缩单元,流量抖动时要么爆 SLO 要么整卡闲置。OpScale 观察到推理内部算子异构性极大,于是以算子为伸缩原语,配套 profiling→provisioning→placement→runtime 一条链路来压制细粒度分配带来的组合爆炸。
  - 关键数据点:生产 trace,最多 40×A100 / 24×GB200 上,守住 SLO 的同时少用 36.3% GPU、降 28% 功耗;固定成本预算下吞吐提升 44%。
  - 对我们的启示:我们的 serving 层若还停留在 KServe 那种整 InferenceService 级 HPA/KPA,天花板就是"整模型副本"。值得评估在自研 serving runtime 里引入算子级(或至少 prefill/decode 分离级)的伸缩与放置策略——这是"省 GPU 成本"最直接能对客户讲的数字,也是和标准 KServe 拉开差异的点。落地代价是要自建 profiling+placement 控制面,需权衡。

- **[TideRL: Boosting Agentic RL Goodput with Readiness-Aware Scheduling](https://arxiv.org/abs/2608.10402)** — 面向"多轮 agentic RL"的训练系统,goodput 最高 5.6×。
  - 核心思路:多轮 agentic RL 里,rollout 会反复因外部环境暂停/恢复、上下文不断变长、完成时间高度离散,GPU 空等和重复 prefill 是纯浪费。TideRL 用三招:Continuous Task Batching(跨暂停保持 rollout 状态)、Resource-Aware Ref-Actor Pipelining(按就绪度在解耦流式 / 共置聚合间切换)、Elastic Resource Scaling(在 rollout 与训练阶段间动态搬 rank)。
  - 关键数据点:相对同步基线 goodput 最高 5.6×、相对异步基线 >33%;KV cache 命中率 1.58×;单步训练时间降 44.3%,等待时间降 77.6%。
  - 对我们的启示:RL 后训练(RLHF / RLVR / agentic)正在成为独立的基础设施战场,痛点不是算力峰值而是 goodput(有效吞吐)。如果我们要做"训练平台"侧的差异化,rollout 调度 + 训推资源弹性复用是比"又一个分布式训练封装"更值得投入的方向。可与 Ray/veRL 生态的整合方式一起评估。

- **[CoRun: Padding is Simple and Efficient for Deterministic LLM Inference](https://arxiv.org/abs/2608.14376)** — 用"位置不变"而非"批不变"实现确定性推理,吞吐不降反升。
  - 核心思路:即便固定采样参数和随机种子,LLM 推理输出仍然不一致(不同 batch 形状下浮点归约顺序变化),这直接污染模型评测和 RL 训练。业界已有的 batch-invariant 方案能保确定性但代价惨重(>2× 延迟、吞吐掉最多 74%)。CoRun 改走 position-invariance:prefill 隔离执行 + decode 定形批处理,配 CUDA graph 高效跑。
  - 关键数据点:相比 batch-invariant 基线,吞吐 +15%~324%,TTFT 平均降 51.8%,TPOT 平均降 48.6%;在 Qwen、DeepSeek 等多架构验证。
  - 对我们的启示:确定性/可复现性是企业级(尤其金融、合规、模型评测流水线)的硬需求,过去只能靠牺牲性能换。CoRun 说明可以低成本给到"确定性推理"这个 SKU——建议在产品里把它作为可开关的服务级承诺(如"评测模式/审计模式"),对标 OAI 也少有人做到。

- **[Beyond Capacity: Scalable MoE LLM Inference via High-Bandwidth Flash with Direct GPU and HBM Paths](https://arxiv.org/abs/2608.14333)** — 用高带宽闪存(HBF)把 MoE 专家权重从 HBM 里挪出来,双路径供给。
  - 核心思路:MoE 专家权重膨胀让 HBM 容量和成本吃紧。该工作引入 HBF 存专家权重,提供两条并发不复制的供给路径——direct(HBF→GPU)与 relay(HBF→HBM base die→GPU);再靠"提前确定专家"把 HBF 读延迟和前序计算重叠,并把不可变的专家权重与可变的 KV cache 分开管理以减少互扰。
  - 关键数据点:代表性负载下,较仅用 HBM relay 路径吞吐 1.94×,较传统单路径端到端 1.90×。
  - 对我们的启示:这是"内存层级向 HBM 之下扩展"趋势的又一例(本周还有多篇 KV offload/flash 论文)。对我们意味着:在大 MoE 模型托管上,可以主打"用更便宜的存储层级换单卡可托管更大模型",给客户降 HBM 成本。虽偏硬件协同、短期难自研,但要跟踪它对上游 vLLM/SGLang 内存管理接口的影响。

- **[GenRec: An LLM-Backed Recommendation Ranker at Netflix](https://arxiv.org/abs/2608.10257)** — Netflix 生产级 LLM 排序器,用 prefill-only 推理压成本。
  - 核心思路:把传统"人工特征 + 判别式排序器"换成"自研基础 LLM + 口语化用户历史/上下文"的生成式排序。两阶段:P1 用 Netflix 数据适配开源 LLM,P2 用对齐业务目标的奖励信号做专精。服务侧关键是成本约束下的 prefill-only 推理设计(排序只需一次前向打分,不做自回归解码)。
  - 关键数据点:用远少于生产基线的 P2 标注样本和输入信号,拿到离线+在线均统计显著的收益。
  - 对我们的启示:这是"LLM 落生产"的真实成本工程范本。prefill-only / 打分类推理是一类被独立优化的负载(和 chat 生成的资源画像完全不同),我们的 serving 层若能识别并针对这类"仅 prefill、无 KV 增长"负载做专门调度/批处理,能显著提升这类企业客户(推荐、风控、检索排序)的性价比。

## 值得泛读(8 篇)

- [Kairos / Taming Request Imbalance: SLO-Aware Scheduling for Disaggregated LLM Inference](https://arxiv.org/abs/2605.02329) — 分离式架构下 prefill 侧 urgency 优先级 + decode 侧 slack 引导批处理,端到端 SLO 达成 +33.8%(注:5 月原稿,8-11 更新 v2)。
- [Scheduling Mixed RL Rollouts Beyond Prefix Locality (MISA-T)](https://arxiv.org/abs/2608.11152) — 混合 RLVR/RLHF/agentic rollout 的 KV 容量分配 + 驻留时间计费,较 cache-aware vLLM Router rollout 吞吐 +35.6%。
- [Exploring High-Bandwidth Flash for Modern LLM Inference](https://arxiv.org/abs/2608.13868) — 系统性评估 HBF 作为 HBM 容量瓶颈解法的机会与挑战,是上面精选 HBF 论文的背景铺垫。
- [InFactPlanner: Planning Sustainable Geo-Distributed LLM Data Centers](https://arxiv.org/abs/2608.12915) — trace 驱动的地理分布式推理选址决策支持,做碳/成本的 what-if 分析。
- [MoE-Prism: Disentangling Monolithic Experts for Elastic MoE Services](https://arxiv.org/abs/2510.19366) — 把单体专家拆成子专家,支持请求级路由弹性与异构 serving 预算(8-10 更新)。
- [Lifecycle-Optimal Tokenization: Vocabulary Size as a Deployment-Regime-Dependent Parameter](https://arxiv.org/abs/2608.11361) — 论证成本最优词表随 serving 场景变化,端侧到数据中心可差 16×,把词表当基础设施参数。
- [ImpactHO: Importance-Aware KV Cache Transfer for Multi-User Edge LLM Handover](https://arxiv.org/abs/2608.10545) — 边缘多用户切换时按重要度 + 注水法迁移高价值 KV 分片。
- [MERA: Model Evolution and Routing with Skill Adaptation for Agentic Systems at Scale](https://arxiv.org/abs/2608.10333) — 迭代微调 + SkillBook 蒸馏提升小模型,配成本校准路由。

## 趋势观察

本周(相对上周)系统类论文明显聚在四条主线:

1. **SLO-aware 细粒度调度/伸缩成为主战场**:OpScale(算子级伸缩)、Kairos(prefill/decode 分离调度)不约而同瞄准"分离式架构 + 长尾请求"下的 SLO 达成率,共同结论是"整模型级伸缩粒度太粗、要下沉"。对做 serving 产品的我们,这是最能量化对客价值(省 GPU / 保 SLO)的方向。
2. **内存层级向 HBM 之下扩展**:HBF/flash 相关本周井喷(Beyond Capacity、Exploring HBF,叠加上周的 OasisKV KV offload),根因是 MoE 专家权重膨胀把 HBM 容量/成本逼到墙角。产品叙事:用更便宜存储层级换"单位成本可托管更大模型"。
3. **RL 后训练基础设施独立成赛道**:TideRL(rollout 训练 goodput)、MISA-T(混合 rollout 的 KV 调度)都在解 agentic/多轮 RL 的独特系统问题——痛点是 goodput 与 KV 复用,而非峰值算力。这块过去被"训练框架"笼统覆盖,现在正被拆出来单独优化。
4. **确定性/可复现性被当作可交付能力**:CoRun 把"确定性推理"从"必然掉性能"变成"几乎免费甚至更快",直接服务于评测与 RL 场景——是企业级/合规叙事里被低估的一个 SKU。

补充:本周窗口外(8-5~8-9)还有几篇强系统论文值得留意——Cascade(SLO 预算感知,goodput 2.4×)、ElastiCo(训推共卡 co-location,JCT 降 2.94×)、LLMVisor(多租户 GPU 分片的微秒级延迟归因)、Determinism-Preserving GPU Spatial Sharing(Vitamin-E,训练吞吐 3.50×)。其中训推共卡与多租户 GPU 分片是和我们"多租户 + GPU 调度"能力高度重叠的方向,建议下周持续跟踪同一批作者/机构。
