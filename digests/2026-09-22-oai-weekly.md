# OpenShift AI 周报 2026-09-22

窗口:2026-09-15 -> 2026-09-22(7 天)

## 摘要(3 条以内)
- OAI 3.6 EA2 信号集中在三条线:平台组件继续 module 化，KServe/llm-d 观测与 Kueue 控制面进入发行物，Dashboard 把私有 Hugging Face 模型接入 Model Catalog/Model Deployment。
- 安全与企业默认值仍在加固:ODH Operator 拒绝空 strict TLS cipher profile，KServe 一度引入 workload TLS profile 后又回滚，说明 TLS policy 需要在平台兼容性和可控性之间谨慎推进。
- Dashboard 继续围绕 MaaS、AutoRAG、External Models、Kueue deployment tracking 补产品面，OAI 正把模型目录、外部模型、RAG pattern、队列/调度状态合到统一控制台。

## 新功能 / 能力

- [ODH Dashboard v3.6.0-ea2-odh](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.6.0-ea2-odh) — EA2 release note 明确新增 Private Hugging Face models in Model catalog and model deployments。
  - 启示:模型目录不再只是公共 catalog，开始承载私有模型源、凭据和部署入口。我们做模型目录时要把 registry secret、模型许可、runtime 兼容性和部署模板绑定成一个流程。
- [ODH Operator PR #4089](https://github.com/opendatahub-io/opendatahub-operator/pull/4089) — 实现 AIPipelines module handler，注册为 platform module runlevel 20，并将 `spec.components.aipipelines` 翻译到 module API。
  - 启示:OAI 继续把核心能力迁入 module 生命周期。我们的平台 operator 也应把 pipeline、serving、registry、dashboard 拆成可独立启停、独立状态汇总的组件，而不是一个总 reconcile。
- [ODH Dashboard PR #9840](https://github.com/opendatahub-io/odh-dashboard/pull/9840) — 增加 Kueue deployment tracking。
  - 启示:队列/批调度已经从后端基础设施进入 AI 平台可见层。用户需要在控制台看到队列启用状态、作业是否被 Kueue 管理、为什么 Pending。
- [ODH Dashboard PR #9769](https://github.com/opendatahub-io/odh-dashboard/pull/9769) — 更新 External Models CRUD 文案。
  - 启示:External Models 已经是 MaaS/AI Gateway 产品面的一部分。我们需要把外部模型的 endpoint、auth、配额、审计和失败诊断做成一等资源，而不是只让用户填 URL。
- [ODH Dashboard PR #9857](https://github.com/opendatahub-io/odh-dashboard/pull/9857) — 修复 AutoRAG pattern detail 中 Sample Q&A 页面在生产镜像的崩溃。
  - 启示:RAG pattern 进入控制台后，样例问答、索引状态、评估结果是用户验收路径。AutoRAG 不能只生成资源，还要把运行结果稳定展示出来。

## 架构 / 依赖变化

- [ODH KServe odh-v3.6-ea2](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.6-ea2) — release 包含 kserve-kueue controller Dockerfile、module platformVersion transition/webhook contract 测试、Prometheus metrics scraping NetworkPolicy。
  - 启示:KServe module 正在补齐平台版本感知、webhook 启用校验、Kueue 控制器镜像和用户命名空间监控权限。我们的模型服务组件也要把调度、观测、webhook readiness 做成 release gate。
- [ODH Operator PR #4115](https://github.com/opendatahub-io/opendatahub-operator/pull/4115) — strict TLS profile 转换时拒绝空或不可用 cipher list，避免回落到 Go 默认值。
  - 启示:安全 profile 的失败模式必须显式 fail closed。企业平台不要在“用户给了严格策略但解析为空”时静默降级。
- [ODH KServe PR #1969](https://github.com/opendatahub-io/kserve/pull/1969) 与 [#2038](https://github.com/opendatahub-io/kserve/pull/2038) — LLMISVC / InferenceService workload TLS profile 配置先合入后整体回滚。
  - 启示:OpenShift TLS security profile 下沉到 workload 是正确方向，但会触碰 runtime 兼容性、mesh/gateway、模板复杂度。我们推进 TLS 策略继承时要先做 runtime 矩阵和回滚开关。
- [ODH Dashboard PR #9764](https://github.com/opendatahub-io/odh-dashboard/pull/9764) — federation module images 强制使用 federated `DEPLOYMENT_MODE`，覆盖 model-registry、gen-ai、autorag、maas 等模块。
  - 启示:前端模块化不是构建细节，会影响 workspace/federation 运行时能否按模块加载。我们如果做前端能力市场，需要把 build mode、module manifest 和后端配置一起版本化。

## 上游生态整合动向

- [ODH KServe PR #2030](https://github.com/opendatahub-io/kserve/pull/2030) 与 [#2027](https://github.com/opendatahub-io/kserve/pull/2027) — llm-d dashboard 对齐 `llm_d_epp_*` 指标名，并增加 EPP scheduling latency panel。
  - 启示:LLM-D 的 EPP 调度开销已经进入 OAI/KServe 观测面。我们做推理路由时要暴露 router/EPP 自身延迟，否则用户只看到模型延迟，定位不到调度瓶颈。
- [ODH KServe PR #1992](https://github.com/opendatahub-io/kserve/pull/1992) — per-pod dashboard 查询按 namespace 分组。
  - 启示:多租户观测必须先按 namespace/project 隔离，否则同名 pod 或跨租户查询会让控制台指标失真。
- [ODH Model Registry v0.3.17](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.17) 与 [release PR #1889](https://github.com/opendatahub-io/model-registry/pull/1889) — 跟随 Kubeflow Model Registry v0.3.17 发布 Tekton pipelines。
  - 启示:OAI 的 registry 仍然贴近上游 Kubeflow，但通过 Tekton pipeline release 交付。我们需要明确 registry server、Python client、pipeline 组件的版本矩阵。

## 值得跟进
- [ ] 跟踪 OAI 3.6 EA2 到 GA 的 module handler 覆盖面，重点看 AIPipelines、KServe、Dashboard、Model Registry 的 status/API 是否稳定。
- [ ] 对比 OAI strict TLS fail-closed 与 KServe workload TLS rollback，定义我们自己的 TLS profile 下沉策略和 runtime 兼容矩阵。
- [ ] 试读 KServe llm-d EPP metrics panel，补齐我们推理路由的调度延迟、队列长度、后端饱和度指标。
- [ ] 把 Private Hugging Face model catalog、External Models、AutoRAG pattern result、Kueue tracking 映射成我们控制台的产品能力清单。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.6.0-ea2-odh
- https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.6-ea2
- https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.17
- https://github.com/opendatahub-io/opendatahub-operator/pull/4089
- https://github.com/opendatahub-io/opendatahub-operator/pull/4115
- https://github.com/opendatahub-io/opendatahub-operator/pull/4094
- https://github.com/opendatahub-io/odh-dashboard/pull/9840
- https://github.com/opendatahub-io/odh-dashboard/pull/9764
- https://github.com/opendatahub-io/odh-dashboard/pull/9769
- https://github.com/opendatahub-io/odh-dashboard/pull/9857
- https://github.com/opendatahub-io/kserve/pull/1969
- https://github.com/opendatahub-io/kserve/pull/2038
- https://github.com/opendatahub-io/kserve/pull/2030
- https://github.com/opendatahub-io/kserve/pull/2027
- https://github.com/opendatahub-io/kserve/pull/1992
- https://github.com/opendatahub-io/model-registry/pull/1889
- 备注:本机 `.env` 和 `/Volumes/macOS-2/Users/yuan/Dev/tools/envs/env.github` 中的 `GITHUB_TOKEN` 均返回 `Bad credentials`，本轮 GitHub 按匿名 API 抓取。
</details>
