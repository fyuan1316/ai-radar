# NVIDIA 算力栈 diff 雷达 2026-09-07

## 摘要
- 仅 **KAI-Scheduler** 活跃(3 提交):调度语义两处实质演进——(1) 引入类型化 `TaskAllocationMode` 枚举替代裸 `bool`,并把 gang 满足判定从"平铺 PodSets 循环"改为沿 `RootSubGroupSet` 树递归,强化嵌套子组(minSubGroup/minAvailable)的 gang 准入底线;(2) 新增 `queuePriorityInQuotaReclaim` 抢占策略,允许高优先级队列在双方均在配额内时凭优先级从"in-quota"受害者处回收资源。
- NVIDIA 供应商栈其余 8 仓(gpu-operator / container-toolkit / driver-container / k8s-device-plugin / DRA driver / dcgm-exporter / DCGM / mig-parted)全部无新提交,ClusterPolicy CRD、DRA、time-slicing/MPS 配置面本日零演进。

## 当日重要改变
- KAI-Scheduler [新能力] 新增 `InQuotaQueuePriorityStrategy` 回收策略:开启 `queuePriorityInQuotaReclaim` 后,严格更高优先级的 reclaimer 队列可从"仍在自身配额内"的 reclaimee 回收资源(前提是 reclaimer 自身不超 deserved quota)——打破了此前"in-quota 资源不可被抢占"的隐含保护。证据 pkg/scheduler/plugins/proportion/reclaimable/strategies/strategies.go。https://github.com/kai-scheduler/KAI-Scheduler/pull/2104
- KAI-Scheduler [架构方向] gang 准入重构:`isRealAllocation bool` → 类型化 `TaskAllocationMode`(Real/Simulated/Partial/VictimReallocation),`IsGangSatisfied`/`IsStale` 从平铺 `PodSets` 遍历改为 `RootSubGroupSet` 树递归判定。证据 pkg/scheduler/api/podgroup_info/{allocation_info,job_info,subgroup_info/subgroupset}.go。https://github.com/kai-scheduler/KAI-Scheduler/pull/2096

## kai-scheduler/KAI-Scheduler: da8e4a0d -> 61e935cb
- 比较: da8e4a0d...61e935cb | ahead=3 | files=45 | Release: v0.17.1
- https://github.com/kai-scheduler/KAI-Scheduler/compare/da8e4a0d4f2eb0ca7dca13140ac1dc2e4186dff5...61e935cb233887894d548412cbed87da59a7542c

### AI 总结重点(源码 diff 为据)
- **裸 `bool` 分配语义升级为类型化 `TaskAllocationMode` 枚举**,四态覆盖不同调度场景:`RealTaskAllocation`(当前周期待绑定)、`SimulatedTaskAllocation`(评估调度场景)、`PartialTaskAllocation`(内部搜索/资源核算的部分任务集)、`VictimReallocation`(抢占后恢复受害者剩余分配)。新增 `enforceGangAdmission()`——只有 Real 与 Simulated 两态强制 gang 准入,把"部分/模拟"分配与"真实绑定"在 gang 语义上区分开。
  <details><summary>代码依据 pkg/scheduler/api/podgroup_info/allocation_info.go</summary>

  ```diff
  -func HasTasksToAllocate(podGroupInfo *PodGroupInfo, isRealAllocation bool) bool {
  +type TaskAllocationMode int
  +const (
  +	RealTaskAllocation TaskAllocationMode = iota
  +	SimulatedTaskAllocation
  +	PartialTaskAllocation
  +	VictimReallocation
  +)
  +func (mode TaskAllocationMode) enforceGangAdmission() bool {
  +	return mode == RealTaskAllocation || mode == SimulatedTaskAllocation
  +}
  +func HasTasksToAllocate(podGroupInfo *PodGroupInfo, mode TaskAllocationMode) bool {
   	for _, task := range podGroupInfo.GetAllPodsMap() {
  -		if task.ShouldAllocate(isRealAllocation) {
  +		if task.ShouldAllocate(mode.isRealAllocation()) {
  ```
  </details>
- **任务选择缓存从单槽升级为按模式分槽**:`tasksToAllocate []*PodInfo` → `tasksToAllocateByMode map[taskAllocationCacheMode][]*PodInfo`(同理 init resource vector)。避免不同分配模式共用一份缓存导致相互污染(如模拟态的选择结果污染真实绑定态)。
  <details><summary>代码依据 pkg/scheduler/api/podgroup_info/job_info.go</summary>

  ```diff
  -	tasksToAllocate                   []*pod_info.PodInfo
  -	tasksToAllocateInitResourceVector resource_info.ResourceVector
  +	tasksToAllocateByMode                   map[taskAllocationCacheMode][]*pod_info.PodInfo
  +	tasksToAllocateInitResourceVectorByMode map[taskAllocationCacheMode]resource_info.ResourceVector
  ```
  </details>
- **gang 满足判定从平铺改递归树**:`IsStale`/`IsGangSatisfied` 不再对平铺 `pgi.PodSets` 逐个判 `IsGangSatisfied`,而是委托 `pgi.RootSubGroupSet.IsGangSatisfied()`;新增的 `SubGroupSet.IsGangSatisfied()` 对直接子 SubGroupSet + 直接 PodSet 递归计数"满足者",与 `GetMinMembersToSatisfy()` 比较。这让嵌套子组(minSubGroup 下挂 minAvailable 叶子)的 gang 语义能被正确表达——某可选叶子未达 minAvailable 但父 minSubGroup 已满足时,整体不判为 stale。
  <details><summary>代码依据 pkg/scheduler/api/podgroup_info/subgroup_info/subgroupset.go + job_info.go</summary>

  ```diff
  +func (sgs *SubGroupSet) IsGangSatisfied() bool {
  +	satisfiedMembers := 0
  +	for _, subGroupSet := range sgs.GetDirectSubgroupsSets() {
  +		if subGroupSet.IsGangSatisfied() { satisfiedMembers++ }
  +	}
  +	for _, podSet := range sgs.GetDirectPodSets() {
  +		if podSet.IsGangSatisfied() { satisfiedMembers++ }
  +	}
  +	return satisfiedMembers >= sgs.GetMinMembersToSatisfy()
  +}
  // job_info.go:
  -	for _, podSet := range pgi.PodSets { if !podSet.IsGangSatisfied() { return false } }
  -	return true
  +	if pgi.RootSubGroupSet == nil { return false }
  +	return pgi.RootSubGroupSet.IsGangSatisfied()
  ```
  </details>
- **新增 `queuePriorityInQuotaReclaim` 回收策略**:在原有 `MaintainFairShareStrategy` + `GuaranteeDeservedQuotaStrategy` 之外追加 `InQuotaQueuePriorityStrategy`,仅当 flag 开启时挂入 `priorityLeadStrategies`。该策略允许严格更高优先级的 reclaimer 从 in-quota 的 reclaimee 回收(条件:reclaimer 加上被回收资源后仍在自身 deserved quota 内)。语义变化:in-quota 资源不再对更高优先级队列绝对免疫抢占。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/reclaimable/strategies/strategies.go</summary>

  ```diff
  +type InQuotaQueuePriorityStrategy struct{}
  +var priorityLeadStrategies = append(append([]ReclaimStrategy{}, strategies...), &InQuotaQueuePriorityStrategy{})
  +func (iqps *InQuotaQueuePriorityStrategy) Reclaimable(...) bool {
  +	if reclaimerQueue.Priority <= reclaimeeQueue.Priority { return false }
  +	return ReclaimerFitsDeservedQuota(reclaimerResources, vectorMap, reclaimerQueue)
  +}
  ```
  </details>
- **配套队列排序改动**:`GetQueueOrderResult` 新增 `queuePriorityInQuotaReclaim` 入参,开启时先走 `prioritizeBasedOnPriorityIfBothQueuesInQuota`——当两队列各自加上候选 job 后都仍在 deserved quota 内,则优先级先于 starvation 检查决定排序,避免低优先级 in-quota job 卡住高优先级 in-quota job。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/queue_order/queue_order.go</summary>

  ```diff
  +	if queuePriorityInQuotaReclaim {
  +		result := prioritizeBasedOnPriorityIfBothQueuesInQuota(
  +			lQueue, lJobInfo, rQueue, rJobInfo, subGroupOrderFn, taskOrderFn, minNodeGPUMemory)
  +		if result != equalPrioritization { return result }
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 两处改动共同指向 KAI 的**层级化配额 + gang 调度精细化**:`TaskAllocationMode` 四态是把"真实绑定 / 模拟 / 部分搜索 / 抢占恢复"的分配路径显式建模,为后续在不同路径施加不同 gang 与缓存策略铺路;树递归的 gang 判定是嵌套 SubGroup(多层 minSubGroup)落地的前置。证据只覆盖 podgroup_info 与 proportion 插件的 diff,未见 CRD/API 层暴露 `queuePriorityInQuotaReclaim` 的开关字段(本次 hunk 未含 `*_types.go`),该 flag 如何配置(全局 config vs 队列级)未在本区间可见。
- `InQuotaQueuePriorityStrategy` 是"优先级压过配额保护"的方向信号,对多租户强 SLA 场景(高优队列可抢占低优队列 in-quota 资源)有直接意义;但默认关闭(需显式 flag),说明仍在保守灰度。未见默认开启或迁移计划。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY(无新提交 / 仅 bump·CI·merge)</summary>

- NVIDIA/gpu-operator — 无新提交(HEAD 停在 08c40bc4,Release v26.7.0)
- NVIDIA/nvidia-container-toolkit — 无新提交(752e1e57,Release v1.20.0)
- NVIDIA/gpu-driver-container — 无新提交(9ac64592)
- NVIDIA/k8s-device-plugin — 无新提交(4edf2b66,Release v0.20.0)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(8ad4e66f,Release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(181290c3,Release 4.6.0-4.8.3)
- NVIDIA/DCGM — 无新提交(64df9f89,branch master)
- NVIDIA/mig-parted — 无新提交(20986865,Release v0.15.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=08c40bc479192e3d5a82b7fd41d7e85a7197741f branch=main release=v26.7.0 scanned=2026-09-07 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=752e1e571bdfda0a5e0e3f5804c4c556796ab0eb branch=main release=v1.20.0 scanned=2026-09-07 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9ac64592151369a93da35b831322f193c03b13f5 branch=main release=— scanned=2026-09-07 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=4edf2b66ec53db87c36e035f82e5629b676893e3 branch=main release=v0.20.0 scanned=2026-09-07 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=8ad4e66f1367b852c36e1f405d50055b7b3bbe66 branch=main release=v0.5.0 scanned=2026-09-07 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-07 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-07 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2098686586250d28c472aaa821643a069f8464ec branch=main release=v0.15.0 scanned=2026-09-07 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=61e935cb233887894d548412cbed87da59a7542c branch=main release=v0.17.1 scanned=2026-09-07 -->
