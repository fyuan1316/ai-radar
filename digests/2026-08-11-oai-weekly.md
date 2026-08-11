# OpenShift AI 周报 2026-08-11

扫描窗口:2026-08-04 → 2026-08-11(过去 7 天)。7 个上游仓库全扫,官方 release notes 页无新内容(v3.5.0 已于 7/29 GA,属上周范围)。本周主线在 odh-dashboard 与 kserve:**Gen AI Studio / OGX 的"零重启"模型发现架构**、**model-serving 通过 host-api 上下文桥解耦**、**kserve module operator 与 llmisvc 的认证/注册中心硬化**,叠加一轮跨仓库的**断网(disconnected)可交付性**建设。

## 摘要(3 条以内)

- **Gen AI 层从 UI 走向"运行时"**:dashboard 为 OGX 的 `remote::passthrough` provider 落地 `/v1/models` 代理端点,做到不重启 Pod 动态发现模型;配合 eval-hub agent 元数据、prompt picker 模型关联,OAI 的 Agentic/GenAI 栈正从"控制台功能"变成一套有自己 BFF 代理层的运行时。
- **架构在"拆"**:model-serving 前端通过 host-api 上下文桥消费 10 个共享服务、不再直接 import internal 包(#9048);kserve 独立成 module operator,并把 ModelRegistry 状态注入 KServe 模块 CR。OAI 正把单体 dashboard/operator 切成可插拔模块。
- **断网可交付性成一等工程**:operator + dashboard 一整轮 disconnected readiness scorer、镜像用 digest 不用 tag、OCI host 校验。企业/政企私有化交付被当成 CI 门禁在管。

## 新功能 / 能力

- [feat(gen-ai): /v1/models proxy handler for OGX passthrough (#9120)](https://github.com/opendatahub-io/odh-dashboard/pull/9120) — 新增 `GET /api/v1/genai-proxy/ns/:namespace/v1/models`,以 OpenAI list 格式聚合命名空间内 InferenceService、自定义 endpoint、MaaS 三类模型源;是 OGX "零重启模型发现"三个代理端点的第一个(RHAISTRAT-1921)。
  - 启示:这是 OAI 把"模型目录 + 网关"直接内建进 Gen AI Studio 的信号——BFF 层自己做聚合与 OpenAI 兼容透传,而不是让上游 gateway 独扛。我们若在做 AI 网关/模型广场,要评估是走"独立网关"还是像 OAI 这样把发现逻辑下沉到控制台 BFF;对多模型源(自建 + MaaS + 外部 endpoint)的统一目录抽象值得抄。
- [feat(eval-hub): surface provider agent metadata in results and creation flows (#9149)](https://github.com/opendatahub-io/odh-dashboard/pull/9149) — 评测中心在结果与创建流程里暴露 provider/agent 元数据,配合 NemoGuardrails egress 规则(#9151)。
  - 启示:OAI 的"评测"正在从模型评测扩到 **agent/provider 级评测 + guardrails**,和 Gen AI Studio 绑成一条链。我们的模型生命周期若只有"部署+监控",缺"评测+护栏"这一环会明显落后。
- [feat: inject TLS infrastructure into transformer for auth-enabled predictor (kserve #1545)](https://github.com/opendatahub-io/kserve/pull/1545) — 当 `security.opendatahub.io/enable-auth` 打开时,predictor 挂 kube-rbac-proxy sidecar 在 8443 终止 TLS,transformer 容器自动注入 CA bundle、`SSL_CERT_DIR`、`PREDICTOR_HOST/PORT/PROTOCOL` 做 TLS endpoint 发现。
  - 启示:transformer↔predictor 的**东西向流量默认加密 + RBAC 鉴权**成了 KServe 的内建能力,不再靠 Service Mesh 兜底。我们做多容器推理拓扑(前后处理分离)时,要把 sidecar TLS 注入做成 reconciler 级别的自动行为,而非用户手配。
- [Copy llmd topologies when deploying (#9104)](https://github.com/opendatahub-io/odh-dashboard/pull/9104) — 部署时把选中的 llm-d 拓扑配置拷进部署命名空间,编辑时展示本地副本(RHOAIENG-79541,router 配置尚未包含)。
  - 启示:OAI 正把 **llm-d 的分布式推理拓扑**做成 dashboard 一等部署对象。若我们跟进大模型分布式推理(PD 分离 / 多实例路由),拓扑模板的"选择→拷贝→随部署演进"这套 UX 是现成参考。
- [feat(mcp): add serverJson field to MCP server API (model-registry #3043,上游 kubeflow 同步)](https://github.com/opendatahub-io/model-registry/commit/398f851) — 模型注册中心 API 增加 `serverJson` 字段,把 **MCP server** 纳入注册对象;同期抽出共享 catalog settings 基座(#3063)。
  - 启示:model-registry 正在从"模型/版本注册"扩成"**MCP server / 工具目录**"。Agentic 时代注册中心要管的不只是权重,还有工具与 server 端点——这是产品目录能力要提前预留的抽象。

## 架构 / 依赖变化

- [Bridge 10 services to host-api for model-serving decoupling (#9048)](https://github.com/opendatahub-io/odh-dashboard/pull/9048) — model-serving 前端不再 `import from @odh-dashboard/internal`,改经 host-api 上下文桥消费 10 个服务(连接类型/serving connections/DashboardConfig 模板排序与禁用/Prometheus 指标/KServe·NIM 平台可用性等)。dashboard 正走向插件化,model-serving 变成可独立演进的模块。
- **kserve 独立成 module operator**:本周多条围绕 kserve-module——e2e 部署 DSC/DSCI CRD(#1864)、升级时清理遗留 LLMInference webhook(#1861)、补 ClusterServingRuntime RBAC(#1856)、把 ModelRegistry 状态传播给 odh-model-controller(#1852)。operator 侧对应 [Inject ModelRegistry state into Kserve module CR (#3920)](https://github.com/opendatahub-io/opendatahub-operator/pull/3920)。
- [feat(operator): SecureServing + FilterProvider on metrics endpoint (#3888)](https://github.com/opendatahub-io/opendatahub-operator/pull/3888) — operator metrics 端点走 HTTPS,用 controller-runtime SecureServing + TokenReview/SubjectAccessReview 做认证鉴权,`serving-cert-secret-name` 注入证书,直连 8443 不再经 proxy。配套 [收紧 DSCI status/finalizers 子资源的 delete/deletecollection verb (#3933)](https://github.com/opendatahub-io/opendatahub-operator/pull/3933)。
- **断网可交付性(disconnected readiness)成体系**:operator 侧 disconnected readiness scorer + workflow、[镜像用 digest 不用 tag 保证可镜像化 (#3922)](https://github.com/opendatahub-io/opendatahub-operator/pull/3922);dashboard 侧 OCI host 校验提示词避免误报(#9211)、mock 目录改名规避扫描器(#9099)。
- **notebooks 镜像重构**:新增 `jupyter/baseline` 与 `codeserver-baseline` 精简基础镜像(phase-1 wiring),base image 升到 3.6-EA1-test,移除 kubeflow-training 依赖覆盖为 3.6 EA1 做准备——下一个大版本(3.6)工作台镜像栈已在动。

## 上游生态整合动向

- **KServe**:除上面的 TLS/认证与 module operator 化,还有 [llmisvc 对 Route/Gateway 不匹配发 warning event(#1688)](https://github.com/opendatahub-io/kserve/pull/1688)、tokenizer 镜像统一指向 vLLM v0.18.0 CPU 镜像(替换退役的 UDS sidecar)、OCI modelcar 服务修复(INFERENG-7332)。方向:LLMInferenceService 的 URL 发现与网关集成在收口。
- **vLLM**:作为 tokenizer/推理运行时基线锁定在 **v0.18.0**(RHAII 3.4.1),多处 CI 改用公共 vLLM CPU 镜像。
- **llm-d**:拓扑配置进入 dashboard 部署流(#9104),标志 OAI 分布式推理路线选型倾向 llm-d。
- **Kubeflow model-registry**:opendatahub-io/model-registry 持续从 kubeflow/main 同步(#1840/#1842/#1843/#1845),MCP server 字段、async-upload 传递可信 CA、catalog 领导锁回收等均来自上游。
- **TrustyAI**:evalhub API SA 增加 hardware profile 权限(#836)、依赖校验从 Service Mesh 切到 KServe InferenceService(#853)——TrustyAI 也在去 Service Mesh 依赖,和 KServe 内建 TLS 是同一趋势。
- **DSP(data-science-pipelines-operator)**:本周无提交,最新 release 仍是 2025-11 的 v2.18.0,流水线线相对沉寂。

## 值得跟进

- [ ] 通读 [odh-dashboard #9120](https://github.com/opendatahub-io/odh-dashboard/pull/9120) 的 `genai_proxy_handler.go` + RHAISTRAT-1921 架构,评估我们模型广场/网关是否要把"多源模型发现"下沉到 BFF 做 OpenAI 兼容透传。
- [ ] 跟踪 OGX 三个代理端点的另外两个(models 之后应有 chat/completions 类透传),判断 OAI 是否在自建轻量 AI 网关取代独立 gateway。
- [ ] 研究 [kserve #1545](https://github.com/opendatahub-io/kserve/pull/1545) 的 transformer TLS 自动注入 reconciler,作为我们多容器推理拓扑东西向加密的实现范式。
- [ ] 评估把 **MCP server / 工具**纳入我们模型注册中心的数据模型(参考 model-registry `serverJson`),为 Agentic 目录能力预留抽象。
- [ ] 拉一遍 operator 的 disconnected readiness scorer 机制,对照我们私有化/政企交付的 air-gap 检查清单,看是否值得做成 CI 门禁。

## 原始材料

<details>
<summary>本次扫描的 commit/PR/release 清单(点开)</summary>

**Releases(窗口内无新增,列最新基线)**
- opendatahub-operator v3.5.0(2026-07-29 GA)
- odh-dashboard v3.5.0(2026-07-27)
- kserve odh-v3.5(2026-07-27)
- notebooks v1.47.0(2026-07-22)
- model-registry v0.3.14(2026-07-27)
- trustyai-service-operator odh-3.5-ea2(2026-06-12)
- data-science-pipelines-operator v2.18.0(2025-11-11,无新动作)

**opendatahub-operator(commits 7d,节选)**
- #3942 add related image default from ODH-Build-Config;#3933 收紧 DSCI status/finalizers RBAC verb;#3927 E2E 失败检测 + blocker bug 自动化;#3888 SecureServing HTTPS metrics;#3920 注入 ModelRegistry 状态到 KServe 模块 CR;#3922 disconnected 用 image digest;#3770 disconnected readiness workflow;#3905 trainer imageParamMap 升 TH 0.9.2 / PyTorch 2.11.0;#3575 抽 operator-actions-framework go module

**odh-dashboard(commits 7d,节选)**
- #9225 notebooksV2 feature flag;#9048 bridge 10 services to host-api(model-serving 解耦);#9120 /v1/models OGX 透传代理;#9104 部署时拷贝 llmd 拓扑;#9149 eval-hub provider agent 元数据;#9151 NemoGuardrails egress;#8411 Gen AI Studio prompt picker 模型关联;#7951 阻止生产环境 InsecureSkipVerify;#9070 iframe sandbox;#9109 nimServiceOperator flag;#9146 从 kubeflow/model-registry 同步

**kserve(commits 7d,节选)**
- #1545 transformer TLS 注入(auth 场景);#1864 e2e 部署 DSC/DSCI CRD;#1861 清理遗留 LLMInference webhook;#1856 补 ClusterServingRuntime RBAC;#1852 传播 ModelRegistry 状态到 odh-model-controller;#1688 llmisvc Route/Gateway 不匹配告警;#1732 uidModelcar 修 OCI modelcar 服务;tokenizer 镜像统一 vLLM v0.18.0 CPU

**notebooks(commits 7d,节选)**
- #4304/#4317 codeserver-baseline phase-1;jupyter/baseline 新建 + pandoc/EPEL 修复;#4331 base image 升 3.6-EA1-test;#4281 移除 kubeflow-training 依赖覆盖(3.6 EA1);#4342 agentic-reviewer 换本地 schema 工具

**model-registry(commits 7d,节选)**
- #3043 MCP server API serverJson 字段(上游 kubeflow);#3063 抽共享 catalog settings 基座;#3064 async-upload 传递可信 CA;#3054 回收崩溃 pod 的 catalog 领导锁;多次从 kubeflow/main 同步

**trustyai-service-operator(commits 7d)**
- #836 evalhub API SA 增加 hardware profile 权限;#853 依赖校验从 Service Mesh 切到 KServe InferenceService

**data-science-pipelines-operator**:窗口内无 commit

</details>
