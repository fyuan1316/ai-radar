# AI 推理 & MLOps 生态周报 2026-07-24

> 窗口:2026-07-17 ~ 2026-07-24。仓库改名已核对(lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、llama-stack→ogx-ai/ogx、LLaMA-Factory 大小写)。

## 摘要(5 条以内)

1. **KServe 上游把重心全压在 `llmisvc`(LLMInferenceService v1alpha2)上**:本周集成集群级 TLS 安全 profile、迁移 metrics-data-source 插件、修 InferencePool reconcile 与 KV-transfer(P/D 分离)配置——这是对标 OAI 的模型服务核心,值得逐条盯。
2. **Kubeflow Trainer v2.3.0 连发 4 个 RC**:新增 `OptimizationJob` CRD(KEP-3562,把超参/优化搜索纳入 Trainer),并**破坏性移除 Runtime Finalizers**、MPI launcher 依赖 worker 就绪——训练栈下一代形态在定型。
3. **推理引擎集体转向 DeepSeek V4**:vLLM(DSv4 CT 量化 + TTFT 优化)、SGLang(DSV4 megamoe/CP decode)、TensorRT-LLM(DeepSeek-V4-Pro 配置)同周落地;SGLang 还新增 **Intel XPU 后端**并初始化 Rust server 工程。
4. **KubeAI v0.23.3** 补齐 OpenAI `/v1/responses`、支持把模型作为 **OCI 镜像**加载、外部 LB——轻量 K8s LLM 部署往企业形态靠。
5. **合规/安全信号密集**:Feast v0.65.0 上 FIPS 合规 gRPC 密码套件;ogx(原 llama-stack)对 web_search/file_search 不可信输出做定界防注入并 run-as-non-root;MLflow 全面接 MCP registry。

---

## 推理引擎动态

### vLLM
无 release,主干持续高频。对我们有意义的:
- **DeepSeek V4 适配成主线**:CompressedTensors DSv4 量化支持(#41276);"跳过 topk/router,Decode 端 E2E TTFT 提升 3.4%"(#49486);sparse-MLA target + SWA draft 的 KV cache 支持(#48776)。
- **硬件前移**:PyTorch 升到 2.13.0 / triton 3.7.1(#48155);新增 Rubin `sm_107`(#49387,热度最高 PR);GLM-5.2 Blackwell decode 优化(#48597);ROCm Quark W4A8(INT4-FP8)MoE。
- 稳定性热修:投机解码抢占后的 IMA(#49620)、xgrammar 结构化输出 stop token 屏蔽(#49227)、KV offload 按 model revision 命名空间隔离(#49266)。
- 来源:https://github.com/vllm-project/vllm/commits/main

### SGLang
无 release,但两件结构性动作:
- **新增 Intel GPU / XPU 平台后端**(#31949、#32044、#23534 LMCache radix cache),推理引擎多硬件后端竞争加剧。
- **初始化 Rust server 工程**(#32256、#32014 rust workspace)——SGLang 在往 Rust 控制面迁移。
- deterministic inference for eagle parity(#30026)、DSV4 megamoe CP(#29569)、`return_token_ids` API(#30917)。
- 来源:https://github.com/sgl-project/sglang/commits/main

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc22**(07-22):新增 DeepSeek-V4-Pro 配置、Qwen3-VL 图文混合模态;**两处破坏性变更**——自动 per-model transceiver 运行时选择、移除 legacy TensorRT C++ 后端;新增**分离式 coordinator + 多进程 orchestrator fleet**(#15905,disagg 推理编排)。已知问题多(torch.compile 多 GPU 精度崩、H200 FP8 OOM)。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc22
- **Ollama v0.32.3**(07-23,0.32.2 已撤回):CUDA on Windows ARM64、**B200(CUDA 12)支持**、Linux CUDA/ROCm iGPU 降内存;修 GLM 工具调用被静默丢弃。https://github.com/ollama/ollama/releases/tag/v0.32.3
- **TGI**:窗口内无实质提交,无重大更新。

## 模型服务 & 编排

### KServe 上游
本周提交几乎全部围绕 `llmisvc`(LLMInferenceService),企业级方向明确:
- **安全**:`feat: integrate with cluster TLS security profile`(#5791)——服务网格/网关 TLS 走集群统一安全 profile。
- **架构迁移**:samples/envtest 从 v1alpha1 → **v1alpha2**(#5804);修 v1alpha2 InferencePool 在 CRD 缺失时跳过 reconcile(#5890);迁移弃用 flag 到 metrics-data-source 插件(#5877)。
- **P/D 分离**:修生成 `--kv-transfer-config` 时的引号转义(#5880);从 prefix-cache 路由样例移除 NixlConnector(#5883)。
- 大量 e2e canary/稳定性加固(#5884、#5876、#5863 等)。
- 来源:https://github.com/kserve/kserve/commits/master
- **启示**:KServe 已把 LLM 专用 CRD(llmisvc)与集群安全 profile、InferencePool、KV-transfer 绑成一套,直接对标我们要做的企业级 LLM 服务面,建议单开专项跟 v1alpha2 API 定型。

### Ray
- **Ray 2.56.1**(07-17,补丁版):**Ray Serve LLM** 修 direct-streaming 路由——`PrefixCacheAffinityRouter` 等 body-aware 路由在 `RAY_SERVE_LLM_ENABLE_DIRECT_STREAMING=1` 下不再挂起(#64488);protobuf 7 兼容(#64592);Ray Core 新增 system-slice 内存压力早检测(#64492),提示调大 `--system-reserved-memory` 以避免节点被 OOM 打死。https://github.com/ray-project/ray/releases/tag/ray-2.56.1

### KubeAI(原 substratusai/lingo)
- **v0.23.3**(07-20):新增 OpenAI **`/v1/responses`** 兼容(#667)、支持把模型作为 **OCI 镜像加载**(#661)、外部 LoadBalancer 支持(#655)、Helm 暴露 `proxy.mode`(#670)、排除 terminating pod 出 rollout 计划(#659)。https://github.com/kubeai-project/kubeai/releases/tag/v0.23.3

## 训练 & 微调

### Kubeflow Trainer(原 training-operator)
- **v2.3.0-rc.0 ~ rc.3**(07-23/24 连发):
  - **feat: KEP-3562 引入 `OptimizationJob` CRD**(#3565)——把超参/优化搜索作业纳入 Trainer v2,是本周训练侧最大结构变化。
  - **BREAKING:移除 Runtime Finalizers**(#3716);MPI launcher 改为依赖 worker 就绪(#3748);PodSets.Count 传播进 TemplateSpec 的 Parallelism/Completions(#3651);初始化器校验 cache storage URI(#3741)。
  - https://github.com/kubeflow/trainer/releases/tag/v2.3.0-rc.3
- **启示**:Trainer v2 正把训练 + 优化搜索统一到一套 CRD,且 API 仍在破坏性演进,若我们内嵌 Kubeflow 训练能力需锁定到 v2.3.0 GA 再跟。

### LLaMA-Factory
- v1 重构线:新增 **muon optimizer**(#10618)、修 grad norm / lr 日志(#10640)。体量小,无 release。https://github.com/hiyouga/LLaMA-Factory/commits/main

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
无 release,但方向清晰——**全面接入 MCP**:接受 MCP registry server 信封(#24572)、create 时自动发现 MCP 工具(#24520)、MCP registry 操作埋点(#24477);另有 presigned artifact 直下载(#24435/#24341)、GenAI evaluate 保留显式 expectation(#24561)、Assistant 会话 token 用量展示。https://github.com/mlflow/mlflow/commits/master

### Kubeflow Hub(原 model-registry,已升级为 AI Hub)
- **v0.3.14**(07-17,仍 Alpha):核心是 **MCP catalog 源管理**——ConfigMap 后端的 MCP catalog source CRUD(#2930)、MCP catalog 设置页增删表单(#2935);vendor-neutral userInteraction 埋点抽象(#2937)。Model Registry 正演进为含 MCP/Agent catalog 的 AI Hub。https://github.com/kubeflow/hub/releases/tag/v0.3.14

### Feast
- **v0.65.0**(07-20):以 bug fix 为主,**合规信号突出**——FIPS 模式检测回退日志、离线 server 配置 **FIPS 合规 gRPC 密码套件**;修 DynamoDB 不兼容标签、SQL registry proto 列改 LONGBLOB。https://github.com/feast-dev/feast/releases/tag/v0.65.0

## LLM 评估 & 安全

- **ogx(原 meta-llama/llama-stack)**:安全与 provider 扩展并进——**对不可信 web_search/file_search 工具输出做定界后再回喂模型**(#6337,防提示注入)、responses 补 file_citation 注解(#6292);新增 **DeepSeek(#6240)/Mistral(#6239)远程推理 provider**;starter 改 **run-as-non-root**(#6319);修 CVE-2026-59885(pyasn1)。https://github.com/ogx-ai/ogx/commits/main
- **NVIDIA/garak**:仅 continuation probe 的 trigger 裁剪修复(#1976),无重大更新。
- **EleutherAI/lm-evaluation-harness**:窗口内无提交,无重大更新。

## 值得跟进

- [ ] **KServe llmisvc v1alpha2 API 定型**:cluster TLS security profile + InferencePool + KV-transfer 一整套企业级 LLM 服务面,直接对标我们产品,建议开专项。https://github.com/kserve/kserve/pulls?q=is%3Apr+llmisvc
- [ ] **Kubeflow Trainer OptimizationJob(KEP-3562)**:训练 + 优化搜索统一 CRD,若内嵌 Kubeflow 需评估 v2.3.0 破坏性变更。https://github.com/kubeflow/trainer/pull/3565
- [ ] **MCP 正在渗透 MLOps 控制面**:MLflow registry、Kubeflow Hub catalog 同周把 MCP 作为一等公民,需判断我们模型/工具目录是否要接 MCP。
- [ ] **推理引擎多硬件后端**:SGLang 上 Intel XPU、Ollama 上 B200/Win ARM64——评估我们调度层对异构 GPU/加速器的抽象是否跟得上。
- [ ] **合规能力**:Feast FIPS、ogx run-as-non-root,是企业客户硬需求,可作为我们平台合规叙事的对标点。
