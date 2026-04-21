# AI 推理 & MLOps 生态周报 2026-04-21

窗口：2026-04-14 → 2026-04-21
扫描范围：14 个核心仓库（推理引擎 5 / 模型服务 3 / 训练微调 2 / 模型生命周期 3 / 评估 1）

## 摘要（5 条以内）

1. **TurboQuant 2-bit KV cache 压缩正式合入 vLLM** — PolarQuant（WHT + Lloyd-Max）实现 4× 容量，无需离线校准；Ampere/Ada/Hopper 全覆盖 ([#38479](https://github.com/vllm-project/vllm/pull/38479))。
2. **Ray 2.55.0 为 LLM Serve 做出大调整** — ingress-bypass 5 PR 系列开启（HAProxy 直连 replica 后端 HTTP 端口）；PDProxyServer 被 "decode-as-orchestrator" 架构替换；Serve LLM / Data LLM API 晋升 beta ([release](https://github.com/ray-project/ray/releases/tag/ray-2.55.0), [#62667](https://github.com/ray-project/ray/pull/62667))。
3. **KServe v0.18.0-rc0 发布** — LLMInferenceService 支持 KEDA/HPA + WVA v0.6.0 自动伸缩，Gateway 自动检测并迁移到 v1 InferencePool，namespace-scoped ModelCache，新增 `/v1/responses` OpenAI Responses API 路由 ([release](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc0))。
4. **MLflow v3.11.1 把 AI 治理升级为产品主线** — Gateway Budget（时间窗口花费限额 + 自动阻断）、Automatic Issue Detection（跨 correctness/safety/performance 自动分析 trace）、OpenTelemetry GenAI 语义、pickle-free 序列化一次交付 ([release](https://github.com/mlflow/mlflow/releases/tag/v3.11.1))。
5. **SGLang 启动 native Rust gRPC server (RFC #22558)** — 25 个 RPC、与现有 HTTP 并行，构建 PyO3/Tonic crate；同期大量 NPU（Ascend）文档补齐 ([#22736](https://github.com/sgl-project/sglang/pull/22736))。

---

## 推理引擎动态

### vLLM

**v0.19.1** 于 4/21 发布（[release](https://github.com/vllm-project/vllm/releases/tag/v0.19.1)），v0.19.2rc0 于 4/18 出卡（[release](https://github.com/vllm-project/vllm/releases/tag/v0.19.2rc0)）；主要聚焦 Gemma4 的流式工具调用、量化 MoE、Eagle3 等稳定性修复。

本周重量级变化：

| 方向 | 要点 |
|------|------|
| KV cache 压缩 | **TurboQuant 2-bit KV 压缩合入**：PolarQuant（Walsh-Hadamard 旋转 + Lloyd-Max 量化），多档预设 2.6×~4.9×，边界层保 FP16，K/V 可非对称位宽；`k8v4` 预设在 Qwen3-4B 上取得 79–100% baseline 吞吐，长序列反而更优 ([#38479](https://github.com/vllm-project/vllm/pull/38479))。初始仅支持 full-attention 和均匀 SWA。 |
| vLLM IR | 新增 IR op 测试/基准框架 ([#40167](https://github.com/vllm-project/vllm/pull/40167))：引入统一输入生成器和容差 API，为跨硬件算子实现提供自动化精度/性能验证，样例展示 6.48× 几何平均加速 — 这是硬件抽象层逐步成形的关键底座。 |
| KV connector / LMCache | `num_lmcache_extra_cached_token` 参数加入 KVTransferParams（[#39843](https://github.com/vllm-project/vllm/pull/39843)）；多 connector 指标修正（[#40010](https://github.com/vllm-project/vllm/pull/40010)）；NIXL 升级到 0.10.1（[#39922](https://github.com/vllm-project/vllm/pull/39922)）。 |
| 多租户 | LMCache `cache_salt` 通过 MP connector 透传、实现 per-user 存储配额隔离 ([#39837](https://github.com/vllm-project/vllm/pull/39837))，merge 后有跟进 commit 补全 fallback adapter。 |
| 启动优化 | torch/transformers import 与权重预取 / forkserver 并行化 ([#40331](https://github.com/vllm-project/vllm/commit/8256833fe6f90e508b0264120757c5ea999a044d))。 |
| 量化 | MXFP4 W4A4 CUTLASS MoE kernel for SM100 ([#37463](https://github.com/vllm-project/vllm/pull/37463))；mxfp8 online quant 前端迁移（[#40152](https://github.com/vllm-project/vllm/pull/40152)）；Marlin kernel 接入 block-scaled mm 选型（[#40105](https://github.com/vllm-project/vllm/pull/40105)）。 |
| WideEP | naive all2all 被 allgather_reducescatter 替换 ([#40321](https://github.com/vllm-project/vllm/commit/81d954f454d45425a0ad0a0a742de2695e4f043a))。 |

**对我们的启示**：TurboQuant 合入意味着"4× KV 容量不动模型"正式进入主线，长上下文场景显存墙能实打实地下移，值得立刻在内部基准上复测我们支持的模型；`cache_salt` 多租户隔离已经是 KV connector 的公认 API，若我们自研推理网关要做 per-tenant KV 缓存必须沿用这条语义；**vLLM IR** 如果稳定下来，未来插入自家加速卡/算子的成本会显著降低，建议关注其 op 注册协议。

### SGLang

**窗口内无新 release**，但一周落了 200+ 个 PR，方向上出现两处结构性信号：

- **Native Rust gRPC server 启动（RFC #22558）**：proto 定义 25 RPC、Rust crate scaffold、PyO3/Tonic，与 HTTP 并行 ([#22736](https://github.com/sgl-project/sglang/pull/22736))；构建层由 `setuptools-rust` 打进主 wheel，`sglang.srt.grpc._core` 直接可用。额外 protoc `--experimental_allow_proto3_optional` 支持（[#23226](https://github.com/sgl-project/sglang/pull/23226)）。
- **HiCache 持续打磨**：`UnifiedRadixTree` 新增 HiCache hook 接口（[#22924](https://github.com/sgl-project/sglang/pull/22924)）、`flush_cache` 时回收 L2 host pool 槽位（[#23216](https://github.com/sgl-project/sglang/pull/23216)）、L2 host cache 插入现在会发 KV events（[#22894](https://github.com/sgl-project/sglang/commit/3c007ee5d406c2cffd6cfa4edc8abdf66ed0c697)）、SiMM 作为存储后端（[#18016](https://github.com/sgl-project/sglang/pull/18016)）。
- **PD 分离稳定性**：R3 support on mini_lb（[#22916](https://github.com/sgl-project/sglang/pull/22916)）；`--fake-prefill` benchmark flag 专门压测 decode-only（[#22973](https://github.com/sgl-project/sglang/pull/22973)）；IntraNode NVLink 下 `_commit_transfer_to_req()` 错误修复（[#23252](https://github.com/sgl-project/sglang/pull/23252)）；`follow_bootstrap_room` fast path 下线（[#22901](https://github.com/sgl-project/sglang/pull/22901)）。
- **投机解码**：Eagle3/DFLASH aux hidden state capture in CUDA graph init 修复（[#22836](https://github.com/sgl-project/sglang/pull/22836)）；piecewise CUDA graph 与 spec decode 共存（[#22128](https://github.com/sgl-project/sglang/pull/22128)）；EAGLE topk=1 新增自适应 `speculative_num_steps`（[#21599](https://github.com/sgl-project/sglang/pull/21599)）；spec v2 的 overshoot 裁剪（[#22897](https://github.com/sgl-project/sglang/commit/efc267c)）；NPU 端 Eagle/Eagle3 与 xgrammar 冲突修复（[#20989](https://github.com/sgl-project/sglang/pull/20989)）；spec decode OpenTelemetry tracing（[#19545](https://github.com/sgl-project/sglang/pull/19545)）。
- **Score API**：Multi-Item Scoring with pre-computed delimiter indices（[#23315](https://github.com/sgl-project/sglang/pull/23315)） — 批评分场景的吞吐优化。
- **Ascend NPU**：大量 best-practice 文档更新 + 能力矩阵刷新（[#23238](https://github.com/sgl-project/sglang/pull/23238), [#22975](https://github.com/sgl-project/sglang/pull/22975), [#22808](https://github.com/sgl-project/sglang/pull/22808), [#22860](https://github.com/sgl-project/sglang/pull/22860)）。
- Opt-in strip of thinking tokens from radix cache ([#23315](https://github.com/sgl-project/sglang/pull/23315)) — reasoning 场景避免"思考过程"污染前缀缓存。

**对我们的启示**：SGLang 的 Rust gRPC 服务表明"推理引擎原生协议不再只是 OpenAI HTTP"，若我们的平台面向企业客户做高吞吐内部互联，提前在网关层预留 gRPC/流式能力有直接价值。NPU 分支的密集文档更新反映"推理栈+国产卡"已经是 SGLang 的正式兼容面，我们在客户侧给 NPU 做兼容时可以直接引用。

### TensorRT-LLM

**v1.3.0rc12** 于 4/18 发布（[release](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc12)），**v1.2.1 稳定补丁**于 4/20 发布，修复 KV cache 损坏关键 bug 并升级 xgrammar / flashinfer（[release](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.2.1)）。

v1.3.0rc12 要点：

- **VisualGen API Pydantic 化** + per-model 默认值、请求校验；
- **Disagg serving 会话亲和路由**（conversation-affinity routing）优化负载均衡；block reuse 与 overlap scheduler 协同；
- **KVConnector 简写**：`"lmcache"`/`"kvbm"` 一键切换；
- **LoRA × 投机解码**、FP8 权重加载；**MoE CuteDSL for Qwen3.5**；**Qwen-Next** 支持 Python cache transceiver；
- **生产级 Prometheus 指标** + NvTelemetry/GXT 合规；
- **稳定性**：消除 disagg serving 中阻塞 KV 传输导致的挂起、VLM guided decoding 启动崩溃、multi-stream MoE 在 MLIR+CUDA graph 下的精度问题；
- **[TRTLLM-12291] 新 sharding 基础设施**（[#12419](https://github.com/NVIDIA/TensorRT-LLM/commit/a8bd7b36a0574101d548193b17e2b78a15cd8c7e)）；VisualGen GDN prefill 用 indexed in-kernel state 更新提速。

**对我们的启示**：TRT-LLM 在推 production-grade metrics + 会话亲和路由，这和我们在 OAI 对标产品里要做的"多轮会话 KV 局部性优化"方向一致；v1.2.1 的 KV cache 损坏是运行中集群要立即关注的升级点。

### Ollama

**节奏继续飞快**：7 天内 v0.20.7（4/14）→ v0.21.0-rc0（4/16）→ v0.21.0-rc1（4/17）→ **v0.21.0**（4/18）→ v0.21.1-rc0（4/21）五个版本。

v0.21.0 要点（[release](https://github.com/ollama/ollama/releases/tag/v0.21.0)）：

- **Gemma4 on MLX**：Apple Silicon 文本运行时、混合精度量化、新增算子；同期 commit 大量围绕 MLX backend 调优（top-P/top-K fused sort、sigmoid router 融合、repeat penalty 采样、logprobs 支持）。
- **Hermes agent**：声称"能在使用中自动为用户生成新技能"的 agent 方向尝试。
- **`ollama launch` 集成**：新增 GitHub Copilot CLI（[#15583](https://github.com/ollama/ollama/commit/7d271e6dc9fb114d48b91a1ed2ed3d414178a883)）、Kimi CLI（[#15723](https://github.com/ollama/ollama/commit/8e05d734b95750d406ee753d62430891299faa86)）；config 无变化时不必重写；OpenCode 改为内联配置。
- **Gemma4 小规模 fixes**：Metal 构建、macOS 交叉编译、渲染 / 缓存 / 路由精度等一堆扫尾。

**对我们的启示**：Ollama 的 `launch` 渐渐定型成"端侧 LLM 的 brew tap"，跟 Copilot CLI / Kimi CLI 的联动意味着端侧 Agent 载体的争夺已经白热化 — 我们对端-云协同的定位需要评估这类生态产品的影响面。MLX 采样器 + 量化 MoE 的持续加码说明苹果 M 系列已经是 Ollama 的一等公民。

### TGI / Lingo

- HuggingFace TGI：**窗口内无 commit、无 release**，上一个 release 为 2025-12-19 的 v3.3.7。社区活跃度下降信号持续。
- substratusai/lingo：仓库本身已经迁移为 `kubeai-project/kubeai`，窗口内无新 release、无新 commit（上一个 v0.23.2 于 3/31 发布），需要警惕项目维护状态。

---

## 模型服务 & 编排

### KServe 上游

**v0.18.0-rc0** 于 4/20 发布（[release](https://github.com/kserve/kserve/releases/tag/v0.18.0-rc0)），是本周最重要的版本事件：

- **LLMInferenceService 自动伸缩**：KEDA/HPA 支持 + WVA v0.6.0，LWS（Lightweight Workload Services）作为 autoscaling target 实现多节点伸缩。
- **Gateway 自动化**：检测到 Gateway 在位时自动迁移到 v1 InferencePool；支持 Gateway ref 的 `SectionName`（[#5410](https://github.com/kserve/kserve/commit/b0d101233595388658a606c57d84f1ac89ecf8c3)）。
- **Namespace-scoped ModelCache** + download job 在 job namespace 运行。
- **OpenAI 兼容**：新增 `/v1/responses` HTTPRoute。
- **数据格式**：CSV 和 Parquet marshaller。
- **安全**：InferenceService 与 ServingRuntime webhook 屏蔽 `PYTHONPATH` 环境变量；LLMInferenceService 默认模板强制 PSS restricted profile；CVE-2026-30922（pyasn1 DoS）修复（[#5404](https://github.com/kserve/kserve/commit/e21290ce13d34330efb240a928dcb1f5b66fdec8)）。
- **存储迁移**：LLMInferenceService API 的存储迁移 + deferred webhook serving。
- **Storage & 运维**：S3 模型下载间歇性 403 修复（[#5393](https://github.com/kserve/kserve/commit/eaf73bae2fe477b91e1dfc7f11b57f7f8705ba51)），legacy deploymentMode 状态归一化（[#5427](https://github.com/kserve/kserve/commit/85076650e7a7f03c7e5b43a1216baa7c5801c127)）。
- **LLMISvc 细节**：`spec.labels`/`annotations` 向 Service 透传（[#5365](https://github.com/kserve/kserve/commit/9b78477900b70acf06b9ac88cf065729acc020c2)）、webhook 名长度合规（[#5381/5398](https://github.com/kserve/kserve/commit/b3587fa6e088e9b37841e162818b7055d5d73896)）。
- **发布流程**：GOTAGS 构建参数（[#5403](https://github.com/kserve/kserve/commit/b7b2886205156dec62507c0a8ee7936fd1edbe46)）、Copilot CLI release 自动化（[#5419](https://github.com/kserve/kserve/commit/152baeb329b7dbd52799fb9c4efe3ffcdf7653b7)）、release orchestrator 安全性增强（[#5423](https://github.com/kserve/kserve/commit/20b2d7edd42a459cc4dfd8efa9662a6afec731ce)）。

**对我们的启示**：v0.18 的 KEDA/HPA + WVA 组合直接定义了"多节点 LLM 自动伸缩"的主流路径；namespace-scoped ModelCache 解决了多团队/多租户场景的模型下载隔离；`/v1/responses` 路由意味着 OAI Responses API 成为上游一等公民，我们的兼容层需要同步跟进。LLMInferenceService 存储迁移说明 v0.18 有破坏性 schema 动作，升级前必须做 backup/测试。

### Ray

**Ray 2.55.0** 于 4/15 发布（[release](https://github.com/ray-project/ray/releases/tag/ray-2.55.0)），这是本周最有分量的发行：

- **Ray LLM 重构**：PDProxyServer 被 "decode-as-orchestrator" PD 架构替换 — 解耦 proxy 与 decode；Wide-EP 部署下引入数据并行组级容错；**Data LLM / Serve LLM API 晋升 beta**。
- **SGLang engine 扩展**：流式 chat/completions、tokenize/detokenize、embeddings、多 GPU TP/PP。
- **vLLM 升级**：同时追到 0.16.0/0.17.0/0.18.0。
- **Ray Serve gRPC**：端到端客户端，双向流式，原生流式 workload 友好。
- **Queue-based autoscaling**：同时考虑 in-flight HTTP + queued task。
- **Gang scheduling**：多副本 validation / fault tolerance / autoscaling 统一协调。
- **Tracing**：跨 deployment 的 gRPC 传播。

4/14–4/21 窗口内还在推进的关键工作：

- **Ingress bypass 5-PR 系列启动**：[#62667](https://github.com/ray-project/ray/pull/62667)（backend HTTP endpoint metadata，本周已合并）、[#62680](https://github.com/ray-project/ray/pull/62680)、[#62668](https://github.com/ray-project/ray/pull/62668)、[#62669](https://github.com/ray-project/ray/pull/62669)、[#62670](https://github.com/ray-project/ray/pull/62670) — 最终目标是让 HAProxy 直接按 replica ID 路由到后端 HTTP，LLM 侧提供 `/internal/route` 和 backend ASGI 切换；
- **Ray-HAProxy 实验性特性**：引入 `RAY_SERVE_EXPERIMENTAL_PIP_HAPROXY`，从 PyPI `ray-haproxy` 包提供 HAProxy 二进制，解耦系统依赖（[commit](https://github.com/ray-project/ray/commit/2048fcf30ed397d3d02a1b20643ebc13ce920d60)）；配套 HAProxy 2.8.20 解锁（[commit](https://github.com/ray-project/ray/commit/164411cc6581da169c2b6bf9be5de3a9cae2722c)）；
- **Serve 运维能力**：max replica processing latency（[#62381](https://github.com/ray-project/ray/commit/606af2a3195ad2ec1f39eb7a1cae47d3d65afb7b)）；
- **Data V1 parquet** 默认 scanner（readahead + buffered stream）调优 + actor 池利用率监控（[commit](https://github.com/ray-project/ray/commit/e6d96857e326fd76ea20b7b6c3597c8edfdac745)）。

**对我们的启示**：Ray Serve 的 ingress bypass + HAProxy 侧车化是明牌——减少 proxy hop 的 fast-path 从此成为高吞吐推理场景的标配，我们自研推理网关的"是不是要走 L4 旁路"问题要趁早决策；PDProxyServer 被"decode-as-orchestrator"替换也提醒我们：上游 PD 分离的上层控制平面正在改造，若我们的 Ray LLM 组件有下游依赖，需要准备向 2.55 升级的路径。

### Lingo / KubeAI

窗口内无实质更新（见上面推理引擎段落）。

---

## 训练 & 微调

### Kubeflow Trainer

- **v2.2.0 发行后，2026 ROADMAP 公布**（[#3242](https://github.com/kubeflow/trainer/pull/3242)）：Workload-Aware Scheduling、NVIDIA DRA 多节点 NVLink、Flux + Intel MPI + PMIx、Tensor Caching / RDMA、LLM fine-tuning 强化、多 runtime 插件注册机制、Trainer UI、Kueue 多集群任务分发、MCP server 集成。
- Helm CI e2e 测试加入（[#3253](https://github.com/kubeflow/trainer/commit/d4546f4f4a45b961d0aa7efbd4f37c56dbe7b8c7)）、Megatron TP notebook GPU E2E 恢复（[#3434](https://github.com/kubeflow/trainer/commit/71335f7d304cd0154d9bea0c293cdd6e7cb2ca44)）。
- 其余为 deepspeed / transformers / huggingface-hub 等依赖升级。

**对我们的启示**：Kubeflow Trainer 在 2026 路线图上"正面迎击 LLM fine-tuning + Kueue 多集群"，与我们的训练平台定位有直接竞争/借鉴关系，特别是"多 runtime 插件注册机制"，决定了未来第三方训练框架（SGLang-train / vLLM-train / MindSpeed）如何接入 Kubeflow，建议跟进其 API。

### LLaMA-Factory

v1 refactor 持续推进（4 个关键 PR 合入）：

- [#10300](https://github.com/hiyouga/LLaMA-Factory/commit/28a6ea1cdc6fba34760c236504fece8df5e642f4) **deepspeed zero3 触发低内存权重加载**；
- [#10366](https://github.com/hiyouga/LLaMA-Factory/commit/f5d739b132a9ef111647ba2a507115653ad1f935) **修复 Ulysses CP 下的 device mesh 与 clip_grad_norm**（Context Parallel）；
- [#10280](https://github.com/hiyouga/LLaMA-Factory/commit/c4bbac49b2827f126cff46234096e407413a2e08) **checkpoint 恢复训练**；
- [#10408](https://github.com/hiyouga/LLaMA-Factory/commit/c5aecaf31de46ace2a7bc243810b995957b84c0b) `SeedToolUtils.tool_extractor` 无 tool call 时回填 content。

**对我们的启示**：LLaMA-Factory v1 的 Ulysses CP 落地意味着长序列微调在开源侧有了可用的 PyTorch 路径，可以拉进我们内部训练 SLA 的技术评估。

---

## 模型生命周期

### MLflow

**v3.11.1** 于 4/20 发布（[release](https://github.com/mlflow/mlflow/releases/tag/v3.11.1)），功能密度本周最高：

- **Automatic Issue Detection**：AI 驱动的 trace 质量分析，跨 correctness/safety/performance 三类自动打标签 — 开始挑战"观测 → 分析 → 修复"闭环。
- **Gateway Budget**：按 daily/weekly/monthly 窗口设花费限额，支持告警与自动 block；Redis-backed 支持分布式 gateway（[#22700](https://github.com/mlflow/mlflow/pull/22700)）。
- **Trace Graph Visualization**：父子关系可视化，交互式探索。
- **OpenTelemetry GenAI 兼容**：trace 可原生翻译为 OTel GenAI 语义，直接对接企业观测平台。
- **Pickle-free 序列化**：`torch.export` + `skops` 取代 pickle，安全合规的一步。
- **Native gateway providers**：Vertex AI / Databricks / Ollama / xAI (Grok) / Bedrock Converse API 均为一级公民。
- **Guardrails 全链路完工**：executor 进入 gateway API handler（[#22306](https://github.com/mlflow/mlflow/pull/22306)）、endpoint editor 新标签页（[#22360](https://github.com/mlflow/mlflow/pull/22360)）、DetailModal 查看/编辑（[#22435](https://github.com/mlflow/mlflow/pull/22435)）、bulk selection 表格（[#22527](https://github.com/mlflow/mlflow/pull/22527)）、tracing span（[#22581](https://github.com/mlflow/mlflow/pull/22581)）、AI Gateway 官方文档（[#22577](https://github.com/mlflow/mlflow/pull/22577)）。
- **`mlflow gateway start` CLI 正式弃用**（[#22580](https://github.com/mlflow/mlflow/pull/22580)） — gateway 独立进程模式正在淡出，未来走集成路径。
- **新增 flavor**：`mlflow.diffusers` 管理 diffusion 模型 LoRA adapter（[#22253](https://github.com/mlflow/mlflow/pull/22253)），支持 FLUX.2 Klein 4B 的端到端 GPU 推理验证。
- **Trace 产品化细节**：share button（[#22608](https://github.com/mlflow/mlflow/pull/22608)）、attachment 大小限制（[#22575](https://github.com/mlflow/mlflow/pull/22575)）、TypeScript Codex CLI tracing（[#22410](https://github.com/mlflow/mlflow/pull/22410)）。
- **Breaking changes**：TypeScript SDK 包名改用 `@mlflow/*` 组织域名；`litellm`/`gepa` 从 `genai` extras 中移除；注册模型名禁用 `/` 和 `:`。
- **Model Catalog 周级 CI 发布**：`model-catalog/latest` 滚动 tag（[release](https://github.com/mlflow/mlflow/releases/tag/model-catalog%2Flatest)），71 个 per-provider 清单周更。

**对我们的启示**：MLflow 已经完成了"实验追踪平台 → AI 治理平台"转身，Budget + Guardrails + Issue Detection + OTel GenAI 这 4 件一次性到位，对 OAI 类平台形成直接压力 — 我们下一轮迭代要明确回答"要不要原地集成 MLflow Gateway，还是自研治理层同质化"。Diffusers flavor 值得注意：意味着 LoRA adapter 管理正在从 LLM 专属扩到扩散模型，我们的模型注册中心若只支持 LLM LoRA，需要尽快扩容 schema。

### Kubeflow Model Registry

**无新 release**。窗口内主要是 UI 打磨 + dependency 升级：

- UI：filter 面板独立滚动（[#2475](https://github.com/kubeflow/model-registry/commit/d941024350a42ef5f0b047c4617ee98e85158e26)）、mod-arch 升级到 1.15.3 + McpCatalogIcon（[#2602](https://github.com/kubeflow/model-registry/commit/7a380bf0e1740222f31a4f1a69f1a0a7326a660e)）、license values mapping 下线（[#2596](https://github.com/kubeflow/model-registry/commit/bcf05624dfdf0355caaac12892d6a689deb9112b)）。
- Ops：Kind 本地开发环境 setup skill（[#2307](https://github.com/kubeflow/model-registry/commit/b5dd0583f496afb84ed3d78c8e78b3cacd0532d0)）、docker image pull rate limit workaround（[#2611](https://github.com/kubeflow/model-registry/commit/36dcfed0c566a5875aafe424f4b0e1a7821937a3)）。
- 大量 dependabot：actions/cache、apimachinery 0.35.4、pgx 5.9.2、pydantic 2.13.0、otel-sdk 1.43.0 等。

本周属于稳定期，重点在 Catalog UI 细化。

### Feast

**无新 release**，提交仍然密集：

- **Online store 和 materialization**：`online_write_batch_size` 配置化（[#6268](https://github.com/feast-dev/feast/commit/d41becff2ecade63788903e44aeb3ec05878105b)）、物化中 `Ambiguous truth value of array` 修复（[#6259](https://github.com/feast-dev/feast/commit/d0c89846f3340fabaa036a4a8f61795b541e920d)）、Milvus online store 5 个 bug 一口气修（[#6275](https://github.com/feast-dev/feast/commit/212504bb7aa32fb6ff14be82490a2f5f50616937)）。
- **Feature serving**：在线特征检索新增 feature status metric（[#6280](https://github.com/feast-dev/feast/pull/6280)）；**Go Feature Server TLS**（[#6229](https://github.com/feast-dev/feast/commit/28a58d0735ce4bf22554e1e562aef6b97e7bafe4)）。
- **Registry**：字符串形式指定 registry 时自动识别 GCS/S3 store（[#6260](https://github.com/feast-dev/feast/commit/7ebcf03d6d33a3904bcfd9f4cbc01ce7d606856d)）。
- **Feature builder**：pandas mode + dask column 额外列修复（[#6287](https://github.com/feast-dev/feast/commit/863315e212a1aa3179b17cd1761f159100ffda15)）；`LocalOutputNode` 回传改用 `ArrowTableValue` 保持类型一致（[#6286](https://github.com/feast-dev/feast/commit/a16cd550983531e74f2f4da857f8eb8a53c7fcdb)）。
- **Remote Offline Store**：`get_historical_features` 接受 SQL 字符串作为 `entity_df`（[commit](https://github.com/feast-dev/feast/commit/c559889c244ef2abe151d472c383287f6e16f01a)）。
- **DocEmbedder** 文档与示例（[commit](https://github.com/feast-dev/feast/commit/9b185ee1db6f1bf1df4eaaa0833f967cc0ba38b5)）。
- Ops 类：Redis 测试部署禁用 RDB 持久化；feast server 镜像打包 git；kustomize 选择器通过 JSON 6902 patch 移除。

**对我们的启示**：Feast 在"生产化 Go Feature Server"方向持续加码（TLS、metric、remote offline SQL），这和 Feature Store 进入主流数据基建的趋势一致。Milvus 在线存储稳定化 + DocEmbedder 官方化，把 Feast 从"数值特征平台"推向"文档+向量特征平台"，如果我们的检索/RAG 场景想走 Feast，现在可以认真评估。

---

## LLM 评估

### lm-evaluation-harness

**窗口内无 commit、无 release**，上一个 commit 是 2026-04-08。PR 队列中尚未出现重大事件（上周提到的 0.5 版本审查和新 benchmark 提交仍在评审）。

---

## 对我们产品的启示（PM 视角）

1. **推理侧的"KV 压缩"已进入可用区**：vLLM TurboQuant 合入 + Ollama tq2/tq3 + SGLang HiCache 生态完善，说明"4× KV / 长上下文"这条价值主张不再是实验室玩具；产品视角下，我们对"支持 256k+ 上下文且显存成本可控"的宣称可以更硬气，但落地要挑选经过 Ampere/Ada/Hopper 三代验证的 preset。
2. **PD 分离从代码变成架构共识**：vLLM 完善 KV connector API（cache_salt、extra_cached_token）、SGLang 细化 PD 稳定性、Ray 用 "decode-as-orchestrator" 替掉 PDProxyServer、TRT-LLM 加会话亲和路由 — 我们的 inference operator 方案要把 PD 拆分作为"默认能力"而不是"高端可选"。
3. **Serve 层 fast-path**：Ray 的 ingress-bypass 5-PR 系列 + HAProxy 侧车 + KServe v0.18 的 Gateway 自动 v1 InferencePool 迁移 — 整体信号是"proxy hop 越来越少、L4 直连 replica"。OAI 对标的网关层要评估：要不要引入 HAProxy/Gateway API v1 作为默认数据路径。
4. **治理平台要抢窗口期**：MLflow v3.11.1 在一周内把 Budget / Guardrails / Issue Detection / OTel GenAI 一次交齐，Kubeflow Model Registry 还停在 UI 打磨、Feast 在补 TLS — 治理层"第二梯队"与 MLflow 差距在快速拉大。我们如果不希望客户选择 MLflow Enterprise，要在 6 个月内补齐 gateway budget 和 guardrails 执行链路（或者直接 OEM）。
5. **国产卡（NPU/Ascend）在 SGLang 生态已正式化**：SGLang 本周 NPU 最佳实践文档、能力矩阵、Docker 镜像、特性 gating 成批合入。对"向 Ascend/昇腾客户交付云原生 AI 基础设施"而言，SGLang 路线图优先级应等同于 vLLM。
6. **多模态 + LoRA 的 artifact 管理**：MLflow 新增 `mlflow.diffusers` flavor 专门管理扩散模型 LoRA，KServe 本周仍在推进静态 LoRA adapter 调和 — LoRA 不再只是 LLM 特性，我们的模型生命周期 schema 要扩到多模态 / 扩散 / VLM 场景。
7. **Ollama 端侧 Agent 入口化**：`ollama launch` 打通 Copilot CLI / Kimi CLI / WhatsApp / Telegram 等多渠道，端侧 LLM 正从"本地模型跑腿"升级为"Agent OS 入口"。对云原生 AI 基础设施产品的影响主要是"云-边协同"策略：端侧越 Agent 化，云侧要提供的就是模型编排与治理（评估、安全、成本），而不是简单的推理容器。
8. **安全补丁优先级**：本周 KServe 侧进一步修复 pyasn1 DoS（CVE-2026-30922）、TRT-LLM v1.2.1 修复 KV cache 损坏关键 bug — 运营中的推理平台要立即跟进。

## 值得跟进

- [ ] **[高]** TurboQuant 2-bit KV ([#38479](https://github.com/vllm-project/vllm/pull/38479)) 在我们支持的模型上做端到端质量/吞吐基准，输出 preset 推荐表。
- [ ] **[高]** KServe v0.18.0-rc0 升级测试：LLMInferenceService 存储迁移、Gateway v1 InferencePool 自动迁移在我们的 fork 上验证；评估 `/v1/responses` 路由需要在哪层暴露。
- [ ] **[高]** MLflow v3.11.1 Budget + Guardrails + Issue Detection：立项评估是否 OEM 或同质化自研。
- [ ] **[中]** Ray Serve ingress-bypass 5-PR 系列（[#62667](https://github.com/ray-project/ray/pull/62667) 起）：观察是否引入为我们 Serve 组件的默认路径。
- [ ] **[中]** SGLang Native Rust gRPC server ([#22736](https://github.com/sgl-project/sglang/pull/22736))：提前在推理网关层预留 gRPC 客户端。
- [ ] **[中]** Kubeflow Trainer ROADMAP 2026（[#3242](https://github.com/kubeflow/trainer/pull/3242)）：对 LLM fine-tuning + Kueue 多集群分发做竞品对位分析。
- [ ] **[中]** vLLM IR 自动测试框架（[#40167](https://github.com/vllm-project/vllm/pull/40167)）：跟踪其算子注册协议，评估国产卡/自研算子接入成本。
- [ ] **[低]** MLflow `mlflow.diffusers` flavor（[#22253](https://github.com/mlflow/mlflow/pull/22253)）：我们的 model registry 是否兼容扩散 LoRA adapter schema。
- [ ] **[低]** TRT-LLM v1.2.1 KV cache 损坏修复（[release](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.2.1)）：运营中的 TRT-LLM 后端升级。
- [ ] **[监控]** TGI、lingo/kubeai 两个社区停滞信号，影响客户兼容矩阵决策。

---

## 原始来源清单

### Releases
- vLLM v0.19.1 — https://github.com/vllm-project/vllm/releases/tag/v0.19.1
- vLLM v0.19.2rc0 — https://github.com/vllm-project/vllm/releases/tag/v0.19.2rc0
- TRT-LLM v1.3.0rc12 — https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc12
- TRT-LLM v1.2.1 — https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.2.1
- Ollama v0.20.7 — https://github.com/ollama/ollama/releases/tag/v0.20.7
- Ollama v0.21.0-rc0 — https://github.com/ollama/ollama/releases/tag/v0.21.0-rc0
- Ollama v0.21.0-rc1 — https://github.com/ollama/ollama/releases/tag/v0.21.0-rc1
- Ollama v0.21.0 — https://github.com/ollama/ollama/releases/tag/v0.21.0
- Ollama v0.21.1-rc0 — https://github.com/ollama/ollama/releases/tag/v0.21.1-rc0
- KServe v0.18.0-rc0 — https://github.com/kserve/kserve/releases/tag/v0.18.0-rc0
- MLflow v3.11.1 — https://github.com/mlflow/mlflow/releases/tag/v3.11.1
- MLflow Model Catalog — https://github.com/mlflow/mlflow/releases/tag/model-catalog%2Flatest
- Ray 2.55.0 — https://github.com/ray-project/ray/releases/tag/ray-2.55.0（发布于窗口第一天）

### Repos（仓库主页 / PR 列表）
- vLLM commits — https://github.com/vllm-project/vllm/commits/main
- SGLang commits — https://github.com/sgl-project/sglang/commits/main
- TRT-LLM commits — https://github.com/NVIDIA/TensorRT-LLM/commits/main
- Ollama commits — https://github.com/ollama/ollama/commits/main
- KServe commits — https://github.com/kserve/kserve/commits/master
- Ray commits — https://github.com/ray-project/ray/commits/master
- Kubeflow Trainer commits — https://github.com/kubeflow/trainer/commits/master
- LLaMA-Factory commits — https://github.com/hiyouga/LlamaFactory/commits/main
- Kubeflow Model Registry commits — https://github.com/kubeflow/model-registry/commits/main
- MLflow commits — https://github.com/mlflow/mlflow/commits/master
- Feast commits — https://github.com/feast-dev/feast/commits/master
- HuggingFace TGI commits — https://github.com/huggingface/text-generation-inference/commits/main （窗口内无活动，源仅做存在性确认）
- KubeAI (原 substratusai/lingo) commits — https://github.com/kubeai-project/kubeai/commits/main （窗口内无活动）
- lm-evaluation-harness commits — https://github.com/EleutherAI/lm-evaluation-harness/commits/main （窗口内无活动）

### 数据抓取方式
- GitHub atom feeds（releases.atom / commits/<branch>.atom），7 天窗口内条目逐个入栏；
- 高频仓库（vLLM / SGLang / TRT-LLM）叠加 GitHub 网页 PR 列表按关键词过滤（KV, disagg, spec, quant, guardrail, budget 等）。
- 未登录 `gh`、未触达 API 限额。
- 源拉失败情况：无（所有仓库 atom + 网页均可访问）。
