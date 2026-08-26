# AI 推理 & MLOps 生态周报 2026-08-26

> 窗口:2026-08-19 ~ 2026-08-26。数据源经过改名映射(lingo→kubeai、training-operator→trainer、TGI 已归档)。只筛"对做云原生 AI 基础设施产品有用"的变化,版本 bump / CI / dependabot 已全部跳过。

## 摘要(5 条以内)

1. **Ray 2.58.0 把"KV-cache & token 感知路由"做完了**:tokenization 在 LLMRouter ingress 副本内进程完成、KV 生命周期事件广播到每个 ingress、且**把 CPU 侧 offload 的 KV 块也算进缓存命中**——这是推理网关层最值得对标的能力。https://github.com/ray-project/ray/releases/tag/ray-2.58.0
2. **KServe 上游 llmisvc 给 LoRA 适配器加了 localModelCache**,并把 llm-d 镜像升到 0.10——上游正把"LoRA 多适配器 + 本地模型缓存 + llm-d 分布式推理"往生产形态收。https://github.com/kserve/kserve/pull/5690
3. **MLflow 把 basic-auth 默认改成 fail-closed(默认拒绝)**,并逐条给原生 FastAPI/网关/job 路由加按 owner 的授权门禁——企业级鉴权硬化,值得我们抄安全默认值。https://github.com/mlflow/mlflow/pull/25308
4. **SGLang v0.5.18(710 PR)**:启动期 checkpoint overlap 加载(冷启快至 2.38x)、NVFP4 权重可在 AMD 上跑、编译缓存目录统一;同时大规模押注 diffusion/视频生成 serving。https://github.com/sgl-project/sglang/releases/tag/v0.5.18
5. **kubeflow/model-registry 持续 catalog 化**:新增 skill catalog manifests + KEP、MCP 详情页,Python client 切 v1 端点并**移除实验追踪**——Registry 正从"模型登记"扩到"skill/agent catalog + MCP"。https://github.com/kubeflow/model-registry/pull/3109

## 推理引擎动态

### vLLM
本周无 release,但主干有几处产品向信号:
- **新增 `/v1/messages/render` 端点对齐 Anthropic Messages API**(#45803),外加 Cohere ChatV2 render 端点——前端 API 兼容面继续扩。https://github.com/vllm-project/vllm/pull/45803
- **Rust 前端 gRPC 加 LoRA 生命周期控制**(#52840),配合 DeepSeek V4 LoRA、Qwen3-Omni 多模态 LoRA——动态挂载/卸载 LoRA 的生产化。https://github.com/vllm-project/vllm/pull/52840
- **多模态安全硬化**:强制 `VLLM_MAX_AUDIO_CLIP_FILESIZE_MB`、下载前拒绝超大媒体、日志里 redact `hf_token`/凭据(#53561/#51896/#53625/#53738)——企业部署关心的输入面收敛。https://github.com/vllm-project/vllm/pull/51896
- 空闲流式加 SSE keep-alive 注释(#51034);Model Runner V2 推进;删了十个废弃模型架构(#53608);RL 场景 P2P RDT 权重同步(#43375)。

### SGLang
**v0.5.18 发布**(212 位贡献者,710 PR),对我们有参考价值的:
- **启动期 overlap 加载**:checkpoint 分页在 CUDA graph capture 时并行 staging,Qwen3-32B 冷启比默认快 2.38x,`--startup-weight-load-mode overlap` 开启——大模型副本扩容速度直接相关。
- **NVFP4 checkpoint 可在 AMD 跑**(`--quantization quark_mxfp4`,加载时转 MXFP4,不留全精度副本);**编译缓存统一到 `SGLANG_CACHE_DIR`**(Triton/FlashInfer/Inductor/DeepGEMM 一处)——容器镜像/缓存卷设计可借鉴。
- 主干出现大量 **diffusion / 视频生成 serving** 提交(MiniMax-H3、Cosmos3、LongCat-Image、SANA-Video 等)+ Rust server 原生多模态,SGLang 明显在往"多模态/视频生成推理"扩边界。
- 调度器新增**已发布权重版本追踪 / per-token 权重版本 span**(#35925~#35929)——面向 RL/在线更权重的可观测。
https://github.com/sgl-project/sglang/releases/tag/v0.5.18

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:无 release,主干 BREAKING **移除 star attention**(#18025);上了 **VisualGen serving API**(#17490,视频/图像生成服务,支持 `response_format` 与异步 job 状态)与 **VisualGen 动态 LoRA**(#17435);**LoRA CUDA graph 特化**(#17412)与 LoRA/base 计算 overlap(#16951);DeepSeek-V4/DSA 经 FlashInfer sparse-MLA 上 SM120(#16224);Ray disagg 传 `server_start_timeout`(#18012)。整体:LoRA 生产化 + 生成式多模态 serving。
- **TGI**:仓库已归档(最后 push 2026-03-21),窗口内 0 提交,属正常停维护,不再跟踪。
- **Ollama v0.33.0 / v0.32.15**:核心是 **把 Ollama 做成 Claude Desktop 的第三方网关 provider**(Claude Desktop model mapping / Auto mode / origin 校验),以及一批 **prefill 缓存/恢复点可靠性修复**(取消的 prefill 保留 restore point,避免 47k token 里差 1k 就全量重算);还禁掉了 Claude Code "剩余 token" 系统消息以免每次请求打断 KV cache。https://github.com/ollama/ollama/releases/tag/v0.33.0

## 模型服务 & 编排

### KServe 上游
最实质的一周,方向清晰:
- **llmisvc 给 LoRA 适配器加 localModelCache**(#5690),并修"LoRA served name 不一定是合法对象名"(#6077)、路由规则删除检测(#6046)——LoRA 多适配器服务正在补生产细节。https://github.com/kserve/kserve/pull/5690
- **llm-d 镜像升到 0.10**(#6026)——KServe 与 llm-d 分布式推理栈的绑定继续跟版。https://github.com/kserve/kserve/pull/6026
- autoscaler 对无 autoScaling 的组件跳过 KEDA ScaledObject(#6029);JWE 解密同时支持完整 JWK 与裸 key(#6034);两枚 CVE 修复(opentelemetry-go / urllib3)。
- 治理:移除废弃 plugin 并重命名 flag(#6067),CLI flag drift 检测(#6035)。

### Ray
**2.58.0 是本周分量最重的 release**:
- **Ray Serve LLM:KV-cache & token 感知路由收尾**——tokenization 移到 `LLMRouter` ingress 进程内做、路由决策在此下、token 带外传给 engine 避免二次 tokenize、KV 生命周期事件广播到所有 ingress 副本;**CPU 侧 offload 的 KV 块也计入命中**(#64642/#65063 等)。附带 KV-aware 路由指南 + 原生 KV offload 文档(#65569)。
- **TPU 支持成型**:Ray Train 加 TorchTPU 后端、Ray Core 加 `SubslicePlacementGroup` 做 TPU subslice gang 调度、`tpu7x` 资源核算(#64796/#64578)。
- **Ray Sandbox(实验)**:task/actor 跑在 gVisor 下、可直接跑 Docker 构建的镜像(#64964/#65570)——多租户隔离思路。
- **Serve 支持带 gang 调度的 scale-to-zero**(#65575);KubeRay 侧把 worker group 优先级从 RayCluster CR 透传给 autoscaler(#65244)。
https://github.com/ray-project/ray/releases/tag/ray-2.58.0

**substratusai/lingo → kubeai-project/kubeai**:窗口内 0 提交,持续静默,无重大更新。

## 训练 & 微调
- **kubeflow/trainer(原 training-operator)**:基本是 deps bump,唯一产品向是 **controller metrics 端点加 TLS + 基于 RBAC 的鉴权**(#3912)、initializer 改进 dataset provider 报错(#3826)。整体安静。https://github.com/kubeflow/trainer/pull/3912
- **LLaMA-Factory**:仅 2 提交——v1 支持 GDN Ulysses context parallel(#10727)、补 NPU 镜像 tag 历史。无重大更新。

## 模型生命周期(MLflow / Registry / Feast)
- **MLflow**:企业级安全是主线——**basic-auth 默认 fail-closed**(#25308)、逐批给原生 FastAPI / gateway / job 路由加**按 owner 的授权门禁**(#25069~#25102 系列)、修 basic-auth 覆盖 K8s auth(#25131)、redact 网关 secrets 口令(#25298)。另有 Traces V4 表能力移植进 OSS、自动评估路径加限流+重试(#24702)、内置 judge 支持 UC 模型服务(#25246)、MLflow Assistant 修复。https://github.com/mlflow/mlflow/pull/25308
- **kubeflow/model-registry**:**catalog 化**继续——新增 **skill catalog manifests + KEP 示例**(#3109)、MCP 详情页、catalog source 校验状态刷新;**Python client 切 v1 端点并移除实验追踪**(BREAKING #3114)、强制 v1 OpenAPI 命名规范(#3086)。方向:模型登记 → skill/agent/MCP catalog。https://github.com/kubeflow/model-registry/pull/3109
- **Feast v0.66.0**:operator 增强明显——**FeatureStore CR 支持 tolerations/nodeSelector**、**onlineStore.disabled 可选关在线库**(#6586)、Lineage 配置走 operator、RBAC 规则重组、默认认证改 K8s auth;还避免 import 时拉起 `feast.feature_store`(MCP server 相关)。企业化/operator 化在推进。https://github.com/feast-dev/feast/releases/tag/v0.66.0

## LLM 评估 & 安全
- **lm-evaluation-harness**:加**跨平台 onnxruntime-genai 后端**(#3960)、chat completions 支持 `think_end_token`(适配 reasoning 模型输出)(#3959)、自定义任务支持函数解析(#3992);一批 task 注册与配置解析修复。https://github.com/EleutherAI/lm-evaluation-harness/pull/3960
- **garak**:**AgentBreaker judge 现在以"受害者的工具契约(tool contract)"为锚**做判定(#1970),区分"未判定输出"与"干净未命中"、先判普遍危害再过契约/用途门——agentic/工具调用 agent 的红队方向明确;因兼容性临时 pin anthropic client(#2098)。https://github.com/NVIDIA/garak/pull/1970
- **llama-stack v1.2.4(内部仓 ogx-ai/ogx)**:Responses API 支持 **`truncation=auto` 的反应式截断**(#6410)、**可关闭 chat completions 持久化**(#6412);**向量库元数据持久化到 kvstore**(Milvus/Chroma/Weaviate,重启后仍可查,#6371);修 Anthropic-compat 用量把 cached token 算两遍(#6415);Postgres store 加 ssl_mode/ca_cert(#6196)。https://github.com/meta-llama/llama-stack/releases/tag/v1.2.4

## 值得跟进
- [ ] **对标 Ray Serve LLM 的 KV-aware 路由**:重点看"ingress 内进程 tokenize + KV 事件广播 + CPU offload KV 计入命中"这套是否能移植到我们的推理网关/KServe llmisvc 路由层。
- [ ] **KServe llmisvc 的 LoRA + localModelCache + llm-d 0.10**:这是上游 LLM 服务的主推形态,评估我们产品的 LoRA 多适配器/本地缓存路径差距。
- [ ] **抄 MLflow 的 fail-closed 鉴权默认值**:把"默认拒绝 + 按 owner/job 门禁"作为多租户平台的安全基线。
- [ ] **model-registry 的 skill/agent catalog + MCP 走向**:关系到我们"模型生命周期"是否要延伸到 skill/MCP catalog。
- [ ] **SGLang 启动期 overlap 加载 + 统一编译缓存目录**:对大模型副本冷启/扩容速度与镜像缓存卷设计有直接借鉴。
- [ ] **生成式多模态 serving**:SGLang / TensorRT-LLM(VisualGen)都在把 diffusion/视频生成纳入推理栈,评估是否进入我们路线图。
