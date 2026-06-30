# OpenShift AI 周报 2026-06-30

扫描窗口:2026-06-23 ~ 2026-06-30(过去 7 天 main 分支 commit + release)。
本周活跃度:dashboard 71 / notebooks 69 / model-registry 27 / kserve 14 / operator 13 / trustyai 4 / dsp-operator 3 commit。

## 摘要(3 条以内)

- **OAI 正从"模型服务平台"转向"Agent 平台"**:主 operator 一周内把三个新模块——`ai-gateway`、`agent-ops`、`mcp-lifecycle-module-operator`——编进 operator manifests;dashboard 侧 gen-ai/agent-ops 提交占了一半以上(agent configuration、MCP 自动连接、ASR、MaaS、AutoRAG/AutoML)。这是本周最强的方向性信号。
- **MCP 成为跨组件一等公民**:operator 装 `mcp-lifecycle-module-operator`([#3713](https://github.com/opendatahub-io/opendatahub-operator/pull/3713)),model-registry 加 MCP source preview endpoint([#2885](https://github.com/opendatahub-io/model-registry/pull/2885)),dashboard agent 加载时自动连接 MCP server([#8287](https://github.com/opendatahub-io/odh-dashboard/pull/8287))。MCP 在 OAI 里已从"实验"落到"平台基础设施"。
- **llm-d / LLMInferenceService 继续填坑做产品化**:kserve fork 新增 Route 发现(裸机/断网环境外部端点)、LLMInferenceServiceConfig RBAC、ModelCache 协调、fast-channel 加速器 overlay;dashboard 落地 llm-d topology/routing 数据层。kserve 同时出了 `v3.5.0+rhaiv.0` storage 标签(06-23)。

## 新功能 / 能力

- [operator: add ai-gateway module](https://github.com/opendatahub-io/opendatahub-operator/pull/3625) — 把 ai-gateway 镜像 + 4 个 batch-gateway 镜像(initContainer + manager)以纯 manifests 形式编进 operator;新增"模型名与 deployment 名不一致"的 module env injection 支持。注:下游 RHDS 还没完全配好,暂不跑 RHOAI e2e。
  - 启示:OAI 在 KServe/llm-d 之上又叠了一层"AI Gateway"做统一入口(批量推理 + 路由)。我们若仍只在 Gateway API / Envoy 层做裸编排,需要评估是否要提供同级的"AI 网关"产品语义(模型名路由、批量端点),否则在"开箱即用的 LLM 入口"上会落后。
- [operator: add agent-ops module image to dashboard imagesMap](https://github.com/opendatahub-io/opendatahub-operator/pull/3684) + [dashboard: agentOps operator module](https://github.com/opendatahub-io/odh-dashboard/pull/8241) — agent-ops 作为独立 dashboard 模块接入,managementState 默认 Removed,带 Owns() watch 和 webhook 模板;BFF 侧新增 `POST /agents/deploy`([#8173](https://github.com/opendatahub-io/odh-dashboard/pull/8173))和 agent 部署列表表格([#8211](https://github.com/opendatahub-io/odh-dashboard/pull/8211))。
  - 启示:agent 的"部署 + 运维(ops)"被当成一个独立可装卸模块,而不是塞进现有 serving。我们做 agent 能力时应同样模块化(可选安装、独立 RBAC/webhook),并尽早定义 agent 部署的 CRD/BFF 边界。
- [dashboard: agent configuration 体系化](https://github.com/opendatahub-io/odh-dashboard/pull/8266) — "Agent profile"统一改名为"Agent configuration",dev flag 迁到 `agentConfigManagement` CRD 字段([#8269](https://github.com/opendatahub-io/odh-dashboard/pull/8269)),新增 config guard、加载/预览模式、ASR 模型支持([#8261](https://github.com/opendatahub-io/odh-dashboard/pull/8261))、与 agent 同时禁用 compare mode。
  - 启示:agent 配置正在从"实验性开关"沉淀为"声明式 CRD"。这是抄作业的好窗口:可直接参考其 CRD 字段设计(agentConfigManagement)来定义我们自己的 agent 配置模型,少走弯路。
- [model-registry: catalog 增强](https://github.com/opendatahub-io/model-registry/pull/2879) — CatalogModel 加 `artifactCounts`([#2879](https://github.com/opendatahub-io/model-registry/pull/2879)),UI 展示最小 vRAM / 容器大小等部署提示([#2867](https://github.com/opendatahub-io/model-registry/pull/2867)),OpenAPI spec 补 security artifacts endpoint([#2891](https://github.com/opendatahub-io/model-registry/pull/2891))。
  - 启示:模型注册中心正往"选型即知道部署成本(vRAM/容器规格)"演进,把硬件需求前置到 catalog。我们的模型目录如果只有元数据、没有部署资源画像,选型体验会明显逊色。
- [dashboard: Kueue 工作负载状态细化](https://github.com/opendatahub-io/odh-dashboard/pull/8167) — 区分 Evicted 与 Requeued 状态,新增"Kueue enabled project"横幅([#8181](https://github.com/opendatahub-io/odh-dashboard/pull/8181))和 LocalQueue 校验下拉提示([#8224](https://github.com/opendatahub-io/odh-dashboard/pull/8224))。
  - 启示:Kueue 在 OAI 里已是默认的批/训练排队层,且开始打磨"用户能看懂排队状态"的可观测体验。我们的 GPU 排队若用 Kueue,这些状态映射(Evicted/Requeued)值得直接对齐。

## 架构 / 依赖变化

- [operator: DAG for upgrade & provision ordering](https://github.com/opendatahub-io/opendatahub-operator/pull/3634) — 升级与组件 provision 顺序改成 DAG 依赖编排。模块越来越多(gateway/agent-ops/mcp/mlflow),顺序依赖管理被正式抽象出来。
- [operator: 默认启用 MLflow operator](https://github.com/opendatahub-io/opendatahub-operator/pull/3623) + [dashboard: 全局 MLflow namespace 管理 CRD + API](https://github.com/opendatahub-io/odh-dashboard/pull/7866) — MLflow 进入默认 DSC,实验跟踪正式成为开箱栈的一部分(此前 DSP 是唯一流水线/跟踪路径)。
- [operator: 对接集群 TLS security profile](https://github.com/opendatahub-io/opendatahub-operator/pull/3653) + [gateway NetworkPolicy 增加 OCP 4.22 egress](https://github.com/opendatahub-io/opendatahub-operator/pull/3682) — 企业级安全合规(统一 TLS profile、4.22 网络策略适配)持续补齐。
- [dashboard/operator: Go 升级到 1.26 并加固 Dockerfile](https://github.com/opendatahub-io/odh-dashboard/pull/8239);notebooks 把全部 GHA runner 从 ubuntu-24.04 迁到 ubuntu-26.04(系列 #3872/#3919),并为 3.5 GA 保留 2025.2 runtime 镜像。
- [dashboard: ui-core 公共包抽取](https://github.com/opendatahub-io/odh-dashboard/pull/8183)(共享表格组件、constants/utilities、plugin-core area-gating)——dashboard 的微前端/模块化重构在加速,为前述 gen-ai/agent-ops 等可装卸模块铺底座。

## 上游生态整合动向

- **KServe / llm-d**:fork 修正 llm-d 的 `RELATED_IMAGE_*` 环境变量名([#1672](https://github.com/opendatahub-io/kserve/pull/1672)),为 fast-1/fast-2 加速器加 LLMInferenceServiceConfig 的 kustomize overlay([#1613](https://github.com/opendatahub-io/kserve/pull/1613)),并在镜像与 stable 一致时过滤 fast-channel 资源([#1612](https://github.com/opendatahub-io/kserve/pull/1612))。[LLMInferenceService 发现 OpenShift Route](https://github.com/opendatahub-io/kserve/pull/1564) 解决裸机/断网集群拿不到外部 URL 的问题。
- **Kubeflow model-registry**:本周多次 `Sync from kubeflow/main`(operator/UI),OAI 仍紧跟上游,自有改动集中在 catalog/security/UI。dashboard 也同步上游 [Sync from kubeflow/model-registry](https://github.com/opendatahub-io/odh-dashboard/pull/8242)。
- **MLflow 上游**:dashboard 跟随 MLflow v3.13.0 的 "Edit experiment" 重命名修测试选择器([#8255](https://github.com/opendatahub-io/odh-dashboard/pull/8255))。
- **MaaS(Models-as-a-Service)**:dashboard 把 Gen AI MaaS 端点路由到 MaaS BFF 而非 MaaS-API([#7542](https://github.com/opendatahub-io/odh-dashboard/pull/7542)),订阅/策略管理加总览表([#8280](https://github.com/opendatahub-io/odh-dashboard/pull/8280))。OAI 在做"模型即服务 + 订阅计费"形态。

## 安全(本周值得单列)

- [model-registry: 修复 HuggingFace catalog loader 的 SSRF 与环境变量 oracle](https://github.com/opendatahub-io/model-registry/pull/2857) — 外部模型目录加载的注入面被堵。我们若也接 HF/外部 catalog,需自查同类 SSRF。
- [notebooks: codeserver open redirect 修复](https://github.com/opendatahub-io/notebooks/pull/3867)(用相对 nginx 重定向)+ 新增 SECURITY.md 漏洞披露流程。

## 值得跟进

- [ ] 读 [operator #3625 ai-gateway](https://github.com/opendatahub-io/opendatahub-operator/pull/3625) 与其依赖的 ai-gateway 仓,搞清 OAI"AI Gateway"的能力边界(批量端点 / 模型名路由),对比我们 Gateway 层定位。
- [ ] 跟踪 [mcp-lifecycle-module-operator](https://github.com/opendatahub-io/mcp-lifecycle-module-operator) 仓:MCP server 的生命周期(部署/注册/发现)如何被建模,这是 agent 平台的关键拼图。
- [ ] 参考 dashboard `agentConfigManagement` CRD 字段([#8269](https://github.com/opendatahub-io/odh-dashboard/pull/8269))设计我们自己的 agent 配置模型;评估 agent-ops 作为可装卸模块([#8241](https://github.com/opendatahub-io/odh-dashboard/pull/8241))的边界划分。
- [ ] 评估把模型部署资源画像(min vRAM / 容器规格,[model-registry #2867](https://github.com/opendatahub-io/model-registry/pull/2867))前置到我们模型目录的可行性。
- [ ] 对齐 Kueue 工作负载状态语义(Evicted vs Requeued,[#8167](https://github.com/opendatahub-io/odh-dashboard/pull/8167))到我们的 GPU 排队可观测面。

## 原始材料

<details>
<summary>本次扫描的 commit/PR/release 清单</summary>

**opendatahub-operator(13 commit)** — 关键:#3625 ai-gateway 模块、#3713 mcp-lifecycle-module-operator、#3684 agent-ops imagesMap、#3634 升级/provision DAG、#3653 集群 TLS profile、#3623 默认启用 MLflow、#3622 model cache PV claimRef、#3682 gateway NetworkPolicy egress(OCP 4.22)、#3662 trustyai 升级删陈旧 immutable selector、#3698 移除未用 trainer 镜像映射。Release:v3.5.0-ea.2(06-17)。

**kserve(14 commit)** — #1564 llmisvc 发现 OpenShift Route、#1670 LLMInferenceServiceConfig 只读 RBAC、#1672 llm-d RELATED_IMAGE 名修正、#1508 kserve-module ModelCache 协调、#1613 fast-1/fast-2 加速器 overlay、#1612 过滤 fast-channel 资源、#1675 operator-chaos 升级校验。Release:v3.5.0+rhaiv.0(06-23)、odh-v3.5-EA2(06-15)。

**odh-dashboard(71 commit)** — gen-ai/agent:#8299 agent config guard、#8287 自动连 MCP、#8269 agentConfigManagement CRD、#8266 改名 Agent configuration、#8261 ASR+MaaS、#8244 agent profile load/preview;agent-ops:#8241 operator 模块、#8173 /agents/deploy BFF、#8211 部署列表;serving:#8256 llm-d topology/routing 数据层、#8113 ServingRuntime "Template removed" 标签;Kueue:#8167/#8181/#8224;MLflow:#7866 全局 namespace 管理 CRD;MaaS:#7542 路由到 MaaS BFF、#8280 订阅总览;模块化:#8183/#8189/#8185 ui-core/plugin-core 抽取;#8239 Go 1.26。Release:v3.4.4-odh(06-15)。

**notebooks(69 commit)** — 主要为 CI/基础设施:ubuntu-24.04→26.04 runner 迁移(#3872/#3919 系列)、buildinputs/check-payload 改用预构建镜像、RHAIENG-5858 保留 2025.2 runtime(3.5 GA)、jupyter 权限处理 perf 优化(#3928)、codeserver open redirect 修复(#3867)、SECURITY.md、大量 deps/konflux base image bump。Release:v1.45.0(06-12)。

**model-registry(27 commit)** — #2857 HF catalog SSRF/env-oracle 修复、#2885 MCP source preview endpoint、#2879 CatalogModel artifactCounts、#2867 UI 展示 vRAM/容器规格、#2891 OpenAPI security artifacts endpoint;多次 sync kubeflow/main(#1798/#1795/#1793/#1790/#1788);余为 deps bump。Release:v0.3.10(06-15)。

**data-science-pipelines-operator(3 commit)** — 给 PipelineVersion CRD 加 `versionName` 字段,managed pipeline 元数据用平台版本号。Release:v2.18.0(2025-11-11,无新 release)。

**trustyai-service-operator(4 commit)** — #766 operand 镜像加 RELATED_IMAGE_* 解析、#787 evalhub ClusterRole 重命名 + secret update verb;两次 merge 自 trustyai-explainability/main。Release:odh-3.5-ea2(06-12)。

</details>
