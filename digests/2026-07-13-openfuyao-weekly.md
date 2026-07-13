# OpenFuyao 周报 2026-07-13

窗口:2026-07-06 -> 2026-07-13(7 天)

## 摘要(3 条以内)
- [openFuyao v26.06](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) 于 2026-07-06 发布，主线集中在 InferNex 推理性能、NPU DRA、KubeVirt 虚机容器共管、声明式组件升级和自动化合规扫描。
- AI 推理侧从单纯部署 vLLM-Ascend 走向完整 serving stack:InferNex 迁到 LWS 模式，多 DP 架构，Mooncake + KVCache-aware/prediction router，infernex-bridge 对接 KServe，elastic-scaler/eagle-eye/weight-dispatcher 补齐扩缩容、网络指标和权重分发。
- 昇腾资源管理侧 NPU DRA 支持 910B/910C/310P、DeviceClass/CEL、ResourceClaim/ResourceSlice、CDI 和 910B 固定模板 vNPU；GitCode 日志显示 `npu-dra-plugin` 本周继续补软件 NPU 虚拟化。

## 新功能 / 能力

- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — 官方宣称 InferNex 在多轮对话与定长系统提示词场景中，首 token 时延平均降低 55%，总吞吐平均提升 32%。
  - 启示:OpenFuyao 的推理优化不是只调 vLLM 参数，而是把 KVCache 路由、Mooncake、LWS、多 DP、权重分发和网络指标串成系统能力。我们对标时也要按“router/cache/scaler/network/weight distribution”整栈评估。
- [InferNex GitCode](https://gitcode.com/openFuyao/InferNex) — 本周 GitCode 日志显示 2026-07-06 更新 InferNex specification sheet，2026-07-09 修复 bridge restricted PSA 下的 capabilities/drop 和 supplementalGroups。
  - 启示:InferNex 已经在补企业集群的 Pod Security Admission 兼容。我们推理 chart 也要在 restricted/baseline PSA 下跑安装验证，不能只在 privileged 开发集群通过。
- [npu-dra-plugin GitCode](https://gitcode.com/openFuyao/npu-dra-plugin) — 本周日志显示 2026-07-08 合入 “Support software NPU virtualization in DRA Plugin”，并已有 tag `v26.6.0`。
  - 启示:OpenFuyao 把软件 vNPU 放进 DRA plugin 路线。我们评估 NPU DRA 时要区分硬切分、软件虚拟化、CDI 注入和 scheduler 可见资源。

## AI 推理栈(InferNex / hermes-router / ...)

- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — InferNex 部署方式从 Deployment 变为 LeaderWorkerSet(LWS)，新增多 DP 架构部署，支持一键部署 minimax 2.7、deepseek v4、GLM5.2 等 MoE 模型。
  - 对比:这与 OAI/KServe/LLM-D 的方向一致，都是把多角色、多副本、多节点推理拓扑交给 K8s 原生 controller 表达；不同点是 OpenFuyao 绑定昇腾/vLLM-Ascend 场景更深。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — Mooncake + KVCache aware router TTFT 收益 59.1%、TPS 收益 40.5%；Mooncake + prediction router TTFT 收益 59.6%、TPS 收益 31.7%。
  - 对比:KServe/Envoy AI Gateway 更偏通用 API gateway，OpenFuyao 的 hermes-router 更偏请求级推理路由和 KVCache locality。我们应把二者拆成两层:入口网关负责安全/协议/租户，推理路由负责 cache locality 和 backend saturation。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — `infernex-bridge` 新增 KServe 对接插件，可通过 KServe 在 NPU 环境拉起 InferNex 推理服务。
  - 对比:这说明 OpenFuyao 没有完全另起模型服务 API，而是在 KServe 之上接入自己的 NPU 推理栈。我们如果要支持昇腾，也可以优先做 KServe adapter，而不是复制一套服务 CRD。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — `hermes-router` 新增基于推理时延预测与后端算力饱和度的路由策略，K8s GIE 升级到 1.5.0，并新增 tokenizer 模块。
  - 启示:路由器开始承担 tokenizer 和请求级全局调度。我们的 LLM gateway 需要明确 tokenizer 放在哪一层，否则 token 估算、限流、成本和 cache locality 都会分裂。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — `cache-indexer` 用 Go 重构，维护推理实例本地 HBM KVCache 索引，并支持 Mooncake 内存级 KVCache index。
  - 启示:KV cache 索引已经是独立系统组件，不是 engine 内部细节。我们应评估是否需要跨实例 cache indexer，以支撑路由、迁移和故障恢复。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — `elastic-scaler` 完善 CRD、MetricsManager、Context Builder，支持基于 LWS 的大参数 LLM 弹性扩缩，并提供 APA 默认算法。
  - 启示:推理扩缩容必须理解 LWS 角色和模型行为，不能只拿 HPA 盯 CPU/GPU 利用率。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — `weight-dispatcher` 新增权重分发组件，多节点并发拉取权重场景模型端到端传输时间缩短 20%。
  - 启示:大模型冷启动瓶颈正在从镜像拉取转向权重分发。我们的模型缓存/预热设计需要覆盖权重广播、节点本地缓存和并发加载。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — npu-dra-plugin 支持昇腾 910B、910C、310P 资源发现和上报，支持 DeviceClass/CEL、ResourceClaim/ResourceClaimTemplate、ResourceSlice 绑定和 CDI 注入。
  - 对比:这与 Kubernetes DRA 标准路线一致，区别在于 OpenFuyao 把昇腾硬切分/vNPU 语义内置到 DRA plugin。我们做通用 DRA 时，要把厂商特定切分能力留在 device plugin/driver 层，上层只暴露标准 claim。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — 支持 910B 固定模板 vNPU，可按申请内存大小自动匹配模板。
  - 启示:这对昇腾 NPU 有直接价值，但通用产品不应把“内存大小自动匹配模板”写死为所有加速器模型。应抽象为 vendor profile / partition template。
- [npu-dra-plugin GitCode](https://gitcode.com/openFuyao/npu-dra-plugin) — 本周合入软件 NPU 虚拟化支持。
  - 启示:硬切分和软件虚拟化会共存，调度层需要知道隔离强度、性能保证和可抢占性差异。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — 资源调度层面提到基于 KubeVirt 实现鲲鹏虚拟机与容器共管，并整合众核调度编排。
  - 对比:这条线更偏昇腾/鲲鹏/企业混部栈，不是 KServe/OAI 的主线。我们可以借鉴 VM/Pod 共管和网络热插拔经验，但不要把它与通用 AI serving 控制面混为一谈。
- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — `eagle-eye` 新增权重分发及超节点网络动态指标采集，覆盖 RDMA/RoCE 链路状态、速率、剩余带宽、丢包率等 30+ 指标，通过 Prometheus 周期采集和 NATS 近实时推送。
  - 启示:大模型推理/训练调度需要网络指标进入容量决策。我们的 GPU/NPU 调度和故障诊断应把 RDMA/RoCE 指标纳入节点画像。

## 官方动态

- [openFuyao v26.06 release note](https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/) — v26.06 正式发布，官方定位为多层面协同进化，覆盖 AI 推理、资源调度、多样化算力接入、声明式组件升级、自动化合规扫描。
  - 启示:OpenFuyao 的版本叙事是“昇腾异构集群软件栈”，不是单个 operator。我们对标时应按发行版能力包比较:推理服务、NPU 资源、调度、网络、升级、合规。

## 跟我们产品的对比

- 已有或应已有:KServe 对接、LWS/JobSet/Kueue 方向、模型缓存/预热、GPU/NPU operator、Prometheus 指标、离线交付。
- OpenFuyao 独有或更强:昇腾 NPU DRA + vNPU 模板、vLLM-Ascend/InferNex 整栈、Mooncake/KVCache-aware 路由、权重分发、RDMA/RoCE 超节点指标、鲲鹏 VM/Pod 共管。
- 我们该补:把 LLM serving 拆成 gateway、router、cache-indexer、weight-dispatcher、scaler、network metrics 几个产品化组件；DRA 层按标准 API 暴露，厂商切分能力放 profile；推理部署必须在 restricted PSA、离线和 TLS 策略下验证。

## 值得跟进
- [ ] 拉取 `openFuyao/npu-dra-plugin` v26.6.0，阅读软件 NPU 虚拟化实现和 DeviceClass/ResourceClaim 示例。
- [ ] 对比 InferNex LWS 多 DP 部署与 KServe LLMInferenceService / LLM-D 拓扑，找出 API 可复用点。
- [ ] 评估 hermes-router、cache-indexer、weight-dispatcher 是否能抽象成通用推理平台能力。
- [ ] 将 restricted PSA、supplementalGroups、capabilities.drop ALL 纳入我们推理 chart 的安全基线测试。

## 原始材料

<details>
<summary>本次扫描清单</summary>

- https://www.openfuyao.cn/zh/blogs/blogsList/openFuyao-26-06-released/
- https://gitcode.com/openFuyao/InferNex
- https://gitcode.com/openFuyao/npu-dra-plugin
- GitCode `openFuyao/InferNex` 本轮浅克隆日志:
  - 2026-07-09 `fix(bridge): preserve capabilities.drop ALL and add supplementalGroups for restricted PSA`
  - 2026-07-06 `feat: update readme with infernex specification sheet`
- GitCode `openFuyao/npu-dra-plugin` 本轮浅克隆日志:
  - 2026-07-08 `Support software NPU virtualization in DRA Plugin`
  - tag `v26.6.0`
</details>
