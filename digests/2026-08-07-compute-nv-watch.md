# NVIDIA 算力栈 diff 雷达 2026-08-07

## 摘要
- KAI-Scheduler 补了两处 GPU 共享/gang 调度的账目正确性 bug:①**一个 DRA ResourceClaim 被多 pod 共享的物理 GPU 现在每节点只计一次**(此前每 pod 各计一次 → 节点出现负空闲 GPU,#1931);②**成功结束的 pod 保留在调度器视野内**,让"整组正在收尾"的 gang 不再被 stalegangeviction 误驱逐(#2012)。均指向 DRA 原生共享路径的成熟化。
- gpu-driver-container 仅一次 RHEL UBI9 基础镜像 digest 刷新(+一次 nvlink5 GPU 复位改动加进又回退,净无变化),无实质能力改动。
- 其余 7 仓(gpu-operator/container-toolkit/k8s-device-plugin/dra-driver-nvidia-gpu/dcgm-exporter/DCGM/mig-parted)本期无新提交。

## 当日重要改变
- KAI-Scheduler [新能力/正确性] DRA 共享 GPU 去重:新增 `DRASharedDeviceRefCount` 按 `driver/pool/device` 给每张物理设备做引用计数,一个 ResourceClaim 的 `status.reservedFor` 挂多个 pod 时该 GPU 只计一次,修此前的负空闲 GPU。证据 `pkg/scheduler/api/node_info/dra_shared_device_info.go`(新增)https://github.com/kai-scheduler/KAI-Scheduler/pull/1931
- KAI-Scheduler [正确性] gang 收尾误驱逐:informer watch 过滤条件从"过滤所有终态 pod(Failed+Succeeded)"收窄为"仅过滤 Failed",Succeeded pod 保留(压缩存储),避免 gang 内 pod 成功退出后剩余 pod 被 stalegangeviction 清掉。证据 `pkg/scheduler/cache/cache.go`、`pkg/scheduler/cache/pod_transform.go` https://github.com/kai-scheduler/KAI-Scheduler/pull/2012

## kai-scheduler/KAI-Scheduler: 3ce5dcfa -> c048f657
- 比较: 3ce5dcfa -> c048f657 | ahead=3 | files=13 | Release: v0.17.0(未跨档)
- https://github.com/kai-scheduler/KAI-Scheduler/compare/3ce5dcfa16495af2c893b6b657d37d915c8dda47...c048f657

### AI 总结重点(源码 diff 为据)
- **DRA 共享物理 GPU 每节点只计一次,消除负空闲 GPU**。`GpuSharingNodeInfo` 新增字段 `DRASharedDeviceRefCount map[string]int`,键是 `draDeviceKey = driver + "/" + pool + "/" + device`,记录该物理 DRA GPU 设备被节点上多少个 pod 引用。核心逻辑在新文件 `dra_shared_device_info.go`:`dedupSharedDRAGpus` 在 `addTaskResources` 里、把要计入 UsedVector 的 GPU 数扣掉"已被别的 pod 计过的物理设备数"(`alreadyCounted`),并给对应设备 refcount++;`releaseSharedDRAGpus` 是其镜像,在 `removeTaskResources` 里只要还有别的 pod 引用就保留该设备的占用。这修的是:同一 `ResourceClaim`(`status.reservedFor` 挂多个 pod,即 DRA time-slicing/MPS 形态)下每个消费 pod 都各自把整张 GPU 计一遍,导致节点算出负的空闲 GPU。
  <details><summary>代码依据 pkg/scheduler/api/node_info/dra_shared_device_info.go(新增)</summary>

  ```go
  // draDeviceKey uniquely identifies a physical DRA device on the node.
  func draDeviceKey(result resourceapi.DeviceRequestAllocationResult) string {
      return result.Driver + "/" + result.Pool + "/" + result.Device
  }
  // dedupSharedDRAGpus removes from resourcesToTrack the GPU count that would
  // double-count physical DRA devices already referenced by other pods ...
  func (ni *NodeInfo) dedupSharedDRAGpus(task *pod_info.PodInfo, resourcesToTrack resource_info.ResourceVector) {
      current := resourcesToTrack.Get(resource_info.GPUIndex)
      if current <= 0 { return }
      alreadyCounted := 0.0
      for _, key := range ni.allocatedGPUDeviceKeys(task) {
          if ni.DRASharedDeviceRefCount[key] > 0 { alreadyCounted++ }
          ni.DRASharedDeviceRefCount[key]++
      }
      if alreadyCounted > current { alreadyCounted = current }
      // ... deduct alreadyCounted from the GPU index of resourcesToTrack
  }
  ```
  </details>
  <details><summary>代码依据 pkg/scheduler/api/node_info/node_info.go(接入点)</summary>

  ```diff
  @@ func (ni *NodeInfo) addTaskResources
  +	// A physical DRA device shared by several pods (one ResourceClaim with
  +	// multiple reservedFor entries) must be counted once, not once per pod.
  +	ni.dedupSharedDRAGpus(task, resourcesToTrackVector)
  @@ func (ni *NodeInfo) removeTaskResources
  +	ni.releaseSharedDRAGpus(task, resourcesToTrackVector)
  @@ func (ni *NodeInfo) lessEqualTaskToNodeResources
  +	// A task sharing an already-counted DRA device does not need additional
  +	// GPU capacity for that device.
  +	if discount := ni.sharedDRAGpuDiscount(task); discount > 0 {
  +		adjusted := nodeResourcesVector.Clone()
  +		adjusted.Set(resource_info.GPUIndex, adjusted.Get(resource_info.GPUIndex)+discount)
  +		return task.ResReqVector.LessEqual(adjusted)
  +	}
  ```
  </details>
  同时 `Clone()` 里补了对该 map 的深拷贝(`gpu_sharing_node_info.go`),保证节点快照隔离。注:去重只作用于 `IsGPUDeviceClass(result.Driver)` 命中的 GPU 设备,非 GPU 设备(网卡等)不参与此账目。

- **成功结束的 pod 不再从调度器视野消失,避免 gang 收尾时误驱逐剩余 pod**。此前 informer 用 `filterTerminalPods` 把 `PodFailed`+`PodSucceeded` 两种终态都从 watch 里过滤掉;改为 `filterFailedPods` 只过滤 `PodFailed`,`watchFilteredPodPhases` 只剩 `PodFailed`。Succeeded pod 因此保留在缓存里,但经 `compactSucceededPod` 压成极小对象(仅 name/namespace/uid/phase + PodGroup 注解 + SubGroup label)以省内存。效果:一个 gang 里部分 pod 成功退出后,调度器仍能看到它们属于该 PodGroup,`stalegangeviction` 不会把整组当"stale"而驱逐剩余还在跑的 pod(#1968/#2012)。
  <details><summary>代码依据 pkg/scheduler/cache/cache.go</summary>

  ```diff
  -func filterTerminalPods(options *metav1.ListOptions) {
  -	selectors := make([]string, 0, len(terminalPodPhases))
  -	for _, phase := range terminalPodPhases {
  +var watchFilteredPodPhases = []v1.PodPhase{
  +	v1.PodFailed,
  +}
  +func filterFailedPods(options *metav1.ListOptions) {
  +	selectors := make([]string, 0, len(watchFilteredPodPhases))
  +	for _, phase := range watchFilteredPodPhases {
   		selectors = append(selectors, fmt.Sprintf("status.phase!=%s", phase))
   	}
  ...
  -			filterTerminalPods,
  +			filterFailedPods,
  ```
  </details>
  <details><summary>代码依据 pkg/scheduler/cache/pod_transform.go</summary>

  ```diff
  +	if pod.Status.Phase == v1.PodSucceeded {
  +		return compactSucceededPod(pod), nil
  +	}
  +func compactSucceededPod(pod *v1.Pod) *v1.Pod {
  +	compact := &v1.Pod{ObjectMeta: metav1.ObjectMeta{Name, Namespace, UID}, Status: {Phase}}
  +	if podGroup, found := pod.Annotations[PodGroupAnnotationForPod]; found { ... }
  +	if subGroup, found := pod.Labels[SubGroupLabelKey]; found { ... }
  +	return compact
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 两处都是 **DRA 原生 GPU 共享(而非 HAMi 式 hook 时分)** 落地过程中的账目/生命周期修补:`DRASharedDeviceRefCount` 的引入说明 KAI 正把"一 ResourceClaim 多 pod reservedFor"(DRA 层面的 time-slicing/MPS)当作一等公民做资源核算,之前的向量记账模型没考虑物理设备被多 pod 共享。证据只覆盖 node_info 的记账路径,未见 DRA 分配器如何生成这种多 reservedFor 的 claim(不在本 diff)。
- gang 收尾误驱逐的修法暴露出"调度器为省内存过滤掉终态 pod"与"gang 完整性判定需要看到成功 pod"之间的张力;当前用"保留但压缩 Succeeded pod"折中。证据未覆盖 stalegangeviction 判定逻辑本身是否还有其他触发路径(仅测试文件 `stalegangeviction_test.go` 改了 195 行,未逐行读)。

## gpu-driver-container: ba907417 -> 14c135c2
- 比较: ba907417 -> 14c135c2 | ahead=4 | files=1 | Release: —
- https://github.com/NVIDIA/gpu-driver-container/compare/ba907417925834a1ffa4db6fb20a39e82e0e88af...14c135c2

### AI 总结重点(源码 diff 为据)
- **无能力改动,仅一次 RHEL9 UBI 基础镜像 digest 刷新**。`rhel9/Dockerfile` 的 `BASE_IMAGE` 从 `ubi9/ubi:9.8-1785807559` 更到 `9.8-1785906690`。区间内另有 `[nvlink5] reset GPUs after starting the FM service` 一次改动,但被同区间的 Revert 抵消,净无功能变化。
  <details><summary>代码依据 rhel9/Dockerfile</summary>

  ```diff
  -ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.8-1785807559
  +ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.8-1785906690
  ```
  </details>

### 后续发展方向 [AI]
- 无方向性信号,常规基础镜像 pin 维护。nvlink5 启动后复位 GPU 的想法出现又回退,说明该行为仍在斟酌;证据仅两条 commit 标题,回退原因不在 diff 内。

## 本期无实质改动(折叠)
<details><summary>7 仓无新提交</summary>

- NVIDIA/gpu-operator(release v26.3.3)
- NVIDIA/nvidia-container-toolkit(release v1.20.0-rc.1)
- NVIDIA/k8s-device-plugin(release v0.19.3)
- kubernetes-sigs/dra-driver-nvidia-gpu(release v0.4.1)
- NVIDIA/dcgm-exporter(release 4.6.0-4.8.3)
- NVIDIA/DCGM(branch master)
- NVIDIA/mig-parted(release v0.14.4)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=736fdfb8f4064a2eb6f45f8af3a4809f3a4da800 branch=main release=v26.3.3 scanned=2026-08-07 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=f86148376a4fa0fd89e360274916aff057416fbc branch=main release=v1.20.0-rc.1 scanned=2026-08-07 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=14c135c2b56d1def04dfbf49f0909928b15a0971 branch=main release=— scanned=2026-08-07 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=c648e14098589a4a917796596bc4f96908b54433 branch=main release=v0.19.3 scanned=2026-08-07 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9c52a7d50994adbf2fbb5f1ce2f6466fa3f9936f branch=main release=v0.4.1 scanned=2026-08-07 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-07 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-07 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9020443d2187a2d994b22d8ba17ceb9ab3f3999d branch=main release=v0.14.4 scanned=2026-08-07 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=c048f6571cac11da4836c0c929b09d2b56db2f38 branch=main release=v0.17.0 scanned=2026-08-07 -->
