# OpenShift AI 周报 2026-07-28

扫描窗口:2026-07-21 → 2026-07-28(过去 7 天),覆盖 opendatahub-io 下 7 个核心仓库(operator 31 / dashboard 114 / kserve 51 / notebooks 68 / model-registry 27 / trustyai 7 / dspo 0 提交)。本周是**发版周**:3.5 GA 全家桶落地(dashboard v3.5.0、kserve odh-v3.5、model-registry v0.3.14 均 07-27 打标),同时 operator 侧完成了一次**深层架构转向——把主要组件从 in-tree controller 全量迁到"module operator"(Helm chart 部署)**。

## 摘要(3 条)

- **3.5 GA 全家桶发布**:odh-dashboard [v3.5.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.5.0)、kserve [odh-v3.5](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.5)、model-registry [v0.3.14](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.14) 同日(07-27)打标,operator 也 [bump 到 3.5 GA](https://github.com/opendatahub-io/kserve/pull/1766)。上周成型的 MaaS 网关、KServe RawDeployment 金丝雀、Agent/MLflow 内嵌本周随 3.5 GA 一起下沉为正式版本。
- **组件全面"模块化"(RHAISTRAT-1064)**:operator 把 dashboard、kserve、workbenches、MLflow、FeastOperator 逐一从 in-tree 组件控制器迁到 module operator 框架(各自用 Helm chart 部署 + 独立 module-operator 管生命周期),并支持 [Standalone 部署模式](https://github.com/opendatahub-io/opendatahub-operator/pull/3869)。这是平台从"单体 operator 内嵌所有组件"转向"operator-of-operators / 可插拔模块"的关键一步。
- **集群 TLS 安全档端到端贯通**:operator 把集群 TLS profile 注入 kube-rbac-proxy sidecar 并[下发 cert-manager 共享配置给各模块](https://github.com/opendatahub-io/opendatahub-operator/pull/3866),kserve [接入集群 TLS 安全档](https://github.com/opendatahub-io/kserve/pull/1716)、[动态发现 cert-manager 命名空间](https://github.com/opendatahub-io/kserve/pull/1801)。合规级 TLS 强度统一治理正在成为平台默认能力。

## 新功能 / 能力

### 平台架构:组件模块化(operator 本周主线)
- [migrate dashboard to module-based architecture(#3733)](https://github.com/opendatahub-io/opendatahub-operator/pull/3733) — dashboard 从 in-tree 组件控制器迁到 ModuleHandler,用 odh-dashboard 仓自带的 `dashboard-operator` Helm chart 渲染部署;配套 [migrate FeastOperator 到 module operator(#3694)](https://github.com/opendatahub-io/opendatahub-operator/pull/3694)、[integrate workbenches as module operator(#3817)](https://github.com/opendatahub-io/opendatahub-operator/pull/3817)、[add module handler for kserve-module-operator(#3704)](https://github.com/opendatahub-io/opendatahub-operator/pull/3704)、[Move MLflow to module handler path(#3654)](https://github.com/opendatahub-io/opendatahub-operator/pull/3654)。
  - 启示:OAI 正把"主 operator 内嵌全部组件"重构成 **operator-of-operators**——每个能力是独立 module-operator(带自己的 Helm chart 与 CR 生命周期),主 operator 只做编排、状态镜像进 DSC、按需 mirror status。这直接对标我们自研平台的组件解耦难题:若我们仍是单体 controller 打包所有能力,升级耦合、灰度困难。值得研究其 ModuleHandler 抽象(module 声明、submodule、OIDC projection、status 回填 DSC)作为我们组件插件化的参考架构。
- [enable Standalone deployment mode(#3869)](https://github.com/opendatahub-io/opendatahub-operator/pull/3869) + dashboard 侧 [restructure kustomize:merge base / rename sidecar / add standalone overlays(#8708)](https://github.com/opendatahub-io/odh-dashboard/pull/8708) — dashboard 可脱离完整平台独立部署。
  - 启示:模块化的直接红利是"单组件可独立交付",利于按需/最小化安装。我们做私有化交付时也常遇"客户只要推理不要全套",这套 standalone overlay 思路可借鉴。
- [dashboard-operator: preserve user-configured replicas/resources per ADR-0005(#8846)](https://github.com/opendatahub-io/odh-dashboard/pull/8846)、[ConfigMap 内容哈希触发 federation 滚动重启(#8786)](https://github.com/opendatahub-io/odh-dashboard/pull/8786) — module-operator 尊重用户手改的副本/资源(不再被 reconcile 覆盖),并用配置哈希驱动前端 module-federation 滚更。kserve module 也有[同款 preserve user-set replicas/resources(#1772)](https://github.com/opendatahub-io/kserve/pull/1772)。
  - 启示:"reconcile 不覆盖用户手改字段"是 operator 成熟度的硬指标(ADR-0005 明确成规范),我们的 controller 若还在无脑覆盖 replicas/resources,应尽快引入同类 3-way merge / 保留策略。

### 安全 / 合规:集群 TLS 安全档
- [inject cluster TLS profile into kube-rbac-proxy sidecars(#3717)](https://github.com/opendatahub-io/opendatahub-operator/pull/3717) — 把集群解析出的 `TLSProfileSpec` 翻成 `--tls-min-version` / `--tls-cipher-suites` 注入监控代理 sidecar;[forward cert-manager shared config to modules(#3866)](https://github.com/opendatahub-io/opendatahub-operator/pull/3866) 把 cert-manager 共享配置下发给各模块;kserve 侧 [integrate with cluster TLS security profile(#1716 / 上游 #5791)](https://github.com/opendatahub-io/kserve/pull/1716)、[动态发现 cert-manager namespace 做 CA 查找(#1801)](https://github.com/opendatahub-io/kserve/pull/1801)、[把 TLS distro role 绑到 localmodel controller 与 agent(#1812)](https://github.com/opendatahub-io/kserve/pull/1812)。
  - 启示:OpenShift 的 TLS 安全档(Old/Intermediate/Modern/Custom)被作为**单一事实源**贯穿所有组件的 sidecar 与 webhook,而不是各组件各配一套。企业合规(FIPS、密码套件基线)场景下这是刚需——我们平台应把"集群级 TLS 策略统一注入所有数据面组件"做成能力,而非让每个组件散配。
- operator [extend admin RBAC role for app logs access(#3859)](https://github.com/opendatahub-io/opendatahub-operator/pull/3859) — 管理员角色扩权访问应用日志。

### 推理服务(KServe)
- 本周 kserve 以 3.5 GA 收尾为主:大量 e2e/CI 稳定化(canary 流量测试、CanaryPredictorReady 轮询、cert-manager webhook 主动探测替代 sleep),以及上周金丝雀/DRA 能力的加固。
- [wire disconnected image references through env vars(#1708)](https://github.com/opendatahub-io/kserve/pull/1708) — 断网(disconnected)环境镜像引用走环境变量注入。
  - 启示:disconnected/air-gapped 是政企与信创客户的标配场景,镜像引用参数化是硬需求,值得对照我们自己的离线部署镜像改写方案。
- [llmisvc: skip v1alpha2 InfPool reconcile when CRD absent(#5890)](https://github.com/kserve/kserve/pull/5890)、[bump scheduler version gate for downstream llm-d-router image(#1786)](https://github.com/opendatahub-io/kserve/pull/1786) — LLMInferenceService(llm-d)持续加固,CRD 缺失时优雅降级。

### 控制台(odh-dashboard)
- [Promote projectRBAC + roleManagement 从 Tech Preview 到 GA(#8763)](https://github.com/opendatahub-io/odh-dashboard/pull/8763) — 项目级 RBAC 与角色管理正式 GA(上周还是 tech preview)。
  - 启示:多租户"项目级 RBAC + 角色管理"进 GA,意味着 OAI 认为其租户隔离/授权模型已生产就绪。这是企业级卖点,我们应对照自家多租户权限模型的成熟度与 GA 节奏。
- **llm-d 服务面产品化**:[Add llmdTemplates Tech Preview flag,放出 topology/routing 字段与 admin 页(#8781)](https://github.com/opendatahub-io/odh-dashboard/pull/8781)、[topology 变更时重置 routing 配置并对不兼容选择告警(#8764)](https://github.com/opendatahub-io/odh-dashboard/pull/8764)、[llm-d 配置表列排序(#8570)](https://github.com/opendatahub-io/odh-dashboard/pull/8570)、[llm-d routing 配置 admin 页 E2E(#8778)](https://github.com/opendatahub-io/odh-dashboard/pull/8778)。
  - 启示:llm-d(分布式/PD 分离推理)正从后端能力长出**控制台配置面**(拓扑、路由、admin 页)。这是把"分布式推理"变成产品可视化配置的关键一跳,我们若在做 PD 分离/多实例路由,需同步规划其 UI 配置模型,别只停在 CR/YAML。
- [Implement Feature Store management page(#8409)](https://github.com/opendatahub-io/odh-dashboard/pull/8409) + [Feature Store Segment 埋点(#8398)](https://github.com/opendatahub-io/odh-dashboard/pull/8398) — 配合 operator 侧 FeastOperator 模块化,Feast 特征商店拿到独立管理 UI。
  - 启示:model-registry(模型)+ Feature Store(特征)双目录成型,OAI 在补齐 MLOps 数据侧拼图。我们若只做模型注册,特征管理是明确的能力缺口。
- 工程化:大规模 [decouple model-serving from @odh-dashboard/internal(#8646)](https://github.com/opendatahub-io/odh-dashboard/pull/8646)、[定义 model-serving 稳定公共 API 面(#8600)](https://github.com/opendatahub-io/odh-dashboard/pull/8600)、host-api bridge 解耦——前端正把 model-serving 抽成有稳定 API 边界的独立包(配合 module-federation 架构)。
  - 启示:前端也在走"包边界 + 联邦"路线呼应后端模块化,做插件化控制台的团队值得参考其 public API surface 治理。

### 模型注册(model-registry)
- 本周以 [v0.3.14](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.14) 发版收尾 + 大批依赖 bump;实质变更为 Agents Catalog / MCP settings 的[文案与 A11y 修复(#3001](https://github.com/opendatahub-io/model-registry/pull/3001)、[#3002)](https://github.com/opendatahub-io/model-registry/pull/3002) 及 [model catalog 迁到 orderBy=RECOMMENDED(#2889)](https://github.com/opendatahub-io/model-registry/pull/2889)。上周落地的 Agents Catalog 本周随 GA 稳定。

### 可信 AI / 评估(trustyai)
- [evalhub 健康探针改走 /api/v1/health(#832)](https://github.com/opendatahub-io/trustyai-service-operator/pull/832)、[移除 limit 后同步 collections(#831)](https://github.com/opendatahub-io/trustyai-service-operator/pull/831)、新增 early-gate CI。evalhub(LM 评估)本周主要是收敛稳定,无新形态。

### 工作台镜像(notebooks)
- 本周几乎全是 CI/lockfile/base image 维护:切到 `3.6_ea1` 基础镜像标签、Konflux 引用更新、[非 ROCm 镜像启用 arm64(#4170)](https://github.com/opendatahub-io/notebooks/pull/4170)、引入 [Antigravity agentic-reviewer CI(#3806)](https://github.com/opendatahub-io/notebooks/pull/3806)。无面向用户的新镜像能力。
  - 注:base image 已在为 **3.6 EA** 铺路(`v3.6.0-ea.1` 标签),下个 EA 周期开始预热。

## 架构 / 依赖变化

- **module operator 框架**成为 operator 核心:新增 `internal/controller/modules/*` ModuleHandler、支持声明 submodule、status 镜像进 DSC、OIDC projection;manifests 里[移除 odh-dashboard 与 odh-maas-api 静态清单(#3873)](https://github.com/opendatahub-io/opendatahub-operator/pull/3873)(改由 module operator 部署)。
- kserve module [每 pod 启动经 odh-crds overlay 装一次 CRD(#1778)](https://github.com/opendatahub-io/kserve/pull/1778),延续上周 CRD 与 controller 解耦路线。
- Kueue 升级:operator [kueueOcpOperatorChannel 切 stable-v1.4(#3843)](https://github.com/opendatahub-io/opendatahub-operator/pull/3843);dashboard 侧 Workbenches × Kueue 集成埋点/生命周期 E2E 持续投入。
- MaaS URL 语义反复:dashboard 先 [改用 /v1/tenants(#8578)](https://github.com/opendatahub-io/odh-dashboard/pull/8578) 又 [revert(#8800)](https://github.com/opendatahub-io/odh-dashboard/pull/8800),并 [remove maas 前缀(#8785)](https://github.com/opendatahub-io/odh-dashboard/pull/8785)——MaaS API 面在 GA 前仍在微调。

## 上游生态整合动向

- **llm-d**:kserve LLMInferenceService + dashboard llm-d 配置面双向推进(见上),下游 llm-d-router 镜像 scheduler 版本门控。这是 OAI 押注的分布式推理路线,和 vLLM/PD 分离生态强绑定。
- **KServe 上游同步**频繁(本周多次 `sync upstream/master`),odh 分支紧跟 kserve/kserve master;上游 [restructure CRD management]、cluster TLS profile 等能力同步进 odh。
- **Feast(Feature Store)**:上游 feast-operator 被包成 module-operator 纳管,补齐特征商店。
- **Kubeflow model-registry**:持续从 kubeflow/main 同步(多个 Merge from kubeflow/main),odh 分支跟上游 UI/catalog 变更。

## 值得跟进

- [ ] 精读 operator ModuleHandler 抽象([#3733](https://github.com/opendatahub-io/opendatahub-operator/pull/3733) / [#3704](https://github.com/opendatahub-io/opendatahub-operator/pull/3704) 及 `internal/controller/modules/`),评估把我们单体 operator 拆成 operator-of-operators 的可行性与迁移成本。
- [ ] 试装 3.5 GA(dashboard [v3.5.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.5.0) + kserve [odh-v3.5](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.5)),重点体验 Standalone 部署模式与 module-operator 独立交付路径。
- [ ] 评估"集群 TLS 安全档统一注入所有数据面 sidecar/webhook"([#3717](https://github.com/opendatahub-io/opendatahub-operator/pull/3717))作为我们合规(FIPS/密码套件基线)能力的落地方案。
- [ ] 对照 projectRBAC + roleManagement GA([#8763](https://github.com/opendatahub-io/odh-dashboard/pull/8763))评估我们多租户授权模型的成熟度差距。
- [ ] llm-d 控制台配置面([#8781](https://github.com/opendatahub-io/odh-dashboard/pull/8781) / [#8764](https://github.com/opendatahub-io/odh-dashboard/pull/8764)):若我们在做 PD 分离/多实例路由,规划对应 UI 配置模型。
- [ ] 关注 notebooks `3.6_ea1` 基础镜像——下个 EA 周期已开始预热。

## 原始材料(折叠)

<details>
<summary>本次扫描清单</summary>

- 窗口:2026-07-21T03:00Z → 2026-07-28(过去 7 天)
- 提交量:operator 31 / odh-dashboard 114(2 页)/ kserve 51 / notebooks 68 / model-registry 27 / trustyai 7 / data-science-pipelines-operator 0
- 本周 release:odh-dashboard `v3.5.0`(07-27)、`v3.5.0-odh`(07-24);kserve `odh-v3.5`(07-27);model-registry `v0.3.14`(07-27);operator 无新 tag(最新仍 `v3.5.0-ea.2`,但代码已 bump 3.5 GA);trustyai 无新 tag(最新 `odh-3.5-ea2`)
- operator 重点 PR:#3733 #3694 #3704 #3817 #3654(模块化)、#3869(standalone)、#3717 #3866 #3859(TLS/RBAC)、#3843(Kueue stable-v1.4)
- kserve 重点 PR:#1766(3.5 GA bump)、#1716/#5791 #1801 #1812(TLS)、#1708(disconnected)、#1772 #1778(module)、#5890 #1786(llmisvc)
- dashboard 重点 PR:#8763(RBAC GA)、#8781 #8764 #8570 #8778(llm-d)、#8409 #8398(Feature Store)、#8846 #8786 #8708(module-operator/standalone)、#8600 #8646(前端解耦)
- model-registry:v0.3.14 发版 + 依赖 bump 为主,实质仅 #3001/#3002/#2889 文案与 catalog 排序
- trustyai:#832 #831 evalhub 收敛 + early-gate CI
- notebooks:CI/lockfile/base image 维护为主,3.6_ea1 基础镜像预热
</details>
