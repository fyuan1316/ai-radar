# OpenShift AI 周报 2026-07-13

窗口:2026-07-06 -> 2026-07-13(7 天)

## 摘要(3 条以内)
- ODH operator 本周继续把平台组件迁入 module handler:Dashboard、KServe、MLflow、Feast、RhoaiMcp 都出现模块化信号，说明 OAI 正从“单体总控 operator”转向可独立生命周期管理的组件平台。
- MaaS/AIGateway 仍是主线:ModelsAsAService 被嵌入 AIGateway module，KServe module 新增 MaaS spec，AIGateway spec 继续补 `inferencePayloadProcessing`，Dashboard 也在补 model capability、subscription YAML 和 external models。
- 企业级默认值集中在 cluster TLS、disconnected readiness、webhook 容错和 platform version status，说明 OAI 3.5+ 的竞争点不只是模型服务功能，而是离线、合规、安全策略继承和升级可观测。

## 新功能 / 能力

- [ODH Operator PR #3733](https://github.com/opendatahub-io/opendatahub-operator/pull/3733) — Dashboard 迁移到 module-based architecture。
  - 启示:控制台也进入独立模块生命周期后，平台总控可以做组件级启停、升级、状态汇总。我们自己的 AI 平台 operator 不应把 UI、推理、流水线、registry 的状态迁移都压在一个 reconcile 里。
- [ODH Operator PR #3654](https://github.com/opendatahub-io/opendatahub-operator/pull/3654)、[#3694](https://github.com/opendatahub-io/opendatahub-operator/pull/3694)、[#3704](https://github.com/opendatahub-io/opendatahub-operator/pull/3704) — MLflow、FeastOperator、KServe module handler 继续迁入 module 路径。
  - 启示:OAI 正把实验追踪、Feature Store、模型服务都作为平台模块治理。我们做组件市场/能力中心时，要明确 module API、status、version、dependency 和 upgrade ownership。
- [ODH Operator PR #3753](https://github.com/opendatahub-io/opendatahub-operator/pull/3753) — RhoaiMcp 作为 managed operator component 集成。
  - 启示:MCP 已经从生态概念进入 OAI 发行版治理面。Agent/MCP server 的安装、权限、审计、网络出口和生命周期需要进入平台能力，而不是只做演示入口。
- [ODH Operator PR #3723](https://github.com/opendatahub-io/opendatahub-operator/pull/3723) 与 [#3712](https://github.com/opendatahub-io/opendatahub-operator/pull/3712) — ModelsAsAService 嵌入 AIGateway module，并为 AIGateway spec 增加 `inferencePayloadProcessing`。
  - 启示:MaaS 入口正在收敛到 AI Gateway 控制面，payload processing、认证、路由、订阅与审计应是同一个产品域。我们如果做 MaaS 网关，不能只包装 Gateway API Route。
- [ODH Dashboard PR #8352](https://github.com/opendatahub-io/odh-dashboard/pull/8352) 与 [#8386](https://github.com/opendatahub-io/odh-dashboard/pull/8386) — MaaS wizard 增加 model capabilities，subscription management detail 增加 YAML tab。
  - 启示:OAI 控制台在把 MaaS 的“能力声明”和“底层资源 YAML”同时暴露给用户。我们的模型目录也需要把 capability、计费/订阅状态、实际 K8s 对象之间的映射讲清楚。
- [ODH Dashboard PR #8247](https://github.com/opendatahub-io/odh-dashboard/pull/8247) — Workbench spawner 支持引用已有 Kubernetes Secrets 作为环境变量。
  - 启示:企业 notebook/workbench 最常见痛点是密钥注入和合规复用。我们应避免让用户复制 secret 值，改为引用现有 Secret 并做权限检查。

## 架构 / 依赖变化

- [ODH Operator PR #3786](https://github.com/opendatahub-io/opendatahub-operator/pull/3786) 与 [#3762](https://github.com/opendatahub-io/opendatahub-operator/pull/3762) — DAG orchestration 迁移到 platform controller，并增加 module status reporting。
  - 启示:组件安装顺序、依赖和状态汇总正在成为平台 controller 的一等职责。我们应把 DAG、precondition、status 聚合做成明确 API，而不是散落在各组件 Helm/Operator 里。
- [ODH Operator PR #3717](https://github.com/opendatahub-io/opendatahub-operator/pull/3717)、[ODH Dashboard PR #8437](https://github.com/opendatahub-io/odh-dashboard/pull/8437)、[ODH KServe PR #1716](https://github.com/opendatahub-io/kserve/pull/1716)、[DSP Operator PR #1063](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1063) — 多个组件接入 cluster TLS security profile。
  - 启示:OAI 在把 OpenShift 集群级 TLS/Crypto policy 传递到 AI 组件。我们的组件交付必须继承平台 TLS 策略，否则会在金融/政企环境被安全基线卡住。
- [ODH KServe PR #1723](https://github.com/opendatahub-io/kserve/pull/1723) — KServe module 从 ConfigMap 读取 platform version。
  - 启示:组件需要知道平台版本并上报兼容状态。我们升级时应有 platform/component version matrix，而不是只看镜像 tag。
- [ODH KServe PR #1708](https://github.com/opendatahub-io/kserve/pull/1708) 与 [#1694](https://github.com/opendatahub-io/kserve/pull/1694) — disconnected image references 通过 env vars 贯穿，OVMS auto-versioning image 可配置。
  - 启示:离线交付要覆盖每一个 runtime、sidecar、auto-versioning image 和 module operator 镜像。只替换主镜像会留下隐性联网点。

## 上游生态整合动向

- [ODH KServe PR #1703](https://github.com/opendatahub-io/kserve/pull/1703) — LLM-D dashboards 与 kserve-module operator 集成。
  - 启示:LLM-D 正进入 OAI 的标准 KServe module 视图。我们对接 LLM-D 时，应把 dashboard、operator、runtime image 和推理拓扑作为整体设计。
- [KServe PR #5798](https://github.com/kserve/kserve/pull/5798) — LLMInferenceService 增加 group routing machinery for traffic splitting。
  - 启示:LLM 服务灰度和版本流量切分正在下沉到 KServe LLMISVC。模型发布、回滚、SLO 对比应该跟 LLMISVC 状态绑定。
- [KServe PR #5033](https://github.com/kserve/kserve/pull/5033) 与 [#4965](https://github.com/kserve/kserve/pull/4965) — LocalModelCacheDeployment CRD 和 LocalModelNode agent event filtering 继续推进。
  - 启示:模型缓存不再只是 PVC/镜像层优化，而是有 CRD、agent、节点事件过滤的控制面。我们的模型缓存能力要显式管理容量、淘汰、命中率和节点亲和。
- [KServe PR #5642](https://github.com/kserve/kserve/pull/5642) — 增加 nvidia-dra LLMInferenceService examples。
  - 启示:KServe 已开始把 DRA 设备申请写入 LLMISVC 示例。后续 GPU/NPU DRA 会影响模型服务 API 设计，不应只停留在 `resources.limits` 时代。

## 值得跟进
- [ ] 梳理 ODH module handler/status/DAG 模型，评估我们 operator 是否需要拆出组件 lifecycle API。
- [ ] 跟踪 AIGateway + MaaS spec，明确 payload processing、鉴权、订阅、审计的边界。
- [ ] 对比 OAI cluster TLS/disconnected readiness 做法，补齐我们离线和合规 preflight。
- [ ] 试读 KServe LLMISVC traffic splitting、LocalModelCache、nvidia-dra samples，判断模型发布和缓存控制面可复用度。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://github.com/opendatahub-io/opendatahub-operator/pull/3654
- https://github.com/opendatahub-io/opendatahub-operator/pull/3733
- https://github.com/opendatahub-io/opendatahub-operator/pull/3753
- https://github.com/opendatahub-io/opendatahub-operator/pull/3694
- https://github.com/opendatahub-io/opendatahub-operator/pull/3712
- https://github.com/opendatahub-io/opendatahub-operator/pull/3704
- https://github.com/opendatahub-io/opendatahub-operator/pull/3723
- https://github.com/opendatahub-io/opendatahub-operator/pull/3786
- https://github.com/opendatahub-io/opendatahub-operator/pull/3762
- https://github.com/opendatahub-io/opendatahub-operator/pull/3717
- https://github.com/opendatahub-io/odh-dashboard/pull/8352
- https://github.com/opendatahub-io/odh-dashboard/pull/8386
- https://github.com/opendatahub-io/odh-dashboard/pull/8247
- https://github.com/opendatahub-io/odh-dashboard/pull/8437
- https://github.com/opendatahub-io/kserve/pull/1703
- https://github.com/opendatahub-io/kserve/pull/1723
- https://github.com/opendatahub-io/kserve/pull/1708
- https://github.com/opendatahub-io/kserve/pull/1694
- https://github.com/opendatahub-io/kserve/pull/1716
- https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1063
- https://github.com/kserve/kserve/pull/5798
- https://github.com/kserve/kserve/pull/5033
- https://github.com/kserve/kserve/pull/4965
- https://github.com/kserve/kserve/pull/5642
- 备注:本次 `.env` 中 `GITHUB_TOKEN` 对 GitHub API 返回 401，GitHub 侧按任务约定改用匿名 curl；未使用 `gh` CLI。
</details>
