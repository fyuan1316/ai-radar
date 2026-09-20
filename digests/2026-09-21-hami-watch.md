# HAMi diff 雷达 2026-09-21

## 摘要
- HAMi 主仓单仓有实质改动(ahead=7):**多厂商共存打分正确性修复**(按 vendor 而非型号名比较,NVIDIA/Cambricon 混部原本打分被静默跳过)+ **Moore Threads S5000 纳管**(可配置每卡显存、整卡/切片混用拦截、按物理卡 id 绑卡)+ **调度器启动期资源名/默认值校验**(两 backend 抢同一 resourceName 直接报错)。
- 其余 4 仓(HAMi-core、volcano-vgpu-device-plugin、ascend-device-plugin、HAMi-WebUI)全 EMPTY,无新提交。
- 一次性删除了 ~13 篇 `docs/develop` 设计文档(#3050),经查为"搬到官网"而非能力下线;但被删文档反证了当前在建方向(CA scale-up 仿真、dynamic MIG、AMD vGPU、init/sidecar GPU 计账)。

## 当日重要改变
- Project-HAMi/HAMi [新能力] Moore Threads S5000(80GiB)纳管:每卡显存单位从硬编码 96 改为可配置 `mthreads.memoryPerCard`,并新增整卡资源 `mthreads.com/gpu` 与 sGPU 切片同容器混用的准入拦截。证据 pkg/device/mthreads/device.go https://github.com/Project-HAMi/HAMi/pull/2988
- Project-HAMi/HAMi [新能力/健壮性] 调度器启动期校验:非法资源名告警、nvidia defaultCores 必须落在 0-100、两个 backend 声明同一 resourceCountName 直接判错(否则同一请求会被双重分配)。证据 pkg/scheduler/config/config.go https://github.com/Project-HAMi/HAMi/pull/3010
- Project-HAMi/HAMi [Bug/正确性] vGPU 打分改用 DeviceVendor 而非注册 Type 比较,修复 NVIDIA/Cambricon 因把型号名当 Type 导致打分永远被跳过。证据 pkg/scheduler/policy/gpu_policy.go https://github.com/Project-HAMi/HAMi/pull/2870

## Project-HAMi/HAMi: 5abc69dc -> 60197354
- 比较: https://github.com/Project-HAMi/HAMi/compare/5abc69dca3f198cd8eebc5942ce4838338831b0f...60197354e5fa0bb042b0ee62862fa68a621ecb77 | ahead=7 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **vGPU 打分的"同型号"判定从 `Type` 改为新字段 `DeviceVendor`**。`DeviceUsage` 结构体新增 `DeviceVendor string`,`ComputeScore` 里过滤请求容器的比较从 `container.Type != ds.Device.Type` 改成 `container.Type != ds.Device.DeviceVendor`。注释点明根因:NVIDIA / Cambricon 等 backend 把**型号名**("NVIDIA A100-SXM4-40GB"、"MLU370-X8")注册进 `Type`,而请求侧携带的是 **vendor common word**,旧比较两者永远不等 → 该设备在打分阶段被 `continue` 跳过。这是多厂商共存场景下的打分正确性修复。
  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
  -	// Here we are required to use the same type device
  +	// Here we are required to use the same type device. Compare against the
  +	// vendor rather than the registered type: backends such as NVIDIA and
  +	// Cambricon register a model name ("NVIDIA A100-SXM4-40GB", "MLU370-X8")
  +	// as the type, while the request carries the vendor common word.
   	for _, container := range requests {
  -		if container.Type != ds.Device.Type {
  +		if container.Type != ds.Device.DeviceVendor {
   			continue
   		}
  ```
  </details>
  <details><summary>代码依据 pkg/device/devices.go(新增字段 + DeepCopy 补齐)</summary>

  ```diff
   	Type                string
  +	DeviceVendor        string
   	Health              bool
   ```
  </details>

- **调度器初始化新增两级校验:启动前拦截"不可被 backend 二次改写"的配置错误**。`InitDevicesWithConfig` 在初始化成功后新增 `validateRegisteredDevices(device.DevicesMap)`;`validateConfig` 拆出 `anyDeviceConfigured`,并新增 nvidia `defaultCores` 必须在 0-100(百分比)、`defaultMemory` 非负的校验(用 `utilerrors.NewAggregate` 聚合报错)。
  <details><summary>代码依据 pkg/scheduler/config/config.go</summary>

  ```diff
  +	if err := validateRegisteredDevices(device.DevicesMap); err != nil {
  +		return fmt.Errorf("invalid device configuration: %w", err)
  +	}
  +	if config.NvidiaConfig.DefaultCores < 0 || config.NvidiaConfig.DefaultCores > 100 {
  +		errs = append(errs, fmt.Errorf("nvidia: defaultCores is a percentage and must be between 0 and 100, got %d", config.NvidiaConfig.DefaultCores))
  +	}
  ```
  </details>

- **`validateRegisteredDevices`:通过 `GetResourceNames()` 回读各 backend 应用默认值之后的资源名做交叉校验**。三点行为:① 资源名不是合法 K8s qualified name → 只 `klog.ErrorS` 告警不拒绝(注释说明:拒绝会是 breaking change);② `memoryFactor` 负值 → 报错;③ **两个 backend 声明同一 `resourceCountName` → 报错**,注释点明后果是"一个请求该资源的容器会被两个 backend 各分配一次设备"。
  <details><summary>代码依据 pkg/scheduler/config/config.go</summary>

  ```diff
  +		if previous, taken := owners[names.ResourceCountName]; taken {
  +			errs = append(errs, fmt.Errorf("%s and %s both claim resource %q; a container requesting it would be allocated devices by both", previous, commonWord, names.ResourceCountName))
  +			continue
  +		}
  +		owners[names.ResourceCountName] = commonWord
  ```
  </details>

- **Moore Threads:每卡显存单位从硬编码常量改为可配置,支持 S4000/S5000 混合集群**。常量 `memoryPerMthreadsGPU = 96` 更名 `defaultMemoryPerMthreadsGPU = 96`(MTT S4000 = 96×512MiB = 48GiB);`MthreadsConfig` 新增 `MemoryPerCard []int64`(如 `[96, 160]` 对应 S4000/S5000);合法显存请求列表 `legalMemoryslices` 从硬编码 `[2,4,8,16,32,64,96]` 改为 `buildLegalMemorySliceUnion` 按配置容量动态生成(2 的幂次 + 整卡容量,混合集群取**并集**,准入放行任一型号合法的请求,由调度器在选中节点后按真实每卡容量兜底)。
  <details><summary>代码依据 pkg/device/mthreads/device.go</summary>

  ```diff
  -	memoryPerMthreadsGPU     = 96
  +	defaultMemoryPerMthreadsGPU = 96
  -	legalMemoryslices      = []int64{2, 4, 8, 16, 32, 64, 96}
  +	legalMemoryslices      = buildLegalMemorySlices(defaultMemoryPerMthreadsGPU)
  +	// MemoryPerCard lists the per-card memory capacities (in 512MiB units) ...
  +	MemoryPerCard []int64 `yaml:"memoryPerCard"`
  ```
  </details>

- **Moore Threads:准入拦截"整卡 + 切片"同容器混用**。`MutateAdmission` 新增检查:整卡资源 `mthreads.com/gpu`(由厂商 device plugin 在 HAMi 计账之外交付)与 sGPU 切片资源(count/memory/cores)不能出现在同一容器,聚合 Limits+Requests 判断以防拆分绕过,否则会静默超配节点。
  <details><summary>代码依据 pkg/device/mthreads/device.go</summary>

  ```diff
  +	hasWhole := contains(ctr.Resources.Limits, MthreadsWholeGPUResource) || contains(ctr.Resources.Requests, MthreadsWholeGPUResource)
  +	hasSlice := contains(ctr.Resources.Limits, MthreadsResourceCount, MthreadsResourceMemory, MthreadsResourceCores) || ...
  +	if hasWhole && hasSlice {
  +		return true, fmt.Errorf("cannot mix %s (whole card, delivered outside HAMi) with %s/%s/%s (sGPU slices) in the same container", ...)
  +	}
  ```
  </details>

- **Moore Threads:节点设备发现改从 `mthreads.com/sgpu.cores` 标签读物理卡 id,不再假设卡号连续 0..N-1**。当 sgpu_km 以非连续绑定(如 gpu_ids=0,2,3)时,调度器选出的卡 index 会被厂商栈当物理卡 id 消费,合成 0..N-1 会绑错卡。有标签走严格路径(容量对不上直接报错),无标签回退到连续推导(上游旧行为)。同时 count>1 时不再注入固定 memory 单位,留给调度器按选中节点真实容量推导。
  <details><summary>代码依据 pkg/device/mthreads/device.go</summary>

  ```diff
  +	if raw := n.Labels[SGPUCoresLabel]; raw != "" {
  +		cardIDs = parseSGPUCoresLabel(raw)
  +		if int64(len(cardIDs))*coresPerMthreadsGPU != cores {
  +			return ..., fmt.Errorf("sgpu capacity mismatch on %s: ...", ...)
  +		}
  +	} else {
  +		for i := uint(0); int64(i)*coresPerMthreadsGPU < cores; i++ { cardIDs = append(cardIDs, i) }
  +	}
  ```
  </details>

- **vGPUmonitor:`hami_host_gpu_memory_controller_utilization_ratio` 指标补 `node` label,并统一 GPU 型号命名**。该指标原缺 `node` label,多节点无法区分(#2776)。同时抽出 `nvidia.NormalizeDeviceModel`:NVML 报的型号名有的带 "NVIDIA" 前缀有的不带("NVIDIA A100..." vs "Tesla V100..."),旧代码无条件拼 `"NVIDIA-" + name` 导致重复前缀(#2991);device plugin 的 register.go 与 vGPUmonitor 现共用该函数,保证同一物理 GPU 在节点注册注解与 `device_type` label 里标一致。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go + pkg/device/nvidia/device.go</summary>

  ```diff
  -		[]string{"device_index", "device_uuid", "device_type"}, nil,
  +		[]string{"node", "device_index", "device_uuid", "device_type"}, nil,
  -		deviceName: "NVIDIA-" + deviceName,
  +		deviceName: nv.NormalizeDeviceModel(deviceName),
  +func NormalizeDeviceModel(model string) string {
  +	if strings.HasPrefix(model, NvidiaGPUDevice) { return model }
  +	return NvidiaGPUDevice + "-" + model
  +}
  ```
  </details>

- **文档搬家(非能力下线):`chore: remove the docs now hosted on the website` (#3050) 删除 ~13 篇 `docs/develop` 设计文档**。删除项含 dynamic-mig / dynamic-mig-migration / mig-dynamic-deallocate、initContainer-design、sidecarsContainer-design、scheduler-policy、amd-vgpu、dry-run-filter-design、hostpid-broker、biren-support 等。提交标题含 remove 命中[弃用/移除]信号,但性质是文档迁移到官网,**不是 CRD/flag/能力删除**,不作弃用信号计。

### 后续发展方向 [AI]
- **多国产/多厂商卡纳管仍是主线,且正从"能接入"走向"接入正确性"**:本期三条主改动(vendor 打分修复、mthreads 每卡显存可配置+混用拦截+物理卡 id 绑卡、启动期资源名去重校验)都不是新增厂商,而是补齐多 backend 共存时的正确性边界。证据覆盖 mthreads/nvidia/cambricon 打分与准入路径,未见对 Ascend/Hygon 等其他 backend 的同类加固(那些 backend 本期未改)。
- **被删设计文档反证在建能力**:dry-run-filter-design 指向 Cluster Autoscaler scale-up 仿真(让 CA 能调 HAMi `/filter` 判断冷启节点组是否可容纳 GPU Pod),dynamic-mig 系列指向 NVML 发现 + reservation-first 的按需 MIG,amd-vgpu 指向 LD_AUDIT + CU masking 的 AMD Instinct 切分。证据仅为被删文档正文,**未见对应实现代码在本区间落地**,方向判断需下期看主仓 pkg 是否出现对应 package。

## 本期无实质改动(折叠)
<details><summary>4 仓 EMPTY,仅保锚点</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=60197354e5fa0bb042b0ee62862fa68a621ecb77 branch=master release=v2.10.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a5231c7f4524e5d98f5200fde47f97b06356fcbe branch=main release=— scanned=2026-09-21 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-21 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=074d93a8e1ca4f357fb1f4946f0566ced93641a6 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=b2af8ecc94a2330a6f11ab189522f16f328495bd branch=main release=v1.3.0 scanned=2026-09-21 -->
