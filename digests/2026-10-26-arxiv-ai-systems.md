# AI 系统论文周报 2026-10-26

> 覆盖窗口:2026-10-19 ~ 10-26(arxiv API 本期仍返 "Rate exceeded",走 cs.DC/cs.PF recent 列表 + xllm-io/daily-papers 周更 issue + WebSearch 查漏,逐篇读 abs 页核实)。筛选口径见 `tasks/arxiv-ai-systems.md`:只收系统/调度/服务化且有实验验证的,纯模型结构/纯应用/纯理论不收。上周(10-19)已覆盖的 BLIS / FastEEP / JointServe / CacheSmith / Meta-AMD / Quota-aging / Prorsa 等不再重复。
>
> 说明:本期几篇高价值论文(PairSight / KVCompass / BaGuaLu-2)v1 落在 10-16,严格说贴着 7 天窗口上沿、上周 digest 未覆盖,本周才经 daily-papers 周更浮现,按"新且相关且未收录"纳入,日期已逐篇标注,不冒充本周新作。

## 本周精选(5 篇)

- **[HAWK: Heterogeneity-Aware KV Cache Transfer for Efficient GPU-NPU Phase-Disaggregated LLM Inference](https://arxiv.org/abs/2610.29873)**(10-21)— 把 prefill(算力密集)放 GPU、decode(访存密集)放 NPU,跨异构芯片用 RDMA 直传 KV cache。
  - 核心思路:prefill/decode 两阶段的硬件偏好天然不同,与其在同构集群里硬凑,不如按阶段分派到最合适的芯片上。难点在 GPU 与 NPU 的 tensor layout 不一致,HAWK 在 NPU 侧开"布局感知的 RDMA buffer",让 GPU 算出的 KV 直接 DMA 到 NPU 且无需二次 rearrange 即可被 decode 消费。
  - 关键数据点:等 SLO 约束下端到端性能落在纯 GPU 基线的 7.88% 以内(即几乎不掉性能),功耗能效最高 1.26x、成本能效最高 1.72x。
  - 对我们的启示:这篇几乎是为我们"NV + 昇腾多芯纳管"量身定做的论证——异构不是只能各跑各的,prefill/decode 阶段级分派能把贵的 GPU 省下来、让 NPU 吃下访存密集的 decode,拿到真金白银的成本/能效收益。产品决策级动作:(1) 推理控制面要把"阶段→芯片"的亲和性做成可声明的调度策略,而不是把一个实例钉死在单一芯片;(2) KV 跨芯片传输要把 tensor layout 转换(昇腾 NZ 格式 vs. NV 行主序)当成一等公民,在网关/传输层做零拷贝适配,这正是 PD 分离落到多芯环境的核心工程债。可直接作为我们昇腾线差异化卖点立项。

- **[PairSight: Characterizing and Predicting Operator-Level Interference in GPU Sharing for DNN Inference](https://arxiv.org/abs/2610.23086)**(10-16)— 共享 GPU 时两个算子互相拖慢多少,过去靠"算力/访存二元规则"猜,PairSight 用算子级 + 硬件计数器把它预测准。
  - 核心思路:单个推理任务很少能同时打满 GPU 的算力和访存带宽,共享(SM 划分 co-locate)能提利用率但引入干扰。作者用硬件计数器把干扰根因定位到"共享访存路径的争用",且某任务的 slowdown 取决于与它同住的另一个算子是谁——不是单任务属性。于是训练一个硬件感知预测器,在 co-locate 之前就预测每个任务的时延。
  - 关键数据点:6 个模型(含 LLM)上平均预测误差 4.3%,而"算力-访存强度规则"是 19.0%;少量样本即可泛化到没见过的模型/输入。
  - 对我们的启示:这直击我们 HAMi/vGPU 做 GPU 共享切分时最大的黑盒——"把哪两个负载塞一张卡上不会互相打架"目前基本靠拍脑袋或静态配额。PairSight 证明干扰是可解释、可预测、且依赖"配对关系"的。产品动作:在 HAMi 调度器的 bin-packing 决策里引入一个轻量干扰预测器(算子级 profile + 几样本在线校准),把"co-location 后的 SLO 预估"作为放置约束,而不是只看显存/算力余量就塞。这是把 GPU 共享从"能跑"做到"敢对客户承诺 SLO"的关键一跳。

- **[KVCompass: A Discovery Plane for Internet-Scale Prefix Cache Sharing in LLM Serving](https://arxiv.org/abs/2610.24179)**(10-16)— 同一模型跨多地域部署时,各地重复 prefill 相同热门前缀是浪费;KVCompass 做一个"KV 发现平面"让请求跨地域找到已有的 KV。
  - 核心思路:把 KV cache 的"身份(是什么)"与"位置(在哪台 worker)"解耦。难点在于缓存持有者随请求和驱逐动态变化,不是传统哈希查表能解决的。KVCompass 建一个支持变长前缀查找的发现索引,网络边缘可常数时间本地读表,请求据此在"缓存复用 / 负载 / 网络距离"三者间权衡着路由。
  - 关键数据点:P99 TTFT 比基线低 1.3–14x,P99 端到端时延最高低 3.7x,吞吐最高提升 4.7x,峰值负载因子距理论最优 2% 以内;64-worker 地域分布仿真 + 横跨三大洲 14-worker 实测台。
  - 对我们的启示:多地域/多集群是企业私有化与混合云交付的常态,而我们的 KV 复用目前基本困在单集群内。KVCompass 给出的"发现平面"是一个清晰的产品模块边界:在我们的推理控制面之上加一层"全局前缀缓存目录 + 亲和路由",让跨 region 请求优先落到已有 KV 的 worker。注意它强调持有者动态变化导致不能用静态哈希——我们若自研要把驱逐/迁移事件实时同步进发现索引。这跟上周 llm-d 方向连起来看,"KV 复用正从单机→跨层级存储→跨地域集群"三级跳,控制面要预留这一层抽象。

- **[SARIA: Persistence-Aware KV Caching with Coordinated DRAM-SSD Reload for LLM Agents](https://arxiv.org/abs/2610.31169)**(10-22)— 多轮 agent 的 KV 放不下 DRAM 要落 SSD,但全量落盘既磨损 SSD 又拖慢重载;SARIA 做选择性落盘 + 协调重载。
  - 核心思路:双路径策略。写路径只持久化"预计在被挤出 DRAM 后还会被复用"的 KV block(用驱逐与复用历史判断),避免无谓写;读路径在 prefill 后把选中的 SSD 常驻块提升回 DRAM 加速同会话后续访问;再加一个传输协调器在读写同时发生时分配带宽。实现在 LMCache MP 上。
  - 关键数据点:相比全量重复落盘,SSD 写入量减少 57.1–58.9%;相比纯 DRAM 方案,平均 TTFT 降 42.3–79.7%;在 TraceLab、WEKA 真实 trace 上验证,覆盖 full-attention 与 hybrid-attention 模型。
  - 对我们的启示:私有化/边缘盒子显存小、又要跑长会话 agent,把 KV 下沉到 SSD/host 是必然,但"落盘把客户的企业级 SSD 几个月磨穿"是真实售后风险(配合同期 Gandalf 的 7.3x 寿命结论,这已成一个明确议题)。产品动作:我们的 KV 分层栈不能做成"内存满就无脑刷盘",要把"复用概率预测 + 选择性持久化 + 读写带宽协调"做进去,并把 SSD 磨损量作为可观测指标暴露给运维。LMCache 已是事实标准底座,建议直接在其上做二次开发而非另起炉灶。

- **[BaGuaLu-2: Taming Dynamic Memory Fluctuation for Efficient MoE Model Training over 10,000 GPUs](https://arxiv.org/abs/2610.23064)**(10-16)— 细粒度 MoE 训练里专家负载动态不均导致显存剧烈波动,BaGuaLu-2 用"弹性显存供给"替代静态预留。
  - 核心思路:现有系统要么过量预留(平时显存闲置)、要么不足(负载峰值 OOM 崩溃 + 人工回滚)。BaGuaLu-2 把显存分配从"一次性调优的静态选择"变成"连续、细粒度的在线控制",按每个 training batch 的实际需要精确授予激活显存,并用系统优化抵消动态管理开销。
  - 关键数据点:在 12,288 张 GPU 上训练 1.04 万亿参数模型,持续 >2 EFlops、MFU 达 35%;相比 Megatron-Kuai、AdaPipe 分别平均提速 1.14x、1.13x。
  - 对我们的启示:本期唯一的超大规模训练侧实证,点出一个我们训练平台容易忽视的痛点——MoE 训练的显存是"动态波动"而非恒定,静态 request/limit 配额在 MoE 上要么浪费要么 OOM。产品动作:(1) 训练作业的显存配额要支持"弹性区间 + 在线细粒度调整",而不是 K8s 式一次性 request/limit 钉死;(2) OOM 不该靠人工回滚,调度层要有基于 batch 级显存预测的保护与弹性回收机制。这对我们接 MoE 大模型训练(DeepSeek/Qwen-MoE 量级)是硬门槛,不解决就只能靠过量堆卡。

## 值得泛读(8 篇)

- [RISK-KV: Quality-Aware Selective KV Cache Reconstruction for Distributed LLM Inference](https://arxiv.org/abs/2610.29544)(10-21)— 请求迁移/中断恢复时不全量留 KV,用跨层岭回归重建缺失层:KV 存储省 18.2–33.3%、困惑度变化 <0.5%、恢复场景比全量重放快 1.51–3.31x。对我们做"抢占/故障后会话恢复"有直接价值。
- [Gandalf: Flash Shall Not Die! Increasing Flash Storage Lifetime for KV Cache Offloading](https://arxiv.org/abs/2610.30791)(10-22)— KV 落盘把 SSD 寿命从数年磨到数月;按 attention 类型区分准入(优先 full-attention),平均延长 SSD 寿命 7.3x 且几乎不掉命中率。与 SARIA 同属"KV 落盘的硬件磨损"新议题。
- [The Token-Energy Law of LLM Decode](https://arxiv.org/abs/2610.28576)(cs.PF)— 用"active bytes + 实际 decode 时间"的仿射模型预测每 token 能耗,Hopper/Blackwell 上误差 ≤3.73%。可作为我们给客户算 TCO/碳排和做能效调度的量化底座。
- [UlaCache: Unified Logical Addressing for Sparse LLM Serving](https://arxiv.org/abs/2610.29820)(10-21)— 为稀疏 LLM 服务做统一逻辑寻址的 KV 管理抽象,简化稀疏/分页下的地址映射。
- [MoEZip: Routing-Aware KV Cache Compression for Sparse MoE LLMs](https://arxiv.org/abs/2610.30206)(10-21, NeurIPS 2026)— 按 MoE 路由模式做 KV 压缩,MoE 服务显存优化方向。
- [Characterizing Predictability-Latency Trade-offs of KV-Cache SSD Offloading in LMCache](https://arxiv.org/abs/2610.21249)(10-21)— 对 LMCache 的 SSD 卸载做"可预测性 vs 时延"实证刻画,选型 LMCache 存储层时的参考数据。
- [Hard and Soft Real-Time DNN Inference Scheduling on Heterogeneous Multi-Accelerator Systems via RL](https://arxiv.org/abs/2610.29503)(10-21)— 用 RL 在异构多加速器上做硬/软实时推理调度,与我们多芯调度器选题同赛道。
- [Local Inference of LLMs on Long Contexts: A Data Systems Perspective](https://arxiv.org/abs/2610.28223)(10-21)— 从数据系统视角拆解长上下文本地推理的系统瓶颈,边缘/私有化长文场景参考。

## 趋势观察

- **KV cache 的战场从"算法压缩"全面转向"存储工程 + 跨设备搬运"**:本周 KV 相关论文密度仍是绝对第一,但主题明显从上周的"压缩/迁移/分层建模"进一步下沉到物理存储层——SSD 写放大与磨损寿命(SARIA、Gandalf)、SSD 卸载的时延可预测性(LMCache 实证 21249)、跨异构芯片的零拷贝搬运(HAWK)、跨地域发现(KVCompass)。信号很清楚:KV 已经是一个贯穿 HBM→DRAM→SSD→远端→跨地域的完整存储体系问题,"磨损寿命"这种传统存储指标首次成为 LLM 服务论文的一等主角。我们的推理存储栈要按真正的分级存储系统来设计,而非把 KV 当临时 buffer。
- **异构/多芯从"训练去锁定"扩散到"推理阶段级分派"**:上周是 Meta 在 AMD 上做训练协同设计,本周 HAWK 把异构下沉到推理——prefill 放 GPU、decode 放 NPU 的阶段级异构。对我们纳管 NV+昇腾是强正反馈:异构的正确姿势不是"每种卡跑一套完整实例",而是沿 PD 分离的接缝把不同阶段派到最合适的芯片,核心工程债是跨芯 tensor layout 的零拷贝适配。
- **GPU 共享从"静态配额"走向"可预测的配对干扰建模"**(PairSight):这是对 HAMi/vGPU 路线最有营养的一篇——它把"共享会不会互相打架"从玄学变成 4.3% 误差的可预测量,且证明干扰依赖"谁和谁同住"。预示 GPU 共享调度的下一代形态是"干扰感知放置",而非只看显存/算力余量的 bin-packing。
- **agentic 与超大规模训练继续各自给系统层出题**:agent 多轮长会话推高了 KV 持久化/寿命问题(SARIA、Gandalf、Cache Engineering for Agents);训练侧 MoE 的动态显存波动(BaGuaLu-2,12,288 GPU 实证)说明静态资源配额模型在 MoE 时代已不适用。两端都在逼迫资源管理从"静态预留"转向"在线细粒度弹性"。
- **"实证/实测台 + 挂到 LMCache/llm-d 等开源底座"仍是高质量系统论文标配**:SARIA 实现在 LMCache、KVCompass 三大洲实测台、BaGuaLu-2 万卡实测。延续上周结论——跟紧 LMCache / llm-d 这类上游底座,是低成本获取前沿调度/存储能力的入口,我们宜在其上做二次开发而非重造轮子。
