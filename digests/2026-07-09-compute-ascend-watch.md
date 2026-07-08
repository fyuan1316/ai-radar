# 昇腾算力栈 diff 雷达 2026-07-09

## 摘要
- **今日主线是 DRA 原生软虚拟化落地**:`npu-dra-plugin` 合入 "Support software NPU virtualization in DRA Plugin"(!26),新增第三种共享策略 `SoftSharing`(前两种是 TimeSlicing/SpacePartitioning),配套 `SoftSharingConfig`(aicoreQuota/memoryQuotaMB/policy)、新包 `internal/vnpu/soft_manager.go`(基于 **vCANN-RT** 运行时,把物理 NPU 切成多 vNPU 写 `npu_info.config` + shm),并把 `DeviceState.vnpuManager` 从单实例改为 `map[string]VNPUManager`(noop/hard/soft 按 flag 选择)。这是昇腾软切分继 mind-cluster device-plugin 路径、vNPU 仓 npu-smi 路径之后的**第三条实现路线,且是唯一走 K8s DRA + 动态 ResourceSlice 属性更新的**。
- mind-cluster 本期实质代码只有两处(其余是 8 个组件 README 的 markdown 格式统一 + taskd 回退域名链接,均为噪声):npu-exporter 把 CRI 客户端默认切到 `v1alpha2` 并在收到 `Unimplemented` 时自动回退 `v1`(兼容旧版 docker/k8s 场景);ascend-device-plugin 修软切分下 `kltDev` 注解随重调度叠加后缀的 bug(设备映射改为 real→real)。
- 其余 7 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin)全无新提交。
- mind-cluster tag 从 v26.0.1 走到 v26.1.0.beta.2(进入下一 minor 的 beta)。

## 当日重要改变
- npu-dra-plugin [新能力][架构方向] DRA 插件新增软 NPU 虚拟化:`api/sharing.go` 加 `SoftSharingStrategy` 及 `SoftSharingConfig{AICoreQuota,MemoryQuotaMB,Policy}`,新增独立包 `internal/vnpu/soft_manager.go`(vCANN-RT 后端)。证据文件 Ascend-npu-dra-plugin/api/sharing.go、internal/vnpu/soft_manager.go。https://gitcode.com/openFuyao/npu-dra-plugin/compare/dbffd7942b003f1bd4880861c167aa7a0410c9ca...98f8fa5e34726e82f6dee560e0d510750845ff49
- npu-dra-plugin [架构方向] `DeviceState.vnpuManager` 由单一 `VNPUManager` 改为 `map[string]VNPUManager`(noop/hard/soft),soft 仅在 `--share-count>1` 时注册;新增 `updateDevices` goroutine 消费 `SoftDeviceUpdate` 通道动态改写 ResourceSlice 设备属性 `allocation_mode`。证据文件 cmd/ascend-npu-dra-kubeletplugin/state.go、driver.go。同上 compare 链接
- mind-cluster [新能力] npu-exporter CRI 采集回退 v1alpha2 以兼容旧 docker/k8s:`initCriClient` 默认改用 `v1alpha2.NewRuntimeServiceClient`,`GetContainers` 先试 v1alpha2、命中 `Unimplemented` 再退回 v1。证据文件 component/npu-exporter/collector/container/runtime_ops.go。https://gitcode.com/Ascend/mind-cluster/compare/47c436e3d52121a4c1f67c36e5138fbf688d06bb...c836864aa50044c463790eb8b2f9e4d7fa7c321f
- mind-cluster [修复] ascend-device-plugin 软切分设备映射 real→real,修 `kltDev` 注解随后续调度叠加后缀:`generateAllDeviceMap` 在 `IsSupportSoftShareDevice()` 时把 `vol2KlDevMap[r]=r` 而非 `=k`,避免引入虚拟设备 ID 映射。证据文件 component/ascend-device-plugin/pkg/server/plugin.go。同上 mind-cluster compare 链接

## npu-dra-plugin: dbffd794 -> 98f8fa5e
- 比较: https://gitcode.com/openFuyao/npu-dra-plugin/compare/dbffd7942b003f1bd4880861c167aa7a0410c9ca...98f8fa5e34726e82f6dee560e0d510750845ff49 | tag: v26.6.0 | commits=2 | truncated=false

### AI 总结重点(源码 diff 为据)

- **新增第三种共享策略 `SoftSharing` 及其配置结构**。在原有 `TimeSlicingStrategy`/`SpacePartitioningStrategy` 之外加 `SoftSharingStrategy`,`GpuSharing` 结构新增 `SoftSharingConfig` 字段,并加 `IsSoftSharing()` 与 `GetSoftSharingConfig()`(后者显式互斥:同时带 TimeSlicing/SpacePartitioning 配置即报错)。软切分配额通过 `AICoreQuota`(1-100 AI Core 算力百分比)、`MemoryQuotaMB`(HBM MB)、`Policy`(fixed-share/elastic/best-effort)声明。
  <details><summary>代码依据 Ascend-npu-dra-plugin/api/sharing.go</summary>

  ```diff
  +	SoftSharingStrategy       GpuSharingStrategy = "SoftSharing"
  ...
  +	SoftSharingConfig       *SoftSharingConfig       `json:"softSharingConfig,omitempty"`
  ...
  +type SoftSharingConfig struct {
  +	AICoreQuota   int    `json:"aicoreQuota,omitempty"`   // AI Core 算力时间百分比 (1-100)
  +	MemoryQuotaMB int    `json:"memoryQuotaMB,omitempty"` // HBM 内存配额 MB
  +	Policy        string `json:"policy,omitempty"`        // fixed-share / elastic / best-effort
  +}
  +func (s *GpuSharing) IsSoftSharing() bool { return s != nil && s.Strategy == SoftSharingStrategy }
  ```
  </details>

- **`api.Normalize` 给 SoftSharing 补默认配额**:策略为 SoftSharing 且未带 config 时,默认 `AICoreQuota=100, MemoryQuotaMB=0, Policy="elastic"`(即默认整卡算力、内存不限、弹性策略——等价"软共享但不设硬上限")。
  <details><summary>代码依据 Ascend-npu-dra-plugin/api/api.go</summary>

  ```diff
  +	if c.Sharing.Strategy == SoftSharingStrategy && c.Sharing.SoftSharingConfig == nil {
  +		c.Sharing.SoftSharingConfig = &SoftSharingConfig{
  +			AICoreQuota: 100, MemoryQuotaMB: 0, Policy: "elastic",
  +		}
  +	}
  ```
  </details>

- **新增独立包 `internal/vnpu/soft_manager.go`(315 行),基于 vCANN-RT 的软 vNPU 生命周期管理**。`SoftManager` 实现 `VNPUManager`:`NewSoftVNPUManager(shareCount, baseDir, shmDir)` 持有 `baseConfigDir`(默认 `/etc/enpu`)、`shmDir`(默认 `/dev/shm`)、每物理卡的 `vNPUCounter map[int]sets.Int` 计数、以及带 100 缓冲的 `updater chan SoftDeviceUpdate`。`CreateVNPU` 按 `getNextVNPUID` 分配 vNPU 号并把 `SoftVNPUConfig`(物理/虚拟 NPU ID、AICoreQuota、MemoryQuotaMB、ShmID、Policy)落成 `npu_info.config` 供容器内 vCANN-RT(挂载 `/etc/enpu/vcann-rt`)读取。
  <details><summary>代码依据 Ascend-npu-dra-plugin/internal/vnpu/soft_manager.go(新增)</summary>

  ```diff
  +type SoftManager struct {
  +	baseConfigDir string
  +	shmDir        string
  +	vNPUCounter   map[int]sets.Int
  +	shareCount    int
  +	updater chan profiles.SoftDeviceUpdate
  +}
  +func NewSoftVNPUManager(shareCount int, baseDir string, shmDir string) profiles.VNPUManager { ... }
  +func (m *SoftManager) CreateVNPU(params profiles.CreateVNPUParams) (...) {
  +	virtualNPUID := m.getNextVNPUID(params.NPUID, params.SchedulingPolicy) ... }
  ```
  </details>

- **`VNPUManager` 接口新增 `DeviceUpdater() chan SoftDeviceUpdate`,支持运行时动态改写设备分配态**。`SoftDeviceUpdate{DeviceName, AllocationMode}`,AllocationMode 取值 unbound/fixed/elastic/best-effort。这让 soft 管理器能在 vNPU 创建/回收后异步通告设备状态变化,而非静态枚举。
  <details><summary>代码依据 doc/soft-vnpu.md(接口定义) + internal/profiles</summary>

  ```go
  type VNPUManager interface {
      CreateVNPU(params CreateVNPUParams) (*CreateVNPUOutcome, error)
      DeleteVNPU(deleteRef string) error
      DeviceUpdater() chan SoftDeviceUpdate  // 新增:动态状态更新
  }
  type SoftDeviceUpdate struct { DeviceName string; AllocationMode string }
  ```
  </details>

- **`DeviceState.vnpuManager` 从单实例改为 `map[string]VNPUManager`,按 flag 选管理器**。原逻辑仅当 `Profile=="npu" && enableHardVNPU` 时用 `NewNPUSMIManager()`;新逻辑 `getVNPUManagersFromConfigAndDeviceUpdater` 建 map:`noop` 恒有,`hard` 在 `enableHardVNPU` 时用 npu-smi,`soft` 在 `shareCount>1` 时用 `NewSoftVNPUManager` 并取其 `DeviceUpdater()` 通道存入 `DeviceState.updater`。硬/软虚拟化从"二选一开关"变成"可并存的多后端"。
  <details><summary>代码依据 cmd/ascend-npu-dra-kubeletplugin/state.go</summary>

  ```diff
  -	vnpuManager       profiles.VNPUManager
  +	vnpuManager       map[string]profiles.VNPUManager
  +	updater           chan profiles.SoftDeviceUpdate
  ...
  +	vm["noop"] = profiles.NoopVNPUManager
  +	if config.flags.enableHardVNPU { vm[npu.HardVNPUMode] = vnpu.NewNPUSMIManager() }
  +	if config.flags.shareCount > 1 {
  +		vm[npu.SoftVNPUMode] = vnpu.NewSoftVNPUManager(config.flags.shareCount,
  +			config.flags.softShareDevConfigDir, config.flags.softShareShmDir)
  +		updater = vm[npu.SoftVNPUMode].DeviceUpdater()
  +	}
  ```
  </details>

- **`driver.go` 新增 `updateDevices` goroutine,把 `SoftDeviceUpdate` 落到 ResourceSlice 设备属性 `allocation_mode`**。消费 updater 通道,用 `findDeviceInDriverResources` 定位设备后写 `device.Attributes["allocation_mode"]=update.AllocationMode`,实现 DRA 侧设备可分配状态的动态发布(而非重启才更新)。这是走 K8s DRA `resourceslice` 原生模型、区别于 device-plugin 静态上报的关键点。
  <details><summary>代码依据 cmd/ascend-npu-dra-kubeletplugin/driver.go</summary>

  ```diff
  +func updateDevices(ctx context.Context, devices resourceslice.DriverResources,
  +	updater chan profiles.SoftDeviceUpdate, helper *kubeletplugin.Helper) {
  +	case update, ok := <-updater:
  +		key, sliceIndex, deviceIndex := findDeviceInDriverResources(devices, update.DeviceName)
  +		device.Attributes["allocation_mode"] = resourceapi.DeviceAttribute{
  +			StringValue: ptr.To(update.AllocationMode) }
  ```
  </details>

- **NPU Profile 引入软/硬 ID 映射配置 `ProfileConfig`,由 `--npu-profile-config`(dra.config yaml)注入**。`npu.go` 加 `ProfileConfig{HardIds,SoftIds,SoftShareMounts}` 与 `NewProfileWithSoftShare`,把物理卡分为"硬虚拟化用的 hardIds"和"软共享用的 softIds",softShareMounts 声明要 rbind 进容器的 vCANN-RT 库(libvruntime.so、enpu-monitor、ld.so.preload 等)。main.go 新增 4 个 flag:`--share-count`(每卡软 vNPU 数 1-100)、`--soft-share-dev-config-dir`、`--soft-share-shm-dir`、`--npu-profile-config`。
  <details><summary>代码依据 internal/profiles/npu/npu.go + cmd/.../main.go + manifests/soft-vnpu-daemonset-template.yaml</summary>

  ```diff
  +type ProfileConfig struct {
  +	HardIds         []int            `yaml:"hardIds"`
  +	SoftIds         []int            `yaml:"softIds"`
  +	SoftShareMounts []SoftShareMount `yaml:"softShareMounts"`
  +}
  +func NewProfileWithSoftShare(nodeName string, numNPUs int, shareCount int, config ProfileConfig) Profile { ... }
  ```
  ```diff
  +	&cli.IntFlag{ Name: "share-count", Usage: "Number of soft-share vNPU instances per physical NPU (1-100)." ...}
  +	&cli.StringFlag{ Name: "soft-share-dev-config-dir", Value: "/etc/enpu" ...}
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾软切分正式补齐 DRA 原生路线,形成"三条并行实现"格局**:mind-cluster device-plugin(softShareDevConfigDir + volcano 注解)、vNPU 仓(npu-smi device-share + 节点锁)、以及本仓 DRA(SoftSharing 策略 + ResourceSlice 动态属性 + vCANN-RT)。三者都指向"物理 NPU 软切分",但只有 DRA 路线用 K8s 1.32+ 原生 DRA 模型且支持运行时改设备态,是最贴近上游(对标 NVIDIA DRA driver 的 TimeSlicing/MPS)的一条。证据覆盖 sharing.go 策略枚举、state.go 多后端 map、driver.go 动态更新,未见 SoftManager 与 vCANN-RT 的实际 IPC/配额 enforcement 细节(soft_manager.go 只见到前 80 行框架)。
- **软/硬 vNPU 可并存是架构信号**:vnpuManager 从开关变 map、Profile 分 hardIds/softIds,意味着同节点可同时有硬切分(npu-smi vnpu)和软切分(vCANN-RT)的卡,DRA 插件按 device 分派到不同 manager。这比 device-plugin 的"整机一种模式"更细粒度。证据覆盖 state.go 的 map 装配,未见 Allocate/NodePrepareResources 侧如何据 device 名路由到 soft vs hard manager。
- **软切分配额语义已定型但强度未知**:AICoreQuota(算力时间百分比)+ MemoryQuotaMB + Policy(fixed/elastic/best-effort)是完整的配额三元组,但实际隔离由容器内 vCANN-RT 运行时(libvruntime.so preload)做,属"软隔离/尽力而为"而非硬件强隔离——与 HAMi-core 的 CUDA hook 同类。证据覆盖配置结构与挂载清单,未见运行时是否真能限制越界(enforcement 代码不在本仓)。

## mind-cluster: 47c436e3 -> c836864a
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/47c436e3d52121a4c1f67c36e5138fbf688d06bb...c836864aa50044c463790eb8b2f9e4d7fa7c321f | tag: v26.1.0.beta.2 | commits=18 | truncated=false

### AI 总结重点(源码 diff 为据)

- **npu-exporter CRI 采集默认切 v1alpha2 + Unimplemented 自动回退 v1**(修复标题:回退 cri-api 至 0.25.13 兼容旧版 docker 场景的 k8s)。`initCriClient` 对非 isulad 端点由 `criv1.NewRuntimeServiceClient` 改为 `v1alpha2.NewRuntimeServiceClient`;`GetContainers` 先按 v1alpha2 取容器,若 `isUnimplementedError(err, "runtime.v1alpha2.RuntimeService")` 命中(gRPC code=Unimplemented 且 message 含该服务名)则新建 `criv1` client 重试。即优先用旧 alpha2 API,新版才回退 v1——为兼容仍只暴露 v1alpha2 的旧 docker/containerd 运行时。
  <details><summary>代码依据 component/npu-exporter/collector/container/runtime_ops.go</summary>

  ```diff
  -	operator.criClient = criv1.NewRuntimeServiceClient(criConn)
  +	operator.criClient = v1alpha2.NewRuntimeServiceClient(criConn)
  ...
  -	if client, ok := operator.criClient.(criv1.RuntimeServiceClient); ok {
  -		return getContainersByContainerdV1(ctx, client)
  +	if client, ok := operator.criClient.(v1alpha2.RuntimeServiceClient); ok {
  +		containers, err := getContainersByContainerdV1alpha2(ctx, client)
  +		if isUnimplementedError(err, criV1alpha2) {
  +			v1Client := criv1.NewRuntimeServiceClient(operator.criConn)
  +			return getContainersByContainerdV1(ctx, v1Client)
  +		}
  +		return containers, err
  +	}
  +func isUnimplementedError(err error, serviceName string) bool {
  +	st, ok := status.FromError(err)
  +	if ok { return st.Code() == codes.Unimplemented && strings.Contains(st.Message(), serviceName) } ... }
  ```
  </details>

- **ascend-device-plugin 软切分设备映射改 real→real,修 kltDev 注解重调度叠加后缀**(标题:软切分场景任务 Pod 的 `huawei.com/kltDev` 注解随后续 Pod 调度异常叠加后缀问题修复)。`generateAllDeviceMap` 构建 `vol2KlDevMap` 时,软切分场景(`IsSupportSoftShareDevice()`)把 real→real 直映射并 `continue`,不再走 real→klt(k)的虚拟设备 ID 映射,避免注解里 kltDev 值在多次调度后叠加错误后缀。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/plugin.go</summary>

  ```diff
   for k, r := range ps.klt2RealDevMap {
  +	// Soft share: real → real, avoiding the introduction of virtual device ID mapping
  +	if common.IsSupportSoftShareDevice() {
  +		vol2KlDevMap[r] = r
  +		continue
  +	}
   	vol2KlDevMap[r] = k
   }
  ```
  </details>

- **其余为噪声**:8 个组件 README(ascend-for-volcano/ascend-device-plugin/infer-operator/clusterd/ascend-operator/npu-exporter/noded 等)统一 markdown 有序列表/代码块围栏格式(`1.  `→`1. `、补 ```text 语言标注),无逻辑变化;taskd 两条"回退使用域名""使用域名链接 clusterd"未落入本次 patch 节选(信号文件里无对应 .go),仅据标题记录不作符号级研判。

### 后续发展方向 [AI]
- **npu-exporter 在向后兼容上做妥协**:默认走 v1alpha2、失败才升 v1,说明现网仍有大量只认 v1alpha2 CRI 的旧运行时(老 docker-shim/containerd),监控采集优先保存量兼容而非追新 API。证据仅 runtime_ops.go 客户端选择与回退逻辑,未见对应最低支持版本矩阵。
- **软切分 bug 持续收口**:继 07-08 修 Allocate 挂卡后,今日修 kltDev 注解叠加,连续两日都是软切分调度侧边界修复,印证软切分处于产品化打磨末期而非新特性期。证据仅 generateAllDeviceMap 一处映射改动,未见 IsSupportSoftShareDevice 判定条件本身是否变化。

## 本期无实质改动(折叠)
<details><summary>7 个 openFuyao 仓无新提交</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- vNPU(8c58a454,无新提交)
- npu-node-provision(717ef777,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=c836864aa50044c463790eb8b2f9e4d7fa7c321f tag=v26.1.0.beta.2 scanned=2026-07-09 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=v26.6.0 scanned=2026-07-09 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-09 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=v26.6.0 scanned=2026-07-09 -->
<!-- ANCHOR repo=vNPU sha=8c58a454b89831edc3b1f51a22b24852c5e5f24f tag=v0.1.0 scanned=2026-07-09 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-09 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-09 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-09 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-09 -->
</content>
</invoke>
