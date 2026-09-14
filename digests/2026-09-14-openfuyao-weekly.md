# OpenFuyao 周报 2026-09-14

> 扫描窗口:2026-09-07 ~ 2026-09-14。主仓 GitCode `openFuyao` 组织 + 昇腾 upstream `ascend/mind-cluster`(本周 96 MR,继续为最高频)+ 官方 CSDN/官网。**非发版周,但本周落地一个方向性新组件**:`ascend-clusterops-agent`——把昇腾 ascend-faultdiag 包装成"**任务维度一键诊断 + 可选 LLM 智能总结**"的 K8s 集群运维 Agent(agent-core Deployment + node-collector DaemonSet + kubectl 插件),分 9 个 part 合入。其余主线:DRA 支持**静态 vNPU 发布与选择**(从只发物理 NPU 扩到预创建 vNPU 作独立可选设备)、`cache-indexer` KVCache 索引**纳入 decode pod**(PD 分离感知)、`cluster-api-provider-bke`/`bkeadm` 为 v26.09 收尾(nginx LB 模式 + 静态 pod 热更新 + 自管集群名继承)、跨仓协同的 **grpc CVE 安全升级**。官方无新 release、无新博客(仍停在 08-25 Agent Sandbox SIG)。新功能非空,正常出报并推送。

## 摘要(3 条以内)

- **落地 `ascend-clusterops-agent`:任务维度一键故障诊断 + 可选 LLM 总结的集群运维 Agent**。`ascend/mind-cluster` 本周分 9 个 part(!4616~!4623 等)合入全新组件:用户执行 `kubectl ascend_diag --job job-x` 即可自动完成"**采集 → 清洗 → 集中诊断 → 报告**"全流程——agent-core(Deployment,查任务→pod→node 映射、并发下发采集、聚合调 `ascend-fd diag` 出报告)+ node-collector(DaemonSet,按采集契约本地 `ascend-fd parse` 清洗回传)+ kubectl 插件。**关键设计**:LLM 总结(langgraph + langchain-openai,对接 OpenAI 兼容端点如 glm-4-plus)是**可选增强**,未配置时自动回退确定性诊断报告,不阻断主流程。**对标视角**:这是 AIOps/agentic-ops 落地——比 OpenShift Insights(云端遥测)更"现场化"(kubectl 插件 + 节点采集),LLM 只做报告总结不做决策。**诊断编排框架通用可借鉴,ascend-fd/plog 昇腾绑定**。 https://gitcode.com/ascend/mind-cluster
- **DRA 从"只发物理 NPU"扩到"发布并选择静态 vNPU"**。mind-cluster !4638 `支持静态vNPU设备发布与分配`:ascend-dra-driver 在 910A/910B-A2/910A3 枚举时查询**用户预创建的静态 vNPU**,发布为独立 DRA 设备并带 `deviceKind/vDevID/template/vnpuType/aicore` 属性,可按 vNPU 类型/模板/vDevID/AICore 选择;CDI 按设备名解析 vDevID 注入;**同一 Claim 混用物理 NPU 与静态 vNPU 会被拒绝**。这是 DRA 主线的实质推进——从设备直通迈向**切分设备的声明式选择**,与 K8s 上游 DRA partitionable devices 同向。同期 `cache-indexer`(KVCache 索引,oFEP-0053)!43 把 **decode pod 纳入 L1 索引**(PD 分离感知)、!47 接受 map 编码 KV 事件。**DRA 切分建模 + KV-aware 路由都通用可对标**。 https://gitcode.com/openFuyao/npu-dra-plugin
- **v26.09 集群侧收尾 + 跨仓 CVE 安全升级**。`cluster-api-provider-bke` 本周高频:!451 nginx 负载均衡模式(含升级路径)、!482 静态 pod 热更新、!485 bkeagent 日志级别可配、!488 自管集群/节点名从 bootstrap 继承、!491 master-join 只等 master agent ready、!489 BKENode 删除态处理;`bkeadm`/`e2e-auto-test` 同步跟进(nginx-proxy schema、self-managed name derive、etcd 健康检查重试)。同时 `hermes-router`/`npu-dra-plugin`/`ub-network-device-plugin` **同一周协同把 grpc 升到 v1.83.2 修 CVE-2026-84303/84304/84445**。信号:v26.09 集群生命周期在补 LB/热更新/自管命名,发版临近;依赖安全走跨仓协同修复。**集群生命周期能力通用可对标 OpenShift**。 https://gitcode.com/openFuyao/cluster-api-provider-bke

## 新功能 / 能力

- [ascend-clusterops-agent:任务维度一键诊断 + 可选 LLM 总结的集群运维 Agent](https://gitcode.com/ascend/mind-cluster) — mind-cluster 本周分 9 part 合入新组件(feat/clusterops_part1~9 + DT/UT for py3.9.11 + docs)。架构:**agent-core**(Deployment,`:9700` HTTP `/diag` + `:9710` gRPC,经 relcache 查任务→pod→`{node,poduid,rank}`、并发下发 TriggerCollect、聚合清洗产物调 `ascend-fd diag`、按需缓存);**node-collector**(DaemonSet,每 NPU 节点,`:9720` gRPC,按 `collect_manifest.yaml` entity 经 pathmap CM 匹配宿主路径、现场采集、本地 `ascend-fd parse` 清洗回传);**kubectl 插件**(`kubectl-ascend_diag` 走 port-forward 调 agent-core、`kubectl-clusterops` 管 LLM 配置,纯标准库无需 pip)。诊断输出直接给 `[Root Cause]` + 故障码 + 根因设备 + 建议;10 秒内重复走缓存,`--refresh` 强刷。
  - 启示:**本周最有产品价值的信号**。这是把"故障诊断"做成 **agentic 运维闭环**——用户只说"job X 有问题",Agent 自动跨节点采集/清洗/诊断。三个可借鉴点:①**任务维度而非节点维度**入口(`--job` 反查全部 pod/node),对分布式 AI 作业的运维语义正确;②**LLM 只做报告总结、可选、有确定性回退**——务实,不把 LLM 塞进决策链;③**采集契约(collect_manifest)+ pathmap CM** 把"采什么日志/在哪采"做成可配置契约。**编排框架 + 契约化采集通用可抄**,`ascend-fd`/plog/HCCS 故障码昇腾绑定。我们若做 AI 集群运维,这套"任务维度一键诊断 + LLM 可选总结"是明确的对标标的。
- [ascend-dra-driver:支持静态 vNPU 设备发布与分配](https://gitcode.com/openFuyao/npu-dra-plugin) — mind-cluster !4638。此前 Ascend DRA 只发布物理 NPU,无法把用户预创建的静态 vNPU 作为独立可选设备。本 PR:910A/910B-A2/910A3 枚举时查询已创建静态 vNPU,发布为独立 DRA 设备并带 `deviceKind/vDevID/template/vnpuType/aicore` 属性;增加 DCMI 模板名→公开 vNPU 规格名转换与校验;CDI 按设备名解析 vDevID 生成注入信息;无静态 vNPU 时保持物理 NPU 发布;同一 Claim 混用物理+静态 vNPU 被拒绝。
  - 启示:**DRA 主线实质推进**。从"设备直通"迈向"**切分设备的声明式属性选择**"——把 vNPU 的 type/template/AICore 做成 DRA 设备属性,让 ResourceClaim 按属性选切片。这与 K8s 上游 **DRA partitionable devices / device attributes selector** 同向,是我们 DRA 选型强相关的信号:昇腾在用 DRA 表达"细粒度切分设备 + 属性选择",不是只做整卡直通。"同 Claim 拒绝混用物理/vNPU"的约束也值得记(切分与整卡不可同 claim 混排)。
- [cache-indexer:L1 索引纳入 decode pod + 接受 map 编码 KV 事件](https://gitcode.com/openFuyao/cache-indexer) — !43 `include decode pods in L1 cache indexing`、!47 `accept map-encoded KV events in L1 ingest`。cache-indexer 是面向 LLM 推理的全局 KVCache 索引(L1=实例本地 HBM,订阅 vLLM ZMQ KV-event;L3=实例内存/SSD,轮询 Mooncake Master),在 Go 侧复刻 vLLM block hash 计算(token_ids/block_size/cache_salt/PYTHONHASHSEED 对齐),供路由做全局请求级 KV 命中调度(oFEP-0053)。
  - 启示:**通用可对标 llm-d/Dynamo 的 KV-aware 路由**。本周把 **decode pod 纳入 L1 索引**是 **PD 分离(prefill/decode 分离)感知**的关键一步——路由不仅看 prefill 实例的 KV,也看 decode 实例的 KV 命中,PD 分离部署下路由决策才完整。这与 hermes-router 构成"索引层(cache-indexer)+ 路由层(hermes-router)"的分层设计。我们做 KV-aware 路由可直接参考其"L1 订阅 KV-event + L3 轮询 Mooncake + Go 侧复刻 block hash 保持与引擎一致"的分层与一致性方案。
- [cluster-api-provider-bke:nginx 负载均衡模式 + 静态 pod 热更新](https://gitcode.com/openFuyao/cluster-api-provider-bke) — !451 `support nginx load balancer mode with upgrade`(nginx LB 模式含升级路径)、!482 静态 pod 热更新能力(改 clusterversion/upgradepath/command 升级链)、!485 bkeagent 日志级别经 `customExtra.agentLogLevel` 可配、!488 自管集群/节点名从 bootstrap 继承、!491 master-join 只需 master agent ready(不等 worker)、!489 BKENode 置 Deleting 后再删并允许 BKECluster 删除态下删节点。
  - 启示:**v26.09 集群生命周期收尾,通用可对标 OpenShift**。本周补的都是企业级集群管理刚需:控制面 LB 模式可选(nginx)+ 静态 pod 热更新(kube-apiserver 等静态 pod 不重建即更配置)+ 升级路径打磨。"静态 pod 热更新"尤其值得记——控制面组件配置变更不重建 pod,是 Day-2 运维平滑性的关键。配合上周的声明式升级,BKE 集群生命周期在向 OpenShift OTA/机器管理看齐。

## AI 推理栈(InferNex / hermes-router / cache-indexer)

本周推理栈**以工程化 + 安全为主,cache-indexer 是唯一有架构含义的动作**:

- **cache-indexer**:decode pod 纳入 L1 索引 + 接受 map 编码 KV 事件(见"新功能")——PD 分离感知的 KV-aware 路由推进,**本周推理栈最有价值项**。
- **hermes-router**:!92 grpc v1.80.0→v1.83.2 修 CVE(安全)、!90 修正 README 聚合架构路由策略名称(文档)。**窗口内无路由算法变更**,处于消化期(前两周的 KVCache 路由精调之后)。
- **InferNex**:!238 新增 **AIPerf 数据集生成脚本 + README**(perf 基准工具化)、!243/codecheck 修复。无功能性变更,补性能测试资产。
- **e2e-auto-test**:!482 更新 hermes-router 及 InferNex 各模块 e2e、!457 新增 flux-sandbox dataplane e2e suite——推理栈 e2e 为 v26.09 收尾。

架构定性不变:cache-indexer(L1 vLLM ZMQ / L3 Mooncake)= 索引层,hermes-router(建在上游 GIE 上)= 路由层,分层设计 ≈ llm-d(KV-aware)。本周推理栈**核心变化就是 cache-indexer 的 PD 分离感知**,其余为安全补丁 + 基准工具 + 发版对齐。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **DRA 静态 vNPU 发布与选择**(见"新功能")是本周 DRA 主线实质进展;另 !4581 dra 二进制打印 version+commitid、节点加 annotation、clusterD 收集 dra 组件版本信息(版本可观测性)。
- **UB 链路精细诊断继续收尾**:ub-p2/p3/p4(日志清洗增 ubctl_log 解析、cqe 错误故障识别、基于日志指标预判生成 flag)、故障模式库(FD)适配旧关键字匹配去重(!4650/!4652)、ub 故障判定关键字转小写(!4655)、sfu 光模块解析(!4651)、修全卡 UB 端口 down 偶现隔离故障 bug(!4587)。**纯昇腾/超节点(灵衢 UB)专用**,承接上周"网络健康进调度/诊断"主题,本周偏 bug 收敛。
- **Resilience Controller 日落 + Elastic Agent 改 taskd**:!4613 docs 移除已日落的 Resilience Controller 文档、`Elastic Agent已日落,修改为taskd`。**信号**:昇腾容错栈在做组件收敛——弹性/韧性相关旧组件下线,能力可能被 taskd / clusterops-agent / coordinator 等新组件吸收,值得下周确认收编关系。
- **infer-operator(mind-cluster 内)**:!4604/!4572 推理支持 Pod 重调度补充资料 + volcano 侧实现。承接上周判断:mind-cluster 自带 infer-operator 与 InferNex 是**两套推理编排**,定位差异仍需厘清。
- **npu-exporter**:!4632 无进程时仍上报空进程 id 的进程级指标(兼容原实现)、优化自定义指标样例。
- **acjob TTL 清理修复**:!4586 用正确的 job key 获取 TTL(修上周 TTL 自动清理的 bug)。
- **npu-operator**:!117 `adapt volcano scheduler plugin arch`(适配 volcano 调度插件架构),仅此一条,继续跟随 mind-cluster volcano 演进。
- **1825 场景 RDMA + 独占模式**:!4639 docs 挂载 rdma 设备/驱动描述、!4606 独占模式在共享模式组件开发 UT——承接上周 RDMA 独占模式,本周补文档 + UT。

## 调度 & 集群(volcano-ext / 超大规模 / 超节点)

- **volcano(mind-cluster 内)节点内通用亲和调度打分框架**:!4610/!4629 重构节点内亲和调度**打分框架 + 测试用例**、!4578 chip-affinity 资料。承接上周"节点内通用亲和(NPU+通算)",本周把它做成**可扩展打分框架**——往"一套调度器 + 可插拔打分"收敛,通用趋势可对标。
- **超节点扩型**:!4566 集群调度新增 **Atlas 950 SuperPoD Flex** 支持(承接上周 950-SuperPod-Flex)、ubs-k8s-enable !85 `SuperPod controller with two-source superPodId and SuperPod CRD`(**SuperPod 抽象为 CRD**,双源 superPodId)、ubs-openstack-enable !62 检测 **H2N 链路健康状态** + 补 type131 HDK 驱动适配文档。**纯超节点专用**,信号=超节点从"设备"上升为"CRD 管理对象"。
- **cluster-api-provider-bke / bkeadm**(见"新功能"):nginx LB + 静态 pod 热更新 + 自管命名继承 + master-join 优化,v26.09 集群侧收尾;bkeadm 同步 nginx-proxy schema、k3s bootstrap token 不再硬编码、preflight 配置化。
- **e2e-auto-test**(40 commit,持续高频):自管集群名派生对齐、bke nginx-proxy 负载均衡测试用例、flux-sandbox dataplane e2e、etcd 健康检查重试、kubescape 密码扫描、删除 many-core scheduler e2e。**v26.09 FIT/E2E 门禁在持续对齐新特性**。
- **volcano-ext(独立仓)**:窗口内**无提交**(上周仅文档改错字)。独立仓与 mind-cluster 内 volcano 的分工仍待厘清。
- **在离线混部**:`colocation-website`/kubevirt 窗口内**无实质提交**,**本周仍无进展**。

## 官方动态

- **无新版本 release**:v26.06(07-09)仍是最新公开季度版;官网 news/活动/博客栏目均"暂无内容"。v26.09 发版信号继续来自代码侧(e2e FIT 对齐 + bke nginx LB/静态 pod 热更新收尾),**官方尚无公告**。
- **无新官方博客**:CSDN `openFuyao` 最近一篇仍是 08-25 Agent Sandbox SIG(上周已报道),08-19 InferNex TTFT 优化。—— https://blog.csdn.net/openFuyao
- **组件收敛信号**:代码侧 Resilience Controller 文档日落、Elastic Agent 改 taskd、新立 ascend-clusterops-agent——昇腾运维/容错栈在做组件世代更替,官方尚未成文说明。
- **仓库观察**:`cache-indexer`(KVCache 索引,oFEP-0053)、`ubs-k8s-enable`/`ubs-openstack-enable`(超节点使能)本周有实质活动;未见全新立仓。`sig-installation`/`bkeadm` 高频(安装/CLI 收尾)。

## 跟我们产品的对比

| 能力维度 | OpenFuyao 现状(本周) | 与上游/我们的关系 |
|---|---|---|
| **AI 集群运维 Agent** | ascend-clusterops-agent:kubectl 任务维度一键诊断,采集契约 + 节点清洗 + 集中诊断,LLM 可选总结(有确定性回退) | **agentic-ops 落地**;编排框架通用可抄,ascend-fd 昇腾绑定;比 OpenShift Insights 更现场化 |
| **设备 DRA(切分)** | ascend-dra-driver 发布静态 vNPU 为独立 DRA 设备,按 type/template/vDevID/AICore 属性选择;拒绝同 claim 混物理+vNPU | **≈ K8s DRA partitionable devices / attribute selector**;DRA 选型强相关,通用可对标 |
| **KV-aware 推理路由** | cache-indexer L1 纳入 decode pod(PD 分离感知)、接受 map 编码 KV 事件 | **≈ llm-d/Dynamo KV-aware 路由**;分层(索引层+路由层)+ 引擎一致 block hash 通用可借鉴 |
| **集群生命周期** | bke nginx LB 模式 + 静态 pod 热更新 + 自管命名继承 + master-join 优化 | **≈ OpenShift OTA/机器管理**;静态 pod 热更新(控制面平滑变更)值得对齐 |
| 依赖安全 | 跨仓协同 grpc v1.83.2 修 CVE-2026-84303/84304/84445 | 通用;跨仓协同修复的工程纪律可参考 |
| 超节点抽象 | SuperPod CRD(双源 superPodId)、H2N 链路健康检测、Atlas 950 SuperPoD Flex | 昇腾专用;信号=超节点从设备升为 CRD 管理对象 |
| 统一调度 | volcano 节点内通用亲和**打分框架**重构(NPU+通算) | 往"一套调度器+可插拔打分"收敛,通用趋势可对标 |
| 网络健康诊断 | UB 链路精细诊断收尾(FD 故障模式库/cqe/sfu 光模块) | 纯昇腾/超节点;思路(网络健康作诊断/调度输入)可类比 |
| 合规加固 | compliance-operator 修 K8s 加固回退/健康检查 + UT 覆盖率 85.5% | ≈ OpenShift Compliance Operator;本周偏稳定性打磨 |
| 在离线混部 | 本周无实质进展 | — |

**我们该补 / 该警惕**:
- **AI 集群运维 Agent 是本周最该对标的一条**:ascend-clusterops-agent 把"故障诊断"做成 kubectl 任务维度一键闭环,且 **LLM 只做可选总结、有确定性回退**——这是 agentic-ops 的正确落地姿势(不把 LLM 塞进决策链)。我们若做 AI 集群运维,应对标"任务维度采集契约 + 节点端清洗 + 集中诊断 + LLM 可选总结"的编排框架,不必绑昇腾 ascend-fd。
- **DRA 切分选择模型要盯紧**:昇腾把静态 vNPU 做成带属性(type/template/AICore)的独立 DRA 设备、按属性选切片,与上游 DRA partitionable devices 同向。我们做 GPU DRA 选型时,"切分设备属性化 + ResourceClaim 属性选择 + 切分与整卡不同 claim 混排约束"是可直接参考的建模。
- **KV-aware 路由要覆盖 PD 分离**:cache-indexer 把 decode pod 纳入 L1 索引说明——PD 分离部署下,路由必须同时看 prefill 与 decode 实例的 KV 命中。我们做 KV-aware 路由不能只索引 prefill 侧。
- **静态 pod 热更新**:控制面组件配置变更不重建 pod 是 Day-2 平滑性刚需,若我们控制面变更仍需重启,值得评估热更新路径。

## 值得跟进
- [ ] 读 `ascend-clusterops-agent` 组件 README + `03_using_fault_diagnosis`/`04_configuring_llm` 文档,抽取"任务维度采集契约 + 节点清洗 + 集中诊断 + LLM 可选总结"编排框架,评估我们 AI 集群运维的对标:https://gitcode.com/ascend/mind-cluster
- [ ] 读 mind-cluster !4638 静态 vNPU DRA 实现,理解"切分设备属性化(type/template/vDevID/AICore)+ ResourceClaim 属性选择 + 混用拒绝"的 DRA 建模,对齐我们 GPU DRA 选型:https://gitcode.com/openFuyao/npu-dra-plugin
- [ ] 看 `cache-indexer` !43/!47(decode pod 纳入 L1 索引 + map 编码 KV 事件)+ oFEP-0053,抽取 PD 分离感知的 KV-aware 路由分层与引擎一致性方案:https://gitcode.com/openFuyao/cache-indexer
- [ ] 确认昇腾运维/容错栈组件收编关系:Resilience Controller 日落 / Elastic Agent→taskd / 新 clusterops-agent 三者的能力边界与替代关系:https://gitcode.com/ascend/mind-cluster
- [ ] 盯 v26.09 发版:cluster-api-provider-bke nginx LB + 静态 pod 热更新 + e2e FIT 对齐,预计 9 月内落地,评估集群生命周期对标 OpenShift 的进度:https://gitcode.com/openFuyao/cluster-api-provider-bke

## 原始材料

<details>
<summary>本次扫描清单</summary>

**扫描窗口**:2026-09-07 ~ 2026-09-14

**有实质更新的仓**:
- `ascend/mind-cluster`(最高频,96 MR):**ascend-clusterops-agent 新组件(feat/clusterops part1~9 + DT/UT py3.9.11 + docs,一键任务诊断 + LLM 可选总结)**、**【dra】支持静态 vNPU 设备发布与分配(!4638)**、dra 二进制 version+commitid + clusterD 收集 dra 版本(!4581)、UB 链路精细诊断 ub-p2/p3/p4 + 故障模式库去重/关键字小写 + sfu 光模块解析(!4651)+ 修全卡 UB 端口 down 隔离 bug(!4587)、docs 移除已日落 Resilience Controller + Elastic Agent→taskd、infer-operator 推理 Pod 重调度(!4604/!4572)、npu-exporter 空进程 id 兼容 + 自定义指标样例、acjob 用正确 job key 取 TTL(!4586)、volcano 节点内亲和打分框架重构 + 测试(!4610/!4629)+ chip-affinity 资料、Atlas 950 SuperPoD Flex 支持(!4566)、1825 RDMA 挂载 docs + 独占模式共享组件 UT、安全编译选项 oidc 认证、81078603 故障码 5 分钟轮询临时缩短、RL 实例级故障恢复资料、进程级在线恢复同 Step 多次故障约束 docs、dpu-exporter dockerfile 归档 + helm + version
- `openFuyao/e2e-auto-test`(40 commit,高频):!482 更新 hermes-router/InferNex 各模块 e2e、!457 flux-sandbox dataplane e2e suite、!442 bke nginx-proxy 负载均衡测试、!486/!485 自管集群名派生对齐 + SSH 取 mgmt kubeconfig、!484 rsg ContinueOnFailure、!480 scale down 前等 node ready + kubescape 密码扫描、!477 etcd 健康检查重试、!476 close tracing、!474/!473 infernex system-integration 清理、!465 HelmInstaller e2e、!469 NUMA 亲和日志断言改 Eventually
- `openFuyao/cluster-api-provider-bke`(16 commit):!451 nginx LB 模式含升级、!482 静态 pod 热更新、!485 bkeagent 日志级别 customExtra.agentLogLevel、!488 自管集群/节点名从 bootstrap 继承、!491 master-join 只等 master ready、!489 BKENode Deleting 态删除 + 允许 cluster 删除态删节点、!490 grpc.WithInsecure→insecure credentials
- `openFuyao/bkeadm`(16 commit):!350 nginx-proxy 负载均衡 schema + version config、!359 预置 customExtra.agentLogLevel=INFO、!353 引导节点 bke crd 新增两 hash 字段、!344 缓存 API discovery + 提升 client 限速防安装节流、!360 preflight 配置化、!357 k3s 不硬编码 bootstrap token、!355 k3s bootstrap 容器日志挂宿主
- `openFuyao/compliance-operator`(11 commit):!19 修 K8s 加固回退 + 健康检查 + 完善文档、!18 codecheck gate、!17 UT 覆盖率提升至 85.5%(api/controllers/manager/scanner)、!16 restore_file 按内容 diff 做幂等回滚、!14 docs 对齐实际行为
- `openFuyao/ubs-k8s-enable`(11 commit):!85 SuperPod controller(双源 superPodId + SuperPod CRD)、!89 关键模块 UT 覆盖率 80%+、!79 收敛 MatrixAgent Event 权限、!78 CRD/SOP 域名迁移
- `openFuyao/ubs-openstack-enable`(7 commit):!62 检测 H2N 链路健康状态、!66/!67 H2N 配置/调度包装层/链路健康 UT、!68 type131 HDK 驱动适配文档
- `openFuyao/openfuyao-powers`(5 commit):!61 简化 squad 循环并把 test coding 折入 avatar、!59 新增 2 个 CI e2e 分析 skill、!62 更新 D3 rubric
- `openFuyao/cache-indexer`(3 commit):!43 decode pod 纳入 L1 索引、!47 L1 ingest 接受 map 编码 KV 事件
- `openFuyao/InferNex`(3 commit):!238 AIPerf 数据集生成脚本 + README、!243/codecheck 修复
- `openFuyao/hermes-router`(3 commit):!92 grpc v1.80.0→v1.83.2 修 CVE、!90 修正 README 聚合架构路由策略名称(docs)
- `openFuyao/npu-operator`(1):!117 adapt volcano scheduler plugin arch
- `openFuyao/npu-dra-plugin`(1):!47 grpc 升级至 v1.83.2 修 CVE-2026-84303/84304/84445
- `openFuyao/ub-network-device-plugin`(1):!61 grpc 升级修同批 CVE
- `openFuyao/flux-sandbox`(1,降温):!40 watcher criSocket 默认置空 + agent /tmp 目录(chore)

**窗口内无实质提交(跳过)**:`openFuyao/volcano-ext`(0)、`openFuyao/rootpv`(0)、`colocation-website`/kubevirt(在离线混部,无进展)、`npu-feature-discovery`(11 天前)、`sig-ai-inference`(9 天前)、`kae-operator`(05-26)

**官方源**:
- 无新版本 release(v26.06 07-09 仍为最新);官网 openfuyao.cn news/活动/博客栏目"暂无内容"
- CSDN openFuyao 最近一篇仍是 08-25 Agent Sandbox SIG(上周已报道)、08-19 InferNex TTFT 优化 —— https://blog.csdn.net/openFuyao
- v26.09 发版信号来自代码侧(bke nginx LB/静态 pod 热更新 + e2e FIT 对齐),非官方公告

**抓取方式**:GitCode 走 `git clone --filter=blob:none --shallow-since=2026-09-05` + 本地 `git log --since=2026-09-07 --until=2026-09-15`;组织仓清单 + CSDN + 官网走 WebFetch(组织首页 SSR + CSDN 列表页)。GitCode raw/blob 页仍为 JS 壳,文件读取走 clone 后本地 `cat`/`git show`;tag 因 shallow clone 未拉取,release 判断以官网/CSDN 为准。

</details>
