# AI 推理 & MLOps 生态周报 2026-08-07

> 覆盖窗口:2026-07-31 ~ 2026-08-07(过去 7 天)。已过滤 version bump / dependabot / CI 噪音,只保留对"云原生 AI 基础设施产品"有借鉴或威胁意义的变化。

## 摘要(5 条以内)

1. **KServe v0.20.0 正式发布**,`LLMInferenceService`(llmisvc)继续快速成熟:加入基于模型的路由门控、直连 KEDA 扩缩容、DRA/LoRA 注解校验,并支持 Python 3.13。这是本周与我们产品最直接相关的信号。https://github.com/kserve/kserve/releases/tag/v0.20.0
2. **Kubeflow Trainer v2.3.0 发布**,新增 `OptimizationJob` CRD(超参优化,KEP-3562)与 runtime 快照机制(KEP-2599);但带**两处 BREAKING**(移除 Runtime Finalizers、CRD 挪进 Helm 模板),从 v2.0/2.1/2.2 升级必须先落 v2.3 再往上。https://github.com/kubeflow/trainer/releases/tag/v2.3.0
3. **Ray Data/Serve LLM 能力 GA**(#65194),同时修掉一处 Serve 副本 token 认证被绕过的安全问题(#65189)——多租户网关场景要留意。
4. **MLflow 3.15.0** 上线 **MCP Registry**(集中登记/版本化 MCP server,自带 Claude Code、`.mcp.json` 连接说明)+ 预签名 URL 直传制品(绕过 tracking server)+ LLM 评审支持多模态。MLOps 平台正把"注册中心"的边界从模型扩到 MCP/Agent。
5. **模型生命周期整体在向 Agent/MCP/Skill 靠拢**:kubeflow/model-registry 本周加了 MCP server API 与 catalog 的 SKILL.md 解析/skill 插件;llama-stack(OGX)加了检索后重排分类器。评估侧 garak v0.16.0 引入"上下文感知扫描"(trait/intent/policy + IntentProbe)。

## 推理引擎动态

### vLLM
无 release,但 main 高频推进,重点是 **Model Runner V2**:支持 `thinking_token_budget`(#46727)、decoder token-wise pooling(#50931)、以及若干 draft/rejection sampling 修复。另有值得关注的工程化动作:
- **独立 Rust 前端渲染器**(#50289)——vLLM 前端在往 Rust 迁,长期看会改变 sidecar/网关的集成方式。
- PRIORITY 调度静默丢请求的修复(#49206)、KV Offload 失败清理与 `MADV_POPULATE_WRITE` 不支持时的回退(#51227/#51116)——离线/大上下文场景的健壮性补强。
- 治理层刷新 committers/TSC(#51300),项目治理结构在正规化。
来源:https://github.com/vllm-project/vllm/commits/main

### SGLang
两条主线:
- **Diffusion(图像/视频)持续加码**:FLUX.2 bit-exact 快路径、Z-Image/FLUX.1 VAE 解码器泛化、序列并行注意力——SGLang 明显在从"LLM 推理"扩成"多模态生成引擎"。
- **Disagg(P/D 分离)**:StagingBuffer 支持 radix cache(#30545),配合 ModelOpt FP4 在线 MoE 量化(#33115)。对做 P/D 分离部署的平台是可参考的工程路径。
来源:https://github.com/sgl-project/sglang/commits/main

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:发了 v1.3.0rc23(仍 RC)。功能面新增 **Kimi K3(KimiLinear)模型**(#17269)、支持读取 `generation_config.json` 采样默认值(#17213);注意一处 **BREAKING**——block reuse 策略重命名(#17277)。日常 commit 大量是 nvbugs 修复与测试解禁,信息噪音高。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc23
- **TGI**:本周**无重大更新**(0 提交),HuggingFace 侧几乎停更,持续观察其是否被 vLLM/SGLang 边缘化。
- **Ollama v0.32.6**:`/v1/chat/completions` 流式输出**对齐 OpenAI wire format**(role 只在首块、finish_reason 独立块、usage 独立块),截断响应报 `finish_reason:"length"`;Qwen3.5 在 Apple MLX 上自动用 MTP 头做投机解码。实验性图像生成被临时下线。https://github.com/ollama/ollama/releases/tag/v0.32.6

## 模型服务 & 编排

### KServe 上游
**v0.20.0 是本周头条**,`LLMInferenceService` 相关改动密集,值得逐条对标:
- `feat(llmisvc)`: **基于模型的路由门控 + status 里暴露 models**(#5579)——多模型/多 LoRA 路由能力在补齐。
- `feat(llmisvc)`: **直连 KEDA 扩缩容**(#5839)——不再必须绕 HPA,事件驱动扩缩容更顺。
- `fix(llmisvc)`: 收口 **LoRA 与 DRA 注解**的 v1alpha1 校验(#5938)——GPU 动态资源分配(DRA)已进入 KServe 的 LLM 服务面。
- `feat(llmisvc)`: 缓存 inferenceservice-config 并 watch 变更(#5573)、状态模型名变更时重新入队组内 peer(#5943)。
- 平台面:**支持 Python 3.13**(#5897)、transformer 注入 CA bundle 给 httpx(#5932)、`RawKubeReconciler` 在 Reconcile 内设置 owner refs(#5934)。
> 启示:KServe 正把 llmisvc 做成"LLM 专用 CRD",路由/扩缩容/DRA/LoRA 都往这条线收敛。我们如果自研 LLM 服务面,应直接对标 llmisvc 的 CRD 语义而非老的 InferenceService。
来源:https://github.com/kserve/kserve/releases/tag/v0.20.0

### Ray
- **Ray Data / Serve LLM GA**(#65194)——`ray.data.llm` 批量推理与 Serve LLM 正式转正,同时把重引擎 import 延迟加载(#64990),降冷启动开销。
- **安全**:修复 Serve 副本 `ASGIService` 绕过 token 认证(#65189)——对外暴露 Serve 端点的多租户平台请评估影响。
- Core 稳定性:`check_signals` 改为上报关闭而非直接退出进程(#65184)、owner 内存泄漏与 double-free 修复(#65133/#65246)。
- 支持 multipart/form-data 文件上传进 `HttpRequestUDF`(#63903)——多模态数据管线更顺。
来源:https://github.com/ray-project/ray/commits/master

### KubeAI(原 substratusai/lingo)
本周**无更新**(0 提交)。

## 训练 & 微调

- **Kubeflow Trainer v2.3.0**(见摘要):
  - 新增 **`OptimizationJob` CRD**(KEP-3562)——把超参优化纳入 CRD,训练 operator 往"训练+调优"一体化走。
  - **runtime 快照机制**(KEP-2599)、MPI launcher 依赖 worker readiness(#3748)、PodSet 容器暴露 Image/Command(#3674)。
  - ⚠️ **两处 BREAKING**:移除 Runtime Finalizers(#3716)、CRD 移入 Helm chart 模板(#3655)。跨大版本升级必须先经 v2.3 中转,升级路径要写进我们的运维手册。
  来源:https://github.com/kubeflow/trainer/releases/tag/v2.3.0
- **LLaMA-Factory**:v1 重构推进——按模型类型重做 NPU kernel 匹配(#10643,昇腾相关)、**支持多模态数据训练**(#10656)、新增 MOSS-VL(#10708)。国内/NPU 微调链路值得盯。
  来源:https://github.com/hiyouga/LLaMA-Factory/commits/main

## 模型生命周期(MLflow / Registry / Feast)

### MLflow 3.15.0 / 3.15.1
- **MCP Registry**:集中登记、语义化版本、可提升的 alias、自动发现工具,并直出 Claude Code / `.mcp.json` 连接说明——注册中心边界从"模型"扩到"MCP server"。
- **MLflow Assistant** 支持多 LLM provider(Claude Code / Codex / OpenAI 兼容),composer 内显示 token 用量与预估成本。
- **预签名 URL 直传制品**:大文件绕过 tracking server 直连 S3,失败自动回退代理传输——解决大制品超时,平台侧值得抄。
- **多模态 LLM 评审**:`{{ trace }}` judge 可通过 `get_span_image` 看到 trace span 里的图片。
来源:https://github.com/mlflow/mlflow/releases/tag/v3.15.0

### Kubeflow Model Registry
虽无 release,但方向很明确——**从"模型注册中心"扩成"Agent/MCP/Skill catalog"**:
- `feat(mcp)`: MCP server API 加 `serverJson` 字段(#3043)。
- `feat(catalog)`: **SKILL.md 解析器**(SKC-104)+ skill 插件脚手架(SKC-103)——开始把"技能"当一等公民纳入 catalog。
- 实现 model-registry v1 endpoints(#3037)、catalog 从崩溃 pod 抢回 stale leader lock(#3054,HA 健壮性)。
来源:https://github.com/kubeflow/model-registry/commits/main

### Feast
- **Remote Materialization**(#6649)——物化下推到远端执行,契合大规模特征物化。
- **Feast Operator 支持打包的 feature repo**——CRD 化部署更完整。
- 新增 Valkey online store 文档、OIDC JWKS client 跨请求复用(#6683)。
来源:https://github.com/feast-dev/feast/commits/master

## LLM 评估 & 安全

- **garak v0.16.0**:核心是 **Context Aware Scanning(CAS)** 首版——引入 trait/intent 注解与 `IntentProbe`,支持用户带入自己的上下文与目标期望来识别攻击向量。红队测试从"固定 probe"往"上下文感知"演进,做安全合规能力可跟进。https://github.com/NVIDIA/garak/releases/tag/v0.16.0
- **llama-stack(OGX)**:新增**检索后 chunk 过滤的分类器重排器**(#5890,RAG 安全/质量)、file_processors 的持久化跨进程作业调度(#6160);另修 `AsyncOgxClient` 与 CVE-2026-69244 的 aiohttp 升级。注意 SDK 已改名 `ogx_client`。https://github.com/meta-llama/llama-stack/commits/main
- **lm-evaluation-harness**:本周**无重大更新**(0 提交)。

## 值得跟进

- [ ] **对标 KServe `LLMInferenceService`**:路由门控、直连 KEDA、DRA/LoRA 校验已成型,梳理与我们 LLM 服务面 CRD 的差异点。
- [ ] **评估 Kubeflow Trainer v2.3 升级路径**:两处 BREAKING + 强制经 v2.3 中转,若产品内置 Trainer 需提前规划迁移。
- [ ] **跟踪"注册中心"边界外扩**:MLflow MCP Registry + Kubeflow model-registry 的 MCP/Skill catalog,判断我们的模型仓是否要纳入 MCP/Agent/Skill。
- [ ] **Ray Serve token 认证绕过(#65189)**:核对我们若基于 Ray Serve 暴露端点是否受影响。
- [ ] **garak CAS 上下文感知扫描**:作为企业级"模型安全评估"能力的候选,评估集成成本。
- [ ] 观察 **TGI 停更 / KubeAI 停更**趋势,判断这两条依赖是否需要降权。
