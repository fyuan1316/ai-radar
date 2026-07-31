# AI 推理 & MLOps 生态周报 2026-07-31

> 覆盖窗口:2026-07-24 ~ 07-31(过去 7 天)。已过滤版本 bump / dependabot / CI 修复噪音,只保留对"做云原生 AI 基础设施产品"有借鉴或威胁的动向。

## 摘要(5 条以内)

1. **vLLM v0.26.0 发版**:KV 缓存分层 offload 成体系——二级层落对象存储且带 workload identity、DP 副本感知分层;Rust 前端补齐多模态音视频。控制面正在向 Rust + 分层存储演进。[release](https://github.com/vllm-project/vllm/releases/tag/v0.26.0)
2. **KServe 深化 llm-d 整合**:`llmisvc` 迁移 model-server-metrics 系列 flag、从模板参数探测 scheduler 插件;同时给 RawDeployment 加金丝雀流量拆分、收紧 controller-manager 的 ClusterRole。这是最贴近我们平台层的一组变化。[#5930](https://github.com/kserve/kserve/pull/5930) [#5912](https://github.com/kserve/kserve/pull/5912)
3. **模型注册中心在向"Agent/MCP/Skill 注册中心"扩张**:MLflow 3.15 引入 MCP Registry UI 全套、AI Gateway 按 endpoint 预算策略;Kubeflow Hub(原 model-registry,已并入 monorepo)提出 Skills Catalog 并给 Model Registry / Model Catalog 出 v1 OpenAPI。模型生命周期正在被"智能体资产生命周期"重定义。
4. **SGLang v0.5.16**:DSpark 置信度驱动投机解码、Inkling 首日支持、UnifiedRadixTree 转默认;仓库里在成体系地自研 Rust server(与 vLLM Rust 前端呼应)。[release](https://github.com/sgl-project/sglang/releases/tag/v0.5.16)
5. **企业级安全在多仓同步推进**:KServe RBAC 收紧、Feast 加 OIDC audience/issuer 校验与 FIPS 加密套件、garak 强化 markdown 数据外泄检测。合规/多租户这条线值得盯。

---

## 推理引擎动态

### vLLM
- **v0.26.0(07-27,411 commits/212 contributors)** 对平台侧最有价值的是 **KV offloading 与分层二级存储成熟**:offload 指标、tier-owned 事件、**对象存储二级层 + workload identity**([#47063](https://github.com/vllm-project/vllm/pull/47063)、[#47274](https://github.com/vllm-project/vllm/pull/47274)、[#48150](https://github.com/vllm-project/vllm/pull/48150))、DP 副本感知分层([#47987](https://github.com/vllm-project/vllm/pull/47987))、异构 KV 组的 `blocks_per_chunk` 配置。[release](https://github.com/vllm-project/vllm/releases/tag/v0.26.0)
- **灵活注意力后端**:可**按 KV-cache group 选择不同 attention backend**([#48012](https://github.com/vllm-project/vllm/pull/48012))、滑窗作为后端显式能力([#48011](https://github.com/vllm-project/vllm/pull/48011))——对混合架构模型(SWA+full+Mamba)是关键基础设施。
- **Rust 前端**继续补齐:多模态视频/音频、原生 `vllm-bench` 移植。控制面性能路线已定。
- **安全**:新增文档明确 **Ray 集群信任模型与环境变量传播**([#50397](https://github.com/vllm-project/vllm/pull/50397))——多租户部署 vLLM+Ray 时的信任边界,值得读。
- 模型侧:新增 Inkling(975B 多模态 MoE)、Kimi K3([#50000](https://github.com/vllm-project/vllm/pull/50000)),DeepSeek-V4 全栈性能优化。

### SGLang
- **v0.5.16(07-25,574 PRs)**:亮点是 **DSpark 置信度驱动投机解码**(按草稿自身置信度动态定 verify 窗口,DeepSeek-V4-Pro B300 上 383.7 tok/s)、Inkling 首日支持、**UnifiedRadixTree 转为 SWA/Mamba/DSA 默认前缀缓存**。[release](https://github.com/sgl-project/sglang/releases/tag/v0.5.16)
- **显存工程**很硬核:GLM-5.2 DSA 缓存层在 prefill CP 下按层分片,单 rank KV 省 ~74%;ReplaySSM Ring 投机验证把 GDN 投机 scratch 从 11.5GB→1.8GB(6.4x)。对"同卡跑更大模型/更高并发"是直接杠杆。
- **自研 Rust server**:本周多条 commit 在把 rust server 的 ingress/codec/tokenizer/runtime 逐块接入([#32877](https://github.com/sgl-project/sglang/pull/32877)、[#32358](https://github.com/sgl-project/sglang/pull/32358) 等)。与 vLLM Rust 前端同向,提示"推理网关/前端去 Python 化"是行业趋势。
- **破坏性变更**多(QServe/FBGEMM FP8 移除、`--fp4-gemm-backend cutlass` 删除、多个 flag 无别名重命名),我们若封装 SGLang 需锁版本并跟 upgrade notes。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:主要是内部演进——KVCacheManagerV2 的 C++ 迁移([#14047](https://github.com/NVIDIA/TensorRT-LLM/pull/14047))、TorchSampler 补齐 min_p / 重复惩罚采样、Qwen3.x/Gemma4 VLM 多模态 encoder cache。平台层无直接可用面。
- **TGI**:**本周无实质更新**(近 7 天 0 commit),HuggingFace 推理栈重心已明显转向 TRT-LLM/vLLM 后端。
- **Ollama**:重心在 MLX 后端与**内置 agent/TUI**(agent 权限 skill 加载 [#17304](https://github.com/ollama/ollama/pull/17304)、system prompt 命令、文件 mention),并移除 MLX 图像生成代码。边缘/桌面侧在往"本地 agent runtime"走,发版 v0.32.4/v0.32.5。

---

## 模型服务 & 编排

### KServe 上游
本周是**平台层信息量最大的仓库**,主线全在 `llmisvc`(LLM InferenceService)与 llm-d 整合:
- 迁移剩余 `--model-server-metrics-*` flag 给 llm-d([#5930](https://github.com/kserve/kserve/pull/5930)),从模板参数探测 scheduler 插件([#5931](https://github.com/kserve/kserve/pull/5931)),为 disagg-sidecar 换新 TLS flag([#5875](https://github.com/kserve/kserve/pull/5875))。
- **RawDeployment 的 HTTPRoute 加金丝雀流量拆分**([#5912](https://github.com/kserve/kserve/pull/5912))——不依赖 Knative/Istio 也能灰度,和我们自研 gateway 路线可对比。
- **收紧 controller-manager 的 ClusterRole**([#5785](https://github.com/kserve/kserve/pull/5785))、把存储资源模板化进 inferenceservice-config ConfigMap([#5697](https://github.com/kserve/kserve/pull/5697))。
- 新增**agentic 工具调用指南与样例**([#5906](https://github.com/kserve/kserve/pull/5906))——KServe 也在往 agent serving 场景延伸。
- 启示:llm-d 已是 KServe LLM 路线的事实底座,评估我们的 LLM 服务分层时应把 llm-d 的 scheduler/metrics/disagg 这套接口纳入对标。

### Ray
- **LLM KV 路由系列(#8–#10)**:把 tokenization 移进 `LLMRouter` ingress 副本、在副本内做 KV/token 路由决策、向所有 ingress 副本广播 KV 生命周期事件([#64949](https://github.com/ray-project/ray/pull/64949))——Ray Serve 在把 KV-aware 路由做进入口层,和 vLLM/llm-d 的 KV 路由是同一战场。
- **调度/弹性**:公开 **preemption API 与 controller PreemptingState**([#64360](https://github.com/ray-project/ray/pull/64360))、TPU subslice gang 调度 `SubslicePlacementGroup`([#64578](https://github.com/ray-project/ray/pull/64578))、Serve 依赖序关闭([#64922](https://github.com/ray-project/ray/pull/64922))。
- **基础设施**:发布 **arm64 的 ray LLM 镜像**([#65002](https://github.com/ray-project/ray/pull/65002))、LLM 镜像升到 vLLM 0.26.0([#65045](https://github.com/ray-project/ray/pull/65045))、GCS 内嵌 RocksDB 后端文档化([#64731](https://github.com/ray-project/ray/pull/64731))、RDT 跨设备传输走 NIXL([#64815](https://github.com/ray-project/ray/pull/64815))。
- 启示:Ray 与 vLLM 版本咬合很紧(同周就升 0.26.0),我们若用 Ray Serve 托管 vLLM,需把这条版本联动纳入升级流水线。

### KubeAI(原 substratusai/lingo)
- 发 **v0.23.4**(07-30),但本周提交基本都是 release/helm chart 工作流修复,**无产品级新能力**。[release](https://github.com/kubeai-project/kubeai/releases/tag/helm-chart-kubeai-0.23.4)

---

## 训练 & 微调

- **Kubeflow Trainer(原 training-operator,Trainer v2)**:本周仅 3 条实质提交——status server bearer token 解析改进([#3782](https://github.com/kubeflow/trainer/pull/3782))、E2E 的 Kubeflow SDK 安装修复、去重 TrainJob status patch。**基本无重大更新**。
- **LLaMA-Factory(仓库大小写改名 hiyouga/LlamaFactory)**:新增 **megatron-bridge 支持 PT/SFT 训练**([#10645](https://github.com/hiyouga/LlamaFactory/pull/10645))、修复 hyper parallel 尾部累积的 loss scaling([#10705](https://github.com/hiyouga/LlamaFactory/pull/10705))、改进 NPU 镜像构建([#10664](https://github.com/hiyouga/LlamaFactory/pull/10664))。国内 + NPU 场景仍活跃。

---

## 模型生命周期(MLflow / Registry / Feast)

### MLflow(3.15.0 在途)
- **MCP Registry UI 全套落地**:从基础脚手架、列表卡片/表格视图、详情页版本/别名/标签管理、RBAC 门禁与 compare 视图,到 tool 自动发现弹窗([#24509](https://github.com/mlflow/mlflow/pull/24509)、[#24657](https://github.com/mlflow/mlflow/pull/24657)、[#24644](https://github.com/mlflow/mlflow/pull/24644))。**MLflow 正把"模型注册中心"扩成"MCP/工具注册中心"**——对我们模型生命周期模块是明确的方向信号。
- **AI Gateway 按 endpoint 预算策略**([#24370](https://github.com/mlflow/mlflow/pull/24370))、原生 FastAPI 制品上传/下载(流式)([#24340](https://github.com/mlflow/mlflow/pull/24340))、Pydantic AI 2.x autologging、GenAI Traces 保存视图。
- 安全:给 `mlflow.statsmodels` 加 `MLFLOW_ALLOW_PICKLE_DESERIALIZATION` 反序列化开关([#24686](https://github.com/mlflow/mlflow/pull/24686))、修 K8s `kubernetes-client` 36+ 的 token 提取。

### Kubeflow Hub(原 kubeflow/model-registry,已并入 monorepo)
- **提出 Skills Catalog**([#2973](https://github.com/kubeflow/hub/pull/2973))并配 OpenAPI + codegen([#3015](https://github.com/kubeflow/hub/pull/3015)、skill source config [#3035](https://github.com/kubeflow/hub/pull/3035));给 **Model Registry / Model Catalog 出 v1 OpenAPI 规范**([#3013](https://github.com/kubeflow/hub/pull/3013)、[#3038](https://github.com/kubeflow/hub/pull/3038));MCP/agent catalog 支持 YAML 热加载([#2997](https://github.com/kubeflow/hub/pull/2997))。
- 启示:上游 Model Registry 已升级为含 Model / MCP / Agent / Skill 四类目录的 AI Hub。我们对标模型注册中心时,catalog 抽象要预留 agent/tool/skill 资产类型。

### Feast
- **企业级安全**:operator 透传 OIDC audience/issuer([#6677](https://github.com/feast-dev/feast/pull/6677))、在线校验 OIDC token audience/issuer([#6670](https://github.com/feast-dev/feast/pull/6670))、API fallback 上应用中间 TLS 默认值([#6587](https://github.com/feast-dev/feast/pull/6587))、FIPS 加密套件在 pyarrow.flight import 前设置以防 IBM Power 崩溃。
- **operator 能力**:`spec.services.initImage` 覆盖 init 容器镜像([#6598](https://github.com/feast-dev/feast/pull/6598))、`onlineStore.disabled` 退出在线存储、多架构镜像发布;DynamoDBOnlineStore 加 `plan()` 支持。合规 + operator 化两条线都在补强。

---

## LLM 评估 & 安全

- **garak(NVIDIA LLM 红队)**:强化 **web_injection 的 markdown 数据外泄检测**(抗 domain/扩展名/参数规避)([#1928](https://github.com/NVIDIA/garak/pull/1928))、新增 technique/intent 标注与初版 IntentProbe([#1984](https://github.com/NVIDIA/garak/pull/1984))、StringDetector 加 Unicode 归一化([#1884](https://github.com/NVIDIA/garak/pull/1884))、修 NeMo Guardrails Server 的 extra_params。若我们要做内置安全评测,garak 的探针/检测器抽象值得直接引。
- **lm-evaluation-harness**:**本周无实质更新**(近 7 天 0 commit)。
- **OGX(原 meta-llama/llama-stack,已改名)**:发 v1.2.2 / v0.7.3 / v0.4.7(07-27);**Bedrock 经 ListFoundationModels + mantle API 自动发现模型**([#6315](https://github.com/ogx-ai/ogx/pull/6315))、暴露 httpx 连接池上限([#6306](https://github.com/ogx-ai/ogx/pull/6306))、移除 `remote::passthrough` 推理 provider([#6368](https://github.com/ogx-ai/ogx/pull/6368))、CLI `letsgo`→`go` 改名。[release v1.2.2](https://github.com/ogx-ai/ogx/releases/tag/v1.2.2)

---

## 值得跟进

- [ ] **读 vLLM KV 二级存储 + workload identity 那组 PR**([#47063](https://github.com/vllm-project/vllm/pull/47063)/[#47274](https://github.com/vllm-project/vllm/pull/47274)/[#48150](https://github.com/vllm-project/vllm/pull/48150)):评估我们平台把 KV cache 落对象存储的可行性与身份边界设计。
- [ ] **对标 KServe llm-d 整合面**:把 [#5930](https://github.com/kserve/kserve/pull/5930)(metrics flag)、[#5931](https://github.com/kserve/kserve/pull/5931)(scheduler 插件探测)、[#5912](https://github.com/kserve/kserve/pull/5912)(RawDeployment 金丝雀)读完,梳理我们 LLM 服务与 llm-d 接口差异。
- [ ] **跟踪"注册中心→agent/MCP/skill 目录"演进**:并读 MLflow MCP Registry([#24509](https://github.com/mlflow/mlflow/pull/24509))与 Kubeflow Skills Catalog 提案([#2973](https://github.com/kubeflow/hub/pull/2973)),给我们模型生命周期模块的 catalog 抽象定型。
- [ ] **验证 Ray Serve KV-aware 路由([#64949](https://github.com/ray-project/ray/pull/64949))**与 vLLM/llm-d KV 路由的重叠与取舍,避免我们平台两套 KV 路由打架。
- [ ] **评估把 garak 作为内置安全评测引擎**:先跑 web_injection / IntentProbe 探针([#1928](https://github.com/NVIDIA/garak/pull/1928)、[#1984](https://github.com/NVIDIA/garak/pull/1984)),看输出能否接入我们的合规报告。

---

<details>
<summary>原始扫描范围(16 仓,过去 7 天)</summary>

- 有实质更新:vllm-project/vllm(v0.26.0)、sgl-project/sglang(v0.5.16)、kserve/kserve、ray-project/ray、mlflow/mlflow、feast-dev/feast、NVIDIA/garak、kubeflow/hub(原 model-registry)、ogx-ai/ogx(原 llama-stack,v1.2.2)、ollama/ollama(v0.32.4/5)、hiyouga/LlamaFactory、NVIDIA/TensorRT-LLM、kubeai-project/kubeai(v0.23.4,仅发布工程)
- 本周无重大更新:huggingface/text-generation-inference(0 commit)、EleutherAI/lm-evaluation-harness(0 commit)、kubeflow/trainer(仅 3 条内部提交)
- 改名/迁移已按 -L 跟随:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、llama-stack→ogx-ai/ogx、LLaMA-Factory→hiyouga/LlamaFactory

</details>
