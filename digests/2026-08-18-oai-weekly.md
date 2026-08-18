# OpenShift AI 周报 2026-08-18

扫描窗口:2026-08-11 ~ 2026-08-18(过去 7 天)。数据源为 opendatahub-io 七个核心仓库的 commit / PR / release,官方 release notes 仅确认当前公开线为 3.5 EA2,实际研发主线已进入 3.6。

## 摘要(3 条以内)

- **训练栈换代确定**:RHOAI 3.6 正式弃用 Kubeflow Training Operator v1(KFTO),operator 层已删除 v1 handler 并禁用组件,Kubeflow Trainer v2 成为唯一训练路径。这是本周最有产品影响的变化。
- **GenAI / MaaS 产品化提速**:新增独立的 MaaS Consumer Portal distribution、OpenAI 兼容的 `/v1/chat/completions` 代理、eval-hub 实时评估与失败诊断、AutoRAG/AutoML 流水线节点——OAI 正把"模型即服务 + 生成式应用平台"做成一条完整产品线。
- **推理与调度继续深化**:KServe 全控制器启用 SecureServing 指标 RBAC(替换 kube-rbac-proxy),llmisvc 支持 KEDA 真正 scale-to-zero;dashboard 侧把 llm-d 路由/拓扑、Kueue 动态准入(停/启 + 队列排位)做进部署设置。

## 新功能 / 能力

- [弃用 Training Operator v1、禁用组件(RHOAI 3.6)](https://github.com/opendatahub-io/opendatahub-operator/pull/3868) — v1 handler 整体移除,弃用状态检查内联进 DSC reconciler,新集群不再安装 KFTO 的 CRD/informer;Trainer v2 为替代品。
  - 启示:如果我们训练能力仍绑 KFTO v1 API(`PyTorchJob`/`TFJob` 等),需要立刻规划向 Trainer v2(`TrainJob` + runtime)的迁移路径,并评估存量用户作业的兼容层;这是对标 OAI 无法回避的一步。
- [MaaS Consumer Portal distribution](https://github.com/opendatahub-io/odh-dashboard/pull/9072) — 新增 `distributions/maas-customer-portal/`,把 `maas` + `gen-ai` 打包成面向消费者的门户:API key 管理、AI 资产端点、MaaS 治理(admin-only)、内置 playground。
  - 启示:OAI 把"平台管理面"和"API 消费面"拆成两个独立发行物,这是把内部模型服务对外变现的关键动作。我们若要做企业内 MaaS,应参考其"治理归管理员、消费门户归用户"的边界切分。
- [GenAI `/v1/chat/completions` 代理处理器](https://github.com/opendatahub-io/odh-dashboard/pull/9279) — BFF 层实现 OpenAI 兼容的透明代理(非流式先落地),按 namespace 把模型解析到具体上游端点并带凭据转发。
  - 启示:统一 OpenAI 兼容入口是 GenAI 应用接入的刚需;我们的推理网关如果还没有 namespace 级别的模型解析 + 凭据注入,应补齐,流式(SSE)是下一步。
- [eval-hub:实时评估进度与状态可见性](https://github.com/opendatahub-io/odh-dashboard/pull/9258) 与 [评估任务可操作失败诊断](https://github.com/opendatahub-io/odh-dashboard/pull/9228) — 模型评测从"黑盒批处理"走向实时进度 + 可诊断失败。
  - 启示:模型评测正成为 OAI 的一等公民能力,面向企业"上线前必须评估"的合规诉求。我们若只有离线评测脚本,差距明显。
- [AutoRAG/AutoML 流水线节点图标与任务分类](https://github.com/opendatahub-io/odh-dashboard/pull/9155)、[从模式结果启动文档索引运行](https://github.com/opendatahub-io/odh-dashboard/pull/9314) — RAG/AutoML 被建模成流水线节点,索引可从检索模式结果直接触发。
- [Feature Store(Feast)管理页接入导航](https://github.com/opendatahub-io/odh-dashboard/pull/9233) + [创建向导](https://github.com/opendatahub-io/odh-dashboard/pull/9092) + [admin ClusterRole 授予 featurestores CRUD](https://github.com/opendatahub-io/opendatahub-operator/pull/3892) — Feast 从"能装"走向"平台管理员可全集群管理"的一等集成。
  - 启示:特征存储正被纳入 AI 平台标配;注意其用 `SelfSubjectAccessReview` + admin group ClusterRole 的权限模型,是多租户下开放新 CRD 的通用模式,可复用到我们自定义资源。
- [部署向导追踪 Model Deployed/Updated 事件](https://github.com/opendatahub-io/odh-dashboard/pull/9251)、[部署表展示模型能力列](https://github.com/opendatahub-io/odh-dashboard/pull/9249)、[modelCapabilities 特性开关入 CRD](https://github.com/opendatahub-io/odh-dashboard/pull/9267) — 模型"能力"(如工具调用)成为可展示、可路由的一等属性。
- [分布式工作负载支持 LeaderWorkerSet](https://github.com/opendatahub-io/odh-dashboard/pull/8921) — 为多节点推理/训练引入 LWS 编排原语。

## 架构 / 依赖变化

- [KServe 全控制器启用 SecureServing 指标端点](https://github.com/opendatahub-io/kserve/pull/1871) — 用 controller-runtime 内置 SecureServing 替换已移除的 kube-rbac-proxy sidecar,四个控制器(kserve/llmisvc/localmodel/localmodelnode)统一加 `--metrics-secure` / `--metrics-cert-path`,并配 authn/authz RBAC。
  - 启示:上游正去掉 kube-rbac-proxy 这个历史包袱;我们若在推理组件里还挂着 kube-rbac-proxy sidecar,可跟随迁移,减一个 sidecar、少一层运维。
- KServe [llmisvc 允许 `idleReplicaCount=0` 实现真正的 KEDA scale-to-zero](https://github.com/kserve/kserve/pull/5996)(上游 2026-08-11 合并,经 sync 进 odh fork) — LLM 服务空闲可缩到 0 副本。
  - 启示:LLM 推理成本敏感,scale-to-zero 是降本关键;与 llm-d 路由 + KEDA 组合评估,能显著压低长尾模型的常驻开销。
- opendatahub-operator:[在内建组件上打平台 release 版本戳(RHOAIENG-76106)](https://github.com/opendatahub-io/opendatahub-operator/pull/3966)、[从 bundle CRD 剥离 spec.conversion 交由 OLM 拥有(RHOAIENG-76183)](https://github.com/opendatahub-io/opendatahub-operator/pull/3962)、[为 RHOAI 解绑 kuberay 镜像 digest](https://github.com/opendatahub-io/opendatahub-operator/pull/3959)。
- notebooks:[移除 imagestream 上的 Kubeflow-Training v1 SDK 注解(RHOAIENG-81891)](https://github.com/opendatahub-io/notebooks/pull/4360) — 与 Training v1 弃用呼应;工作台镜像开始清理 v1 SDK 痕迹。
- odh-dashboard:[Fastify 4→5 升级被回退(#9202→#9295)](https://github.com/opendatahub-io/odh-dashboard/pull/9295),说明 BFF 框架大版本升级还有阻塞项;[PatternFly 升到 ~6.5 并集中 MF 共享模块策略](https://github.com/opendatahub-io/odh-dashboard/pull/8660)。

## 上游生态整合动向

- **Kubeflow Trainer v2**:成为 RHOAI 训练的唯一路径(见 operator #3868 + notebooks #4360),KFTO v1 退场。
- **model-registry**:持续从 `kubeflow/model-registry` 上游 sync([a08ada1](https://github.com/opendatahub-io/odh-dashboard/pull/9270)、[eb5ba42](https://github.com/opendatahub-io/odh-dashboard/pull/9246));新增 [MCP 详情页 serverJson 段](https://github.com/opendatahub-io/model-registry/pull/3068) 与 agent catalog source——模型注册中心正扩成"含 MCP server / agent 的资产目录"。
- **llm-d**:dashboard 把 [llm-d 路由配置](https://github.com/opendatahub-io/odh-dashboard/pull/9227) 与 [拓扑配置](https://github.com/opendatahub-io/odh-dashboard/pull/9210) 迁进"模型部署设置"标签页(`modelDeploymentSettings` 特性开关后),llm-d 正从实验走向产品化配置面。
- **Kueue**:[停/启 readmission + 队列排位 API](https://github.com/opendatahub-io/odh-dashboard/pull/9308)、[部署面展示 Kueue 状态](https://github.com/opendatahub-io/odh-dashboard/pull/9235)——GPU 排队/抢占从后台走到前台可操作。
- **KEDA + LeaderWorkerSet**:scale-to-zero(KServe llmisvc)与 LWS(分布式工作负载 #8921)进入编排层。
- **TrustyAI / eval**:[evalhub 从上游同步 collections 与 providers](https://github.com/opendatahub-io/trustyai-service-operator/pull/876),评测能力对齐上游 provider 生态。

## 值得跟进

- [ ] 读 [operator#3868](https://github.com/opendatahub-io/opendatahub-operator/pull/3868) 及其迁移设计文档,评估我们训练能力对 Kubeflow Trainer v2(`TrainJob` + ClusterTrainingRuntime)的兼容与迁移工作量,给存量 KFTO v1 用户一个过渡方案。
- [ ] 拆解 [MaaS Consumer Portal #9072](https://github.com/opendatahub-io/odh-dashboard/pull/9072) 的 distribution 架构(管理面 vs 消费面切分、API key/治理边界),对标我们的模型服务门户设计。
- [ ] 评估 [KServe SecureServing #1871](https://github.com/opendatahub-io/kserve/pull/1871):我们推理组件是否还依赖 kube-rbac-proxy sidecar,能否跟随去掉。
- [ ] 验证 "llm-d 路由 + KEDA scale-to-zero(llmisvc idleReplicaCount=0)" 组合对长尾 LLM 常驻成本的实际影响,作为我们推理平台降本的候选方案。
- [ ] 跟进 model-registry 向"含 MCP server / agent catalog"演进(#3068),判断我们的模型注册中心是否要纳入 MCP/agent 资产类型。

## 原始材料

<details>
<summary>本次扫描的仓库与信号(commit since 2026-08-11)</summary>

- opendatahub-io/opendatahub-operator:29 commits。关键:#3868 弃用 Training v1、#3966 平台版本戳、#3962 bundle CRD conversion 交 OLM、#3959 解绑 kuberay digest、#3892 feast admin CRUD、#3868 相关 Trainer v2 handler 更新。最新 release v3.5.0(2026-07-29)。
- opendatahub-io/odh-dashboard:71 commits(最活跃)。关键:#9072 MaaS 门户、#9279 chat completions 代理、#9258/#9228 eval-hub、#9155/#9314 autorag/automl、#9233/#9092 Feature Store、#9227/#9210 llm-d、#9308/#9235 Kueue、#9249/#9067/#9267 model capabilities、#8921 LeaderWorkerSet、#9295 回退 Fastify 5、#8660 PatternFly 6.5。最新 release v3.5.0(2026-07-27)。
- opendatahub-io/kserve:13 commits。关键:#1871 SecureServing 指标 RBAC、#1873 localmodel CA bundle、上游 #5996 llmisvc KEDA scale-to-zero、8-04/8-11 两次 upstream sync。最新 release odh-v3.5(2026-07-27)。
- opendatahub-io/notebooks:39 commits。关键:#4360 移除 Training v1 SDK 注解、runtime-baseline(#4363)、#4324 慢启动 startup probe、#4368 安全扫描覆盖 rhoai-* 分支。最新 release v1.47.0 / 3.5-v1.47.0(2026-07-22)。
- opendatahub-io/model-registry:19 commits。关键:#3068 MCP serverJson、#3078 agent catalog 日志、#3074 catalog settings 重构、两次 upstream(kubeflow)sync。最新 release v0.3.14(2026-07-27)。
- opendatahub-io/data-science-pipelines-operator:2 commits(仅 OWNERS / yamllint 维护)。最新 release v2.18.0(2025-11-11),本周无实质变化。
- opendatahub-io/trustyai-service-operator:4 commits。关键:#876 evalhub 从上游 sync collections/providers。最新 release odh-3.5-ea2(2026-06-12)。

官方 release notes(docs.redhat.com,OpenShift AI self-managed):当前公开最新为 3.5 EA2,页面未列 mid-2026 具体新特性;研发信号(RHOAIENG-78xxx/80xxx/82xxx)显示主线已在 3.6。

</details>
