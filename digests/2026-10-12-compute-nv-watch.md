# NVIDIA 算力栈 diff 雷达 2026-10-12

## 摘要
- 当日唯一实质信号在 **KAI-Scheduler**(6 commit,清一色 fix):补齐 topology 感知调度在子组(subgroup)场景下的正确性——用 namespace 限定 PodGroupID 防跨命名空间碰撞、丢失的子组副本保留在作业原拓扑域内;operator 侧新增"Config 被重建后重新收养遗留 operand"与"CRD 升级前预检 stale storedVersions 早失败"两条运维健壮性修复;numa-placement-exporter 把普通 init 容器内存从观测完整性判定中剔除。
- **gpu-operator** 8 commit 全是版本收尾(v26.7.1→v26.7.2 CSV/skipRange、Go 1.27.1→1.27.2、golangci-lint v2.14.0),无能力/API/CRD 变更,按噪声处理。
- 其余 7 仓(container-toolkit / driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)无新提交,HEAD 逐仓一致。

## 当日重要改变
- 无命中强信号([弃用/移除]/[API/CRD变更]/[版本跨档]/[新能力]/[架构方向])。KAI-Scheduler 的改动命中 `pkg/scheduler/api/pod_info/pod_info.go` 路径,但属内部 API 包的一行取值修正,非对外 CRD 字段增删,不计作 [API/CRD变更]。

## kai-scheduler/KAI-Scheduler: 469ad7ef -> 173748a0
- 比较: 469ad7efa3a601f01f6f213458e040f7c03f6b24 -> 173748a0 | ahead=6 | files=37 | Release: v0.18.5
- https://github.com/kai-scheduler/KAI-Scheduler/compare/469ad7efa3a601f01f6f213458e040f7c03f6b24...173748a0

### AI 总结重点(源码 diff 为据)

- **PodGroupID 从裸注解值改为 namespace 限定键**,修节点快照里跨命名空间同名 PodGroup 互相覆盖。`getPodGroupID` 读到 `PodGroupAnnotationForPod` 注解后不再直接 `PodGroupID(gn)`,改走 `NewPodGroupID(pod.Namespace, gn)` 把命名空间拼进 ID。(#2366)
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
   func getPodGroupID(pod *v1.Pod) common_info.PodGroupID {
   	if gn, found := pod.Annotations[commonconstants.PodGroupAnnotationForPod]; found && len(gn) != 0 {
  -		return common_info.PodGroupID(gn)
  +		return common_info.NewPodGroupID(pod.Namespace, gn)
   	}
   	return ""
   }
  ```
  </details>

- **topology 插件计算"可分配拓扑域"时,改为从作业子组树重新解析 PodSet,而非沿用上游传入的 `podSets` 形参**,确保带 required 拓扑约束的作业在部分子组副本丢失/重建时,域校验仍覆盖整棵子组的后代 PodSet,不把替换副本挤出原域。`subSetNodesFn`/`getJobAllocatableDomains` 删掉 `podSets` 参数,内部新增 `getPodSetsForAllocatedPodDomains(job, subGroup)`:根子组返回 `RootSubGroupSet.GetDescendantPodSets()`,叶子组从 `GetAllPodSets()` 取单个,中间子组用新 `findSubGroupSet` 递归查后代;查不到显式报错而非静默空集。(#2321)
  <details><summary>代码依据 pkg/scheduler/plugins/topology/job_filtering.go</summary>

  ```diff
  -	if hasActiveAllocatedTasks(podSets) && hasTopologyRequiredConstraint(subGroup) {
  -		relevantDomainsByLevel = getRelevantDomainsWithAllocatedPods(podSets, topologyTree,
  +	podSetsForAllocatedPodDomains, err := getPodSetsForAllocatedPodDomains(job, subGroup)
  +	if err != nil {
  +		return nil, err
  +	}
  +	if hasActiveAllocatedTasks(podSetsForAllocatedPodDomains) && hasTopologyRequiredConstraint(subGroup) {
  +		relevantDomainsByLevel = getRelevantDomainsWithAllocatedPods(podSetsForAllocatedPodDomains, topologyTree,
   			DomainLevel(subGroup.GetTopologyConstraint().RequiredLevel))
  +func getPodSetsForAllocatedPodDomains(job *podgroup_info.PodGroupInfo, subGroup *subgroup_info.SubGroupInfo) (map[string]*subgroup_info.PodSet, error) {
  +	if subGroup.GetName() == subgroup_info.RootSubGroupSetName {
  +		return job.RootSubGroupSet.GetDescendantPodSets(), nil
  +	}
  +	if podSet, found := job.GetAllPodSets()[subGroup.GetName()]; found {
  +		return map[string]*subgroup_info.PodSet{subGroup.GetName(): podSet}, nil
  +	}
  +	if subGroupSet := findSubGroupSet(job.RootSubGroupSet, subGroup.GetName()); subGroupSet != nil {
  +		return subGroupSet.GetDescendantPodSets(), nil
  +	}
  ```
  </details>

- **CRD 升级前新增 storedVersions 预检,存在陈旧存储版本则在任何 CRD 被 apply 前整体失败**,避免 apiserver 中途拒绝 apply 留下半升级状态。`ApplyCRDs` 循环前插入 `checkStoredVersions`:逐个取 live CRD,若其 `Status.StoredVersions` 里有新内嵌 CRD 不再声明的版本,返回含修复指令的错误(先 `kubectl get ... | kubectl replace -f -` 重存对象,再 patch `/status/storedVersions`)。(#2381)
  <details><summary>代码依据 pkg/helmhooks/apply_crds.go</summary>

  ```diff
  +	if err := checkStoredVersions(ctx, c, objects); err != nil {
  +		return err
  +	}
   	for _, obj := range objects {
   		if err := c.Apply(ctx, client.ApplyConfigurationFromUnstructured(obj), ...
  +		var stale []string
  +		for _, v := range live.Status.StoredVersions {
  +			if !declared[v] { stale = append(stale, v) }
  +		}
  +		if len(stale) > 0 {
  +			return fmt.Errorf("CRD %s has stored versions %v that the new version no longer declares; ...", obj.GetName(), stale, ...)
  +		}
  ```
  </details>

- **operator 协调时,DeepEqual 相等但 controller owner UID 不同的 operand 不再判为"无需改动",改为纳入更新集以重新收养**,修 Config 被删后重建、老对象 owner 指向已消失 UID 时不被接管。`calculateActionsOnObjects` 新增 `ownerUID` 入参,新增 `hasPreviousOwner`(取 `GetControllerOf` 比对 UID),相等判定附加 `&& !hasPreviousOwner(...)`。(#2372)
  <details><summary>代码依据 pkg/operator/operands/deployable/deployable.go</summary>

  ```diff
  -			if reflect.DeepEqual(currentState[key], obj) {
  +			if reflect.DeepEqual(currentState[key], obj) && !hasPreviousOwner(currentState[key], ownerUID) {
   				objectsNotToChange[key] = obj
   			} else {
   				objectsToUpdate[key] = obj
  +func hasPreviousOwner(obj client.Object, ownerUID types.UID) bool {
  +	owner := v1.GetControllerOf(obj)
  +	return owner != nil && owner.UID != ownerUID
  +}
  ```
  </details>

- **numa-placement-exporter 把普通(非 restartable)init 容器从内存观测完整性判定中剔除**,不再因普通 init 容器运行/完成而把内存分组观测置 null。`memoryObservationComplete` 删掉整段 `ordinaryInit`/`ordinaryInitStarted`/`applicationStarted` 逻辑,InitContainerStatuses 循环改为仅处理出现在 `expected` 里的容器(即 restartable init / native sidecar),其余 continue 跳过。设计文档同步标注:普通 init 内存块不被 podResources 暴露、属本特性范围外,native sidecar 仍计入长期观测。(#2365)
  <details><summary>代码依据 pkg/npe/placement/memory_groups.go</summary>

  ```diff
   	for _, status := range pod.Status.InitContainerStatuses {
  +		if _, exists := expected[status.Name]; !exists {
  +			continue
  +		}
   		started[status.Name] = status.State.Running != nil || status.State.Terminated != nil
   		anyStarted = anyStarted || started[status.Name]
  -		if ordinaryInit[status.Name] && started[status.Name] { ... }
   	}
  -	if ordinaryInitStarted && !applicationStarted { ... }
  ```
  </details>

- **发布流水线新增无 v 前缀的 Helm chart OCI tag**,支持 semver 范围安装。`push-artifacts.yaml` 在 helm push 后用 ORAS 把 `kai-scheduler:$PACKAGE_VERSION` 额外打一个去掉 v 前缀的 tag(`${PACKAGE_VERSION#v}`)。(#2393)

### 后续发展方向 [AI]
- 本期 KAI-Scheduler 全是 fix,方向是**拓扑感知 gang 调度在多层子组(SubGroupSet)场景下的正确性收敛**:#2366(namespace 限定 ID)+ #2321(子组树重解析 PodSet)两条都指向"作业被拆成嵌套子组、副本会丢失重建"的真实部署形态——证据覆盖 topology 插件域计算与节点快照两处,未见对调度算法本身(bin-packing/抢占)的改动。
- operator 两条修复(#2381 CRD storedVersions 预检、#2372 重建 Config 后收养 operand)反映 KAI 作为 Helm/operator 交付物在**升级与重装生命周期**上的加固,与调度能力无关;证据仅覆盖 helmhooks 与 deployable 两文件,未见 CRD schema 字段层变化。
- numa-placement-exporter 持续打磨(#2365),文档明确其**长期将被 DRA 取代**("Superseded long-term by DRA"),当前仅作为 NUMA 内存放置的观测旁路;证据只覆盖观测完整性判定逻辑,未见其与 DRA 路径的衔接代码。

## 本期无实质改动(折叠)
<details><summary>8 仓无新提交 / 仅版本收尾</summary>

- NVIDIA/gpu-operator — 8 commit 全版本收尾(v26.7.2 CSV/skipRange、Go 1.27.1→1.27.2、golangci-lint v2.14.0),无能力/API/CRD 变更
- NVIDIA/nvidia-container-toolkit — 无新提交(Release v1.20.1)
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交(Release v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(Release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.8.4)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — 无新提交(Release v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9eddbaa4292c3ceb56295f40bc70ea5755237004 branch=main release=v26.7.1 scanned=2026-10-12 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-12 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9287a5418573da037ba0d287e059812aa4740e45 branch=main release=— scanned=2026-10-12 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=bd98fbd6b676c655d235857574bdca29ab562dbc branch=main release=v0.20.1 scanned=2026-10-12 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=fb8b9674749c15b35f3bc7535c2e796c86463397 branch=main release=v0.5.0 scanned=2026-10-12 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-12 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-12 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=87f9e3c6be56020a346e9d25379734291cfc9cca branch=main release=v0.15.1 scanned=2026-10-12 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=173748a0b254531a5054374580e34ec8b9d839c8 branch=main release=v0.18.5 scanned=2026-10-12 -->
