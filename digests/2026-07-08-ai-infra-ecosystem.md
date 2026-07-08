# AI 推理 & MLOps 生态周报 2026-07-08

> 窗口:2026-07-01 ~ 2026-07-08(过去 7 天)。仅筛选对"做云原生 AI 基础设施产品(对标 OpenShift AI)"有用的变化,版本 bump / dependabot / CI 噪声已跳过。

## 摘要(5 条以内)

1. **KServe 上游全面绑定 llm-d**:llmisvc 默认拓扑改用 llm-d 优化基线(EndpointPicker 走 queue+prefix-cache 调度),路由 CRD 迁到 llm-d.ai 官方 InferencePool,并新增 LLMInferenceService 渐进式流量切分 API——分布式 LLM 推理的"开箱即调优 + 金丝雀发布"能力正在上游成型。
2. **多家仓库本周发生改名/迁移**,后续抓取需换路径:`meta-llama/llama-stack`→`ogx-ai/ogx`(改名 OGX)、`kubeflow/model-registry`→并入 `kubeflow/hub`(升级为 AI Hub)、`substratusai/lingo`→`kubeai-project/kubeai`、`kubeflow/training-operator`→`kubeflow/trainer`。
3. **KV 卸载/分层缓存成跨项目主线**:vLLM 建体系化 KV-Offloading(workload identity + objectstore),KServe 扩二级文件系统缓存(GPU→CPU→POSIX),SGLang 增强 HiCache——显存不足下托管大模型/长上下文的成本优化是共同方向。
4. **MLflow 与 llama-stack(OGX)双双向"企业级 Agent 平台 + 安全合规"演进**:MLflow 补 Agent 网关 RBAC、模型注册表鉴权收紧、SSRF 修复;OGX 强制 TLS、OTel/Prometheus 指标暴露、Responses API 加 memory 路径。
5. **红队/安全评测成为 eval 框架标配方向**:garak 新增编码类绕过探针(全角/Unicode)与公式注入检测,lm-eval-harness 社区在推 JailbreakBench / OWASP LLM02 等安全任务——可纳入我们模型上线的准入门禁。

## 推理引擎动态

### vLLM
- 本周打出 `v0.25.0rc1` 预发布 tag(2026-07-08),窗口内活跃度极高(7 天 100+ commit);最近一个稳定 release 是 v0.24.0(6/29,窗口前) https://github.com/vllm-project/vllm/releases/tag/v0.24.0
- 投机解码新范式 DSpark 合入(置信度调度式 spec decode),是企业级低延迟推理的关键能力 https://github.com/vllm-project/vllm/pull/46995
- KV 卸载体系化推进:二级 objectstore 存储层支持 workload identity / 密钥,并新增卸载指标——对多租户下显存不足、大模型托管场景有直接价值 https://github.com/vllm-project/vllm/pull/47063
- 前端新增 endpoint plugins 可扩展框架(便于把自定义端点插进 OpenAI 兼容服务),配合 per-request timing metrics,利于计费与可观测性接入 https://github.com/vllm-project/vllm/pull/47454
- 架构精简信号:合入"让 Transformers modeling 后端跑到原生 vLLM 同速",降低对旧内核的维护面 https://github.com/vllm-project/vllm/pull/47187

### SGLang
- 本周未发新正式版(v0.5.14 于 6/26 发布,窗口外),主线在为 v0.5.15 备货 https://github.com/sgl-project/sglang/releases/tag/v0.5.14
- 原生 gRPC server 推进(launcher + HTTP + server args wiring),朝生产级服务化接口演进,利于与云原生控制面集成 https://github.com/sgl-project/sglang/pull/23508
- HiCache 分层 KV 缓存增强:为 HiCacheFile 存储加客户端元数据缓存,并有 L2 prefetch-buffer-only 内存模式,提升分层缓存托管能力 https://github.com/sgl-project/sglang/pull/29716
- 配置系统重构落地(资源租约 named slots、config 解析统一到 server_args),降低运行时状态耦合,对稳定性有利 https://github.com/sgl-project/sglang/pull/30348
- DSpark(置信度调度投机解码)在 SGLang 侧也有提交,与 vLLM 形成上下游呼应 https://github.com/sgl-project/sglang/pull/30261

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:明确将移除 TensorRT 后端、全面转向 PyTorch 路线;功能面新增 Qwen3.5 VL Dense、Disaggregated KV-cache bounce transfer,并暴露启动期 KV cache 容量查询(利于容量规划) https://github.com/NVIDIA/TensorRT-LLM/pull/15810
- **TGI**:窗口内无提交、无新版本(最新 v3.3.7 停在 2025-12),无重大更新 https://github.com/huggingface/text-generation-inference/releases/tag/v3.3.7
- **Ollama**:v0.31.2-rc2(7/6)推进中,亮点是新增 agent harness core(内置 agent 运行时)、CC 6.x CUDA GPU 启用 FlashAttention;社区高热诉求集中在可观测性(/metrics 暴露 eval 指标) https://github.com/ollama/ollama/releases/tag/v0.31.2-rc2

## 模型服务 & 编排

### KServe 上游
- llmisvc 深度对齐 llm-d:默认单 profile / P/D 分离配置全面采用 llm-d 优化基线(EndpointPicker 用 queue+prefix-cache 调度),企业可直接拿到经调优的分布式推理默认拓扑 https://github.com/kserve/kserve/pull/5670
- 路由资源迁移到 llm-d.ai 官方 CRD(InferencePool 走 GIE v1),少维护一层上游依赖、CRD 来源更规范——对做 LLM 网关/路由集成是明确的上游标准化信号 https://github.com/kserve/kserve/pull/5585
- 新增 LLMInferenceService 渐进式流量切分 API(支持多版本受控灰度),补齐模型生命周期里的金丝雀/蓝绿发布能力 https://github.com/kserve/kserve/pull/5727
- KV cache offloading 扩展二级文件系统层级(GPU→CPU→POSIX 磁盘多级缓存,基于 vLLM OffloadingConnector),提升长上下文/高并发下的显存利用与成本 https://github.com/kserve/kserve/pull/5740
- Envoy AI Gateway 升级至 v1.0.0(AI 网关侧走向 GA) https://github.com/kserve/kserve/pull/5723

### Ray
- 本周无新版本(最近为 6/29 的 ray-2.56.0) https://github.com/ray-project/ray/releases/tag/ray-2.56.0
- Ray Serve LLM 推进 KV-aware 路由:新增 token 级请求生命周期跟踪,把 vLLM 引擎的每请求 token 负载上报给 deployment 级 KVRouterActor,为按在途负载做 KV 感知路由铺路 https://github.com/ray-project/ray/pull/64327
- Serve LLM 在 direct-streaming 模式打通 /classify 与 /pooling 端点,补齐 reward/分类模型的原生 vLLM 服务能力 https://github.com/ray-project/ray/pull/64494
- Data.LLM 批处理增强:ServeDeploymentProcessor 新增 request_timeout_s,避免副本饱和时批量推理无限期挂起 https://github.com/ray-project/ray/pull/64496
- 方向性提案:让 NIC 成为 Ray Core 一等可调度资源,对 GPU/网络亲和调度是信号 https://github.com/ray-project/ray/issues/64426

### Lingo
- 无重大更新。仓库已改名迁移到 kubeai-project/kubeai(Lingo 演进为 KubeAI),窗口内主分支仅有 dependabot 与 CI PR;最近一次功能提交(以 OCI 镜像加载模型)在窗口外 https://github.com/kubeai-project/kubeai/pull/661

## 训练 & 微调

### Kubeflow Training Operator
- 仓库已正式更名迁移到 kubeflow/trainer(Kubeflow Trainer v2),原路径 301 重定向;最新版仍是 v2.2.1(6/18),本周无新 release https://github.com/kubeflow/trainer/releases
- v2.3 已进入 mid-July 计划,目标本月出首个 RC,附带 Helm 破坏性变更迁移指南 https://github.com/kubeflow/trainer/issues/3664
- 新增 Flux Framework 集成与 e2e 测试,TrainJob 的 gang-scheduling 调度后端进一步覆盖 Flux https://github.com/kubeflow/trainer/pull/3561
- 安全/多租户方向:为 runtimes 增加 restricted PodSecurityStandard 安全上下文(评审中),契合企业级合规诉求 https://github.com/kubeflow/trainer/pull/3702

### LLaMA-Factory
- 仓库更名为 hiyouga/LlamaFactory(旧路径重定向);最新 release 仍是 v0.9.5,本周无新版本 https://github.com/hiyouga/LlamaFactory/releases
- 正在推进 v1 架构重构:移除自研模板/渲染栈,改为直接走模型自带 `apply_chat_template`,降低模板维护成本、提升与上游 transformers 一致性 https://github.com/hiyouga/LlamaFactory/pull/10598
- v1 分支新增 Muon 优化器支持,跟进新一代优化器 https://github.com/hiyouga/LlamaFactory/pull/10618
- WebUI 新增 seed 复现控制(训练/生成/评估可显式设种子),利于可复现实验 https://github.com/hiyouga/LlamaFactory/pull/10629

## 模型生命周期(MLflow / Registry / Feast)

### Kubeflow Model Registry
- **重大架构信号**:`kubeflow/model-registry` 已并入 monorepo `kubeflow/hub`(旧路径 301),定位从"模型注册表"升级为"AI Hub",本周合入 AI Hub v1 提案 https://github.com/kubeflow/hub/pull/2690
- 新增 Agent Catalog:落地智能体目录后端与 artifacts/template artifact type 端点,面向 Agent 分发 https://github.com/kubeflow/hub/pull/2912
- 新增 MCP Server Catalog:BFF 增加 MCP catalog sources 的 CRUD 端点,把 MCP 工具/服务纳入统一目录治理,对标企业级 Agent/工具编排 https://github.com/kubeflow/hub/pull/2890
- CSI 加固:拒绝畸形 model-registry URI,收敛模型拉取路径安全边界 https://github.com/kubeflow/hub/pull/2911

### MLflow
- 无新版本(最新仍为 6/17 的 v3.14.0),但本周主线大量围绕"Agent/GenAI + 企业安全"演进 https://github.com/mlflow/mlflow/releases/tag/v3.14.0
- Agent 网关 RBAC:让 OpenAI 协议的编码 Agent 通过 RBAC gateway 认证接入 MLflow,补齐 Agent 侧鉴权 https://github.com/mlflow/mlflow/pull/24294
- 模型注册表 RBAC 收紧(多租户相关):创建 model version 需对源 run/model 有读权限;LogInputs 端点强制 update-run 授权 https://github.com/mlflow/mlflow/pull/24293
- TypeScript SDK 升到 0.3.0 并支持 search traces,追踪能力向 JS 生态延伸 https://github.com/mlflow/mlflow/pull/23660
- 安全修复:修复 webhook 投递的 DNS-rebinding SSRF 绕过 https://github.com/mlflow/mlflow/pull/24258

### Feast
- 无新版本(最新仍为 6/13 的 v0.64.0) https://github.com/feast-dev/feast/releases/tag/v0.64.0
- 新增 Aerospike 在线存储,扩充低延迟特征服务后端选择 https://github.com/feast-dev/feast/pull/6532
- 企业合规:为 offline server 配置 FIPS 合规的 gRPC 密码套件——面向受监管环境部署 https://github.com/feast-dev/feast/pull/6574
- 注册表持久化修复:MySQL SQL registry proto 列改用 LONGBLOB,避免大 proto 截断 https://github.com/feast-dev/feast/pull/6566

## LLM 评估 & 安全

### lm-evaluation-harness
- 本周无发布、主干无实质提交(最新仍为 5 月 v0.4.12);社区活跃在"安全/红队评测任务"提案:JailbreakBench 对抗鲁棒性评测 https://github.com/EleutherAI/lm-evaluation-harness/issues/3915 、OWASP LLM02 输出处理基准 https://github.com/EleutherAI/lm-evaluation-harness/issues/3771
- 启示:企业级模型上线前的"安全合规评测"正成为 eval 框架标配方向,可纳入我们模型生命周期的准入门禁

### garak
- 本周无新版本(最新仍 v0.15.1),提交多为测试/修复 https://github.com/NVIDIA/garak/pull/1901
- 新红队探针在评审中,方向对我们的安全护栏有参考:CSV/表格公式注入探针+检测器(CWE-1236) https://github.com/NVIDIA/garak/pull/1908 、UTF 全角编码绕过探针 https://github.com/NVIDIA/garak/pull/1864 、StringDetector 增加 Unicode 归一化 https://github.com/NVIDIA/garak/pull/1884
- 启示:编码类绕过(全角/Unicode)与公式注入是当前红队热点,护栏检测需补 Unicode 归一化预处理

### llama-stack
- **重大变化**:仓库整体更名为 OGX,`meta-llama/llama-stack` 现 301 跳转到 https://github.com/ogx-ai/ogx ,客户端 SDK 改名 ogx_client https://github.com/ogx-ai/ogx/pull/6207
- 安全/合规:强制 TLS 模式(破坏性变更) https://github.com/ogx-ai/ogx/pull/5603
- 可观测性:OTel 指标通过 Prometheus 抓取端点暴露,便于接入云原生监控栈 https://github.com/ogx-ai/ogx/pull/6034
- Responses API 演进:新增 memory 读/写路径,并把 skills 指令注入系统提示 https://github.com/ogx-ai/ogx/pull/6162
- 值得警惕的安全 issue:访问控制"取反条件"在数据缺失时 fail-open https://github.com/ogx-ai/ogx/issues/5700 、服务端工具执行绕过护栏导致间接提示注入不被检测 https://github.com/ogx-ai/ogx/issues/5036 ——多租户/护栏设计应引以为戒

## 值得跟进

- [ ] **KServe llmisvc × llm-d 整合**:这是本周对我们最直接的信号,建议评估把 llm-d 优化基线 + InferencePool(GIE v1)路由纳入我们自家推理编排,以及渐进式流量切分 API 的对齐 https://github.com/kserve/kserve/pull/5670
- [ ] **抓取路径更新**:后续任务把 lingo→`kubeai-project/kubeai`、model-registry→`kubeflow/hub`、training-operator→`kubeflow/trainer`、llama-stack→`ogx-ai/ogx`,并让 curl 带 `-L` 跟随 301
- [ ] **KV 卸载/分层缓存**:vLLM、KServe、SGLang 三方在推分层 KV 缓存(GPU→CPU→磁盘/objectstore),对标我们大模型托管的显存成本优化,值得做一次横向能力对比
- [ ] **Kubeflow Hub 的 Agent/MCP Catalog**:model-registry 升级为统一 AI Hub(含 Agent 目录 + MCP server 目录),与我们模型/工具治理面重叠度高,需跟进其 API 形态
- [ ] **红队护栏补强**:参考 garak 的全角/Unicode 编码绕过探针与公式注入检测,评估我们安全护栏是否需补 Unicode 归一化预处理
