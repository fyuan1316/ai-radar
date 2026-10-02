# AI 推理 & MLOps 生态周报 2026-10-02

> 窗口:2026-09-25 ~ 10-02(过去 7 天)。已跳过版本 bump / dependabot / CI 噪音。
> 源仓库改名已校正:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、LLaMA-Factory→hiyouga/LlamaFactory;TGI 已 archived(永远 0 提交)。

## 摘要(5 条以内)

1. **KServe v0.21.0 GA 发布**,且本周 llmisvc(LLMInferenceService)方向密集落子:KV cache 卸载进 v1alpha1 API、P/D disaggregated 工作负载标注、全新 **KernelCache**(从 OCI registry 带凭证拉取并挂进推理 Pod)。KServe 正把"LLM 原生服务 + KV/kernel 缓存"做进核心 CRD,是本周对我们最重要的信号。https://github.com/kserve/kserve/releases/tag/v0.21.0
2. **P/D 分离(prefill/decode disaggregation)全赛道工程化**:vLLM 继续补 NIXL/KV connector 与 async KV 的指标与一致性,SGLang 把 sgl-router 做成生产级(peer bootstrap + RBAC + downward API、worker-api-key、dp-aware 路由),TRT-LLM 引入 Mooncake store 与 sparse KV cache 分层锁。KV 传输层正在成为推理平台的独立组件。
3. **Kubeflow Trainer 新增 OptimizationJob 控制器(KEP-3562)**,把超参优化做成一等 Job 类型,与 Volcano gang 集成。训练侧 operator 从"跑训练"扩到"跑调优"。https://github.com/kubeflow/trainer/pull/3828
4. **MLOps 侧两处值得抄**:Feast 把 MLflow 变成一等 offline DataSource、MLflow 新增 OTLP/Prometheus 指标导出(feat/otlp prometheus metrics)。可观测与特征/实验链路在互相打通。
5. **llama-stack 转向"原生透传"**:对 Anthropic/DeepSeek/Fireworks 的 `/v1/messages` 不再翻译而是原生转发,并支持 MCP 2.x 客户端 SDK、TEI 推理 provider、rerank 模型。网关层去翻译化 + MCP 升级是明确趋势。

## 推理引擎动态

### vLLM
无新 release,但主干高速迭代,对平台侧有用的几条:
- **原生 ModelExpress 权重传输后端**(`[Feature] Add native ModelExpress weight transfer backend`),配合 WorkspaceManager sleep 时释放 scratch——弹性/快速加载方向。https://github.com/vllm-project/vllm/pull/58399
- **P/D 与 KV 连接器**:KV-fetch 阶段 gauge 指标、NIXL 过期后到达的完成通知计数、跨 cache group 合并 host-buffer KV 拷贝——disagg 的可观测与正确性在收口。https://github.com/vllm-project/vllm/pull/58874
- **Anthropic API 兼容**:接受 Anthropic `tool_addition`/`tool_removal` 内容块;从 `/v1/chatcompletions` 剥离 `x-anthropic-billing-header`。vLLM 前端在向 Anthropic 协议靠拢。https://github.com/vllm-project/vllm/pull/57693
- Model Runner V2、批不变性(batch-invariant)下的 custom all-reduce 等底层重构持续推进。

### SGLang
- **v0.5.21 发布**。https://github.com/sgl-project/sglang/releases/tag/v0.5.21
- **sgl-router 生产化**是本周重点:支持 `--worker-api-key` 启动的引擎、`--dp-aware` 路由到指定 DP rank、PD 版本组兼容性强校验、prefill 失败即 fail-fast 取消 decode;并补齐 peer bootstrap 的 flags/RBAC/downward API/探针文档。对标我们自研网关可直接参考。https://github.com/sgl-project/sglang/pull/42049
- **unified-memory KV 池重构**(1/7~7/7 系列):统一分页 KV 视图、按 stride 而非 shape 推地址。底层内存管理大改。https://github.com/sgl-project/sglang/pull/40326

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:发 v1.3.0rc29,主干已 bump 到 1.4.0rc0。平台相关:sparse KV cache 配置 + 分层感知锁(TRTLLM-16282)、**Mooncake store 第一部分**(pool/CLI/V2 调度器抢占)、DeepSeek V4 sparse KV offload 准备、OpenAI server 的**按模型 serving-extension 注册表**;**BREAKING**:移除 KVCacheManagerV2 的 Python 后端。https://github.com/NVIDIA/TensorRT-LLM/pull/19580
- **TGI**:仓库已 archived,窗口内 0 提交,属正常停维护。
- **Ollama**:发 v0.35.0 与 v0.40.0-rc0;新增每次响应最多 10 次 web search、System One 打分 API、显式声明模型能力(capabilities)。偏应用/边缘侧。https://github.com/ollama/ollama/releases/tag/v0.35.0

## 模型服务 & 编排

### KServe 上游
本周最活跃(28 commits),方向非常清晰,全在 **llmisvc + KernelCache**:
- **v0.21.0 GA**。https://github.com/kserve/kserve/releases/tag/v0.21.0
- `feat(llmisvc): add KVCacheOffloading to v1alpha1 API with conversion`——KV 卸载进 CRD。https://github.com/kserve/kserve/pull/6006
- `feat(llmisvc): label disaggregated workload revisions`——P/D 分离工作负载的版本标注。https://github.com/kserve/kserve/pull/6218
- **KernelCache 全家桶**:capture 基础、与推理 workload 集成、registry 凭证/鉴权、支持 insecure OCI registry、从 OCI 拉 kernel cache 并挂进 Pod。等于把"编译后 kernel 产物"也做成 OCI 制品分发。https://github.com/kserve/kserve/pull/6299
- isvc/inferencegraph 控制器大量加 **platform customization hooks**(raw Deployment 定制、条件上报、分发特定逻辑钩子)——为下游 distribution(如 ODH、我们)留扩展点。https://github.com/kserve/kserve/pull/6313
- 存储:oci+fetch 支持 zstd 压缩 OCI 层。https://github.com/kserve/kserve/pull/6022

### Ray
无新 release。Serve/LLM 侧:ingress router 失败时回退到可用副本、移除 P/D tokenize-once 补丁、应用副本性能默认值、llm CI 升级到 vLLM 0.30.0。其余大量是 Ray Data v2 重构与文档。平台相关度中等。https://github.com/ray-project/ray/pull/66339

### KubeAI(原 lingo)
安静(5 commits,多为 release/deps):v0.23.5,修 OTel autoscaling 基数、Ollama 预处理在 startup probe 前执行。https://github.com/kubeai-project/kubeai/releases/tag/v0.23.5

## 训练 & 微调

- **Kubeflow Trainer**:新增 **OptimizationJob 控制器(KEP-3562)**——把 HPO/调优做成独立 Job CRD,是 Trainer v2 的重要能力扩张;另有 Volcano priorityClassName 的全 ReplicatedJobs 校验、插件阶段确定性执行顺序。https://github.com/kubeflow/trainer/pull/3828
- **LlamaFactory**:新增 Ascend 950PR/950DT 与 Intel XPU 镜像、XPU 测试基建、GLM-5.3-Flash 训练支持。硬件多样性(昇腾+Intel)是国内社区信号。https://github.com/hiyouga/LlamaFactory/pull/10851

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow**:新增 **OTLP/Prometheus 指标导出**(feat/otlp prometheus metrics)、TypeSafe SDK autologging、gateway 对 Gemini/Vertex 的 `tool_choice` 支持、修多家 provider 的并行 tool call 流式索引;WSGI 线程池耗尽时保持 server-info 可响应。可观测标准化值得关注(本周大量提交是 triage 自动化,已略)。https://github.com/mlflow/mlflow/pull/25192
- **Feast**(40 commits,很活跃):**MLflow 作为一等 offline DataSource**、Milvus online store 可配索引/搜索参数并支持 token/uri/db 鉴权、Redis 在线读可选 GLIDE 客户端、物化中(MATERIALIZING)仍可提供特征。向量检索 + RAG 特征供给方向明显。https://github.com/feast-dev/feast/pull/6702
- **Model Registry(kubeflow/hub)**:catalog 支持 **MCP 架构过滤**、catalog 凭证 UI、Model/MCP 共享 catalog 设置壳。Registry 正把 MCP server 也纳入 catalog 管理。https://github.com/kubeflow/hub/pull/3297

## LLM 评估 & 安全

- **lm-evaluation-harness**:窗口内 0 提交,无重大更新。
- **NVIDIA/garak**:窗口内 0 提交,无重大更新。
- **llama-stack**(原 meta-llama,PR 指向 ogx-ai/ogx):
  - **网关去翻译化**:对 Anthropic/DeepSeek/Fireworks 的 `/v1/messages` 改为原生透传,不再协议翻译。https://github.com/meta-llama/llama-stack/pull/6664
  - **MCP 2.x 客户端 SDK** 支持、新增 **TEI(Text-Embeddings-Inference)推理 provider**、exa web search provider、llama.cpp server 支持 rerank 模型。https://github.com/meta-llama/llama-stack/pull/6684
  - 多项 BREAKING:显式 `apis:` 列表即使为空也权威、conversations/prompts 服务条件化。

## 值得跟进

- [ ] **KServe KernelCache**:把编译 kernel 做成 OCI 制品 + 凭证拉取挂载,是否值得在我们产品里对标?它和 KVCacheOffloading 一起定义了"LLM 服务的缓存层"。
- [ ] **P/D 分离的 KV 传输层**(vLLM NIXL / SGLang router / TRT-LLM Mooncake store)正在独立成组件,评估我们网关/调度是否需要原生支持 disagg 拓扑与 KV transfer 指标。
- [ ] **llmisvc platform hooks**:KServe 为下游 distribution 预留的定制钩子,是我们 fork/扩展的接入点,建议跟 ODH fork 的用法一起看。
- [ ] **Kubeflow Trainer OptimizationJob**:HPO 作为一等 CRD,评估与我们训练平台的调优能力差距。
- [ ] **MLflow OTLP 指标 + Feast×MLflow 打通**:MLOps 可观测与特征/实验链路在收口,看是否影响我们的集成方式。
- [ ] **协议层**:vLLM / llama-stack 同时向 Anthropic 协议原生兼容/透传靠拢,关注是否要在我们网关侧支持 `/v1/messages`。
