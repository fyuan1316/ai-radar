# NVIDIA 算力栈 diff 雷达 2026-11-22

## 摘要
- **DRA 驱动新增 claim 级 local IPC 目录(alpha 特性门)**:新 config kind `LocalIPCConfig` + 新组件 `LocalIPCManager`,给同一个 ResourceClaim 的所有容器注入一块 per-claim tmpfs(`/run/nvidia-dra/local-ipc`,`size=64k,nr_inodes=1024,mode=1777,noexec`)和环境变量 `NVIDIA_DRA_LOCAL_IPC_DIR`。这是 DRA 第一次把"claim 级(而非 device 级)CDI edit"做成公开 API——为 UNIX socket 跨容器通信(典型即 vLLM/NCCL 这类同节点多进程)提供官方通道。
- **DRA 驱动修了 Fabric Manager 分区激活与 GPU persistence 的时序 bug**:`Manager.ActivatePartition` 签名加了 `prepare func() error` 回调,激活前先关掉本分区所有 GPU 的 persistence 模式(否则 FM 报 `NV_ERR_IN_USE`),并在激活前新增"与活跃分区 GPU 重叠"检查;释放时对不走 VFIO 的整卡 claim 补回 persistence。NVSwitch 多卡分区路径的可靠性问题。
- **gpu-operator 默认驱动跨档 595 → 620,driver-container 跟进 R620 的打包方式变更**:fabric manager / IMEX 从 `nvidia-fabricmanager`/`nvidia-imex` 改为独立版本化的 `-direct` 包,靠 `nvidia-driver-pinning-${DRIVER_VERSION}` 锁版本;CSV 里 `driver-image-610`/`-615` 被删、补了 `driver-image-595`。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [新能力] 新增 `api/nvidia.com/resource/v1beta1/localipcconfig.go`(`LocalIPCConfig{Enabled bool}`)+ 新 package 级文件 `cmd/gpu-kubelet-plugin/local_ipc.go`(309 行),`api.go` 注册 `LocalIPCConfigKind`,受新 feature gate `LocalIPCDirectory`(alpha,默认 false,起始版本 0.6)约束。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/095cabc0a8
- kubernetes-sigs/dra-driver-nvidia-gpu [API/CRD变更] `CDIHandler.CreateClaimSpecFile` 签名新增第三参 `claimContainerEdits *cdiapi.ContainerEdits`,CDI spec 第一次支持 claim 级(非 device 级)container edits;webhook 新增校验:`LocalIPCConfig` 带 `requests` 选择器直接拒绝。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/da882883c9
- kubernetes-sigs/dra-driver-nvidia-gpu [API/CRD变更] `fabricmanager.Manager.ActivatePartition(partitionID int)` → `ActivatePartition(partitionID int, prepare func() error)`,内部实现从 `isPartitionActivated` 单点查询改为全量拉 `GetSupportedFabricPartitions()` 后做重叠检测。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/9e2cba5826
- NVIDIA/gpu-operator [版本跨档] 默认 driver version `595.91.07` → `620.70.06`(values.yaml + nvidiadriver 样例 + CSV relatedImages 全套),同时 CSV 删掉 `driver-image-610`、`driver-image-615` 两个 relatedImage。 https://github.com/NVIDIA/gpu-operator/commit/61095f51e5
- NVIDIA/gpu-operator [API/CRD变更] `api/nvidia/v1/clusterpolicy_types.go` 与 `api/nvidia/v1alpha1/nvidiadriver_types.go` 的 Age printcolumn `type=string` → `type=date`,四份 CRD yaml(config/crd、deployments/crds、bundle/manifests)同步重生成。 https://github.com/NVIDIA/gpu-operator/commit/b041816df7
- NVIDIA/gpu-operator [弃用/移除] `values.yaml` 里 `operator.podDisruptionBudget.enabled: true` 这个显式默认值被删成 `podDisruptionBudget: {}`,改由模板内 `dig "enabled" true` 兜默认;新增 render 期硬失败:显式 `enabled=true` 且 `replicaCount<=1` 直接 `fail`。 https://github.com/NVIDIA/gpu-operator/commit/f9c12b48a8
- NVIDIA/gpu-driver-container [新能力] R620+ 在 Ubuntu 22.04/24.04 precompiled 路径改装 `nvidia-fabricmanager-direct` / `nvidia-imex-direct`,新增 `nvidia-driver-pinning-${DRIVER_VERSION}` 版本锁与 `apt-mark hold`。 https://github.com/NVIDIA/gpu-driver-container/commit/bc4df2b897

## kubernetes-sigs/dra-driver-nvidia-gpu: 9ca111cf -> 44cf296c
- 比较: 9ca111cffd06cf9686b704ea5eb85771781cc2b0 -> 44cf296c | ahead=10 | files=27 | Release: v0.5.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/9ca111cffd06cf9686b704ea5eb85771781cc2b0...44cf296cdfb787ec2155a5ffae11763cb7e92c7e

### AI 总结重点(源码 diff 为据)
- **新增 claim 级 local IPC 目录,是 DRA 配置面上第一个"不绑 request"的 config kind**:`LocalIPCConfig` 只有一个 `Enabled bool` 字段,`Validate()` 把 feature gate 检查写进 API 对象自身——gate 关着时声明 `enabled: true` 会被 API 校验直接拒掉,而不是运行期静默忽略。

  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/localipcconfig.go(新增)</summary>

  ```diff
  +// LocalIPCConfig enables a claim-scoped directory for same-node local IPC.
  +// It must be specified without a requests selector because the directory is
  +// injected as a claim-level CDI edit.
  +type LocalIPCConfig struct {
  +	metav1.TypeMeta `json:",inline"`
  +	Enabled         bool `json:"enabled"`
  +}
  +
  +func (c *LocalIPCConfig) Validate() error {
  +	if c.Enabled && !featuregates.Enabled(featuregates.LocalIPCDirectory) {
  +		return fmt.Errorf("local IPC directory is requested, but the %q feature gate is not enabled", featuregates.LocalIPCDirectory)
  +	}
  +	return nil
  +}
  ```
  </details>

  <details><summary>代码依据 pkg/featuregates/featuregates.go</summary>

  ```diff
  +	// LocalIPCDirectory allows a claim-scoped directory to be injected into
  +	// workload containers for same-node local IPC.
  +	LocalIPCDirectory featuregate.Feature = "LocalIPCDirectory"
  ...
  +	LocalIPCDirectory: {
  +		{
  +			Default:    false,
  +			PreRelease: featuregate.Alpha,
  +			Version:    version.MajorMinor(0, 6),
  +		},
  +	},
  ```
  </details>

- **目录由 per-claim tmpfs 支撑,资源上限写死在 mount options 里**:不是普通 hostPath 子目录,每个 claim 单独 mount 一个 tmpfs,`size=64k` + `nr_inodes=1024`;注释点明真正的闸门是 inode 数(UNIX socket 占 inode 不占数据页)。挂载点权限 `mode=1777`(sticky),容器内固定路径 `/run/nvidia-dra/local-ipc`,并注入 `NVIDIA_DRA_LOCAL_IPC_DIR` 环境变量让负载自己发现。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/local_ipc.go(新增)</summary>

  ```diff
  +// Each claim directory is backed by its own tmpfs so that workloads cannot
  +// fill the node's disk or inodes. UNIX sockets use an inode but no data
  +// pages, so nr_inodes is the real limit; size only bounds small regular
  +// files, which cost one page each.
  +var localIPCMountOptions = []string{"rw", "nosuid", "nodev", "noexec", "mode=1777", "size=64k", "nr_inodes=1024"}
  +
  +func (i *LocalIPCInfo) GetCDIContainerEdits() *cdiapi.ContainerEdits {
  +	return &cdiapi.ContainerEdits{
  +		ContainerEdits: &cdispec.ContainerEdits{
  +			Env: []string{"NVIDIA_DRA_LOCAL_IPC_DIR=" + i.ContainerPath},
  +			Mounts: []*cdispec.Mount{{
  +				ContainerPath: i.ContainerPath,
  +				HostPath:      i.HostPath,
  +				Options:       []string{"rw", "nosuid", "nodev", "noexec", "bind"},
  +			}},
  +		},
  +	}
  +}
  ```
  </details>

- **CDI spec 生成路径被改造以承载 claim 级 edit**:`CreateClaimSpecFile` 新增 `claimContainerEdits` 参数,把 claim 级 edit 追加到原来的 `commonEdits`(设备节点、驱动库那套)之后,语义是"本 claim 的任一设备被注入时就生效"。这解决了 local IPC 的本质问题:目录属于 claim 而非某块 GPU,没法挂在 device edit 上。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/cdi.go</summary>

  ```diff
  -func (cdi *CDIHandler) CreateClaimSpecFile(claimUID string, preparedDevices PreparedDevices) error {
  +func (cdi *CDIHandler) CreateClaimSpecFile(claimUID string, preparedDevices PreparedDevices, claimContainerEdits *cdiapi.ContainerEdits) error {
  ...
  +	if claimContainerEdits != nil {
  +		// Claim-level edits apply whenever any device from this claim-specific
  +		// CDI spec is injected.
  +		commonEdits = (&cdiapi.ContainerEdits{}).Append(commonEdits).Append(claimContainerEdits)
  +	}
  ```
  </details>

- **生命周期做全了:Prepare / Restore / Remove / Reconcile 四态,且 unprepare 失败不删 checkpoint**:`DeviceState` 新增 `localIPCManager` 字段;`Unprepare` 里 local IPC 清理失败直接 `return false, err`——注释明确宁可让 kubelet 重试,也不能留下无主的可写目录。新增 `reconcileCheckpointState()` 在启动恢复时按 checkpoint 重建应有目录、删掉多余目录(孤儿 tmpfs 回收)。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  +	if err := s.localIPCManager.Remove(claimUID); err != nil {
  +		// Keep the checkpoint entry so kubelet can retry cleanup instead of
  +		// orphaning a writable claim directory.
  +		return false, fmt.Errorf("unable to remove local IPC directory for claim %s: %w", claimRef.String(), err)
  +	}
  ...
  +func (s *DeviceState) reconcileCheckpointState(cp *Checkpoint) error {
  +	if err := s.localIPCManager.Reconcile(cp.V2.PreparedClaims); err != nil {
  +		return fmt.Errorf("unable to reconcile local IPC directories: %w", err)
  +	}
  +	syncPreparedDevicesGaugeFromCheckpoint(s.config.flags.nodeName, cp)
  +	return nil
  +}
  ```
  </details>

- **解码路径刻意分两档:Prepare 走 StrictDecoder + Validate,checkpoint 恢复走 NonstrictDecoder 且不校验**。效果是"gate 后来被关掉"或"checkpoint 里存着新版本才有的 config kind"都不会让 plugin 启不来——`NewDeviceState` 的注释明说要保留 manager 以便恢复/删除已有 claim。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/local_ipc.go + device_state.go</summary>

  ```diff
  +func getLocalIPCConfig(allocation *resourceapi.AllocationResult) (*configapi.LocalIPCConfig, error) {
  +	result, err := decodeLocalIPCConfig(configapi.StrictDecoder, allocation)
  +	...
  +	if err := result.Validate(); err != nil { return nil, err }
  +}
  +
  +func getCheckpointLocalIPCConfig(allocation *resourceapi.AllocationResult) (*configapi.LocalIPCConfig, error) {
  +	return decodeLocalIPCConfig(configapi.NonstrictDecoder, allocation)
  +}
  +		// Inspect TypeMeta before runtime decoding so checkpoint recovery can
  +		// ignore unrelated config kinds added by newer driver versions.
  ...
  +	// Keep the manager available when the gate is disabled so previously
  +	// prepared claims can still be restored and removed.
  +	localIPCManager := NewLocalIPCManager(config.DriverPluginPath(), mount.New(""))
  ```
  </details>

- **路径安全按"不信任 claim UID"写**:`claimPath()` 同时查 `filepath.Base(claimUID) != claimUID` 与 `filepath.Rel` 是否逃逸;`ensureDirectory`/`removeClaimPath`/`validateRoot` 全用 `os.Lstat` 拒绝符号链接,挂载前先 `IsMountPoint` 判重(否则二次挂载会把活着的 socket 盖掉)。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/local_ipc.go</summary>

  ```diff
  +func (m *LocalIPCManager) claimPath(claimUID string) (string, error) {
  +	if claimUID == "" || claimUID == "." || claimUID == ".." || filepath.Base(claimUID) != claimUID {
  +		return "", fmt.Errorf("invalid claim UID %q", claimUID)
  +	}
  +	path := filepath.Join(m.root, claimUID)
  +	rel, err := filepath.Rel(m.root, path)
  +	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
  +		return "", fmt.Errorf("claim UID %q escapes local IPC root", claimUID)
  +	}
  +	// Restore and Reconcile call this for directories that may already be
  +	// mounted; mounting again would hide the live sockets underneath.
  +	mounted, err := m.mounter.IsMountPoint(path)
  ```
  </details>

- **Fabric Manager 分区激活的 persistence 时序 bug 修复**:`ActivatePartition` 从"查一下激活状态就激活"改成"全量拉分区表 → 确认目标仍被支持 → 查 GPU 与活跃分区是否重叠 → 跑 prepare 回调 → 再激活"。prepare 回调由 `device_state.go` 传入,内容是关掉本分区所有 GPU 的 persistence。根因注释写得很直接:persistence 让 GPU 一直 initialized,FM 会返 `NV_ERR_IN_USE`;VFIO 路径的 Configure 本来会顺手关 persistence,但它跑在激活之后,且整卡容器 claim 根本不走 VFIO。

  <details><summary>代码依据 pkg/fabricmanager/manager.go</summary>

  ```diff
  -func (m *Manager) ActivatePartition(partitionID int) error {
  +func (m *Manager) ActivatePartition(partitionID int, prepare func() error) error {
  -	activated, err := m.isPartitionActivated(partitionID)
  +	partitions, err := m.client.GetSupportedFabricPartitions()
  ...
  +	if target == nil {
  +		return fmt.Errorf("fabricmanager: partition %d is no longer supported", partitionID)
  +	}
  +	// Preparation may change GPU state, so reject conflicts before invoking it.
  +	physicalIDs := target.GPUPhysicalIDs()
  +	for _, partition := range partitions {
  +		if !partition.IsActive { continue }
  +		for _, gpu := range partition.GPUs {
  +			if slices.Contains(physicalIDs, gpu.PhysicalID) {
  +				return fmt.Errorf("fabricmanager: partition %d overlaps active partition %d", partitionID, partition.ID)
  +			}
  +		}
  +	}
  +	if prepare != nil {
  +		if err := prepare(); err != nil {
  +			return fmt.Errorf("fabricmanager: preparing partition %d: %w", partitionID, err)
  +		}
  +	}
  ```
  </details>

- **对称地,释放分区时给"不走 VFIO 的整卡 claim"补回 persistence**:`deactivateFabricPartition` 在 FM 去激活成功后,遍历该 claim 的 `GpuDeviceType` 设备逐个 `enableGPUPersistenceMode`。注释点出缺口所在:整卡 claim 留在 NVIDIA 驱动上,不经过 VFIO Unconfigure,所以之前没人把 persistence 开回来。顺带把 `nvlib.go` 里的 `nvml.DeviceGetPersistenceMode(device)` 改成方法式 `device.GetPersistenceMode()`。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
   	if err := s.fmManager.DeactivatePartition(partitionID); err != nil {
   		return fmt.Errorf("deactivating fabric partition %d: %w", partitionID, err)
   	}
  +	// Full GPUs stay on the NVIDIA driver and do not pass through VFIO
  +	// Unconfigure, which restores persistence. Enable it only after the
  +	// partition is inactive, including on retries after partial cleanup.
  +	for _, device := range s.getAllocatableDevicesForClaim(claimUID, *pc) {
  +		if device.Type() != GpuDeviceType { continue }
  +		gpu := device.Gpu
  +		if err := s.nvdevlib.enableGPUPersistenceMode(gpu.pciBusID); err != nil {
  +			return fmt.Errorf("enabling persistence for GPU %s (PCI %s): %w", gpu.UUID, gpu.pciBusID, err)
  +		}
  +	}
  ```
  </details>

- **webhook 补了 API 校验不到的那一层**:`LocalIPCConfig` 要求必须不带 `requests` 选择器,但 `requests` 字段在 opaque 对象之外,`LocalIPCConfig.Validate()` 看不见,所以在 `admitResourceClaimParameters` 里单独判一次并给出带 JSON path 的报错。同一处逻辑在 `local_ipc.go` 的解码路径里也有一份(双保险)。

  <details><summary>代码依据 cmd/webhook/main.go</summary>

  ```diff
  +		case *nvapi.LocalIPCConfig:
  +			configInterface = castConfig
  ...
  +		// LocalIPCConfig is claim-scoped, but Requests is outside the opaque
  +		// object and cannot be checked by LocalIPCConfig.Validate.
  +		if _, ok := decodedConfig.(*nvapi.LocalIPCConfig); ok && len(config.Requests) != 0 {
  +			requestsPath := fmt.Sprintf("%s.devices.config[%d].requests", specPath, configIndex)
  +			errs = append(errs, fmt.Errorf("local IPC config at %s must not select individual requests", requestsPath))
  +			continue
  +		}
  ```
  </details>

### 后续发展方向 [AI]
- **DRA 驱动正在把 "claim" 坐实为一等资源边界,而不只是一组设备的句柄**:`LocalIPCConfig` 是第一个显式声明"不得绑 request"的 config kind,配套的 `CreateClaimSpecFile` 新参数把 claim 级 CDI edit 变成可复用的机制。这条路一旦铺好,后续"claim 级共享 shm、claim 级 NCCL 配置、claim 级临时卷"都能走同一入口。证据覆盖 API + CDI + kubelet plugin 三处 hunk,未见 Helm chart 暴露 `LocalIPCDirectory` gate(本期 `deployments/helm/` 无改动),所以当前只能通过 driver 启动参数开。
- **NVSwitch/IMEX 多卡分区路径仍在补时序正确性,不是新增能力**:两个 fix 都指向同一类问题——GPU 状态(persistence)与 FM 分区生命周期是两套独立的状态机,之前靠 VFIO 路径顺带收敛,整卡容器 claim 一露出就暴了。新增的"分区重叠检测"说明他们开始承认 `GetSupportedFabricPartitions()` 的分区表是会变的(目标分区可能"no longer supported")。证据只覆盖 `ActivatePartition`/`deactivateFabricPartition` 两个函数,未见 ComputeDomain 控制器侧是否也需要同样的重叠检查。
- **对我们产品的启示**:(1) 如果自家产品也在做"同节点多容器共享 GPU + 进程间通信"(PD 分离、sidecar 形态的 tokenizer/router),local IPC 这套 per-claim tmpfs + inode 限额 + `noexec/nosuid` 的做法可以直接抄,比开 hostPath 或 `shareProcessNamespace` 干净;(2) `nr_inodes=1024` 和 `size=64k` 是硬编码常量,大规模 socket 场景会撞上限,接入时要评估是否 fork 调整;(3) FM persistence 时序这类坑说明"整卡直通/整卡容器"在 NVSwitch 机型上和 MIG/VFIO 走的是不同代码路径,自研调度器若复用 DRA 驱动需按形态分别压测。

## NVIDIA/gpu-operator: bf7ada64 -> d338c6bd
- 比较: bf7ada64c97d46edb98b4a7cf54db85e493fac71 -> d338c6bd | ahead=16 | files=34 | Release: v26.7.3
- https://github.com/NVIDIA/gpu-operator/compare/bf7ada64c97d46edb98b4a7cf54db85e493fac71...d338c6bd60db03ef29db86f5ef411b0dca35a85b

### AI 总结重点(源码 diff 为据)
- **默认驱动版本跨档 595.91.07 → 620.70.06**,三处同步(`values.yaml`、`config/samples/nvidia_v1alpha1_nvidiadriver.yaml`、CSV 的 `DRIVER_IMAGE`);CSV 的 relatedImages 列表同时删掉 `driver-image-610`、`driver-image-615`,新增 `driver-image-595` 承接旧 digest。即预发布的 610/615 两个短命分支被 620 取代,595 降为"旧版可选"。CI 的 `TARGET_DRIVER_VERSION` 另走 580 LTS 线(580.178.04 → 580.196.07)。

  <details><summary>代码依据 deployments/gpu-operator/values.yaml + bundle/manifests CSV</summary>

  ```diff
   driver:
     usePrecompiled: false
     repository: nvcr.io/nvidia
     image: driver
  -  version: "595.91.07"
  +  version: "620.70.06"
  ...
       - name: driver-image
  +      image: nvcr.io/nvidia/driver@sha256:1e00f804fd23c18bb4fc77e3e26079b68b487392899437318e25653be5e09ad2
  +    - name: driver-image-595
         image: nvcr.io/nvidia/driver@sha256:e243d778bd83de47668e7629d78f673317a130fedc99941be12aad7fc6bdfa85
       - name: driver-image-580
         image: nvcr.io/nvidia/driver@sha256:fbbd829db234885d6f0026ca6fb6369f6875b0b91fc5e98d7752f31aeab5e470
  -    - name: driver-image-610
  -      image: nvcr.io/nvidia/driver@sha256:a35d05d5b984ad18713af957f87380ccbefd8f0bb5e6771fc7856e6a9e1d201f
  -    - name: driver-image-615
  -      image: nvcr.io/nvidia/driver@sha256:54d5e96cd981acf4525dc1d0bcc4f27acde1fe199bb739dc7cf5923517db66b5
  ```
  </details>

- **DCGM Exporter 镜像 tag 从复合格式退回纯语义化版本**:`4.7.0-4.9.0-distroless` → `4.9.0`,digest 不变(`sha256:2490e1df…`),说明是同一镜像换了 tag 别名;renovate 的 versioning 正则同步改掉。运维影响是:tag 里不再编码"内置 DCGM 库版本",想确认 bundled DCGM 版本得另查(CSV 里独立的 `dcgm-image` 仍停在 `4.7.0-ubi10`)。

  <details><summary>代码依据 .github/renovate.json + values.yaml</summary>

  ```diff
         "matchPackageNames": [ "nvcr.io/nvidia/k8s/dcgm-exporter" ],
  -      "versioning": "regex:^v?(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)-\\d+\\.\\d+\\.\\d+-distroless$",
  +      "versioning": "regex:^v?(?<major>\\d+)\\.(?<minor>\\d+)\\.(?<patch>\\d+)$",
  ...
   dcgmExporter:
  -  version: 4.7.0-4.9.0-distroless
  +  version: 4.9.0
  ```
  </details>

- **ClusterPolicy / NVIDIADriver 的 Age 列从 `type=string` 改成 `type=date`**:kubebuilder printcolumn 注解改动,四份 CRD yaml 重新生成。实际效果是 `kubectl get clusterpolicy` 的 Age 列从打印 RFC3339 时间戳变成 kubectl 的相对时长渲染(`5d`)。属 CRD 规格变更(additionalPrinterColumns),升级时 CRD 需同步 apply。

  <details><summary>代码依据 api/nvidia/v1/clusterpolicy_types.go</summary>

  ```diff
   // +kubebuilder:printcolumn:name="Status",type=string,JSONPath=`.status.state`,priority=0
  -// +kubebuilder:printcolumn:name="Age",type=string,JSONPath=`.metadata.creationTimestamp`,priority=0
  +// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`,priority=0
   type ClusterPolicy struct {
  ```
  </details>

- **operator 自身 HA 的 PDB 配置改成"隐式默认 + 显式冲突硬失败"**:`values.yaml` 里的 `podDisruptionBudget.enabled: true` 被删,只留 `podDisruptionBudget: {}`;默认值下沉到模板 `dig "enabled" true $pdb`(所以单副本仍不生成 PDB、多副本仍生成,默认行为不变)。新增的校验用的是 `dig "enabled" false`——只有用户**显式**写 `enabled: true` 且 `replicaCount<=1` 才 `fail`,避免了"默认值 × 单副本"被自己的校验误伤。这是昨天那批多副本 HA 能力(`replicaCount`/PDB/podAntiAffinity/leader-election-warmup)的配置面收口。

  <details><summary>代码依据 deployments/gpu-operator/templates/validations.yaml</summary>

  ```diff
  +{{- $pdb := .Values.operator.podDisruptionBudget | default dict }}
  +{{- if and (dig "enabled" false $pdb) (le (int .Values.operator.replicaCount) 1) }}
  +{{- fail "operator.podDisruptionBudget.enabled=true requires operator.replicaCount to be at least 2" }}
  +{{- end }}
  ```
  </details>

- **ComputeDomain daemon 的镜像拉取凭据终于能透传**:DRA driver controller deployment 新增环境变量 `CD_DAEMON_IMAGE_PULL_SECRET_NAMES`(逗号拼接 `DRADriver.Spec.ImagePullSecrets`)。原因写在测试注释里:ComputeDomain daemon 的 DaemonSet 是 controller 自己渲染的,operator 没法用 PodSpec 注入,只能把 secret 名字通过环境变量递进去。空列表时该变量不渲染(测试覆盖 unset/empty/single/multiple 四例)。私有/离线 registry 场景的实际阻塞点。

  <details><summary>代码依据 manifests/state-dra-driver/0600_controller-deployment.yaml + internal/state/dra_driver_test.go</summary>

  ```diff
           - name: IMAGE_NAME
             value: {{ .DRADriver.ImagePath | quote }}
  +        {{- if .DRADriver.Spec.ImagePullSecrets }}
  +        - name: CD_DAEMON_IMAGE_PULL_SECRET_NAMES
  +          value: {{ join "," .DRADriver.Spec.ImagePullSecrets | quote }}
  +        {{- end }}
  ...
  +			// The controller renders the ComputeDomain daemon DaemonSets itself, so it
  +			// needs the secret names to set on those pods.
  +			value, found := env["CD_DAEMON_IMAGE_PULL_SECRET_NAMES"]
  ```
  </details>

- **容器运行时探测修了一个"吞错继续"的 bug**:`getContainerRuntime()` 里 OpenShift 版本查询失败原来只打一行 `"failed to retrieve"` 就往下走去列 node 猜运行时,现在改为直接 `return "", err`。新测试显式断言"OpenShift discovery 失败时不得去 list nodes"。其余是 `fmt.Sprintf` → 结构化 kv 日志的批量替换(`state_manager.go`、`object_controls.go`、`main.go`)。

  <details><summary>代码依据 controllers/clusterinfo/clusterinfo.go + clusterinfo_test.go</summary>

  ```diff
   	ocpVersion, err := getOpenshiftVersion(ctx, config)
   	if err != nil {
  -		logger.Error(err, "failed to retrieve")
  +		logger.Error(err, "failed to retrieve OpenShift version")
  +		return "", err
   	}
  ...
  +	require.False(t, nodeListRequested,
  +		"node listing should not happen when OpenShift discovery fails")
  ```
  </details>

### 后续发展方向 [AI]
- **gpu-operator 的 driver 版本策略看起来在收敛成"620 新主线 + 580 LTS"两条**:relatedImages 删 610/615、默认跳到 620、而 CI 的 `TARGET_DRIVER_VERSION` 独立停在 580.x。对需要长期稳定的企业环境,580 LTS 仍是测试覆盖最好的那条线。证据只有镜像清单与 values 的 digest/版本号改动,未见 release note 或 lifecycle 文档说明 610/615 为何退场。
- **ComputeDomain(IMEX/NVLink 域)正在从"demo 能跑"往"离线/私有仓可部署"补洞**:imagePullSecrets 透传这种改动通常是真实客户环境触发的。结合 DRA 侧 FM 分区的两个时序 fix,可以判断 NVSwitch 多卡域这条路径最近才开始承接生产负载。证据覆盖模板 + 测试,未见 ComputeDomain controller 侧消费该环境变量的代码(改动在 DRA driver 仓,本期 diff 未含)。
- **对我们产品的启示**:(1) 默认驱动跳到 620 且 fabric manager/IMEX 改 `-direct` 包,如果自家 driver 容器基于 NVIDIA 的 precompiled 路径二次构建,这次打包方式变更会直接打断构建脚本,需提前跟进 `nvidia-driver-pinning` 机制;(2) DCGM Exporter tag 不再编码内置 DCGM 版本,监控组件的版本矩阵文档要改成按 digest 或另查的方式记录;(3) PDB 这类"默认值写 values 还是写模板"的取舍值得照抄——默认下沉到模板、校验只管显式值,能避免自家 chart 的校验误伤默认安装。

## NVIDIA/gpu-driver-container: db5ac9ce -> 6be32fc9
- 比较: db5ac9ce7c25f3c9cbece0c41d0bd02e6919d2bd -> 6be32fc9 | ahead=2 | files=4 | Release: —
- https://github.com/NVIDIA/gpu-driver-container/compare/db5ac9ce7c25f3c9cbece0c41d0bd02e6919d2bd...6be32fc94f4599b2cfc35f113a170607980cdd03

### AI 总结重点(源码 diff 为据)
- **R620 起 fabric manager 与 IMEX 改用 `-direct` 包,且版本与驱动解耦**:`fabricmanager_download()`/`imex_download()`/`fabricmanager_install()`/`imex_install()` 四个函数各加一档 `DRIVER_BRANCH -ge 620` 分支,装 `nvidia-fabricmanager-direct`/`nvidia-imex-direct`(注意:**不带版本约束**,而 580 档是 `${DRIVER_VERSION}*`)。版本一致性改由新装的 `nvidia-driver-pinning-${DRIVER_VERSION}` 包负责。Ubuntu 22.04 与 24.04 的 precompiled 脚本对称改动。

  <details><summary>代码依据 ubuntu24.04/precompiled/local-repo.sh</summary>

  ```diff
   fabricmanager_download() {
  -  if [ "$DRIVER_BRANCH" -ge "580" ]; then
  +  if [ "$DRIVER_BRANCH" -ge "620" ]; then
  +    download_apt_with_dep nvidia-fabricmanager-direct
  +  elif [ "$DRIVER_BRANCH" -ge "580" ]; then
       download_apt_with_dep nvidia-fabricmanager ${DRIVER_VERSION}*
  ...
  +  # From R620, fabric manager and IMEX ship as -direct packages versioned independently of the
  +  # driver. nvidia-driver-pinning pins them and their libraries to the versions matching the driver.
  +  if [ "$DRIVER_BRANCH" -ge "620" ]; then
  +    apt-get install -y --no-install-recommends "nvidia-driver-pinning-${DRIVER_VERSION}"
  +  fi
  ```
  </details>

- **安装阶段用 `apt-mark hold` 锁住运行时库,R620 的 hold 清单里多了 `nvidia-modprobe`**:`imex_install()` 在 620 档 hold 的是 `nvidia-modprobe nvidia-imex-direct libnvidia-imex1`,fabricmanager 档 hold `nvidia-fabricmanager-direct libnvidia-fmdrv1`,然后 `return 0` 提前退出,完全跳过旧分支那套 `${package_name}-${DRIVER_BRANCH}` 拼名逻辑。注意 `libnvidia-fmdrv1`/`libnvidia-imex1` 这两个独立 so 包名是本期新出现的。

  <details><summary>代码依据 ubuntu24.04/precompiled/nvidia-driver</summary>

  ```diff
   imex_install() {
  +  if [ "$DRIVER_BRANCH" -ge "620" ]; then
  +    apt-get install -y --no-install-recommends nvidia-imex-direct
  +    apt-mark hold nvidia-modprobe nvidia-imex-direct libnvidia-imex1
  +    return 0
  +  fi
     local imex_package_name
     if [ "$DRIVER_BRANCH" -ge "580" ]; then
       imex_package_name=nvidia-imex
  ```
  </details>

### 后续发展方向 [AI]
- **NVIDIA 在把 fabric manager / IMEX 从"随驱动版本走"拆成"独立发版 + pinning 包约束"**,这是 NVSwitch/NVLink 域组件要独立迭代节奏的信号(IMEX 近两年变化比驱动核心快得多)。对驱动容器化的直接后果是:镜像构建时的版本一致性不再由包名里的版本号保证,而依赖 `nvidia-driver-pinning` 这一层间接约束。证据只覆盖 Ubuntu 22.04/24.04 的 precompiled 路径;RHEL/CentOS 与非 precompiled(源码编译)路径本期未改,620 在那些矩阵上怎么处理尚无依据。

## 本期无实质改动(折叠)
<details><summary>6 个仓库</summary>

- NVIDIA/nvidia-container-toolkit:无新提交(v1.20.2)
- NVIDIA/k8s-device-plugin:无新提交(v0.20.2)
- NVIDIA/dcgm-exporter:无新提交(4.9.0)
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:无新提交(v0.15.2)
- kai-scheduler/KAI-Scheduler:无新提交(v0.16.18)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=d338c6bd60db03ef29db86f5ef411b0dca35a85b branch=main release=v26.7.3 scanned=2026-11-22 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d8041cb623e601ebc085e2198725d2ce8277ab5a branch=main release=v1.20.2 scanned=2026-11-22 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6be32fc94f4599b2cfc35f113a170607980cdd03 branch=main release=— scanned=2026-11-22 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=057b54be3946886765dc2700ce1ab80ce6bcf4ba branch=main release=v0.20.2 scanned=2026-11-22 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=44cf296cdfb787ec2155a5ffae11763cb7e92c7e branch=main release=v0.5.1 scanned=2026-11-22 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-22 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-22 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9e4154330f5124ee62bf8f724892f6dcfa1a7145 branch=main release=v0.15.2 scanned=2026-11-22 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4c565e5ed2e1543cb8d603b606833472e4e388e3 branch=main release=v0.16.18 scanned=2026-11-22 -->
