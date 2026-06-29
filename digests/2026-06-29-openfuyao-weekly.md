# OpenFuyao 周报 2026-06-29

窗口:2026-06-22 -> 2026-06-29(7 天)

## 摘要(3 条以内)
- OpenFuyao 本周有实质代码/文档信号:GitCode `InferNex`、`hermes-router`、`cache-indexer`、`npu-dra-plugin`、`sig-ai-inference` 近 7 天都有提交，重点围绕 InferNex Bridge、Helm/制品规范、Hermes routing sidecar、weight-dispatcher v26.06 性能报告。
- `InferNex` README 已把 26-06 更新写入主线:后端切换为 LWS 部署编排、PD-Orchestrator elastic-scaler 新增 APA、Hermes-router 新增算力饱和度与时延预测路由、cache-indexer 实现 L3 KV-aware、eagle-eye 增加权重分发与网络动态指标、checker 增加前置校验。
- `sig-ai-inference` 新增 [weight-dispatcher v26.06 性能报告](https://gitcode.com/openFuyao/sig-ai-inference/blob/main/reports/performance/weight-dispatcher%E6%80%A7%E8%83%BD%E6%B5%8B%E8%AF%95%E6%8A%A5%E5%91%8A-v26.06.md)，把模型权重预热/分发作为推理弹性和冷启动加速的一等能力。

## 新功能 / 能力

- [InferNex README](https://gitcode.com/openFuyao/InferNex) — 26-06 更新包括 LWS 编排、多 DP 协同、APA 扩缩算法、算力饱和度/时延预测路由、L3 KV-aware cache-indexer、权重分发与灵衢网络动态指标、部署前置校验。
  - 启示:OpenFuyao 的推理栈正在从“路由 + KV cache”扩展到“编排、弹性、缓存、观测、前置校验”的完整控制面。和 OAI/KServe 相比，它更强调底层硬件/网络/缓存协同。
- [InferNex Bridge README](https://gitcode.com/openFuyao/InferNex/blob/main/component/InferNex-Bridge/README.md) — 明确支持 KServe `LLMInferenceService` 0.17.0-0.19.0 与原生 `InferNexService` 双 CRD，自动部署 InferNex 推理套件和 Hermes Router、Mooncake、cache-indexer、Elastic-Scaler、Eagle-Eye 等增强组件。
  - 启示:OpenFuyao 正在主动接入 KServe LLMISVC，而不是另起一套完全割裂的 Serving API。我们对标时应把它视为“KServe API + Ascend/InferNex 增强栈”的路线。
- [Weight-Dispatcher 用户文档](https://gitcode.com/openFuyao/sig-ai-inference/blob/main/docs/zh/ai_inference_weight_dispatcher/ai_inference_weight_dispatcher.md) — 通过 `ModelWarmupJob` CRD 做模型权重预热，支持 node 源、多源条带化、多节点分发、CRC32C 分块校验、RDMA 与 TCP fallback、缓存发布状态机。
  - 启示:模型权重分发正在被产品化成独立 CRD，而不是 initContainer 下载脚本。我们的模型冷启动优化也应抽象出“模型预热任务”，支持目标节点选择、分块校验、缓存命中和状态回写。

## AI 推理栈(InferNex / hermes-router / ...)

- [Hermes-router README](https://gitcode.com/openFuyao/hermes-router) — 2026-06 新增 `aggregate-prediction`、`pd-prediction`，基于算力饱和度和时延预测评分；支持 GIE v1.5.0 插件体系、standalone 和 gateway 集成模式。
  - 启示:Hermes-router 与 KServe/llm-d、Ray Serve 的新 PR 都在收敛到“KV 命中 + token/request load + 实例资源饱和度 + 时延预测”。我们应把路由能力做成策略矩阵，明确每个策略需要的数据源。
- [sig-ai-inference 文档提交](https://gitcode.com/openFuyao/sig-ai-inference) 本周同步 Hermes routing sidecar guide 和 InferNex Bridge user manual。
  - 启示:OpenFuyao 正在把 sidecar/gateway 接入方式文档化，降低已有推理后端接入门槛。我们的推理路由组件也应同时支持“全栈托管”和“只接入路由层”两种路径。
- [cache-indexer GitCode 仓库](https://gitcode.com/openFuyao/cache-indexer) 本周提交对齐 Helm chart artifact spec。
  - 启示:cache-indexer 已从实验代码向可发布制品推进。它提供的“全局 KV Cache 索引服务”是值得单独对标的抽象，不应只把 KV cache 视为 engine 内部状态。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [npu-dra-plugin GitCode 仓库](https://gitcode.com/openFuyao/npu-dra-plugin) 本周有 codecheck 修复提交，但未看到新功能级说明。
  - 启示:OpenFuyao 仍在保持 NPU DRA 接入线。结合 Kubernetes DRA KEP 本周更新，我们应跟踪其 ResourceClaim/DeviceClass 设计是否能复用到自家 NPU/GPU 共享方案。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [InferNex README](https://gitcode.com/openFuyao/InferNex) 将后端切换到 LWS 部署编排，并声明原生支持多 DP 协同。
  - 启示:OpenFuyao 在多实例/多 DP 推理上选择贴近 K8s LWS，而 OAI/KServe 也在使用 LWS。LWS 可能成为多副本 LLM 推理的共同底座，值得我们优先验证。
- [weight-dispatcher v26.06 性能报告](https://gitcode.com/openFuyao/sig-ai-inference/blob/main/reports/performance/weight-dispatcher%E6%80%A7%E8%83%BD%E6%B5%8B%E8%AF%95%E6%8A%A5%E5%91%8A-v26.06.md) — 在 3 计算节点场景下，weight-dispatcher(TCP) 相比 rsync E2E 降低 58.41%-65.94%，相比 rclone 降低 72.45%-76.13%，相比 netcat 降低 49.15%-52.72%。
  - 启示:模型分发速度会直接决定弹性扩容和冷启动体验。我们的推理弹性方案不能只扩 Pod，还要考虑权重在节点间的预热/复制路径。

## 官方动态

- 本周未确认到 OpenFuyao 官网正式 release 公告；代码和文档已出现 26.06 相关能力描述与性能报告。
  - 启示:这是“发版前能力沉淀/文档同步”信号，后续应继续等官方 v26.06 release note，再把能力纳入稳定对标。

## 跟我们产品的对比

- 已有/可对齐:KServe LLMISVC、LWS、Gateway API、Kueue、模型缓存、推理观测这些底座方向与 OAI/KServe 路线一致。
- OpenFuyao 独有或更强:Ascend/NPU 专用部署前置校验、灵衢/网络动态指标、weight-dispatcher、Hermes prediction routing、KV cache 全局索引与 Mooncake 联动更贴硬件。
- 我们该补:模型预热/分发应从 initContainer 下载升级为平台任务；KV cache 应从 engine 参数升级为可观测、可路由、可回收的集群资源；路由策略要纳入资源饱和度和预测延迟。

## 值得跟进
- [ ] 跟踪 OpenFuyao v26.06 正式 release note，确认 README 中 26-06 能力哪些已发布。
- [ ] 读 InferNex Bridge 技术规格，评估 KServe LLMISVC 双 CRD 适配方式对我们集成 KServe 的启发。
- [ ] 对比 Weight-Dispatcher `ModelWarmupJob` 与我们现有模型下载/缓存方案，设计模型预热 CRD 或平台任务。
- [ ] 跟踪 Hermes-router `prediction` 策略的数据源和评分公式，和 KServe llm-d / Ray Serve routing 做横向比较。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://gitcode.com/openFuyao/InferNex
- https://gitcode.com/openFuyao/InferNex/blob/main/component/InferNex-Bridge/README.md
- https://gitcode.com/openFuyao/hermes-router
- https://gitcode.com/openFuyao/cache-indexer
- https://gitcode.com/openFuyao/npu-dra-plugin
- https://gitcode.com/openFuyao/sig-ai-inference
- https://gitcode.com/openFuyao/sig-ai-inference/blob/main/docs/zh/ai_inference_weight_dispatcher/ai_inference_weight_dispatcher.md
- https://gitcode.com/openFuyao/sig-ai-inference/blob/main/reports/performance/weight-dispatcher%E6%80%A7%E8%83%BD%E6%B5%8B%E8%AF%95%E6%8A%A5%E5%91%8A-v26.06.md
- 本次对 GitCode 仓库执行了 `git clone --depth 50` 并读取近 7 天 `git log`；未使用 `gh` CLI。
</details>
