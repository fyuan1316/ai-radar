# OpenShift AI 周报 2026-10-13

> 扫描窗口:2026-10-06 ~ 2026-10-13(过去 7 天),7 个 opendatahub-io 仓库全部有实质提交。
> 大背景:官方自管版 GA 流仍是 2.25.x(2.25.11,2026-09 安全更新),而上游主线这周几乎所有大改动都打着 **RHOAI 3.6** 标签——下一个大版本的组件重构正在主线密集落地。

## 摘要(3 条)

- **RHOAI 3.6 组件大重构进入主线深水区**:operator 引入 `DataScienceCluster` v3 API 并重排组件,把 modelregistry 模块整体改名为 **aihub**、feastoperator 改名,v3 转换里彻底丢掉 WVA。这是面向 3.6 的 API 破坏性演进,不是修补。
- **MaaS(Models-as-a-Service)门户成型**:dashboard 这周一大批提交把产品正式定名 "MaaS Portal",消费者门户加了可观测性面板、InferencePriority 优先级、无项目直接展示模型、部署后横幅——一个多租户"模型即服务"市场雏形。
- **KServe 推理面同时推进 P/D 分离与模型分发**:llmisvc 加入 opt-in 的 `DisaggregatedSet`(prefill/decode 分离)后端,并把 **ModelExpress** 模型缓存/分发 operator 作为 opt-in 组件接入;3.6 起不再部署 WVA。

## 新功能 / 能力

- [DataScienceCluster v3 for RHOAI 3.6 组件重排](https://github.com/opendatahub-io/opendatahub-operator/pull/4137) — 新增 DSC v3 API,配合 3.6 的组件重组(RHOAIENG-94804)。
  - 启示:我们对标的产品正在做一次"控制面 CRD 大版本跃迁",v2→v3 带转换逻辑。我们若也有类似顶层 CRD,要提前规划多版本共存/转换 webhook 的策略,别等到破坏性改动才补。
- [把 modelregistry 模块改名为 aihub](https://github.com/opendatahub-io/opendatahub-operator/pull/4177) + [feastoperator 改名](https://github.com/opendatahub-io/opendatahub-operator/pull/4178) + [重命名后清理](https://github.com/opendatahub-io/opendatahub-operator/pull/4180) — "模型注册中心"被重新定位成 **aihub**(AI 资产中枢),不止是 registry。
  - 启示:信号是把"模型注册"升格为"AI 资产中心(模型/数据/特征一体)"。值得看 aihub 最终收纳哪些能力——可能是他们模型生命周期的新聚合点。
- [MaaS 消费者门户加可观测性面板](https://github.com/opendatahub-io/odh-dashboard/pull/9957) — 复用 Perses 面板,消费者按可访问项目看模型调用监控,核心 dashboard 被移除时门户仍独立可用。
  - 启示:MaaS 门户被设计成能脱离主 dashboard 独立运行,这是"给外部消费者/租户的自助界面"思路。我们做多租户模型服务时,消费侧和管理侧界面应解耦。
- [MaaS 用 InferencePriority 取代 Priority](https://github.com/opendatahub-io/odh-dashboard/pull/10193)、[无项目也展示 MaaS 模型](https://github.com/opendatahub-io/odh-dashboard/pull/10104)、[内外部模型部署后横幅](https://github.com/opendatahub-io/odh-dashboard/pull/9992) — MaaS 门户的租户体验细化。
- [Gen AI Studio 默认项 转 GA](https://github.com/opendatahub-io/odh-dashboard/pull/10106) — Gen AI Studio 从预览默认值升为 GA 默认值(RHOAIENG-96312/96313)。
  - 启示:他们的"生成式 AI 工作室"正式进入 GA 节奏,Playground + Agent + RAG 一整套在收口。对标时这块已不是实验特性。
- [Playground 支持音频附件播放](https://github.com/opendatahub-io/odh-dashboard/pull/10034)、[文档附件追踪](https://github.com/opendatahub-io/odh-dashboard/pull/10192)、[AutoRAG BFF responses 端点](https://github.com/opendatahub-io/odh-dashboard/pull/9695) — Playground 走向多模态(音频转写、文档上传)+ 自动 RAG。
- [从 runtime library 镜像安装 LLM 加速器配置 / Serving runtime 模板](https://github.com/opendatahub-io/odh-dashboard/pull/10187) + [runtime 镜像库落地页](https://github.com/opendatahub-io/odh-dashboard/pull/10081) — 运行时/加速器配置改为从镜像库一键安装,配套向导。
  - 启示:把"serving runtime + 加速器配置"做成可从镜像库拉取的制品,降低用户手配门槛。我们 runtime 管理可借鉴这种"模板市场 + 向导"模式。
- [EvalHub 加 gallery 标签页](https://github.com/opendatahub-io/odh-dashboard/pull/10141) — 评测中心加入画廊式入口(配合 trustyai 侧 EvalHub provider 扩张)。
- [data-science-pipelines:Managed Pipelines 默认启用](https://github.com/opendatahub-io/data-science-pipelines-operator/commit/24a4fd6) + [新增 enabled 字段与处理逻辑](https://github.com/opendatahub-io/data-science-pipelines-operator/commit/05ff899) — 托管流水线从可选变默认开。
- [model-registry:serving runtime catalog 接受 Template 包装与 minimumRHOAIVersion](https://github.com/opendatahub-io/model-registry/pull/1913) — 让 odh-model-controller 的 OpenShift Template 形态 runtime 能进目录,并支持按最低 RHOAI 版本过滤(此前严格校验导致 24 个 runtime 家族 0 加载)。
  - 启示:他们在建"serving runtime 目录",带版本门槛字段。做模型/运行时市场时,"按平台版本声明兼容性"是个必要维度。

## 架构 / 依赖变化

- [DSC v3 转换中彻底丢掉 WVA](https://github.com/opendatahub-io/opendatahub-operator/pull/4174) + [KServe 在 RHOAI 3.6 永不部署 WVA](https://github.com/opendatahub-io/kserve/pull/2006) — WVA(workload/vLLM 相关旧组件)在 3.6 被下线。
- [KServe 接入 ModelExpress operator(opt-in)](https://github.com/opendatahub-io/kserve/pull/2040) — 以和 WVA 同样的方式作为 KServe 模块组件安装,默认 `Removed`;渲染 `overlays/odh` 与 `overlays/odh-xks` 两套,报告 `ModelExpressReady`,移除时保留 CRD 并等 `auth-delegator` finalizer 释放。ModelExpress 做模型缓存/分发。
  - 启示:他们在推理面之外单独立了一个"模型分发/缓存"控制面(ModelExpress),opt-in 接入。大模型权重分发是独立问题域,值得评估我们是否也要拆出专门的模型分发层。
- [operator gateway 为每个附加 ingress 桥接 OpenShift Route](https://github.com/opendatahub-io/opendatahub-operator/pull/4136) + [XKS GatewayConfig 准入校验](https://github.com/opendatahub-io/opendatahub-operator/pull/4095) — 多 ingress/网关走 Gateway API + reencrypt Route,按 ingress 粒度报就绪与冲突隔离。
- [operator 移除 TrustyAI CRD ownership 并删除 FeatureTracker API](https://github.com/opendatahub-io/opendatahub-operator/pull/4175) — 清理旧 API。
- [独立依赖监控 / DSCI 日志投射到 Monitoring CR](https://github.com/opendatahub-io/opendatahub-operator/pull/4155) — 可观测性向 Monitoring CR 聚合。
- [notebooks:opt-in RHOAI baseline ImageStreams](https://github.com/opendatahub-io/notebooks/pull/4745) + AIPCC base 镜像升级(cuda 13.0 / 12.9、rocm 7.14) — 工作台镜像换到 AIPCC 统一基础镜像流,新增 jupyter-universal 镜像线。

## 上游生态整合动向

- **KServe / vLLM(P/D 分离)**:[llmisvc 加 opt-in DisaggregatedSet 后端(commit 7506077)](https://github.com/opendatahub-io/kserve/commit/7506077) 对应上游 kserve #6330,把 prefill/decode 分离部署作为 LLMInferenceService 的一种后端。这是 vLLM 社区 P/D disaggregation 在 KServe 控制面的落地。
  - 启示:P/D 分离已从论文/vLLM 特性变成推理 CRD 的一等后端。我们推理产品要把"是否分离部署"做成声明式开关。
- **model-registry ↔ LLMInferenceService**:[把 llmInferenceServiceTemplate 改名为 llmInferenceServiceConfig](https://github.com/opendatahub-io/model-registry/pull/1912) — registry 侧对齐 KServe 的 LLMInferenceService 配置命名。
- **TrustyAI / 评测生态**:EvalHub 这周爆发式迭代——[每 Job 的 ingress/egress NetworkPolicy](https://github.com/opendatahub-io/trustyai-service-operator/pull/980)、[API ingress 网络策略](https://github.com/opendatahub-io/trustyai-service-operator/pull/983)、[Job NetworkPolicy 权限](https://github.com/opendatahub-io/trustyai-service-operator/pull/985),并新纳管 ToolEval / FollowBench / IFBench 等评测 provider、升级 Inspect/RULER/GuideLLM 适配镜像。
  - 启示:评测中心在往"多 benchmark provider + 每任务网络隔离"方向做,安全隔离做得很细。我们若做模型评测,provider 插件化 + 任务级 NetworkPolicy 是可直接抄的工程范式。
- **Guardrails 路线切换**:[从 operator 删除 FMS Guardrails(GuardrailsOrchestrator)整套生态](https://github.com/opendatahub-io/trustyai-service-operator/pull/902),同时 [NeMo guardrails 的 Status.Endpoint/就绪跟随 rollout](https://github.com/opendatahub-io/trustyai-service-operator/commit/b7ada7b) 在完善。
  - 启示:护栏方案从 FMS 转向 NeMo Guardrails。对标安全合规能力时,护栏技术栈选型他们已经换队,值得确认我们站哪边。

## 值得跟进

- [ ] 精读 [DSC v3 PR #4137](https://github.com/opendatahub-io/opendatahub-operator/pull/4137),搞清 3.6 组件重组后的顶层 CRD 结构与 v2→v3 转换方式,评估对我们控制面 API 版本策略的借鉴。
- [ ] 跟 [ModelExpress operator](https://github.com/opendatahub-io/modelexpress) + [KServe 接入 #2040](https://github.com/opendatahub-io/kserve/pull/2040):模型分发/缓存是否该从推理面独立成层。
- [ ] 评估 [llmisvc DisaggregatedSet(P/D 分离,commit 7506077)](https://github.com/opendatahub-io/kserve/commit/7506077) 对应的上游 kserve #6330,确认我们推理产品的 P/D 分离部署路线。
- [ ] 摸清 "aihub"([#4177](https://github.com/opendatahub-io/opendatahub-operator/pull/4177))的最终定位——是不是把模型/特征/数据注册合并成一个 AI 资产中枢。
- [ ] 跟进护栏栈从 FMS 迁到 NeMo Guardrails([#902](https://github.com/opendatahub-io/trustyai-service-operator/pull/902)),对照我们安全合规方案选型。

## 原始材料

<details>
<summary>本周扫描清单(7 repo,2026-10-06~10-13)</summary>

commit 数:opendatahub-operator 23、odh-dashboard 93、kserve 16、notebooks 31、data-science-pipelines-operator 15、model-registry 3、trustyai-service-operator 36。本周 7 仓均无新 release(releases 页无 7 天内条目)。

**opendatahub-operator**:#4137 DSC v3、#4177/#4180 modelregistry→aihub、#4178 feastoperator 改名、#4174 drop WVA from v3、#4172 DatabaseService ModuleHandler skeleton、#4173 独立依赖监控、#4155 DSCI 日志投射 Monitoring、#4175 删 TrustyAI CRD ownership + FeatureTracker API、#4136 gateway 桥接附加 ingress、#4095 XKS GatewayConfig 准入校验、#4090 workbenches baseline image manifest、#4191 adopt framework utility APIs。

**odh-dashboard**:#10193 MaaS InferencePriority、#10187/#10181/#10081/#9995 runtime library 镜像安装向导、#9957 MaaS 可观测性门户、#10134/#10135/#10138/#10150/#10166 MaaS Portal 重命名、#10104 无项目展示 MaaS 模型、#9992 部署后横幅、#10106 Gen AI Studio GA 默认、#10034 Playground 音频、#10192 文档附件、#9695 AutoRAG BFF、#10141 EvalHub gallery、#10180 Infrastructure workloads 表、#10017/#10102/#10088 agent 部署与可观测性、#10157 dataRegistry 配置。

**kserve**:#2040 ModelExpress opt-in、#6330(llmisvc DisaggregatedSet P/D,commit 7506077)、#2006 3.6 不部署 WVA、#2077 kserve-module extraCleanup、#6351 KernelCache E2E、#6366 恢复 agent watcher(SSRF 存储校验)。

**notebooks**:#4745 RHOAI baseline ImageStreams opt-in、jupyter-universal 镜像线、AIPCC base 镜像升级(cuda 13.0/12.9、rocm 7.14、cpu el9.8)、rpms.lock 更新。

**data-science-pipelines-operator**:Managed Pipelines 默认启用(24a4fd6)+ enabled 字段(05ff899)、RetrievePipelineId 响应大小限制(6020bbc)、MLMD Envoy 限 IPv4(ff61cf1/ff480e5)、apiserver startup probe(4b71a6e)、MinIO→RustFS 测试夹具(c729022)。

**model-registry**:#1913 catalog 接受 Template 包装 + minimumRHOAIVersion、#1909 serving runtime 加载前校验、#1912 llmInferenceServiceTemplate→llmInferenceServiceConfig。

**trustyai-service-operator**:#980 per-job ingress/egress 策略、#983 API ingress 网络策略、#985 Job NetworkPolicy 权限、#981 共享 operand 网络策略底座、#992 ToolEval provider、#1001/6ffc7c5 FollowBench、#991 IFBench、#902 删 FMS Guardrails 生态、NeMo guardrails 端点/就绪完善、Inspect→v0.6.9、GuideLLM→v0.6.1。

</details>
