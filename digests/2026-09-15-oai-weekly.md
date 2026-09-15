# OpenShift AI 周报 2026-09-15

扫描窗口:2026-09-08 ~ 2026-09-15,7 个 opendatahub-io 仓库。本周无新 release,但主线动作密集,三个方向同时发力:跳出 OpenShift(XKS)、operator 拆模块、面向消费者的自助服务层(MaaS + GPUaaS)。

## 摘要(3 条)

- **OAI 正在系统性"去 OpenShift 化"**:operator 与 kserve 同步给核心路径加 XKS(vanilla / 非 OCP Kubernetes)分支,gateway、LLMISVC 的 TLS、Route/ConsoleLink 等 OCP-only 资源都按集群类型条件化。产品第一次认真把"能装在别家 K8s 上"当成一等目标。
- **单体 operator 继续拆成 module 化子算子**:本周 ai-gateway-operator(含 ai-gateway-controller + praxis-extproc)、data-connect-hub、AIPipelines(DSPO)、trustyai 都以"module"形态推进,伴随大量 module 在 fresh-install 下的 RBAC/webhook cert 修复。架构从"一个大 operator 管所有 DSC 组件"转向"平台 operator + 一批可独立发布的 module operator"。
- **自助消费层成形**:MaaS(Models-as-a-Service)Consumer Portal 收敛到统一 gateway 路径下、共享认证会话;GPU-as-a-Service 配额视图(基于 Kueue cluster queue)进入 dashboard。OAI 在做"平台方发布模型 + 租户自助领用配额消费"的分层。

## 新功能 / 能力

- [operator: gateway 支持部署在 vanilla Kubernetes(XKS)](https://github.com/opendatahub-io/opendatahub-operator/pull/3995) — 新增 XKS 专用 gateway namespace/name/controller 与 Istio revision;非 OCP 集群强制要求显式 `spec.domain`,缺失时干净停止 reconcile 而非报错;跳过 Route、dashboard redirect 等 OCP-only 资源,为 kube-auth-proxy 自签 TLS。
  - 启示:这是我们最该逐条对照的 PR。OAI 把"OpenShift 特有假设"逐个抽出做条件分支的做法(domain 显式化、Route→Gateway API、ConsoleLink 可选、自签证书兜底),正是我们产品若要支持多种 K8s 发行版必然要走的路。建议把它当迁移 checklist。
- [dashboard: MaaS Consumer Portal 收到统一 gateway 路径下](https://github.com/opendatahub-io/odh-dashboard/pull/9678) — Portal 从派生 hostname 改为 `https://<gateway.domain>/maas-consumer-portal/`,共享 Gateway 主机名与认证会话,配 302 尾斜杠重定向 + 前缀重写到 Core-BFF;并[移除独立的 OpenShift ConsoleLink](https://github.com/opendatahub-io/odh-dashboard/pull/9696)、[autorag 从 OGX 迁到 MaaS](https://github.com/opendatahub-io/odh-dashboard/pull/9629)。
  - 启示:MaaS Consumer Portal 是一个独立于管理控制台的"模型消费者门户",走 Gateway 统一入口 + 统一 session。我们若做多租户模型自助,值得抄这个"管理面 / 消费面分离但共享网关与认证"的形态,而不是把消费能力塞进管理控制台。
- [dashboard: GPU-as-a-Service 配额视图(Kueue cluster queue 工作负载表)](https://github.com/opendatahub-io/odh-dashboard/pull/9692) — Quota usage 页新增 cluster queue workloads 表、accelerator 用量汇总与 borrowing 状态。
  - 启示:OAI 的 GPU 配额消费视图直接建在 Kueue 的 ClusterQueue/借用语义上。我们做 GPU 多租户配额,UI 与数据模型对齐 Kueue 会比自造一套账本更省、也更容易和上游对齐。
- [dashboard: 新增 data-connect-hub(DCH)/ data-registry 模块](https://github.com/opendatahub-io/odh-dashboard/pull/9451) — 在 model-registry 之外新起一条"数据资产"主线:资产/集合的注册、编辑、删除、owner、非结构化资产统一详情页(RHAI-599 / RHOAIENG-90400)。
  - 启示:OAI 把"数据侧目录"当成与模型注册中心平级的新一等能力(data assets + collections + connections)。这是 model-centric 平台向 data+model 双目录扩张的信号,值得评估我们是否需要对应的数据资产/连接目录。
- [model-registry: 支持 HuggingFace gated / private 模型的预览与门控](https://github.com/opendatahub-io/model-registry/pull/3189) — 目录侧增加 gated md 预览、[Add source 表单处理 gating](https://github.com/opendatahub-io/model-registry/pull/3183)、[读取/清除 catalog source 持久化状态的 endpoint](https://github.com/opendatahub-io/model-registry/pull/3159)。
  - 启示:企业接入受限模型(需授权/私有)时的目录体验正在补齐,门控状态可读可清是运维刚需,可对照我们模型目录的私有源接入。
- [kserve: 为 LLMISVC 配置 cert-manager 提供的 metrics TLS(XKS)](https://github.com/opendatahub-io/kserve/pull/1964) — LLMInferenceService 在非 OCP 上用 cert-manager 出具 metrics TLS 证书。
  - 启示:与 operator XKS 呼应——推理服务的可观测端口在非 OpenShift 上靠 cert-manager 兜底证书,是"去 OCP 化"落到组件级的具体做法。

## 架构 / 依赖变化

- **module 化子算子成为主线**:[operator 为 ai-gateway-operator module 注册相关镜像](https://github.com/opendatahub-io/opendatahub-operator/pull/4060)(纳入 `ai-gateway-controller` + `praxis-extproc` 两个子组件,praxis-extproc 看名字是 Envoy ext-proc 形态的 LLM 网关处理器);DSPO 新增 [AIPipelines module API](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1094) 与 [AIPipelines modular mode](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1104);dashboard 侧 [DCH module scaffold](https://github.com/opendatahub-io/odh-dashboard/pull/9451);operator 向 dashboard-operator [转发 RELATED_IMAGE](https://github.com/opendatahub-io/odh-dashboard/pull/9598) 类变量以支撑子算子独立发布。
  - 启示:架构方向明确——平台 operator 只做编排,各能力域(gateway / pipelines / data / trustyai)拆成可独立构建发布的 module operator。对标我们自家 operator,这是"避免单体膨胀"的参考路径,但也意味着 module 间的 RBAC/证书/版本握手复杂度上升(见下)。
- **module fresh-install 的 RBAC / webhook 证书是当前主要坑**:trustyai 本周连续修 [module 在全新安装时创建 workload RBAC 与 webhook 证书](https://github.com/opendatahub-io/trustyai-service-operator/pull/918)、[serviceaccounts RBAC + SSA create verb + 条件聚合](https://github.com/opendatahub-io/trustyai-service-operator/pull/915),并加 OPA guard 防回归 module RBAC watch 修复。
  - 启示:模块化的代价集中在"首装时的权限与证书自举"。若我们走同路,应提前把 module 的 RBAC watch verb、SSA、webhook cert 自举做成统一脚手架 + 策略守卫,而不是每个 module 各修各的。
- **集中式 TLS security profile 落地**:[dashboard 让全部 10 个 BFF 与 operator 遵循集群 TLS security profile](https://github.com/opendatahub-io/odh-dashboard/pull/9396)(RHOAIENG-75339,应对 OCP 5.0 / OCPSTRAT-2611,从硬编码 TLS 版本改为动态解析 `apiservers.config.openshift.io/cluster`);DSPO [启用安全 metrics serving](https://github.com/opendatahub-io/data-science-pipelines-operator);operator 把 [TLS bootstrap 的 context deadline 视为可重试](https://github.com/opendatahub-io/opendatahub-operator/pull/4059)。
  - 启示:企业合规要求"全栈统一 TLS 策略、可从集群配置动态下发",硬编码 TLS 版本会成为审计负债。我们所有对外/对内端口应统一从集群安全 profile 解析,而非各组件各写。
- **operator 生命周期健壮性**:修 [保留 DSC/DSCI owner references](https://github.com/opendatahub-io/opendatahub-operator/pull/4069)、修 [managementState 在 Managed→Removed 快速切换时遗留 out-of-tree module CR 孤儿](https://github.com/opendatahub-io/opendatahub-operator/pull/4087)。
  - 启示:module 化后"快速启停/切换 managementState 导致孤儿 CR"是新的一类 bug 面,做类似设计要重点测这条路径。

## 上游生态整合动向

- **KServe**:主线在 LLMInferenceService(LLMISVC)——本周补 XKS 下 cert-manager metrics TLS、[s390x 专用模板改用 default-scheduler](https://github.com/opendatahub-io/kserve/pull/1931)、[新增发布后 E2E 验证工作流](https://github.com/opendatahub-io/kserve/pull/1893)。OAI 的 kserve fork 明显把重心押在 LLM 专用推理 CRD 与多架构/多发行版覆盖上。
- **Kueue**:GPUaaS 配额直接建在 Kueue ClusterQueue / borrowing 语义上;operator e2e 收敛 `autoCreateQueues=false` 断言到 operator 自有队列。Kueue 已是 OAI GPU 多租户配额的事实底座。
- **Kubeflow model-registry**:持续从 kubeflow/main 定频同步(本周多次 merge),grpc 升到 [v1.83.2](https://github.com/opendatahub-io/model-registry/pull/3186)(修 CVE 系列,与其它算子仓一致)。OAI 的 model-registry 仍是 kubeflow 上游的下游 fork,值得跟其融合节奏。
- **DRA / PodResourceClaims**:DSPO 增加"在所有相关组件支持 PodResourceClaims 并更新 CRD/模板/测试"。流水线组件开始接 K8s DRA 资源模型。
- **后量子密码(PQC)**:notebooks 在 ODH midstream / RHOAI baseline 基础镜像 [启用 PQC crypto policy](https://github.com/opendatahub-io/notebooks/pull/4568)(RHOAIENG-84389),并加测试断言覆盖。合规前瞻信号。

## 值得跟进

- [ ] 精读 operator XKS PR([#3995](https://github.com/opendatahub-io/opendatahub-operator/pull/3995)),整理成"OpenShift 假设 → vanilla K8s 替代"对照表(Route→Gateway API、ConsoleLink 可选、domain 显式化、自签/cert-manager 证书兜底),作为我们多发行版支持的迁移清单。
- [ ] 评估 MaaS Consumer Portal 形态([#9678](https://github.com/opendatahub-io/odh-dashboard/pull/9678)):管理面与消费面分离、共享 Gateway + 统一 session,是否适配我们多租户自助模型消费。
- [ ] 跟踪 ai-gateway-operator(`ai-gateway-controller` + `praxis-extproc`,[#4060](https://github.com/opendatahub-io/opendatahub-operator/pull/4060)):确认它与上游 Envoy AI Gateway / kgateway 的关系,判断 OAI 的 LLM 网关选型。
- [ ] 对照 module 化 RBAC/证书自举坑(trustyai [#918](https://github.com/opendatahub-io/trustyai-service-operator/pull/918)/[#915](https://github.com/opendatahub-io/trustyai-service-operator/pull/915)):若我们走 module operator,提前做统一的 RBAC/SSA/webhook cert 脚手架与策略守卫。
- [ ] 评估集中式 TLS security profile 方案([#9396](https://github.com/opendatahub-io/odh-dashboard/pull/9396)):我们组件是否也应从集群安全 profile 动态解析 TLS 版本/密码套件,而非硬编码。

## 原始材料

<details>
<summary>本周扫描清单(2026-09-08 ~ 2026-09-15,无 release)</summary>

Releases:全部 7 仓过去 7 天均无发布。

Commits(过去 7 天数量):opendatahub-operator 10、odh-dashboard 71、kserve 3、notebooks 70、data-science-pipelines-operator 10、model-registry 29、trustyai-service-operator 21。

opendatahub-operator 关键提交:
- feat(gateway): support deploying gateway on vanilla Kubernetes (XKS) #3995
- feat: register new related images in ai-gateway-operator module #4060
- feat(gateway): support deploying gateway on vanilla Kubernetes 相关 + feat(dashboard): forward RELATED_IMAGE_ODH_OGX_CORE_IMAGE #4056
- fix(platform): preserve DSC and DSCI owner references #4069
- RHOAIENG-93536 orphaned out-of-tree module CRs on Managed→Removed #4087
- fix(tls): treat context deadline as retryable on TLS bootstrap #4059

kserve:
- feat(xks): provision cert-manager metrics TLS for LLMISVC #1964
- feat(kserve-module): add post-release E2E validation workflow #1893
- Update schedulerName to default-scheduler for LLMISVC s390x template #1931

data-science-pipelines-operator:
- feat(api): add AIPipelines module API #1094 / feat(controller): AIPipelines modular mode #1104
- feat(tls): enable secure metrics serving for DSPO
- Add support for PodResourceClaims in all relevant components

odh-dashboard 关键提交:
- feat: serve MaaS Consumer Portal under gateway path #9678
- feat: remove the MaaS Consumer Portal OpenShift ConsoleLink #9696
- fix(autorag): migrate OGX to MaaS #9629
- feat(gpuaas): add cluster queue workloads table to Quota usage #9692
- Feat(RHOAIENG-88178): summary accelerator section #9701
- feat(DCH): Scaffold data-connect-hub module #9451
- feat(data-registry): collections details / edit / delete / owner #9634 #9639 #9631 #9514
- feat(RHOAIENG-75339): honor cluster TLS security profile in all BFFs and operator #9396
- Fix registry MCP tool discovery / server status checks #9734 #9727

model-registry:
- enhance model preview with gated md #3189 / Add source form gating #3183 / update HF gated sources #3184
- feat(catalog): read+clear source persisted status #3159 / fix paginate on empty artifact list #3198
- 频繁 sync from kubeflow/main;grpc v1.83.2 #3186

trustyai-service-operator:
- fix(module): workload RBAC + webhook certs on fresh installs #918
- fix(module): serviceaccounts RBAC + SSA create verb + condition aggregation #915
- refactor(tls): shared OpenShift profile resolver #914
- evalhub config sync;grpc v1.83.2 #911

notebooks:
- RHOAIENG-84389: enable PQC crypto policy in baseline/midstream base images #4568
- triton plugins libtriton.so ELF link check #4580
</details>
