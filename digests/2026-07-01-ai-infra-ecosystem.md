# AI 推理 & MLOps 生态周报 2026-07-01

窗口:2026-06-24 -> 2026-07-01(7 天)

## 摘要(5 条以内)
- [vLLM v0.24.0](https://github.com/vllm-project/vllm/releases/tag/v0.24.0)(571 commits/256 贡献者)大版本:Model Runner V2 默认支持量化模型、DeepEP v2 专家并行、统一 Streaming Parser Engine、多层 KV offload 带 metrics,并停止内部设置 `CUDA_VISIBLE_DEVICES` 改用 `device_ids`(ROCm 进入弃用窗口)。
- [TensorRT-LLM v1.3.0rc20](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc20) 明确宣布**这是最后一个支持 TensorRT backend 的 RC,下个版本移除**;并把 `chat_template` 改为 opt-in(breaking),DeepSeek-V4 预备、MXFP8 落地。
- [Ray 2.56.0](https://github.com/ray-project/ray/releases/tag/ray-2.56.0) 把 Ray Serve LLM 请求处理与 token streaming 解耦,新增会话粘滞 `ConsistentHashRouter` 和 `CapacityQueueRouter`;Core 侧新增 GPU-domain 亲和 placement group 与 K8s 原地 Pod 扩缩(autoscaler v2)。
- KServe 上游把 CPU KV cache tiering 做成一等 spec 字段 [`kvCacheOffloading`](https://github.com/kserve/kserve/pull/5599),并新增 [延迟预测 sidecar 自动注入](https://github.com/kserve/kserve/pull/5678)(检测 `predicted-latency-producer` 插件)。
- 模型生命周期集体转向 Agent/MCP:[MLflow 上 MCP registry SDK](https://github.com/mlflow/mlflow/pull/23896) 与 [MCP server 列表页](https://github.com/mlflow/mlflow/pull/24217)、[Model Registry 加 Agent Catalog 脚手架](https://github.com/kubeflow/model-registry/pull/2887) 与 MCP catalog 设置页;llama-stack 更名为 **OGX**。

## 推理引擎动态

### vLLM

- [vLLM v0.24.0](https://github.com/vllm-project/vllm/releases/tag/v0.24.0) — Model Runner V2(MRv2)默认支持量化模型(#44446)、默认启用 GraniteMoE,并迁移 Qwen/DeepSeek-V2 MoE。
  - 启示:MRv2 正在成为默认 runtime 且原生吃量化权重。我们做引擎版本管理时要把 "MRv1/MRv2" 当作一个能力维度追踪,量化模型的默认执行路径变了,回归基线要重跑。
- [vLLM v0.24.0](https://github.com/vllm-project/vllm/releases/tag/v0.24.0) — 不再内部设置 `CUDA_VISIBLE_DEVICES`,改用新的 `device_ids` 参数(#45026),ROCm 上开始弃用窗口(#46636)。
  - 启示:这是影响调度/设备隔离的行为变更。我们平台若依赖注入 `CUDA_VISIBLE_DEVICES` 做设备可见性,需要评估切到 `device_ids` 的兼容路径,尤其是与 device-plugin / HAMi 软切分的交互。
- [vLLM v0.24.0](https://github.com/vllm-project/vllm/releases/tag/v0.24.0) — 统一 Streaming Parser Engine(#45413)覆盖 Qwen3/MiniMax-M2/GLM/Nemotron,tool-call 支持 strict mode(Chat Completions + Responses API)。
  - 启示:工具调用/推理解析正在从 "每模型一套 parser" 收敛为引擎级统一实现。做 Agent/function-calling 网关时应对齐这套 parser 契约与 strict mode,而不是自己维护模型专属解析。
- [vLLM v0.24.0](https://github.com/vllm-project/vllm/releases/tag/v0.24.0) — DeepEP v2 专家并行集成(#41183);KV offload 多层异步批量查找 + labeled/CPU-usage metrics(#45957、#45737)、self-describing KV events(#43468)。
  - 启示:WideEP + 分层 KV offload 的可观测性(labeled metrics、KV events)在成熟。我们的推理面板应能按 tier、按 EP region 拆解 KV 命中/传输,才能支撑成本与 SLO 归因。

### SGLang

- 本周无新 release([v0.5.14](https://github.com/sgl-project/sglang/releases/tag/v0.5.14) 已在上期覆盖);合入以修复/后端补齐为主,如 Offloader 内 [CUDA graph capture 期间 inline H2D 避免 stream 隔离](https://github.com/sgl-project/sglang/pull/29166)、[GLM-5.2 的 AMD MI300X/325X/355X cookbook](https://github.com/sgl-project/sglang/pull/28471)、speculative draft worker 的 weight checker 扩展。
  - 启示:SGLang 本周属稳定期,无需专门跟进;继续以 v0.5.14 的 MoE/prefix-cache/多后端能力作为对标基线即可。

### TensorRT-LLM / TGI / Ollama

- [TensorRT-LLM v1.3.0rc20](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc20) — **最后一个支持 TensorRT backend 的 RC,下版本移除 TensorRT backend**;`chat_template` 改为 opt-in(BREAKING);新增 DeepSeek-V4 预备、MXFP8 权重格式 + CUTLASS W8A8、Hopper 上 Marlin NVFP4。
  - 启示:NVIDIA 官方推理栈正式弃用 "编译式 TensorRT engine" 路径,全面转向 PyTorch-native(TRT-LLM Gen)。凡是基于 TRT engine 构建/缓存的部署管线要规划迁移;`chat_template` opt-in 会静默改变对话渲染,升级前需回归。
- [Ollama v0.31.1](https://github.com/ollama/ollama/releases/tag/v0.31.1) 等本周多个 release,工程重点仍偏桌面/边缘体验,对企业级平台无关键信号,本期不展开。
- HuggingFace TGI 本周无重大更新。

## 模型服务 & 编排

### KServe 上游

- [KServe PR #5599](https://github.com/kserve/kserve/pull/5599) — 新增结构化字段 `spec.kvCacheOffloading`(含 `cpu` 预留量 + `evictionPolicy`),支持 P/D 分离下 `spec.prefill.kvCacheOffloading`,自动渲染 vLLM `--kv-transfer-config`;旧 `kserve-config-llm-cpu-offload` preset 被删除。
  - 启示:CPU KV tiering 从 "选一个 preset" 升级为一等 API 字段。我们的模型服务规格应把 KV offload 的容量与淘汰策略显式建模,并注意它和 vLLM 现有 `VLLM_ADDITIONAL_ARGS` 的去重逻辑。
- [KServe PR #5678](https://github.com/kserve/kserve/pull/5678) — 检测 EPP 配置里的 `predicted-latency-producer` 插件,自动注入 training-server + prediction-server sidecar(well-known LLMInferenceServiceConfig 模式),无 CRD 改动、无硬编码默认。
  - 启示:KServe 在把 "延迟预测器" 做成可插拔 sidecar,用于调度/路由决策。这是 SLO-aware 路由的上游能力,值得对照我们自己的推理路由打分器评估是否复用同一套 latency predictor。

### Ray

- [Ray 2.56.0](https://github.com/ray-project/ray/releases/tag/ray-2.56.0) — Ray Serve LLM 把请求处理与 token streaming 响应路径解耦(#62667 等),显著提升 LLM serving 性能;新增会话粘滞路由 `ConsistentHashRouter`(一致性哈希)与供给受限场景的 `CapacityQueueRouter`。
  - 启示:会话粘滞(consistent-hash)对 prefix-cache 命中率至关重要;KServe/llm-d、Ray Serve 的路由策略都在往 "会话亲和 + 容量感知" 收敛。我们的推理网关应把 session-sticky 作为一等路由策略,而非仅轮询/最少连接。
- [Ray 2.56.0](https://github.com/ray-project/ray/releases/tag/ray-2.56.0) — Core 新增 GPU-domain 亲和 placement group(按 `ray.io/gpu-domain` label 打包 bundle),并加入 Autoscaler v2 的 K8s 原地 Pod 扩缩(先 resize 现有 worker 的 CPU/内存,再横向扩)。
  - 启示:GPU 拓扑域亲和调度 + 原地扩缩,正是大模型作业降低跨域通信、减少冷启动的关键。我们做 GPU 调度时应支持拓扑域 label 亲和,并关注 K8s in-place resize(1.33+ VPA)在训练/推理弹性上的落地。

## 训练 & 微调

- [Kubeflow Training Operator](https://github.com/kubeflow/training-operator/commits) — 本周补齐 TorchTune 微调 runtime(如 [torchtune llama3.2-1b runtime helm 单测](https://github.com/kubeflow/training-operator/pull/3630)、TorchTune plugin helpers 测试),并加了 JAX 分布式 TPU smoke test notebook、修 MPI SSH Secret 的 defaultMode。
  - 启示:Training Operator v2 正把 TorchTune 作为内置微调 runtime,微调正在被纳入统一 TrainJob 控制面。我们维护训练/微调能力时应对齐 TrainingRuntime 抽象,而非为微调单独造轮子。
- [LLaMA-Factory](https://github.com/hiyouga/LLaMA-Factory/commits) — v1 架构新增 [DPO trainer(#10544)](https://github.com/hiyouga/LLaMA-Factory/pull/10544)、修 device mesh / reward model 的 LoRA / sequence parallel;新增 Qwen-AgentWorld-35B-A3B、Hy-MT2 等模型支持。
  - 启示:LLaMA-Factory v1 正把 DPO 等偏好对齐纳入主线并补齐 SP/device-mesh。国内微调场景若走 LLaMA-Factory,可关注其 v1 的分布式正确性修复节奏。

## 模型生命周期(MLflow / Registry / Feast)

- MLflow 本周主线明显押注 MCP / Agent:[MCP registry SDK(#23896)](https://github.com/mlflow/mlflow/pull/23896)、[带卡片/表格视图的 MCP server 列表页(#24217)](https://github.com/mlflow/mlflow/pull/24217)、[MLflow Assistant 的 token 用量统计(#24099)](https://github.com/mlflow/mlflow/pull/24099)、[DSPy judge optimizer 路由到 Mosaic AI Gateway(#24177)](https://github.com/mlflow/mlflow/pull/24177);工程侧还有[本地 artifact 原子 rename 上传优化(#23794)](https://github.com/mlflow/mlflow/pull/23794)。
  - 启示:实验追踪工具正在把自己变成 "Agent/MCP 注册与治理中心"。我们的模型生命周期若要对标,需要提前规划 MCP server 的登记、发现、权限与用量计量,而不仅是 model registry。
- [Kubeflow Model Registry](https://github.com/kubeflow/model-registry/commits) — 新增 [Agent Catalog 脚手架(#2887)](https://github.com/kubeflow/model-registry/pull/2887)、[MCP catalog 设置页与源管理子页(#2888)](https://github.com/kubeflow/model-registry/pull/2888)、security artifacts endpoint;安全上修了 [HuggingFace catalog loader 的 SSRF / env-var oracle(#2857)](https://github.com/kubeflow/model-registry/pull/2857)。
  - 启示:上游 Model Registry(ODH fork 的源头)正从 "模型目录" 扩展为 "Agent + MCP 目录 + 安全工件"。这直接关系我们对标 OAI 的模型/Agent 治理面;同时 catalog loader 拉外部源的 SSRF 风险要引以为戒。
- [Feast](https://github.com/feast-dev/feast/commits) — [接入 OpenLineage consumer(#6549)](https://github.com/feast-dev/feast/pull/6549) 做跨生产者血缘、[新增 Compute & Jobs API + UI(#6561)](https://github.com/feast-dev/feast/pull/6561)、[RegistryServer.Proto RPC 带 RBAC 过滤响应(#6552)](https://github.com/feast-dev/feast/pull/6552)、[BigQuery 无需 entity_df 取历史特征(#6569)](https://github.com/feast-dev/feast/pull/6569)。
  - 启示:Feature Store 在补 血缘(OpenLineage)+ RBAC + 计算作业可见性,往企业级数据治理靠拢。做特征平台的企业能力时,血缘与 RBAC 过滤是必答题。

## LLM 评估 & 安全

- [NVIDIA/garak](https://github.com/NVIDIA/garak/pulls) — 本周集中扩展 content-abuse-safety(cas)意图体系:[intent->detector 映射覆盖扩展(#1861)](https://github.com/NVIDIA/garak/pull/1861)、[technique_intent_matrix 补名称与描述(#1890)](https://github.com/NVIDIA/garak/pull/1890)、IntentProbe 跨意图剪枝均衡化、donotanswer 意图集。
  - 启示:garak 在把红队从 "一堆 probe" 升级为 "意图(intent)→ 技术 → detector" 的结构化矩阵。我们做 LLM 安全评估时应采用类似的 intent 分类法,让越狱/滥用测试可归因、可覆盖度量,而非零散用例。
- [lm-evaluation-harness](https://github.com/EleutherAI/lm-evaluation-harness/pulls) — 本周以任务修复/新增为主([LegalBench HELM-lite 5 任务子集(#3860)](https://github.com/EleutherAI/lm-evaluation-harness/pull/3860)、韩语/北马其顿语任务标识修复),无框架级变化。
- meta-llama/llama-stack 已更名为 **OGX**(命令改为 `ogx run` / `ogx connect codex`,新增 `ogx-open-client`、`OGX_WORKERS` 环境变量),本周还修了 file_search ranking 权重、owner-encrypted PDF 处理。
  - 启示:Meta 的 llama-stack 正在改名重塑为 OGX,若我们文档/集成引用了 llama-stack CLI,需跟踪其品牌与命令行迁移。

## 值得跟进
- [ ] 评估 vLLM v0.24.0 的 `device_ids`(替代 `CUDA_VISIBLE_DEVICES`)对我们设备可见性/HAMi 软切分注入路径的影响,规划兼容方案。
- [ ] 规划 TRT-LLM TensorRT backend 移除的迁移:盘点是否有基于编译式 TRT engine 的部署,全部转 PyTorch-native 路径。
- [ ] 对标 KServe `kvCacheOffloading` 一等字段 + latency-predictor sidecar,决定我们的服务规格是否引入 KV tier 与 SLO-aware 路由打分。
- [ ] 把 Ray/KServe 的会话粘滞(consistent-hash)+ GPU-domain 亲和调度纳入我们推理路由与 GPU 调度能力矩阵。
- [ ] 跟进 MLflow / Model Registry 的 MCP + Agent Catalog 方向,评估我们模型/Agent 治理面是否需要提前建 MCP 登记与用量计量。

## 原始材料

<details>
<summary>扫描清单</summary>

- https://github.com/vllm-project/vllm/releases/tag/v0.24.0
- https://github.com/sgl-project/sglang/releases/tag/v0.5.14
- https://github.com/sgl-project/sglang/pull/29166
- https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc20
- https://github.com/ollama/ollama/releases/tag/v0.31.1
- https://github.com/ray-project/ray/releases/tag/ray-2.56.0
- https://github.com/kserve/kserve/pull/5599
- https://github.com/kserve/kserve/pull/5678
- https://github.com/kubeflow/training-operator/pull/3630
- https://github.com/hiyouga/LLaMA-Factory/pull/10544
- https://github.com/mlflow/mlflow/pull/23896
- https://github.com/mlflow/mlflow/pull/24217
- https://github.com/mlflow/mlflow/pull/24099
- https://github.com/mlflow/mlflow/pull/24177
- https://github.com/kubeflow/model-registry/pull/2887
- https://github.com/kubeflow/model-registry/pull/2888
- https://github.com/kubeflow/model-registry/pull/2857
- https://github.com/feast-dev/feast/pull/6549
- https://github.com/feast-dev/feast/pull/6561
- https://github.com/feast-dev/feast/pull/6552
- https://github.com/feast-dev/feast/pull/6569
- https://github.com/NVIDIA/garak/pull/1861
- https://github.com/NVIDIA/garak/pull/1890
- https://github.com/EleutherAI/lm-evaluation-harness/pull/3860
- https://github.com/substratusai/lingo/pull/661
</details>
