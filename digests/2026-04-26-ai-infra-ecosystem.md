# AI 推理 & MLOps 生态周报 2026-04-26

窗口:2026-04-19 → 2026-04-26

## 摘要

- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) 于 2026-04-23 发布,本周 main 继续推进 KV offload/HMA、MoE LoRA、FlashInfer NVLink workspace、ROCm engine memory leak 修复。启示:vLLM 的重点已从“单机高吞吐”扩展到 MoE、KV 分层、跨互联和多硬件稳定性。
- [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1) 于 2026-04-22 发布,本周又合入 llm-d v0.6 migration、WVA autoscaling e2e、Istio/Envoy keep-alive timeout。启示:KServe 正在把 LLM serving 的控制面能力快速主线化。
- [Ray 2.55.1](https://github.com/ray-project/ray/releases/tag/ray-2.55.1) 发布,本周 Ray Serve/LLM 继续加 multi-host TPU topology、label locality、placement group 修复。启示:Ray 在复杂多主机场景和数据/推理一体化上越来越像“AI runtime 控制面”。
- [TensorRT-LLM v1.2.1](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.2.1) 和 [v1.3.0rc12](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc12) 出现,本周 main 聚焦 NVFP4/Nemotron/测试内存假设。启示:NVIDIA 栈在 Blackwell/FP4/MoE 上继续领先,但私有化集成要处理更强的硬件绑定。

## 推理引擎动态

### vLLM

- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) 发布,包括 CUDA 13/PyTorch 2.11/Transformers v5、FlashAttention 4 MLA prefill、TurboQuant 2-bit KV cache、KV offload/connector 等方向。
  - 启示:runtime 选择器需要记录 CUDA/PyTorch/Transformers/KV backend/quantization 组合,否则升级 vLLM 会变成黑盒风险。
- [kv_offload+HMA: support store with multiple KV groups](https://github.com/vllm-project/vllm/commit/60cd878a3beca91e63d9a34a9c60fd335e780182) 本周合入。
  - 启示:KV offload 正走向分组/分层存储。产品侧要把 KV cache 从“显存占用”提升为可观测资源:命中率、迁移量、offload 延迟。
- [MoE LoRA Refactor](https://github.com/vllm-project/vllm/commit/8cd174fa358326d5cc4195446be2ebcd65c481ce) 和 [FlashInfer NVLink MNNVL workspace](https://github.com/vllm-project/vllm/commit/9558f43903faa1b6db08ac98802bf88111196345) 本周出现。
  - 启示:MoE + LoRA + NVLink/多节点互联会成为高端推理集群的复杂组合,需要单独压测和容量模型。

### SGLang

- [SGLang v0.5.10](https://github.com/sgl-project/sglang/releases/tag/v0.5.10) 近窗口发布,piecewise CUDA graph、Elastic EP、PD disaggregation GPU staging buffer 等仍是主要信号。
  - 启示:SGLang 在 PD 分离、MoE 和故障容忍上很激进,适合作为 vLLM 的对照 benchmark。
- 本周 main 出现 [DeepSeek-V4 H200/GB200 cookbook recipes](https://github.com/sgl-project/sglang/commit/3cfd1561df783d274d35f1e1d429544a7e405f35) 和 [MoE JIT silu/gelu_and_mul 优化](https://github.com/sgl-project/sglang/commit/c7878dbb6ddfc9c6721b9db20a876f2718b0e955)。
  - 启示:硬件 recipe 正在变成推理框架交付的一部分。我们平台如果要支持高端 GPU/NPU,也需要内置“已验证部署配方”。

### TensorRT-LLM / Ollama

- [TensorRT-LLM v1.2.1](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.2.1) 本周发布,main 上继续修 NVFP4/Nemotron 相关测试: [commit](https://github.com/NVIDIA/TensorRT-LLM/commit/c10954b5fa6db50e7bf3a164fabc17a849fe4e39)。
  - 启示:FP4/NVFP4 是 NVIDIA 新硬件栈的关键能力,我们需要把它作为 Blackwell 代际能力单独跟踪。
- [Ollama v0.21.2](https://github.com/ollama/ollama/releases/tag/v0.21.2) 和 [v0.21.3-rc0](https://github.com/ollama/ollama/releases/tag/v0.21.3-rc0) 本周出现;main 上有 OpenAI reasoning effort 映射和 sampler batch: [commit](https://github.com/ollama/ollama/commit/ea01af6f76fc03ba737aec1f9a49e82f6063bab1)。
  - 启示:桌面/边缘推理也在追 OpenAI Responses/Reasoning 语义,企业平台需要兼容新的 API 字段。

## 模型服务 & 编排

- [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1) 是本周模型服务主线。
  - [llm-d v0.6 migration logic](https://github.com/kserve/kserve/commit/93701d774a5f0dd8852aa8261b31e2b917695bf7) 说明 KServe 已经把 llm-d 组件升级路径纳入控制面。
  - [WVA scaling e2e](https://github.com/kserve/kserve/commit/7dd90abec985e423a90d8a3d2747a6516d76ec61) 说明 autoscaling 不再只是配置项,开始进入 CI 验收。
  - [Istio/Envoy timeout_keep_alive](https://github.com/kserve/kserve/commit/7b52c79e4a1520709d784c755b028a41be371072) 对长连接推理很关键。
- 启示:KServe 的 LLMInferenceService 正在变成“模型服务 + 路由 + autoscaling + 网关兼容”的组合控制面,我们集成时应按完整链路测。

## 训练 & 微调

- [Ray 2.55.1](https://github.com/ray-project/ray/releases/tag/ray-2.55.1) 修复 ray-llm image SSH connectivity,[Ray 2.55.0](https://github.com/ray-project/ray/releases/tag/ray-2.55.0) 加 Data LLM metrics/Grafana、Serve routing/autoscaling 等。
  - 启示:Ray 适合承载数据处理、批推理、分布式训练和复杂 DAG。我们应把它和 KServe 分层定位:Ray 管复杂 pipeline,KServe 管标准在线 serving。
- [Ray Serve LLMConfig 增加 topology 字段支持 multi-host with TPUs](https://github.com/ray-project/ray/commit/2674b71106928e2b1ff6eaa973bc131f68c78ce7)。
  - 启示:多主机拓扑正在进入 LLM serving 配置本身,这与 K8s 侧 LWS/JobSet 的拓扑表达会逐步汇合。

## 模型生命周期(MLflow / Registry / Feast)

- [Feast 本周使 ODFV input_schema 可选](https://github.com/feast-dev/feast/commit/f08b4e823abe2b64de5f91cec205c8367d61a44a),并优化 aggregation/udf 配置: [commit](https://github.com/feast-dev/feast/commit/f630056dfdf6676ae1033175dff5ea7226033c7a)。
  - 启示:Feature Store 正在降低定义复杂度,有利于把特征工程纳入平台 UI。
- [MLflow 本周 surface thinking/tool_result events in stream.sh](https://github.com/mlflow/mlflow/commit/7346cc8bc9144e05b46112928036d19f4829a904),并持续修 prompts/agent 相关体验。
  - 启示:MLflow 正在向 GenAI trace/agent event 方向延伸。我们的观测模型也应覆盖工具调用、思考事件、评估结果。

## LLM 评估 & 安全

- [NVIDIA garak 本周明确枚举 configurable params docs](https://github.com/NVIDIA/garak/commit/b24d640b787c8f7a2c00083312d9b621c1d064e1),并清理依赖。
  - 启示:LLM 安全评估工具的可配置参数会变成平台集成点。我们可以把 garak 作为红队/越狱测试 provider。

## 值得跟进

- [ ] 建 vLLM/SGLang/KServe/OpenFuyao 的 KV cache 与 PD disaggregation 能力矩阵。
- [ ] 用 [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1) 验证 LLMInferenceService + llm-d v0.6 + WVA scaling。
- [ ] 跟 Ray Serve topology 字段,评估与 K8s LWS/JobSet 拓扑表达如何对接。
- [ ] 跟 TensorRT-LLM NVFP4/Blackwell 支持,作为高端 GPU 产品路线输入。

## 原始材料

- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0)
- [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1)
- [Ray 2.55.1](https://github.com/ray-project/ray/releases/tag/ray-2.55.1)
- [SGLang v0.5.10](https://github.com/sgl-project/sglang/releases/tag/v0.5.10)
- [TensorRT-LLM v1.2.1](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.2.1)
- [Ollama v0.21.2](https://github.com/ollama/ollama/releases/tag/v0.21.2)
- [Feast commits](https://github.com/feast-dev/feast/commits/master/)
- [MLflow commits](https://github.com/mlflow/mlflow/commits/master/)
