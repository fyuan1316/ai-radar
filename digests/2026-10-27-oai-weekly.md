# OpenShift AI 周报 2026-10-27

> 扫描窗口:2026-10-20 → 2026-10-27。源:opendatahub-io 7 个核心仓库(operator/dashboard/kserve/notebooks/DSPO/model-registry/trustyai)+ Red Hat 官方。
> 本周无新 release 里程碑(operator/dashboard/kserve/trustyai 仍停在 9 月的 v3.6.0-ea.2;notebooks 发了 v1.50.0 但内容基本是 CI/安全日常);实质动作全在 main 分支的功能提交里。

## 摘要(3 条)

- **AI Gateway / LLM Gateway 正在被产品化成一等模块**:operator 侧给 AI Gateway 模块接入发布版 kube-auth-proxy 镜像、为 `GatewayConfig.spec.additionalIngresses` 加准入校验与鉴权基建(RHAISTRAT-2272);dashboard 侧把 "LLM gateway" 字段默认打开、MaaS(Models-as-a-Service)门户收敛导航。这是 OAI 把"模型即服务 + 统一入口鉴权"做成平台能力的明确信号。
- **集群级 TLS 合规被拉成跨组件硬要求**:kserve 让 kube-rbac-proxy sidecar 跟随 OpenShift 集群 TLS profile(watch APIServer 策略→requeue ISVC→改 min 版本/cipher/curve,RHOAIENG-95581),DSPO 把同一套下发到流水线 sidecar,trustyai 在 kube-rbac-proxy 默认曲线里加了后量子 **X25519MLKEM768** 并对不可用 profile 做 fail-closed。企业安全合规(含后量子)在整条产品线同步收口。
- **Gen AI "工作室"持续加厚**:dashboard 本周 EvalHub(模型评测,进 Technology Preview + GA 遥测)、AutoRAG(加音频)、AutoML/AutoX(自动实验选优)、Gen AI playground(接 MLflow tracing)全在推进。OAI 正在把"评测—RAG—自动调优—在线试验"做成端到端 GenAI 开发面。

## 新功能 / 能力

### AI Gateway / MaaS(本周最大主线)
- [feat(aigateway): 给 AI Gateway 模块传发布版 kube-auth-proxy 镜像](https://github.com/opendatahub-io/opendatahub-operator/pull/4250) — ai-gateway-controller 用发布镜像部署"消费者门户"鉴权代理,而非上游 fallback。
- [feat(gateway): 为 additionalIngresses 加准入校验](https://github.com/opendatahub-io/opendatahub-operator/pull/4255) 配套 [额外 ingress 鉴权基建 #4221](https://github.com/opendatahub-io/opendatahub-operator/pull/4221) 与 [ingress 准入校验 #4255](https://github.com/opendatahub-io/opendatahub-operator/pull/4255) — 按 RHAISTRAT-2272 策略做多入口的生命周期/mutation/幂等校验。
- [feat: dashboard 默认启用 LLM gateway 字段](https://github.com/opendatahub-io/odh-dashboard/pull/10399)(RHOAIENG-96895)+ [fix(maas-portal): 隐藏 playground 导航](https://github.com/opendatahub-io/odh-dashboard/pull/10381) — 前端把 LLM 网关从隐藏开关转正。
  - 启示:OAI 的 AI Gateway = "统一 LLM 入口 + 消费者门户 + 鉴权代理(kube-auth-proxy)+ 多 ingress 准入",本质是把 MaaS 的租户接入与配额/鉴权收进平台层。我们若也做模型服务对外暴露,要对标它这套"网关 CRD(GatewayConfig)+ 准入校验 + 门户鉴权"的组合,而不是只做一个反代。

### Gen AI 工作室(dashboard)
- [feat(evalhub): 落地页加 Technology Preview 提示](https://github.com/opendatahub-io/odh-dashboard/pull/10377) + [GA 就绪遥测 #9944](https://github.com/opendatahub-io/odh-dashboard/pull/9944) + [按 collection 类别自动过滤 benchmark #10360](https://github.com/opendatahub-io/odh-dashboard/pull/10360) — 模型评测中心进 TP、铺 GA 前的埋点。
- [feat(autorag): 内容支持音频](https://github.com/opendatahub-io/odh-dashboard/pull/10276);[feat(autox): 流水线运行禁用 MLflow 集成 #10341](https://github.com/opendatahub-io/odh-dashboard/pull/10341) + [修正 winner 逻辑 #10338](https://github.com/opendatahub-io/odh-dashboard/pull/10338) — AutoRAG 扩模态、AutoX 自动实验选优成形。
- [fix(gen-ai): playground 接 MLflow experiment / collector 做 tracing](https://github.com/opendatahub-io/odh-dashboard/pull/10403) — playground 的调用链可观测。
  - 启示:EvalHub 从 TP 往 GA 走、AutoML/AutoX/AutoRAG 同步推进,说明 OAI 把"评测与自动调优"当作差异化重点而非附属。我们产品里若评测仍是人工脚本,这块会成明显短板;建议近期评估一个内置评测+基准库(benchmark collection)的 MVP。

### 模型 / 数据注册
- [feat(model-registry): dashboard 加 quality insights 标签页](https://github.com/opendatahub-io/odh-dashboard/pull/10229);[feat(RHOAIENG-100845): 给 catalog 安装的 runtime 加 provenance 注解](https://github.com/opendatahub-io/odh-dashboard/pull/10402)。
- model-registry 后端一批 catalog 修复:[Hugging Face cardData 直接解码 #3267](https://github.com/opendatahub-io/model-registry/pull/3267)、[syncInterval 非正值回退默认 #3352](https://github.com/opendatahub-io/model-registry/pull/3352)、[>50 个取值仍保留数组筛选项 #3361](https://github.com/opendatahub-io/model-registry/pull/3361) — Hugging Face 模型目录同步在打磨。
- [feat(feastoperator): 投影能力并 pin 模块 manifest](https://github.com/opendatahub-io/opendatahub-operator/pull/4232) + [dashboard netpol 放行到 Feast registry REST #10367](https://github.com/opendatahub-io/odh-dashboard/pull/10367) — Feast 特征库纳入平台能力投影。
  - 启示:provenance 注解 + quality insights 说明 OAI 在往"模型/runtime 来源可追溯 + 质量画像"靠拢,这是企业治理卖点。可直接借鉴 catalog→runtime 的 provenance 注解做法。

## 架构 / 依赖变化

- **集群 TLS profile 下沉为跨组件基线**:[kserve RHOAIENG-95581 强制工作负载走集群 TLS profile](https://github.com/opendatahub-io/kserve/pull/2099)(watch APIServer→requeue ISVC→改 proxy 的 minVersion/cipher/curve,保留用户自定义参数)、[honor runtime cluster cipher profiles #2129](https://github.com/opendatahub-io/kserve/pull/2129);DSPO 把同套逻辑抽到 `controllers/util` 并下发到 kube-rbac-proxy sidecar(commit `refactor(tls)` / `feat: apply OpenShift TLS profile to kube-rbac-proxy sidecars`);[trustyai 在默认曲线里加后量子 X25519MLKEM768 #1056](https://github.com/opendatahub-io/trustyai-service-operator/pull/1056) + [对不可用 profile fail-closed #1045](https://github.com/opendatahub-io/trustyai-service-operator/pull/1045)。
  - 启示:这是"一次改集群 TLS profile,全平台 sidecar 自动跟随"的架构,且已把后量子 TLS 纳入默认。做政企/合规市场的话,"集群级密码策略单点下发 + 后量子就绪"是可直接对标的硬指标。
- **零信任网络策略铺开**:DSPO 给流水线 operand 加出站 NetworkPolicy 并堵未受限 ingress(`feat(networkpolicy): add outbound NetworkPolicies ...`、`test: guard against unrestricted ingress on direct API ports 8888/8887`);dashboard 给 controller-pod metrics 加 NetworkPolicy([#10285](https://github.com/opendatahub-io/odh-dashboard/pull/10285))、放行到 Feast registry 的 egress([#10367](https://github.com/opendatahub-io/odh-dashboard/pull/10367))。
- [fix(dashboard-operator): 把 OdhDashboardConfig 的 watch 收到独立 cache](https://github.com/opendatahub-io/odh-dashboard/pull/10324) — 减少全局 informer 压力。
- [feat: 分布式工作负载页加弃用横幅](https://github.com/opendatahub-io/odh-dashboard/pull/10417) — "Distributed Workloads" 页面进入弃用流程,功能很可能并入 Kueue/训练新入口,值得盯其替代路径。

## 上游生态整合动向

- **KServe(llmisvc / 分离式推理)**:[fix(llmisvc): 更新时保留 DisaggregatedSet 控制器注解 #6428](https://github.com/kserve/kserve/pull/6428)(经 upstream→odh 同步)+ odh 侧 `fix(odh): wire multi-port preset images` — LLMInferenceService 的 prefill/decode 分离(DisaggregatedSet)+ 多端口预设镜像在成形。
  - 启示:KServe 的分离式 LLM 服务(disaggregated prefill/decode)正从实验走向控制器稳定化,这是大模型高吞吐部署的关键能力,建议跟 upstream `llmisvc` 控制器的 DisaggregatedSet 设计。
- **KServe 安全/同步**:本周两次 upstream→odh master 同步(`sync upstream/master`,含 storage initializer IRSA 传播、PyJWT 安全下限);[bump golang.org/x/crypto v0.55.0 (RHAI-5361) #2126](https://github.com/opendatahub-io/kserve/pull/2126)。
- **Kueue / Ray**:operator 侧 [Kueue operator channel 在 e2e 可配置(RHOAIENG-89733) #4257](https://github.com/opendatahub-io/opendatahub-operator/pull/4257)、[更新 KubeRay 与 Ray 模块 operator values(RHOAIENG-101130) #4237](https://github.com/opendatahub-io/opendatahub-operator/pull/4237);dashboard [不可达 Ray 集群用 disabled 链接 #10419](https://github.com/opendatahub-io/odh-dashboard/pull/10419)。
- **Workbench 镜像**:[notebooks v1.50.0](https://github.com/opendatahub-io/notebooks/releases/tag/v1.50.0)(以 CI/安全/锁文件为主)+ operator [新增 Code Server Minimal related image #4249](https://github.com/opendatahub-io/opendatahub-operator/pull/4249);[清理 vllm-omni-cuda / 移除弃用 ODH vLLM CPU 镜像条目 #4235](https://github.com/opendatahub-io/opendatahub-operator/pull/4235)。

## 值得跟进

- [ ] 读 [opendatahub-operator#4255](https://github.com/opendatahub-io/opendatahub-operator/pull/4255) 与 [#4221](https://github.com/opendatahub-io/opendatahub-operator/pull/4221),摸清 `GatewayConfig` CRD 的字段形状(additionalIngresses + 消费者门户鉴权),评估我们网关能力的差距。
- [ ] 跟 [kserve#2099](https://github.com/opendatahub-io/kserve/pull/2099) 的"集群 TLS profile 单点下发到所有 sidecar"实现,判断我们是否要做等价的集群级密码策略联动(含后量子曲线)。
- [ ] 跟 upstream [kserve#6428](https://github.com/kserve/kserve/pull/6428) 的 DisaggregatedSet / 多端口预设,评估分离式 LLM 推理在我们平台的落地路径。
- [ ] 看 dashboard EvalHub 相关 PR(#10377/#9944/#10360),评估内置模型评测 + benchmark collection 的最小可行版本。
- [ ] 关注 dashboard [分布式工作负载弃用横幅 #10417](https://github.com/opendatahub-io/odh-dashboard/pull/10417) 后续的替代入口(Kueue/训练),避免我们迁移路线踩同样的弃用。

## 原始材料

<details>
<summary>本周扫描清单(2026-10-20 → 2026-10-27)</summary>

**commit 量(main,7 天)**:operator 19 / dashboard 96 / kserve 16 / notebooks 100 / DSPO 8 / model-registry 16 / trustyai 16。

**releases**:仅 notebooks v1.50.0(2026-10-22,CI/安全日常);其余仓库最新 release 均停在 9 月的 v3.6.0-ea.2 / odh-v3.6-ea2 等,窗口内无新 tag。

**operator 要点 PR**:#4250 (aigateway kube-auth-proxy)、#4255/#4247/#4252/#4221 (gateway ingress 校验与鉴权)、#4249 (Code Server Minimal 镜像)、#4232 (feastoperator 能力投影)、#4237 (KubeRay/Ray values)、#4257 (Kueue channel 可配)、#4235 (移除弃用 vLLM CPU 镜像)。

**dashboard 要点 PR**:#10399 (LLM gateway 默认开)、#10381 (maas-portal)、#10377/#9944/#10360 (EvalHub TP/GA)、#10276 (AutoRAG 音频)、#10341/#10338 (AutoX)、#10403 (playground MLflow tracing)、#10229 (model-registry quality insights)、#10402 (runtime provenance 注解)、#10285/#10367 (NetworkPolicy)、#10324 (dashboard-operator cache)、#10417 (分布式工作负载弃用横幅)。

**kserve 要点 PR**:#2099 (RHOAIENG-95581 集群 TLS profile)、#2129 (runtime cipher profile)、#2126 (x/crypto bump)、upstream #6428 (llmisvc DisaggregatedSet)、`fix(odh): wire multi-port preset images`;2 次 upstream→odh master 同步。

**DSPO 要点**:`feat(networkpolicy)` 出站策略、`feat: apply OpenShift TLS profile to kube-rbac-proxy sidecars`、`refactor(tls)`、`guard against unrestricted ingress on 8888/8887`。

**model-registry 要点 PR**:#3267 (HF cardData)、#3352 (HF syncInterval 回退)、#3361 (数组筛选项)、#3348/#3353 (OCI base image 解耦)。

**trustyai 要点 PR**:#1056 (X25519MLKEM768 后量子曲线)、#1045 (TLS fail-closed)、#1048 (TAS ConfigMap 数据库调优)、#1053 (evalhub NetworkPolicy)。

**Red Hat 官方**:developers.redhat.com 产品页本周无带日期的新文章;OpenShift AI 正式 release notes 无 v3.6 窗口内更新(仍 EA 阶段)。

</details>
