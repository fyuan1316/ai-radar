# OpenShift AI 周报 2026-05-26

窗口:2026-05-19 → 2026-05-26(7 天)

> 与上一份 digest(2026-05-19,窗口 05-12 → 05-19)有 1 天衔接,无需去重;trustyai-service-operator 本周 0 commit / 0 PR 活动。

## 摘要(3 条以内)
- **OGX 全面替代 Llama Stack**:autorag 整包从 `llamastack/lsd/lls` 改名到 `ogx`([dashboard #7536](https://github.com/opendatahub-io/odh-dashboard/pull/7536)),secret key `LLAMA_STACK_CLIENT_API_KEY` → `OGX_CLIENT_API_KEY`、路径 `/lsd/*` → `/ogx/*`、CLI flag `--mock-ls-client` → `--mock-ogx-client` 全部改完;同期 Gen AI Studio 启动 OGX 解耦([#7664](https://github.com/opendatahub-io/odh-dashboard/pull/7664)),OGX 模块同步新增 offline 环境变量字段([#7661](https://github.com/opendatahub-io/odh-dashboard/pull/7661));opendatahub-io 组织里 [`ogx`(Not a gateway. The full stack.)](https://github.com/opendatahub-io/ogx)、[`ogx-k8s-operator`](https://github.com/opendatahub-io/ogx-k8s-operator)、[`ogx-distribution`](https://github.com/opendatahub-io/ogx-distribution) 三个仓库本周都有更新,LlamaStack 路径正式停止维护
- **AutoML / AutoRAG / Agent 全栈进入 manifests**:[operator #3562](https://github.com/opendatahub-io/opendatahub-operator/pull/3562) 把 `RELATED_IMAGE_ODH_AUTOML_IMAGE` / `RELATED_IMAGE_ODH_AUTORAG_IMAGE` 写进 `imageParamMap`,DSP 同步追加 AUTOML/AUTORAG 镜像([dsp 582a406](https://github.com/opendatahub-io/data-science-pipelines-operator/commit/582a406));[operator #3565](https://github.com/opendatahub-io/opendatahub-operator/pull/3565) 把 [`odh-agents-operator`(kagenti)](https://github.com/opendatahub-io/agents-operator)挂进 `manifests-config.yaml`,dashboard 同周加 [`agent-ops` mod-arch 模块](https://github.com/opendatahub-io/odh-dashboard/pull/7610)、注册 `agentOps` feature flag — "AutoML(autogluon)+ AutoRAG(documents_rag_optimization)+ Agent Ops" 这三条新管线一次性落进 operator/DSP/dashboard 的发布通道
- **KServe Module 从"实验组件"变成"自含子 operator"**:kserve-module 这一周一口气补齐四件套——SSA Deploy + GC + Rollback([#1499](https://github.com/opendatahub-io/kserve/pull/1499))、per-component conditions + release info 状态上报([#1521](https://github.com/opendatahub-io/kserve/pull/1521))、CRD/OLM/operator-health dependency 探测 + 动态 watch([#1525](https://github.com/opendatahub-io/kserve/pull/1525))、envtest 集成测试基础设施([#1527](https://github.com/opendatahub-io/kserve/pull/1527)),三周内从"骨架代码"达到"可独立 reconcile + 自报状态 + 有测试"

## 新功能 / 能力

- [autorag:Llama Stack → OGX 全量改名](https://github.com/opendatahub-io/odh-dashboard/pull/7536) — Go BFF 目录 `integrations/llamastack/` → `integrations/ogx/`、`lsmocks/` → `ogxmocks/`,文件 `lsd_*.go` → `ogx_*.go`;管道参数 `llama_stack_vector_io_provider_id` → `vector_io_provider_id`、`embeddings_models` → `embedding_models`、`llama_stack_secret_name` → `ogx_secret_name`;Secret key `LLAMA_STACK_CLIENT_*` → `OGX_CLIENT_*`;API 路径 `/lsd/models` → `/ogx/models`、`/lsd/vector-stores` → `/ogx/vector-stores`;CLI flag `--mock-ls-client` → `--mock-ogx-client`
  - 启示:OAI 用一周时间把整个 RAG/Gen AI 工作流上层抽象从 Llama Stack 这个 Meta 项目,迁到自家命名的 OGX("Open GenAI Stack")。我们如果在自家产品里也对接了 LlamaStack 上游(`llama-stack-client-*`),要立刻评估:OAI 后续会把 OGX 当成 "RAG/Agent 控制面"对外暴露,把上游 vLLM/KServe 包在底下——这与"直接暴露 KServe API"是两种产品路线。Red Hat 的赌注是更高一层的 GenAI 工作流接口,我们要么跟、要么明确做"更底层、更便携"的差异化
- [opendatahub-operator 把 AutoML / AutoRAG 镜像写入 imageParamMap](https://github.com/opendatahub-io/opendatahub-operator/pull/3562) — `RELATED_IMAGE_ODH_AUTOML_IMAGE`(`quay.io/rhoai/odh-automl-rhel9`)与 `RELATED_IMAGE_ODH_AUTORAG_IMAGE`(`quay.io/rhoai/odh-autorag-rhel9`)进入 operator manifest,服务于 `autogluon_timeseries_training_pipeline`、`autogluon_tabular_training_pipeline`、`documents_rag_optimization_pipeline` 三条 managed pipelines;[DSP 同步加 AUTORAG/AUTOML images commit](https://github.com/opendatahub-io/data-science-pipelines-operator/commit/582a406);dashboard 同周追加 [AutoML/AutoRAG StopRunModal 文案](https://github.com/opendatahub-io/odh-dashboard/pull/7566)、[Reconfigure experiment S3 connection 修复](https://github.com/opendatahub-io/odh-dashboard/pull/7582)
  - 启示:OAI 在用 "vendor 内置 managed pipelines"模式把 AutoGluon(AutoML 时序/表格)与文档 RAG 调优作为开箱即用能力嵌入。这是给"客户根本不想写 pipeline 的"那一类企业用户的能力路径——值得对照我们的产品:我们如果是"提供 pipeline runtime,客户自带 DAG",就要清楚 OAI 在向上走"无 pipeline 的体验"。是否需要补"一键 AutoML / 一键 RAG"模板,是个明确的产品决策点
- [odh-agents-operator(kagenti)挂进 operator manifests-config](https://github.com/opendatahub-io/opendatahub-operator/pull/3565) — 在 `build/manifests-config.yaml` 加 `odh-agents-operator` 条目,源 `https://github.com/opendatahub-io/agents-operator @ main`,目标路径 `kagenti-operator`,以"组件 operator"形式纳入 ODH 平台
  - 启示:OAI 把"Agent runtime"显式建模成 operator 管理的组件(component),而不是嵌进现有组件。这与 [dashboard #7610 agent-ops mod-arch 模块](https://github.com/opendatahub-io/odh-dashboard/pull/7610) 配对——Agent 在 OAI 的产品形态是 first-class component。我们做 AI 基础设施如果只把 Agent 当成"业务侧的事情",会错过 Red Hat 已经定义的"Agent 是平台能力"路径
- [dashboard 加 agent-ops mod-arch 模块 + agentOps feature flag](https://github.com/opendatahub-io/odh-dashboard/pull/7610) — 仿照 MLflow / Gen-AI 模式新增 `packages/agent-ops/{bff,frontend}` 骨架,BFF Go + Frontend React,nav 注册 "Agent Ops > My Agents"(默认 off),仅做 BFF/前端连通性占位
  - 启示:dashboard 已经为 Agent 留出了"运维入口"。下一阶段会有什么落在这个模块,可以通过 RHOAIENG-xxxxx JIRA 跟进。我们的 console 如果做类似事情,可以参考 OAI 的 mod-arch 模块分包:每个能力一个 `bff + frontend` + 独立 OWNERS,降低主仓 monorepo 的耦合
- [kserve-module:SSA Deploy / GC / Rollback](https://github.com/opendatahub-io/kserve/pull/1499) — Server-Side Apply 带 ForceOwnership 与专属 fieldManager `kserve-module-controller`;owned 资源挂 `blockOwnerDeletion`;通过 `Owns()` 监听所有 operand 类型做 drift detection;`escalate/bind` 动词支持 aggregationRule ClusterRoles;CRD 不挂 ownerReference(让 CR 删除时 CRD 存活)
  - 启示:这是 KServe 在 OAI fork 里独立的 reconciler 控制面。SSA + dedicated fieldManager 是当代 controller 的"标准范式",我们任何 component-operator 重写都应该是这个范式。另一个值得抄的设计是"CRD 排除 ownerReference"——避免"卸载 CR 时连 CRD 一起带走、用户重装就要重新订阅"的坑,这是个隐性的产品体验细节
- [kserve-module:per-component 状态条件 + release info](https://github.com/opendatahub-io/kserve/pull/1521) — 拆 `checkKServeReadiness` / `checkModelControllerReadiness`,Kserve CR 上分别报 `ProvisioningSucceeded`、`KServeReady`、`ModelControllerReady`,聚合为 top-level `Ready`;附带从 `component_metadata.yaml` 注入 release 信息(version、git sha)
  - 启示:"每个子组件单独 Condition、再聚合"这个 status 设计,是 K8s controller 真正可观测的最佳实践。我们 component operator 如果还是"一个 Ready 条件"涵盖所有,生产环境排错时会回到"看 logs"。OAI 把这条做成了 module 的入口标准
- [kserve-module:依赖探测 + CRD watch](https://github.com/opendatahub-io/kserve/pull/1525) — reconcile 前检 CRD、OLM Subscription、operator 健康;关键依赖缺失阻塞 reconcile,可选依赖以 group condition 上报;监听 dependency CRD 装/卸事件触发 re-evaluation
  - 启示:对照上一周 #3505 把"依赖健康"提到 precondition 框架——OAI 在不同抽象层(operator-level + module-level)都贯彻"先验失败先发出 Condition"。模式很值得搬到我们的多 operator 协同场景:"依赖 CRD 是否在 / OLM Subscription 是否健康 / 上游 CR 是否就绪",这三层全要显式建模而不是"假设它都在"
- [opendatahub-operator:Custom precondition + MonitorSubscription precondition 两类新前置类型](https://github.com/opendatahub-io/opendatahub-operator/pull/3556) + [#3551](https://github.com/opendatahub-io/opendatahub-operator/pull/3551) — Trainer 组件率先从 `checkPreCondition` 迁到 `Custom`;`MonitorSubscription` 监控 OLM Subscription 健康,补齐上周 #3505 的 `MonitorOperator`
  - 启示:这是上周"precondition 框架替换 dependency.NewAction"的延续,显示出 OAI 正在把所有 component 的"依赖检查 / 订阅检查 / 自定义检查"都收归 precondition 一套框架,从而让 operator 的健康检查"可组合、可枚举、可标准化"。我们如果做类似 platform operator,这套抽象(`MonitorOperator` / `MonitorSubscription` / `Custom`)值得直接对标
- [Cloud Manager(CCM):per-dependency 监控状态](https://github.com/opendatahub-io/opendatahub-operator/pull/3537) — 把单一 `DeploymentsAvailable` 拆成 `GatewayAPIReady` / `CertManagerReady` / `LWSReady` / `SailOperatorReady`,每个依赖两层检测(Tier1:Deployment ready replicas;Tier2:operator CR degraded 透传),再聚合 `DependenciesReady`;监控配置从 `chartDef` 单一来源派生,确保"部署了什么 = 监控什么"的一致性
  - 启示:CCM 是 OAI 管 KAS-on-aws / EKS 路径的 cloud-side 控制器,这次把"网关 / 证书 / lws / sail-operator"四个依赖做成单独 Condition——这是我们做托管路径(managed control plane / SaaS)时的标准模式。两层检测尤其关键:Deployment ready 只能说"进程起来了",Tier2 看 operator CR degraded 才能说"它真的能干活"
- [CCM:个别 apply 失败不再中断整体部署](https://github.com/opendatahub-io/opendatahub-operator/pull/3547) — Cloud Manager reconcile 现在 collect 单个资源 apply 错误后继续走完,而不是 fail-fast
  - 启示:从"first error wins"切到"best-effort + 聚合错误",这是 reconcile 控制器在生产里的常见进化路径。我们做 operator 时往往直接 `return err` 然后整个 reconcile cycle 失败,导致一个 ConfigMap 写不进就连 50 个其他资源也卡住——这条修复确实是生产事故驱动的产物
- [model-registry:Catalog 统一 plugin server](https://github.com/opendatahub-io/model-registry/pull/2724) — Catalog 后端引入统一插件式 server,为多 catalog 源(model catalog / MCP catalog / 第三方)做插件化运行时;[dashboard #7583](https://github.com/opendatahub-io/odh-dashboard/pull/7583) 把 Model Catalog 与 MCP Catalog 从 Model Registry 的 `reliantArea` 中解耦
  - 启示:Catalog 从"Model Registry 的下游模块"独立成"插件化平台"。这跟上周 model-registry 的 `ToolCallingConfig / ServingConfig / ValidatedTasks` 三层能力模型呼应——Catalog 正在变成"所有可发现资产"(模型、MCP 工具、未来可能还有数据集和 Agent)的统一入口。如果我们的"模型仓库"还只装模型元数据,产品方向需要扩展
- [NIM image selector 进 deployment wizard](https://github.com/opendatahub-io/odh-dashboard/pull/7466) — Model 详情步增加 NIM image 下拉,数据从项目 `NIMAccount` ConfigMap 读;结构化 `{repository, tag}` 与 KServe `spec.image` 对齐;RBAC 区分"无 API key (NOT_FOUND)"与"key 失效 (ERROR)" 两种错误态;`accountStatus` 由 `useNIMAccountStatus` 一次拉取,`useNIMImages` 复用,避免重复 API 调用
  - 启示:NIM 集成已经从"独立平台"进入"deployment wizard 一等公民"。我们做"多 serving runtime"平台时,可以学这套 wizard field 的两件事:(1) 不同 runtime 的 `spec.image` 结构化输出而非字符串拼,避免 UI 端字符串解析;(2) external data hook 复用(account status + image list 共享一次拉取),减少 wizard 内重复请求
- [Feast operator 升级失败修复:Deployment selector immutable](https://github.com/opendatahub-io/opendatahub-operator/pull/3566) — 旧 Feast operator Deployment 用了不可变 selector,升级时同名 Deployment 已存在但 selector 字段冲突,导致升级失败;修复:升级路径先删旧 Deployment 再重建
  - 启示:K8s Deployment 的 `spec.selector` 是 immutable 字段,任何"选择器变更"(label 调整、matchLabels 加字段)都意味着"先删后建"。我们的 operator 升级路径必须把这一点显式处理,尤其是在做 label 规范化重构时,否则升级就 stuck。这是一个值得加进 operator 升级 checklist 的硬约束
- [dashboard:Extension serving runtime templates 扩展点](https://github.com/opendatahub-io/odh-dashboard/pull/7575) — Serving runtime templates 改造为前端扩展点,允许 mod-arch 模块自带 runtime template
  - 启示:OAI 把"内置 runtime templates"也插件化了。如果我们的 dashboard 还在维护"硬编码 vLLM / TGI / Triton template",这是迁移到"模块自带 template"架构的时机

## 架构 / 依赖变化

- [opendatahub-operator:每依赖单独 monitoring 条件(CCM)](https://github.com/opendatahub-io/opendatahub-operator/pull/3537) 与 [CCM 资源 apply 失败继续部署](https://github.com/opendatahub-io/opendatahub-operator/pull/3547) — 上面已展开
- [Skip dashboard-redirect 资源当 Dashboard 未部署](https://github.com/opendatahub-io/opendatahub-operator/pull/3524) — 之前不论 DSC `dashboard.managementState` 是什么,operator 都会创建 dashboard-redirect 配套资源(Route 等);现在按 DSC 状态条件创建
  - 启示:"组件未启用,配套资源也不应该出现"是基础卫生,但许多 operator 早期为了简单都默认创建。这是个值得 audit 的反模式 — 不该长在集群里的资源,会让用户产生"是不是我开启了什么"的困惑
- [opendatahub-operator:KServe CR 删除时保留 Condition 时间戳](https://github.com/opendatahub-io/opendatahub-operator/pull/3495) — 之前 reconcile 中"重新生成 Condition"会把 `lastTransitionTime` 覆盖成当前时间;这会让用户看不出"问题在 1 小时前出现"还是"刚刚出现"
  - 启示:Condition 的 `lastTransitionTime` 是"状态 latching"的关键字段——只有 status 真正变化才能 touch。这是 K8s API conventions 里反复强调的细节,但我们自己的 operator 是不是也犯过同样的错(每次 reconcile 都 New 一个 Condition)?值得审一次
- [KServe(OAI fork):升级时避免 scheduler 重启](https://github.com/opendatahub-io/kserve/pull/1452) — 从 3.3 升级到当前版本时,scheduler Pod 会被不必要重启;修复保持其稳定
  - 启示:平台组件升级时"无关 Pod 不要重启"是生产稳态要求。我们做产品升级路径要把"哪些 Pod 必须重启 / 哪些应该保持"显式建模
- [KServe:CI 用 SeaweedFS 缓存 facebook/opt-125m](https://github.com/opendatahub-io/kserve/pull/1501) — CI 不再每次从 HuggingFace 拉模型,改本地 SeaweedFS 镜像
  - 启示:模型 CI 缓存是个工程细节,但对"每天跑几百次 e2e"的项目至关重要——HuggingFace rate limit + 网络抖动都会让 CI 不可靠。我们的模型相关测试如果还在每次拉 HF,值得评估本地缓存方案
- [KServe:cryptography 升 48.0.0 应对 CVE-2026-39892](https://github.com/opendatahub-io/kserve/pull/1515)
  - 启示:常规安全跟进,不展开

## 上游生态整合动向

- **新仓库浮现**(opendatahub-io 组织,本周或近期有更新):
  - [`opendatahub-io/ogx`](https://github.com/opendatahub-io/ogx) — "Not a gateway. The full stack." 这就是替代 LlamaStack 的全栈 GenAI 框架
  - [`opendatahub-io/ogx-k8s-operator`](https://github.com/opendatahub-io/ogx-k8s-operator) — OGX 的 K8s operator
  - [`opendatahub-io/ogx-distribution`](https://github.com/opendatahub-io/ogx-distribution) — OGX core distribution 镜像
  - [`opendatahub-io/agents-operator`](https://github.com/opendatahub-io/agents-operator)(kagenti) — Agent runtime operator
  - [`opendatahub-io/batch-gateway`](https://github.com/opendatahub-io/batch-gateway) — "llm-d implementation of the OpenAI batch inference API"
  - [`opendatahub-io/llm-d-batch-gateway-operator`](https://github.com/opendatahub-io/llm-d-batch-gateway-operator) — llm-d batch gateway operator
  - [`opendatahub-io/llm-d-async`](https://github.com/opendatahub-io/llm-d-async) — llm-d 异步推理(可能对应 batch)
  - [`opendatahub-io/models-as-a-service`](https://github.com/opendatahub-io/models-as-a-service) — MaaS 控制面(operator #3545 修复的就是 MaaS payload-processing namespace)
  - [`opendatahub-io/ai-helpers`](https://github.com/opendatahub-io/ai-helpers) — Claude Code / Cursor skills 与 commands 集合
  - [`opendatahub-io/agentic-ci`](https://github.com/opendatahub-io/agentic-ci) — Agent 化 CI
  - 启示:opendatahub 组织正在快速扩张组件矩阵,而且四个方向同时推进——(a) OGX 作为 GenAI 控制面;(b) Agent 作为一等公民(agents-operator + agentic-ci + ai-helpers);(c) llm-d 异步 / batch 推理(直接对标 OpenAI Batch API);(d) MaaS 多租户服务化。我们对标产品时要明确选自己的赌注,不要试图全跟
- [Dashboard:Model Catalog / MCP Catalog 与 Model Registry 解耦](https://github.com/opendatahub-io/odh-dashboard/pull/7583) — UI reliantArea 拆分,Catalog 不再依赖 Model Registry 实例存在
  - 启示:这是产品分层关键一步——Catalog 是发现层,Model Registry 是治理层,二者解耦后客户可以"只装 Catalog 看 RHEL AI 提供的模型,不装 Model Registry"。我们做企业模型库时,要把"浏览 vs 治理"两套权限/部署形态分开
- [Dashboard:remove RStudio reference](https://github.com/opendatahub-io/odh-dashboard/pull/7630) + [notebooks #3674 RHAIENG-4776 remove remaining RStudio artifacts](https://github.com/opendatahub-io/notebooks/pull/3674)
  - 启示:RStudio 退场延续上一周开始的清理工作;OAI 把 R 工作流移出官方维护版图,这与"GenAI / Python 优先"的产品定位一致

## 值得跟进

- [ ] 跟 [ogx](https://github.com/opendatahub-io/ogx) 与 [ogx-k8s-operator](https://github.com/opendatahub-io/ogx-k8s-operator) 仓库的 README / API doc,搞清楚 OGX 的能力边界:它是"LlamaStack 的 Red Hat 版" 还是"重写的 GenAI 控制面"?对标我们自家产品有没有同位置组件
- [ ] 读 [kserve-module #1499 SSA Deploy 实现](https://github.com/opendatahub-io/kserve/pull/1499),把 `ForceOwnership` + `blockOwnerDeletion` + `CRD 排除 ownerReference` 这套范式整理成我们 operator 标准
- [ ] 读 [opendatahub-operator #3537 CCM per-dependency monitoring](https://github.com/opendatahub-io/opendatahub-operator/pull/3537) 与 [#3556 Custom precondition](https://github.com/opendatahub-io/opendatahub-operator/pull/3556),评估"precondition 框架(Custom + MonitorOperator + MonitorSubscription)" 是否值得移植
- [ ] 评估 [agents-operator(kagenti)](https://github.com/opendatahub-io/agents-operator) 的 Agent 抽象——是否需要在我们产品里也加 first-class Agent 资源类型,而不是把 Agent 当业务层资产
- [ ] 跟 [batch-gateway](https://github.com/opendatahub-io/batch-gateway) 与 [llm-d-async](https://github.com/opendatahub-io/llm-d-async),搞清楚 OAI 的"批量推理 / 异步推理"产品形态,这是大客户(OpenAI Batch API 用量大)的强需求
- [ ] 跟 [dashboard mod-arch 模块化模式](https://github.com/opendatahub-io/odh-dashboard/pull/7610),评估在自家 console 引入"每能力 bff + frontend + 独立 OWNERS"分包的成本/收益

## 原始材料

<details>
<summary>本次扫描的 commit/PR/release 清单</summary>

**Releases(本周窗口内无新 GA;上一个 EA 是 v3.5.0-ea.1 / odh-v3.5-EA1,2026-05-08)**
- [opendatahub-operator v3.5.0-ea.1](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.5.0-ea.1)(2026-05-08)
- [kserve odh-v3.5-EA1](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.5-EA1)(2026-05-04)

**opendatahub-operator(24 commits, 41 PRs updated)**
- [#3573](https://github.com/opendatahub-io/opendatahub-operator/pull/3573) chore: update manifest commit SHAs
- [#3569](https://github.com/opendatahub-io/opendatahub-operator/pull/3569) Confidence scoring fallback + client setup guides + scenario docs
- [#3567](https://github.com/opendatahub-io/opendatahub-operator/pull/3567) macgregor 加入 platform owners
- [#3566](https://github.com/opendatahub-io/opendatahub-operator/pull/3566) fix(feast): immutable Deployment selector
- [#3565](https://github.com/opendatahub-io/opendatahub-operator/pull/3565) Add odh-agents-operator (kagenti) to manifests-config
- [#3564](https://github.com/opendatahub-io/opendatahub-operator/pull/3564) fix(modelcontroller): remove unused DependenciesAvailable condition
- [#3562](https://github.com/opendatahub-io/opendatahub-operator/pull/3562) feat: add AutoML/AutoRAG images to imageParamMap
- [#3561](https://github.com/opendatahub-io/opendatahub-operator/pull/3561) System Prompt Iteration — Cascading & Multi-Failure
- [#3559](https://github.com/opendatahub-io/opendatahub-operator/pull/3559) chore: return fake recorders from MockManager
- [#3556](https://github.com/opendatahub-io/opendatahub-operator/pull/3556) feat: Custom precondition type, migrate Trainer
- [#3551](https://github.com/opendatahub-io/opendatahub-operator/pull/3551) RHOAIENG-58946: MonitorSubscription precondition
- [#3547](https://github.com/opendatahub-io/opendatahub-operator/pull/3547) fix(ccm): continue deploying resources when individual apply fails
- [#3545](https://github.com/opendatahub-io/opendatahub-operator/pull/3545) fix(maas): keep payload-processing in gateway namespace
- [#3542](https://github.com/opendatahub-io/opendatahub-operator/pull/3542) fix: align with labeled pod/service monitors
- [#3537](https://github.com/opendatahub-io/opendatahub-operator/pull/3537) feat: per-dependency monitoring status for CCM
- [#3524](https://github.com/opendatahub-io/opendatahub-operator/pull/3524) Skip dashboard-redirect when Dashboard not deployed
- [#3512](https://github.com/opendatahub-io/opendatahub-operator/pull/3512) RHOAIENG-61378: e2e tests retry mode
- [#3495](https://github.com/opendatahub-io/opendatahub-operator/pull/3495) fix(RHOAIENG-60488): preserve Condition timestamps across reconcile
- [#3479](https://github.com/opendatahub-io/opendatahub-operator/pull/3479) fix: discover PKI resource names from cloud manager deployment

**odh-dashboard(53 commits, 193 PRs updated;只列功能性变更)**
- [#7536](https://github.com/opendatahub-io/odh-dashboard/pull/7536) feat(autorag): Switch from Llama Stack to OGX(已展开)
- [#7466](https://github.com/opendatahub-io/odh-dashboard/pull/7466) feat(nim-serving): NIM image selector in deployment wizard
- [#7610](https://github.com/opendatahub-io/odh-dashboard/pull/7610) feat: add agent-ops mod-arch module
- [#7575](https://github.com/opendatahub-io/odh-dashboard/pull/7575) Extension serving runtime templates
- [#7583](https://github.com/opendatahub-io/odh-dashboard/pull/7583) fix: decouple Model Catalog and MCP Catalog from Model Registry
- [#7588](https://github.com/opendatahub-io/odh-dashboard/pull/7588) mySubscriptions feature flag + tabs
- [#7594](https://github.com/opendatahub-io/odh-dashboard/pull/7594) feat(RHOAIENG-60621): playground welcome prompt examples clickable
- [#7619](https://github.com/opendatahub-io/odh-dashboard/pull/7619) RHOAIENG-63547: per-provider indexed env vars for max_tokens
- [#7566](https://github.com/opendatahub-io/odh-dashboard/pull/7566) fix(automl,autorag): StopRunModal text
- [#7582](https://github.com/opendatahub-io/odh-dashboard/pull/7582) AutoML/AutoRAG reconfigure S3 connection 修复
- [#7568](https://github.com/opendatahub-io/odh-dashboard/pull/7568) fix(RHOAIENG-58424): skip compare mode modal when no messages
- [#7427](https://github.com/opendatahub-io/odh-dashboard/pull/7427) chore: feature store frontend clean up
- [#7347](https://github.com/opendatahub-io/odh-dashboard/pull/7347) fix(feature-store): populate features and description on lineage nodes
- [#7428](https://github.com/opendatahub-io/odh-dashboard/pull/7428) chore (gen-ai): RHOAIENG-58763 vector store event tracking
- [#7589](https://github.com/opendatahub-io/odh-dashboard/pull/7589) Updating BFF mocks for My Subscriptions
- [#7591](https://github.com/opendatahub-io/odh-dashboard/pull/7591) Remove LlamaStack managed state setup from Gen AI / Prompt Management E2E
- [#7527](https://github.com/opendatahub-io/odh-dashboard/pull/7527) feat(gen-ai): cluster-deploy-genai skill for fast sidecar testing
- 开放但未合并(本周热点):[#7664 Gen AI Studio 解耦 OGX](https://github.com/opendatahub-io/odh-dashboard/pull/7664)、[#7661 OGX CR 加 offline env vars](https://github.com/opendatahub-io/odh-dashboard/pull/7661)、[#7632 Tool Calling feature flag](https://github.com/opendatahub-io/odh-dashboard/pull/7632)、[#7633 autorag 消费 embeddable playground](https://github.com/opendatahub-io/odh-dashboard/pull/7633)、[#7628 My Subscriptions View Details Page](https://github.com/opendatahub-io/odh-dashboard/pull/7628)、[#7625 fix(gen-ai) post-loop SSE write errors](https://github.com/opendatahub-io/odh-dashboard/pull/7625)、[#7630 Remove RStudio reference](https://github.com/opendatahub-io/odh-dashboard/pull/7630)

**kserve(OAI fork, 11 commits)**
- [#1527](https://github.com/opendatahub-io/kserve/pull/1527) feat(kserve-module): envtest 集成测试基础设施
- [#1525](https://github.com/opendatahub-io/kserve/pull/1525) feat(kserve-module): dependency checking + CRD watch
- [#1521](https://github.com/opendatahub-io/kserve/pull/1521) feat(kserve-module): status reporting with conditions + release info
- [#1499](https://github.com/opendatahub-io/kserve/pull/1499) feat(kserve-module): SSA deploy / GC / Rollback
- [#1452](https://github.com/opendatahub-io/kserve/pull/1452) Avoid scheduler restarts on upgrades from 3.3
- [#1501](https://github.com/opendatahub-io/kserve/pull/1501) RHOAIENG-63043: cache facebook/opt-125m in SeaweedFS
- [#1515](https://github.com/opendatahub-io/kserve/pull/1515) RHOAIENG-62077 CVE-2026-39892: cryptography 48.0.0
- [#1510](https://github.com/opendatahub-io/kserve/pull/1510) RHOAIENG-63040 Fix merge step git config
- [#1516](https://github.com/opendatahub-io/kserve/pull/1516) RHOAIENG-61083 MinIO client binary CI fix
- [#1140](https://github.com/opendatahub-io/kserve/pull/1140) Adding llm auth file from release v0.15 branch
- [#1523](https://github.com/opendatahub-io/kserve/pull/1523) chore: add maskarb to OWNERS
- [#1433](https://github.com/opendatahub-io/kserve/pull/1433) refactor(ci): layered Makefile/script for OpenShift E2E

**notebooks(21 commits)**
- [#3690](https://github.com/opendatahub-io/notebooks/pull/3690) RHAIENG-5297: MintMaker scope to ODH main + RHDS support
- [#3689](https://github.com/opendatahub-io/notebooks/pull/3689) llm-requests(atheo89)
- [#3688](https://github.com/opendatahub-io/notebooks/pull/3688) Update Konflux references
- [#3686](https://github.com/opendatahub-io/notebooks/pull/3686) build(deps): bump idna 3.11 → 3.15
- [#3685](https://github.com/opendatahub-io/notebooks/pull/3685) Remove tensorflow-rocm wheel, use rh secured index
- [#3679](https://github.com/opendatahub-io/notebooks/pull/3679) RHAIENG-5053: self-contained multi-stage build model doc
- [#3681](https://github.com/opendatahub-io/notebooks/pull/3681) Update lock files / ImageStream annotations
- [#3674](https://github.com/opendatahub-io/notebooks/pull/3674) RHAIENG-4776: remove remaining RStudio artifacts
- [#3672](https://github.com/opendatahub-io/notebooks/pull/3672) fix(renovate): harden base-image versioning
- [#3668](https://github.com/opendatahub-io/notebooks/pull/3668) fix(renovate): compare EA seq before timestamp

**data-science-pipelines-operator(2 commits)**
- [commit 582a406](https://github.com/opendatahub-io/data-science-pipelines-operator/commit/582a406) Add AUTORAG & AUTOML images
- [commit 37e72e1](https://github.com/opendatahub-io/data-science-pipelines-operator/commit/37e72e1) OWNERS: gmfrasca → emeritus

**model-registry(11 commits)**
- [#2724](https://github.com/opendatahub-io/model-registry/pull/2724) feat(catalog): unified plugin server
- [#2730](https://github.com/opendatahub-io/model-registry/pull/2730) Microcopy updates for tool calling
- [#2683](https://github.com/opendatahub-io/model-registry/pull/2683) Fix: "Clear all filters" appearance in Model performance view
- [#2718](https://github.com/opendatahub-io/model-registry/pull/2718) Fix model type selector in model catalog
- [#2725](https://github.com/opendatahub-io/model-registry/pull/2725) Whitespace fix for search/title in model & mcp catalog
- [#2711](https://github.com/opendatahub-io/model-registry/pull/2711) ci: add mod-arch packages group to dependabot
- [#1745](https://github.com/opendatahub-io/model-registry/pull/1745) [pull] main from kubeflow:main (upstream 同步)

**trustyai-service-operator**:本周 0 commit / 0 merged PR(沉寂周)

</details>
