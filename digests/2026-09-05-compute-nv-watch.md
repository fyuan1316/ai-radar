# NVIDIA 算力栈 diff 雷达 2026-09-05

## 摘要
- **DRA 结构化分配路径今天在"驱动侧"和"调度侧"同时补齐**:KAI-Scheduler 把 DRA 结构化分配器从硬编码空 `structured.Features{}` 改成从上游 feature gate 真实构造(打开 PartitionableDevices/ConsumableCapacity 等能力);dra-driver-nvidia-gpu 顺带修了 time-slicing config 无 interval 时的 nil panic。两仓都在往"DRA 原生 GPU 共享/可分区设备"这条主线推进。
- **dra-driver 显式声明"不上报设备健康"**:gpu-kubelet-plugin 与 compute-domain-kubelet-plugin 都改成 `HealthService(false)`,主动不向 kubelet 注册 KEP-4680 的 `DRAResourceHealth` 服务,以消除注册期的伪错误日志——等于官方口径确认该 DRA 驱动当前不实现设备健康上报。
- 其余多为工程整备:k8s-device-plugin 一次性 "Go Modernize"(`ptr()`→`new()`、`interface{}`→`any`、`maps.Copy`/`slices.Contains`)顺带删掉 config 若干 json 字段的 `omitempty`;gpu-operator / nvidia-container-toolkit 仅 Go 1.27.1 bump + 单测/PR 模板;gpu-driver-container、dcgm-exporter、DCGM、mig-parted 四仓 EMPTY。**无任何 ClusterPolicy CRD 字段增删**。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [新能力] DRA 结构化分配器不再传空 Features,而由 `allocatorFeatures()` 把上游 scheduler feature gate(AdminAccess/PrioritizedList/PartitionableDevices/DeviceTaints/DeviceBindingAndStatus/ConsumableCapacity)映射进 `structured.NewAllocator`;此前 `filter`/`allocate` 两处都写死 `structured.Features{}`,导致可分区设备与可消费容量等 DRA 高级能力被静默禁用。证据 `pkg/scheduler/plugins/dynamicresources/dynamicresources.go`。 https://github.com/kai-scheduler/KAI-Scheduler/pull/2102
- kubernetes-sigs/dra-driver-nvidia-gpu [架构方向] 两个 kubelet plugin 均改为 `kubeletplugin.HealthService(false)`,主动不广告 KEP-4680 `DRAResourceHealth` 服务(注释:本插件不上报设备健康)。证据 `cmd/gpu-kubelet-plugin/driver.go`、`cmd/compute-domain-kubelet-plugin/driver.go`。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/8ad4e66f1367b852c36e1f405d50055b7b3bbe66
- kubernetes-sigs/dra-driver-nvidia-gpu [稳定性] time-slicing config 存在但 `Interval` 为 nil 时:`Normalize()` 现补默认 interval、`Validate()` 现显式报 "no time-slice interval set",修复原先直接解引用 nil 的 panic。证据 `api/nvidia.com/resource/v1beta1/gpuconfig.go`、`validate.go`。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/8ad4e66f1367b852c36e1f405d50055b7b3bbe66
- NVIDIA/k8s-device-plugin [API/CRD变更] `api/config/v1` 的 `Config.{Flags,Resources,Sharing,Imex}` 与 `Sharing.TimeSlicing` 的 json tag 去掉了 `omitempty`(yaml 仍保留),这些字段今后即使为空也会被序列化进 JSON。证据 `api/config/v1/config.go`、`sharing.go`。 https://github.com/NVIDIA/k8s-device-plugin/pull/1996

## kubernetes-sigs/dra-driver-nvidia-gpu: 58f4c3bd -> 8ad4e66f
- 比较 / Release:`58f4c3bd...8ad4e66f` | ahead=4 | files=5 | Release v0.5.0
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/58f4c3bd936cd168b9e0ab2f088dd1183e63ba16...8ad4e66f1367b852c36e1f405d50055b7b3bbe66

### AI 总结重点(源码 diff 为据)
- **time-slicing 归一化拆成两级判空,消除 nil interval panic**:`GpuConfig.Normalize()` 原先只在 `TimeSlicingConfig == nil` 时兜底建结构并塞默认 interval;现在拆成"config 为 nil 就先建空 config",再单独判"`Interval == nil` 才补 `DefaultTimeSlice`"。等于覆盖了"用户给了 TimeSlicingConfig 但没写 interval"这个中间态。配套 `TimeSlicingConfig.Validate()` 增加 `c == nil || c.Interval == nil` 的前置守卫,直接返回 "no time-slice interval set" 而不是解引用崩溃。

  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/gpuconfig.go + validate.go</summary>

  ```diff
  // gpuconfig.go Normalize()
  -		if c.Sharing.Strategy == TimeSlicingStrategy && c.Sharing.TimeSlicingConfig == nil {
  -			c.Sharing.TimeSlicingConfig = &TimeSlicingConfig{
  -				Interval: ptr.To(DefaultTimeSlice),
  +		if c.Sharing.Strategy == TimeSlicingStrategy {
  +			if c.Sharing.TimeSlicingConfig == nil {
  +				c.Sharing.TimeSlicingConfig = &TimeSlicingConfig{}
  +			}
  +			if c.Sharing.TimeSlicingConfig.Interval == nil {
  +				c.Sharing.TimeSlicingConfig.Interval = ptr.To(DefaultTimeSlice)
  			}
  		}
  // validate.go
   func (c *TimeSlicingConfig) Validate() error {
  +	if c == nil || c.Interval == nil {
  +		return fmt.Errorf("no time-slice interval set")
  +	}
  	return c.Interval.Validate()
  ```
  </details>

- **两个 kubelet plugin 显式关闭 DRAResourceHealth 服务**:`gpu-kubelet-plugin` 与 `compute-domain-kubelet-plugin` 在 `NewDriver` 里给 `kubeletplugin.Start` 追加 `HealthService(false)`,注释点明"本插件不实现 KEP-4680 设备健康上报,故不向 kubelet 广告该服务",目的是消除注册期的伪错误日志。这是一处明确的能力边界声明:当前 NVIDIA DRA 驱动不走 kubelet 的设备健康通道。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/driver.go + cmd/compute-domain-kubelet-plugin/driver.go</summary>

  ```diff
  // gpu-kubelet-plugin/driver.go
  +	// This plugin does not report device health (KEP-4680), so don't
  +	// advertise the DRAResourceHealth service to the kubelet.
  +	opts = append(opts, kubeletplugin.HealthService(false))
   	helper, err := kubeletplugin.Start(ctx, driver, opts...)
  // compute-domain-kubelet-plugin/driver.go
  +		// This plugin does not report device health (KEP-4680), so don't
  +		// advertise the DRAResourceHealth service to the kubelet.
  +		kubeletplugin.HealthService(false),
  ```
  </details>

### 后续发展方向 [AI]
- time-slicing 判空的加固说明 DRA 原生 time-slicing 配置面正在被真实使用(否则不会碰到"给了 config 没给 interval"的边界),这条路径仍是该驱动 GPU 共享的一等公民。证据只覆盖 `v1beta1` 的 Normalize/Validate,未见 MPS/MIG 分支是否有同类加固。
- 主动关闭 HealthService 是"暂不做"而非"永不做"的信号(注释直接引 KEP-4680)。若后续该驱动要接入设备健康/故障驱逐,预期会反转这个开关并新增健康探测代码。证据只覆盖两处 driver.go 的 option 追加,未见任何健康采集实现。

## kai-scheduler/KAI-Scheduler: f5287fb2 -> da8e4a0d
- 比较 / Release:`f5287fb2...da8e4a0d` | ahead=1 | files=3 | Release v0.17.1
- https://github.com/kai-scheduler/KAI-Scheduler/compare/f5287fb22942a52d38b1f5cdd17f2c78823afffb...da8e4a0d4f2eb0ca7dca13140ac1dc2e4186dff5

### AI 总结重点(源码 diff 为据)
- **DRA 结构化分配器从"空 Features"改为透传真实 feature gate**:`draPlugin` 新增字段 `allocatorFeatures structured.Features`,由新函数 `allocatorFeatures(k8splfeature.Features)` 把上游 `k8s.io/kubernetes/.../plugins/feature` 的 gate 逐项映射:`AdminAccess`、`PrioritizedList`、`PartitionableDevices`、`DeviceTaints`、`DeviceBindingAndStatus`(= `EnableDRADeviceBindingConditions && EnableDRAResourceClaimDeviceStatus`)、`ConsumableCapacity`。`New()` 里用 `GetK8sFeatures()` 的结果一次性算出并存下;`filter()` 与 `allocate()` 两处 `structured.NewAllocator(ctx, structured.Features{}, ...)` 改成传 `drap.allocatorFeatures`。此前写死空 Features 意味着无论集群开了哪些 DRA gate,分配器一律按"全关"跑,可分区设备/可消费容量等能力被静默吞掉。

  <details><summary>代码依据 pkg/scheduler/plugins/dynamicresources/dynamicresources.go</summary>

  ```diff
   type draPlugin struct {
   	manager               ksf.SharedDRAManager
   	celCache              *cel.Cache
  +	allocatorFeatures     structured.Features
   	queueLabelKey         string
   }
  +func allocatorFeatures(features k8splfeature.Features) structured.Features {
  +	return structured.Features{
  +		AdminAccess:            features.EnableDRAAdminAccess,
  +		PrioritizedList:        features.EnableDRAPrioritizedList,
  +		PartitionableDevices:   features.EnableDRAPartitionableDevices,
  +		DeviceTaints:           features.EnableDRADeviceTaints,
  +		DeviceBindingAndStatus: features.EnableDRADeviceBindingConditions && features.EnableDRAResourceClaimDeviceStatus,
  +		ConsumableCapacity:     features.EnableDRAConsumableCapacity,
  +	}
  +}
   // filter() / allocate():
  -		context.Background(), structured.Features{},
  +		context.Background(), drap.allocatorFeatures,
  ```
  </details>

### 后续发展方向 [AI]
- KAI 现在能吃到 `PartitionableDevices` 与 `ConsumableCapacity`,正好对上 dra-driver-nvidia-gpu 侧的 per-device 节点选择 / 共享计数模型(新增测试里 `buildPerDeviceNodeSelectionSlice` 注释直指 nvidia-dra-driver-gpu 的 DynamicMIG)。这意味着"KAI 调度 + NVIDIA DRA 驱动做动态 MIG/可分区 GPU"的端到端链路正在打通。证据覆盖 dynamicresources.go 的 Features 透传与新测试文件的 ResourceSlice 构造,未见 KAI 是否已在 e2e 层验证 DynamicMIG。
- gate 映射把 `DeviceBindingAndStatus` 做成两个 gate 的与,说明 KAI 对齐的是上游较新的 DRA 绑定条件/设备状态语义;后续若上游 gate 演进(GA/改名),这个映射需要跟着改。证据仅此一处映射函数。

## NVIDIA/k8s-device-plugin: 3c6be400 -> ad5bc6cc
- 比较 / Release:`3c6be400...ad5bc6cc` | ahead=1 | files=31 | Release v0.20.0
- https://github.com/NVIDIA/k8s-device-plugin/compare/3c6be400411aad793892e976824910d0880dd3a8...ad5bc6ccbf9608431c0c94927866882d998a6196

### AI 总结重点(源码 diff 为据)
- **一次性 "Go Modernize" 机械改写,但夹带一处序列化行为变更**:提交把 `ptr[T]` 辅助函数删除、全仓 `ptr(x)` 改用内建 `new(x)`,`interface{}` 全改 `any`,手写 map 拷贝改 `maps.Copy`、`/dev/dxg` 路径查找改 `slices.Contains`——这些不改行为。**但** `api/config/v1/config.go` 把 `Config.Flags/Resources/Sharing/Imex` 的 json tag 从 `...,omitempty` 改成无 `omitempty`,`sharing.go` 同样去掉 `TimeSlicing` 的 json `omitempty`(yaml tag 仍保留 omitempty)。后果:这些字段即便为零值也会出现在 JSON 序列化输出里,消费 device-plugin 配置 JSON 的下游需注意多出的空字段。

  <details><summary>代码依据 api/config/v1/config.go + sharing.go + devices.go</summary>

  ```diff
  // config.go
  -	Flags     Flags     `json:"flags,omitempty"     yaml:"flags,omitempty"`
  -	Resources Resources `json:"resources,omitempty" yaml:"resources,omitempty"`
  -	Sharing   Sharing   `json:"sharing,omitempty"   yaml:"sharing,omitempty"`
  -	Imex      Imex      `json:"imex,omitempty"      yaml:"imex,omitempty"`
  +	Flags     Flags     `json:"flags"     yaml:"flags,omitempty"`
  +	Resources Resources `json:"resources" yaml:"resources,omitempty"`
  +	Sharing   Sharing   `json:"sharing"   yaml:"sharing,omitempty"`
  +	Imex      Imex      `json:"imex"      yaml:"imex,omitempty"`
  // sharing.go
  -	TimeSlicing ReplicatedResources `json:"timeSlicing,omitempty" yaml:"timeSlicing,omitempty"`
  +	TimeSlicing ReplicatedResources `json:"timeSlicing" yaml:"timeSlicing,omitempty"`
  // devices.go — 语义等价的现代化改写
  -	for _, p := range d.Paths { if p == "/dev/dxg" { return false } }
  -	return true
  +	return !slices.Contains(d.Paths, "/dev/dxg")
  ```
  </details>

### 后续发展方向 [AI]
- 除 json omitempty 外全是零行为的工具化改写,不预示能力变化;真正值得盯的是那处序列化差异对 config-manager / gpu-operator 下发配置时的兼容影响。证据覆盖 config.go/sharing.go 的 tag 与 devices.go 的改写,未逐一核对 31 个文件是否还有其他非机械改动(其余多为 `_test.go` 与 `any` 替换)。

## 本期无实质改动(折叠)
- **NVIDIA/gpu-operator**:仅 Go 工具链 1.27.0→1.27.1 bump(versions.mk + 两个 Dockerfile)、给 `getRuntimeString` 加单测、删 `state_manager.go`/`nodepool.go` 里的陈旧 TODO 注释。无功能改动,无 CRD 变更。
- **NVIDIA/nvidia-container-toolkit**:仅新增 PR 模板 + devel Dockerfile 的 Go 1.27.0→1.27.1 bump。
- **NVIDIA/gpu-driver-container**:无新提交(EMPTY)。
- **NVIDIA/dcgm-exporter**:无新提交(EMPTY)。
- **NVIDIA/DCGM**:无新提交(EMPTY)。
- **NVIDIA/mig-parted**:仅 bump/CI(EMPTY)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=df32e7e61ad2bc6677c302ec4d805ddaf43a13c4 branch=main release=v26.7.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a471da0e7ebaa924e44bd77c547d4e93110dc21e branch=main release=v1.20.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9ac64592151369a93da35b831322f193c03b13f5 branch=main release=— scanned=2026-09-05 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=ad5bc6ccbf9608431c0c94927866882d998a6196 branch=main release=v0.20.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=8ad4e66f1367b852c36e1f405d50055b7b3bbe66 branch=main release=v0.5.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-05 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-05 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2098686586250d28c472aaa821643a069f8464ec branch=main release=v0.15.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=da8e4a0d4f2eb0ca7dca13140ac1dc2e4186dff5 branch=main release=v0.17.1 scanned=2026-09-05 -->
