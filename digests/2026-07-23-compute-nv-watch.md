# NVIDIA 算力栈 diff 雷达 2026-07-23

## 摘要
- **k8s-device-plugin 把共享设备(time-slicing 副本 + MIG)的分配策略做成可配置** `--shared-devices-allocation-policy=[distributed|packed]`(config 面新增字段),`distributed`(铺开)之外首次给出 `packed`(收拢到少数物理卡)语义,底层把 `distributedAlloc` 重构成通用 `greedyAlloc`+comparator——这是当日唯一的配置面/能力信号。
- **KAI-Scheduler 修 NUMA 对齐的 QoS 漏判**:此前整 pod 卡在 `QOSClass==Guaranteed` 才对齐,导致请求 GPU 的 Burstable pod 被放过;现改为"设备(GPU)对所有 QoS 对齐、cpu/内存仅 Guaranteed 对齐",Burstable GPU pod 也纳入拓扑约束。
- 另:gpu-operator 修 vGPU 预装场景的就绪门(等 host-vgpu-manager-ready);dra-driver 补一批 GPU 分配/MIG 文档(含 DynamicMIG alpha 门控说明,纯 docs 无代码)。

## 当日重要改变
- **NVIDIA/k8s-device-plugin [API/CRD变更]+[新能力]** 新增 config 字段 `sharedDevicesAllocationPolicy`(CLI `--shared-devices-allocation-policy` / env `SHARED_DEVICES_ALLOCATION_POLICY`),取值 `distributed`/`packed`,作用于 replicated(time-slicing)与 MIG 共享资源的 preferred allocation。命中 `api/config/v1/flags.go`、`api/config/v1/consts.go`。PR #1621 → https://github.com/NVIDIA/k8s-device-plugin/pull/1621
- **kai-scheduler/KAI-Scheduler [行为变更]** NUMA 插件 `shouldHandle` 门控修复:非 Guaranteed 但请求拓扑设备(GPU)的 task 现在也被 NUMA 约束,修掉"Burstable GPU pod 被 kubelet 对齐却被调度器放过"的错配。PR #1946 → https://github.com/kai-scheduler/KAI-Scheduler/pull/1946

## NVIDIA/k8s-device-plugin: 8461b2e1 -> 88a79d7e
- 比较: 8461b2e1ea526922093155e5ad579b0a9d9bb66a -> 88a79d7e | ahead=1 | files=7 | Release: v0.19.3
- 提交:Add configurable allocation policy (packed/distributed) for replicated and MIG resources (#1621) — https://github.com/NVIDIA/k8s-device-plugin/pull/1621

### AI 总结重点(源码 diff 为据)
- **配置面新增 `SharedDevicesAllocationPolicy` 字段**,挂在 `PluginCommandLineFlags` 下,对应 CLI flag `shared-devices-allocation-policy`(默认 `distributed`)与 env `SHARED_DEVICES_ALLOCATION_POLICY`;`validateFlags` 只接受 `distributed`/`packed`,非法值启动即报错。这是给共享设备分配策略开出的第一个用户可见开关。
  <details><summary>代码依据 api/config/v1/flags.go / cmd/nvidia-device-plugin/main.go</summary>

  ```diff
  +	SharedDevicesAllocationPolicy *string `json:"sharedDevicesAllocationPolicy" yaml:"sharedDevicesAllocationPolicy"`
  ...
  +			case "shared-devices-allocation-policy":
  +				updateFromCLIFlag(&f.Plugin.SharedDevicesAllocationPolicy, c, n)
  ...
  +		&cli.StringFlag{
  +			Name:    "shared-devices-allocation-policy",
  +			Value:   spec.AllocationPolicyDistributed,
  +			Usage:   "the allocation policy for replicated and MIG resources:\n\t\t[distributed | packed]",
  +			EnvVars: []string{"SHARED_DEVICES_ALLOCATION_POLICY"},
  +		},
  ...
  +	if config.Flags.Plugin.SharedDevicesAllocationPolicy != nil {
  +		switch *config.Flags.Plugin.SharedDevicesAllocationPolicy {
  +		case spec.AllocationPolicyDistributed:
  +		case spec.AllocationPolicyPacked:
  +		default:
  +			return fmt.Errorf("invalid --shared-devices-allocation-policy option: %s", ...)
  ```
  </details>
- **`distributed` 之外首次引入 `packed` 语义**,并把原来写死的 `distributedAlloc` 重构成一套"贪心选择 + comparator"框架:两种策略共用同一个 `greedyAlloc` 主循环,仅在"下一块该选哪张物理卡"上不同——`distributed` 选已分配副本最少的卡(铺开、均衡利用),`packed` 选已分配副本最多的卡(收拢、腾空整卡)。`getPreferredAllocation` 与 `GetPreferredAllocation` 两处调用点都改走 `comparatorForPolicy(policy)`。
  <details><summary>代码依据 internal/rm/allocate.go / consts.go / nvml_manager.go</summary>

  ```diff
  +const (
  +	AllocationPolicyDistributed = "distributed"
  +	AllocationPolicyPacked      = "packed"
  +)
  ...
  +var allocationComparators = map[string]replicaComparator{
  +	spec.AllocationPolicyDistributed: func(i, j *replicaCount) bool { return i.allocated() < j.allocated() },
  +	spec.AllocationPolicyPacked:      func(i, j *replicaCount) bool { return i.allocated() > j.allocated() },
  +}
  ...
  -	// Otherwise, distribute them evenly across all replicated GPUs
  -	return r.distributedAlloc(available, required, size)
  +	policy := spec.AllocationPolicyDistributed
  +	if r.config.Flags.Plugin != nil && r.config.Flags.Plugin.SharedDevicesAllocationPolicy != nil {
  +		policy = *r.config.Flags.Plugin.SharedDevicesAllocationPolicy
  +	}
  +	return r.greedyAlloc(available, required, size, comparatorForPolicy(policy))
  ```
  </details>

### 后续发展方向 [AI]
- `packed` 的用途是把 time-slicing/MIG 副本尽量收到少数物理卡上,腾出整卡给需要独占/整卡的负载——这是"共享 + 整卡"混部集群的碎片治理原语,和 HAMi 的 binpack 打分、DRA 的 partitionable devices 是同一问题的不同层解法。证据只覆盖 device-plugin 的 preferred-allocation 选卡逻辑,未见与上层调度器(如 KAI/volcano binpack)的协同,也未见 MPS 分支是否走同一策略(`comparatorForPolicy` 仅在 `getPreferredAllocation` 的非 aligned 分支接入)。

## kai-scheduler/KAI-Scheduler: d17b3fbe -> ba7e186f
- 比较: d17b3fbe244a2eed41348224c1b230accc85b6ef -> ba7e186f | ahead=4 | files=11 | Release: v0.16.4

### AI 总结重点(源码 diff 为据)
- **NUMA 插件 `shouldHandle` 门控从"整 pod 卡 Guaranteed"改为"按资源类型分治"**:Guaranteed task 无条件处理;非 Guaranteed task 仅当请求了拓扑感知设备(GPU 等)才处理。设计文档明说这是 bug 修复——Burstable 的 GPU pod 会被 kubelet device manager 对齐,但旧逻辑直接放过。新增 `isGuaranteed`、`isQoSGatedResource`(cpu/memory/hugepages)、`requestsAlignedDevice`。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/numa.go</summary>

  ```diff
  -	if topo == nil || !isModeledPolicy(topo.Policy) {
  +	if topo == nil || !isModeledPolicy(topo.Policy) || task.Pod == nil {
   		return false
   	}
  +	if isGuaranteed(task) {
  +		return true
  +	}
  +	return pp.requestsAlignedDevice(task, topo)
  ...
  +func isQoSGatedResource(name v1.ResourceName) bool {
  +	return name == v1.ResourceCPU || name == v1.ResourceMemory ||
  +		strings.HasPrefix(string(name), string(v1.ResourceHugePagesPrefix))
  +}
  ```
  </details>
- **配套新增 `alignedAware`**:评估器对非 Guaranteed task 只约束设备维度,剔除 cpu/memory/hugepages 索引(这些仅 Guaranteed 对齐),使调度器的约束面精确等于 kubelet 实际会对齐的资源。`solveTask` 由 `effectiveAware` 改调 `alignedAware(task, node)`。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/evaluator.go</summary>

  ```diff
  +func (pp *numaPlugin) alignedAware(task *pod_info.PodInfo, node *node_info.NodeInfo) []int {
  +	aware := pp.effectiveAware(node)
  +	if isGuaranteed(task) { return aware }
  +	...
  +	for _, idx := range aware {
  +		if isQoSGatedResource(topo.AwareNames[idx]) { continue }
  +		out = append(out, idx)
  +	}
  -	aware := pp.effectiveAware(node)
  +	aware := pp.alignedAware(task, node)
  ```
  </details>
- **调度成功后清理 PodGroup 的 `UnschedulableOnNodePool` 陈旧 condition**(#1908):新增 `clearPodGroupSchedulingCondition`,但用 `hasTasksAwaitingBind`(Allocated/Pipelined/Binding)做守卫——只有确认没有 task 在等 bind 才清,保证失败的 bind 仍留下"为何 pending"的解释。
  <details><summary>代码依据 pkg/scheduler/cache/status_updater/default_status_updater.go</summary>

  ```diff
  +	} else {
  +		updatePodgroupStatus = su.clearPodGroupSchedulingCondition(job)
  ...
  +func (su *defaultStatusUpdater) clearPodGroupSchedulingCondition(job *podgroup_info.PodGroupInfo) bool {
  +	if hasTasksAwaitingBind(job) { return false }
  +	return removePodGroupSchedulingCondition(job.PodGroup)
  +}
  +var bindInFlightStatuses = []pod_status.PodStatus{ pod_status.Allocated, pod_status.Pipelined, pod_status.Binding }
  ```
  </details>

### 后续发展方向 [AI]
- NUMA 修复把 KAI 的拓扑对齐从"只服务 Guaranteed"扩到"任何请求 GPU 的 pod",对推理这种常跑 Burstable 的负载是实打实的正确性提升,和 ascend-for-volcano 近期在拓扑亲和上的收敛同向。证据只覆盖 `single-numa-node`/`restricted` 两种 policy(`isModeledPolicy`),GPU *分片*(fraction)本身的 NUMA 对齐仍在 Non-Goals(代码注释明标 out of scope)。

## NVIDIA/gpu-operator: 4918a72c -> c37a3850
- 比较: 4918a72c29a57edeb129156a6b300c6ac9767f5b -> c37a3850 | ahead=4 | files=62 | Release: v26.3.3
- 提交:fix(vgpu-device-manager): wait for host-installed vGPU Manager readiness — https://github.com/NVIDIA/gpu-operator/commit/c37a3850b40db6dbd850aa75119dd479f75935ec

### AI 总结重点(源码 diff 为据)
- **vGPU Device Manager 的 `vgpu-manager-validation` init 容器就绪门改为等两种状态文件之一**:容器化部署写 `vgpu-manager-ready`,host 预装 driver 写 `host-vgpu-manager-ready`,旧逻辑只等前者,导致 `driver.enabled=false`(vGPU Manager 预装在主机)时 operand 永久 hang。改成 `|| [ -f .../host-vgpu-manager-ready ]` 后两种部署模式都能起来。
  <details><summary>代码依据 assets/state-vgpu-device-manager/0600_daemonset.yaml</summary>

  ```diff
  -          args: ["until [ -f /run/nvidia/validations/vgpu-manager-ready ]; do echo waiting ...; sleep 5; done"]
  +          args: ["until [ -f /run/nvidia/validations/vgpu-manager-ready ] || [ -f /run/nvidia/validations/host-vgpu-manager-ready ]; do echo waiting ...; sleep 5; done"]
  ```
  </details>

### 后续发展方向 [AI]
- 这是把 vGPU 栈"预装 driver / 容器化 driver"两条部署路径的就绪判定统一,补齐 host 预装分支的最后一环。证据仅覆盖 daemonset asset 与新增的断言测试 `TestVGPUDeviceManagerReadinessGate`,未触及 ClusterPolicy CRD 字段(无 `api/nvidia/v1` 命中)。

## kubernetes-sigs/dra-driver-nvidia-gpu: 4d0b3898 -> 6f2ff2eb(纯文档)
- 比较: 4d0b3898aa3a1940fa30dd1b16eb242d419be8d1 -> 6f2ff2eb | ahead=4 | files=14 | Release: v0.4.1
- 本期 14 个文件全在 `site/content/docs/`,无代码/CRD 改动,不写符号级总结;但新文档披露的能力边界值得记锚:
  - **DynamicMIG 为 alpha、feature gate 默认 false**,且与 `PassthroughSupport`/`NVMLDeviceHealthCheck`/`MPSSupport` 互斥(同开则启动 validation 报错);静态 MIG 默认开、无需 gate。
  - 动态 MIG 建在 K8s partitionable devices(KEP-4815)之上:启动时枚举所有 MIG profile×placement 全部广告进 ResourceSlice + 每卡共享计数器,调度器可分配"尚不存在"的分区,prepare 阶段再实际创建、释放时销毁,用 node-local checkpoint 做崩溃恢复真源。
  - 新增 `resourceslice-attributes.md` 参考:GPU/MIG/VFIO 三类设备统一在 `gpu.nvidia.com` driver 下、按 `type` 属性(gpu/mig/vfio)分 DeviceClass,列全可用 CEL selector 的属性/capacity(productName/memory/profile/parentUUID 等)。

## 本期无实质改动(折叠)
<details>
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=c37a3850b40db6dbd850aa75119dd479f75935ec branch=main release=v26.3.3 scanned=2026-07-23 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1cddfb0dc179136cd720090f0a13e6ce0de611ed branch=main release=v1.20.0-rc.1 scanned=2026-07-23 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=2518686ce14b1ff85fa6a786644e94539398d931 branch=main release=— scanned=2026-07-23 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=88a79d7e98c146e13a6bbb48fff6effdc87e541d branch=main release=v0.19.3 scanned=2026-07-23 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=6f2ff2eb7d311016f05bcfdde7067bf415093179 branch=main release=v0.4.1 scanned=2026-07-23 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-23 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-23 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f484af1ba590265e0cb429ca71e3c08cb8374a5d branch=main release=v0.14.4 scanned=2026-07-23 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=ba7e186ff71d496db9f43164e7008af45b33b71d branch=main release=v0.16.4 scanned=2026-07-23 -->
