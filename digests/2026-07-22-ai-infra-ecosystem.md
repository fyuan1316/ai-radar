# AI 推理 & MLOps 生态周报 2026-07-22

覆盖窗口:2026-07-15 ~ 07-22(过去 7 天)。只筛与"做云原生 AI 基础设施产品(对标 OAI)"相关的实质变化,版本 bump / dependabot / CI 噪音已剔除。

## 摘要(5 条)

1. **KServe v0.20.0-rc0 切出**,`LLMInferenceService`(llmisvc)本轮是绝对主角:新增 **DRA(Dynamic Resource Allocation)托管支持**、RawDeployment 金丝雀滚动、**Anthropic Messages API(`v1/messages`)HTTPRoute**、分布式追踪 API、GIE 升到 v1.5.0。这是我们 serving 层最该对齐的上游路线。https://github.com/kserve/kserve/releases/tag/v0.20.0-rc0
2. **Kubeflow Trainer 引入 `OptimizationJob` CRD(KEP-3562)**——把超参优化/HPO 收进 Trainer v2 原生 CRD,并做了 "移除 Runtime Finalizers" 的 BREAKING 变更。训练编排的形态在收敛。https://github.com/kubeflow/trainer/pull/3565
3. **MLflow 与 Kubeflow model-registry 双双"长出" MCP / Agent 目录能力**:MLflow 新增 MCP Server Registry(带鉴权加固),model-registry 整轮在做 Agents Catalog(Gallery/Details/artifacts 端点)。模型生命周期工具正集体向"Agent 注册中心"扩边界。
4. **TensorRT-LLM 宣布弃用 AutoDeploy 后端**,改走"agentic 方式"在 PyTorch 后端加速新模型支持;同时 DeepSeek V3.2/V4 与 disaggregated serving 仍列大量 known issues。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc21
5. **KubeAI(原 Lingo)v0.23.3** 加了 **OCI 镜像作为模型源** 与 **`/v1/responses` API**;Feast 0.65.0 一次性接入 Aerospike / ScyllaDB(带向量检索)/ Iceberg REST Catalog 三个数据源并上了 OpenLineage 血缘。

---

## 推理引擎动态

### vLLM
无新 release,但主干持续大改,几条对 infra 有意义:
- **Rust 前端在成型**:本周多个 `[Rust][Benchmark]`/`[Rust Frontend]` 提交(async HTTP 客户端、tracing 日志、修 logprobs 空列表 panic #49113)。vLLM 正把 serving 前端从 Python 迁向 Rust,值得关注对我们网关层的启示。
- **ModelRunner V2(MRV2)** 收尾:capture-time 构建 attn metadata(#49364)、encoder cache profiling(#47985)、FULL CUDA graph 前置 graph_pool_id(#48843)。
- **KV connector**:修了 KV connector defer 请求时 prefix-cache 指标双计(#48860)——多级缓存/PD 分离场景的可观测性细节。
- DeepSeek-V4 路径开始进主干(XPU `fuse_index_q` SYCL kernel #45991)。
来源:https://github.com/vllm-project/vllm/commits/main

### SGLang
- **JIT/kernel 大重构(RFC #29630)**:把 JIT 基建 + 算子组迁进 `sglang.kernels`(#31666),trait 驱动统一 per-token-group 量化 kernel 家族(#30924)。工程化收敛,利于后续可维护性。
- **HiCache(分层缓存)** 持续打磨:异构 MHA 的 staged write-back(#30981)、混合/DSA L3 预取结果同步与可用前缀 clamp(#31443)。多级 KV 缓存是它相对 vLLM 的差异化重点。
- **PD 分离(EPD)** encoder 注册/健康检查健壮化(#31576);Mamba + 投机解码支持(#30437)。
- DeepSeek-V4 在 sglang 0.5.15 上重新压测(#31363)。
来源:https://github.com/sgl-project/sglang/commits/main

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc21**:**AutoDeploy 后端弃用**(转 agentic 提速模型支持);classic IPC executor 上多进程 HTTP 前端(#16523);CuTE-DSL top-k decode 上限提到 16384(#16546);attention DP 下的 rejection sampling(#16544)。Release note 里 DeepSeek V3.2/V4、disaggregated serving 的 known issues 很长,B300/NVFP4 精度与多卡稳定性仍是坑。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc21
- **TGI(huggingface/text-generation-inference)**:本窗口 0 提交,**无重大更新**。
- **Ollama v0.32.1 / v0.32.2**:整轮几乎全是 **agent + skills system**(#17203)、Claude Code channels、Anthropic 集成、无限工具轮次(#17217);基建侧仅 CUDA on Windows ARM64(#16931)、iGPU dio。Ollama 正从"本地推理"转型成"本地 agent 客户端",与我们服务端产品交集变小,但产品形态值得看。https://github.com/ollama/ollama/releases/tag/v0.32.2

---

## 模型服务 & 编排

### KServe 上游
v0.20.0-rc0 的 llmisvc 是本周全生态最密集的信号,拣对我们最有借鉴的:
- **DRA 支持双管齐下**:ServingRuntime 加 `resourceClaims`(#5828)+ llmisvc 的 Managed DRA(#5352)。GPU/加速器分配从 device-plugin 往 DRA 迁,这是 K8s 1.3x 的调度大方向,我们 serving 栈要提前对齐。
- **多协议接入**:新增 **Anthropic Messages API `v1/messages` HTTPRoute**(#5648)——单一 ISVC 暴露多套 LLM API 契约,是网关层差异化点。
- **金丝雀发布**:RawDeployment 模式的 canary rollout(#5672)+ 全套 e2e 生命周期测试,llmisvc 的渐进式发布逐渐生产可用。
- **路由/调度**:模型级路由 gate 与 status 里带 models(#5579)、LoRA adapter 自动启用 lora-affinity-scorer(#5655)、GIE 升到 **v1.5.0** 并带 InferencePool v1alpha2 shim(#5571)。
- **架构清理**:用 vLLM render deployment 替换 UDS tokenizer sidecar(#5712);CRD 拆分为可独立安装(#5843);storageUris 支持多个 OCI 源(#5470)并给出 OCI 模型交付路径的启动基准(#5852);分布式追踪 API(#5481)。
来源:https://github.com/kserve/kserve/releases/tag/v0.20.0-rc0

### Ray(2.56.1)
- **Ray Serve LLM**:修 direct-streaming 路由——`PrefixCacheAffinityRouter` 等 body-aware 路由在 `RAY_SERVE_LLM_ENABLE_DIRECT_STREAMING=1` 下不再 hang(#64488);ingress 请求路由按 proxy 节点扩副本(#64724)。前缀缓存亲和路由是 LLM serving 的关键降本手段。
- **Ray Core**:内存监控新增 **system-slice 压力早检**——用户/系统 cgroup 一起快照,超 `--system-reserved-memory` 就告警,防节点被 OOM 杀(#64492);`ray start --block` 收到 SIGTERM 先 drain 节点(#64454)。K8s 上跑 Ray 的稳定性改进。
- **Ray Data**:DataSource V2 默认开启(#64821);**Unity Catalog 写入(Parquet/Iceberg)**(#64519);shuffle v2 上聚合。
- **Ray Train**:v1/v2 统一走 autoscaling coordinator(#64824)。
来源:https://github.com/ray-project/ray/releases/tag/ray-2.56.1

### KubeAI(原 substratusai/lingo → kubeai-project/kubeai)v0.23.3
- **OCI 镜像作为模型源**(#661)——和 KServe 的多 OCI 源同频,OCI 正成为模型分发事实载体。
- **`/v1/responses` API 支持**(#667,对齐 OpenAI Responses API)、external LB(#655)、Helm 暴露 `proxy.mode`(#670)。
- 排除 terminating pod 参与滚动计划计算(#659),空转/滚动稳定性修复。
来源:https://github.com/kubeai-project/kubeai/releases/tag/v0.23.3

---

## 训练 & 微调

### Kubeflow Trainer(原 kubeflow/training-operator → kubeflow/trainer)
- **`OptimizationJob` CRD(KEP-3562)**(#3565):Trainer v2 原生 HPO/超参优化 CRD,等于把 Katib 的能力形态收进 Trainer 主线。做训练平台的要重点跟踪它与 TrainJob 的关系。
- **BREAKING:移除 Runtime Finalizers**(#3716);MPI launcher 依赖 worker readiness 后再起(#3748);PodSet Container 暴露 Image/Command(#3674);runtime 资源与 Runtime 容器资源合并(#3602)。
来源:https://github.com/kubeflow/trainer/commits/master

### LLaMA-Factory(hiyouga)
本窗口仅 3 个实质提交:v1 重构下修 grad norm/lr 日志(#10640)、**新增 Muon 优化器**(#10618)、AMD GPU Cloud 文档。**基本无重大更新**。
来源:https://github.com/hiyouga/LLaMA-Factory/commits/main

---

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
- **MCP Server Registry 成型**:新增 Swagger UI API 文档(#24519)+ 加固鉴权/校验/迁移边界(#24479)。MLflow 正把自己做成 MCP server 的注册与治理中心,和"模型注册中心"平级的新资产类型。
- **MLflow Assistant(产品内 AI 助手)** 持续迭代:tool call 视图(#24235)、reasoning content parts(#24176);同时也在删冗余入口(traces 工具栏 / 侧栏重复按钮)。
- **企业治理**:在线打分配置端点强制实验权限(#24562)、自定义 scorer 服务端校验(#24540);UC model-registry 客户端 gate 到原生 `/api/2.1` 端点(#24517)。
- 命名保存视图(saved views,#24359/#24360/#24426)——多租户下的实验视图管理。
来源:https://github.com/mlflow/mlflow/commits/master

### Kubeflow model-registry
整轮几乎全在做 **Agent Catalog**:Agents Catalog Gallery + Filters(#2934)、Agent Details 页(#2964)、Agent catalog artifacts 端点(#2967)、middleware 里 agent catalog API 路径切换(#2969)、`create-agent-catalog-source` skill(#2975)。Model Registry 正扩成"Agent/模型统一目录"。
- **安全硬化**:CSI 加 **artifact URI 白名单 + 云 metadata 黑名单**(#2968)——防 SSRF/云元数据泄露,做多租户平台的必看点。
来源:https://github.com/kubeflow/model-registry/commits/main

### Feast(0.65.0)
- **在线存储扩容**:新增 Aerospike(#6532)、**ScyllaDB 带向量检索**(#6508)。Feature Store 与向量库边界继续融合。
- **数据源**:Iceberg REST Catalog data source;**OpenLineage 消费者**——接收/存储/可视化跨生产者血缘(#6549)。
- **Bring Your Own Spark(SparkApplication)**(#6550)+ operator 自动建 RBAC(#6597);Permissions CRUD UI + OIDC 鉴权。企业级多租户与合规在补齐。
来源:https://github.com/feast-dev/feast/releases/tag/v0.65.0

---

## LLM 评估 & 安全

### lm-evaluation-harness(EleutherAI)
本窗口 0 提交,**无重大更新**。https://github.com/EleutherAI/lm-evaluation-harness

### garak(NVIDIA)
仅 continuation probe 的缺陷修复——prompt 裁剪后 trigger 未同步 pruning(#1976)及对齐断言。**无重大能力更新**。https://github.com/NVIDIA/garak/commits/main

### llama-stack(meta-llama;内部包已改名 ogx_api)
- **推理 provider 扩展**:新增 Mistral 远程推理 provider(#6239);vector_io 新增 **Neo4j 向量 provider**(#6274)。
- **企业化**:starter 以非 root 运行(#6319)、未配置鉴权时启动告警(#6307)、多租户能力博客(#6129)、CVE 修复。
- 注:仓库路径仍是 `meta-llama/llama-stack`,但源码内 API 包已是 `src/ogx_api`(OGX 改名在代码层坐实,GitHub repo 尚未搬迁)。
来源:https://github.com/meta-llama/llama-stack/commits/main

---

## 值得跟进
- [ ] **KServe llmisvc 的 DRA 路线**:我们 serving 层的 GPU 分配是否规划从 device-plugin 迁 DRA?对齐 #5828 / #5352 的 API 形态。
- [ ] **多 LLM API 协议网关**:KServe 的 `v1/messages`(Anthropic)+ KubeAI 的 `/v1/responses`(OpenAI Responses)——评估我们网关是否要做多协议契约适配层。
- [ ] **OCI 作为模型分发载体**:KServe 多 OCI 源 + KubeAI OCI 镜像模型源同时落地,值得把 OCI 模型交付纳入我们模型仓设计。
- [ ] **MCP / Agent 注册中心**:MLflow(MCP Server Registry)与 Kubeflow model-registry(Agent Catalog)双向扩边界——我们的模型注册中心是否要预留 Agent/MCP 资产类型?
- [ ] **Kubeflow Trainer OptimizationJob(KEP-3562)**:HPO 收进 Trainer v2,跟踪它与 TrainJob/Katib 的整合终态,评估我们训练平台的 HPO 方案选型。
- [ ] **DRA 调度对齐**(横跨 KServe/上游 K8s):这是本周多个上游共同指向的调度大方向,建议单开一次专题调研。
