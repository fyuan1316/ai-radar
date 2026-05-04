# AI 推理 & MLOps 生态周报 2026-05-04

窗口:2026-04-27 → 2026-05-04(7 天)

## 摘要(5 条以内)
- vLLM v0.20.0(2026-04-27)是大节点:DeepSeek V4 初步支持、CUDA 13.0 + PyTorch 2.11 默认、FlashAttention 4 重做 MLA prefill 默认后端、TurboQuant 2-bit KV cache(4× 容量)、新增 vLLM IR 与 Online Quantization 前端
- KServe v0.18.0(2026-04-29)上游主线发布,llmisvc 是核心:升 llm-d 0.6、加 WVA + KEDA/HPA 自动扩缩、加 storage migration、双协议(REST/gRPC)路由、加 GIE CRD 进 bundle、Gateway 自动迁移到 v1 InferencePool
- meta-llama/llama-stack 改名 **ogx-ai/ogx**,2026-05-01 发布 v0.8.0:新增原生 Anthropic Messages API(/v1/messages)、移除已废弃的 Eval API(breaking);substratusai/lingo 改名 **kubeai-project/kubeai**(本周无新版)
- containerd 端 / 运行时层之外,kubebuilder + controller-runtime + kyverno + calico 集体对齐 k8s 1.36(详见 k8s-core digest);AI 侧的 garak v0.15.0 加入 NeMoGuardrails generator 与 Agent Breaker probe,MLOps 评测开始覆盖 agent
- feast v0.63.0、TRT-LLM v1.3.0rc13(初步 Nemotron 3 Nano Omni、DeepSeek-V3.2 性能优化、AMD ROCm 集成 9/N)、ollama v0.22-0.23 集成 Claude Desktop / Claude Code / Claude Cowork — 工具链向"agent + 多模态 + 端侧"全面延展

## 推理引擎动态

### vLLM
- [v0.20.0](https://github.com/vllm-project/vllm/releases/tag/v0.20.0) — 752 commits / 320 contributors
- 关键能力(对产品决策有影响的):
  - **环境基线变化(breaking)**:CUDA 13.0 默认、PyTorch 2.11 升级、Python 3.14 支持、HuggingFace transformers v5 兼容
  - **DeepSeek V4 初步支持**(#40860)+ DeepSeek V3.2 多个修复
  - **FlashAttention 4 默认 MLA prefill**(#38819)+ 头维 512 + paged-KV(SM90+)
  - **TurboQuant 2-bit KV cache**(#38479)— 4× 容量,FA3/FA4 prefill 已支持
  - **Online Quantization 前端**(#38138 + 文档 #39736)— end-to-end 在线量化路径,MXFP8 / experts_int8 整合进来
  - **vLLM IR 雏形**(#33825)— 自有 IR 层,为 OOT 平台和 kernel 工作铺路
  - **Model Runner V2** 多项进步:Eagle prefill full-CUDA-graph、CUDA graph 自动决策、stale draft token 准确度回归修复(#39833)、prefill warmup 覆盖
  - 启示:CUDA 13 + torch 2.11 是必须跟的环境基线;TurboQuant 2-bit KV 对长上下文 / 多租户 KV 容量是直接收益,值得在 staging 测;vLLM IR 出现意味着 vLLM 在为"非 NVIDIA 后端"做长期架构投资,与 vLLM-XPU、vLLM-Ascend 适配关系将长期化

### SGLang
- 本窗口无新 release(最近 v0.5.6.post5 在 2026-04-15 早于窗口)
- 272 个 PR 大部分是 internal refactor:
  - DeepSeek V4 同步支持(#24337 等系列 "amd/deepseek_v4 integration N/M")
  - 增量 hybrid-SWA layers 抽取(#24334)
  - mega-moe 分层抽取(#24301)
  - sgl-deep-gemm wheel 发布工作流(#24348)
- 启示:SGLang 路线开始把 "kernel/IR/mega-moe" 做成可分发组件;DeepSeek V4 与 vLLM 同周到位,DSv4 已成新的"模型必跟"基线

### TensorRT-LLM
- [v1.3.0rc13](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc13) — 大量优化
- Nemotron 3 Nano Omni 初步支持 + 视频音频提取 + ViT attention 优化(#12921 等)
- DeepSeek-V3.2 / V3-Lite chunked-prefill 修复(#13142、#13257)
- VisualGen Cache-DiT + 统一 cache accelerator(#12548)
- 稀疏 MQA / GQA 与新 sharding infra(#12470 / #12419)
- 启示:TRT-LLM 在多模态(VisualGen / audio-from-video)和 SM100/Blackwell 持续深挖;若选 NVIDIA 闭源栈,Nemotron Nano 是当前 Omni 模型基线

### 其它
- [ollama v0.23.0](https://github.com/ollama/ollama/releases/tag/v0.23.0) — `ollama launch claude-desktop` 直接拉起 Claude Desktop / Claude Code / Claude Cowork;`v0.22.0` 加入 NVIDIA Nemotron 3 Omni 与 Poolside Laguna XS.2
  - 启示:ollama 已经把"装个本地模型 = 桌面 / IDE 一体化"做成产品化;从 dev / inner-loop 视角值得跟,但与企业 K8s 服务路线无直接对接
- TGI 本窗口无新版

## 模型服务 & 编排

### KServe(上游)
- [v0.18.0](https://github.com/kserve/kserve/releases/tag/v0.18.0) — 2026-04-29
- llmisvc 路线的核心改动:
  - [#5121 升级 llm-d 到 0.6](https://github.com/kserve/kserve/pull/5121) — llm-d 路由层主线推进
  - [#5194 自动扩缩:WVA + KEDA/HPA 集成](https://github.com/kserve/kserve/pull/5194) — Worker Vertical Autoscaler 与 KEDA 同框集成
  - [#5149 LLMinferenceService API 加 storage migration](https://github.com/kserve/kserve/pull/5149) — API 演进的 storage 迁移
  - [#5451 双协议(REST/gRPC)路由 in Standard mode](https://github.com/kserve/kserve/pull/5451)
  - [#5214 GIE CRD 打包进 KServe bundle](https://github.com/kserve/kserve/pull/5214) — Gateway Inference Extension(GIE)默认进来
  - [#5041 自动检测 Gateway 迁移到 v1 InferencePool](https://github.com/kserve/kserve/pull/5041)
  - [#5202 同时评估两个 InferencePool 的 readiness](https://github.com/kserve/kserve/pull/5202)
  - [#5249 LLMInferenceServiceConfig + TLS flag](https://github.com/kserve/kserve/pull/5249)
  - [#5260 Scheduler TLS 证书热加载](https://github.com/kserve/kserve/pull/5260)
  - [#5264 vllm-cpu 镜像替换为上游构建](https://github.com/kserve/kserve/pull/5264)
- modelcache:
  - [#4887 Namespace Scoped ModelCache](https://github.com/kserve/kserve/pull/4887)
  - [#5262 namespace-scoped 下载 job 在 jobNamespace 跑](https://github.com/kserve/kserve/pull/5262)
- 启示:KServe v0.18 是"llmisvc + InferencePool + GIE + WVA + KEDA"完整闭环的版本;我们若 fork KServe 做产品,这一版是要重点对齐的基线;ModelCache namespace 化 + GIE 默认捆绑是企业部署的关键改进

### Ray
- 本窗口无新 release;85 个 PR 多在 Data / Train 内部:
  - [#63089 Logical operator apply transform 去重](https://github.com/ray-project/ray/pull/63089)
  - [#63066 HashAggregate AggregateFnV2 重复 group rows 修复](https://github.com/ray-project/ray/pull/63066)
  - [#63054 Resource isolation cgroup 约束对齐](https://github.com/ray-project/ray/pull/63054)
  - [#63029 / #63028 Serve 控制器 benchmark / LongPoll 日志改进](https://github.com/ray-project/ray/pull/63029)
- 启示:Ray Serve 仍持续优化路由层细节,但本周无重大产品级 feature

### KubeAI(原 substratusai/lingo)
- 仓库改名为 `kubeai-project/kubeai`,本窗口无新 release(最近 v0.23.2 在 2026-03-31)
- 启示:轻量 K8s LLM 服务方案在重整品牌,值得列入"轻量竞品"长跟

## 训练 & 微调
- **Kubeflow 重大重组**:
  - `kubeflow/training-operator` 仓库**重定向到 `kubeflow/trainer`**(本仓 v2.2.0 在 2026-03-20),意味着 Training Operator → Trainer 的品牌迁移已完成
  - `kubeflow/model-registry` 仓库**重定向到 `kubeflow/hub`**,Kubeflow 的 model registry 进一步整合为 Hub
  - 启示:Kubeflow 在做品牌简化,把 training-operator/model-registry 这种"组件名"重命名为更产品化的 trainer / hub。我们若引用上游文档,链接需要更新;OAI 端的 fork 暂时仍按旧名(opendatahub-io/model-registry 仍在,通过 sync PR 跟 kubeflow:main 同步)
- kubeflow/trainer 本窗口主要是 dependabot bumps(transformers / huggingface-hub / bitsandbytes 等),无重大 feature
- LLaMA-Factory 本窗口无 merged PR(无活跃)

## 模型生命周期(MLflow / Hub / Feast)
- [mlflow v3.12.0rc0](https://github.com/mlflow/mlflow/releases/tag/v3.12.0rc0) — RC 版本,主要内容是"per-provider 模型目录文件,CI 周更"
- [feast v0.63.0](https://github.com/feast-dev/feast/releases/tag/v0.63.0) — 2026-05-04 当天发布
  - [#6357 BatchFeatureView Spark compute-on-read 支持](https://github.com/feast-dev/feast/pull/6357)
  - [#6363 加入 Cursor / Claude rules 与 Feast 开发 agent skills](https://github.com/feast-dev/feast/pull/6363) — Feast 也内嵌 agent skills
  - [#6322 apply/delete data source 加 project filter](https://github.com/feast-dev/feast/issues/6322)
  - 启示:feast 在做多 project 隔离打磨;agent skills 进 feast 是行业大趋势(连 Kueue 这周都加了)— 我们的 ops 工具如果要被 agent 调用,需要预先准备好"agent skills"清单
- **kubeflow/hub(原 model-registry)** — v0.3.8(2026-04-03)是当前最新,本周仅 build/dep bumps + #2644 抽 internal/platform 共享层

## LLM 评估 & 安全
- [garak v0.15.0](https://github.com/NVIDIA/garak/releases/tag/v0.15.0) — 多项新能力
  - 新 probes:Multi-turn GOAT、Agent Breaker(测试目标系统的 tool 暴露)、System prompt extraction、homoglyph obfuscation smuggling
  - 新 detectors:ModernBERT refusal detector
  - 新 generators:NeMoGuardrails server 支持、reasoning traces test generator
  - REST generator 加 mTLS;Bedrock generator 支持 reasoning models
  - 启示:Garak 这一版核心在"评测 LLM agent 而非单 prompt 模型",Agent Breaker 直接对 tool 攻击面做红队测试,这与 OAI 这周的 NemoGuardrails / MCP 集成是同一个安全栈;若我们做 LLM 服务,要把 garak 加入 CI 测试矩阵
- [lm-evaluation-harness](https://github.com/EleutherAI/lm-evaluation-harness):
  - [#3733 加 Trackio logger 与 per-sample Trace 日志](https://github.com/EleutherAI/lm-evaluation-harness/pull/3733)
  - 多个 vLLM / IFEval / GPQA fix
- **ogx-ai/ogx(原 meta-llama/llama-stack)** [v0.8.0](https://github.com/ogx-ai/ogx/releases/tag/v0.8.0) — 2026-05-01
  - **新增原生 Anthropic Messages API**(`/v1/messages`,#5386)
  - **breaking: 移除已废弃的 Eval API + 相关 API**(#5290)— 评估能力外迁
  - vector_io 修复:default_search_mode 配置生效、sqlite-vec BM25 score 反转
  - 客户端从 `llama-stack-client` 迁到 `ogx-client`
  - 启示:Meta 把"llama-stack"重塑为"ogx",不再绑定 Llama 模型,定位转向"通用 LLM 应用栈";同时 OpenAI / Anthropic 双协议都进来了。这条路线与 OAI 的 LlamaStackDistribution 直接相关 — OAI 的 LlamaStack 这一称呼在上游已不复存在,后续 OAI 是否同步改名值得跟

## 值得跟进
- [ ] 升级 vLLM 到 v0.20.0:CUDA 13 / torch 2.11 是 breaking,我们镜像基线要同步;TurboQuant 2-bit KV 跑实测看长上下文场景收益
- [ ] 读 KServe v0.18.0 的 llmisvc + WVA + KEDA 集成代码(#5194 + #5249);评估 InferencePool v1 自动迁移路径(#5041)
- [ ] llama-stack → ogx 改名:看 OAI gen-ai 包是否计划同步切到 ogx-client;若我们用 LlamaStack,要规划 client 迁移
- [ ] 把 garak v0.15.0 的 Agent Breaker probe 接入我们 LLM 服务红队测试
- [ ] 评估 feast v0.63.0 的 BatchFeatureView Spark compute-on-read,看是否替换我们现有 feature pipeline
- [ ] kubeflow/training-operator → kubeflow/trainer 的迁移 — 我们文档中如有链接要更新

## 原始材料

<details>
<summary>本窗口内 release</summary>

- vllm v0.20.0(2026-04-27)
- ollama v0.22.0 / 0.22.1(2026-04-28)/ 0.23.0(2026-05-03)
- mlflow v3.12.0rc0(2026-04-28)
- KServe v0.18.0(2026-04-29)
- TRT-LLM v1.3.0rc13(2026-04-29)
- kyverno(在 k8s-core)/ calico / containerd / etc
- garak v0.15.0(2026-05-01)
- ogx-ai/ogx v0.8.0(2026-05-01)
- feast v0.63.0(2026-05-04)
</details>

<details>
<summary>本窗口 PR 计数</summary>

- sglang 272 / vllm 184 / TRT-LLM 133 / ray 85 / mlflow 59 / ogx 38 / feast 27 / garak 17 / lm-eval 19 / kserve 11 / hub 18 / trainer 18 / kubeai 0
- 仓库改名:meta-llama/llama-stack → ogx-ai/ogx;substratusai/lingo → kubeai-project/kubeai;kubeflow/training-operator → kubeflow/trainer;kubeflow/model-registry → kubeflow/hub
</details>
