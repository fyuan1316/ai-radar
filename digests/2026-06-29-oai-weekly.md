# OpenShift AI 周报 2026-06-29

窗口:2026-06-22 -> 2026-06-29(7 天)

## 摘要(3 条以内)
- ODH/OAI 本周主线从 3.5 EA2 的组件版本矩阵继续向平台化能力落地推进:ODH operator PR 已出现 AI Gateway 默认 DSC、`inferencePayloadProcessing`、xKS platform CR、MCP lifecycle module、dashboard operator manifest 等信号。
- ODH Dashboard 本周高频推进 GenAI/MaaS/LLM-D/Agent Ops:新增 LLM-D deployment wizard 的 topology type/custom config、agent deployments filter、MaaS subscription empty state 和 GenAI custom endpoint e2e。
- ODH KServe fork 发布 [v3.5.0+rhaiv.0](https://github.com/opendatahub-io/kserve/releases/tag/v3.5.0%2Brhaiv.0)，同时 PR 侧继续迁移 HWP upgrade path、ModelCache 命名空间、LLM-D image env、LLMInferenceServiceConfig RBAC。

## 新功能 / 能力

- [ODH Operator PR #3715](https://github.com/opendatahub-io/opendatahub-operator/pull/3715) 和 [#3709](https://github.com/opendatahub-io/opendatahub-operator/pull/3709) — AI Gateway 已进入默认 DSC / xKS platform CR 相关变更；[#3712](https://github.com/opendatahub-io/opendatahub-operator/pull/3712) 为 AIGateway spec 增加 `inferencePayloadProcessing`。
  - 启示:OAI 的 MaaS/LLM endpoint 入口正在从单纯 Route/Gateway 配置转向专门 AI Gateway 模型。我们设计 MaaS 网关时要把 payload processing、认证、限流、审计、订阅状态放在同一个控制面里。
- [ODH Operator PR #3713](https://github.com/opendatahub-io/opendatahub-operator/pull/3713) — 新增 `odh-mcp-lifecycle-module-operator` 到 operator manifests。
  - 启示:MCP/Agent 生命周期开始进入平台组件清单，后续 OAI 可能把工具调用、agent deployment、MCP server 生命周期纳入标准发行版。我们应提前定义 Agent/MCP 的安装、租户权限和运行态观测边界。
- [ODH Dashboard PR #8312](https://github.com/opendatahub-io/odh-dashboard/pull/8312) — LLM-D serving deployment wizard 增加 topology type 和 custom config selection。
  - 启示:LLM-D 不再是隐藏在 values/configmap 里的后端选项，控制台会暴露 topology/config 决策。我们的推理部署向导也应把 aggregate、PD、KV cache、router/autoscaler 配置显式化。
- [ODH Dashboard PR #8309](https://github.com/opendatahub-io/odh-dashboard/pull/8309) — Agent deployments list 增加 project/status filters。
  - 启示:Agent Ops 正在形成资源列表与生命周期视图。我们如果支持 Agent 应用，应先把部署状态、项目隔离、trace/eval 入口串起来，而不是只提供一个 playground。
- [ODH KServe PR #1676](https://github.com/opendatahub-io/kserve/pull/1676) — ModelCache 部署到 `model-serving-cache` namespace。
  - 启示:模型缓存已经从 KServe 内部实现细节变成可独立管理的 namespace 资源。我们做缓存能力时需要明确隔离、容量、回收和权限，而不只是给 workload 挂 PVC。

## 架构 / 依赖变化

- [ODH KServe PR #1679](https://github.com/opendatahub-io/kserve/pull/1679) — HWP upgrade path 从 opendatahub-operator 迁移到 kserve-module。
  - 启示:ODH 正把部分升级路径下沉到组件 module。我们维护 AI 平台组件时也要区分平台总控升级与组件自升级责任，避免所有状态迁移都堆在总 operator。
- [ODH KServe PR #1672](https://github.com/opendatahub-io/kserve/pull/1672) — 修正 LLM-D `RELATED_IMAGE` env var 名称。
  - 启示:LLM-D 这类多镜像组件对 relatedImages / disconnected install 很敏感。企业离线交付必须把 router、sidecar、model cache、gateway 等所有镜像纳入制品清单验证。
- [ODH Operator PR #3717](https://github.com/opendatahub-io/opendatahub-operator/pull/3717) — kube-rbac-proxy sidecar 注入 cluster TLS profile。
  - 启示:OAI 在把集群级 TLS profile 下沉到组件 sidecar，说明安全默认值和集群合规策略会影响 AI 组件部署。我们的 operator 也要继承平台 TLS/Crypto policy，而不是组件各自配置。

## 上游生态整合动向

- [KServe PR #5727](https://github.com/kserve/kserve/pull/5727) — LLMInferenceService 增加 controlled deployment traffic splitting。
  - 启示:LLM 服务升级需要原生灰度/流量切分，而不是只靠上层网关手写规则。我们的模型服务发布能力应把版本、权重、回滚、SLO 指标绑定。
- [KServe PR #5721](https://github.com/kserve/kserve/pull/5721) — LLMInferenceService 增加 tiered KV-cache offloading。
  - 启示:KV cache 已经进入 KServe LLMISVC 的平台抽象层；我们对接 KServe 时要关注 cache tier 配置和节点/存储约束，而不是只暴露 vLLM 参数。
- [KServe PR #5723](https://github.com/kserve/kserve/pull/5723) — Envoy AI Gateway 升级到 v1.0.0、Envoy Gateway 升级到 v1.8.1。
  - 启示:OAI/ODH 与上游 KServe 的 gateway 方向正在趋同到 Envoy AI Gateway。MaaS 网关选型需要同步评估 Envoy AI Gateway 的 API 稳定性、鉴权扩展和观测指标。

## 值得跟进
- [ ] 读 ODH operator AI Gateway / xKS / MCP lifecycle module PR，确认 3.5 后续默认组件边界。
- [ ] 对比 ODH Dashboard LLM-D wizard 与我们推理部署向导，梳理 topology/config/cache/router/autoscaler 应暴露哪些字段。
- [ ] 跟踪 KServe LLMISVC traffic splitting 与 tiered KV-cache offloading，评估能否作为我们模型发布和缓存策略的上游基线。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://github.com/opendatahub-io/opendatahub-operator/pull/3718
- https://github.com/opendatahub-io/opendatahub-operator/pull/3717
- https://github.com/opendatahub-io/opendatahub-operator/pull/3715
- https://github.com/opendatahub-io/opendatahub-operator/pull/3713
- https://github.com/opendatahub-io/opendatahub-operator/pull/3712
- https://github.com/opendatahub-io/opendatahub-operator/pull/3709
- https://github.com/opendatahub-io/odh-dashboard/pull/8316
- https://github.com/opendatahub-io/odh-dashboard/pull/8312
- https://github.com/opendatahub-io/odh-dashboard/pull/8309
- https://github.com/opendatahub-io/kserve/releases/tag/v3.5.0%2Brhaiv.0
- https://github.com/opendatahub-io/kserve/pull/1679
- https://github.com/opendatahub-io/kserve/pull/1676
- https://github.com/opendatahub-io/kserve/pull/1672
- https://github.com/kserve/kserve/pull/5727
- https://github.com/kserve/kserve/pull/5721
- https://github.com/kserve/kserve/pull/5723
- 备注:本次 `.env` 中 `GITHUB_TOKEN` 返回 401 Bad credentials，GitHub 侧改用匿名 curl；未使用 `gh` CLI。
</details>
