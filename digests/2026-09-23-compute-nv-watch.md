# NVIDIA 算力栈 diff 雷达 2026-09-23

## 摘要
- **container-toolkit 彻底删除 ChmodHook**:连同 `deviceFolderPermissions` workaround 整条链路一并移除(crun#1047 早已修复,该 hook 本就 deprecated + 默认禁用),CDI 生成路径进一步瘦身。
- **k8s-device-plugin 修共享 GPU 的 Xid 健康上报**:`parentToDeviceMap` 从"一个物理 GPU 只记一个设备"改成 `map[parent][]*Device`,time-slicing/MPS 下同卡的**所有副本**在 Xid 事件时统一标记不健康(此前只有 map 里最后覆盖的那个被标)。
- **KAI-Scheduler 加 `Admission.ServiceName` CRD 字段** + 分数 GPU 计算共享模式(SMSharing)在 fit 阶段一致校验 + greedy GPU 匹配换线段树。dra-driver 本期集中修 ComputeDomain/IMEX 多节点 fabric 健壮性。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [弃用/移除] 删除 `ChmodHook` CDI hook 及 `pkg/nvcdi/workarounds-device-folder-permissions.go` 整个 discoverer(-160/-110 行),`defaultDisabledHooks` 变量与 chmod 子命令注册一并去除。证据见下。 https://github.com/NVIDIA/nvidia-container-toolkit/compare/3a6c050d9c0c7b2516ce17e2190fb7e71b741f82...84e2c2c182bfa0b2edab4fdca27e5197faba0ca7
- NVIDIA/k8s-device-plugin [新能力] 共享同一物理 GPU 的设备在 Xid 错误时全部标记不健康(修 time-slicing 场景漏标)。 https://github.com/NVIDIA/k8s-device-plugin/compare/1a7c1f8a9c074efd3ff2063a689195dea461f178...3dd82d32e62c4b956a85ed765edb0a7b86d83737
- kai-scheduler/KAI-Scheduler [API/CRD变更] `Admission` 新增可选字段 `ServiceName *string`(覆盖 webhook Service 名与证书 DNS 身份),CRD `kai.scheduler_configs.yaml` 同步。 https://github.com/kai-scheduler/KAI-Scheduler/pull/2206
- kubernetes-sigs/dra-driver-nvidia-gpu [架构方向] ComputeDomain 状态同步修竞态(节点被误清出 `status.nodes` → 破坏 IMEX 节点索引→IP 映射),IMEX DNS 引入 sentinel IP 防 search-domain 洪泛。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/83b9d60cf4eb325278948d826458227a95f59905...b936bcbce55e299dda65c25555867d200668ff72

## NVIDIA/nvidia-container-toolkit: 3a6c050d -> 84e2c2c1
- 比较 / Release: v1.20.1 | ahead=2 | files=9
### AI 总结重点(源码 diff 为据)
- **`ChmodHook` 从常量、默认禁用列表、命令注册、类型分发到实现文件被整体删除**。此前 chmod hook 用于把嵌套设备节点(`/dev/dri/*`、`/dev/nvidia-caps/*`)父目录权限置 755,规避 rootless podman + 老版 crun 的 bug(crun#1047);该 bug 已修,hook 早已标 deprecated 且默认禁用,本次做净移除。`internal/discover/hooks.go` 同时删掉 `defaultDisabledHooks` 变量本身——从"默认禁用某 hook"简化为"该 hook 不存在"。

  <details><summary>代码依据 internal/discover/hooks.go</summary>

  ```diff
  -	// A ChmodHook is used to set the file mode of the specified paths.
  -	//
  -	// Deprecated: The chmod hook is deprecated and will be removed in a future release.
  -	ChmodHook = HookName("chmod")
  ...
  -// defaultDisabledHooks defines hooks that are disabled by default.
  -var defaultDisabledHooks = []HookName{
  -	ChmodHook,
  -}
  ...
  -	o.disabledHooks = append(o.disabledHooks, defaultDisabledHooks...)
  ...
  -	case CreateSymlinksHook, ChmodHook, DisableDeviceNodeModificationHook, EnableCudaCompatHook, ...:
  +	case CreateSymlinksHook, DisableDeviceNodeModificationHook, EnableCudaCompatHook, ...:
  ```
  </details>

- **`deviceFolderPermissions` discoverer 整文件删除**,`pkg/nvcdi/management.go` 与 `full-gpu-nvml.go` 不再把它 merge 进设备发现链——management 路径直接 `return &managementDiscoverer{deviceNodes}, nil`,不再多包一层权限 hook。

  <details><summary>代码依据 pkg/nvcdi/management.go</summary>

  ```diff
  -	deviceFolderPermissionHooks := (*nvcdilib)(l).newDeviceFolderPermissionHookDiscoverer(
  -		deviceNodes,
  -	)
  -	d := discover.Merge(
  -		&managementDiscoverer{deviceNodes},
  -		deviceFolderPermissionHooks,
  -	)
  -	return d, nil
  +	return &managementDiscoverer{deviceNodes}, nil
  ```
  </details>

- `WithEnabledHooks` 注释与语义从"启用默认禁用的 hook"改为"覆盖 `WithDisabledHooks` 传入的 hook"——因为不再有默认禁用集合,enabled/disabled 变成纯对称的显式开关。
### 后续发展方向 [AI]
- CDI hook 集合正在收敛:移除历史兼容 workaround、去掉"默认禁用"这类隐式状态,朝"hook 要么注册要么不存在"的显式模型走。证据只覆盖 chmod 一条链的删除,未见是否有新 hook 补位。

## NVIDIA/k8s-device-plugin: 1a7c1f8a -> 3dd82d32
- 比较 / Release: v0.20.0(CHANGELOG 已含 v0.20.1)| ahead=4 | files=11
### AI 总结重点(源码 diff 为据)
- **健康检查从"每个 parent UUID 记一个设备"改为"记一组设备"**。新增 `placedDevice{parentUUID, device}` 与 `groupByParent()`,`parentToDeviceMap` 类型由 `map[string]*Device` 变为 `map[string][]*Device`。旧代码 `parentToDeviceMap[uuid] = d` 会让同一物理 GPU 的多个副本(time-slicing/MPS 共享、或同卡多 MIG)互相覆盖,Xid 事件到来时只有 map 里幸存的那个被 `unhealthy <-`;新代码遍历该 parent 下**全部**设备逐个标记。

  <details><summary>代码依据 internal/rm/health.go</summary>

  ```diff
  -	parentToDeviceMap := make(map[string]*Device)
  +	placedDevices := make([]placedDevice, 0, len(devices))
  ...
  -		parentToDeviceMap[uuid] = d
  +		placedDevices = append(placedDevices, placedDevice{parentUUID: uuid, device: d})
  ...
  +	parentToDeviceMap := groupByParent(placedDevices)
  ...
  -		d, exists := parentToDeviceMap[eventUUID]
  +		ds, exists := parentToDeviceMap[eventUUID]
  ...
  +		for _, d := range ds {
  +			if d.IsMigDevice() {
  +				if !matchesMigEvent(gi, ci, e.GpuInstanceId, e.ComputeInstanceId) { continue }
  ```
  </details>

- **新增 `matchesMigEvent()` 收敛 MIG 事件匹配**:显式处理 `GPU_INSTANCE_ID_ANY` / `COMPUTE_INSTANCE_ID_ANY` 通配(此前用裸 `0xFFFFFFFF` 常量与 `!=` 比较),GPU 级 Xid(gi/ci=ANY)现能命中该卡上所有 MIG 设备。
### 后续发展方向 [AI]
- 故障域从"单设备"上升到"物理 GPU 共享组":与 v0.20.0 的 packed/distributed 分配策略配合,共享 GPU 的健康语义在往"一荣俱荣一损俱损"靠。证据覆盖 Xid 健康路径,未见分配侧是否也按同组回收。

## kubernetes-sigs/dra-driver-nvidia-gpu: 83b9d60c -> b936bcbc
- 比较 / Release: v0.5.0 | ahead=8 | files=131(多为 CI/mock-NVML 脚手架)
### AI 总结重点(源码 diff 为据)
- **修 ComputeDomain 状态同步竞态**:`cdstatus.go` 新增 `dedupeNodesByName()`,并对 `slices.Concat(fabricNodes, nonFabricNodes)` 结果去重。根因是节点在 clique 间迁移时会同时出现在旧 clique(尚未被并发的 `cleanupClique` 剪除)和新 clique,API server 拒绝 `status.nodes` 含重名项 → 整个 ComputeDomain 状态更新失败。

  <details><summary>代码依据 cmd/compute-domain-controller/cdstatus.go</summary>

  ```diff
  -		newNodes = slices.Concat(fabricNodes, nonFabricNodes)
  +		newNodes = dedupeNodesByName(slices.Concat(fabricNodes, nonFabricNodes))
  ...
  +func dedupeNodesByName(nodes []*nvapi.ComputeDomainNode) []*nvapi.ComputeDomainNode {
  +	seen := make(map[string]struct{}, len(nodes))
  +	... // 保留首次出现,cleanupClique 下个 tick 收敛最终成员
  ```
  </details>

- **剪枝改为 live quorum-consistent 读**:`getNonStaleFabricNodes` 签名加 `ctx, string(cd.UID)`,配合新增 `podMatchesDaemon()`,只有经 API server 实读(`listLivePodsForCD`)确认 daemon pod 真的没了才剪除节点,避免 clique informer 与 pod informer 短暂不同步被误判为节点消失(误删会破坏 IMEX 的 node-index→IP 映射,打断在途 GPU 显存 export/import)。

  <details><summary>代码依据 cmd/compute-domain-controller/cdstatus.go</summary>

  ```diff
  -		fabricNodes = m.getNonStaleFabricNodes(cd.Status.Nodes, fabricPods)
  +		fabricNodes = m.getNonStaleFabricNodes(ctx, string(cd.UID), cd.Status.Nodes, fabricPods)
  +func podMatchesDaemon(pod *corev1.Pod, nodeName, daemonIP string) bool {
  +	if pod.Spec.NodeName != nodeName { return false }
  +	if daemonIP != "" && pod.Status.PodIP != "" && pod.Status.PodIP != daemonIP { return false }
  +	return true
  +}
  ```
  </details>

- **IMEX daemon DNS 引入 sentinel IP**:`dnsnames.go` 把 `IPToDNSNameMap map[string]string` 换成 `[]dnsNameMapping{dnsName, ip}`,给每个 `maxNodesPerIMEXDomain` 槽位都写一条 hosts 记录——空槽填 `127.0.0.2`(sentinelIPAddress)。这样解析始终走本地 NSS files、空槽立即 ECONNREFUSED,避免为缺失的 `/etc/hosts` 条目触发 DNS search-domain 洪泛;模板同步加 `dnsConfig` ndots=1。

  <details><summary>代码依据 cmd/compute-domain-daemon/dnsnames.go + templates/compute-domain-daemon.tmpl.yaml</summary>

  ```diff
  +	sentinelIPAddress = "127.0.0.2"
  -type IPToDNSNameMap map[string]string
  +type dnsNameMapping struct { dnsName string; ip string }
  ...
  +      dnsConfig:
  +        options:
  +          - name: ndots
  +            value: "1"
  ```
  </details>

- `pkg/metrics/computedomain_cluster.go` 给 `computeDomainLastStatus` map 加 `sync.Mutex`,`ObserveComputeDomainStatus`/`ForgetComputeDomain` 现支持多 CD 并行 sync 并发调用。
### 后续发展方向 [AI]
- 本期全在 ComputeDomain/IMEX 多节点 fabric(GB200 NVL 级 NVLink 显存互访)的健壮性:防误删节点、防 DNS 放大、指标并发安全。方向是把多节点 GPU 内存域做成生产可靠的控制面。证据未覆盖任何 CRD 字段增删(`v1beta1` 类型仅被引用未改),纯运行时修复。

## kai-scheduler/KAI-Scheduler: 90f9eb33 -> 6e83bbca
- 比较 / Release: v0.17.2 | ahead=5 | files=59
### AI 总结重点(源码 diff 为据)
- **`Admission` API 新增 `ServiceName *string`**:可覆盖 webhook Service 名与证书 DNS 身份(默认取 admission operand 资源名),带 DNS-1035 校验(`^[a-z]([-a-z0-9]*[a-z0-9])?$`,1–63 字符),CRD `kai.scheduler_configs.yaml` 同步生成。

  <details><summary>代码依据 pkg/apis/kai/v1/admission/admission.go</summary>

  ```diff
  +	// ServiceName overrides the webhook Service name and certificate DNS identity.
  +	// +kubebuilder:validation:MaxLength=63
  +	// +kubebuilder:validation:Pattern=`^[a-z]([-a-z0-9]*[a-z0-9])?$`
  +	ServiceName *string `json:"serviceName,omitempty"`
  ```
  </details>

- **分数 GPU 计算共享模式在 fit 阶段一致校验**:`IsTaskFitOnGpuGroup` 入参从 `*GpuRequirement` 改为完整 `*PodInfo`,使其能读 pod 注解里的 `ComputeSharingMode`(如 SMSharing),fit 判断不再只看显存、还要求计算共享模式兼容。

  <details><summary>代码依据 pkg/scheduler/api/node_info/node_info_test.go</summary>

  ```diff
  -	assert.True(t, node.IsTaskFitOnGpuGroup(&pendingPod.GpuRequirement, gpuGroup))
  +	assert.True(t, node.IsTaskFitOnGpuGroup(pendingPod, gpuGroup))
  +// TestIsTaskFitOnGpuGroupRequiresCompatibleComputeSharingMode:
  +// SMSharing 组内,未标注 SMSharing 的 task 判 false,标注后判 true
  ```
  </details>

- **greedy GPU 匹配换线段树**:`idle_gpus/common.go` 的 `greedyMatchRequirements` 从每个需求线性扫全部 holder(`virtuallyAllocated` map)改为 `maxSegmentTree` + `firstAtLeast(required)`/`update`,并加 `len(holders)>=len(requirements)` 快速通过分支——把 O(需求×holder) 降到近 O(需求×log holder)。

  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/accumulated_scenario_filters/idle_gpus/common.go</summary>

  ```diff
  -	virtuallyAllocated := make(map[K]float64, len(holders))
  -	for _, holder := range holders { ... 线性扫 ... }
  +	tree := newMaxSegmentTree(totals)
  +	index, found := tree.firstAtLeast(required)
  +	if !found { return false }
  +	allocated[index] += required
  +	tree.update(index, totals[index]-allocated[index])
  ```
  </details>

- **verbose 日志惰性化**:大批 `log.InfraLogger.V(n).Infof(...)` 包进 `.V(n).Do(func(){...})`(node_info.go / gpu_sharing_node_info.go / job_info.go / cluster_info.go 等),日志级别未开时跳过参数格式化;另 Dockerfile 从 distroless 换 scratch 基础镜像。
### 后续发展方向 [AI]
- 分数 GPU 共享(fractional + SMSharing 计算模式)是 KAI 对标 NVIDIA GPU 复用的主线:本期把"共享模式兼容性"从分配后校验前移到 fit/排序阶段一致执行,配合线段树给大规模分数匹配提速。证据覆盖 fit 路径与 filter 性能,未见 SMSharing 与 MPS/time-slicing 的运行时落地关系。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- **NVIDIA/gpu-operator**:仅 chore——CODEOWNERS 改用 gh team(`@NVIDIA/gpu-operator-dev`)、README 徽章 GitLab→GitHub Actions/coveralls,以及把 mig-manager 镜像 pin 从 v0.15.0 升到 v0.15.1(CSV + values.yaml),无控制器逻辑改动,`clusterpolicy_types.go` 未动。
- **NVIDIA/mig-parted**:仅 bump/CI,Release v0.15.0→v0.15.1(patch,非跨档),即 gpu-operator 上面 pin 的那版。
- **NVIDIA/gpu-driver-container**:无新提交。
- **NVIDIA/dcgm-exporter**:无新提交(Release 4.8.4)。
- **NVIDIA/DCGM**:无新提交(master)。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=50e3b56ccfbaa530f185d97c6d21c1055c426747 branch=main release=v26.7.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=84e2c2c182bfa0b2edab4fdca27e5197faba0ca7 branch=main release=v1.20.1 scanned=2026-09-23 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=575c9011c4fa4b94200c56818b1f97cdbcf610af branch=main release=— scanned=2026-09-23 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=3dd82d32e62c4b956a85ed765edb0a7b86d83737 branch=main release=v0.20.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=b936bcbce55e299dda65c25555867d200668ff72 branch=main release=v0.5.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-09-23 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-23 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2fb707148a34a364eb44f4ca37e2be6859eb2ce3 branch=main release=v0.15.1 scanned=2026-09-23 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=6e83bbcaf9a9b5c6ba2c7cfda3068cf7baa19ce1 branch=main release=v0.17.2 scanned=2026-09-23 -->
