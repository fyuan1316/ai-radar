# AI 推理 & MLOps 生态周报 2026-09-02

覆盖窗口:2026-08-26 ~ 09-02。仓库改名沿用备忘:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、llama-stack 源码在 ogx-ai/ogx 但仍发 release 于 meta-llama/llama-stack;TGI 已 archived(永远 0 提交,正常)。vLLM v0.28.0 / SGLang v0.5.18 / Ray 2.58.0 / feast v0.66.0 均已在上周(08-28)digest 覆盖,本周只看其后的主线提交。

## 摘要(5 条以内)

1. **KV cache 分层/传输成全行业默认**:TensorRT-LLM 把 **KV Cache Manager V2 设为几乎所有主力模型的默认**(DeepSeek/GLM/GPT-OSS/Qwen3.x/Kimi 等),vLLM 补 Mooncake Store 的**异构 TP 共享**,SGLang 上 **CPU FP8 KV cache** + 统一缓存的 Mooncake 外部后端 + 按行释放 KV。三家同时把"KV 存算分离+跨节点传输"做成标配,是我们推理层缓存/调度设计的硬参照。
2. **但 disaggregated serving 仍不稳**:TensorRT-LLM rc25 的 Known Issues 列了几十条 disagg/PD 启动挂死、KV 传输 abort 后 hang、B200 OOM——连 NVIDIA 自家在 P/D 分离上都还在填坑;KServe 本周恰好修了 `llmisvc` 的 **P/D 引擎缺 NixlConnector 导致 KV 根本没传** 的 bug。信号:PD 分离要上生产,KV 连接器的正确性和容错是主要风险点。
3. **KServe 持续把 LLM 服务化"做重、做安全"**:kernelcache 新增**安全验证框架**、**TLS 证书轮转热加载**、EPP 调度器改为 preset+最新插件、KEDA triggerAuth 放宽、多 LoRA 挂载路径消歧。上游把企业级安全/多适配器/自动扩缩往 CRD 里收,是对标 OAI 推理栈的第一参照。
4. **评测可信度被上游"打补丁"**:lm-eval-harness v0.4.13 修了**少样本泄漏**(被测题混进 few-shot 示例)、**多选正则前缀误匹配**、**分组 stderr 误差条窄到 1/3**——这些会**改变此前发布过的分数**;并新增抗污染的 Uncheatable Eval + ONNX 后端。做模型评估/榜单能力要注意版本对齐,否则历史数字不可比。
5. **模型接入/生命周期往"多租户 + 目录 + MCP"走**:llama-stack v1.3.0 加 **Meta AI 远端推理 provider**、Neo4j 向量库、多租户能力(博客)、**未配置鉴权时启动告警**、starter 以非 root 跑;model-registry v0.3.16 继续 **MCP catalog 的 ConfigMap-backed CRUD**。模型平台正从"托管推理"扩到"模型/工具接入分发 + Agent 目录"。

## 推理引擎动态

### vLLM
本周无新 release(v0.28.0 已在上周覆盖),主线提交仍以 Qwen3.8/Qwen4、Kimi-K3、DeepSeek-V4 的 kernel 为主。对做基础设施有用的横切项:
- **KV 连接器 / 分布式**:Mooncake Store Connector 支持**异构 TP 共享**(#53129,KV 可在 TP 不一致的实例间复用)、预共享 `ncclUniqueId` 的权重传输握手(#53784)、opt-in FlashInfer PCIe IPC all-reduce 后端(#53576)、sleep 模式下释放 NCCL communicator 显存(#51485)。https://github.com/vllm-project/vllm/pull/53129
- **可观测性**:新增**请求级 preemption 次数直方图指标**(#49984),便于观测调度抢占压力。https://github.com/vllm-project/vllm/pull/49984
- **量化框架收敛**:LinearMethod 类按 QuantKey 泛型化重构(#49381)、QuarkConfig 采用 QuantKey 派发(#52958)——量化后端的可插拔性在收口。
- Rust 前端继续成熟(迁到 tekken crate #53056、词表只统计一次 #54449、多模态 #54813),前端/调度解耦利于外部编排层接管。

### SGLang
本周无新 release(v0.5.18 已覆盖),主线亮点:
- **CPU FP8 KV cache**(#32733):KV cache 下沉到 CPU 且支持 FP8,长上下文/高并发的内存成本再降一档。https://github.com/sgl-project/sglang/pull/32733
- **统一缓存(Unified Cache)接外部存储**:新增 **Mooncake 后端**(#37205)、`free_kv_row` 按行范围释放 KV(#36721)、HiCache offload 状态记账简化(#37299)。KV 分级/外部化与 vLLM 同频。https://github.com/sgl-project/sglang/pull/37205
- **NPU(昇腾)支持扩张**:sgl-kernel-npu 升到 2026.9.0 并把 memfabric 依赖并入 pyproject(#37399)、NPU MLA HiCache 修复(#36813)、新增 DSV4-Flash/GLM-5.2/Kimi-K3 的 NPU 精度用例(#37431)。跨厂商推理正被认真对待。
- 工程化:Rust 的 mem-cache 更名为 `sglang-radix-tree`(#37290),radix 前缀缓存作为独立组件外露。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc25**(08-31):**KV Cache Manager V2 成为几乎所有主力模型的默认**(DeepSeek V3/R1/V3.2/V4、GLM-5、GPT-OSS、Mistral Large 3、Kimi K2/K2.5/K3、Nemotron H、Qwen3-Next/3.5/3.8、Gemma 3/4),官方称 V2 可扩展性/稳定性更好、V1 将弃用。但 **Known Issues 列了几十条 disaggregated serving 挂死 / KV 传输 abort 后 hang / B200 OOM / 各类 NaN**——生产落地前务必按机型和模型逐一验证。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc25
- **Ollama v0.33.2**(08-27)/ v0.33.3-rc0(09-02):主要修 **Claude Desktop proxy 在模型目录更新时不再打断在途请求**、macOS 单实例接管、深色模式。延续"桌面 Agent 客户端把本地推理当标准后端"的信号。https://github.com/ollama/ollama/releases/tag/v0.33.2
- **TGI**:已 archived,无更新(正常)。

## 模型服务 & 编排

### KServe 上游
本周主线继续压在 LLM 服务化与企业级安全上:https://github.com/kserve/kserve/commits/main
- **安全/证书**:kernelcache 新增**安全验证框架**(#6099)、**轮转后的 TLS 证书热加载**(#6106)、transformer 支持 SSL 配置(#6045)、autogluon 加载工件安全加固(#5803)。https://github.com/kserve/kserve/pull/6106
- **P/D 分离正确性**:修 `llmisvc` 的 **P/D 引擎缺 NixlConnector 导致 KV 实际未传输**(#6027)——与 TensorRT-LLM 的 disagg 稳定性问题呼应。https://github.com/kserve/kserve/pull/6027
- **调度 & 扩缩**:EPP 调度器默认配置改为 **preset + 最新插件**(#5921)、允许 KEDA `triggerAuthName` 不带 authModes(#6004)、canary 提升时清理孤儿 autoscaler/OTel 资源(#5899)、canary 权重限制在 predictor 规则(#5944)。
- **多 LoRA**:挂载路径消歧(#6085)、校验 config 声明的 LoRA(#6092)。

### Ray
无新 release(2.58.0 已覆盖),主线里对平台方有用的:https://github.com/ray-project/ray/commits/master
- **供应链/安全**:两处**反序列化 RCE 防护**——读 Delta Sharing(#65769)与 Hudi(#65780)时加 unpickling guard;为 POSIX 多进程改用 forkserver(#65159)。https://github.com/ray-project/ray/pull/65769
- **KubeRay/自动扩缩**:autoscaler 支持**可配置的 K8s API 认证**(#65827)、修 maxReplicas 上限导致的幽灵 worker 节点(#65705);KubeRay 版本引用统一到 1.7.0(#65498)。https://github.com/ray-project/ray/pull/65827
- **Serve**:入口 router 不再滞留 proxy 节点(#65824)、jinja2 懒加载并纳入 serve extra(#65542)。
- **训练/数据**:checkpoint 恢复可通过 `CheckpointConfig` 插件化(`checkpoint_filter_cls`/`checkpoint_manager_cls`,#65676);沙箱支持 Docker Hub pull-through 镜像(#65745)、镜像层解压保留 mtime(#65737)。

### KubeAI
本周无实质提交(延续静默,属正常)。

## 训练 & 微调

- **Kubeflow Trainer**:**TrainingRuntime 加弃用告警**(#3966)、补 **MPIJob→TrainJob 迁移文档**(#3968)与 slurm-bridge 调度文档(#3951);controller **按 runtime 快照校验 TrainJob 更新**(#3960)、拒绝超大 chunked status 请求(#3973)、修 runtime 快照 GVK 未填导致 reconcile 失败(#3922)、修 Flux reconcile 在 trainer 字段未设时 panic(#3904)。v2 TrainJob 收口、老 API 开始退场。https://github.com/kubeflow/trainer/pull/3966
- **LLaMA-Factory**:v1 新增 **LoRA 配合 FSDPTurbo 专家并行**(#10791)、加 minicpm5 的 XML 工具调用模板(#10801)、修打包 mrope 后的 position ids(#10783)。https://github.com/hiyouga/LLaMA-Factory/pull/10791

## 模型生命周期(MLflow / Registry / Feast)

- **kubeflow/model-registry v0.3.16**(08-31):继续 **MCP catalog 化**——MCP catalog 设置页的**新增/管理 source 表单**(#2935)与 **ConfigMap-backed 的 source 配置 CRUD**(#2930)、厂商中立的 userInteraction 跟踪抽象(#2937)、python-client 加 s3 extra 别名(#2926)。仍属 Kubeflow alpha 组件(注意源码已在 kubeflow/hub 仓)。https://github.com/kubeflow/model-registry/releases/tag/v0.3.16
- **MLflow v3.15.2**(08-26):GenAI 评估方向——**不可变的评估数据集版本**(#24845)、组合多个 scorer 的 **`scorer_ensemble` 原语**(#24749);另修 MemAlign 对齐裁判的 base judge 调用流(#24883)。https://github.com/mlflow/mlflow/releases/tag/v3.15.2
- **Feast**:仅文档/UI 小修(#6763/#6793),无重大更新。

## LLM 评估 & 安全

- **lm-eval-harness v0.4.13**(08-31,少见的发版):以修复为主,且部分会**改变此前发布过的分数**——(1)**少样本泄漏**:采样器会把被测文档抽进它自己的示例、`gen_prefix` 对着被测题解析(影响 RULER/humaneval,#3978/#3979);(2)**MultiChoiceRegexFilter 前缀遮蔽**(`"Guilty"` 匹配进 `"Guilty of Romance"`,把对答案判错,#3884);(3)`weight_by_size:false` 时分组仍报按大小加权的 stderr,误差条最多窄到 1/3(#3882)。新增**抗污染 Uncheatable Eval**(对新近发布文档做滚动 log-likelihood)、LegalBench/LongProc 等 8 套基准,以及 **onnxruntime / onnxruntime-genai 后端**。https://github.com/EleutherAI/lm-evaluation-harness/releases/tag/v0.4.13
- **llama-stack v1.3.0/1.3.1**(08-31/09-01):productionization——**Meta AI 远端推理 provider**(#6275)、Neo4j 向量库(#6274)、**未配置鉴权时启动告警**(#6307)、starter **以非 root 运行**(#6319)、给 OpenAIMixin 加 `anthropic_count_tokens` 翻译(#6268);v1.3.1 全为向量库元数据持久化等 backport 修复。多租户能力单出博客。https://github.com/meta-llama/llama-stack/releases/tag/v1.3.0
- **garak**:本周无提交(无更新)。

## 值得跟进

- [ ] **P/D 分离的 KV 连接器容错**:TensorRT-LLM disagg Known Issues + KServe NixlConnector 修复,说明 KV 传输 abort/超时/清理是 P/D 生产化的头号风险,我们的推理层若做 PD 分离需把这块做成一等容错路径。
- [ ] **KV 分级与外部存储对接**:vLLM(Mooncake 异构 TP 共享)、SGLang(CPU FP8 KV + Mooncake 外部后端 + 按行释放)方向一致,评估是否在我们缓存层对接 Mooncake 类外部 KV store。
- [ ] **评估版本对齐**:lm-eval-harness v0.4.13 修了会改分数的 bug,若产品内嵌评测/榜单,需锁版本并回归历史数字,避免不可比。
- [ ] **KServe 企业能力对标**:TLS 证书轮转热加载、kernelcache 安全验证框架、EPP 调度 preset、多 LoRA——逐条对照我们推理栈的差距。
- [ ] **MCP catalog 化**:model-registry 把 MCP source 做成 ConfigMap-backed CRUD,评估我们的模型/工具目录是否要原生支持 MCP source 管理。
- [ ] **Kubeflow Trainer v2 迁移**:TrainingRuntime 进入弃用告警、MPIJob→TrainJob 有迁移文档,若跟随 Kubeflow 训练栈需规划迁移窗口。
