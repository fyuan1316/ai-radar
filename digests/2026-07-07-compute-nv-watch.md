# NVIDIA 算力栈 diff 雷达 2026-07-07

## 摘要
- KAI-Scheduler 单仓推进 3 提交,核心是 proportion(配额比例)插件的**热路径去分配重构**(#1822):新增 4 个 `QueueResourceShare` 标量比较方法,把此前"物化整张 `ResourceQuantities` map 再 Add/Less/LessEqual"的比较,改为按 `AllResources` 逐资源标量比较,免去 reclaim/队列排序热路径上的 map 分配;配套把 `ReclaimerInfo` 从堆指针改为值传递、把多处 verbose 日志包进 `log.V(n).Do(func(){...})` 延迟求值。
- 另一处是**指标语义修复**(#1622):`kai_pod_group_evicted_pods_total` 此前按 gang size 累加(`.Add(count)`),导致驱逐计数被组大小放大;改为每次驱逐 `.Inc()` 单增,计数回归"驱逐事件数"语义。
- 其余 8 仓(gpu-operator / nvidia-container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)相对上期锚点均无新提交,锚点顺延。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [指标语义/修复] `kai_pod_group_evicted_pods_total` 计数由"按 gang size 累加"改为"每次驱逐单增",消费该指标做 SLO/告警的看板读数会显著下降(不再乘以组大小)。证据 `pkg/scheduler/metrics/metrics.go`、`pkg/scheduler/cache/status_updater/default_status_updater.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1622

## kai-scheduler/KAI-Scheduler: 1ce0bd23 -> 8fab211a
- 比较: 1ce0bd236c324fba10731ed5268faff351addc2e -> 8fab211a | ahead=3 | files=35 | Release: v0.16.2
- Compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/1ce0bd236c324fba10731ed5268faff351addc2e...8fab211af6e482be7f4b0a75dbf59571909c496a

### AI 总结重点(源码 diff 为据)
- **proportion 插件新增 4 个 `QueueResourceShare` 标量比较方法,替换掉"物化 map 再整体比较"的旧路径**。旧代码 `GetFairShare()/GetAllocatedShare()/GetDeservedShare()/GetAllocatableShare()` 每次都构造一整张 `ResourceQuantities` map 再做 `Less/LessEqual/Add`;新方法(`FairShareLessThanAllocated`、`AllocatedPlusResourcesLessEqualDeserved`、`QuantitiesLessEqualAllocatable`、`ResourceQuantityFromVector`)按 `AllResources` 逐资源取 `ResourceShare(resource)` 做标量比较,不再分配 map。这是 reclaim 判定 + 队列排序的高频热路径,目标是降低分配开销(commit 标题 "reduce reclaim allocation churn")。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/resource_share/queue_resource_share.go</summary>

  ```diff
  +// FairShareLessThanAllocated preserves the strict all-resource comparison used by ResourceQuantities.Less.
  +func (qrs *QueueResourceShare) FairShareLessThanAllocated() bool {
  +	for _, resource := range AllResources {
  +		resourceShare := qrs.ResourceShare(resource)
  +		if resourceShare.FairShare >= resourceShare.Allocated { return false }
  +	}
  +	return true
  +}
  +// AllocatedPlusResourcesLessEqualDeserved compares a vector without materializing resource quantities.
  +func (qrs *QueueResourceShare) AllocatedPlusResourcesLessEqualDeserved(
  +	resources resource_info.ResourceVector, vectorMap *resource_info.ResourceVectorMap) bool {
  +	for _, resource := range AllResources {
  +		resourceShare := qrs.ResourceShare(resource)
  +		allocated := resourceShare.Allocated + ResourceQuantityFromVector(resource, resources, vectorMap)
  +		if compareQuantities(allocated, resourceShare.Deserved) > 0 { return false }
  +	}
  +	return true
  +}
  ```
  </details>
- **`ResourceQuantityFromVector` 把 scheduler 的 `ResourceVector` 直接投影成 proportion 当前记账的 cpu/mem/gpu 标量**,GPU 维度在有 `vectorMap` 时走 `TotalGPUs(vectorMap)`、否则退回 `Get(GPUIndex)`。这是免去"先 QuantifyVector 成 map 再比"这一步的关键——比较侧只取需要的那一维标量。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/resource_share/queue_resource_share.go</summary>

  ```diff
  +func ResourceQuantityFromVector(resource ResourceName, resources resource_info.ResourceVector,
  +	vectorMap *resource_info.ResourceVectorMap) float64 {
  +	switch resource {
  +	case CpuResource:    return resources.Get(resource_info.CPUIndex)
  +	case MemoryResource: return resources.Get(resource_info.MemoryIndex)
  +	case GpuResource:
  +		if vectorMap == nil { return resources.Get(resource_info.GPUIndex) }
  +		return resources.TotalGPUs(vectorMap)
  +	default: return 0
  +	}
  +}
  ```
  </details>
- **调用侧全面切到新方法,并去掉中间 map 物化**。`filter_victims.go` 的 `canBeDeservedQuotaReclaimCandidate` 从"构造 involvedResources 集合 + 取 allocated/deserved map"改为直接遍历 `rs.AllResources`,用 `ResourceQuantityFromVector` 过滤零需求维度、用 `reclaimeeQueue.ResourceShare(resource)` 逐维比 Allocated/Deserved;`queue_order.go` 抽出 nil 安全的 `jobInitResources` 助手(返回裸 vector 而非 map),`prioritizeUnderUtilized/prioritizeUnderQuotaWithJob` 改用 `FairShareLessThanAllocated`/`AllocatedPlusResourcesLessEqualDeserved`;`strategies.go` 的 `FitsMaintainFairShare`→`QuantitiesLessEqualAllocatable`、`ReclaimerFitsDeservedQuota`→`AllocatedPlusResourcesLessEqualDeserved`。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/reclaimable/filter_victims.go + queue_order/queue_order.go</summary>

  ```diff
  -	involvedResources := getInvolvedResourcesNames([]resource_info.ResourceVector{reclaimer.RequiredResources}, reclaimer.VectorMap)
  -	for resource := range involvedResources {
  -		if deserved[resource] == commonconstants.UnlimitedResourceQuantity { continue }
  -		if allocated[resource] > deserved[resource] { return true }
  +	for _, resource := range rs.AllResources {
  +		if rs.ResourceQuantityFromVector(resource, reclaimer.RequiredResources, reclaimer.VectorMap) <= 0 { continue }
  +		resourceShare := reclaimeeQueue.ResourceShare(resource)
  +		if resourceShare.Deserved == commonconstants.UnlimitedResourceQuantity { continue }
  +		if resourceShare.Allocated > resourceShare.Deserved { return true }
  ```
  </details>
- **`buildReclaimerInfo` 从返回堆指针 `*rec.ReclaimerInfo` 改为返回值 `rec.ReclaimerInfo`,调用点改传 `&reclaimerInfo`**,减少每次 reclaim 判定的堆逃逸——与上面的去 map 分配是同一 perf 主题的收尾。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/proportion.go</summary>

  ```diff
  -func (pp *proportionPlugin) buildReclaimerInfo(...) *rec.ReclaimerInfo {
  -	return &rec.ReclaimerInfo{
  +func (pp *proportionPlugin) buildReclaimerInfo(...) rec.ReclaimerInfo {
  +	return rec.ReclaimerInfo{
  ...
  -	return pp.reclaimablePlugin.CanReclaimResources(pp.queues, reclaimerInfo)
  +	return pp.reclaimablePlugin.CanReclaimResources(pp.queues, &reclaimerInfo)
  ```
  </details>
- **驱逐指标语义修复:`RecordPodGroupEvictedPods(...count int)`→`IncPodGroupEvictedPods(...)`**,底层从 `.Add(float64(count))`(count=EvictionGangSize)改为 `.Inc()`。此前每次驱逐把计数器加上整个 gang 大小,`kai_pod_group_evicted_pods_total` 被组大小放大;修复后按驱逐事件单增。调用点同步去掉 `evictionMetadata.EvictionGangSize` 实参。
  <details><summary>代码依据 pkg/scheduler/metrics/metrics.go + cache/status_updater/default_status_updater.go</summary>

  ```diff
  -func RecordPodGroupEvictedPods(name, namespace, uid, nodepool, action string, count int) {
  -	podGroupEvictedPodsTotal.WithLabelValues(name, namespace, uid, nodepool, action).Add(float64(count))
  +func IncPodGroupEvictedPods(name, namespace, uid, nodepool, action string) {
  +	podGroupEvictedPodsTotal.WithLabelValues(name, namespace, uid, nodepool, action).Inc()
  ...
  -	metrics.RecordPodGroupEvictedPods(..., evictionMetadata.Action, evictionMetadata.EvictionGangSize)
  +	metrics.IncPodGroupEvictedPods(..., evictionMetadata.Action)
  ```
  </details>
- **多处 verbose 日志改为 `log.InfraLogger.V(n).Do(func(){...})` 延迟求值**(session_plugins.go V7、nodeavailability.go V7、strategies.go V6)。旧写法要么 `if !IsVerbose(7) { return }` 手动守卫、要么直接 eager 拼串(节点名列表、GPU 向量、queue share 快照);新写法把拼串闭包进 `Do`,只在该日志级别开启时执行,同属"热路径少做无用功"的 perf 主题。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/reclaimable/strategies/strategies.go</summary>

  ```diff
  -	log.InfraLogger.V(6).Infof("Checking if reclaim is possible for reclaimer <%s> and reclaimee <%s> ...",
  -		reclaimerQueue.Name, reclaimeeQueue.Name, reclaimeeQueue.GetRequestableShare(), ...)
  +	log.InfraLogger.V(6).Do(func() {
  +		log.InfraLogger.V(6).Infof("Checking if reclaim is possible for reclaimer <%s> and reclaimee <%s> ...",
  +			reclaimerQueue.Name, reclaimeeQueue.Name, reclaimeeQueue.GetRequestableShare(), ...)
  +	})
  ```
  </details>
- 第三个提交 `feat(docs): render native scale test results and metrics`(#1835)是 `docs/scale-tests/` 前端看板重写(metrics.js/app.js/results.js 及一批 *.test.js),渲染其自研规模基准(填满集群、拓扑分配、reclaim 延迟、NCCL 模拟等)的耗时曲线,属项目内部可观测工具,不涉调度器行为,不做符号级展开。

### 后续发展方向 [AI]
- **proportion 插件在做"零分配热路径"的系统性打磨**:本次把 reclaim 判定与队列排序两条高频路径的 map 物化全部下沉为逐资源标量比较,并配合值传递 + 日志延迟求值。方向是大规模场景下的调度吞吐/GC 压力优化(与同仓 scale-tests 看板重写时间点吻合,像是为规模基准背书)。证据只覆盖 proportion 子树的比较路径,`compareQuantities`/`ResourceShare` 的实现与 `AllResources` 的定义本次未读 hunk,不能断言所有旧 `ResourceQuantities` 语义都已等价迁移。
- **指标口径在向"事件数"而非"资源量"收敛**:evicted 计数修复暗示其驱逐/抢占系列指标此前有按量放大的口径混淆,消费侧看板需按 v0.16.2 之后重新标定基线。证据仅这一个计数器,是否还有同类"Add(size)"型指标未一并修,未见其他 hunk,待后续确认。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓</summary>

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
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7b38b13887ac4054d2f958d9e178d25f6b72ef8a branch=main release=v26.3.3 scanned=2026-07-07 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=69c285d7fd8f23e2a45bf64efe71e1bdaa61c1de branch=main release=v1.19.1 scanned=2026-07-07 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=102ce377e0478c58cb3927c28cfda685c6bd3425 branch=main release=— scanned=2026-07-07 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-07 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=884f41fdd20204ae2f194ba9a94cce4b4200110b branch=main release=v0.4.1 scanned=2026-07-07 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-07 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=944764a9e9685d82279eb2d1ee216b7b2451e213 branch=main release=v0.14.3 scanned=2026-07-07 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=8fab211af6e482be7f4b0a75dbf59571909c496a branch=main release=v0.16.2 scanned=2026-07-07 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-07-07 -->
