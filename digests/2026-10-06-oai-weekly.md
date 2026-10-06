# OpenShift AI 周报 2026-10-06

扫描窗口:2026-09-29 → 2026-10-06(过去 7 天),覆盖 7 个 opendatahub-io 仓库。
版本上下文:上游 ODH 已全线打到 `v3.6.0-ea.2`(operator / dashboard / kserve / trustyai 均在 9/20~9/22 出 ea2 标签,notebooks `v1.49.0` 对应 3.6_ea2),`rhoai-3.6` 分支已切出,正处于 3.6 EA2 → GA 冲刺期。Red Hat 产品侧稳定版仍是 2.25.11(2026-09,纯安全更新),实质新功能都压在 3.6。

## 摘要(3 条以内)
- **本周主线是"智能体平台"(Agentic / gen-ai)**:odh-dashboard 一周 74 个提交,大半在搭 Agent Profile、Agent 部署、MCP Registry 纳管、MaaS 网关发现、GraphRAG、Playground 等能力——OAI 正把 3.6 做成一个端到端的 agent 构建/部署/评测平台,而不只是模型服务台。
- **MCP(Model Context Protocol)从 Tech Preview 转正 GA**:MCP Lifecycle Operator 默认启用([operator #4097](https://github.com/opendatahub-io/opendatahub-operator/pull/4097)),同时 dashboard 把 MLflow MCP Registry 接入 Agent 部署、model-registry 支持按 MCP architecture 过滤——MCP 已是 3.6 的一等平台能力。
- **odh-kserve fork 在做"发行版解耦"大重构**:把 OpenShift 特有逻辑(inferencegraph、OVMS webhook、RBAC marker、OAuth/TLS、监控)统一挪到 platform hook / distro build tag 背后,并给新的 `LLMInferenceService`(llmisvc)加 OTLP 追踪 egress NetworkPolicy。

## 新功能 / 能力

### 智能体(Agent)全链路(odh-dashboard,gen-ai / autorag 模块)
- [管理 Agent 部署 + 部署详情页(#9990 / RHOAIENG-89756)](https://github.com/opendatahub-io/odh-dashboard/pull/9990) 与 [创建 agent sandbox 部署(#9928)](https://github.com/opendatahub-io/odh-dashboard/pull/9928) — Agent 现在是可部署、可查状态的一类工作负载,且带隔离沙箱。
- [支持从 MLflow MCP Registry 选择 MCP server 部署 Agent(#10052 / RHOAIENG-90615)](https://github.com/opendatahub-io/odh-dashboard/pull/10052)、[在 Agent Profile 里持久化 MCP Registry 选择(#10000)](https://github.com/opendatahub-io/odh-dashboard/pull/10000) — Agent 的工具(tool)通过 MCP Registry 声明式选取,保留 `allowedTools` 白名单与部署期授权。
  - 启示:这是"Agent + 工具治理"的产品化样板。我们若要做 agent 能力,工具不该硬编码,得有一个 MCP server 注册表 + per-agent 工具白名单 + 部署期鉴权的三件套;OAI 直接复用了 MLflow 做 registry 后端,值得对标。
- [发现 MaaS 网关供 Agent 使用(#10024 / RHOAIENG-89747)](https://github.com/opendatahub-io/odh-dashboard/pull/10024)、[agent 部署 feature flag(#10026)](https://github.com/opendatahub-io/odh-dashboard/pull/10026) — Agent 的模型后端走 Models-as-a-Service 网关而非直连 ISVC。
- [AutoRAG 支持 GraphRAG(#9979 / RHOAIENG-95862)](https://github.com/opendatahub-io/odh-dashboard/pull/9979) — 用一套通用 DB 连接契约同时支持 Simple RAG(Milvus/pgvector)和 Graph RAG(Neo4j),按 provider 过滤数据库 Secret。
  - 启示:RAG 产品正从"向量库单选"走向"向量 + 图谱多后端可插拔"。连接契约统一(`db_secret_name` + `store_binding`)是关键设计,避免给每种库写一套 UI/契约,我们做数据连接抽象时可借鉴。
- [Playground 支持文档附件(#9927)](https://github.com/opendatahub-io/odh-dashboard/pull/9927)、[AutoRAG 支持 evaluator 限定的优化指标(#9862)](https://github.com/opendatahub-io/odh-dashboard/pull/9862)、[OpenShell workspace 并入 Agents 导航(#9680)](https://github.com/opendatahub-io/odh-dashboard/pull/9680)。

### Models-as-a-Service(MaaS)网关
- [operator 接入 MaaS Discovery Service 镜像(#4126)](https://github.com/opendatahub-io/opendatahub-operator/pull/4126)(配套 ai-gateway-operator #127)、[dashboard 重命名 MaaS portal 属性(#10056)](https://github.com/opendatahub-io/odh-dashboard/pull/10056)。
  - 启示:OAI 正把"模型即服务"做成独立网关层(ai-gateway-operator + Discovery Service),上层 Agent/应用通过网关统一消费模型,而不是各自绑定 InferenceService。这对多租户模型复用、配额、计量是前提设施,是和我们产品的直接对标点。

### MCP Lifecycle Operator 转 GA
- [默认启用 MCP Lifecycle Operator(#4097 / OCPMCP-382)](https://github.com/opendatahub-io/opendatahub-operator/pull/4097) — 默认 DSC 把 `mcplifecycleoperator` 设为 `Managed`,从 Tech Preview 转 GA;未显式设置仍回落 `Removed`(与 Kserve 等组件口径一致),显式 admin 选择(含 Removed)恒被尊重。
  - 启示:MCP server 的生命周期管理(部署/升级/下线)被当作平台组件而非应用负担。我们若纳管 MCP server,应有专门的 lifecycle operator,而不是让用户手工 kubectl apply。

### 模型注册中心(model-registry)
- [新增 `llmInferenceServiceTemplate` 字段 + 把 `template` 改名 `servingRuntimeTemplate`(#1903)](https://github.com/opendatahub-io/model-registry/pull/1903) — registry 现在同时存裸 `LLMInferenceServiceConfig` 模板和 serving runtime 模板。
- [serving runtime catalog 原子化重载并补测试缺口(#1906)](https://github.com/opendatahub-io/model-registry/pull/1906)、[catalog 支持 MCP architecture 过滤(#3297)](https://github.com/opendatahub-io/model-registry/pull/3297)、[新增 serving runtime logo endpoint(#1904)](https://github.com/opendatahub-io/model-registry/pull/1904)。
  - 启示:模型注册中心正从"存元数据"演进为"存可直接部署的 LLMInferenceService/ServingRuntime 模板",注册与部署被打通。model-registry 已对齐新的 llmisvc API——这是我们模型生命周期模块要跟上的 schema 变化。

## 架构 / 依赖变化

### KServe fork 发行版解耦(多个 refactor,为上游/OpenShift 双轨维护)
- [把 inferencegraph 的 OpenShift 逻辑挪到 platform hook 背后(#1328)](https://github.com/opendatahub-io/kserve/pull/1328)、[OVMS 自动版本化挪到 distro build tag 背后(#1330)](https://github.com/opendatahub-io/kserve/pull/1330)、[发行版专属 RBAC marker 隔离到独立子包(#1563)](https://github.com/opendatahub-io/kserve/pull/1563)、[OAuth/TLS 部署逻辑移到 platform hook(#1326)](https://github.com/opendatahub-io/kserve/pull/1326)、[llmisvc 监控移到 platform hook(#2054)](https://github.com/opendatahub-io/kserve/pull/2054)。本周还做了一次上游 master → odh master 同步(解决 36 处冲突)。
  - 启示:OAI 维护 KServe fork 的长期策略是"把 OpenShift 特有行为抽到 hook/build tag,核心逻辑尽量贴近上游",以降低 rebase 成本。我们若也 fork 上游组件,这套"platform hook + distro build tag"分层值得照搬——否则每次上游同步都是地狱。
- [llmisvc 新增 OTLP egress NetworkPolicy(#1955)](https://github.com/opendatahub-io/kserve/pull/1955) — `spec.tracing` 设置时为每个 LLMInferenceService reconcile 一条 `{name}-otlp-egress` 网络策略,解析 OTLP collector 到 Service 并记录到 status,放行 DNS / 同命名空间 / collector / 443·6443 egress。
  - 启示:`LLMInferenceService`(llmisvc)是 KServe 面向 LLM 的新 CRD(区别于传统 InferenceService),且追踪、监控、网络策略都在围绕它建。我们的推理服务抽象要开始评估是否对齐 llmisvc,而非停留在 InferenceService。

### 网关 / TLS 加固(operator)
- [cert-manager 集成做 TLS(XKS gateway,#4029 / RHOAIENG-81157)](https://github.com/opendatahub-io/opendatahub-operator/pull/4029)、[给 gateway proxy 传 curve preferences(#4159)](https://github.com/opendatahub-io/opendatahub-operator/pull/4159)、[kube-auth-proxy fallback 支持 TLS curve 标志(#4165)](https://github.com/opendatahub-io/opendatahub-operator/pull/4165)、[加注解可禁用 legacy dashboard 跳转(#4138)](https://github.com/opendatahub-io/opendatahub-operator/pull/4138)。

## 上游生态整合动向
- **MCP(Model Context Protocol)**:本周 OAI 把 MCP 做成贯穿 operator(lifecycle operator GA)、model-registry(architecture 过滤)、dashboard(MLflow MCP Registry 接入 agent)的横切能力。MCP 是 OAI 3.6 的核心赌注。
- **KServe 上游**:odh fork 本周同步了一次 upstream master(36 冲突),并持续围绕 `LLMInferenceService` 新 API 建设(OTLP 追踪、监控、网络策略);ModelCache / kernelcache(KV cache 节点 agent)相关调整进 charts。
- **MLflow**:作为 MCP Registry 的后端被 dashboard 直接集成(request-scoped MLflow BFF client)。
- **向量/图数据库**:AutoRAG 现支持 Milvus、pgvector、Neo4j 三类后端。
- **Kueue**:evalhub 评测任务接入 Kueue 硬件配置调度([dashboard #9945](https://github.com/opendatahub-io/odh-dashboard/pull/9945));但 evalhub 因 RBAC 策略未定[临时移除了 Kueue 权限请求(#10049)](https://github.com/opendatahub-io/odh-dashboard/pull/10049)——Kueue 纳管评测负载的 RBAC 方案还在拉锯。

## 值得跟进
- [ ] 读透 KServe 的 `LLMInferenceService`(llmisvc)CRD 与配套 `LLMInferenceServiceConfig`:它和传统 InferenceService 的分工、哪些能力(tracing/监控/NetworkPolicy)只在 llmisvc 上有。评估我们推理服务抽象是否要对齐。参考起点 [kserve #1955](https://github.com/opendatahub-io/kserve/pull/1955)、[model-registry #1903](https://github.com/opendatahub-io/model-registry/pull/1903)。
- [ ] 跟踪 ai-gateway-operator + MaaS Discovery Service 这条"模型即服务网关"线([operator #4126](https://github.com/opendatahub-io/opendatahub-operator/pull/4126)),这是多租户模型复用/计量的关键设施,和我们产品直接竞争。
- [ ] 复盘 OAI 的 "Agent Profile + MCP Registry + allowedTools 白名单 + 部署期授权" 工具治理模型([dashboard #10052](https://github.com/opendatahub-io/odh-dashboard/pull/10052) / [#10000](https://github.com/opendatahub-io/odh-dashboard/pull/10000)),作为我们 agent 工具治理的参考设计。
- [ ] 评估 KServe fork 的 "platform hook + distro build tag" 分层([kserve #1326](https://github.com/opendatahub-io/kserve/pull/1326) / [#1330](https://github.com/opendatahub-io/kserve/pull/1330) / [#1563](https://github.com/opendatahub-io/kserve/pull/1563)),用于我们自己 fork 上游组件时的解耦范式。

## 原始材料

<details>
<summary>本次扫描的 commit/release 清单</summary>

扫描窗口:2026-09-29T03:00Z → 2026-10-06,`since` 过去 7 天。GitHub token 生效,配额 5000/h。

过去 7 天各仓 main 分支提交数:
- opendatahub-operator: 13
- odh-dashboard: 74
- kserve: 29
- notebooks: 64(本周几乎全是 CI/CVE/renovate/codeserver 维护,无实质功能)
- data-science-pipelines-operator: 1(仅 OWNERS 变更,**本周无实质更新**)
- model-registry: 37(多数为 deps bump)
- trustyai-service-operator: 3(evalhub:[#971 把 FailedMount 识别为评测失败](https://github.com/opendatahub-io/trustyai-service-operator/pull/971)、[#969 collection ConfigMap 传播测试](https://github.com/opendatahub-io/trustyai-service-operator/pull/969))

最近 release 标签(均为 3.6 EA2 节奏):
- operator `v3.6.0-ea.2`(2026-09-22)
- odh-dashboard `v3.6.0-ea2-odh`(2026-09-21)
- kserve `odh-v3.6-ea2`(2026-09-20)
- trustyai `odh-3.6-ea2`(2026-09-21)
- model-registry `v0.3.17`(2026-09-21)
- notebooks `v1.49.0 / 3.6_ea2`(2026-09-18)
- data-science-pipelines-operator `v2.18.0`(2025-11,无新 release)

Red Hat 产品侧:RHOAI Self-Managed 稳定版 2.25.11(2026-09),2026 年各 patch 以安全更新为主,实质新功能集中在上游 3.6。

本周无相关 release 发布(均为上游持续集成到 main / ea2 分支)。
</details>
