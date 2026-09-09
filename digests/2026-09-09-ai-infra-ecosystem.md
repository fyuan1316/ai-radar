# AI 推理 & MLOps 生态周报 2026-09-09

> 窗口:2026-09-02 ~ 2026-09-09。只筛"对做云原生 AI 基础设施产品有用"的变化,版本 bump / dependabot / CI 噪音已剔除。

## 摘要(5 条以内)

1. **KServe 上游把"供应链安全"下沉到 kernelcache**:本周连续合入签名契约(signing contract)与 cert-mode 签名验证,配合 llmisvc 的 InferencePool 自动打标/路由治理,是最值得对标的一块。
2. **Kubeflow Trainer 落地 DRA(KEP-2782)**:TrainJob 开始支持 Dynamic Resource Allocation,GPU/加速器申领方式向 K8s 原生 DRA 收敛——训练侧调度模型要跟进了。
3. **TensorRT-LLM 给 trtllm-serve 加了 Anthropic Messages API**:推理服务网关从"OpenAI 兼容"扩到"Anthropic 兼容",多 API 协议兼容正在成为推理引擎标配。
4. **vLLM 的分离式(disaggregated)serving 持续硬化**:Elastic EP 缩容只路由存活引擎、KV/NIXL 支持 per-region 传输几何、EC(encoder cache)连接器容错——大规模分布式推理的工程细节在补齐。
5. **MLflow v3.16.0 收紧反序列化安全**:skops 模型加载被 `MLFLOW_ALLOW_PICKLE_DESERIALIZATION` 开关拦住(默认关);llama-stack 则把租户维度做成可配置——两边都在往企业级多租户/安全靠。

---

## 推理引擎动态

### vLLM
`vllm-project/vllm`,本周提交量很大,几个方向对我们有参考价值:

- **分离式 serving 容错**:`[Elastic EP] Route only to surviving engines during scale-down` (#55772)、`[EC Connector] Fail the request, not the engine, when a remote encoding cannot arrive` (#55290)、`[KV Connector] Resolve connector block tables for every scheduled request` (#54853)。方向是"缩容/远端组件失败时,别把整引擎拖垮"——PD 分离、EP 弹性这类拓扑越来越像分布式系统在做优雅降级。 https://github.com/vllm-project/vllm/pull/55772
- **KV 传输**:`[KV Connector][NIXL] Support per-region transfer geometry` (#53780),NIXL 传输开始支持按区域切分几何,利于跨 NUMA/跨卡的 KV 搬运。 https://github.com/vllm-project/vllm/pull/53780
- **Rust frontend 持续演进**:多条 `[Rust Frontend]` 提交(推理解析、reasoning parser 初始化),vLLM 前端在往 Rust 迁移,值得关注其对多语言/低延迟前置层的取舍。 https://github.com/vllm-project/vllm/pull/55417
- 其余大量 NVFP4 kernel / ROCm 性能提交,偏底层算子,产品层可略。

### SGLang
`sgl-project/sglang`,发布 **v0.5.19**(2026-09-05)。 https://github.com/sgl-project/sglang/releases/tag/v0.5.19
产品相关信号:

- **`[Scheduler] Add HRRN schedule policy to significantly reduce TTFT` (#32911)**:调度器新增 HRRN(最高响应比优先)策略,官方称显著降 TTFT——对"多租户共享推理服务的公平性/首 token 延迟"有直接借鉴。 https://github.com/sgl-project/sglang/pull/32911
- **`[HiCache] Add MLA host-dedup primitives` (#36800)**:HiCache 加 MLA 主机侧去重原语,分层 KV 缓存继续做省显存/省内存。 https://github.com/sgl-project/sglang/pull/36800
- **国产 NPU/Ascend 支持在推进**:`[NPU] Add sparsity-driven KV offload for DeepSeek DSA on Ascend` (#33089)、URMA/host RDMA 传输类型等。国产算力适配是 SGLang 本周的一条明显主线。 https://github.com/sgl-project/sglang/pull/33089
- 注:本周相当比例提交是 diffusion(图像/视频生成)方向,已跳过。

### TensorRT-LLM / TGI / Ollama

- **TensorRT-LLM** `NVIDIA/TensorRT-LLM`:重点是 **`Add Anthropic Messages API support to trtllm-serve` (#18289)**——推理网关从 OpenAI 兼容扩到 Anthropic 兼容;另有 `Support in-graph sampling for temperature/top-k/top-p batches` (#18437) 把采样搬进 graph,以及通过 ModelExpress 策略委托 MX 权重加载 (#17029)。多协议兼容 + 图内采样是两个可跟的工程点。 https://github.com/NVIDIA/TensorRT-LLM/pull/18289
- **TGI** `huggingface/text-generation-inference`:**无重大更新**——仓库已 archived(最后 push 2026-03),窗口内 0 提交属正常停维护,后续可从本周报数据源降级。
- **Ollama** `ollama/ollama`:发 v0.33.3 与 v0.34.0-rc3。本周主线是**桌面 Agent 生态**——大量 `app:`/`openai:` 提交把 Codex、ChatGPT Desktop 接进来(Codex 默认启动、compaction、client tool search),外加 MLX runner(gemma4 图像+音频输入、结构化输出用 xgrammar)。基础设施层借鉴有限,但反映"本地推理 + 桌面 Agent"路线在加速。 https://github.com/ollama/ollama/releases/tag/v0.34.0-rc3

## 模型服务 & 编排

### KServe 上游
`kserve/kserve`(上游,非 ODH fork)。本周是全表最值得看的一块:

- **kernelcache 供应链安全**:`feat(kernelcache): add signing contract` (#6118) + `cert-mode signature verification` (#6103) + `refactor(kernelcache): extract security data contracts into types package` (#6130)。KServe 在给模型/内核缓存加签名与证书模式验签——正好对标企业级"模型来源可信 / 供应链完整性"诉求,建议重点研读其数据契约设计。 https://github.com/kserve/kserve/pull/6118
- **llmisvc(LLM InferenceService)治理成熟化**:`automatically label workloads with InferencePool ref` (#5624)、`match group backends by their referenced pool` (#6149)、`release terminating members from owned routes` (#6156)、`grant events create/patch to the scheduler Role` (#6142)。LLM 专用 ISVC 与 Gateway API InferencePool 的绑定/路由/RBAC 在补齐,是 KServe LLM 路线的核心。 https://github.com/kserve/kserve/pull/5624
- **可观测**:`feat(api): add InferenceService tracing configuration` (#6108),ISVC 级 tracing 配置进 API。 https://github.com/kserve/kserve/pull/6108
- 其它:storage-initializer 加 Power 架构支持 (#5235)、autogluon 修路径穿越漏洞 (#5802)、Go 升到 1.26。

### Ray
`ray-project/ray`。Serve/LLM 侧几条:

- **`[serve] Aggregate autoscaling metrics only at the controller` (#65714)**:自动扩缩指标只在 controller 侧聚合,减少 proxy 侧开销——大规模副本下的扩缩容架构参考。 https://github.com/ray-project/ray/pull/65714
- **`[serve][llm] Add RunAI streamer release test` (#66005)** 与 `[llm] Fix s3:// model_source dropped for streaming load formats` (#65753):模型流式加载(RunAI streamer / S3 源)在 serve-llm 侧被正式测试与修复。 https://github.com/ray-project/ray/pull/66005
- **`[core][sandbox] Isolate network="public" sandboxes in per-sandbox netns via pasta` (#65820)**:沙箱按 netns 隔离网络——多租户/不可信代码执行的安全隔离思路。 https://github.com/ray-project/ray/pull/65820
- GPU fraction 系列 (#63184) 继续把节点资源可用量封装,细粒度 GPU 共享在铺路。

> 注:`substratusai/lingo` 已演进为 `kubeai-project/kubeai`,该仓自 2026-07-30 起无提交,**无重大更新**(真实静默)。

## 训练 & 微调

- **Kubeflow Trainer** `kubeflow/trainer`(原 training-operator,v2):**`feat(api): KEP-2782: Dynamic Resource Allocation support for TrainJob` (#3540)**——TrainJob 接入 K8s DRA,加速器申领从 device-plugin 老路往 DRA 迁移。这是训练侧调度的方向性变化,建议评估我们训练产品的 DRA 路线图。 https://github.com/kubeflow/trainer/pull/3540
- **LLaMA-Factory** `hiyouga/LlamaFactory`:`[train] support HyperParallel Expert-Parallel` (#10811) 加专家并行、`[model] add Qwen3.8 model support` (#10749)。微调框架跟进 MoE 专家并行 + 新模型,速度依旧很快。 https://github.com/hiyouga/LlamaFactory/pull/10811

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow** `mlflow/mlflow`,发 **v3.16.0**(2026-09-04)。 https://github.com/mlflow/mlflow/releases/tag/v3.16.0
  - 安全:`Gate skops model loading behind MLFLOW_ALLOW_PICKLE_DESERIALIZATION` (#25686),默认拦住 pickle 反序列化——供应链/RCE 面收敛。 https://github.com/mlflow/mlflow/pull/25686
  - 治理:`Record scorer versions in assessment metadata` (#25570)、`Support span links for Unity Catalog traces` (#25597)、`Require model_id permission for LogMetric/LogBatch` (#25664)——评估版本化、trace 血缘、按模型鉴权都在往企业级走。 https://github.com/mlflow/mlflow/pull/25570
- **Kubeflow Model Registry** `kubeflow/model-registry`:本周主线是 **model catalog 接 HuggingFace**——HF access token 校验 (#3167)、按来源解析 HF API key (#3171)、按 access type 渲染 catalog 卡片/详情 (#3169)。Registry 正在"catalog 化 + 外部模型源接入",与我们模型目录能力直接对标。 https://github.com/kubeflow/model-registry/pull/3171
- **Feast** `feast-dev/feast`:**无重大更新**(最后提交 2026-08-28,窗口内静默)。

## LLM 评估 & 安全

- **lm-evaluation-harness** `EleutherAI/lm-evaluation-harness`:**无重大更新**(最后提交 2026-09-01,恰在窗口外;上一条是插件化 filter/metric 注册 #4014)。
- **garak** `NVIDIA/garak`:红队工具的稳健性修复为主——`Fix: indefinite hang on OpenAICompatible unreachable targets` (#2153)、init 时校验 URI 连通性、`type-validate agent_breaker judge verdicts` (#2121)。若我们把 garak 接进模型上线前的安全门禁,这些连通性/判定健壮性修复值得纳入。 https://github.com/NVIDIA/garak/pull/2153
- **llama-stack** `meta-llama/llama-stack`(release 仍发在此仓):`ci: Make tenancy configurable`(#6512)+`fix: qualify tenant column in PostgreSQL upserts` (#6509) 把**多租户**做成一等公民;`migrate MilvusClient to AsyncMilvusClient` (#6493) 向量 IO 全异步化;`update packages for CVE remediations` (#6488)。多租户 + 异步向量库是两条产品相关线。 https://github.com/meta-llama/llama-stack/pull/6512

## 值得跟进

- [ ] **KServe kernelcache 签名/验签设计**(#6118 / #6103 / #6130):精读其 security data contracts,评估能否对齐我们"模型供应链可信"能力。
- [ ] **Kubeflow Trainer DRA(KEP-2782, #3540)**:训练侧加速器申领是否要跟进 DRA;与我们现有 device-plugin/调度方案的迁移成本。
- [ ] **推理网关多协议兼容**:TRT-LLM 已加 Anthropic Messages API(#18289),评估我们网关是否要在 OpenAI 兼容之外补 Anthropic 兼容。
- [ ] **vLLM/SGLang 分离式 serving 与调度**:vLLM Elastic EP 缩容路由(#55772)、SGLang HRRN 降 TTFT(#32911)——纳入我们推理调度/降级策略的对标清单。
- [ ] **MLflow 反序列化安全开关(#25686)**:检查我们模型加载路径是否有等价的 pickle/skops 反序列化防护默认关。
