# OpenShift AI 周报 2026-04-16

窗口:2026-04-01 → 2026-04-15(首次运行,14 天)
扫描范围:opendatahub-io 组织下 7 个核心仓库(opendatahub-operator / odh-dashboard / kserve / notebooks / data-science-pipelines-operator / model-registry / trustyai-service-operator)

## 摘要

- **v3.4.0 发版(2026-04-08)**:这是包含 MaaS(Models-as-a-Service)、Kubeflow Trainer、Feast 整合的重大版本,标志 OAI 从"平台"向"服务"转型。见 [opendatahub-operator v3.4.0](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0)。
- **MaaS 首次变成 GA 级特性**:订阅模型、API Key、用量配额、鉴权策略完整成套上线,`models-as-a-service` 独立仓库发布 v0.1.0,Dashboard 默认开启 MaaS 功能开关。这是典型"把开源推理栈封装成 OpenAI-like 产品"的路线,值得重点对标。
- **LLM 推理重心从 KServe 扩展到 `LLMInferenceService` + llm-d + vLLM**:LLM-D 升级到 0.6.0,vLLM 0.17.1,支持 OpenAI `/v1/responses` API、Intel Gaudi、LWS 多节点(去 Ray 化),这套组合正在成为 OAI 对标 NVIDIA NIM / Nebius / Together 的主力。

## 新功能 / 能力

### MaaS(Models-as-a-Service)—— 最值得重点关注
- [`feat(maas): add ubi-minimal image for api-key cleanup cronjob`](https://github.com/opendatahub-io/opendatahub-operator/pull/3430)、[`feat: deploy MaaS dashboard(s)`](https://github.com/opendatahub-io/opendatahub-operator/pull/3381)、[`feat: prerequisite validation for MaaS operator reconciliation`](https://github.com/opendatahub-io/opendatahub-operator/pull/3376) —— MaaS operator 被拉进 OAI 主线,成为受管组件。
- [`Turn on MaaS feature flags by default`](https://github.com/opendatahub-io/odh-dashboard/pull/7217) —— Dashboard 里 MaaS 不再是隐藏实验特性。
- [`feat(maas): add phase column to subscription and auth policy tables`](https://github.com/opendatahub-io/odh-dashboard/pull/7197)、[`Make MaaS UI rely on ModelAsServiceReady condition`](https://github.com/opendatahub-io/odh-dashboard/pull/7236)、[`Add vLLMDeploymentOnMaaS to crd`](https://github.com/opendatahub-io/odh-dashboard/pull/7100) —— 订阅生命周期、vLLM 挂载到 MaaS 的 CRD 链路完整化。
- 启示:**MaaS 不是"一个新功能",是整个产品形态的演进方向**。如果你们产品目前还停在"平台给客户部署 KServe"的阶段,OAI 已经再往前一步做"平台直接卖模型订阅/API key/quota"。需要评估自家产品有无必要跟进,以及差异化切入点(私有化合规、国产芯片、按集群/按调用定价模型等)。

### LLM 推理栈
- [`feat(llmisvc): enable LWS as autoscaling target for multi-node workloads`](https://github.com/opendatahub-io/kserve/pull/5356)、[`feat(multinode): add groundwork for multinode support without ray`](https://github.com/opendatahub-io/kserve/pull/1390) —— **去 Ray 化**,改用 Kubernetes 原生 LeaderWorkerSet(LWS)+ 自研 LLMInferenceService CRD 承载多节点推理。
- [`chore: upgrade vLLM to 0.17.1`](https://github.com/opendatahub-io/kserve/pull/5338)、[`fix(llmisvc): upgrading to LLM-D v0.6.0`](https://github.com/opendatahub-io/kserve/pull/5346) —— vLLM/LLM-D 跟版非常紧。
- [`feat: add /v1/responses HTTPRoute for OpenAI Responses API`](https://github.com/opendatahub-io/kserve/pull/5291) —— 原生对接 **OpenAI Responses API**,意味着 OAI 推理出来的模型可以被各种按 OpenAI 协议开发的前端直接接入,兼容性战略。
- [`feat(llmisvc): add Intel Gaudi accelerator LLMInferenceServiceConfig`](https://github.com/opendatahub-io/kserve/pull/1331)、[`Add Intel Gaudi vLLM image override support for KServe`](https://github.com/opendatahub-io/opendatahub-operator/pull/3370) —— 非 NVIDIA 加速器(Gaudi)的一等支持开始成形。
- 启示:**LLMInferenceService(llmisvc)正在从 KServe 的一个 CRD 变成独立产品**,涵盖多节点、多后端、多加速器。如果你们想做推理平台,应考虑:① 是否跟进 LLMInferenceService CRD 以复用生态;② 国产加速器(昇腾/寒武纪/海光)的 plugin 模式可以参考 Gaudi 接入方式;③ OpenAI 协议兼容已经是事实标准。

### MCP(Model Context Protocol)
- Operator 侧:[`MCP Server Scaffold and Platform_health Tool`](https://github.com/opendatahub-io/opendatahub-operator/pull/3393)、[`Added classify_failure and component_status MCP tools`](https://github.com/opendatahub-io/opendatahub-operator/pull/3398)、[`Added pod_logs tool`](https://github.com/opendatahub-io/opendatahub-operator/pull/3404)、[`Add recent_events tool`](https://github.com/opendatahub-io/opendatahub-operator/pull/3416)、[`operator_dependency and describe_resource MCP tools`](https://github.com/opendatahub-io/opendatahub-operator/pull/3427)。
- Model Registry 侧:MCP Catalog + MCP server 分页、endpoint 管理、鉴权(`fix(model-registry): scope in-cluster K8s client to SAR-only interface`)。
- 启示:**OAI 正在把 operator 本身变成 MCP Server**,让运维 agent(Claude / Cursor 等)能直接用 MCP 工具诊断/调参。这是一条"AI 原生运维"的路线,你们产品如果有类似诉求可以直接参考他们的 MCP tool 设计。

### AutoML / AutoRAG / EvalHub —— 产品线在拓宽
- AutoML:leaderboard 排名、负向指标、预测类型列、AutoML Save as 下拉(模型注册/Notebook/Pipeline 多态保存)
- AutoRAG:Llama Stack 连接模态框、topology 节点自适应长 label、S3 文件浏览器、Eval 模板
- EvalHub(TrustyAI):Garak benchmark(LLM 红队/越狱测试)、lm-evaluation-harness 内存调优、IBM CLEAR 作为 provider、primary_score/pass_criteria 标准化
- 启示:**OAI 从"训练+推理"延伸到了"自动化 + 评估"**。特别是 **Garak + lm-eval-harness 组合**已经成为 LLM 安全/质量度量的事实栈,做 AI 基础设施绕不开。

### 可观测性
- [`fetch all perses dashboards`](https://github.com/opendatahub-io/odh-dashboard/pull/6870)、[`feat(auth): add admin RBAC roles for Perses access`](https://github.com/opendatahub-io/opendatahub-operator/pull/3339) —— **Perses(CNCF)** 作为下一代仪表盘被全面接入,逐步替换 Grafana 定位。
- [`feat(modelsasservice): add deployment-based observability toggle`](https://github.com/opendatahub-io/opendatahub-operator/pull/3374) —— 可观测性可按组件粒度开关,节省资源。

## 架构 / 依赖变化

- **Gateway API 成为主网关**:`Gateway release`、`vLLMDeploymentOnMaaS` CRD 通过 Gateway / HTTPRoute 暴露;KServe 代码已经有 `DisableHTTPRouteTimeout` 这种 GKE Gateway 特定 flag,说明多云 Gateway 实现适配在做。
- **ExternalOIDC 支持**:[`feat: adding ExternalOIDC support`](https://github.com/opendatahub-io/opendatahub-operator/pull/3362) —— 企业级 IdP(Okta/Azure AD/Keycloak)整合,不再强绑 OpenShift OAuth。对我们做私有化/多租户很有参考价值。
- **多集群 / CloudManager**:[`cloud-manager: add configurable namespaces for dependency operators`](https://github.com/opendatahub-io/opendatahub-operator/pull/3402)、`rename resources to rhai/rhaii for cloudmanager`、`RBAC 自动化` —— "cloud manager"出现频率很高,暗示他们在把 OAI 管理面抽到跨集群管理平面(`xks` 命名)。值得盯。
- **Distro build tags**:KServe 大量 PR 把 "OpenShift 专属代码"用 Go build tag 隔离(`manager_options_ocp.go`、`OpenShift Route and CRB management behind distro build tags`)。含义:**他们在为 OAI 能部署到非 OCP(原生 K8s / EKS / AKS / 自建)做铺垫**,降低对 OpenShift 的耦合。
- **Konflux + Hermetic Builds**:Jupyter notebooks 大量 "Hermetic build" PR(CUDA/ROCm/TensorFlow/PyTorch/TrustyAI),这是 Red Hat Konflux(基于 Tekton)的隔离构建体系,供应链安全(SLSA)方向。
- **managed pipelines**(DSP operator):整个一簇 PR 做"从 OCI registry 拉取受管流水线 + 校验 + 缓存 + 白名单 + 透明错误处理"。这是一个独立的**受管流水线分发机制**,值得看看是不是 OAI 在做"官方 pipeline 商店"。

## 上游生态整合动向

- **KServe**:上游 kserve:master 持续 sync 到 opendatahub-io/kserve(`Sync upstream master into odh master partN`),OAI 一直紧跟上游,同时把 OCP 特定代码隔离出来。
- **Kubeflow Model Registry**:opendatahub-io/model-registry 几乎每两天从 kubeflow:main 拉一次(`pull main from kubeflow:main`),差不多就是 Kubeflow 上游的"下游定制版"。
- **Kubeflow Trainer (KFP v2)**:opendatahub-io/trainer 随 v3.4 发布 odh-3.4.0 版本,KFP 升到 2.16.0。
- **Feast**:0.62.0 升级(notebooks #3368),OAI 把 Feast 完整 bundle 到工作台镜像里。
- **vLLM / LLM-D**:vLLM 0.17.1、LLM-D 0.6.0、llm-d-kv-cache v0.7.1 —— 三件套协同升级,节奏极紧。
- **llama-stack**:AutoRAG 支持 Llama Stack 连接(#7237),值得观察 OAI 是把 Llama Stack 当"运行时"还是"协议"。
- **Trusty AI / trustyai-explainability**:opendatahub-io/trustyai-service-operator 与 trustyai-explainability 上游完全联动,Garak/EvalHub 是 upstream 路线。

## 值得跟进

- [ ] **精读 MaaS 仓库**:`opendatahub-io/models-as-a-service` v0.1.0 源码 + `vLLMDeploymentOnMaaS` CRD 定义。理解订阅、限流、鉴权、计量的实现边界。
- [ ] **跑通 LLMInferenceService + LWS 多节点推理**:看一下 [PR #5356](https://github.com/opendatahub-io/kserve/pull/5356) 和 [PR #5366](https://github.com/opendatahub-io/kserve/pull/5366) 的去 Ray 化方案,是否适合你们产品。
- [ ] **体验 operator MCP server**:clone 一份 opendatahub-operator,跑起来 MCP Server 感受一下"AI 运维"体验。
- [ ] **评估 Perses 作为仪表盘**:我们产品是否可以跳过 Grafana 直接上 Perses。
- [ ] **ExternalOIDC PR #3362 阅读**:对接企业 IdP 的最佳实践。
- [ ] **关注 cloudmanager/xks 命名变化**:下一周再看时重点追这条线,可能是重大架构调整的前奏。
- [ ] **查 Red Hat 官方 OpenShift AI 2.22 / 2.23 release notes**:确认商业版发布节奏是否跟随 ODH v3.4。

## 原始材料

本次扫描命中的核心 PR 数量(仅列 merged/open 合计):
- opendatahub-operator:~50 PRs
- odh-dashboard:~80 PRs(活跃度最高)
- kserve:~50 PRs
- notebooks:~40 PRs
- data-science-pipelines-operator:~20 PRs
- model-registry:~60 PRs
- trustyai-service-operator:~35 PRs

原始 JSON 归档于 `/tmp/ai-radar-raw/`(下次运行会覆盖;正式环境下请移到归档目录保留)。
