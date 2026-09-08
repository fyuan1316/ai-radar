# OpenShift AI 周报 2026-09-08

覆盖窗口:2026-09-01 ~ 2026-09-08(7 个 opendatahub-io 主仓 + Red Hat 官方博客)

## 摘要(3 条以内)

- **v3.6 EA1 全面开闸**:operator(v3.6.0-ea.1)、kserve(odh-v3.6-ea1)、trustyai(odh-3.6-ea1)本周同步打出 3.6 早鲜版,operator 主线已切到 `rhoai-3.6-ea.2`,3.6 进入密集收尾。
- **两条新产品线在 dashboard 里成形**:一是 "Data Registry"(数据资产注册:表/卷/连接),把 Model Registry 的资产治理范式扩展到数据侧;二是 "MaaS Consumer Portal"(模型即服务消费门户),通过 Dashboard Module Controller + operator ConsoleLink 部署,BFF 已支持外部 provider/model 的实时 CRUD。
- **平台走向 "模块契约(platform contract)" 架构**:kserve/trustyai/dashboard 本周集中补 PlatformObject 契约一致性测试,配合 Dashboard Module Controller,OAI 正把各组件统一成可插拔"模块"由 operator 编排。

## 新功能 / 能力

- [Data Registry:连接支持](https://github.com/opendatahub-io/odh-dashboard/pull/9583) + [表注册](https://github.com/opendatahub-io/odh-dashboard/pull/9510) + [表/卷资产详情视图](https://github.com/opendatahub-io/odh-dashboard/pull/9464) — dashboard 新增"数据注册中心"界面,管理表、卷、连接等数据资产(RHAI-427)。
  - 启示:OAI 在把"注册中心"从模型扩展到数据,朝统一资产目录(model + data + 未来 feature)演进。我们若只有模型注册,数据资产治理会成为差异点;可评估是否用同一套 catalog 后端(model-registry 的 ML Metadata)承载数据资产,避免重复造轮子。
- [MaaS Consumer Portal 经 Dashboard Module Controller 部署](https://github.com/opendatahub-io/odh-dashboard/pull/9637) + [operator 下发 ConsoleLink](https://github.com/opendatahub-io/odh-dashboard/pull/9485) + [外部 model/provider 实时 BFF](https://github.com/opendatahub-io/odh-dashboard/pull/9557) — "模型即服务"消费门户:支持接入外部模型 provider、BBR 托管密钥,面向"内部 AI 服务集市"场景(RHOAIENG-90191/88480)。
  - 启示:这是 OAI 把推理能力产品化成"内部 API 集市/网关"的明确信号(叠加外部模型聚合)。对标我们产品,应尽快明确"平台自建模型"与"聚合外部模型(OpenAI/托管厂商)"的统一消费入口与计量/鉴权路径。
- [gen-ai BFF 探测 Agent Sandbox CRD 可用性](https://github.com/opendatahub-io/odh-dashboard/pull/9541) — BFF 启动即探测 `agents.x-k8s.io/v1beta1`(kubernetes-sigs Agent Sandbox),按集群是否提供该 CRD 动态开关 Agent Sandbox UI(RHOAIENG-89750)。
  - 启示:OAI 的 GenAI Studio 正接入上游 Agent Sandbox 标准(agents.x-k8s.io),做 agent 隔离运行时。值得跟这个 CRD 的上游进展,决定我们 agent 运行时是自研还是对齐该标准。
- [gen-ai:MCP registry BFF 集成 + 本地 MLflow 开发栈](https://github.com/opendatahub-io/odh-dashboard/pull/9552) + [MCP registry 更新语义修复](https://github.com/opendatahub-io/odh-dashboard/pull/9593) — GenAI 侧引入 MCP(Model Context Protocol)注册中心,并用 MLflow 承载本地开发。
  - 启示:MCP 正在从"实验"进入 OAI 的一等公民(有独立 registry)。我们的 agent/工具接入层应把 MCP 作为标准协议纳入路线图。
- [Feature Store 管理 UI 补齐 E2E 测试](https://github.com/opendatahub-io/odh-dashboard/pull/9600) — Feast 特征库管理台进入测试固化阶段。
- [Kueue 配额用量树视图](https://github.com/opendatahub-io/odh-dashboard/pull/9580) + [zero-quota workbench 生命周期判定 Inadmissible](https://github.com/opendatahub-io/odh-dashboard/pull/9630) — 配额治理 UI 化,workbench 纳入 Kueue 准入。
  - 启示:OAI 把 Kueue 作为统一配额/准入底座(workbench + 训练 + 推理),配额可视化是多租户卖点。我们若仍用自研配额,需评估迁移或对齐 Kueue。

## 架构 / 依赖变化

- **模块契约一致性(platform contract)成主线工作**:kserve(RHOAIENG-82796/82798/82802 采用 ValidatePlatformObject 契约、webhook/platformVersion 传递验证)、trustyai([平台契约 conformance 测试](https://github.com/opendatahub-io/trustyai-service-operator/commit/87d6a50)、对齐 singleton CR 命名)、dashboard(RHOAIENG-83650/83654/83655 PlatformObject 契约 + envtest)。各组件正被规约成统一"模块"接口,由 operator/Dashboard Module Controller 编排。
  - 启示:这是 OAI 组件解耦、支持"按需启停模块"的底层重构。对我们的插件化/组件化架构有直接借鉴价值,值得读一份 PlatformObject 契约定义。
- **集群 TLSSecurityProfile 全线贯通**:operator [尊重 Old profile without tls-lint](https://github.com/opendatahub-io/opendatahub-operator/pull/4052)、DSP([profile-fetch 失败 fail-closed / 可重试](https://github.com/opendatahub-io/data-science-pipelines-operator/commit/284edae)、TLS RBAC 收敛到 openshift overlay)、trustyai([SecureServing metrics + TLS profile watcher](https://github.com/opendatahub-io/trustyai-service-operator/pull/896))。各组件统一从集群级 TLS 策略取信。
  - 启示:企业级安全合规靠"集群级策略下沉到各组件"来做,而非各组件各自配置。我们产品的 TLS/合规也应有统一 profile 下发机制。
- [odh-observability 模块配置](https://github.com/opendatahub-io/opendatahub-operator/pull/4041) — operator 新增可观测性模块入口。
- [DSC 调和错误日志转结构化 KV](https://github.com/opendatahub-io/opendatahub-operator/pull/4005)(RHAI-524)— operator 日志结构化,利于对接集中式日志/告警。

## 上游生态整合动向

- **KServe / LLMISVC**:[为用户命名空间的 Prometheus 抓取加 NetworkPolicy](https://github.com/opendatahub-io/kserve/pull/1904)(llmisvc 为 Prometheus/Gateway 加 per-service NetworkPolicy);[新增 kserve-kueue controller Dockerfile](https://github.com/opendatahub-io/kserve/commit/17077f0);LLMISVC 的 ServiceMonitor/CRD 已 vendored 并加测试。LLM 专用推理服务(LLMInferenceService)持续成熟,并与 Kueue 深度整合。
  - 启示:KServe 正分化出 LLM 专用 CRD(LLMISVC)+ Kueue 配额调度的组合拳。我们的推理层若基于 KServe,应跟 LLMISVC 而非只用传统 InferenceService。
- **MCP / Agent Sandbox**:见上,OAI GenAI 侧接入 MCP registry 与 agents.x-k8s.io Agent Sandbox。
- **TrustyAI**:[KServe CRD 缺失时自愈、从不可变 Deployment selector 恢复](https://github.com/opendatahub-io/trustyai-service-operator/commit/10d985d)(TAS 自愈)。
- **官方博客(9/3)**:[用 IBM CLEAR & EvalHub 评估 AI agent](https://developers.redhat.com/articles?f%5B0%5D=taxonomy_product_variant%3A101541)、[vLLM Speculators 用 P-EAGLE 加速 LLM 推理](https://developers.redhat.com/articles?f%5B0%5D=taxonomy_product_variant%3A101541)(Speculators v0.6.0 并行草稿)。EvalHub(agent 评估)与投机解码是 OAI 当前对外主推的两个能力点。

## 值得跟进

- [ ] 读 PlatformObject 契约与 Dashboard Module Controller 设计(dashboard PR #9587/#9599 + kserve RHOAIENG-82796),评估我们组件化架构是否借鉴"模块契约"模式。
- [ ] 试 MaaS Consumer Portal + 外部 model provider BFF(dashboard #9557/#9637),对比我们"模型服务集市/网关"的定位与鉴权计量设计。
- [ ] 跟踪上游 `agents.x-k8s.io` Agent Sandbox CRD 与 MCP registry(dashboard #9541/#9552),决定 agent 运行时与工具协议是自研还是对齐标准。
- [ ] 评估 KServe LLMISVC + kserve-kueue controller(kserve #1904/#1940)作为 LLM 推理 + 配额调度的组合,对比我们现有推理栈。
- [ ] 关注 v3.6 GA(EA2 已在 operator 主线),整理 3.6 相较 3.5 的能力差异清单。

## 原始材料

<details>
<summary>本次扫描的 release / 关键 commit / PR 清单</summary>

Release(窗口内):
- opendatahub-operator v3.6.0-ea.1(2026-09-02);主线切 rhoai-3.6-ea.2(#4043)
- kserve odh-v3.6-ea1(2026-09-03)/ odh-v3.6-EA1(2026-09-01)
- trustyai-service-operator odh-3.6-ea1(2026-09-01)
- model-registry v0.3.16(2026-08-31,窗口边缘)

commit 计数(since 2026-09-01):operator 18 / dashboard 88 / kserve 12 / notebooks 49 / DSP 12 / model-registry 26 / trustyai 16

关键 PR:
- dashboard: #9583 #9510 #9464(Data Registry)、#9637 #9485 #9557 #9565(MaaS)、#9541 #9552 #9593(gen-ai/MCP/Agent Sandbox)、#9600(Feature Store)、#9580 #9630(Kueue 配额)、#9587 #9599 #9618(platform contract)
- kserve: #1904(NetworkPolicy)、#1940(kserve-kueue Dockerfile)、#1942 #1936 #1934(module 契约测试)
- operator: #4005(结构化日志)、#4041(observability 模块)、#4052(TLS profile)、#4043(3.6-ea.2)
- trustyai: #896(SecureServing/TLS watcher)、#899(自愈)、#875 #893(module 契约/envtest)
- DSP: TLS fail-closed / 可重试 profile-fetch、OpenShift TLS RBAC overlay 收敛
- notebooks: 主要为镜像/依赖/CI 与文档,产品性变更少(#4537 ODH Kale 加入 Runtime Images)

官方博客(developers.redhat.com,OpenShift AI 标签,2026-09-03):
- Evaluate AI agents with IBM CLEAR & EvalHub on OpenShift AI
- Speeding up LLM inference with P-EAGLE in vLLM Speculators

</details>
