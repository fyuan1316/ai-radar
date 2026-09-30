# AI 推理 & MLOps 生态周报 2026-09-30

> 窗口:2026-09-23 ~ 2026-09-30。只筛对"做云原生 AI 基础设施产品(对标 OAI)"有借鉴/威胁的变化,版本 bump / dependabot / CI 噪音已跳过。

## 摘要(5 条以内)

1. **KServe v0.21.0 发布**,LLMInferenceService(llmisvc)本轮集中补齐生产级能力:DRA(动态资源分配)、KEDA 直接扩缩、RawDeployment 金丝雀分流、agentic tool-calling、rolloutStrategy,并深度对齐 llm-d。这是本周对我们最直接相关的信号。 https://github.com/kserve/kserve/releases/tag/v0.21.0
2. **Ray Serve LLM 在 PD 分离部署上支持 LoRA**,同时 Ray 新增 gVisor 沙箱(Ray Sandbox)、RayCluster 空闲自动终止选项、TorchTPU 多 slice 训练——分布式推理+Agent 代码执行+异构算力三线并进。
3. **Feast 把 MLflow 提升为一等公民的离线 DataSource**——特征库与实验追踪的边界在收窄,值得我们在数据/特征层布局时留意。
4. **llama-stack 快速演进为"通用推理网关"**:原生透传 /v1/messages(Anthropic/DeepSeek/Fireworks)、接入 TEI、加 rerank 模型与多家 Web 搜索 provider。
5. **模型注册中心开始纳管 MCP 资产**:kubeflow/hub(原 model-registry)的 catalog 把 MCP server 也纳入 runtimeMetadata 与 UI;同时 LLaMA-Factory 补 Ascend 950 / Intel XPU 镜像,异构算力纳管是共同主题。

## 推理引擎动态

### vLLM
无版本发布,窗口内 100+ 提交,主线仍是模型覆盖 + 异构后端 + KV/投机解码性能:
- KV 传输:[Mooncake connector 把 hybrid/MLA KV 打包成合并传输区](https://github.com/vllm-project/vllm/pull/57952)、[MoRIIO 支持 K3 DSpark hybrid READ](https://github.com/vllm-project/vllm/pull/57700)——disaggregated PD 的 KV 通道持续优化。
- 异构:[Fast Start 支持 PP](https://github.com/vllm-project/vllm/pull/55477)、CPU WNA16 W4A16 量化 Whisper、多个 ROCm/XPU 内核。
- 投机解码:[FlashInfer trtllm-gen 融合多步 draft decode](https://github.com/vllm-project/vllm/pull/58371)。
- 启示:PD 分离 + KV connector 已是上游既成事实,我们的推理平面若还停在单体 ISVC,需尽快对齐 KServe llmisvc + vLLM connector 的组合形态。

### SGLang
无版本发布,窗口内 100+ 提交,重点在 PD 路由与 KV 缓存服务化:
- Router:[以 --kv-peer-selector 命名副本的兄弟节点](https://github.com/sgl-project/sglang/pull/40689)、[在 /internal/kv_snapshot 暴露 cache-aware 树](https://github.com/sgl-project/sglang/pull/40688)——KV 感知路由正在标准化成可被外部编排消费的接口。
- 指标:[新增请求级 TPOT 直方图 sglang:request_time_per_output_token_seconds](https://github.com/sgl-project/sglang/pull/40275)、[修 PD 延迟直方图统计](https://github.com/sgl-project/sglang/pull/39706)。
- 异构:GB300 TP16、NPU 910C L2 memcache offload、XPU chunked prefill、W4A16。
- 启示:SGLang 把 KV 快照做成 HTTP 端点,和 KServe 的 prefix-cache-aware 路由方向一致;我们做多副本调度时可直接复用这类"KV 感知"信号,而非自研亲和策略。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:窗口内仅 rc(v1.3.0rc28→rc29),无稳定版。看点:[KV connector 前缀纳入 V2 scheduler 预算](https://github.com/NVIDIA/TensorRT-LLM/pull/17974)、[Ray orchestrator 下的 mnnvl allreduce](https://github.com/NVIDIA/TensorRT-LLM/pull/18231)、[agent flow 按角色分后端路由](https://github.com/NVIDIA/TensorRT-LLM/pull/19522)、新增 GLM-5.3-Flash;Rubin(SM107)硬件支持在铺。
- **Ollama**:发布密集。[v0.35.0 引入 decision models / System One 打分 API(/v1/systemone)](https://github.com/ollama/ollama/releases/tag/v0.35.0),返回选择/概率/分数用于工单分流、模型路由、内容分类;[v0.40.0-rc0 让 Apple Silicon 默认走 MLX 运行时](https://github.com/ollama/ollama/releases/tag/v0.40.0-rc0);另加[单次响应最多 10 次 Web 搜索](https://github.com/ollama/ollama/pull/18602)。
- **TGI**:已 archived(最后 push 2026-03-21),窗口内 0 提交,属正常停维护,不再跟踪。
- 启示:Ollama 的 "decision model / 打分 API" 是把"模型路由/分类"产品化的思路,和我们做智能网关/请求路由时的分流器可对标。

## 模型服务 & 编排

### KServe 上游 —— 本周重点
[v0.21.0](https://github.com/kserve/kserve/releases/tag/v0.21.0)(2026-09-25)围绕 LLMInferenceService 补齐生产能力:
- **DRA**:[servingruntime 支持 resourceClaims](https://github.com/kserve/kserve/pull/5828)——GPU/加速卡走 K8s 动态资源分配,不再只靠 resource limits。
- **弹性**:[llmisvc 直接对接 KEDA 扩缩](https://github.com/kserve/kserve/pull/5839)、[RawDeployment 的 HTTPRoute 支持金丝雀分流](https://github.com/kserve/kserve/pull/5912)、[llmisvc 新增 rolloutStrategy 控制滚动更新](https://github.com/kserve/kserve/pull/5916)、[金丝雀流量按 readiness 放量避免瞬时 503](https://github.com/kserve/kserve/pull/5984)。
- **架构**:[用 vLLM render deployment 取代 UDS tokenizer sidecar](https://github.com/kserve/kserve/pull/5712)、[WVA 从 CRD 迁到注解发现](https://github.com/kserve/kserve/pull/5722)、[CRD 拆分以支持独立安装](https://github.com/kserve/kserve/pull/5843)。
- **llm-d 对齐**:多个 PR 迁移 --model-server-metrics-* 系列 flag 以适配 llm-d([5930](https://github.com/kserve/kserve/pull/5930)、[5877](https://github.com/kserve/kserve/pull/5877))。
- **Agent 化**:[新增 agentic tool-calling 指南与样例](https://github.com/kserve/kserve/pull/5906)。
- 启示:KServe 正把 llmisvc 做成"llm-d 的声明式外壳"(DRA + KEDA + 金丝雀 + tokenizer render)。这几乎就是我们要对标的推理平面完整形态,建议逐个 PR 拆读 5828/5839/5912/5712,评估我们自研 CRD 与之的差距。

### Ray
无版本发布,serve/llm 与 core 是重点:
- [Serve LLM:direct streaming 聚合与 PD 分离部署均支持 LoRA](https://github.com/ray-project/ray/pull/65680)。
- [RayCluster 支持 idleTerminationOptions 空闲自动终止](https://github.com/ray-project/ray/pull/65763)——降本相关。
- [TorchTrainer 支持 TorchTPU 多 slice 分布式训练](https://github.com/ray-project/ray/pull/66055)。
- Ray Sandbox:[gVisor 后端支持 per-exec 用户与追加写](https://github.com/ray-project/ray/pull/65942)、[给外部 sandbox 客户端加 gRPC facade](https://github.com/ray-project/ray/pull/65839)、[实验性 HTTP API 服务](https://github.com/ray-project/ray/pull/65633)——Agent/代码执行沙箱正在成为 Ray 的一等能力。
- 启示:Ray 在补"Agent 安全执行沙箱",这是 Agent 平台的刚需;如果我们要做 Agent runtime,gVisor 沙箱 + gRPC facade 的设计值得直接参考。

### KubeAI(原 substratusai/lingo)
窗口内仅 2 个提交(otel 自动扩缩基数修复、Ollama 启动探针顺序修复),延续近期低活跃,无重大更新。

## 训练 & 微调

- **Kubeflow Trainer(原 training-operator)**:窗口内仅 2 个稳定性修复([MPI plugin NumProcPerNode 空指针](https://github.com/kubeflow/trainer/pull/4049)、[无数据文件 worker 的 readiness 路径](https://github.com/kubeflow/trainer/pull/4058)),无功能级更新。
- **LLaMA-Factory**:异构算力扩张明显——[新增 Ascend 950PR&950DT 镜像](https://github.com/hiyouga/LLaMA-Factory/pull/10851)、[Intel XPU 支持接入测试基建](https://github.com/hiyouga/LLaMA-Factory/pull/10835)、[GLM-5.3-Flash 训练支持](https://github.com/hiyouga/LLaMA-Factory/pull/10840)。
- 启示:微调侧对国产/异构卡(Ascend 950、Intel XPU)的一等支持在提速,和我们纳管多厂商加速卡的产品判断一致。

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow**:无功能级发布(v2.11.5 为补丁),100+ 提交多为 model catalog 自动同步、tracing/judge 修复。值得留意的方向是 GenAI 可观测/评估:[TypeScript tracing 支持 MLFLOW_TRACE_LOCATION](https://github.com/mlflow/mlflow/pull/23772)、TypeSafe judges + System One Gateway 文档化。
- **kubeflow/hub(原 model-registry)**:catalog 化继续,并开始纳管 MCP 资产——[MCP runtimeMetadata 加存储(catalog server + BFF DTO)](https://github.com/kubeflow/hub/pull/3238)、[Model 与 MCP 共享 catalog 设置 UI 外壳](https://github.com/kubeflow/hub/pull/3135)。模型注册中心正扩展成"模型 + MCP server"统一目录。
- **Feast**:[将 MLflow 提升为一等的离线 DataSource](https://github.com/feast-dev/feast/pull/6702);另有[Trino 离线库质量监控特征](https://github.com/feast-dev/feast/pull/6779)、[特征视图 MATERIALIZING 期间可继续服务](https://github.com/feast-dev/feast/pull/6789)。
- 启示:Registry 纳管 MCP、Feast 拉入 MLflow——生命周期组件在互相打通边界。我们若做模型/资产目录,应预留 MCP server 这类"非模型 AI 资产"的位置。

## LLM 评估 & 安全

- **lm-evaluation-harness**:窗口内 0 提交、无发布,无重大更新。
- **garak**:窗口内 0 提交、无发布,无重大更新。
- **llama-stack(release 仍在 meta-llama/llama-stack;内部改名 ogx-ai/ogx)**:无窗口内发布但提交活跃,主线是"通用网关化":
  - 原生透传:[Anthropic /v1/messages 原生转发不再翻译](https://github.com/meta-llama/llama-stack/pull/6664),同类透传补齐 [DeepSeek](https://github.com/meta-llama/llama-stack/pull/6677)、[Fireworks](https://github.com/meta-llama/llama-stack/pull/6676)。
  - Provider 扩张:[接入 Text-Embeddings-Inference](https://github.com/meta-llama/llama-stack/pull/6657)、[llama.cpp server 支持 rerank 模型](https://github.com/meta-llama/llama-stack/pull/6620)、新增 [exa](https://github.com/meta-llama/llama-stack/pull/6643) / [Serply](https://github.com/meta-llama/llama-stack/pull/6636) Web 搜索 provider。
- 启示:llama-stack 在往"多后端统一 API 网关 + 工具/检索编排"方向收敛,与 KServe llmisvc、Ollama decision API 一样都在抢"推理入口层"。这一层的标准化竞争值得我们持续盯。

## 值得跟进

- [ ] 逐个拆读 KServe v0.21.0 的 llmisvc PR:[DRA #5828](https://github.com/kserve/kserve/pull/5828)、[KEDA 直接扩缩 #5839](https://github.com/kserve/kserve/pull/5839)、[RawDeployment 金丝雀 #5912](https://github.com/kserve/kserve/pull/5912)、[vLLM render 取代 tokenizer sidecar #5712](https://github.com/kserve/kserve/pull/5712),对比我们自研推理 CRD 的差距。
- [ ] 评估 Ray Sandbox(gVisor + gRPC facade,[#65942](https://github.com/ray-project/ray/pull/65942)/[#65839](https://github.com/ray-project/ray/pull/65839))能否作为我们 Agent 代码执行的沙箱参考方案。
- [ ] 关注 kubeflow/hub 的 MCP catalog 化([#3238](https://github.com/kubeflow/hub/pull/3238)):我们的模型目录是否要预留 MCP server / 非模型 AI 资产的数据模型。
- [ ] 评估 Feast × MLflow 一等集成([#6702](https://github.com/feast-dev/feast/pull/6702))对我们数据/特征层选型的影响。
- [ ] 跟踪 llama-stack 的原生透传网关趋势与 KServe llmisvc 的"入口层"竞争关系。
