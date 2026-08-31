# OpenFuyao 周报 2026-08-31

> 扫描窗口:2026-08-24 ~ 2026-08-31。主仓 GitCode `openFuyao` 组织 + 昇腾 upstream `ascend/mind-cluster` + 官方 CSDN。非发版周(v26.06 已于 07.09 发布,下一季度版待定),但信息量足:①昇腾集群栈本周主线新增 **DPU 维度**(数据面卸载卡进场);②AI 推理栈的 KVCache 路由持续往上游 GIE/KServe **收敛并调优**(减 kserve 自定义 patch);③Agent 沙箱**正式立 SIG** + flux-sandbox 工程化收尾;④`compliance-operator` 新增 CIS/STIG hardening,直接对标 OpenShift Compliance Operator。正常出报并推送。

## 摘要(3 条以内)
- **昇腾集群栈本周主线转向 DPU(数据处理单元)**:`ascend/mind-cluster` 一周密集提交 `dpu-exporter`(支持 1825 芯片 1825 指标采集 part1~3 + UT + 白名单)、`dpu-dp`(把 RDMA 资源名写进节点 annotation、故障上报新增 `AffectedNPU` 字段、npu-nic-mapping.json 入构建产物)、以及 **DPU 触发断点续训**(ascend-for-volcano 部分代码 + clusterD 聚合 dpu-dp 的 configmap)。上周是 A5(950)全栈铺开,本周叠加 DPU 数据面卸载——**纯昇腾/超节点专用**,作硬件节奏信号,与我们无直接借鉴。
- **AI 推理栈 KVCache 路由往上游 GIE/KServe 收敛 + 精度调优**:`hermes-router` + `InferNex` 本周一串通用改动——KV-aware picker **对齐 score 语义**(!229/InferNex)、**只统计完整 cache block**(!87/hermes)、**解决与 GIE 的 plugin 类型冲突**(!86)、暴露 `cacheIndexer.blockSize` 配置、**drop kserve scheduler config webhook patch**(!224,减少对 kserve 的自定义 patch)、tokenizer 冷启动改 **socket wait 单飞初始化**替代指数退避(!83)、以及**分布式 tracing traceparent 传播**(!218)。这是与我们最直接对标、且**通用可借鉴**的部分。
- **Agent 沙箱正式立 SIG + 工程化收尾;企业合规能力补齐**:官方 08-25 发文成立 **Agent Sandbox SIG**(K8s 上 MicroVM 级高安全隔离),`flux-sandbox` 从上周的 pause/resume/snapshot 主线转入工程化(Helm chart、dockerfile 重构、经 K8s Service 而非 NODE_IP 访问 E2B API、SandboxGroup 支持污点定向调度)。同期 `compliance-operator` 新增 **CIS/STIG hardening + 回滚工具**(!11),形态直接对标 OpenShift Compliance Operator。

## 新功能 / 能力

- [compliance-operator:新增 K8s CIS/STIG hardening + 回滚工具](https://gitcode.com/openFuyao/compliance-operator) — 本周 !11 `feat(compliance-hardening): add k8s CIS/STIG hardening and rollback tool`。该 Operator 双引擎(kube-bench 跑 CIS Benchmark、OpenSCAP 跑 DISA STIG),支持按 control-plane/worker/all 分目标、Cron 定时扫描;本周从"只扫描"进化到"**扫描→加固→可回滚**"闭环。
  - 启示:**这是本周对标价值最高的一条**。它几乎是 **OpenShift Compliance Operator 的 1:1 对位**(OpenShift 用 OpenSCAP + ComplianceScan/ComplianceRemediation CR 做 CIS/STIG 扫描与自动 remediation)。我们做对标 OAI 的产品,企业级安全合规(CIS/STIG 扫描 + 一键加固 + 回滚)是**多租户/等保场景的刚需件**。OpenFuyao 选了和 OpenShift 同源的 kube-bench + OpenSCAP 技术栈,说明这条路是行业公认解。建议对照我们产品的合规能力做 gap 分析:**是否有自动 remediation + rollback**,而不只是扫描报告。**通用能力。**

- [ascend/mind-cluster:昇腾集群栈引入 DPU 维度](https://gitcode.com/ascend/mind-cluster) — 本周 DPU 相关约 10+ MR:`dpu-exporter` 支持 1825 芯片指标采集(part1~3)+ 全局默认白名单 + UT;`dpu-dp`(DPU device plugin)将 RDMA 资源名加入节点 annotation、故障上报新增 `AffectedNPU`、把 `npu-nic-mapping.json` 加入构建产物;**DPU 支持触发断点续训**(ascend-for-volcano 基础代码 + clusterD 聚合 dpu-dp 的 cm)。另有 `k8s-rdma-shared-dev-plugin` 镜像 dockerfile 修正、`host device cni 原生版本`。
  - 启示:**纯昇腾/超节点专用,对我们无直接借鉴**,但信号明确:昇腾把 **DPU 作为独立可观测 + 可调度 + 可触发容错的一等资源**纳入集群栈(DPU 故障也能触发断点续训,说明训练容错的"故障域"从 NPU 扩展到网络/数据面)。这是"超节点(灵衢)整机柜化"的配套——DPU 承担 RDMA/存储卸载。作为判断昇腾大规模训练集群成熟度的节奏信号即可。

- [cluster-api-provider-bke:HelmInstaller 组件安装引擎 + master 保护 webhook](https://gitcode.com/openFuyao/cluster-api-provider-bke) — 本周 !471 `HelmInstaller 核心引擎 + HelmComponentExecutor + CRD Helm 扩展`(把"给纳管集群装生态组件"做成 Helm 驱动的可执行引擎)、!472 `webhook to block master node deletion and scale-up`(webhook 阻止误删/误扩 master)、!475 least-privilege bkeagent RBAC + controller-owned command finalizers、!473 KubeletConfig 文件下发。
  - 启示:BKECluster(基于 Cluster API 的集群纳管 provider)本周把**组件部署从脚本式升级为 Helm-as-CRD 引擎**——这与 OpenShift 的 Operator/OLM、或 Cluster API + addon provider 是同一方向(声明式装 addon)。**通用可借鉴**:如果我们的集群生命周期管理里生态组件仍是脚本/kustomize 硬编码,这种"CRD 里声明 Helm component、由 executor 幂等安装"的模型值得参考。master 保护 webhook 是很实的运维护栏。

- [npu-dra-plugin:NPU 拓扑亲和属性上报 + README 明确三种切分模式](https://gitcode.com/openFuyao/npu-dra-plugin) — 本周 !41 `feat: 支持NPU拓扑亲和属性上报`(把 NPU 拓扑作为 DRA device attribute 上报,供调度器做拓扑亲和),!43/!44 大改 README:明确 **整卡 / 硬切分(aiCore+aiCPU 模板,硬件级隔离)/ 软切分(vCANN-RT 劫持库,memCapacity+coreCapacity 弹性配额,支持 elastic/fixed-share/best-effort 三策略)** 三模式,并暴露 NUMA 亲和、HCCS 环网拓扑、芯片型号、PCIe 作为 CEL 调度约束;要求 K8s v1.34+(`DynamicResourceAllocation`+`DRAConsumableCapacity` 特性门控)。
  - 启示:**与我们 DRA 选型强相关**。上周的"双实现"疑问本周有进一步信号:**`openFuyao/npu-dra-plugin` 是承载 vNPU 切分语义的 DRA driver**(软/硬/整卡三模式 + vCANN-RT 软切分),本周只在做拓扑亲和上报 + 文档收敛;而 `ascend/mind-cluster` 侧的 `ascend-dra-driver` 本周仅是 **UT 补充(part1~4)**,无新特性。倾向判断:**npu-dra-plugin = 面向 vNPU 细粒度切分/共享的 DRA 主线**。其 `DRAConsumableCapacity`(K8s 1.34 的可消费容量 DRA 扩展)+ CEL + HCCS 拓扑约束的组合,与 NVIDIA/Intel DRA driver 架构一致,**通用可比**;我们做 DRA 选型可重点参考它对"软切分弹性配额"的建模。

- [flux-sandbox:Agent 沙箱工程化收尾(Helm/Service/污点定向调度)](https://gitcode.com/openFuyao/flux-sandbox) — 上周合入 pause/resume/snapshot 主线后,本周转工程化:!32 Helm chart 部署、!29 dockerfile 重构、!26 **经 K8s Service 访问 E2B API 而非 NODE_IP**(去掉宿主机 IP 硬依赖)、!27 **SandboxGroup 支持指定 agent pod 的节点调度约束(污点定向)**、!25 go 降到 1.25 + etcd client 降级。
  - 启示:**通用 + 潜在竞争**。承接上周判断——OpenFuyao 的 Agent 沙箱已从能力堆叠进入"可产品化部署"阶段(Helm 一键装 + Service 化解耦 + 调度约束)。污点定向调度是把沙箱这类"不可信/隔离 workload"钉到专用节点池的实操手段,我们若做 Agent/沙箱隔离可直接抄这个模型。

- [openfuyao-powers:avatar-agent 支持 defect-fixer squad 的权限隔离](https://gitcode.com/openFuyao/openfuyao-powers) — 本周 !57 `refactor(multica): introduce avatar-agent to support permission isolation in defect fixer squad`、workspace config-as-code snapshot + sync 脚本(!53)、新增 pipeline-issue-reviewer / pipeline-pr-gate-diagnoser / e2e-issue-retest / e2e test regression 等 skill,并把配置改为 opencode.jsonc。
  - 启示:社区把研发自动化从"单 skill"推进到"**多 Agent 协作(squad)+ 每个 Agent 权限隔离(avatar-agent)**"。这正是我们若在产品里引入 Agent 化运维时最该关注的治理点:**多 Agent 协作时如何做最小权限隔离**(每个 avatar 只拿它该有的权限,而非共享一把大权限)。config-as-code snapshot 也是把 Agent 工作区配置纳入版本化的实操。**通用能力。**

## AI 推理栈(InferNex / hermes-router / Mooncake)

本周推理栈是**除 DPU 外最活跃的一块**,主题是 **KVCache 路由精度调优 + 向上游 GIE/KServe 收敛**:

- **KV-aware 路由精度**:`InferNex` !229 `align KV-aware picker with score semantics`(让 KV-aware picker 的打分与 score 语义一致)、`hermes-router` !87 `count only complete cache blocks`(只统计**完整**的 cache block,不把半块也算进命中)。→ 这两条都是路由命中率/打分**正确性**的修正,说明 KVCache-aware 路由已进入精调阶段。
- **与上游 GIE 兼容**:`hermes-router` !86 `resolve plugin type conflicts with GIE`(解决与 Gateway API Inference Extension 的 plugin 类型冲突)。→ 印证架构定性:hermes-router 建在上游 **GIE** 上,本周在做与 GIE 插件体系的类型对齐。
- **减少对 KServe 的自定义 patch**:`InferNex` !224 `drop kserve scheduler config webhook patch`、!226 `align hermes-router tokenizer overlay with sidecar defaults`、hermes !81 `对齐 kserve scheduler preset`。→ **方向性信号:它们在删掉对 kserve 的私有 webhook patch、往 kserve 官方 preset 对齐**,即从"fork/patch kserve"往"用上游默认 + overlay"收敛,降低上游跟随成本。
- **tokenizer 冷启动**:hermes !83 用 **socket wait + 长 Initialize 单飞**替换上周(08-14)的有界指数退避——原短超时退避会在 transformers 首次 lazy import 时把 gRPC 掐断,现改为先等 UDS 就绪、再一枪覆盖冷启动 initTimeout(默认 2m),sidecar 用锁单飞、同 key 成功短路。→ Serverless 推理冷启动的经典坑,解法通用。
- **可观测**:InferNex !218 `propagate traceparent header for distributed tracing` + !221 `remove eagle-eye top-level condition to support independent tracing control`(eagle-eye 分布式追踪可独立开关)、!228 过滤 /health /metrics 访问日志。→ 分布式 tracing 用 **W3C traceparent** 标准头贯穿网关→引擎,通用做法。

架构定性不变(据 26-06 README):hermes-router 建在上游 GIE 上、与 llm-d/kgateway 同源;cache-indexer 前缀树 KV-aware ≈ llm-d;PD-Orchestrator + APA 弹性 ≈ Dynamo/llm-d。**本周的增量是"更贴上游、更精调",而非架构变动**。路由/索引/弹性/tracing 通用可借鉴;传输(HCCL)、UB 网络指标、后端(vLLM-Ascend)昇腾绑定。`mooncake`(仓)本周无实质提交。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **DPU 进场(见"新功能")** 是 mind-cluster 本周主线:dpu-exporter/dpu-dp/DPU 断点续训。
- **npu-exporter**:`A2/A3 支持 vnpu 指标`(!4289)——把 vNPU 粒度的指标采集补到 A2/A3 代芯片。
- **DRA**:`ascend/mind-cluster` 侧 `ascend-dra-driver` 本周仅 **UT 补充**(part1~4,补 /device、/driver 的 ut),无新特性;新特性落在 `openFuyao/npu-dra-plugin`(拓扑亲和上报,见"新功能")。**倾向:npu-dra-plugin 是 vNPU 切分 DRA 主线,mind-cluster ascend-dra-driver 本周处于测试补强期。**
- **CDI**:mind-cluster 本周 `feat(cdi): add unified mount Build entrypoint and MountConfig`、`add legacy list-mode mount reader`、`add mount config types and JSON profile`、`add mount filesystem helpers(glob/symlink owner)`——把设备挂载重构成**统一 MountConfig(JSON profile)+ 兼容 legacy list-mode** 的模型,是上周 CDI 合入后的架构化收尾。与 NVIDIA container toolkit CDI 同路,通用。
- **container-manager**:`支持 A5 热复位`(A5 代设备故障热复位)。
- **coordinator**:`新增容器协调服务的 protobuf 定义和生成代码`——新出现的"容器协调服务",值得下周观察其定位。
- **noded**:`ipmi 监控支持故障自愈`(!4493)——带外 IPMI 监控 + 自愈。
- **npu-operator**:本周窗口内**无提交**(最新 08-18),跳过。上周的 vnpu/mindcluster volcano 切换主题本周无进展。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- **volcano(mind-cluster 内)**:`修复重调度 grace 删除场景下的 pod 数据竞争问题`(!4477)——重调度并发正确性修复;`ascend-for-volcano 组件旁路 dra 任务`(!4478 区)——让 ascend-for-volcano **对 DRA 任务放行/旁路**(DRA 任务不走它的老调度路径),是 DRA 与既有 Volcano 扩展并存的适配;`新增 dpu 故障触发基础断点续训 volcano 部分代码`。
- **节点标签**:mind-cluster `节点标签统一规范与自动标识`(pr1~3)+ `dp 自动打标签`系列修复——设备自动打标签的规范化。
- **cluster-api-provider-bke**:HelmInstaller 引擎 + master 保护(见"新功能"),另有 `consolidate cluster status fields into single source of truth`(集群状态字段收敛为单一来源)、bkeagent RBAC 最小化。
- `volcano-ext`(独立仓,最新 2024-09)、`kae-operator`(最新 05-26)、`colocation-website`(在离线混部前端)、`kubevirt` 窗口内**无提交**;`ub-network-device-plugin` 仅 1 笔权限修复(!57 honor provided path)。**在离线混部本周无实质进展。**

## 官方动态

- **[CSDN(08-25):Agent Sandbox SIG 开发者集结——基于 Kubernetes 的高安全 MicroVM 级隔离环境](https://blog.csdn.net/openFuyao)**:官方发文**正式成立 Agent Sandbox SIG**,主题是在 K8s 上构建 MicroVM 级(Firecracker)高安全隔离沙箱。这与代码侧 `flux-sandbox` 的推进对应——沙箱从项目升格为 **SIG 级方向**,说明 OpenFuyao 把"Agent 运行时隔离"当作战略方向在投入。剥离宣传话术后,技术事实是:用 microVM 给不可信 Agent 代码做强隔离,并已具备 pause/resume/snapshot 全生命周期。
- **无新版本发布**:v26.06(07-09)仍是最新季度版,本周无 release / 路线图公告。官网 openfuyao.cn news/活动栏目仍基本为空,官方内容以 CSDN 为主发布口。
- **组织新仓/新仓观察**:本周未见全新立仓;`compliance-operator`(安全合规扫描)、`kubevirt`(VM 管理)、`colocation-website`(在离线混部前端)是已存在但此前 digest 未单独提及的仓,本周 compliance-operator 有实质提交(见"新功能")。

## 跟我们产品的对比

| 能力维度 | OpenFuyao 现状(本周) | 与上游/我们的关系 |
|---|---|---|
| **安全合规扫描** | compliance-operator:kube-bench(CIS)+ OpenSCAP(STIG)扫描 → 加固 → 回滚 | **≈ OpenShift Compliance Operator**,同源技术栈;**通用刚需**,需对我们做 gap 分析(有无自动 remediation+rollback) |
| KVCache 路由 | KV-aware picker 对齐 score、只算完整 block、与 GIE 类型对齐 | 建在上游 GIE 上;**精调而非改架构**,通用可借鉴 |
| 上游跟随策略 | drop kserve 自定义 webhook patch、对齐 kserve preset | 从"fork/patch"往"上游默认+overlay"收敛,降跟随成本,值得学 |
| 分布式 tracing | traceparent(W3C)贯穿网关→引擎,eagle-eye 独立开关 | 通用标准做法 |
| 设备 DRA | npu-dra-plugin(vNPU 软/硬/整卡三切分,DRAConsumableCapacity)+ 本周拓扑亲和上报;mind-cluster ascend-dra-driver 本周仅补 UT | 与 NV/Intel DRA 一致;**倾向 npu-dra-plugin 是切分主线**,参考其软切分弹性配额建模 |
| Agent 沙箱 | 升格为 SIG;flux-sandbox Helm 化 + Service 化 + 污点定向调度 | **通用+潜在竞争**;隔离节点池调度模型可抄 |
| 多 Agent 治理 | openfuyao-powers avatar-agent 做 squad 权限隔离 | 通用;引入 Agent 运维时的最小权限隔离样例 |
| 集群纳管 | cluster-api-provider-bke HelmInstaller(Helm-as-CRD)+ master 保护 webhook | ≈ Cluster API addon provider / OLM,声明式装 addon,通用 |
| DPU 数据面 | mind-cluster dpu-exporter/dpu-dp + DPU 触发断点续训 | 昇腾/超节点专用,作硬件节奏信号 |
| 在离线混部 | 本周无实质进展(colocation 前端/仓静默) | — |

**我们该补 / 该警惕**:
- **安全合规**是本周新冒头且最该对齐的一条:compliance-operator 几乎照搬 OpenShift Compliance Operator 的技术栈与"扫描+remediation+rollback"闭环。如果我们产品的合规能力只停在"扫描出报告",要尽快补上**自动加固 + 回滚**,否则在等保/多租户合规场景会被对标方拉开。
- **上游跟随策略**值得内部复盘:OpenFuyao 主动删 kserve 自定义 patch、往上游 preset 对齐,是降低长期维护成本的正确姿势。我们如果对 KServe/vLLM 有大量私有 patch,应评估同样的收敛路径。
- **DRA 主线判断**:本周信号进一步指向 **npu-dra-plugin(vNPU 切分)是活跃主线**、mind-cluster ascend-dra-driver 处于测试补强,选型参考重心可放前者,但仍需确认二者最终收敛关系。

## 值得跟进
- [ ] 读 `compliance-operator` !11 的 hardening + rollback 实现,对照我们产品合规能力做 gap 分析(kube-bench/OpenSCAP 双引擎、remediation 是否可回滚):https://gitcode.com/openFuyao/compliance-operator
- [ ] 跟 `hermes-router`/`InferNex` 的"去 kserve 自定义 patch、对齐上游 preset"路线,评估我们对 KServe/vLLM 的私有 patch 是否该同样收敛:https://gitcode.com/openFuyao/InferNex
- [ ] 确认 `npu-dra-plugin`(vNPU 切分,DRAConsumableCapacity 软切分弹性配额)与 `ascend/mind-cluster` `ascend-dra-driver` 的分工与收敛方向,盯准长期主线:https://gitcode.com/openFuyao/npu-dra-plugin
- [ ] 看 `openfuyao-powers` 的 avatar-agent 权限隔离模型(!57),若我们引入多 Agent 运维,参考其 squad 最小权限隔离粒度:https://gitcode.com/openFuyao/openfuyao-powers
- [ ] 观察 mind-cluster 新出现的 `coordinator`(容器协调服务 protobuf)后续定位:https://gitcode.com/ascend/mind-cluster

## 原始材料

<details>
<summary>本次扫描清单</summary>

**扫描窗口**:2026-08-24 ~ 2026-08-31

**有实质更新的仓**:
- `ascend/mind-cluster`(最高频):DPU 全套(dpu-exporter 1825 指标 part1~3+UT+白名单、dpu-dp RDMA 资源 annotation/AffectedNPU/npu-nic-mapping.json、DPU 触发断点续训 volcano+clusterD 聚合)、npu-exporter A2/A3 vnpu 指标(!4289)、CDI 统一 MountConfig(unified mount entrypoint/legacy list-mode/JSON profile/filesystem helpers)、container-manager A5 热复位、coordinator 容器协调服务 protobuf、noded IPMI 故障自愈(!4493)、volcano grace 删除数据竞争修复(!4477)、ascend-for-volcano 旁路 dra 任务、节点标签统一规范(pr1~3)+dp 自动打标签修复、host device cni 原生版本、ascend-dra-driver UT 补充(part1~4)、各组件版本信息上报、verl RL 最佳实践文档
- `openFuyao/InferNex`(活跃):!229 KV-aware picker 对齐 score、!227 暴露 cacheIndexer.blockSize、!226 tokenizer overlay 对齐 sidecar、!224 drop kserve scheduler config webhook patch、!221 eagle-eye 独立 tracing、!218 traceparent 传播、!228 过滤 /health/metrics 日志、!222 vLLM engine options 移到 extraArgs、!223 helm 参数校验
- `openFuyao/hermes-router`(活跃):!87 只统计完整 cache block、!86 解决与 GIE plugin 类型冲突、!85 暴露 cacheIndexer.blockSize、!83 tokenizer socket wait 单飞替代指数退避、!81 对齐 kserve scheduler preset、!80 UT 覆盖率 >80%
- `openFuyao/flux-sandbox`:!32 Helm chart、!29 dockerfile 重构、!27 SandboxGroup 污点定向调度、!26 经 K8s Service 访问 E2B API、!25 go 降 1.25/etcd client 降级
- `openFuyao/compliance-operator`:!11 K8s CIS/STIG hardening + rollback 工具(kube-bench+OpenSCAP 双引擎)
- `openFuyao/cluster-api-provider-bke`:!471 HelmInstaller 引擎+HelmComponentExecutor+CRD Helm 扩展、!472 webhook 阻止 master 删除/扩容、!475 bkeagent 最小权限 RBAC+finalizer、!473 KubeletConfig 下发、!465 集群状态字段单一来源
- `openFuyao/npu-dra-plugin`:!41 NPU 拓扑亲和属性上报、!43/!44 README 重构(整卡/硬切/软切三模式+vCANN-RT+CEL 拓扑约束)
- `openFuyao/rootpv`:!18 部署/安装资产、!17 runtime image bootstrap、!16 runtime wrapper lifecycle 测试
- `openFuyao/openfuyao-powers`:!57 avatar-agent squad 权限隔离、!53 workspace config-as-code snapshot、!51 pipeline-issue-reviewer/pr-gate-diagnoser、!50/!49 e2e-issue-retest/regression、!54 改用 opencode.jsonc

**窗口内无实质提交(跳过)**:`openFuyao/npu-operator`(最新 08-18)、`volcano-ext`(2024-09)、`kae-operator`(05-26)、`mooncake`(仓)、`kubevirt`、`colocation-website`;`ub-network-device-plugin` 仅 1 笔权限修复(!57)

**官方源**:
- CSDN(08-25):Agent Sandbox SIG 开发者集结——基于 Kubernetes 的高安全 MicroVM 级隔离环境(SIG 正式成立公告,对应 flux-sandbox)—— https://blog.csdn.net/openFuyao
- 官网 openfuyao.cn news/活动栏目基本为空;无新版本发布(v26.06 07-09 仍为最新);无全新立仓

**抓取方式**:GitCode 走 `git clone --filter=blob:none --shallow-since` + 本地 `git log --since="2026-08-24"`;官方走 WebFetch(CSDN 列表页 + openFuyao 组织首页 SSR)。GitCode raw/blob 页仍为 JS 壳,README 读取走 clone 后本地 cat。

</details>
