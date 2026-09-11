# AI 推理 & MLOps 生态周报 2026-09-11

> 窗口:2026-09-04 ~ 2026-09-11。只筛"对做云原生 AI 基础设施产品有用"的变化;版本 bump / dependabot / CI / diffusion 等噪音已剔除。与 09-09 那期(窗口 09-02~09-09)有部分重叠的条目本期只保留新增进展。

## 摘要(5 条以内)

1. **vLLM 发 v0.29.0,并合入"水印生成 + 检测"(Gumbel-max)**:推理引擎首次把内容溯源/水印做进核心(#54053),这是合规(生成内容可标识)方向的信号,值得纳入我们"可信 AI / 内容溯源"能力清单。 https://github.com/vllm-project/vllm/releases/tag/v0.29.0
2. **KServe 发 v0.21.0-rc0,Helm 直接暴露 OCI 模型支持**:`enableOciModelSupport` / `ociModelMode` 进 chart values(#6152)——把"模型作为 OCI 制品"分发做成开箱可配,与我们模型打包/分发路线正面对标。 https://github.com/kserve/kserve/releases/tag/v0.21.0-rc0
3. **garak v0.17.0 带来 EU AI Act 映射**:红队工具把探针映射到欧盟 AI 法案条款(#2094),外加 package-hallucination 检测增强——安全测试正在向"合规可审计"演进,若我们做模型上线安全门禁应跟进。 https://github.com/NVIDIA/garak/releases/tag/v0.17.0
4. **MLflow 一轮企业级安全硬化(多个 GHSA)**:移除 basic-auth 默认管理员口令(GHSA-gq3w-7jj3-x7gr)、passthrough 路由不再转发客户端 auth header(#25129)、非管理员 UI 走 fail-closed 授权(#25672)——多租户/自托管部署面收敛,直接对标我们平台的鉴权基线。 https://github.com/mlflow/mlflow/pull/25751
5. **Ray Serve 自定义自动扩缩策略毕业到 beta**,同时 KubeRay 侧补齐生产化(RayCluster mTLS 指南、GCS 容错零停机升级、autoscaler `--gcs-address`)——大规模副本的扩缩容与 K8s 上的高可用在成熟。 https://github.com/ray-project/ray/pull/66058

---

## 推理引擎动态

### vLLM
`vllm-project/vllm`,发布 **v0.29.0**(2026-09-09)。 https://github.com/vllm-project/vllm/releases/tag/v0.29.0

- **水印生成与检测**:`[feature] Watermarked generation and detection (Gumbel-max algorithm)` (#54053)——引擎内置可选的生成水印+检测。这是"内容可溯源/可标识"这类合规诉求首次进入主流推理引擎核心,建议评估能否作为我们平台的一等能力(尤其面向监管敏感行业)。 https://github.com/vllm-project/vllm/pull/54053
- **前端多协议解耦**:`[Frontend][last/N] Move all non-OpenAI content out of the OpenAI folder` (#56369) 收尾了把非 OpenAI 内容移出 OpenAI 目录的重构;Rust frontend 继续硬化(强类型 wire dtype #56174、metrics 里 HTTP method 标签归一化 #56058)。前端从"OpenAI 兼容单体"走向"多协议可插拔",与网关多协议兼容是同一趋势。 https://github.com/vllm-project/vllm/pull/56369
- **鲁棒性**:`[Structured Output] Keep invalid structured-output requests from stopping the engine` (#51450)——非法结构化输出请求不再拖停整引擎;`[Bugfix][Core] Stop zero-progress preemption cascades for deferred KV frees` (#49675) 修复 KV 延迟释放导致的抢占级联。多租户共享引擎的隔离/降级在补齐。 https://github.com/vllm-project/vllm/pull/51450
- **CPU / 异构后端**:`[Model] Add DeepSeek-V4 CPU backend` (#55355)、`[Feature][SimpleCPU] Load fine-grained hybrid prefix hits` (#54736);另有大量 ROCm/XPU/NVFP4 算子(产品层可略)。

### SGLang
`sgl-project/sglang`,**v0.5.19**(2026-09-05,已在上期覆盖)。本期新增进展:

- **KV 分片系列启动**:`[kv-shard 1/4] Logical-page placement with UnifiedRadixCache` (#38356)——UnifiedRadixCache 上做逻辑页放置,是分布式 KV 缓存分片的第 1/4 步,后续值得追这条线。 https://github.com/sgl-project/sglang/pull/38356
- **Router / 健康就绪**:`[router] Raise chat body cap to 32 MB for multimodal payloads` (#38735) 放宽多模态请求体上限;`[Rust] Gate health on startup warmup completion` (#37994) 把健康检查门控在 warmup 完成后——K8s 就绪探针语义更准,避免流量打到未热引擎。 https://github.com/sgl-project/sglang/pull/37994
- **国产 NPU 主线延续**:`[NPU][Hicache] Optimize HiCache L2 IO with Memfabric acc_offload` (#38826)、GLM5.2 + FP8 DSA/Indexer kvcache for 950 (#38250)。
- **技术债清理**:`Delete cutlass_mla, non-Marlin GPTQ, AWQ AOT kernel, Dual Chunk Flash Attention` (#32114)——删除一批过时量化/kernel 路径,`msgspec.Struct` 化 config 层(#38753)。

### TensorRT-LLM / TGI / Ollama

- **TensorRT-LLM** `NVIDIA/TensorRT-LLM`,**v1.3.0rc26**(2026-09-09)。产品相关:
  - `[feat] Admit one context per uncached prefix instead of letting every duplicate recompute it` (#18195)——同一未命中前缀只准入一个 context,避免重复 prefill,直接省算力。 https://github.com/NVIDIA/TensorRT-LLM/pull/18195
  - `[feat] Improve KV event publish performance via StreamingEvent` (#17023)——KV 事件用流式发布提速,是缓存感知路由(cache-aware routing)的底座。 https://github.com/NVIDIA/TensorRT-LLM/pull/17023
  - `[feat] cuDNN attention backend` (#18075)、`[feat] Support image input in the Triton llmapi backend` (#18381)、disagg 编排重构进 `DisaggTransferCoordinator` (#18827);安全侧 `[feat] protect private model architecture names` (#18455)。 https://github.com/NVIDIA/TensorRT-LLM/pull/18455
- **TGI** `huggingface/text-generation-inference`:**无重大更新**(仓库已 archived,窗口内 0 提交,属正常停维护;建议下期起从数据源降级)。
- **Ollama** `ollama/ollama`,**v0.34.0**(2026-09-05)。主线仍是桌面 Agent 生态(Codex/ChatGPT Desktop 接入),基础设施借鉴有限;`server: extract GGUF metadata and unify capabilities` (#17858) 统一了模型能力探测,是唯一偏平台侧的点。 https://github.com/ollama/ollama/releases/tag/v0.34.0

## 模型服务 & 编排

### KServe 上游
`kserve/kserve`(上游,非 ODH fork),发布 **v0.21.0-rc0**(2026-09-10)。 https://github.com/kserve/kserve/releases/tag/v0.21.0-rc0

- **OCI 模型支持进 Helm**:`feat(helm): expose enableOciModelSupport and ociModelMode in chart values` (#6152)——把"模型作为 OCI 制品拉取/挂载"做成 chart 可配开关。模型分发走 OCI(镜像仓库统一治理、签名、缓存)是企业级刚需,建议对照我们模型分发方案的差距。 https://github.com/kserve/kserve/pull/6152
- **llmisvc 就绪/路由继续硬化**:`report HTTPRoutesReady after a route is observed` (#6164)、`recognizes header case-insensitively` (#6161)、`release terminating members from owned routes` (#6156)、`match group backends by their referenced pool` (#6149)。LLM ISVC 与 Gateway API InferencePool 的状态机/RBAC 在打磨成熟。 https://github.com/kserve/kserve/pull/6164
- **自动扩缩**:KEDA 升到 v2.20.2(#6153)。
- 注:上期的 `feat(api): InferenceService tracing configuration` (#6108) 本窗口正式合入。

### Ray
`ray-project/ray`(无新 release,2.58.0 仍为最新)。Serve/KubeRay 生产化是本期看点:

- **自定义自动扩缩策略毕业 beta**:`[serve][docs] Graduate custom autoscaling policies from experimental to beta` (#66058),配合 `[serve] Columnar zero-copy autoscaling-metrics codec` (#64281)(指标零拷贝编解码)——可插拔扩缩策略走向可用。 https://github.com/ray-project/ray/pull/66058
- **KubeRay 高可用/安全文档与能力**:`mTLS for RayClusters` (#65107)、`GCS fault tolerance with zero-downtime upgrades` (#66057)、`--gcs-address flag for kuberay_autoscaler` (#65894)。在 K8s 上跑 Ray 的生产化(零停机升级、mTLS)在补齐。 https://github.com/ray-project/ray/pull/66057
- **反序列化安全**:`[Data] Reject pickled-object columns in all ungated readers` (#66042)——所有未 gated reader 拒绝 pickle 对象列,和 MLflow/上期趋势一致,都在收 pickle RCE 面。 https://github.com/ray-project/ray/pull/66042
- **生产默认值**:`[serve] Production defaults for HAProxy connect timeout and dead-replica detection` (#65729)、`Aggregate autoscaling metrics only at the controller` (#65714,上期条目本窗口延续)。

> `kubeai-project/kubeai`(原 substratusai/lingo):**无重大更新**(窗口内 0 提交,真实静默,自 2026-07-30 无新提交)。

## 训练 & 微调

- **Kubeflow Trainer** `kubeflow/trainer`(原 training-operator,v2):本窗口**无实质功能更新**,仅 `chore: update trainer to k8s 1.37` (#4005) 与一批 dependabot。上期的 DRA(KEP-2782, #3540)是主线,本周无推进。 https://github.com/kubeflow/trainer/pull/4005
- **LLaMA-Factory** `hiyouga/LLaMA-Factory`:`[v1] Support multimodal Ulysses CP and memory-efficient chunk loss for SFT` (#10762)——多模态 Ulysses 上下文并行 + 省显存 chunk loss 进 SFT;`[KT] Support Kimi K2.5/2.6 LoRA fine-tuning` (#10826) 跟进新模型。长序列/多模态微调的工程能力在快速补齐。 https://github.com/hiyouga/LLaMA-Factory/pull/10762

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow** `mlflow/mlflow`(v3.16.0 于 09-04 发布,已在上期覆盖)。本窗口是一轮**集中的企业级安全硬化**,多条带 GHSA,值得逐条对照我们平台鉴权基线:
  - `Remove the default basic-auth admin password shipped in basic_auth.ini` (GHSA-gq3w-7jj3-x7gr, #25751)——移除出厂默认管理员口令。 https://github.com/mlflow/mlflow/pull/25751
  - `fix(gateway): stop forwarding client auth headers on passthrough routes` (#25129)——passthrough 路由不再泄露客户端 auth header。 https://github.com/mlflow/mlflow/pull/25129
  - `basic-auth: serve the web UI to non-admins under fail-closed authorization` (#25672)、`Authorize scorer/invoke and bind traces to the caller's experiment` (GHSA-6c27-cp6h-c66m, #25721)、`Enforce password policy on the basic-auth password-update path` (GHSA-v67f-7g57-fjhv, #25722)、`Fail fast when MLFLOW_FLASK_SERVER_SECRET_KEY is unset for basic-auth` (#25754)。 https://github.com/mlflow/mlflow/pull/25672
  - 另:`Add a timeout option to the @scorer decorator` (#25720)、`Enable async trace logging by default for Claude Code` (#25541)——评估器超时 + trace 异步落盘。
- **Kubeflow Model Registry** `kubeflow/model-registry`:延续 catalog 化,本周主线是**私有/门控(gated)模型接入**——`update hf models and sources for private/gated models` (#3184)、`enhance model preview with gated md` (#3189)、`Handle the preview gating in Add source form` (#3183),外加 `add endpoint to read and clear a source's persisted status` (#3159)。外部模型源(HF 私有仓)接入与目录治理直接对标我们模型目录能力。 https://github.com/kubeflow/model-registry/pull/3184
- **Feast** `feast-dev/feast`:**无重大更新**(窗口内仅 registry cache key 快照标签过滤 + Go 1.26 bump 两条)。

## LLM 评估 & 安全

- **garak** `NVIDIA/garak`,发布 **v0.17.0**(2026-09-09)。 https://github.com/NVIDIA/garak/releases/tag/v0.17.0
  - **EU AI Act 映射**:`EU AI Act Mapping` (#2094)——把探针/风险映射到欧盟 AI 法案条款,红队测试从"能不能越狱"走向"合规可审计报告"。若我们做模型上线安全门禁或合规报告,这是可直接借鉴的映射框架。 https://github.com/NVIDIA/garak/pull/2094
  - **package-hallucination 检测增强**:`packagehallucination misses dotted and indented imports` (#2108)、`misses packages after the first in import a, b` (#1991)——把"模型幻觉出不存在的依赖包"(slopsquatting 供应链风险)检测做全。 https://github.com/NVIDIA/garak/pull/2108
  - 报告聚合修复:`preserve attempt uuids when aggregating reports` (#2158)。
- **lm-evaluation-harness** `EleutherAI/lm-evaluation-harness`:**无重大更新**(v0.4.13 于 08-31 发布、恰在窗口外;窗口内仅 gguf logprobs 格式修复 #4012)。 https://github.com/EleutherAI/lm-evaluation-harness/releases/tag/v0.4.13
- **llama-stack** `meta-llama/llama-stack`:本窗口以维护为主——OGX 改名后的文档/引用清理(#6494、#6459)、`fix(ui): enable TypeScript build validation and fix 198 type errors` (#6480) + 生产依赖漏洞修复(#6479)、`update packages for CVE remediations` (#6488)、`docs(batches): clarify security model and add authorization tests` (#6485)。上期的多租户可配置(#6512)/异步 Milvus(#6493)已合入,无新方向。 https://github.com/meta-llama/llama-stack/pull/6480

## 值得跟进

- [ ] **vLLM 水印生成/检测(#54053)**:精读 Gumbel-max 实现与开销,评估作为我们平台"生成内容可溯源"合规能力的可行性与性能代价。
- [ ] **KServe OCI 模型分发(#6152, v0.21.0-rc0)**:对照我们模型打包/分发方案,评估走 OCI 制品(签名+镜像仓库统一治理)的迁移收益与差距。
- [ ] **garak EU AI Act 映射(#2094)**:把该映射框架接进我们模型上线前安全门禁,产出合规可审计报告。
- [ ] **MLflow 安全硬化清单(#25751 / #25129 / #25672 / #25721 / #25722)**:逐条核查我们自托管/多租户部署是否有等价基线(无默认口令、fail-closed 授权、不泄露 auth header)。
- [ ] **Ray KubeRay 生产化(#66057 mTLS/零停机升级)**:若我们编排层用到 Ray,评估零停机升级与 mTLS 的落地路径。
