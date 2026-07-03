# AI 推理 & MLOps 生态周报 2026-07-03

窗口:2026-06-26 -> 2026-07-03(7 天)。本期与上一份(2026-07-01)仅隔 2 天,vLLM v0.24.0 / SGLang v0.5.14 / TensorRT-LLM v1.3.0rc20 / Ray 2.56.0 四个大 release 均已在上期覆盖,**本周无新 release**。因此本期只记录上期之后(07-01 起)的增量 commit/PR,以及一个易被忽略但影响追踪口径的信号:多个核心仓库发生了组织级改名/搬迁。

## 摘要(5 条以内)

- **四个我们在追的上游仓库本周被改名/迁组织**,继续按旧 slug 打 GitHub API 会吃 301:`kubeflow/training-operator` -> [`kubeflow/trainer`](https://github.com/kubeflow/trainer)、`kubeflow/model-registry` -> [`kubeflow/hub`](https://github.com/kubeflow/hub)、`substratusai/lingo` -> [`kubeai-project/kubeai`](https://github.com/kubeai-project/kubeai)、`meta-llama/llama-stack` -> [`ogx-ai/ogx`](https://github.com/ogx-ai/ogx)(即上期提到的 OGX,现独立成 org,定位 "Open GenAI Stack",8.4k star)。追踪脚本的仓库清单需要更新。
- **vLLM Model Runner V2 再进一步**:[对所有 dense 模型默认启用](https://github.com/vllm-project/vllm/pull/44443)(上期还只是量化模型默认)。MRv2 已基本成为默认 runtime,回归基线要以 MRv2 为准。
- **Model Registry 正在变成 "AI Hub"**:改名后的 kubeflow/hub 落地 [AI Hub v1 提案](https://github.com/kubeflow/hub/pull/2690) 与 [MCP catalog 的 CRUD 端点](https://github.com/kubeflow/hub/pull/2890)——上游模型注册中心正从"模型元数据"扩到"模型 + MCP 工具/Agent 目录"。
- **企业级安全/合规信号密集**:OGX(原 llama-stack)合入 [strict TLS 模式(breaking)](https://github.com/ogx-ai/ogx/pull/5603) + [OTel 指标经 Prometheus 端点暴露](https://github.com/ogx-ai/ogx/pull/6034);MLflow 修 [webhook 投递的 DNS-rebinding SSRF 绕过](https://github.com/mlflow/mlflow/pull/24258);Feast 上 [FIPS 合规的 gRPC cipher suite](https://github.com/feast-dev/feast/pull/6532 分支)。
- **SGLang 把 DeepSeek-V4 长上下文 + 分层 KV 做成默认路径**:[FlashMLA sparse prefill 默认开](https://github.com/sgl-project/sglang/pull/29775)、[长上下文 non-paged indexer](https://github.com/sgl-project/sglang/pull/29619)、[HiCache 走 NIXL path-mode](https://github.com/sgl-project/sglang/pull/27060) + [DRAM+SSD L3 分层存储](https://github.com/sgl-project/sglang/pull/25377)。

## 推理引擎动态

### vLLM

- [ModelRunner V2 对所有 dense 模型默认启用](https://github.com/vllm-project/vllm/pull/44443);MRv2 调度补齐(req slot 全量记账 [#46974](https://github.com/vllm-project/vllm/pull/46974))、Mamba2 非 spec-decode 崩溃修复。
  - 启示:MRv2 默认化基本完成,上期我们把 "MRv1/MRv2" 列为能力维度是对的;现在应把 MRv2 当作默认执行路径做性能与正确性回归,MRv1 只当兼容回退。
- [异构词表的通用投机解码(TLI)](https://github.com/vllm-project/vllm/pull/38174),外加 DSpark speculators checkpoint、Laguna XS.2.1 DFlash drafter 等多条 spec-decode 增强。
  - 启示:投机解码正从"draft 模型必须同词表"放宽到跨词表(TLI),这让"小 draft + 大 target"组合空间变大;做推理加速选型/计费时要把投机解码当可配置能力暴露。
- Rust frontend 持续成形:[暴露 profiler 控制路由](https://github.com/vllm-project/vllm/pull/46306)、scheduler stats 日志对齐、tool parser 失败错误上下文。
  - 启示:vLLM 的前端(HTTP/调度/工具解析)正整体迁到 Rust,长期会影响我们对接的 API 行为与可观测字段,值得单列跟踪。

### SGLang

- [DeepSeek-V4 FlashMLA sparse prefill 默认开启](https://github.com/sgl-project/sglang/pull/29775) + [长上下文 non-paged indexer(opt-in)](https://github.com/sgl-project/sglang/pull/29619);[混合 Mamba/SWA 模型的统一 memory pool](https://github.com/sgl-project/sglang/pull/29678)。
- HiCache 分层 KV 存储成熟:[NIXL path-mode](https://github.com/sgl-project/sglang/pull/27060) + [DRAM + SSD(hugepage host allocator)L3 后端](https://github.com/sgl-project/sglang/pull/25377);PD 分离下 [KV-event publisher 端口冲突修复](https://github.com/sgl-project/sglang/pull/29211)、[prefill 失败时取消配对 decode](https://github.com/sgl-project/sglang/pull/29017)(出现 `model-gateway`/PD router 目录)。
  - 启示:SGLang 的分层 KV(DRAM/SSD + NIXL)与 PD 分离容错正在补齐,和上期 KServe `kvCacheOffloading`、vLLM 多层 KV offload 是同一条主线——KV tiering + PD 编排正成为推理平台的标配能力,我们的 KV 可观测/成本归因面板要能覆盖 SSD tier 与 PD region。
- Intel XPU 快速补齐:[XPU graph](https://github.com/sgl-project/sglang/pull/29053)、[XPU 投机解码](https://github.com/sgl-project/sglang/pull/23180)、DeepSeek-V4 XPU triton 路径。多后端(NV/AMD/XPU/NPU)是 SGLang 本周主投入方向。

### TensorRT-LLM / TGI / Ollama

- TensorRT-LLM 本周无新 release(上期 v1.3.0rc20 已覆盖"最后一个支持 TensorRT backend 的 RC")。commit 侧偏运维硬化:[trtllm-serve CLI 选项的 CI 稳定性门禁](https://github.com/NVIDIA/TensorRT-LLM/pull/15643)、[HangDetector 触发即硬退出并跨 rank 传播](https://github.com/NVIDIA/TensorRT-LLM/pull/15612)、[DSA 跨层 indexer top-k 共享(GLM-5.2)](https://github.com/NVIDIA/TensorRT-LLM/pull/15574);AutoDeploy(PyTorch-native 路径)持续加 MTP/ADP 与 post-merge 阶段。
  - 启示:NVIDIA 在给 `trtllm-serve` 补"生产可运维"护栏(选项稳定性门禁、挂起自愈)。若我们把 trtllm-serve 作为受支持后端之一,可直接借鉴 HangDetector 这类跨 rank 快速失败逻辑。
- Ollama:[agent harness core](https://github.com/ollama/ollama/pull/16963) 落地(向 Agent 运行时延伸)、CUDA CC 6.x 开 FlashAttention、移除不再支持的 ROCm 设备。仍偏桌面/边缘,企业级信号有限。
- HuggingFace TGI:本周 0 commit,无更新。

## 模型服务 & 编排

### KServe 上游

- 活跃度低但方向清晰,仍集中在 `llmisvc`(LLM InferenceService):[为所有匹配的 listener 发现 URL](https://github.com/kserve/kserve/pull/5664)、[给 llmisvc 设 limits 并上调 requests](https://github.com/kserve/kserve/pull/5637)。
  - 启示:KServe 正把 LLM 专用的 `llmisvc` 打磨到可用(多 listener 路由、资源默认值),和上期 `kvCacheOffloading`/延迟预测 sidecar 是一条线。我们若基于 KServe 分叉,`llmisvc` 的 CRD 契约要持续对齐。

### Ray

- 本周无新 release(上期 2.56.0 已覆盖)。commit 侧 Serve/Data-LLM 稳定性为主:[gRPC direct ingress 加流式](https://github.com/ray-project/ray/pull/64310)、[ServeDeploymentProcessor 加 request_timeout_s 防无限挂起](https://github.com/ray-project/ray/pull/64496)、[LLM 侧 token 级请求生命周期跟踪](https://github.com/ray-project/ray/pull/64327)、[弃用 HTTPOptions.num_cpus](https://github.com/ray-project/ray/pull/64418)。
  - 启示:Ray Serve LLM 在补请求级超时/生命周期可观测,这些正是多租户推理平台做 SLO/限流需要的原语;做基于 Ray Serve 的编排时可直接采用 request_timeout_s + token 级 tracking。

### KubeAI(原 substratusai/lingo)

- `substratusai/lingo` 已迁到 [`kubeai-project/kubeai`](https://github.com/kubeai-project/kubeai)(自我定位 "AI Inference Operator for Kubernetes",1.2k star,已支持 VLM/LLM/embedding/STT)。本周窗口内无新 commit,但项目从"轻量 LLM 代理"升级成完整推理 Operator,值得作为轻量级对标重新评估。

## 训练 & 微调

- **Kubeflow Training Operator 正式改名 [Kubeflow Trainer](https://github.com/kubeflow/trainer)**;本周合入 [Flux 调度器集成 + e2e 测试](https://github.com/kubeflow/trainer/pull/3561)。
  - 启示:Trainer 引入 Flux(HPC 侧 gang/批调度)集成,是训练侧 gang scheduling 生态的又一落点;若我们训练调度对标 Volcano/Kueue,可关注 Trainer 如何抽象多调度器后端。
- LLaMA-Factory 仓库名改为 [`hiyouga/LlamaFactory`](https://github.com/hiyouga/LlamaFactory)(仅大小写规范化,内容无组织变动);本周仅 bitsandbytes 安装文档修订与 Qwen3-VL 多视频 prompt 修复,无重大更新。

## 模型生命周期(MLflow / Registry / Feast)

- **Model Registry -> [Kubeflow Hub](https://github.com/kubeflow/hub)**:[AI Hub v1 提案](https://github.com/kubeflow/hub/pull/2690) + [MCP catalog sources 的 CRUD 端点](https://github.com/kubeflow/hub/pull/2890) + [MCP server displayName 支持](https://github.com/kubeflow/hub/pull/2864)。
  - 启示:延续上期判断——上游 Model Registry 正从"模型/版本元数据"扩张为"模型 + Agent/MCP 工具目录"的一站式 Hub。我们做模型生命周期产品时,MCP/Agent catalog 已经是上游一等公民,不能只按"模型仓库"设计。
- MLflow:安全修复 [webhook 投递的 DNS-rebinding SSRF 绕过](https://github.com/mlflow/mlflow/pull/24258)、[Admin UI 暴露 per-resource 直接权限](https://github.com/mlflow/mlflow/pull/24253)、[免凭证 `claude` stub 以评审 provider-gated 的 Assistant UI](https://github.com/mlflow/mlflow/pull/24225)。
  - 启示:MLflow 的 webhook/权限/Assistant 面正被当作企业级攻击面加固(SSRF、细粒度权限可见性)。我们若自建 MLOps 平台的 webhook/事件出站,DNS-rebinding SSRF 是需要主动防的一类。
- Feast:[新增 Aerospike OnlineStore](https://github.com/feast-dev/feast/pull/6532);多条 FIPS 合规工作(offline server 的 FIPS gRPC cipher suite、FIPS 模式探测回退日志)。
  - 启示:Feast 在补 FIPS 合规,这是面向受监管行业(金融/政务)的硬门槛;我们做特征/数据平台时,FIPS 模式是一个可直接对齐的合规卖点。

## LLM 评估 & 安全

- OGX(原 meta-llama/llama-stack,现 [ogx-ai/ogx](https://github.com/ogx-ai/ogx)):[strict TLS 模式(breaking)](https://github.com/ogx-ai/ogx/pull/5603)、[OTel 指标经 Prometheus scrape 端点暴露](https://github.com/ogx-ai/ogx/pull/6034)、[Responses memory 读路径](https://github.com/ogx-ai/ogx/pull/6162),并 pin 了 vLLM metrics 路由依赖。
  - 启示:Meta 把 llama-stack 独立成 OGX org 并主推"企业级默认安全"(强制 TLS)+ 标准可观测(OTel/Prometheus)。这是一个把推理+安全+工具打包的完整栈,和我们的平台定位有正面竞争,值得单列跟踪其 Responses/Agent API 契约。
- NVIDIA garak:本周仅 detector 单测与 NVCF 400 处理的死代码修复,无重大能力更新。
- lm-evaluation-harness:本周 0 commit,无更新。

## 值得跟进

- [ ] **更新追踪脚本的仓库清单**:training-operator->trainer、model-registry->hub、lingo->kubeai、llama-stack->ogx-ai/ogx(旧 slug 会 301,匿名 curl 不跟随会静默拿到 `Moved Permanently` JSON)。
- [ ] **kubeflow/hub 的 AI Hub v1 提案**([#2690](https://github.com/kubeflow/hub/pull/2690)):看它如何把 MCP/Agent catalog 与模型注册统一建模,对我们模型生命周期产品的信息架构有直接参考。
- [ ] **OGX(ogx-ai/ogx)** 作为"推理+安全+工具"整栈竞品:跟踪其 Responses API、strict TLS、OTel 默认化,评估与我们平台的差异点。
- [ ] **KV tiering 主线**:SGLang(NIXL + DRAM/SSD L3)、vLLM(多层 offload)、KServe(kvCacheOffloading)已合流;确认我们推理面板能按 tier(GPU/CPU/SSD)与 PD region 拆解 KV 命中/成本。
- [ ] **vLLM MRv2 默认化**:以 MRv2 为默认执行路径重跑推理回归基线(dense 模型已默认切换)。
- [ ] **MLflow webhook SSRF([#24258](https://github.com/mlflow/mlflow/pull/24258))**:如自建 MLOps 平台有事件出站/webhook,排查 DNS-rebinding SSRF 防护。
