# OpenFuyao 周报 2026-06-01

窗口:2026-05-25 → 2026-06-01(7 天)

## 摘要

- **InferNex + hermes-router 同步升级 v0.22 推理控制面**:vLLM 部署模板从 Deployment 整体换成 LeaderWorkerSet(LWS),首次以一等公民支持多机张量/数据并行;hermes-router 升到 GIE v1.5.0,引入"random / kv-cache-aware / bucket / prediction"四种路由 profile,落地了 tokenizer 与 prediction 两个 gRPC sidecar(后者基于 xgboost/lightgbm 离线训练)。这条线已经超出"KVCache-aware 路由"的叙事,变成"特征 + ML 预测 + 多 profile 调度"的完整栈。
- **weight-dispatcher 从 README 占位仓直接到 RDMA-native 雏形**:5-29 起一周内连续落 ModelWarmupJob CRD、lightweight controller、node-agent、本地文件 dataplane、RDMA 原生引擎、PublishAsSource P2P 节点接力。架构是"控制器 + node-agent DaemonSet + 多种 dataplane",目标场景就是 KServe StorageInitializer 无法处理的 P2P 权重分发,**这是行业空白被独立组件填上的信号**。
- **v26.06 Beta(rc.2)按计划应 5-27~29 出,但 release-management 没有 rc.2 目录、本周只回填了 v26.03 的 kubectl tag**;CSDN 一周年通稿提到的 "Cache Tier V3"(TTFT 降 40%)、"Aether 框架"(京东共建,97% 训练利用率)、Kata+NPU 安全容器(8 卡直通、77~79% 非 Kata 吞吐)三件事在 GitCode 主仓里都看不到对应代码,需要按住"等代码"再下结论。

## 新功能 / 能力

- [InferNex inference-backend 全面切换到 LeaderWorkerSet](https://gitcode.com/openFuyao/InferNex/-/commit/6f8cf2c) — 2026-05-30,prefill/decode/aggregated 三个 deployment 全部改写为 [leaderworkerset.x-k8s.io/v1 LeaderWorkerSet](https://gitcode.com/openFuyao/InferNex/-/blob/master/charts/infernex/charts/inference-backend/templates/prefill-engine-lws.yaml);chart 自动按 `dataParallelSize / dataParallelSizeLocal` 算 `lwsSize = dpSize/dpLocal`,vLLM 多机 DP 启动参数(data-parallel-address / start-rank / rpc-port / hybrid-lb)由 chart 自动注入
  - 启示:**LWS 正式成为 InferNex 的多机推理底座**。KServe 主线还在用 `InferenceService` + Deployment,llm-d 也只有路由层。LWS 是 K8s SIG 项目,直接支持"1 个 leader pod + N 个 worker pod 作为同一推理实例"的拓扑,跟 vLLM/SGLang 多机部署的真实形态对得上。如果我们做 LLM 推理产品,**继续靠 Deployment + Headless Service 拼出 PD 多机已经落后**;应该走 LWS,InferNex 的 chart 模板(`_helpers.tpl` 里的 `lwsReplicas` / `lwsSize` 计算)是可以直接借鉴的样本
- [hermes-router 升级 GIE v1.5.0 + 重设四套路由 profile](https://gitcode.com/openFuyao/hermes-router/-/commit/cec164e) — 一周内 30+ commits,核心:[GIE v1.5.0 base 升级](https://gitcode.com/openFuyao/hermes-router/-/commit/f3975fa)、[NPU 数据层与 extractor 管道](https://gitcode.com/openFuyao/hermes-router/-/commit/93b342e)、[tokenizer sidecar + 插件](https://gitcode.com/openFuyao/hermes-router/-/commit/04e3d93)、[shared inflight 生命周期跟踪](https://gitcode.com/openFuyao/hermes-router/-/commit/152e0dc)、[prefix cache producer](https://gitcode.com/openFuyao/hermes-router/-/commit/c8c393c)、[prediction sidecar + 离线训练管道](https://gitcode.com/openFuyao/hermes-router/-/commit/8f7b8f1)、[routing plugins 重设](https://gitcode.com/openFuyao/hermes-router/-/commit/0839e0f)
  - 启示:**这是 KVCache-aware 路由向"ML 预测调度"扩张的关键一步**。新增 4 个 profile:random / kv-cache-aware / bucket(PD 专用)/ prediction。`prediction` profile 跑的是一个独立 Python sidecar(`sidecar/prediction/src/app.py`),用 xgboost 或 lightgbm 做分位数回归(默认 q=0.9),特征包括 prefixCacheScore(4 桶)、kvCacheUsage(20 桶)、numRequestWaiting(5 桶)、inputTokenLength,从生产 inflight 落盘 JSONL 数据离线训练 artifact 再热加载。这跟 llm-d / Dynamo 的"heuristic 权重打分"是分叉,**OpenFuyao 选了 ML 预测分支**。tokenizer sidecar(gRPC over UDS,支持 HuggingFace + ModelScope)解决了 router 不知道 prompt 真实 token 数的痛点。我们如果做 LLM 路由层,**这两个 sidecar 都值得拆出来单独借鉴 — 都是与 NPU/昇腾无关的通用能力**
- [weight-dispatcher 从空仓到 RDMA 雏形,ModelWarmupJob CRD 成型](https://gitcode.com/openFuyao/weight-dispatcher/-/blob/master/api/v1alpha1/modelwarmupjob_types.go) — 5-29~6-01,关键 commit:[foundation 包](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/7dd315e)、[cache state machine](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/047fdbf)、[warmup API types](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/8092115)、[local filesystem dataplane](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/78d7a7a)、[lightweight controller](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/1688b76)、[RDMA Go dataplane](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/aa4ef6a)、[RDMA native engine](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/b727d6d)、[node agent entrypoint](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/8ee8ad6)、[HuggingFace helpers](https://gitcode.com/openFuyao/weight-dispatcher/-/commit/c980542)
  - 启示:**P2P 权重分发这条能力线 OpenFuyao 已经下场,且选了 RDMA + 节点接力(PublishAsSource)路径**。CRD 字段定义干净:`Artifact{Type,Key}`、`Sources[{sourceType=node|external,nodeName,endpoint,path}]`、`Target{nodeNames|nodeSelector,targetPath}`、`Policy{ChunkSizeMB,EnableChunkCRC32C,PublishAsSource,TimeoutSeconds}`,status 记录每个节点的 BytesTransferred / ThroughputMBps / TransportPath。`PublishAsSource=true` 意味着节点完成 warmup 后自动注册为后续作业的 source — **这是 BitTorrent / Run.AI Model Streaming 同款思路**。RDMA 是 Mellanox / 昇腾通用接口,**不是昇腾专属**;如果我们做 K8s 上的 LLM 推理平台,这个 CRD 抽象可以直接借鉴(NVIDIA GPU 集群下 RDMA dataplane 换成 NCCL/GDS 或 TCP 也成立)
- [InferNex Checker 加入,Helm install 前的 H/K/CE 三层预检查工具](https://gitcode.com/openFuyao/InferNex/-/commit/4e58660) — 2026-05-30,`infernex-checker/` 6700+ 行 Go 代码;CLI 子命令 `hardware`(H-01~H-08:NPU 驱动/固件、Ascend Device Plugin、NPU 可用性、host 文件完整性、hccn.conf、节点内 HCCS、跨节点 RoCE RDMA)、`k8s`(K-01~K-04)、`configenv`、`all`;输出 JSON 报告
  - 启示:**这是"装机前自检"能力 — 角色对标 OpenShift 的 must-gather + preflight,但更窄,只针对 InferNex 部署**。检查项 90% 是昇腾专属(`hccn_tool ping` / `/dev/davinci*`),通用 K8s 栈不能直接抄。**但产品形态值得借鉴**:把 "Helm install 前应该跑什么检查" 抽象成独立 CLI + JSON 报告,比塞到 operator preflight 里更轻、用户能本机离线跑、CI 流水线友好。我们如果做企业级 K8s AI 平台,提供一个 `<product>-check` CLI 是降低支持成本的小投入
- [elastic-scaler 落地 HPA-like 推荐稳定化与 default 算法](https://gitcode.com/openFuyao/elastic-scaler/-/commit/e905de5) — 2026-05-28 大合入 ~5500 行;新增 [DefaultRecommendationStabilizer](https://gitcode.com/openFuyao/elastic-scaler/-/blob/master/pkg/elasticscaler/scaling/recommendation_stabilizer.go)(scaleUp 默认 30s 窗口、scaleDown 默认 180s 窗口、maxPodsPerStep 注解)、[AverageAlgorithm 默认算法](https://gitcode.com/openFuyao/elastic-scaler/-/blob/master/pkg/elasticscaler/scaling/default_algorithm.go)(upTolerance/downTolerance/maxScaleUpRate/maxScaleDownRate);[同周落地 APA 推荐稳定化](https://gitcode.com/openFuyao/elastic-scaler/-/commit/0850ad6)、[ExternalServer query + ready pod filter](https://gitcode.com/openFuyao/elastic-scaler/-/commit/40879ac)、[scaling 算法名归一化](https://gitcode.com/openFuyao/elastic-scaler/-/commit/89de0f9)
  - 启示:**elastic-scaler 正在重做一套 HPA**,行为注解(`elasticscaler.io/behavior.scaleUp.stabilizationWindowSeconds` 等)直接抄 K8s HPA v2 的 `behavior` 字段。**但加了两个 LLM 场景需要的东西**:① ExternalServer 数据源(可以接 vLLM /metrics 之类不在 Prometheus 里的端点);② APA(自适应)+ tidal(潮汐)等专门为推理设计的算法。这跟 KServe 的 AutoscalerClass=hpa/kpa 是一个生态位的竞争品。如果我们做推理产品,**KEDA + 自定义 ScaledObject 仍然是更轻的方案**,但 elastic-scaler 的 algorithm 接口设计可以参考
- [npu-dra-plugin 重新有了 commit](https://gitcode.com/openFuyao/npu-dra-plugin/-/commit/28088b4) — 2026-05-28 修了 Ascend910 整卡 CDI edits 的物理 ID 配对 bug(`base = phyID - phyID%2` 替代 `npuIndex*2`),commit msg 是"支持按照容量进行动态硬切分调度",**实际改动只是 4 行 bug 修复**;无新 tag、无新功能进展
  - 启示:仓位仍然冷,DRA 接入昇腾仍停在去年的设计文档阶段,**短期不进我们 DRA 路线评估的优先级**(沿用上周判断)

## AI 推理栈(InferNex / hermes-router / ...)

- [InferNex 合入 cache-indexer Go 版到 master](https://gitcode.com/openFuyao/InferNex/-/commit/13ac6f5) — 2026-05-26,把上周的 `feat/go-refactor` 全量合到 master,InferNex chart 默认拉的就是 Go 版 cache-indexer
- [hermes-router chart 配置重构,路由 profile 模板化](https://gitcode.com/openFuyao/InferNex/-/commit/873f67c) — InferNex 主仓 `values.yaml` 把 hermes-router 段从"内嵌 EPP YAML 字符串"改为"profile + 子字段",可直接通过 helm values 选 `routing.profile=kv-cache-aware | prediction | bucket | random`,并配置 tokenizer sidecar 路径、cacheIndexer 地址、persistence 等;实际模板逻辑在 [hermes-router 仓 caf2091 feat(charts): template routing profiles](https://gitcode.com/openFuyao/hermes-router/-/commit/caf2091) 落地
- [InferNex chart 加 network-performance-exporter 默认配置](https://gitcode.com/openFuyao/InferNex/-/commit/3f61176) — `eagle-eye-network-performance-exporter` 加入默认 values,metricsPort=8222、collectInterval=15s — 网络性能监控正式进入 InferNex 标配栈;eagle-eye 此前以"hardware-diagnosis + hardware-monitor"两件出现,本周加上 network-performance 凑齐三件
- [hermes-router chart provider 默认切到 istio](https://gitcode.com/openFuyao/hermes-router/-/commit/286f510) — chart 默认 provider 字段切到 istio,跟 GIE v1.5.0 主流路径对齐(envoy → istio gateway)
- [cache-indexer 配置改读 ConfigMap,日志去 console 仅留 JSON](https://gitcode.com/openFuyao/cache-indexer/-/commit/3f16b42) — 5-27 落入,配套 [chore: simplify build flow](https://gitcode.com/openFuyao/cache-indexer/-/commit/1a04ca7)、[stabilize naming, enhance endpoint discovery](https://gitcode.com/openFuyao/cache-indexer/-/commit/ac8d726);Go 版进入稳定化打磨阶段
- [cache-indexer discovery 用 mooncake master segments 反查 vLLM endpoint](https://gitcode.com/openFuyao/cache-indexer/-/commit/bbe99ef) — L3(Mooncake)拉到的 segment 反向解析回 vLLM pod IP,这是 L1/L3 聚合查询前置依赖

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [mind-cluster infer-operator 实例级重调度落地"实际故障重调度"](https://gitcode.com/Ascend/mind-cluster/-/commit/797badc) — 2026-05-26,`pkg/controller/rescheduling/rescheduling.go` +220 行 + 716 行测试;上周是"故障感知与记录",本周是基于感知结果**触发实际重调度动作**;同步合 [InstanceSet 删除事件漏清理 bug](https://gitcode.com/Ascend/mind-cluster/-/commit/158671e)
  - 启示:[2026-04-17 双控制面 deep-dive](./2026-04-17-openfuyao-infer-operator-vs-infernex.md) 提到的 mind-cluster infer-operator 这条线本周补齐了"重调度执行"环节,跟 InferNex 那边走 KServe `LLMInferenceService` 还是两条独立路径;**双控制面格局没解,反而都在加重**
- [mind-cluster infer-operator 增加优先级调度文档+示例](https://gitcode.com/Ascend/mind-cluster/-/commit/d105d2d) — 文档 +152 行,新增 `schedulingStrategy.type=Priority` 字段(默认 `Parallel`),prefill/decode/router 三个角色可以分别配 `priority`(值越小越高优);**主要场景:缩 P 保 D**(降低 prefill 优先级以保住 decode 实例)
  - 启示:**"PD 角色感知的优先级调度"是 KServe 没有的能力**。KServe 把推理实例当无角色单元,缩容时不会区分 prefill 还是 decode;OpenFuyao 这套把"角色 + 优先级"作为一等公民。**如果我们做 PD 解耦推理服务,这种 role-priority 模型应该是默认设计**,不是 nice-to-have
- [mind-cluster device-plugin 补齐 vNPU 软切分能力](https://gitcode.com/Ascend/mind-cluster/-/commit/e044208) — 2026-05-28,~640 行 + 343 行说明文档;接 dcmi v2 API,plugin 上报多种切分形态的 vNPU;[配套文档说明 5-30 入](https://gitcode.com/Ascend/mind-cluster/-/commit/154615d)。**配合 openFuyao 主组织新公开的 [vNPU 仓](https://gitcode.com/openFuyao/vNPU)**(基于 CANN ACL Runtime API hijack 做用户态虚拟化,1-to-20 切分粒度、AICore 与显存可独立切分),两条线连起来:**mind-cluster device-plugin 上报 + vNPU 仓做 ACL 拦截**
  - 启示:vNPU 是昇腾专属(基于 CANN runtime API hijack),但**思路 = NVIDIA MPS / GMA-IO 同款用户态时分复用**;通用 GPU 栈对应的方案是 NVIDIA MPS、HAMi、vGPU 等,**不是直接借鉴对象**,但提示了"硬件原生分片粒度不够时,用户态拦截补位"是产业普遍策略
- [mind-cluster device-plugin / npu-exporter 支持 UBX / 大禹 / 银河机型](https://gitcode.com/Ascend/mind-cluster/-/commit/2c0300a) — 三类新机型识别;[npu-exporter 同步支持](https://gitcode.com/Ascend/mind-cluster/-/commit/231eae2);[Atlas 9000 A3 SuperPod 断点续训资料](https://gitcode.com/Ascend/mind-cluster/-/commit/2d38a57)
  - 启示:硬件适配持续滚动,**不是产品借鉴维度的关注点**,但提示昇腾产品矩阵在持续扩张,对标产品(我们)如果以"硬件无关"为卖点,这是优势放大窗口
- [mind-cluster 进程级重调度 + 框亲和性场景恢复失败 fix](https://gitcode.com/Ascend/mind-cluster/-/commit/5cf6db8) — `clusterd` reboot 场景下 fault_recover 控制器修复;[taskd 与 clusterd kill master 协同 bug fix](https://gitcode.com/Ascend/mind-cluster/-/commit/9ee66c1)
- [mind-cluster 节点配置易用性优化](https://gitcode.com/Ascend/mind-cluster/-/commit/b7ebe0b) — 涉及 ascend-common / device-plugin / volcano / ascend-docker-runtime / npu-exporter / ascend-operator / infer-operator / noded 多组件,统一 node label 规则;减少装机 boilerplate
- [mind-cluster BMC 故障模式库继续扩张](https://gitcode.com/Ascend/mind-cluster/-/commit/38d4e52) — [BMC fault mode library part last](https://gitcode.com/Ascend/mind-cluster/-/commit/38d4e52),配合上周的 OS/HBM 故障码;故障诊断维度持续扩张到 BMC 层
- [npu-operator](https://gitcode.com/openFuyao/npu-operator/commits/master)、[ub-network-device-plugin](https://gitcode.com/openFuyao/ub-network-device-plugin) — 本周仅 README 维护,无功能变更

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [cluster-api-provider-bke feat/upgrade-530:升级流程进入 DAG 执行阶段](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/5363ba4) — 一周内 20+ commits,核心:[execute DAG + BkeAgentConfig CRD](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/7073bc4)(~3500 行,新增 `componentfactory` 包 + `dagexec` scheduler + `BkeAgentConfig` 配置 CRD)、[pre-upgrade phase](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/5791cdc)(~835 行,phase framework + bundle registry)、[DeclarativeUpgrade process + bc 完成状态](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/5363ba4)、[ReleaseImage OCI pull fix](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/b1ea916)、[image pull log](https://gitcode.com/openFuyao/cluster-api-provider-bke/-/commit/a665f70)
  - 启示:**上周给出的"集群升级控制面 CRD 抽象"本周开始落实施加层**。phase framework + DAG scheduler + component factory + bundle registry 的拆法是 OpenShift CVO 同款架构(operator 编排 + manifest 拉取 + 阶段化升级)。**OCI artifact 加载 release image 这条路径已经跑通**(`b1ea916 fix releaseimage oci pull`),意味着发布通道可以纯走 OCI registry,**这比 OpenShift 自建 Cincinnati 服务的方案轻一档**。我们如果要做平台级升级,这套 phase framework(`pkg/phaseframe/`)+ DAG 调度器(`pkg/dagexec/scheduler.go`)的代码骨架值得通读
- [community 仓登记 compliance-operator](https://gitcode.com/openFuyao/community/-/commit/e961d7f) — 2026-05-28,security-committee SIG 新登记 `openfuyao/compliance-operator` 公开仓,描述"安全扫描 Operator,支持 CIS、STIG 规则扫描"
  - 启示:**这是 OpenShift Compliance Operator 的同位对标**。Red Hat OAI 通过 Compliance Operator 提供 CIS / NIST / STIG 基线扫描,**OpenFuyao 现在准备做对应物**;代码尚未公开,但仓位登记意味着上下游有人在写。**对比维度上 OpenFuyao 在补齐企业合规栈**,我们也该评估自家产品的合规扫描路径
- [community 仓登记 openfuyao-powers(AI 辅助研发能力集)](https://gitcode.com/openFuyao/community/-/commit/08b0828) — sig-ai-inference 新登记 `openfuyao/openfuyao-powers` 公开仓:"为 openFuyao 社区提供 AI 辅助研发能力集,覆盖需求分析、方案设计、编码开发与集成测试,支持 Claude Code、Codex、OpenCode 等"
  - 启示:**OpenFuyao 开始把"内部 AI-augmented dev workflow"产品化对外开源**。这跟我们做 AI 基础设施产品本身关系不大,**但提示一个数据点**:这个组织本身在用 Claude Code 等工具做开发(配套 e2e-auto-test 仓里也出现了 `CLAUDE.md`);后续可关注这套 powers 的 skill / 工作流模板抽象
- [community 仓登记 openfuyao-sandbox](https://gitcode.com/openFuyao/community/-/commit/082937b) — sig-orchestration-engine 登记新仓,无更多信息;名字暗示是 Agent / sandbox / K8s-on-K8s 实验场域;沿用上周"sandbox 路径有动作"的判断
- [ubs-k8s-enable 持续打磨,内存共享/借用走 CSI 路径](https://gitcode.com/openFuyao/ubs-k8s-enable) — 本周修了 csi 插件日志、CR poduid 限制、6010 错误码冲突;README 明确两类能力:**内存无感借用**(节点 NUMA 内存到阈值时跨节点借用)、**内存共享**(UBS-Core 内存池化,跨节点共享内存块)
  - 启示:**昇腾 UB 专属能力**(需要 UB 硬件 + OpenEuler 24.03 + 内核 `numa_remote=nofallback`),通用 K8s 栈无法借鉴;但提示"内存作为可调度资源"在异构互联硬件上有产品化空间
- [volcano-ext](https://gitcode.com/openFuyao/volcano-ext)、[volcano-config-service](https://gitcode.com/openFuyao/volcano-config-service)、[volcano-config-website](https://gitcode.com/openFuyao/volcano-config-website) — 本周仅 README 维护;volcano-config 两个仓本周首次出现在 openFuyao 首页 featured(但代码自 2025-03 起);Volcano NUMA 拓扑可视化前端

## 官方动态

- **v26.06 rc.2(Beta)按 release-plan 应 5-27~29 出,实际未出**:[release-management 仓](https://gitcode.com/openFuyao/release-management/commits/main) 本周只合了 [v26.03 的 kubectl-openfuyao 版本回填](https://gitcode.com/openFuyao/release-management/-/commit/e2798b5) 和英文 README,**没有 `openFuyao-26.06/rc.2/` 目录**;按 [release-plan](https://gitcode.com/openFuyao/release-management/blob/main/openFuyao-26.06/release-plan.md) 下一步是"全量测试期 6-01 ~ 6-15"和"rc.3 6-17~19"、GA "6-29~30"。**rc.2 实际滑窗,GA 是否还能赶 6-30 需要在下一周看 release-management 是否出 rc.2 目录**
- **KADC 2026 openFuyao 分论坛 / 主会场展示**(2026-05-26 两篇 CSDN):
  - [大咖云集:Aether + V3 Cache + URMA + 容器热迁移](https://blog.csdn.net/openFuyao/article/details/161432507) — **披露的可验证能力指标(剥离营销话术)**:
    - **京东 × openFuyao "Aether" 框架**:"Brain 全局决策 + Driver 运行时感知 + Executor 进程级执行",数字"训练有效时间 97%、资源成本下降 30%"(基线模型未披露);**对应 GitCode 仓里目前找不到 `aether` 命名,可能仍在内部或对应已开源的某个仓** — 下周待核
    - **Cache Tier V3 / Mooncake 共建**:"TTFT 降 40%、端到端时延降 30%",承载在 InferNex 中(对应本周仓里的 cache-indexer L1/L3 架构和 InferNex Mooncake resource limits 配置)
    - **中国移动云超节点**:"两万卡超节点集群,三层拓扑感知调度、逻辑超节点、自动故障检测隔离,分钟级训练任务恢复"
    - **中国联通 CSK Turbo**:"KVCache-aware 路由平均时延降 36%、TTFT 提升 50%"、"100GB 镜像下载从分钟级到约 1 分钟"(后者对应 InferNex `huggingface-download` 0.23 镜像)
    - **路线图关键词**:新模型加速、超节点文件语义抽象、多模态、DRA(动态资源分配)、Agent sandbox、智能运维
  - [鲲鹏昇腾大会展台:K8s-on-K8s + Kata+NPU](https://blog.csdn.net/openFuyao/article/details/161431636):
    - **沈一帆 演讲**:"K8s-on-K8s 大规模集群终态自治运维",通过"管理集群统管工作负载集群",后续靠 openFuyao BKE 实现多节点高可用 + 弹性伸缩 — **对应本周 cluster-api-provider-bke 的 DeclarativeUpgrade / DAG 执行框架**
    - **罗刚毅 演讲**:"Kata+NPU 集群安全容器调度",Kata+QEMU+VFIO+CDI+Guest rootfs,"8 卡 NPU 整卡安全直通,单卡算子性能无损,大模型推理达非 Kata 场景 77~79% 吞吐";**GitCode 目前找不到对应仓**,可能仍在 ascend 上游或未公开
- 一周年通稿(5-22)上周已覆盖,本周无新发文;**官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/) news/release/blogs 三板块仍"暂无内容"**,沿用上周判断
- 上周登记的 `many-core-orchestrator` 仍非公开;`weight-dispatcher` 本周从占位仓变出代码(见"新功能"章节)
- **vNPU 仓首次出现在 openFuyao 首页 featured**(2026 年 3 月起就有 commit,但此前未在主组织 featured 列表);**volcano-config-service / volcano-config-website 同样**(NUMA 拓扑可视化前端 + 服务);**沙箱型仓位补齐 ubs-k8s-enable / ubs-openstack-enable**

## 跟我们产品的对比

| 维度 | OpenFuyao 本周变化 | OAI / KServe / 通用 K8s 栈 | 我们应该怎么做 |
|------|-------------------|---------------------------|----------------|
| 推理实例多机部署 | **(本周新增)**InferNex 全量切 LeaderWorkerSet,vLLM DP 启动参数 chart 自动注入 | KServe 仍 `InferenceService` + Deployment;llm-d 无多机原语 | **直接借鉴** — 多机 PD/DP 拓扑用 LWS 是上游 K8s SIG 推荐路径;InferNex 的 `_helpers.tpl` 是参考模板 |
| LLM 路由层 | **(本周新增)**hermes-router GIE v1.5.0 + 4 个 profile(random/kv-cache-aware/bucket/prediction)+ tokenizer/prediction 两个 sidecar | KServe + llm-d 主用 KVCache-aware 启发式;无 ML 预测路由 | **借鉴 tokenizer sidecar 设计**(UDS gRPC + HuggingFace/ModelScope provider);**评估是否走 prediction profile**(xgboost/lightgbm 分位数回归)— 这条 ML 路径与启发式各有取舍,优势在长尾负载稳定性 |
| 权重分发 | **(本周新增)**weight-dispatcher 落 ModelWarmupJob CRD,RDMA dataplane + PublishAsSource P2P 节点接力 | KServe StorageInitializer 单点 init container 拉取;无 P2P、无 RDMA、无预热 | **借鉴 CRD 抽象**(ModelWarmupJob 字段 = artifact/sources/target/policy);RDMA dataplane 在通用 GPU 集群可换 NCCL/GDS/TCP — **架构骨架可移植** |
| 部署预检查 | **(本周新增)**InferNex Checker CLI(H/K/CE 三层 + JSON 报告) | 无对等物,OAI 靠 must-gather 事后排错 | **可借鉴产品形态**(独立 CLI、JSON 输出),检查项内容是昇腾专属不可移植 |
| HPA-like 弹性 | elastic-scaler 落地默认稳定化算法(stabilization window + maxPodsPerStep behavior 注解);APA 稳定化 | KServe 用 K8s HPA v2(behavior 字段) / KPA | **不必自研** — KServe 默认栈足够;elastic-scaler 的 ExternalServer 数据源思路可借鉴(vLLM 引擎内 metrics 不经 Prometheus 直接喂给 scaler) |
| 推理控制面 | InferNex(KServe-style)+ mind-cluster infer-operator(实例级 PD 优先级 + 故障重调度)双线并存,两边都在加重 | 单一路径(KServe) | 沿用上周判断 — **我们保持单路径,避免概念分裂** |
| 集群升级 | cluster-api-provider-bke 从 4 个 CRD 推进到 DAG 执行框架 + Pre-upgrade phase + ReleaseImage OCI 拉取 | OAI 靠 OpenShift CVO + Cincinnati(平台,非 OAI 自带) | **直接借鉴架构** — phase framework + DAG scheduler + bundle registry 的拆法可移植;OCI artifact 作为升级图载体比自建 update server 轻 |
| 合规扫描 | **(本周新增)**community 登记 compliance-operator(CIS / STIG 规则) | OAI 有 Red Hat Compliance Operator(CIS / NIST / STIG) | **评估合规扫描在产品形态中的位置** — 企业客户审核时这是硬需求,代码尚未公开,**先关注他们打算用哪个 OPA 后端或定制实现** |
| PD 角色感知调度 | **(本周新增)**infer-operator 加 `schedulingStrategy.type=Priority`,prefill/decode/router 三角色独立 priority(默认场景:缩 P 保 D) | KServe 把推理实例当无角色单元 | **如果做 PD 解耦,role-priority 应作为默认设计**,不是 nice-to-have |
| 故障感知重调度 | mind-cluster infer-operator "感知 → 实际触发" 闭环 | KServe Liveness/Readiness + Pod 重启 | 沿用上周判断 — "workload 抽象 + 故障码驱动重调度" 模式可应用于 GPU 故障(NVML 事件、ECC) |
| 用户态硬件虚拟化 | **(本周新增)**vNPU 仓首次 featured(CANN ACL Runtime API hijack,1-to-20 切分粒度) | NVIDIA MPS / HAMi / vGPU(GPU 同位对标) | 思路通用,实现对昇腾专属;**不直接借鉴** |
| 网络池化资源 | UBS-K8s 内存借用 / 共享(UB 专属);eagle-eye 加 network-performance-exporter | Multus / SR-IOV;无内存池化 | UBS 不通用,**network-performance-exporter** 这条监控线可借鉴(KServe 推理服务监控也缺一个网络层维度) |
| DRA | npu-dra-plugin 本周仅 1 个 bug fix | K8s 1.34 DRA 已 GA | 沿用上周判断,DRA 短期不进主路径 |

## 值得跟进

- [ ] **读 hermes-router 的 `sidecar/prediction/` 与 `pkg/epp/internal/inflight/store.go`**:弄清 prediction profile 的训练数据从生产 inflight 落盘 JSONL 的格式、xgboost 训练参数空间、quantile=0.9 的业务含义;评估 ML 预测路由是否值得纳入我们路由层设计的候选(对比 llm-d / Dynamo 的纯启发式)
- [ ] **跑通 weight-dispatcher RDMA dataplane 端到端**:用 docker compose 起两个 node-agent,验证 PublishAsSource P2P 接力是否真能工作;弄清 RDMA bindings 的具体技术栈(libibverbs?rdma-core?)是否能在 GPU 集群无缝复用
- [ ] **完整 review InferNex Checker 的 K8s 检查项 K-01~K-04**:其中通用部分(K8s API server、CNI、CRD 完整性?)可以抽出来作为我们产品的 preflight 检查参考
- [ ] **read cluster-api-provider-bke `pkg/phaseframe/` + `pkg/dagexec/scheduler.go`**:phase framework + DAG 调度的接口抽象;评估是否能用于我们产品的升级流程编排(对比 Operator SDK / Argo Workflows / Tekton 重型方案)
- [ ] **关注 v26.06 rc.2 是否在下周(2026-06-02 ~ 06-08)出**:如果继续滑窗,GA 6-30 风险大;rc.2 是 "新特性上车截止" 的硬节点,可以一次性看清 v26.06 实际进入了哪些组件
- [ ] **关注 KADC 2026 提到的 "Aether 框架" 对应代码仓**:京东共建,目前 GitCode 上 grep 不到,下周扫一遍 openFuyao 与 jd 上游
- [ ] **compliance-operator 公开后第一时间读 CRD 与 SCAP/OPA 后端选型**:决定我们是否对齐到同一基线扫描标准

## 原始材料

<details>
<summary>本周扫描清单</summary>

**openFuyao 主组织活跃仓**(commits in 2026-05-25..2026-06-01):
- `InferNex`:25+ commits,核心:`6f8cf2c merge: inference backend upgrades to LWS resource deployment`(2026-05-30,~790 行 +/-,prefill/decode/aggregated 全部改 LeaderWorkerSet);`4e58660 feat: add infernex checker`(2026-05-30,+6729 行 Go 代码 — H/K/CE 三层预检查工具);`873f67c feat: Refine hermes-router chart configuration for v26.06`(2026-05-30,values.yaml profile 化重构);`13ac6f5 merge cache-indexer into master`(2026-05-26);`3f61176 update: update values.yaml`(2026-05-30,加 network-performance-exporter);`b95b55e fix: allow global.modelName with "."`、`9440c08 fix hermes router image name error`
- `hermes-router`:30+ commits,**核心结构性升级**:`f3975fa feat: upgrade Hermes Router to GIE v1.5.0`(2026-05-27)、`93b342e feat: add NPU datalayer and extractor pipeline`、`04e3d93 feat: add tokenizer sidecar and tokenizer plugin integration`(+11287 行)、`152e0dc feat: add shared inflight lifecycle tracking`(+6548 行)、`c8c393c feat: add prefix cache producer`(+1085 行)、`8f7b8f1 feat: add prediction sidecar and offline prediction pipeline`、`0839e0f refactor: redesign routing plugins for GIE v1.5.0 scheduling`、`caf2091 feat(charts): template routing profiles`(2026-05-28)、`286f510 chore(chart): default provider to istio`(2026-05-29)
- `cache-indexer`:15+ commits,Go 版稳定化:`f6216d0 merge feat/go-refactor into master`(2026-05-25)、`3f16b42 refactor(config)!: load settings from ConfigMap`(2026-05-27)、`bbe99ef fix(discovery): use mooncake master segments for vLLM endpoints`(2026-05-26)、`ac8d726 feat: stabilize naming, enhance endpoint discovery`(2026-05-28)
- `cluster-api-provider-bke`:**master 仅 2 个文档/合并 commit**,主力在 `feat/upgrade-530`(20+ commits):`7073bc4 feat: add execute dag and bkeagent config`(2026-05-28,+3500 行,新增 BkeAgentConfig CRD)、`5791cdc feat: add pre-upgrade phase`(2026-05-28,+835 行,phase framework)、`5363ba4 feat: add DeclarativeUpgrade process`(2026-05-29,+1407 行)、`b1ea916 fix: fix releaseimage oci pull`(2026-05-29)、`a665f70 feat: add pull image log`(2026-05-30)、`bcb64e8 fix: DFX modify`(2026-05-30)
- `elastic-scaler`:8 commits,`e905de5 feat: implementation of elasticscaler enhancements`(2026-05-28,+5556 行 -446 行 — 大架构升级)、`0850ad6 feat: stabilize APA replica recommendations`(2026-05-27)、`40879ac feat: support external server query and ready pod filtering`(2026-05-25)、`89de0f9 fix: normalize scaling algorithm names`(2026-05-30)、`c623a87 chore: bump version to 0.22.0`(2026-05-30)后又被 revert(`631bb8b`, 2026-06-01)
- `weight-dispatcher`:50+ commits,**从空仓建仓**:`7dd315e feat: add foundation packages`(2026-05-29)、`8092115 feat: add warmup API types`、`047fdbf feat: add cache state machine`、`78d7a7a feat: add local filesystem dataplane`(2026-05-30)、`1688b76 feat: add lightweight controller entrypoint`、`aa4ef6a feat: add rdma go dataplane`、`b727d6d feat: add rdma native engine`、`8ee8ad6 feat: add node agent entrypoint`、`c980542 feat: add rdma huggingface helpers`(2026-05-29)、`5495646 fix: enable native rdma tag`(2026-05-30)、`b8e3595 fix: stabilize ModelWarmupJob cache reuse and fallback paths`(2026-05-31)
- `community`:`082937b add openfuyao-sandbox repo`(2026-06-01)、`08b0828 添加 AI 辅助研发能力集`(2026-05-30,新登记 `openfuyao-powers`)、`e961d7f 添加安全扫描仓库`(2026-05-28,新登记 `openfuyao/compliance-operator`)
- `npu-dra-plugin`:`28088b4 支持按照容量进行动态硬切分调度`(2026-05-28,实际只是 4 行 phyID 配对 bug 修复;**commit msg 与实际改动不符**)
- `release-management`:**v26.06 rc.2 未出**;仅 `e2798b5 update: update kubectl-openfuyao version`(2026-05-28,回填 v26.03 各阶段)
- `npu-operator`:仅 1 个 master merge,无功能变更
- `ubs-k8s-enable`:`a64debe fix: 适配 ubse 的 so 的版本号修改`(2026-05-26)、`b9d5906 fix: 增加 csi 插件定位日志`(2026-05-26)、`65568d1 docs: 在部署说明中补充添加用户和目录`(2026-05-27)
- `e2e-auto-test`:`bbab3d4 feat: add many-core-orchestrator e2e test cases`、`f3caa55 feat: add mco-metrics test cases README`、`81582de chores: update CLAUDE.md`(2026-05-29)、`ed671a4 add checkpoint e2e`(2026-06-01)

**openFuyao 主组织无活动仓**(窗口内 0 实质 commit):
- `volcano-ext`、`kae-operator`、`ub-network-device-plugin`(仅 README)、`olc-python`

**openFuyao 主组织首次出现在 featured(代码不新):
- `vNPU`(2026-03 起就有 commit,本周本届可见性提升):基于 CANN ACL Runtime API hijack 做用户态 NPU 虚拟化,1-to-20 切分粒度,AICore + 显存独立切分
- `volcano-config-service` / `volcano-config-website`(2025-03 起):Volcano NUMA 调度可视化前端

**上游 Ascend/mind-cluster**:本窗口 95+ commits,核心:
- `797badc 【infer-operator】infer-operator实例级重调度：实际故障重调度`(2026-05-26,+936 行 / 715 行测试)
- `158671e 修改instanceSet删除事件可能漏掉清理动作的bug`(2026-05-29)
- `d105d2d 【资料修改】Infer-Operator 增加优先级调度资料`(2026-05-28,+152 行,文档介绍 schedulingStrategy.type=Priority 与缩 P 保 D)
- `e044208 <feature>【device-plugin】【修改说明】VNPU 软切分能力补齐`(2026-05-28,+640 行 + 343 行文档)
- `154d0a8 / 154671e (5-30) 【device-plugin】【修改说明】VNPU 软切分能力补齐资料补充`(2026-05-30)
- `2c0300a 【Device-plugin】支持UBX/大禹/银河机型`(2026-05-30)、`231eae2 [npu-exporter] 支持大禹、银河、UBX机型`(2026-05-30)
- `b7ebe0b <feat>【ascend-common/device-plugin/volcano/ascend-docker-runtime/npu-exporter/ascend-operator/infer-operator/noded】节点配置易用性优化`(2026-05-29)
- `5cf6db8 【clusterd】fix: 进程级重调度reboot与开启框亲和性场景下可能导致的恢复失败`(2026-05-30)
- `9ee66c1 【taskd】 clusterd和taskd的kill master协同问题`(2026-05-28)
- `38d4e52 [feat][FD] add bmc fault mode library part last`(2026-05-29)
- `2d38a57 [docs]添加Atlas 9000 A3 SuperPod硬件类型断点续训支持`(2026-05-30)

**v26.06 状态**:仍停在 rc.1,无 rc.2 目录;release-plan 中 rc.2 Beta deadline 是 2026-05-26(PR 截止)/ 5-27~29(发布),**实际滑窗**;rc.3 与 GA 仍按计划标 6-19、6-30

**官方信息源**:
- 官网 [www.openfuyao.cn](https://www.openfuyao.cn/zh/)(news/release/blogs 仍"暂无内容")
- 文档站 [docs.openfuyao.cn](https://docs.openfuyao.cn/zh/)(无 release notes 公开路径)
- CSDN [blog.csdn.net/openFuyao](https://blog.csdn.net/openFuyao) 2 篇新文:
  - 2026-05-26 [KADC 2026 | openFuyao 分论坛](https://blog.csdn.net/openFuyao/article/details/161432507)(披露 Aether / V3 Cache / 京东案例 / 移动云超节点 / 联通 CSK Turbo)
  - 2026-05-26 [KADC 2026 | openFuyao 鲲鹏昇腾大会展台](https://blog.csdn.net/openFuyao/article/details/161431636)(沈一帆 K8s-on-K8s 演讲、罗刚毅 Kata+NPU 8 卡直通)

</details>
