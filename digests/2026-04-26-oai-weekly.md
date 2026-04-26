# OpenShift AI 周报 2026-04-26

窗口:2026-04-19 → 2026-04-26

## 摘要

- **OAI 3.4 进入 EA2 叙事,训练恢复成为新增重点**:Red Hat OpenShift AI 3.4 release notes 已更新到 [Early Access 2](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index),Kubeflow Trainer 增加 JIT checkpoint、周期 checkpoint 和 S3 checkpoint。启示:训练编排的竞争点从“能发起多机任务”升级到“抢占/维护/驱逐前能保存并恢复状态”。
- **ODH 本周主线是 3.4 稳定化 + 3.5 铺垫**:`opendatahub-operator` 本周有 15 个 main commits,包括 JobSet CRD condition、Spark ScheduledSparkApplication E2E、leader election 初始化、vLLM image 命名从 RHAIIS 改为 RHAII: [opendatahub-operator commits](https://github.com/opendatahub-io/opendatahub-operator/commits/main/)。启示:OAI 在把 AI workload 依赖(JobSet/Spark/vLLM)收进 operator 的健康面和发行面。
- **Dashboard 继续补 MLOps 工作流细节**:`odh-dashboard` 本周有 30 个 main commits,包括 MLflow experiments/prompts 测试、shared/block storage 百分比修复、MCP deployment auth 的 SAR-only client、model registry custom properties retention test: [odh-dashboard commits](https://github.com/opendatahub-io/odh-dashboard/commits/main/)。启示:OAI 正在把 Registry/MLflow/MCP 这些“平台服务”做成可验收的 UI 工作流,不是只接 API。

## 新功能 / 能力

- [RHOAI 3.4 EA2: Kubeflow Trainer checkpoint](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) — Trainer 支持 JIT checkpoint、周期 checkpoint 和 S3 兼容对象存储 checkpoint。
  - 启示:我们训练产品也应把 checkpoint 策略做成模板字段:保存时机、存储位置、恢复状态、异常后的重试策略。
- [ODH Operator: JobSet CRD check surfaced into JSO conditions](https://github.com/opendatahub-io/opendatahub-operator/commit/bb965877690eb29de489630ae892a11e365092bc) — JobSet CRD 检查被拆成单独 action,能把状态暴露到 JobSet Operator conditions。
  - 启示:AI workload 依赖组件的“缺 CRD/版本不对”要进入产品健康面,不要等用户提交训练/推理任务时才报错。
- [ODH Operator: ScheduledSparkApplication E2E](https://github.com/opendatahub-io/opendatahub-operator/commit/038549e88e3bdbedb3c07ad36ab5f9a27c71e937) — Spark Operator 覆盖 ScheduledSparkApplication E2E。
  - 启示:OAI 继续把批处理/数据处理能力纳入 AI 平台验收范围。我们如果面向企业 MLOps,Ray/Spark/Argo 这类非推理 workload 也需要纳入平台 SLO。
- [ODH Dashboard: MCP deployment auth SAR-only client](https://github.com/opendatahub-io/odh-dashboard/commit/07c97858c0a0245c9a2ef47c9e673d9395f1aba7) — Model Registry/MCP deployment auth 中 in-cluster K8s client 被收敛到 SAR-only interface。
  - 启示:MCP 进入平台后,权限边界会很快变成核心问题。我们的诊断/agent 工具也应默认最小权限,用 SAR/SubjectAccessReview 做授权判断。

## 架构 / 依赖变化

- [opendatahub-operator v3.4.0](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0) 组件清单已包含 KServe、llm-d scheduler、llm-d KV cache、WVA、Model Registry、MLflow、Feast、Kueue、Trainer、Ray 等。
  - 启示:OAI 的 3.x 架构是“模型平台 + 推理调度 + 批训练 + 实验/特征/注册中心”的组合包。我们对标时不能只盯 KServe,要按完整产品链路拆差距。
- [opendatahub-io/kserve 本周同步 upstream master](https://github.com/opendatahub-io/kserve/commit/56fa4f85d7a54ec4ec0ee6957a676dea7bfe54b5),并修 OpenShift SCC 下 E2E 的 `runAsUser` 问题: [commit](https://github.com/opendatahub-io/kserve/commit/745375ef852071da4298ef88a206f17dcac867d1)。
  - 启示:ODH KServe fork 的维护策略仍是“紧跟上游 + OpenShift 适配”。我们维护 fork 时也应把发行版差异限制在 overlay/SCC/build tag 层。
- [model-registry 本周继续同步 Kubeflow main](https://github.com/opendatahub-io/model-registry/commit/15661b34e1a6bef25267fe9a6619131c01335550),并修 custom property 类型切换时 stale columns 清理: [commit](https://github.com/opendatahub-io/model-registry/commit/aebe8f8632f103865c9ecbbad717c0c8c5ea6204)。
  - 启示:模型元数据 schema 演化会影响 UI、API、数据库迁移。我们的 Registry 需要把字段类型变更、属性保留、审计迁移作为产品级能力。

## 上游生态整合动向

- [odh-dashboard v3.4.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0) 继续把 MaaS、Prompt Management、Gen AI Playground、Ray Jobs、AutoML、Eval Hub、MCP catalog 放到前台。
  - 启示:企业用户看到的是端到端工作流入口,不是底层 CRD。我们的推理底座要有“模型导入、评估、部署、调试、治理”的用户路径。
- [notebooks 本周更新 LLM Compressor/PyTorch/TensorFlow ROCm 相关测试和 manifests](https://github.com/opendatahub-io/notebooks/commits/main/)。
  - 启示:OAI 把模型压缩/工作台镜像当成上线前优化链路的一部分。我们可以设计“压缩/量化 → 评估 → 注册 → 部署”的内置流水线。

## 值得跟进

- [ ] 把 [RHOAI 3.4 EA2 checkpoint](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) 拆成训练产品需求:checkpoint 策略、对象存储、恢复状态、抢占场景。
- [ ] 跟 [JobSet condition 暴露](https://github.com/opendatahub-io/opendatahub-operator/commit/bb965877690eb29de489630ae892a11e365092bc),确认 OAI 怎么把依赖组件健康状态投射到 DataScienceCluster。
- [ ] 精读 Dashboard MCP auth 相关变更,评估我们诊断工具的最小权限模型。

## 原始材料

- [RHOAI 3.4 Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index)
- [opendatahub-operator v3.4.0](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0)
- [odh-dashboard v3.4.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0)
- [opendatahub-io/opendatahub-operator commits](https://github.com/opendatahub-io/opendatahub-operator/commits/main/)
- [opendatahub-io/odh-dashboard commits](https://github.com/opendatahub-io/odh-dashboard/commits/main/)
- [opendatahub-io/kserve commits](https://github.com/opendatahub-io/kserve/commits/main/)
