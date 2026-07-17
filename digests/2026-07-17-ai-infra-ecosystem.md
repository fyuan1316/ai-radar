# AI 推理 & MLOps 生态周报 2026-07-17

> 覆盖窗口:2026-07-10 ~ 07-17。数据源见 `tasks/ai-infra-ecosystem.md`。
> 本期与 2026-07-15 digest 有 2 天重叠——vLLM v0.25.0/.1、SGLang v0.5.15/post1、Ollama v0.32.0、Kubeflow Hub v0.3.12、OGX v1.2.0/.1 已在上期详述,本期只写 **07-15 之后的新增动向**,重点是 KServe v0.20.0-rc0。
> 任务清单已改名仓库按新路径抓取:`substratusai/lingo`→`kubeai-project/kubeai`、`kubeflow/training-operator`→`kubeflow/trainer`、`kubeflow/model-registry`→`kubeflow/hub`、`meta-llama/llama-stack`→`ogx-ai/ogx`。

## 摘要(5 条以内)

1. **KServe v0.20.0-rc0——本周最重信号**:`LLMInferenceService`(llmisvc)从"新增 CRD"跨到"生产级 LLM 服务面",一次性补齐:接入 Gateway API Inference Extension(GIE v1.5.0)做模型感知路由与调度、集成 llm-d v0.8.0、**Managed DRA 做 GPU 供给**、多节点 NVSHMEM/UCX RDMA、**机密计算模型服务(confidential serving)**、Anthropic Messages API 路由、分布式追踪、LoRA affinity 打分、端到端 TLS。这正是我们对标 OAI 的服务面板核心,值得逐条对表。
2. **KServe 同时补企业接入细节**:transformer→predictor 转发 Authorization 头、`storageUris` 支持多 OCI 源、显式 `storageContainerName` 选择 CSC、`enableLLMInferenceServiceTLS` 打通、starlette CVE-2026-48710 修复——都是自建平台会踩的坑。
3. **MLflow 转向 MCP + Unity Catalog 原生**:新增 MCP registry 后端与客户端(#24380)、UC-native model-registry protos(#24412)、MLflow Assistant 支持远程 API provider(#24040)。实验追踪平台在把"模型注册表"往 MCP 生态和 UC 治理靠。
4. **Ray Serve LLM 全面转 SGLang RayEngine**:Serve LLM 的 SGLang 引擎切到原生 `sglang RayEngine`(#62888)并支持 Serve direct streaming(#64611);GCS RocksDB 容错后端继续硬化(aarch64 构建、TSAN 竞态修复)。
5. **TensorRT-LLM v1.3.0rc21**:新增 **DeepSeek V4(DSv4)+ 稀疏 MLA 注意力后端**、**inflight weight update(在线权重更新,利好 RLHF)**、原生 `/v1/embeddings` 动态批处理;正式在 release 层删除遗留 TensorRT 后端(全面 PyTorch 化);**AutoDeploy 后端宣布弃用**。

---

## 推理引擎动态

### vLLM
本周无新 release。v0.25.0/v0.25.1 已在 07-15 digest 详述(Model Runner V2 默认、删 PagedAttention、Rust 前端 mTLS/DP supervisor、v0.25.1 修 NVFP4 融合乱码)。生产升级仍建议直接 v0.25.1。

### SGLang
本周无新 release。v0.5.15/post1 已在 07-15 digest 覆盖(GLM-5.2 NVFP4 生产调优、Spec V2 默认开、内建 Exa web_search、MLA Decode Context Parallelism)。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc21**(07-15 晚):
  - **模型**:新增 DeepSeek V4(DSv4,#15414)、DSv4 稀疏 MLA 注意力后端(#15409);Qwen3.5-VL MoE/Dense(#14599、#15249)、Qwen3.6 NVFP4(#15703)、Gemma 4 12B 无编码器多模态(#15768)、Minimax M3 MXFP8/NVFP4(#15687、#15857)。
  - **能力**:**支持 inflight weight update(#14815)**——在线更新权重不重启,是 RLHF/持续训练服务化的关键件;原生 `/v1/embeddings` 动态批处理(#15424);prefix-aware 调度可 opt-out(#15526);`trtllm-serve` 原生后处理 hook(#15631)。
  - **BREAKING**:release 层正式移除遗留 TensorRT 后端 Python 模块(#15918);重命名 server args(#16091)、多模态 args/env(#15640)、投机解码接受率字段(#12905)。
  - **弃用**:AutoDeploy 后端将弃用,官方转向"agentic 方式加速 PyTorch 后端的新模型支持"(称已用它在模型发布首周落地 Minimax M3)。
  - Known Issues 巨长(DSv4 host KV offload 多卡 OOM/hang、多款模型 torch.compile 精度失败),rc21 仍是预览,勿上生产。
  https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc21
- **TGI**:本周仍无提交,主分支停在 2026-03-21。维护/停滞状态未变,选型不建议作新平台基座。
- **Ollama v0.32.1**(07-16,小补丁):改进 Gemma 4 工具调用与多轮推理、修复 MLX 模型 cache 泄漏(跨请求内存增长)、MLX 加载尊重 `OLLAMA_LOAD_TIMEOUT`、agent web 搜索需认证时提示 `ollama signin`、交互式 agent 拿到当前工作目录。属 v0.32.0 agent 化后的稳定性收尾。
  https://github.com/ollama/ollama/releases/tag/v0.32.1

## 模型服务 & 编排

### KServe 上游
**v0.20.0-rc0(07-16)是本期最值得逐条读的发布**,主线是把 `LLMInferenceService`(llmisvc)做成企业级 LLM 服务 CRD:

- **调度/路由(接上游 Gateway API Inference Extension)**:升级 GIE 到 v1.5.0 并带本地 v1alpha2 InferencePool shim(#5571);模型感知路由 gate + status 里暴露 models(#5579);HTTPRoute parent status 按 gateway name 过滤(#5583);scheduler v0.6→v0.7 迁移 e2e(#5564)。集成 **llm-d 组件升到 v0.8.0**(#5596)。
- **GPU 供给用 DRA**:**为 LLMInferenceService 加 Managed DRA 支持(#5352)**——KServe 直接对接 Dynamic Resource Allocation 做 GPU 分配,和 k8s v1.37 主线 DRA 方向一致。
- **多节点分布式推理**:导出所有 HCA 到 `NVSHMEM_HCA_LIST`/`UCX_NET_DEVICES`(#5603)、修多节点 InferenceService Ready 卡在 Unknown(#5703)——多机 RDMA 大模型推理在打磨。
- **API 兼容面**:新增 `v1/messages` HTTPRoute **支持 Anthropic Messages API(#5648)**;distributed tracing API 加入 llmisvc(#5481);vLLM 作为受支持 runtime(#4769)。
- **企业能力**:**机密计算模型服务(confidential model serving,#5382)**;transformer→predictor 转发 Authorization 头(#5567);`enableLLMInferenceServiceTLS` 打通(#5525);LoRA adapter 自动开 lora-affinity-scorer(#5655);平台可插 service 定制 hook(#5617);LLMInferenceServiceConfig finalizer 防误删(#5400)。
- **存储/供应链**:`storageUris` 支持多个 OCI 源(#5470);显式 `storageContainerName` 选 ClusterStorageContainer(#5314);localmodel PV/PVC RBAC 加 delete(#5659)。
- **安全**:bump starlette >=1.0.1 修 CVE-2026-48710 并强制 Content-Type(#5632)。
- 另注:release 里也含 `release: prepare v0.19.0`(#5654),v0.19 线并入本次 rc。
- **对我们产品的启示**:KServe 正在把"LLM 服务面"= GIE 调度 + llm-d + DRA + 多机 RDMA + 机密计算 + OpenAI/Anthropic 双协议路由,打包进单个 CRD。这是 OAI 服务栈的上游底座,**我们的推理服务 CRD 应逐条对照 llmisvc 的字段与集成点**(尤其 DRA、GIE InferencePool、confidential serving 三项差异化能力)。
  https://github.com/kserve/kserve/releases/tag/v0.20.0-rc0

### Ray
本周无 release,commit 侧(07-15 后)几处对平台有参考:
- **Serve LLM 转原生 SGLang RayEngine**:Serve LLM 的 SGLang 引擎切到 `sglang RayEngine`(#62888),并支持 Ray Serve direct streaming(#64611);Serve LLM CI 升到 vLLM 0.25.1(#64697)。
- **GCS RocksDB 容错后端继续硬化**:vendored RocksDB 改用 Make 构建修 aarch64(#64748)、修 TSAN 误报竞态(#64759)——上期提到的 REP-64 控制面持久化在补构建/稳定性。
- **Core 稳定性**:按退出类型优先驱逐死 worker(#64729)、streaming generator replay 对象计数不匹配 fail-fast(#64394)、Gauge 指标加 TTL 清理(#64633)。
- **Data**:新增 `read_lerobot` 数据源支持 LeRobot v3 机器人数据集(#63821);Parquet footer 直接答 `count()` 的 PushdownCountFiles 优化(#64763);`read_numpy` 默认 `allow_pickle=False`(#64684,安全默认)。

### KubeAI(原 substratusai/lingo)
本周仅一处修复:无 rewrite 时保留原始请求体(#691)。无重大更新。

## 训练 & 微调

- **Kubeflow Trainer(原 training-operator)**:本周仅 `feat: expose Image and Command on PodSet Container`(#3674),小增强。v2 主体(runtime snapshot KEP-2599、managedBy)已在 07-15 覆盖。
- **LLaMA-Factory(现 hiyouga/LlamaFactory)**:本周只有文档(AMD GPU Cloud 链接,#10649),无实质代码变化。v1 重构(apply_chat_template)见上期。

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
本周无 release,commit 侧信号明确——往 **MCP 生态 + Unity Catalog 治理**走:
- **新增 MCP registry 后端与客户端(#24380)**:MLflow 开始做 MCP 服务注册,和"模型/工具目录 MCP 化"的行业方向一致。
- **Unity Catalog 原生化**:新增 UC-native model-registry protos(additive,#24412)、恢复 `TemporaryCredentials.credentials` 的 oneof(#24489)——注册表在往 UC 一等公民靠。
- **MLflow Assistant**:允许 API-based provider 远程访问 Assistant(#24040)、收紧 Assistant prompt 的 scope guard 与响应长度(#24445)。
- 第三方 scorer telemetry(Guardrails/Phoenix/TruLens,#24437)延续上期"评估中台"方向。
- **启示**:MCP registry + UC 原生这两条,是模型/工具治理层的新战场,和 Kubeflow Hub 的 perf/security 目录方向并行,值得一起纳入我们模型治理的 schema 规划。

### Kubeflow Hub(原 model-registry)
v0.3.12(07-13)已在 07-15 digest 详述(perf 指标 + security-evaluations 目录化)。本周无新增。

### Feast
本周无 release、07-15 后无实质 commit。上期的 ScyllaDB 在线存储 + 向量搜索(#6508)仍是最近亮点。无重大更新。

## LLM 评估 & 安全

- **OGX(原 meta-llama/llama-stack)**:v1.2.1 后 commit 侧——新增 **Neo4j 向量 provider(#6274)**(vector_io 生态继续扩);启动时若未配置认证会告警(#6307,安全默认);修 macOS 上 faiss 导入重复 libomp 崩溃(#6304);官方发多租户能力博客(#6129,呼应上期租户隔离硬分区键 #6126)。
- **garak**:本周(07-15 后)无新提交。上期的反向翻译顺序修复、Bedrock suppressed_params 仍是近期变化。无重大更新。
- **lm-evaluation-harness**:本周无实质提交。上期的多语种基准扩张(ASSIN2、IndicParam)后基座无变化。无重大更新。

## 值得跟进

- [ ] **KServe llmisvc 逐条对表**:GIE InferencePool 调度(#5571/#5579)、Managed DRA GPU 供给(#5352)、confidential serving(#5382)、多机 NVSHMEM/UCX(#5603)、Anthropic Messages 路由(#5648)——对照我们推理服务 CRD,重点评估 DRA / GIE / 机密计算三项差异化能力的落地路径。
- [ ] **KServe + llm-d v0.8.0 的分工**:KServe 把 llm-d 作为分布式推理组件集成(#5596),需搞清 KServe 控制面与 llm-d 数据面的边界,决定我们是自研还是复用这条链路。
- [ ] **MLflow MCP registry(#24380)**:实验追踪平台做 MCP 服务注册,评估我们模型/工具目录是否需要 MCP 暴露面。
- [ ] **TensorRT-LLM inflight weight update(#14815)**:在线权重更新对 RLHF/持续训练服务化是关键件,跟进其 API 与 vLLM/SGLang 的同类能力对比。
- [ ] **Ray Serve LLM 转 SGLang RayEngine(#62888)**:Ray 把 SGLang 做成原生引擎,若我们平台用 Ray Serve 承载 LLM,需评估引擎抽象的迁移影响。
- [ ] **KServe starlette CVE-2026-48710(#5632)**:自建 Python 服务面若用 starlette/FastAPI,核对同版本修复。
