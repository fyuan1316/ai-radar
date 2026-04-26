# OpenShift AI 周报 2026-04-26

窗口:2026-04-19 → 2026-04-26(过去 7 天)

抓取说明:本次运行环境中 `curl https://api.github.com/rate_limit` 返回 DNS 解析失败,未能按任务要求完成 GitHub API 原始 JSON 扫描;本 digest 使用 GitHub release 页面、Red Hat 官方文档和公开页面补充。结论可信度低于完整 API 扫描,需要下次在可解析 `api.github.com` 的环境里补一次 PR 级别核对。

## 摘要

- Red Hat OpenShift AI 3.4 文档已从 EA1 更新到 [3.4 Early Access 2](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index),这周最有价值的新信号是 **Kubeflow Trainer 的 JIT/周期 checkpoint + S3 checkpoint**。启示:OAI 把“训练作业被抢占后自动续跑”做成产品能力,我们自己的训练编排不能只停留在提交 TrainJob,必须把 checkpoint 策略、对象存储、恢复路径放进默认体验。
- ODH v3.4.0 release 组件清单确认 MaaS、Trainer、Model Registry、MLflow、Feast、KServe、llm-d scheduler、WVA、llm-d KV cache 等已经被收束到同一条产品线: [opendatahub-operator v3.4.0](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0)。启示:OAI 的 GenAI 平台不是单点推理服务,而是“模型目录 + 服务 + 调度 + 评估 + 实验追踪 + 特征”的组合,我们对标时需要按能力簇拆差距。
- Dashboard v3.4.0 的 Notable Changes 把 MaaS API keys、订阅模型、Prompt Management、Gen AI Playground、Ray Jobs、AutoML、Eval Hub、MCP catalog 都列进前台能力: [odh-dashboard v3.4.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0)。启示:企业用户感知的是一套工作流入口,不是底层 controller 名字;我们需要把“推理底座能力”包装成更完整的用户路径。

## 新功能 / 能力

- [RHOAI 3.4 EA2: Kubeflow Trainer 支持 JIT checkpoint 和 S3 checkpoint](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) — 文档说明 Trainer 会在抢占、驱逐、维护前保存训练状态,并可把 checkpoint 存在 PVC 或 S3 兼容对象存储。
  - 启示:这直接补齐 AI 集群里最贵的一类失败:长训练被节点维护/抢占打断。我们产品如果提供训练编排,应该默认暴露“checkpoint 存储位置、保存周期、恢复状态”三件事,而不是让用户在训练代码里自己兜底。
- [RHOAI 3.4 EA2: model catalog 支持 IBM Power(ppc64le)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) — 官方列出 ppc64le 架构可发现和部署的 Granite 模型镜像。
  - 启示:OAI 在把“模型目录”扩展成多架构交付入口。我们如果面向国产/异构 CPU 和加速卡,模型目录也应记录架构、runtime、驱动栈和镜像兼容性,否则部署失败会变成售后问题。
- [RHOAI 3.4: Feature Store 与项目、Workbench、RBAC 集成](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) — Feature Store 进入 OpenShift AI 的项目/权限模型。
  - 启示:OAI 不是只做 LLM,还在补传统 MLOps 的数据特征层。我们做 AI 基础设施时至少要考虑 MLflow/Feature Store/Model Registry 的权限边界是否统一到 namespace/project。
- [RHOAI 3.4: LLM Compressor Developer Preview](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) — 新增 workbench image 和 data science pipelines runtime,用于压缩优化 LLM 以便部署到 vLLM。
  - 启示:这是“模型上线前优化”产品化。我们可以借鉴成一条标准流水线:模型导入 → 压缩/量化 → 评估 → 注册 → 部署,不要让压缩工具散落在 Notebook 里。
- [odh-dashboard v3.4.0: MCP catalog and deployments 是 Dev Preview](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0) — Dashboard 发行说明已经把 MCP catalog/deployments 列为前台功能。
  - 启示:MCP 正在从调试/运维工具转成平台能力入口。我们可以先做一个“集群诊断 MCP 工具集”,覆盖组件状态、事件、依赖、日志摘要,比直接做复杂 agent 更容易落地。

## 架构 / 依赖变化

- [opendatahub-operator v3.4.0 组件清单](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0) 显示 OAI 已把 `llm-d-inference-scheduler`、`workload-variant-autoscaler`、`llm-d-kv-cache` 都作为 ODH v3.4 组件发布。
  - 启示:OAI 的 LLM serving 方向已经从“只部署 vLLM/KServe”转向“调度器 + autoscaler + KV cache”三件套。我们做 KServe 兼容时,不能只看 InferenceService CRD,还要评估其周边调度扩展。
- [opendatahub-operator v3.4.0 变更列表](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0) 继续出现 xKS/cloudmanager/Gateway API/LWS/WVA 权限和依赖项。
  - 启示:xKS/cloudmanager 仍是“跨 Kubernetes / 托管面”的强信号。我们自己的 operator 也应该保持可被上层管理面调用:清晰的 CRD、幂等状态、可观测 status、可控 RBAC 命名。
- [opendatahub-io/kserve odh-v3.4](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.4) 包含 llmisvc 的 WVA autoscaling config、Intel Gaudi config、imagePullSecrets 继承、distro build tags、customizeManagerOptions hook 等。
  - 启示:ODH fork 的重点是“上游 KServe + 发行版适配层”。我们如果维护 fork,也应把发行版差异隔离在 build tags/overlay/hook,避免污染上游接口。

## 上游生态整合动向

- [RHOAI 3.4 文档](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) 继续明确 Kubeflow Trainer v2、Kueue 集成、TrustyAI-Llama Stack guardrails、MLflow、Feature Store。
  - 启示:OAI 的统一路径是“项目 namespace + RBAC + Kubeflow/Kueue/KServe/Llama Stack/MLflow”。我们若要对标,需要画出自己的项目域模型,明确每个组件如何共享用户、权限、审计和网络边界。
- [odh-dashboard v3.4.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0) 把 Ray jobs 接入 Training dashboard。
  - 启示:Ray 不只是底层 runtime,而是训练/批处理工作流的一等入口。我们如果支持 Ray,不要只安装 KubeRay operator,还需要 UI、日志、指标和失败恢复体验。

## 值得跟进

- [ ] 下次在能访问 `api.github.com` 的环境里补扫 2026-04-19 → 2026-04-26 的 ODH PR,重点过滤 `cloudmanager`、`xKS`、`MCP`、`Trainer`、`MaaS`、`WVA`。
- [ ] 精读 [RHOAI 3.4 EA2 release notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index),把 EA1→EA2 的新增能力单独整理成产品差距表。
- [ ] 评估 Kubeflow Trainer checkpoint 能力是否可复用到我们训练任务:对象存储配置、抢占前 hook、恢复状态展示。
- [ ] 设计“模型上线前优化流水线”:LLM Compressor / 量化 / eval / registry / KServe 部署一条链路。

## 原始材料

- [Red Hat OpenShift AI Self-Managed 3.4 Release Notes EA2](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index)
- [opendatahub-io/opendatahub-operator v3.4.0](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0)
- [opendatahub-io/odh-dashboard v3.4.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0)
- [opendatahub-io/kserve odh-v3.4](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.4)
- 未完成:GitHub API curl 原始扫描失败,错误为 `Could not resolve host: api.github.com`。
