# HAMi diff 雷达 2026-10-13

## 摘要
- **HAMi 主仓一个方向性改动落地:整卡(whole-GPU)工作负载绕过 HAMi-core CUDA hook,改走 NVML 直采监控(#3112)。** 这是软切分边界的一次收缩——HAMi 从"所有 GPU 容器一律挂 libvgpu.so 拦截"转向"只有真分片才拦截,整卡独占直通零开销",新增独立文件 `pkg/monitor/nvidia/wholegpu.go`(+512)补齐整卡容器的 per-pod 指标。
- AMD 侧两处:新增 `amd.com/link-bind` 注解按 XGMI 链路做多卡 clique 亲和调度(#3191);修复无 type 的 AMD 注册会被调度器子串匹配拒绝的 bug(#3212)。
- RemoteGPU(Lupine)修复 NotReady server 相关的两类正确性问题(#3184):NotReady 节点不再接新分配、但其上运行 Pod 的预留不被误释放。其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI)本期无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增 `pkg/monitor/nvidia/wholegpu.go`:整卡容器停写 libvgpu 缓存后,由 monitor 用 NVML 合成 per-pod 指标;配套 device plugin 对整卡分配自动注入 `CUDA_DISABLE_CONTROL=true` 并跳过 `ld.so.preload` 挂载。证据:`pkg/monitor/nvidia/wholegpu.go`、`pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go`。 https://github.com/Project-HAMi/HAMi/pull/3112
- Project-HAMi/HAMi [新能力] AMD 新增 `amd.com/link-bind` 注解(常量 `AMDLinkBind`),多卡请求按 XGMI 链路做 clique 搜索亲和调度。证据:`pkg/device/amd/device.go`。 https://github.com/Project-HAMi/HAMi/pull/3191

## Project-HAMi/HAMi: 015b302b -> c5ca416f
- 比较: 015b302b1d1a63c74f6e9b58dca2b8a7beffa1e7 -> c5ca416f | ahead=7 | files=17 | Release: v2.10.0
- 比较页:https://github.com/Project-HAMi/HAMi/compare/015b302b1d1a63c74f6e9b58dca2b8a7beffa1e7...c5ca416f05a75ad54986b7cf2f05e633ab3f92b7

### AI 总结重点(源码 diff 为据)

- **整卡分配绕开 HAMi-core 拦截,改用 CUDA_DISABLE_CONTROL 环境变量 + 跳过 preload 挂载。** device plugin 的 `Allocate` 新增:当用户未显式设过 `CUDA_DISABLE_CONTROL`、且本节点满足 `wholeGPUDisableHAMiCoreAllowed()`(`DeviceMemoryScaling==1 && DeviceCoreScaling==1`,即无超分)、且 `isWholeGPUAllocation()`(每块设备满显存、cores 为 0 或 100)时,注入 `CUDA_DISABLE_CONTROL=true` 并置 `found=true` 以跳过 `/etc/ld.so.preload` 的 libvgpu 挂载。含义:整卡独占不再走 CUDA hook,软切分拦截从"全量 GPU 容器"收窄为"仅分片容器"。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  +				// auto-inject CUDA_DISABLE_CONTROL=true only when the user hasn't
  +				// set it explicitly and every allocated device is a whole GPU
  +				if !userSpecified && plugin.wholeGPUDisableHAMiCoreAllowed() {
  +					isWhole := isWholeGPUAllocation(devreq, plugin.rm)
  +					if isWhole {
  +						response.Envs["CUDA_DISABLE_CONTROL"] = "true"
  +						// mark found so the ld.so.preload mount below is skipped
  +						found = true
  +					}
  +				}
  +func (plugin *NvidiaDevicePlugin) wholeGPUDisableHAMiCoreAllowed() bool {
  +	return wholeGPUDisableHAMiCore &&
  +		*plugin.schedulerConfig.DeviceMemoryScaling == 1 &&
  +		*plugin.schedulerConfig.DeviceCoreScaling == 1
  +}
  +func isWholeGPUAllocation(devreq device.ContainerDevices, rm rm.ResourceManager) bool {
  +	...
  +		if uint64(dev.Usedmem) != totalMiB || (dev.Usedcores != 0 && dev.Usedcores != nvidia.WholeGPUUsedCores) {
  +			return false
  +		}
  ```
  </details>

- **整卡容器停写 libvgpu 缓存,monitor 改从 NVML 直接合成 per-pod 指标。** 新增文件 `pkg/monitor/nvidia/wholegpu.go`,开关变量 `wholeGPUDisableHAMiCore = os.Getenv("DISABLE_HAMI_CORE_FOR_WHOLE_GPU")=="true"`;`ContainerLister` 新增 `wholeGPU *wholeGPUState` 字段,`Update()` 在加锁前预取(`prefetchWholeGPUInputs`,因其会跑 node-registry GET 不能持锁)、加锁后 `reconcileWholeGPULocked(inputs)`。对"整卡判定"用三态裁决 `wholeGPUVerdict`(notWholeGPU/confirmedWholeGPU/indeterminate),registry miss 是伪造敏感路径、带重试窗口后锁定为 notWholeGPU——即判整卡要靠节点设备注册表而非仅凭 Pod 注解,防伪造。
  <details><summary>代码依据 pkg/monitor/nvidia/cudevshr.go + wholegpu.go</summary>

  ```diff
  + // wholeGPU holds the whole-GPU reconciliation state; nil unless
  + // wholeGPUDisableHAMiCore is set.
  + wholeGPU *wholeGPUState
  ...
  + var inputs *wholeGPUInputs
  + if wholeGPUDisableHAMiCore {
  +     inputs = l.prefetchWholeGPUInputs(pods)   // node-registry GET,不能持锁
  + }
    l.mutex.Lock()
  + if inputs != nil {
  +     l.reconcileWholeGPULocked(inputs)
  + }
  ```
  ```diff
  + // wholegpu.go
  + var wholeGPUDisableHAMiCore = os.Getenv("DISABLE_HAMI_CORE_FOR_WHOLE_GPU") == "true"
  + const ( notWholeGPU wholeGPUVerdict = iota; confirmedWholeGPU; indeterminate )
  + const ( causeNotIndeterminate indeterminateCause = iota; causeRegistryMiss; causePhysUnreadable )
  ```
  </details>

- **新增"整卡"标识常量与长期可读注解,供 device plugin 和 monitor 共享。** `pkg/device/nvidia/device.go` 新增 `AllocatedDevicesAnnotation = "hami.io/vgpu-devices-allocated"`(与 `-to-allocate` 不同,Allocate 后不清除、整个 Pod 生命周期可读)与 `WholeGPUUsedCores int32 = 100`(整卡在 allocated 注解里记的 cores 百分比标记)。`InitNvidiaDevice` 把 `device.SupportDevices[NvidiaGPUDevice]` 的字面量替换为该常量。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  + AllocatedDevicesAnnotation = "hami.io/vgpu-devices-allocated"
  + // WholeGPUUsedCores is the cores percentage recorded in the
  + // vgpu-devices-allocated annotation when a container holds the entire GPU.
  + WholeGPUUsedCores int32 = 100
  ...
  -   device.SupportDevices[NvidiaGPUDevice] = "hami.io/vgpu-devices-allocated"
  +   device.SupportDevices[NvidiaGPUDevice] = AllocatedDevicesAnnotation
  ```
  </details>

- **AMD 新增 XGMI link-bind 多卡亲和调度。** 新注解常量 `AMDLinkBind = "amd.com/link-bind"`;`Fit()` 当 `assertLinkBind(annos) && request.Nums>=2` 时,要求所选 GPU 组是 XGMI 互联的 clique——因贪心会被首选带偏,故以每块卡为起点各试一遍(`ordered := append(slices.Clone(devices[start:]), devices[:start]...)`)。`xgmiLinked`/`hasPeer` 从注册表 `custominfo.xgmiPeers`(amd-device-plugin 发布,按 `pciBDF` 匹配)判互联。注释自标"贪心对 4/8 卡够用,规模更大再上精确 clique 搜索"。
  <details><summary>代码依据 pkg/device/amd/device.go</summary>

  ```diff
  + // AMDLinkBind asks for every GPU of a multi-GPU request to be linked to all the others over XGMI.
  + AMDLinkBind     = "amd.com/link-bind"
  + func xgmiLinked(a, b *device.DeviceUsage) bool { return hasPeer(a, b) && hasPeer(b, a) }
  + func hasPeer(from, to *device.DeviceUsage) bool {
  +   bdf, _ := to.CustomInfo["pciBDF"].(string)
  +   ... from.CustomInfo["xgmiPeers"] ...
  + func (amddevice *AMDDevices) Fit(...) {
  +   if !assertLinkBind(pod.GetAnnotations()) || request.Nums < 2 { return amddevice.fit(..., false) }
  +   for start := range devices {
  +     ordered := append(slices.Clone(devices[start:]), devices[:start]...)
  +     ok, devs, reason := amddevice.fit(ordered, request, pod, nodeinfo, allocated, true)
  ```
  </details>

- **修复:无 type 的 AMD 注册会被调度器拒绝整台节点。** `GetNodeDevices` 对每块卡补默认:`if nodedevices[idx].Type == "" { nodedevices[idx].Type = AMDDevice }`。原因注释:调度器按注册 type 的子串为请求挑卡,空 type 永远匹配不上、节点被判为无设备。
  <details><summary>代码依据 pkg/device/amd/device.go</summary>

  ```diff
  + // a registration without a type would never match and the node would be rejected as having no device.
  + if nodedevices[idx].Type == "" {
  +     nodedevices[idx].Type = AMDDevice
  + }
  ```
  </details>

- **RemoteGPU(Lupine)两处正确性修复:NotReady server 不接新分配、但不误释放在跑 Pod 的预留。** `pool.refresh` 新增 `isReadyLupineNode(n)`(缺失 Ready condition 按 Unknown 处理、不算可用),NotReady 节点跳过加入可分配 endpoints;但预留重建的判据从 `len(endpoints)==0` 改为 `len(nodes)==0`——只要 server Node 还在就继续重建预留,防止 NotReady server 让其运行 Pod 的分配"看起来被释放"。`askServers` 新增 `listedServers` 入参:只丢弃 Kubernetes 已不再返回的 Node 的 busy 记录,临时 NotReady 的旧占用予以保留。
  <details><summary>代码依据 pkg/device/remotegpu/pool.go</summary>

  ```diff
  + listedServers[n.Name] = struct{}{}
  + if !isReadyLupineNode(n) {
  +     klog.V(4).InfoS("remotegpu: skipping unavailable lupine server", "node", n.Name)
  +     continue
  + }
  - if len(endpoints) == 0 {
  + if len(nodes) == 0 {
        inUse = map[string]struct{}{}
  - busy := askServers(ctx, endpoints, previousBusy)
  + busy := askServers(ctx, endpoints, previousBusy, listedServers)
  + func isReadyLupineNode(n *corev1.Node) bool { ... condition.Type == corev1.NodeReady ... }
  ```
  </details>

- **Chart 文档化(#3208/#3209/#3216,非行为变更):** `values.yaml`/`README.md` 为 global 段、`devices.nvidia`、`devices.mthreads` 补齐逐项 `# --` 注释说明;README 删掉旧的分散参数表、统一到自动生成表。同时 values.yaml 新增 `devicePlugin.monitor.disableHAMiCoreForWholeGPU: true`(默认开),即上面整卡绕 hook 能力默认启用。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  + ## @param devicePlugin.monitor.disableHAMiCoreForWholeGPU disable the HAMi-core hook for whole-GPU containers; the monitor reads their metrics from NVML instead
  + disableHAMiCoreForWholeGPU: true
  ```
  </details>

### 后续发展方向 [AI]
- **软切分"按需拦截"是明确方向。** 整卡绕 hook 这条路证据充分(server.go 注入逻辑 + wholegpu.go 直采 + 默认开关 on),HAMi 正把 libvgpu.so 的拦截成本限定在真正分片的容器上,整卡独占做零开销直通。对我们产品的启示:若自家也用 CUDA hook 做显存/算力隔离,整卡独占场景的拦截开销与 NVML 直采监控路径值得对齐——这是 HAMi 在把"软隔离 vs 硬直通"做成同一调度器下的自动分流。证据只覆盖 NVIDIA 路径与 monitor 侧合成,未见 HAMi-core 仓对应改动(本期 HAMi-core EMPTY),也未展开三态裁决里 `causePhysUnreadable`/重试窗口的完整实现(hunk 截断)。
- **多卡拓扑亲和在向厂商特性下沉。** AMD 侧继 NUMA-bind 后再加 XGMI link-bind clique 调度,判据来自 device-plugin 发布的 `xgmiPeers`/`pciBDF` 注册信息;方向是 HAMi 调度器吸收各厂商互联拓扑做多卡组亲和。证据仅覆盖 AMD 的贪心 clique 实现(自注明规模大时才上精确搜索),未见 NVIDIA NVLink 侧对应路径。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=c5ca416f05a75ad54986b7cf2f05e633ab3f92b7 branch=master release=v2.10.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5ab7da10f72c72b7c158bb2d81f5148ec0af6392 branch=main release=— scanned=2026-10-13 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-13 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf890f96118f38a85f71d31da2e74ca95aeb1a0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=09f0b75b0773c2caf835933936f0301f7efc248c branch=main release=v1.3.0 scanned=2026-10-13 -->
