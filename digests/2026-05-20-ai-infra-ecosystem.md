# AI 推理 & MLOps 生态周报 2026-05-20

窗口:2026-05-13 → 2026-05-20(7 天)

## 摘要(5 条以内)
- vLLM [v0.21.0](https://github.com/vllm-project/vllm/releases/tag/v0.21.0)(2026-05-15)发布,367 commits / 202 contributors。两条 breaking:transformers v4 废弃 + C++20 编译要求;关键能力:KV Offload 与 Hybrid Memory Allocator 整合、推理性 thinking-budget 投机解码、Blackwell 上的 TOKENSPEED_MLA 后端、NVFP4 KV cache 与 AsyncTP all-gather GEMM 融合、DeepSeek V4 ROCm + PP + disagg 完整化
- SGLang [v0.5.12](https://github.com/sgl-project/sglang/releases/tag/v0.5.12)(2026-05-16)与 vLLM v0.21 同周到位,DeepSeek V4 全栈(TP/EP/CP/DP attention、Blackwell+MI35X、PD 拆分、HiSparse KV 卸载到 CPU)+ TokenSpeed MLA(同名,FP8 KV)+ HiCache UnifiedRadixTree + Spec V2 成熟化;统一镜像 tag `lmsysorg/sglang:v0.5.12` 覆盖所有 NV GPU
- **ogx-ai/ogx 跳 v1.0.0**(2026-05-12 主版本 + 13/14 两次 hotfix),原 meta-llama/llama-stack 的"通用 LLM 应用栈"进入 GA;最大变更是 MaaS 多租户核心(#5756 +!)、AuthorizedSqlStore 强制(#5776 +!)、Safety API → moderation_endpoint(breaking)、`/v1/tools` 移到 `/v1/admin/tools`、ogx-api 包面稳定化、gateway-first 架构、letsgo 加 Claude Code / Gemini / Azure
- KServe v0.18.0 后没有新 release,但 17 个 PR 全集中在 llmisvc 运营加固:preStop + graceful shutdown(#5485)、static LoRA adapter reconciliation(#5317)、status 上报 routing topology / workload refs / ConfigNotFound(#5417/5414/5409)、readiness 事件(#5437)、storage migration 重试窗口扩大(#5405)、access-log 带 vLLM 版本回退(#5507)— v0.18.x 在快速补企业部署细节
- 训练 / 评测 / 微调侧本周冷清:kubeflow/trainer 仅 KEP 与 nightly OSV 扫描;LLaMA-Factory、lm-evaluation-harness、garak、TGI 本窗口无新版且几乎无 PR 活动;feast 无 release 但合入 Registry REST API + MCP 暴露(#6413/6304)— Feature Store 正在把自己挂到 agent / MCP 调用链上

## 推理引擎动态

### vLLM
- [v0.21.0](https://github.com/vllm-project/vllm/releases/tag/v0.21.0) — 2026-05-15
- 重点能力(对产品决策有影响的):
  - **环境基线 breaking**:transformers v4 废弃([#40389](https://github.com/vllm-project/vllm/pull/40389));C++20 编译要求([#40380](https://github.com/vllm-project/vllm/pull/40380));NIXL 连接器升 1.x([#42364](https://github.com/vllm-project/vllm/pull/42364));ROCm 7.2.2([#41386](https://github.com/vllm-project/vllm/pull/41386))
  - **KV Offload + Hybrid Memory Allocator 整合**:scheduler-side sliding window 组([#41228](https://github.com/vllm-project/vllm/pull/41228))、全量 HMA 启用([#41445](https://github.com/vllm-project/vllm/pull/41445))、multi-connector HMA([#39571](https://github.com/vllm-project/vllm/pull/39571))、MooncakeStoreConnector 分布式 KV offload([#40900](https://github.com/vllm-project/vllm/pull/40900))
  - **推理性投机解码 thinking budget**([#34668](https://github.com/vllm-project/vllm/pull/34668))— reasoning 模型与 spec decode 兼容,这是 RLHF / 多步推理服务的关键能力
  - **Blackwell TOKENSPEED_MLA 后端**([#41778](https://github.com/vllm-project/vllm/pull/41778))— DeepSeek R1 / Kimi K2.5 prefill+decode 专用,同名后端在 SGLang v0.5.12 同周上线
  - **NVFP4 KV cache**([#40177](https://github.com/vllm-project/vllm/pull/40177))+ NVFP4 all-gather GEMM AsyncTP 融合([#41882](https://github.com/vllm-project/vllm/pull/41882))
  - **Disaggregated serving 系列**:P/D 双向 KV transfer([#32553](https://github.com/vllm-project/vllm/pull/32553))、NIXL transfer 重设计([#40731](https://github.com/vllm-project/vllm/pull/40731))、NIXL P-node 预入场拒绝通知([#41269](https://github.com/vllm-project/vllm/pull/41269))
  - **Ray Executor V2 默认启用**([#41421](https://github.com/vllm-project/vllm/pull/41421))— Ray 后端从可选转默认
  - **PluggableLayer MoE OOT 接口**([#35178](https://github.com/vllm-project/vllm/pull/35178))— 配合 vLLM IR 给外厂硬件 / 自有 MoE runner 留接入点
  - **LoRA EP 初步支持**([#40867](https://github.com/vllm-project/vllm/pull/40867))
  - Responses API:streaming tool calling 加 `required` / 命名 tool choice([#40700](https://github.com/vllm-project/vllm/pull/40700)、[#41110](https://github.com/vllm-project/vllm/pull/41110))
  - 容器 image 缩小约 2.5GB(延迟下载 FlashInfer cubin,[#41134](https://github.com/vllm-project/vllm/pull/41134))
- 启示:**KV Offload + HMA 是这一版的产品级新能力**,直接影响长上下文 / 多租户的内存模型;若我们的 inference plane 还在自管 KV swap,这一版可以省掉一层;NIXL 1.x + Mooncake 分布式 KV offload 是大规模 P/D 拆分的基础设施。Ray Executor V2 转默认意味着我们若 fork 老的 V1 执行路径,要做好迁移评估

### SGLang
- [v0.5.12](https://github.com/sgl-project/sglang/releases/tag/v0.5.12) — 2026-05-16,385 个合入 PR
- 核心轴:
  - **DeepSeek V4 全栈([#23882](https://github.com/sgl-project/sglang/pull/23882))**:TP/EP/CP/DP attention、NV B300/B200/H200/H100/GB200/GB300 + AMD MI35X、PD 拆分、HiSparse KV 卸载到 CPU、reasoning + tool-call parser、DeepGEMM + FlashMLA(含 MegaMoE)kernel;Day-0 之后还补了 W4A4 MegaMoE 内核([#25052](https://github.com/sgl-project/sglang/pull/25052))、Marlin/FlashInfer W4A8 MoE on Hopper([#24816](https://github.com/sgl-project/sglang/pull/24816)、[#24986](https://github.com/sgl-project/sglang/pull/24986))、TP16 on H100/H20([#24949](https://github.com/sgl-project/sglang/pull/24949))、PP + PD([#24700](https://github.com/sgl-project/sglang/pull/24700))
  - **TokenSpeed MLA attention 后端**([#24925](https://github.com/sgl-project/sglang/pull/24925))— MLA prefill/decode 整合为后端,FP8 KV cache,SM100。与 vLLM 同期同名上线,这条能力线变成"双引擎共识"
  - **HiCache + UnifiedRadixTree**:统一 radix tree 框架支持 HiCache([#23316](https://github.com/sgl-project/sglang/pull/23316))、SWA HiCache([#23391](https://github.com/sgl-project/sglang/pull/23391))、DSv4 HiCache + 夜测([#24691](https://github.com/sgl-project/sglang/pull/24691))、Mooncake SSD offload([#24277](https://github.com/sgl-project/sglang/pull/24277))
  - **Speculative Decoding V2 成熟化**:Adaptive Spec V2([#23336](https://github.com/sgl-project/sglang/pull/23336))、EAGLE-3 + SWA([#24664](https://github.com/sgl-project/sglang/pull/24664))、Kimi K2.5 EAGLE-3 MLA([#24826](https://github.com/sgl-project/sglang/pull/24826))、Gemma 3/4 + EAGLE-3([#23976](https://github.com/sgl-project/sglang/pull/23976))、custom spec-algo registry([#23991](https://github.com/sgl-project/sglang/pull/23991))
  - **PD 拆分继续打磨**:NIXL staging buffer 处理 heterogeneous-TP([#22536](https://github.com/sgl-project/sglang/pull/22536))、NIXL async([#23967](https://github.com/sgl-project/sglang/pull/23967))、Mooncake 增量 + SSD([#24257](https://github.com/sgl-project/sglang/pull/24257))
  - **CUDA 13 DeepEP 迁移**:从社区 fork 切回 `deepseek-ai/DeepEP@hybrid-ep`([#25113](https://github.com/sgl-project/sglang/pull/25113))— DeepEP 上游主线化
  - **统一镜像 tag `lmsysorg/sglang:v0.5.12` 适配所有 NV GPU**(原来不同 GPU 系列要选不同 tag)
  - 新模型:Intern-S2-Preview / MiniCPM-V 4.6 / Laguna XS.2 / Ring-2.6-1T(万亿参 reasoning 模型)/ Gemma 4 MTP
- 启示:DSv4 已成"必跟"基线(KServe llmisvc 端会很快需要对应 modelopt 文档);**TokenSpeed MLA 在 vLLM/SGLang 同周登场**,Blackwell prefill/decode 的低延迟方案进入产品选型期;统一镜像 tag 这种工程细节对 K8s 部署友好——值得 KServe llmisvc 默认 Pod template 跟进

### TensorRT-LLM
- 本窗口无新 release(最近 v1.3.0rc14 在 2026-05-07 早于窗口),但 commit 流量大
- 重点 commit:
  - [#14134 Gemma 4 chunked prefill(text + vision multimodal)](https://github.com/NVIDIA/TensorRT-LLM/pull/14134)
  - [#13401 W4A8_MXFP4_FP8 MoE](https://github.com/NVIDIA/TensorRT-LLM/pull/13401)
  - [#13994 Upgrade transformers 5.5.3](https://github.com/NVIDIA/TensorRT-LLM/pull/13994)
  - [#13977 Nemotron 3 Nano Omni in-flight batching for multimodal encoder](https://github.com/NVIDIA/TensorRT-LLM/pull/13977)
  - [#13689 bf16 trtllm-moe through flashinfer](https://github.com/NVIDIA/TensorRT-LLM/pull/13689) — TRT-LLM 把 flashinfer 路径接进来
  - [#13843 Reduce host overhead during scheduling and sampling](https://github.com/NVIDIA/TensorRT-LLM/pull/13843)
  - [#14061 Early emission of first token with overlap scheduling](https://github.com/NVIDIA/TensorRT-LLM/pull/14061) — TTFT 优化
  - [#13787 AutoDeploy: Onboarding Sprint Part 1](https://github.com/NVIDIA/TensorRT-LLM/pull/13787) — 自动部署模型库继续扩
- 启示:TRT-LLM 多模态 + flashinfer 整合路线持续;若 NVIDIA 栈被选作"闭源高性能侧",Gemma 4 + Nemotron Nano Omni 是当前主线模型基线

### Ollama
- 本窗口未在 GH releases 上 cut tag,但 v0.30.0-rc 系列(rc12 → rc21)在窗口内持续滚动
- 关键 PR:
  - [#16134 mlxrunner: DFlash speculative decoding](https://github.com/ollama/ollama/pull/16134) — MLX/Apple Silicon 上的投机解码
  - [#16122 mlx: rework MLX sampler](https://github.com/ollama/ollama/pull/16122)
  - [#15795 launch: codex model metadata catalog](https://github.com/ollama/ollama/pull/15795)、[#16120 codex app integration](https://github.com/ollama/ollama/pull/16120)、[#16157/16155](https://github.com/ollama/ollama/pull/16157) — Ollama 把 OpenAI Codex 桌面应用接入"launch app"
  - [#16215 Reduce startup model hydration](https://github.com/ollama/ollama/pull/16215)
- 启示:ollama 把 inner-loop 客户端从 Claude Desktop / Code 扩到 Codex,所有主流 coding agent 都能"`ollama launch <app>`"拉起;MLX 投机解码使 Apple Silicon 单机推理性能继续追近 NV — 与企业 K8s 路线无直接对接,但作为"开发者本地基线"要持续盯

### TGI
- 本窗口无新 release(最近 v3.3.7 是 2025-12-19),0 个合入 PR
- 启示:HF TGI 实际进入维护模式,产品对标可不再重点跟

## 模型服务 & 编排

### KServe(上游)
- 本窗口无新 release(v0.18.0 在 2026-04-29),17 个 PR 集中在 llmisvc 运营加固
- llmisvc 健壮性:
  - [#5485 feat(llmisvc): preStop hook + terminationGracePeriod](https://github.com/kserve/kserve/pull/5485) — 优雅退出,生产部署刚需
  - [#5317 feat(llmisvc): static LoRA adapter reconciliation](https://github.com/kserve/kserve/pull/5317) — LoRA adapter 入 reconcile 循环,多 LoRA 服务化的关键能力
  - [#5507 feat(llmisvc): targeted access-log flag with vLLM version fallback](https://github.com/kserve/kserve/pull/5507) — 跨 vLLM 版本兼容的日志开关
- 可观测性:
  - [#5417 status: observed routing topology](https://github.com/kserve/kserve/pull/5417)
  - [#5414 status: observed workload references](https://github.com/kserve/kserve/pull/5414)
  - [#5409 status: surface ConfigNotFound condition](https://github.com/kserve/kserve/pull/5409)
  - [#5437 emit k8s events on llmisvc readiness transitions](https://github.com/kserve/kserve/pull/5437)
- 修复:
  - [#5405 fix: extend storage migration retry window](https://github.com/kserve/kserve/pull/5405) — 配合 v0.18 的 storage migration
  - [#5489 router: off-by-one in splitter pickupRoute random range](https://github.com/kserve/kserve/pull/5489)
  - [#5553 CVE: vllm setup + pillow](https://github.com/kserve/kserve/pull/5553)
  - [#5539 prevent ClusterStorageContainer CRD deletion on helm upgrade](https://github.com/kserve/kserve/pull/5539)
- 启示:v0.18.0 后的 llmisvc 进入"打磨期",**先升 v0.18 站稳,再吃这些 fix**;LoRA reconciliation(#5317)是多租户 / 模型组合服务的能力前提,值得我们对 OAI 端 kserve fork 看是否同步引入;status 上报的 routing topology / workload refs 直接降低运维排障成本,推荐拉到我们的 dashboard

### Ray
- 本窗口无新 release(最近 ray-2.55.1 在 2026-04-22),92 个 PR 多在 Data / Train / Serve 打磨
- 值得看:
  - [#62932 Serve: mark widely-used APIs as stable](https://github.com/ray-project/ray/pull/62932) — Serve API 稳定性标注,有助于产品长期对接
  - [#63510 Removed deprecated DeploymentMode](https://github.com/ray-project/ray/pull/63510) — Serve breaking
  - [#63415 Serve: HAProxy retry knobs for ingress-request-router](https://github.com/ray-project/ray/pull/63415)
  - [#63348 serve: hap grpc perf tuning](https://github.com/ray-project/ray/pull/63348)
  - [#63461 Train: Remove Predictor from train v1](https://github.com/ray-project/ray/pull/63461) — Train v1 API 进一步收缩
  - [#63470 Data: Block pickle object columns when reading untrusted Parquet](https://github.com/ray-project/ray/pull/63470) — 安全加固
- 启示:Ray Serve API 稳定性收敛 + HAProxy 路由配置裸露是 inference router 侧的产品化信号;若使用 Ray Serve 做我们 LLM router,要跟进 DeploymentMode 移除路径

### KubeAI(原 substratusai/lingo)
- 本窗口无新 release(最近 v0.23.2 在 2026-03-31),0 个合入 PR
- 启示:仓库进入低活跃期,作为"轻量竞品"维持观察即可

## 训练 & 微调

- **Kubeflow Trainer**(原 training-operator)— 5 个 PR,均为 KEP/工程基础:
  - [#3428 KEP-2599: Decouple runtime lifecycle from TrainJobs](https://github.com/kubeflow/trainer/pull/3428) — runtime 与 TrainJob 解耦,简化运行时升级
  - [#3417 KEP: inject PET envs into init-container](https://github.com/kubeflow/trainer/pull/3417)
  - [#3514 update k8s to 0.36 for release-2.2](https://github.com/kubeflow/trainer/pull/3514)
  - [#3518 nightly OSV-Scanner workflow](https://github.com/kubeflow/trainer/pull/3518)
  - [#3216 fix(cache): validate cache_index schema collisions](https://github.com/kubeflow/trainer/pull/3216)
- LLaMA-Factory:**本窗口无 commit / 无 PR**
- 启示:Kubeflow 训练侧本周没有产品级新能力,主要是 KEP 阶段;若我们正打算引入 Trainer,KEP-2599 的 runtime 解耦值得提前 review,会影响 trainjob → runtime 的版本管理模型

## 模型生命周期(MLflow / Hub / Feast)

- **MLflow**:本窗口无主版本 release,只有 [`ts/v0.2.0`](https://github.com/mlflow/mlflow/releases/tag/ts/v0.2.0)(Tracing Server / TS npm 包,2026-05-15)
  - [#23464 WAL foundational files for async batch trace export](https://github.com/mlflow/mlflow/pull/23464) — Tracing Server 加 WAL 异步导出
  - [#23293 Security: extend `MLFLOW_ALLOW_PICKLE_DESERIALIZATION` guard to DSPy non-pkl](https://github.com/mlflow/mlflow/pull/23293) — pickle deserialization 攻击面收紧
  - [#23443 Make `mlflow.get_trace` V4 retry policy configurable](https://github.com/mlflow/mlflow/pull/23443)
  - [#23241 Fix UnicodeEncodeError on artifact download with non-ASCII filename](https://github.com/mlflow/mlflow/pull/23241)
  - 启示:Tracing Server 是 MLflow 这一阶段的核心产品轴,WAL 异步导出 + 配置化 retry 都是规模化前提
- **kubeflow/hub**(原 model-registry):[v0.3.9](https://github.com/kubeflow/hub/releases/tag/v0.3.9)(2026-05-04 早于窗口)
  - 本周 PR:
    - [#2687 Add tool calling support to Model catalog](https://github.com/kubeflow/hub/pull/2687) — model catalog 把"模型是否支持 tool calling"作为一阶字段
    - [#2707 Add validated configuration filter section for model catalog](https://github.com/kubeflow/hub/pull/2707)
    - [#2705 docs(catalog): add validatedTasks and servingConfig YAML reference](https://github.com/kubeflow/hub/pull/2705)
  - 启示:Hub 在把"模型 → 适配硬件 / 任务 / 工具能力"做成 catalog 元数据,这是 inference router 选模的基础。若我们要做"按能力路由",这套 schema 值得对齐
- **Feast** 0.63.0(2026-05-04 上次发的),本窗口无 release 但 12 个 PR:
  - [#6413 feat: Registry REST API for entities / data sources / feature views](https://github.com/feast-dev/feast/pull/6413)
  - [#6304 feat: Expose registry endpoints on feature server for MCP access](https://github.com/feast-dev/feast/pull/6304) — Feast Registry 通过 MCP 暴露给 agent
  - [#6415 fix: Replace selector label strip patch with migration Job](https://github.com/feast-dev/feast/pull/6415) — 升级安全的 K8s migration
  - [#6407 fix: Ray source materialization for KubeRay](https://github.com/feast-dev/feast/pull/6407)
  - [#6354 feat: Prometheus gauges for FeatureStore installation telemetry](https://github.com/feast-dev/feast/pull/6354)
  - 启示:Feature Store **通过 MCP 接入 agent 是行业新动作**,与上周 feast 0.63 的 agent skills 是一条线;若我们的 feature 平台要被 agent 调用,提前出 MCP server

## LLM 评估 & 安全

- **garak**:本窗口无 release,6 个 PR 都是杂项修复(tiktoken fallback、AGENTS.md 扩充、litellm proxy 期望更新等),无产品级新能力
- **EleutherAI/lm-evaluation-harness**:[v0.4.12](https://github.com/EleutherAI/lm-evaluation-harness/releases/tag/v0.4.12)(2026-05-11 略早于窗口),**本窗口无 commit / 无 PR**
- **ogx-ai/ogx 跳 GA**(原 meta-llama/llama-stack):
  - [v1.0.0](https://github.com/ogx-ai/ogx/releases/tag/v1.0.0)(2026-05-12)+ [v1.0.1](https://github.com/ogx-ai/ogx/releases/tag/v1.0.1)(2026-05-13)+ [v1.0.2](https://github.com/ogx-ai/ogx/releases/tag/v1.0.2)(2026-05-13)
  - **重大 breaking / 产品级变化**:
    - [#5756 feat!: multi-tenancy core for MaaS deployments](https://github.com/ogx-ai/ogx/pull/5756) — MaaS 部署的多租户核心
    - [#5776 feat(storage)!: enforce AuthorizedSqlStore for APIs requiring access control](https://github.com/ogx-ai/ogx/pull/5776) — 访问控制强制走 AuthorizedSqlStore
    - [#5291 refactor!: remove Safety API and replace with moderation_endpoint](https://github.com/ogx-ai/ogx/pull/5291) — Safety API 切到 moderation,与 OpenAI moderation 对齐
    - [#5744 refactor(api)!: deprecate Safety run-shield and Shields list/get](https://github.com/ogx-ai/ogx/pull/5744)
    - [#5522 feat!: multi-SDK response shapes for /v1/models](https://github.com/ogx-ai/ogx/pull/5522)
    - [#5787 refactor(tools)!: move `/v1/tools` route to `/v1/admin/tools`](https://github.com/ogx-ai/ogx/pull/5787) + [#5659 connectors → `/v1alpha/admin/connectors`](https://github.com/ogx-ai/ogx/pull/5659)
    - [#5740 feat(ogx-api): introduce `ogx_api.provider` and `ogx_api.types` namespaces](https://github.com/ogx-ai/ogx/pull/5740) + [#5719 docs(api): document datatype stability](https://github.com/ogx-ai/ogx/pull/5719) — SDK 稳定性面成型
    - [#5750 refactor(server): gateway-first architecture for edge concerns](https://github.com/ogx-ai/ogx/pull/5750)
    - [#5782 feat(vector_io): tenant isolation for vector store metadata](https://github.com/ogx-ai/ogx/pull/5782)
    - [#5757 feat(connectors,batches)!: migrate KVStore to AuthorizedSqlStore](https://github.com/ogx-ai/ogx/pull/5757)
  - 工具链 / 应用集成:
    - [#5709 feat(letsgo): add Claude Code compatibility](https://github.com/ogx-ai/ogx/pull/5709) + [#5706 letsgo: Gemini + Azure](https://github.com/ogx-ai/ogx/pull/5706) — letsgo 一键启动 Claude Code/Gemini/Azure
    - [#5689 feat(cli): top-level `ogx run` and `ogx letsgo` shortcuts](https://github.com/ogx-ai/ogx/pull/5689)
    - [#5664 perf(responses): batch guardrail checks during streaming](https://github.com/ogx-ai/ogx/pull/5664)
    - [#5739 refactor(storage): replace psycopg2 with asyncpg](https://github.com/ogx-ai/ogx/pull/5739)
  - v1.0.1/1.0.2 是热修(asyncio.Lock、SQLStore engine reset、secret handling、async safety)
  - 启示:**ogx 在做"LLM 应用栈 → MaaS 平台"的定位升级**。多租户 / 鉴权 / admin 路由集中 / asyncpg / gateway-first 都是面向"对外提供模型服务"的能力。这条路线**与 OAI 的 LlamaStackDistribution 直接相关**,且 ogx 已经不再叫 llama-stack——OAI 端若不同步,文档 / API 链将与上游断裂。若我们对 OAI 的"LLM 应用栈"做产品对标,这一版的多租户与 admin 路由是必须吃透的

## 值得跟进
- [ ] 升级 vLLM v0.21:transformers v5 + C++20 是 breaking,镜像基线要同步;重点测 KV Offload + HMA 在我们多租户长上下文场景下的内存收益(#41228/#41445)
- [ ] vLLM v0.21 的 thinking-budget spec decode(#34668)— 我们若做 reasoning 模型服务,正确性回归测试要新加这个轴
- [ ] SGLang v0.5.12 的 TokenSpeed MLA + HiCache UnifiedRadixTree 是与 vLLM 的差异化能力,要在 staging 用 DSv4 对比 vLLM v0.21 跑一轮
- [ ] KServe llmisvc 的 LoRA adapter reconciliation(#5317):评估是否同步引入 OAI fork;先评估多 LoRA 服务化的资源调度模型
- [ ] KServe llmisvc preStop + graceful shutdown(#5485):我们的 inference pod 是否已有等效 hook
- [ ] **ogx v1.0 多租户核心(#5756)+ admin 路由收敛(#5787 / #5659)** — 读代码,评估 OAI LlamaStackDistribution 是否计划同步;若我们正在做 MaaS,这是上游唯一可参考的开源实现
- [ ] Feast Registry MCP 暴露(#6304):如果我们的 feature 平台要被 agent 调用,值得对齐 MCP server schema
- [ ] kubeflow/hub model catalog 加 tool-calling 字段(#2687):"按能力路由"的元数据基础,看是否拉进我们的 catalog
- [ ] Kubeflow Trainer KEP-2599 runtime 解耦(#3428):若引入 Trainer,这是值得提前 review 的架构变更

## 原始材料

<details>
<summary>本窗口内 release</summary>

- vLLM v0.21.0(2026-05-15)
- SGLang v0.5.12(2026-05-16)
- ogx v1.0.0(2026-05-12 主版本)/ v1.0.1(2026-05-13)/ v1.0.2(2026-05-13)
- MLflow ts/v0.2.0(Tracing Server,2026-05-15)
- TensorRT-LLM、Ray、TGI、KServe、KubeAI、Trainer、LLaMA-Factory、Feast、garak、lm-eval、Hub 本窗口无新 release
</details>

<details>
<summary>本窗口 PR 计数</summary>

- SGLang 385 / vLLM 225 / mlflow 132 / Ray 92 / ogx 46 / KServe 17 / ollama 13 / kubeflow/hub 13 / Feast 12 / garak 6 / Trainer 5
- 0 PR:TGI、KubeAI、LLaMA-Factory、lm-evaluation-harness
- TRT-LLM:大量 commit(>50/日),Gemma 4 + Nemotron Nano Omni + flashinfer 整合是主线;无 release tag
</details>
