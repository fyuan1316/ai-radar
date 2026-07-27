# OpenFuyao 周报 2026-07-27

窗口:2026-07-13 -> 2026-07-27(14 天,补上无 07-20 digest 的空档)

## 摘要(3 条以内)
- 非发版周(v26.06 仍是最新版,官网无新 release note),但代码侧持续补 v26.06 能力:hermes-router 公开了 [prediction sidecar 的完整训练/发布流程](https://gitcode.com/openFuyao/hermes-router),把"请求级时延预测路由"从黑盒变成 `prediction-train` 造 bundle + `prediction-sidecar` 提供 gRPC 预测的可复现 ML 流水线——这是本周最有借鉴价值的通用能力。
- InferNex 补推理栈可观测性与接入面:新增 [PodMonitor 采集 vLLM engine 指标](https://gitcode.com/openFuyao/InferNex)(区分 prefill/decode/aggregated 三种 PD 角色),并加 EnvoyFilter 让网关兼容 HTTP/1.0 客户端。
- 昇腾侧([ascend/mind-cluster](https://gitcode.com/ascend/mind-cluster))集中在大规模集群故障域治理:Volcano 移除驱逐成本打分(>100 节点时干扰亚健康排序)、交换机/nodeD 故障信息进 fault-job 日志、clusterD 新增 4 个隔离 NPU 故障码,均是昇腾专用的运维健壮性收敛。

## 新功能 / 能力

- [hermes-router prediction sidecar 训练指南](https://gitcode.com/openFuyao/hermes-router) — 文档化了预测式路由的数据闭环:Router 的 `RequestLifecycleTracker` 在请求完成时把记录写 inflight store,按 `flushThreshold/flushInterval` 追加到 completed-request JSONL;`prediction-train` 读 JSONL→转样本→按 `target_model` 过滤→按 slot 切训练/验证集→逐 slot 训模型→先写 staging 再原子 rename 成 bundle;`prediction-sidecar` 加载 bundle 对外提供 gRPC 预测。
  - 启示:这是本周唯一可直接借鉴到通用 LLM gateway 的能力。它把"路由决策"做成了在线采样→离线训练→热加载 artifact 的标准 MLOps 闭环,而不是写死启发式。我们的推理路由若要引入时延/负载预测,应照这个分层:请求生命周期采集(持久化到 JSONL)、离线训练产物版本化(manifest/metadata/report + 原子发布)、sidecar 只读加载。注意其默认 `persistence.enabled=false` 且 JSONL 写在 EPP 容器内——训练数据落盘和导出是需要单独设计的一环。
- [InferNex PodMonitor for vLLM engine metrics](https://gitcode.com/openFuyao/InferNex) — 新增 `engine-podmonitor.yaml`,当集群装了 `monitoring.coreos.com/v1` 时自动下发 PodMonitor;PD 分离模式按 `openfuyao.com/pdRole` 分别抓 prefill/decode 的 `:8000/metrics`(15s 间隔),非 PD 模式抓 aggregated。
  - 对比:与 KServe/vLLM 上游用 ServiceMonitor/PodMonitor 抓 vLLM 原生 `/metrics` 是同一条路,通用能力,没有昇腾锁定。差异只在它用 `openfuyao.com/*` label 选择器和 pdRole 维度切分。我们做 PD 分离推理时也要让指标按 prefill/decode 角色可分,否则 TTFT/TPOT 归因和分角色扩缩容都做不了。
- [InferNex 网关 HTTP/1.0 兼容开关](https://gitcode.com/openFuyao/InferNex) — 通过 `enable_http10` values 开关下发一个 `accept-http-10` EnvoyFilter,让 inference-gateway 接受 HTTP/1.0 客户端。
  - 对比:纯工程兼容项(默认关闭),说明 InferNex 网关就是 Envoy/Istio 数据面。对我们无架构启示,仅提示:企业存量客户端里仍有 HTTP/1.0,网关层要留 escape hatch。
- [npu-operator operator nodeSelector 可配](https://gitcode.com/openFuyao/npu-operator) — 移除 operator.yaml 里写死的 nodeSelector 约束,改为可配置。
  - 启示:小修,但方向对——operator 自身的落点不该被硬编码到某类节点。我们的 NPU/GPU operator chart 也应把控制面 Pod 的 nodeSelector/affinity 暴露为 values。

## AI 推理栈(InferNex / hermes-router / ...)

- hermes-router 本周实质变更只有上面的 prediction 训练文档(!71),无路由算法代码合入;但文档把 `prediction-train`/`prediction-sidecar` 两个入口命令、bundle 目录结构(`manifest.json`/`metadata.json`/`report.json`/`slots/*`)、`requestTracking.persistence` 配置项都写清了。
  - 对比:相比 KServe GIE(Gateway Inference Extension)当前以 EPP 内启发式 + 队列深度为主,hermes-router 已经在把"路由用的预测模型"当成独立可训练、可版本化的 artifact。这是它相对上游路由层走得更前的一点,值得跟踪其预测特征(用了哪些请求特征、slot 怎么定义)。
- InferNex 侧本轮无路由/KVCache/弹性算法级变更,只有可观测性(PodMonitor)和网关兼容(HTTP/1.0)。v26.06 已交付的 Mooncake/KVCache-aware/prediction router、elastic-scaler、weight-dispatcher 本周无新提交,处于发版后收尾期。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- [clusterD 新增隔离 NPU 故障码](https://gitcode.com/ascend/mind-cluster)(#826) — 按 MindCluster 公共错误码定义原则新增 4 个错误码,用于 CPU/NPU 故障触发的 NPU 隔离,并在 clusterD 重调度名单配置里加入这些故障码。
  - 对比:这是昇腾专用的故障→隔离→重调度联动,和 K8s 通用 node problem detector + taint 的思路一致,但错误码语义绑死昇腾硬件。我们做通用异构故障治理时,应把"故障码目录"抽象成 vendor 可插拔字典,上层重调度策略只认"是否需隔离/是否可续训"这类归一化信号。
- [device-plugin 带内热复位默认超时 480s→180s](https://gitcode.com/ascend/mind-cluster) — 带内热复位(in-band hot reset)默认超时检测时间收紧到 180s。
  - 启示:昇腾专用运维参数,但提示一个通用点:加速器在线复位/热重置的超时是故障恢复 SLO 的一部分,默认值会直接影响 pod 卡死时长。我们若接入类似"设备热复位"能力,超时要可配且默认值需和上层重调度等待窗口对齐。
- [npu-exporter 重构 telegraf 指标上报模块](https://gitcode.com/ascend/mind-cluster) — 从"各采集器往 map 里塞数据、Gather 时按类型拆分"改为"采集器把统一 `TelegrafMetric` 写 channel、消费协程统一聚合上报"的生产者/消费者模式(对齐 prometheus 侧 `chan<- prometheus.Metric` 设计);另有一处把 UB 指标的 `dieId`/`portId` 从指标名的一部分改为 label。
  - 启示:纯工程质量改进,但 dieId/portId 改成 label 是对的——把维度塞进指标名会导致时间序列基数爆炸且无法聚合。我们的 NPU exporter 设计要保证硬件拓扑维度(die/port/链路)一律走 label 而非拼进 metric name。
- npu-dra-plugin、ub-network-device-plugin 本周窗口内无新提交(仍停在 v26.6.0 tag),DRA 软件 vNPU 路线本周无进展。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

- [Volcano 移除驱逐成本打分逻辑](https://gitcode.com/ascend/mind-cluster) — 现象:节点数 >100 时,驱逐成本打分会干扰亚健康(subhealth)打分对节点的排序,导致本应高分的节点反被排后;方案:直接移除驱逐成本打分。
  - 对比:这印证了大规模集群里"多打分插件叠加会互相污染排序"的通用坑。上游 Volcano/kube-scheduler 也有 score plugin 权重调参问题。我们做调度打分时要保证各插件量纲可比、可单独观测,并在 100+ 节点规模下验证插件叠加后的实际排序,而不是只看单插件正确性。
- [Volcano 交换机与 nodeD 故障信息进 fault-job 日志](https://gitcode.com/ascend/mind-cluster) — 在 Volcano 记录 fault job 的日志里,新增展示交换机故障与 nodeD 上报的故障信息。
  - 启示:大规模昇腾训练把"网络交换机故障"纳入作业故障归因,不只看节点/NPU。我们的分布式训练故障诊断也应把网络域(交换机/链路)故障关联到具体 job,否则大集群里定位"作业为何被驱逐/重调度"会缺一层。
- [Volcano action 增强](https://gitcode.com/ascend/mind-cluster) — 解决资源判断导致 filtered 列表为空的问题,抢占回收失败返回正确状态值,并适配 chip4node8 亲和性调度策略;另修"集群中存在不符合调度策略的任务导致其他任务调度异常"。
  - 对比:都是超大规模昇腾调度的稳定性补丁,昇腾拓扑(chip4node8)专用。通用启示:抢占/回收失败时的状态返回值要准确,否则会连锁影响其他 job 的调度决策。

## 官方动态

- 官网与 CSDN 本周**无新版本发布、无路线图公告**;v26.06(2026-07-09)仍是最新版,已在上期周报覆盖。本周官方内容为生态/市场类:
  - [openFuyao 亮相 LEAP East 2026](https://blog.csdn.net/openFuyao)(07-23)— 展示 InferNex 推理加速套件的分布式 KV cache 调度。
  - openFuyao 助力鲲鹏超节点搜推案例入选《超节点定义与实践白皮书》(07-23)— 容器化高速通信能力对接鲲鹏超节点。
  - 统信云基础设施管理平台 V3.0 发布(07-23)— 声称基于 openFuyao 的容器编排与异构算力调度能力。
  - 剥离营销话术后的技术事实:第三方(统信)开始把 openFuyao 作为底座集成,超节点方向进入行业白皮书。无新技术能力发布。

## 跟我们产品的对比

- 已有或应已有:vLLM 指标 PodMonitor/ServiceMonitor、Envoy 网关、operator nodeSelector 可配、exporter 维度用 label、故障→重调度联动、大规模调度打分——这些都不是 OpenFuyao 独有,方向一致。
- OpenFuyao 本周独有/更前:hermes-router 把路由预测做成可训练/版本化 artifact(prediction-train + bundle 原子发布);昇腾专用的交换机故障归因、chip4node8 拓扑亲和、隔离 NPU 故障码目录、带内热复位超时。
- 我们该补:(1) 若推理路由要上时延/负载预测,照 hermes 的采集→离线训练→sidecar 热加载分层,别写死启发式;(2) PD 分离推理的指标必须按 prefill/decode 角色可分;(3) 调度打分在 100+ 节点规模下验证插件叠加排序;(4) 分布式训练故障诊断把网络交换机故障关联到 job;(5) exporter 硬件拓扑维度一律走 label。

## 值得跟进
- [ ] 读 `openFuyao/hermes-router` `sidecar/prediction/README.md` 全文,搞清预测模型用哪些请求特征、slot 如何定义、bundle 里 `report.json` 的评估口径,评估能否抽象成通用推理路由的预测层。
- [ ] 对比 hermes-router prediction 路由与 KServe GIE / Envoy AI Gateway 的路由决策输入,判断"可训练预测路由"是否值得我们纳入 gateway roadmap。
- [ ] 在我们的 vLLM PD 分离部署上验证 prefill/decode 分角色指标采集与归因(对标 InferNex PodMonitor 的 pdRole 维度)。
- [ ] 复盘我们调度打分插件在 100+ 节点规模下的叠加排序,确认不存在类似"驱逐成本打分污染亚健康排序"的量纲干扰。

## 原始材料

<details>
<summary>本次扫描清单</summary>

官方源(过去 14 天):
- https://www.openfuyao.cn/zh/ (无新 release/blog,仅 07-21 直播预告)
- https://blog.csdn.net/openFuyao (07-23 三条生态/市场文:LEAP East、超节点白皮书、统信 V3.0;无新技术发布)

GitCode 浅克隆日志(--depth 100,--since=2026-07-13):
- `openFuyao/InferNex`:
  - 2026-07-21 !201 feat: add PodMonitor for vLLM engine metrics collection(prefill/decode/aggregated)
  - 2026-07-21 !205 feat(inference-gateway): add enable_http10 toggle for HTTP/1.0 clients(EnvoyFilter)
- `openFuyao/hermes-router`:
  - 2026-07-22 !71 docs(prediction): document training data persistence(prediction-train / bundle / requestTracking.persistence)
- `openFuyao/npu-operator`:
  - 2026-07-14 !105 fix: make operator nodeSelector configurable
- `openFuyao/npu-dra-plugin`、`openFuyao/volcano-ext`、`openFuyao/ub-network-device-plugin`、`openFuyao/kae-operator`:窗口内无新提交(tag 仍为 v26.6.0 / v1.10.0)
- `ascend/mind-cluster`(实质提交,已滤 merge/docs/dockerfile):
  - 2026-07-23 【fix】【volcano】移除驱逐成本打分逻辑(>100 节点干扰亚健康排序)
  - 2026-07-23 【volcano】添加交换机与 nodeD 上报故障信息展示(fault-job 日志)
  - 2026-07-23 修复 inferoperator 不兼容低版本 k8s 问题
  - 2026-07-21 [fix][volcano] action 增强:filtered 列表为空修复、抢占回收失败状态值、chip4node8 亲和性
  - 2026-07-22 [device-plugin] 带内热复位默认超时 480s→180s
  - 2026-07-22 <fix>[volcano] 修复不符合调度策略的任务导致其他任务调度异常
  - 2026-07-21 修复 kubelet 场景 panic 问题
  - 2026-07-20 新增 clusterD 隔离 NPU 故障码(#826,4 个错误码)
  - 2026-07-16 [npu-exporter] 重构 telegraf 指标上报模块(生产者/消费者 channel 模式)
  - 2026-07-16/17 UB 指标 dieId/portId 改为 label(而非指标名一部分)
  - 2026-07-16 修复 role workload 主备场景优先级调度导致非 ready 影响其他 role 调度

</details>
