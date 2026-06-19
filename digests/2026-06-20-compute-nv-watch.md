# NVIDIA 算力栈 diff 雷达 2026-06-20

## 摘要
- 9 仓今日唯一实质改动仍在 **KAI-Scheduler**:落两件——(1) 队列指标新增 `queue_metadata_name`/`queue_display_name` 两个标签(scheduler + queue-controller 双侧),把"展示名"与"稳定 join key(metadata.name)"分离;(2) 修 Session 生命周期内存泄漏——`clear()` 整块置空 ClusterInfo + 全部 Fn 表 + 重置资源缓存,并用显式 `releaseNodeScoringPool()` 取代 `runtime.SetFinalizer` 释放节点打分协程池。
- 无 API/CRD 字段增删(命中的 `queue_info.go` 是调度器内部 api 包,非 CRD types);无版本跨档(仍 v0.15.2)。
- L1 驱动容器化 / device-plugin / DRA / 监控 / mig-parted 全线 EMPTY。

## 当日重要改变
- KAI-Scheduler [指标语义] 队列指标加 `queue_metadata_name`(恒为 Queue 的 metadata.name,推荐做跨指标 join 键)+ `queue_display_name`(spec.displayName,未设为空串);旧 `queue_name` 标签保留向后兼容。属**附加式**改动,不删旧标签,但会改变 6+ 个 queue_* 指标的标签集合,涉及面板/PromQL 的需复核 series 维度。证据 docs/metrics/METRICS.md + pkg/scheduler/metrics/metrics.go。 https://github.com/kai-scheduler/KAI-Scheduler/pull/1582
- KAI-Scheduler [内存/生命周期] `Session.clear()` 从只清 PodGroupInfos/Nodes 扩成整体置空 ClusterInfo 与 ~25 个回调 Fn 表、重置 k8sResourceStateCache;并把节点打分池释放从 GC finalizer 改为快照失败/closeSession 两处显式调用。修长会话快照不被回收的内存/协程泄漏。 https://github.com/kai-scheduler/KAI-Scheduler/pull/1726

## kai-scheduler/KAI-Scheduler: 1eab11c8 -> 4cbd3eab
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/1eab11c812b328de8f761bcf285dfbb4ea5a3b12...4cbd3eab | ahead=2 | files=14 | Release: v0.15.2

### AI 总结重点(源码 diff 为据)

- **队列模型新增 `DisplayName` 字段并贯穿到指标**:`QueueInfo` 与 proportion 插件的 `QueueAttributes` 各加 `DisplayName string`,从 `queue.Spec.DisplayName` 取值并在 `Clone()` 中复制。这是把"人读的展示名"提升为调度器一等数据,供指标标签使用。

  <details><summary>代码依据 pkg/scheduler/api/queue_info/queue_info.go</summary>

  ```diff
   type QueueInfo struct {
   	UID               common_info.QueueID
   	Name              string
  +	DisplayName       string
   	ParentQueue       common_info.QueueID
  @@ NewQueueInfo
  +		DisplayName:       queue.Spec.DisplayName,
  ```
  </details>

- **`UpdateQueueFairShare`/`UpdateQueueUsage` 签名从 1 个 queueName 扩成 3 个标签参数**:新增 `queueMetadataName`、`queueDisplayName`。注释明确语义分工——`queue_name` 保留 legacy 值(设了 DisplayName 时为 DisplayName,否则 metadata.name),`queue_metadata_name` 恒为 metadata.name 且为推荐 join 键,`queue_display_name` 为 spec.displayName(未设为空)。调用方 `resource_division.go` 传入 `string(queue.UID)`(即 metadata.name)与 `queue.DisplayName`。

  <details><summary>代码依据 pkg/scheduler/metrics/metrics.go + resource_division.go</summary>

  ```diff
  -func UpdateQueueFairShare(queueName string, cpu, memory, gpu float64) {
  -	queueFairShareCPU.WithLabelValues(queueName).Set(cpu)
  +func UpdateQueueFairShare(queueName, queueMetadataName, queueDisplayName string, cpu, memory, gpu float64) {
  +	queueFairShareCPU.WithLabelValues(queueName, queueMetadataName, queueDisplayName).Set(cpu)
  // 调用方:
  	metrics.UpdateQueueFairShare(
  		queue.Name,
  +		string(queue.UID),
  +		queue.DisplayName,
  ```
  </details>

- **queue-controller 侧同步铺标签**:`queueNameLabel` 旁新增 `queueMetadataNameLabel`/`queueDisplayNameLabel` 常量,`InitMetrics` 把三者一起 append 进 `queueMetricsLabels`;`SetQueueMetrics` 里 `queueQuotaMetricValues` 以 `{queueName, queueName, queueDisplayName}` 填值——即此侧 `queue_name` 与 `queue_metadata_name` 同值(都为 queue.Name),display_name 取 spec.DisplayName。

  <details><summary>代码依据 pkg/queuecontroller/metrics/metrics.go</summary>

  ```diff
  -	queueNameLabel = "queue_name"
  +	queueNameLabel         = "queue_name"
  +	queueMetadataNameLabel = "queue_metadata_name"
  +	queueDisplayNameLabel  = "queue_display_name"
  @@ InitMetrics
  -	queueMetricsLabels := append([]string{queueNameLabel}, additionalMetricLabelKeys...)
  +	queueMetricsLabels := append(
  +		[]string{queueNameLabel, queueMetadataNameLabel, queueDisplayNameLabel},
  +		additionalMetricLabelKeys...)
  @@ SetQueueMetrics
  -	queueQuotaMetricValues := append([]string{queueName}, additionalMetricLabelValues...)
  +	queueQuotaMetricValues := append(
  +		[]string{queueName, queueName, queueDisplayName}, additionalMetricLabelValues...)
  ```
  </details>

- **Session 释放路径重写,堵内存/协程泄漏**:`clear()` 原仅清两字段,现把 `ClusterInfo` 整体置 nil 并加清近 25 个回调 Fn 表(GpuOrderFns/Predicate/Preempt/Reclaim/NumaPlacement 等)与 `Config`、`k8sResourceStateCache = sync.Map{}`。节点打分池释放从 `runtime.SetFinalizer`(依赖 GC 不确定时机)改为显式 `releaseNodeScoringPool()`,在 `openSession` 快照失败和 `closeSession` 两处主动调用。配套 `fix(scheduler): clear completed session snapshots (#1726)`,即长跑下旧 session 快照(含 Nodes/PodGroups 大对象与协程池)无法及时回收的问题。

  <details><summary>代码依据 pkg/scheduler/framework/session.go</summary>

  ```diff
   func (ssn *Session) clear() {
  -	ssn.ClusterInfo.PodGroupInfos = nil
  -	ssn.ClusterInfo.Nodes = nil
  +	ssn.ClusterInfo = nil
  +	ssn.GpuOrderFns = nil
  +	... (PredicateFns/PreemptVictimFilterFns/NumaPlacementFn/Config 等约 25 个)
  +	ssn.k8sResourceStateCache = sync.Map{}
  +}
  +func (ssn *Session) releaseNodeScoringPool() {
  +	if ssn.nodeScoringPool != nil { ssn.nodeScoringPool.Release(); ssn.nodeScoringPool = nil }
  +	ssn.scoringPoolWorkerCount = 0
   }
  @@ InitNodeScoringPool
  -	runtime.SetFinalizer(ssn, func(s *Session) { ... s.nodeScoringPool.Release() ... })
  @@ openSession (snapshot err 路径)
  +		ssn.releaseNodeScoringPool()
  @@ closeSession
  -	ssn.nodeScoringPool.Release(); ssn.nodeScoringPool = nil; ssn.scoringPoolWorkerCount = 0
  +	ssn.releaseNodeScoringPool()
  ```
  </details>

### 后续发展方向 [AI]
- 指标改造是**可观测性面向多租户租户名/展示名**的收尾:把"稳定标识(metadata.name/UID)"与"展示名(displayName)"在指标层正式拆开,推荐 `queue_metadata_name` 做跨指标 join——意味着 KAI 自带 dashboard 后续会改用此键关联 scheduler 侧与 queue-controller 侧指标。证据只覆盖 metrics.go/METRICS.md 的标签定义,未见实际 Grafana 模板改动。
- Session 释放重写指向**调度器长稳/内存占用治理**:放弃 finalizer(时机不可控)走确定性释放,是为高频开 session(大集群秒级调度周期)下控制常驻内存与 goroutine 数。证据只覆盖 session.go 的 clear/release 逻辑,未见 benchmark 或泄漏复现数据。
- 对我们产品的启示:若自研调度/计量复用 KAI 指标做租户用量计费,需现在就以 `queue_metadata_name` 为聚合键、把 `queue_name` 视作展示用途;同时校验自身 session 类对象是否也存在 finalizer 依赖导致的延迟回收。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY(仅保锚点)</summary>

- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9b198ba801ee9f1754dea0d74d85384659bea1c9 branch=main release=v26.3.2 scanned=2026-06-20 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6d1a53dbd83f7b95eff3645afedf2335466014f2 branch=main release=v1.19.1 scanned=2026-06-20 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d5f839873900dc0f985eae0ff4d975c9aacff0b4 branch=main release=— scanned=2026-06-20 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.2 scanned=2026-06-20 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba branch=main release=v0.4.1-rc.1 scanned=2026-06-20 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-20 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-20 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=d8348422bc7338fba3e112fa3f733e7eecaf51da branch=main release=v0.14.2 scanned=2026-06-20 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4cbd3eab2ec39c2ecce87b2e2c77e01759e9700e branch=main release=v0.15.2 scanned=2026-06-20 -->
