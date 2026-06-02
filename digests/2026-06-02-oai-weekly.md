# OpenShift AI 周报 2026-06-02

扫描窗口:2026-05-26 ~ 2026-06-02(UTC),覆盖 opendatahub-io 下 7 个核心仓库 + Red Hat 官方博客。

## 摘要

- **模块化组件框架(Modular handler)落地,4 个新独立 operator 同步集成进 ODH 主 operator**:agents、ai-gateway、batch-gateway(基于 llm-d-batch-gateway-operator)、trainer。这是 OAI 从"单 operator 巨石"向"主 operator + 一组可独立演进的子 operator"重构的关键一周。
- **kserve-module 引入动态 CRD watch,HardwareProfile 注入下沉到 kserve**:operator 端的 InferenceService/LLMInferenceService 相关 webhook 被瘦身,职责边界进一步明确。
- **MaaS(Models as a Service)开始走向"开箱即用"**:operator 自动建 `maas-default-gateway`、检测缺失的 gateway annotation 与 Authorino TLS、Dashboard 把 MaaS API 错误直接展示在 UI 上;同时 llm-d 镜像批量改名(`llm-d-inference-scheduler` → `llm-d-router-endpoint-picker`)。

## 新功能 / 能力

- [modular handler 框架](https://github.com/opendatahub-io/opendatahub-operator/pull/3459) — 把模块生命周期从 DSC reconciler 拆出来,新增 `modules_controller.go`,挂在 DSC 实例 "modules" 上独立 reconcile,带 `--suppress-module-<name>` 抑制位与本地 Helm chart 路径注入。
  - 启示:这是 OAI 多 operator 演进的"协议层"。我们如果也要拆子 operator,可以借鉴这套 module handler + suppression flag 的契约,而不是各子 operator 各搞各的 CR。
- [agents-operator 接入 modular framework](https://github.com/opendatahub-io/opendatahub-operator/pull/3584) — Jira RHOAIENG-62623,挂在 `internal/controller/modules/agentsoperator`,依赖 #3459 才能合入。
- [ai-gateway-operator 进 manifests-config](https://github.com/opendatahub-io/opendatahub-operator/pull/3598) / [batch-gateway-operator 进 manifests-config](https://github.com/opendatahub-io/opendatahub-operator/pull/3596) / [trainer-operator 进 manifests-config](https://github.com/opendatahub-io/opendatahub-operator/pull/3597) — 三个全新仓库一次性注册;batch-gateway 上游就是 `opendatahub-io/llm-d-batch-gateway-operator`,等于把 llm-d 的批量推理网关编入 OAI 主 operator 编排。
  - 启示:OAI 正在把"推理网关"和"训练编排"拆成独立的 operator,而不是塞进 kserve/kubeflow trainer。我们做对标产品时,组件清单要新增"AI 网关"和"trainer-operator"两类。
- [Show MaaS API Errors in the UI #7734](https://github.com/opendatahub-io/odh-dashboard/pull/7734) — RHOAIENG-63607,MaaS 后端报错直接渲染到 Dashboard,而不是吞掉。
- [auto-provision maas-default-gateway #3527](https://github.com/opendatahub-io/opendatahub-operator/pull/3527) — `kserve.modelsAsService.managementState: Managed` 一开,operator 自动创建 `maas-default-gateway` 和 `openshift-default` GatewayClass,免去人工事先配 Gateway。
- [feat(maas): detect missing gateway annotations and Authorino TLS #3541](https://github.com/opendatahub-io/opendatahub-operator/pull/3541) — operator 主动检查 MaaS 启用所需的前置条件,缺啥写到 status,不是默默 NotReady。
  - 启示:这两条加上 UI 错误展示是一套完整的"MaaS UX 降摩擦"动作。我们自家的 MaaS 故事如果还停留在"装上去能跑",在易用性上已经落后了。
- [feat(webhook): remove IS and LLMis from HWP/Kueue webhooks #3580](https://github.com/opendatahub-io/opendatahub-operator/pull/3580) — kserve 现在在 reconcile 时直接把 HardwareProfile scheduling stanza 注入,operator 那侧就不再需要在 webhook 里改 IS/LLMis,Kueue 标签也下沉到 Deployment/LWS。
  - 启示:这次重构把 HWP 的"职责单点"从 operator 移到了 kserve,符合"谁拥有资源谁负责字段注入"的原则。我们如果有类似的 hardware profile 抽象,值得照搬这套责任划分。
- [feat(kserve-module): dynamic watch for Subscription and LeaderWorkerSet CRDs #1537](https://github.com/opendatahub-io/kserve/pull/1537) — 可选依赖的 CRD 启动时未必存在,改成每次 reconcile 用 `controller.Watch(source.Kind)` 重试注册,避免重启 controller。
  - 启示:解决了"可选 CRD 必须重启 controller 才生效"这个老大难。Operator SDK 对 optional CRD 没标准答案,我们可以把这块代码模式抄过来。
- [ModelCache reconciliation into kserve-module #1508](https://github.com/opendatahub-io/kserve/pull/1508) — 把 PV/PVC/LocalModelNodeGroup/PSA patch/ConfigMap 一整套 ModelCache 编排从 opendatahub-operator#3379 搬到 kserve-module-operator;`ModelCacheSpec` 进 Kserve CRD。
  - 启示:同样是"职责下沉"的延续——模型缓存属于推理域,放进 kserve operator 比放在主 operator 合理。
- [feat: add SparkApplication to default frameworkMapping #3587](https://github.com/opendatahub-io/opendatahub-operator/pull/3587) — RHOAIENG-63983,operator 生成的 Kueue CR 默认把 `sparkoperator.k8s.io/sparkapplication` 列进 frameworkMapping。
  - 启示:Kueue 的 framework 列表是 OAI 决定"哪些工作负载默认走配额"的开关清单,Spark 进默认集说明 OAI 在更明确地把 Spark 当一等公民。
- [RHOAIENG-63152: Roles tab with routing (feature flag) #7729](https://github.com/opendatahub-io/odh-dashboard/pull/7729) — Dashboard 加 dev feature flag 和"Roles"标签页路由,RBAC 管理的入口在搭建。
- [Add validated deployment resource label (model-registry) #2757](https://github.com/opendatahub-io/model-registry/pull/2757) — registry 给注册过的模型加上"已验证部署"标签,补全 ModelCar 之外的 model→deployment 联动。
- [Add catalog hardware tags (model-registry) #2748](https://github.com/opendatahub-io/model-registry/pull/2748) — catalog entry 增加硬件 tag,后续可以按"能跑在哪类硬件"过滤模型。
- [Add mlflow plugin support (DSP) #1048](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1048) — Data Science Pipelines operator 原生支持 mlflow 插件,呼应 RH AI 3.4 把 mlflow 作为评估/追踪入口的方向。

## 架构 / 依赖变化

- **modular handler + 三个新 component-operator 仓库**:`agents-operator`、`ai-gateway-operator`、`trainer-operator`、`llm-d-batch-gateway-operator` 都是 opendatahub-io org 下新增/重命名的仓库,本周第一次进 OAI 主 operator 的 manifests-config。OAI 的"组件清单"在快速膨胀。
- **职责下沉**:HardwareProfile 注入和 ModelCache 编排都从 opendatahub-operator 搬到 kserve-module-operator;主 operator 的 IS/LLMis webhook 直接删除([#3580](https://github.com/opendatahub-io/opendatahub-operator/pull/3580))。
- **Go 1.26 全面升级**:[operator Dockerfile #3586](https://github.com/opendatahub-io/opendatahub-operator/pull/3586)、[model-registry #2754](https://github.com/opendatahub-io/model-registry/pull/2754) 同步切。
- **3.5-ea.2 切支**:[chore: update RHOAI branch to rhoai-3.5-ea.2 #3582](https://github.com/opendatahub-io/opendatahub-operator/pull/3582),notebooks Konflux 基础镜像也批量打到 `v3.5.0-ea.2-*` tag([#3769](https://github.com/opendatahub-io/notebooks/pull/3769) 等)。
- **prevent-reset of kserve-local-gateway**([#3549](https://github.com/opendatahub-io/opendatahub-operator/pull/3549)):operator 不再把用户改过的 kserve-local-gateway 配置 reset 回默认,典型的"用户自定义优先"补丁。

## 上游生态整合动向

- **llm-d**:[bumping llm-d versions to v0.6.0 #1360](https://github.com/opendatahub-io/kserve/pull/1360) 还在 open,当前 kserve 仍是 llm-d v0.5(对应 Red Hat 5/27 的"inference-aware routing"博客 [redhat.com/.../same-16-gpus-twice-users-...](https://www.redhat.com/en/blog/same-16-gpus-twice-users-inference-aware-routing-llm-clusters));[#3593 switch 2 llm-d images after renaming](https://github.com/opendatahub-io/opendatahub-operator/pull/3593) 把镜像名换成 `llm-d-router-endpoint-picker` / `llm-d-router-d`,意味着 llm-d 0.5→0.6 间还做了组件级改名。
- **KServe 主线 sync**:[#1522 sync upstream/master to odh/master](https://github.com/opendatahub-io/kserve/pull/1522) 解了 12 个冲突,fork 与上游差距正在拉开。
- **Kubeflow Model Registry**:[#1750](https://github.com/opendatahub-io/model-registry/pull/1750) / [#1747](https://github.com/opendatahub-io/model-registry/pull/1747) 持续做 `[pull] main from kubeflow:main`;同时 ODH fork 自己在做 catalog 插件化([#2751 split unified plugin into per-domain plugins](https://github.com/opendatahub-io/model-registry/pull/2751)、[#2735 split OpenAPI spec into per-plugin files](https://github.com/opendatahub-io/model-registry/pull/2735)、[#2726 share filter components across model and MCP catalogs](https://github.com/opendatahub-io/model-registry/pull/2726))。
- **agents-operator / ai-gateway-operator**:呼应 Red Hat 5/12 那篇"Red Hat AI 3.4"博客里的 Kagenti / MCP gateway 故事([redhat.com/.../inference-agentic-ai-scaling-...](https://www.redhat.com/en/blog/inference-agentic-ai-scaling-enterprise-foundation-red-hat-ai-34)),代码层这周才真正开始整合进 ODH。

## 值得跟进

- [ ] 把 modular handler 框架的 [PR #3459](https://github.com/opendatahub-io/opendatahub-operator/pull/3459) 与配套的 module integration PR(#3584/#3596/#3597/#3598)读完,提炼一份"OAI 子 operator 注册契约",评估能不能套到我们自家产品的子组件管理。
- [ ] 跟踪 [llm-d v0.6 bump #1360](https://github.com/opendatahub-io/kserve/pull/1360) 合入节奏 + 上游 llm-d v0.6 release notes,确认"router-endpoint-picker / router-d"的功能差异,以判断我们做推理网关时是直接吃 llm-d 还是再封一层。
- [ ] 试一下 [kserve-module 动态 CRD watch #1537](https://github.com/opendatahub-io/kserve/pull/1537) 的代码模式(`controller.Watch(source.Kind)` + retry 注册),在我们 operator 里对可选 CRD 抄一份,解决重启 controller 问题。
- [ ] 评估 MaaS 三件套(auto-provision gateway / 前置条件检测 / UI 错误展示)的整体 UX 路径,跟我们 MaaS 故事做差异对照,看是不是补"开箱即用"这一块。
- [ ] 关注 odh-mod-arch-agent-ops 这条线([dashboard #7746](https://github.com/opendatahub-io/odh-dashboard/pull/7746))后续会接入什么 agent UI,可能是 Red Hat 把 Kagenti 投到 Dashboard 的入口。

## 原始材料

<details>
<summary>本次扫描清单</summary>

仓库 / merged PR 数(2026-05-26 之后):

- opendatahub-io/opendatahub-operator: 11 (含 1 个 EA 切支 PR)
- opendatahub-io/odh-dashboard: 19(其中 6 个 axios bump,大量 e2e fix)
- opendatahub-io/kserve: 7
- opendatahub-io/notebooks: 18+(集中在 Konflux 镜像 bump、CVE 修复、AGENTS.md 重构)
- opendatahub-io/data-science-pipelines-operator: 3
- opendatahub-io/model-registry: 4(每 sync 算 1)+ 30 余条主线 commit
- opendatahub-io/trustyai-service-operator: 1

发布(过去 30 天):

- opendatahub-operator `v3.5.0-ea.1`(2026-05-08),3.5-ea.2 在 branching 中
- kserve `odh-v3.5-EA1`(2026-05-04)
- odh-dashboard `v3.4.3-odh`(2026-05-04)
- model-registry `v0.3.9`(2026-05-04)

Red Hat 官方博客(参考):

- 2026-05-12 [From inference to agents: Scaling AI in the enterprise with Red Hat AI 3.4](https://www.redhat.com/en/blog/inference-agentic-ai-scaling-enterprise-foundation-red-hat-ai-34)
- 2026-05-27 [The same 16 GPUs, twice the users: Inference-aware routing for LLM clusters](https://www.redhat.com/en/blog/same-16-gpus-twice-users-inference-aware-routing-llm-clusters)
- 2026-05-20 [Bringing Claude self-hosted sandboxes to OpenShell on Red Hat AI](https://www.redhat.com/en/blog/bringing-claude-self-hosted-sandboxes-to-openshell-on-red-hat-ai)

</details>
