# OpenShift AI 周报 2026-09-01

> 扫描窗口:2026-08-25 ~ 2026-09-01(过去 7 天)。数据源:opendatahub-io 7 个核心仓 GitHub API。
> 本周非发版周,但信息量很足:MaaS 与"外部模型联邦"两条产品线同时在 dashboard 落地,operator 侧监控完成模块化拆分,KServe 侧一批 TLS/安全硬化。

## 摘要(3 条)

- **MaaS(Models-as-a-Service)+ 外部模型联邦成型**:dashboard 本周同时推进"把推理服务包成带 gateway/token 鉴权的模型即服务"(MaaS Overview tab、gateway/token auth 引导)和"聚合注册外部模型端点"(External Provider CRUD、外部模型增删、labels 管理)。这是 OAI 从"自建模型服务"往"模型接入/分发平面"扩张的明确信号。
- **可观测性完成模块化拆分**:opendatahub-operator 把 in-tree monitoring service 换成独立的 `odh-observability` operator(Helm 部署),并厘清了 service module 归 DSCI owner、component module 归 DSC owner 的所有权契约。模块化(out-of-tree module)架构继续吃掉核心 operator 的内建能力。
- **KServe 一批 TLS/安全硬化 + LLM-d 迭代**:新增 TLS profile watcher(读 OpenShift `TLSAdherencePolicy` 自动应用 Intermediate profile)、禁用 DestinationRule/PodMonitor 的 InsecureSkipVerify、LoRA 走 localModelCache;llm-d sidecar/endpoint-picker 重新 pin 到 v3.6-ea1。

## 新功能 / 能力

- [MaaS gateway/token 鉴权引导 + Overview 分页](https://github.com/opendatahub-io/odh-dashboard/pull/9346)(RHOAIENG-79255)、[MaaS Overview 分页修复](https://github.com/opendatahub-io/odh-dashboard/pull/9483) — dashboard 里 Models-as-a-Service 选型时给 gateway/token auth 加了 popover/helper text,MaaS Overview tab 独立成型。
  - 启示:OAI 正把 KServe/llm-d 的推理端点抽象成"对外可计量、带鉴权网关的 MaaS"。我们若做多租户模型服务,应把"gateway + token 限流 + 用量视图"作为一等公民,而不是让租户直接对接 InferenceService。
- [外部模型 Provider/Model 的 BFF 与 UI](https://github.com/opendatahub-io/odh-dashboard/pull/9523)(RHOAIENG-88480,PR1)、[恢复删除外部模型](https://github.com/opendatahub-io/odh-dashboard/pull/9495)、[data-registry 增加 labels 管理](https://github.com/opendatahub-io/odh-dashboard/pull/9534) — 支持注册/编辑/删除"外部 Provider + 外部 Model + Secrets",UI 通过 `make dev-bff-federated-mock` 联邦式对接。
  - 启示:OAI 在做"模型接入平面联邦"——把不在集群内自托管的第三方模型端点(OpenAI/供应商 API 等)纳入统一目录与治理。这是对标点:我们的模型目录若只覆盖自托管模型,会在"混合模型接入"上落后。建议评估把外部端点作为一类可注册资源。
- [GatewayConfig 增加 TokenReview 限流覆写](https://github.com/opendatahub-io/opendatahub-operator/pull/3932) — 允许对 TokenReview 的 rate limiting 做配置覆写,配合上面的 gateway 鉴权链路。
- [KServe:LoRA adapter 走 localModelCache](https://github.com/opendatahub-io/kserve/pull/5690) — llmisvc 支持把 LoRA 适配器纳入本地模型缓存,减少每次拉取。
  - 启示:多 LoRA 场景(一底座多微调)是当前推理降本重点,本地缓存 adapter 直接影响冷启动。值得看其缓存 key/淘汰策略。
- [KServe:TLS profile watcher + adherence policy](https://github.com/opendatahub-io/kserve/pull/1910)(RHOAIENG-78968) — 读 `apiservers.config.openshift.io/cluster` 的 `TLSAdherencePolicy`,在 NoOpinion/LegacyAdheringComponentsOnly 时应用 Intermediate profile,profile 变更时取消 manager 启动 context 优雅重启。
  - 启示:把 TLS 合规从"部署时静态配"变成"随集群策略动态收敛"。企业级安全合规差异点,值得借鉴到我们组件的 TLS 基线。

## 架构 / 依赖变化

- [可观测性模块化](https://github.com/opendatahub-io/opendatahub-operator/pull/4001)(RHOAIENG-63222) — 监控从 in-tree service handler 改为独立 `odh-observability` operator(Helm chart 部署),独立管理 Monitoring CR。所有权契约明确:**service module CR 由 DSCInitialization owner,component module(Dashboard/KServe 等)由 DataScienceCluster owner**,disable 时显式删除以触发 finalizer 清理子资源。
  - 启示:这是 OAI"核心 operator 瘦身、能力外置为独立 operator/module"路线的又一步。我们若也走 meta-operator 编排,应尽早固化 service vs component 的 owner 语义,否则卸载/finalizer 会踩坑。
- [不再由 operator 给 Dashboard CR 设 deploymentMode](https://github.com/opendatahub-io/opendatahub-operator/pull/4003)(RHOAIENG-61022) — Serverless/Raw 部署模式的决策不再硬塞进 Dashboard CR。
- [把 notebooksNamespace / modelRegistryNamespace 投影进 Dashboard CR](https://github.com/opendatahub-io/opendatahub-operator/pull/3982) — 让 dashboard 从 CR 直接拿到工作台与模型注册中心的命名空间,减少隐式约定。
- [vLLM CPU(P/Z 架构)RELATED_IMAGE](https://github.com/opendatahub-io/opendatahub-operator/pull/3996)(RHAI-121,AIPCC 迁移) + [notebooks 3.6.0-ea.1 基础镜像切 midstream](https://github.com/opendatahub-io/notebooks/pull/3678) — vLLM/工作台镜像继续走多架构(Power/Z)与 AIPCC 统一构建(hermetic/Konflux)。
  - 启示:OAI 在把 vLLM 推向 x86 之外的多架构。若我们只保 x86/GPU,异构(ARM/CPU 推理)覆盖是差距项。
- [model-registry v0.3.16](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.16) + [python-client 切 v1 端点、移除 experiment tracking](https://github.com/opendatahub-io/model-registry/pull/3114)、[catalog Python client 按 v1 spec 重生成](https://github.com/opendatahub-io/model-registry/pull/3137) — **破坏性**:python client 切到 v1 endpoints 并砍掉 experiment tracking,catalog 走 v1 spec。
  - 启示:experiment tracking 从 model-registry 剥离,实验管理会另立门户(此前有往 MLflow/独立组件收敛的迹象,dashboard 本周也在改 MLflow e2e)。若我们把实验跟踪耦合进模型注册,需要重新分层。

## 上游生态整合动向

- **KServe / llm-d**:[llm-d sidecar/endpoint-picker repin v3.6-ea1](https://github.com/opendatahub-io/kserve/commit/09db181c33453b1325ed4d95b1d637dc367acd00)、[禁用 DestinationRule/PodMonitor 的 InsecureSkipVerify](https://github.com/opendatahub-io/kserve/pull/1520)、[canary 权重限定在 predictor rules](https://github.com/opendatahub-io/kserve/pull/5944)、[autoscaler 对无 autoScaling 组件跳过 KEDA ScaledObject](https://github.com/opendatahub-io/kserve/pull/6029)、[setuptools 升级修 CVE-2025-47273](https://github.com/opendatahub-io/kserve/pull/6055)。llm-d(P/D 分离 + 智能路由)仍是 OAI 大模型推理主线。
- **Kubeflow(model-registry)**:midstream 持续 `periodic sync upstream KF to midstream ODH`,OAI 的 model-registry 基本贴着上游 Kubeflow 走。
- **NIM 重构**:[弃用旧 nim odh app](https://github.com/opendatahub-io/odh-dashboard/pull/9501),但同时[NIM wizard 优先 NVIDIA hardware profiles](https://github.com/opendatahub-io/odh-dashboard/pull/9497)、[改用项目级 NIMAccount secrets](https://github.com/opendatahub-io/odh-dashboard/pull/9515) — 不是砍 NIM,而是把 NIM 接入从"独立 app"重构进主流程 + 硬件画像。
- **TrustyAI 指标安全硬化**:一组 commit 把 Prometheus 抓取改为经 kube-rbac-proxy 鉴权、恢复 CA 校验、给 Prometheus SA 授 bearer token Secret 读权限。可信 AI 组件的指标暴露在往"默认安全"收。
- **Kubeflow Trainer 回退信号**:dashboard [移除 TrainJob node scaling](https://github.com/opendatahub-io/odh-dashboard/pull/9509) — TrainJob(Kubeflow Trainer v2)的节点扩缩在 UI 侧被撤,分布式训练集成仍在打磨。
- **前端工程**:[module remotes 从 webpack 迁 rspack](https://github.com/opendatahub-io/odh-dashboard/pull/9326)、[workbenches BFF 支持 TLS server](https://github.com/opendatahub-io/odh-dashboard/pull/9503)。

## 值得跟进

- [ ] 读 [odh-dashboard #9523](https://github.com/opendatahub-io/odh-dashboard/pull/9523) + RHOAIENG-88480 全链,搞清 OAI"外部模型 Provider"的数据模型(Provider/Model/Secret 三元组、federation 方式),对标我们模型目录是否要支持外部端点注册。
- [ ] 跟 MaaS 主线(RHOAIENG-79255 系列):OAI 的 gateway + token 限流 + 用量视图具体落在哪个组件(是否复用 llm-d gateway / Istio)。这决定我们多租户模型服务网关的选型。
- [ ] 评估 [KServe TLS profile watcher #1910](https://github.com/opendatahub-io/kserve/pull/1910) 的"随集群策略动态收敛 TLS"模式,能否推广到我们全组件的安全基线。
- [ ] 关注 [model-registry python-client v1 破坏性变更 #3114](https://github.com/opendatahub-io/model-registry/pull/3114):experiment tracking 剥离后 OAI 的实验管理落到哪(MLflow?),避免我们踩耦合。
- [ ] 观察可观测性模块化([#4001](https://github.com/opendatahub-io/opendatahub-operator/pull/4001))落地后,`odh-observability` 是否会成为可独立复用的组件。

## 原始材料(本次扫描清单)

<details>
<summary>各仓 7 天提交量与关键项</summary>

- **opendatahub-operator**:15 commits。观测性模块化(#4001)、GatewayConfig TokenReview(#3932)、停设 deploymentMode(#4003)、namespace 投影 Dashboard CR(#3982)、vLLM CPU P/Z(#3996)、模块契约/卸载(#4016 #4018)。
- **odh-dashboard**:64 commits(本周最活跃)。MaaS(#9346 #9483)、外部模型/Provider(#9523 #9495 #9534)、NIM 重构(#9501 #9497 #9515 #9449)、EvalHub(#9516 #9511)、llmd 路由配置保护(#9465)、rspack 迁移(#9326)、workbenches BFF TLS(#9503)、移除 TrainJob 扩缩(#9509)。
- **kserve**:20 commits。LoRA localModelCache(#5690)、TLS profile watcher(#1910)、禁 InsecureSkipVerify(#1520)、canary 权重(#5944)、KEDA 跳过(#6029)、CVE-2025-47273(#6055)、llm-d repin v3.6-ea1、autogluon 加载安全(#5803)。
- **notebooks**:29 commits。多为 3.6.0-ea.1 基础镜像更新(CUDA 12.9/13.0、ROCm 7.14、CPU el9.8)、hermetic/Konflux 构建、codeserver 去 seccomp(#4457)、基础镜像切 midstream(#3678)。
- **data-science-pipelines-operator**:0 commits(本周无更新,最新发版仍是 2025-11 的 v2.18.0)。
- **model-registry**:18 commits + [v0.3.16 发版](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.16)。catalog v1 spec 重生成(#3137)、python-client 切 v1 去 experiment tracking(#3114)、catalog GenericRepository 重构(#3111);其余为 KF 上游同步与 deps bump。
- **trustyai-service-operator**:12 commits。Prometheus 抓取走 kube-rbac-proxy 鉴权 + CA 校验一组 fix、inspect adapter 升级、evalhub/lm-eval 指标同步。

</details>
