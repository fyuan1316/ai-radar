# OpenFuyao 周报 2026-07-06

窗口:2026-06-29 -> 2026-07-06(7 天)

## 摘要(3 条以内)
- 本周无官方 release / 新公告(官网 news 空、CSDN 最新仍是 6-18 生态案例与 6-15 三月-五月运作报告),但代码侧有实质进展:vNPU 落地 spread/binpack 调度策略、新仓 [ub-ssu-csi](https://gitcode.com/openFuyao/ub-ssu-csi)(UB 存储 CSI 驱动)开始成型、InferNex 补齐 GLM-5.1/5.2 与 MiniMax-M2.7 的 vLLM 参考配置。
- 昇腾上游 [mind-cluster](https://gitcode.com/ascend/mind-cluster) 持续高频迭代,主题集中在"杀 Pod 触发实例重调度 + gang 门禁""推理亲和性重调度死循环二次修复""npu-exporter 增 UBOE 带宽指标""CVE/开源组件版本修复",偏工程收敛非新特性。
- 全社区本周主线是 v26.06 之后的能力沉淀 + 大规模英文文档补齐(InferNex/hermes-router/sig-ai-inference/vNPU/docs 均新增 README-en),为 v25.12 首个 LTS 前的国际化/发版做准备。

## 新功能 / 能力

- [vNPU 支持 spread/binpack 调度策略](https://gitcode.com/openFuyao/vNPU)(commit `3d6ec4c`,06-29)— 通过 Pod annotation `huawei.com/vnpu-pod-node-scheduler-policy` / `...-device-scheduler-policy` 配置 node 级与 device 级的 spread/binpack;统一 `calculateDeviceScore` 打分函数支持 soft/hard 两模式,设备分配重构为 check/apply 两阶段(评估与状态变更解耦),并支持单 Pod 多设备分配。随后 `aa3c41a`(07-01)把 volcano 插件升到 1.15.0。
  - 启示:这是"通用 K8s AI 栈能借鉴"的一类——把碎片资源(vNPU/GPU 分片)的 spread(打散抗故障)/binpack(压紧提利用率)做成 Pod 级可切换策略,而非全局 scheduler config,与 Kueue/Volcano 的 binpack 思路同源。我们的 GPU/NPU 共享调度也应把打散/压紧下沉到工作负载声明,而不是集群级一刀切。两阶段 check/apply 值得抄,能避免评估期误改状态导致的调度抖动。
- [ub-ssu-csi:UB SSU 存储 CSI 驱动](https://gitcode.com/openFuyao/ub-ssu-csi)(新仓,本周 07-03/04 多个 feat)— 为 Unified Bus 分布式存储实现标准 CSI,原生支持 Block/Filesystem 两类卷 + 组逻辑卷;基于 NVMe over UB 传输,README 自称相较 nvme-of 可让 Mooncake 等上层 AI 存储业务性能提升 ~10%。本周落地 volume stats/staging 支持、block 模式 deviceID/aggregateDevicePath 校验、NodeServer 测试全覆盖。
  - 启示:这是**昇腾/UB 专用**能力,不能直接复用,但方向值得对标——把 KVCache 池化存储(Mooncake)下沉到一个专用高速存储通路 + 标准 CSI,而不是让推理引擎自己管远端 KV。对我们意味着:KVCache offload 的存储后端应抽象成 CSI/CDI 可插拔层,底层用 RDMA/NVMe-oF 还是 UB 只是 driver 差异,上层 Mooncake 接口不变。
- [InferNex 新增 GLM-5.1/5.2、MiniMax-M2.7 vLLM 参考配置](https://gitcode.com/openFuyao/InferNex/tree/main/examples)(commit `821e31c`,07-01)— 三份 ready-to-deploy 的 values.yaml,覆盖不同量化与拓扑:GLM-5.1(w4a8,PD 分离,prefill TP8 / decode TP2)、GLM-5.2(w8a8,聚合 TP8×DP4 + mooncake KV transfer + Ascend 量化 + deepseek_mtp 投机解码)、MiniMax-M2.7(w8a8-QuaRot,PD 分离 TP8/TP8),均基于 hermes-router random profile 串起 inference gateway + 路由 + vLLM 后端。
  - 启示:OpenFuyao 用"模型 × 量化 × PD拓扑"的样例矩阵降低新模型接入门槛,和 vLLM/llm-d 的 recipes、KServe runtime 样例是同一条路。我们对标 KServe 时也该维护一套"主流模型 + 量化方案 + PD/聚合拓扑"的开箱配置库,而不是只给一个通用模板让用户自己调 TP/DP。

## AI 推理栈(InferNex / hermes-router / cache-indexer)

- [hermes-router 新增 README-en](https://gitcode.com/openFuyao/hermes-router)(`046821d`,07-02)、[sig-ai-inference 文档修订](https://gitcode.com/openFuyao/sig-ai-inference)(`54bf68f` 修 InferNex 用户指南锚点、`42bfe54` 修文档错误)本周均为文档/国际化,无新路由策略。README 明确路由三层插件(Data / Request Control / Scheduling)对齐 GIE v1.5.0,策略仍是上周已记的 kv-cache-aware / pd-bucket / prediction(aggregate-prediction、pd-prediction)。
  - 启示:与 KServe llm-d 的 EPP 走同一 GIE 框架,路由能力已收敛稳定,本周无新分叉。持续跟踪点仍是 prediction 策略的数据源(NPU exporter 算力饱和度 + TTFT/TPOT 预测)与评分公式,这块是可迁移到通用 GPU 栈的思路。
- cache-indexer 本周无提交(上周对齐了 Helm chart artifact spec 后暂停)。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [npu-dra-plugin 提升单测覆盖率至 90.1%](https://gitcode.com/openFuyao/npu-dra-plugin)(`374cf70`/`dbffd79`)+ 删除 golangci-lint 配置、修复真实 dcmi 库下的单测(`0876c67`)。无新功能,是发版前的工程质量收敛。
- [sig-orchestration-engine 补齐 DRA ResourceClaimTemplate 切分策略示例](https://gitcode.com/openFuyao/sig-orchestration-engine)(`e31d25d`)— 文档修正显示 npu-dra-plugin 的 vNPU 切分通过 ResourceClaimTemplate 里的 annotation `npu.huawei.com/strategy: "SpacePartitioning"` 声明。
  - 启示:这是本周对我们 **DRA 选型最有价值的一条**——OpenFuyao 把 vNPU 空分策略(SpacePartitioning)塞进 ResourceClaimTemplate 的 annotation,而不是扩 DeviceClass/opaque config。说明其 DRA 实现还在用 annotation 传切分参数(偏过渡态)。我们做 NPU/GPU DRA 共享时应评估:切分策略到底放 ResourceClaim opaque parameters(结构化、可校验)还是 annotation(灵活但弱类型),OpenFuyao 目前选了后者,可作为反面/权衡参照。
- [mind-cluster 昇腾上游](https://gitcode.com/ascend/mind-cluster) 本周实质提交(去重 merge 后):
  - `ee8615c` **支持通过杀 Pod 触发实例重调度** + `3f8bdc7` 修正"未配 gang 调度的 workload 被杀 Pod 不触发重建"→ 用 kill-pod 作为重调度触发信号,并用 gang 标签门禁,只对 gang workload 重建通信域。
  - `c8a2ab2` npu-exporter 增加 **UBOE bandwidth 指标查询**(标签新增 type 字段);`9da107d`/`83aff24` device-plugin 主动查询 IO DIE / UB 网口状态与端口状态范围。
  - `12aad4a`/`b1af251` **开启推理亲和性后重调度偶现死循环**二次修复;`22d6b29` ascend-for-volcano sameRacks 复合 key 避免多 SuperPod 同 RackID 冲突(上周议题的延续)。
  - `5ee000f` 升 golang.org/x/net→v0.55.0 修 CVE-2026-25680、`8bd13e0` 全组件开源软件版本升级修漏洞、`f665dd7` mindio acp 安全问题修改。
  - 启示:mind-cluster 的重调度/容错正围绕"超节点(灵衢/UB)+ 推理亲和 + gang 通信域"打磨,属昇腾专用工程。可迁移的抽象:①用 kill-pod 作为幂等的重调度触发点(声明式、K8s 原生);②故障域感知调度里 rack/superpod 的复合 key 建模,避免跨故障域标识冲突——这在任何多层拓扑(zone/rack/node)调度里都是通用坑。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部 / 安装)

- [cluster-api-provider-bke](https://gitcode.com/openFuyao/cluster-api-provider-bke)(BKECluster 的 Cluster API provider)本周 `e004bc4` 修 provider/bkeagent 数据竞争、`c494fe9` 加 UT、`82908da` 调整 coredns/kube-proxy/calico 安装配置、`299b8fb` i18n。属安装/集群生命周期链路的工程加固。
  - 启示:OpenFuyao 的集群装机走标准 Cluster API + 自定义 BKE provider,与 OpenShift 的 Machine API/CAPI 路线一致。对标点:其昇腾节点的 driver/firmware 安装是否也纳入 CAPI bootstrap,还是走独立 npu-driver-installer,决定了"装机即带昇腾栈"的一体化程度。
- volcano-ext / npu-operator / kae-operator / ub-network-device-plugin 本周无提交,跳过。

## 官方动态
- **本周无官方 release / 新公告**。官网 news/blog/活动均空;CSDN 最新两篇仍是 6-18《生态五大案例入选国家级示范案例》与 6-15《社区 2026 年 3 月-5 月运作报告》(报告口径:v26.03 已发、InferNex 首 token 时延降 30% / E2E 降 10%、约 20 个新技术提案),均在上一窗口已覆盖。
- 无 v26.06 正式 release note,能力仍停留在各仓 README 的"26-06"标注与 sig-ai-inference 性能报告层面。v25.12 首个 LTS 尚未启动发版流程,本周大量英文文档补齐可视作 LTS 前置准备。

## 跟我们产品的对比
- **已有/可对齐**:CSI 存储抽象、Cluster API 装机、GIE 路由框架、vLLM PD/聚合拓扑样例——底座与 OAI/KServe/上游一致。
- **OpenFuyao 独有或更硬件绑定**:UB SSU 存储(NVMe over UB)、UBOE 带宽可观测、SpacePartitioning vNPU 空分、超节点重调度/通信域重建——均绑定昇腾/灵衢,不可直接复用。
- **我们该补**:①vNPU/GPU 分片调度的 spread/binpack 应做成 Pod 级可切换策略 + 两阶段 check/apply;②KVCache offload 存储后端抽象成 CSI/CDI 可插拔层;③主流模型的"量化×PD拓扑"开箱配置库;④DRA 切分参数放 opaque parameters 而非 annotation(比 OpenFuyao 当前做法更结构化)。

## 值得跟进
- [ ] 读 [vNPU spread/binpack 实现](https://gitcode.com/openFuyao/vNPU)(`calculateDeviceScore` + 两阶段 check/apply),评估能否借鉴到我们的 GPU 分片打散/压紧策略。
- [ ] 跟踪 [ub-ssu-csi](https://gitcode.com/openFuyao/ub-ssu-csi) 成熟度,看 Mooncake KVCache 是否会正式以 CSI PV 形态挂载,对照我们 KVCache offload 的存储后端设计。
- [ ] 评估 npu-dra-plugin 用 annotation `npu.huawei.com/strategy` 传切分策略 vs. 我们计划的 ResourceClaim opaque parameters,固化 DRA 选型结论。
- [ ] 继续等 v26.06 / v25.12 LTS 正式 release note,再把各仓 README "26-06" 能力纳入稳定对标。

## 原始材料

<details>
<summary>本次扫描清单(git clone --depth 100 + git log --since=2026-06-29,未用 gh CLI)</summary>

有实质提交:
- https://gitcode.com/openFuyao/vNPU (spread/binpack、volcano 1.15.0)
- https://gitcode.com/openFuyao/ub-ssu-csi (新仓,CSI feat)
- https://gitcode.com/openFuyao/InferNex (GLM/MiniMax 样例、README-en)
- https://gitcode.com/openFuyao/hermes-router (README-en)
- https://gitcode.com/openFuyao/sig-ai-inference (文档修订)
- https://gitcode.com/openFuyao/npu-dra-plugin (单测覆盖率 90.1%)
- https://gitcode.com/openFuyao/sig-orchestration-engine (DRA ResourceClaimTemplate 切分策略示例)
- https://gitcode.com/openFuyao/cluster-api-provider-bke (race 修复、UT、装机配置)
- https://gitcode.com/openFuyao/docs (英文文档/图)
- https://gitcode.com/ascend/mind-cluster (杀 Pod 重调度、UBOE 指标、亲和死循环二修、CVE)

本周无提交(跳过):cache-indexer、npu-operator、volcano-ext、kae-operator、ub-network-device-plugin、sig-installation(仅 2 条 doc)

官方源:
- https://www.openfuyao.cn/zh/ (news/blog 空)
- https://blog.csdn.net/openFuyao (最新 6-18,窗口内无新文)
</details>
