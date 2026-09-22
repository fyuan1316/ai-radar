# AI 推理 & MLOps 生态周报 2026-09-22

窗口:2026-09-15 -> 2026-09-22(7 天)

## 摘要(5 条以内)
- [SGLang v0.5.20](https://github.com/sgl-project/sglang/releases/tag/v0.5.20) 与 [TensorRT-LLM v1.3.0rc27](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc27) 本周发布，推理引擎竞争继续围绕 speculative decoding、KV cache、MoE、ROCm/Ascend/Blackwell 多硬件展开。
- vLLM 与 SGLang 的高价值 PR 都在处理长 prefill、公平调度、KV cache/offload、CUDA graph、ROCm/NPU kernel 适配，说明“多模型新架构 + 多硬件 + 长上下文”正在放大 serving runtime 的边界 bug。
- KServe 本周主要信号是构建链路对 Gateway API Inference Extension / llm-d-router CRD 下载失败做 fail-fast，说明 LLM serving 的供应链依赖已经进入 release 风险点。
- Ray 侧集中在 Data/Train fault tolerance、autoscaling reservation per node、多租户 placement 校验，分布式数据/训练正在补资源预留与恢复语义。
- MLflow 3.16.1 patch release 移除默认 basic-auth admin password，并增加 evaluation timeout，MLOps 安全默认值和评估可控性继续增强。

## 推理引擎动态

### vLLM

- [vLLM PR #57951](https://github.com/vllm-project/vllm/pull/57951) — 放宽 `long_prefill_token_threshold`，避免长 prompt 在 token budget 足够时被无条件切分。
  - 启示:长上下文调度需要在吞吐公平和单请求延迟之间动态取舍。我们的模型服务 SLO 配置不应只有 batch size，还要暴露 prefill token budget、长 prompt 限制和饥饿保护。
- [vLLM PR #55390](https://github.com/vllm-project/vllm/pull/55390) — 在 hybrid grouping path 上按位置标注 MTP draft KV cache group，修复 Qwen3.5/Qwen3-Next 等 hybrid attention + MTP 场景。
  - 启示:新模型结构会把 KV cache grouping/offload 的假设打破。runtime catalog 需要记录“模型结构特性 -> KV/offload/spec decode 支持矩阵”。
- [vLLM PR #57458](https://github.com/vllm-project/vllm/pull/57458) — 降低 GLM sparse MLA attention 的 query packing 和 sparse-index preparation 开销。
  - 启示:国产/新模型的 attention 变体会持续带来 kernel 级优化需求。平台要能按模型选择 runtime image，而不是全局一个 vLLM 版本。
- [vLLM PR #57737](https://github.com/vllm-project/vllm/pull/57737) — Pooling runner shutdown 时释放模型引用和 GPU 内存。
  - 启示:embedding/pooling 服务也会遇到 GPU 内存泄露。我们需要为非生成类模型服务做生命周期与显存回收 smoke。

### SGLang

- [SGLang v0.5.20](https://github.com/sgl-project/sglang/releases/tag/v0.5.20) — release note 显示 713 PR、237 contributors，并新增 GLM-5.3-Flash 等模型支持。
  - 启示:SGLang 的迭代速度已经足以影响 runtime 选型。产品层应支持多 serving engine 并行，而不是把 vLLM 固化成唯一后端。
- [SGLang PR #40640](https://github.com/sgl-project/sglang/pull/40640) — 修复 Kimi K3 在 B300 上 CUDA graph stream explosion。
  - 启示:Blackwell/B300 级硬件会暴露 CUDA graph/attention replay 的新问题。新 GPU 节点上线前要有目标模型压测，而不是只跑 synthetic benchmark。
- [SGLang PR #38875](https://github.com/sgl-project/sglang/pull/38875)、[#39338](https://github.com/sgl-project/sglang/pull/39338)、[#39775](https://github.com/sgl-project/sglang/pull/39775) — ROCm 上 QSA MQA decode、zero-RoPE MHA prefill、MoE grouped topk JIT kernel 修复。
  - 启示:AMD 后端适配正在细到模型结构和 kernel 路径。我们支持 AMD 时要把“可启动”和“关键模型性能路径正确”分开验收。
- [SGLang PR #40371](https://github.com/sgl-project/sglang/pull/40371) — Ascend NPU 上 Qwen3-VL 变长 prompt/image length 避免 M-RoPE 重复编译。
  - 启示:多模态 + NPU 的动态 shape 会把 JIT 编译成本暴露给用户。NPU runtime 需要编译缓存、shape bucket 和冷启动指标。
- [SGLang PR #37507](https://github.com/sgl-project/sglang/pull/37507) — 为 unified-memory GDN、sliding-window、tri-pool、MLA 配置启用 hierarchical HiCache。
  - 启示:分层 cache 将成为大模型 serving 的核心能力。我们需要把 HBM/DRAM/CPU/offload 的容量、命中率和迁移成本纳入产品观测。
- [SGLang PR #40603](https://github.com/sgl-project/sglang/pull/40603) — router circuit-breaker 半开探测被取消时释放 probe。
  - 启示:推理路由器的熔断/探活状态是服务可靠性核心。Gateway 层必须能观测 worker 被熔断、恢复和半开探测失败的原因。

### TensorRT-LLM / TGI / Ollama

- [TensorRT-LLM v1.3.0rc27](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc27) — release note 列出 GPT-OSS Eagle3 speculative decoding、Triton MoE backend 等已知问题。
  - 启示:NVIDIA 高性能栈的 rc 版本也会明确限制 speculative/MoE 场景。企业平台应把 TensorRT-LLM 标记为“按模型/后端灰度”，不要直接替换通用 runtime。
- [TensorRT-LLM PR #19366](https://github.com/NVIDIA/TensorRT-LLM/pull/19366) — KV cache v2 context chunk budget 不足时避免 prefix probe。
  - 启示:prefix-aware scheduling 自身也会有额外开销。我们做 prefix cache 或 KV reuse 时要监控“探测成本”而不是只看命中率。
- [TensorRT-LLM PR #19458](https://github.com/NVIDIA/TensorRT-LLM/pull/19458) — 校验 media data URI，并将 private URL fetch 放到 opt-in 后。
  - 启示:多模态推理入口存在 SSRF/私网访问风险。MaaS 网关必须默认禁止私有 URL 拉取，或通过显式策略与审计放行。
- [Ollama v0.34.2](https://github.com/ollama/ollama/releases/tag/v0.34.2) / [v0.34.3-rc1](https://github.com/ollama/ollama/releases/tag/v0.34.3-rc1) — 增加首次运行 setup、桌面 app 深链和模型 thinking controls/default 展示。
  - 启示:Ollama 持续把本地/边缘体验做轻。企业平台可以借鉴“模型能力声明”展示，但集群 serving 仍要回到权限、计量和多租户治理。

## 模型服务 & 编排

### KServe 上游

- [KServe PR #6254](https://github.com/kserve/kserve/pull/6254) — manifest download 失败时直接 fail，而不是把 HTTP 错误体写成损坏 CRD；涉及 Gateway API Inference Extension 和 llm-d-router CRD 下载。
  - 启示:模型服务构建链路已经依赖多个上游 CRD release。离线/内网构建必须校验下载内容和 checksum，不能把“下载失败”变成后续隐蔽部署故障。

### Ray

- [Ray PR #65487](https://github.com/ray-project/ray/pull/65487) — 增加 job-level 配置启用/禁用 lineage reconstruction。
  - 启示:自动 lineage reconstruction 提升容错但有开销。训练/数据作业平台应允许按作业选择恢复策略，而不是全局开关。
- [Ray PR #66136](https://github.com/ray-project/ray/pull/66136) — Ray Data lineage tracking 支持 fan-in。
  - 启示:复杂数据流水线的容错需要理解 fan-in/fan-out DAG。我们做数据预处理/训练 pipeline 时，应把 lineage 和 checkpoint 成本纳入调度。
- [Ray PR #66001](https://github.com/ray-project/ray/pull/66001) 与 [#66002](https://github.com/ray-project/ray/pull/66002) — autoscaling coordinator 按节点跟踪 reservation，并让 Train V2 workers 绑定到 reservation。
  - 启示:训练任务容量预留必须落到具体节点，否则并发任务会争用同一“理论容量”。这与 Kueue/Cluster Autoscaler 的联动高度相关。
- [Ray PR #66268](https://github.com/ray-project/ray/pull/66268) — 修复多租户 placement check 误判。
  - 启示:多租户隔离在 Ray Data/Train 中不仅是 namespace，任务放置和资源标签检查也要准确。

## 训练 & 微调

- 本轮 Kubeflow Training Operator 未筛出重大 release；训练侧更值得看 Ray Train reservation、Kueue SparkApplication 资源预留修复以及 SGLang/vLLM 的 adapter/spec decode runtime 能力。

## 模型生命周期(MLflow / Registry / Feast)

- [MLflow v3.16.1](https://github.com/mlflow/mlflow/releases/tag/v3.16.1) — patch release 移除 `basic_auth.ini` 中默认 basic-auth admin password，并增加 evaluation timeout。
  - 启示:MLOps 组件默认密码会直接变成供应链/交付风险。我们打包 MLflow/registry/tracking 服务时必须保证默认凭据不可用或强制初始化。
- [Kubeflow Model Registry v0.3.17](https://github.com/kubeflow/hub/releases/tag/v0.3.17) — 上游 model registry 仍标记为 Alpha。
  - 启示:Model Registry API 还在早期阶段。企业产品要在上游兼容和自有稳定 API 之间加适配层，避免直接暴露不稳定语义给用户。

## LLM 评估 & 安全

- [TensorRT-LLM PR #19458](https://github.com/NVIDIA/TensorRT-LLM/pull/19458) 对多模态 media URL 做 opt-in 限制，是本周最直接的 LLM serving 安全信号。
  - 启示:评估/安全不只在 prompt guardrail，也在输入媒体拉取、URL 访问、tokenizer、runtime sandbox 等基础路径。

## 值得跟进
- [ ] 给 vLLM 长 prefill、MTP KV grouping、GLM sparse MLA、pooling GPU memory release 建 runtime smoke。
- [ ] 对 SGLang v0.5.20 做 ROCm/NPU/HiCache/Router circuit-breaker 能力评估，确认哪些能纳入多引擎 catalog。
- [ ] 将 TensorRT-LLM media URL opt-in 作为 MaaS 网关 SSRF 默认策略参考。
- [ ] 把 Ray Train reservation per node 与 Kueue quota/admission、Cluster Autoscaler 节点扩缩容做一轮端到端验证。
- [ ] 对 KServe 构建链路增加 CRD 下载 checksum/fail-fast，覆盖 llm-d-router 和 Gateway API Inference Extension。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://github.com/sgl-project/sglang/releases/tag/v0.5.20
- https://github.com/sgl-project/sglang/pull/40640
- https://github.com/sgl-project/sglang/pull/38875
- https://github.com/sgl-project/sglang/pull/39338
- https://github.com/sgl-project/sglang/pull/39775
- https://github.com/sgl-project/sglang/pull/40371
- https://github.com/sgl-project/sglang/pull/37507
- https://github.com/sgl-project/sglang/pull/40603
- https://github.com/vllm-project/vllm/pull/57951
- https://github.com/vllm-project/vllm/pull/55390
- https://github.com/vllm-project/vllm/pull/57458
- https://github.com/vllm-project/vllm/pull/57737
- https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc27
- https://github.com/NVIDIA/TensorRT-LLM/pull/19366
- https://github.com/NVIDIA/TensorRT-LLM/pull/19458
- https://github.com/ollama/ollama/releases/tag/v0.34.2
- https://github.com/ollama/ollama/releases/tag/v0.34.3-rc1
- https://github.com/kserve/kserve/pull/6254
- https://github.com/ray-project/ray/pull/65487
- https://github.com/ray-project/ray/pull/66136
- https://github.com/ray-project/ray/pull/66001
- https://github.com/ray-project/ray/pull/66002
- https://github.com/ray-project/ray/pull/66268
- https://github.com/mlflow/mlflow/releases/tag/v3.16.1
- https://github.com/kubeflow/hub/releases/tag/v0.3.17
- 备注:本轮 GitHub token 失效，按匿名 API 抓取。
</details>
