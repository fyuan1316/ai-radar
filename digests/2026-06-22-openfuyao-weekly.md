# OpenFuyao 周报 2026-06-22

窗口:2026-06-15 → 2026-06-22(7 天)

## 摘要

- **InferNexService 重构出"扁平化引擎 API + 原生 vLLM 数据并行(DP)跨节点 MoE 编排(走 LeaderWorkerSet)"——这是本周最重要的能力**:把原来 `aggregate` / `pd{prefill,decode}` 的嵌套结构拍平成"根级 inline 工作负载 spec + 可选 `prefill` 子 spec"(prefill 有 template 即判定为 PD 模式,**KServe LLMInferenceService 同款形状**);同时新增 `worker` Pod 模板 + `dataParallelSize` / `dataParallelSizeLocal`(对应 vLLM `--data-parallel-size`),用 `groupSize = DP/DPLocal` 自动在 **Deployment(=1)与 LeaderWorkerSet(>1)** 间切换,并补 `cross-node-moe-lws` 跨节点 MoE 样例。([commit 10464c0](https://gitcode.com/openFuyao/InferNex/-/commit/10464c0))**对标判断:走的是和 KServe/llm-d 同一条路**——扁平化 LLM serving API + vLLM 原生 DP/宽 EP 多机编排,而非分叉自造,整条与昇腾无关,可直接搬 GPU 栈。
- **昇腾侧给出调度面配套:mind-cluster 新增 Atlas 950 SuperPod / 850"推理大 EP 亲和性调度"**([429eb3c](https://gitcode.com/Ascend/mind-cluster/-/commit/429eb3c)、[e5eb2c4](https://gitcode.com/Ascend/mind-cluster/-/commit/e5eb2c4))——为 MoE 大专家并行(Expert Parallel)做拓扑亲和放置(新增 `chip8node8ra64sp` policy,335 行 infer_service)。**和 InferNex 的 LWS/DP 工作负载侧正好上下游配对:工作负载声明 DP/EP,调度器按 SuperPod 拓扑亲和落点。** 拓扑实现是昇腾 SuperPod 专属,但"为 MoE 宽 EP/DP 做拓扑亲和调度"的诉求 GPU 栈完全一致。
- **v26.06 节奏:rc.3 已按计划于 06-16 切出(release-plan 窗口 6-17~19),包集合与 rc.2 完全一致(15 包,含 PDOrchestrator/RayPackage/HermesRouter)**;后续 bugfix 刷新版 6-23~25、拉发布分支 6-20~21、**GA 仍稳定标 6-29~30**。同时全社区刮起一轮 **GA 前安全加固**(CVE-2026-33186 gRPC 授权绕过 → grpc v1.79.3,多仓批量升级;ubs-k8s-enable 一整批"AI 检视意见"安全修复)。**非发版周但临近 GA,本周以收敛/加固为主,新特性以 InferNex 扁平化 API 与昇腾大 EP 调度为代表。**

## 新功能 / 能力

- [InferNexService 扁平化引擎 API + LWS 数据并行多机编排](https://gitcode.com/openFuyao/InferNex/-/commit/10464c0) — 06-16 `feat(bridge): InferNexService LWS engine workloads with flattened engine API`。`InferenceEngineSpec` 不再分 `Aggregate`/`PD`,改为 inline `InferenceEngineWorkloadSpec` 于根 + 可选 `Prefill`(KServe 风格:decode 在根、prefill 子 spec);新增 `Worker`(LWS 非 leader pod 模板,`groupSize==1` 时忽略)、`DataParallelSize`/`DataParallelSizeLocal`;`replicas` 语义随之改为"Deployment=Pod 数 / LWS=组数"。新增三个聚合样例(单机单卡 / 单机多卡 / `ag-03-cross-node-moe-lws` 跨节点 MoE),删旧 `infernexservice.yaml`。
  - 启示:**这是本周对我们最直接的通用借鉴点**。我们做 LLM serving CRD 时,InferNexService 这版 API 形状已基本= KServe `LLMInferenceService`(template 在根 + prefill 子 spec 区分 PD)叠加 **vLLM 原生 DP 语义**(`dataParallelSize/Local` → 按 `groupSize` 自动选 Deployment vs LeaderWorkerSet)。两点值得抄:① **用 DP 全局/本地比值自动决定单机(Deployment)还是多机(LWS)**,把"多机 MoE/宽 EP"做成 spec 字段而非两套 CRD,用户只填 DP 数;② **leader/worker 双模板**,worker 留空回退用 template——这是 vLLM `data-parallel` + LWS 多机部署的标准落法,与 llm-d 多机编排选型一致。整条与昇腾无关。
- [mind-cluster:Atlas 950 SuperPod / 850 推理大 EP 亲和性调度](https://gitcode.com/Ascend/mind-cluster/-/commit/429eb3c) — 06-17 ascend-for-volcano 新增 `chip8node8ra64sp` policy(8 node × 8 RA × 64 SuperPod)`infer_service.go`(+335 行)+ 测试(+400 行),为推理大专家并行做拓扑亲和放置;配套 [850 大 EP 亲和性调度](https://gitcode.com/Ascend/mind-cluster/-/commit/e5eb2c4)、[950/850 基础镜像支持 UB 通信能力](https://gitcode.com/Ascend/mind-cluster/-/commit/196261b)。
  - 启示:**调度面与 InferNex 工作负载面是配套的两半**。MoE 推理走宽 EP 时,专家分片要落在低时延互联(SuperPod UB)同域内,否则 all-to-all 跨域打穿带宽——这正是 InferNex DP/LWS 声明出来后需要调度器解决的拓扑问题。**对我们的启示是架构层:做 MoE 多机推理调度时,"EP/DP 维度的拓扑亲和(同 NVLink 域/同 IB 子网优先)"是必须的调度约束**;昇腾用 SuperPod 拓扑,我们对应的是 NVLink domain / rail-optimized 拓扑,思路同构,实现要换拓扑模型。
- [noded:容器快照(checkpoint/restore)能力](https://gitcode.com/Ascend/mind-cluster/-/commit/cc01f8c) — 06-22 noded 新增 `pkg/containersnapshot/`(`pod_monitor.go` +260、`run_checkpoint.go` +122),配套 [ascend-docker-runtime 容器快照三部分](https://gitcode.com/Ascend/mind-cluster/-/commit/f4940dd)。给训推 Pod 做容器级检查点,故障/迁移时从快照恢复。
  - 启示:**和前两周"故障重建优先回原节点(previous_node)"是同一条恢复局部性主线**——回原节点是为复用本地态,容器快照是把本地态(进程内存/KV/checkpoint)直接落盘可还原。**通用概念**(对标 K8s kubelet checkpoint API / CRIU、以及 forensic container checkpointing KEP),但这版实现绑在 ascend-docker-runtime。我们若要做"推理实例秒级故障恢复/热迁移",CRIU/容器快照是绕不开的底座,值得对照 K8s 上游 checkpoint 成熟度评估。
- [Volcano action 增强收口:补齐 preempt + reclaim action](https://gitcode.com/Ascend/mind-cluster/-/commit/7b3fa49) — 06-17 `volcano action 增强 Part 1:支持 preempt action`、[Part 2:支持 reclaim action](https://gitcode.com/Ascend/mind-cluster/-/commit/9f0c91b),在 ascend-for-volcano 各芯片 base(910A3/910B/910old/superpod/软切分/chip4nodex)统一接入 preempt/reclaim 框架。
  - 启示:延续前几周"抢占/回收从 gang 迁到 volcano-npu 插件"的线,本周把 **preempt + reclaim 两个 action 在 NPU 插件侧补全**。**对标 Kueue/Volcano**:这是把昇腾拓扑/亲和约束下沉进 Volcano 标准 action 框架(而非旁路),路线正确;我们用 Volcano/Kueue 做 GPU 抢占回收时,同样应让设备拓扑感知以"插件扩展 action"方式接入,而非分叉调度器。

## AI 推理栈(InferNex / hermes-router / cache-indexer)

- [InferNex-Bridge:新增 eagle-eye network-performance-exporter sidecar](https://gitcode.com/openFuyao/InferNex/-/commit/dee4fb7) — 06-17,给增强编排加"网络性能采集" sidecar(+85 行模板),纳入 InferNexService 组件矩阵。多机 MoE/PD 起来后,网络成为瓶颈,网络性能可观测性是配套刚需。
- [InferNex:固定 inference gateway NodePort(30088)+ 对齐 hermes-router 配置](https://gitcode.com/openFuyao/InferNex/-/commit/0612329) — 06-17,通过 `spec.infrastructure.parametersRef` 给 Istio 数据面 ConfigMap 钉死 NodePort,并把 hermes tokenizer/prediction(sidecar 资源、modelVolume schema、scorer 权重)对齐上游 chart。说明 InferNex 网关数据面坐实在 **Istio + Gateway API Inference Extension**。
- [InferNex:GIE 推理扩展 CRD 从 v1.2.0 升到 v1.5.0](https://gitcode.com/openFuyao/InferNex/-/commit/a9d06cd) — `chore(crds): upgrade inference-extension CRDs from v1.2.0 to v1.5.0`(本周合入)。**直接追踪上游 sig-network Gateway API Inference Extension(GIE)**,跟 llm-d/GIE 同一套 InferencePool/InferenceModel 语义,不分叉。我们若也建在 GIE 上,需同步关注 v1.5.0 的 CRD 变更面。
- [hermes-router:跨候选池归一化 PD 组指标,修 1P1D 拓扑下"忙/闲二值塌缩"](https://gitcode.com/openFuyao/hermes-router/-/commit/413c08f) — 06-16。每组队列/运行最大值在 1P1D 拓扑下塌成二值忙闲信号,导致不同负载的组无法区分;改为每周期收集池级上限并贯穿 PDGroup 与 prediction fallback 打分。**我们做 PD 分离路由打分时同类坑要警惕**:打分归一化必须按池级(pool-wide)而非按组局部最大值,否则小拓扑下信号丢失。
- [hermes-router:tokenizer 拆分 source/identity(`tokenizerSource`)+ 并行渲染 sidecar](https://gitcode.com/openFuyao/hermes-router/-/commit/93ab1c0) — 06-15/16,EPP tokenizer 插件 JSON key 改 `tokenizerSource`,Helm 各 routing profile 分支统一渲染;配套 [并行 sidecar 渲染 + worker pool](https://gitcode.com/openFuyao/hermes-router/-/commit/b6086b9)、Dockerfile 对齐 openfuyao builder、[Istio TLS insecureSkipVerify 风险文档化](https://gitcode.com/openFuyao/hermes-router/-/commit/bcf2489)。延续上周学习型路由的工程化收敛,无新算法。
- [InferNex:mooncake master 支持自定义配置 + 三项集成卫生修复](https://gitcode.com/openFuyao/InferNex/-/commit/f157742) — 06-15 mooncake-master 自定义 config;[553ade8](https://gitcode.com/openFuyao/InferNex/-/commit/553ade8) PSA securityContext / 默认配置 bootstrap / RBAC 三修(co-author `yuanfang@alauda.io`,我方上游工作)。cache-indexer 本周仅 doc。

## 昇腾资源管理(NPU Operator / MindCluster / FD)

- **FD 故障诊断继续加重 PyMotor-vLLM 引擎日志路径**:[新增 PyMotor-vLLM kg config](https://gitcode.com/Ascend/mind-cluster/-/commit/49d6058)(06-17)、[覆写 mindie 解析数据](https://gitcode.com/Ascend/mind-cluster/-/commit/18960b0)、[多标识 EID 解析](https://gitcode.com/Ascend/mind-cluster/-/commit/0841556),延续上周 CANN Fault Mode Library(故障模式知识图谱)+ 引擎日志关联。是 AgenticOps SIG 的数据底座。
- [device-plugin:卡死(hang)故障检测逻辑优化 + 故障处理模块化](https://gitcode.com/Ascend/mind-cluster/-/commit/8f8fa55) — 06-17 `feat(device): 卡死故障检测逻辑优化`、[故障处理模块化](https://gitcode.com/Ascend/mind-cluster/-/commit/5143e7b)、[A5 device-plugin/AO 区/NodeD 故障码适配](https://gitcode.com/Ascend/mind-cluster/-/commit/19dd8ca)、[调整 0x81AF8009 故障等级](https://gitcode.com/Ascend/mind-cluster/-/commit/9f1f75a)。hang detection 是大模型训练长稳的关键,昇腾这块在持续硬化。
- [npu-exporter:修指标为空时 telegraf 异常 + intervalSeconds 删除后默认值异常 + 缓存有效期](https://gitcode.com/Ascend/mind-cluster/-/commit/c89bc8b) — 06-18,延续上周指标分组采集周期的善后修复。
- [mindio:适配 UB 链路故障快恢](https://gitcode.com/Ascend/mind-cluster/-/commit/fc1f08c)、[helm 支持动态加载 dpc/dtfs](https://gitcode.com/Ascend/mind-cluster/-/commit/3f1be10);[build 升级 golang 至 1.26](https://gitcode.com/Ascend/mind-cluster/-/commit/81ed294)(同步 go.mod 适配)。
- [npu-operator](https://gitcode.com/openFuyao/npu-operator) 本周仅修文档链接;[npu-dra-plugin](https://gitcode.com/openFuyao/npu-dra-plugin) 仅 CVE 依赖升级(无功能);[volcano-ext](https://gitcode.com/openFuyao/volcano-ext)、[kae-operator](https://gitcode.com/openFuyao/kae-operator) 本周无提交。**DRA 接入昇腾仍无功能进展,沿用既往判断:短期不进我们 DRA 路线优先级**。
- [vNPU:节点级锁防同节点并发 Pod 分配冲突](https://gitcode.com/openFuyao/vNPU/-/commit/d93fde2) — 06-13(窗口边缘),软切分并发分配加 node-level lock;本周余下为 build 脚本/文档。

## 调度 & 集群(volcano / bke / UB / 安全加固)

- **GA 前全社区安全/CVE 加固(本周一条主线)**:
  - **CVE-2026-33186(gRPC 授权绕过)→ grpc v1.79.3**:[ubs-k8s-enable](https://gitcode.com/openFuyao/ubs-k8s-enable/-/commit/2314b8f)、[ub-network-device-plugin](https://gitcode.com/openFuyao/ub-network-device-plugin/-/commit/c269fff)、[npu-dra-plugin(并修 CVE-2025-13281)](https://gitcode.com/openFuyao/npu-dra-plugin/-/commit/938a934)、[InferNex checker](https://gitcode.com/openFuyao/InferNex/-/commit/b58d4bd) 批量升级。
  - [ubs-k8s-enable 一整批"AI 检视意见"安全修复](https://gitcode.com/openFuyao/ubs-k8s-enable/-/commit/0f24de4):整数溢出、内存泄漏、unix socket 监听到设权的竞态、限制 body 大小、校验设备合法路径、隔离 agent/controller ServiceAccount、RBAC 收敛——一次集中的代码级安全审查落地。
  - [cluster-api-provider-bke:fix cve 0618 + 修 deepcopy panic + 升级 mgmt 集群时 webhook 挂载缺失](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/e56a8f3)、[DAG 升级失败处理](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/f522365)。
  - 启示:**这是临近 LTS/GA 的标准动作**——集中扫 CVE + 用 AI 代码审查兜底内存安全/竞态/输入校验。我们自家组件在版本冻结前也应跑同样的"gRPC/依赖 CVE 扫描 + AI 检视(整数溢出/竞态/路径校验/SA 隔离)"清单。
- [mind-cluster:helm 部署适配 k8s-rdma-shared-dev-plugin + dp 与 volcano 1.12.0](https://gitcode.com/Ascend/mind-cluster/-/commit/e8935cf) — 06-15,延续 volcano v1.12.0 适配;[调度回原节点打分规则修改](https://gitcode.com/Ascend/mind-cluster/-/commit/84c202d)(06-16)继续打磨 previous_node 局部性恢复。
- [community:正式建 AgenticOps SIG(含首仓 log-parser)](https://gitcode.com/openFuyao/community/-/commit/5cd3162) — 06-16,把上周 OFEP-0005 落成 `sig/sig-AgenticOps/`,首个 repo 是 `log-parser`(日志解析,对应 mind-cluster FD 引擎日志路径);[新增 serverlessdb-operator 仓](https://gitcode.com/openFuyao/community/-/commit/0247740)(06-15,sig-orchestration-engine)。

## 官方动态

- **v26.06 rc.3 已按计划切出(06-16,[release-management add 26.06-rc.3 dir](https://gitcode.com/openFuyao/release-management/-/commit/afcaaed))**:15 个 VersionConfig 与 rc.2 完全一致(无包增删),含 PDOrchestrator / RayPackage / HermesRouter / InferNex。按 release-plan,**bugfix 刷新版 6-23~25、拉发布分支 6-20~21、Release Review 6-25、GA 6-29~30**。上周逾期的 rc.3 本周已补上,GA 节奏未滑。下周(6-23~25)进 bugfix 回归窗口,看是否有阻塞 GA 的回归。
- **CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao) 本周两条实质内容**:06-15 发布 **2026 年 3-5 月社区运作报告**(季度运作报告,含组件进展/SIG 扩张盘点)、06-18 "生态五大案例入选国家级示范案例"(生态宣传,剥离后无新技术指标)。官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/) news/release 仍"暂无内容",发布节奏依旧 CSDN + GitCode 驱动。
- **组织方向**:AgenticOps SIG 正式成立(首仓 log-parser),延续上周"往 Agent 基础设施(运维 + 沙箱)延伸"的判断;新增 serverlessdb-operator(orchestration-engine 方向,待观察)。

## 跟我们产品的对比

| 维度 | OpenFuyao 本周变化 | OAI / KServe / llm-d / 通用栈 | 我们应该怎么做 |
|------|-------------------|------------------------------|----------------|
| LLM serving API | **(本周重点)**InferNexService 扁平化(根级 inline + prefill 子 spec)+ vLLM DP(`dataParallelSize/Local`)按 groupSize 自动选 Deployment/LWS | KServe `LLMInferenceService` 同款扁平形状 + llm-d vLLM 原生 DP/宽 EP 多机 | **可直接借鉴**:用 DP 数自动决定单机/多机(LWS),leader/worker 双模板;与 KServe/llm-d 同路,与昇腾无关 |
| MoE 多机调度 | **(本周新增)**Atlas 950 SuperPod / 850 推理大 EP 亲和性调度(拓扑亲和 policy) | Volcano/Kueue 拓扑感知;GPU 侧 NVLink-domain/rail-optimized 放置 | **架构借鉴**:MoE 宽 EP/DP 必须做拓扑亲和(同高速互联域优先);换昇腾 SuperPod→NVLink domain 拓扑模型 |
| 故障恢复 | **(本周新增)**noded 容器快照(checkpoint/restore)+ 调度回原节点打分 | K8s kubelet checkpoint API / CRIU / forensic checkpoint KEP | **借鉴**:秒级故障恢复/热迁移需 CRIU/容器快照底座;对照上游 checkpoint 成熟度 |
| 调度 action | **(本周)**Volcano preempt + reclaim action 在 NPU 插件侧补齐 | Volcano/Kueue 标准 action | 沿用:设备拓扑感知以"插件扩展 action"接入,不分叉调度器 |
| 推理网关 | **(本周)**钉死 Istio NodePort + GIE CRD v1.2.0→v1.5.0 + 网络性能 exporter sidecar | llm-d/GIE InferencePool/InferenceModel | 若也建在 GIE 上,同步追 v1.5.0 CRD 变更面 |
| PD 路由打分 | **(本周)**hermes 跨候选池归一化 PD 组指标(修 1P1D 二值塌缩) | llm-d EPP 打分 | 借鉴:打分归一化按池级而非组局部最大值,否则小拓扑信号丢失 |
| 安全/CVE | **(本周)**GA 前全社区 CVE-2026-33186 grpc 升级 + AI 检视安全批 | 通用发布纪律 | **照搬清单**:冻结前跑依赖 CVE 扫描 + AI 检视(溢出/竞态/路径校验/SA 隔离) |
| DRA | npu-dra-plugin 仅 CVE 升级,无功能 | K8s 1.34 DRA 已 GA | 沿用既往判断,DRA 短期不进主路径 |

## 值得跟进

- [ ] **精读 InferNexService 扁平化 API + LWS/DP 实现**(`api/v1alpha1/infernexservice_types.go`、`examples/insvc/aggregate/ag-03-cross-node-moe-lws.yaml`):弄清 `dataParallelSize/dataParallelSizeLocal → groupSize → Deployment/LeaderWorkerSet` 的判定与 leader/worker 模板渲染;评估能否照搬到我们的 LLM serving CRD,与 KServe `LLMInferenceService` 做字段级对齐分析
- [ ] **对照 InferNex DP/LWS(工作负载侧)与 mind-cluster `chip8node8ra64sp` 大 EP 亲和调度(调度侧)**:理清"DP/EP 声明 → 拓扑亲和落点"的完整链路,映射到我们 GPU 栈的 NVLink-domain/rail 拓扑模型,判断 MoE 宽 EP 多机推理在我们调度器上的拓扑约束怎么建
- [ ] **评估 noded 容器快照实现 vs K8s 上游 checkpoint/CRIU**:看 `pkg/containersnapshot/run_checkpoint.go` 走的是 kubelet checkpoint API 还是自研;判断我们做推理实例热迁移/秒级恢复时容器快照的可行性与成熟度
- [ ] **关注 v26.06 GA 收尾(6-23~25 bugfix 回归 → 6-29~30 GA)**:跟踪 release-management 是否出 rc.4 或直接进发布分支,确认 InferNex 扁平化 API / hermes prediction / PD-Orchestrator 是否随 26.06 GA 交付;若 API 重构在 GA 前才落,留意兼容性破坏
- [ ] **跑一遍我们组件的 GA 前安全清单**:对照本周 ubs-k8s-enable 的 AI 检视项(整数溢出/内存泄漏/socket 竞态/body 大小/路径校验/SA 隔离)+ gRPC CVE-2026-33186,在自家组件冻结前扫一轮

## 原始材料

<details>
<summary>本次扫描清单(commits in 2026-06-15..2026-06-22)</summary>

**openFuyao 主组织活跃仓**:
- `InferNex`:`10464c0 feat(bridge): InferNexService LWS engine workloads with flattened engine API`(06-16)、`dee4fb7 feat(infernex-bridge): add eagle-eye network-performance-exporter sidecar`(06-17)、`0612329 feat: pin inference gateway NodePort and align hermes-router config`(06-17)、`a9d06cd chore(crds): upgrade inference-extension CRDs v1.2.0→v1.5.0`、`f157742 feat: mooncake master with custom config`(06-15)、`553ade8 chore: three integration hygiene fixes (PSA/RBAC)`(co-author yuanfang@alauda.io)、`dd3e6af fix: alias inference-gateway to inferenceGateway values key`、`061ef86 chore: subchart version/format`、`b58d4bd fix: infernex checker go modules security vulns`、`758e846 update: remove unused binary file`(06-22)
- `hermes-router`:`413c08f fix(score): normalize PD group metrics across the candidate pool`(06-16)、`93ab1c0 feat(tokenizer): expose tokenizerSource and wire Helm charts`(06-15)、`b6086b9 feat(tokenizer): parallelize sidecar render paths with worker pool`、`7b5dbe7/4b12fc1 tokenizer/Dockerfile`、`bcf2489 docs: Istio TLS insecureSkipVerify security risk`、`c58b534 chore(charts): Mulan PSL v2 license headers`(06-22)
- `cache-indexer`:`d49c590 update(doc): add doc reference url`(仅 doc)
- `vNPU`:`d93fde2 feat: node-level lock to prevent concurrent pod allocation conflicts`(06-13)、`4c40d5f/de37025 build script`、`7d3554f docs`
- `ubs-k8s-enable`:`2314b8f fix: 升级 grpc v1.79.3 修 CVE-2026-33186`(06-18)、`0f24de4 fix: AI 检视意见`、`5e7f650 rbac`、`21a5667/4f9db78 unix 监听设权竞态`、`1433179 类型截断`、`f937df6 整数溢出`、`a0e13b8 解除挂载权限`、`aa4dc68 内存泄漏`、`b9d63fa 限制 body 大小`、`3594077 校验设备合法路径`、`9c1d859 隔离 agent/controller SA`(均 06-15)
- `cluster-api-provider-bke`:`e56a8f3 fix cve 0618`(06-18)、`123d435 fix: deepcopy panic`、`8d63e62 optimize can-reach condition`、`69b289a fix webhook mount missing on mgmt upgrade`、`f522365 add dag upgrade fail deal`
- `elastic-scaler`:`824ff4d fix: duplicate codes`(06-22)、`80ada09 feat: update charts`(06-18)
- `npu-dra-plugin`:`938a934 fix: upgrade deps CVE-2025-13281 / CVE-2026-33186`(06-18,无功能)
- `ub-network-device-plugin`:`c269fff/31cfbe0 fix: upgrade grpc CVE-2026-33186`(06-18)
- `npu-operator`:`a4a216f fix: broken link`(纯 doc)
- `community`:`5cd3162 feat: add Agentic Ops SIG`(06-16,含 log-parser 首仓)、`0247740 feat: add serverlessdb-operator repo`(06-15)、`81258c2 sig-qa committers`、`7da350d add dev branch`
- `release-management`:`afcaaed add 26.06-rc.3 dir`(06-16)+ `d2b4458 !219`、`13647ba/77eddd3 mod file name`;rc.3 包集合 = rc.2(15 包),GA 6-29~30
- **无功能/无活动仓**:`weight-dispatcher`(0)、`ofep`(0,OFEP-0005 已于上周合入)、`volcano-ext`(0)、`kae-operator`(0)

**上游 Ascend/mind-cluster**(窗口内数十 commits,核心):
- 推理/调度:`429eb3c 支持 Atlas 950 SuperPod 推理大EP亲和性调度`(+335/+400)、`e5eb2c4 850 大EP亲和性调度`、`196261b 950&850 基础镜像支持 UB 通信`、`7b3fa49 volcano preempt action`、`9f0c91b volcano reclaim action`、`84c202d 调度回原节点打分规则修改`、`13c861a jobPipelined pod 就绪数量判断`、`e8935cf helm 适配 rdma-dp/volcano 1.12.0`、`faff78a A2/3 node annotation rackID 修复`
- 故障恢复/快照:`cc01f8c/43e7d30 noded 容器快照`(+260/+122)、`f4940dd/6eb82f4/ac4cd00 ascend-docker-runtime 容器快照`、`fc1f08c mindio 适配 UB 链路故障快恢`
- 故障诊断/检测(FD/DP):`49d6058 PyMotor-vLLM kg config`、`18960b0 覆写 mindie 解析数据`、`0841556 多标识 EID 解析`、`c1cba00 external switch 命令`、`8f8fa55 卡死故障检测逻辑优化`、`5143e7b 故障处理模块化`、`19dd8ca A5 device-plugin/AO/NodeD 故障码`、`9f1f75a 0x81AF8009 故障等级`、`dd6217b/84a5f12 device-plugin 软切分任务名清理`
- 监控/构建:`c89bc8b npu-exporter telegraf/intervalSeconds/缓存有效期修复`、`3f1be10 helm 动态加载 dpc/dtfs`、`81ed294 升级 golang 1.26`、`e418c92 热复位插件开发者指南`、`bfc1e56 mindio tft IPv6`
- 大量 docs/资料修改(略)

**官方信息源**:
- 官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/)(news/release 仍"暂无内容")
- CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao):06-15 2026 年 3-5 月社区运作报告、06-18 生态五大案例入选国家级示范案例(宣传)
- 组织:AgenticOps SIG 正式成立(首仓 log-parser)、新增 serverlessdb-operator 仓;v26.06 rc.3 已切,GA 6-29~30

</details>
