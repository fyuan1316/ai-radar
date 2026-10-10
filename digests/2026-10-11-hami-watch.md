# HAMi diff 雷达 2026-10-11

## 摘要
- **HAMi 主仓头条:动态 MIG 生命周期重写(#3128)**——Pod 释放后不再销毁 GI/CI,而是转 `Idle` 缓存、同 profile+placement 请求直接复用,配套新增磁盘持久化的"所有权记录"(`/var/run/hami/dynamic-mig-state`)+ 重启恢复逻辑,删掉原启动即清空空闲 GPU 的 `ResetIdleGPUs`。这是 HAMi 硬件分区(MIG)路径的一次能力升级,区别于 HAMi-core 的 hook 软切分,也非 DRA 原生路径。
- **昇腾 vNPU 切分粒度可配(#3203)**:chart 新增 `devices.ascend.vnpuDeviceSplitCount`(默认 10),hami-core 模式下每张物理 NPU 可切的虚拟槽位数首次参数化——这是本 task 核心关心的 vNPU 软切分能力。
- 其余为 AMD GPU 工程化加固(runtimeClassName 注入、按 allocatable 判健康、新增 e2e 套件)与 chart extraEnvs 结构修正;HAMi-core / volcano / ascend-device-plugin / WebUI 四仓本期 EMPTY。

## 当日重要改变
- Project-HAMi/HAMi [新能力][架构方向] 动态 MIG 从"用后即焚"改为"空闲缓存+复用",新增 `mig_ownership.go`/`mig_recovery.go` 两个顶层文件 + 状态机 + 节点级持久化目录。证据见下。 https://github.com/Project-HAMi/HAMi/pull/3128
- Project-HAMi/HAMi [新能力] 昇腾 vNPU 每卡切分槽位数 `vnpuDeviceSplitCount` 可配(需 ascend-device-plugin #144 配合)。 https://github.com/Project-HAMi/HAMi/pull/3203
- Project-HAMi/HAMi [新能力] AMD GPU 支持可配置 runtimeClassName,准入时自动注入 Pod。 https://github.com/Project-HAMi/HAMi/pull/3194

## Project-HAMi/HAMi: c40de0fa -> 015b302b
- 比较: https://github.com/Project-HAMi/HAMi/compare/c40de0fa87f38ebe585b47d5675c6fd1d2b62ff2...015b302b1d1a63c74f6e9b58dca2b8a7beffa1e7 | ahead=8 | 最新 Release v2.10.0

### AI 总结重点(源码 diff 为据)

- **动态 MIG 实例引入显式状态机 + 复用。** `migInstance` 新增 `State`(`Creating/Active/Idle/Reclaiming/Deleting/Error`)与 `LastUsed` 字段;分配出口从返回 `(migUUID, created)` 二元改为返回 `migAllocationResult{MigUUID, Created, Reused, Reclaimed}`。Pod 释放不再销毁实例而是转 Idle,同 profile+placement 的下一个请求直接复用同一 MIG UUID,从而消除重复 GI/CI 创建开销。`MigInstanceManager` 还注入了 `now func() time.Time` 便于测试。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/migmgr.go</summary>

  ```diff
  +type migInstanceState string
  +const (
  +	migInstanceCreating   migInstanceState = "Creating"
  +	migInstanceActive     migInstanceState = "Active"
  +	migInstanceIdle       migInstanceState = "Idle"
  +	migInstanceReclaiming migInstanceState = "Reclaiming"
  +	migInstanceDeleting   migInstanceState = "Deleting"
  +	migInstanceError      migInstanceState = "Error"
  +)
   type migInstance struct {
   	...
  +	State     migInstanceState
  +	LastUsed  time.Time
  +}
  +type migAllocationResult struct {
  +	MigUUID   string
  +	Created   bool
  +	Reused    bool
  +	Reclaimed []string
   }
  ```
  </details>

- **删掉"启动即清空空闲 GPU"的 `ResetIdleGPUs`。** 旧逻辑在插件启动时对所有非占用 GPU 开 MIG 模式并销毁全部已存在 GI/CI(即每次重启丢弃全部实例)。移除后,启动改走 `mig_recovery.go` 的"恢复而非清零",空闲实例得以跨重启存活。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/migmgr.go(removed)</summary>

  ```diff
  -// ResetIdleGPUs prepares idle MIG-capable GPUs for on-demand instance creation
  -// through NVML. Busy GPUs are left untouched; idle GPUs
  -// have MIG mode enabled and all existing GI/CI instances destroyed.
  -func (m *MigInstanceManager) ResetIdleGPUs(deviceCount int, inUse map[int]struct{}) ([]int, error) {
  -	...
  -}
  ```
  </details>

- **新增磁盘持久化的 MIG 所有权记录(`mig_ownership.go`,+341)。** HAMi 为每个它创建/收养的 GI/CI 对在 `/var/run/hami/dynamic-mig-state` 写一条 `migOwnershipRecord`(含 MIGUUID/父 GPU/profile/placement/GI ID/CI ID),通过 `fileMIGOwnershipStore` 落盘。作用:重启后凭此判定哪些实例是 HAMi 自己的、可安全复用,与 CDI 解耦(非 CDI 模式也生效)。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/mig_ownership.go(added)</summary>

  ```diff
  +const (
  +	dynamicMIGOwnershipVersion    = 1
  +	dynamicMIGOwnershipRoot       = "/var/run/hami/dynamic-mig-state"
  +	dynamicMIGOwnershipFilePrefix = "hami-owned-"
  +)
  +type migOwnershipRecord struct {
  +	Version           int                   `json:"version"`
  +	MIGUUID           string                `json:"migUUID"`
  +	ParentGPUUUID     string                `json:"parentGPUUUID"`
  +	Profile           string                `json:"profile"`
  +	Placement         migOwnershipPlacement `json:"placement"`
  +	GPUInstanceID     uint32                `json:"gpuInstanceID"`
  +	ComputeInstanceID uint32                `json:"computeInstanceID"`
  +}
  ```
  </details>

- **新增重启恢复 `RestoreAllocations`(`mig_recovery.go`,+210)。** 先收养活跃 Pod 注解引用的运行时身份,再加载落盘所有权记录与真实 NVML GI/CI 布局对账:验证通过的 HAMi 实例恢复为 Idle;无有效记录的既存实例默认保留不碰;仅当 `adoptExisting=true` 时才收养未标记的完整 GI/CI 对。校验不过直接报错而非改动不确定的硬件状态(fail-closed)。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/mig_recovery.go(added)</summary>

  ```diff
  +func (m *MigInstanceManager) RestoreAllocations(deviceCount int, inUse map[int]struct{}, owned map[string]migOwnershipRecord, adoptExisting bool) error {
  +	...
  +		if err := m.restoreGPUAllocationsLocked(gpuIndex, dev, owned, adoptExisting, !busy); err != nil {
  ```
  </details>

- **复用路径接入分配主流程(`util.go`)。** `GetContainerDeviceStrArray` 新增 `reusedMigUUIDs` 跟踪、失败回滚时对复用实例 `MarkIdle`(而非销毁)、每次分配 `persistMIGOwnership` 落盘、并用 `removeReclaimedMIGArtifacts` 统一清理被回收实例的所有权记录 + CDI 条目。即"创建/复用/回收"三态在分配出口处分流处理。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go</summary>

  ```diff
  -		migUUID, created, err := nv.migMgr.EnsureAllocation(gpuIndex, reservation.Profile, nvml.GpuInstancePlacement{...})
  +		result, err := nv.migMgr.EnsureAllocation(gpuIndex, reservation.Profile, placement)
  +		nv.removeReclaimedMIGArtifacts(result.Reclaimed)
  +		migUUID := result.MigUUID
  +		if result.Created {
   			createdMigUUIDs = append(createdMigUUIDs, migUUID)
  +		} else if result.Reused {
  +			reusedMigUUIDs = append(reusedMigUUIDs, migUUID)
  +		}
  +		if err := nv.persistMIGOwnership(allocationKey(gpuIndex, reservation.Profile, placement)); err != nil {
  ```
  </details>

- **配置面新增 `adoptExistingMIGInstances` 开关 + hostPath 挂载。** `NvidiaConfig` 加 `AdoptExistingMIGInstances bool`,chart `devices.nvidia.adoptExistingMIGInstances: false` 默认关,daemonset 把节点 `/var/run/hami/dynamic-mig-state` 以 `DirectoryOrCreate` 挂进插件容器,使所有权记录跨重启存活。
  <details><summary>代码依据 pkg/device/nvidia/device.go + charts/hami/values.yaml + daemonsetnvidia.yaml</summary>

  ```diff
  // pkg/device/nvidia/device.go
  +	// AdoptExistingMIGInstances allows Dynamic MIG startup recovery to adopt
  +	// unannotated GI/CI pairs. It must only be enabled when HAMi exclusively owns the MIG layout.
  +	AdoptExistingMIGInstances bool `yaml:"adoptExistingMIGInstances"`
  // charts/hami/values.yaml
  +    adoptExistingMIGInstances: false
  // daemonsetnvidia.yaml
  +            - name: dynamic-mig-state
  +              mountPath: /var/run/hami/dynamic-mig-state
  ```
  </details>

- **昇腾 vNPU 每卡切分槽位数首次可配 `vnpuDeviceSplitCount`(默认 10)。** hami-core 模式下每张物理 Ascend NPU 可切的虚拟设备槽位数参数化,节点级正 `vDeviceCount` 优先;template/ENPU 模式各自保留容量语义。chart `_helpers.tpl` 加硬校验:非正整数直接 `fail`。需 ascend-device-plugin #144(`vnpus.vnpuDeviceSplitCount`)版本配合。这是 HAMi 对 NPU 软切分粒度的直接暴露。
  <details><summary>代码依据 charts/hami/values.yaml + _helpers.tpl</summary>

  ```diff
  // values.yaml
  +    # Positive integer virtual-device slots per physical Ascend NPU in hami-core mode.
  +    vnpuDeviceSplitCount: 10
  // _helpers.tpl
  +{{- $count := .Values.devices.ascend.vnpuDeviceSplitCount -}}
  +{{- if not (and $numeric (gt $integer 0) (eq (float64 $count) (float64 $integer))) -}}
  +  {{- fail "devices.ascend.vnpuDeviceSplitCount must be a positive integer" -}}
  ```
  </details>

- **AMD GPU:可配 runtimeClassName + 健康判定口径修正。** 准入时若用户未设 `spec.runtimeClassName` 且配置了默认值,则自动注入;`CheckHealth` 从读 `Status.Capacity` 改为读 `Status.Allocatable`——kubelet 对不健康 GPU 的做法是"留在 capacity、从 allocatable 剔除",故只有 allocatable 能反映 Pod 还能否被准入。
  <details><summary>代码依据 pkg/device/amd/device.go</summary>

  ```diff
  +	if ok && p.Spec.RuntimeClassName == nil && dev.runtimeClassName != "" {
  +		p.Spec.RuntimeClassName = &dev.runtimeClassName
  +	}
  ...
  -	gpuCount, ok := n.Status.Capacity.Name(corev1.ResourceName(dev.resourceCountName), resource.DecimalSI).AsInt64()
  +	// Allocatable, not capacity: kubelet keeps an unhealthy GPU in capacity and drops it from allocatable
  +	gpuCount, ok := n.Status.Allocatable.Name(corev1.ResourceName(dev.resourceCountName), resource.DecimalSI).AsInt64()
  ```
  </details>

- **chart extraEnvs 结构从 map 改为 list(#3205)。** `devicePlugin.extraEnvs` 与 vGPU monitor 的 `extraEnvs` 默认值由 `{}` 改为 `[]`,语义对齐 K8s env 的"name/value 或 valueFrom 对象列表"。属 chart 工程化修正,非运行时能力。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  -    extraEnvs: {}
  +    # -- Extra Kubernetes env entries ..., as a list of objects with name and value or valueFrom.
  +    extraEnvs: []
  ```
  </details>

### 后续发展方向 [AI]
- 动态 MIG 正从"每次重启重建"走向"有状态缓存 + 跨重启恢复 + 外部所有权仲裁"——`migOwnershipRecord` 的 `Version` 字段 + `adoptExistingMIGInstances` 显式 opt-in 表明团队在为"HAMi 独占 MIG 布局"这一前提做长期加固;文档明确点出 idle TTL 与缓存上限是"roadmap 扩展",当前只在 placement 冲突时回收空闲实例。证据只覆盖本次 8 commit 的 diff 与 docs/develop/dynamic-mig-lifecycle.md,未展开读 PR 讨论,TTL/缓存上限尚未落代码。
- 昇腾 vNPU 切分粒度参数化 + 对 ascend-device-plugin #144 的版本依赖,说明 HAMi 主仓与 ascend-device-plugin 的 vNPU 契约正在收敛为"主仓给 split 数、device-plugin 认 split 数"的双向约定;但本仓本期只见 chart 侧暴露,实际消费该字段的调度/插件代码不在本次 diff(需看 ascend-device-plugin 侧,其今日 EMPTY)。
- AMD 支持持续工程化(e2e mock 套件 + 健康口径修正 + runtimeClassName),属"把已有厂商适配做扎实"而非新切分能力,未见 AMD 侧引入 hami-core 式软隔离。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓</summary>

- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/volcano-vgpu-device-plugin:仅 bump/CI/merge(ahead=2)
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=015b302b1d1a63c74f6e9b58dca2b8a7beffa1e7 branch=master release=v2.10.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5ab7da10f72c72b7c158bb2d81f5148ec0af6392 branch=main release=— scanned=2026-10-11 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-11 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf890f96118f38a85f71d31da2e74ca95aeb1a0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=09f0b75b0773c2caf835933936f0301f7efc248c branch=main release=v1.3.0 scanned=2026-10-11 -->
</content>
</invoke>
