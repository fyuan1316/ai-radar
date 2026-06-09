# OpenShift AI 周报 2026-06-09

> 扫描窗口:2026-06-02 ~ 2026-06-09(过去 7 天),数据源为 7 个 opendatahub-io 上游仓库的 main 分支提交。本周无新 release(仍处 3.5-EA 周期,上一版 v3.5.0-ea.1 / odh-v3.5-EA1 发布于 5 月初)。Red Hat 官方 release notes 页本周对自动抓取返回 403,无可引用更新。

## 摘要(3 条以内)
- **企业级 RBAC 与 MaaS 在 dashboard 同时收口**:细粒度自定义角色(Role 列表/详情/YAML + 创建表单)成形,Model-as-a-Service 的 "Publish as MaaS" 去掉 Tech Preview 标签、API Keys 页接入订阅管理——多租户 + 模型对外售卖这条企业线在 3.5 明显加速。
- **Gen-AI / Agent 方向密集投入**:Playground 多模态(图片/文档上传 + thinking panel)、AutoRAG 支持 PGVector 向量库并把嵌入式 Playground 接进 AutoRAG,EvalHub 评估能力被包装成 MCP Server 对外暴露。
- **架构上两条解耦主线**:operator 引入独立 module controller(为未来摆脱 DSC/DSCI 铺路),KServe 管理逻辑下沉成 "kserve-module" 并补 E2E/动态 watch;dashboard 持续 BFF 化(7 个 BFF 模块 manifests + Core BFF proxy 层)。

## 新功能 / 能力

- [自定义角色全套 UI:Role 列表+详情+YAML(#7793)](https://github.com/opendatahub-io/odh-dashboard/pull/7793) 与 [创建自定义角色表单(#7751)](https://github.com/opendatahub-io/odh-dashboard/pull/7751) — 在 Project Details 下提供可搜索的角色表、详情与 YAML 展示,并支持创建自定义角色(role configuration section)。配套 [Settings 每卡片 RBAC 的 Cypress mock 测试(#7856)](https://github.com/opendatahub-io/odh-dashboard/pull/7856) 与 [集群指标访问改用 RBAC check(#7848)](https://github.com/opendatahub-io/odh-dashboard/pull/7848)。
  - 启示:OAI 正把 RBAC 从"几个预置 ClusterRole"推进到"项目级可视化的自定义角色管理",这是对标我们多租户授权体验的直接参照。重点看它的角色模型是纯 K8s RBAC 投影还是引入了自有抽象——若是前者,我们的权限页可以同样以 namespace-scoped Role/RoleBinding 为底座做可视化,避免再造一套授权语义。
- [Publish as MaaS 去掉 Tech Preview 标签(#7784)](https://github.com/opendatahub-io/odh-dashboard/pull/7784)、[API Keys 页加订阅过滤与关联(#7680)](https://github.com/opendatahub-io/odh-dashboard/pull/7680),以及 My Subscriptions 详情页(commit [c7bebb8](https://github.com/opendatahub-io/odh-dashboard/commit/c7bebb8))。
  - 启示:MaaS(把已部署模型作为带 API Key/订阅的服务对外提供)在 3.5 从预览转正,形成 "发布→订阅→API Key→用量" 的闭环。这是 OAI 区别于纯推理平台的商业化能力,我们若要做模型对外售卖,这套订阅/密钥模型值得逐页对照。
- [Playground 多模态聊天(#7621)](https://github.com/opendatahub-io/odh-dashboard/pull/7621) — 图片/文档上传(客户端校验 JPG/PNG、10MB)、内联渲染、thinking 面板、文档 chips,走 responses API。配套 [BFF 文件上传端点与多模态 API 契约(#7613)](https://github.com/opendatahub-io/odh-dashboard/pull/7613)。
  - 启示:OAI 的内置 Playground 正从"文本对话"升级为完整多模态 + 推理过程可视化,且 thinking panel 说明它在对齐 reasoning 模型的输出形态。我们的模型试用界面若还停在纯文本,差距会被拉开。
- [AutoRAG 支持 PGVector 向量库(#7732)](https://github.com/opendatahub-io/odh-dashboard/pull/7732) 与 [嵌入式 Playground 接入 AutoRAG(#7633)](https://github.com/opendatahub-io/odh-dashboard/pull/7633) — AutoRAG configure 现可选 `remote::pgvector`(此前仅 Milvus)。
  - 启示:OAI 的 RAG 路线在补齐"非 Milvus 用户也能用"的向量后端,并把 Playground 嵌进 AutoRAG 形成"配置即试用"。PGVector 对已用 Postgres 的企业是低门槛入口,我们做 RAG 时向量后端的可插拔性应作为硬需求。
- [EvalHub MCP Server(上游 trustyai #734)](https://github.com/trustyai-explainability/trustyai-service-operator/pull/734) — trustyai-service-operator 本周大量提交围绕把 EvalHub(模型评估)包成 MCP server:reconcile、HTTPS reencrypt route、kube-rbac-proxy 鉴权映射(opendatahub-io 侧同步 commit [d93cbbd](https://github.com/opendatahub-io/trustyai-service-operator/commit/d93cbbd)、[a4dde1a](https://github.com/opendatahub-io/trustyai-service-operator/commit/a4dde1a))。
  - 启示:模型评估能力以 MCP 协议对外,意味着 OAI 把"评估"做成可被 Agent/外部工具直接调用的标准化服务,而非埋在 UI 里。MCP 正在成为 OAI 内部能力的统一出口(评估、未来可能还有目录/注册),我们应评估自家能力是否也该以 MCP server 形态暴露。
- [部署向导直接创建 NIMService CR(#7752)](https://github.com/opendatahub-io/odh-dashboard/pull/7752)、[NIM 部署加 PVC 缓存存储字段(#7705)](https://github.com/opendatahub-io/odh-dashboard/pull/7705)、[选 NIM 位置时强制模型类型为 NVIDIA NIM(#7720)](https://github.com/opendatahub-io/odh-dashboard/pull/7720)。
  - 启示:NIM 路径从"向导手动拼 ServingRuntime+InferenceService"改为"创建 `apps.nvidia.com/v1alpha1` NIMService、由 NIM operator 下游展开",PVC 缓存解决 NIM 镜像/权重冷启动慢。OAI 在把 NVIDIA 推理栈做成一等公民,我们若也接 NIM,这种"交给 operator 展开"的解耦方式可借鉴。
- Model Catalog 持续建设(model-registry):[catalog-gen 代码生成器(commit e8b01d8)](https://github.com/opendatahub-io/model-registry/commit/e8b01d8)、[Model Catalog 元数据 csv-exporter(commit 9ef9714)](https://github.com/opendatahub-io/model-registry/commit/9ef9714)、[MetricsType 加 security-metrics(commit 8dee97e)](https://github.com/opendatahub-io/model-registry/commit/8dee97e)、[cold-start/vRAM 数据格式对齐后端(commit 81b2b7a)](https://github.com/opendatahub-io/model-registry/commit/81b2b7a)。
  - 启示:Model Registry 正在长出"Model Catalog"这层——带安全指标、冷启动/显存画像、可导出 CSV 的模型选型门户。这是模型生命周期里"选型/治理"环节,比单纯的版本注册更靠近企业采购决策,值得跟进它的元数据模型。

## 架构 / 依赖变化

- [operator 引入独立 module controller(#3459)](https://github.com/opendatahub-io/opendatahub-operator/pull/3459) — 把 module 生命周期从 DSC reconcile 循环中拆出,独立 action pipeline;PR 明说这是"未来 DSC/DSCI 被弃用时只换 primary resource、handler 逻辑不动"的铺垫。OAI 的核心编排 CRD 正在为下一代解耦做地基,值得密切关注 DSC/DSCI 是否会被替换。
- [KServe 管理下沉为 kserve-module](https://github.com/opendatahub-io/kserve/pull/1568):本周补 E2E 生命周期测试 + cert-manager RBAC(#1568)、[动态 watch 集成测试(#1549)](https://github.com/opendatahub-io/kserve/pull/1549)、[集中化 OpenShift operator subscription 配置(#1558)](https://github.com/opendatahub-io/kserve/pull/1558),并 [解耦 ODH 专有 S3 endpoint 处理逻辑(#1551)](https://github.com/opendatahub-io/kserve/pull/1551)。说明 KServe 在 OAI 里正从 fork 补丁演进为有独立测试/订阅治理的"模块"。
- [Kueue frameworkMapping 加 SparkApplication(#3587)](https://github.com/opendatahub-io/opendatahub-operator/pull/3587) — 让 operator 生成的 Kueue CR 把 `sparkoperator.k8s.io/sparkapplication` 列为受管工作负载,打通 Kueue + Kubeflow Spark Operator(Suspend/Resume 准入)。批处理/数据工作负载纳入统一队列调度。
- dashboard 持续 BFF 化:[7 个 dashboard BFF 模块的 manifests(#7785)](https://github.com/opendatahub-io/odh-dashboard/pull/7785)、[Core BFF proxy 层(K8s API + WebSocket 透传)(#7733)](https://github.com/opendatahub-io/odh-dashboard/pull/7733)、[gen-ai BFF 加 body size limit 与结构化 413(#7740)](https://github.com/opendatahub-io/odh-dashboard/pull/7740)。前端正从"直连 K8s"转向"每能力一个 BFF + 联邦模块"的微前端架构。
- [odh-batch-gateway-operator 上架 manifests(commit bb1f76f)](https://github.com/opendatahub-io/opendatahub-operator/commit/bb1f76f) — 新增批处理网关 operator,与上面 Spark/Kueue 的批量调度方向呼应。
- notebooks 依赖收敛:统一到 Python 3.12.*(#3810)、TrustyAI 镜像保留 transformers 5.x(commit [871b1c0](https://github.com/opendatahub-io/notebooks/commit/871b1c0))。

## 上游生态整合动向

- **KServe**:除上述模块化,还为 NIM 增加 `nim.opendatahub.io` 的 account-editor/viewer RBAC([#1555](https://github.com/opendatahub-io/kserve/pull/1555)),并在 operator 侧"默认 NIM 配置防止 KServe CR 漂移"([#3618](https://github.com/opendatahub-io/opendatahub-operator/pull/3618))、允许可选 LWS operator(LeaderWorkerSet,面向大模型多节点推理,[#3612](https://github.com/opendatahub-io/opendatahub-operator/pull/3612))。
- **Kubeflow**:model-registry 本周多次从 kubeflow/main 同步(merge #1758/#1756/#1751),dashboard 也同步 model-registry 上游(#7899/#7794)。OAI 的模型注册/目录基本与 Kubeflow 上游保持紧耦合。
- **Kueue + Spark**:见上,SparkApplication 纳入 Kueue 受管;trustyai 还 [把 Kueue GPU 准入失败分类成用户可读消息(上游 #732)](https://github.com/trustyai-explainability/trustyai-service-operator/pull/732),提升 GPU 配额不足时的可观测性。
- **vLLM / Ray**:本周 7 仓无直接 vLLM/Ray 相关实质提交。
- **MLflow**:dashboard 接入 MLflow——Runs 页加 MLflow 链接(commit [46980ae](https://github.com/opendatahub-io/odh-dashboard/commit/46980ae))、Experiments 页加 "MLflow 未配置" 空状态(commit [ff6046e](https://github.com/opendatahub-io/odh-dashboard/commit/ff6046e))。实验跟踪在向 MLflow 靠拢。

## 值得跟进
- [ ] 读 [#7793](https://github.com/opendatahub-io/odh-dashboard/pull/7793) + [#7751](https://github.com/opendatahub-io/odh-dashboard/pull/7751),确认 OAI 自定义角色到底是 K8s RBAC 的可视化投影还是自有授权抽象——直接影响我们权限页的底座选型。
- [ ] 评估 EvalHub 的 MCP Server 形态([trustyai #734](https://github.com/trustyai-explainability/trustyai-service-operator/pull/734)):我们的评估/目录类能力是否也应以 MCP server 暴露给 Agent 与外部工具。
- [ ] 对照 MaaS 闭环(订阅 [#7680](https://github.com/opendatahub-io/odh-dashboard/pull/7680) + Publish 转正 [#7784](https://github.com/opendatahub-io/odh-dashboard/pull/7784)),盘点我们"模型对外售卖"是否有等价的 API Key/订阅/用量链路。
- [ ] 跟踪 operator module controller([#3459](https://github.com/opendatahub-io/opendatahub-operator/pull/3459))后续:DSC/DSCI 是否会被弃用,关系到我们若复用 ODH operator 的升级路径。
- [ ] 试 AutoRAG PGVector 路径([#7732](https://github.com/opendatahub-io/odh-dashboard/pull/7732)),验证 Postgres 作为向量后端的体验,作为我们 RAG 向量层可插拔的参考实现。

## 原始材料

<details>
<summary>本次扫描清单(7 repo,过去 7 天 main 分支)</summary>

- **opendatahub-operator**(9 commits,无新 release):#3459 modular handler、#3587 SparkApplication→Kueue、#3618 默认 NIM 配置、#3612 可选 LWS operator、#3614 KServe SCC RBAC、#3596 odh-batch-gateway-operator manifests、#3613/#3606 MCP Server 故障场景测试、#3628 go.mod 全版本号。
- **odh-dashboard**(71 commits,无新 release):自定义角色 #7793/#7751/#7793,RBAC #7856/#7848;MaaS #7784/#7680/#7628;Gen-AI 多模态 #7621/#7613,Playground 错误透出 #7152/#7631;AutoRAG #7732/#7633/#7736;NIM #7752/#7705/#7720;Feature Store #7895/#7844/#7721;BFF 化 #7785/#7733/#7740/#7750;MLflow #6850/#7602;dashboard-operator #7745;模型同步 #7899/#7794。
- **kserve**(7 commits,无新 release):#1568 E2E+cert-manager RBAC、#1551 解耦 ODH S3 endpoint、#1562 E2E 集群脚本、#1558 集中化 subscription、#1549 动态 watch 测试、#1555 nim.opendatahub.io RBAC、#1554 _odh.go 命名规范。
- **notebooks**(19 commits,无新 release):#3810 统一 Python 3.12、transformers 5.x 固定、jupyter-resource-usage / odh-elyra 冲突修复、CVE tracker 脚本、CI artifact 上传、若干 RHAIENG xfail/EVR 清理。
- **data-science-pipelines-operator**(0 commits):本周无 main 分支提交;最新 release 仍为 2025-11 的 v2.18.0。
- **model-registry**(34 commits,无新 release):catalog-gen 代码生成器、Model Catalog csv-exporter(#2784)、security-metrics、cold-start/vRAM 格式对齐、health state 追踪(#2780)、hardware_tag labels(#2758)、移除 tool calling 临时 flag(#2761)、多次从 kubeflow 同步及大量 deps bump。
- **trustyai-service-operator**(30 commits,无新 release):EvalHub MCP Server 系列(reconcile / HTTPS reencrypt route / kube-rbac-proxy 鉴权,上游 #734、#745/#746/#748/#749/#750),Kueue GPU 准入失败分类(上游 #732),SAR 配置修复。注:该仓与 model-registry 为上游(trustyai-explainability、kubeflow)的下游镜像,提交内 `#xxx` 多指向上游 PR 号。

</details>
