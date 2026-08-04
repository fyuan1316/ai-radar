# OpenShift AI 周报 2026-08-04

扫描窗口:2026-07-28 ~ 2026-08-04(过去 7 天),数据源为 opendatahub-io 七个主仓的 releases / main commits。

## 摘要(3 条以内)
- **ODH/RHOAI v3.5.0 正式 GA**(operator + dashboard + kserve + model-registry-operator 同步打 v3.5 tag),这是本周头等事件;release note 的组件矩阵首次把 llm-d、WVA、batch-gateway、MaaS、OGX、Feast、MLflow-operator 一起纳入同一版本线。见 https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.5.0
- **架构主线是"组件模块化(module operator)"**:operator 把 OGX、TrustyAI、KServe 从 in-tree 组件处理器迁到独立 module operator,自身只下发 Module CR、不再直接 reconcile 子资源;operator 仓本周还成批删 CRD/dead code。
- **推理栈全面转向 llm-d + LLMInferenceService**:kserve odh-v3.5 一周 27 个 commit 密集打磨 llmisvc(LoRA/DRA 校验、scheduler/latency 插件探测、metrics flag 迁移),并给 RawDeployment 加金丝雀流量切分、重新启用 ClusterServingRuntime。

## 新功能 / 能力
- [operator v3.5.0 组件矩阵](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.5.0) — 一次性锁定 llm-d-router、workload-variant-autoscaler(WVA)、batch-gateway、models-as-a-service v0.2.1、ogx-k8s-operator、Feast v0.65.0、MLflow-operator 1.1.0、Trainer odh-3.5.0 等一整套版本。
  - 启示:OAI 已把"分布式 LLM 推理(llm-d)+ 变体自动扩缩(WVA)+ 批量网关 + MaaS 计量"打包成同一发行线,这是我们产品做推理平台对标的最新基线,组件清单可直接当能力核对表。
- [Enable ClusterServingRuntime in ODH (#1803)](https://github.com/opendatahub-io/kserve/pull/1803) — 重新启用 ClusterServingRuntime CRD 与校验 webhook(此前被 `$patch: delete` 关掉),为 runtimes 团队的 CLI/GitOps CSR 工作铺路。
  - 启示:OAI 在推运行时的 GitOps/CLI 管理(集群级 ServingRuntime 声明式下发),我们若还停在 namespace 级 ServingRuntime,需评估是否补集群级共享运行时能力。
- [canary traffic splitting to RawDeployment HTTPRoutes (#5912)](https://github.com/opendatahub-io/kserve/pull/5912) — RawDeployment 模式(无 Knative)下用 Gateway API HTTPRoute 做金丝雀流量切分。
  - 启示:去 Knative 的 RawDeployment 现在也能做渐进式发布,消除了"要灰度就得上 Serverless"的绑定,值得我们在 raw 部署路径对齐。
- [add modelCapabilities feature flag (#9041)](https://github.com/opendatahub-io/odh-dashboard/pull/9041) — dashboard 引入 `modelCapabilities` 特性开关与 well-known 值,作为部署向导/部署表里"模型能力"标注的基础设施。
  - 启示:控制台开始按"模型能力(如是否支持 chat/embedding/vision)"组织部署与展示,是模型即服务(MaaS)体验的前置能力,建议纳入我们模型目录的元数据模型。
- [Feature Store 创建向导数据层 (#8402)](https://github.com/opendatahub-io/odh-dashboard/pull/8402) — 为 Feast(v0.65)特征库落地创建向导的数据模型、多步校验和 CRD spec builder。
  - 启示:OAI 把 Feast 特征库做成一等公民并配可视化建库向导,补齐了"数据→特征→训练/推理"链路,是我们特征平台方向的直接参照。
- [MaaS 治理 UI 系列](https://github.com/opendatahub-io/odh-dashboard/pull/8875) — dashboard 本周多处 MaaS(Models-as-a-Service)工作:解锁 MaaS Governance Overview Tab(#8875)、治理分组标签点击高亮(#9002)、Token 速率上限对齐 CRD(#8991)。
  - 启示:MaaS 的"多租户配额 + Token 限流 + 治理视图"正在成型,这是把内部推理平台变成对外/跨团队计量服务的关键一层,和我们做多租户 GPU/推理售卖强相关。
- [model-registry v0.3.14 + Skill/Agent/MCP Catalog](https://github.com/opendatahub-io/model-registry/pull/3038) — Model Catalog v1 OpenAPI 定稿,并新增 Skill Catalog(SKC-101~104,含 SKILL.md 解析器)、MCP catalog 与 agent catalog 的 YAML 实时热加载(#2997)。
  - 启示:模型注册中心正扩成"模型 + 技能 + Agent + MCP 工具"的统一目录,这是面向 Agentic/GenAI 的资产中枢演进方向,我们的模型注册若只管模型权重会落后一个身位。
- [TrustyAI EvalHub + Inspect AI provider (#840)](https://github.com/opendatahub-io/trustyai-service-operator/pull/840) — TrustyAI 新增 EvalHub 组件,接入 Inspect AI、deepeval、ragas、lighteval 等评测 provider。
  - 启示:可信 AI 从"可解释/偏差检测"扩到"统一 LLM 评测中枢(EvalHub)",评测能力正从散装脚本收敛成平台组件,值得对标我们模型评估模块。

## 架构 / 依赖变化
- **模块化(module operator)推进**:operator 新增 OGX Module Handler([#3813](https://github.com/opendatahub-io/opendatahub-operator/pull/3813)),operator 不再直接管 OGX CR,而是部署 ogx-k8s-operator 由其自持生命周期;TrustyAI 同步落地 `trustyai-operator-module` 骨架([#849](https://github.com/opendatahub-io/trustyai-service-operator/pull/849))并实现平台依赖校验、SSA 迁移、健康聚合;kserve 也有独立 kserve-module 的 e2e/部署路径。operator 本周还成批 `remove CRDs and dead code for modularized components (#3854)`、删 finalizer 迁移代码(#3901)。
  - 启示:OAI 正把单体 operator 拆成"总控 operator + 各组件 module operator"的联邦架构,好处是组件可独立发版/独立 reconcile。我们若也是单 operator 管所有组件,该模式(平台契约标准 conditions + SSA 采纳迁移)值得借鉴。
- **aigateway 进入 helm 组件(xks)** [#3879](https://github.com/opendatahub-io/opendatahub-operator/pull/3879) — AI Gateway 被加进 xKS 用的 helm 组件集。
- **安全/多租户加固**:operator 集成集群 TLS security profile(#3653)、gateway 的 kube-auth-proxy TLS 依 APIServer 配置增强(#3620);kserve 收紧 controller-manager ClusterRole(#5785)、给 llmisvc-controller-manager 加 NetworkPolicy(#1823)、model cache 重打共享 SELinux level(#1838);dashboard 多处收紧 kustomize/network policy egress。
  - 启示:整个发行线在按"最小权限 + 显式 NetworkPolicy + TLS profile 对齐 OCP"做企业级合规收口,这是 OAI 面向监管客户的护城河,我们做企业版需要同等的默认安全基线。
- **Kueue 增强**:operator 新增 `autoCreateQueues` flag(#3648),按 DSC 声明自动建队列。

## 上游生态整合动向
- **KServe / llm-d**:odh fork 本周 3 次 sync upstream(#1831/#1820 等);llm-d 相关持续硬化——从模板参数探测 scheduler / latency-producer 插件(#5931/#5937)、迁移 `--model-server-metrics-*` flag 到 llm-d(#5930)、补齐 v1alpha1 对 LoRA/DRA annotation 的校验(#5938)。llm-d 已是 OAI 分布式推理事实标准。
- **Kubeflow**:model-registry 频繁从 kubeflow/main 合并(#1834~#1839),保持与上游 Kubeflow model-registry 同步;notebooks 走 kubeflow notebook-controller v1.10.0-14。
- **Ray / Feast / MLflow**:v3.5.0 锁定 KubeRay v1.6.2、Feast v0.65.0(特征库)、MLflow-operator 1.1.0 并在默认 DSC 里默认启用 MLflow(#3623),dashboard 补 MLflow 嵌套 run 比较与 pipeline server 配置(#8987)。
- **DSPO(data-science-pipelines-operator)**:本周 main 无新 commit,发行仍锚定 v2.18.0(随 v3.5.0 打包)。

## 值得跟进
- [ ] 读 [operator v3.5.0 release note](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.5.0) 的完整组件矩阵,逐项与我们产品能力做 gap 分析(重点:MaaS、WVA、batch-gateway、OGX)。
- [ ] 评估 module operator 联邦架构([#3813](https://github.com/opendatahub-io/opendatahub-operator/pull/3813) + TrustyAI [#849](https://github.com/opendatahub-io/trustyai-service-operator/pull/849)):我们的单 operator 是否要跟进拆分,以及"平台契约标准 conditions / SSA 迁移"如何落地。
- [ ] 试 RawDeployment 金丝雀流量切分([kserve #5912](https://github.com/opendatahub-io/kserve/pull/5912)),验证去 Knative 路径的渐进发布体验,对齐我们 raw 部署灰度能力。
- [ ] 跟进 model-registry 的 Skill/Agent/MCP Catalog([#3038](https://github.com/opendatahub-io/model-registry/pull/3038)/#2997),判断我们的模型注册是否要扩成 Agentic 资产目录。
- [ ] 看 MaaS 治理 + Token 限流([dashboard #8991](https://github.com/opendatahub-io/odh-dashboard/pull/8991)/#8875)与 models-as-a-service v0.2.1,对标我们多租户推理计量方案。

## 原始材料

<details>
<summary>本次扫描的 release / commit / PR 清单</summary>

**Releases(过去 7 天新增或对齐 v3.5)**
- opendatahub-operator v3.5.0(2026-07-29 GA)
- odh-dashboard v3.5.0 / v3.5.0-odh(2026-07-27/24)
- kserve odh-v3.5(2026-07-27)
- notebooks v1.47.0(2026-07-22,3.6.0 已 kickoff)
- model-registry v0.3.14(2026-07-27)
- DSPO v2.18.0(旧,随 3.5 打包,本周 main 无提交)
- trustyai-service-operator odh-3.5(release note 引用)

**opendatahub-operator(14 commits)**:#3913 移除 llm-d kv-cache known issue、#3908 加 ubi-micro image、#3901 删 finalizer 迁移码、#3854 删模块化组件 CRD/dead code、#3898 mirrored submodule condition 视为 informational、#3879 aigateway 进 helm、#3890 workbenchNamespace 镜像进 DSC status、#3813 OGX Module Handler、#3893 Trainer image 参数例外、#3889 cloudmanager sailor RBAC、#3885 related image check。

**odh-dashboard(68 commits,选摘)**:#9029 模型部署设置 tab 页壳+flag、#9041 modelCapabilities flag、多条 RHOAIENG-798xx 把 util/组件抽到 @odh-dashboard/ui-core|k8s-core|model-serving 共享包、#8402 Feature Store 创建向导数据层、#8875 解锁 MaaS Governance Tab、#9002 MaaS 治理分组高亮、#8991 Token 速率上限对齐 CRD、#8987 MLflow 嵌套 run 比较、#9016 standalone 部署资源 right-size+PDB、AutoML/AutoRAG 多处修复(#9025/#9020/#8980)。

**kserve odh-v3.5(27 commits,选摘)**:#5912 RawDeployment 金丝雀、#1803 启用 ClusterServingRuntime、#5938 llmisvc LoRA/DRA 校验、#5931/#5937 scheduler/latency 插件探测、#5930 迁移 model-server-metrics flag、#1838 model cache 共享 SELinux level、#5785 收紧 controller ClusterRole、#1823 llmisvc NetworkPolicy、多次 upstream sync(#1831/#1820)。

**notebooks(86 commits,多为 CI/CVE/konflux)**:3.6.0 release kickoff(#4280)、CodeServer culling 心跳修复(#4065)、check-payload 0.3.17、konflux base image 升 3.6.0-ea.1、CVE tracker 去重重构。

**model-registry(16 commits)**:#3038 Model Catalog v1 OpenAPI、#3041/#3040 Skill 插件+SKILL.md 解析器、#3035 skill source config、#2997 MCP/agent catalog YAML 热加载、多次 merge kubeflow/main。

**trustyai-service-operator(13 commits)**:#849 trustyai-operator-module 骨架、#834 retry-on-conflict/Unmanaged 状态、#811 平台依赖校验、#804 SSA 采纳迁移、#818 平台契约标准 conditions、#802 健康聚合、#840 EvalHub Inspect AI provider、#847 README 加 EvalHub。

**data-science-pipelines-operator**:本周 main 无新提交。

</details>
