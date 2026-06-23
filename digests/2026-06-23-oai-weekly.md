# OpenShift AI 周报 2026-06-23

扫描窗口:2026-06-16 ~ 2026-06-23,7 个 opendatahub-io 主仓 + 相关上游(kserve/kserve、trustyai-explainability)。本周是 **v3.5 EA2 冲刺周**,活动密集(operator 21 / dashboard 58 / kserve 37 / notebooks 52 / model-registry 41 commit),围绕四条主线推进:Models-as-a-Service、Agent 平台、llm-d 分布式推理、机密推理。

## 摘要(3 条以内)

- **MaaS(Models-as-a-Service)正在成为 v3.5 一等组件**:operator 把 MaaS 监控资源迁到独立 monitoring namespace、DSC 默认样例加入 `modelsAsService`,dashboard 侧补齐 API Key 管理与 LLMISVC 清理。这是把"模型即托管 API 端点 + 配额/密钥"产品化的关键拼图。
- **KServe 同时落地两项重磅能力**:上游合入"机密模型服务"(TEE + 硬件证明 + KBS 解密加密模型)和 AutoGluon Server(新增时序预测),并把 llm-d 组件拉到 v0.8.0/router v0.9.0-rc.2、GIE 升到 v1.5.0(带本地 InferencePool v1alpha2 shim)。
- **Agent 平台从 UI 到 BFF 成形**:dashboard 新增 agent-ops(Agent 部署列表、kagenti AgentRuntime 卡片)、gen-ai Agent 画像预览;TrustyAI 把 NeMo Guardrails 接入 MCP Gateway(EnvoyFilter 拦截),Agent 的"运行 + 治理"两端同步推进。

## 新功能 / 能力

- [机密模型服务 Confidential Model Serving (kserve #5382)](https://github.com/kserve/kserve/pull/5382) — 在 `PredictorExtensionSpec`(v1beta1)和 `LLMModelSpec`(v1alpha2)加 `ConfidentialSpec{enabled,resourceId}`;加密模型工件只在 TEE 内、经硬件证明后由 KBS(`kbs:///<repo>/<type>/<tag>`)解密,webhook 给 storage-initializer 注入 `CONFIDENTIAL_*` 环境变量。
  - 启示:这是面向金融/政企/主权 AI 的差异化卖点——"模型权重对平台运营方也不可见"。我们若主打企业级合规,应评估 CoCo(Confidential Containers)/ TEE 链路,至少在路线图上对齐 KBS 式密钥代理 + attestation 的模型解密方案,否则在监管客户处会被这一条卡掉。
- [AutoGluon Server 支持时序预测 (kserve #5269)](https://github.com/kserve/kserve/pull/5269) — `autogluonserver` 运行时新增 `TimeSeriesPredictor`,与既有 `TabularPredictor` 并存,ClusterServingRuntime 支持 v1/v2 协议。dashboard 侧同步推进 AutoML 配置流([AutoGluon preset 选择 #7782](https://github.com/opendatahub-io/odh-dashboard/pull/7782)、[预测类型推荐重设计 #7890](https://github.com/opendatahub-io/odh-dashboard/pull/7890)、[表格评估指标拆分二分类/多分类 #8179](https://github.com/opendatahub-io/odh-dashboard/pull/8179))。
  - 启示:OAI 在补"低代码 AutoML(表格 + 时序)"这块传统 ML 短板,目标是非深度学习的企业数据科学场景。我们的产品如果只盯 LLM/GenAI,会在"经典预测类"招标里失分;可考虑以 KServe AutoGluon runtime 形式低成本补齐。
- [Kueue `autoCreateQueues` 开关 (operator #3648)](https://github.com/opendatahub-io/opendatahub-operator/pull/3648) — DSC 的 Kueue 组件配置新增布尔位,默认 `false`:关闭时不再自动创建默认 `ClusterQueue/LocalQueue/ResourceFlavor`,把队列拓扑交给集群管理员手工管控。
  - 启示:从"开箱即用默认队列"转向"管理员显式定义配额拓扑",是多租户 GPU 调度走向生产严肃化的信号。我们做 GPU 配额/队列时应提供类似"托管默认 vs 完全自管"两档,别强塞默认 CR 污染客户命名空间。
- [Kale 集成进 Notebooks (notebooks #3677, RHOAIENG-62436)](https://github.com/opendatahub-io/notebooks/pull/3677) — 首次把 Kale(Notebook → Kubeflow Pipelines 自动转换)打进 RHOAI workbench 镜像。
  - 启示:降低"从交互式实验到流水线"的门槛。我们的 Notebook 镜像若想对标,需要类似 notebook→pipeline 的一键转化体验,而非让用户手写 DSL。
- [Model Registry 引入安全评估目录 (model-registry #2779/#2814)](https://github.com/opendatahub-io/model-registry/pull/2779) — catalog 新增 `security-evaluations.ndjson` 加载器与 Artifacts 端点 `security-metrics` 枚举,模型条目可携带安全评估元数据;[#2819](https://github.com/opendatahub-io/model-registry/pull/2819) 加 `orderBy=RECOMMENDED`。
  - 启示:模型注册中心正从"血缘 + 版本"扩展到"安全/合规评分"维度,呼应企业模型准入治理。我们的模型生命周期产品应预留可挂载第三方/自有安全评测结果的元数据槽位。

## 架构 / 依赖变化

- [GIE 升级 v1.3.1 → v1.5.0 + 本地 InferencePool v1alpha2 shim (kserve #5571)](https://github.com/kserve/kserve/pull/5571) — Gateway API Inference Extension 升级;为绕开 KEDA v2.18 的 controller-runtime v0.19 与 k8s v0.35 informer 崩溃,把 `k8s.io/*` 钉在 v0.34.x、controller-runtime v0.22.5,并自带 v1alpha2↔v1 转换 shim 保持 LLMISVC 控制器向后兼容。
  - 启示:GIE 在 v1alpha2→v1 迁移期会持续踩版本地雷。我们若集成 Gateway API 推理扩展,要预留转换 shim,别直接吃上游最新 API 版本。
- [llm-d 组件升级到 v0.8.0 / router v0.9.0-rc.2 (kserve #5596)](https://github.com/kserve/kserve/pull/5596) — `llm-d-inference-scheduler` 更名为 `llm-d-router-endpoint-picker`、`llm-d-routing-sidecar` 更名为 `llm-d-router-disagg-sidecar`,伴随 scheduler 迁移;ODH fork 同步 bump 镜像([8e490cf 重命名后切镜像](https://github.com/opendatahub-io/kserve/commit/8e490cf))。
  - 启示:llm-d(分离式 prefill/decode + 智能路由)是 OAI 大模型推理的底座,且组件命名/架构仍在快速翻动。跟进 llm-d 时要以"上游 rc 版本 + 频繁重命名"为常态,绑死稳定 tag。
- [DSPO 改用 Go 1.26.3 原生 FIPS (data-science-pipelines-operator)](https://github.com/opendatahub-io/data-science-pipelines-operator) — 移除旧 FIPS wrapper 命令,改 `GODEBUG=fips140=on`(从 Dockerfile 迁到 go.mod)、`GOTOOLCHAIN=local`,统一走 Go 1.26.3 原生 FIPS。
  - 启示:Go 1.26 原生 FIPS 模式是合规交付的简化路径,值得我们所有 Go 组件跟进——少一层 wrapper、少一类构建坑。
- [Operator 收敛 RBAC 权限 (operator #3642)](https://github.com/opendatahub-io/opendatahub-operator/pull/3642) — 从 operator ClusterRole 移除通配的 SCC `use` verb;[gateway kube-auth-proxy 按 APIServer 配置增强 TLS (#3620)](https://github.com/opendatahub-io/opendatahub-operator/pull/3620)。
  - 启示:最小权限收口 + 网关侧 TLS 跟随集群 APIServer 设置,是企业安全基线动作,可直接对照自查我们 operator 的 ClusterRole 是否还有 wildcard。

## 上游生态整合动向

- **KServe / llm-d**:见上,机密推理、AutoGluon、GIE v1.5.0、llm-d v0.8.0;另 [mlserver 运行时用 image volume 替代 model car (#1640)](https://github.com/opendatahub-io/kserve/pull/1640)、[kserve-module 暴露 oauthProxy/NIM/TLS 等可配项 (#1635/#1634/#1622)](https://github.com/opendatahub-io/kserve/pull/1635)。
- **NeMo Guardrails / MCP**:[TrustyAI 把 MCP Gateway 接入 NeMo Guardrails (trustyai #735, RHAISTRAT-1721)](https://github.com/trustyai-explainability/trustyai-service-operator/pull/735) — operator 发现同名 MCP Gateway 与 NeMo BBR 插件后,部署一个剥离 SSE framing 的 EnvoyFilter,实现对 MCP 服务响应的护栏。这是"Agent/工具调用链路的运行时安全"落地。
- **EvalHub / lm-evaluation-harness**:[EvalHub 社区 provider 升 v0.3.0 (trustyai #781)](https://github.com/opendatahub-io/trustyai-service-operator)、[给 lm-eval-harness provider 注入 agent 元数据 (#773)](https://github.com/opendatahub-io/trustyai-service-operator);模型评估正向 Agent 场景延伸。
- **Kubeflow / Kale**:notebooks 集成 Kale(见上);model-registry 持续从 kubeflow/model-registry 同步上游([#1787 等多次 merge](https://github.com/opendatahub-io/model-registry/pull/1787))。
- **kagenti(Agent runtime)**:[dashboard 用 kagenti AgentRuntime 卡片丰富 BFF agent 详情 (#8142)](https://github.com/opendatahub-io/odh-dashboard/pull/8142)、[agent-ops BFF 接入 mod-arch manifests (#7800)](https://github.com/opendatahub-io/odh-dashboard/pull/7800) — OAI 的 Agent 运行时押注 kagenti。

## 值得跟进

- [ ] **机密推理可行性**:精读 [kserve #5382](https://github.com/kserve/kserve/pull/5382),评估 KBS + attestation 链路能否落到我们的推理栈;判断目标客户(金融/政务)是否真有 TEE 模型保护刚需。
- [ ] **MaaS 端到端拆解**:看 [models-as-a-service #985](https://github.com/opendatahub-io/models-as-a-service/pull/985) + operator #3652 + dashboard MaaS API key 改动([#8118](https://github.com/opendatahub-io/odh-dashboard/pull/8118)),弄清 OAI 的"模型即 API + 密钥 + 配额 + 监控"完整产品形态,对照我们差距。
- [ ] **Agent 平台对标**:跟踪 dashboard agent-ops / gen-ai 与 kagenti AgentRuntime,评估我们是否需要一等的 Agent 部署/治理界面。
- [ ] **Kueue 多租配额范式**:试用 `autoCreateQueues=false`,设计我们 GPU 队列产品的"托管默认 vs 完全自管"两档。
- [ ] **Go 1.26 原生 FIPS**:把我们 Go 组件迁到 `GODEBUG=fips140=on`,参考 DSPO 的 go.mod 写法。

## 原始材料

<details>
<summary>关键 release(7 天内)</summary>

- opendatahub-operator: [v3.5.0-ea.2](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.5.0-ea.2)(2026-06-17,汇总各组件 EA2:trainer/trustyai/notebooks v1.45/feast v0.64/dashboard v3.4.4-odh/ray v1.4.4/model-registry v0.3.10/spark/kserve odh-v3.5-EA2/ogx)
- kserve(ODH fork): [v3.5.0+rhaiv.0](https://github.com/opendatahub-io/kserve/releases/tag/v3.5.0+rhaiv.0)(2026-06-22)、[v3.5.0-rhaiv.0](https://github.com/opendatahub-io/kserve/releases/tag/v3.5.0-rhaiv.0)(2026-06-18)
- odh-dashboard: [v3.4.4-odh](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.4-odh)(2026-06-15)
- notebooks: [v1.45.0 / 3.5_ea2](https://github.com/opendatahub-io/notebooks/releases/tag/v1.45.0)(2026-06-12)
- model-registry: [v0.3.10](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.10)(2026-06-15)
- trustyai-service-operator: [odh-3.5-ea2](https://github.com/opendatahub-io/trustyai-service-operator/releases/tag/odh-3.5-ea2)(2026-06-12)

</details>

<details>
<summary>commit 量(过去 7 天)</summary>

- opendatahub-operator: 21 — MaaS 监控 namespace、Kueue autoCreateQueues、gateway TLS、RBAC 去 wildcard、modelsAsService 默认样例、llm-d 镜像重命名切换
- odh-dashboard: 58 — agent-ops、gen-ai agent 画像、AutoML(AutoGluon/表格评估)、autorag、MaaS API key、dashboard module controller 迁移、Go 1.26
- kserve(ODH fork): 37 — 上游同步(机密推理/AutoGluon/GIE v1.5.0/llm-d v0.8.0)、kserve-module 可配置项(oauthProxy/NIM/TLS)、image volume 替代 model car
- notebooks: 52 — Kale 集成、CUDA 13.0/12.9 base 镜像、k8s 1.36 CI、CVE/锁文件更新
- data-science-pipelines-operator: 13 — Go 1.26.3 原生 FIPS 迁移、DSPA 就绪检查增强
- model-registry: 41 — catalog 安全评估目录、security-metrics 枚举、RECOMMENDED 排序、大量 deps bump、kubeflow 上游同步
- trustyai-service-operator: 13 — MCP Gateway/NeMo Guardrails、EvalHub provider v0.3.0、policy conftest 增强

</details>
