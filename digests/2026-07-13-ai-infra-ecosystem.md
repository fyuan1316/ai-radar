# AI 推理 & MLOps 生态周报 2026-07-13

窗口:2026-07-06 -> 2026-07-13(7 天)

## 摘要(5 条以内)
- [vLLM v0.25.0](https://github.com/vllm-project/vllm/releases/tag/v0.25.0) 与 [SGLang v0.5.15](https://github.com/sgl-project/sglang/releases/tag/v0.5.15) 同周发布，推理引擎竞争继续集中在 KV cache、MoE/LoRA、RDMA/PD 分离、多硬件后端和镜像/依赖交付。
- vLLM 本周 PR 重点是 KV offload、KV transfer/RDMA backpressure、DeepEPv2/NCCL、RayExecutorV2、fp8 KV cache；SGLang 则在 multi-LoRA、adapter upsert、CPU/AMD 后端、CUDA 依赖稳定性上活跃。
- KServe LLMInferenceService 继续补模型服务平台能力:traffic splitting、LocalModelCache、StorageContainer、runtimeClassName、nvidia-dra samples、path based routing。
- Ray Serve/Ray Core 的信号集中在 Serve router、vLLM 0.25.0 升级、K8s Pod events、accelerator support 和 DAG/NCCL fallback。
- MLflow 本周继续强化 tracing/agent span、OpenInference retriever document ingest、model catalog 和 DB upgrade 稳定性，说明模型生命周期正在向 agent observability 延伸。

## 推理引擎动态

### vLLM

- [vLLM v0.25.0](https://github.com/vllm-project/vllm/releases/tag/v0.25.0) 发布。
  - 启示:vLLM 版本节奏仍然很快，我们的推理 runtime 集成要把模型兼容、CUDA/NCCL、Ray、KServe adapter 和镜像构建拆开验证，不能只按单一版本升级。
- [vLLM PR #48150](https://github.com/vllm-project/vllm/pull/48150) — KV cache layout parsing 下沉到 offloading connector。
  - 启示:KV offload 正在变成可插拔连接器问题。平台侧应把 KV cache tier、offload backend、节点本地/远端资源作为可配置能力，而不是藏在 engine flags。
- [vLLM PR #47495](https://github.com/vllm-project/vllm/pull/47495) 与 [#46115](https://github.com/vllm-project/vllm/pull/46115) — MoRIIO KV-transfer/RDMA backpressure 与高并发 P/D proxy 修复。
  - 启示:PD 分离和远端 KV transfer 的关键风险在网络背压和高并发稳定性。我们的基准测试要覆盖 send-queue full、RDMA 丢包/拥塞、prefill/decode burst。
- [vLLM PR #45321](https://github.com/vllm-project/vllm/pull/45321) — 更新 NCCL 到 2.30.7 以启用 DeepEPv2。
  - 启示:推理引擎性能越来越依赖通信库版本。离线交付要把 NCCL/CUDA/driver/runtime matrix 做成一等制品，不然性能特性可能无法启用。
- [vLLM PR #48439](https://github.com/vllm-project/vllm/pull/48439) 与 [#48433](https://github.com/vllm-project/vllm/pull/48433) — fp8 KV cache startup crash、KV connector async load reservation 修复。
  - 启示:KV cache 相关 bug 会直接表现为启动失败或吞吐抖动。我们发布 runtime image 时需要有 KV-heavy smoke，而不是只跑单请求推理。

### SGLang

- [SGLang v0.5.15](https://github.com/sgl-project/sglang/releases/tag/v0.5.15) 发布。
  - 启示:SGLang 正保持高频 release，已经是 vLLM 之外必须持续对标的引擎。产品上不要把“高性能 LLM serving”绑定到单引擎。
- [SGLang PR #30912](https://github.com/sgl-project/sglang/pull/30912) 与 [#30913](https://github.com/sgl-project/sglang/pull/30913) — 支持按 rid prefix abort request、从 tensors/distributed upsert adapter，面向 multi-LoRA。
  - 启示:多 LoRA/adapter 在线管理需要请求级取消、adapter 热更新和分布式状态一致性。我们的模型服务 API 应把 adapter lifecycle 作为独立资源。
- [SGLang PR #30719](https://github.com/sgl-project/sglang/pull/30719) 与 [#30745](https://github.com/sgl-project/sglang/pull/30745) — CPU AMX 优化、AMD 平台 DeepSeek V4 DSpark 支持。
  - 启示:推理引擎正在覆盖更多非 NVIDIA 后端。我们做多算力平台时，需要把 AMD/CPU fallback 的能力、性能和限制写进 runtime catalog。
- [SGLang PR #30961](https://github.com/sgl-project/sglang/pull/30961) — cu13 镜像恢复 flashinfer 依赖变化导致缺失的 CUDA compiler components。
  - 启示:推理镜像的 Python 依赖会隐式改变 CUDA 组件。离线镜像构建要有 runtime import/kernel compile smoke，不能只看 pip lock。

### TensorRT-LLM / TGI / Ollama

- [Ollama v0.32.0-rc0](https://github.com/ollama/ollama/releases/tag/v0.32.0-rc0) 与 [v0.31.2](https://github.com/ollama/ollama/releases/tag/v0.31.2) 本周发布。
  - 启示:Ollama 仍在桌面/边缘侧保持节奏。对企业平台来说，Ollama 更像边缘体验和模型分发入口，不是集群 serving 基线，但它会影响用户对“简单部署”的预期。
- 本轮未确认到 TensorRT-LLM / TGI 与云原生平台直接相关的重大 release。

## 模型服务 & 编排

### KServe 上游

- [KServe PR #5798](https://github.com/kserve/kserve/pull/5798) — LLMInferenceService group routing machinery for traffic splitting。
  - 启示:KServe 正把 LLM 灰度发布和流量切分做进 LLMISVC。模型服务平台应把版本、权重、SLO、回滚作为一组原生概念。
- [KServe PR #5033](https://github.com/kserve/kserve/pull/5033) — LocalModelCacheDeployment CRD。
  - 启示:模型缓存开始拥有独立 CRD。我们需要规划缓存容量、节点选择、预热、回收、租户隔离和可观测。
- [KServe PR #5705](https://github.com/kserve/kserve/pull/5705) — namespace-scoped StorageContainer CRD。
  - 启示:存储初始化和模型拉取将更细粒度地进入租户命名空间。企业场景要把 StorageContainer 与 Secret、镜像仓库、对象存储权限绑定。
- [KServe PR #5198](https://github.com/kserve/kserve/pull/5198) — ServingRuntimePodSpec 支持 `runtimeClassName`。
  - 启示:模型服务需要选择不同 runtime handler，例如 GPU/NPU runtime、sandbox、kata。我们的 runtime catalog 应暴露 runtimeClassName，并校验节点支持。
- [KServe PR #5642](https://github.com/kserve/kserve/pull/5642) — 增加 nvidia-dra LLMInferenceService examples。
  - 启示:DRA 将进入模型服务规格示例。我们需要尽早验证 ResourceClaimTemplate 与模型服务生命周期、扩缩容、滚动更新的关系。

### Ray

- [Ray PR #64700](https://github.com/ray-project/ray/pull/64700) — Serve router sticky latency-adaptive queue-length probe deadline。
  - 启示:Ray Serve 路由仍在针对延迟和队列长度优化。我们做推理网关时，应把 queue length、latency、KV locality、backend saturation 合并评估，而不是只做轮询。
- [Ray PR #64697](https://github.com/ray-project/ray/pull/64697) — Ray LLM 升级到 vLLM 0.25.0。
  - 启示:Ray 与 vLLM 的耦合很深。平台升级 Ray Serve/LLM 时，要同步验证 vLLM 版本、模型参数和镜像依赖。
- [Ray PR #63937](https://github.com/ray-project/ray/pull/63937) — Ray Dashboard Head 捕获 K8s Pod events。
  - 启示:Ray on K8s 的可观测正在补齐 K8s 原生事件。我们的训练/推理控制台也应直接展示 Pod events、调度原因和节点事件。
- [Ray PR #61898](https://github.com/ray-project/ray/pull/61898) — Mobilint Accelerator Support。
  - 启示:Ray 正继续扩展 accelerator abstraction。我们多硬件接入要跟踪 Ray accelerator label 与 K8s device/DRA 的映射。

## 训练 & 微调

- Kubeflow Training Operator 本轮未确认到重大 release；生态重点转向 JobSet/Kueue/LWS 与推理 serving 结合。
- SGLang multi-LoRA 相关 PR [#30912](https://github.com/sgl-project/sglang/pull/30912)、[#30913](https://github.com/sgl-project/sglang/pull/30913) 对在线微调/adapter serving 有直接参考价值。

## 模型生命周期(MLflow / Registry / Feast)

- [MLflow PR #24397](https://github.com/mlflow/mlflow/pull/24397) — 更新 model catalog from upstream sources。
  - 启示:model catalog 正成为模型生命周期入口。我们的模型目录需要自动同步上游元数据，但必须叠加企业审核、许可、镜像/runtime 可用性。
- [MLflow PR #24290](https://github.com/mlflow/mlflow/pull/24290) — OpenAI agent `Generation` span token usage 记录到 tracing attribute。
  - 启示:Agent/LLM 应用的 token usage 正进入实验追踪/观测体系。MaaS 计量、成本、评估和 trace 应统一。
- [MLflow PR #24388](https://github.com/mlflow/mlflow/pull/24388) — OTel ingest 时重组 OpenInference retriever documents 到 span outputs。
  - 启示:RAG 的 retriever 证据链会进入 trace。我们做 RAG/AgentOps 时，应把检索文档、生成结果、评估指标作为同一 trace 视图。
- [MLflow PR #24394](https://github.com/mlflow/mlflow/pull/24394) — database upgrade 时处理已有 tables。
  - 启示:模型生命周期系统升级经常卡在元数据库迁移。生产交付要有 migration dry-run 和回滚策略。

## LLM 评估 & 安全

- 本轮未确认到 garak / llama-stack 可可靠筛选的重大 release；`meta-llama/llama-stack` pulls 端点返回非数组错误，未纳入结论。
- MLflow tracing 与 OpenInference ingest 的变化说明评估/安全信号正在向 trace 汇聚，后续可跟 TrustyAI、Garak、OpenTelemetry 结合。

## 值得跟进
- [ ] 给 vLLM 0.25.0 做 KV offload/RDMA/DeepEPv2/FP8 KV cache smoke，明确我们的 runtime image 升级风险。
- [ ] 对比 SGLang multi-LoRA adapter lifecycle，设计 adapter 资源、热更新、取消请求和分布式一致性 API。
- [ ] 试读 KServe LocalModelCache、StorageContainer、runtimeClassName、nvidia-dra samples，评估模型缓存和 DRA 进入产品规格的时间点。
- [ ] 跟 Ray Serve router 和 K8s Pod events 集成，补齐我们控制台的调度/事件/路由可观测。
- [ ] 把 MLflow tracing/OpenInference 信号映射到 MaaS 计量、RAG trace 和 AgentOps。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://github.com/vllm-project/vllm/releases/tag/v0.25.0
- https://github.com/vllm-project/vllm/pull/48150
- https://github.com/vllm-project/vllm/pull/47495
- https://github.com/vllm-project/vllm/pull/46115
- https://github.com/vllm-project/vllm/pull/45321
- https://github.com/vllm-project/vllm/pull/48439
- https://github.com/vllm-project/vllm/pull/48433
- https://github.com/sgl-project/sglang/releases/tag/v0.5.15
- https://github.com/sgl-project/sglang/pull/30912
- https://github.com/sgl-project/sglang/pull/30913
- https://github.com/sgl-project/sglang/pull/30719
- https://github.com/sgl-project/sglang/pull/30745
- https://github.com/sgl-project/sglang/pull/30961
- https://github.com/ollama/ollama/releases/tag/v0.32.0-rc0
- https://github.com/ollama/ollama/releases/tag/v0.31.2
- https://github.com/kserve/kserve/pull/5798
- https://github.com/kserve/kserve/pull/5033
- https://github.com/kserve/kserve/pull/5705
- https://github.com/kserve/kserve/pull/5198
- https://github.com/kserve/kserve/pull/5642
- https://github.com/ray-project/ray/pull/64700
- https://github.com/ray-project/ray/pull/64697
- https://github.com/ray-project/ray/pull/63937
- https://github.com/ray-project/ray/pull/61898
- https://github.com/mlflow/mlflow/pull/24397
- https://github.com/mlflow/mlflow/pull/24290
- https://github.com/mlflow/mlflow/pull/24388
- https://github.com/mlflow/mlflow/pull/24394
- 备注:`meta-llama/llama-stack` pulls 端点本轮返回非数组错误，未纳入结论。
</details>
