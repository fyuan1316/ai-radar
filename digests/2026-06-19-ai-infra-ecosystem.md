# AI 推理 & MLOps 生态周报 2026-06-19

> 覆盖区间:2026-06-12 ~ 2026-06-19。只筛对"做云原生 AI 基础设施产品(对标 OAI)"有用的变化,版本 bump/CI/dependabot 噪音已剔除。

## 摘要(5 条以内)

1. **KServe v0.19.0 发布,LLMInferenceService(llmisvc)成为本次绝对主线**——异构 GPU 负载均衡、llm-d v0.6 升级迁移逻辑、LocalModelCache 接入 llmisvc、Standard 模式 REST/gRPC 双协议路由、status 里回填"观测到的路由拓扑/工作负载引用"。这是与我们产品最直接对标的一周。 https://github.com/kserve/kserve/releases/tag/v0.19.0
2. **DeepSeek-V4 支持竞赛全面铺开**:vLLM(v0.23.0)、SGLang(v0.5.13)、TensorRT-LLM 三家本周都在为 DSv4 做稀疏注意力/上下文并行/MoE 内核硬化——新一代 MoE+稀疏注意力模型正在成为推理栈的"必答题"。
3. **PD 分离(Prefill/Decode disaggregation)+ KV 感知路由从论文走向产品**:Ray Serve 落地 KVAwareRouter 接口与 MoRIIO KV-connector,SGLang 做异构 CPU+GPU EPD 分离(联合 Intel),KServe llmisvc 用 sha256_cbor 做精确前缀 KV 路由。
4. **MLflow 3.14.0 把重心彻底压到 GenAI 可观测性**:`mlflow agent setup` 一条命令给 Claude Code/Codex/OpenCode 装链路追踪 + WAL 持久化低延迟 tracing,新增 Trace Review Queues、pytest 回归测试 `@mlflow.test`、LLM Playground。
5. **本周静默**:TGI、substratusai/lingo、kubeflow/training-operator、kubeflow/model-registry、LLaMA-Factory、lm-evaluation-harness、llama-stack 主分支 7 天内无实质提交。

---

## 推理引擎动态

### vLLM — v0.23.0(408 commits / 200 contributors)
- **DeepSeek-V4 大幅硬化**:稀疏 MLA 元数据从 V3.2 解耦、新增 TRTLLM-gen 注意力内核、Mega-MoE 的 EPLB 支持、滑窗 KV 的选择性前缀缓存保留;并从 `torch.compile` 中剥离。
- **Model Runner V2 扩面**:除 Qwen3 外,**Llama / Mistral dense 模型默认走 MRv2**,新增 FlashInfer sampler、可打断 CUDA graph、流水线并行气泡消除。
- **实验性 Rust 前端在成型**:加了流式 `generate`、动态 LoRA 端点、`/version`、`/server_info`、server-router 扩展钩子、多种 tool parser。值得跟踪——这是 vLLM 想把 API 网关层做重的信号。
- 新增 Gemma 4 Unified(encoder-free)与 Gemma 4 MTP。
- 来源:https://github.com/vllm-project/vllm/releases/tag/v0.23.0
- **对我们的启示**:Rust 前端 + server-router 钩子意味着 vLLM 在往"自带路由/网关"方向走,会和我们(以及 KServe/Ray)的服务编排层产生重叠,需评估是集成还是绕开。

### SGLang — v0.5.13
- **Spec V2 成为默认投机解码路径**:tree drafting(topk>1)在 triton/FA3/MLA/aiter 全后端生产可用,Spec V1 弃用,EAGLE/MTP 统一到 V2 worker。
- **DeepSeek-V4**:上下文并行 + MTP、非 DeepEP 的 CP+fused MoE 内核、稀疏 FlashMLA、FP4 indexer、SM120。
- **异构 CPU+GPU EPD 分离(联合 Intel)**:把 VLM 视觉编码 offload 到 Xeon CPU,负载下 P99 TTFT/吞吐约 +1.3x。
- **HiCache 对混合模型(SWA/Mamba)默认开启**,分层 KV 缓存 offload 开箱即用。
- 来源:https://github.com/sgl-project/sglang/releases/tag/v0.5.13
- **启示**:"把部分阶段卸到 CPU"的异构分离思路,对降本(尤其多模态)有参考价值;HiCache 默认化提示分层 KV offload 正在标准化。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**(无 release,实质 commit):MiniMax-M3 PyTorch 后端引入(**含 breaking API 改动**)、DSv4 attention 算子铺路、MegaMoE CuteDSL NVFP4 MoE 后端、`prefetch_reuse_blocks` + 可配置预取数、SM120/SM121 的 skip-softmax warp-specialized FMHA。整体仍是 PyTorch 后端持续吸纳新模型/新硬件。源:https://github.com/NVIDIA/TensorRT-LLM/commits/main
- **TGI**:本周主分支无实质提交,**无重大更新**。
- **Ollama**(v0.30.8→v0.30.10):MLX 引擎扩面(Command A / North 系列上 Apple Silicon)、Cohere2Moe 架构支持、**prompt caching 与 context shift 解耦以提升 KV 复用**、`ollama launch claude` 修复。边缘/桌面侧仍在补 MLX 与编码 agent 接入。源:https://github.com/ollama/ollama/releases/tag/v0.30.10

## 模型服务 & 编排

### KServe 上游 — v0.19.0(本周重点)
LLMInferenceService(llmisvc)是本次发布的绝对核心,挑产品相关的:
- **异构 GPU 负载均衡 sample**(`feat(llmisvc): add heterogeneous GPUs load balancing sample`,#5374)——多型号 GPU 混部调度,正是企业级痛点。
- **llm-d v0.6 组件升级迁移逻辑**(#5433):KServe 与 llm-d 的绑定在加深。
- **LocalModelCache 支持 LLMInferenceService**(#5318):本地模型缓存接入 LLM 服务,缩短冷启动/拉模型时间。
- **Standard 模式双协议(REST/gRPC)路由**(#5451)。
- **status 可观测性增强**:回填观测到的路由拓扑(#5417)、工作负载引用(#5414),readiness 变更发 k8s event(#5437),新增 `ConfigNotFound` 专门 condition(#5409)。
- 精确前缀 KV 缓存路由改用 `sha256_cbor`(#5484);Envoy AI Gateway 升 v0.6.0 / Envoy Gateway v1.7.0(#5520)。
- 来源:https://github.com/kserve/kserve/releases/tag/v0.19.0
- **启示**:KServe 正把 llmisvc 做成"声明式 LLM 服务 + llm-d 数据面 + 网关"的整套,且大量精力花在 status 可观测性和异构调度上。这与我们产品高度同赛道,建议逐条对照 llmisvc 的 CRD 字段与我们的差距,尤其是异构 GPU 调度和 status 拓扑回填。

### Ray — Serve LLM(无 release,实质 commit)
- **KV 感知路由接口**(`[llm][kv][1/N] Add KV-aware routing interfaces (KVAwareRouter + KVRouterActor)`,#64084)——Ray Serve 开始把 KV 命中纳入路由决策,与 KServe 的前缀路由是同一方向。
- **MoRIIO KV-connector 后端用于 prefill/decode**(#63951)+ 跨节点经 vLLM 插件广播 worker 内网 IP(#64067):PD 分离的数据面在 Ray 侧落地。
- 预填充-解码分离里避免重复 prompt 分词(#64049);升级到 vllm 0.23.0(#64082);**移除 Serve LLM config generator**(#64075,接口在收敛)。
- 默认 HAProxy 二进制改为 ray-haproxy(#64163/#64141)。
- 来源:https://github.com/ray-project/ray/commits/master
- **启示**:KV 感知路由 + PD 分离正在 Ray、KServe、SGLang 三处并行成熟,这应是我们路由/调度层下一步的重点能力。

### substratusai/lingo
本周无提交,**无重大更新**。

## 训练 & 微调
- **kubeflow/training-operator**:主分支 7 天内无实质提交,**无重大更新**。
- **hiyouga/LLaMA-Factory**:同上,**无重大更新**。

## 模型生命周期(MLflow / Registry / Feast)

### MLflow — v3.14.0
全面 GenAI 化,挑相关的:
- **`mlflow agent setup` 一条命令完成 agent 接入**:装 MLflow + 配 tracing,并把 MLflow skills 交给 Claude Code / OpenAI Codex / OpenCode。
- **面向 Claude Code 的持久化低延迟 tracing**:用 WAL 保证不拖慢 agent、不在网络抖动/崩溃时丢 trace。
- **Trace Review Queues**:把 trace 派给评审人/agent,结构化反馈与 ground-truth 标注直接写回 trace,可立即用于评估。
- **pytest 回归测试**:`@mlflow.test` 标记把 GenAI 回归测试写成普通 pytest,在 CI 里 gate。
- **LLM Playground**:浏览器里对着 AI Gateway 端点 + Prompt Registry 调 prompt。
- 内置规则打分器:`RegexMatch` / `PIIDetection` / `ResponseLength`;OTLP trace 摄取支持 `x-mlflow-run-id`。
- **Breaking**:sklearn 默认序列化 `cloudpickle`→`skops`,pytorch→`pt2`,lightgbm→`skops`。
- 来源:https://github.com/mlflow/mlflow/releases/tag/v3.14.0
- **启示**:MLflow 把自己重定位成"GenAI/agent 可观测性 + 评估平台",而非传统实验追踪。我们若提供模型/应用全生命周期,需要考虑 trace/eval/review 这条线,以及与 OTLP 的对接。

### kubeflow/model-registry
本周主分支无实质提交,**无重大更新**。

### Feast — v0.64.0
偏维护,但有两条架构/安全相关值得记:
- **Registry RBAC 收紧**:移除 registry proto dump,给 Commit/Refresh RPC 加权限校验(#328431f)。
- **Operator**:registry gRPC Service 设 `appProtocol: grpc`(#6367);用 migration Job 做升级安全的 selector 唯一性(替换打 patch 的旧做法)。
- Milvus VARCHAR `max_length` 可配(去掉硬编码 512);RemoteOnlineStore 单 HTTP 请求发全部特征。
- 来源:https://github.com/feast-dev/feast/releases/tag/v0.64.0

## LLM 评估 & 安全

- **EleutherAI/lm-evaluation-harness**:本周无提交,**无重大更新**。
- **NVIDIA/garak**:新增 simple adaptive attacks probe(#1742);**安全修复**——在容器内解析符号链接安装路径时的 data_path 逃逸防护(#1860),以及在多进程 pickle 前先捕获 OpenAI AuthenticationError(#1859)。源:https://github.com/NVIDIA/garak/commits/main
- **meta-llama/llama-stack**:本周主分支无实质提交,**无重大更新**。

## 值得跟进
- [ ] **逐条对照 KServe llmisvc 的能力**(异构 GPU 负载均衡、LocalModelCache、双协议路由、status 拓扑回填)与我方产品差距;评估是否跟进 llm-d v0.6。 https://github.com/kserve/kserve/releases/tag/v0.19.0
- [ ] **PD 分离 + KV 感知路由**作为路由/调度层专题:对比 KServe 前缀路由、Ray KVAwareRouter+MoRIIO、SGLang EPD 三家实现。 https://github.com/ray-project/ray/pull/64084
- [ ] **评估 MLflow 3.14 的 GenAI tracing/eval/review 线**是否值得集成进我们的模型生命周期(尤其 OTLP `x-mlflow-run-id` 摄取与 review queue)。 https://github.com/mlflow/mlflow/releases/tag/v3.14.0
- [ ] **DeepSeek-V4 部署就绪度**:vLLM/SGLang/TRT-LLM 三家 DSv4 路径各自的硬件/并行要求,确认我们平台默认推理运行时能否承接。
- [ ] 关注 **vLLM Rust 前端 + server-router 钩子**演进,判断与我方网关/路由层是冲突还是可复用。 https://github.com/vllm-project/vllm/releases/tag/v0.23.0
