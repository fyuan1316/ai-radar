# OpenShift AI 周报 2026-11-24

> 扫描窗口:2026-11-17 ~ 2026-11-24,源为 opendatahub-io 下 7 个主仓库(operator / dashboard / kserve / notebooks / DSP-operator / model-registry / trustyai)。窗口内 **7 个仓库均无新 release**,属于 3.6 GA 之后的修补 + 3.7 周期开工期,实质变化集中在少数几个 PR。
>
> 覆盖缺口:本 task 上期跑在 11-03,**11-04 ~ 11-16 未覆盖**,本期按 7 天口径未回溯。缺口期内已知的发版:opendatahub-operator [v3.6.0](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.6.0)(11-03 晚)、kserve [odh-v3.6](https://github.com/opendatahub-io/kserve/releases/tag/odh-v3.6)(11-03),上期只写到 dashboard v3.6.0。

## 摘要(3 条以内)

- **RHOAI 2.25 退役 llm-d 技术预览的部署能力**(RHAI-10213,只改 `stable-2.x` 分支):2.x 上已有的 LLMInferenceService 一律转为 unmanaged,webhook 拒绝新建和改 spec,只允许删除和改 metadata;**升级到 3.x 前必须删除所有 LLMInferenceService**。https://github.com/opendatahub-io/kserve/pull/2189
- **LLM 推理的安全管控继续收紧**:DSC 新增 `enableLLMMonitoringIngressNetworkPolicy` 开关,控制 LLMInferenceService 的严格 NetworkPolicy([operator#4275](https://github.com/opendatahub-io/opendatahub-operator/pull/4275));审计日志就绪状态按 InferenceService 和 LLMInferenceService 拆开上报,OCSF 策略要等 Kuadrant 回报 Accepted+Enforced 才算就绪([kserve#2195](https://github.com/opendatahub-io/kserve/pull/2195))。
- **Dashboard 往"多发行形态"走**:新增 RHAII/xKS 统一项目选择器,在用户没有列出 namespace 权限时可手动输入 namespace([#10709](https://github.com/opendatahub-io/odh-dashboard/pull/10709));llm-d UI 不再跟 KServe 功能开关绑定([#10688](https://github.com/opendatahub-io/odh-dashboard/pull/10688));部署向导在管理员没有设置时默认选 llm-d([#10758](https://github.com/opendatahub-io/odh-dashboard/pull/10758))。

## 新功能 / 能力

- [LLMInferenceService 严格 NetworkPolicy 开关上 DSC](https://github.com/opendatahub-io/opendatahub-operator/pull/4275) — 在 v3 DSC 的 `spec.components.kserve` 上新增可选布尔字段 `enableLLMMonitoringIngressNetworkPolicy`,默认关闭。它是上期 kserve [#2088](https://github.com/opendatahub-io/kserve/pull/2088)(把 Prometheus 抓取的 ingress NetworkPolicy 改成按需开启)缺的那一半:之前 operand 上有这个字段,但没有受支持的入口能打开它。v2 API 仍在提供服务,所以字段值存在一个转换专用注解里,防止通过 v2 写入时把开关冲掉(PR 里说真实集群上复现过这个问题)。
  - 启示:安全加固项默认关、平台 CR 上给一个开关,方便客户按合规要求逐个打开。另外,**多版本 CRD 下"v3 才有的字段被 v2 写入冲掉"是通用坑**,我们的 operator 如果同时提供多个 API 版本,应照这个 PR 补一条转换回写测试。

- [审计日志就绪状态拆分](https://github.com/opendatahub-io/kserve/pull/2195) — 原来的 `AuditLoggingReady` 会出现"ISVC 审计正常,但因为 LLMISVC 的 OCSF 依赖失败而整体报错"的情况。现在拆成 ISVC 和 LLMISVC 两组条件,LLM 侧再把 OCSF schema 支持和 TelemetryPolicy/Authorino 自定义字段支持分开报;托管的 OCSF 策略要等 Kuadrant 对当前 generation 回报 `Accepted=True` 且 `Enforced=True` 才算就绪。release note 标明 **Action required**:依赖旧条件的消费方要改用新条件。
  - 启示:OAI 的审计链路是 Kuadrant(TelemetryPolicy)+ Authorino 加 OCSF 格式,能力探测细到"CRD 是否支持某个字段"。我们做审计合规时,状态条件也应按"推理类型 × 能力"拆开,否则一项依赖缺失就会让整个审计状态误报失败。

- [DSPA 可配置流水线 PVC 的默认 StorageClass](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1144) — 新增 `spec.apiServer.pipelineTaskPVCDefaultStorageClass`,通过环境变量传到 API server 和 driver。生效优先级:流水线里写的值(包括显式写 `""` 表示不用默认)> DSPA 配置 > 集群默认。原来 KFP driver 硬编码 `standard`,在没有这个 StorageClass 的集群上会出错;上游修复见 kubeflow/pipelines [#15024](https://github.com/kubeflow/pipelines/pull/15024)。
  - 启示:我们如果集成了 KFP,也要检查是否受 `standard` 硬编码影响(国产化或私有云集群一般没有这个 StorageClass),可以直接跟进这个上游修复。

- Dashboard 本周的能力项(其余 40 多个 PR 是测试、OWNERS 和 CI 改动):
  - [RHAII/xKS 统一项目选择器](https://github.com/opendatahub-io/odh-dashboard/pull/10709) + [AI 项目过滤](https://github.com/opendatahub-io/odh-dashboard/pull/10780):list namespace 返回 403 时,判定为"无权列出",不当成空列表或故障处理;用户可以输入准确的 namespace 名,校验访问权限后加入选择器。选择器默认只显示 AI 项目。这个功能(UPS)默认关闭。Gen AI 页面也接入了 UPS([#10670](https://github.com/opendatahub-io/odh-dashboard/pull/10670))。
  - [EvalHub 不再直接访问 Kueue](https://github.com/opendatahub-io/odh-dashboard/pull/10660):BFF 改为调用 EvalHub 的 `/api/v1/info`,由它返回硬件 profile 和 LocalQueue 可用情况,并删除 BFF 直接读 Kueue/HardwareProfile 的代码和对应 RBAC(+3852/-4537)。
  - [社区插件管理页](https://github.com/opendatahub-io/odh-dashboard/pull/10756):仅管理员可见,页面明确写着"无支持、无 SLA",可以用 `disableCommunityPlugins` 隐藏。
  - 流水线 UI 为移除 MLMD 做准备:新增 KFP v2beta1 Task/Artifact API 的类型和封装([#10655](https://github.com/opendatahub-io/odh-dashboard/pull/10655),合入 `mlmd-removal` 分支)。
  - 启示:① 在"用户不能 list namespace"的托管 K8s 环境里,项目选择要能手动输入兜底,我们多租户控制台在受限 RBAC 下也会遇到同样问题;② EvalHub 把队列和硬件感知收到自己的服务里,前端不再直接碰 Kueue,这样做 RBAC 更少、边界更清楚,适合我们的评测模块参考。

## 架构 / 依赖变化

- [RHOAI 2.25:退役 llm-d 技术预览的部署能力,已有服务转为 unmanaged](https://github.com/opendatahub-io/kserve/pull/2189)(配套 operator [#4348](https://github.com/opendatahub-io/opendatahub-operator/pull/4348) / [#4349](https://github.com/opendatahub-io/opendatahub-operator/pull/4349))— 只改 `stable-2.x` 分支:
  - 沿用原有的 fail-closed webhook:拒绝 CREATE 和修改 spec 的 UPDATE,允许改 metadata、finalizer、status 以及删除;停止创建和调和子资源,readiness 标为 `Unknown / Unmanaged`;删除内置 preset 和 llm-d 镜像映射(scheduler、routing-sidecar、RHAIIS CUDA)。
  - 普通 InferenceService 不受影响。PR 给出的验证:从 RHOAI 2.25.13 直接 OLM 升级,9 个服务和 95 个子资源保留,9/9 个 CREATE 被拒,已有模型的外部端点仍返回 200。
  - **升级 3.x 前必须删除所有 LLMInferenceService**。#4349 还说明了一个坑:新 manifests 已经删掉 LLMI 权限,但旧版 model-controller 二进制还会启动 LLMI informer,informer 同步不了时 manager 会退出,同进程里的普通 serving 控制器也会跟着受影响,所以镜像 digest 必须和 manifests 一起升级。
  - 启示:这是 TP 功能退场的一个完整做法:不硬删、不中断流量,改成只读托管,再给出明确的升级前置条件。我们产品下线预览特性时可以照搬"webhook 冻结 spec + 状态标 Unmanaged + 只放行删除"这套机制。同时说明 OAI 的 llm-d/LLMISVC 在 2.x 是 TP,只在 3.x 线上继续演进,对标时应以 3.x 为准。
- [3.5→3.6 升级卡死修复:SSA 字段所有权迁移](https://github.com/opendatahub-io/opendatahub-operator/pull/4342) — 3.6 起 operand 改由 platform modules 控制器 apply(field owner 从 `datasciencecluster` 变成 `platform`)。旧 owner 留下的列表项不会释放,导致 dashboard-operator Deployment 出现两个同名 `metrics` 端口,之后每次 apply 都被拒,集群无法自愈。修复方法是用 `WithPreviousFieldOwners` 在第一次调和时把旧 owner 的字段转给新 owner。
  - 启示:**更换 SSA field manager 时必须迁移字段所有权**。我们的 operator 如果做过控制器拆分或重命名 field manager,应该检查升级路径上有没有同样的问题。
- [AI Hub catalog 镜像改走 RelatedImages](https://github.com/opendatahub-io/opendatahub-operator/pull/4301) — RHOAI 的 AI Hub catalog 数据镜像改为通过 CSV 的 RelatedImages 统一注入(配套 model-registry-operator [#782](https://github.com/opendatahub-io/model-registry-operator/pull/782)),以便离线环境做镜像同步。
- model-registry([#1959](https://github.com/opendatahub-io/model-registry/pull/1959))和 trustyai([#276](https://github.com/opendatahub-io/trustyai-service-operator/pull/276))本周都接入了 **API 契约兼容性检查**;其余是上游同步。
- notebooks:按 FIPS 要求,把 `uv` 从 CUDA/ROCm 版 Jupyter 和运行时镜像的最终镜像中删掉([#4953](https://github.com/opendatahub-io/notebooks/pull/4953)),原因是 uv 静态链接的 aws-lc 不是经认证的 FIPS 模块;其余是 CI 和依赖升级。

## 上游生态整合动向

- **KServe**:master 本周只有审计条件拆分([#2195](https://github.com/opendatahub-io/kserve/pull/2195))和 CVE 依赖升级([#2193](https://github.com/opendatahub-io/kserve/pull/2193)/[#2190](https://github.com/opendatahub-io/kserve/pull/2190)),此外新增了上游同步冲突处理规范文档([#2161](https://github.com/opendatahub-io/kserve/pull/2161))。主要动作在 stable-2.x 的 llm-d 退役。
- **llm-d**:3.x 线上 llm-d 正成为默认推理方式——dashboard 解除了与 KServe 开关的绑定,向导在没有设置时默认选 llm-d;2.x 线则退役 TP。方向和前几期一致:**LLMInferenceService + llm-d 是 OAI 3.x 的主推理路径**。
- **Kubeflow Pipelines**:DSPO 跟进 KFP 默认 StorageClass 修复;dashboard 开始对接 KFP v2beta1 Task/Artifact API,为移除 MLMD 做准备。
- **Kueue**:EvalHub 把 Kueue 访问收到服务端;dashboard 修复了名字相近的 Workbench 之间 Queued 状态互相串的问题([#10649](https://github.com/opendatahub-io/odh-dashboard/pull/10649))。
- **vLLM / Ray**:本周无直接依赖变更。

## 值得跟进

- [ ] 读 kserve [#2189](https://github.com/opendatahub-io/kserve/pull/2189) 的 webhook 和 reconcile 改动,整理成我们的"预览特性退役"设计模板(冻结 spec、Unmanaged 状态、放行删除、升级前置检查)。
- [ ] 检查自家 operator 的 SSA field manager 历史,参照 operator [#4342](https://github.com/opendatahub-io/opendatahub-operator/pull/4342) 确认升级路径上有没有残留的旧 owner 列表项。
- [ ] 确认我们集成的 KFP driver 是否仍硬编码 `standard` StorageClass,评估是否跟进 [DSPO #1144](https://github.com/opendatahub-io/data-science-pipelines-operator/pull/1144) 和上游 kubeflow/pipelines #15024。
- [ ] 对照 kserve [#2195](https://github.com/opendatahub-io/kserve/pull/2195) 的条件设计,检查我们审计/合规状态是否按推理类型和能力拆分。
- [ ] 补上 11-04~11-16 的缺口:读 opendatahub-operator [v3.6.0](https://github.com/opendatahub-io/opendatahub-operator/releases/tag/v3.6.0) 的 release note,核对它锁定的各组件版本。

## 原始材料

<details>
<summary>本次扫描清单(releases / merged PR)</summary>

**Releases(窗口内)**:无。各仓最新版本:operator v3.6.0(11-03)、dashboard v3.6.0(11-02)、kserve odh-v3.6(11-03)、model-registry v0.3.18(11-02)、notebooks v1.50.0(10-22)、trustyai odh-3.6-ea2(09-21)、DSPO v2.18.0(2025-11-11)

**默认分支 commit 数(11-17 起)/ merged PR 数**:dashboard 43/48、notebooks 17/12、DSPO 12/3、trustyai 10/3、operator 7/9、model-registry 3/2、kserve 2/5

**Red Hat 官方**:docs.redhat.com release notes 页返回 403,无法抓取;Red Hat Developer 博客 11-19~11-23 的最新约 10 篇里没有 OpenShift AI 相关文章(topic 页返回 404,只看了未按标签筛选的列表首页)。

**opendatahub-operator**:#4348/#4349 llm-d 退役(stable-2.x)、#4275 LLMI NetworkPolicy 开关、#4342 SSA 所有权迁移、#4301 AI Hub catalog RelatedImages、#4341 manifest-tools 自动同步 digest 默认值、#4260 Dashboard 显示上游链接与版本、#4325 manifest SHA 更新、#4353 jira 组件映射

**kserve**:#2189 llm-d 退役(stable-2.x)、#2195 审计条件拆分、#2193/#2190 CVE、#2161 上游同步冲突规范

**odh-dashboard**:#10709/#10780 RHAII/xKS UPS、#10670 GenAI 接入 UPS、#10688 llm-d 与 KServe 开关解耦、#10758 llm-d 默认选中、#10660 EvalHub info API、#10756 社区插件页、#10655 KFP v2beta1 类型、#10649 Kueue 状态串扰修复、#10689 加速器自动选择放宽、#10834 部署 Pod 事件/日志、#10553 AutoML 时序最佳质量预设、#10537 AutoRAG PGVector e2e、#10744/#10774 MaaS Portal 组名显示组织名、#10785/#10793 data-registry 403 回退;其余为 OWNERS / fullsend / Cypress / CI

**DSPO**:#1144 默认 StorageClass、#1149 CI、#1150 OWNERS
**model-registry**:#1959 API 契约检查、#1958 同步 kubeflow/hub
**trustyai**:#276 API 契约检查、#279/#281 上游同步
**notebooks**:#4953 移除 uv(FIPS)、#4956 main→stable 同步计划、FullSend 接入与 actions 升级

</details>
