# AI 推理 & MLOps 生态周报 2026-04-26

窗口:2026-04-19 → 2026-04-26(过去 7 天)

抓取说明:本次运行环境中 `curl https://api.github.com/rate_limit` 返回 DNS 解析失败,未能完成 GitHub API PR/commit 级扫描;本 digest 基于 GitHub release 页面和公开资料。由于 release 级信号足够强,本周仍有可归档价值。

## 摘要

- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) 在 2026-04-23 发布,546 commits,重点包括 CUDA 13/PyTorch 2.11/Transformers v5、FlashAttention 4 默认 MLA prefill、TurboQuant 2-bit KV cache、Model Runner V2、vLLM IR、KV offload/connector、大规模 serving 改进。启示:vLLM 已经从“推理引擎”演进成硬件/编译/量化/KV/分布式 serving 平台,我们集成时要按 capability matrix 管理。
- [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1) 发布,LLMInferenceService 继续强化 LWS、WVA/KEDA/HPA、llm-d 0.6、ModelCache namespace scope、GatewayClass 测试。启示:模型服务编排层正在把 LLM 专用能力纳入主线,我们不能把 KServe 当传统 sklearn/xgboost serving 工具。
- [Ray 2.55.1](https://github.com/ray-project/ray/releases/tag/ray-2.55.1) 修复 ray-llm image SSH connectivity;[Ray 2.55.0](https://github.com/ray-project/ray/releases/tag/ray-2.55.0) 则把 Ray Data、GPU shuffle、Data LLM metrics/Grafana、Ray Serve 自定义路由/autoscaling 继续推进。启示:Ray 的价值从训练扩展到“数据处理 + LLM serving observability + Serve autoscaling”。
- [SGLang v0.5.10](https://github.com/sgl-project/sglang/releases/tag/v0.5.10) 虽在窗口前发布,但方向与 vLLM 形成直接竞争:piecewise CUDA graph、Elastic EP partial failure tolerance、PD disaggregation GPU staging buffer、HiSparse、FlashInfer MXFP8。启示:SGLang 正在用更激进的 serving 架构挑战 vLLM,尤其是 PD 分离和故障容忍。

## 推理引擎动态

### vLLM

- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) 切到 CUDA 13 默认 wheel、PyTorch 2.11、Transformers v5 兼容。
  - 启示:这会直接影响企业环境镜像基线。我们的 runtime 选择器需要记录 CUDA/PyTorch/Transformers 三元组,否则升级 vLLM 可能导致底层驱动或模型加载不兼容。
- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) 启用 FlashAttention 4 作为 MLA prefill 默认后端,并加入 TurboQuant 2-bit KV cache compression、per-token-head INT8/FP8 KV cache quantization 等。
  - 启示:KV cache 已成为推理成本核心。我们产品应该暴露 KV cache 压缩/Offload/Connector 能力,并把它们纳入容量评估器,不能只估模型权重显存。
- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) 在 Large Scale Serving 中包括 KV offload/connector、3FS KVConnector、NIXL 0.10.1、multi-connector metrics、LMCache 事件等。
  - 启示:分离式 prefill/decode 和跨节点 KV 传输已进入工程主线。我们在 KServe/llm-d/OpenFuyao hermes-router 对标时,应把“KV 路由/存储/传输”单独作为架构层。

### SGLang

- [SGLang v0.5.10](https://github.com/sgl-project/sglang/releases/tag/v0.5.10) 默认启用 piecewise CUDA graph,并引入 Elastic NIXL-EP 以支持 DeepSeek MoE 部署的 partial failure tolerance。
  - 启示:大规模 MoE serving 的可用性正在从“失败重启”走向“部分专家重分布继续服务”。这类能力对企业 SLA 很有价值,我们应跟踪是否能通过 SGLang/KServe 暴露。
- [SGLang v0.5.10](https://github.com/sgl-project/sglang/releases/tag/v0.5.10) 的 PD disaggregation GPU staging buffer 宣称在 Qwen3.5 大并发下 Prefill TP4 + Decode DEP4 TPS/GPU 提升约 5x。
  - 启示:PD 分离的瓶颈已经不是“能不能拆”,而是 RDMA/KV 数据搬运效率。我们做多节点推理时要把网络、GPU staging、KV cache 命中率纳入 benchmark。

### TensorRT-LLM / TGI / Ollama

- 本次未能通过 GitHub API 完成 TensorRT-LLM / TGI / Ollama 本周 PR 扫描。
  - 启示:下次补扫时重点看 Blackwell/FP4、OpenAI-compatible API、structured output、LoRA serving、Kubernetes packaging。

## 模型服务 & 编排

### KServe 上游

- [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1) 包含 llmisvc LWS leader address、missing LWS CRD graceful handling、WVA+KEDA/HPA autoscaling、llm-d 0.6、GatewayClass e2e、Namespace Scoped ModelCache。
  - 启示:KServe 正在把 LLM serving 的关键控制面整合到 release train。我们如果继续使用 ODH fork,也要同步看 upstream v0.18,避免 fork 里重复维护已上游化的能力。

### Ray

- [Ray 2.55.1](https://github.com/ray-project/ray/releases/tag/ray-2.55.1) 修复 `ray-llm` image SSH connectivity 并升级 slim base apt packages。
  - 启示:Ray LLM 镜像已经是官方关注对象。私有化部署要把 Ray 镜像的安全修复纳入镜像同步/扫描流水线。
- [Ray 2.55.0](https://github.com/ray-project/ray/releases/tag/ray-2.55.0) 增加 Ray Data GPU shuffle、vLLM metrics export、Data LLM Grafana dashboard、Ray Serve 自定义 request routing/autoscaling 相关能力。
  - 启示:Ray 适合做“数据 → 批处理 → LLM 推理”的管线底座。我们产品可以把 Ray Serve 与 KServe 区分定位:KServe 管在线标准 serving,Ray 管复杂数据/批推理/自定义 DAG。

## 训练 & 微调

- [RHOAI 3.4 EA2](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) 把 Kubeflow Trainer JIT checkpoint 和 S3 checkpoint 写入产品文档。
  - 启示:训练 operator 的竞争点从“能拉起多机 PyTorch”转向“中断恢复和状态管理”。我们应该将 checkpoint 策略作为训练模板的一等字段。

## 模型生命周期(MLflow / Registry / Feast)

- [RHOAI 3.4 release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) 包含 Feature Store 与项目/Workbench/RBAC 集成、MLflow Developer Preview、Model Registry 数据库配置等方向。
  - 启示:模型生命周期正在和 Kubernetes namespace/RBAC 绑定。我们的 Model Registry 不应是孤立数据库,要能映射项目、权限、实验、部署和审计。

## LLM 评估 & 安全

- [RHOAI 3.4 release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) 提到 Garak evaluation provider 可用于 Llama Stack distribution,同时 TrustyAI-Llama Stack integration 支持 safety/guardrails/evaluation。
  - 启示:评估/安全能力正在向“平台内置 provider”发展。我们如果做合规能力,可以先从 Garak/TrustyAI 风格的可插拔 provider 开始,而不是自研一套评测框架。

## 值得跟进

- [ ] 升级测试 [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0),重点测 CUDA 13/PyTorch 2.11/Transformers v5 对现有镜像和模型的影响。
- [ ] 跟进 [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1) 到 GA,验证 llmisvc + LWS + WVA/KEDA/HPA。
- [ ] 对比 vLLM KV connector / LMCache / SGLang PD staging / OpenFuyao hermes-router,整理一张 KV 路由与缓存能力矩阵。
- [ ] 评估 Ray 2.55 的 vLLM metrics + Grafana dashboard 是否能并入我们的可观测方案。

## 原始材料

- [vLLM v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0)
- [SGLang v0.5.10](https://github.com/sgl-project/sglang/releases/tag/v0.5.10)
- [KServe v0.18.0-rc1](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc1)
- [Ray 2.55.1](https://github.com/ray-project/ray/releases/tag/ray-2.55.1)
- [Ray 2.55.0](https://github.com/ray-project/ray/releases/tag/ray-2.55.0)
- [RHOAI 3.4 EA2 release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index)
- 未完成:GitHub API curl 原始扫描失败,错误为 `Could not resolve host: api.github.com`。
