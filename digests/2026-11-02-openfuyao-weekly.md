# OpenFuyao 周报 2026-11-02

窗口:2026-10-27 -> 2026-11-02(7 天)

## 摘要(3 条以内)
- **DRA 这周是绝对主线,且在往"上游标准 UX"靠拢**:mind-cluster 落地 K8s KEP-5004(`DRAExtendedResource`),新增 `ascend910.ext.huawei.com` / `npu.ext.huawei.com` 两个带 `extendedResourceName` 的 DeviceClass——业务**不再需要写 ResourceClaimTemplate**,直接在 Pod `resources.requests` 里写 `huawei.com/Ascend910` 或 `huawei.com/npu` 就能申请整卡(K8s 1.36+,DRAExtendedResource 门控)。同时 npu-dra-plugin 修了一个关键 DRA 语义 bug(整卡独占模式误报 `AllowMultipleAllocations`/`Capacity` 导致第二个独立 Claim 永远 pending,对应上游 kubernetes#133705),并把 NUMA 属性切到上游 `StandardDeviceAttributeNUMANode` 标准常量。**方向判断**:OpenFuyao 的 DRA 正在把"传统 device-plugin 扩展资源名的申请体验"用 DRA 后端重新实现,这正是我们做 device-plugin→DRA 迁移时最关心的"旧 UX 零改写、后端换 DRA"路径。
- **昇腾 Ascend 950 新一代 NPU 全栈适配同步铺开**:vNPU(设计 0002)、npu-dra-plugin(`ascend-950-dra-adaptation` 设计稿 !53)、mind-cluster(`npu.ext.huawei.com` 扩展资源名 `huawei.com/npu`)三处同时落 950 适配。昇腾专用,但说明其硬件代际更替是"设计先行、DRA 为默认接入面"——950 的接入直接走 DRA/扩展资源名,而非新造 device-plugin。
- **两条"运行时/调度"实质能力**:(1)Volcano 故障退避新增**第三类——亚健康资源退避**(亚健康 NPU 芯片含公共故障芯片 + 交换机亚健康节点),新注解 `huawei.com/subhealthy.tolerance.after-time`,默认 10s 窗口,仅整卡任务生效、交换机亚健康节点在预选期整节点拦截;(2)**SandboxSched**——一个专给 AI Agent sandbox 做低时延生命周期调度的独立引擎(OpenSandbox 的运行时后端)本周高强度迭代,节点级 NoSchedule drain + 账本驱动弹性伸缩。官方公告侧本窗口静默(CSDN 仍停 10-18)。

## 新功能 / 能力

- [mind-cluster DRA 支持 KEP-5004 扩展资源名申请整卡](https://gitcode.com/Ascend/mind-cluster)(2026-10-29,`feat(dra): KEP5004特性-使用extend_resource_name申请未切分物理整卡`,feb3c0b)——DRA driver 的 YAML 现在一次创建 5 个 DeviceClass:`npu.huawei.com`(整卡,无扩展名)、`static-vnpu.huawei.com`(静态 vNPU)、`dynamic-vnpu.huawei.com`(动态硬切分)、`ascend910.ext.huawei.com`(扩展名 `huawei.com/Ascend910`)、`npu.ext.huawei.com`(扩展名 `huawei.com/npu`,Ascend950 系列)。
  - **核心变化**:只有带 `extendedResourceName` 的两个类,业务才能在 Pod 的 `resources.requests`/`limits` 里**直接写 `huawei.com/Ascend910` 申请整卡,无需 ResourceClaimTemplate**;要求 K8s 1.36+、`DynamicResourceAllocation`+`DRAExtendedResource` 门控开启、调度器为 kube-scheduler。DeviceClass 由 YAML 建、driver 启动时不同步;同名但签名不同的旧对象不会被覆盖,需手动删。
  - **对比**:这是上游 `DRAExtendedResource`(让 DRA 设备也能被当作经典 extended resource 申请)在昇腾侧的首次落地,走的是**标准上游路径**,不是自造语法。概念上等价于"device-plugin 的 `nvidia.com/gpu: 1` 申请体验,但底层换成 DRA ResourceSlice/DeviceClass"。
  - **启示**:这正是我们做 device-plugin→DRA 迁移最想要的过渡形态——**存量 workload 的 `resources.requests: vendor/gpu` 写法零改动,后端悄悄换成 DRA**,避免逼业务全量改写成 ResourceClaimTemplate。建议直接对照其 DeviceClass 分层(整卡/静态 vNPU/动态 vNPU/扩展名整卡)设计我们自己的 DeviceClass 命名与扩展名映射。

- [npu-dra-plugin 修复整卡独占多 Claim pending 错误 !42](https://gitcode.com/openFuyao/npu-dra-plugin)(2026-11-02,f065435,`fix:修复在整卡独占情况下多Pod/多独立Claim时 pending 的错误`)——整卡 full 模式下,之前误把设备报成"可共享容量"(`AllowMultipleAllocations=true` + `Capacity`),导致多个独立 Claim 里第二个常年 pending(调度器报 "cannot allocate all claims"),即使还有空闲 npu-*。修法:新增 `applyExclusiveWholeCardReporting` 把 full 模式设备的 `AllowMultipleAllocations`/`Capacity` 清空,让每张整卡成为一对一独占 DRA 设备;硬切分 vNPU 才保留 consumable-capacity 共享。注释明确指向上游 kubernetes#133705。
  - **启示**:非常具体的 DRA 建模坑——**"整卡独占"必须报成 exclusive device(不带 Capacity/AllowMultipleAllocations),"可切分共享"才报 consumable capacity**,两者混用会让调度器把独占卡当共享容量算,触发多 Claim 分配失败。我们自研 DRA driver 时的 ResourceSlice 建模要照此严格区分独占/共享两类,并补对应的多-Claim 回归用例。

- [npu-dra-plugin NUMA 属性对齐上游标准常量 !48](https://gitcode.com/openFuyao/npu-dra-plugin)(2026-10-28,32fc8e9,`feat: 支持k8s 1.37规范，增加resource.kubernetes.io/numaNode属性`)——把设备 NUMA 属性键从手写字符串 `"resource.kubernetes.io/numaNode"` 换成上游 `k8s.io/dynamic-resource-allocation/deviceattribute.StandardDeviceAttributeNUMANode` 常量(整卡与软切分 vNPU 两处都改)。
  - **启示**:小而正确的上游跟随——**DRA 标准化设备属性(NUMA 等)开始由上游库提供常量,别再手写字符串**,否则上游键名/语义演进时会静默漂移。我们 DRA driver 的属性上报应直接依赖 upstream `deviceattribute` 包。

- [Volcano 新增第三类故障退避:亚健康资源退避](https://gitcode.com/Ascend/mind-cluster)(2026-10-28,312006f,`支持基于时长的亚健康退避`,volcano 侧 ~25 文件)——在既有"静默故障芯片 / Pod 错误芯片"两类退避之上,新增**亚健康资源**:亚健康 NPU 芯片(含公共故障涉及的芯片)+ 交换机亚健康的节点。
  - **机制**:新注解 `huawei.com/subhealthy.tolerance.after-time`(秒),**默认窗口 10s**:任务等待在窗口内时调度器不把它放到亚健康资源上,超窗后放行;临时退避不支持 -1 永久禁止;**仅整卡调度任务生效,vNPU 任务暂不支持**;生效前提是任务 `subHealthyStrategy` 标签为 `ignore` 或不配;**交换机亚健康节点在预选阶段整节点拦截**(其余按芯片粒度剔除候选)。
  - **对比/启示**:延续前几周"基于时长的二段式故障退避"主线,现在把"网络域(交换机)亚健康"也纳入同一退避框架。通用可借鉴点:**把"故障事实"(静默/Pod错误/亚健康/交换机)与"是否避让"的决策解耦成按任务配置的时长窗口**,且区分"芯片粒度剔除候选" vs "节点粒度预选拦截"(网络域故障必须整节点拦,因为同节点所有卡共享交换机)。我们 GPU/网络故障调度可照此分层。

- [SandboxSched:AI Agent sandbox 专用低时延调度引擎](https://gitcode.com/openFuyao/SandboxSched)(本周高强度迭代,!67~!75)——OpenSandbox 的运行时后端(不直接对外暴露 API,经 OpenSandbox Server 的 `flux` runtime 用 gRPC 消费),面向 AI agent workload 的低时延、高吞吐 sandbox 生命周期管理。
  - **架构**:v1 演进后控制面合并成单个多活组件 `flux-sandbox-scheduler-evolution`(FastPath HTTP :9090 / SandboxProvider gRPC :9091 / agent 心跳 :9092),多副本共享 **MySQL intent ledger(CAS 状态机)+ Redis view layer**(liveness/自描述/容量仲裁),周期任务只在 Lease holder 跑;数据面 `flux-sandbox-agent` 经 runtime API(containerd / E2B)管实例;`sandbox-watcher` DaemonSet 清理孤儿 sandbox。
  - **本周重点**:!73 节点级 NoSchedule sandbox drain + 账本驱动弹性伸缩;!75 冷启动心跳窗口内不误判创建;!68/!70/!71 viewlayer 对 draining agent 的候选剔除、并发创建打散、镜像引导;!63 心跳过期误判 Lost 修复。
  - **对比/启示**:这是一条**不同于 KServe/K8s Pod 调度**的路线——为 agent sandbox(秒级起停、E2B 式隔离环境)**单独造调度器**,用"意图账本 + 视图层"而非 etcd/kube-scheduler 来扛高频短生命周期创建。对标对象是 E2B / Firecracker sandbox orchestration,不是模型推理服务。**启示**:如果我们要做 agent 执行沙箱/代码解释器的资源面,K8s 原生调度在"秒级高频短命"场景下不合适,这套"CAS 账本 + Redis 视图 + 多活控制面 + 心跳驱动 Lost 判定"值得作为自研 sandbox 调度的参照;但需评估引入 MySQL+Redis 外部依赖的运维成本。

- [openfuyao-powers 新增 API 文档一致性门禁技能 !75](https://gitcode.com/openFuyao/openfuyao-powers)(2026-10-27,3b82cf5,`feat(skills): add openapi-doc-check and code-doc-consistency-check`,+1938)——两个新 agent 技能:`openapi-doc-check`(用 spectral lint OpenAPI 规范 + breaking-change diff)与 `code-doc-consistency-check`(从代码生成 swagger、与文档做分层 diff/breaking 检测、门禁规则)。
  - **启示**:延续前两周"把研发/评审流程做成可复用 agent 技能"的组织下注,这次聚焦**API 文档与代码一致性门禁**。硬件无关,是"AI 原生软件工程"方向;若我们内建研发助手,这套"OpenAPI 规范 lint + 代码↔文档 breaking diff 作为 CI 门禁"的技能可直接参照。

## AI 推理栈(InferNex / hermes-router / weight-dispatcher)
- **InferNex / hermes-router / weight-dispatcher / cache-indexer 本窗口均无 in-window 实质提交**(InferNex 最新仍是 10-24 的 infernex-deploy skill,上期已覆盖)。
- [mind-cluster 适配 infer-operator podautoscalers CRD](https://gitcode.com/Ascend/mind-cluster)(2026-10-29,dd289c7,`feat(helm): adapt infer-operator podautoscalers CRD`)——helm 部署工具把 infer-operator 的 `podautoscalers` CRD 纳入渲染。信号:**昇腾推理 operator 开始带自动扩缩容 CRD**(方向与 KServe/Knative 的 revision autoscaler 同类,但走自定义 operator 而非 KPA/HPA)。仅 helm 适配,控制器逻辑未在本仓。
- [mind-cluster verl 弹性推理容错资料适配 verl 0.9.0](https://gitcode.com/Ascend/mind-cluster)(2026-10-28,4b7425b)——弹性 RL 推理容错文档跟进上游 verl 0.9.0(纯资料)。说明其在跟 RLHF/RL 训练-推理一体的上游(verl)做容错对接。
- [sig-ai-inference 补 InferNex 安装前集群/依赖文档 !225](https://gitcode.com/openFuyao/sig-ai-inference)(2026-10-31,fafd471)——纯文档,InferNex 安装前置准备。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)
- **Ascend 950 全栈适配**(昇腾专用,设计稿为主):vNPU `docs/design/0002-support-Ascend-950.md`(!95,10-27);npu-dra-plugin `doc/ascend-950-dra-adaptation.md`(!53,10-27);mind-cluster `npu.ext.huawei.com` DeviceClass(扩展资源名 `huawei.com/npu`)对应 950 系列整卡。950 的接入默认走 DRA/扩展资源名。
- [vNPU 软切分优先级抢占设计细化 !96](https://gitcode.com/openFuyao/vNPU)(2026-10-28,055e153,`docs/design/0003-support-VNPU-Priority-Preemption.md`)——上期 npu-dra-plugin 侧提出的"软切分 vNPU 算力优先级抢占"在 vNPU 仓补齐完整设计并细化:
  - **两级放置串行决策**:节点级排序(节点已有高优先级任务数升序 → 节点可用剩余算力降序)定目标节点,设备级排序(卡上高优先级 vNPU 数升序 → 卡剩余算力降序)在该节点内定目标卡;高优先级不占算力配额、算力永不阻塞在线调度,显存+单卡切分数(20)为仅存硬约束;旧 binpack/spread 注解对普通优先级照常、对高优先级整体被本策略取代。
  - **旧版 vCANN 兼容已验证**(非"待验证"):按旧版 vCANN 源码确认 `load_config` 对未知键 `vnpu_priority` 仅告警不中断、`check_config` 只校验六个既有必填键——"新 device-plugin + 旧 vCANN"灰度组合功能正常,高优先级固定值 `aicore-quota=0`/`sched_policy=3` 旧 vCANN 按 best-effort 跑。
  - **可观测**:新增 `xpu_vnpu_priority` 指标(Gauge,vNPU 粒度,值 0/1,复用 `vnpuLabel` 标签集),给出 PromQL 示例(`count by (node_name) (xpu_vnpu_priority==1)` 监控每节点在线 vNPU 数)。
  - **对比/启示**:仍严格走"优先级编码进 DeviceClass 名 / 抢占下沉 vCANN 时间片层 / K8s 不驱逐只透传契约"的上游 DRA 分层(见上期)。本周新增的通用可借鉴点:**混部可观测要按"资源粒度=消费者粒度"(vNPU 粒度而非设备粒度)输出优先级指标**,否则同卡混部时设备级单值无意义;以及**"旧数据面兼容性要拿旧版源码逐行验证而非假设"**这条工程纪律。
- [mind-cluster 修复 DRA ResourceSlice 上报 DCMI 显存容量](https://gitcode.com/Ascend/mind-cluster)(2026-10-28,4cc4743,`【BUG】DRA流程中ResourceSlice上报DCMI-memorysize的问题`)——DRA 链路里 ResourceSlice 的显存容量取自 DCMI 的修正。说明 DRA 侧容量上报在逐步对齐 device-plugin 的口径。
- [mind-cluster DRA 部署与 device-plugin 互斥校验](https://gitcode.com/Ascend/mind-cluster)(2026-10-29,04e7801,`dra资料修正与helm部署与dp互斥`)——helm 新增 `validate-mutex.yaml`,强制 **DRA 部署与 device-plugin 部署互斥**(同节点二选一)。合理:同一批 NPU 不能同时被两套资源管理面接管。我们做 DRA 灰度时同样要加这类部署期互斥护栏。
- [mind-cluster NPUHandler 适配静默故障退避](https://gitcode.com/Ascend/mind-cluster)(2026-10-30,9a3cb7b,`NPUHandler中没有适配静默故障退避，导致chipX-nodeY策略无法退避`)——修复 chipX-nodeY 粒度退避策略在 NPUHandler 未生效的问题,是上述退避框架的补齐。
- `npu-operator`(openFuyao 侧)、`npu-container-toolkit`、`ub-network-device-plugin`、`kae-operator`、`elastic-scaler`、`eagle-eye`(仅观测增强,见下)本窗口无昇腾资源能力级新提交。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)
- **亚健康退避(mind-cluster 312006f)+ SandboxSched 弹性伸缩**为本窗口调度侧两大实质信号,见上。
- [mind-cluster 推理任务 external-force-pod-failed 场景不记入重调度原因](https://gitcode.com/Ascend/mind-cluster)(2026-10-30,3079efa + 10-31 文档 748821c)——推理任务被外部强制杀 Pod(`external-force-pod-failed`)时,重调度原因不计入 `job-reschedule-reason` configmap,并补文档说明该场景不支持静默故障检测。属故障语义收敛:区分"外部人为杀 Pod" vs "真故障",避免误判故障统计。
- [mind-cluster pod 故障时间为 0 不算故障 / pod error 默认退避时长改 0](https://gitcode.com/Ascend/mind-cluster)(2026-10-28,7c9fa21)——Pod 错误退避默认值从非 0 改为 0(默认不降级),且故障时间为 0 视为未发生故障。是上期 pod-error-time 节点化的默认行为调整。
- [cluster-api-provider-bke 集群状态流转引擎 phase 2 + 安全加固 !503/!511](https://gitcode.com/openFuyao/cluster-api-provider-bke)(2026-10-27~29)——BKECluster 生命周期:引入集群状态流转引擎(phase 2)、master 凭据与 RBAC 安全加固、worker kubelet 指向本地 `kubelet.conf` 而非 `admin.conf`(!512,最小权限修正)。属 SIG-installation 集群编排面,通用 Cluster API 实践。
- `volcano-ext`(openFuyao 侧)、`sig-orchestration-engine` 本窗口无 in-window 实质提交。

## 官方动态
- **本窗口(10-27~11-02)无新官方公告/发版**。CSDN 官方博客最新仍是 10-18 的三篇技术讲堂(权重分发加速 / 众核编排 / 容器虚拟机共管)+ 10-18 的"2026 年 8-9 月社区运作报告",均上期已覆盖。官网 www.openfuyao.cn 新闻/博客/活动板块仍"暂无内容"(符合历史:发布以 CSDN 为准)。
- 代码侧 mind-cluster 唯一 tag 仍为 `v26.3.0-beta.1`(无前进),本周为 26.3.0 周期内的 bugfix/develop 合流(DRA、volcano 退避、FD 诊断项、device-plugin Flex 机型端口恢复等),非社区能力发版。
- [eagle-eye 观测增强 !40/!41](https://gitcode.com/openFuyao/eagle-eye)(2026-10-27/31)——DaemonSet exporter 加节点标签做节点级指标标识;tracing 部署加时钟同步检查。可观测子项目(Eagle Eye)的工程完善。

## 跟我们产品的对比
- **同一路线(该对齐)**:
  - **DRA 扩展资源名(KEP-5004)**:让 workload 用 `vendor/gpu: 1` 的经典写法申请整卡、后端走 DRA——这是 device-plugin→DRA 迁移期"存量零改写"的关键过渡形态,我们应优先实现而非强推 ResourceClaimTemplate。
  - **整卡独占 vs 共享的 DRA 建模**:独占必须报 exclusive device(无 Capacity/AllowMultipleAllocations),共享才报 consumable capacity;混用触发多-Claim pending(kubernetes#133705)。
  - **NUMA 等设备属性用上游 `deviceattribute` 标准常量**,别手写字符串键。
  - **故障退避三层解耦**(故障事实 / 时长窗口决策 / 芯片粒度 vs 节点粒度拦截),网络域故障整节点拦——通用 GPU+网络故障调度可照搬。
  - **混部可观测按消费者粒度输出优先级指标**、**旧数据面兼容拿源码逐行验证**——两条工程纪律。
  - **DRA 与 device-plugin 部署期互斥护栏**(同节点二选一)。
- **分叉 / 昇腾或场景专用(记录不照抄)**:Ascend 950 代际适配、vCANN 时间片优先级抢占、DCMI 显存口径、交换机亚健康(依赖 UB/昇腾网络拓扑)、infer-operator 自研 autoscaler CRD(非 KPA/HPA)。
- **我们该补 / 该警惕**:
  - **Agent sandbox 资源面**:SandboxSched 证明"秒级高频短命 sandbox"不适合 K8s 原生 Pod 调度,需要独立调度器(CAS 账本 + 视图层 + 心跳 Lost 判定)。如果我们要做 agent 执行环境/代码解释器,这是一条必须单独评估的架构线,不能默认套 KServe/Pod。
  - **DRA 迁移别逼业务改 YAML**:优先把扩展资源名申请路径(DRAExtendedResource)打通,DeviceClass 分层(整卡/静态 vNPU/动态 vNPU/扩展名整卡)照其设计。
  - **推理 autoscaler 走自定义 CRD 还是复用 KPA/HPA**:OpenFuyao 选了自研 `podautoscalers`,我们要想清楚是否也脱离 Knative/HPA 另起一套,以及与上游生态的兼容代价。

## 值得跟进
- [ ] 读 mind-cluster DRA `ascend-dra-driver.yaml` 里 5 个 DeviceClass 的定义与 `extendedResourceName` 配置,拆解 KEP-5004 在昇腾侧的实现(扩展名 → ResourceSlice 容量 → kube-scheduler 分配),对照我们 device-plugin→DRA 迁移的"扩展资源名兼容层"设计。
- [ ] 拆解 npu-dra-plugin !42 `applyExclusiveWholeCardReporting`,把"整卡独占 vs 切分共享"的 ResourceSlice 建模差异 + 多-Claim 回归用例纳入我们 DRA driver 测试基线(对照 kubernetes#133705)。
- [ ] 评估 SandboxSched 架构(intent ledger CAS 状态机 + Redis view layer + 多活控制面 + 心跳 Lost 判定),判断我们 agent 执行沙箱资源面是否需要独立调度器,以及 MySQL+Redis 外部依赖的运维取舍。
- [ ] 跟进 infer-operator `podautoscalers` CRD 的控制器实现(本周仅 helm 适配),看它是 KPA/HPA 风格还是自定义指标驱动,评估我们推理自动扩缩容选型。
- [ ] 跟踪 vNPU 软切分优先级抢占从设计(!96)到代码落地,对照我们 GPU 共享在离线混部 QoS 的抢占语义与优先级指标(xpu_vnpu_priority 粒度)。
- [ ] 持续监测 CSDN 是否发布 v25.12 LTS / v26.12 预告(季度发版节奏,年底 LTS 窗口)。

## 原始材料

<details>
<summary>本次扫描清单(2026-10-27 -> 2026-11-02)</summary>

有信息量:
- https://gitcode.com/Ascend/mind-cluster
  - 2026-10-29 feb3c0b feat(dra): KEP5004 特性-使用 extend_resource_name 申请未切分物理整卡(新增 ascend910.ext/npu.ext 等 5 个 DeviceClass,扩展资源名 huawei.com/Ascend910、huawei.com/npu;K8s 1.36+ DRAExtendedResource 门控)
  - 2026-10-28 312006f 支持基于时长的亚健康退避(第三类故障退避:亚健康 NPU 芯片 + 交换机亚健康节点;注解 huawei.com/subhealthy.tolerance.after-time 默认 10s;仅整卡,交换机亚健康整节点预选拦截;~25 文件)
  - 2026-10-28 4cc4743 【BUG】DRA 流程 ResourceSlice 上报 DCMI 显存容量修正
  - 2026-10-29 04e7801 dra 资料修正 + helm 部署与 device-plugin 互斥(validate-mutex.yaml)
  - 2026-10-29 dd289c7 feat(helm): 适配 infer-operator podautoscalers CRD
  - 2026-10-30 9a3cb7b 【volcano 26.3.0】NPUHandler 适配静默故障退避(chipX-nodeY 策略)
  - 2026-10-30 3079efa 推理 external-force-pod-failed 不记入 job-reschedule-reason configmap(+ 10-31 748821c 文档:该场景不支持静默故障检测)
  - 2026-10-28 7c9fa21 pod 故障时间为 0 不算故障 / pod error 默认退避时长改 0
  - 2026-10-28 4b7425b verl 弹性推理容错资料适配 verl 0.9.0
  - 2026-10-28 ae3236d device-plugin Flex 机型 5808 重启 NPU 端口恢复不一致导致 1002 隔离误报修复
  - mind-cluster tag 仍 v26.3.0-beta.1(无前进)
- https://gitcode.com/openFuyao/npu-dra-plugin
  - 2026-11-02 !42 f065435 fix 整卡独占多 Pod/多独立 Claim pending 错误(applyExclusiveWholeCardReporting 清 AllowMultipleAllocations/Capacity;对应 kubernetes#133705)
  - 2026-10-28 !48 32fc8e9 feat 支持 k8s 1.37,NUMA 属性切上游 StandardDeviceAttributeNUMANode 常量
  - 2026-10-27 !53 f4b6f12 add dra plugin support Ascend 950PR(doc/ascend-950-dra-adaptation.md +121)
- https://gitcode.com/openFuyao/vNPU
  - 2026-10-28 !96 055e153 软切分 vNPU 优先级抢占设计细化(两级放置、旧 vCANN 兼容已验证、xpu_vnpu_priority 指标 + PromQL)
  - 2026-10-27 !95 6282df8 support Ascend 950(docs/design/0002-support-Ascend-950.md +122;并建 0003 设计 +225)
- https://gitcode.com/openFuyao/SandboxSched
  - 2026-10-29~11-02 !61~!75 OpenSandbox 运行时后端;!73 节点级 NoSchedule drain + 账本驱动弹性伸缩;!75 冷启动心跳窗口;!68/!70/!71 viewlayer 候选剔除/并发打散/镜像引导;!63 心跳过期误判 Lost 修复
- https://gitcode.com/openFuyao/openfuyao-powers
  - 2026-10-27 !75 3b82cf5 新增 openapi-doc-check + code-doc-consistency-check 技能(API 文档↔代码一致性门禁,spectral lint + breaking diff;+1938)
- https://gitcode.com/openFuyao/cluster-api-provider-bke
  - 2026-10-27 !503 集群状态流转引擎 phase 2;2026-10-29 !511 master 凭据/RBAC 安全加固;2026-10-31 !512 worker kubelet 指向本地 kubelet.conf
- https://gitcode.com/openFuyao/eagle-eye
  - 2026-10-27 !40 exporter DaemonSet 加节点标签;2026-10-31 !41 tracing 部署加时钟同步检查
- https://gitcode.com/openFuyao/sig-ai-inference
  - 2026-10-31 !225 补 InferNex 安装前集群/依赖文档
- https://gitcode.com/openFuyao/sig-installation
  - 2026-10-29 !274 co-deployment FAQ 用 nerdctl rm -f 清 k3s 容器(文档)
- https://gitcode.com/openFuyao/docs
  - 2026-10-29 !1492 修改 vnpu 场景示例 yaml 镜像 + 新增 runtimeClassName 字段;2026-10-27 !1494 修 helm install --generate 无效 flag(文档)

官方源:
- https://blog.csdn.net/openFuyao —— 本窗口无新文章,最新仍为 10-18 三篇技术讲堂 + 8-9 月社区运作报告(上期已覆盖)
- https://www.openfuyao.cn/zh/ —— 新闻/博客/活动"暂无内容"

本窗口无 in-window 实质提交:
- https://gitcode.com/openFuyao/InferNex(HEAD 10-24 infernex-deploy skill)
- https://gitcode.com/openFuyao/hermes-router、weight-dispatcher、cache-indexer、elastic-scaler
- https://gitcode.com/openFuyao/npu-operator、kae-operator、npu-container-toolkit、ub-network-device-plugin
- https://gitcode.com/openFuyao/volcano-ext、sig-orchestration-engine

tag:mind-cluster v26.3.0-beta.1(无前进);vNPU v0.1.0;npu-dra-plugin v26.6.0;本窗口各仓无新 release/tag。
</details>
