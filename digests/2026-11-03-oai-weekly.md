# OpenShift AI 周报 2026-11-03

> 扫描窗口:2026-10-27 ~ 2026-11-03,源为 opendatahub-io 下 7 个主仓库(operator / dashboard / kserve / notebooks / DSP-operator / model-registry / trustyai)。本周是 3.6 版本周期的收尾节点,odh-dashboard v3.6.0 正式 GA。

## 摘要(3 条以内)

- **odh-dashboard v3.6.0 正式 GA**(11-02 发布):MaaS(Models-as-a-Service)治理能力成形——消费者门户、订阅/模型访问管理、API Key 作用域化;同期推进 evalhub 评测中心、AutoRAG、Gen AI Studio 可观测性,以及 Kueue 工作负载监控进 Infrastructure。https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.6.0
- **机密计算(Confidential Containers)落地 KServe 模型推理**:operator 在 DSC 上新增 `confidentialContainers`(裸金属 LUKS/KBS 加密服务)与 `auditLoggingProfile`(LLMInferenceService 的 OCSF 审计日志)两组字段。企业级安全合规方向的实质动作。https://github.com/opendatahub-io/opendatahub-operator/pull/4279
- **KServe 的 llmisvc / LLM-d 全链路 TLS 收口**:EPP 指标端点走 TLS、ModelExpress 以 CA bundle 校验 https、SCC 授权、modelcache 迁至独立 `model-serving-cache` 命名空间;dashboard 侧同步迁移 llm-d 拓扑/加速器配置页。

## 新功能 / 能力

- [odh-dashboard v3.6.0 GA](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.6.0) — 本版本重心:
  - **MaaS 治理闭环**:MaaS Consumer Portal 独立分发([#9072](https://github.com/opendatahub-io/odh-dashboard/pull/9072))、订阅与模型访问管理页、管理员专属 Model Access 导航、API Key 与订阅作用域化([#10471](https://github.com/opendatahub-io/odh-dashboard/pull/10471))、状态标签体系翻修。
  - **评测中心 evalhub**:benchmark/suite 抽屉式详情、非数值指标解析修复、与 MLflow 集成更稳健(本周 10+ PR 高频迭代)。
  - **Gen AI Studio 可观测性**:Playground 为失败请求展示 trace([#10510](https://github.com/opendatahub-io/odh-dashboard/pull/10510)),collector 晚启动也能接管 tracing([#10492](https://github.com/opendatahub-io/odh-dashboard/pull/10492));`/v1/models` 走 OGX 透传。
  - **AutoRAG**:BFF 增加 Neo4j 支持([#10459](https://github.com/opendatahub-io/odh-dashboard/pull/10459)),断连 MaaS 网关访问修复。
  - **基础设施观测**:Infrastructure 页新增工作负载监控(队列位置、调度状态概览)+ 准入指标,把 Kueue 队列状态带到模型部署视图。
  - 工程侧:前端打包从 webpack 迁 rspack、Node 后端改 esbuild;新增 data-registry 联邦模块(Go BFF)脚手架([#9203](https://github.com/opendatahub-io/odh-dashboard/pull/9203))。
  - 启示:OAI 把 MaaS 从"能跑"推到"能治理"(订阅/配额/访问/计量),这正是对标目标里"模型即服务 + 多租户计量"的核心。我们若要对标,`订阅—模型访问—API Key 作用域`这条管控链是最小必争集;evalhub 作为内置评测中心也值得单列对标项。

- [机密容器 + 审计日志进 KServe](https://github.com/opendatahub-io/opendatahub-operator/pull/4279) — DSC 的 `KserveCommonSpec` 新增两组字段,透传到 kserve-module CR:
  - `confidentialContainers`(`luksResourceId` 走 `kbs:///`、`initData`)对应 kserve [#2105](https://github.com/opendatahub-io/kserve/pull/2105) 的裸金属机密服务;
  - `auditLoggingProfile`(枚举 `Removed`/`Metadata`,默认 `Removed`)对应 kserve [#2107](https://github.com/opendatahub-io/kserve/pull/2107) 的 OCSF 审计。
  - 配套 [#4102](https://github.com/opendatahub-io/opendatahub-operator/pull/4102) 暴露 CoCo 可选依赖、[#4282](https://github.com/opendatahub-io/opendatahub-operator/pull/4282) 检查 CoCo 条件下组件就绪。
  - 启示:这是把"可信执行环境里跑模型推理 + 标准化(OCSF)审计"做成产品级一等公民,面向金融/政务等强合规场景。我们产品若无机密计算推理路径,会在这类客户的 POC 直接出局——建议评估 CoCo + KBS(Key Broker Service)的接入成本。

- [DCGM 监控开关下放到 DSCI](https://github.com/opendatahub-io/opendatahub-operator/pull/4281) + [observability 传 OpenTelemetry operator 命名空间](https://github.com/opendatahub-io/opendatahub-operator/pull/4243) — GPU 指标(DCGM)与可观测性配置可被集群侧覆盖;[#4266](https://github.com/opendatahub-io/opendatahub-operator/pull/4266) 镜像 usage-log 的大小/导出器/凭证,计量链路更完整。

## 架构 / 依赖变化

- [启动时迁移 CRD 存储版本](https://github.com/opendatahub-io/opendatahub-operator/pull/4277)([#4284](https://github.com/opendatahub-io/opendatahub-operator/pull/4284))— operator bootstrap 阶段主动把旧存储版本的 CR 迁到新版本,配合 [#4283](https://github.com/opendatahub-io/opendatahub-operator/pull/4283) 用 Webhook conversion 策略守护写入。启示:多版本 CRD 平滑升级是我们自家 operator 的常见痛点,这种"启动即迁移"模式可直接借鉴。
- [AKS 网关支持 OIDC scope 与 access-token 转发](https://github.com/opendatahub-io/opendatahub-operator/pull/4154) — OAI 在往 Azure(AKS)做托管适配,网关层打通 OIDC;印证其多云(非仅 OCP)落地路线。
- [e2e 默认 Kueue 升到 1.5](https://github.com/opendatahub-io/opendatahub-operator/pull/4270) — Kueue 1.5 成为默认排队/配额栈,dashboard 侧也补齐 Kueue 状态 hook 与不可准入配额修复。
- trustyai-service-operator:本周全是 upstream 同步,其中 [#245](https://github.com/opendatahub-io/trustyai-service-operator/pull/245) 合入 **TAS(TrustyAI Service)数据库迁移**;可信 AI 在往有状态持久化演进。
- model-registry **v0.3.18**(11-02)+ notebooks:均为同步/发版/CI(konflux、RPM lockfile、FIPS 构建清理)类变更,无对外能力新增。

## 上游生态整合动向

- **KServe(llmisvc / LLM-d 方向为主)**:
  - TLS 全链路收口:EPP 指标端点在启用 TLS 时走 TLS([#2128](https://github.com/opendatahub-io/kserve/pull/2128)/[#2154](https://github.com/opendatahub-io/kserve/pull/2154))、ModelExpress server 以 CA bundle 校验 https([#2158](https://github.com/opendatahub-io/kserve/pull/2158))、恢复 ODH 工作负载 TLS profile 支持([#2125](https://github.com/opendatahub-io/kserve/pull/2125))。
  - 模型缓存架构:kv PVC evictor 集成([#2113](https://github.com/opendatahub-io/kserve/pull/2113))、modelcache manifests 迁至独立 `model-serving-cache` 命名空间([#2109](https://github.com/opendatahub-io/kserve/pull/2109))。
  - llmisvc 可观测性/网络:opt-in 监控 ingress NetworkPolicy([#2088](https://github.com/opendatahub-io/kserve/pull/2088))、给加 capabilities 的单节点 pod 授 SCC([#2157](https://github.com/opendatahub-io/kserve/pull/2157))。
  - 启示:KServe 在 OAI 口径下已明显以 **llmisvc(LLMInferenceService)+ LLM-d** 为一等公民,围绕其做 TLS/SCC/NetworkPolicy/缓存的产品化收口。我们若仍停在经典 InferenceService,差距会在 LLM 推理栈上拉开。
- **Kueue**:升 1.5 为默认,并把队列状态接入 dashboard 的 Infrastructure/模型部署视图——批作业与在线推理的统一配额治理在成形。
- **vLLM / Ray**:本周无直接依赖变更;operator 侧仅手工更新 Ray manifests([#4286](https://github.com/opendatahub-io/opendatahub-operator/pull/4286)),dashboard 修了非 admin 解析 Ray dashboard URL 的 RBAC。

## 值得跟进

- [ ] 读透机密计算推理链路:kserve [#2105](https://github.com/opendatahub-io/kserve/pull/2105)(裸金属 CoCo 服务)+ [#2107](https://github.com/opendatahub-io/kserve/pull/2107)(OCSF 审计),评估在我们产品里引入 CoCo + KBS 的工程量与硬件前提。
- [ ] 拆解 MaaS 治理数据模型:看 dashboard [#10471](https://github.com/opendatahub-io/odh-dashboard/pull/10471)(API Key/订阅作用域)与 [#9072](https://github.com/opendatahub-io/odh-dashboard/pull/9072)(Consumer Portal),对照我们"模型即服务"的订阅/计量设计差距。
- [ ] 评估 evalhub 作为内置评测中心的能力边界(benchmark/suite/MLflow 集成),判断是自建还是整合。
- [ ] 复用 operator 的"启动即迁移 CRD 存储版本"模式([#4277](https://github.com/opendatahub-io/opendatahub-operator/pull/4277)),改进我们自家 operator 的多版本升级体验。

## 原始材料

<details>
<summary>本次扫描清单(releases / 关键 merged PR)</summary>

**Releases(窗口内)**
- odh-dashboard v3.6.0(2026-11-02 GA)、v3.6.0-ga-odh(10-30)
- model-registry v0.3.18(2026-11-02)
- notebooks v1.50.0(10-22,窗口外,3.6 线)

**commit 量(默认分支,近 7 天)**:dashboard 79 / notebooks 71 / kserve 47 / trustyai 33 / operator 17 / model-registry 5 / DSP-operator 0

**opendatahub-operator 关键 PR**:#4279 CoCo+审计字段、#4102 CoCo 可选依赖、#4282 CoCo 就绪检查、#4277/#4284 CRD 存储版本启动迁移、#4283 Webhook conversion 守护、#4281 DCGM 下放 DSCI、#4243 OTel 命名空间、#4266 usage-log 镜像、#4154 AKS OIDC 转发、#4270 Kueue 默认 1.5

**kserve 关键 PR**:#2128/#2154 EPP 指标 TLS、#2158 ModelExpress CA 校验、#2125 ODH TLS profile、#2113 kv PVC evictor、#2109 modelcache 迁命名空间、#2088 监控 NetworkPolicy、#2157 单节点 SCC、#2052 transformer 端口校验

**odh-dashboard 关键 PR**:#10471 API Key/订阅作用域、#9072 MaaS Consumer Portal、#10463/#10498 Model Access 管理、#10459 AutoRAG Neo4j、#10510/#10492 Gen AI Playground tracing、evalhub 系列(#10493/#10491/#10474 等)、#9203 data-registry 联邦模块、#8868 rspack 迁移、#8935 esbuild

**trustyai**:#245 TAS 数据库迁移 + 多条 upstream 同步
**model-registry**:#1928/#1929 v0.3.18 发版 + upstream 同步
**notebooks**:konflux/RPM lockfile/CI 维护类为主,#4843 移除非 FIPS 构建产物

</details>
