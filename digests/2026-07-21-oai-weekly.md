# OpenShift AI 周报 2026-07-21

扫描窗口:2026-07-14 → 2026-07-21(过去 7 天),覆盖 opendatahub-io 下 7 个核心仓库。本周非常活跃(operator 33 / dashboard 100 / kserve 61 / notebooks 73 / model-registry 25 / trustyai 9 / dspo 3 提交),三条主线清晰:MaaS 网关成型、KServe 生产级推理发布能力、Agent/GenAI + MLflow 全面内嵌。

## 摘要(3 条)

- **MaaS 收编进 AIGateway 模块**:opendatahub-operator 把 `ModelsAsService` 从独立组件重构为挂在 AIGateway module 之下,配单向 CEL 校验 + admission warning + XKS 平台 overlay。"模型即服务"网关正被做成一等公民平台模块,而非散落的 flag。
- **KServe 补齐两块生产短板**:RawDeployment 模式拿到金丝雀发布(CanarySpec + 零重启晋升 + 聚合 CanaryReady 状态);ServingRuntime 支持 pod 级 DRA `resourceClaims`,补全动态资源分配(GPU/加速器)调度链路。
- **Agent-native + MLflow 内嵌成为新战场**:dashboard 上线 MCP Registry tab、agentOps CRD(Dev Preview);model-registry 长出 Agents Catalog(Gallery / Details / artifacts endpoint);MLflow 从"可选"走向"内嵌"(mlflowPipelines 默认开启、collector→MLflow trace 采集 RBAC、dspo 加 MLflow 集成测试)。

## 新功能 / 能力

### 推理服务(KServe)
- [canary rollout for RawDeployment mode(上游 kserve/kserve #5672)](https://github.com/kserve/kserve/pull/5672) — 新增 `CanarySpec` 列表类型,支持命名金丝雀部署的渐进发布、校验 webhook 强约束、零重启晋升、per-canary 状态 + 聚合 `CanaryReady` 条件。
  - 启示:这是 RawDeployment(非 Serverless/Knative)路径首次拿到原生金丝雀,直接对标我们自研推理平台的灰度发布能力。若我们仍靠外部 Ingress/网格做流量切分,应评估切到 KServe 原生 CanarySpec,减少一层胶水。
- [ServingRuntime pod-level DRA resourceClaims(上游 kserve/kserve #5828)](https://github.com/kserve/kserve/pull/5828) — 之前 ServingRuntime 只能设容器级 `resources.claims`,缺 pod 级 `resourceClaims` 导致 DRA spec 不完整、Pod 无法调度;本 PR 在 `ServingRuntimePodSpec` 补齐并纳入 `MergePodSpec`。
  - 启示:OAI 明确押注 K8s DRA 作为下一代加速器分配范式。我们的 GPU 调度若仍停留在 device-plugin/扩展资源,需要排 DRA 迁移路线,否则与上游 ServingRuntime 生态脱节。
- [model-access aggregate roles for publisher path(kserve odh 分支 #1744)](https://github.com/opendatahub-io/kserve/pull/1744) — 为模型发布路径引入聚合式 model-access RBAC 角色。
  - 启示:多租户下"谁能发布/访问哪个模型"正在被 RBAC 化,是模型生命周期治理的一环,值得对照我们的模型权限模型。
- [CRD 拆分为独立安装 / odh-crds overlay(kserve odh 分支 #1759)](https://github.com/opendatahub-io/kserve/pull/1759)、[restructure CRD management(上游 #5843)](https://github.com/kserve/kserve/pull/5843) — 把 CRD 管理从主 chart 抽出,支持独立安装。
  - 启示:多组件共享 CRD 生命周期的工程化做法,便于 operator 分层升级;我们若把 CRD 和 controller 打包在一起,升级时易冲突,可借鉴此拆分。
- KEDA WVA autoscaling 基础设施进 OpenShift CI([commit e5803e7](https://github.com/opendatahub-io/kserve/commit/e5803e7))、LLMISVC(LLM InferenceService)持续加固(分组停机成员处理、tracing via Jaeger/Helm)。

### 控制台(odh-dashboard)
- [MCP Registry tab(#8616)](https://github.com/opendatahub-io/odh-dashboard/pull/8616) — MCP servers 页新增 MCP Registry 标签(mlflow-embedded 归属)。
- [agentOps CRD + Dev Preview 导航(#8656)](https://github.com/opendatahub-io/odh-dashboard/pull/8656) — Agent 运维对象与列表页/生命周期动作([#8615](https://github.com/opendatahub-io/odh-dashboard/pull/8615))。
  - 启示:dashboard 正在从"模型平台 UI"扩成"Agent 平台 UI"(MCP + agentOps + Gen AI Studio 追踪)。Agent-native 控制面是明确产品方向,我们应尽早定义自己的 Agent/MCP 对象模型,别被上游 CRD 形态锁死。
- [spawner 引用现有 K8s Secret 作环境变量(#8564)](https://github.com/opendatahub-io/odh-dashboard/pull/8564) — workbench 可直接引用集群内 Secret 注入环境变量,免手工复制凭据。
- [roleManagement 提级 tech preview(#8647)](https://github.com/opendatahub-io/odh-dashboard/pull/8647)、[Enable mlflowPipelines feature flag by default(#8519)](https://github.com/opendatahub-io/odh-dashboard/pull/8519)。
- AutoX 套件(AutoML / AutoRAG)本周大量 UI 投入:混淆矩阵重设计 + 多选回测指标([#8652](https://github.com/opendatahub-io/odh-dashboard/pull/8652))、从 AutoRAG/AutoML 运行列表启用托管 pipeline([#8425](https://github.com/opendatahub-io/odh-dashboard/pull/8425))、leaderboard 列重排/预设、pipeline 可视化增强。
  - 启示:OAI 在做面向业务用户的"自动化 RAG/ML"低代码层(AutoX),这是往上层应用体验走。若我们只做底座,需想清楚是接入还是自建这层。

### 模型 / Agent 注册(model-registry)
- Agents Catalog 落地:[Gallery + Filters(commit 859284b)](https://github.com/opendatahub-io/model-registry/commit/859284b)、[Agent Details page(commit 9c58e84)](https://github.com/opendatahub-io/model-registry/commit/9c58e84)、artifacts endpoint 与详情路由。
  - 启示:model-registry 正从"模型注册中心"扩展为"模型 + Agent 目录"。我们的注册中心若只存模型元数据,应预留 Agent/工具目录的抽象。
- 安全加固:[CSI artifact URI 白名单 + 云元数据(169.254.x)黑名单(commit 27cb0f4)](https://github.com/opendatahub-io/model-registry/commit/27cb0f4)、[CORS 默认关闭(commit 719c924)](https://github.com/opendatahub-io/model-registry/commit/719c924)、[BFF 用 SAR 授权而非要求 namespace 相等(commit 30081dc)](https://github.com/opendatahub-io/model-registry/commit/30081dc)。
  - 启示:artifact 拉取的 SSRF/云元数据防护(封 169.254.169.254)是模型供应链安全的实操点,建议直接抄进我们的 artifact 拉取器。

### 可信 AI / 评估(trustyai)
- evalhub(LM 评估组件)持续成型:[从上游同步 provider/collection ConfigMap(#827)](https://github.com/opendatahub-io/trustyai-service-operator/pull/827)、健康探针改走 kube-rbac-proxy/内部端口、[检测因缺 PVC 卡 Pending 的 job 并标记 FAILED(#819)](https://github.com/opendatahub-io/trustyai-service-operator/pull/819)。
  - 启示:TrustyAI 在补一个托管式 LLM 评估中心(evalhub),对标我们做模型评测/守护栏的能力。

### 工作台(notebooks)
- [Integrate Kale into Notebooks(#3677)](https://github.com/opendatahub-io/notebooks/pull/3677) — 把 Kubeflow 生态的 Kale(notebook→pipeline 转换)集成进工作台镜像。
- [Release v1.46.0(2026-07-17)](https://github.com/opendatahub-io/notebooks/releases/tag/v1.46.0) — 本周唯一正式 release,主要是 base image / konflux / lockfile / CVE 治理,无用户可见新特性(注:随后 revert 回 EA2 版本线)。

## 架构 / 依赖变化

- **MaaS → AIGateway module 化**:[nest MaaS under AIGateway module(commit bfc494d)](https://github.com/opendatahub-io/opendatahub-operator/commit/bfc494d)、[one-directional CEL + admission warning for kserve.modelsAsService(commit d9eed51)](https://github.com/opendatahub-io/opendatahub-operator/commit/d9eed51)、[XKS platform overlay for AIGateway(#3825)](https://github.com/opendatahub-io/opendatahub-operator/pull/3825)、[forward platform-type to module operator deployments(#3814)](https://github.com/opendatahub-io/opendatahub-operator/pull/3814)。operator 走 "module operator" 模式,把平台类型下发给各 module,MaaS 成为其一。
- **监控/追踪管道对接 MLflow**:[collector→MLflow ClusterRole/Binding for trace ingestion(#3719)](https://github.com/opendatahub-io/opendatahub-operator/pull/3719) —— OpenTelemetry collector 直接把 trace 灌进 MLflow,配合 dashboard mlflowPipelines 默认开、dspo MLflow 集成测试,MLflow 正被做成 OAI 的实验/追踪/pipeline 一体后端。
- **供应链/校验**:[排除 SBOM metadata env vars 并引入 rhoai_exceptions 机制(#3827)](https://github.com/opendatahub-io/opendatahub-operator/pull/3827)、[migrate remaining checkPreConditions to WithPreCondition 框架(#3707)](https://github.com/opendatahub-io/opendatahub-operator/pull/3707)。
- **notebooks 构建**:base image 改由 `versions_config.yml` 驱动、konflux 引用更新、rpms.lock 自动化 —— 纯构建供应链工程,无功能面变化。

## 上游生态整合动向

- **KServe(核心上游)**:本周两大能力(RawDeployment 金丝雀、pod 级 DRA)均先落上游 kserve/kserve,再 cherry-pick 到 opendatahub-io/kserve 分支。DRA + KEDA WVA 表明 OAI 推理层在贴 K8s 1.34+ 的动态资源/事件驱动扩缩范式。
- **Kubeflow**:Kale 集成进 notebooks,继续吃 Kubeflow 生态的 notebook→pipeline 工具链。
- **MLflow**:从"可选组件"转向"内嵌后端"(embedded),覆盖 pipeline、trace、MCP registry 多处。这是本周相对新的方向,值得单列跟踪。
- **MCP / Agent 协议**:dashboard MCP Registry + agentOps CRD + model-registry Agents Catalog,三仓联动铺 Agent-native 控制面。

## 值得跟进

- [ ] 读透 [kserve/kserve #5672(RawDeployment canary)](https://github.com/kserve/kserve/pull/5672):对比我们现有灰度方案,评估直接采用 CanarySpec 的可行性与迁移成本。
- [ ] 评估 [kserve/kserve #5828(pod-level DRA)](https://github.com/kserve/kserve/pull/5828) 与 K8s DRA GA 路线,排我们 GPU 分配从 device-plugin → DRA 的迁移计划。
- [ ] 抄安全实践:model-registry 的 [artifact URI 白名单 + 云元数据黑名单(commit 27cb0f4)](https://github.com/opendatahub-io/model-registry/commit/27cb0f4),直接用于我们 artifact/模型拉取器防 SSRF。
- [ ] 跟踪 MLflow 内嵌进度:确认 OAI 是否用 MLflow 取代/并存 data-science-pipelines 的实验追踪,决定我们注册中心 + pipeline 的 MLflow 兼容策略。
- [ ] 定义我们自己的 Agent/MCP 对象模型:观察 dashboard agentOps CRD([#8656](https://github.com/opendatahub-io/odh-dashboard/pull/8656))与 model-registry Agents Catalog 的 schema 走向,避免后续被上游形态绑架。

## 原始材料(折叠)

<details>
<summary>本周扫描的提交/PR/release 清单</summary>

提交计数(since 2026-07-14):opendatahub-operator 33 / odh-dashboard 100 / kserve 61 / notebooks 73 / model-registry 25 / trustyai-service-operator 9 / data-science-pipelines-operator 3。

Release(7 天内):notebooks [v1.46.0(2026-07-17)](https://github.com/opendatahub-io/notebooks/releases/tag/v1.46.0);其余仓库最新 release 均早于本窗口(operator v3.5.0-ea.2 / dashboard v3.4.4-odh / kserve v3.5.0+rhaiv.0 / model-registry v0.3.10 / trustyai odh-3.5-ea2,均 6 月),即本周无新版本切出。

关键 PR / commit:
- opendatahub-operator:#3827 SBOM+rhoai_exceptions / #3825 XKS overlay / #3814 platform-type 下发 / #3719 collector→MLflow trace / #3707 WithPreCondition 迁移;commit bfc494d(MaaS nest AIGateway)、d9eed51(CEL modelsAsService)。
- odh-dashboard:#8616 MCP Registry / #8656 agentOps CRD / #8647 roleManagement tech preview / #8564 spawner 引用 Secret / #8519 mlflowPipelines 默认开 / #8425 托管 pipeline from AutoX / #8652 混淆矩阵重设计。
- kserve:上游 kserve/kserve #5672(canary RawDeployment)、#5828(pod-level DRA)、#5843(CRD 重构);odh 分支 #1759 odh-crds overlay / #1744 model-access roles / #1763 LLMISVCConfig 解耦。
- model-registry:commit 859284b(Agents Gallery)、9c58e84(Agent Details)、27cb0f4(CSI URI 白名单 + 云元数据黑名单)、719c924(CORS 默认关)、30081dc(BFF SAR 授权)。
- trustyai:#827 evalhub configmap 同步 / #828 webhook guard / #819 缺 PVC job 标 FAILED。
- notebooks:#3677 Kale 集成;v1.46.0(随后 revert 回 EA2 版本线)。
- data-science-pipelines-operator:MLflow 集成测试 + TLS profile IsServerTimeout 处理(commit 14b4881)。

</details>
