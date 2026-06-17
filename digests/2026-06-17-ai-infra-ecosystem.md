# AI 推理 & MLOps 生态周报 2026-06-17

> 覆盖窗口:2026-06-10 ~ 2026-06-17。仓库多,只保留对"做云原生 AI 基础设施产品(对标 OAI)"有借鉴或威胁意义的变化,版本 bump / dependabot / CI 噪音已剔除。

## 摘要(5 条以内)

1. **KServe v0.19.0 发布,几乎全部增量压在 `LLMInferenceService`(llmisvc)上**:Managed DRA、Anthropic Messages API 路由、分布式追踪、LoRA affinity scorer 自动注入、vLLM 正式成为受支持 runtime——KServe 正把"LLM 原生服务"做成一类独立 CRD,这是本周对我们产品最直接的对标信号。https://github.com/kserve/kserve/releases/tag/v0.19.0
2. **四个被跟踪仓库本周发生改名/转移**(GitHub API 重定向已确认):`kubeflow/training-operator`→`kubeflow/trainer`(Trainer v2.2.1)、`kubeflow/model-registry`→`kubeflow/hub`、`substratusai/lingo`→`kubeai-project/kubeai`、`meta-llama/llama-stack`→`ogx-ai/ogx`。上游身份在重排,选型与集成路径需要重新校准。
3. **vLLM v0.23.0 发布**:KV connector 生态(Mooncake / MoRIIO 跨节点)、ModelRunnerV2 默认化推进、新增 MinimaxM2 流式解析器与多家模型支持;SGLang v0.5.13 押注 GLM-5.2 与 MoE 专家并行的 LPLB 线性规划负载均衡器,并补强 Ascend NPU。两强继续在 MoE / 大模型部署体验上贴身肉搏。
4. **DRA(动态资源分配)成横向主题**:KServe llmisvc 加 Managed DRA、Feast FeatureStore CRD 加 DRA 字段、Kubeflow Trainer 往 init 容器注入 PET_* 环境。K8s DRA 正从 GPU 调度底座外溢到服务/特征/训练各层,值得在我们调度栈里立项跟踪。
5. **MLOps 侧全面转向 GenAI 评估与人审闭环**:MLflow 本周密集落地 Review Queues(标注/复核队列)+ Prompt Playground + `@mlflow.test` 回归测试;Feast 把数据质量监控(DQM)搬进 UI。实验追踪正在演化成"GenAI 质量治理平台"。

## 推理引擎动态

### vLLM
- **v0.23.0 发布**(2026-06-15)。https://github.com/vllm-project/vllm/releases/tag/v0.23.0
- **服务架构**:`ModelRunnerV2` 持续推进,GraniteMOE 默认走 MRv2(#45461);新增"prefill step cadence"改善非 PD 分离场景下的 DP 负载均衡(#44558)。
- **KV / 分离式部署生态**:Mooncake connector 给 namespace store key 加 cache_prefix(#45767),MoRIIO connector 支持覆盖对外 host IP(#45488)——P/D 分离与跨节点 KV 复用的工程细节在快速补齐。
- **前端 & 工具调用**:新增 Streaming Parser Engine 与 MinimaxM2 解析器(#45701);Rust 前端加 CORS(#45753)。新模型适配多(HRM 文本模型 #43098 等)。
- **容器友好**:numactl `--membind` 在受限容器被阻断时回退(#45438)——对在 K8s 受限 securityContext 下跑 vLLM 是实打实的健壮性修复。

### SGLang
- **v0.5.13 发布**(2026-06-13)。https://github.com/sgl-project/sglang/releases/tag/v0.5.13
- **MoE 专家并行**:`LPLB` 线性规划负载均衡器(#24515),给 MoE EP 做更优专家落位;flashinfer_trtllm routed 用 pack-topk-ids triton kernel(#25702)。
- **GLM-5.2 全家桶**:多篇 cookbook(B300 单机 FP8+BF16 #28460、MTP 5-1-6 调参 #28448、Ascend 部署 #28433)——SGLang 在"新模型 day-0 可部署"上的文档/工程响应非常快,是其对 vLLM 的差异化打法。
- **国产卡**:替换 Ascend vision attention 算子(#25768)、更新 Ascend NPU 文档到 HDK 25.5.2(#28311);router 出多架构实验镜像并修 distroless 启动崩溃(#28474)。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:活跃但以 NVbug 修复 + CI waive 为主。值得看的实质项:PyTorch backend 支持 T5/BART(#13919)、DSv4 attention op 预埋(#15384)、MNNVL 性能优化 + FP8/NVFP4 量化融合(#14476)、并明确"移除 TensorRT 性能基线,全面转 PyTorch backend"(#15256)——TRT-LLM 的重心已基本迁到 PyTorch 路径。最新 tag https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc18
- **TGI**:**无重大更新**。默认分支最后一次提交停在 2026-03-21,项目近乎停更,HuggingFace 推理重心明显外移。
- **Ollama**:v0.30.8 / v0.30.9 发布。实质改动是 context shift 体系——支持 >8k 上下文窗口的 context shift 并在触顶时显式报错(#16712)、把 prompt caching 与 context shift 解耦(#16639)。https://github.com/ollama/ollama/releases/tag/v0.30.9

## 模型服务 & 编排

### KServe 上游
- **v0.19.0 发布**(2026-06-14),本周绝对主角。https://github.com/kserve/kserve/releases/tag/v0.19.0。`LLMInferenceService` 一连串能力落地:
  - **Managed DRA support**(#5352)——把 K8s 动态资源分配纳入 LLM 服务 CRD。
  - **Anthropic Messages API**:新增 `v1/messages` HTTPRoute(#5648),原生兼容 Anthropic 协议。
  - **分布式追踪 API**(#5481)、EPP 优雅关闭与就绪探针阈值修复(#5677/#5602)。
  - **LoRA**:为 LoRA adapter 自动启用 lora-affinity-scorer(#5655),并只把该 scorer 注入默认配置(#5675)。
  - **vLLM 正式成为受支持 runtime**(#4769)。
  - 安全:starlette 升到 >=1.0.1 修 CVE-2026-48710(#5632)。
- 启示:KServe 把"LLM 服务"从泛化 InferenceService 里拆出来独立演进(协议兼容 + LoRA 亲和 + EPP 网关 + DRA),正是我们模型服务层要对齐的形态。

### Ray
- 未发新 release,但 Serve/LLM 与 KubeRay 文档/工程持续推进:**KubeRay IPPR 用户指南**(#63212)、Serve LLM 落地页+配置参考(#64076)、KubeRay Serve 高吞吐指南更新到 Ray 2.56(#64144)。
- **ray-llm 升级到 vLLM 0.23.0**(#64082),并新设 ray-llm 作为 LLM 依赖 CODEOWNER(#64083)——Ray Serve LLM 与 vLLM 的版本耦合在制度化。
- 跨节点分离式:`serve.llm` 通过 vLLM 插件对外广告 worker 节点内网 IP 走 MoRIIO 跨节点(#64067);RDT 把 NIXL 升到 v1.2.0(#63980)。Data 侧大量 OOM/内存安全治理。

### KubeAI(原 substratusai/lingo)
- 仓库已转移到 `kubeai-project/kubeai`。本周:Helm chart 暴露 `proxy.mode`(#670)、**支持 OpenAI `/v1/responses`**(#667)、支持外部 LB(#655)。轻量 K8s LLM 网关在补齐 OpenAI 最新 API 面。https://github.com/kubeai-project/kubeai

## 训练 & 微调
- **Kubeflow Trainer(原 training-operator)发布 v2.2.1**。https://github.com/kubeflow/trainer/releases/tag/v2.2.1。实质项:通过 envInjection 配置把 `PET_*`(PyTorch Elastic)环境注入 init 容器(#3516)、JAX EnforceMLPolicy 防 nil trainer PodSet(#3563)、data_cache 用状态码而非 identity 判 Service AlreadyExists(#3507)。Trainer v2 体系趋于稳定。
- **LlamaFactory(原 hiyouga/LLaMA-Factory)**:新增 MiniCPM5-1B-Chat(#10558)、修 Ascend NPU 上 liger kernel patch(#10583)、补 DataFlow/DataFlex 教程。国产卡 + 新模型适配仍是其活跃主线。https://github.com/hiyouga/LlamaFactory

## 模型生命周期(MLflow / Registry / Feast)
- **MLflow**:本周提交量极大,主题集中在 **GenAI 评估与人审闭环**——Review Queues / Label Schemas(队列重命名、权限、去重、唯一性约束等几十个 PR)、Prompt Playground 落地(#23273,并加"保存 Prompt 到 registry" #24021)、`@mlflow.test` pytest 回归测试体系([2/3] #23869、[3/3] 在 eval-run UI 展示回归结果 #23985)。另:sklearn 序列化默认从 cloudpickle 改 skops(#23987,安全/可移植性提升)。MLflow 正从"实验追踪"转型成"GenAI 质量治理平台"。
- **Kubeflow Hub(原 kubeflow/model-registry)发布 v0.3.10**。https://github.com/kubeflow/hub/releases/tag/v0.3.10。重心是 **model catalog**:把 cold-start / vRAM / 容器体积过滤接到真实 API(#2815)、cold_start_matrix 持久化为 JSON 自定义属性(#2820)、修就绪探针与 leader election 解耦防滚动更新死锁(#2821)。"按冷启动/显存选模型"的目录化体验值得借鉴。
- **Feast v0.64.0 发布**。https://github.com/feast-dev/feast/releases/tag/v0.64.0。亮点:**数据质量监控(DQM)进 UI**(#6422)、新增 **Apache Flink 计算引擎**(#6476)、FeatureStore CRD 增加 DRA 字段、init 模板加 Label View。

## LLM 评估 & 安全
- **garak**:新增 **原生 Anthropic generator**(#1809);安全硬化——解析符号链接安装路径以加固 data_path 逃逸防护(#1860)、容器内路径解析修复、OpenAI/Mistral 鉴权错误在进入多进程 pickle 前先捕获(#1859/#1769)。红队工具自身的供应链/路径安全在收紧。
- **lm-evaluation-harness**:**无重大更新**(最后活动停在 2026-06-02,窗口内无提交)。
- **llama-stack → OGX(ogx-ai/ogx)**:**重大身份变化**——仓库已转移/改名为 OGX,本周发 v1.1.0 / v1.1.1。实质项:**多租户隔离作为独立于 ABAC 的硬分区 key**(#6126)、Files API 对齐 OpenAI 规范(#6127)、内置 **Skills provider**(manifest 解析 + zip 校验,#6078/#6087)、加 Trivy 安全扫描(#6074)。多租户硬隔离 + Skills 化的方向与企业级平台诉求高度相关,需重点跟一仓究竟。https://github.com/ogx-ai/ogx/releases/tag/v1.1.1

## 值得跟进
- [ ] **KServe LLMInferenceService 形态**:Managed DRA + Anthropic Messages 路由 + LoRA affinity + EPP 网关,逐项对照我们模型服务层的能力缺口。
- [ ] **上游改名潮的影响面**:training-operator→trainer、model-registry→hub、lingo→kubeai、llama-stack→ogx,确认我们文档/集成/选型引用是否需要更新,以及 model-registry→hub、llama-stack→ogx 是否伴随治理/许可变化。
- [ ] **DRA 横向化**:KServe / Feast / Trainer 都在接入 K8s DRA,评估我们 GPU/NPU 调度栈对 DRA 的支持节奏。
- [ ] **OGX(原 llama-stack)多租户硬分区 + Skills provider**:是否值得作为企业级 LLM 应用栈的参考实现深读。
- [ ] **MLflow GenAI 质量治理(Review Queues + @mlflow.test)**:对标我们(若有)模型/Prompt 评估与人审闭环。
- [ ] **TGI 停更信号**:确认 HuggingFace 推理重心去向,涉及 TGI 在我们栈里的去留。
