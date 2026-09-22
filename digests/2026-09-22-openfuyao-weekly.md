# OpenFuyao 周报 2026-09-22

窗口:2026-09-15 -> 2026-09-22(7 天)

## 摘要(3 条以内)
- 本周 OpenFuyao 的实质变化集中在 InferNex / hermes-router:继续推进 D/PD route orchestration、Decode-first 调度、PD 权重配置收敛和 Mooncake resource namespace singleton。
- 昇腾资源管理仓本周较冷清，`npu-dra-plugin`、`npu-operator`、`npu-driver-installer`、`npu-container-toolkit` 未在 9 月 15 日后看到新提交；vNPU 只有格式/代码检查修复。
- 对标 OAI/KServe/LLM-D，本周最值得看的是 OpenFuyao 把 prefill/decode 分离路由和 KV cache 发现继续做成独立 router/cache-indexer 能力，而不是只依赖 vLLM-Ascend runtime。

## 新功能 / 能力

- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 2026-09-17 合入 `feat(proxy-server): support Decode-first D/PD route orchestration（RFC PR3）`。
  - 启示:OpenFuyao 正在把 Decode-first 的 D/PD 编排放到 proxy-server，而不是只在引擎内部调参。我们做 LLM serving 时，prefill/decode 分离应有路由层 API 和运行时状态，而不是隐藏在部署模板里。
- [hermes-router GitCode](https://gitcode.com/openFuyao/hermes-router) — 2026-09-17 合入 `feat(scheduling): Decode-first 核心调度能力（RFC PR1）` 与 `feat(routing): add D/PD routing adaptation and configuration integration(RFC PR2)`。
  - 启示:hermes-router 正在从 KVCache-aware router 扩到 PD orchestration router。它与 KServe/LLM-D 路线的共性是“推理路由独立于 runtime”，差异是更深绑定昇腾/vLLM-Ascend/Mooncake。
- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 2026-09-18 合入 `fix: make Mooncake resources namespace singletons`。
  - 启示:Mooncake 资源从部署实例级走向 namespace singleton，说明 KV cache/内存池类组件需要租户边界内共享治理。我们的 cache-indexer / KV pool 设计也应先明确 namespace/project 级 ownership。

## AI 推理栈(InferNex / hermes-router / ...)

- [hermes-router GitCode](https://gitcode.com/openFuyao/hermes-router) — 2026-09-15 `refactor(score): 将 PD 权重内嵌到插件 Config 并收敛 PDGroup 签名`。
  - 对比:OAI/KServe 当前更关注 llm-d observability 和 Kueue/serving 集成，OpenFuyao 则把 PD 权重和调度插件配置做得更细。我们可借鉴插件化 score config，但需要保持通用硬件无关，不要把昇腾拓扑语义泄漏到上层 API。
- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 2026-09-15 `chore(bridge): bump example vllm-ascend image to v0.23.0`。
  - 启示:OpenFuyao 的 serving stack 紧贴 vLLM-Ascend 版本。我们若支持昇腾，应把 vLLM-Ascend runtime image 与 InferNex/KServe bridge/driver/CANN 版本做成矩阵。
- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 2026-09-09 已有 `feat(cache-indexer): support decode KV cache discovery`，虽略早于窗口，但本周 D/PD 路由变更明显接续这条线。
  - 启示:Decode KV cache discovery + Decode-first route orchestration 表明 OpenFuyao 的路由决策依赖 cache 可见性。我们评估 LLM gateway 时，应把 cache discovery 作为独立能力，不应只做 HTTP/gRPC 转发。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [npu-dra-plugin GitCode](https://gitcode.com/openFuyao/npu-dra-plugin)、[npu-operator GitCode](https://gitcode.com/openFuyao/npu-operator)、[npu-driver-installer GitCode](https://gitcode.com/openFuyao/npu-driver-installer)、[npu-container-toolkit GitCode](https://gitcode.com/openFuyao/npu-container-toolkit) — 本轮浅克隆未看到 2026-09-15 后的实质新提交；多个仓库仍停留在 v26.6.0 tag。
  - 启示:OpenFuyao 的 NPU DRA/driver/operator 本周没有新产品信号。短期对标重点应从资源层切回推理路由层。
- [vNPU GitCode](https://gitcode.com/openFuyao/vNPU) — 2026-09-15 只有 gofmt / codecheck 修复。
  - 启示:无新增能力，暂不作为本周产品决策依据。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [volcano-ext GitCode](https://gitcode.com/openFuyao/volcano-ext) 与 [ub-network-device-plugin GitCode](https://gitcode.com/openFuyao/ub-network-device-plugin) — 本轮浅克隆未看到 2026-09-15 后实质提交。
  - 启示:本周没有新的 Volcano NPU 拓扑或 UB 网络信号；网络/调度能力仍以 v26.06 发布内容为基线。

## 官方动态

- 本轮未找到 2026-09-15 -> 2026-09-22 的 OpenFuyao 官网新 release 公告。GitCode 代码侧已有 InferNex/hermes-router 增量，因此本周归档并推送，但不解读为版本发布。

## 跟我们产品的对比

- 同一路线:OpenFuyao、OAI/KServe/LLM-D 都在把多角色推理拓扑、路由、观测从 runtime 内部抽出来，向 K8s controller + 独立 router 靠拢。
- 分叉路线:OpenFuyao 的 D/PD、Mooncake、vLLM-Ascend、NPU 资源语义更偏昇腾专用；OAI/KServe 更偏跨硬件和 OpenShift 企业集成。
- 我们该补:把 LLM serving API 分层为入口网关、安全/租户、推理路由、cache discovery、PD role orchestration、runtime image catalog。昇腾专用优化放 profile/adapter，不写死在通用模型服务 CRD。

## 值得跟进
- [ ] 深读 hermes-router Decode-first RFC PR1/PR2 的代码，确认 D/PD routing adaptation 的配置模型和 score 插件扩展点。
- [ ] 深读 InferNex proxy-server D/PD route orchestration，评估是否可映射到 KServe LLMInferenceService 或 LWS。
- [ ] 跟踪 Mooncake resource namespace singleton 的 owner/reference 设计，判断 KV pool/cache-indexer 是否应按 namespace 共享。
- [ ] 下轮继续观察 npu-dra-plugin 是否恢复增量，特别是软件 vNPU 与 DRA ResourceClaim/CDI 的结合。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://gitcode.com/openFuyao/InferNex
  - 2026-09-18 `build: optimize build performance with cache-mount`
  - 2026-09-18 `fix: make Mooncake resources namespace singletons`
  - 2026-09-17 `feat(proxy-server): support Decode-first D/PD route orchestration（RFC PR3）`
  - 2026-09-15 `chore(bridge): bump example vllm-ascend image to v0.23.0`
- https://gitcode.com/openFuyao/hermes-router
  - 2026-09-17 `feat(routing): add D/PD routing adaptation and configuration integration(RFC PR2)`
  - 2026-09-17 `feat(scheduling): Decode-first 核心调度能力（RFC PR1）`
  - 2026-09-15 `refactor(score): 将 PD 权重内嵌到插件 Config 并收敛 PDGroup 签名`
- https://gitcode.com/openFuyao/vNPU
  - 2026-09-15 `fix: gofmt test files to resolve G.FMT.01`
  - 2026-09-15 `fix: resolve codecheck issues`
- https://gitcode.com/openFuyao/npu-dra-plugin
- https://gitcode.com/openFuyao/npu-operator
- https://gitcode.com/openFuyao/npu-driver-installer
- https://gitcode.com/openFuyao/npu-container-toolkit
- https://gitcode.com/openFuyao/volcano-ext
- https://gitcode.com/openFuyao/ub-network-device-plugin
</details>
