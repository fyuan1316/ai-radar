# OpenShift AI 周报 2026-08-25

> 扫描窗口:2026-08-18 ~ 2026-08-25。数据源:opendatahub-io 7 个核心仓的 main 分支 commits / PR / releases(api.github.com)。本周无新 release(v3.5.0 GA 仍是 7 月底),但 **rhoai-3.6-ea.1 分支已切出**,3.6 的架构与能力方向本周集中落地。

## 摘要(3 条以内)
- **架构大转弯**:DAG 编排从 DSC 控制器上移到 platform 控制器,OpenShift 与非 OpenShift 原生 K8s(xKS)统一为单一代码路径;组件持续"出树化"成独立 module(model-registry→AIHub、spark-operator、Workbenches v2、kserve-module),dashboard 侧配套 module federation(host-api / federation-config / core-bff 代理)。
- **押注 Gen-AI / Agentic**:AI Hub、OpenAI 兼容 embeddings 代理、AutoRAG、AutoML、model-catalog 工具调用 GA、MCP 部署表 + MCP Registry、agentic-starter-kits 全部为 3.6 铺路;KServe 的 `LLMInferenceService`(llmisvc)持续加固(预设配置、证书签发、审计日志)。
- **上游依赖切换**:notebooks 用 ODH 自维护的 Kale 取代 Kubeflow Kale,OS 基础镜像 9.6→9.8,统一走 AIPCC base images;TrustyAI evalhub 接入 Open-Telco Inspect 基准与 lighteval。

## 新功能 / 能力

- [feat(dag): migrate DAG orchestration to platform controller](https://github.com/opendatahub-io/opendatahub-operator/pull/3786) — DAG 编排(`WalkBatches`)从 DSC 控制器迁到 platform 控制器,OpenShift 与 xKS(非 OCP 原生 K8s)共用同一编排路径,解决组件排序、版本安全升级、生命周期三类问题。
  - 启示:这是"一套 operator 同时跑 OCP 和裸 K8s"的关键一步,直接影响我们能不能把类似平台下沉到非 OpenShift 集群。值得精读它怎么做 runlevel 分级与升级门控(配套 #4008 加了 DAG runlevel 回归测试)。
- [feat(gen-ai): /v1/embeddings proxy handler](https://github.com/opendatahub-io/odh-dashboard/pull/9245) — 在 dashboard BFF 里实现 OpenAI 兼容的 `POST /api/v1/genai-proxy/ns/:namespace/v1/embeddings`,接收 OGX 请求、解析模型到具体上游 endpoint(带凭据)后透明转发。
  - 启示:OAI 正把 dashboard 变成"模型网关"——OpenAI 兼容 + 命名空间隔离 + 凭据代管。我们若做统一推理入口,可对标这套 genai-proxy 的凭据解析与多租户路由。
- [feat(data-registry): registry table + collections](https://github.com/opendatahub-io/odh-dashboard/pull/9412) 配 [RHAI-415 BFF 代理路由](https://github.com/opendatahub-io/odh-dashboard/pull/9276) — dashboard 新增 "Data Registry"(数据资产注册表,带过滤/分页/collections 管理与 InsecureSkipVerify 安全护栏)。
  - 启示:继 model-registry 之后再补"数据侧目录",OAI 在往数据+模型双 registry 的资产治理演进,是企业级差异化能力,值得评估我们是否要对齐。
- [Add registry linking and delete cascade to MCP Deployments table](https://github.com/opendatahub-io/odh-dashboard/pull/9299) — MCP(Model Context Protocol)部署表进入 Phase 2C:从 MCP Registry 创建的部署可回显 registry 关联信息,删除时级联清理 registry 访问端点;model-registry 侧同步加了 MCP details 页(serverJson 卡片)。
  - 启示:OAI 已把 MCP server 当作一等公民纳入部署与注册闭环——这是 agentic 平台的底座,我们做 agent 编排绕不开 MCP registry 这一环。
- [feat(kserve-module): EnableAuditLogging to KserveSpec](https://github.com/opendatahub-io/kserve/pull/1858) 及 [watch/restore LLMInferenceServiceConfig presets](https://github.com/opendatahub-io/kserve/pull/1872) — llmisvc 加审计日志开关、CA bundle 同步、EC 证书签发修复;推理配置预设可被 watch 并自动恢复。
  - 启示:`LLMInferenceService` 正在从实验走向可运维(审计/证书/预设),是 KServe LLM 路线的主线,建议持续跟 llmisvc CRD 的字段演进。
- [feat(evalhub): Open-Telco Inspect benchmarks + lighteval](https://github.com/opendatahub-io/trustyai-service-operator/pull/883) 及 [Add open telco collection](https://github.com/opendatahub-io/trustyai-service-operator/pull/882) — TrustyAI evalhub 接入电信领域 Inspect 基准、修复 lighteval TruthfulQA,dashboard 侧评估任务支持 stop/retry([#9317](https://github.com/opendatahub-io/odh-dashboard/pull/9317))。
  - 启示:模型评估在往"垂直领域基准 + 可运维任务(停/重试)"走,是模型生命周期里我们较薄弱的一环。

## 架构 / 依赖变化

- **组件出树化(out-of-tree module)成为主旋律**:model-registry 迁到独立的 [AIHub module](https://github.com/opendatahub-io/opendatahub-operator/pull/4000)、[spark-operator 出树](https://github.com/opendatahub-io/opendatahub-operator/pull/3836)、新增 [WorkbenchesV2 聚合 module](https://github.com/opendatahub-io/opendatahub-operator/pull/3956);operator 内部完成 ModuleHandler 接口 + DAG 迁移的测试对齐(#4017/#3916)。
- **Dashboard 走 module federation**:[core-bff 通过 federation-config 代理 module API 路径](https://github.com/opendatahub-io/odh-dashboard/pull/9444)、HostApi 拆分为 Core/Infra 上下文(#9289)、notebooks v2 插件前端集成(#9226)。整个前端在从单体走向可插拔联邦。
- **cert-manager 解耦**:operator [移除 cloud controller manager 里的 cert-manager Helm 部署与健康监控](https://github.com/opendatahub-io/opendatahub-operator/pull/3929)。
- **安全**:[OIDC IssuerURL 校验](https://github.com/opendatahub-io/opendatahub-operator/pull/3987)、data-registry BFF 加 InsecureSkipVerify 护栏。
- **notebooks 基础镜像**:[改用 ODH Kale 取代 Kubeflow Kale](https://github.com/opendatahub-io/notebooks/pull/4400)、OS 9.6→9.8 迁移、统一 AIPCC base images。
- **维护流程 agent 化(值得单独看)**:notebooks 构建仓建了工具无关的 `.agents/plugins/` 插件体系(cve-resolution / cluster-bot / ci-summary / pr-review 四个 skill,各带 plugin.json + mcp_config.json);[#4410](https://github.com/opendatahub-io/notebooks/pull/4410) 只是把正本 skill 软链进 `.claude/skills/` 与 `.cursor/skills/`,让 Claude Code / Cursor 都能 `/fix-cve`。`fix-cve` 是一条全自主 CVE 修复流水线:经 Atlassian MCP 拉 Jira 工单→按"包×分支"聚类→改 `cve-constraints.txt`→refresh lock→建 PR→回写工单→触发 Konflux 构建→出 Slack 汇总,失败即记录续跑、无人值守。
  - 启示:OAI 把 AI agent 用到了自己的产品供应链维护(面向下游 red-hat-data-services/notebooks 发行版),不是 demo。CVE/合规 toil 是 agent 高价值落地点;那套"skill 正本中立目录 + 多工具软链"的组织方式可直接抄;MCP 已是其研发流程的生产集成层。建议拿我们镜像仓 CVE backlog 做一次对标 PoC。

## 上游生态整合动向

- **KServe**:ODH fork 本周几乎全是 kserve-module(module-operator 化)与 llmisvc 加固;同时持续 sync upstream/master(#1901),JWE 支持 full JWK 与 raw key 两种格式(#6034)。方向明确:把 KServe 包装成 ODH module CR,并以 `LLMInferenceService` 作为 LLM 服务的一等入口。
- **Kubeflow**:notebooks 从 Kubeflow Kale 切到 ODH 自维护 Kale——上游依赖进一步"去 Kubeflow 化",自控力增强。
- **vLLM**:operator 为 [vllm-omni-cuda runtime](https://github.com/opendatahub-io/opendatahub-operator/pull/3930) 与 [trainer 的 vllm CUDA 镜像](https://github.com/opendatahub-io/opendatahub-operator/pull/3985) 加 RELATED_IMAGE 引用,3.6 会带多个 vLLM 变体运行时。
- **model-registry**:catalog v1 API handlers 落地(#3065)、强制 v1 OpenAPI 命名规范并清理 deprecated 参数(#3086)——registry API 在 GA 化。

## 值得跟进
- [ ] 精读 [operator #3786](https://github.com/opendatahub-io/opendatahub-operator/pull/3786):platform 控制器如何统一 OCP 与 xKS 的 DAG 编排、runlevel 分级、版本安全升级——对我们"一套平台多种 K8s 底座"最有参考价值。
- [ ] 摸清 MCP Registry + MCP Deployments 的完整闭环([dashboard #9299](https://github.com/opendatahub-io/odh-dashboard/pull/9299) + model-registry MCP details #3099),评估我们 agent 平台是否要引入 MCP registry。
- [ ] 跟踪 `LLMInferenceService`(llmisvc)CRD 字段演进([kserve #1858](https://github.com/opendatahub-io/kserve/pull/1858)/#1872),判断是否值得在我们推理栈里对齐这套 LLM-native CRD。
- [ ] 试用 genai-proxy 的 embeddings 代理([dashboard #9245](https://github.com/opendatahub-io/odh-dashboard/pull/9245)),评估"dashboard 即模型网关"的多租户/凭据代管模式。
- [ ] 观察 3.6-ea.1 后续 release(operator/kserve/trustyai 目前仍停在 3.5 GA),下周大概率有 3.6 EA 版本号落地。

## 原始材料

<details>
<summary>本次扫描的 commit/PR 清单(点开)</summary>

**opendatahub-operator(27 commits)**:DAG 迁移到 platform 控制器 #3786;out-of-tree module 化 #4000(modelregistry→AIHub)/#3836(spark)/#3956(WorkbenchesV2);ModuleHandler 测试对齐 #4017/#3916;vllm-omni-cuda RELATED_IMAGE #3930;trainer vllm CUDA #3985;OIDC IssuerURL 校验 #3987;移除 cert-manager Helm #3929;切 rhoai-3.6-ea.1 分支 #3984;DCGM metric relabel #3997;Tempo trace RBAC #3990。

**odh-dashboard(~99 commits,截取 feat/重构)**:data-registry 表 #9412 + BFF 路由 #9276/#9266;genai embeddings 代理 #9245;MCP 部署表 registry 关联+级联删除 #9299;notebooks v2 插件 #9226/manifests #9154;core-bff 联邦代理 #9444;HostApi 拆 Core/Infra #9289;AI Hub Data tab #9293;evalhub collections API #9368 / 任务 stop-retry #9317;catalog 工具调用 GA #9329;AutoML/AutoRAG segment 追踪 #9340/#9357;agentic-starter-kits 更新到 3.6 #9255;NIM KServe PVC 选择 #9344。

**kserve(ODH,29 commits)**:kserve-module EnableAuditLogging #1858;llmisvc presets watch/restore #1872;llmisvc EC CA 证书签发 #1896 / CA bundle RBAC #5965;autogluon-image #1855;sync upstream #1901;JWE full-JWK/raw-key #6034;大量 module-operator e2e/文档。

**model-registry(15 commits)**:catalog v1 API handlers #3065;v1 OpenAPI 命名规范 #3086;MCP details serverJson 卡片 #3099;catalog source 校验状态刷新 #3085;去 deprecated handler #3102;若干 deps bump。

**trustyai-service-operator(8 commits)**:evalhub Open-Telco Inspect + lighteval TruthfulQA #883;open telco collection #882;mlflow public route #881;OTel↔Prometheus bridge #879;kube-rbac-proxy 指向主 API 端口。

**notebooks(29 commits)**:ODH Kale 取代 Kubeflow Kale #4400;OS 9.6→9.8 迁移 #4408;AIPCC base images 一批更新;fix-cve Claude/Cursor skill #4410;s390x/ppc64le 构建修复。

**data-science-pipelines-operator**:本周 main 无新 commit。

**Releases**:7 仓本周均无新 release;operator/kserve/trustyai 停在 3.5 GA(7 月底),3.6-ea.1 分支已切出但未打 tag。

</details>
