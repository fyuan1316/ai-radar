# OpenFuyao 周报 2026-09-07

> 扫描窗口:2026-08-31 ~ 2026-09-07。主仓 GitCode `openFuyao` 组织 + 昇腾 upstream `ascend/mind-cluster`(本周 62 个 MR)+ 官方 CSDN/官网。非发版周,但出现两条重要节奏信号:①**v26.09 季度版进入测试收尾期**——`e2e-auto-test` 新增 v26.09 FIT 用例 + 声明式升级(declarative-upgrade)门禁测试,`cluster-api-provider-bke` 同步移除 legacy 声明式升级门禁(声明式集群升级从 gated 转默认);②**mind-cluster 本周主线从上周的 DPU 进场,转向"网络/UB 链路故障感知调度 + 跨节点 NPU 自愈协调器"**——container-manager 落地分布式 coordinator、volcano 一串 linkdown 感知修复、UB 链路精细诊断 + NPU 故障模式库、节点内通用亲和性调度新算法。官方无新版本 release、无新博客(08-25 Agent Sandbox SIG 已在上周报道)。信息量足,正常出报并推送。

## 摘要(3 条以内)
- **v26.09(Q3 季度版)在测试收尾**:`e2e-auto-test`(08-28 新立的 E2E 框架仓)本周 !459 `align e2e with extraArgs chart and add v26.09 FIT cases`,并有一整套 `declarative-upgrade` FIT 门禁测试(gate open/closed、mgmt-upgrade、upgrade);`cluster-api-provider-bke` !476 同步 `remove legacy declarative-upgrade gate`。合起来说明:v26.06(07-09)之后的下一季度版 **v26.09** 正在做发布前 FIT 验证,且**声明式集群升级**是本次重点交付特性(从门禁试验转为默认路径)。这是对标 OpenShift OTA/声明式升级的能力,**通用可对标**。
- **昇腾集群栈主线:网络/UB 链路故障感知调度 + 跨节点自愈协调器**。`ascend/mind-cluster` 本周把"故障域"从上周的 DPU 进一步铺到**参数面网络/UB 链路**:container-manager 落地 **分布式 coordinator(part1/2 + DT)支持跨节点 NPU 自愈**;volcano 侧一串 linkdown 感知修复(单机任务不调度到网络故障节点、vnpu 场景整卡分布式调度感知 linkdown、参数面网络忽略 linkdown);新增 **UB 链路精细诊断 + NPU 故障模式库(FD)**;另起 **节点内通用亲和性调度**(chip-affinity)新算法一整条链。**纯昇腾/超节点专用**,作大规模训练容错成熟度的节奏信号。
- **Agent 沙箱深入 E2B 运行时对接 + 性能基准**:`flux-sandbox` 从上周"Helm/Service 工程化"进入 **E2B runtime 集成实测**——SandboxGroup 端到端成为权威资源源(!33)、返回 runtime 提供的 endpoint(!35)、containerd 对 E2B-only 集群变可选(!37)、runtime 实测统计 + 单请求全链路 trace(!38)、参数化生命周期超时(!34)。同期 `openfuyao-powers` 把 avatar-agent 权限隔离从 defect-fixer squad 扩展到 **design-coding squad**。研发自动化 + Agent 隔离两条线继续推进,**通用可借鉴**。

## 新功能 / 能力

- [e2e-auto-test:v26.09 FIT 用例 + 声明式升级门禁测试](https://gitcode.com/openFuyao/e2e-auto-test) — 08-28 新立的端到端测试框架仓,本周高频:!459 `align e2e with extraArgs chart and add v26.09 FIT cases`(把 InferNex e2e 对齐 extraArgs chart 并加 v26.09 FIT 用例)、!466 `disable tracing to prevent Helm install timeout in npe e2e`、!467 preflight kubeconfig/testnode 调整;仓内含成套 `declarative-upgrade`(fit_gate_open/closed、fit_mgmt_upgrade、fit_upgrade)、`abnormal-retry`、`kubeos` 安装类 FIT 测试。
  - 启示:**这是本周最有价值的节奏信号**。OpenFuyao 季度发版(YY.MM),v26.06 是 07-09 发布,**v26.09 正在做发布前 FIT 验证**,预计 9 月内落地。更关键的是 FIT 集覆盖 **声明式升级(declarative-upgrade)+ 异常重试 + KubeOS 安装**——说明 v26.09 的重点是**集群 Day-2 升级/运维闭环**,而非新功能堆叠。这与 `cluster-api-provider-bke` 移除 legacy 声明式升级门禁互为印证(见下)。**对标视角**:声明式升级 = OpenShift 的 OTA/ClusterVersion 声明式滚动升级路线,**通用可对标**;我们若做集群生命周期管理,应关注它把"升级"纳入 CR 声明 + FIT 门禁验证的做法。

- [ascend/mind-cluster:container-manager 分布式协调器,支持跨节点 NPU 自愈](https://gitcode.com/ascend/mind-cluster) — 本周 `feat(coordinator): container-manager 添加分布式协调器,支持跨节点 NPU 自愈`(part1/part2)+ `test(coordinator): 协调器模块 DT / 数据同步、客户端端点和命令协调 DT` + `docs(container-manager): 分布式协调功能文档`。这是上周新出现的 `coordinator` protobuf 定义的落地实现。
  - 启示:**纯昇腾专用,但架构信号明确**。上周 coordinator 还只是 protobuf 骨架,本周落地为"**跨节点** NPU 自愈"的分布式协调器——即单节点的故障隔离/恢复升级为**跨节点协同**(某节点 NPU 故障时,协调器聚合信息、跨节点触发迁移/续训/隔离)。这补齐了大规模训练容错的"控制面协同"环节,配合 DPU 亚健康触发断点续训(见下),昇腾在把容错从"单卡/单节点"推向"整集群故障域协同"。作判断其超大规模(1.6w+ 节点)训练成熟度的信号,与我们无直接借鉴。

- [ascend/mind-cluster:网络/UB 链路故障感知调度 + 精细诊断](https://gitcode.com/ascend/mind-cluster) — 本周一串:volcano `修复单机任务无法调度到网络故障节点`、`节点上有 vnpu 时整卡分布式调度无法感知 linkdown 故障`、`参数面网络忽略 linkdown 故障`;`ub 链路诊断精细定位代码(故障模式库 + 常量,第一部分)`、`[feature] 增加 NPU 故障模式库`、`super pod faultdiag doc`;dpu-exporter `网卡端口 linkdown 之后 carrier 指标异常修复`。
  - 启示:**纯昇腾/超节点专用**。主题是把**网络链路状态(linkdown / UB 超低时延链路)纳入调度与诊断的一等输入**——调度器感知 linkdown 决定是否放行任务,诊断侧建"NPU 故障模式库 + UB 链路精细定位"。这是超节点(灵衢 UB 网络)整机柜化后的必然:计算-网络耦合紧,网络故障必须进调度决策。**通用可类比**的只有"把网络健康度作为调度约束"这一思路(NVIDIA 也在做 NCCL/网络拓扑感知调度),具体 UB/HCCL 实现不可迁移。

- [ascend/mind-cluster:节点内通用亲和性调度算法 + Atlas 950-SuperPod-Flex 超节点调度](https://gitcode.com/ascend/mind-cluster) — volcano `节点内通用亲和性调度`一整链(基础调度部分 → 算法 → 驱逐场景 → 测试用例);`支持 Atlas 950-SuperPod-Flex 超节点调度`;`支持从 Pod 注解读取 huawei.com/schedule.mode`;`device-plugin 支持上报节点 NPU 拓扑`。
  - 启示:**昇腾专用(拓扑/超节点绑定)**,但"节点内通用亲和性调度"值得记一笔——它把此前只对 NPU 的亲和调度**泛化为节点内通用亲和**(可覆盖非 NPU workload),并支持从 Pod 注解读调度模式(`schedule.mode`),是往"一套调度器覆盖异构 + 通算"收敛。device-plugin 上报节点 NPU 拓扑与 `npu-dra-plugin` 的拓扑亲和上报(见下)呼应,说明**拓扑数据源正在双轨(device-plugin + DRA)供给调度器**。

- [flux-sandbox:E2B 运行时集成实测 + 全链路 trace](https://gitcode.com/openFuyao/flux-sandbox) — 本周从工程化转入 E2B runtime 对接:!33 `make SandboxGroup the authoritative resource source end-to-end`(SandboxGroup 端到端成为权威资源源)、!35 `return runtime-provided endpoints for E2B sandboxes`、!37 `make containerd dependency optional for E2B-only clusters`、!38 `runtime 实测统计、trace 单请求全链路追踪与首末时序`(含 benchmark 延迟分解树:端到端 + opensandbox-server 段)、!34 参数化沙箱生命周期超时(`--operation-timeout`)、!39 `ListSandbox 按 agent-name 过滤修复同节点多 agent 串报`。
  - 启示:**通用 + 潜在竞争**。承接前两周(能力堆叠 → Helm 工程化 → 本周 E2B 运行时对接 + 性能基准)。两个可借鉴点:①**containerd 对 E2B-only 集群变可选**——把沙箱运行时后端做成可插拔(E2B / containerd),不锁死单一运行时;②**沙箱冷启动/生命周期的延迟分解树 + 单请求全链路 trace**——沙箱这类"频繁创建/销毁的隔离 workload"必须有细粒度延迟归因,这套 benchmark/trace 方法论我们做 Agent 沙箱可直接抄。

- [openfuyao-powers:avatar-agent 权限隔离扩展到 design-coding squad](https://gitcode.com/openFuyao/openfuyao-powers) — 本周 !58 `apply avatar workflow to design-coding squad`(把上周只在 defect-fixer squad 的 avatar-agent 权限隔离模型推广到 design-coding squad)、!60 `unify git conventions and refine pr-manager AI declaration rules`(统一 git 规范 + pr-manager 的 AI 声明规则)。
  - 启示:**通用能力**。承接上周判断——多 Agent 协作(squad)+ 每 Agent 最小权限隔离(avatar-agent)从单一 squad 扩到第二个 squad,说明这套治理模型在社区内被验证为可复用范式。`pr-manager AI declaration rules`(要求 AI 生成的 PR 显式声明)也是个务实的治理点:**AI 参与研发时的可追溯/合规声明**。我们若在产品里引入 Agent 化研发/运维,这套"多 squad 复用同一权限隔离范式 + AI 产出显式声明"值得参考。

## AI 推理栈(InferNex / hermes-router / ...)

本周推理栈**明显降温**(上周是 KVCache 路由精调高峰,本周 hermes-router 窗口内**零提交**):

- **InferNex**:!235 `add --enable-connectivity-check flag for optional network tests and HCCL profiling support`(新增可选网络连通性测试 + HCCL profiling 开关)、!237 `upgrade golang.org/x/crypto to v0.55.0 for CVE-2026-56854`(安全补丁)、!230 docs 同步 webhook 行为。
  - `--enable-connectivity-check`(网络连通性预检 + HCCL profiling)是与 mind-cluster 本周"网络故障感知"主题呼应的推理侧动作:**部署前预检 NPU 间 HCCL 连通性**,避免起服务后才发现网络问题。这个"推理部署前做网络预检"的思路**通用可借鉴**(通用集群也可在起分布式推理前预检 RDMA/NCCL),但 HCCL profiling 本身昇腾绑定。
- **hermes-router**:窗口内无提交。上周的 KVCache 路由精调(对齐 GIE、只算完整 block、去 kserve patch)本周无进展,处于消化期。
- **e2e 侧**:v26.09 FIT 用例把 InferNex 对齐 extraArgs chart(见"新功能"),说明推理栈的 chart 参数模型在为发版做冻结。

架构定性不变:hermes-router 建在上游 GIE 上、cache-indexer 前缀树 KV-aware ≈ llm-d、PD-Orchestrator/APA ≈ Dynamo/llm-d。本周推理栈无架构变动,只有**安全补丁 + 网络预检 + 发版对齐**。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- **coordinator 跨节点自愈 / 网络故障感知 / UB 诊断**(见"新功能")是 mind-cluster 本周三大主线。
- **DPU 亚健康主动触发断点续训**:`[clusterD][ascend-for-volcano] DPU 亚健康支持主动触发断点续训` + `[Docs] DPU 亚健康支持配置断点续训策略`。承接上周"DPU 故障触发断点续训",本周细化到**亚健康(非完全故障)也能主动触发** ckpt 续训,并可配置策略。容错颗粒度进一步下沉。
- **infer-operator(mind-cluster 内)**:`推理支持 pod 重调度`(!4542)、`修复 prometheus adapter 提供推理实例负载指标报 unable to fetch metrics 错误`(!4531)。mind-cluster 自带的 infer-operator 在补推理实例的**重调度 + HPA 外部指标**闭环——注意这是**独立于 InferNex 的另一套推理编排**(mind-cluster 侧),二者定位差异值得下周厘清。
- **DRA**:mind-cluster 侧本周 `【dra】补充 ckpt 相关代码`、`修改发布的设备属性 & 增加测试脚本接入流水线`、`【dra】增加开发者指南文档` + `新增 Ascend Dynamic Resource Allocation 组件介绍`(文档正式化)、`【dra】ut 补充`。`openFuyao/npu-dra-plugin` 侧 !45 `使用 HAL 获取 NPU 拓扑并按 physicalID 上报亲和属性` + `DCMI 拓扑主路径优先并兼容双 ID 回退`(修上周 !41 拓扑上报的数据源:改走 HAL/DCMI 按 physicalID)。
  - **DRA 主线判断更新**:本周两侧都在动但都偏基建——mind-cluster `ascend-dra-driver` 补 ckpt 代码 + 设备属性发布 + 文档正式化(有"组件介绍"了,说明准备对外);npu-dra-plugin 修拓扑数据源。倾向维持上周判断(npu-dra-plugin = vNPU 切分 DRA 主线),但 mind-cluster 侧 DRA **文档正式化 + ckpt 代码**说明它也在补断点续训场景的 DRA 支持,**二者收敛关系仍需盯**。
- **ascendjob**:`实现 acjob 完成后 TTL 自动清理功能`——训练作业完成后按 TTL 自动清理(≈ K8s Job `ttlSecondsAfterFinished`),通用运维能力。
- **CDI**:`handle hostRoot prefix in glob expansion and symlink resolution`——承接上周 CDI 统一 MountConfig 的边界修复。
- **独占模式 RDMA**:`k8s rdma exclusive mode code` + `ub-host-device-cni ut`——RDMA 独占模式代码 + UB host-device CNI 测试。
- **npu-operator**:窗口内**无提交**(最新 08-18),跳过。上周的 vnpu/mindcluster volcano 切换主题本周无进展。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- **volcano(mind-cluster 内)本周是最活跃区**:节点内通用亲和性调度新算法(见"新功能")、Atlas 950-SuperPod-Flex 超节点调度、linkdown 感知系列修复、`schedule.mode` 注解读取、`跳过非 NPU Pod 校验(不需单独配置)`、clusterD `节点预隔离故障统一处理,任务负载统计包含 volcano 调度的通算任务`。信号:**volcano 扩展在往"NPU + 通算统一调度、网络健康纳入决策、超节点原生"三个方向同时推进**。
- **cluster-api-provider-bke**:!476 `centralize annotation constants and remove legacy declarative-upgrade gate`(集中注解常量 + **移除 legacy 声明式升级门禁**,与 v26.09 声明式升级发版呼应)、!477 `preserve containerdConfigRef and kubeletConfigRef in manage manifest`、!478 `修复缩容失败时 replicas 不回滚导致级联缩容`(实打实的稳定性 bug)、!481 `enable worker needskip`、!479 `clean /var/lib/lxc`。本周是**升级路径 + 缩容稳定性打磨**,为 v26.09 收尾。
- **bkeadm(BKE 集群 CLI,非新仓,07-22 立)**:本周高频但多为 codecheck/gofmt + `BKENode/BKECluster 命名空间对齐、命名空间不匹配则 fail`——CLI 侧收敛与 cluster-api-provider-bke 的命名空间语义。作 BKECluster 的命令行前端,与 CR/controller 配套。
- **rootpv**:!19 `add cluster e2e and performance scripts`(补集群 e2e + 性能脚本)——上周部署资产合入后,本周补测试。
- **volcano-ext**(独立仓):!13 仅 `fix typos and duplicated words in design docs`(文档改错字,仓时隔久后有微动但无代码)。
- **ub-network-device-plugin**:!59 `Add executable permission to shell scripts`(trivial)。
- `kae-operator`(05-26)、`mooncake`(仅上游镜像 bump 到 0.3.13.post1,非 openFuyao 自研改动)、`kubevirt`、`colocation-website`(在离线混部前端)窗口内**无实质提交**。**在离线混部本周仍无实质进展**。

## 官方动态

- **v26.09 季度版进入测试收尾期**(推断,来自代码):`e2e-auto-test` v26.09 FIT 用例 + 声明式升级 FIT 门禁,`cluster-api-provider-bke` 移除 legacy 声明式升级门禁。**官方尚无 release / 公告**,但代码侧节奏明确指向 9 月内发 v26.09,重点是**集群 Day-2 升级/运维闭环(声明式升级 + 异常重试 + KubeOS 安装)**。—— https://gitcode.com/openFuyao/e2e-auto-test
- **无新版本 release**:v26.06(07-09)仍是最新公开季度版。
- **无新官方博客**:CSDN `openFuyao` 最近一篇仍是 08-25 的 Agent Sandbox SIG(上周已报道);官网 openfuyao.cn news/活动栏目基本为空,官方内容以 CSDN 为主发布口。
- **仓库观察**:`e2e-auto-test`(08-28 新立,E2E/FIT 框架)是本周新纳入视野的仓;`bkeadm`(BKE CLI)、`ubs-openstack-enable`(超节点 OpenStack 使能,本周仅 !65 补 release_notes,Python)为已存在但此前未单独提及的仓。未见其他全新立仓。

## 跟我们产品的对比

| 能力维度 | OpenFuyao 现状(本周) | 与上游/我们的关系 |
|---|---|---|
| **声明式集群升级** | v26.09 把 declarative-upgrade 从门禁转默认,配 FIT 门禁测试(gate/mgmt/upgrade) | **≈ OpenShift OTA/ClusterVersion 声明式升级**;**通用可对标**,我们做集群生命周期需关注"升级纳入 CR 声明 + FIT 验证" |
| 跨节点故障自愈 | container-manager 分布式 coordinator,跨节点 NPU 自愈 | 昇腾专用;信号=容错从单节点升到整集群故障域协同 |
| 网络健康纳入调度 | volcano linkdown 感知、UB 链路诊断、NPU 故障模式库 | 思路通用(网络健康作调度约束,≈ NV 网络拓扑感知),UB/HCCL 实现不可迁 |
| 统一调度 | volcano 节点内通用亲和(NPU+通算)、schedule.mode 注解 | 往"一套调度器覆盖异构+通算"收敛,通用趋势可对标 |
| Agent 沙箱 | flux-sandbox E2B runtime 对接、runtime 可选、延迟分解树 + 全链路 trace | **通用+潜在竞争**;运行时可插拔 + 沙箱延迟归因方法论可抄 |
| 多 Agent 治理 | avatar-agent 隔离扩到第二个 squad;pr-manager AI 声明规则 | 通用;多 squad 复用权限隔离范式 + AI 产出显式声明 |
| 推理部署预检 | InferNex --enable-connectivity-check(HCCL 连通性 + profiling) | 思路通用(起分布式推理前预检网络),HCCL 昇腾绑定 |
| 安全合规 | compliance-operator 规则级可追溯(changes.json 记 rule_id) | ≈ OpenShift Compliance Operator;本周细化审计追踪 |
| 设备 DRA | ascend-dra-driver 补 ckpt + 设备属性 + 文档正式化;npu-dra-plugin 改 HAL/DCMI 拓扑源 | 双轨仍在,收敛关系待定;参考其软切分 + ckpt 场景 DRA 建模 |
| 在离线混部 | 本周无实质进展 | — |

**我们该补 / 该警惕**:
- **声明式升级是本周最该对齐的一条**:v26.09 把集群升级做成 CR 声明 + FIT 门禁验证的默认路径,直接对标 OpenShift OTA。我们若集群升级仍是脚本/手工滚动,要评估"声明式升级 + 升级前 FIT 门禁"这条路——这是企业级集群管理的分水岭能力。
- **网络健康进调度**:昇腾把 linkdown/UB 链路状态做成调度一等输入。虽然 UB/HCCL 昇腾专用,但"网络健康度作为调度约束 + 起分布式作业前网络预检"是通用刚需,我们做 GPU 分布式训练/推理调度应同样把 RDMA/NCCL 健康纳入。
- **沙箱延迟归因方法论**:flux-sandbox 的"延迟分解树 + 单请求全链路 trace + runtime 可插拔"是做 Agent 沙箱的成熟工程范式,若我们做隔离 workload 可直接借鉴,别只做功能不做可观测。

## 值得跟进
- [ ] 盯 v26.09 发布:读 `e2e-auto-test` 的 declarative-upgrade FIT 用例,评估其"声明式升级 + 升级前门禁验证"模型是否值得我们对标 OpenShift OTA:https://gitcode.com/openFuyao/e2e-auto-test
- [ ] 读 `ascend/mind-cluster` container-manager coordinator(跨节点 NPU 自愈)设计文档,理解昇腾整集群故障域协同的控制面模型:https://gitcode.com/ascend/mind-cluster
- [ ] 看 `flux-sandbox` !37(containerd 对 E2B-only 可选)+ !38(延迟分解树/全链路 trace),抽取沙箱运行时可插拔 + 延迟归因方法论:https://gitcode.com/openFuyao/flux-sandbox
- [ ] 厘清 mind-cluster 内 `infer-operator`(推理 pod 重调度 + HPA 外部指标)与 `InferNex` 两套推理编排的定位差异:https://gitcode.com/ascend/mind-cluster
- [ ] 持续跟 DRA 双轨:`ascend-dra-driver`(ckpt + 设备属性 + 文档正式化)vs `npu-dra-plugin`(拓扑源改 HAL/DCMI)的收敛方向:https://gitcode.com/openFuyao/npu-dra-plugin

## 原始材料

<details>
<summary>本次扫描清单</summary>

**扫描窗口**:2026-08-31 ~ 2026-09-07

**有实质更新的仓**:
- `ascend/mind-cluster`(最高频,62 MR):coordinator 分布式协调器跨节点 NPU 自愈(part1/2 + DT + docs)、DPU 亚健康主动触发断点续训(clusterD/ascend-for-volcano + docs)、volcano 节点内通用亲和性调度(基础/算法/驱逐/测试)、Atlas 950-SuperPod-Flex 超节点调度、linkdown 感知系列(单机任务/vnpu 整卡/参数面网络)、schedule.mode 注解读取、device-plugin 上报节点 NPU 拓扑、跳过非 NPU Pod 校验、UB 链路精细诊断 + NPU 故障模式库(FD)、dpu-exporter carrier linkdown 修复、infer-operator 推理 pod 重调度 + prometheus adapter 外部指标修复、ascendjob TTL 自动清理、【dra】ckpt 代码 + 设备属性发布 + 开发者指南 + Ascend DRA 组件介绍 + ut、CDI hostRoot glob/symlink 修复、k8s rdma exclusive mode + ub-host-device-cni ut、ascend-docker-runtime injection-mode legacy 默认、clusterd 节点预隔离故障统一处理、大量资料/docs
- `openFuyao/e2e-auto-test`(08-28 新立):!459 v26.09 FIT 用例 + InferNex extraArgs chart 对齐、!466 disable tracing 防 npe e2e Helm timeout、!467 preflight kubeconfig/testnode;仓含 declarative-upgrade/abnormal-retry/kubeos FIT 套件
- `openFuyao/flux-sandbox`(活跃):!33 SandboxGroup 端到端权威资源源、!34 参数化生命周期超时、!35 返回 runtime endpoint、!37 containerd 对 E2B-only 可选、!38 runtime 实测统计 + 全链路 trace + 延迟分解树、!39 ListSandbox 按 agent-name 过滤修串报
- `openFuyao/cluster-api-provider-bke`:!476 集中注解常量 + 移除 legacy 声明式升级门禁、!477 保留 containerd/kubelet ConfigRef、!478 修缩容失败 replicas 不回滚级联缩容、!481 worker needskip、!479 清 /var/lib/lxc(!471/!472 属上周边界)
- `openFuyao/bkeadm`(BKE CLI,07-22 立):!356 命名空间对齐(停止自动加前缀、命名空间不匹配则 fail)+ 一串 codecheck/gofmt
- `openFuyao/InferNex`:!235 --enable-connectivity-check(网络测试 + HCCL profiling)、!237 crypto CVE-2026-56854 升级、!230 webhook docs 同步
- `openFuyao/npu-dra-plugin`:!45 使用 HAL 获取 NPU 拓扑并按 physicalID 上报 + DCMI 拓扑主路径优先双 ID 回退
- `openFuyao/openfuyao-powers`:!58 avatar workflow 扩展到 design-coding squad、!60 统一 git 规范 + pr-manager AI 声明规则(!57 属上周边界)
- `openFuyao/compliance-operator`:!12 补 entry 脚本 bin/k8s-hardening.sh、!13 changes.json 记 rule_id 做规则级可追溯
- `openFuyao/rootpv`:!19 add cluster e2e and performance scripts
- `openFuyao/ub-network-device-plugin`:!59 shell 脚本加可执行权限(trivial)
- `openFuyao/volcano-ext`:!13 design docs 改错字(trivial,无代码)
- `openFuyao/ubs-openstack-enable`(超节点 OpenStack 使能,Python):!65 补 docs/release_notes(仅文档)

**窗口内无实质提交(跳过)**:`openFuyao/npu-operator`(最新 08-18)、`openFuyao/hermes-router`(窗口内零提交)、`openFuyao/kae-operator`(05-26)、`openFuyao/mooncake`(仅上游镜像 bump 0.3.13.post1,非自研)、`kubevirt`、`colocation-website`

**官方源**:
- 无新版本 release(v26.06 07-09 仍为最新);CSDN openFuyao 最近一篇仍是 08-25 Agent Sandbox SIG(上周已报道)—— https://blog.csdn.net/openFuyao
- 官网 openfuyao.cn news/活动栏目基本为空
- v26.09 发版信号来自代码侧(e2e-auto-test FIT 用例 + declarative-upgrade),非官方公告

**抓取方式**:GitCode 走 `git clone --filter=blob:none --shallow-since=2026-08-24`(部分回退 `--depth`)+ 本地 `git log --since="2026-08-31" --until="2026-09-08"`;组织仓清单 + CSDN 走 WebFetch(组织首页 SSR + CSDN 列表页)。GitCode raw/blob 页仍为 JS 壳,文件读取走 clone 后本地 `git show`/`cat`。

</details>
