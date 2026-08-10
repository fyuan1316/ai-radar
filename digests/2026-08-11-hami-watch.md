# HAMi diff 雷达 2026-08-11

## 摘要

- 主仓 10 个实质提交,主线是 **Dynamic MIG 重构(#2378)**:MIG 从"整卡固定几何模板 + nvidia-smi 抓 UUID"改为"每 Pod 预约 profile+物理 placement,device plugin 按需建/销 GI+CI",配置字段 `knownMigGeometries` 被 `migProfileAllowlist` 取代——切换 MIG 布局不再必然 drain 节点。
- 第二条线是**调度器 init 容器资源核算(#1773)**:init 容器结束后按 app 容器实际用量收缩配额(`CollapseInitContainerUsage`/`AppContainersOnlyDeviceUsage`),修此前 init 容器 device 用量被长期占用的账。
- 其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI)HEAD 未动,无实质改动。

## 当日重要改变

- Project-HAMi/HAMi [新能力] 引入 Dynamic MIG:新增 `MigInstanceManager`(migmgr.go +535),节点级唯一权威,按 `profile+placement` 记录活的 GI+CI,`Allocate` 时按预约创建、Pod 终止时精确回收对应 CI/GI。 https://github.com/Project-HAMi/HAMi/pull/2378
- Project-HAMi/HAMi [弃用/移除] 删掉固定几何模型:移除 `MigPartedSpec/MigConfigSpec/MigConfigSpecSlice` 结构体与 `GetMigUUIDFromSmiOutput/GetMigUUIDFromIndex`(nvidia-smi -L 抓 UUID,-237 行),配置 `knownMigGeometries` → `migProfileAllowlist`,改用 NVML 直接发现合法 placement。 https://github.com/Project-HAMi/HAMi/blob/master/pkg/device/nvidia/device.go
- Project-HAMi/HAMi [新能力] 调度器 init 容器资源核算修正:init 容器成功后把用量从"init+app 并集"收缩到仅 app 容器,释放 device 配额。 https://github.com/Project-HAMi/HAMi/pull/1773

## Project-HAMi/HAMi: 3616313c -> 91f02483

- 比较: https://github.com/Project-HAMi/HAMi/compare/3616313cb4d30841a6162421969d7ab9463931aa...91f024838dc5cd428f428a08f3a6f259efa1bd1f | ahead=10 files=86 | Release: v2.9.0(不变)

### AI 总结重点(源码 diff 为据)

- **MIG 配置模型从"整卡几何模板"改为"profile 白名单"**:`NvidiaConfig` 删除 `MigGeometriesList []AllowedMigGeometries`(yaml `knownMigGeometries`,内含 name/core/memory/count 的完整 geometry),换成 `MigProfileAllowlist []AllowedMigProfiles`(yaml `migProfileAllowlist`);语义从"运维手工维护每种卡的整卡布局组合"转为"白名单只定策略、实际能力由 NVML 供给"。`GetNodeDevices` 里据 `MigGeometriesList` 填 `val.MIGTemplate` 的整段逻辑被删除。

  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -type MigPartedSpec struct {
  -	Version    string                        `json:"version"               yaml:"version"`
  -	MigConfigs map[string]MigConfigSpecSlice `json:"mig-configs,omitempty" yaml:"mig-configs,omitempty"`
  -}
  -// MigConfigSpec defines the spec to declare the desired MIG configuration for a set of GPUs.
  -type MigConfigSpec struct { ... }
  -type MigConfigSpecSlice []MigConfigSpec

   	// TODO Whether these should be removed
  -	DisableCoreLimit  bool                          `yaml:"disableCoreLimit"`
  -	MigGeometriesList []device.AllowedMigGeometries `yaml:"knownMigGeometries"`
  +	DisableCoreLimit    bool                        `yaml:"disableCoreLimit"`
  +	MigProfileAllowlist []device.AllowedMigProfiles `yaml:"migProfileAllowlist"`

  +	if err := ValidateMigProfileAllowlist(nvconfig.MigProfileAllowlist); err != nil {
  +		klog.Fatalf("invalid MIG profile allowlist: %v", err)
  +	}
  -	for _, val := range nodedevices {
  -		if val.Mode == MigMode {
  -			val.MIGTemplate = make([]device.Geometry, 0)
  -			for _, migTemplates := range dev.config.MigGeometriesList { ... }
  -		}
  -	}
  ```
  </details>

- **新增节点级 MIG 实例管理器 `MigInstanceManager`**:以 `migAllocationKey{GPUIndex, Profile, Start, Size}` 为键跟踪活的 `migInstance{Profile, Placement, GIID, CIID, MigUUID}`,带 per-GPU 锁;profile 名到 NVML GI/CI profile ID 的映射直接用 `nvml.GPU_INSTANCE_PROFILE_*_SLICE` 常量。这是"按需建/销 GI+CI 而非整卡重切"的落点。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/migmgr.go(新增)</summary>

  ```diff
  +type migInstance struct {
  +	Profile   string // slice group, e.g. "1g"
  +	Placement nvml.GpuInstancePlacement
  +	GIID      uint32
  +	CIID      uint32
  +	MigUUID   string
  +}
  +// MigInstanceManager is the single authority over live MIG GI+CI state on a node.
  +type MigInstanceManager struct {
  +	mu                  sync.Mutex
  +	gpuLocks            map[int]*sync.Mutex
  +	byAllocation        map[migAllocationKey]*migInstance
  +	byAllocationMigUUID map[string]migAllocationKey
  +}
  ```
  </details>

- **device plugin 去掉 `migCurrent` 整卡状态、改持有 `migMgr`**:`NvidiaDevicePlugin` 删除 `migCurrent nvidia.MigPartedSpec`,新增 `migMgr *MigInstanceManager`(仅 `operatingMode=="mig"` 时初始化);构造前先 `ValidateMigProfileAllowlist`。注释点明设计意图:"destroy and recreate them per-task rather than resharding the whole card"。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  	operatingMode string
  -	migCurrent    nvidia.MigPartedSpec
  	deviceCache   string
  +	// migMgr tracks live MIG GI+CI instances so we can destroy and recreate
  +	// them per-task rather than resharding the whole card. Only set when
  +	// operatingMode == "mig".
  +	migMgr *MigInstanceManager

  +	if err := nvidia.ValidateMigProfileAllowlist(sConfig.NvidiaConfig.MigProfileAllowlist); err != nil {
  +		return nil, fmt.Errorf("validate MIG profile allowlist: %w", err)
  +	}
  +	var migMgr *MigInstanceManager
  +	if mode == "mig" { migMgr = NewMigInstanceManager() }
  ```
  </details>

- **弃用 nvidia-smi 文本抓 MIG UUID 的旧路径**:`util.go` 删除 `GetMigUUIDFromSmiOutput`(解析 `nvidia-smi -L` 文本按 Device index 抠 UUID)与 `GetMigUUIDFromIndex`(NVML 失败时 fallback 到 exec `nvidia-smi -L`),净 -237 行,`os/exec`/`bytes`/`strconv` import 一并移除。方向是把 MIG 身份发现完全收敛到 NVML。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go</summary>

  ```diff
  -func GetMigUUIDFromSmiOutput(output string, uuid string, idx int) string {
  -	migmode := false
  -	for val := range strings.SplitSeq(output, "\n") { ... num := strings.Split(val, "Device")[1] ... }
  -}
  -func GetMigUUIDFromIndex(uuid string, idx int) string {
  -	...
  -	migdev, ret := nvml.DeviceGetMigDeviceHandleByIndex(ndev, idx)
  -	if ret != nvml.SUCCESS {
  -		cmd := exec.Command("nvidia-smi", "-L") ...
  -	}
  -}
  ```
  </details>

- **调度器 init 容器用量收缩(#1773)**:`onUpdatePod` 从"直接转发 onAddPod"重写为完整状态机——终态删账、terminating 更新;新增在 init 容器全部成功后,把 device 用量从 `CollapseInitContainerUsage`(init+app 峰值并集)替换为 `AppContainersOnlyDeviceUsage`(仅 app),调 `quotaManager.ReplaceUsage` 释放差额。修 init 容器 device 配额被长期占用的问题。

  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -func (s *Scheduler) onUpdatePod(_, newObj any) {
  -	s.onAddPod(newObj)
  +func (s *Scheduler) onUpdatePod(oldObj, newObj any) {
  +	...
  +	if util.IsPodInTerminatedState(newPod) {
  +		if pi, ok := s.podManager.TakeAndDeletePod(newPod); ok {
  +			s.quotaManager.RmUsage(newPod, pi.Devices)
  +		}
  +		return
  +	}
  +	if !pi.InitContainerResourceReleased && util.AllInitContainersSucceeded(newPod) {
  +		appOnlyDevices := device.AppContainersOnlyDeviceUsage(newPod, rawDevices)
  +		oldDevices, ok := s.podManager.UpdatePodDevice(newPod, appOnlyDevices)
  +		if ok { s.quotaManager.ReplaceUsage(newPod, oldDevices, appOnlyDevices) }
  +	}
  ```
  </details>

- **`fitInDevices` 按设备类型分账**:此前用全节点 `DeviceLists` 长度判断"设备数够不够",现改为先 `getNodeResources(*node, k.Type)` 取该类型设备再比数量;device type 未找到、Fit 后按 UUID 回填找不到设备等分支都补了结构化 error 日志。修多类型设备混插节点上的错误 reject。

  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
  -		if int(k.Nums) > len(node.Devices.DeviceLists) { ... return false, common.NodeInsufficientDevice }
  -		_, ok := device.GetDevices()[k.Type]
  +		devPlugin, ok := device.GetDevices()[k.Type]
  +		typeDevices := getNodeResources(*node, k.Type)
  +		if int(k.Nums) > len(typeDevices) {
  +			return false, common.NodeInsufficientDevice
  +		}
  +		fit, tmpDevs, reason := devPlugin.Fit(typeDevices, k, pod, nodeInfo, devinput)
  ```
  </details>

- **多后端小修(仅提交标题+信号文件,未逐一贴 hunk)**:`skip unhealthy devices in Fit() for all non-nvidia backends`(#2260)、AMD core 分配比归一化为百分比(#2527)、ascend `MutateAdmission` 防 nil Requests(#2416)、cambricon 对 percentage/整卡显存请求强制 ResourceQuota(#2536)、metax `ScoreNode` 与 policy string 解耦(#2413)、util 防 nil pod panic(#2499)。

### 后续发展方向 [AI]

- **MIG 从静态整卡布局走向"预约式细粒度切分"**,与 HAMi 一贯的软切分(hook/时分)是互补的硬切分路径:证据是 device.go 配置字段替换 + migmgr.go 的 per-Pod GI/CI 生命周期 + 迁移文档里 "reservation-first model / created during Allocate / reclaimed after Pod terminates"。对我们产品的启示:若对标 OAI 的 GPU 分区能力,HAMi 这条 Dynamic MIG 让"换 profile 不 drain"成为可能,是多租户混合推理场景的调度弹性卖点。证据只覆盖 device plugin/scheduler 侧的数据结构与配置 schema,未见 GI/CI 实际 NVML 创建/销毁调用的 hunk(migmgr.go 后半截断),restart 后按 Pod annotation 对账 NVML 的实现也未展开。
- **配置 schema 是 breaking change**:`knownMigGeometries` 直接被移除而非并存,`ValidateMigProfileAllowlist` 失败即 `Fatalf`。迁移文档明说"不支持保留 legacy MIG Pod 的无缝滚动迁移",需逐节点 cordon/drain/升级。证据只覆盖配置结构体与 init 校验,未见向后兼容/双读旧字段的代码。

## 本期无实质改动(折叠)

<details><summary>4 个仓库无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交(HEAD 仍 5496322f)
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交(HEAD 仍 abe6919b)
- Project-HAMi/ascend-device-plugin — 无新提交(HEAD 仍 771e19f8)
- Project-HAMi/HAMi-WebUI — 无新提交(HEAD 仍 fa9b560d,Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=91f024838dc5cd428f428a08f3a6f259efa1bd1f branch=master release=v2.9.0 scanned=2026-08-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-11 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=abe6919b389e98d33af1d8dd1c7d4fee6874102c branch=main release=— scanned=2026-08-11 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-11 -->
