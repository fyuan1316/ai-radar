# HAMi diff 雷达 2026-09-05

## 摘要
- HAMi 主仓给 `ContainerDevice` 加了 **`Slots` 字段并贯通注解编解码**:多 slot 的 DRS profile(Enflame)在 annotation round trip 后不再丢失占用槽数,计账、Fit、initContainer 峰值三处统一按 slot 数算(#2877)。这是本期唯一带结构级/编码格式变化的改动。
- vGPUmonitor 反馈路径把 `UtilizationPerDevice` 从 `[]int` 切片改为 **`map[int]int` 按优先级为键**——优先级来自容器可读写的共享内存,任意 int32 都不该再当切片下标,兼具健壮性/安全硬化意味(#2931)。
- 其余为 kunlun calcscore 排序真正生效的修复(#2924)、dashboard 新增"分配 vs 宿主已用显存"面板(#2922),另 4 个子仓(HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI)本期无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力/编码格式变更] `ContainerDevices` 注解新增可选第 5 字段 `Slots`(仅 >1 时写出,兼容旧 4 字段),让多 slot DRS 分配跨注解往返不丢占用。证据:`pkg/device/devices.go` `EncodeContainerDevices`/`DecodeContainerDevices`。 https://github.com/Project-HAMi/HAMi/pull/2877
- Project-HAMi/HAMi [修复/健壮性] vGPUmonitor `UtilizationPerDevice` 由 slice 改 map,按 priority 为键,消除"容器可写共享内存里的优先级被当切片下标"的越界/超量分配面。证据:`cmd/vGPUmonitor/feedback.go`。 https://github.com/Project-HAMi/HAMi/pull/2931
- Project-HAMi/HAMi [修复] Enflame `Fit` 从"只要有 1 槽空闲"收紧为"整个 profile 的 slot 数都要放得下"。证据:`pkg/device/enflame/device.go` `dev.Count-dev.Used < profileSlices`。 https://github.com/Project-HAMi/HAMi/pull/2877

## Project-HAMi/HAMi: f47cd28a -> 42cdc782
- 比较: f47cd28ac603e9bb1a6bbfccfa310cc4747f1af4 -> 42cdc782 | ahead=6 | files=18 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/f47cd28ac603e9bb1a6bbfccfa310cc4747f1af4...42cdc782

### AI 总结重点(源码 diff 为据)

- **`ContainerDevice` 新增 `Slots` 字段,成为 DRS "占几个切片"的权威来源**。Enflame 侧新抽 `sliceCount(ctr)`:优先读 `ctr.Slots`,为 0 才回退到 `CustomInfo["drsSlice"]`,再兜底 1;`AddResourceUsage` 直接用它累加 `n.Used`。`Fit` 里把 `profile.Size` 一次性转成 `profileSlices` 并写进新分配的 `Slots`,注释点明"注解往返会丢 CustomInfo,靠 Slots 保住计数"。
  <details><summary>代码依据 pkg/device/enflame/device.go</summary>

  ```diff
  +// sliceCount returns the DRS slices an entry occupies. Slots is authoritative;
  +// CustomInfo is the fallback for entries built before Fit recorded Slots.
  +func sliceCount(ctr *device.ContainerDevice) int32 {
  +	if ctr == nil { return 1 }
  +	slice := ctr.Slots
  +	if slice <= 0 {
  +		slice = clampToInt32(readCustomInfoInt(ctr.CustomInfo, "drsSlice"))
  +	}
  +	if slice <= 0 { return 1 }
  +	return slice
  +}
  -func (dev *EnflameDevices) AddResourceUsage(...) error {
  -	slice := clampToInt32(readCustomInfoInt(ctr.CustomInfo, "drsSlice"))
  -	...
  -	n.Used = clampToInt32(int(n.Used) + int(slice))
  +	n.Used = clampToInt32(int(n.Used) + int(sliceCount(ctr)))
  ...
  +				// A DRS profile consumes profile.Size slices; recording it here keeps
  +				// the count across the annotation round trip that drops CustomInfo.
  +				Slots: profileSlices,
  ```
  </details>

- **`Fit` 的容量判断从"是否还有 1 槽"改为"整段 profile 放得下"**:旧 `dev.Count <= dev.Used` 只保证有余量,3 槽 profile 在只剩 1 槽时会误判可放;新逻辑要求 `dev.Count-dev.Used >= profileSlices`,并把 `request slices` 打进日志。
  <details><summary>代码依据 pkg/device/enflame/device.go</summary>

  ```diff
  -		if dev.Count <= dev.Used {
  +		// The whole profile has to fit: a 3 slice profile needs 3 free slices,
  +		// not just one.
  +		if dev.Count-dev.Used < profileSlices {
   			reason[common.CardTimeSlicingExhausted]++
  -			klog.V(5).InfoS(..., "count", dev.Count, "used", dev.Used)
  +			klog.V(5).InfoS(..., "count", dev.Count, "used", dev.Used, "request slices", profileSlices)
  ```
  </details>

- **注解编解码把 `Slots` 作为向后兼容的可选第 5 字段**:`Slots>1` 才多写一段,单槽分配保持历史 4 字段编码;解码端第 5 字段"解析失败就忽略"而非拒绝整条注解,理由注释写明"丢整条注解比少算 1 槽更糟"。这是一次注解 wire-format 扩展,但对旧 reader 透明。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
  +		if val.Slots > 1 {
  +			fmt.Fprintf(&builder, "%s,%s,%d,%d,%d%s", val.UUID, val.Type, val.Usedmem, val.Usedcores, val.Slots, OneContainerMultiDeviceSplitSymbol)
  +			continue
  +		}
   		fmt.Fprintf(&builder, "%s,%s,%d,%d%s", ...)
  ...
  +		if len(tmpstr) >= 5 {
  +			if devslots, err := strconv.ParseInt(tmpstr[4], 10, 32); err == nil && devslots >= 0 {
  +				tmpdev.Slots = int32(devslots)
  +			} else {
  +				klog.V(5).Infof("ignoring unusable slots field %q in segment %q", tmpstr[4], val)
  +			}
  +		}
  ```
  </details>

- **initContainer 计账全面改用 `slotsOf(dev)=max(dev.Slots,1)` 替代硬编码 `+1`**:sidecar 累计、峰值(peak)、稳态(SteadyState)三处占槽数都从"每容器 1 槽"改为"按实际 slot 数",与上面 `Slots` 字段闭环。原始(未标 Slots)分配仍算 1 槽。
  <details><summary>代码依据 pkg/device/initContainer.go</summary>

  ```diff
  +func slotsOf(dev ContainerDevice) int32 { return max(dev.Slots, 1) }
  ...
  -					s.sc.slots++
  +					s.sc.slots += slotsOf(dev)
  -					s.peak.slots = max(s.peak.slots, s.sc.slots+1)
  +					s.peak.slots = max(s.peak.slots, s.sc.slots+slotsOf(dev))
  -				s.slots++ // each concurrent app container occurrence is one slot
  +				s.slots += slotsOf(dev)
  ```
  </details>

- **vGPUmonitor `UtilizationPerDevice`: `[]int` → `map[int]int`,priority 从切片下标改成键**。旧逻辑用 `for i := range min(p, len(...))` 遍历、`utSwitchOn[uuid][p]` 按下标取值,并在 `Observe` 里 `append` 补齐到 p 长度;新代码 `for priority, count := range ...; if priority < p && count > 0`。注释点明 priority 读自设备插件以读写方式挂进容器的共享内存,可为任意 int32,绝不能拿来给分配定长——把风险面从"攻击者可控的下标/长度"拆掉。
  <details><summary>代码依据 cmd/vGPUmonitor/feedback.go</summary>

  ```diff
  -type UtilizationPerDevice []int
  +// ... The priority is keyed rather than used as a slice index: it is
  +// read from the shared memory region the device plugin mounts into the
  +// container read-write, so it can be any int32 and must never size an
  +// allocation.
  +type UtilizationPerDevice map[int]int
  ...
  -			for i := range min(p, len(utSwitchOn[uuid])) {
  -				if utSwitchOn[uuid][i] > 0 { return true }
  +			for priority, count := range utSwitchOn[uuid] {
  +				if priority < p && count > 0 { return true }
  -			if p >= 0 && p < len(utSwitchOn[uuid]) && utSwitchOn[uuid][p] > 1 {
  +			if counts[p] > 1 {
  -					for p >= len(utSwitchOn[uuid]) { utSwitchOn[uuid] = append(utSwitchOn[uuid], 0) }
  +					if utSwitchOn[uuid] == nil { utSwitchOn[uuid] = UtilizationPerDevice{} }
  ```
  </details>

- **kunlun `calcscore` 排序修复**:旧 `sort.Slice(p, func(i,j) { return i < j })` 比的是下标(恒成立,等于没排序),`countbubble` 拿到的是未排序序列;换成 `slices.Sort(p)`/`slices.Sort(c)` 按元素值真正排序,拓扑打分才正确。
  <details><summary>代码依据 pkg/device/kunlun/topo.go</summary>

  ```diff
  -	sort.Slice(p, func(i, j int) bool { return i < j })
  -	sort.Slice(c, func(i, j int) bool { return i < j })
  +	slices.Sort(p)
  +	slices.Sort(c)
  ```
  </details>

- **dashboard 新增"GPU memory: allocated vs host used"面板**:同一物理 GPU 上叠放 `hami_gpu_memory_allocated_bytes`(调度器分配)与 `hami_host_gpu_memory_used_bytes`(宿主实际已用,虚线),便于看超卖/实际占用背离。另 monitor `feedback_test.go` 大改配合上面 map 改动;service/monitorservice chart 的 label 缩进修复(#2932)。
  <details><summary>代码依据 dashboards/hami-vgpu-dashboard.json</summary>

  ```diff
  +          "expr": "hami_gpu_memory_allocated_bytes{node=~\"$node\"}",
  +          "legendFormat": "allocated {{node}} idx{{device_index}} ({{device_uuid}})",
  +          "expr": "hami_host_gpu_memory_used_bytes{node=~\"$node\"}",
  +          "legendFormat": "host used {{node}} idx{{device_index}} ({{device_uuid}})",
  +      "title": "GPU memory: allocated vs host used",
  ```
  </details>

### 后续发展方向 [AI]
- **DRS 多 slot 语义正在被抬为一等公民**:`Slots` 从 Enflame 专属的 `CustomInfo["drsSlice"]` 提升为 `ContainerDevice` 结构字段 + 注解字段 + 三处计账入口统一消费,说明"一个容器占多个时分槽"的路径要跨设备类型稳定下来。证据只覆盖 Enflame(device.go)与通用 device/initContainer 层,未见其它厂商(kunlun/enflame 以外)已改用 `Slots`——CustomInfo 回退仍在,迁移未完。
- **软隔离侧对"容器可写共享内存"的信任边界在收紧**:feedback 的 slice→map 改动本质是把容器可控数据从"能定长/定下标"降级为"只当键值",与近期几日调度/计账边界收口是同一方向(把 v2.10 GA 后暴露的输入正确性长尾夯实)。证据仅本次 feedback.go 一处,未排查 vGPUmonitor 其它读取共享内存的路径是否也做了同类加固。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 f01e9f23,无 release tag)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 f6ae9160,release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=42cdc7820d7b00df886d82164af74cb5634469a3 branch=master release=v2.10.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-05 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-05 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-05 -->
