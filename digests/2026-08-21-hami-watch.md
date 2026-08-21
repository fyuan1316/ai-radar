# HAMi diff 雷达 2026-08-21

## 摘要
- HAMi 主仓新增**在线单卡 cordon** 能力(`hami.io/device-cordon` 节点注解):把某块物理 GPU 从新分配中摘除、又不驱逐已在跑的 Pod,即时生效、无需重启 device-plugin,是运维层的重要新能力(#2298)。
- HAMi-core 软隔离共享内存区的控制字段(显存上限/SM 上限/最近内核时间/利用率开关)全部改为 **atomic 读写**,修掉 CUDA hook 与调度侧并发改写这些切分参数的数据竞争(#2179)。
- 昇腾 vNPU 侧(ascend-device-plugin)修掉一个可用性坑:设备缓存原来只在有 unhealthy 设备时刷新,导致设备恢复后节点永远卡在 Unhealthy、只能重启插件;现改为每个 watch tick 都刷新并按指纹变化上报 kubelet。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增 `hami.io/device-cordon` 节点注解,实现单卡在线 cordon(排空维护不重启、不影响存量 Pod)。证据:`pkg/device/nvidia/device.go` 新增常量 `DeviceCordonAnnotation` + `cordonedDevices()`。https://github.com/Project-HAMi/HAMi/pull/2298
- Project-HAMi/HAMi [新能力] MIG 支持一块 GPU 上并存多个 MIG 实例(#2724),并加入 RTX PRO 6000 的 MIG E2E preset(#2725),硬切分路径覆盖面扩大。https://github.com/Project-HAMi/HAMi/pull/2724
- Project-HAMi/ascend-device-plugin [版本跨档] 出现首个打包 Release `ascend-device-plugin-0.1.0`(上期锚点 release=—),昇腾 vNPU 插件进入可发布阶段。https://github.com/Project-HAMi/ascend-device-plugin/releases/tag/ascend-device-plugin-0.1.0

## Project-HAMi/HAMi: 949f78e6 -> f06e7e3c
- 比较: 949f78e634f67294e9c8f843c25b806837944532 -> f06e7e3c | ahead=21 | files=46 | Release: v2.9.0
- 比较页:https://github.com/Project-HAMi/HAMi/compare/949f78e634f67294e9c8f843c25b806837944532...f06e7e3cac2e7fc9594ebb50c803000b95455663

### AI 总结重点(源码 diff 为据)
- **新增在线单卡 cordon**:在 `pkg/device/nvidia/device.go` 定义节点注解 `hami.io/device-cordon`(逗号分隔 GPU UUID),`cordonedDevices()` 把它解析成 UUID 集合供 `Fit` 排除;注释明确其语义是"live, per-GPU equivalent of `kubectl cordon`",即时生效、不重启 device-plugin、不影响已在这些卡上运行的 Pod——区别于需要重启的 `FilterDeviceToRegister`。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +	// DeviceCordonAnnotation is a node annotation holding a comma-separated list of
  +	// GPU UUIDs to exclude from new allocations, without affecting pods already
  +	// running on those devices. It's a live, per-GPU equivalent of `kubectl cordon`;
  +	// unlike FilterDeviceToRegister, it takes effect immediately and needs no
  +	// device-plugin restart.
  +	DeviceCordonAnnotation = "hami.io/device-cordon"
  ...
  +func cordonedDevices(nodeInfo *device.NodeInfo) map[string]struct{} {
  +	cordoned := make(map[string]struct{})
  +	if nodeInfo == nil || nodeInfo.Node == nil { return cordoned }
  +	raw, ok := nodeInfo.Node.Annotations[DeviceCordonAnnotation]
  +	if !ok || strings.TrimSpace(raw) == "" { return cordoned }
  +	for uuid := range strings.SplitSeq(raw, ",") {
  +		if uuid = strings.TrimSpace(uuid); uuid != "" { cordoned[uuid] = struct{}{} }
  +	}
  +	return cordoned
  +}
  ```
  </details>
- **NVIDIA 显存请求做 int32 溢出/非法值拒绝**:`GenerateResourceRequests` 原来把 `mem.AsInt64()` 直接乘以 `MemoryFactor` 再 `int()` 截断,负值/超 int32 会静默欠分配;新逻辑用 `factor := max(MemoryFactor,1)`,遇到解析失败、负数或 `memnums > MaxInt32/factor` 直接 `return device.ContainerDeviceRequest{}` 并 ErrorS 日志,宁可拒绝也不静默少给显存。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -				memnums, ok := mem.AsInt64()
  -				if ok {
  -					if dev.config.MemoryFactor > 1 {
  -						memnums = memnums * int64(dev.config.MemoryFactor)
  -					}
  -					memnum = int(memnums)
  +				memnums, parsed := mem.AsInt64()
  +				factor := max(int64(dev.config.MemoryFactor), 1)
  +				if !parsed || memnums < 0 || memnums > int64(math.MaxInt32)/factor {
  +					klog.ErrorS(nil, "nvidia memory request is not a plain integer within the int32 range; rejecting to avoid silent under-allocation", "container", ctr.Name)
  +					return device.ContainerDeviceRequest{}
  +				}
  +				if factor > 1 { memnums = memnums * factor }
  +				memnum = int(memnums)
  ```
  </details>
- **软隔离共享内存区改 atomic 读写**(`pkg/monitor/nvidia/v1/spec.go`):切分控制字段 `limit`(显存上限)、`smLimit`(SM/算力上限)、`lastKernelTime`、`recentKernel`、`utilizationSwitch` 的 get/set 从裸读写改为 `atomic.Load/Store`。这些字段是 HAMi-core CUDA hook 与 vGPUmonitor 共享的时分/显存切分参数,裸读写在并发下有撕裂/竞争风险,atomic 化保证跨进程共享区读写一致。
  <details><summary>代码依据 pkg/monitor/nvidia/v1/spec.go</summary>

  ```diff
  -func (s Spec) DeviceMemoryLimit(idx int) uint64 { return s.sr.limit[idx] }
  +func (s Spec) DeviceMemoryLimit(idx int) uint64 { return atomic.LoadUint64(&s.sr.limit[idx]) }
   func (s Spec) SetDeviceMemoryLimit(l uint64) {
   	n := min(s.sr.num, maxDevices)
  -	for idx := range n { s.sr.limit[idx] = l }
  +	for idx := range n { atomic.StoreUint64(&s.sr.limit[idx], l) }
   }
  -func (s Spec) GetRecentKernel() int32 { return s.sr.recentKernel }
  +func (s Spec) GetRecentKernel() int32 { return atomic.LoadInt32(&s.sr.recentKernel) }
  ```
  </details>
- **调度器一批健壮性修复**(`pkg/scheduler/scheduler.go`):
  (1) 部分锁回滚(#2626)——`lockAllDevices` 先对设备 key 排序、逐个 lock 记入 `acquired`,任一失败可回滚已获取的锁,消除部分加锁残留;
  (2) 快照缺节点不再缓存 nil NodeUsage(#2436)——`overallnodeMap[node.ID]` 取不到时标记 `failedNodes[nodeID]="node usage unavailable"` 并 continue,而非把 nil 写进 `cachenodeMap`;
  (3) 陈旧分配探测(#2618)——统计 Pod 已分配设备时若 UUID 在节点设备列表里 `!matched`,ErrorS 记 "pod allocated unknown or stale device resources";
  (4) 设备发现出错也继续对账健康(#2568)——`register` 中 `GetNodeDevices` 出错不再直接 continue,而是补记 error 并继续走 `CheckHealth`。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	for _, val := range device.GetDevices() {
  +	devs := device.GetDevices()
  +	keys := make([]string, 0, len(devs))
  +	for k := range devs { keys = append(keys, k) }
  +	sort.Strings(keys)
  +	acquired := make([]device.Devices, 0, len(keys))
  +	for _, k := range keys {
  +		val := devs[k]
  ...
  -		cachenodeMap[node.ID] = overallnodeMap[node.ID]
  +		usage, ok := overallnodeMap[node.ID]
  +		if !ok {
  +			failedNodes[nodeID] = "node usage unavailable"
  +			continue
  +		}
  +		cachenodeMap[node.ID] = usage
  +					if !matched {
  +						klog.ErrorS(nil, "pod allocated unknown or stale device resources", "pod", klog.KRef(p.Namespace, p.Name), "nodeID", p.NodeID, "gpuUUID", udevice.UUID)
  +					}
  ```
  </details>
- **昆仑芯 use/nouse-gpuuuid 注解生效**(`pkg/device/kunlun/device.go`,#2577):`Fit` 原来直接 `graghSelect(devices, request, FitXPU)`,UUID 约束不起作用;新逻辑包一层 `fitFn`,在 `graghSelect` 内对每张卡跑 `CheckUUID`(通用 + 昆仑专用两组注解),不匹配记 `uuidMismatches` 并返回 `CardUUIDMismatch` reason——UUID 约束必须在 fitFn 里判断而非预过滤,因为 graghSelect 依赖设备在 slice 中的位置算拓扑。
  <details><summary>代码依据 pkg/device/kunlun/device.go</summary>

  ```diff
  -	alloc := graghSelect(devices, request, FitXPU)
  +	uuidMismatches := make(map[string]bool)
  +	fitFn := func(d *device.DeviceUsage, r device.ContainerDeviceRequest) bool {
  +		if !device.CheckUUID(pod.GetAnnotations(), d.ID, UseUUIDAnno, NoUseUUIDAnno, kl.CommonWord()) ||
  +			!device.CheckUUID(pod.GetAnnotations(), d.ID, KunlunUseUUID, KunlunNoUseUUID, kl.CommonWord()) {
  +			uuidMismatches[d.ID] = true
  +			return false
  +		}
  +		return FitXPU(d, r)
  +	}
  +	alloc := graghSelect(devices, request, fitFn)
  ```
  </details>
- **AWS Neuron 请求校验收紧**(`pkg/device/awsneuron/device.go`,#2674):`MutateAdmission` 从"只判断有没有请求"改为真正校验数量——新增 `validateResourceRequest`(整数、>0、不超上限)与 `resourceQuantity`(Limits 缺则回落 Requests),并对 core 请求走 `splitCoreRequest` 转换路径,防止奇数 NeuronCore 被截断;上限 `maxCoresPerNeuronDevice=2`、`maxAWSNeuronDeviceCount=MaxInt32`。
  <details><summary>代码依据 pkg/device/awsneuron/device.go</summary>

  ```diff
  -	_, ok := ctr.Resources.Limits[corev1.ResourceName(dev.resourceCountName)]
  -	if !ok { _, ok = ctr.Resources.Limits[corev1.ResourceName(dev.resourceCoreName)] }
  -	return ok, nil
  +	count, countRequested := resourceQuantity(ctr, corev1.ResourceName(dev.resourceCountName))
  +	if countRequested {
  +		_, err := validateResourceRequest(count, dev.resourceCountName, maxAWSNeuronDeviceCount)
  +		return err == nil, err
  +	}
  +	core, coreRequested := resourceQuantity(ctr, corev1.ResourceName(dev.resourceCoreName))
  +	if !coreRequested { return false, nil }
  +	coreCount, err := validateResourceRequest(core, dev.resourceCoreName, maxAWSNeuronCoreCount)
  +	if err != nil { return false, err }
  +	if _, _, err := dev.splitCoreRequest(coreCount); err != nil { return false, err }
  +	return true, nil
  ```
  </details>

### 后续发展方向 [AI]
- **运维态设备生命周期正在补齐**:在线 cordon(#2298)+ 陈旧分配探测(#2618)+ 设备发现失败仍对账健康(#2568),三者叠加,说明 HAMi 正把"单卡级、不停机"的运维原语补进调度器——对我们产品的启示:GPU 池的排空/维护/故障隔离若还依赖重启 device-plugin 或打 taint,可对标 `hami.io/device-cordon` 这种即时、卡粒度、不驱逐存量的做法。证据只覆盖 nvidia 设备与 scheduler 主流程,未见该注解在其它厂商(kunlun/ascend)device 实现里的对称落地。
- **软切分参数并发正确性被系统性加固**:spec.go 全字段 atomic 化(#2179)针对的是 HAMi-core 共享内存切分控制面,方向是把时分/显存限额的读写做成无锁并发安全——证据只在 monitor/nvidia/v1 这一版 spec,未见 v0 或 HAMi-core C 侧是否同步(本期 HAMi-core 仓无新提交)。
- **多厂商 XPU 的请求校验在向 NVIDIA 看齐**:kunlun UUID 注解生效、awsneuron 数量/core 校验、iluvatar/mthreads int32 溢出拒绝(#2285,见提交列表),都是把各厂商 device 实现的准入校验补到同一水位——方向是减少"请求非法但静默分配"的类问题。证据为各 device.go 的 diff,未逐一展开非 nvidia/awsneuron/kunlun 的厂商。

## Project-HAMi/ascend-device-plugin: 1cf92f2f -> 4b977f92
- 比较: 1cf92f2ff25cebfe6f6752c1d50bbb729fb0683e -> 4b977f92 | ahead=2 | files=3 | Release: ascend-device-plugin-0.1.0
- 比较页:https://github.com/Project-HAMi/ascend-device-plugin/compare/1cf92f2ff25cebfe6f6752c1d50bbb729fb0683e...4b977f92853a9e797f7d219204e575524e740ee0

### AI 总结重点(源码 diff 为据)
- **设备缓存改为每 tick 刷新,修复"设备恢复后永久 Unhealthy"**(`internal/server/register.go`):`watchAndRegister` 原来只在 `GetUnHealthIDs()` 非空时才 `UpdateDevice()` 刷新缓存;若设备在两个 tick 之间恢复,缓存永远保持旧状态,kubelet 停留在启动时(驱动未初始化完常全为 Unhealthy)的设备表,只能重启插件解脱。新逻辑每 tick 都 `UpdateDevice()`,并用 `deviceFingerprint()`(UUID+健康位拼串)判断设备集是否变化,变化才通过 `healthCh` 上报 kubelet;上报走 `select` 加 `healthUpdateSendTimeout=5s` 超时,防止没有 ListAndWatch 消费者时卡死整个 loop(连带卡住 HAMi 节点注册)。
  <details><summary>代码依据 internal/server/register.go</summary>

  ```diff
  -		unhealthy := ps.mgr.GetUnHealthIDs()
  -		if len(unhealthy) > 0 {
  -			if err := ps.mgr.UpdateDevice(); err != nil { ... continue }
  -			ps.healthCh <- unhealthy[0]
  -		}
  +		// Refresh the cached device view on every tick.
  +		if err := ps.mgr.UpdateDevice(); err != nil { ... continue }
  +		if fp := ps.deviceFingerprint(); fp != ps.lastPublishedDevices {
  +			select {
  +			case ps.healthCh <- 0:
  +				ps.lastPublishedDevices = fp
  +			case <-ps.stopCh:
  +				return
  +			case <-time.After(healthUpdateSendTimeout):
  +				klog.Warningf("no ListAndWatch consumer accepted the device update, retrying later")
  +			}
  +		}
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾 vNPU 插件在打磨"设备健康态与 kubelet 的同步语义"**:引入 `lastPublishedDevices` 指纹 + 有界上报,是把 device-plugin 的健康对账做成幂等、可恢复、不阻塞的——方向是提升 vNPU 节点在驱动慢启动/设备抖动下的自愈能力。配合首个 0.1.0 Release,昇腾这条 HAMi×Ascend 交汇线正走向可发布。证据仅覆盖 watchAndRegister 与 server 启动路径,未见 vNPU 切分(VDeviceCount)本身逻辑变动。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=f06e7e3cac2e7fc9594ebb50c803000b95455663 branch=master release=v2.9.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-21 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-21 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-21 -->
