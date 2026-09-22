# OpenShift AI 周报 2026-09-22

窗口:2026-09-15 -> 2026-09-22(7 天)

## 摘要(3 条以内)
- OAI 3.6 EA2 全家桶落地:opendatahub-operator v3.6.0-ea.2 作为伞状 release 钉住了 Trainer/OGX/llm-d/KServe/TrustyAI/Dashboard/Model Registry 等 20+ 组件版本,主线仍是平台组件持续 module 化 + KServe/llm-d 观测与 Kueue 控制面进入发行物。
- 安全与治理是本轮明显重心:TrustyAI EA2 把 NeMo Guardrails 与 MCP Guardrails 做成可开关的平台模块,ODH Operator 拒绝空 strict TLS cipher、并支持在 vanilla Kubernetes(XKS)上部署 Gateway,KServe 的 workload TLS profile 则合入后又整体回滚。
- 产品面继续围绕控制台与工作台补齐:Dashboard 接入私有 Hugging Face 模型、External Models、AutoRAG、Kueue tracking;Notebooks v1.49.0 用 ODH Kale 替换 Kubeflow Kale,并把 CUDA/ROCm base 切到 midstream、推进 hermetic 构建。

## 新功能 / 能力

- [opendatahub-operator v3.6.0-ea.2](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.6.0-ea.2) — 3.6 EA2 伞状 release,release note 逐一钉住各组件版本(Trainer odh-3.6.0-ea2、OGX、llm-d-router odh-v3.6-ea2、TrustyAI odh-3.6-ea2、Dashboard v3.6.0-ea2-odh、Model Registry v0.3.17、DSP v2.18.0、KubeRay v1.6.2、Feast v0.66.0 等)。
  - 启示:OAI 的版本管理是"平台 operator 用一份 release note 固定所有组件镜像/manifest SHA"。我们做多组件 AI 平台时,应把组件版本矩阵作为一等交付物,让一次平台升级对应一份可审计的组件清单,而不是各组件各自发版。
- [TrustyAI odh-3.6-ea2](https://github.com/opendatahub-io/trustyai-service-operator/releases/tag/odh-3.6-ea2) — 本轮把安全护栏做成平台能力:支持 [MCP Guardrails 模式](https://github.com/opendatahub-io/trustyai-service-operator/commit/3d71693)、[可开关 NeMo Guardrails 外部路由](https://github.com/opendatahub-io/trustyai-service-operator/commit/bc112d3)、[默认 NeMo Guardrails 配置](https://github.com/opendatahub-io/trustyai-service-operator/commit/cf40d13),并把 TrustyAI 自身重构成 operator module。
  - 启示:护栏(输入/输出内容安全)正从"应用层自己接"上升为"平台内置、可声明式开关"的模块。我们做推理平台要把 guardrails 当成可挂载到 InferenceService 的一等策略资源,支持 NeMo/MCP 这类外部 guard 服务的路由与开关,而不是让每个业务自己接内容审核。
- [ODH Dashboard v3.6.0-ea2-odh](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.6.0-ea2-odh) — EA2 release note 明确新增 Private Hugging Face models in Model catalog and model deployments。
  - 启示:模型目录不再只是公共 catalog,开始承载私有模型源、凭据和部署入口。我们做模型目录时要把 registry secret、模型许可、runtime 兼容性和部署模板绑定成一个流程。
- [ODH Operator PR #4089](https://github.com/opendatahub-io/opendatahub-operator/pull/4089) — 实现 AIPipelines module handler,注册为 platform module runlevel 20,并将 `spec.components.aipipelines` 翻译到 module API。
  - 启示:OAI 继续把核心能力迁入 module 生命周期。我们的平台 operator 也应把 pipeline、serving、registry、dashboard 拆成可独立启停、独立状态汇总的组件,而不是一个总 reconcile。
- [ODH Dashboard PR #9840](https://github.com/opendatahub-io/odh-dashboard/pull/9840) — 增加 Kueue deployment tracking。
  - 启示:队列/批调度已经从后端基础设施进入 AI 平台可见层。用户需要在控制台看到队列启用状态、作业是否被 Kueue 管理、为什么 Pending。
- [ODH Dashboard PR #9769](https://github.com/opendatahub-io/odh-dashboard/pull/9769) — 更新 External Models CRUD 文案。
  - 启示:External Models 已经是 MaaS/AI Gateway 产品面的一部分。我们需要把外部模型的 endpoint、auth、配额、审计和失败诊断做成一等资源,而不是只让用户填 URL。
- [ODH Dashboard PR #9857](https://github.com/opendatahub-io/odh-dashboard/pull/9857) — 修复 AutoRAG pattern detail 中 Sample Q&A 页面在生产镜像的崩溃。
  - 启示:RAG pattern 进入控制台后,样例问答、索引状态、评估结果是用户验收路径。AutoRAG 不能只生成资源,还要把运行结果稳定展示出来。

## 架构 / 依赖变化

- [ODH Operator PR #3995](https://github.com/opendatahub-io/opendatahub-operator/pull/3995) — 支持在 vanilla Kubernetes(XKS)上部署 Gateway:新增 XKS 专用的 gateway namespace/name/controller 与 Istio revision 值,在非 OpenShift 集群强制要求显式 `spec.domain`,缺失时干净停止 reconcile 而非报错,并跳过 OpenShift 专有资源。
  - 启示:OAI 正在把控制面从"必须跑在 OpenShift"往"能跑在原生 K8s"松绑,代价是把 OpenShift 隐式提供的能力(域名、Istio revision、Route)显式化为配置。我们如果要做跨发行版可移植,必须先盘点对底座的隐式依赖并让它们变成可声明的输入。
- [ODH KServe odh-v3.6-ea2](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.6-ea2) — release 包含 kserve-kueue controller Dockerfile、module platformVersion transition/webhook contract 测试、Prometheus metrics scraping NetworkPolicy。
  - 启示:KServe module 正在补齐平台版本感知、webhook 启用校验、Kueue 控制器镜像和用户命名空间监控权限。我们的模型服务组件也要把调度、观测、webhook readiness 做成 release gate。
- [ODH Operator PR #4115](https://github.com/opendatahub-io/opendatahub-operator/pull/4115) — strict TLS profile 转换时拒绝空或不可用 cipher list,避免回落到 Go 默认值。
  - 启示:安全 profile 的失败模式必须显式 fail closed。企业平台不要在"用户给了严格策略但解析为空"时静默降级。
- [ODH KServe PR #1969](https://github.com/opendatahub-io/kserve/pull/1969) 与 [#2038](https://github.com/opendatahub-io/kserve/pull/2038) — LLMISVC / InferenceService workload TLS profile 配置先合入后整体回滚。
  - 启示:OpenShift TLS security profile 下沉到 workload 是正确方向,但会触碰 runtime 兼容性、mesh/gateway、模板复杂度。我们推进 TLS 策略继承时要先做 runtime 矩阵和回滚开关。

## 上游生态整合动向

- [ODH Notebooks v1.49.0](https://github.com/opendatahub-io/notebooks/releases/tag/v1.49.0) — 用 [ODH Kale 替换 Kubeflow Kale](https://github.com/opendatahub-io/notebooks/pull/4400),CUDA/ROCm base 镜像切到 midstream(#3678),推进 hermetic 构建与 codeserver-baseline 加固,并新增 fix-cve wrapper skills for Claude Code。
  - 启示:OAI 在工作台层把上游包 fork/内制化(ODH Kale)、并把基础镜像收敛到自控 midstream + hermetic,以掌握 CVE 与供应链。我们做 workbench 镜像也要有 base 镜像自控与 hermetic 构建路线,否则每个 CVE 都得等上游。
- [ODH KServe PR #2030](https://github.com/opendatahub-io/kserve/pull/2030) 与 [#2027](https://github.com/opendatahub-io/kserve/pull/2027) — llm-d dashboard 对齐 `llm_d_epp_*` 指标名,并增加 EPP scheduling latency panel。
  - 启示:LLM-D 的 EPP 调度开销已经进入 OAI/KServe 观测面。我们做推理路由时要暴露 router/EPP 自身延迟,否则用户只看到模型延迟,定位不到调度瓶颈。
- [ODH KServe PR #1992](https://github.com/opendatahub-io/kserve/pull/1992) — per-pod dashboard 查询按 namespace 分组。
  - 启示:多租户观测必须先按 namespace/project 隔离,否则同名 pod 或跨租户查询会让控制台指标失真。
- [ODH Model Registry v0.3.17](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.17) — 跟随 Kubeflow Model Registry v0.3.17,通过 Tekton pipelines 交付。
  - 启示:OAI 的 registry 仍然贴近上游 Kubeflow,但通过 Tekton pipeline release 交付。我们需要明确 registry server、Python client、pipeline 组件的版本矩阵。

## 值得跟进
- [ ] 精读 TrustyAI odh-3.6-ea2 的 NeMo/MCP Guardrails module 设计,评估把 guardrails 做成挂到 InferenceService 的声明式策略资源的可行性与 API 形态。
- [ ] 跟踪 opendatahub-operator XKS(vanilla K8s)gateway 路径,盘点我们控制面对 OpenShift 的隐式依赖(Route/Istio revision/域名),定义可移植的显式配置。
- [ ] 跟踪 OAI 3.6 EA2 到 GA 的 module handler 覆盖面,重点看 AIPipelines、KServe、Dashboard、Model Registry、TrustyAI 的 status/API 是否稳定。
- [ ] 对比 OAI strict TLS fail-closed 与 KServe workload TLS rollback,定义我们自己的 TLS profile 下沉策略和 runtime 兼容矩阵。
- [ ] 评估 Notebooks 的 midstream base + hermetic 构建路线,对照我们 workbench 镜像的 CVE 响应速度与供应链自控程度。

## 原始材料

<details>
<summary>本次扫描清单(GITHUB_TOKEN 已生效,认证 API,余量 5000/h)</summary>

各仓库过去 7 天提交数:opendatahub-operator 20、odh-dashboard 100+、kserve 100+、notebooks 100+、model-registry 34、trustyai-service-operator 23、data-science-pipelines-operator 0(最近 release v2.18.0 于 2025-11)。

- https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.6.0-ea.2
- https://github.com/opendatahub-io/opendatahub-operator/pull/3995
- https://github.com/opendatahub-io/opendatahub-operator/pull/4089
- https://github.com/opendatahub-io/opendatahub-operator/pull/4115
- https://github.com/opendatahub-io/trustyai-service-operator/releases/tag/odh-3.6-ea2
- https://github.com/opendatahub-io/trustyai-service-operator/commit/3d71693
- https://github.com/opendatahub-io/trustyai-service-operator/commit/bc112d3
- https://github.com/opendatahub-io/trustyai-service-operator/commit/cf40d13
- https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.6.0-ea2-odh
- https://github.com/opendatahub-io/odh-dashboard/pull/9840
- https://github.com/opendatahub-io/odh-dashboard/pull/9769
- https://github.com/opendatahub-io/odh-dashboard/pull/9857
- https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.6-ea2
- https://github.com/opendatahub-io/kserve/pull/1969
- https://github.com/opendatahub-io/kserve/pull/2038
- https://github.com/opendatahub-io/kserve/pull/2030
- https://github.com/opendatahub-io/kserve/pull/2027
- https://github.com/opendatahub-io/kserve/pull/1992
- https://github.com/opendatahub-io/notebooks/releases/tag/v1.49.0
- https://github.com/opendatahub-io/notebooks/pull/4400
- https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.17
</details>
