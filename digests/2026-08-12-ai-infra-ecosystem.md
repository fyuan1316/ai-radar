# AI 推理 & MLOps 生态周报 2026-08-12

> 覆盖窗口:2026-08-05 ~ 08-12。数据源见 `tasks/ai-infra-ecosystem.md`。仓库多、只保留对"做云原生 AI 基础设施产品(对标 OAI)"有借鉴/威胁的变化,版本 bump/CI/依赖噪音已剔除。

## 摘要(5 条)

1. **KServe v0.20.0 是本周最该细看的一枪**:`LLMInferenceService` 这条 LLM 专用服务路径几乎所有精力都砸在企业级能力上——Managed DRA(GPU 动态资源分配)、Anthropic Messages API 兼容、分布式追踪、KEDA scale-to-zero、GIE v1.5.0/InferencePool 网关推理扩展、LoRA 亲和调度。这条线和我们的产品正面重叠,建议逐条对标。https://github.com/kserve/kserve/releases/tag/v0.20.0
2. **vLLM v0.27** 把 Model Runner V2 从"只做生成"扩到 embedding/分类/pooling 等非生成负载,并把 KV 分层卸载(TieredOffloading:P2P 二级层、可插拔淘汰策略、文件系统卸载)做成了体系;还上了 DP+EP 大规模部署的容错框架与 Rust gRPC 控制面。推理底座正在"平台化"。https://github.com/vllm-project/vllm/releases/tag/v0.27.0
3. **Kubeflow 两个信号**:Trainer v2.3.0 新增 `OptimizationJob` CRD(训练之外补上"优化/压缩"作业类型);原 `kubeflow/model-registry` 已并入 monorepo `kubeflow/hub`,本周提交清一色围绕 Agent / MCP server / Skill catalog——Model Registry 正演进成"AI Hub(含 Agent/MCP 目录)"。https://github.com/kubeflow/trainer/releases/tag/v2.3.0
4. **SGLang v0.5.17 大举进军 diffusion(图像/视频生成)**:一周内接入 SANA-Video、LTX-2、Ideogram-4、ERNIE-Image、Cosmos3 等一堆扩散模型并做 bit-exact 融合优化,同时 PD 分离(disaggregation)持续加固。推理引擎不再只盯 LLM,开始吃多模态生成赛道。https://github.com/sgl-project/sglang/releases/tag/v0.5.17
5. **HuggingFace TGI 已归档(archived,最后提交停在 2026-03)**——TGI 事实上退役,推理引擎格局收敛到 vLLM / SGLang / TensorRT-LLM 三强 + Ollama(边缘)。数据源清单可把 TGI 降级为"仅存档参考"。https://github.com/huggingface/text-generation-inference

---

## 推理引擎动态

### vLLM(v0.27.0 / v0.27.1)
一次 561 commits / 242 贡献者的大版本,和平台化直接相关的几点:
- **Model Runner V2 扩到非生成负载**:encoder-only attention、embedding/分类的 sequence pooling、token classification、BGE-M3 pooling、CPU 多模态。意味着同一套 runtime 既能跑生成也能跑 embedding/rerank/分类,统一服务栈的想象空间变大。
- **KV 分层卸载体系化(TieredOffloading)**:通用 P2P 二级层 + peer 查找、按请求 tier 过滤、可插拔淘汰策略(CachePolicyFactory)、文件系统批量 store/load。长上下文 / 高并发下的显存成本治理,产品侧值得跟。
- **大规模服务韧性**:DP+EP 外部负载均衡部署的(简化)容错框架、弹性 EP 扩缩的异步准备。
- **Rust 前端长出 gRPC 控制面**:引擎级健康上报、abort 控制、server/model 发现、KV event 源发现;`vllm-bench` 并入 `vllm` CLI。
- 环境破坏性变更:升级到 PyTorch 2.13 / Triton 3.7.1。模型侧新增 Kimi K3、Qwen3.5、DeepSeek-V4 大量性能优化。
- 配置默认值:`max_num_batched_tokens` 8192→16384(#51726),吞吐默认更激进。
来源:https://github.com/vllm-project/vllm/releases/tag/v0.27.0

### SGLang(v0.5.17)
- **战略性转向多模态生成**:一周里 SANA-Video(T2V)、LTX-2、Ideogram-4、ERNIE-Image、Cosmos3-Edge 等扩散模型接入 + bit-exact 融合 kernel(多个 denoise -5%~-19% H100/H200)。SGLang 在把自己从 LLM 引擎扩成"通用推理引擎"。
- **PD 分离加固**:`SGLANG_DISAGGREGATION_ZMQ_MAX_SOCKETS` 提升每上下文 socket 上限、abort 路由到多 tokenizer worker、HiCache 在 overlap 调度下的一致性修复;`ReqToTokenPool.alloc()` 做到 O(1)。
- 硬件面:flashinfer MNNVL allreduce、NPU(Ascend)/XPU 持续补齐。
来源:https://github.com/sgl-project/sglang/releases/tag/v0.5.17

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**(主分支高频):`KVCacheManagerV2` 持续推进(零拷贝 token 传递、DSA 支持)、**NIXL cache transceiver 打通 Ray**、PD 分离用 Python V2 transceiver 覆盖 Llama/Gemma3;`_autodeploy` 后端标注弃用;一个 rank 崩溃时硬杀所有 rank(容错语义)。方向和 vLLM 高度趋同:KV 管理 + 分离式服务 + 大规模容错。https://github.com/NVIDIA/TensorRT-LLM
- **TGI**:仓库已 archived,最后一次提交 2026-03,视为退役。https://github.com/huggingface/text-generation-inference
- **Ollama**(v0.32.7~v0.32.9):MLX runner 补多模态(图像输入、vision tower 量化保精度)、块扩散草稿模型(DFlash / block-diffusion drafting),边缘/桌面侧持续加速。对企业服务栈影响小,略。https://github.com/ollama/ollama/releases

## 模型服务 & 编排

### KServe 上游(v0.20.0)—— 本周重点
`LLMInferenceService`(llmisvc)是全部火力所在,和 OAI/我们产品几乎逐项对标:
- **Managed DRA 支持**(#5352):把 K8s Dynamic Resource Allocation 接进 LLM 服务,GPU 分配走 DRA 而非老的 device plugin。
- **Anthropic Messages API 兼容**(#5648):新增 `v1/messages` HTTPRoute,除 OpenAI 兼容外再兜 Anthropic 协议。
- **分布式追踪 API**(#5481)进入 llmisvc CRD。
- **KEDA 真·scale-to-zero**:`idleReplicaCount=0`(#5996);新增 `rolloutStrategy` 控滚动更新(#5916);canary 流量按就绪门控避免瞬时 503(#5984)。
- **GIE v1.5.0 / InferencePool**(#5571)升级 + 本地 v1alpha2 shim;LoRA 适配自动启用 lora-affinity-scorer(#5655);EPP(Endpoint Picker)优雅关闭与探针阈值修复。
- 其它:vLLM 作为受支持 runtime(#4769)、transformer→predictor 转发鉴权头、多 OCI 源 storageUris、Python 3.13。
启示:LLM 网关推理扩展(GIE/InferencePool)+ DRA + 多协议兼容(OpenAI/Anthropic)+ scale-to-zero,这套组合是上游给出的"企业级 LLM 服务"参考架构,建议做一次逐条 gap 分析。
来源:https://github.com/kserve/kserve/releases/tag/v0.20.0

### Ray(ray-2.57.0)
- **Serve 扩展性**:controller benchmark 扫到 8K 副本;proxy/controller 关键模块强制类型检查;RayService 增量升级期 proxy 崩溃修复 + 支持回滚(#65249)。
- **gVisor 沙箱(实验)**(#64964):Ray 任务跑进 gVisor,多租户安全隔离方向的信号。
- **core 可扩展性**:task events 迁出 GCS(降 GCS 压力);Data 侧新增 ORC 读、Iceberg count 修复。
来源:https://github.com/ray-project/ray/releases/tag/ray-2.57.0

### 轻量 K8s LLM 部署(原 substratusai/lingo → kubeai-project/kubeai)
本周无提交(最后 push 2026-07-31),无重大更新。

## 训练 & 微调

- **Kubeflow Trainer v2.3.0**(原 training-operator → `kubeflow/trainer`):新增 `OptimizationJob` CRD(#3552)——在 TrainJob 之外补上"优化/压缩"作业原语;新增 PreComponentBuilder 与 PodSpec plugins(#3889),扩展 runtime 定制点;API 侧收紧校验(拒绝 numNodes/numProcPerNode≤0、Failed 条件设为终态)。https://github.com/kubeflow/trainer/releases/tag/v2.3.0
- **LLaMA-Factory**(现 `hiyouga/LlamaFactory`):仅 3 个实质提交——NPU 镜像升 CANN 9.1 / PyTorch 2.10;修 Gemma-3/4 非 FA2 packing 路径的 rotary 崩溃。无架构级变化。https://github.com/hiyouga/LLaMA-Factory

## 模型生命周期(MLflow / Registry / Feast)

- **Model Registry → Kubeflow Hub**(`kubeflow/model-registry` 已并入 monorepo `kubeflow/hub`):本周提交全在 catalog——git-backed skill catalog 同步(SKC-105/106/107)、MCP server 的 logo endpoint、agent catalog 加载摘要、async-upload 透传可信 CA。**Model Registry 正在升级为"AI Hub":不只是模型元数据,而是模型 + Agent + MCP + Skill 的统一目录**。这是对"模型生命周期"边界的重新定义,值得盯。https://github.com/kubeflow/hub
- **MLflow**(高频,100+ commits):偏产品/UI 与 GenAI 评估——自定义视图 tab(save/rename/tag 持久化)、`make_judge` 暴露 `generate_rationale_first`、MemAlign 对齐 judge、gateway 保留 provider usage extras;工程侧修并发 `log_batch` 死锁、trace 归档排序加索引、FastAPI router 支持 `--static-prefix`。方向:LLM/GenAI 评估("judge")与 tracing 是 MLflow 的重心。https://github.com/mlflow/mlflow
- **Feast**:新增 SQL registry `schema_mode` + `registry create` 命令、**远程 Materialization(server 端)**(#6649)、Spark compute engine 指南;修远程 registry 首次 apply 失败。企业化(远程 registry/物化、安全策略)在补齐。https://github.com/feast-dev/feast

## LLM 评估 & 安全

- **lm-evaluation-harness**:本周 18 提交几乎全是**数据集加载适配**——`datasets>=4` 移除了 dataset script,大量任务(MMLU-SR、arithmetic、SCROLLS、PROST、mathqa 等)改走无脚本 parquet 镜像/命名空间路径。信号:HF datasets 破坏性升级正在冲击整个评测生态,自建评测流水线若 pin 老任务需同步适配。https://github.com/EleutherAI/lm-evaluation-harness
- **garak**(NVIDIA LLM 红队):新增 Ollama 认证与自定义 client kwargs、转发生成参数到 Ollama;IntentProbe 优先用于意图无关探针;修若干探测器不可达分支。红队工具在补齐对本地/自托管后端(Ollama)的一等支持。https://github.com/NVIDIA/garak
- **llama-stack → ogx-ai/ogx**:本周仅 2 个提交(改名后遗留修复:`AsyncOgxClient` 继承 sync ApiClient、fallback 版本 bump),v1.3.0 已发布但本窗口无实质功能变化。https://github.com/ogx-ai/ogx/releases/tag/v1.3.0

## 值得跟进

- [ ] **对标 KServe v0.20.0 的 LLMInferenceService**:逐条比对我们产品在 GIE/InferencePool 网关推理扩展、Managed DRA、多协议(OpenAI+Anthropic)、KEDA scale-to-zero、LoRA 亲和调度上的差距。
- [ ] **Model Registry → AI Hub 的边界扩张**:Kubeflow Hub 把 Agent/MCP/Skill 纳入统一目录,评估我们的模型注册中心是否要跟进"Agent/MCP 目录"能力。
- [ ] **推理引擎"平台化"趋势**:vLLM(MRV2 覆盖 embedding/分类)、TensorRT-LLM(KVCacheManagerV2 + NIXL/Ray)、SGLang(diffusion + PD 分离)都在从"单一 LLM 引擎"扩成通用推理平台,产品选型/集成层需重新审视。
- [ ] **多模态生成进推理引擎**:SGLang 大举接入扩散(图像/视频),关注是否需要在服务层预留 diffusion 工作负载的调度/计量。
- [ ] **HF datasets>=4 破坏性升级**:自建评测(lm-eval)与任何依赖 dataset script 的流水线需排查兼容性。
- [ ] TGI 退役、KubeAI(原 Lingo)停更——两个曾经的候选项失活,数据源清单可降权。
