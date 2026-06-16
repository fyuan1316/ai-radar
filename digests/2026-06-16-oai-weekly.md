# OpenShift AI 周报 2026-06-16

> 扫描窗口:2026-06-09 ~ 2026-06-16,7 个 opendatahub-io 仓库。本周正值 **ODH 3.5 EA2** 切版,多仓同步发版,信息量大。

## 摘要(3 条以内)

- **统一推理网关(Gateway)架构成形**:operator 主仓把全新组件 `odh-ai-gateway-operator` 纳入 manifests;dashboard 同步改造,`LLMInferenceService` 端点改读 KServe `status.addresses` 以支持 **llm-d gateway 路由**。OAI 的 3.x 正在用"AI Gateway + llm-d"替换老的 OAuth/手工 URL 拼接路径。
- **Dashboard 全面转向 Agentic / GenAI 产品形态**:新增 Agent Profiles(CRUD API + ConfigMap 持久化 + AI Asset Endpoints 页签)、View Code 切到 OpenAI SDK、MaaS(模型即服务)订阅与 API Key 管理、ASR/音频转写/Vision 多模态 UX——控制台的重心从"训练/部署"明显向"消费大模型 API"迁移。
- **模块化 Operator 架构进入硬切阶段**:dashboard-operator 把 CRD 迁到 `components.platform.opendatahub.io/v1alpha1`、对接 ModuleHandler;kserve 用 distro build tag 隔离 ODH 逻辑、新增 WVA(Workload Variant Autoscaler)子组件。但 **trainer-operator 因自家 build 基建尚不支持 module operator 被临时下架(offboard)**,说明这套模块化改造还在路上。

## 新功能 / 能力

- [Add odh-ai-gateway-operator to manifests-config.yaml (#3598)](https://github.com/opendatahub-io/opendatahub-operator/pull/3598) — 新组件 `odh-ai-gateway-operator`(上游 opendatahub-io/ai-gateway-operator)纳入平台 manifests,RHOAIENG-65493。
  - 启示:这是一个独立的 AI 网关组件,定位很可能是统一对外的模型/Agent API 入口(鉴权、路由、限流)。我们若也想做 MaaS/对外 API 网关,应直接对标它的能力边界——是自研 Envoy/Gateway API 还是包一层,关系到我们网关层的选型。
- [use KServe status.addresses for LLMInferenceService endpoint (#7882)](https://github.com/opendatahub-io/odh-dashboard/pull/7882) — 端点解析从手工拼 URL 改为读 `status.addresses[]`,过滤 `.svc.cluster.local`,以打通 **llm-d gateway 路由**,RHOAIENG-36320。
  - 启示:OAI 把 llm-d 作为 LLM 推理的默认数据面在落地。我们产品若仍用 KServe 经典 InferenceService + 单 address,需要评估迁到 `LLMInferenceService` + llm-d 的成本与收益(PD 分离、KV-cache 感知路由)。
- [Add WVA sub-component ManagementState reconciliation (#1609)](https://github.com/opendatahub-io/kserve/pull/1609) — KServe module 新增 **WVA(Workload Variant Autoscaler)** 子组件,默认 Removed,可切 Managed。
  - 启示:WVA 是面向推理的"变体感知"自动伸缩(不同精度/并行度变体),比 HPA/KEDA 更贴 LLM 负载。值得跟进它的伸缩信号源(是否复用 llm-d 指标),这正是我们 GPU 调度差异化的发力点。
- [Agent Profiles tab + CRUD API + ConfigMap 存储 (#7987](https://github.com/opendatahub-io/odh-dashboard/pull/7987), [#7941](https://github.com/opendatahub-io/odh-dashboard/pull/7941), [#7917)](https://github.com/opendatahub-io/odh-dashboard/pull/7917) — 在 AI Asset Endpoints 页新增 Agent Profiles,提供完整增删改查并以 ConfigMap 持久化,gate 在 `agentProfileManagement` 开发标志后。
  - 启示:OAI 把"Agent 配置"做成平台一等公民(声明式、存 ConfigMap)。我们若做 Agent 平台,Agent 定义的存储模型(CR vs ConfigMap)和与网关的绑定关系是可以直接借鉴的设计先例。
- [model catalog cold-start / vRAM / 容器尺寸过滤器接真实 API (#2815)](https://github.com/opendatahub-io/model-registry/pull/2815) + [persist cold_start_matrix as JSON (#2820)](https://github.com/opendatahub-io/model-registry/pull/2820) — 模型目录新增按**冷启动时间、显存占用、容器体积**筛选模型,cold_start_matrix 作为 JSON custom property 持久化。
  - 启示:模型注册中心正从"元数据登记"演进为"带资源画像的选型助手"。这类 cold-start/vRAM 画像对我们做 GPU 排布、Serverless 缩容到零的体验很关键,建议评估在自家 registry 复刻该字段。

## 架构 / 依赖变化

- **模块化 Operator(ModuleHandler)硬切**:[dashboard-operator 迁 CRD 到 `components.platform.opendatahub.io/v1alpha1` 并加 platform contract (#7795)](https://github.com/opendatahub-io/odh-dashboard/pull/7795),对接 ODH Operator 的 ModuleHandler 注册(RHOAIENG-61029);operator 主仓支持 [controller image 注入到 init container (#3639)](https://github.com/opendatahub-io/opendatahub-operator/pull/3639)。
- **trainer-operator 临时下架**:[offboard trainer operator (#3647)](https://github.com/opendatahub-io/opendatahub-operator/pull/3647) —— 原因明确写着"build 基建尚不支持 module operator 的模块化架构,改造完成前无法 onboard"。同期却又 [把 `odh-trainer-operator` 加进 manifests (#3597)](https://github.com/opendatahub-io/opendatahub-operator/pull/3597),是一次反复/过渡。
  - 启示:OAI 的"每个组件 = 独立 module operator"路线代价不小(build/CI 都要改),自家若在做类似拆分,可参考其踩坑顺序:先把 ModuleHandler/CRD 契约定死,再逐个迁,别一次性全切。
- **Gateway 取代 OAuth 的收尾**:[修复升级时 stale client ID 并清理 legacy OAuthClient (#3638)](https://github.com/opendatahub-io/opendatahub-operator/pull/3638)、[forward user-agent 到 kube-auth-proxy (#3557)](https://github.com/opendatahub-io/opendatahub-operator/pull/3557)、[更新 Prometheus 规则适配 3.x gateway 架构 (#3574)](https://github.com/opendatahub-io/opendatahub-operator/pull/3574)——一组围绕"3.x gateway 架构"的鉴权/可观测收尾改动。
- **KServe distro build tag 隔离**:[isvc reconciler 的 ODH 逻辑藏到 distro build tag 后 (#1559)](https://github.com/opendatahub-io/kserve/pull/1559)、[localmodel 用 receiver 方法做 platform hook (#1566)](https://github.com/opendatahub-io/kserve/pull/1566)——OAI fork 在用编译期 tag 把下游定制与上游解耦,降低 rebase 成本。

## 上游生态整合动向

- **KServe / llm-d**:本周 KServe fork 的主线就是 module 化 + WVA + llm-d 路由(见上)。`LLMInferenceService` + `status.addresses` 是 OAI 接 llm-d 的官方姿势,值得作为我们跟 llm-d 整合的参考实现。
- **vLLM / OpenAI 兼容**:dashboard [View Code 片段从 ogx-client 切到 OpenAI SDK (#7961)](https://github.com/opendatahub-io/odh-dashboard/pull/7961),并 [新增 BFF 音频转写端点与通用媒体上传 (#7808)](https://github.com/opendatahub-io/odh-dashboard/pull/7808)——对外一律 OpenAI 协议(含多模态),背后由 vLLM/llm-d 承载。
- **Kubeflow model-registry**:持续从 [kubeflow/model-registry 同步 (#7979)](https://github.com/opendatahub-io/odh-dashboard/pull/7979),catalog 能力(cold-start/vRAM 画像)是 OAI 在上游基础上的下游增强。
- **TrustyAI / 评测 / Guardrails**:evalhub 推进——[CRD 升 v1 + conversion webhook (#758)](https://github.com/opendatahub-io/trustyai-service-operator/pull/758)、[标准 LLM 评测套件与 benchmark 集合 (#754)](https://github.com/opendatahub-io/trustyai-service-operator/pull/754)、[MCP 部署加 rbac-proxy 鉴权 (#753)](https://github.com/opendatahub-io/trustyai-service-operator/pull/753)、[NemoGuardrails 支持 affinity/tolerations/nodeSelector](https://github.com/opendatahub-io/trustyai-service-operator/pull/747)。可信 AI 正在把"评测 + 护栏 + MCP"做成一条独立产品线。
- **Feature Store**:dashboard 把 Feature Store 与 Workbench 打通([connected workbenches 弹窗 #7924](https://github.com/opendatahub-io/odh-dashboard/pull/7924)、[Workbench 展开行显示 Connected feature stores #7932](https://github.com/opendatahub-io/odh-dashboard/pull/7932))。

## 值得跟进

- [ ] 读透 [opendatahub-io/ai-gateway-operator](https://github.com/opendatahub-io/ai-gateway-operator) 的 CRD 与能力边界,判断它和 llm-d gateway、Istio/Gateway API 的分层关系——这决定我们网关层是否需要单独造轮子。
- [ ] 评估 `LLMInferenceService` + llm-d 路由路径(对照 PR [#7882](https://github.com/opendatahub-io/odh-dashboard/pull/7882)),在自家测试集群跑一遍 PD 分离 / KV-cache 感知路由,量化对长上下文吞吐的收益。
- [ ] 跟踪 [WVA(Workload Variant Autoscaler) #1609](https://github.com/opendatahub-io/kserve/pull/1609) 的伸缩信号设计,对照我们现有 GPU 调度/弹性方案,找差异化点。
- [ ] 复盘 OAI 的 module operator 迁移路线([dashboard-operator #7795](https://github.com/opendatahub-io/odh-dashboard/pull/7795) + [trainer offboard #3647](https://github.com/opendatahub-io/opendatahub-operator/pull/3647)),为我们自家 operator 拆分定迁移顺序与 build/CI 改造清单。
- [ ] 在自家 model registry 评估引入 cold-start/vRAM 资源画像字段(对照 [#2815](https://github.com/opendatahub-io/model-registry/pull/2815)),用于选型与调度。

## 原始材料

<details>
<summary>本周扫描清单(7 仓 / 窗口 2026-06-09 ~ 06-16)</summary>

**本周新发布(EA2 切版)**
- odh-dashboard `v3.4.4-odh`(2026-06-15)
- kserve `odh-v3.5-EA2`(2026-06-15)
- notebooks `v1.45.0` / `3.5_ea2-v1.45.0`(2026-06-12)
- model-registry `v0.3.10`(2026-06-15)
- trustyai-service-operator `odh-3.5-ea2`(2026-06-12)
- operator 主仓最新仍为 `v3.5.0-ea.1`(2026-05-08),本周仅 main 提交

**7 天 main 提交量**
- odh-dashboard 62、notebooks 51、model-registry 23、kserve 15、trustyai 12、opendatahub-operator 11、data-science-pipelines-operator 1

**operator 主仓关键提交**
- #3598 odh-ai-gateway-operator 入 manifests / #3647 offboard trainer / #3597 odh-trainer-operator 入 manifests
- #3638 gateway stale client ID 修复 + 清理 legacy OAuthClient / #3557 user-agent → kube-auth-proxy / #3574 Prometheus 规则适配 3.x gateway
- #3639/#3632 controller image 注入 init container / #3631 platform CRD 入 rhaii config / #3572 CleanupStaleConditions

**kserve(odh midstream)关键提交**
- #1609 WVA 子组件 ManagementState / #1559 isvc reconciler distro build tag 隔离 / #1566 localmodel platform hook
- #1567 distro-builds 规则 + GOTAGS / #1468 deployment profile support

**model-registry catalog**
- #2815 cold-start/vRAM/容器尺寸过滤接真实 API / #2820 cold_start_matrix 存 JSON / #2818 cold-start artifact 名按 modelID 唯一化 / #2821 readiness 与 leadership 解耦防滚动更新死锁

**dashboard(gen-ai / agent / MaaS)**
- #7987/#7941/#7917 Agent Profiles tab + CRUD + ConfigMap 持久化 / #7959 序列化与 URL 载入
- #7882 LLMInferenceService 用 status.addresses(llm-d 路由)/ #7961 View Code 切 OpenAI SDK / #7808 BFF 音频转写端点
- #7795/#7797 dashboard-operator CRD 迁移 + platform contract + 动态依赖发现
- MaaS:API key 表排序 #7950、key count #7927、订阅清理 #7945;多模态 ASR/Vision #7898/#7913

**trustyai evalhub**
- #758 CRD 升 v1 + conversion webhook / #760 discovery ConfigMap 注入租户 ns / #761 metrics Service + ServiceMonitor / #754 标准 LLM 评测套件 / #753 MCP rbac-proxy 鉴权 / #747 NemoGuardrails affinity/tolerations

**data-science-pipelines-operator**:仅 1 笔(chaos testing 文件),本周无实质功能更新

</details>
