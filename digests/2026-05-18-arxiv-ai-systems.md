# AI 系统论文周报 2026-05-18

窗口:2026-05-11 → 2026-05-18(7 天,UTC 提交时间)
来源:arxiv API (cs.DC / cs.LG / cs.PF / cs.AR + LLM serving / KV cache / GPU 调度 / 分布式训练 / MoE 等关键词)
本周窗口内匹配论文 112 篇,精读候选 ~30 篇。

## 本周精选(5 篇)

- **[KVServe: Service-Aware KV Cache Compression for Communication-Efficient Disaggregated LLM Serving](http://arxiv.org/abs/2605.13734v1)** — 把 KV 压缩从静态参数变成 service-aware 在线决策
  - 核心思路:PD 分离 / KV disaggregation 让 KV 成为跨网络与存储边界的显式 payload,既是吞吐瓶颈也是 SLO 杀手。现有 KV 压缩都是启动时设死的静态配置,workload mix / 带宽 / SLO 在线变化时静态选择反而拉低延迟。KVServe 做了三件事:(1) 把现有 KV 压缩方法统一成模块化策略空间并支持跨方法重组;(2) Bayesian Profiling Engine 离线搜索抽出 3D Pareto 候选集(搜索开销下降 50×);(3) Service-Aware Online Controller 用解析延迟模型 + 轻量 bandit 在线选择压缩档位,纠正离线-在线 mismatch。已集成进 vLLM。
  - 对我们的启示:llm-d / KServe llmisvc / hermes-router 现在的 KV 路由都还是"开关型"配置(开/关压缩、固定位宽),没有把 KV 压缩位宽当作可调度的 SLO 资源。KVServe 验证了"在线 bandit 选压缩档位"是 Pareto 优于静态配置的;如果我们做多租户 LLM 平台,把 KV 压缩档位接入 Inference Gateway / SLO 控制面是下一步差异化抓手
  - 关键数据点:PD 分离场景 JCT 加速 9.13×,KV-disaggregated 场景 TTFT 缩短 32.8×

- **[Surviving Partial Rank Failures in Wide Expert-Parallel MoE Inference (EEP)](http://arxiv.org/abs/2605.10670v1)** — 把 EP membership 从启动期常量变成 mutable runtime state
  - 核心思路:宽 EP 部署(DeepSeek V3/R1 这类多机 MoE)里一个 rank 挂掉整个 instance 就废了,因为 communicator、专家放置、CUDA graph 里都烧死了"启动时定下"的 rank 集合。EEP 把 membership 显式表达成可变 runtime state,做三件事:故障后不重建通信子层只修可达性、按带宽感知的层级补回失踪专家、修复的 rank 不强制健康 rank 重 capture CUDA graph。集成进 SGLang
  - 对我们的启示:OpenShift AI / KServe 在多机 EP 推理(DeepSeek、Qwen3-MoE)上完全没有 partial-failure recovery 概念,只能整 instance 重启。如果我们做企业级 MoE 推理服务,这是一个非常具体的可以做差异化的位置;EEP 的设计也告诉我们"membership as first-class state"应该是 Inference Service CRD 里的字段而不是 reload-everything 的隐式输入
  - 关键数据点:稳态性能比固定 membership 的 DeepEP baseline 仅低 4.4%;单 rank 故障下 11s 恢复 + 8s 重接入,52s 内吞吐回到故障前 95%;同样场景重启 baseline 要 348s 才可用

- **[ReCoVer: Resilient LLM Pre-Training System via Fault-Tolerant Collective and Versatile Workload](http://arxiv.org/abs/2605.11215v1)** — 把"故障不偏离 failure-free 轨迹"上升为系统不变式
  - 核心思路:千 GPU 级预训练里硬件故障是常态。ReCoVer 守住一条不变式:每次 iteration 的 microbatch 数量恒定,使每步梯度在统计上与 failure-free run 等价。系统拆成三层解耦协议:故障容忍 collective(隔离故障跨 replica 传播)、in-step 细粒度恢复(保留 iteration 内进度防止梯度污染)、versatile-workload policy(在幸存 rank 间动态重分配 microbatch 配额)。与 3D 并行和 HSDP 都是 drop-in
  - 对我们的启示:OpenShift AI / Kubeflow Trainer V2 / Distributed Workload Operator 当前的故障语义还是 checkpoint-restart,失败重启从上次 ckpt 重做整轮。ReCoVer 提供的"per-iteration gradient equivalence"是一个更强的 SLO,我们家做 SFT / RL 训练时如果能保证这个,客户对训练稳定性的合规要求会容易满足很多;这条思路应该直接做进我们的 Training Operator
  - 关键数据点:512 GPU 端到端预训练,运行过程中累计丢 256 GPU,训练轨迹仍能保持;对比 checkpoint-restart baseline 有效吞吐 2.23×,234 GPU-hour 多处理 74.9% tokens

- **[MinT: Managed Infrastructure for Training and Serving Millions of LLMs](http://arxiv.org/abs/2605.13779v1)** — 把"百万级 LoRA 适配器"当作 first-class 资源管理对象
  - 核心思路:多策略 RL 训练 + 服务场景下,每条策略物化成完整 checkpoint 既贵又慢。MinT 让 base model 常驻,只在 rollout / update / export / eval / serve / rollback 流水线里搬动 LoRA adapter 修订版(<1% base 大小)。系统沿三轴扩展:Scale Up(LoRA RL 延伸到 1T+ MoE,支持 MLA / DSA);Scale Down(adapter-only 交接,4B dense 18.3× / 30B MoE 2.85× 单步加速,并发多策略 GRPO 1.77× 端到端加速);Scale Out(可寻址目录 10^6 量级,千级活跃 adapter wave,packed MoE LoRA tensor 让 live engine 加载快 8.5-8.7×)
  - 对我们的启示:OpenShift AI 当前对 fine-tune 后的 adapter 没有专门的目录管理,model registry 也是 full-checkpoint 心智。我们家做 MaaS 时,如果客户希望按用户 / 按场景生成大量 LoRA 适配器,需要专门一层"adapter catalog + 冷热加载调度";MinT 提供了完整的 API 边界和扩展轴定义,可直接借鉴成我们 Model Registry / Inference Service 的下一代规约
  - 关键数据点:10^6 级 adapter 可寻址(实测扫描 100K),千级并发 active wave,8.5-8.7× live 加载提速,4B/30B 模型上 RL 单步加速 18.3×/2.85×

- **[GRIEF: Continuous Discovery of Vulnerabilities in LLM Serving Systems with Fuzzing](http://arxiv.org/abs/2605.11202v1)** — 第一个把 serving 层并发态当作安全边界的 greybox fuzzer
  - 核心思路:LLM 推理引擎把 KV cache / batching / prefix sharing / speculative decoding / 多 adapter / 多租户调度组合到一起,产生只有在真实并发负载下才暴露的共享状态行为;标准的 model / safety / API 测试看不到这些 bug。GRIEF 把"带时间戳的多请求 trace"当作 first-class 输入,用轻量 oracle 检测崩溃 / 挂起 / 性能病态 / 静默输出污染,用受控 replay + logprob 比较确认可复现的 serving-layer 故障
  - 对我们的启示:OpenShift AI 多租户推理服务的最大公关风险不是 prompt injection,而是 KV cache 跨请求泄露 / noisy neighbor / 静默输出污染——这些都是 vLLM / SGLang 引擎层 bug,我们做平台层无法兜底。GRIEF 找到的 15 个 vuln(其中 2 个 CVE)直击我们生产栈;**短期 action:把 vLLM / SGLang 当前打的版本号交叉对照 GRIEF 披露的 CVE,提前做兼容声明**;**长期:这种引擎层 fuzz 应该进我们 PV(Product Validation)流程,作为每个 ServingRuntime 镜像升级的卡点**
  - 关键数据点:vLLM 与 SGLang 上发现 15 个漏洞,10 个被引擎开发者确认,其中 2 个 CVE;漏洞类别覆盖 KV cache 隔离失败、跨请求性能干扰、崩溃 / 活性 bug

## 值得泛读(~11 篇)

- [BatchWeave: A Consistent Object-Store-Native Data Plane for Large Foundation Model Training](http://arxiv.org/abs/2605.09994v2) — versioned manifest + 条件对象写入做训练数据 plane,提出 Transactional Global Batch 抽象,64 GPU 多模态 SFT 比 Kafka 更快且 read 延迟更低
- [Maestro: Accelerating Compound LLM Training Workloads](http://arxiv.org/abs/2605.10501v1) — KD + 多模态训练的"section graph + wavefront 调度",生产已跑数百万 GPU-hour,关键 workload GPU 消耗 -40%
- [PrismLLM: Faithful LLM Training Emulation with a Few GPUs](http://arxiv.org/abs/2605.15617v1) — slice + hybrid emulation,用 <1% 物理 GPU 复现 8192 GPU 训练行为,迭代时间误差 0.58%、峰值显存误差 <0.01%(训练侧的 LLM-Emu)
- [Asteria: Runtime-Orchestrated Second-Order Optimization for Scalable LLM Training](http://arxiv.org/abs/2605.16184v1) — Shampoo/KL-Shampoo 类二阶优化器状态分布到 GPU/CPU/NVMe,DGX Spark 上单 GB10 GPU 跑 1B 二阶训练
- [MARLIN: Multi-Agent Game-Theoretic RL for Sustainable LLM Inference](http://arxiv.org/abs/2605.13496v1) — 联合优化 TTFT / 碳排 / 水耗 / 能源费用,相比 SOTA 推理管理框架 TTFT -18%、碳 -33%、水 -43%、能源 -11%
- [The Illusion of Power Capping in LLM Decode](http://arxiv.org/abs/2605.11999v1) — H200 上 decode 实际只画 137-300 W(700 W 卡),功率封顶根本不触发;SM clock locking 替代功率帽,decode 能耗回收 32%、吞吐几乎不损
- [DualKV: Shared-Prompt Flash Attention for Efficient RL Training](http://arxiv.org/abs/2605.15422v1) — GRPO/DAPO 里 N 条 rollout 共用 prompt,DualKV 在 FlashAttention kernel 层去重复算 prompt,Qwen3-8B GRPO 1.63-2.09× 加速,MFU 从 36% 到 76%
- [Fast MoE Inference via Predictive Prefetching and Expert Replication](http://arxiv.org/abs/2605.11537v1) — 预测过载专家并复制,Switch-base-128/256 上 GPU 利用率近 100%,推理速度 3×,质量保留 90-95%
- [AB-Sparse: Sparse Attention with Adaptive Block Size](http://arxiv.org/abs/2605.12110v1) — 不同 attention head 对块粒度敏感度差别大,自适应块大小 + 无损 block centroid quantization,无吞吐损失下 accuracy +5.43%
- [NCCLZ: Compression-Enabled GPU Collectives](http://arxiv.org/abs/2605.12396v1) — 把量化放接口、熵编码嵌入 NCCL 原语,科学计算 / 训练 gradient / 合成负载下相比 NCCL 加速 9.65×,比上一代压缩集合通信库快 3.34×
- [Designing Datacenter Power Delivery Hierarchies for the AI Era](http://arxiv.org/abs/2605.16255v1) — 微软 Azure 数据驱动,2027 单机柜 ~1 MW 趋势下,multi-resource stranding 会显著改变"实际可部署容量",规划目标从"装机 MW"变成"生命周期可部署容量"

## 趋势观察

- **MoE serving 系统化进入工程深水区**:本周 EEP(分 rank 容错)、Fast MoE(预测预取 + 专家复制)、KVServe(MoE 也覆盖)、AB-Sparse 同时出现,主题统一为"宽 EP 部署是新的 production baseline,围绕它的容错 / 调度 / 通信都要重做"。这与上周(05-04)的"agent-native serving"并不冲突:一个是 workload 层(agent),一个是部署层(MoE wide-EP),都是新一代 serving 的标配假设
- **Fault tolerance 从故障恢复模式升级为不变式**:ReCoVer(per-iteration gradient equivalence)与 EEP(membership as mutable runtime state)采用了同一种思想——不要在故障发生后救火,而是在系统里维护一个"故障下仍成立的不变式"。这是从"高可用"心智迈到"持续可服务"心智,直接影响 Training Operator / Inference Service CRD 该怎么暴露语义
- **Energy / 碳 / 水进入一线指标**:本周 MARLIN(联合 4 目标)、EnergyLens ×2、The Illusion of Power Capping、Designing Datacenter Power Delivery 五篇都把能源放到与延迟 / 吞吐同级。值得注意的是 The Illusion of Power Capping 直接证明"power cap"在 decode 阶段是个伪杠杆,这意味着我们家任何 GPU 能耗 dashboard 如果只读 power 数,看到的可能是错误信号——SM clock 才是真正能动的杠杆
- **RL post-training / 多 adapter 管理浮出系统层**:MinT(million-scale LoRA)、DualKV(GRPO/DAPO 训练 attention 去重)、ReCoVer(适用于 RL 训练)同周出现,标志着 RL 后训练栈已经从"算法实验"走到"基础设施级别问题"。对我们家 MaaS / 模型平台,这条路径上"训练-评测-上线-回滚"的端到端流水线需要变成一等公民
- **LLM serving 第一次作为安全边界被审计**:GRIEF 是本周(可能也是迄今为止)第一个把"serving 层并发态"当作 first-class 安全审计对象的 fuzzer。这对所有跑 vLLM / SGLang 多租户的厂商都是即时风险信号,产品上需要立刻把引擎层补丁纳入 PV 流程
