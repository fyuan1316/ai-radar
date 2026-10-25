# 昇腾算力栈 diff 雷达 2026-10-26

## 摘要
- 本期**无任何生产代码改动**。唯一有新提交的仓是 `Ascend/mind-cluster`(c144488f → a1ba9a44,2 次提交:1 merge + 1 文档),改动全是调度用户指南文档:新增 1 篇《故障退避容忍的降级调度》(+104 行)、改 yaml 配置参考(+30 行)、两处菜单。device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator / DRA driver / common 这些核心算力组件的生产代码本期零改动。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)相对上期(2026-10-25)锚点**全部无新提交**,HEAD SHA 逐一比对一致。
- 虽为文档单改,但文档披露了一个**已在 26.3.0 落地、本期才补文档**的 Volcano 调度新能力:按芯片粒度的"故障退避容忍降级调度",引入两个新任务注解 `huawei.com/silent.unhealthy-tolerance.after-time`(静默故障芯片)与 `huawei.com/pod.error-tolerance.after-time`(Pod 错误芯片),让任务在退避窗口内避让疑似问题芯片而非被反复调度上去。证据只覆盖文档,未见对应 for-volcano 调度器生产代码 hunk。

## 当日重要改变
- 无(本期无生产代码改动,无 API/CRD/架构级代码 diff 命中)。下述退避容忍能力为文档软信号,记在正文,不计入重要改变。

## mind-cluster: c144488f -> a1ba9a44
- 比较: c144488fabc83fa79ca0e811df77a26c8c2d13b3..a1ba9a44 | tag: v26.2.0 | commits=2 | truncated=false
- 源链接:https://gitcode.com/Ascend/mind-cluster/compare/c144488fabc83fa79ca0e811df77a26c8c2d13b3...a1ba9a44c56109a57f9c63911bb20c5860f20ac6

### AI 总结重点(文档 diff 为据,无生产代码 hunk)
- **[软信号] Volcano 侧新增"故障退避容忍降级调度",按芯片(非节点)粒度生效,靠两个任务注解驱动**。文档明确该特性仅支持 26.3.0 及以上,依赖 Volcano + Ascend Device Plugin(静默故障检测还需 ClusterD),本期只是补了用户指南与 yaml 配置参考,**未见 `component/ascend-for-volcano` 调度器代码随动**。两个注解的语义(从 yaml 配置参考文档摘):
  - `huawei.com/silent.unhealthy-tolerance.after-time`:静默故障芯片(ClusterD 综合判定、不改健康状态、不触发重调度)的退避时长,默认 `0`(立即允许/不降级),范围 `[-1, 1800]` 秒;`-1`=永久禁止,且已运行任务若用到该芯片会被**驱逐并重调度**。
  - `huawei.com/pod.error-tolerance.after-time`:Pod 失败时本次用过的芯片的退避时长,**按任务维度生效**(只出错任务避让,不影响他人),默认 `30`,范围 `[0, 300]` 秒,仅临时退避、**不支持 `-1`**。
  <details><summary>代码依据 docs/zh/scheduling/06_api/15_yaml_configuration.md(新增注解表项)</summary>

  ```diff
  +|metadata.annotations['huawei.com/silent.unhealthy-tolerance.after-time']|字符串|-|静默故障芯片退避容忍时长,单位 s。<ul><li>0:立即允许,不降级。</li><li>-1:永久禁止,任务不调度到静默故障芯片,已运行任务使用到静默故障芯片时会被驱逐并重调度。</li><li>N(N>0):任务排队N秒后才允许使用静默故障芯片。</li></ul>默认 0,取值范围 [-1, 1800]。|
  +|metadata.annotations['huawei.com/pod.error-tolerance.after-time']|字符串|-|Pod错误芯片退避容忍时长,单位 s。<ul><li>0:立即允许,不降级。</li><li>N(N>0):任务在Pod失败后N秒内避让导致本次失败的芯片。</li></ul>默认 30,取值范围 [0, 300]。Pod错误退避为临时退避,不支持配置-1。|
  ```
  </details>
  <details><summary>代码依据 docs/zh/scheduling/04_usage/03_basic_scheduling/08_fault_tolerance_backoff_scheduling.md(新增 104 行,原理节)</summary>

  ```diff
  +## 使用前必读
  +任务运行过程中,集群中可能存在一些不影响芯片健康状态、但可能会导致任务反复失败的芯片:
  +- 静默故障芯片:节点反复出现软件故障、但检测窗内无硬件故障上报时,由ClusterD综合判定为静默故障(SilentFault)。仅追加故障列表,不改变芯片健康状态,因此不触发Job/Pod/进程级重调度。
  +- Pod错误芯片:任务运行中因各类故障导致Pod失败时,该Pod本次使用过的芯片。
  +针对这类芯片,Volcano提供基于时长的退避容忍机制:退避窗口内调度器不再把这类芯片分配给该任务(降级调度),窗口结束后自动恢复。
  ```
  </details>

### 后续发展方向 [AI]
- 这是昇腾调度在"芯片级可靠性"上的细化:从既有的"健康/不健康"二元过滤,扩展到"疑似问题芯片按时长软避让"的灰度降级,且区分集群级共识故障(静默故障,全局退避)与任务级观测故障(Pod 错误,仅本任务退避)。证据只覆盖文档,无法判定调度器内部是用 predicate 过滤候选芯片集还是打分降权实现——文档描述"从候选芯片集合中剔除",倾向前者,但无 `ascend-for-volcano` 代码 hunk 佐证。对我们产品的启示:若对标做 NPU/GPU 故障退避,注解即契约——注意静默故障 `-1` 会触发**驱逐+重调度**(破坏性动作)、而 Pod 错误退避永不永久禁止,这组非对称默认值(0 vs 30)是厂商在"可用性 vs 规避坏卡"之间的取舍点,值得在自家策略里复刻。下期盯 `component/ascend-for-volcano` 与 `component/clusterd`(静默故障判定逻辑)生产代码(参见 [[ascend-dra-pathprefix-gap]])。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓均无新提交;mind-cluster 核心组件生产代码零改动</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:compare base..HEAD 无新提交,HEAD SHA 与上期一致。
- mind-cluster 的 device-plugin / docker-runtime / for-volcano / operator / npu-exporter / noded / clusterd / infer-operator / DRA driver / common 本期生产代码零改动,仅调度用户指南文档被改。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=a1ba9a44c56109a57f9c63911bb20c5860f20ac6 tag=v26.2.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v26.9.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=npu-dra-plugin sha=031dc691f082fdb90610f77eab3bcf91ad8e9aa3 tag=v26.9.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-26 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-26 -->
