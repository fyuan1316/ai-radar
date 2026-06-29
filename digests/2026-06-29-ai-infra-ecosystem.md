# AI 推理 & MLOps 生态周报 2026-06-29

窗口:2026-06-22 -> 2026-06-29(7 天)

## 摘要(5 条以内)
- [SGLang v0.5.14](https://github.com/sgl-project/sglang/releases/tag/v0.5.14) 继续把竞争焦点放在 DeepSeek-V4、MoE load balancing、Blackwell/GB300、linear-attention prefix cache、MSCCL++、Ascend/ROCm 后端。
- [TensorRT-LLM v1.3.0rc19](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc19) 推进 Blackwell 默认 decode backend、disaggregated serving、Prometheus 推理指标、speculative decoding、MoE/NVFP4。
- KServe 上游本周 PR 明确推进 LLMInferenceService controlled deployment traffic splitting、tiered KV-cache offloading、WVA annotation discovery、Envoy AI Gateway v1.0.0。
- Ray 本周 PR 出现 LLM KV prefill/decode token load aware request routing，Serve 侧也在收敛 router retry 和 queue-length cache 失败路径。
- MLflow 3.14.x 后续 PR 聚焦 tracking/model-registry/evaluation 的 bugfix，尤其 strict JSON schema、artifact/model registry UI 和 DB migration 幂等。

## 推理引擎动态

### vLLM

- [vLLM PR #46972](https://github.com/vllm-project/vllm/pull/46972) — KV offload 在 MTP/Eagle 场景下处理 interior chunk-boundary blocks。
  - 启示:KV offload 与 speculative decoding/MTP 组合后，cache block 边界会成为正确性风险。我们做推理引擎升级时，不能只看 steady-state throughput，也要压测 spec decode + offload + 长上下文。
- [vLLM PR #46968](https://github.com/vllm-project/vllm/pull/46968) — spec decode draft prefill 避免 redundant hidden-states gather。
  - 启示:speculative decoding 的性能优化已经深入到 hidden-state 传输细节。产品层面的性能诊断需要能区分 prefill、draft、verify、decode 各阶段，而不是只看总延迟。
- [vLLM PR #46978](https://github.com/vllm-project/vllm/pull/46978) — ROCm CI 继续向 AMD test parity 推进。
  - 启示:非 NVIDIA 后端正在进入主线质量门禁。多硬件平台应把 AMD/ROCm、Ascend 等后端纳入同等回归，而不是按“最佳努力”处理。

### SGLang

- [SGLang v0.5.14](https://github.com/sgl-project/sglang/releases/tag/v0.5.14) — DeepSeek-V4 on GB300、Waterfill/LPLB MoE load balancing、Blackwell KDA prefill kernel、linear-attention prefix-cache memory savings 是 release 重点。
  - 启示:SGLang 正把差异化建立在 MoE、Blackwell、linear attention、prefix cache 和多后端上。我们对标 vLLM 时应专门拉出 MoE routing/load balancing 和 prefix cache 能力，而不是只看 API 兼容。
- [SGLang v0.5.14](https://github.com/sgl-project/sglang/releases/tag/v0.5.14) — MSCCL++ integration、MNNVL allreduce fusion、Nemotron DP attention + MTP。
  - 启示:高端集群推理性能越来越依赖通信库和 collective tuning。平台要记录 engine、通信库、GPU/NPU 代际、网络拓扑的组合，而不是只记录模型镜像 tag。

### TensorRT-LLM / TGI / Ollama

- [TensorRT-LLM v1.3.0rc19](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc19) — `TrtllmGenAttention` 成为 Blackwell+ 默认 decode backend，并新增 prompt cache、speculative decoding、perplexity、batch occupancy 的 Prometheus metrics。
  - 启示:NVIDIA 栈会把 Blackwell/GB200/GB300 的默认性能路径牢牢绑定到 TRT-LLM。企业 NVIDIA 场景下，vLLM/SGLang/TRT-LLM 应并行压测，并把 engine metrics 接到统一 SLO 面板。
- [TensorRT-LLM v1.3.0rc19](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc19) — 支持 disaggregated serving beam search、gen-only speculative decoding for disagg setups、per-request multimodal processor kwargs。
  - 启示:PD/disaggregated serving 不只是吞吐优化，还会影响 beam search、spec decode、多模态请求参数这些功能边界。我们的模型服务声明要覆盖这些差异。
- [Ollama v0.30.11](https://github.com/ollama/ollama/releases/tag/v0.30.11) 本周有 release，但工程重点仍偏桌面/边缘体验，本期不展开。

## 模型服务 & 编排

### KServe 上游

- [KServe PR #5727](https://github.com/kserve/kserve/pull/5727) — LLMInferenceService 增加 traffic splitting for controlled deployment。
  - 启示:模型服务需要一等灰度发布能力。我们应该把 “新模型版本 -> 小流量 -> 指标观察 -> 自动/手动切换” 做成平台工作流。
- [KServe PR #5721](https://github.com/kserve/kserve/pull/5721) — LLMInferenceService 支持 tiered KV-cache offloading。
  - 启示:KV cache tier 将影响节点选型、存储介质、成本和 SLO。服务规格需要表达 cache tier，而不是只配置 replicas/GPU。
- [KServe PR #5722](https://github.com/kserve/kserve/pull/5722) — WVA 从 VA CRD 迁移到 annotation-based discovery。
  - 启示:自动扩缩容组件可能从独立 CRD 转向 workload annotation 发现，降低接入门槛但也提高 annotation contract 的重要性。
- [KServe PR #5732](https://github.com/kserve/kserve/pull/5732) 和 [#5731](https://github.com/kserve/kserve/pull/5731) — storage initializer 可配置 storage volume，LocalModel 支持覆盖 inferenceservice-config ConfigMap namespace。
  - 启示:模型加载路径正在变成可配置的资源面。我们需要将存储初始化、LocalModel cache、ConfigMap namespace、权限隔离统一建模。

### Ray

- [Ray PR #64400](https://github.com/ray-project/ray/pull/64400) — LLM KV prefill/decode token load aware request routing。
  - 启示:Ray Serve 也在把 KV/token load 纳入请求路由。KServe/llm-d、OpenFuyao Hermes-router、Ray Serve 的路由算法正在收敛到“请求形态 + KV + 实例负载”。
- [Ray PR #64399](https://github.com/ray-project/ray/pull/64399) 和 [#64398](https://github.com/ray-project/ray/pull/64398) — Serve router 增加最大重试边界，并在 gRPC request failure 时失效 replica queue-length cache。
  - 启示:Serve 路由器的失败路径会直接影响尾延迟和故障放大。我们的推理网关也要有 retry budget 和队列长度缓存失效机制。

## 训练 & 微调

- 本窗口未确认到 Kubeflow Training Operator / LLaMA-Factory 重大 release。Kueue PR [#12606](https://github.com/kubernetes-sigs/kueue/pull/12606) 提到 Kubeflow training v1 正被 training v2 phased out。
  - 启示:训练作业控制面将继续向 Training Operator v2 + Kueue/JobSet 收敛。我们维护训练能力时应避免继续扩展 v1 CRD 专属能力。

## 模型生命周期(MLflow / Registry / Feast)

- [MLflow PR #24193](https://github.com/mlflow/mlflow/pull/24193) — strict JSON schema 校验递归进入 nested schemas 和 `$defs`。
  - 启示:Agent/tool/function calling 的评估和回归越来越依赖严格 schema。我们的 GenAI eval 模块应保存 schema 版本，并在回归测试中校验嵌套结构。
- [MLflow PR #24195](https://github.com/mlflow/mlflow/pull/24195) — 恢复 runs:/ URI model versions 的 Artifacts tab badge。
  - 启示:模型注册 UI 的 artifact lineage 细节会影响排障效率。我们做模型生命周期时要保留 run、artifact、registered model、serving version 的可追溯链路。

## LLM 评估 & 安全

- [NVIDIA/garak](https://github.com/NVIDIA/garak) 本窗口未出现 release；评估/安全本周更有价值的信号来自 MLflow strict JSON schema 和 KServe traffic splitting，可用于把自动评估接入灰度发布。

## 值得跟进
- [ ] 拉通 KServe LLMISVC traffic splitting + MLflow/eval trace，设计模型灰度发布的自动评估门禁。
- [ ] 对比 SGLang Waterfill/LPLB、Ray token-load routing、OpenFuyao Hermes prediction routing，整理我们自己的推理路由能力矩阵。
- [ ] 验证 vLLM KV offload + speculative decoding + 长上下文的正确性与性能回归。
- [ ] 评估 TRT-LLM Prometheus 指标与现有推理 SLO 面板的字段映射。

## 原始材料

<details>
<summary>扫描清单</summary>

- https://github.com/sgl-project/sglang/releases/tag/v0.5.14
- https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc19
- https://github.com/ollama/ollama/releases/tag/v0.30.11
- https://github.com/vllm-project/vllm/pull/46972
- https://github.com/vllm-project/vllm/pull/46968
- https://github.com/vllm-project/vllm/pull/46978
- https://github.com/kserve/kserve/pull/5727
- https://github.com/kserve/kserve/pull/5721
- https://github.com/kserve/kserve/pull/5722
- https://github.com/kserve/kserve/pull/5732
- https://github.com/kserve/kserve/pull/5731
- https://github.com/ray-project/ray/pull/64400
- https://github.com/ray-project/ray/pull/64399
- https://github.com/ray-project/ray/pull/64398
- https://github.com/mlflow/mlflow/pull/24193
- https://github.com/mlflow/mlflow/pull/24195
- https://github.com/kubernetes-sigs/kueue/pull/12606
</details>
