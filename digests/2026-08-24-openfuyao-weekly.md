# OpenFuyao 周报 2026-08-24

> 扫描窗口:2026-08-17 ~ 2026-08-24。主仓 GitCode `openFuyao` 组织 + 昇腾 upstream `ascend/mind-cluster` + 官方 CSDN。非发版周(v26.06 已于 07.09 发布,下一季度版待定),但本周三条主线密集推进:①flux-sandbox 补齐 E2B 沙箱 pause/resume/snapshot 全生命周期 + 拓扑/镜像亲和调度;②DRA 在两个源头同时成熟(`ascend/mind-cluster` 首次合入自己的 `ascend-dra-driver`,`openFuyao/npu-dra-plugin` 修 vNPU 生命周期);③新一代昇腾硬件 A5 适配全面铺开。信息量足,正常出报并推送。

## 摘要(3 条以内)
- **昇腾 DRA 出现"双实现":`ascend/mind-cluster` 本周首次合入自研 `ascend-dynamic-resource-allocation`(ascend-dra-driver,含 910/950 两代设备代码)**,而 `openFuyao/npu-dra-plugin` 同期在修 vNPU 生命周期/资源清理/share-count 校验。昇腾生态现在**上游(mind-cluster)和 OpenFuyao 侧各有一套 DRA driver**,选型/收敛关系待观察 —— 这直接关系我们参考哪一套。
- **flux-sandbox 补齐 Agent 沙箱全生命周期**:本周合入 E2B 沙箱 pause/resume/snapshot(底层 Firecracker microVM 快照)、快照预热(oFEP-0004)、以及"镜像亲和 + 拓扑亲和"两种调度,并把快照后端存储从 S3 换成 Mooncake 分布式存储。沙箱从"能创建"走到"可暂停省资源 + 秒级恢复 + 快照克隆",且复用 InferNex 那套 Mooncake 池化底座。
- **新一代昇腾硬件 A5 适配全面铺开 + AI-DevOps skill 库集中扩张**:mind-cluster 本周约 10+ MR 做 A5(clusterd rank_list、npu-exporter atlas350/ubx PCIe 采集、A5 part1~3 测试);`openfuyao-powers` 一周新增 6+ 个 gitcode 研发自动化 skill(bug-issue-creator、pr-gate 自动 /retest、design reviewer、issue-dispatcher)+ 一份 Agent 运行安全基线文档。

## 新功能 / 能力

- [flux-sandbox:E2B 沙箱 pause/resume/snapshot 全生命周期](https://gitcode.com/openFuyao/flux-sandbox) — 本周合入 !19(pause/resume/snapshot)、!14(快照预热 oFEP-0004)、!20(快照预热的镜像亲和调度)、!18(沙箱拓扑亲和调度),并修 30000 沙箱压测下的 CR 删除残留/幽灵预留/SSG 生成爆炸问题,新增控制面 + 数据面 e2e 套件。据提案 0005:pause/resume 走 Firecracker microVM 内存快照(释放 CPU/内存仅留磁盘+内存快照),快照后端存储由 S3 改为 Mooncake 超节点分布式存储,E2B 原 APIServer 重定位为 Template Manager(PostgreSQL+Redis 管模板/快照元数据)。
  - 启示:这是本周**最完整的一块新能力**,也是**通用(非昇腾专用)、且与我们方向直接竞争**的部分。Agent 沙箱做到 pause/resume 是生产级刚需(空闲沙箱释放算力、按需秒级恢复),快照则支撑"从检查点克隆沙箱"。两点值得我们抄:(1)**镜像亲和调度**——把沙箱调度到已缓存该快照镜像的节点做预热,本质是 Serverless 冷启动优化(类比 Knative/KServe 的 image locality),思路可直接迁移到我们的推理/函数冷启;(2)**快照存储复用 Mooncake**——沙箱快照和 KVCache 共用同一套分布式存储底座,是"一套池化存储服务多种 AI workload"的架构范式,我们若自建 KVCache 池可顺带覆盖沙箱快照场景。

- [ascend/mind-cluster:首次合入自研 DRA driver(ascend-dynamic-resource-allocation)](https://gitcode.com/ascend/mind-cluster) — 08-21 MR !4399 合入 `ascend-dra-driver`,自带 `ascend-dra-driver.yaml` 部署清单、`generation_910.go` / `generation_950.go` 两代设备实现(950 即 A5 代)。这是昇腾**上游 mind-cluster 侧**的 DRA 实现,与 `openFuyao/npu-dra-plugin` 是两套代码。
  - 启示:**跟我们 DRA 选型最强相关的一条,且信号复杂**。昇腾现在**同时存在两套 DRA driver**——上游 mind-cluster 的 `ascend-dra-driver` 和 OpenFuyao 的 `npu-dra-plugin`。可能是:上游做通用 NPU DRA 底座、OpenFuyao 侧做 vNPU 切分增强(npu-dra-plugin 本周主修 vNPU 生命周期/share-count),也可能后续收敛。我们评估时**要盯准哪一套是长期主线**,别参考到会被弃用的分支。架构路径(ResourceClaim/DeviceClass)仍与 NVIDIA/Intel DRA driver 一致,通用可比。

- [mind-cluster:新一代昇腾硬件 A5 适配](https://gitcode.com/ascend/mind-cluster) — 本周约 10+ MR 铺 A5:`feat(clusterd): support A5 v2.0 rank_list in job-summary hccl.json`、npu-exporter 支持 atlas350/ubx 的 PCIe 数据采集、A5 part1~3 功能与测试适配、A5 部署文档。另有 `[ascend-docker-runtime]支持自动挂载 UB 驱动用户态文件`(umdk-dev)。
  - 启示:**纯昇腾专用**,对我们无直接借鉴,但是**判断昇腾硬件节奏的信号**:A5(950 代)正从驱动/exporter/runtime 到调度全栈适配,意味着新一代超节点硬件临近可用。UB 驱动用户态文件自动挂载则是超节点(灵衢)网络容器化的配套,同样昇腾绑定。

- [openfuyao-powers:AI 研发自动化 skill 库一周集中扩张](https://gitcode.com/openFuyao/openfuyao-powers) — 本周新增 gitcode-bug-issue-creator、gitcode-pr-gate-diagnoser 自动 /retest、design-reviewer skill、gitcode-issue-creator 自动配置属性、gitcode-issue-dispatcher、gitcode-pr-manager 增加"AI 使用/人工评审声明",并加入 `ai_agent_operational_safety_baseline`(Agent 运行安全基线)文档 + skill 布局/frontmatter 标准化。
  - 启示:社区把**研发流程(建 issue、诊断 PR 门禁、设计评审、需求拆解)全面 skill 化**,形态类似 Claude Code skill。两点对我们有参考:(1)**pr-gate-diagnoser 自动 /retest**——CI 门禁失败自动归因并触发重试,是平台自服务化 CI 的具体样例;(2)**Agent 运行安全基线文档**——他们在给 AI Agent 操作定"安全护栏"规范,我们若在产品里引入 Agent 化运维,这类 baseline 是必备治理件,值得看其粒度。**通用能力。**

- [rootpv:有状态容器 rootfs 持久化补齐控制面 + runtime wrapper](https://gitcode.com/openFuyao/rootpv) — 本周加入 rootfs controller service、node rootfs agent、runtime wrapper foundation + execution(在 !11 rootfs HTTP API 基础上)。
  - 启示:延续上周判断——给容器 rootfs 提供持久卷(长跑训练/调试环境/Agent 沙箱持久工作区)。本周补上控制器 + 节点 agent + runtime wrapper,说明从"接口"走到"可运行闭环"。与 flux-sandbox 可能同属一套(沙箱持久工作区)。**通用能力**,可借鉴其 runtime wrapper 注入模型。

## AI 推理栈(InferNex / hermes-router / Mooncake)

本周**推理栈仓库本体基本静默**——`InferNex` 仅有 1 笔(08-17 的 npu-smi 预检复用,是上周主线的收尾)、`hermes-router` 窗口内无新提交(最新仍是 08-14 的 Tokenizer 有界退避)。推理栈本周的实际推进反而落在两处外围:

- **infer-operator(在 mind-cluster 内)做跨 placement-group 亲和自动配置**:`[infer-operator]自动配置 inferservice 下 role 的跨 pg 亲和性标签`、`[volcano]新增 A3 支持通过 inferserviceid 标签配置任务间亲和性`、fault-scheduling 字段补充。→ 这是把**推理服务的 PD 组/多角色 pod 按昇腾拓扑做亲和编排**的自动化,减少手工配 affinity。思路通用(推理多角色亲和调度),但落地在昇腾 super-node 拓扑上。
- **Mooncake 被复用为 flux-sandbox 快照后端**(见上"新功能"):Mooncake 从 InferNex 的 KVCache 池外溢成通用分布式存储底座。→ 印证上周"跟 Mooncake 能否独立复用"这条待办——本周答案是:能,已被沙箱场景复用。

架构定性不变(据 26-06 README):hermes-router 建在上游 GIE(Gateway API Inference Extension)上、与 llm-d/kgateway 同源;cache-indexer 前缀树 KV-aware ≈ llm-d;PD-Orchestrator + APA 弹性 ≈ Dynamo/llm-d。路由/索引/弹性三层通用可借鉴,传输(HCCL)、UB 网络指标、后端(vLLM-Ascend)昇腾绑定。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **DRA 双实现(见上"新功能")** 是本周主线:mind-cluster 合入 `ascend-dra-driver`(910/950 两代),npu-dra-plugin 同期修 vNPU 生命周期/资源清理/share-count 范围校验(1-63)/设备发现 dfx。
- **npu-operator**:`fix: support vnpu and mindcluster volcano switching` —— 支持 vNPU 与 mindcluster volcano 之间切换(大概率是 vNPU 场景下调度器/组件的兼容切换),延续 DRA/vNPU 加固主题。
- **CDI 收尾**:mind-cluster 本周 `feat(cdi): add HostRoot path validation and configurable spec version/kind`、`refactor(ascend-docker-runtime): read injection-mode from install.info`(把注入模式做成安装期可配),是上周 CDI 全套合入后的健壮性 + 可配置化收尾。
- **安全**:mind-cluster nodeD 处理 `CVE-2026-46600`;npu-exporter 支持 atlas350/ubx PCIe 采集。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- `volcano-ext`、`ub-network-device-plugin`、`kae-operator`、`mooncake`(仓)窗口内**无实质提交**,跳过。
- **cluster-api-provider-bke**(企业级集群纳管):本周多为稳定性/安全修复 —— kubeconfig 证书生成加 write-through 缓存、同版本重触发时正确解析 release bundle、AesDecrypt 误导性错误日志降级、失败节点 postprocess 置 NeedSkip、集中化 annotation 常量并移除 e2e 模式。均为质量提交,无新特性。
- 调度侧的新东西本周主要体现在**推理拓扑亲和自动配置**(见"AI 推理栈"的 infer-operator/volcano 条目),而非通用调度器变更。

## 官方动态

- **[CSDN:AI 推理性能优化解读 —— openFuyao InferNex 如何实现 TTFT 直降](https://blog.csdn.net/openFuyao)**(08.19 发布):技术解读文,讲 InferNex 在大规模部署下 KVCache 复用效率、显存管理等瓶颈的优化(对应 cache-indexer L3 KV-aware + Mooncake 池化 + APA 弹性)。剥离营销话术后,是对 v26.06 已发布能力的技术复盘,无新增能力公告。
- 官网 openfuyao.cn news/blog/活动栏目仍基本为空;官方内容仍以 CSDN 为主发布口。
- 组织新仓观察:本周未见全新立仓;`console-website`(控制台前端)、`oauth-server`、`sig-orchestration-engine` 有活动但非本周新增,归入常规迭代。

## 跟我们产品的对比

| 能力维度 | OpenFuyao 现状(本周) | 与上游/我们的关系 |
|---|---|---|
| Agent 沙箱生命周期 | flux-sandbox:E2B pause/resume/snapshot + 快照预热 + 镜像/拓扑亲和调度 | **通用 + 潜在竞争**;我们空白,pause/resume 省算力与镜像亲和冷启动值得抄 |
| 沙箱快照存储 | 复用 Mooncake 超节点分布式存储(替代 S3) | "一套池化存储服务多 workload"范式,通用可借鉴 |
| 设备 DRA | **双实现**:mind-cluster ascend-dra-driver(910/950)+ openFuyao npu-dra-plugin(vNPU) | 与 K8s 官方 DRA 路线一致;但**要判断哪套是主线**再参考 |
| CDI 设备注入 | HostRoot 校验 + 注入模式安装期可配 | 与 NVIDIA container toolkit CDI 同路,通用 |
| 推理拓扑编排 | infer-operator 自动配 PD/role 跨 pg 亲和(A3) | 思路通用,落地昇腾 super-node 拓扑 |
| AI 研发自动化 | openfuyao-powers 6+ skill + Agent 安全基线 | 平台自服务 CI/研发 skill 化样例,通用可借鉴 |
| 有状态容器 | rootpv 补齐控制器 + runtime wrapper | 通用,借鉴注入模型 |
| 新硬件节奏 | A5(950 代)全栈适配铺开 + UB 驱动挂载 | 昇腾专用,作硬件节奏信号 |

**我们该补 / 该警惕**:
- **Agent 沙箱**从上周的"独立立仓"到本周"补齐 pause/resume/snapshot + 亲和调度",OpenFuyao 推进极快,已是接近生产级的完整栈。我们仍空白,建议尽快立项评估,至少把"镜像亲和冷启动 + 快照复用池化存储"两个通用点纳入我们冷启动/存储设计。
- **DRA 双实现**是新变量:上周我们的待办是"深挖 soft-dra",本周要先回答更上层的问题——**上游 ascend-dra-driver 与 OpenFuyao npu-dra-plugin 的分工与收敛方向**,否则参考错分支会白做。

## 值得跟进
- [ ] 搞清 `ascend/mind-cluster` 的 `ascend-dra-driver`(!4399)与 `openFuyao/npu-dra-plugin` 的关系:是分层(通用底座 vs vNPU 增强)还是竞争/待收敛,确认哪套是长期主线:https://gitcode.com/ascend/mind-cluster
- [ ] 读 flux-sandbox 提案 0005 + !19/!20,评估 E2B pause/resume/snapshot 的 Firecracker microVM 方案与"镜像亲和预热"调度,判断能否迁移到我们的推理/函数冷启动:https://gitcode.com/openFuyao/flux-sandbox
- [ ] 跟 Mooncake 作为"通用分布式存储底座"的演进(本周已服务沙箱快照 + KVCache 两类 workload),评估其作为独立池化存储服务的可复用性:https://gitcode.com/openFuyao/InferNex
- [ ] 看 `openfuyao-powers` 的 `ai_agent_operational_safety_baseline`,若我们引入 Agent 化运维,参考其安全护栏粒度:https://gitcode.com/openFuyao/openfuyao-powers

## 原始材料

<details>
<summary>本次扫描清单</summary>

**扫描窗口**:2026-08-17 ~ 2026-08-24

**有实质更新的仓**:
- `openFuyao/flux-sandbox`(最活跃,扫描时仍在提交):E2B pause/resume/snapshot(!19)、快照预热 oFEP-0004(!14)、镜像亲和调度(!20)、拓扑亲和调度(!18)、30000 沙箱压测修复(CR 残留/幽灵预留/SSG 爆炸)、控制面+数据面 e2e 套件、提案 0005(增量快照,后端 S3→Mooncake)
- `ascend/mind-cluster`(高频):自研 `ascend-dra-driver` 合入(!4399,910/950)、A5 适配全套(clusterd rank_list、npu-exporter atlas350/ubx PCIe、A5 part1~3 测试与文档)、UB 驱动用户态文件自动挂载(umdk)、CDI HostRoot 校验 + 注入模式可配、infer-operator 跨 pg 亲和自动配、volcano A3 inter-job 亲和(inferserviceid)、CVE-2026-46600(nodeD)、device-plugin 故障 configmap、310P dcmi 初始化修复
- `openFuyao/npu-dra-plugin`:vNPU 生命周期/资源清理 dfx、share-count 范围校验(1-63)、设备发现修复、propagateInitialPolicies 重构
- `openFuyao/npu-operator`:vnpu 与 mindcluster volcano 切换支持
- `openFuyao/rootpv`:rootfs controller service、node rootfs agent、runtime wrapper foundation+execution
- `openFuyao/openfuyao-powers`:gitcode-bug-issue-creator、pr-gate-diagnoser 自动 /retest、design-reviewer、issue-creator 属性自动配、issue-dispatcher、pr-manager AI 使用声明、ai_agent_operational_safety_baseline、skill 布局标准化
- `openFuyao/cluster-api-provider-bke`:kubeconfig 证书 write-through 缓存、同版本重触发 release bundle 解析、AesDecrypt 日志降级、失败节点 NeedSkip、annotation 常量集中化

**窗口内无实质提交(跳过)**:`openFuyao/InferNex`(仅 08-17 收尾 1 笔)、`openFuyao/hermes-router`(最新 08-14)、`volcano-ext`、`ub-network-device-plugin`、`kae-operator`、`mooncake`(仓)

**官方源**:
- CSDN(08.19):AI 推理性能优化解读——InferNex 如何实现 TTFT 直降(v26.06 已发布能力的技术复盘,无新能力公告)—— https://blog.csdn.net/openFuyao
- 官网 openfuyao.cn news/blog/活动栏目基本为空;无本周新立仓

**抓取方式**:GitCode 走 `git clone --depth 120` + 本地 `git log --since="2026-08-17"`;官方走 WebFetch(CSDN 列表页 + openFuyao 组织首页 SSR)。GitCode raw/blob 页仍为 JS 壳,未用 WebFetch 读文件。

</details>
