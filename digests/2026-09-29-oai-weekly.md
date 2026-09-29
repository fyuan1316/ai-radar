# OpenShift AI 周报 2026-09-29

覆盖窗口:2026-09-22 ~ 2026-09-29(过去 7 天)。数据源:opendatahub-io 7 个核心仓库的 release/commit/PR + Red Hat 官方文档站。

## 摘要(3 条以内)

- **3.6 全线切 EA2、开始冲 GA**:operator / dashboard / kserve / trustyai / notebooks 在 9/20~9/22 集中打出 `v3.6.0-ea.2` 系列 tag,dashboard 侧本周 85 个 commit 密集做 3.6 GA 收尾(data-registry 重新启用、pnpm 迁移、大量 E2E 加固)。官方文档站当前 GA 仍是 3.5,3.6 处于 Early Access。
- **"组件→模块(module)"架构改造是本周主线**:TrustyAI 从 component 迁成独立 module([operator#4051](https://github.com/opendatahub-io/opendatahub-operator/pull/4051)),dashboard 把 llm-d serving 拆出 monolith 并发布共享 K8s primitives 包([dashboard#9930](https://github.com/opendatahub-io/odh-dashboard/pull/9930)),DSPO 把 monitoring 所有权收回模块化管理。整个平台在往"可插拔模块 + 独立 operator 镜像"演进。
- **Gen AI / LLM 服务面持续加码**:MCP 注册服务器 Tech Preview 开关([dashboard#9756](https://github.com/opendatahub-io/odh-dashboard/pull/9756))、MaaS 消费门户网关路由修复、model-registry 上线 Serving Runtime Catalog API([model-registry#1894](https://github.com/opendatahub-io/model-registry/pull/1894))、KServe 检测 Confidential Containers([kserve#1985](https://github.com/opendatahub-io/kserve/pull/1985))。

## 新功能 / 能力

- [TrustyAI 从 component 迁移为 module](https://github.com/opendatahub-io/opendatahub-operator/pull/4051) — TrustyAI 改成基于当前 ModuleHandler 接口的 out-of-tree kustomize 模块,拥有独立 operator 镜像,模板参照 sparkoperator。目前仅 DSC 模式,Platform/xKS 模式待补。
  - 启示:这是 OAI 把"大而全的 operator"往"核心 operator + 一批独立模块"拆的明确信号。我们若还是单体 operator 管所有组件,长期在灰度升级、单组件热修、第三方组件接入上会吃亏。值得评估把可信 AI、pipelines 这类能力做成可独立发版的模块。
- [dashboard 发布模块化 K8s primitives、把 llm-d serving 拆出 monolith](https://github.com/opendatahub-io/odh-dashboard/pull/9930) — 把共享 Kubernetes primitive 从架构对齐的包里发布出来,llmd-serving 消费方不再依赖 `@odh-dashboard/internal` 私有包。配合本周 [monorepo 从 npm 迁到 pnpm](https://github.com/opendatahub-io/odh-dashboard/pull/9361)。
  - 启示:前端也在做"微前端 / 联邦模块"化,serving 作为独立 workspace。对标我们控制台若是单体 SPA,新增推理/评测模块的隔离性和独立交付会是差距点。
- [model-registry 上线 Serving Runtime Catalog API](https://github.com/opendatahub-io/model-registry/pull/1894) — 完整实现 serving runtime 目录 API(含 [YAML loader #1892](https://github.com/opendatahub-io/model-registry/pull/1892)、schema、v1 listing、custom source 过滤、400 校验硬化)。同时给 MCP runtimeMetadata 加了 storage 字段(#3238)。
  - 启示:模型注册中心正从"模型元数据"扩到"serving runtime 目录"——即把"用什么运行时跑这个模型"也纳入注册中心统一管理。这是模型生命周期治理的关键一环,建议对照我们的模型仓库能力盘点差距。
- [dashboard 增加 MCP 注册服务器 Tech Preview 开关](https://github.com/opendatahub-io/odh-dashboard/pull/9756) — 新增 `genAiMcpRegistryServers` feature flag,独立控制通过 MLflow MCP Registry 注册的 MCP server 在 Playground / AI Assets 中的可见性;开关关闭时手动 MCP 连接仍可用。配套 [gen-ai 展示 response tool calls #9779](https://github.com/opendatahub-io/odh-dashboard/pull/9779)。
  - 启示:OAI 在把 MCP(Model Context Protocol)做成一等公民,且走"注册中心 + Playground 消费"的闭环。做 agent / 工具调用能力的产品应重点跟这条线。
- [KServe module 检测 Confidential Containers(CoCo)依赖](https://github.com/opendatahub-io/kserve/pull/1985) — kserve module operator 现在会探测 `kata` / `ccruntime` / `enclave-cc` 类 RuntimeClass,判定 CoCo 可用性并上报 `KserveConfidentialContainer` 状态。
  - 启示:机密计算进推理栈,面向"模型/数据在推理时也要保密"的合规场景(金融、医疗)。这是企业级差异化能力,值得纳入我们安全合规 roadmap 评估。
- [dashboard 部署向导支持 secretKeyRef 环境变量](https://github.com/opendatahub-io/odh-dashboard/pull/9726) 、[EvalHub benchmark suite gallery](https://github.com/opendatahub-io/odh-dashboard/pull/9687)、[runtimeCatalog Tech Preview 开关](https://github.com/opendatahub-io/odh-dashboard/pull/9924)、[Data Connect Hub 连接类型目录页](https://github.com/opendatahub-io/odh-dashboard/pull/9947) — 一批面向 GA 的能力补齐(评测画廊、运行时目录、数据连接中枢 DCH)。

## 架构 / 依赖变化

- **模块化贯穿三个仓库**:operator 侧 TrustyAI 转 module(#4051)、[module 控制器错误日志转结构化 KV(#4075)](https://github.com/opendatahub-io/opendatahub-operator/pull/4075)、[给所有组件加 manifests 校验并动态获取组件名(#4021)](https://github.com/opendatahub-io/opendatahub-operator/pull/4021);DSPO 侧把 monitoring 所有权收归 DSPO、模块清理时保留 DSPA。
- **xKS(external Kubernetes)支持在铺路**:operator 新增 [xKS chart 依赖 onboarding 指南(#4133)](https://github.com/opendatahub-io/opendatahub-operator/pull/4133)、[在 xKS 上部署 RHAII(#4132)](https://github.com/opendatahub-io/opendatahub-operator/pull/4132)、[OLM 侧用 DetectPlatform 并卸载 Catalog ClusterExtensions(#4113)](https://github.com/opendatahub-io/opendatahub-operator/pull/4113)。OAI 在为"非 OpenShift 的 K8s 平台"做适配抽象。
  - 启示:xKS 意味着 OAI 想突破"只能跑在 OpenShift"的边界。如果他们把核心能力做到能跑在通用 K8s 上,对我们(基于通用 K8s 的产品)是正面竞争加剧的信号,需持续盯 xKS 模式成熟度。
- **网关走 Gateway API**:[MaaS 门户路由改为 hostname-less 修复网关 404(#9868)](https://github.com/opendatahub-io/odh-dashboard/pull/9868),并新增 [gateway routing conformance E2E(#9873)](https://github.com/opendatahub-io/odh-dashboard/pull/9873)、[additional ingress listeners 支持(#4116)](https://github.com/opendatahub-io/opendatahub-operator/pull/4116)。入口层在从 Route/Ingress 往 Gateway API 迁。
- **构建/基础设施**:dashboard monorepo npm→pnpm(#9361);model-registry 把 MinIO 换成 SeaweedFS(#3270);kserve kueue 占位控制器升 Go 1.26 + PQC(后量子加密)基础镜像。

## 上游生态整合动向

- **KServe(OAI fork)**:[LLMISVCConfig preset 生命周期优化(#1919)](https://github.com/opendatahub-io/kserve/pull/1919)、[给平台 OTLP collector 打 LLM tracing preset(#1941)](https://github.com/opendatahub-io/kserve/pull/1941)——LLM InferenceService(LLMISVC)+ 可观测性在深度整合。llm-d 作为 serving 后端持续出现在 dashboard 侧。
- **Kueue**:dashboard 侧 GPU-as-a-Service 用 Kueue 管配额(KueueProjectsModal、quota usage tab 埋点),Kueue 已是 OAI 的 GPU 调度/配额底座。
- **Kubeflow model-registry 上游**:本周从 kubeflow/main 同步(#1890),catalog 相关能力(RFC 8594 deprecation headers、cursor 分页精度、filterQuery 传播)持续与上游对齐。
- **MLflow**:MCP Registry 走 MLflow MCP Registry;operator 覆盖 [MLflowOperator 平台 e2e(#4076)](https://github.com/opendatahub-io/opendatahub-operator/pull/4076)。
- **TrustyAI / EvalHub**:TrustyAI 本周主打 TLS 安全([TLS FIPS adherence #951](https://github.com/opendatahub-io/trustyai-service-operator/pull/951)、TLS profile propagation #948、TLS proxy resolver #947),EvalHub 侧同步 inspect provider、BBH exact_match 指标、system collection 策展覆盖。

## 值得跟进

- [ ] 读透 [operator#4051](https://github.com/opendatahub-io/opendatahub-operator/pull/4051) 的 ModuleHandler 接口(PopulatePlatformModule/IsEnabled/BuildModuleCR)与 sparkoperator 模板,评估我们把组件模块化的可行路径与工作量。
- [ ] 跟 xKS 模式:验证 [operator#4132](https://github.com/opendatahub-io/opendatahub-operator/pull/4132) / [#4133](https://github.com/opendatahub-io/opendatahub-operator/pull/4133),判断 OAI 落地通用 K8s 的进度,这直接关系竞争态势。
- [ ] 试用 [model-registry Serving Runtime Catalog API](https://github.com/opendatahub-io/model-registry/pull/1894),对照我们模型仓库,规划"运行时目录"能力。
- [ ] 评估机密计算路线:参考 [kserve#1985](https://github.com/opendatahub-io/kserve/pull/1985) 的 CoCo RuntimeClass 探测方式,判断是否纳入我们企业级安全能力。
- [ ] 关注 3.6 GA 发布节点(官方文档站现仍 3.5 GA),GA 后重点看正式 release notes 里对外口径的功能定位。

## 原始材料

<details>
<summary>本次扫描清单(2026-09-22 ~ 2026-09-29)</summary>

**Release(近期 tag)**
- opendatahub-operator: v3.6.0-ea.2(2026-09-22)、v3.6.0-ea.1(09-02)、v3.5.0(07-29)
- odh-dashboard: v3.6.0-ea2-odh(2026-09-21)、v3.6.0-ea1-odh(08-19)
- kserve: odh-v3.6-ea2(2026-09-20)、odh-v3.6-ea1(09-03)
- notebooks: v1.49.0 / 3.6_ea2(2026-09-18)
- model-registry: v0.3.17(2026-09-21)、v0.3.16(08-31)
- trustyai-service-operator: odh-3.6-ea2(2026-09-21)、odh-3.6-ea1(09-01)
- data-science-pipelines-operator: 无新 release(最新 v2.18.0,2025-11)

**7 天 commit 计数**:dashboard 85、operator 38、model-registry 24、notebooks 21、trustyai 11、dsp-operator 8、kserve 7

**重点 PR**
- operator: #4051(TrustyAI→module)、#4082(DCH 镜像引用)、#4021(manifests 校验)、#4075(结构化日志)、#4113(OLM DetectPlatform)、#4116(ingress listeners)、#4132/#4133(xKS)
- dashboard: #9930(模块化 primitives + llm-d 拆分)、#9361(pnpm)、#9756(MCP 注册开关)、#9726(secretKeyRef)、#9687(EvalHub gallery)、#9924(runtimeCatalog flag)、#9947/#9775(DCH 连接目录)、#9868/#9873(Gateway API)、#9897(data-registry 3.6 GA)、#9791(multimodal E2E)
- kserve: #1985(CoCo)、#1941(LLM tracing OTLP)、#1919(LLMISVCConfig preset)
- model-registry: #1894/#1892(Serving Runtime Catalog)、#3238(MCP runtimeMetadata storage)、#3270(MinIO→SeaweedFS)
- trustyai: #951/#948/#947(TLS FIPS/profile/proxy)、#943(EvalHub system collection)
- dsp-operator: AWS STS 对象存储凭证、object store region 透传、monitoring 所有权收归 DSPO

**官方**:docs.redhat.com OpenShift AI 文档站当前 GA 3.5,3.6 处于 Early Access。

</details>
