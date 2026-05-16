# OpenShift AI 周报 2026-05-16

窗口:2026-05-09 → 2026-05-16(7 天)

## 摘要(3 条以内)
- **LlamaStack → OGX 完成全面改名**:从 BFF、前端、E2E 测试一路下沉到 operator 组件和安装路径(`/etc/llama-stack` → `/etc/ogx`),`ogx-k8s-operator` 作为新 component 进入 manifests-config;原 `llamastackoperator` DSC 字段保留兼容但已 deprecated
- **KServe Module 拆分启动 + ModelCache 进 operator**:KServe 仓库新增 `kserve-module` manifest 渲染流水线,operator 加 `odh-kserve-module-operator` 与 `ModelCacheSpec`(节点亲和 + cacheSize),为本地模型缓存 + 可拆分 ServingRuntime 子模块铺路
- **Operator 多云扩展 + Kueue 1.3 落地**:operator 加 Amazon EKS 作为 cloud manager provider(对齐 Azure / CoreWeave),Kueue v1beta2 ClusterQueue/LocalQueue/ResourceFlavor 支持已上线,运行时探测 API 版本兼容 1.2 与 1.3

## 新功能 / 能力

- [LlamaStack→OGX 完整改名(BFF/Cypress/mocked tests)](https://github.com/opendatahub-io/odh-dashboard/pull/7579) — 紧接 #7403,把 `llamastackoperator` 在测试/扩展点/BFF 中的兜底引用全部清掉,只剩 `ogx`
  - 启示:OGX 是 LlamaStack 1.0.0 的下游 fork(`ogx-k8s-operator`),Red Hat 把"gen-ai 运行时容器"完全收编成自有品牌组件。我们如果之前对 LlamaStack 做过集成,要重新对齐 OGX 的 Go module / env var / header 命名;DSC API 还兼容旧字段,但代码内只认 OGX
- [OGX 安装路径 /etc/llama-stack → /etc/ogx](https://github.com/opendatahub-io/odh-dashboard/pull/7585) — gen-ai BFF 的 InstallOGXServer 配置路径切到 OGX
  - 启示:容器内文件系统布局也跟着改了,任何挂载/configMap 路径假设 LlamaStack 子目录的脚本都会断,迁移时记得改 ConfigMap key 路径
- [ODH operator LlamaStack 组件改名 OGX](https://github.com/opendatahub-io/opendatahub-operator/pull/3531) — operator 里 LlamaStackOperator → OGX,DSC `llamastackoperator` 字段保留为 deprecated
  - 启示:DSC 字段保留兼容意味着升级路径是平滑的;但是新部署应该直接用 `ogx`。"deprecated 字段如果 Managed 报警"这个机制可以借鉴
- [Add odh-ogx-k8s-operator 到 manifests-config](https://github.com/opendatahub-io/opendatahub-operator/pull/3513) — 把 OGX 作为独立 operator 子组件进入 manifest map
- [Add odh-kserve-module-operator 到 manifests-config](https://github.com/opendatahub-io/opendatahub-operator/pull/3543) — 新增 KServe Module 子 operator
  - 启示:OAI 把 KServe 控制面进一步拆分,`kserve-module` 看起来是 KServe ServingRuntime/InferenceService 的"可独立部署"渲染单元,这与 KServe upstream 的 LLMInferenceService 子项目方向一致
- [KServe Module manifest 渲染流水线](https://github.com/opendatahub-io/kserve/pull/1480) — params.env 解析、Kustomize 渲染、xKS overlay 切换、LLMInferenceServiceConfig version 前缀支持滚动升级
  - 启示:KServe Module 不只是 manifest 拆分,还引入了"配置版本前缀"机制,目的是滚动升级时同时存在多个 InferenceServiceConfig 副本,我们做 InferenceService 控制器升级时这个模式值得借鉴
- [KServe 加 modelcache 支持](https://github.com/opendatahub-io/opendatahub-operator/pull/3379) — operator 里 `KserveSpec.ModelCache`:managementState、cacheSize、nodeNames/nodeSelector(互斥),CEL 校验
  - 启示:模型缓存终于走进 operator API,而不是 ServingRuntime 层级的临时实现。我们做模型分发/预热时可以对齐这个数据结构(节点级 PVC + 选择器 + 容量上限)
- [Kueue 1.3 v1beta2 支持](https://github.com/opendatahub-io/opendatahub-operator/pull/3538) — ClusterQueue / LocalQueue / ResourceFlavor 走 v1beta2,运行时探测 API 版本兼容 1.2/1.3
  - 启示:Kueue 1.3 是 GPU 调度栈关键升级;OAI 走的是"运行时 detect"模式,我们如果直接 import v1beta1 客户端会被 1.3 卡住,这个动态 dispatch 模式值得对齐
- [MaaS 拆 maas-controller Deployment + 集群级 Config](https://github.com/opendatahub-io/opendatahub-operator/pull/3535) — disable 不再删 Tenant CR,而是删 maas-controller Deployment,真正的拆卸交给 MaaS controller 的 lifecycle/ownership 图谱
  - 启示:MaaS 走"控制器 ownership 链 + 集群 Config 锚定"模式,operator 只管启停控制器进程,业务对象的回收交给业务控制器。我们做多租户 LLM 服务的卸载时这是参考分层
- [Amazon cloud manager provider](https://github.com/opendatahub-io/opendatahub-operator/pull/3477) — 对齐 Azure/CoreWeave,允许 `--set aws.enabled=true` 在 EKS 上跑 RHAI
  - 启示:Red Hat AI(RHAI)开始走"非 OpenShift" Kubernetes 路径,EKS 直接可用,这是 OAI 在松 OpenShift 绑定方向的一个明确信号;意味着我们做平台产品要预期"RHAI 上 EKS"作为竞品场景
- [NIM Settings Card(项目级 API Key 管理)](https://github.com/opendatahub-io/odh-dashboard/pull/7436) — Project Settings 加 NIM 卡片,创建 Secret + Account CR,Poll 验证状态,支持替换/移除 key
  - 启示:NIM 接入做"per-project API key + Account CR"模式;对比 vLLM/KServe 是"全局 ServingRuntime",NIM 把订阅模型私钥下沉到项目层。我们做闭源模型对接时也需要这种"项目级 secret + 状态机"
- [NIMService 进统一 Deployments 表](https://github.com/opendatahub-io/odh-dashboard/pull/7433) — NIM 作为 `model-serving.platform` 与 KServe ModelMesh 并列
  - 启示:Dashboard 的"deployments 视图"用 `ModelServingPlatformWatchDeploymentsExtension` 扩展点,允许第三方 ServingPlatform 接入;我们做异构 ServingRuntime 整合时,这个扩展点协议可以参照
- [NeMo Guardrails 接入 View Code](https://github.com/opendatahub-io/odh-dashboard/pull/7501) — Playground 生成的 Python 代码自动嵌入 `/v1/guardrail/checks` 调用与 inline config
  - 启示:OAI 不只在运行时挂 Guardrails,还把它生成到用户拷贝的代码片段里,确保用户离开 dashboard 之后仍然带着护栏。这是"安全策略可携带"的产品化思路
- [MCP 部署状态从 Phase 切到 Conditions](https://github.com/opendatahub-io/odh-dashboard/pull/7429) — MCP 部署的 `Pending/Running/Failed` enum 改为 K8s 风格 Conditions(Accepted/Ready/...)
  - 启示:从 Phase 切 Conditions 是 K8s API 演进的标准动作,但说明 MCP server 在 OAI 已经被认真当作"长期运行的 K8s 工作负载",而不是临时容器;我们做工具/agent 集成时也应该走 Conditions
- [MaaS 前端用 Zod 校验 + 移除 Pre-3.4 遗留](https://github.com/opendatahub-io/odh-dashboard/pull/7480) — Subscriptions/AuthPolicies 表单切 Zod;[#7502](https://github.com/opendatahub-io/odh-dashboard/pull/7502) 删除 3.4 以前的 tier/rate-limit/token 旧代码
  - 启示:MaaS 3.5 周期已确定数据模型,前端旧 API 不再保留;我们如果对接过 OAI MaaS pre-3.4 API 需要重新读 schema
- [AutoML/AutoRAG pipeline 3.5 EA1 + 跨版本 runs 列出](https://github.com/opendatahub-io/odh-dashboard/pull/7521) — pipeline runs 不再被 pipeline_version_id 过滤,旧版本 run 不再被隐藏
  - 启示:AutoML/AutoRAG 在 3.5 EA1 是 GA-Ready 状态,产品上要把"跨 pipeline 版本的实验对比"当作核心 UX 设计
- [AutoML 列选择自动推断预测类型](https://github.com/opendatahub-io/odh-dashboard/pull/7469) — CSV schema 增加 `task_type`,识别 TIMESTAMP 等列类型并自动选择预测类型
- [MaaS 按 DSC 后端就绪门控](https://github.com/opendatahub-io/odh-dashboard/pull/7446) — gen-ai 插件不再只查 dashboard 配置,改查 DSC 中 MaaS 后端 ready
  - 启示:OAI 模块就绪检测从"前端配置 flag"升级到"读 DSC 状态"。是 dashboard 与 operator 解耦的好实践
- [Claude Preflight Agent GitHub Action](https://github.com/opendatahub-io/odh-dashboard/pull/7549) — `@odh-dashboard-agent preflight check|fix` 评论触发,30 分钟轮询 `agent-managed` 标签的 PR
  - 启示:Red Hat 在 OAI 自己的 dashboard 仓库里跑 Claude Code 做 PR 自动化(包括"managed mode"自动改代码),信号:dev workflow 里 AI agent 的"PR babysit"是被官方采用的模式
- [Preflight 加 RBAC review skill](https://github.com/opendatahub-io/odh-dashboard/pull/7586) — preflight agent 拿到 RBAC 审查能力
- [Tekton CEL 表达式重构(MLflow release push)](https://github.com/opendatahub-io/odh-dashboard/pull/7552) — MLflow tracking 接入 CI/CD release
  - 启示:MLflow operator 1.1.0 在 3.5 EA1 进入正式发布栈,MLflow 在 OAI 是与 model-registry / Kubeflow Pipelines 并列的实验跟踪入口

## 架构 / 依赖变化

- **OAI 3.5 EA1 释出**:[opendatahub-operator v3.5.0-ea.1 (2026-05-08)](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.5.0-ea.1) — 子组件版本对齐:Trainer odh-3.5-ea.1、KServe odh-v3.5-EA1、TrustyAI odh-3.5-ea1、ModelRegistry v0.3.9、MLflow Operator 1.1.0、llm-d-inference-scheduler odh-v3.5-EA1、ogx-k8s-operator/odh、Ray v1.4.4(kuberay)、Feast v0.63.0、Training Operator v1.9.0-odh-3
  - 启示:**llm-d-inference-scheduler 进入 3.5 EA1 是关键信号** — OAI 把 llm-d(LLM 多副本调度/分布式 KV 缓存)项目正式纳入栈,这是 vLLM + KServe 之后的下一层智能调度。后续我们要重点跟 llm-d-inference-scheduler 的 ServingRuntime 集成方式
- [notebooks v1.44.0](https://github.com/opendatahub-io/notebooks/releases/tag/v1.44.0) (2026-05-08) — 配套 3.5 EA1 的工作台镜像
- [KServe 卷名 63 字符限制修复(NVIDIA Nemotron 长模型名)](https://github.com/opendatahub-io/kserve/pull/1496) — `nvidia-nemotron-3-nano-30b-a3b-nvfp4-v1-0-...` 这种长名导致 volume name 超长
  - 启示:K8s 资源名长度约束在企业模型命名上踩坑,模型注册系统设计时必须做"截断 + hash 后缀"
- [KServe code sync master → release-v0.17](https://github.com/opendatahub-io/kserve/pull/1502) — KServe odh-fork 切到 v0.17 分支线,与上游 KServe 0.17 对齐
- [HardwareProfile 资源 limits 走 DefaultCount 而非 MaxCount](https://github.com/opendatahub-io/opendatahub-operator/pull/3498) — 修 webhook,使 API/CLI 创建工作负载也拿 Guaranteed QoS
  - 启示:Guaranteed QoS 对 GPU/AI 工作负载尤为重要(避免 QoS 抢占),我们的 HardwareProfile / ResourceProfile 控制器要保证 request==limit
- [model-registry pull from kubeflow/main + 同步](https://github.com/opendatahub-io/model-registry/pull/1743) — odh-fork 继续追上游

## 上游生态整合动向

- **llm-d 进入 OAI 3.5 EA1**:`llm-d-inference-scheduler` 作为独立 component release(odh-v3.5-EA1),是本周最大上游整合动作,意味着 OAI 的推理调度层从单 KServe 拓展到"KServe + llm-d 分布式调度"双层
- **KServe upstream 对齐 0.17**:odh-fork 已 sync 到 release-v0.17,后续 LLMInferenceService、ServingRuntime spec 演进可在 upstream 跟
- **Kueue 1.3(v1beta2)落地**:CNCF Kueue 1.3 是 GPU/Batch 调度的关键版本,OAI 在 operator 层完成兼容
- **MLflow Operator 1.1.0 入栈**:MLflow Operator 1.1.0 与 model-registry 并存,实验跟踪官方支持
- **Kubeflow model-registry 持续上游同步**(#1743 #1744)
- **OGX(LlamaStack fork)**:LlamaStack 1.0.0 之后 Red Hat 把它 fork 成 ogx-k8s-operator,作为 OAI 一等 component,信号是与 LlamaStack 上游可能分叉
- **NeMo Guardrails / NVIDIA NIM 持续加深**:NIM project-level API key 管理 + Guardrails 嵌入 View Code,NVIDIA 闭源组件被深度集成

## 值得跟进
- [ ] 读 [llm-d-inference-scheduler odh-v3.5-EA1](https://github.com/opendatahub-io/llm-d-inference-scheduler/releases/tag/odh-v3.5-EA1) 的 changelog,搞清楚 OAI 是怎么把 llm-d 调度器接到 KServe ServingRuntime 上(独立 CRD?Sidecar?)
- [ ] 跟 KServe Module 拆分进展([kserve#1480](https://github.com/opendatahub-io/kserve/pull/1480) + [operator#3543](https://github.com/opendatahub-io/opendatahub-operator/pull/3543)):评估我们 KServe 集成层是否要跟着分模块,以及"配置版本前缀滚动升级"的实现细节
- [ ] 评估 OGX 改名对我们 LlamaStack 集成代码的影响面(env var、Go module、API endpoint 都改了)
- [ ] [operator#3379](https://github.com/opendatahub-io/opendatahub-operator/pull/3379) ModelCacheSpec 的 CRD schema,对照我们模型预热/分发能力的设计
- [ ] [operator#3538](https://github.com/opendatahub-io/opendatahub-operator/pull/3538) Kueue v1beta2 兼容代码可借鉴的"动态 API 探测"模式
- [ ] [operator#3477](https://github.com/opendatahub-io/opendatahub-operator/pull/3477) Amazon EKS provider:RHAI 在 EKS 上跑通后,作为竞品场景需要重新评估

## 原始材料

<details>
<summary>本窗口内 releases</summary>

- **opendatahub-operator v3.5.0-ea.1** (2026-05-08) — OAI 3.5 EA1 主版本,首次包含 llm-d-inference-scheduler + ogx-k8s-operator + MLflow Operator 1.1.0
- **notebooks v1.44.0** (2026-05-08) — 配套 3.5 EA1
- (boundary)上周 2026-05-04 释出 kserve odh-v3.5-EA1、odh-dashboard v3.4.3-odh、trustyai odh-3.5-ea1、model-registry v0.3.9
</details>

<details>
<summary>Merged PR 计数</summary>

- notebooks: 59(多为 3.5 EA1/EA2 image tag 更新、CI 强化、CodeQL/Semgrep SAST 工作流)
- odh-dashboard: 51
- opendatahub-operator: 20
- kserve(odh-fork): 5
- model-registry: 3
- data-science-pipelines-operator: 1
- trustyai-service-operator: 0
</details>

<details>
<summary>主要 PR 列表(odh-dashboard)</summary>

- #7585 OGX install config path /etc/llama-stack → /etc/ogx
- #7579 完成 LlamaStack→OGX 改名(Cypress/mocked/BFF)
- #7574 task assistant → task shortcuts
- #7548 移除 task-assistant dev feature flag
- #7549 Claude Preflight Agent GitHub Action
- #7586 preflight agent + RBAC review skill
- #7567 MLflow 项目切换 Segment 事件追踪
- #7560 MLflow tracking API 调用加 /mlflow 前缀
- #7521 AutoML/AutoRAG pipeline 3.5 EA1 + 跨 pipeline 版本 runs
- #7501 NeMo Guardrails 接入 View Code(生成 Python 代码)
- #7502 移除 Pre-3.4 MaaS Code
- #7480 MaaS create pages 用 Zod
- #7469 AutoML 列选择自动推断 prediction type
- #7446 MaaS 按 DSC 后端就绪门控
- #7436 NIM Settings Card(项目级 API Key)
- #7433 NIMService 进统一 Deployments 表
- #7429 MCP 部署 Phase → Conditions
- #7403 LlamaStack → OGX 1.0.0 BFF/Frontend 完整迁移
</details>

<details>
<summary>主要 PR 列表(opendatahub-operator)</summary>

- #3543 Add odh-kserve-module-operator
- #3538 Kueue 1.3 v1beta2 支持
- #3535 MaaS:删 maas-controller Deployment + 集群 Config
- #3531 ODH operator LlamaStack 组件改名 OGX
- #3513 Add odh-ogx-k8s-operator
- #3498 HardwareProfile webhook DefaultCount fix
- #3477 Amazon cloud manager provider
- #3379 KServe 加 ModelCache 支持
</details>

<details>
<summary>主要 PR 列表(KServe odh-fork)</summary>

- #1502 master → release-v0.17 sync (2026-05-14)
- #1496 长模型名导致 volume name 超 63 字符修复
- #1480 kserve-module manifest 渲染流水线
</details>
