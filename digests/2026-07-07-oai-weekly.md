# OpenShift AI 周报 2026-07-07

> 扫描窗口:2026-06-30 → 2026-07-07,7 个 opendatahub-io 仓库。本周无新 release(最近为 kserve `v3.5.0+rhaiv.0` / operator `v3.5.0-ea.2`,均在窗口之前);Red Hat 官方 2.25.x 本周仅 z-stream 安全更新(2.25.7 / 2.25.8),无新功能。实质动向全部在 v3.5 EA / 上游 main 的代码侧。

## 摘要(3 条)

- **服务层正在从"单一 KServe InferenceService"转向"AI Gateway + llm-d 多节点 P/D"双层架构**:operator 为新的 ai-gateway 模型落 xKS 平台 CR、引入 `llm-d-async` batch-gateway 镜像并把 aigateway 写进默认 DSC;kserve 同步补齐多节点 / prefill-decode 加速器模板与 `supported-topologies` 注解。这是本周最重的架构信号。
- **OAI 明确加码"智能体平台"**:model-registry 提出 AI Hub v1 提案,并落地 Agent Catalog 脚手架 + MCP 目录源(BFF CRUD / 设置页 / displayName);dashboard 侧上线 Deploy Agent 向导与 agent 部署列表筛选。模型注册中心正在扩展为"模型 + 智能体 + MCP"三位一体的目录。
- **企业级调度与可观测能力集中收口**:Kueue Visibility API 把排队位次直接显示到 workbench UI、非 Kueue 负载补异常指示;可观测面板(Perses)从 Tech Preview 转 GA,operator 开始下发 PersesDashboard CR、dashboard 改用 Prometheus 多租户数据源。

## 新功能 / 能力

- [operator #3709 xKS 平台 CR](https://github.com/opendatahub-io/opendatahub-operator/pull/3709) — 为新的 ai-gateway 服务模型预置平台级 CR(作者注:暂不启用,先备代码,模式类比 monitoring),配套 [#3726 llm-d-async 镜像](https://github.com/opendatahub-io/opendatahub-operator/pull/3726) 为 batch-gateway 引入异步镜像(经新仓 `ai-gateway-operator`),并 [把 aigateway 加入默认 DSC(#3715)](https://github.com/opendatahub-io/opendatahub-operator/pull/3715)。
  - 启示:OAI 在 KServe 之上叠一层网关(路由 / 批处理 / 认证代理),对标我们应盯"网关是否成为多模型流量与配额入口"。若我们仍只在 ISVC 层做治理,可能错过统一入口这层能力。建议评估 `ai-gateway-operator` 与 llm-d 的关系,以及它是否替代/收编现有 kube-auth-proxy(本周 [#3636 移除了 gateway 的 PROXY_MODE](https://github.com/opendatahub-io/opendatahub-operator/pull/3636))。
- [kserve #1685 多节点加速器模板 + supported-topologies 注解](https://github.com/opendatahub-io/kserve/pull/1685) — 重命名 NVIDIA CUDA 单节点配置,新增多节点及多节点 prefill/decode(P/D 分离)与 data-parallel 变体,给所有加速器模板加 `supported-topologies` 注解。
  - 启示:P/D 分离与多节点拓扑正在从"手工 YAML"变成"平台内置模板 + 注解声明"。我们若做大模型推理,拓扑感知的模板体系是必备项;`supported-topologies` 注解是 UI 做"硬件-拓扑自动匹配"的关键锚点(见下条 dashboard 变更)。
- [dashboard #8382 / #8312 llm-d 部署向导拓扑与高级路由](https://github.com/opendatahub-io/odh-dashboard/pull/8382) — 部署向导新增拓扑类型 + 自定义配置选择、advanced routing 字段与 topology/routing 配置;并 [#8403 对非单节点拓扑隐藏硬件配置](https://github.com/opendatahub-io/odh-dashboard/pull/8403)。
  - 启示:向导按拓扑分叉表单,是把上面 kserve 模板/注解能力直接暴露给用户。我们产品的部署向导若还是"单节点思维",在多节点大模型场景会显得落后。
- [model-registry AI Hub v1 提案](https://github.com/opendatahub-io/model-registry/commit/526b9bab54350322e6d0ed7c95ca41618cce857b) + [Agent Catalog 脚手架](https://github.com/opendatahub-io/model-registry/commit/57934f97e2e597e8f0d662c102b303a00a786522) + [MCP 目录源 BFF CRUD](https://github.com/opendatahub-io/model-registry/commit/e1afd5963b337da4f91e0ed3b050d131cab33c34) — 模型注册中心正扩成"AI Hub":除模型外新增 Agent 目录与 MCP server 目录(含 [设置页/源管理](https://github.com/opendatahub-io/model-registry/commit/352ff430dfe328e9f85742cfbbf610e8237dd798) 与 [displayName](https://github.com/opendatahub-io/model-registry/commit/8598289f0cd2c5f905d3c3e177177104e04f87b3))。
  - 启示:这是明确的战略方向——把"模型资产管理"升级为"AI 资产中心(模型 + 智能体 + 工具/MCP)"。我们若只做模型注册,差距会拉大;应尽快评估是否把 MCP server / agent 纳入我们目录的数据模型。AI Hub v1 提案文档值得精读。
- [dashboard #8277 Deploy Agent 向导(Mode 1 BYO 镜像)](https://github.com/opendatahub-io/odh-dashboard/pull/8277) + [agent-ops 部署详情页 #8298 / 列表筛选 #8309](https://github.com/opendatahub-io/odh-dashboard/pull/8309) — agent-ops 联邦模块落地"部署自带镜像智能体"的向导壳(步骤 1 镜像选择 / 2 配置)与部署管理页。
  - 启示:OAI 把 agent 当成和 model 平级的一等部署对象,有独立 wizard / 详情页 / 生命周期。对标点:我们的"部署"抽象是否只覆盖模型服务,能否承载 agent 运行时。
- [dashboard #8332 Kueue Visibility API 排队位次](https://github.com/opendatahub-io/odh-dashboard/pull/8332) — 接入 `visibility.kueue.x-k8s.io/v1beta2`,workbench 处于 Queued/Inadmissible 时在状态副标题直接显示队列位次(如 "Waiting for quota in default (position 3)");另 [#8240 为非 Kueue 负载加异常指示](https://github.com/opendatahub-io/odh-dashboard/pull/8240)、[#8371 引入 Kueue CRD 类型与数据 hooks](https://github.com/opendatahub-io/odh-dashboard/pull/8371)。
  - 启示:Kueue 从"后台配额"走向"用户可见的排队体验"是很强的企业级卖点。我们如果用 Kueue 做多租户 GPU 配额,把 position/quota 透出到 UI 是低成本高感知的增强,建议纳入路线图。
- [dashboard #8268 可观测面板 TP→GA](https://github.com/opendatahub-io/odh-dashboard/pull/8268) — 随 3.5 监控栈 GA,`observabilityDashboard` 默认开启、移出 Tech Preview;配套 [operator 侧 #8358 下发 PersesDashboard CR 与 NetworkPolicy](https://github.com/opendatahub-io/odh-dashboard/pull/8358)、[#8264 模型面板改用 Prometheus 多租户数据源](https://github.com/opendatahub-io/odh-dashboard/pull/8264)。
  - 启示:OAI 的可观测栈标准化到 Perses(而非直接堆 Grafana)+ Prometheus tenancy。若我们仍用自定义 Grafana,需评估与 Perses CR 化路线的兼容/迁移成本。
- [trustyai #805 EvalHub 单租户支持](https://github.com/opendatahub-io/trustyai-service-operator/commit/9520041054699721dbf85810b8141c74118a052d) + [#803 扩展 OTEL 设置](https://github.com/opendatahub-io/trustyai-service-operator/commit/acc13e6ab9b4358005642d122cf622503f2140b5) + [#786 v1 转换 webhook](https://github.com/opendatahub-io/trustyai-service-operator/commit/4384502419434a79e7da9d510214782d6e87603c) — 模型评估(EvalHub)向 v1 CR 收敛:单租户模式、OTEL 可观测下沉、双证书转换 webhook 支持版本迁移。
  - 启示:TrustyAI 正把"评估"做成带 CR 版本化 + OTEL 的正式服务。我们若有模型评估需求,可参考其 EvalHub CR 设计与 disconnected 加固([#796 移除硬编码镜像、缺 RELATED_IMAGE 快速失败](https://github.com/opendatahub-io/trustyai-service-operator/commit/e24f3663c2d72e930e88d6a9e3bd9ca7efbd5c3e))。

## 架构 / 依赖变化

- **AI Gateway 成为新的一等平台组件**:operator 新增 xKS 平台 CR、`ai-gateway-operator` 新仓联动、manifests-config 增加 MCPLO 与 AI Gateway 条目([#3729](https://github.com/opendatahub-io/opendatahub-operator/pull/3729));kube-auth-proxy 移除 PROXY_MODE 环境变量([#3636](https://github.com/opendatahub-io/opendatahub-operator/pull/3636))。
- **disconnected(离线)加固成主线**:operator 给 Ray imageParamMap 加代理镜像([#3742](https://github.com/opendatahub-io/opendatahub-operator/pull/3742));trustyai 移除硬编码镜像默认、缺 `RELATED_IMAGE_*` 注入即 fail-fast,并加 disconnected 就绪扫描 GHA([#797](https://github.com/opendatahub-io/trustyai-service-operator/commit/0a1221f0f311c2eb3fe336b4e2636ac459e03791))。信号:v3.5 在为离线/受限网络企业环境做系统性收口。
- **依赖 bump**:trustyai 把 `kserve` 依赖从 0.18.0 升到 0.19.0([#792](https://github.com/opendatahub-io/trustyai-service-operator/pull/792));dashboard 升级 MLflow Go SDK([#8406](https://github.com/opendatahub-io/odh-dashboard/pull/8406))并引入 MLflow 面包屑/工作区上下文,暗示 MLflow 集成在加深。
- **Feature Store(Feast)整合成型中**:dashboard 本周密集提交 Feature Store CRD 类型 / CRUD API / React hooks / workbench 连接 / 全局搜索([#8355](https://github.com/opendatahub-io/odh-dashboard/pull/8355)、[#8372](https://github.com/opendatahub-io/odh-dashboard/pull/8372)、[#8328](https://github.com/opendatahub-io/odh-dashboard/pull/8328)),正把 Feast 做成 dashboard 一等页面。
- **notebooks 构建体系重构**:去除 Dockerfile 符号链接、KONFLUX 重命名为 PRODUCT、`.tekton`/Makefile 改用 `Dockerfile.konflux.*`([#3984](https://github.com/opendatahub-io/notebooks/pull/3984)/[#3978](https://github.com/opendatahub-io/notebooks/pull/3978)),base 镜像走 AIPCC(cuda 13.0 / 12.9 / cpu)。

## 上游生态整合动向

- **KServe**:llm-d 观测面板(Perses)进 kserve([#1606](https://github.com/opendatahub-io/kserve/pull/1606));多节点 P/D 模板([#1685](https://github.com/opendatahub-io/kserve/pull/1685));InferencePool group 默认切到 GA API group([#1686](https://github.com/opendatahub-io/kserve/pull/1686))——Gateway API Inference Extension 走向 GA 的信号。
- **Kubeflow / model-registry**:持续从 `kubeflow/main` 同步;AI Hub / Agent Catalog / MCP 均在 model-registry 内演进,说明 OAI 的"AI 资产中心"选择在 model-registry(而非新仓)上长。
- **Kueue**:Visibility API v1beta2 被 dashboard 采用,批处理/配额调度进入用户可见层。
- **vLLM / llm-d**:未见 vLLM 直接提交,但 llm-d(基于 vLLM 的分布式推理)通过 ai-gateway + kserve 多节点模板 + Perses 面板三处联动落地,是本周 vLLM 生态的主要承载形式。
- **Ray**:仅 disconnected 代理镜像补充,无功能性变化。

## 值得跟进

- [ ] 精读 [model-registry AI Hub v1 提案](https://github.com/opendatahub-io/model-registry/commit/526b9bab54350322e6d0ed7c95ca41618cce857b),判断 OAI 把"模型 + 智能体 + MCP 工具"统一到一个 Hub 的数据模型与边界,对齐我们目录产品的取舍。
- [ ] 跟踪 `opendatahub-io/ai-gateway-operator` 新仓与 [operator #3625 后续 PR](https://github.com/opendatahub-io/opendatahub-operator/pull/3625),搞清 AI Gateway 与 KServe / llm-d / kube-auth-proxy 的分层关系,评估是否要在我们产品补"统一推理网关"这层。
- [ ] 试 [kserve #1685](https://github.com/opendatahub-io/kserve/pull/1685) 的多节点 P/D 模板 + `supported-topologies` 注解,验证我们的部署向导能否消费该注解做拓扑-硬件自动匹配。
- [ ] 评估 [Kueue Visibility API 排队位次 #8332](https://github.com/opendatahub-io/odh-dashboard/pull/8332) 的实现,作为我们多租户 GPU 配额 UI 的低成本增强候选。
- [ ] 评估可观测栈是否跟进 Perses(PersesDashboard CR) + Prometheus tenancy 路线,估算从自定义 Grafana 迁移成本([#8358](https://github.com/opendatahub-io/odh-dashboard/pull/8358) / [#8264](https://github.com/opendatahub-io/odh-dashboard/pull/8264))。

## 原始材料

<details>
<summary>本次扫描清单(commit 数 / 无新 release)</summary>

窗口:2026-06-30 → 2026-07-07。各仓 main 分支 commit 数:
- opendatahub-operator: 31 —— 重点 AI Gateway/xKS(#3709 #3726 #3715 #3729 #3636)、disconnected(#3742)、webhook 校验(#3700 #3725)
- odh-dashboard: 73 —— 重点 llm-d 向导(#8382 #8312 #8403)、agent-ops(#8277 #8298 #8309)、Feature Store(#8355 #8372 #8328 等)、Kueue(#8332 #8240 #8371)、可观测 GA(#8268 #8358 #8264)、gen-ai/autoRAG(#7928 #8281)
- kserve: 5 —— #1685 多节点 P/D 模板、#1606 llm-d Perses 面板、#1686 InferencePool GA group、#1692
- notebooks: 30 —— 构建重构(#3984 #3978)、AIPCC base 镜像 bump、rpms lockfile、安全(FIND-015)
- model-registry: 14 —— AI Hub v1 提案、Agent Catalog、MCP 目录源(#2890 #2888 #2887 #2864 #2886)
- trustyai-service-operator: 16 —— EvalHub(#805 #803 #799)、v1 转换 webhook(#786)、disconnected(#796 #797)、kserve 0.18→0.19(#792)
- data-science-pipelines-operator: 3 —— 集成集群 TLS 安全 profile、arm64 builder、镜像 ref 更新

无窗口内新 release。Red Hat 官方 OpenShift AI 2.25.7 / 2.25.8(2026-06)均为 z-stream 安全更新,无新功能。
</details>
