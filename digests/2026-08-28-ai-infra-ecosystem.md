# AI 推理 & MLOps 生态周报 2026-08-28

覆盖窗口:2026-08-21 ~ 08-28。仓库改名沿用备忘:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer;TGI 已 archived(永远 0 提交,正常)。

## 摘要(5 条以内)

1. **vLLM v0.28.0** 落地"分层 KV cache 到磁盘"+ Model Runner V2 的 E/P/D 分离,推理引擎侧的存算分离/KV 卸载正在成为标配能力,直接影响我们如何设计推理层的缓存与调度。
2. **KServe** 本周主线几乎全在 `llmisvc`:LoRA 多适配器挂载消歧、localModelCache 支持 LoRA、canary 权重收敛到 predictor,外加一次 `kernelcache/mcv` 新模块代码捐赠——上游把 LLM 服务化做得越来越"重",是我们对标 OAI 推理栈的第一参照。
3. **Ray 2.58.0** 完成 Ray Serve LLM 的 **KV-cache/token 感知路由**(含 CPU 卸载 KV 计入命中),并新增 gVisor 沙箱与 TPU gang 调度——分布式推理路由这块 Ray 已经补齐到生产级。
4. **kubeflow/model-registry 全面 catalog 化**:本周新增 skill catalog manifests + KEP,Python 客户端切 v1 端点并**移除实验跟踪**(破坏性);Registry 正从"模型登记"演进成"技能/Agent 目录",值得跟我们的模型生命周期定位对齐。
5. **安全/评估侧**:llama-stack 做结构化日志脱敏 + 可信代理头加固;garak 的 AgentBreaker 检测器把越狱判定"锚定到被测工具契约"——Agent 安全测试开始工程化,是企业合规能力的新增量。

## 推理引擎动态

### vLLM
**v0.28.0**(08-26,584 commits/270 contributors)https://github.com/vllm-project/vllm/releases/tag/v0.28.0
对我们有用的几条:
- **分层 KV cache 卸载**:新增磁盘卸载(#49644)、树外二级 tier 管理器 via `module_path`(#51007)、分层指标(#48798)、以及跨并行度无关的规范 CPU 布局(#48414)。推理层"显存→内存→磁盘"三级 KV 卸载已可插件化,对长上下文/高并发成本优化是关键。
- **Model Runner V2 成熟**:E/P/D 分离(#38390)、权重卸载(#51413)、多层 MTP KV cache(#50062)。Prefill/Decode 分离进入引擎内建。
- **Rust 前端 + gRPC**:独立 renderer(#50289)、多模态图像走 gRPC(#50368)、显式 DP rank 路由(#51178)、protobuf schema 发布到 Buf(#51276)——前端与调度解耦,便于外部编排层接管路由。
- 新默认值:`max_num_batched_tokens` 8192→16384(#51726);Blackwell CUDA graph 默认 1024(#49390)。
- 破坏性:bitsandbytes 迁出为树外插件(#43529);移除 `calculate_kv_scales` 运行时 KV scale(#49389)。

### SGLang
**v0.5.18**(08-22,710 PRs/212 contributors)https://github.com/sgl-project/sglang/releases/tag/v0.5.18
- **启动期重叠 checkpoint staging**:权重从存储 staging 与 CUDA graph 捕获重叠,Qwen3-32B/H100 冷启动比默认快 **2.38x(84.8s→35.6s)**,`--startup-weight-load-mode overlap`(#32017)。对弹性扩缩/冷启延迟是实打实的收益。
- **NVFP4 权重在 AMD 上跑**:load 时 dequant 再 requant 到 MXFP4,GSM8K 恢复 97.5–100.2%(#29328),跨厂商量化互通。
- 编译缓存统一到 `SGLANG_CACHE_DIR`(#32434,破坏性,首启会重编一次);依赖 torch 2.13 / flashinfer 0.6.17。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:窗口内无 release 但主线很活跃——**DeepSeek-V4 Hopper 支持**(#16940)、**Python KV-cache transceiver 设为默认运行时**(#18134)、**Responses API 补齐 `/v1/responses` 面向 agent CLI**(#18130)。KV 传输与 Responses API 是两条值得盯的线。https://github.com/NVIDIA/TensorRT-LLM/commits/main
- **Ollama v0.33.0/0.33.1**(08-21/08-26)https://github.com/ollama/ollama/releases/tag/v0.33.0 —— 主打作为 **Claude Desktop 第三方 gateway** 接入,以及一批 prefill 缓存正确性修复(取消的 prefill 保留 restore point,重试从断点续跑)。信号:桌面 Agent 客户端把本地推理当标准后端接。
- **TGI**:已 archived,无更新(属正常)。

## 模型服务 & 编排

### KServe 上游
本周提交几乎集中在 LLM 服务化,最值得看的:https://github.com/kserve/kserve/commits/main
- `feat(kernelcache): kernelcache/mcv 初始代码捐赠`(#5590)——新模块进场,后续观察其定位。
- `feat(llmisvc): localModelCache 支持 LoRA 适配器`(#5690)+ `fix: LoRA 适配器挂载路径消歧`(#6085)/`校验 config 声明的 LoRA`(#6092)/`不假设 LoRA 名是合法对象名`(#6077)——多 LoRA 适配器的服务化细节在批量收敛。
- `fix(httproute): canary 权重限制在 predictor 规则`(#5944);`fix(autoscaler): 无 autoScaling 的组件跳过 KEDA ScaledObject`(#6029)。
- 一批 CVE 修复(setuptools/urllib3/opentelemetry-go)。
> 启示:上游把 `llmisvc` + LoRA 多适配器 + localModelCache 做成一等公民,是我们推理产品需要对齐的能力基线。

### Ray
**ray-2.58.0**(08-23)https://github.com/ray-project/ray/releases/tag/ray-2.58.0
- **Ray Serve LLM:KV-cache/token 感知路由完成**:tokenization 在 `LLMRouter` ingress 副本内做,路由决策就地完成,token 带外传输避免引擎重复 tokenize,KV 生命周期事件广播到所有 ingress 副本;**CPU 卸载的 KV 块也计入副本命中**(#64642/#64920/#65063)。这正是"KV-aware 路由"生产化的完整拼图。
- Ray Core:任务事件可从 GCS 热路径卸载到独立 task-events head(#64835 等)。
- **Ray Sandbox**:实验性 gVisor 沙箱,可直接跑 Docker 镜像(#64964/#65570)——多租户隔离方向。
- TPU:Ray Train 支持 TorchTPU 后端,Core 新增 `SubslicePlacementGroup` gang 调度(#64796/#64578)。
- **安全**:修复 `read_lance`/嵌套 pickle 的 RCE(#64881)。
- KubeAI(原 lingo)本周 0 提交,持续静默。

## 训练 & 微调

- **kubeflow/trainer**(Trainer v2,无 release)https://github.com/kubeflow/trainer/commits/main
  - `feat(runtimes): 给 TrainingRuntime 加弃用警告`(#3966)——v1 TrainingRuntime 走向淘汰,新用户应用 v2 语义。
  - 一批控制器加固:`校验 TrainJob 更新对齐 runtime snapshot`(#3960)、`拒绝超大分块 status 请求`(#3973)、`Flux reconcile 空字段 panic 修复`(#3904)。稳定性收尾为主,无新特性。
- **hiyouga/LLaMA-Factory**:仅 3 条,亮点 `[v1] LoRA 支持 FSDPTurbo 专家并行`(#10791)。MoE + LoRA 微调路径在补。https://github.com/hiyouga/LLaMA-Factory/commits/main

## 模型生命周期(MLflow / Registry / Feast)

- **kubeflow/model-registry**(无 release,catalog 化持续)https://github.com/kubeflow/model-registry/commits/main
  - `feat(catalog): 新增 skill catalog manifests + KEP 示例`(#3109);`fix(catalog): 多插件共享时不误删 source 状态`(#3107)、`scope model source-id 查询、拒绝多仓内联`(#3108)。
  - **破坏性**:`feat(python-client)!: 切 v1 端点并移除实验跟踪`(#3114)。
  > 启示:Registry 正从"模型登记"扩展到 **skill / agent catalog**(git-backed + KEP 化),这是模型生命周期产品定位的一次外扩,值得对照我们的规划。
- **mlflow v3.15.2**(08-26,patch)https://github.com/mlflow/mlflow/releases/tag/v3.15.2 —— 评估侧:**不可变评估数据集版本**(#24845)、**scorer_ensemble 组合多 scorer 结果**(#24749)。MLflow 持续把 GenAI 评估做成一等能力。
- **feast v0.66.0**(08-21)https://github.com/feast-dev/feast/releases/tag/v0.66.0
  - 企业能力:**Feast Operator 集成 MLflow**(#6611)、OIDC audience/issuer 校验(#6670)、Entra ID 声明支持(#6631)、RBAC 规则重组、CronJob 与 feature-server ServiceAccount 分离(#398f643)。
  - 新特性:`ConnectionRef` 可插拔外部凭据(#28bde01)、HybridOfflineStore(#6707)、SQL registry schema_mode(#6704)。多租户/凭据/合规是本版主线。

## LLM 评估 & 安全

- **NVIDIA/garak**(无 release)https://github.com/NVIDIA/garak/commits/main —— **AgentBreaker 检测器工程化**:把越狱判定"锚定到被测工具契约"(#1970),契约缺失时告警、区分"未判定"与"干净未命中"、先判普适危害再过契约/目的门(NAIS-349 系列)。Agent 红队测试正从"看输出"转向"看是否违反工具契约",对企业级 Agent 安全评估是新范式。
- **meta-llama/llama-stack**(release 仍发在此仓,窗口内无 release)https://github.com/meta-llama/llama-stack/commits/main
  - 安全加固:`结构化日志脱敏`(#6433)、`upstream_header 加可信代理校验`(#6436)、`Postgres 配置加 ssl_mode/ca_cert_path`(#6196)。
  - `Responses API 实现 truncation=auto 的反应式截断`(#6410)——Responses API 的上下文管理在补。
- **EleutherAI/lm-evaluation-harness**(无 release,32 提交)https://github.com/EleutherAI/lm-evaluation-harness/commits/main —— 主要是新 benchmark 与多语言任务铺量(LongProc 长流程 6 类任务 #3544、TyDiQA 9 语言 #4044、GreekMMLU #3581),以及 **onnxruntime / onnxruntime-genai 后端**(#3984/#3960)。无架构级变化,属评测覆盖扩容。

## 值得跟进

- [ ] **KV-aware 路由**:Ray Serve LLM(#64642 系列)已完成 token/KV 感知路由 + CPU KV 命中计入,vLLM 也在做分层 KV 卸载(#49644)——评估我们推理层是否需要把"KV 感知路由 + 分层卸载"纳入路线图。
- [ ] **KServe llmisvc + 多 LoRA**:localModelCache 支持 LoRA(#5690)是对标 OAI 的直接能力点,跟进 `kernelcache/mcv`(#5590)后续定位。
- [ ] **Model Registry → skill/agent catalog**(#3109):上游把 Registry 外扩到技能目录,判断是否与我们的模型生命周期规划冲突或可借鉴。
- [ ] **Agent 安全评估**:garak AgentBreaker 的"工具契约锚定"判定(#1970)+ llama-stack 日志脱敏(#6433),可作为我们企业级 Agent 合规能力的参照。
- [ ] **推理引擎冷启动**:SGLang overlap staging(#32017)2.38x 冷启加速,评估对我们弹性扩缩/Serverless 推理的价值。
