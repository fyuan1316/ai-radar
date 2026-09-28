# OpenFuyao 周报 2026-09-28

窗口:2026-09-22 -> 2026-09-28(7 天)

## 摘要(3 条以内)
- 本周最大信号在**编排/调度层往 K8s 标准靠**:`npu-dra-plugin` 开始暴露标准 DRA 属性 `resource.kubernetes.io/numaNode`,把昇腾 NPU 的 NUMA 亲和交给上游 DRA 语义处理,而不是自定义 key——这条路线跟我们 DRA 选型高度相关。
- OpenFuyao 补上了一整块此前没有的能力:**AI Agent 沙箱**(`opensandbox` + `sig-agent-sandbox/FluxSandbox`),基于 E2B/Firecracker microVM + containerd 双运行时,带 SandboxGroup CRD、预热池、快照预热,对标 E2B、Kata、K8s agent-sandbox。
- InferNex 侧无架构级变更,主要是补 DeepSeek-V4-Flash(1P1D 32 卡 PD)与 GLM-5.2(聚合)示例、默认 vLLM-Ascend 升到 v0.23.0;其 serving 入口已固化在 Gateway API Inference Extension(InferencePool/httpRoute)+ hermes-router 上。

## 新功能 / 能力

- [npu-dra-plugin GitCode](https://gitcode.com/openFuyao/npu-dra-plugin) — 2026-09-23 合入 `feat: 支持k8s的标准numaNode属性暴露`(MR !49)。代码在 device 属性里同时写 `numaNode` 和标准键 `resource.kubernetes.io/numaNode`。
  - 启示:这是"贴标准"而非"造私有语义"的做法——NPU 的 NUMA 位置通过上游 DRA 官方属性发布,K8s 调度器/DRA 可以用通用 NUMA 亲和逻辑分配昇腾卡,不需要昇腾专用调度插件。我们做 DRA 时应对齐同一套 `resource.kubernetes.io/*` 属性命名,把硬件差异收敛到属性值而非属性 key,才能复用上游 NUMA/topology 分配器。
- [opensandbox GitCode](https://gitcode.com/openFuyao/opensandbox)、[sig-agent-sandbox GitCode](https://gitcode.com/openFuyao/sig-agent-sandbox) — 2026-09-24 新增 FluxSandbox 冷启动/预热池性能测试报告与英文特性文档。FluxSandbox 是 OpenSandbox 的 `flux` runtime 后端,提供 K8s 上的 Agent 沙箱生命周期管理。
  - 架构:`SDK/REST → OpenSandbox Server(flux runtime)→ FluxSandbox Controller → Scheduler → Agent Pod → Sandbox Runtime`。运行时双模:**E2B Runtime(默认)** = Firecracker microVM,支持 pause/resume/snapshot、模板秒级启动、快照跨 SuperPod 预热;**containerd Runtime** = 裸容器,不支持快照。用 `SandboxGroup` CRD 声明容量+规格,系统自动维护 warm buffer(sandboxBuffer)扛高并发创建。
  - 启示:这是 OpenFuyao 从"训推资源栈"往"Agent 运行时底座"扩的关键一步,和 E2B/Kata/K8s agent-sandbox 是同一赛道。可借鉴点是**通用的**:SandboxGroup 声明式容量 + 预热池 + 快照预热这套模型跟硬件无关,我们若要做 Agent/代码执行沙箱可直接参考;E2B microVM 依赖则是可替换的运行时后端。
- [ub-ssu-csi GitCode](https://gitcode.com/openFuyao/ub-ssu-csi) — 本周持续收敛部署(9-20 起 `docs/fix(deploy)` 对齐 Helm 与静态 manifest、修 codecheck)。这是 UB(Unified Bus)SSU 分布式存储的 K8s CSI 驱动,走 NVMe over UB,提供块/文件/组逻辑卷,支持 `Block`/`Filesystem` 两种 volumeMode。
  - 启示:属于**昇腾/UB 专用**(依赖 UB 超节点硬件),不是通用 K8s 能力,不建议直接对标;但它和 `ubs-k8s-enable`(超节点拓扑感知调度)一起构成 OpenFuyao 的"超节点(SuperPod)存储+调度"闭环,值得作为竞品的差异化能力记录。

## AI 推理栈(InferNex / hermes-router / ...)

- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 2026-09-24 `feat(examples): add DeepSeek-V4-Flash PD and GLM-5.2 aggregated values`(MR !248)。DeepSeek-V4-Flash 用 1P1D(prefill tp8×dp2 + decode tp8×dp2,32 卡)+ Mooncake store;GLM-5.2 用聚合部署。示例入口是 `inferenceGateway`(istio)+ `hermes-router.inferenceExtension` + `inferencePool` + `httpRoute`——即 Gateway API Inference Extension 那套 InferencePool 模型。
  - 对比:这跟 KServe/llm-d 走的是**同一条路**——推理入口用 Gateway API Inference Extension(InferencePool + EPP/router)标准化,而不是自造 CRD。差异是 hermes-router 充当 inferenceExtension、且 PD/KVCache 语义更绑 vLLM-Ascend + Mooncake。对我们的意义:LLM serving 网关层应直接采用 InferencePool/httpRoute,把 PD 拓扑作为 profile 参数(`deploymentMode: pd`),而不是每个模型写死一套部署模板。
- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 2026-09-24 `docs: bump default vllm-ascend to v0.23.0 and fix spec tags`(MR !231),同步改 `inference-backend` 与顶层 chart 的 values。
  - 启示:再次印证 InferNex↔vLLM-Ascend 是强版本耦合。我们若支持昇腾,需把 vLLM-Ascend 镜像版本 × InferNex/router × CANN 做成显式兼容矩阵,不能默认"最新即可"。
- hermes-router 本周无新提交(最近实质变更仍是 2026-09-17 的 Decode-first D/PD RFC PR1/PR2,已在上期解读)。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- `npu-dra-plugin` 见上"新功能"——本周该仓最有信息量的就是标准 numaNode 暴露(+ README 链接修复)。
- [npu-operator GitCode](https://gitcode.com/openFuyao/npu-operator) — 2026-09-24 仅 `fix: vcann images name`(镜像命名修正),无能力增量。
- [vNPU GitCode](https://gitcode.com/openFuyao/vNPU)、`npu-driver-installer`、`npu-container-toolkit`、`kae-operator` — 本轮浅克隆未见 2026-09-22 后实质提交,多仓仍停在 v26.6.0 tag。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [sig-orchestration-engine GitCode](https://gitcode.com/openFuyao/sig-orchestration-engine) — 本周活跃(9-23 起补 numaNode 标准字段文档、ServerlessDB Operator 特性测试报告,9-28 镜像版本更新)。该 SIG 的 RoadMap(更新于 2026-07-13)给出 26.09/26.12 计划:`ubs-k8s-enable`(超节点拓扑感知调度)、`ub-ssu-csi`(超节点池化存储 CSI)、`pod-live-migration`(容器热迁移+IP 保持,中断 <1s,26.12)、`serverlessdb-operator`(Agent 场景 Serverless DB 池)、`kubevirt`(ARM64 容器-VM 共管,26.12)、`npu-dra-plugin`(NPU 软切分/统一调度/指标,26.09/26.12)、`many-core-orchestrator`(干扰检测+重调度,SLA<5%)。测试集群 K8s 版本为 `v1.34.3-of.1`(OpenFuyao 自维护 fork)。
  - 对比:`many-core-orchestrator` 的"干扰检测 + 重调度保 SLA"跟在离线混部/负载感知调度是同一思路(类比 Koordinator/Volcano 的 colocation);`pod-live-migration` 走的是容器热迁移路线(类比 CRIU/KubeVirt live migration)。这些多为**通用 K8s 调度增强**,是我们该重点跟的方向。
- [volcano-ext GitCode](https://gitcode.com/openFuyao/volcano-ext)、[ub-network-device-plugin GitCode](https://gitcode.com/openFuyao/ub-network-device-plugin) — 本轮未见 2026-09-22 后实质提交,能力仍以 v26.06 为基线。

## 官方动态

- 官网(openfuyao.cn)news/blog 段本周仍"暂无内容";CSDN 官方博客最新仍停在 2026-08(Agent Sandbox SIG 招募、InferNex TTFT 优化解读),2026-09-20 后无新公告。本周信号全部来自代码仓与 SIG 仓文档,**非版本发布周**。
- RoadMap 层面确认:v25.12 为首个 LTS;编排引擎 SIG 26.09 目标(ub-ssu-csi、ubs-k8s-enable、npu-dra-plugin 软切分)本周有对应代码/文档落地迹象。

## 跟我们产品的对比

- **同一路线(该抄)**:① 推理入口统一到 Gateway API Inference Extension(InferencePool/httpRoute + router 扩展),和 KServe/llm-d 一致;② DRA 属性贴 `resource.kubernetes.io/*` 标准(numaNode),让上游调度器复用;③ Agent 沙箱用 SandboxGroup 声明式容量 + 预热池 + 快照预热的通用模型。这三条都硬件无关,是我们可直接借鉴的架构决策。
- **分叉/昇腾专用(记录不照抄)**:UB SSU CS+超节点拓扑存储、UB 网络、vNPU 软切分、Mooncake+vLLM-Ascend 深绑,都依赖昇腾/UB 硬件,属竞品差异化而非通用能力。
- **我们该补**:① 明确 LLM serving 网关就用 InferencePool,不自造 CRD;② DRA 设备属性命名对齐上游标准键,把硬件差异放属性值/profile;③ 评估是否要做 Agent 运行时沙箱(microVM/容器双模 + 预热池),这是 OpenFuyao 本周新开的一条我们目前没有的战线。

## 值得跟进
- [ ] 读 FluxSandbox 特性文档 + SandboxGroup CRD 设计([sig-agent-sandbox/doc/en/flux_sandbox.md](https://gitcode.com/openFuyao/sig-agent-sandbox)),评估我们是否需要 Agent 沙箱底座,以及 E2B/Firecracker 后端能否替换为 Kata/gVisor。
- [ ] 深读 `npu-dra-plugin` MR !49,确认 `resource.kubernetes.io/numaNode` 之外它还打算暴露哪些标准 DRA 属性(topology、软切分容量),对齐我们 DRA 设备模型。
- [ ] 跟踪 `sig-orchestration-engine` RoadMap 的 `many-core-orchestrator`(干扰检测+重调度)与 `pod-live-migration`,这两块是通用在离线混部/热迁移能力,直接对标我们的调度栈。
- [ ] 关注 InferNex DeepSeek-V4-Flash 1P1D 32 卡 PD 示例的 Mooncake store 配置,判断 KVCache 池化的 namespace/资源边界模型。

## 原始材料

<details>
<summary>本次扫描清单(2026-09-22 -> 2026-09-28)</summary>

活跃/有信息量:
- https://gitcode.com/openFuyao/npu-dra-plugin
  - 2026-09-23 `feat: 支持k8s的标准numaNode属性暴露`(MR !49)
  - 2026-09-23 `fix: ReadMe链接修复`(MR !50)
- https://gitcode.com/openFuyao/InferNex
  - 2026-09-24 `feat(examples): add DeepSeek-V4-Flash PD and GLM-5.2 aggregated values`(MR !248)
  - 2026-09-24 `docs: bump default vllm-ascend to v0.23.0 and fix spec tags`(MR !231)
  - 2026-09-24 `fix: check-h02-exact-node-match`(MR !241)
- https://gitcode.com/openFuyao/opensandbox + https://gitcode.com/openFuyao/sig-agent-sandbox
  - 2026-09-24 FluxSandbox 冷启动/预热池性能测试报告、英文特性文档
- https://gitcode.com/openFuyao/ub-ssu-csi
  - 2026-09-20~22 `docs/fix(deploy)` 对齐 Helm/静态 manifest、修 codecheck/gate
- https://gitcode.com/openFuyao/sig-orchestration-engine
  - 2026-09-28 镜像版本更新;2026-09-24 ServerlessDB Operator 特性测试;2026-09-23 numaNode 标准字段文档
- https://gitcode.com/openFuyao/npu-operator
  - 2026-09-24 `fix: vcann images name`(MR !119)

本轮无实质增量(未见 2026-09-22 后实质提交):
- https://gitcode.com/openFuyao/hermes-router(最新实质变更仍为 2026-09-17)
- https://gitcode.com/openFuyao/vNPU
- https://gitcode.com/openFuyao/volcano-ext
- https://gitcode.com/openFuyao/ub-network-device-plugin
- https://gitcode.com/openFuyao/npu-driver-installer
- https://gitcode.com/openFuyao/npu-container-toolkit
- https://gitcode.com/openFuyao/kae-operator

官方源:
- https://www.openfuyao.cn/zh/(news/blog 暂无内容)
- https://blog.csdn.net/openFuyao(最新停在 2026-08,无 9-20 后新公告)
</details>
