# AI 系统论文周报 2026-06-01

窗口:2026-05-25 → 2026-06-01(7 天,UTC v1 提交时间;承接上周 05-25 当日的边界条目)
来源:arxiv cs.DC(本月 446 篇,扫到 446 号尾部)+ cs.PF(本月 88 篇,扫到 88 号尾部)+ cs.LG 关键词定向(WebSearch)。每篇精选/泛读均到 abs 页核对 v1 提交日期,本周再次确认 arxiv ID 与日期非单调对应(如 2605.23911 是 4 月 7 日、2605.23918 是 4 月 15 日的旧文经 cs.PF 交叉挂上);凡跨周边界、超出窗口的都已剔除。
抓取说明:本周 arxiv API(export.arxiv.org/api)继续被本环境出口限流(首条请求即 429),全程走 arxiv 列表页 + abs 页;cs.DC/cs.PF 整月扫完,cs.LG 用关键词搜补,若有只挂 cs.LG 的训练/RL 系统论文仍可能漏网。今日(06-01)cs.DC、cs.PF 的 2026-06 列表均为空("No updates for this time period"),所以窗口本周事实上止于 05-28 这一批。

## 本周精选(5 篇)

- **[AFD: Attention-FFN Disaggregation for Efficient MoE LLM Serving](https://arxiv.org/abs/2605.28302)** — 把 P/D 二段拆分推进到算子级 attention/FFN 拆分,DeepSeek-V3.2 在严苛 SLO 下从"无法服务"变成 ~4k tok/s
  - 核心思路:大 MoE 模型上,大家熟悉的 prefill-decode(P/D)disaggregation 是相位级拆分;AFD 再往下推一级到算子级——把 attention 和 FFN 拆到不同 GPU 组、用 microbatch overlap 把跨组通信藏到计算后面,等于在 MoE 服务里多开了一条"按算子分组、按相位分桶"的两维设计轴。作者在 128 块 B200 上、TensorRT-LLM 作 backend 做了系统的三维设计空间探索(token 级并行 × 相位级 P/D × 算子级 AFD),核心结论是"没有单一最优策略":在宽 SLO 下 aggregated + chunked prefill 还能赢,但一进入严苛 SLO(chat TTFT 50ms/coding 100ms/agentic 150ms,统一 TPOT 15ms)非 AFD 配置直接 infeasible,只有 AFD 还能拿到 ~4k tok/s。
  - 对我们的启示:这是把上周 Spectrum-X(网络)+ Understanding Inference Scaling(并行甜区)又往下推一层——服务层"拆什么、怎么拆"已经从 P/D 二选一变成可由调度器在 token/相位/算子三轴联合搜索。两条产品动作:(1) KServe/llm-d 的 ServingRuntime 抽象要把"算子级拆分"列为一等部署形态,而不是当成 TRT-LLM 内部细节;(2) 我们的"推荐配置"层应该按 SLO 紧度做分档——宽 SLO 下默认 aggregated 省成本,严苛 SLO 自动切 AFD/P/D 组合,而不是让用户自己挑。MoE 服务路线上,这是上周 KVServe + OSCAR 之后又一块直接能落产品的拼图。
  - 关键数据点:128 块 B200、TensorRT-LLM backend;严苛 SLO 下 DeepSeek-V3.2 ~4k tok/s,且非 AFD 配置不可行;TTFT 目标 50/100/150ms、TPOT ≤15ms 全段达成

- **[ReMoE: Boosting Expert Reuse through Router Fine-Tuning in Memory-Constrained MoE LLM Inference](https://arxiv.org/abs/2605.27081)** — 只动 router 门控,在显存受限场景把 MoE 服务效率翻倍,ICML 2026 接收
  - 核心思路:MoE 在显存受限的部署(消费级 GPU、Jetson、CPU offload)里最大的浪费是 router 选 expert 的时间局部性差——专家集合在相邻 token 间频繁切换,触发反复 CPU↔GPU 或 NVMe↔GPU 的搬运。ReMoE 不动 expert 权重,只对 router 的 gate 参数做一次轻量微调:目标函数加一项时间局部性正则,再用 KL 散度锚回到原 router 的分布,保住语义不漂移。作者引入了一个干净的"Expert Overlap Ratio (EOR)"指标度量"相邻 step 专家集合的复用率"。
  - 对我们的启示:这条路线把"MoE 显存友好"的责任从基础设施(offload 引擎、cache 策略)反推到模型一侧——只需对 router 做一次离线轻量微调,无需改 vLLM/KServe 任何代码就能换来显著收益。两条产品动作:(1) 在 MaaS 模型上架流程里增加"router locality 微调"作为可选预处理步骤,对客户上传的 MoE 模型(尤其是 DeepSeek 系、Qwen-MoE)默认推荐做一次;(2) 把 EOR 加进我们 KServe MoE ServingRuntime 的指标面板,让 SRE 能直观看到"换了模型后专家命中率"——这是个比"TPOT/吞吐"更早能预警的领先指标。配合本周 AFD,MoE 服务可以从"基础设施侧硬抗"转向"模型 + 系统协同优化"。
  - 关键数据点:EOR 提升 26%;vLLM GPU↔CPU offload 下吞吐 +8.4%;Jetson Orin NX(NVMe 后端)上 TPOT 降 43.6%–49.8%、decode 1.77–1.99× 加速;DeepSeek-V2-Lite、Qwen1.5-MoE-A2.7B 验证;ICML 2026

- **[Heterogeneous Parallelism for Multimodal Large Language Model Training](https://arxiv.org/abs/2605.27678)** — 多模态训练不再共用同一套并行配置,vision encoder 与 LLM 各跑各的,开源 Megatron-LM 扩展
  - 核心思路:多模态模型(vision encoder + projector + LLM,如 LLaVA 系)里 encoder 和 LLM 的尺寸、计算密度、注意力模式都不一样,但今天主流训练框架还是给整张计算图统一指定一套(TP/CP/PP/DP/EP)。本文让每个 module 独立挑自己的并行 layout 和物理 rank 集合,引入"boundary communicator"专门管模块间的前向激活/反向梯度通信,既保留 colocated(共卡)布局又支持 non-colocated(异卡)布局,且与基线收敛对齐。最大亮点是直接以 Megatron-LM 开源扩展形式释出,而不是私货。
  - 对我们的启示:多模态训练已经是企业级 AI 平台的必备能力之一,而我们今天 Training Operator/Kubeflow 那一层对"异构并行"的支持基本仍是"整张图一套并行配置"。短期产品动作:(1) 把这个 Megatron-LM 扩展纳入我们 Training Stack 的可选 backend,并在 Distributed Training Operator 的 CRD 里允许按子模块声明并行配置——这是个相对小但客户体感强的差异化点;(2) 联系上周"Understanding Inference Scaling"——"配置即性能"也已经被推到训练侧,默认配置选错的代价比"再快 10% 的 kernel"大得多。多模态/长上下文场景客户尤其需要"开箱即最优异构并行"。
  - 关键数据点:colocated 模式 TFLOPS/GPU 最高 +49.3%(1B 编码器 + 7B LLM、64K 序列、75% vision token、32 GPU);non-colocated 聚合吞吐最高 +13.0%、TFLOPS/GPU +9.6%;生产实验覆盖 1B–12B 编码器 × 至 120B LLM;以 Megatron-LM 扩展开源

- **[When Does Deep RL Beat Calibrated Baselines? A Benchmark Study on Adaptive Resource Control (RLScale-Bench)](https://arxiv.org/abs/2605.26418)** — 标定过的规则 HPA 在所有六种 workload 上把六种主流 DRL 全成本压制
  - 核心思路:作者按生产实践方式标定 Kubernetes HPA(70% CPU 目标),用同一套统一架构跑 PPO/A2C/DQN/SAC/TD3/DDPG 六种 DRL,在六类合成 workload(constant/periodic/variable/bursty/ramp/flash)上做 240 次受控实验,目标是把 pod 副本数选对、把基础设施成本压最低(0.01 USD/replica/15s 决策步)。核心结论非常反潮流:**rule-based HPA 在六种 workload 上全部成本最低**;DRL 在某些 bursty/flash 模式下有局部胜场,但综合不胜出;离散动作 DRL(PPO/A2C/DQN)对连续动作 DRL(SAC/TD3/DDPG)在约束违反率上要好 1–2 个数量级。作者结论是问题不在算法选择,而在标定精度 / 奖励设计 / 评测方法。
  - 对我们的启示:过去两年云原生+AI 圈一直在卖"DRL 自适应弹性",这篇把这股潮直接泼了一瓢冷水,而且做法非常可信(标定的 HPA 不是稻草人、6 算法×6 workload×5 seed)。两条产品动作:(1) 我们 KEDA/HPA + Inference Gateway 的弹性策略**先把基线标定做到位再考虑 DRL**——很可能再花的工程量更适合花在"动态目标利用率""请求级 SLO 反馈"上,而不是上 DRL;(2) 给客户做技术选型咨询时,"建议先用标定的 HPA + 一两条手写规则"应成为默认推荐,不再无脑推荐 DRL autoscaler。这也跟上周 PALS(把功率帽当一等调度旋钮)的方向一致——把"已有控制变量调好"比"换更复杂的控制器"更值钱。
  - 关键数据点:6 算法 × 6 workload × 5 seed = 240 次实验;workload 范围 50–300 req/min;**标定 HPA 在 6/6 workload 上成本最低**;离散动作 DRL 约束违反率比连续动作低 1–2 数量级;workload 间算法名次错位最多 4 位

- **[GridPilot: Real-Time Grid-Responsive Control for AI Supercomputers](https://arxiv.org/abs/2605.26384)** — 把 AI 集群作为电网"快速频率响应"资源,GPU 级 PID 在 97.2 ms 内完成功率帽调整
  - 核心思路:电力公司过去依赖电池/水电做秒级频率响应(Nordic FFR 标准是 ≤700 ms),GridPilot 论证 AI 集群本身可以是更快的响应单元。三层预测控制 + 安全旁路:Tier-1 是每 GPU 上 200 Hz PID 控制器,响应链路 UDP 触发 ~1 ms → 安全岛查表 ~50 μs → NVML 功率帽更新 ~5 ms → PID 收敛 ~90 ms,合计 97.2 ms,比 Nordic FFR 标准快 ~7×。另一个差异化点是把 PUE 修正嵌进控制器:电网真正想看的不是 IT 负载侧的功率而是设施总表侧,论文加了一个 4 段 PUE 模型(冷却、泵、风侧、设施杂项),让低负载场景下"承诺频率响应量"在设施表上不被冷却的反向变化吃掉。实验用了三块 V100 + 合成 TSO 触发(注意:这是合成信号,不是真实 TSO 预鉴定),负载用 FP32 GEMM / ResNet-50 inference / 周期性 idle 三类合成 benchmark。
  - 对我们的启示:这是上周"能耗治理体系化"主线的下一步——能耗治理不再止步于 datacenter 内部 FinOps,而是直接把 AI 集群挂上电网灵活性市场,这对欧洲市场尤其有商业价值(可以拿到 frequency reserve 报酬)。两条产品动作:(1) 我们的 Inference Gateway / Distributed Workload 调度面应该在"硬性 SLO"和"能耗"之外预留一条**外部信号通道**(TSO 频率响应、grid CO2 强度),并把"是否允许调度面在毫秒级动 GPU 功率帽"作为租户级策略;(2) GridPilot 把 PUE 直接做进控制器闭环这一手值得我们抄——我们对"基础设施侧"(冷却、PDU)和"IT 侧"(GPU 功率)的可观测打通不够,做 FinOps/能耗报告时这个 gap 会越拉越大。需要注意论文实验仅 3 GPU + 合成触发,要在我们环境上拿到客户级背书还需要真触发 + 大规模验证。
  - 关键数据点:end-to-end 97.2 ms(vs Nordic FFR 700 ms ~7×);PUE 感知控制器把冷却开销降 2.5–5.8 百分点;Tier-1 PID 200 Hz、每 GPU 一个;实验仅 3×V100、合成 TSO 触发;开源

## 值得泛读(8 篇)

- [The Energy Blind Spot: NVIDIA's Flagship Edge AI Hardware Cannot Support Process-Level Energy Attribution](https://arxiv.org/abs/2605.27599)(05-26)— 在 GB10 SoC(ASUS Ascent GX10)上系统检索后发现:没 CPU energy counter、没 INA 功率轨监测、没 IPMI/BMC、没 SCMI powercap;唯一可读的是 NVML 上 GPU 瞬时功率。最尴尬的是 MediaTek 固件内部已通过未公开 ACPI 接口算了每轨能耗,NVIDIA 明确表示无意暴露。结论是当前旗舰边缘 AI 硬件根本无法做 process-level 能耗归因——对我们做 edge AI 平台的能耗 FinOps 是个硬性物理边界,只能走"外部直流电表 - GPU 功率"的折中方案
- [Throughput-Optimized Networks at Scale (TONS)](https://arxiv.org/abs/2605.27963)(05-27)— 把 AI datacenter 网络拓扑设计公式化为线性规划自动综合,在等同硬件下对 Google TPU v4/5p 网络拿到 uniform random 2.1× / all-to-all 1.6× 几何平均加速。是"AI 工厂网络从手设计走向自动综合"的方向标
- [Extreme-Scale Interconnection Networks (MRLS)](https://arxiv.org/abs/2605.26960)(05-26)— Multipass Random Leaf-Spine,在 100k 端点上 All2All 对 Fat-Tree 50%、对 Dragonfly 100% 提速。与 TONS 同周出现,两篇合起来标志着"≥10 万端点级"的 AI 网络拓扑研究在本周明显升温;对我们做拓扑感知调度的假设要从 fat-tree 进一步松开
- [FedRAG: An Efficient and Privacy-Preserving Architecture for Cross-Institutional Collaborative RAG](https://arxiv.org/abs/2605.25716)(05-25)— 跨机构 RAG 的"Scrambled Distributed Attention"协议:把注意力计算和数据物理位置解耦,模型效用下降 <0.1%,相比现有安全方案延迟降低最高 62×。对我们做"金融/医疗多机构知识库共享 RAG"这类合规场景的产品形态有直接借鉴
- [Rotary GPU: Exploring Local Execution Paths for Large MoE Models Under Limited GPU Memory](https://arxiv.org/abs/2605.29135)(05-27)— 探索性工作:Qwen 3.6-35B 跑在单张 RTX 4060(8 GB VRAM)的笔记本上,2048 输出 token 用约 6.3 GB 显存、21 tok/s。和本周 ReMoE 互为补集——前者是模型侧 router 优化,本文是"系统侧极限挤压";对消费级/边缘部署是一个具体可复现的参考线
- [IORM: Hierarchical I/O Governance for Thousands of Consolidated Databases on Oracle Exadata](https://arxiv.org/abs/2605.29006)(05-27,VLDB 2026)— 不是 AI 主题但很有参照价值:成千租户共享存储下,通过 I/O 标签 + 层级化资源画像 + 统一存储治理"几乎消除尾延迟离群点",并按配置比例严格分配。我们做多租户 KServe ServingRuntime 时,"按租户的层级化 SLO 治理 + 真正消除尾延迟"这套范式可以原样借鉴到 GPU/HBM/网络资源治理
- [From Roofline to Ruggedness: Decomposing and Smoothing the GEMM Performance Landscape](https://arxiv.org/abs/2605.29752)(05-28)— 实证 BF16 GEMM 在相邻 N 步长 128 之间能差 30% 吞吐,通过动态 tile + DP 优化把 roughness 降 70%、平均吞吐 +30%(Intel Battlemage)。"配置即性能"在 kernel 层的又一证据,对我们做"自适应 kernel 选择"是个具体的优化曲线
- [High-Quality Multi-Constraint Hypergraph Partitioning via Greedy Rebalancing](https://arxiv.org/abs/2605.28333)(05-27,ESA 2026)— Mt-KaHyPar 集成,几何平均 connectivity 比次优(Metis)再降 11.5%,且在双约束有理论平衡保证。MoE expert placement / Pipeline 切分都用得到这套底层分区算法

## 趋势观察

- **MoE 服务在一周内连续推进三层:算子拆分(AFD)+ 路由器复用(ReMoE)+ 极限边缘(Rotary GPU)**。上周还是"在线选压缩档"和"2-bit KV 可落地"的位宽与缓存维度,本周三篇组合起来等于把 MoE 服务从"单机省内存"推到"算子级跨机解耦"——AFD 把 attention 和 FFN 拆到不同 GPU 组、ReMoE 让 expert 集合在相邻 step 复用、Rotary GPU 把整条 MoE 塞进 8GB 消费卡。对我们家产品的信号非常明确:MoE 服务路线必须做成"模型预处理(router 局部性)+ 系统级算子拆分(AFD)+ 显存档位(2-bit KV/expert offload)"三段联合的产品形态,而不是把它当 vLLM 的一个 backend 旋钮。
- **AI 集群网络拓扑研究在本周明显升温,且转向"自动综合"**。TONS 把拓扑设计转成线性优化、MRLS 给出 100k 端点的具体替代方案,两篇同周出现并不像巧合。结合上周 NVIDIA 公开 Spectrum-X 多平面架构,过去两个月里 AI 网络的研究主轴正从"调参 fat-tree / dragonfly"转到"按 workload pattern 综合拓扑"。我们做拓扑感知调度的隐含假设(底层是 fat-tree)需要重新评估,Distributed Workload Operator 应预留"多平面 / 综合拓扑"扩展点。
- **能耗治理的下一站是"接电网信号"**。上周(PALS、CompPow、ModeSwitch、A-LEMS)把"能耗"从只读指标推到调度面、组件级、目标级;本周 GridPilot 直接把 AI 集群挂到电网频率响应市场,延迟 97.2 ms 比传统电池/水电响应快一个数量级;反向地 Energy Blind Spot 提醒我们"很多硬件根本没有可暴露的能耗 telemetry"——这是治理的物理上限。对我们做企业级 MaaS:能耗治理不再止步于 datacenter 内 FinOps,要么往上(电网灵活性产品)、要么往下(逼硬件厂商暴露 telemetry),纯应用层已经没有进一步空间。
- **"DRL 自适应资源调度"被一篇严肃的 benchmark 直接证伪在弹性场景**。RLScale-Bench 的标定 HPA 在所有 6 类 workload 上把 6 种 DRL 算法全部压制,且离散动作 DRL 对连续动作 DRL 在约束违反率上还高出 1–2 个数量级。这跟上周"配置即性能"的主线一脉相承:平台层的真实价值是"把已有调度旋钮调好"和"给对默认配置",而不是叠更复杂的控制器。我们对客户的技术选型推荐应据此明确:autoscaling 默认 HPA + 一两条手写规则,DRL 仅在标定耗尽后再上。
- **训练侧出现"按模块异构并行"信号,但 RL 后训练 / 大规模训练容错本周相对沉寂**。本周训练侧最强信号是 Heterogeneous Parallelism 多模态训练(开源 Megatron-LM 扩展),意味着多模态训练正式要求"按 module 独立选并行配置"成为框架一等能力。但上周(ReCoVer/EEP/MinT/DualKV)那种"训练容错升级"和"RL 后训练系统化"的强密度本周未见同量级新作——这条线高度依赖只挂 cs.LG 的论文,本周 arxiv API 仍被限流、cs.LG 仅做关键词补充,有漏网可能,不据此下"该方向降温"的结论;下周 API 恢复后用 `(cat:cs.LG) AND (容错/RL rollout)` 复查回补。
