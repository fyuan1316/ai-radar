# AI 系统论文周报 2026-08-10

> 覆盖窗口:约 2026-08-03 ~ 08-10,arxiv cs.DC / cs.PF(cs.LG 以关键词补搜)。
> 数据源:arxiv。本次 `export.arxiv.org` API 持续返回 `Rate exceeded`(该出口 IP 被 Varnish 限流,多次退避重试无效),改走 `arxiv.org/list/cs.DC|cs.PF/recent` 列表页 + 逐篇 `abs` 页读取,并用 WebSearch 查漏 cs.LG。arxiv 周末无 listing,最新一批停在 08-07(08-08/09 无新 listing,08-10 今日尚未上架)。
> 精选论文均读过 abstract(含核心方法/实验数值)再落笔;上周已收录的 08-03 论文(DeltaServe 28848、Aries 29069、SLIM 29575、NUMA-Kernel 28824)本周不重复。

## 本周精选(5 篇)

- **[TensorCast: The Missing Tensor Management Layer in Large Language Model Infrastructure](https://arxiv.org/abs/2608.06007)** — 把权重加载、KV cache、checkpoint 同步这些"各写各的"张量搬运,抽象成一层统一的 Tensor-as-a-Service。
  - 核心思路:现代 LLM 基础设施里,张量不只是算子输入,更是"跨分布式组件共享的持久状态"。但今天每个任务(权重物化、权重热更新、KV 管理、checkpoint 同步)都把机制深度焊死在具体引擎/网络/存储后端上,形成孤岛、无法复用与组合。TensorCast 把"张量生命周期管理"提炼为一个缺失的抽象层:提供一等的张量抽象、可编程的生命周期原语、以及把"管理策略"与"执行机制"解耦的 runtime——开发者用 TensorCast API 写张量管理程序,底层透明地做分布式执行与数据搬运。已接入 vLLM 与 SGLang。
  - 关键数据点:在权重物化、权重同步、KV 管理、可编程请求路由等多种负载上与专用系统性能持平;一个用 TensorCast 写的可编程策略,在高并发多轮 Agent 负载下把中位 TTFT 最高改善 **93.2%**。
  - 对我们的启示:这直接指向我们推理平台的架构分层——与其让 KServe/vLLM/存储各自维护一套 KV/权重/checkpoint 搬运逻辑,不如在平台侧立一层"张量数据面"(策略与机制分离),把跨组件优化(如按会话把 KV 放到最近的节点、权重热切换、多轮 Agent 的路由亲和)做成可编程策略而非硬编码。这是把上周"KV 从引擎内部缓存升级为平台级可调度资产"进一步抽象成"所有张量状态都归一层管"——值得作为我们下一代推理网关的抽象基座认真评估,且接入面走引擎扩展点(vLLM/SGLang)才不绑死单引擎。

- **[When Does Disaggregation Pay? Simulating Prefill–Decode–Attention–FFN Specialization for Agentic LLM Inference (HeteroPanacea)](https://arxiv.org/abs/2608.03741)** — 不再问"怎么拆",而是用仿真回答"到底该不该拆、拆几路、每一路配什么硬件"。
  - 核心思路:Agentic 推理已成主流,prefill 与 decode 行为差异巨大、对算力与显存带宽的诉求完全不同,单一同构 GPU 越来越吃力,业界转向异构 + 分离式服务(如 GPU + Groq LPU 的 Vera-Rubin 形态)。但"每个组件的最优硬件长什么样"仍缺研究。HeteroPanacea 提供一个跨栈仿真框架,沿三个维度做系统级仿真:1) 分离式量化;2) 设备内/设备间并行调度的自动化;3) PDAF(prefill-decode-attention-FFN)NPU 架构异构性。
  - 关键数据点:确认 PD 分离相比当代 GPU 的传统同构服务吞吐最高 **+75%**;在假设定制 NPU 的前提下,**4 路 PDAF 分离**在不同模型上最稳定地提升吞吐;并用消融实验刻画"模型结构 ↔ 分离收益"的关系。
  - 对我们的启示:分离式服务正从"能不能拆"进入"值不值、拆几路、怎么配"的工程决策期。产品上我们不该把 PD 分离做成非黑即白的开关,而应内建一个"分离收益评估"能力:按模型结构 + SLO + 可用硬件(是否有 LPU/定制 NPU、互连拓扑)给出"该拆几路、每路配什么"的建议。尤其"attention 与 FFN 也可各自成一路"这条(4 路 PDAF)提示我们的调度抽象要能表达比 PD 两段更细的算子级放置,否则未来异构硬件红利拿不到。

- **[Routing LLM Inference to the Cleanest Grid in Real Time](https://arxiv.org/abs/2608.06188)** — 把"把请求发到此刻电网最干净的区域"做成生产路由器上可逆的叠加层,并给出实测碳减排上界。
  - 核心思路:LLM 推理是快速增长的用电负荷,其边际碳强度在不同电网区域、一天之内可差一个数量级以上,因此"请求放置"是个免重训、免换硬件的减碳杠杆。本文在多区域 GPU 实测床上做 live 验证,方法学三点比以往扎实:1) 基线是真实生产的压力感知路由器(不是均匀放置的假基线);2) 每请求能耗用 GPU 遥测(NVIDIA DCGM)按实测并发曲线归因(不是铭牌 TDP);3) 每个请求按历史 MOER(边际运行排放率)结算,而非只用驱动决策的预测值。
  - 关键数据点:碳感知放置作为生产路由器上"严格且可逆的叠加",全程零调度失败;回放一年逐时 MOER,相比 round-robin 把 GPU 可归因运营排放降 **50.9%**(95% CI 48.5–53.3%,因按历史 MOER 结算属上界);逐时选最低 MOER 相比"静态年均 MOER"策略再多贡献约 22.4 个百分点(约占 54% 放置减排的 40%)。实务提醒:跨区域比较要按 MOER 绝对值排序,别用区域内归一化的百分位信号。
  - 对我们的启示:多区域/混合云部署时,碳应升级为一等调度信号,而不是事后报表。可落地路径正是本文的"叠加层"范式——不改现有压力路由器,在其上加一个可逆的碳感知覆盖,失败即回退,风险可控;能耗归因必须走 DCGM 实测并发曲线而非铭牌 TDP,否则报给客户的 ESG 数字站不住。对做企业级合规/可持续报表的产品线,这是一个能直接立项的差异化能力。

- **[Preserving Admission Responsibility in Multi-Tenant Large Language Model Prefix Caches (PrefixShield)](https://arxiv.org/abs/2608.01657)** — 共享 prefix cache 里,谁生成新 KV 把别人挤掉,就该谁背回收压力——给多租户 KV 复用补上"责任归属"。
  - 核心思路:共享 prefix caching 把 GPU 显存变成跨租户的持久状态,一个租户物化新 KV 块可能逼另一个租户丢掉可复用状态,但请求级调度只算瞬时服务、替换策略只按对象价值排序、静态分区又浪费空闲容量——作者称之为"准入-责任鸿沟(admission-responsibility gap)"。PrefixShield 对新物化的整块 KV 计量、把"责任/欠债"跨请求累计、在欠债未清时抑制其复用晋升、并用预计欠债来挑选出"由谁供出逐出候选"。已在 vLLM 实现。
  - 关键数据点:在"一次性污染"配对实验里,受害租户命中率相比 LRU +**9.39** 个百分点、相比 S3-FIFO +8.64 个百分点,把受害方在 4096 块规模下从 4.92% 命中恢复到 **84.87%**;延迟回放场景在欠债未清期间领先 **35.16** 个百分点;同时不伤害正常 ShareGPT 行为、保持对空闲容量的 work-conserving 访问。
  - 对我们的启示:一旦我们把 prefix/KV cache 做成多租户共享(这是省显存的必然方向),就会引入一个新的隔离与公平性威胁面:租户 A 的长上下文可以合法地把租户 B 的热缓存冲垮。这既是 QoS 问题也是安全问题(可被恶意构造成"缓存污染攻击")。产品上我们的多租户推理缓存必须内建"物化责任计量 + 欠债感知逐出",而不是裸用 LRU/S3-FIFO;这条与我们做 GPU 配额/多租户隔离的主线同频,且实现代价不高(在 vLLM 缓存层加计量与选择逻辑)。

- **[Operating Multi-Node Full Fine-Tuning on NVIDIA B300: A Field Report on Telemetry-Based Triage, Negative Results, and Operational Hardening](https://arxiv.org/abs/2608.05944)** — 一份少见的 B300 实战报告:不提新算法,只给"新硬件上怎么排障、哪些优化其实没用、怎么把多小时静默失败变成秒级拒绝"。
  - 核心思路:在 16×B300(双节点、FSDP/ZeRO-3)上全参微调 32.76B 稠密模型(Qwen3-32B),交付四件"运维手艺":1) B300 标定的功耗排障表——用板级瓦数区分 compute/通信/数据饥饿/checkpoint 或死锁/idle(关键:NCCL 挂起时利用率仍显示 100%,只有功耗能识破);2) 一组"戳破优化玄学"的诚实负面结果;3) 4/8/16 GPU 强扩展与 GPU-hour 的标定绝对值(近线性);4) 一个真实故障案例——epoch 末因各 rank token 打包不均导致的 NCCL 死锁,配一个 2.7 秒的预跑不变量门禁 + 外部看门狗。
  - 关键数据点:NFS 逐步读与预分词本地缓存吞吐持平(约 **53k tok/s**),因语料能装进 page cache、任务是 compute-bound;此前所谓"吞吐崩塌"复盘为 NFS/CPU 争用而非存储介质瓶颈;2.7 秒不变量门禁把"多小时静默失败"变成即时拒绝。
  - 对我们的启示:这类"操作真实性"内容对我们做训练/微调平台的可观测与可靠性极有价值,可直接转成产品需求:(a) 健康判定不能只看 GPU 利用率(NCCL 挂起时它是 100% 的假信号),要把板级功耗纳入探活维度,做成功耗指纹式的故障分类;(b) 别默认"本地缓存一定比 NFS 快",compute-bound + page cache 命中时二者等价,盲目上高速存储是浪费;(c) 把"预跑不变量门禁 + 外部看门狗"做成平台一等能力,让长作业的静默死锁秒级暴露而不是烧几小时机时。这是把 SRE 经验产品化的好素材。

## 值得泛读(10 篇)

- [TokTier: Exact Stateful CPU+GPU Tokenization for Agentic LLM Serving](https://arxiv.org/abs/2607.29678) — 当 prompt-cache 命中率逼近 0.99,分词竟占到 TTFT 的 **10%→64%**(编码 agent 每次追加一小段却重分词整段百万级上下文)。TokTier 做有状态 CPU+GPU 分词服务,保证 token id 与全量参考分词逐位一致:续写只对追加处开小窗增量修复(0.5–1.1ms,最高 437x 于 HF),新会话走 GPU 上精确 BPE(1M 字符 0.87ms)。接 vLLM 后中位 TTFT 降 16–34%、P99 降 23%;50ms P99 下 4 核修复池+1 GPU 扛 1821 req/s,而 16 核无状态前端只到 40 req/s。启示:高缓存命中的 Agent 负载下,"分词前端"本身会成为新瓶颈,值得做成平台一等组件。
- [Topology-Aware Data Movement for Disaggregated GPU Inference](https://arxiv.org/abs/2607.28633) — PD 分离搬 KV 时,两 GPU 间带宽因物理关系差 **72x**(NVLink 900GB/s vs IB 50 vs 跨 DC TCP 12.5),但 DistServe/Splitwise/Mooncake 都用统一 RDMA。本文启动时探测互连层级、按传输选最优通路 + 逐层流水把 76–100% 传输延迟藏进计算 + MoE 的 NVLink 域感知放置 + CXL 3.0 做溢出层,估算相比统一 RDMA 降 3–18x 延迟。与上周 SmartGen 呼应:KV 传输要把拓扑当一等输入。
- [HorizonServe: Coordinating Request Scheduling with GPU Sharing for Omni-Model Serving](https://arxiv.org/abs/2608.01785) — 全模态(文/语音/图)统一后端里,不同输出模态共享多模态骨干再分叉,SLO 各异却挤在同一 GPU。HorizonServe 联合控制共享段的时间片轮转与下游的空间共享(限流共享段 SM 占用),SLO 达成率最高 4.9x(下游重时 7.0x),首响时延降 38.4–63.7%。
- [Efficiency and Cost Alignment in Batched LLM Serving via Resource-Fair Scheduling (ISJL)](https://arxiv.org/abs/2608.02244) — 同批里短请求被长请求的 max-driven KV 足迹拖累,产生"批内不公平"。ISJL 用可证明 3/4 竞争比的混合批策略约束批内 decode 进度差,并把 max-driven 批成本与按 token 计费的收入对齐——对做计费/QoS 的产品有理论骨架价值。
- [Request-Level Energy Attribution for Batched LLM Serving (JouleShare)](https://arxiv.org/abs/2608.00026) — GPU 功耗遥测是聚合值,但 chargeback/ESG 要请求级能耗。作者用离线 Shapley 建"每请求真实能耗"地面真值,再训轻量 JCalib 在线预测:按 token 分摊相比 Shapley 偏差 0.44–0.46,JCalib 降到 0.12–0.18。结论:批处理下"按 token 摊能耗"不可靠,想做能耗计费得校准。
- [TELLER: Non-intrusive Cross-Layer Root-Cause Analysis for LLM Inference](https://arxiv.org/abs/2608.01975) — 一次请求横跨引擎/后端/CUDA/GPU kernel/通信,排障难。TELLER 免改二进制收 NVTX/CUPTI trace + 服务日志,重建每请求调用链树、对齐日志与执行步,用 Trace Pair Encoding 压缩后做多模态根因定位:中等词表把每步 trace 长度降 80%+ 且诊断最优。可做推理服务的 RCA 基座。
- [AFD-Ledger: Deployment Provisioning for Attention–FFN Disaggregation](https://arxiv.org/abs/2608.04502) — 把 attention 与 FFN 拆成独立部署单元后的资源供给/配比问题,给 AFD 这类更细粒度分离的落地配额提供方法(与 HeteroPanacea 的 4 路 PDAF 同一趋势)。
- [Energy-Efficient LLM Serving via Disaggregated Attention–FFN and Flexible Frequency Scaling](https://arxiv.org/abs/2608.01891) — 借 Attn/FFN 分离后各段计算特征不同,对不同段施加灵活频率调节做节能,属本周"能耗一等公民"主线里"拆分×DVFS"的组合拳。
- [Multi-tenant Kubernetes Use Cases for AI, Secure Computing and Data Services, and More](https://arxiv.org/abs/2608.00742) — 从实践角度梳理 AI/安全计算/数据服务的多租户 K8s 用例,偏经验总结,适合对齐我们多租户产品的场景清单。
- [PLoRA: An NDP-Enhanced Pooled-Memory System for Cost-Efficient Multi-LoRA Serving](https://arxiv.org/abs/2608.05483) — 用近数据处理(NDP)+ 池化内存降低多 LoRA 服务成本,和上周 DeltaServe 的"多 LoRA 同池"路线在硬件侧互补。

## 趋势观察

- **分离式服务从"怎么拆"转入"值不值 / 拆几路 / 每路配什么"的决策期**。本周 HeteroPanacea(03741)直接把它做成三维仿真的决策问题,并把粒度从 PD 两段推到 4 路 PDAF(attention、FFN 各自成路);AFD-Ledger(04502)、Energy Attn-FFN(01891)、Topology-Aware(28633)从供给配比、节能、KV 传输拓扑三个侧面补齐。信号很清楚:我们的调度抽象必须能表达"比 PD 更细的算子级放置",且内建"分离收益评估"而非做成开关,否则拿不到异构硬件(LPU/定制 NPU)的红利。
- **能耗 / 碳本周首次成规模地升级为一等调度与计量信号**。碳感知路由(06188,实测降 50.9%)、请求级能耗归因 JouleShare(00026,证明按 token 摊能耗不可靠)、MFU 当功耗代理(03880)、拆分×DVFS 节能(01891)、消费级 GPU 功耗基准(00008)扎堆出现。相较上周(主线是算力再利用 + 准入保证 + KV 编排),这是本周最明显的新增主线。对我们做企业级合规/ESG 报表是明确的立项窗口:关键工程点是能耗归因走 DCGM 实测并发曲线、而非铭牌 TDP。
- **KV / prefix cache 研究从"复用"深入到"多租户下的责任、公平与污染防护"**。PrefixShield(01657)给共享 prefix cache 补"准入责任"(把缓存污染当 QoS+安全问题治理),PrefixPlace(01655)做可证明的前缀 KV 放置,TokTier(29678)则揭示高命中率下分词成新瓶颈。延续上周"KV 是平台级可调度资产",本周叠上一层多租户治理:谁污染谁、谁付费、谁背回收压力。这与我们 GPU 配额/多租户隔离主线高度同频。
- **"张量状态统一管理层"露头**。TensorCast(06007)提出 Tensor-as-a-Service,把权重/KV/checkpoint 的搬运从各引擎孤岛里抽出来做成策略-机制分离的一层。若这条抽象成立,它会重塑推理平台的分层——值得作为我们下一代推理网关抽象基座持续跟踪。
- **运维真实性 / 可观测成稳定支线**。B300 现场报告(05944,功耗指纹排障 + 戳破优化玄学 + 秒级死锁门禁)、TELLER(01975,免改二进制的跨层 RCA)、NIXT(01449,NCCL 集合通信可观测)三篇都在把 SRE 经验产品化。对我们训练/推理平台的健康探活(别只信 GPU 利用率)、根因定位、长作业静默失败拦截,是可直接转需求的素材。
- **相较上周**:上周重心是"稳态多租户里把每分 GPU 榨干且给得出承诺(算力再利用 + 排队论准入 + KV 编排)";本周在此之上叠了三件新事——(1) 能耗/碳从报表升级为调度与计费信号;(2) 分离式从 how 走到 whether/how-many-ways 且下沉到算子级;(3) KV 治理从"复用"扩到"多租户追责与污染防护"。整体看,研究正从"单集群把吞吐做高"进一步走向"多区域、多租户、可计量(算力+能耗+碳)、可追责"的运营级命题。
