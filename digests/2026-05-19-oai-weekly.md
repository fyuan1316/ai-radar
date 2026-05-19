# OpenShift AI 周报 2026-05-19

窗口:2026-05-12 → 2026-05-19(7 天)

> 与上一份 digest(2026-05-16,窗口 05-09 → 05-16)有 4 天重叠;OGX 改名、KServe Module、ModelCache、Kueue 1.3、EKS provider、NIM Settings Card 等已覆盖,不再展开,本期只标注本窗口内**新增**或**本周才并入**的变更。

## 摘要(3 条以内)
- **3.5 EA2 节奏启动**:notebooks 镜像从 `3.5_ea1-v1.44` 切到 `3.5_ea2-v1.45`(params-latest.env、Tekton pipeline tag、ImageStream lockfile 全量更新),同时叠加 gitleaks 密钥扫描、pnpm 升 11、supply-chain hardening、ODH base-image 装 uv 并退役 rocm 6.4。EA1 释出仅 10 天就进入 EA2 准备,意味着 OAI 3.5 周期是滚动 EA 而非"EA → RC"
- **KServe 删除竞态修复(关键正确性)**:`KServe → Removed` 时 `llmisvc-webhook-server-service` 会被 K8s GC 抢先回收,导致 `LLMInferenceServiceConfig` v1alpha1↔v1alpha2 转换 webhook 调不通,资源卡在 deletion。Operator 加 `WithFinalizer` 显式删 owned IS Config,再交还 finalizer——这是 v1alpha2 引入后第一次真正的"配置版本前缀 + webhook 转换"运维事故
- **架构成熟化三连**:operator 把 dependency 监控从 mid-pipeline 切到 precondition 框架(`MonitorOperator` + `WithPreCondition`,KServe/Kueue/Trainer 全迁);DSC API 新增 `oauthProxy.resources` 字段,KServe RawDeployment 的 oauthProxy sidecar 资源不再需要"改 ConfigMap + 打 unmanaged 标";dashboard 新增 `model-serving.platform/exclude-deployment` 扩展点,NIM-owned InferenceService 不再在 KServe 列表里重复出现

## 新功能 / 能力

- [KServe 组件删除竞态:WithFinalizer 兜底 LLMInferenceServiceConfig 清理](https://github.com/opendatahub-io/opendatahub-operator/pull/3532) — `KServe → Removed` 时,K8s GC 会优先回收 `llmisvc-webhook-server-service`,但 `LLMInferenceServiceConfig` 的 v1alpha1↔v1alpha2 转换 webhook 又依赖这个 service,造成资源卡死;修复方式是在 KServe reconciler 里挂 finalizer,先显式删 owned `LLMInferenceServiceConfig`,确认 webhook 还在线时再放行 platform finalizer
  - 启示:这是 KServe Module 拆分 + LLMInferenceServiceConfig 版本前缀机制上线后的第一例真实运维事故。我们做 CRD 版本演进时必须把"conversion webhook 与依赖资源的删除顺序"列为头等回归点,operator-controller 的 finalizer 链不能假设 GC 顺序
- [DSC API 新增 oauthProxy.resources(KServe RawDeployment 边车资源可配置)](https://github.com/opendatahub-io/opendatahub-operator/pull/3503) — `KserveCommonSpec.OAuthProxyConfig` 暴露 `requests/limits`,只覆盖非 nil 字段;旧 ConfigMap 无 oauthProxy key 也兼容
  - 启示:此前需要"改 inferenceservice-config ConfigMap + 打 `opendatahub.io/managed: false`"才能调 oauthProxy 内存,代价是该 ConfigMap 整体失去 reconcile。新 API 是"局部 override"模式——我们做 sidecar/认证代理资源调优时可以照抄:把"用户局部覆盖"提升到 CRD 字段,避免用户停掉整张 ConfigMap 的 reconcile
- [Precondition 框架替换 dependency.NewAction(MonitorOperator + WithPreCondition)](https://github.com/opendatahub-io/opendatahub-operator/pull/3505) — `MonitorOperator(OperatorConfig, ConditionFilterFunc)` 拉外部 operator CR、过滤 status 条件;KServe / Kueue / Trainer 三个组件从 `dependency.NewAction` 迁过来,`action_operator.go` 删除;`DependencyDegraded` → `PreConditionFailed`,API 错误现在会上抛 `ConditionUnknown` 而不是被吞
  - 启示:OAI 在把"依赖健康检查"从 reconciler 流水线的中段提到"前置"。我们做组件 operator 时往往把依赖检查写在 reconcile loop 内部,这次重构印证了"先验失败暴露成 condition"是更稳健的模型——尤其是依赖 CR 缺失时,以前默认"healthy",现在按 `RequireCR` 配置走 fail 路径,语义更安全
- [SCC watch 在非 OpenShift 集群 CrdExists 守护(EKS/Kind 直跑)](https://github.com/opendatahub-io/opendatahub-operator/pull/3554) — KServe controller 之前用 `Owns(&securityv1.SecurityContextConstraints{})` 静态 watch,Kind / vanilla K8s 缺 `security.openshift.io/v1` API 组直接启动失败;改为 `OwnsGVK(gvk.SecurityContextConstraints, reconciler.Dynamic(reconciler.CrdExists(...)))`
  - 启示:与上周 #3477(EKS cloud manager provider)是一对——operator 在为"RHAI 跑在非 OpenShift 集群"补能力,SCC、Route 等 OpenShift 专有资源都得走"CRD 探测 → 动态注册 watch"。这是我们做"K8s 原生 + OpenShift 增强"双轨产品的必备模式
- [NIM↔KServe 列表去重:新增 model-serving.platform/exclude-deployment 扩展点](https://github.com/opendatahub-io/odh-dashboard/pull/7479) — NIM Operator 创建 `NIMService` 时会顺手 reconcile 一个 owned `InferenceService`(带 ownerReferences),它在 KServe 的 `useWatchDeployments` 里被当成独立 deployment 重复出现;新扩展点让"平台 owner"声明谓词,KServe 通过 `useResolvedExtensions` 解析并过滤
  - 启示:这是"多 ServingPlatform 共栈" UI 去重的标准做法——不是 KServe 知道 NIM,而是 NIM 自己 declare "我拥有这个 IS";我们做异构 inference runtime 整合 dashboard 时,这个"owner-driven 去重协议"应该照搬,避免给 KServe 加各种平台特例
- [BYOIDC(外部 OIDC)集群 User Management 不再无限 loading](https://github.com/opendatahub-io/odh-dashboard/pull/7493) — Keycloak/BYOIDC 集群没有 `user.openshift.io/groups` CRD,`useK8sWatchResourceList` 之前把 `K8sStatus` 404 包成 `new Error('Unknown error occured')` 吞掉了状态码,`useGroups()` 永远不 resolve;改为保留 K8sStatus、`useGroups()` 检测 404 即 settle 到空列表
  - 启示:OAI 越来越正经地支持"非 OCP OAuth"的身份场景;这条修复值得我们的 dashboard 端在做"群组 / RBAC"列表时学:K8s SDK 包的 K8sStatus 不要无脑当 Error 处理,要保留 status code 让上层做语义分支
- [system:authenticated 永不被绑到 Role/ClusterRoleBinding(Auth controller 加固)](https://github.com/opendatahub-io/opendatahub-operator/pull/3484) — RHOAIENG-56110,`bindRole` / `bindClusterRole` 统一过滤 `system:authenticated` 与空字符串;之前测试还允许 non-admin role 绑 `system:authenticated`,本次直接删除该测试用例
  - 启示:`system:authenticated` 绑到任意 Role 等于"OIDC 登录即生效",历史上是常见特权升级面;OAI 把它从"看 role 名字判断"提升到"无条件硬过滤",安全姿态收紧。我们自己 operator 的多租户/订阅授权链路里也要 audit 一次
- [Model Catalog 新增 ToolCalling + ServingConfig + ValidatedTasks 三层能力模型](https://github.com/opendatahub-io/model-registry/pull/2687) — BFF/前端/OpenAPI 同步,Catalog 新增"Validated configurations"卡片(可展开 tool-calling 段),`MODEL_CATALOG_TASK_NAME_MAPPING` 给任务展示名;[文档侧 #2705](https://github.com/opendatahub-io/model-registry/pull/2705) 把 `validatedTasks` 与 `servingConfig` 字段写进 Catalog YAML reference,落地"tasks / validatedTasks / servingConfig"三层模型 + ToolCallingConfig
  - 启示:这是 model-registry 从"元数据登记"向"模型能力声明 + Red Hat 校验过的部署配方"演进的关键一步——产品上意味着用户在 Catalog 看到的不只是 model card,还有"这个模型在 KServe/vLLM/NIM 上跑过的官方 serving config";我们如果做企业级模型库,这种"三层能力模型(原生 / 已验证 / 部署配方)"值得对齐
- [3.5 EA2 节奏:notebooks v1.45 / 3.5_ea2 系列开张](https://github.com/opendatahub-io/notebooks/pull/3636) — `params-latest.env` 与 [Tekton pipeline tag](https://github.com/opendatahub-io/notebooks/pull/3632) 从 `3.5_ea1-v1.44` 切到 `3.5_ea2-v1.45`,lockfile / ImageStream annotation 全量刷新
  - 启示:EA1(2026-05-08)到 EA2 准备只用了 10 天,说明 OAI 3.5 走"短周期 EA 滚动"而非传统"EA → RC → GA"。我们如果要跟版,得把"EA1-EA2 增量"纳入回归测试矩阵,而不是只盯 GA
- [notebooks 加 gitleaks 密钥扫描 + supply-chain hardening](https://github.com/opendatahub-io/notebooks/pull/3663) — Konflux 构建路径加 gitleaks(RHAIENG-5000);[#3650](https://github.com/opendatahub-io/notebooks/pull/3650) ODH base-image 装 `uv` 包管理器,退役 rocm 6.4 镜像;[#3635](https://github.com/opendatahub-io/notebooks/pull/3635) pnpm 全量依赖升级 + supply-chain hardening
  - 启示:供应链信号——OAI 把 uv 选为 Python 包管理器(对照 pip/poetry)、引入 gitleaks 阻断密钥提交,与 NVIDIA H100 时代"GPU 镜像数量爆炸"配套。我们的训练/工作台镜像构建链如果还在用 pip+poetry,可以评估 uv 切换收益
- [notebooks 构建并行化:per-arch prefetch 并行](https://github.com/opendatahub-io/notebooks/pull/3661) — RHAIENG-5173,pip/npm 按架构并行 prefetch,缩短 Konflux 构建时间
- [notebooks 派生 Konflux RHOAI index URL(去硬编码)](https://github.com/opendatahub-io/notebooks/pull/3658) — 从 `BASE_IMAGE` 推导 index URL,镜像源切换不再要改源码
- [Dashboard 同仓 PR 的 agent checkout 修复](https://github.com/opendatahub-io/odh-dashboard/pull/7597) — `@odh-dashboard-agent` workflow 在 non-fork PR 上 `headRepository.owner` 为空,jq 得到 `null` 触发 `/odh-dashboard`(缺 owner),checkout 失败;判定从 `.headRepository` 改为 `.headRepository.owner` 并回退到 base repo
  - 启示:Claude Code preflight agent 在 Red Hat OAI 仓库已经从"PoC"进入"踩工程坑"阶段,值得跟踪它的 same-repo / fork 分支处理与权限边界,我们做 PR babysit agent 时同一处脚本陷阱大概率重现
- [Dashboard storage 测试名 collision 修复](https://github.com/opendatahub-io/odh-dashboard/pull/7595) — `sc-rwo` 是 `sc-rwo-preset` 前缀,`findByRole({ name: /^sc-rwo\b/i })` 在并行 cluster 上跳到错的对象;重命名为 `sc-wb-rwo` / `sc-wb-multi-access`
  - 启示:Cypress 并行 E2E 在共享集群上,资源名前缀冲突是常见 flake 源——做集群级共享 e2e 时,资源命名要预留唯一前缀位

## 架构 / 依赖变化

- **dependency 监控框架重构(本周新增)**:`MonitorOperator` / `WithPreCondition` 取代 `dependency.NewAction`,KServe / Kueue / Trainer 全迁;`action_operator.go` 删除;`DependencyDegraded` → `PreConditionFailed`。架构上把"依赖健康"从 reconcile loop 中段提到前置,行为差异:API 错误从"静默 healthy"改为 `ConditionUnknown`,缺 CR 由 `RequireCR` 显式控制——前置 + 失败可观测的设计取向
- **非 OpenShift K8s 支持继续补齐**:上周 EKS cloud manager provider 之后,本周 KServe controller 的 SCC watch 改 CRD 动态探测(#3554)。下一步可观察 Route / OAuthProxy 等 OCP 资源的同类改造
- **3.5 EA2 节奏**:operator 仍在 3.5.0-ea.1,但 notebooks / Tekton pipeline tag 已切 3.5_ea2-v1.45,下次 operator release 之前先看 notebooks v1.45 是否单独打 tag
- **KServe odh-fork 紧跟 v0.17**:上周 #1502 sync 到 release-v0.17 后,本周 #1496 修复长模型名 63 字符限制(NVIDIA Nemotron `nvfp4-v1-0-...`)真正合入

## 上游生态整合动向

- **KServe Module / LLMInferenceService v1alpha2 conversion webhook 实战**:operator #3532 暴露了 conversion webhook 与依赖 CR 删除顺序的真实风险;upstream KServe v0.17 的 LLMInferenceServiceConfig 滚动升级我们要重点跟其 finalizer 设计
- **NIM ↔ KServe 共栈协议**:#7479 新增 `model-serving.platform/exclude-deployment` 扩展点,是 OAI 让 dashboard 容纳多 inference runtime 的契约层做法(NIM、ModelMesh、KServe、未来 llm-d 都可以走这个协议)
- **Kubeflow model-registry 三层能力模型(tasks / validatedTasks / servingConfig)**:OAI 自带"Validated by Red Hat"语义,加上 ToolCallingConfig,把 model-registry 推向"模型 + 验证过的部署配方"的方向,与 Kubeflow 上游可能逐渐分叉
- **MLflow / model-registry 双轨保留**:上周 MLflow tracking 接入 dashboard,本周 model-registry 继续追上游(#1743 sync from kubeflow/main),两套元数据系统并存的状态延续

## 值得跟进

- [ ] 读 [operator#3532](https://github.com/opendatahub-io/opendatahub-operator/pull/3532) 的 finalizer 实现细节(`WithFinalizer` action 的注册方式 + LLMInferenceServiceConfig 的 conversion webhook 顺序),作为我们做 CRD 多版本演进的删除顺序模板
- [ ] 评估把 `MonitorOperator` + `WithPreCondition` 模式([operator#3505](https://github.com/opendatahub-io/opendatahub-operator/pull/3505))引入我们 operator——目前我们的依赖检查多写在 reconcile loop 中段,前置化对故障可观测性提升明显
- [ ] 跟 [operator#3503](https://github.com/opendatahub-io/opendatahub-operator/pull/3503) 的 `oauthProxy.resources` DSC 字段——我们的 sidecar 资源配置如果也是"ConfigMap + unmanaged 标"模式,可以借鉴这种"CRD 字段局部 override"
- [ ] 拉 [model-registry#2687](https://github.com/opendatahub-io/model-registry/pull/2687) + [#2705](https://github.com/opendatahub-io/model-registry/pull/2705) 的 OpenAPI/YAML reference,看 `tasks / validatedTasks / servingConfig / ToolCallingConfig` 字段结构,作为我们做"企业级模型库 + 部署配方"的 schema 模板
- [ ] 看 dashboard 的 [exclude-deployment 扩展点](https://github.com/opendatahub-io/odh-dashboard/pull/7479) 实现,作为我们做"多 ServingPlatform 共栈 UI 去重"的协议参考——这种 owner-driven 模式不需要 KServe 知道 NIM
- [ ] notebooks v1.45 / 3.5_ea2-v1.45 镜像标签(EA1→EA2 增量回归)
- [ ] gitleaks / uv / supply-chain hardening([notebooks#3663 / #3650 / #3635](https://github.com/opendatahub-io/notebooks/pull/3663))——评估我们工作台镜像与 base-image 构建链的同等改造

## 原始材料

<details>
<summary>本窗口内 releases</summary>

- 本窗口(2026-05-12 → 2026-05-19)**无新 release**。上一窗口 EA1 主版本 v3.5.0-ea.1(2026-05-08)与 notebooks v1.44.0(2026-05-08)是当前最新发布,3.5_ea2-v1.45 仅以 params/Tekton tag 形式出现在 main 分支,operator 尚未打 EA2 tag。
</details>

<details>
<summary>Merged PR / 提交计数</summary>

- notebooks: 92 commits(3.5 EA2 准备 + supply-chain hardening 占主导)
- odh-dashboard: 46 commits
- opendatahub-operator: 28 commits
- model-registry: 7 commits(含 Catalog ToolCalling/ValidatedTasks/ServingConfig 三连)
- kserve(odh-fork): 4 commits
- data-science-pipelines-operator: 0
- trustyai-service-operator: 0
</details>

<details>
<summary>主要 PR(本周新增,2026-05-17 ~ 2026-05-19)</summary>

opendatahub-operator
- #3503 feat(RHOAIENG-60865): oauthProxy configs 通过 DSC API 可配
- #3505 RHOAIENG-58945: MonitorOperator precondition + 迁移 dependency.NewAction
- #3532 RHOAIENG-62174: KServe 删除竞态(WithFinalizer 兜底 LLMInferenceServiceConfig)
- #3554 fix(kserve): SCC watch 用 CrdExists 守护(非 OpenShift K8s)
- #3484 RHOAIENG-56110: system:authenticated 永不被绑到 Role/ClusterRoleBinding
- #3552 / #3553 chore: 更新 manifest commit SHAs

odh-dashboard
- #7479 NIM extension 去重(`model-serving.platform/exclude-deployment` 扩展点)
- #7493 RHOAIENG-44140: BYOIDC 集群 User Management 无限 loading 修复
- #7597 agent checkout 在 same-repo PR 上失败修复
- #7595 RHOAIENG-62962: 集群 storage 命名 collision 修复
- #7593 fix: testEnabledISVs e2e Cypress 测试
- #7592 docs: architecture.md 包分类修正

notebooks
- #3661 RHAIENG-5173: 按架构并行 pip/npm prefetch
- #3663 RHAIENG-5000: gitleaks 密钥扫描
- #3650 RHAIENG-4654: ODH base-images 装 uv,退役 rocm 6.4
- #3658 Konflux RHOAI index URL 从 BASE_IMAGE 派生(去硬编码)
- #3665 RHAIENG-5185: globDockerfiles 修复 + Walk 错误传播
- #3652 移除 AIPCC 迁移 phase 1.5 索引覆盖
- "update to ea2 series" — 3.5_ea2 系列开张

model-registry
- #2687 Model Catalog 加 ToolCalling 支持(BFF + 前端 + OpenAPI)
- #2705 docs(catalog): validatedTasks + servingConfig YAML reference
- #2706 chore: 同步 kubeflow/manifests #3318 istio authorization policy
- #1743 同步 kubeflow/main
</details>

<details>
<summary>主要 PR(上周覆盖过的窗口内合并,2026-05-12 ~ 2026-05-16)</summary>

- operator: #3477 EKS provider / #3535 MaaS 拆控制器 / #3531 ODH 组件改名 OGX / #3513 odh-ogx-k8s-operator / #3543 odh-kserve-module-operator / #3538 Kueue 1.3 v1beta2 / #3379 KServe ModelCache / #3498 HardwareProfile DefaultCount
- dashboard: #7502 移除 Pre-3.4 MaaS Code / #7549 Claude Preflight Agent / #7585 OGX 安装路径 / #7522 Subscriptions 允许重复优先级 / #7586 preflight + RBAC review skill / #7469 AutoML 列选择推断 / #7579 OGX 改名完成 / #7574 task assistant → shortcuts / #7480 MaaS Zod 校验 / #7501 NeMo Guardrails View Code / #7436 NIM Settings Card / #7433 NIMService 进 Deployments 表 / #7429 MCP Phase → Conditions
- kserve(odh-fork): #1496 卷名 63 字符 / #1480 kserve-module manifest 渲染
- notebooks: 3.5_ea1-v1.44 → 3.5_ea2-v1.45 切换、pnpm 11、supply-chain hardening、byte-identical Dockerfile pairs
</details>
