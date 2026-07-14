# OpenShift AI 周报 2026-07-14

窗口:2026-07-07 -> 2026-07-14(7 天,重点是 07-13 周报之后新落地的项)

## 摘要(3 条以内)
- Agent/MCP 从"演示入口"正式进入平台治理面:odh-dashboard 的 agent-ops 改用 `agents.x-k8s.io/v1beta1` Sandbox CR 做发现,`agentsCatalog` flag 接上 kubeflow/hub agents 目录,配套 stop/start/DELETE BFF;operator 侧把 MCPLifecycleOperator 收成一个 ODH module(带 PrometheusRules 告警),并把 ODH MCP server 的通用工具改为委托 Red Hat OpenShift MCP server(read-only)。
- 硬件加速器预设与运行时版本被产品化:Dashboard 给 "LLM accelerator configurations" 补齐 create/edit/duplicate/delete,KServe overlay 给 LLMInferenceServiceConfig presets 打 `opendatahub.io/runtime-version` / fast-version 注解并加 CI 断言;同时 MaaS 侧起了 External Models(scaffolding + BFF list/delete MVP)。
- 离线与合规继续被当成一等工程:notebooks / DSP / trustyai 三仓同步落 "disconnected readiness workflow",operator 修 gateway fallback 镜像 `:latest` 打断断网部署的问题,DSP 做 TLS profile 自愈。上游 KServe 主线是 LLMISVC 流量切分 API 与 KV cache 多层文件系统卸载。

## 新功能 / 能力

- [ODH Dashboard PR #8493](https://github.com/opendatahub-io/odh-dashboard/pull/8493) — agent-ops 的 list/detail 发现从扫 Deployment/StatefulSet/Job 改为只读 `agents.x-k8s.io/v1beta1/sandboxes` CR,解决部署后 detail 404,并按双 selector 去重。
  - 启示:Agent 运行实例应有独立 CR(Sandbox)作为控制面对象,而不是靠猜工作负载类型来反查。我们做 Agent 托管时,list/detail/生命周期都应绑一个显式 CR + SSAR 权限校验,否则发现逻辑会随部署方式漂移。
- [ODH Dashboard PR #8422](https://github.com/opendatahub-io/odh-dashboard/pull/8422) — 新增 `agentsCatalog` feature flag,在 AI hub > Agents 下渲染上游 [kubeflow/hub#2908](https://github.com/kubeflow/hub/pull/2908) 的 agents catalog。配套 [#8343](https://github.com/opendatahub-io/odh-dashboard/pull/8343)(DELETE agent BFF)、[#8345](https://github.com/opendatahub-io/odh-dashboard/pull/8345)(stop/start agent BFF)、[#8442](https://github.com/opendatahub-io/odh-dashboard/pull/8442)(MCP catalog 设置接入 nav)。
  - 启示:OAI 的 Agent 战略是"目录(catalog)+ 生命周期(stop/start/delete)+ MCP 工具治理"三件套,而且目录直接复用 model-registry/hub 上游。我们如果要做 Agent hub,不要自造目录模型,应对齐 kubeflow/hub 的 catalog 抽象,把 Agent、MCP server、模型注册中心放同一个发现面。
- [ODH Operator PR #3676](https://github.com/opendatahub-io/opendatahub-operator/pull/3676) — MCPLifecycleOperator 作为 ODH module 集成:API types(CommonSpec/Status + DSC 嵌入)、module handler(DSC/Platform 双模式)、PrometheusRules 告警模板 + 单测。
  - 启示:MCP server 的生命周期(安装、状态、告警)已经进入 operator 一等治理,不再是 sidecar。我们把 MCP/工具服务纳入平台时,要有 module API、status、告警规则,而不是只给一个 Deployment。
- [ODH Operator PR #3737](https://github.com/opendatahub-io/opendatahub-operator/pull/3737) — ODH MCP server 里的通用 `describe_resource`/`pod_logs` 换成 Red Hat OpenShift MCP server 的 `resources_get`/`pods_log`(以 `--read-only --toolsets core` 加进 .mcp.json),仅保留带 DSCI 命名空间自动发现的 ODH 专属 `recent_events`。
  - 启示:Red Hat 在收敛 MCP 工具到官方 OpenShift MCP server,自研只留真正差异化(命名空间自动发现)。我们做集群运维类 MCP 工具时,通用只读能力应复用平台官方 server 并强制 read-only,自研聚焦领域上下文,别重复造 `get/logs`。
- [ODH Dashboard PR #8485](https://github.com/opendatahub-io/odh-dashboard/pull/8485) — LLM accelerator configurations 管理页补齐 create/edit/duplicate/delete,version 字段映射到 `opendatahub.io/runtime-version` 注解,内嵌 ConfigYAMLEditor;配 [#8472](https://github.com/opendatahub-io/odh-dashboard/pull/8472) 的 enabled toggle 与"未支持接受"流程。
  - 启示:加速器/运行时预设正在变成有增删改查和启停状态的一等资源。我们的硬件 profile 不应只是只读枚举,要支持复制改配、版本注解、启用开关和"未验证组合需显式接受"的合规护栏。
- [ODH Dashboard PR #8471](https://github.com/opendatahub-io/odh-dashboard/pull/8471) 与 [#8478](https://github.com/opendatahub-io/odh-dashboard/pull/8478) — MaaS 引入 External Models(移除 policies flag,加外部模型 scaffolding),BFF 起 external models list MVP(namespaces + list/delete)。
  - 启示:MaaS 目录开始纳管"不在本集群里跑"的外部模型端点。我们做模型目录/网关时要预留 external model 这类只有元数据+路由、无本地工作负载的条目,并把它和自托管模型统一在一个订阅/计费视图里。
- [ODH Dashboard PR #8263](https://github.com/opendatahub-io/odh-dashboard/pull/8263) — AutoML 分类模型增加 ROC 与 precision-recall 曲线图。
  - 启示:OAI 的 AutoML/AutoRAG 在补齐评估可视化。我们若做 AutoML,评估指标(ROC/PR/leaderboard)要作为标准产出,而不是只给一个最优模型。

## 架构 / 依赖变化

- [ODH Operator PR #3576](https://github.com/opendatahub-io/opendatahub-operator/pull/3576) — 修 gateway fallback 镜像用 `:latest` tag 打断 disconnected 部署;配 [#3761](https://github.com/opendatahub-io/opendatahub-operator/pull/3761)(确保 env vars 始终注入)。
  - 启示:断网交付里任何一个 `:latest`/未固定镜像都是隐性联网点。我们做 disconnected preflight 要显式扫 fallback/默认镜像,禁止浮动 tag。
- [ODH Operator PR #3777](https://github.com/opendatahub-io/opendatahub-operator/pull/3777) — 为 ISVC/LLMIsvc 停用 HWP 与 ConnAPI 的 webhook;[#3779](https://github.com/opendatahub-io/opendatahub-operator/pull/3779) 支持把 monitoring namespace 传给 modular。
  - 启示:模块化过程中 webhook 的容错/关停是升级路径关键项。我们拆 module 时要明确每个 admission webhook 在升级/回滚窗口的开关与降级行为,避免卡住 reconcile。
- [ODH KServe PR #1722](https://github.com/opendatahub-io/kserve/pull/1722) 与 [#1679](https://github.com/opendatahub-io/kserve/pull/1679) — kserve-module 升级时清理带旧版 ODH operator selector 的 Deployment/DaemonSet,并从 opendatahub-operator 迁移 HWP 升级路径;[#1727](https://github.com/opendatahub-io/kserve/pull/1727) localmodel agent SCC 改用 `MustRunAs` SELinux context。
  - 启示:从单体 operator 拆到 module 的最大坑是升级时的遗留资源与 selector 漂移。我们做架构迁移必须带"删除旧 owner 资源"的升级 hook 和 SELinux/SCC 收敛,否则升级后双份工作负载并存。
- [DSP Operator PR #1074](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1074) 与 [#1078](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1078) — TLS profile 弹性:处理 transient error、adherence policy、watcher 自愈,并简化错误处理。
  - 启示:把集群 TLS/Crypto policy 继承进组件后,要处理 API 抖动和策略不满足时的自愈,不能一有瞬时错误就把组件打成 Degraded。我们继承平台安全基线时要配 watcher 自愈与容错。

## 上游生态整合动向

- [KServe PR #5727](https://github.com/kserve/kserve/pull/5727) — LLMISVC 增加 traffic splitting API 做受控发布;配 [#5798](https://github.com/kserve/kserve/pull/5798)/[#5800](https://github.com/kserve/kserve/pull/5800)(group routing 及跨 LLMISVC 名字冲突告警)、[#5812](https://github.com/kserve/kserve/pull/5812)(finalizer 重试)。
  - 启示:LLM 灰度/流量切分正式成为 LLMISVC 的显式 API 而非外挂 Gateway 规则。我们的模型发布/回滚/SLO 对比应直接消费 LLMISVC traffic split 状态。
- [KServe PR #5740](https://github.com/kserve/kserve/pull/5740) — LLMISVC KV cache offloading 增加 secondary filesystem tiers;配 [#5670](https://github.com/kserve/kserve/pull/5670)/[#5662](https://github.com/kserve/kserve/pull/5662) 把 standard 与 P/D 默认对齐 llm-d optimized baseline,[#5719](https://github.com/kserve/kserve/pull/5719)/[#5783](https://github.com/kserve/kserve/pull/5783) 升 llm-d 镜像到 0.8。
  - 启示:KV cache 分层卸载(GPU 显存 -> 本地文件系统多层)进入上游默认,且默认值直接对齐 llm-d。我们做长上下文/高并发推理时,KV cache 分层与 llm-d P/D 拓扑要作为默认能力评估,而不是自研缓存。
- [KServe PR #5558](https://github.com/kserve/kserve/pull/5558) — storage 增加 `oci+native://` ImageVolume 挂载(#4083 第 2 步);[#5755](https://github.com/kserve/kserve/pull/5755) hf/https 下载遵守 CA bundle。
  - 启示:模型从 OCI 镜像走 ImageVolume 原生挂载(而非先拉到 PVC)会改变离线/私有 registry 交付路径,且 HF 下载开始尊重企业 CA。我们的模型分发要跟进 ImageVolume 与自定义 CA 信任链。
- [KServe PR #5723](https://github.com/kserve/kserve/pull/5723) — Envoy AI Gateway 升到 v1.0.0、Envoy Gateway 升到 v1.8.1。
  - 启示:AI Gateway 数据面进入 1.0 稳定线。我们如果基于 Envoy AI Gateway 做 MaaS/推理网关,可以开始锁 1.0 API 面而不必再追 pre-1.0 破坏性变更。

## Red Hat 官方

- [EvalHub: Capability and safety benchmarking for AI models](https://developers.redhat.com/articles/2026/07/09/evalhub-capability-and-safety-benchmarking-ai-models)(Red Hat Developer,2026-07-09)— EvalHub 是评估编排服务,把多来源 benchmark 分组成可复用的 evaluation collections,统一做能力/安全/性能评测,配置在 Red Hat AI 上运行。
  - 启示:模型评估正从 TrustyAI 的单点能力升级为"评测编排 + 可复用集合"。我们做模型准入/上线闸门时,应提供 evaluation collection 抽象(能力+安全+性能一起跑),而不是散点脚本;这也是 OAI 在 TrustyAI 之外新增的竞争面。

## 值得跟进
- [ ] 读 [ODH Dashboard #8493](https://github.com/opendatahub-io/odh-dashboard/pull/8493) + [kubeflow/hub#2908](https://github.com/kubeflow/hub/pull/2908),搞清 Agent 的 Sandbox CR(`agents.x-k8s.io/v1beta1`)与 agents catalog 数据模型,评估我们 Agent 托管是否直接复用。
- [ ] 评估 MCPLifecycleOperator([#3676](https://github.com/opendatahub-io/opendatahub-operator/pull/3676))+ 委托官方 OpenShift MCP server([#3737](https://github.com/opendatahub-io/opendatahub-operator/pull/3737))的分工,定我们 MCP 工具的自研/复用边界与 read-only 策略。
- [ ] 试 KServe LLMISVC traffic splitting([#5727](https://github.com/kserve/kserve/pull/5727))与 KV cache 多层卸载([#5740](https://github.com/kserve/kserve/pull/5740)),判断发布控制面与长上下文推理缓存可复用度。
- [ ] 对比 OAI External Models([#8471](https://github.com/opendatahub-io/odh-dashboard/pull/8471))做法,补齐我们模型目录里"外部端点"条目的元数据、路由与订阅统一视图。
- [ ] 试用 EvalHub 的 evaluation collection 模型,评估纳入我们模型上线闸门。

## 原始材料

<details>
<summary>本次扫描清单(07-07 -> 07-14 merged)</summary>

opendatahub-operator:
- https://github.com/opendatahub-io/opendatahub-operator/pull/3676
- https://github.com/opendatahub-io/opendatahub-operator/pull/3737
- https://github.com/opendatahub-io/opendatahub-operator/pull/3777
- https://github.com/opendatahub-io/opendatahub-operator/pull/3779
- https://github.com/opendatahub-io/opendatahub-operator/pull/3576
- https://github.com/opendatahub-io/opendatahub-operator/pull/3761
- https://github.com/opendatahub-io/opendatahub-operator/pull/3762
- https://github.com/opendatahub-io/opendatahub-operator/pull/3735
- https://github.com/opendatahub-io/opendatahub-operator/pull/3701
- https://github.com/opendatahub-io/opendatahub-operator/pull/3680

odh-dashboard:
- https://github.com/opendatahub-io/odh-dashboard/pull/8493
- https://github.com/opendatahub-io/odh-dashboard/pull/8422
- https://github.com/opendatahub-io/odh-dashboard/pull/8343
- https://github.com/opendatahub-io/odh-dashboard/pull/8345
- https://github.com/opendatahub-io/odh-dashboard/pull/8442
- https://github.com/opendatahub-io/odh-dashboard/pull/8485
- https://github.com/opendatahub-io/odh-dashboard/pull/8472
- https://github.com/opendatahub-io/odh-dashboard/pull/8471
- https://github.com/opendatahub-io/odh-dashboard/pull/8478
- https://github.com/opendatahub-io/odh-dashboard/pull/8441
- https://github.com/opendatahub-io/odh-dashboard/pull/8443
- https://github.com/opendatahub-io/odh-dashboard/pull/8444
- https://github.com/opendatahub-io/odh-dashboard/pull/8263
- https://github.com/opendatahub-io/odh-dashboard/pull/8429
- https://github.com/opendatahub-io/odh-dashboard/pull/8473

kserve (ODH fork):
- https://github.com/opendatahub-io/kserve/pull/1722
- https://github.com/opendatahub-io/kserve/pull/1727
- https://github.com/opendatahub-io/kserve/pull/1679
- https://github.com/opendatahub-io/kserve/pull/1706
- https://github.com/opendatahub-io/kserve/pull/1705
- https://github.com/opendatahub-io/kserve/pull/1707
- https://github.com/opendatahub-io/kserve/pull/1687

kserve (upstream):
- https://github.com/kserve/kserve/pull/5727
- https://github.com/kserve/kserve/pull/5798
- https://github.com/kserve/kserve/pull/5800
- https://github.com/kserve/kserve/pull/5812
- https://github.com/kserve/kserve/pull/5740
- https://github.com/kserve/kserve/pull/5670
- https://github.com/kserve/kserve/pull/5662
- https://github.com/kserve/kserve/pull/5558
- https://github.com/kserve/kserve/pull/5755
- https://github.com/kserve/kserve/pull/5723
- https://github.com/kserve/kserve/pull/5719
- https://github.com/kserve/kserve/pull/5783

notebooks / DSP / model-registry / trustyai:
- https://github.com/opendatahub-io/notebooks/pull/4013
- https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1074
- https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1078
- https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1075
- https://github.com/opendatahub-io/model-registry/pull/1809
- https://github.com/opendatahub-io/trustyai-service-operator/pull/152

Red Hat 官方:
- https://developers.redhat.com/articles/2026/07/09/evalhub-capability-and-safety-benchmarking-ai-models

备注:本次 `.env` 的 `GITHUB_TOKEN` 对 GitHub API 正常返回 200(rate limit 余量约 4960/h),全程 curl api.github.com,未用 gh CLI。
</details>
