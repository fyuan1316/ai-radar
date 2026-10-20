# OpenShift AI 周报 2026-10-20

> 扫描窗口:2026-10-13 ~ 2026-10-20(过去 7 天)。7 个主仓本周均无新 release(最近一版仍是 9 月的 3.6-ea2),但 commit/PR 活跃度很高——原因是 **3.6 仍处 Early Access,GA 迫近**,本周大量提交是 "version bump for 3.6GA" 的收尾稳定化([RH 文档站](https://docs.redhat.com/documentation/en-us/red_hat_openshift_ai_self-managed)目前最新正式版仍为 3.5,3.6 只挂在 Early Access)。

## 摘要(3 条)

- **OAI 正在把平台从"部署模型"推向"模型即服务 + Agent 平台"**:本周落地 aiGrid 子组件、maasPortal 投影、MaaS API Key/用量代码片段、MCP Gateway 准入门禁,一整套 Models-as-a-Service 网关/门户层在 3.6 GA 前拼齐。
- **LLMInferenceService(llmisvc)已成推理主线**:新增裸金属机密计算(加密模型跑在 confidential VM)、网关侧 OCSF 审计日志、vLLM-Omni 多模态(TTS/TTI)、ModelExpress 权重缓存(Tech Preview);同时自研的 WVA 自动扩缩被全面弃用,转向 llm-d。
- **DRA 进入用户可见层**:Dashboard 开始在硬件配置和 workbench 详情里展示 ResourceClaimTemplate(Tech Preview),GPU 调度向 Kubernetes DRA 迁移的信号明确。

## 新功能 / 能力

- [aiGrid 子组件上 DataScienceCluster](https://github.com/opendatahub-io/opendatahub-operator/pull/4186) — DSC 新增 `aigateway.aiGrid.managementState`,下发 Grid operator 镜像并传播 `AIGridReady`;配合 [maasPortal 投影](https://github.com/opendatahub-io/opendatahub-operator/pull/4208) 与 Dashboard 侧 [MaaS API Key + 用量代码片段页](https://github.com/opendatahub-io/odh-dashboard/pull/10271),MaaS 门户在 GA 前成形。
  - 启示:这是 OAI 本季最明确的战略动作——把"给平台管理员部署模型"升级为"给租户发 Token、按 API 消费模型"。我们若还停留在 KServe 裸推理暴露,差距会被拉开;应评估自家是否需要等价的 MaaS 网关(限流/计量/API Key/多租户门户)。
- [llmisvc 裸金属机密计算 serving](https://github.com/opendatahub-io/kserve/pull/2105) — 新增 `kserve-config-llm-confidential-bare-metal` preset,加密模型跑在 confidential VM,客户自备 LUKS block PVC,控制器校验 PVC 存在/块模式/可写并注入凭据与 SCC。
  - 启示:面向金融/政企"模型权重不可见于运维"的强合规场景。我们产品若要进同类客户,confidential computing + 加密权重是硬门槛,建议把它列入路线评估而非观望。
- [llmisvc 网关侧 OCSF 审计日志](https://github.com/opendatahub-io/kserve/pull/2107) — `spec.auditLoggingProfile` 单一开关,基于 RHCL 1.5.1+ 在网关侧对 LLM 推理流量做 OCSF 标准审计,带 Authorino 身份元数据,支持漂移修复。
  - 启示:企业合规审计用的是开放标准 OCSF 而非私有格式。我们的推理审计如果要对接客户 SIEM,OCSF 是正确的互操作目标。
- [ModelExpress 成为 KServe 可选子组件](https://github.com/opendatahub-io/opendatahub-operator/pull/4226) — DSC 新增 `kserve.modelExpress.managementState`(默认 Removed),ModelExpress 是模型缓存 + GPU-to-GPU 权重传输服务,3.6 走 Tech Preview。
  - 启示:大模型冷启动/多副本权重分发是实际痛点,GPU 直传权重能显著缩短 scale-up 时间。值得对标我们在模型缓存层的方案。
- [vLLM-Omni 多模态 runtime 注入](https://github.com/opendatahub-io/kserve/pull/2078) — 模块侧映射 base/fast-1/fast-2 三档 vLLM Omni CUDA 镜像,llmisvc 可服务 TTS/TTI 等多模态端点。
  - 启示:推理栈从纯文本 LLM 向语音/图像多模态扩展,运行时选型要预留多模态 vLLM 变体。
- [AI Hub → Skills 嵌入 MLflow Skill Registry](https://github.com/opendatahub-io/odh-dashboard/pull/10315) 与 [MCP Gateway 准入门禁](https://github.com/opendatahub-io/odh-dashboard/pull/10255) — Dashboard 以联邦模块方式加载 MLflow 的 Agent Skill Registry(Tech Preview);并禁止在无 MCP gateway 时部署 OpenShift MCP Server。
  - 启示:OAI 的 Agent 叙事在落地——Skills/MCP/Playground/Agent Traces 成一条产品线。我们若做 Agent 平台,MLflow Skill Registry 复用 + MCP gateway 强管控是可参考的组织方式。
- [DRA ResourceClaimTemplate 进入 Dashboard](https://github.com/opendatahub-io/odh-dashboard/pull/10116) — DRA 硬件配置在弹窗和 workbench 详情显示 Claim template(Tech Preview);硬件过滤器也改读 catalog 的 `supportedAccelerators`([#10303](https://github.com/opendatahub-io/odh-dashboard/pull/10303))。
  - 启示:GPU 调度正从 device-plugin 向 DRA 迁移,且已上浮到用户界面。我们的硬件配置/加速卡纳管需要跟上 DRA 数据模型。
- [Universal Jupyter 双模镜像](https://github.com/opendatahub-io/notebooks/pull/4741) — 一个 hermetic 镜像定义产出单一 digest,既能当交互式 JupyterLab workbench 又能当 Elyra/Pipelines runtime,收敛维护成本;配合 [à-la-carte AIPCC base 镜像](https://github.com/opendatahub-io/notebooks/pull/4748)。
  - 启示:工作台镜像"一镜两用"降低构建/供应链维护面,我们的 notebook 镜像矩阵若臃肿可借鉴这种合并思路。

## 架构 / 依赖变化

- **WVA(自研加权自动扩缩)全面弃用**:operator 侧 [deprecate WVA 并移除镜像](https://github.com/opendatahub-io/opendatahub-operator/pull/4125),kserve 模块侧停止克隆 WVA manifests、清理残留 Deployment(commits `b929702`/`5ca606c`),llmisvc 弃用 WVA autoscaling——方向整体收敛到 llm-d(本周 [llm-d-router 升 v0.11.0](https://github.com/opendatahub-io/kserve/pull/6258),新增 [llm-d pvc evictor 镜像](https://github.com/opendatahub-io/opendatahub-operator/pull/4217))。
- **Gateway/Auth 加固**:CA secret 轮换时 [滚动 kube-auth-proxy pods](https://github.com/opendatahub-io/opendatahub-operator/pull/4212)、[operator 托管的 kube-auth-proxy NetworkPolicy](https://github.com/opendatahub-io/opendatahub-operator/pull/4158)、[共享 OpenShift Route server timeout](https://github.com/opendatahub-io/opendatahub-operator/pull/4179)。
- **TLS 严格模式**:接入 framework v0.2.0,严格遵从下校验 manager profiles 与 Old profile 处理([#4204](https://github.com/opendatahub-io/opendatahub-operator/pull/4204)/[#4167](https://github.com/opendatahub-io/opendatahub-operator/pull/4167))。
- **依赖解耦**:operator [移除对 models-as-a-service/maas-controller API 的直接依赖](https://github.com/opendatahub-io/opendatahub-operator/pull/4203)(改走镜像/manifest 传递),新增 odh-db-operator 到 manifests;kserve [迁移 Istio Helm chart 仓库](https://github.com/opendatahub-io/kserve/pull/6385)。

## 上游生态整合动向

- **vLLM**:多模态 vLLM-Omni(TTS/TTI)运行时接入(上见);huggingfaceserver 侧 lmcache 升到 0.5.5。
- **llm-d**:成为 llmisvc 的自动扩缩/路由主线,router v0.11.0,新增 PVC evictor。
- **KServe**:大量 upstream→odh master 同步(一次解了 28 个冲突),odh fork 正为 3.6 GA 收口。
- **TrustyAI / EvalHub**:评测 provider 大扩张——[operator 传播 EvalHub lighteval/inspectai adapter 镜像](https://github.com/opendatahub-io/opendatahub-operator/pull/4206),模块侧新增 databench、mteb、followbench provider 与 trustworthiness 维度;NeMo Guardrails 增加 [admin 端点独立 auth provider 隔离](https://github.com/opendatahub-io/trustyai-service-operator/pull/995) 与按命名空间声明可挂载 consumer 的管控。
- **MLflow / MCP**:MLflow 既作 Skill Registry 又作 MCP registry 的联邦模块嵌入 Dashboard(上见)。

## 值得跟进

- [ ] 读 [aiGrid PR #4186](https://github.com/opendatahub-io/opendatahub-operator/pull/4186) + [ai-gateway-operator #148](https://github.com/opendatahub-io/ai-gateway-operator/pull/148),摸清 OAI MaaS 网关的 CRD/组件拓扑,产出一页对标我们自家网关的能力差距表。
- [ ] 评估 [confidential bare-metal serving #2105](https://github.com/opendatahub-io/kserve/pull/2105) 的落地门槛(confidential VM/SCC/LUKS PVC),判断我们是否要进强合规客户。
- [ ] 跟踪 OAI 3.6 正式 GA 时点(目前仍 EA);GA release notes 一出,核对本周这些 Tech Preview 特性哪些转 GA、哪些仍 TP。
- [ ] 把 [DRA claim template #10116](https://github.com/opendatahub-io/odh-dashboard/pull/10116) 的数据模型(`spec.dra.resourceClaimTemplateName`)纳入我们硬件配置纳管的设计评审。

## 原始材料(本次扫描清单)

<details>
<summary>展开:各仓库 commit/PR 概览(2026-10-13 ~ 2026-10-20)</summary>

- **opendatahub-operator**(35 commits):#4226 ModelExpress、#4186 aiGrid、#4217 llm-d pvc evictor、#4206 EvalHub adapter 镜像、#4182 workbench project ingresses、#4212/#4158/#4179 gateway 加固、#4204/#4167 TLS、#4203 解耦 maas-controller、#4125 弃用 WVA、#4147 uninstall-in-progress、#4208 maasPortal、#4093 structured-log analyzer。无新 release(最新 v3.6.0-ea.2,2026-09-22)。
- **odh-dashboard**(100+ commits):#10315 MLflow Skills、#10255 MCP gateway 门禁、#10116 DRA claim template、#10303 硬件过滤器、#10316 Agent traces 改名、#10271 MaaS API Key 用量片段、#10287 Data Registry 追踪、#10306 Playground 媒体上传、#10244 DCH 连接详情、#10266 EvalHub Curated Collection 指示器。
- **kserve**(38 commits):#2105 机密计算 serving、#2107 OCSF 审计、#2078 vLLM-Omni 注入、#2089/#2080 审计 e2e/CI、#2104 Model Cache CA bundle、#6258 llm-d-router v0.11.0、#6285 vLLM-Omni TTS/TTI、#6385 Istio Helm 迁移、WVA 清理(#2103/#2076)。
- **notebooks**(34 commits):#4741 Universal Jupyter 双模镜像、#4748 à-la-carte AIPCC base、#4774 notebook-tier 注解、codeserver-minimal-cpu-py312 上线。无新功能型 release(最新 v1.49.0,2026-09-18)。
- **trustyai-service-operator**(27 commits):#995 NeMo admin 端点 auth 隔离、#1018 Inspect v0.6.11、#1019/#1010 EvalHub LocalQueue/NetworkPolicy RBAC、#1017 LMEval permit 字段、evalhub provider 扩张(databench/mteb/followbench)、#1006 bump x/net v0.60.0。
- **data-science-pipelines-operator**(1 commit):限制 Pipelines operand ingress 范围。最新 release v2.18.0(2025-11)。
- **model-registry**(1 commit):仅新增 approver。最新 release v0.3.17(2026-09-21)。

</details>
