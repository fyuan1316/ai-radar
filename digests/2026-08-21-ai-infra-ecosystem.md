# AI 推理 & MLOps 生态周报 2026-08-21

> 窗口:2026-08-14 ~ 2026-08-21。只筛对"做云原生 AI 基础设施产品(对标 OpenShift AI)"有用的变化;版本 bump / dependabot / CI 噪音已跳过。

## 摘要(5 条以内)

1. **KServe v0.20.0 把 `LLMInferenceService`(llmisvc)推成一等公民**:模型级路由门控、LoRA-affinity 自动调度、KEDA 自动扩缩、PVC/ModelScope 存储、vLLM 作为正式 runtime——这是最值得对标的一条主线。
2. **推理引擎集体上"新模型 + 投机解码 + KV 缓存"三件套**:vLLM 铺 Kimi K3/DSv4 与 DFlash2 投机解码并把前端重写为 Rust;SGLang 把 unified radix tree 设为全局默认并扩到 diffusion;TensorRT-LLM 上 Kimi K3 NVFP4。
3. **Ray Serve LLM 补齐生产化能力**:scale-to-zero + gang scheduling、KV-aware 路由与原生 KV 卸载文档、ai-dynamo 1.4.0 集成、TPU serving。
4. **MLflow 把 "Red Hat OpenShift AI" 列为官方 hosting 选项**,并继续加码 GenAI 评估(内置 judge 接 UC model services、自定义 trace 视图);Feast v0.66 operator 接入 MLflow + OpenLineage 血缘。
5. **Kubeflow 侧两条线**:Trainer v1.9.4 给 controller 加 TLS + RBAC 鉴权、支持 GGUF 快照下载;Model Registry 正快速"catalog 化"(skill catalog / MCP / marketplace,v1 API 定型)。

---

## 推理引擎动态

### vLLM
最新 tag v0.27.1(8/11,窗口前);窗口内 main 高频提交,主题清晰:
- **Rust 前端重写持续推进**:用纯 Rust 的 `protox` 替换外部 `protoc`([#52892](https://github.com/vllm-project/vllm/pull/52892))、新增 HY3 统一解析器 + 本地 XGrammar structural-tag builder([#53054](https://github.com/vllm-project/vllm/pull/53054))、`--generation-config vllm`([#53044](https://github.com/vllm-project/vllm/pull/53044))。前端从 Python 迁往 Rust 是架构级动作,值得盯长期影响。
- **投机解码**:DFlash2(local convolution + candidate selector,[#52816](https://github.com/vllm-project/vllm/pull/52816))、DSv4+sm90 自适应验证([#52795](https://github.com/vllm-project/vllm/pull/52795))、OpenAI API 里返回 per-request 接受率统计([#48915](https://github.com/vllm-project/vllm/pull/48915))。
- **新模型/新硬件**:Kimi K3 nvfp4 checkpoint([#53132](https://github.com/vllm-project/vllm/pull/53132))、GEMM-RS→GEMM-AR([#53053](https://github.com/vllm-project/vllm/pull/53053));FlashInfer TRTLLM MXFP8 linear backend([#52204](https://github.com/vllm-project/vllm/pull/52204));Model Runner V2 支持 extract_hidden_states 投机([#49811](https://github.com/vllm-project/vllm/pull/49811))。
- **对我们产品的启示**:投机解码正从"实验特性"变成"带可观测统计的标配";若我们做推理平台,应把 acceptance-rate 之类指标纳入默认 metrics 面板。

### SGLang
最新 tag v0.5.17(8/8);窗口内两条大主题:
- **unified radix tree 设为所有场景默认**([#35081](https://github.com/sgl-project/sglang/pull/35081)),并给 SWA 混合模型加 decode 侧 radix cache([#27770](https://github.com/sgl-project/sglang/pull/27770));PD 传输支持 mxfp8 KV cache([#35718](https://github.com/sgl-project/sglang/pull/35718));gRPC 暴露 KV event discovery 元数据([#35714](https://github.com/sgl-project/sglang/pull/35714))——都是 P/D 分离 + 前缀缓存路由的基础设施。
- **扩张到 diffusion**:支持 out-of-tree 模型与 pipeline([#35713](https://github.com/sgl-project/sglang/pull/35713))、层级组件可配置([#35688](https://github.com/sgl-project/sglang/pull/35688))、LTX-2.5 解码融合。SGLang 不再只是 LLM 引擎,开始做多模态/扩散统一栈。
- **启示**:KV event 元数据 + radix cache 默认化,是"缓存感知路由"落地的信号;做 gateway/scheduler 的话可对接这类 KV 事件做亲和路由(与 KServe llmisvc、Ray KV-aware 路由是同一趋势)。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:活跃(最新 v1.3.0rc24)。实质进展:Kimi K3 NVFP4 用 CUTLASS + cuteDSL MegaMoE 打通([#17865](https://github.com/NVIDIA/TensorRT-LLM/pull/17865))、Qwen3.5/3.8 性能 wave([#17700](https://github.com/NVIDIA/TensorRT-LLM/pull/17700));其余多为 nvbugs 修复 / CI waive 噪音。
- **TGI**:仍处 archived 状态(最后 push 2026-03-21),窗口内无更新——属正常停维护,非抓取错误。
- **Ollama**:窗口内连发 v0.32.12→v0.32.15。看点:内置 Claude 桌面 App 集成([#17899](https://github.com/ollama/ollama/pull/17899))、MLX 后端修好 linux/windows 假设([#17898](https://github.com/ollama/ollama/pull/17898))往非 Mac 平台铺、加模型元数据缓存降低每请求开销([#17752](https://github.com/ollama/ollama/pull/17752))、qwen3.8 渲染与 MLX 导入支持。Ollama 在往"跨平台本地 runtime + 桌面生态入口"走。

---

## 模型服务 & 编排

### KServe 上游
v0.20.0(8/6 tag,窗口内 main 继续)是本周最值得对标的一条。`LLMInferenceService`(llmisvc)持续加码:
- **模型级路由门控 + status 里暴露 models**([#5579](https://github.com/kserve/kserve/pull/5579))、**LoRA adapter 自动启用 lora-affinity-scorer**([#5655](https://github.com/kserve/kserve/pull/5655))、EPP 探针/grace period 调优([#5602](https://github.com/kserve/kserve/pull/5602))——这是 Gateway API Inference Extension 路线的实装。
- **KEDA 独立自动扩缩 e2e**([#6018](https://github.com/kserve/kserve/pull/6018))、scheduler v0.6→v0.7 迁移 e2e([#5564](https://github.com/kserve/kserve/pull/5564))、PVC 存储 e2e([#5623](https://github.com/kserve/kserve/pull/5623))。
- **存储**:新增 ModelScope(`ms://`)下载([#5330](https://github.com/kserve/kserve/pull/5330))、多 OCI source([#5470](https://github.com/kserve/kserve/pull/5470))、显式 `storageContainerName` 选择 CSC([#5314](https://github.com/kserve/kserve/pull/5314));**vLLM 正式作为 supported runtime**([#4769](https://github.com/kserve/kserve/pull/4769));transformer→predictor 转发 Authorization 头([#5567](https://github.com/kserve/kserve/pull/5567))。
- **对我们产品的启示**:KServe 的推理服务重心已从"单模型 InferenceService"迁到"多模型 + LoRA + KV/模型感知路由 + KEDA"的 `LLMInferenceService`。若我们对标 OAI,这是必须跟进的能力矩阵:模型级路由、LoRA-affinity 调度、scale-to-zero、ModelScope/OCI 多源存储。

### Ray
ray-2.57.0(8/11);Serve/LLM 侧生产化补齐:
- **Serve 支持 scale-to-zero + gang scheduling**([#65575](https://github.com/ray-project/ray/pull/65575))、应用/部署未找到返回 404([#65584](https://github.com/ray-project/ray/pull/65584))。
- **LLM**:KV-aware 路由指南 + 原生 KV cache 卸载文档([#65569](https://github.com/ray-project/ray/pull/65569))、用官方 `ai-dynamo` 1.4.0 wheel([#65549](https://github.com/ray-project/ray/pull/65549))、TPU serving 文档([#65026](https://github.com/ray-project/ray/pull/65026));同步 vendored KubeRay CRD 参考([#65618](https://github.com/ray-project/ray/pull/65618))。
- **启示**:Ray Serve 的 scale-to-zero + gang scheduling + KV-aware 路由,与 KServe llmisvc 是正面竞争关系;两家都在把"KV/前缀缓存感知路由"做成标准能力。

---

## 训练 & 微调

- **Kubeflow Trainer v1.9.4**(8/18):controller metrics endpoint 加 TLS + RBAC 鉴权([#3912](https://github.com/kubeflow/trainer/pull/3912))、TrainJobStatus server 注册 healthz/readyz 探针([#3338](https://github.com/kubeflow/trainer/pull/3338))、initializer 允许 HF 模型快照下载 GGUF([#3910](https://github.com/kubeflow/trainer/pull/3910))、加 add-new-crd 的 `.agents` skill([#3837](https://github.com/kubeflow/trainer/pull/3837))。Trainer v2 在补企业级安全与健康探针,是可对标的成熟度信号。
- **LLaMA-Factory**:窗口内仅 2 提交但有料——`[v1] support GDN Ulysses cp`([#10727](https://github.com/hiyouga/LLaMA-Factory/pull/10727))、**KTransformers VLM 微调支持**([#10760](https://github.com/hiyouga/LLaMA-Factory/pull/10760),接入 KTransformers 做 VLM 微调,值得关注异构/低显存路线)。当前稳定版仍 v0.9.5(5 月),v1 在 main 演进。

---

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow**:两点值得记。一是 **把 "Red Hat OpenShift AI" 加进官方 hosting options**([#25151](https://github.com/mlflow/mlflow/pull/25151))——OAI 生态影响力的直接证据;二是持续加码 GenAI 评估与可观测:内置 judge 接 Unity Catalog model services([#25246](https://github.com/mlflow/mlflow/pull/25246))、自定义 trace 视图([#25104](https://github.com/mlflow/mlflow/pull/25104))、basic-auth 按 job/experiment 粒度做权限门控([#25069](https://github.com/mlflow/mlflow/pull/25069))。
- **Kubeflow Model Registry**:正快速"catalog 化"。窗口内定型 v1 API handlers([#3065](https://github.com/kubeflow/model-registry/pull/3065))、强制 v1 命名规范并清理弃用参数([#3086](https://github.com/kubeflow/model-registry/pull/3086))、从 v1alpha1 移除 skill catalog 端点([#3103](https://github.com/kubeflow/model-registry/pull/3103));加 skill 源预览/marketplace([#3087](https://github.com/kubeflow/model-registry/pull/3087))、Python client([#3083](https://github.com/kubeflow/model-registry/pull/3083))、MCP 详情页。Registry 从"模型注册"扩到"model + skill + MCP catalog / marketplace",方向值得警惕对标。
- **Feast v0.66.0**(8/21):operator 侧成熟度显著——FeatureStore CR 支持 tolerations/nodeSelector([#6741](https://github.com/feast-dev/feast/pull/6741))、**operator 接入 MLflow 集成**([#6611](https://github.com/feast-dev/feast/pull/6611))、OpenLineage 血缘全对象覆盖 + API 级同步([#6719](https://github.com/feast-dev/feast/pull/6719))、DataSource 加 ConnectionRef 做可插拔外部凭据解析、HybridOfflineStore 支持([#6707](https://github.com/feast-dev/feast/pull/6707))。血缘(OpenLineage)+ operator 化是特征平台的企业级方向。

---

## LLM 评估 & 安全

- **lm-evaluation-harness**(仍 v0.4.12,5 月;main 活跃):支持 chat completions 的 `think_end_token`([#3959](https://github.com/EleutherAI/lm-evaluation-harness/pull/3959))以适配 reasoning 模型;新增基准 legalbench Contract NLI([#3954](https://github.com/EleutherAI/lm-evaluation-harness/pull/3954))、Putnam Axiom([#3998](https://github.com/EleutherAI/lm-evaluation-harness/pull/3998));Gemma3 多模态 max_length 检测修复。评测正把 reasoning 模型的 think token 纳入标准处理。
- **garak v0.16.0**:主要是维护——弃 py3.10 加 py3.13([#2084](https://github.com/NVIDIA/garak/pull/2084))、analyze 从 attack hits 重建置信区间([#2050](https://github.com/NVIDIA/garak/pull/2050))、若干 probe/detector 健壮性修复(badchars、MarkdownExfilContent ZeroDivisionError)。无重大新攻击面。
- **llama-stack**(窗口内 v1.2.3、v1.2.4):vector-io 把 vector store 元数据持久化进 kvstore(Milvus/Chroma/Weaviate,[#6371](https://github.com/meta-llama/llama-stack/pull/6371))、可关闭 chat completions 持久化([#6412](https://github.com/meta-llama/llama-stack/pull/6412))、新增 local_api_key auth provider([#6400](https://github.com/meta-llama/llama-stack/pull/6400));内部 `ogx` 改名仍在进行(server 默认绑 localhost、Meta AI 自动探测)。

> KubeAI(原 substratusai/lingo)本周 0 提交,延续 7 月底以来的静默,非抓取错误。

---

## 值得跟进

- [ ] **精读 KServe llmisvc 路由/调度设计**:模型级路由门控([#5579](https://github.com/kserve/kserve/pull/5579))+ LoRA-affinity 自动调度([#5655](https://github.com/kserve/kserve/pull/5655)),对照我们产品的推理路由能力做 gap 分析。
- [ ] **对比 KServe llmisvc vs Ray Serve LLM 的 KV-aware 路由 + scale-to-zero**([Ray #65575](https://github.com/ray-project/ray/pull/65575) / [#65569](https://github.com/ray-project/ray/pull/65569)):两条路线选型,评估我们该跟哪套。
- [ ] **评估 SGLang unified radix tree 默认化 + KV event 元数据**([#35081](https://github.com/sgl-project/sglang/pull/35081) / [#35714](https://github.com/sgl-project/sglang/pull/35714)):看能否作为我们缓存感知路由的上游对接点。
- [ ] **跟踪 vLLM Rust 前端重写**:评估其对我们打包/扩展 vLLM 的兼容性影响(protox、structural-tag、generation-config 一系列 Rust 化 PR)。
- [ ] **看 MLflow 把 OAI 列为 hosting option 的落地文档**([#25151](https://github.com/mlflow/mlflow/pull/25151)):我们的平台是否也应成为 MLflow 官方 hosting 目标之一。
- [ ] **关注 Kubeflow Model Registry 的 skill/MCP catalog 化**([#3065](https://github.com/kubeflow/model-registry/pull/3065)):判断"model + skill + MCP marketplace"是否会成为标配,提前规划我们注册中心的边界。
