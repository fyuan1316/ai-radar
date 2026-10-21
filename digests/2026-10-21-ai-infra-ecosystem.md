# AI 推理 & MLOps 生态周报 2026-10-21

窗口:2026-10-14 ~ 2026-10-21(过去 7 天)。版本 bump / dependabot / CI / 纯文档修复已过滤。

## 摘要(5 条以内)

1. **"SystemOne" 结构化决策端点正成为跨引擎的事实标准**:vLLM v0.32.0 新增 `POST /v1/systemone`(默认开启),llama-stack 给 SGLang / llama.cpp provider 都补上了 SystemOne judgment,叠加上周 KubeAI 网关的 systemone 迁移——一个用来做 choice/score/判别的通用原语正在各家落地,值得我们在推理网关层评估接入。
2. **KServe `llmisvc`(LLMInferenceService)是本周信息密度最高的上游**:KEDA 自动伸缩分离式(DisaggregatedSet)角色、wide-EP 的 DP-aware 路由、ModelExpress 权重加载、可插拔 TLS profile、vLLM-Omni 的 TTS/TTI 多模态端点——分离式推理 + 企业级能力同时推进。
3. **三大推理引擎同期发大版本**:vLLM v0.32.0(814 commits)、SGLang v0.5.22(950 PR)、TensorRT-LLM v1.4.0rc0。共同主线是低精度 KV cache(NVFP4/FP8)普及、稀疏注意力、PD 分离与 MoE/EP 并行提效。
4. **MLflow 向 Agent/GenAI 可观测性转身**:新增 Skill Registry、MCP 工具接入、`compare_evaluations` 配对统计、评估血缘(dataset/scorer/agent lineage)——从实验追踪扩到 agent 评估与治理。
5. **Kubeflow Trainer 落地 KEP-3015 Workload-Aware Scheduling**(配合 Volcano PodGroup 清理),训练侧的 gang/感知调度在补齐;Feast 接入 Apache Polaris lakehouse catalog。

---

## 推理引擎动态

### vLLM
- **v0.32.0** 发布(814 commits / 363 contributors):https://github.com/vllm-project/vllm/releases/tag/v0.32.0
  - **结构化决策端点 `POST /v1/systemone`**(#59299,默认服务 #60677/#60696):对结构化状态回答 choice/noul/score;新增 `--tool-call-parser hf` / `--reasoning-parser hf`,直接读 checkpoint 的 `response_template`,免写模型专属 parser(#58604/#58602),Python 与 Rust 前端都支持。
  - **低精度 KV cache 全面铺开**:NVFP4 KV cache 覆盖 SM8x/SM12x/SM90;GLM-5.x 在 SM100 默认 FP8 KV cache,每 rank KV 内存减半、吞吐 +2.3~5.5%(TTFT 代价 7~11%);ROCm 新增 4-bit `ultraquant_4bit`(密度约 FP8 的 2 倍)。
  - **Model Runner V2** 成 ROCm 默认:GPU n-gram 投机解码、Elastic EP、MLA 的 PP+prefill CP。
  - **启动/服务提速**:`vllm download-kernels` 装 FlashInfer 预编译核;`--api-server-count>1` 时连接走最空闲 worker,短请求 req/s +43~85%。
  - **启示**:systemone + hf 通用 parser 是"少配置、免适配"方向,和我们做"开箱即用推理服务"的目标一致;低精度 KV cache 的默认化意味着显存账要按 FP8/NVFP4 重算。

### SGLang
- **v0.5.22** 发布(950 PR / 245 contributors):https://github.com/sgl-project/sglang/releases/tag/v0.5.22
  - DeepSeek-V4.1 在 H200 单卡吞吐最高 +2.3x,并支持 AMD MI350X/MI355X(DSpark,最高 1.9x);InstantTensor loader 让模型加载快 10x。
  - **PD 分离**在长 prompt 负载上吞吐 +27%、p95 TTFT 减半;HiSparse 支持 EAGLE/MTP 的 CPU 内存 KV 长上下文;GLM-5.2/5.3 支持 decode CP 叠加 MTP。
  - 新增 Apple Silicon(标准 PyTorch 后端)、ComfyUI 的 SGLang Diffusion(含 GGUF/LoRA)。
  - **启示**:PD 分离与 KServe `llmisvc` 的 DisaggregatedSet 是同一趋势;AMD 加速卡一等公民化值得在多厂商纳管里跟。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.4.0rc0**:https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc0
  - 新增 Mooncake store pool + V2 调度器抢占(part 1)、稀疏 KV cache 配置/分层锁/offload(为 DeepSeek V4 稀疏 KV offload 铺路)、beam search 走 C++ KVCacheManagerV2。
  - **破坏性 API**:移除 KVCacheManagerV2 的 Python 后端(#19154)、LlmRequest 字段迁到 Python(#19484);OpenAI server 新增 per-model serving-extension registry(#19499),wheel 内置 OpenEngine gRPC 绑定。
  - **启示**:Mooncake(KV 存储池)+ 稀疏 KV offload 是 KV 分层/外置存储的硬件厂商版本,和 vLLM/SGLang 的 CPU-KV、KServe 的 ModelExpress 可横向对比。
- **text-generation-inference(TGI)**:仍为 archived 状态(最后 push 2026-03-21),窗口内 0 提交,属正常停维护,不再跟踪。
- **Ollama v0.40.5~v0.40.7**:https://github.com/ollama/ollama/releases/tag/v0.40.7
  - 上架 NVIDIA Nemotron 3.5 Super(120B 混合 Mamba-2/Transformer MoE,1M 上下文)与 24GB 可跑的 Bolt(74B);修复 OpenAI 兼容 Responses 会话跨模型切换、流式工具调用乱序;客户端断连时取消云端请求。

---

## 模型服务 & 编排

### KServe 上游(本周重点,无 release 但 main 很活跃)
LLMInferenceService(`llmisvc`)路线全面推进:
- **分离式推理(Disaggregated)**:用 KEDA 自动伸缩 DisaggregatedSet 角色(https://github.com/kserve/kserve/pull/6383);修复零副本 DS 角色在扩容时卡死(#6390)、更新时保留 DisaggregatedSet 控制器注解(#6428)。
- **路由 & 并行**:wide-EP 的 DP-aware 路由(https://github.com/kserve/kserve/pull/6386);为路由 sidecar 和 HTTP tokenizer 配置 tracing(#6403);`--max-concurrent-reconciles` 可调(#6358)。
- **权重加载**:通过 ModelExpress 加载模型权重(https://github.com/kserve/kserve/pull/6408);modelcache 对已缓存 OCI 模型跳过 modelcar(#6395)。
- **企业级安全**:可插拔 TLS profile(#6182)、TLS 最低版本与 cipher-suites 模板变量(#5924)。
- **多模态**:`llmisvc` 提供 vLLM-Omni 的 TTS/TTI 模态端点(https://github.com/kserve/kserve/pull/6285)。
- **本地模型**:消费者仍在时阻止共享 PVC 重导入(#6280);导入 Job 去掉 fsGroup(#6361)。
- **启示**:这是对标 OAI 最直接的战场。KEDA 伸缩分离角色 + DP-aware 路由 + ModelExpress 权重分发,正是我们产品"分离式推理 + GPU 高效调度"要对齐的能力清单;TLS profile/min-version 是企业合规可以直接借鉴的落点。

### Ray
- 本周仅补丁:ray-2.58.1 / ray-2.57.1(https://github.com/ray-project/ray/releases/tag/ray-2.58.1),修 Ray Data passthrough 数据集的 block callback 误报、base-extra 镜像装 gcloud CLI。无重大功能更新。

### KubeAI(原 substratusai/lingo)
- 窗口内偏安静,仅修复:RBAC 模板(#764)、SeaweedFS 镜像与 S3 配置参数(#762)、更新 vLLM V1 metrics 的 Grafana 面板(#760)。上周刚发 v0.24.0 重构网关(含 Anthropic `/v1/messages`、systemone 迁移),本周为收尾。

---

## 训练 & 微调

- **Kubeflow Trainer(原 training-operator)**:落地 **KEP-3015 Workload-Aware Scheduling for TrainJob**(https://github.com/kubeflow/trainer/pull/3219);TrainJob 进入终态/挂起时清理 Volcano PodGroup(#4059);S3 initializer 仅下载指定 prefix 下对象(#4116);MLX runtime 镜像换 CUDA 13 构建(#4246);新增 Prometheus 监控 overlay(#4102)。
  - **启示**:感知调度 + Volcano gang 的组合是训练侧多租户/资源保障的关键,和我们 GPU 调度能力可对比 KEP-3015 的设计。
- **LLaMA-Factory(hiyouga/LLaMA-Factory)**:窗口内仅 1 次提交,无重大更新。

---

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow**:v3.17.2 补丁(https://github.com/mlflow/mlflow/releases/tag/v3.17.2),记录 `mlflow.genai.evaluate` 的 dataset/scorer/agent 血缘。main 上信号更密,整体在向 **Agent/GenAI 可观测性与治理**转:
  - **Skill Registry**(用户文档 #26806、响应含 allowed actions #26900、skill 级 tag 权限 #26946);
  - **MCP 接入**:工具刷新优先 MCP access endpoint 而非 server.json remotes(#26719);
  - **评估增强**:`mlflow.genai.compare_evaluations` 配对统计比较(#26396);评估 run 关联 dataset/scorers/prompts 的新 UI(#26782);
  - **Issues/triage** 工作流(原生 Issue 引用的结构化证据 #26791、triage 分流)。
  - **启示**:MLflow 把自己从实验追踪扩成 agent 评估 + skill/工具治理平台,和 KServe/我们做的"模型全生命周期"在 GenAI 侧开始重叠,需评估是整合还是对标。
- **Kubeflow Hub(原 model-registry,已并入 hub)**:本周全是 Model Catalog 修复——restrictToOrg 不再污染共享源集合(#3364)、HuggingFace cardData 直接解码(#3267)、Catalog 响应包进 data envelope(#3351)。catalog 化方向延续,无新功能。
- **Feast**:新增 **PolarisSource / PolarisProvider 接入 Apache Polaris**(lakehouse catalog,https://github.com/feast-dev/feast/pull/7006);PushSource 的上游 FeatureView 血缘(#6853);修 Ray engine 吞掉 materialization 错误(#7026)、DuckDB 下 Lance 源惰性扫描(perf)。

---

## LLM 评估 & 安全

- **garak v0.17.1**:https://github.com/NVIDIA/garak/releases/tag/v0.17.1
  - 新增 **hit@k 攻击成功率(ASR)指标**(#2090),在终端输出并写入 report.jsonl 的 per probe/detector digest;支持 Python 3.14;多处 detector 计分修复(FileDetector 不再把未检查文件判 pass #2080、RefusalOnlyAdversarial 不再多算跳过的多轮尝试 #2111);WebSocket generator 用 `--target_name` 作 uri。
  - **启示**:hit@k ASR 是比单次成功率更贴近实战的红队指标,若我们做模型安全门禁可直接采信这个口径。
- **lm-evaluation-harness**:窗口内 0 提交,无更新。
- **llama-stack(release 在 meta-llama/llama-stack,PR 指向 ogx-ai/ogx)**:v1.4.1(https://github.com/ogx-ai/ogx/releases/tag/v1.4.1),新增 PostgreSQL 连接 URI 支持 SQL/KV store。main 上重点:
  - 新增**远程 SGLang 推理 provider**(https://github.com/ogx-ai/ogx/pull/6776)并接入集成 CI(#6822);
  - 给 SGLang(#6782)与 llama.cpp(#6772)provider 补 **SystemOne judgment** 支持。
  - **启示**:llama-stack 把 SystemOne 判别接到多个 provider,进一步印证 systemone 原语的跨栈扩散。

---

## 值得跟进

- [ ] **评估 SystemOne 原语**:读 vLLM `POST /v1/systemone`(PR #59299)与 llama-stack 的 provider 实现(#6782/#6772),判断是否在我们推理网关层提供统一 choice/score/judge 端点。
- [ ] **对标 KServe llmisvc 分离式能力**:精读 KEDA 伸缩 DisaggregatedSet(#6383)+ DP-aware 路由(#6386)+ ModelExpress 权重加载(#6408),列出与我方分离式推理的差距项。
- [ ] **借鉴 KServe TLS profile**:#6182 / #5924 的可插拔 TLS profile + min-version/cipher-suites,作为企业合规的现成设计参考。
- [ ] **跟 Kubeflow Trainer KEP-3015**:对照其 Workload-Aware Scheduling(#3219)与 Volcano 集成,评估我方训练调度的差距。
- [ ] **观察 MLflow 向 agent 治理扩张**:Skill Registry + MCP 接入(#26719)是否与我们的模型生命周期功能重叠,决定整合/对标策略。
- [ ] **安全口径**:在模型安全门禁里考虑 garak hit@k ASR(#2090)作为统一指标。
