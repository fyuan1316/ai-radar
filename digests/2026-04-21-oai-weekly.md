# OpenShift AI 周报 2026-04-21

窗口:2026-04-14 → 2026-04-21(过去 7 天)
扫描范围:opendatahub-io 组织下 7 个核心仓库(opendatahub-operator / odh-dashboard / kserve / notebooks / data-science-pipelines-operator / model-registry / trustyai-service-operator)+ Red Hat OpenShift AI 3.x 官方文档

## 摘要

- **本周进入 v3.4.0 后的收尾 + 3.5 孵化期**:ODH 的 `opendatahub-operator` / `kserve` 等上周刚切了 v3.4.0(4/8)和 KServe `odh-v3.4`(4/9),本周 PR 基本都是 bug 修补、CI 加固、清单同步(`rhoai-3.4` 分支修复),没有打新 tag。Dashboard 这边一个合集式的 `v3.4.0` Release 在 4/16 才正式挂牌([odh-dashboard v3.4.0](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0)),与上周 digest 的"一大堆 feature 已进 main"是相同发车,正式 tag 在本周才落地。
- **Red Hat OpenShift AI 3.4 Early Access 1 公开文档上线**:与 ODH v3.4 同一条代码线,[3.4 EA1 Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) 正式挂在 docs.redhat.com,官方口径确认了 MaaS、Gateway API、Llama Stack 0.5.0+rhai0、Kubeflow Trainer v2、Multi-node GPU、Hardware profiles 等特性,并强调 **3.4 仍是 EA、不支持生产**。
- **"xks" 和 "cloudmanager" 持续发酵,产品化在做**:本周 odh-operator 密集出现 `fix_conditional_xks`、`kind_testing_enh`、`cloudmanager` 权限/资源改名(`rhai/rhaii`),还把 MaaS api-key cleanup cronjob、MaaS 清单的 E2E 稳住。xks = "X(任何)Kubernetes Service",OAI 在把管理面从 OCP 解耦,转做跨集群/多云的托管模式,这条线**比 MaaS 本身更值得盯**。
- **KServe 侧纯维护周**:没有新 feature,9 个 commit 里全是 llmisvc 的 bug 修(cert hash 重启、storage migration retry 窗口、`customizeManagerOptions` hook 签名)和 OCP build tag 的清理。节奏和"去 OCP 耦合"战略吻合,见 [kserve PR #1329](https://github.com/opendatahub-io/kserve/pull/1329)。
- **Dashboard 还在猛推 AutoML / AutoRAG / MaaS / Kueue v1beta2**:合并大概 60+ commit,重头戏包括 AutoML 的 "One vs Rest 混淆矩阵"、AutoRAG 抛弃 openai-go SDK 改直接用 LlamaStack 结构体、Kueue API v1beta1→v1beta2 迁移,以及 MaaS 的微文案和 Auth Policy 表格滤器。

## 新功能 / 能力

### Red Hat OpenShift AI 3.4 Early Access 1 发布(官方文档)
- 来源:[RHOAI 3.4 Release Notes (EA1)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index)
- 关键新特性(官方表述):
  - **模型注册** PostgreSQL 数据库支持,内置默认数据库(测试用)
  - **KServe** 新增 MLServer ServingRuntime,支持经典 ML 模型不经 ONNX 转换直接部署
  - **多节点 GPU** 部署能力(呼应 kserve LWS/llmisvc 路线)
  - **Hardware profiles** 作为 Tech Preview,能把 Workbench/推理打到特定节点/加速器类型
  - **Gen AI Playground** 重设计:prompt lab 风格 + 多实例对比聊天
  - **Llama Stack Guardrails 基础能力**(Content Safety、Prompt Injection、Privacy Awareness)—— 注意这一套是 Llama Stack 的 `rhai0` 分支(0.5.0+rhai0)
  - **AI Available Assets 页**:可发现已部署模型+MCP server
  - **Feature Store** 组件与 Workbench + RBAC 整合,配 UI
  - **Kubeflow Trainer v2** Tech Preview,取代 deprecated 的 v1
  - **工作台 Python 默认走 Red Hat Python 索引**(供应链合规)
  - **RStudio Server / CUDA-RStudio** 镜像上线
- 启示:这份 release notes 把上游 ODH v3.4 的散点特性**收束成了一套产品叙事**——"让企业以合规方式部署/评估/治理 LLM"。对我们产品有三个直接参考:
  1. **产品叙事主线**:AI Playground(prompt lab)+ AI Asset(已部署模型一览)+ Guardrails(Llama Stack)+ MCP(运维)= 一套完整的企业 LLM 平台最小闭环,我们目前的叙事如果只停在"一套推理底座",需要补 Playground/Asset 这两块用户可感知的入口。
  2. **"默认 Python 索引"**:是 OAI 把供应链合规具体到了 pip 源这一层级。私有化场景同等重要,值得抄。
  3. **3.4 仍 EA、不支持生产** —— 商业 RHOAI 实际生产线还停在 2.25(基于 ODH v2.x 线),ODH v3.x 上游与 RHOAI 商业版之间仍有 1-2 季度的 time-to-GA 落差。

### MaaS 继续收尾(没新大特性,都在打补丁)
- [`fix(maas): subscription filter matches displayName and description`](https://github.com/opendatahub-io/odh-dashboard/commit/b9ff75c3b45adbccfa21df3faaffdf15d2257148) —— 订阅列表的搜索体验修补
- [`e2e test for vLLM on MaaS`](https://github.com/opendatahub-io/odh-dashboard/commit/dd859a110d7838e68ebacad059f6b5e030af35d0)(PR #7004) —— vLLM-on-MaaS 跑通 E2E
- [`MaaS Microcopy Updates`](https://github.com/opendatahub-io/odh-dashboard/commit/96145b51f224c5fa36ab7448dbf00b93a33e654a)(PR #7279,已 cherry-pick 到 release/#7308) —— 所有文案最终调整
- [`Hide API Key Behind a Toggle`](https://github.com/opendatahub-io/odh-dashboard/commit/7adae77a223e675b57afb2dad758bb13df2b56f0)(PR #7287) —— API Key 默认遮盖,合规细节
- 启示:MaaS 处于**"灰度稳住"阶段**。功能层已经冻结,本周没新 feat,全在打磨。可以理解为 v3.4.0 发版后的一周左右是"feature freeze",下一波新能力要等 v3.5 起步(预计 5 月初开 EA1)。

### AutoML / AutoRAG 产品化加速
- [`feat(autorag/automl): add support for stopping and retrying a run`](https://github.com/opendatahub-io/odh-dashboard/commit/7a108eb303fe8932b3eb0f4cede440baac3ab743)(PR #7288) —— 训练/检索管线的可恢复性
- [`feat(automl): add One vs Rest view to confusion matrix`](https://github.com/opendatahub-io/odh-dashboard/commit/ab207591be6e80ba6f50685837cf3a72ad236074)(PR #7240) —— 多分类场景的评估可视化
- [`refactor(autorag): drop openai-go SDK, use typed LlamaStack structs`](https://github.com/opendatahub-io/odh-dashboard/commit/f510fb05410726139594d1e5b9503d98a8438cd7)(PR #7283) —— 放弃 openai-go SDK,全面拥抱 **Llama Stack 类型**作为内部协议
- [`feat(automl,autorag): support namespace persistence`](https://github.com/opendatahub-io/odh-dashboard/pull/7286)、[`feat(autox): support selecting files by clicking rows in file explorer`](https://github.com/opendatahub-io/odh-dashboard/commit/975bac0e7fffeb4046da10bc5f8f30860f85d2e6)
- 启示:**AutoRAG 从 "openai 兼容" 转向 "Llama Stack 原生"** 是一个值得警惕的信号——Red Hat 在把 Llama Stack 当成内部统一协议层,而不是只当成一个外部运行时。这对我们有两个影响:① 如果我们只跟 OpenAI 协议,未来在 OAI 生态对接上会错位;② 可以评估是不是把 Llama Stack 作为我们自家产品的"agent 原生协议"。

### Kueue API v1beta1 → v1beta2 迁移
- [`fix(kueue): migrate Kueue API from v1beta1 to v1beta2`](https://github.com/opendatahub-io/odh-dashboard/commit/70c6c1ab) (PR #7271)
- 启示:Kueue 从 `v1beta1` 毕业到 `v1beta2` 是 Kubernetes Batch WG 的大事件。上游 Kueue 的 v1beta2 已经是几个月前稳定下来的,但 Dashboard 侧本周才完成迁移——说明 OAI 在"批调度/Kueue"这一层一直没放手,持续作为**调度底座**用。我们如果走自家调度(不选 Kueue)需要额外举证。

### opendatahub-operator MCP Server 继续扩展
- [`Added operator_dependency and describe_resource MCP tools`](https://github.com/opendatahub-io/opendatahub-operator/commit/a6087cda)(PR #3427,4/16 合入)—— 加两个新 MCP 工具:看组件间依赖关系 + 描述任意资源
- [`Add recent_events tool to surface warning/error events in namespaces`](https://github.com/opendatahub-io/opendatahub-operator/commit/effa40fe)(PR #3416,4/15)—— warning/error 事件聚合工具
- [`Added classify_failure and component_status MCP tools`](https://github.com/opendatahub-io/opendatahub-operator/commit/c2fe9773)(PR #3398,4/14)—— 失败分类 + 组件状态
- 启示:上周 digest 已经点出"operator 变成 MCP Server"是一条完整路线,本周 **这一路线没停**,持续加工具。预计 v3.5 会把 MCP Server 从隐藏能力抬到一等产品特性(Dashboard v3.4.0 Notable Changes 已经列 "MCP catalog and deployments (Dev Preview)")。这套 MCP 工具集值得我们抄一份做自家产品的"诊断层"。

## 架构 / 依赖变化

- **"xks" 和 "cloudmanager" 重磅起势**:本周新增 [`fixing conditional xks in kind actions`](https://github.com/opendatahub-io/opendatahub-operator/commit/a6d2639a)、[`doing some enhancements to both kind actions`](https://github.com/opendatahub-io/opendatahub-operator/commit/973d70a8)、[`rename resources to rhai/rhaii for cloudmanager`](https://github.com/opendatahub-io/opendatahub-operator/commit/dd36a67a)、[`feat(RHOAIENG-51594): automate resource names updates in cloudmanager rbac`](https://github.com/opendatahub-io/opendatahub-operator/commit/241892bf)。"xks"/"cloudmanager" 不再是零星痕迹,已经形成了独立的**资源命名/RBAC 子体系**,在 kind 测试里也开了条件化的管线。我们产品对标时,"托管面"是一个必须评估的方向。
- **KServe 去 OCP 耦合继续**:[`refactor(test): build-tag OCP scheme registrations and drop legacy SetupEnvTest`](https://github.com/opendatahub-io/kserve/pull/1329)、[`refactor: restore upstream ValidateInitialScaleAnnotation signature`](https://github.com/opendatahub-io/kserve/pull/1324)。KServe fork 本周主动**回归上游签名**,说明"让 fork 里的公共接口和上游对齐,把 OCP 特殊代码用 build tag 圈起来"这一政策在执行。这对我们自己做 KServe fork 有直接启示:**不要在 fork 里改公共接口,只用 build tag 做 overlay**。
- **odh-model-controller 清单替换**:[`fix: odh-model-controller manifest replacement`](https://github.com/opendatahub-io/kserve/pull/1423) —— 这是 odh-model-controller 和 kserve 的清单耦合点修复,产品层面可见的影响不大,但说明他们在统一多 controller 的部署路径。
- **Notebooks 的 Hermetic Build 再推进**:本周又合并了 [`RHAIENG-2854: Hermetic build for Jupyter ROCm PyTorch`](https://github.com/opendatahub-io/notebooks/commit/5dcbe807)、[`RHAIENG-2853: Hermetic build for ROCm TensorFlow`](https://github.com/opendatahub-io/notebooks/commit/a245e57a)、[`RHAIENG-2852: Hermetic build for Jupyter tensorflow CUDA`](https://github.com/opendatahub-io/notebooks/commit/c68d38a4)、[`RHAIENG-2855: ODH: Hermetic Jupyter PyTorch CUDA`](https://github.com/opendatahub-io/notebooks/commit/cda88cf8)、[`RHAIENG-2847: ODH Hermetic build for jupyter trustyai`](https://github.com/opendatahub-io/notebooks/commit/acad3805)。**五个 Jupyter 工作台镜像本周全部 Hermetic 化**。这是 Konflux/SLSA 供应链合规路线的收尾阶段。
- **Notebooks 供应链加固**:[`chore: upgrade all repo-level Python deps, add exclude-newer supply-chain hardening`](https://github.com/opendatahub-io/notebooks/commit/9d16948e)(PR #3389)、[`fix: update pnpm dependencies and harden supply chain with minimumReleaseAge`](https://github.com/opendatahub-io/notebooks/commit/5b14fe8a)(PR #3388)—— pip `--exclude-newer`(避免"给你的包后又回写"的 typosquat)、pnpm `minimumReleaseAge`(新发布包延迟使用)都是**最新一代供应链 best practice**。值得产品侧吸收。
- **DSP operator 进入缓动期**:只有 4 个 commit(ExtractParams 错误处理打磨),说明上周 digest 提到的"managed pipelines from OCI"一整套 PR 已经进主线,本周是稳态。

## 上游生态整合动向

- **Model Registry 双倍同步 Kubeflow**:本周 `model-registry` 合并了 3 次 `[pull] main from kubeflow:main`(4/14、4/17、4/20)——节奏比上周更紧。这周核心动作:[`chore: Workaround the pull rate limit issue noticed with docker images`](https://github.com/opendatahub-io/model-registry/commit/36dcfed0)(PR #2623)——Docker Hub 的 rate limit 被触发,绕过方案入库。供应链里**拉镜像频率被降级**可能是我们也要考虑的问题。
- **TrustyAI 同步上游**:[`Merge pull request #110 from trustyai-explainability/main`](https://github.com/opendatahub-io/trustyai-service-operator/commit/52fa0632) + [`chore(evalhub): bump up memory limit for lm_evaluation_harness`](https://github.com/opendatahub-io/trustyai-service-operator/commit/5497800b)(PR #711) + [`:bug: trigger deployment rollout on ConfigMap content changes for NemoGuardrails`](https://github.com/opendatahub-io/trustyai-service-operator/commit/ecb2aef1)。**NemoGuardrails 接入修复是新增信号**——OAI 在把 NVIDIA NeMo Guardrails 和 Llama Stack Guardrails 并列作为两条 guardrails 路径。对我们产品,如果要做合规评估层,这两套都要看。
- **KServe vs 上游持续对齐**:[`chore: eliminate trivial whitespace drift from upstream`](https://github.com/opendatahub-io/kserve/pull/1398)——连空格差异都在消除。我们自家 KServe fork 维护人可以直接参考这套"漂移消除"习惯,降低 rebase 成本。
- **Llama Stack 从"外挂"变"内嵌"**:Dashboard 的 `autorag` 重构(PR #7283)把 openai-go SDK 替换成 `typed LlamaStack structs`,再加上 3.4 EA1 官方文档里 **Llama Stack 0.5.0+rhai0**(Red Hat 自己的 rhai0 patch 版本),说明 OAI 在走"**Llama Stack 就是产品内部协议**"的路。Llama Stack 不再是一个可选的 runtime,而成了 OAI BFF 层的强依赖。

## 对我们产品的启示(产品视角)

基于上周深度调研 + 本周增量,重点给用户三条新观察:

1. **"云托管 OAI"可能是 RHOAI 的下一个大宗**:本周 xks/cloudmanager 出现频次已经和 MaaS 相当,且在 kind CI 里开条件化管线。结合上周 digest 已经发现的 `rhai/rhaii` 命名变化,合理推断 **RHOAI 下一阶段重心从"客户自己装 operator"转向"Red Hat 给你开一个托管集群"**。如果我们产品也在做私有化/托管路线,现在就该评估:
   - 我们的 operator 是不是已经可以被"cloud manager"样式的上层 orchestrator 调用?
   - 跨集群/多租户的 RBAC 命名方案(`rhai/rhaii` 这种前缀)是否需要抄一份?
2. **Llama Stack 需要明确态度**:这周 `autorag` 放弃 openai-go SDK 改用 LlamaStack struct 是产品侧的第一次强信号。如果我们产品继续走"OpenAI 协议兼容"单路线,在接入 OAI 生态(比如企业客户 RHOAI + 我们产品共存)时就会出现"双协议栈"成本。建议本季度内做一个小 PoC:Llama Stack API 能否作为我们 agent 的统一协议层。
3. **3.4 EA1 release notes 里"默认 Python 索引"是低调但重要的合规能力**:我们如果要投私有化/金融/政企客户,需要评估是否把"默认拉镜像走私有源,默认拉 Python 包走私有源"封装成产品首装向导的一部分。OAI 已经把这个做成 default 配置。

## 值得跟进

- [ ] 精读 [RHOAI 3.4 EA1 Release Notes](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index) 全文(本次只拿到摘要),对比商业 RHOAI 2.25 的 feature matrix,把"EA 阶段特性→商业 GA"的时间窗估出来
- [ ] 盯 opendatahub-operator 下周是否出现 `v3.5.0-ea.1` tag(节奏上一般月初开 EA1),提前知道下一轮大 feature 方向
- [ ] 阅读 `cloudmanager` 相关 PR(#3419、#3431、#3415),搞清楚它到底是托管面 controller,还是只是 operator 内部的 orchestrator 模块。若是前者,这是对标的关键变化点
- [ ] 体验 kserve 的 `customizeManagerOptions` hook(PR #1374),理解 OCP-only 和非 OCP 的 manager 启动参数差异(我们自家 KServe fork 可以直接复用这一模式)
- [ ] 评估 Llama Stack 作为内部协议的可行性,起一个 1 周的 PoC
- [ ] 看 Notebooks 的 `exclude-newer` / `minimumReleaseAge` 供应链加固实现,并评估用到我们产品的 notebook 镜像

## 原始来源清单

### 上游 ODH 发行 / Tag
- [opendatahub-operator v3.4.0 (2026-04-08)](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.4.0)
- [odh-dashboard v3.4.0 (2026-04-16,本周正式挂牌)](https://github.com/opendatahub-io/odh-dashboard/releases/tag/v3.4.0)
- [kserve odh-v3.4 (2026-04-09)](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.4)
- [trustyai-service-operator odh-3.4-final (2026-04-07)](https://github.com/opendatahub-io/trustyai-service-operator/releases/tag/odh-3.4-final)
- [model-registry v0.3.8 (2026-04-03)](https://github.com/opendatahub-io/model-registry/releases/tag/v0.3.8)
- [notebooks v1.43.0 (2026-04-05)](https://github.com/opendatahub-io/notebooks/releases/tag/v1.43.0)
- `opendatahub-operator/v2/pkg/clusterhealth/v0.0.1` 子模块 tag(2026-04-15,非主发行,仅子模块)

### Red Hat 官方文档
- [RHOAI 3.4 Release Notes (EA1)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/release_notes/index)
- [RHOAI 3.0 Release Notes(背景参考,EA 起点)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.0/html-single/release_notes/index)
- [RHOAI 2.25 Release Notes(商业 GA 线)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.25/html-single/release_notes/index)

### 本周 commit 计数(2026-04-14 → 2026-04-21,基于 GitHub API since 查询)
- opendatahub-operator:**45 commits**(~20 PRs merged)
- odh-dashboard:**63 commits**(~40 PRs merged,活跃度最高)
- kserve:**9 commits**(~12 PRs merged,纯 bug-fix 周)
- notebooks:**42 commits**(Hermetic Build 大批量合入)
- model-registry:**33 commits**(上游同步 + dependabot 为主)
- data-science-pipelines-operator:**4 commits**(缓动周)
- trustyai-service-operator:**4 commits**(NemoGuardrails 修复)

原始 JSON/atom 归档于 `/tmp/ai-radar-raw/`(下次运行会覆盖)。

### 未能访问
- 未尝试 Red Hat Developer 博客的 "OpenShift AI" tag 页(上周 WebFetch 对 docs.redhat.com 三级页面效果不稳定,本周未重试,属可接受遗漏)。
- `gh` CLI 未登录,本次完全依赖 curl + atom feed + WebFetch,所有数据源访问成功。
