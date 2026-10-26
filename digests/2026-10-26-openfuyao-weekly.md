# OpenFuyao 周报 2026-10-26

窗口:2026-10-20 -> 2026-10-26(7 天)

## 摘要(3 条以内)
- **OpenFuyao 这周集中押注"agentic 运维/研发":InferNex 把"一键部署"做成了 Agent Skill(!245,10-24,3304 行),openfuyao-powers 同步扩充多 Agent 研发技能(!76/!77,10-20)**。InferNex 仓里塞了一个 Claude-Code 风格的 `infernex-deploy` SKILL.md —— 用确认门(C1 配置→C2 预检深度→C3 报告确认→C4 交付)、数据化预检(`checks.yaml` + `preflight_run.py`)、确定性渲染(`render_values.py` 从 intent 生成 values、禁止手改)把 LLM 驱动的 Helm 部署约束成"带硬护栏的 agentic ops";openfuyao-powers 则在 skills(code-reviewer/cve-fixer/design-reviewer/repo-insight)与 multica 多 Agent 小队(design-coding / defect-fix / test squad)之上又加了"开源项目代码架构分析"和"oFEP 提案索引分析"技能。**部署/研发范式信号**:KServe/OAI 走声明式 CRD + GitOps,OpenFuyao 在其上叠了一层带门禁的 Agent 编排层 —— 技能工程本身硬件无关,值得我们在"助手式运维/研发"方向上对标。
- **npu-dra-plugin 公布软切分 vNPU 算力优先级抢占 DRA 设计(!54,10-20)**:在线/离线混部下,离线任务用软切分 vNPU 填满空闲 AICore,新增 vCANN `vnpu_priority` 能力 —— 高优先级 vNPU 有任务时在**时间片层即时抢占同卡所有低优先级 vNPU(含 fixed-share 保底),不驱逐 Pod**。DRA 侧新增 `priority.npu.huawei.com` DeviceClass,优先级编码进类名前缀(与既有 `elastic./fixed./best-effort.` 同构),CEL 不匹配 schedulingPolicy 以允许任意 soft 卡混部。**与我们 GPU 共享 QoS 选型强相关**:走的是上游 DRA 标准路径,分叉只在设备侧(vCANN 时间片隔离);显存仍是硬隔离不可抢占。
- **官方侧本窗口静默**:CSDN 官方博客最新仍停在 10-18 三篇技术讲堂 + v26.09 公告(上期已覆盖),本窗口无新发版/新公告。代码侧 mind-cluster 以 26.2.0 文档和 volcano 故障退避重构为主,无新 release/tag。

## 新功能 / 能力

- [InferNex infernex-deploy Agent Skill !245](https://gitcode.com/openFuyao/InferNex)(2026-10-24,`feat(skills): add infernex-deploy agent skill`,26 文件 +3304)——一个随仓发布的部署技能(SKILL.md v1.4.0),覆盖环境采集→intent 确认→预检→helm 安装/升级→网关推理验证→卸载全链路。工程要点:
  - **硬门禁不可跳过**:C1(配置确认)→C2(预检深度,硬件 checker 默认跳过、连通性 ping 默认关)→C3(预检报告确认,通过后仍须确认才部署)→C4(交付);卸载必经 U1(仅 helm uninstall / 全部清理 / 取消 三点选)。门的问题与选项**逐字**来自 `gates.md`,禁止 LLM 改写。
  - **判定数据化、渲染确定性**:预检清单/触发条件/判定命令全部数据化在 `references/checks.yaml`,由 `preflight_run.py` 执行产出 `preflight-report.json/.md`,**禁止 LLM 按自然语言自行判定或改报告措辞**;values 的模式/拓扑/模型/命名字段**只能**由 `render_values.py` 从 intent 生成(内嵌自检 + golden UT),禁止手改。
  - **成功判据是真推理**:Pod Running 不算完成,必须经网关 `POST /v1/chat/completions` → 200(默认 30088 端口)才算交付。内置 aggregated / PD 两类模型规格(glm-5.2-w4a8c8/w8a8、qwen3-8b、deepseek-v4-flash、minimax-m2.7、qwen3-coder-30b-a3b)和 `npu_capacity.py` 做 NPU 容量规划。
  - **对比**:这是把"部署专家知识"固化成 agent 可执行流程 + 硬护栏,区别于 KServe/OAI 的纯声明式 CRD。约束 LLM 不乱来的几招(门措辞逐字、判定走执行器而非自然语言、关键字段只由脚本确定性渲染)是通用的 agentic-ops 设计模式。
  - **启示**:如果我们要做"助手式/一键式推理部署",这套"确认门 + 数据化预检 + 确定性渲染 + 真实推理验证"的骨架可直接借鉴 —— 尤其"LLM 只负责交互与编排、关键配置由确定性脚本生成并自检"这条,能把 agent 部署的不可控性压到可审计。昇腾相关的只是 checker/npu_capacity 这几个硬件探针,框架本身硬件无关。

- [openfuyao-powers 扩充 agentic 研发技能 !76/!77](https://gitcode.com/openFuyao/openfuyao-powers)(2026-10-20)——社区的 AI 辅助研发"技能库":`repo-insight` 新技能(GitHub 开源项目代码架构分析 + PR/issue 证据采集脚本 `collect-*.ps1`/`query_evidence.py`,产出 design/evolution/trend 报告),及 oFEP 提案索引分析。仓内已有 skills(`code-reviewer`/`cve-fixer`/`design-reviewer`)和 multica 多 Agent 小队(`design-coding`/`defect-fix`/`test-squad`,含 lead/reviewer/inspector 角色)。
  - **启示**:与 InferNex 部署 skill 同源的信号 —— OpenFuyao 在把"研发/评审/缺陷修复/测试"流程做成可复用的 agent 技能与多 Agent 小队。硬件无关,是"AI 原生软件工程"方向的组织级下注;我们若要内建研发/运维助手,这套"skill + 多 Agent squad + 数据化证据采集"的组织方式可作参照(但要警惕其质量与可维护性尚未经验证)。

- [npu-dra-plugin 软切分 vNPU 算力优先级抢占设计 !54](https://gitcode.com/openFuyao/npu-dra-plugin)(2026-10-20,`doc/npu-soft-vnpu-priority-preemption-design.md`,+339)——面向在线/离线混部的 DRA 设计(设计稿,非代码):
  - **底层能力**:vCANN(`third_party/ubs-virt`)npu_info 新增 `vnpu_priority`(1 高 / 0 普通);高优先级生效时其余时间片策略全失效(core 配额/时间片置 0、sched_policy=3),**有任务即抢占同卡所有低优先级 vNPU(含 fixed-share 保底配额),空闲时低优先级恢复全部算力**。无 Pod 驱逐,时间片粒度即时生效。
  - **DRA 链路**:新增 DeviceClass `priority.npu.huawei.com`,优先级编码进类名前缀(与既有 `elastic./fixed./best-effort.` 策略前缀**完全同构**);priority 类 CEL **不匹配** schedulingPolicy,从而允许高优先级在线 Pod 与任意策略离线 Pod 同卡混部(解决既有三策略类 CEL 精确匹配阻止跨策略同卡的问题)。端到端:ResourceClaimTemplate → kube-scheduler(CEL + 容量扣减)→ kubeletplugin `extractPriority`(类名前缀)→ `writeConfigFile` 给 npu_info.config 追加 `vnpu_priority` → 容器内 vCANN 消费。
  - **边界**:只抢算力(AICore 时间片),**显存是硬隔离 memory-quota 不可抢占**;本期不让优先级参与 kube-scheduler 放置排序(不做高优先级打散/堆叠);config 容器启动前只读挂载,改优先级需重建 Pod/ResourceClaim;旧 vCANN 节点上退化为按声明配额跑的普通 vNPU,存量零影响。
  - **对比**:这是上期 DRA 动态 vNPU(硬切分)之后的软切分续篇,仍严格走 K8s DRA 上游范式(DeviceClass/CEL/CDI + 类名前缀编码参数),分叉只在设备侧(vCANN 时间片隔离)。概念上等价于 GPU 的 MPS/time-slicing + 优先级抢占,但 NVIDIA 侧 time-slicing 无硬件优先级、MPS 的 QoS 粒度更粗。
  - **启示**:我们做 GPU 共享(MPS/MIG/time-slicing)的在离线混部 QoS 时,这套"**优先级通过 DeviceClass 声明、抢占下沉到设备运行时时间片层、K8s 层不驱逐只透传契约**"的分层值得直接对标。关键取舍可抄:把优先级编码进 DeviceClass 名(取值天然合法、调度期可见、Prepare 期零成本解析)、算力可抢但显存硬隔离、优先级不改放置算法只改运行时时间片 —— 既拿到混部利用率又保在线 QoS,且不引入 Pod 驱逐抖动。

- [npu-dra-plugin DRA driver 内嵌 vNPU 指标采集设计 !54](https://gitcode.com/openFuyao/npu-dra-plugin)(2026-10-20,`doc/npu-dra-driver-metrics-design.md`,+212,关联 issue #35)——让 DRA kubeletplugin **内嵌** Prometheus 指标,暴露与 device-plugin 侧 `xpu-exporter` **同名、同 label、同语义**的 6 个指标(切分模式、软切分调度策略、vNPU 内存利用率、vNPU/Pod 数),Grafana 看板与告警直接复用;启动参数控制开关,默认关不改现有行为;**vNPU 仓零改动**,DRA 与 device-plugin 两场景各自独立提供可观测、契约一致。附带披露:硬切分生命周期从"委托 Ascend Docker Runtime"改为"driver 经 DCMI 直管"以消除残留清理缺陷。
  - **启示**:通用可借鉴的是"**把 exporter 内嵌进 DRA driver、复用其已有设备枚举/生命周期/claim-pod 关联状态,而不是再起一个独立 exporter**",并刻意保持与旧 device-plugin exporter 的指标契约一致 —— 这样监控栈在 device-plugin → DRA 迁移期可平滑切换。我们自研 DRA driver 时的可观测设计可照此:指标契约先于实现冻结,新旧数据面指标同名同义。

## AI 推理栈(InferNex / hermes-router / weight-dispatcher)
- **InferNex 本窗口唯一实质提交就是上面的 agent skill(!245)**;推理控制面、路由、权重分发的运行时代码无 in-window 变更。
- `hermes-router` 本窗口无 in-window 提交(HEAD 仍停在 10-14 !95 decode-first 文档,上期已覆盖)。
- `weight-dispatcher`、`cache-indexer` 本窗口无 in-window 提交。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)
- **软切分 vNPU 优先级抢占 + DRA 指标内嵌(npu-dra-plugin !54,见上)——本窗口昇腾资源侧最重要信号**,均为设计稿,代码待跟进。
- [mind-cluster DRA 文档补 exactly 字段](https://gitcode.com/Ascend/mind-cluster)(2026-10-24,b2313a2)——ResourceClaimTemplate 示例补 `exactly` 字段,与上游 DRA v1.34+ 的请求结构对齐(device.requests[].exactly)。纯文档,但说明昇腾 DRA 示例在跟上游 API 演进。
- `npu-operator`(openFuyao 侧)、`vNPU`、`kae-operator`、`npu-container-toolkit`、`ub-network-device-plugin`、`ubs-k8s-enable` 本窗口均无 in-window 实质提交。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)
- [mind-cluster volcano 重构 pod-error-time 设置方式 !5055](https://gitcode.com/Ascend/mind-cluster)(2026-10-26,1c5c3f5,10 文件 +108/-30)——把"Pod 失败故障卡"的记录从**按作业 cache 查 card 名**改为**节点级静态状态**:在 ChipTopo 的 leaf 上存 `podErrorTime`(chip-id → 失败 unix 秒),新增 `PodErrorChips()` / `SetPodErrorTimes()`,与 silent-fault 的存储方式统一(都是 node-level static state,是否扣留交消费方按作业容忍窗口判定)。是上期 !4909"基于时长的故障节点/Pod 二段式容忍降级"的内部收敛。
  - **对比/启示**:绑昇腾故障域(silent fault / pod-error 卡),但"**把故障卡状态下沉到节点级拓扑、把'是否因故障扣留'的决策交给作业级容忍窗口**"这个分层对通用 GPU 故障调度同样成立 —— 故障事实与容忍策略解耦,避免每个 session 重算、避免一节延迟。
- [mind-cluster 调度文档补"故障卡基于时长退避"小节](https://gitcode.com/Ascend/mind-cluster)(2026-10-25,9d81e33)——把上述时长退避机制写进调度章节文档。
- [sig-orchestration-engine K8s v1.35-v1.37 版本变更分析](https://gitcode.com/openFuyao/sig-orchestration-engine)(2026-10-20,!153)——更新众核编排对 K8s v1.35~v1.37 资源变更的跟踪分析(文档),说明其在持续跟进上游 K8s API 演进,无能力级变更。
- `volcano-ext`(openFuyao 侧)本窗口无 in-window 实质提交。

## 官方动态
- **本窗口无新官方公告/发版**。CSDN 官方博客最新仍是 10-18 的三篇技术讲堂(权重分发加速 / 众核编排 / 容器虚拟机共管)和 10-08 的 v26.09 发行公告,均上期已覆盖。官网/文档站发布渠道沿用历史:以 CSDN 为准(见历史记录)。
- 代码侧 mind-cluster 本窗口密集产出 26.2.0 版本文档/镜像发布说明(中英)与组件测试用例,属昇腾 upstream 版本资料工程,非 openFuyao 社区能力发版。
- 各仓本窗口无新 release/tag。

## 跟我们产品的对比
- **同一路线(该对齐)**:
  - **软切分 vNPU 优先级抢占**走 K8s DRA 上游标准(DeviceClass 名前缀编码优先级 / CEL 选设备 / 契约透传到设备运行时),抢占下沉时间片层、不驱逐 Pod、显存硬隔离不可抢 —— 我们 GPU 在离线混部 QoS 应对齐这套"声明在 DeviceClass、抢占在设备层、K8s 只透传"的分层。
  - **DRA driver 内嵌 exporter**(复用 driver 已有设备状态,指标契约与旧 device-plugin exporter 同名同义)—— device-plugin → DRA 迁移期的可观测平滑方案,我们自研 DRA driver 可照抄。
  - **infernex-deploy agent skill 的护栏设计**(确认门逐字、判定走数据化执行器、关键字段确定性脚本渲染并自检、真实推理才算成功)—— 做助手式/一键式部署时的通用 agentic-ops 骨架。
  - **volcano 故障卡状态节点化 + 容忍窗口决策解耦** —— 通用 GPU 故障调度思路。
- **分叉 / 昇腾专用(记录不照抄)**:vCANN `vnpu_priority` 时间片抢占、DCMI 直管硬切分生命周期、silent-fault 感知、`xpu_vnpu_*` 指标语义中的 dieID/AI Core 口径、26.2.0 昇腾版本资料。
- **我们该补 / 该警惕**:
  - DRA 共享设备的**可观测契约要先于实现冻结**,且新旧数据面(device-plugin/DRA)指标同名同义,否则监控栈迁移会断层。
  - 在离线混部别只做"配额隔离",要补"**算力可抢占 + 显存硬隔离**"的分级 QoS,且抢占尽量下沉设备运行时而非靠 K8s 驱逐(避免抖动)。
  - agentic 部署若要落地,**必须给 LLM 加确定性护栏**(关键配置脚本生成 + 自检、判定数据化、成功判据是真实业务探测)——这正是 OpenFuyao 这次 skill 的核心设计,值得抄。

## 值得跟进
- [ ] 跟踪 npu-dra-plugin 软切分优先级抢占**从设计稿到代码**的落地(`extractPriority` / `priority.npu.huawei.com` DeviceClass / npu_info.config `vnpu_priority` 写入),对照我们 GPU 共享 QoS 的抢占语义设计。
- [ ] 读 npu-dra-plugin DRA 指标内嵌实现(metrics server :8082、`vnpuCollector` 6 指标、采样缓存),评估我们自研 DRA driver 的可观测内嵌方案与指标契约冻结策略。
- [ ] 拆解 InferNex `infernex-deploy` skill 的 `gates.md` / `render_values.py` / `checks.yaml`,提炼"agent 部署硬护栏"骨架,评估移植到我们助手式部署的可行性。
- [ ] 跟进 mind-cluster volcano 故障卡时长退避(!5055 + 文档)后续是否补齐静默故障/Pod 失败卡的重启恢复对账,对照我们 GPU 故障隔离的二段式降级。
- [ ] 持续监测官方 CSDN 是否发布 v25.12 LTS / v26.12 相关预告(季度发版节奏,年底为 LTS 窗口)。

## 原始材料

<details>
<summary>本次扫描清单(2026-10-20 -> 2026-10-26)</summary>

有信息量:
- https://gitcode.com/openFuyao/InferNex
  - 2026-10-24 !245 feat(skills): add infernex-deploy agent skill(SKILL.md v1.4.0,确认门 C1-C4/U1、数据化预检 checks.yaml + preflight_run.py、确定性渲染 render_values.py、aggregated/PD 模型规格、npu_capacity.py;3304 行)
- https://gitcode.com/openFuyao/openfuyao-powers
  - 2026-10-20 !77 repo-insight skill(开源项目代码架构分析 + PR/issue 证据采集脚本;skills/repo-insight/*,+1773)
  - 2026-10-20 !76 oFEP 提案索引分析
- https://gitcode.com/openFuyao/npu-dra-plugin
  - 2026-10-20 !54 软切分 vNPU 算力优先级抢占设计(doc/npu-soft-vnpu-priority-preemption-design.md,vCANN vnpu_priority、priority.npu.huawei.com DeviceClass、时间片抢占不驱逐、显存不可抢;+339)
  - 2026-10-20 !54 DRA driver 内嵌 vNPU 指标采集设计(doc/npu-dra-driver-metrics-design.md,6 指标与 xpu-exporter 同名同义、metrics server :8082、硬切分改 DCMI 直管;+212,关联 issue #35)
- https://gitcode.com/Ascend/mind-cluster
  - 2026-10-26 !5055 [volcano] 重构 pod-error-time 设置方式(故障卡状态节点化:ChipTopo leaf podErrorTime、PodErrorChips/SetPodErrorTimes,与 silent-fault 统一;10 文件 +108/-30)
  - 2026-10-25 9d81e33 调度文档补"故障卡基于时长退避"小节
  - 2026-10-24 b2313a2 DRA 文档 ResourceClaimTemplate 示例补 exactly 字段(对齐上游 DRA 请求结构)
  - 2026-10-20~26 26.2.0 版本文档/镜像发布说明(中英)、FD 组件测试用例、clusterops-agent docker 目录等(版本资料工程)
- https://gitcode.com/openFuyao/sig-orchestration-engine
  - 2026-10-20 !153 更新 K8s v1.35-v1.37 版本变更分析(文档)

官方源:
- https://blog.csdn.net/openFuyao —— 本窗口(10-20~10-26)无新文章,最新仍为 10-18 三篇技术讲堂 + 10-08 v26.09 公告(上期已覆盖)

本轮无 in-window 实质提交(边界日 10-19 的 console-website !880 / sig-installation !273 FAQ / flux-sandbox !6 / sig-orchestration !151 上期已覆盖):
- https://gitcode.com/openFuyao/hermes-router(HEAD 10-14 !95)
- https://gitcode.com/openFuyao/weight-dispatcher、cache-indexer
- https://gitcode.com/openFuyao/npu-operator、vNPU、kae-operator、volcano-ext
- https://gitcode.com/openFuyao/npu-container-toolkit、ub-network-device-plugin、ubs-k8s-enable
- https://gitcode.com/openFuyao/sig-agent-sandbox、flux-sandbox(本窗口无新提交)

本窗口各仓无新 release/tag。
</details>
