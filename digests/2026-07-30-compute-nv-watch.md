# NVIDIA 算力栈 diff 雷达 2026-07-30

## 摘要
- **DRA 迁移当日三线齐发**:gpu-operator 把 driver 升级控制器从 ClusterPolicy 解耦(无 ClusterPolicy 也能升级 NVIDIADriver)、DRA 版 GPUCluster CRD 收窄为强单例并砍掉 RootFS;dra-driver 把 Fabric Manager(NVSwitch)分区从 VFIO 直通扩到**整卡 DRA 设备**并解除对 PassthroughSupport 的依赖;KAI-Scheduler 落地上游 KEP-5004 **DRA-backed 扩展资源**,DRA-only 节点开始接纳整卡 device-plugin 式 GPU 请求。三者都是"device-plugin/ClusterPolicy → DRA 原生"这条主线的实质推进。
- KAI-Scheduler 另加按 cgroup 内存上限自动设 GOMEMLIMIT(SchedulingShard 暴露 GoMemLimit/GoMemLimitRatio 字段)。
- gpu-driver-container 仅 RHEL UBI digest + CUDA 13.3.0→13.3.1 补丁位 bump;container-toolkit / k8s-device-plugin / dcgm-exporter / DCGM / mig-parted 五仓无实质改动。

## 当日重要改变
- **kubernetes-sigs/dra-driver-nvidia-gpu** [新能力/架构方向] FabricManagerPartitioning 从"仅 VFIO 直通设备"扩到整卡 `gpu.nvidia.com` DRA 设备,并**移除对 PassthroughSupport 的强依赖**;Prepare 要求 claim 分到的物理 GPU 集合与某个 FM 分区**完全相等**,否则失败。`pkg/featuregates/featuregates.go` https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/48760d6e9c39ecf97d130bdf1dcfe8f983f2d386
- **NVIDIA/gpu-operator** [API/CRD变更] DRA 版 GPUCluster(v1alpha1)加 CEL 单例校验(name 必须 `gpu-cluster`)、删 `ignored` State、用本地 `HostPathsSpec` 顶替 v1 的且**去掉 RootFS**(DRA 栈 host root 硬编码为 `/`)。`api/nvidia/v1alpha1/gpucluster_types.go` https://github.com/NVIDIA/gpu-operator/commit/8ea2298899680793312bd95bd9a4351fa1df8206
- **NVIDIA/gpu-operator** [架构方向] driver 升级控制器与 ClusterPolicy 解耦:请求改用单例名 `driver-upgrade`,每次 reconcile 重新 `resolveActiveConfig`;无 ClusterPolicy 或用 NVIDIADriver CRD 时走 `reconcileNVIDIADriverUpgrades` 路径。`controllers/upgrade_controller.go`
- **kai-scheduler/KAI-Scheduler** [API/CRD变更/新能力] 实现 KEP-5004:新增 `ExtendedResourceClaimAllocation`(合成 DRA claim 承载由 DeviceClass 背书的扩展资源),BindRequest CRD 内嵌完整 DRA AllocationResult(+896 行);DRA-only 节点不再一刀切拒 device-plugin GPU,仅拒分数/共享 GPU。`pkg/apis/scheduling/v1alpha2/bindrequest_types.go`、`pkg/scheduler/api/node_info/node_info.go` https://github.com/kai-scheduler/KAI-Scheduler/commit/c0d44f203bb2b0744224f3bdc2f35a4b50d4e3b1

## NVIDIA/gpu-operator: f3f9415b -> 8ea22988
- 比较: f3f9415b6e4f406b99bb7a8c4b6558b52ee71c17 -> 8ea22988 | ahead=16 | files=71 | Release: v26.3.3
- https://github.com/NVIDIA/gpu-operator/compare/f3f9415b6e4f406b99bb7a8c4b6558b52ee71c17...8ea2298899680793312bd95bd9a4351fa1df8206

### AI 总结重点(源码 diff 为据)
- **driver 升级控制器彻底从 ClusterPolicy 解耦**,这是把驱动生命周期接到 DRA/NVIDIADriver 新栈的关键一步。`UpgradeReconciler` 加 `OperatorNamespace` 字段,请求不再携带 CR 引用而用单例名 `driver-upgrade`,每次 reconcile 都 `resolveActiveConfig` 重解析活跃配置源;当无 ClusterPolicy 或 ClusterPolicy 声明用 NVIDIADriver CRD 类型时,直接进 `reconcileNVIDIADriverUpgrades`(按 NVIDIADriver 实例逐个升级,无 CR 时清理陈旧 upgrade-state 标签并 no-op)。删掉了旧的 `apierrors.IsNotFound` → 不 requeue 分支。
  <details><summary>代码依据 controllers/upgrade_controller.go</summary>

  ```diff
  -	Log             logr.Logger
  -	StateManager    upgrade.ClusterUpgradeStateManager
  -	OperatorMetrics *OperatorMetrics
  +	Log               logr.Logger
  +	StateManager      upgrade.ClusterUpgradeStateManager
  +	OperatorMetrics   *OperatorMetrics
  +	OperatorNamespace string
  +	// 请求携带单例名而非 CR 引用,每次 reconcile 重新解析活跃配置源
  +	upgradeControllerSingletonName = "driver-upgrade"
  -	clusterPolicy := &gpuv1.ClusterPolicy{}
  -	err := r.Get(ctx, req.NamespacedName, clusterPolicy)
  +	clusterPolicy, _, err := resolveActiveConfig(ctx, r.Client)
  +	if clusterPolicy == nil || clusterPolicy.Spec.Driver.UseNvidiaDriverCRDType() {
  +		return r.reconcileNVIDIADriverUpgrades(ctx, reqLogger)
  +	}
  ```
  </details>
- **DRA 版 GPUCluster CRD(v1alpha1)加固为强单例并简化 host 路径模型**。删除 `Ignored` State 常量与 enum 值(不再用"标记重复 CR 为 ignored"的软处理),改用 CEL XValidation 硬约束 `metadata.name == 'gpu-cluster'`;`HostPaths` 从复用 v1 的 `nvidiav1.HostPathsSpec` 换成本地新定义的 `HostPathsSpec`,只留 `DriverInstallDir` + `KubeletRootDir`,**显式去掉 RootFS**——注释说明 DRA 栈 host root 硬编码为 `/`,不再需要 chroot 根(MIG Manager/Toolkit 那套 systemd 交互不在 DRA 路径)。CRD YAML 同步删 `rootFS`、删 `ignored` enum、加 x-kubernetes-validations。
  <details><summary>代码依据 api/nvidia/v1alpha1/gpucluster_types.go</summary>

  ```diff
  -const (
  -	// Ignored marks a duplicate GPUCluster that the singleton controller does not reconcile.
  -	Ignored State = "ignored"
  -)
  -	HostPaths nvidiav1.HostPathsSpec `json:"hostPaths,omitempty"`
  +	HostPaths HostPathsSpec `json:"hostPaths,omitempty"`
  +// Unlike the v1 ClusterPolicy struct it mirrors, it has no RootFS: the host root is
  +// hard-coded to "/" for the DRA stack.
  +type HostPathsSpec struct {
  +	DriverInstallDir string `json:"driverInstallDir,omitempty"`
  +	KubeletRootDir string `json:"kubeletRootDir,omitempty"`
  +}
  -	// +kubebuilder:validation:Enum=ignored;ready;notReady;disabled
  +	// +kubebuilder:validation:Enum=ready;notReady;disabled
  +//+kubebuilder:validation:XValidation:rule="self.metadata.name == 'gpu-cluster'",message="GPUCluster is a singleton, metadata.name must be 'gpu-cluster'"
  ```
  </details>
- 其余为工程/兼容位:controller-gen v0.20.1→v0.21.0(clusterpolicies/gpuclusters/nvidiadrivers 三 CRD 重生成,HashMod 的 int64 字段补 `minimum: 0`);"skip mdev-mode GPUs in waitForVFs"(SR-IOV VF 等待跳过 mdev 模式 GPU)、"helm: schedule CRD hook Jobs on Linux nodes"、"Apply resources to managed init containers" 均为小修,未逐一读 hunk。

### 后续发展方向 [AI]
- 证据集中在"驱动升级/GPUCluster 单例/host 路径"三处,均指向 gpu-operator 正把 **DRA GPUCluster 栈做成与传统 ClusterPolicy 平行、可独立运转的一等路径**:升级控制器已能脱离 ClusterPolicy 存在。RootFS 的移除意味着 DRA 路径放弃了 chroot-host 的 MIG/Toolkit systemd 交互模型——值得盯后续 MIG Manager 在 DRA 下如何重新落地。证据只覆盖 CRD/控制器解耦,未见 DRA GPUCluster 的实际 operand 渲染差异(dra_driver.go 有 62 行改动但未纳入 patch 节选)。

## kubernetes-sigs/dra-driver-nvidia-gpu: b0a51e35 -> 48760d6e
- 比较: b0a51e353fbabab0230639b027e02f1ab29e8cab -> 48760d6e | ahead=2 | files=8 | Release: v0.4.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/b0a51e353fbabab0230639b027e02f1ab29e8cab...48760d6e9c39ecf97d130bdf1dcfe8f983f2d386

### AI 总结重点(源码 diff 为据)
- **Fabric Manager(NVSwitch)分区能力从"仅 VFIO 直通设备"扩展到整卡 `gpu.nvidia.com` DRA 设备**,并**解除对 PassthroughSupport 的强依赖**。featuregate 注释重写语义:开启后 Prepare 会激活成员集与 claim 分到的物理 GPU **完全匹配**的 FM 分区,不匹配则 Prepare 失败;ResourceClaim 需用 `matchAttribute` 约束到 `gpu.nvidia.com/partitionN`;要求 Fabric Manager 以 `FABRIC_MODE=1` 运行。两 gate 都开 → 整卡 + VFIO 都分区;只开本 gate → 仅整卡。`ValidateFeatureGates` 里"本 gate 需 PassthroughSupport"的校验被删除。
  <details><summary>代码依据 pkg/featuregates/featuregates.go</summary>

  ```diff
  -	// FabricManagerPartitioning enables Fabric Manager (NVSwitch) partition
  -	// management for Passthrough VFIO devices.
  +	// ... management for full-GPU (gpu.nvidia.com) devices and Passthrough VFIO
  +	// devices. ... Prepare activates the FM partition whose member set exactly
  +	// matches the claim's allocated physical GPUs; a non-matching set fails Prepare.
  +	// ... Requires Fabric Manager running with FABRIC_MODE=1. Independent of PassthroughSupport
  -	if Enabled(FabricManagerPartitioning) && !Enabled(PassthroughSupport) {
  -		return fmt.Errorf("feature gate %s requires %s to also be enabled", FabricManagerPartitioning, PassthroughSupport)
  -	}
  ```
  </details>
- 配套把 FM 属性发布逻辑**从 VfioDeviceInfo 上移到 GpuInfo**(物理 GPU 才是 FM 信息的真正宿主):新 `GpuInfo.addFabricManagerAttributes` 在整卡 Attributes 里发布 `gpuModuleID` 与 `partition<N>`(N=分区大小→partitionId)属性,供 ResourceClaim 的 matchAttribute 约束;VFIO 设备改为委托其 parent GpuInfo 发布。Unprepare 路径简化:不再逐个收集 vfioInfos 再 deactivate,统一在 `fabricManagerPartitioningEnabled()` 下对整个 PreparedClaim 调 `deactivateFabricPartition(&pc)`。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/deviceinfo.go</summary>

  ```diff
  +	if featuregates.Enabled(featuregates.FabricManagerPartitioning) {
  +		d.addFabricManagerAttributes(attrs)   // 现在挂在 GpuInfo(整卡)上
  +	}
  +	for size, partitionID := range d.partitionsBySize {
  +		key := resourceapi.QualifiedName(fmt.Sprintf("partition%d", size))
  +		attrs[key] = resourceapi.DeviceAttribute{IntValue: ptr.To(int64(partitionID))}
  +	}
  ```
  </details>
- 文档明确风险边界:**不要在仍跑无约束整卡 claim 的节点开启本 gate**——普通多卡整卡 workload 若不带 `gpu.nvidia.com/partitionN` 的 matchAttribute,会因 GPU 集合不匹配任何 FM 分区而 Prepare 失败。其余为 `gpuModuleId`→`gpuModuleID` 命名统一(不改行为)。

### 后续发展方向 [AI]
- 这是 NVL/NVSwitch 域(GB200/GB300 这类 fabric 互联系统)从"VFIO 直通专属"走向"**DRA 整卡分区通用能力**"的实质一步:FM 分区成为 ResourceClaim 可用 matchAttribute 精确选择的一等 DRA 属性。方向是让 DRA scheduler 按 NVSwitch 拓扑分区做整卡分配。证据只覆盖 featuregate/属性发布/unprepare 三处,未见 Prepare 侧激活分区的完整实现(device_state.go 182 行改动 hunk 被截断)。

## kai-scheduler/KAI-Scheduler: f03607a8 -> c0d44f20
- 比较: f03607a860579953aed8d3268a37635d412d6f7d -> c0d44f20 | ahead=3 | files=47 | Release: v0.16.8
- https://github.com/kai-scheduler/KAI-Scheduler/compare/f03607a860579953aed8d3268a37635d412d6f7d...c0d44f203bb2b0744224f3bdc2f35a4b50d4e3b1

### AI 总结重点(源码 diff 为据)
- **实现上游 KEP-5004:DRA-backed 扩展资源**——扩展资源请求(如 `nvidia.com/gpu` 由 DeviceClass 背书时)被转成一个合成 DRA ResourceClaim 走 DRA 分配器。新增 `ExtendedResourceClaimAllocation` 类型(v1alpha2):承载 DRA `AllocationResult`、per-container `DeviceRequests`、以及把每容器扩展资源请求映射到 DeviceRequest 名的 `ContainerMappings`;BindRequestSpec 加同名字段,BindRequest CRD 因此内嵌完整 DRA AllocationResult schema(+896 行)。
  <details><summary>代码依据 pkg/apis/scheduling/v1alpha2/bindrequest_types.go</summary>

  ```diff
  +	// 合成 DRA claim 承载由 DeviceClass 背书的扩展资源请求的分配结果
  +	ExtendedResourceClaimAllocation *ExtendedResourceClaimAllocation `json:"extendedResourceClaimAllocation,omitempty"`
  +type ExtendedResourceClaimAllocation struct {
  +	Allocation *resourceapi.AllocationResult `json:"allocation,omitempty"`
  +	DeviceRequests []resourceapi.DeviceRequest `json:"deviceRequests,omitempty"`
  +	ContainerMappings []corev1.ContainerExtendedResourceRequest `json:"containerMappings,omitempty"`
  +}
  ```
  </details>
- **DRA-only 节点的准入语义放宽**:此前 `PredicateByNodeResourcesType` 一刀切拒绝所有 device-plugin GPU 请求落 DRA-only 节点;现在只拒**分数/共享 GPU 请求**(`IsSharedGPURequest()`),整卡请求可经 DRA 扩展资源路径落地。配套引入 `DeviceClassByResource`(上游 `extendedresourcecache.ExtendedResourceCache`)把扩展资源名解析到背书它的 DeviceClass;fit 计算里对 DRA 背书维度(节点 Allocatable 为 0 且有 DeviceClass)跳过节点向量记账,交给 DRA 分配器,避免双重计费。
  <details><summary>代码依据 pkg/scheduler/api/node_info/node_info.go</summary>

  ```diff
  -	// Temporary fix: Reject device-plugin GPU requests on DRA-only nodes.
  -	if task.GpuRequirement.GPUs() > 0 && ni.HasDRAGPUs {
  -		return ... "device-plugin GPU requests cannot be scheduled on DRA-only nodes"
  +	if ni.HasDRAGPUs && task.IsSharedGPURequest() {
  +		return ... "fractional/shared GPU pods are not yet supported on DRA-only nodes"
  +	// DRA 背书维度:节点 allocatable 为 0,由 DRA 分配器 fit-check,跳过向量记账
  +	if ni.AllocatableVector.Get(i) == 0 &&
  +		ni.DeviceClassByResource.GetDeviceClass(ni.VectorMap.ResourceAt(i)) != nil {
  +		continue
  ```
  </details>
- **按 cgroup 内存上限自动设 GOMEMLIMIT**(#1988):SchedulingShard CRD 加 `GoMemLimitRatio`(容器内存限额的比例,默认 0.9)与 `GoMemLimit`(直接覆盖的 Quantity);新 `cmd/scheduler/app/memory_limit.go` 据此设 GOMEMLIMIT,降 scheduler 在大集群下的 OOM 风险。
  <details><summary>代码依据 pkg/apis/kai/v1/schedulingshard_types.go</summary>

  ```diff
  +	// GoMemLimitRatio: 容器内存限额乘此比例作为 GOMEMLIMIT,默认 0.9
  +	GoMemLimitRatio *float64 `json:"goMemLimitRatio,omitempty"`
  +	// GoMemLimit: 覆盖 cgroup 推导的 GOMEMLIMIT
  +	GoMemLimit *resource.Quantity `json:"goMemLimit,omitempty"`
  +func (s *SchedulingShardSpec) SetDefaultsWhereNeeded() {
  +	s.GoMemLimitRatio = common.SetDefault(s.GoMemLimitRatio, ptr.To(0.9))
  ```
  </details>

### 后续发展方向 [AI]
- KAI-Scheduler 正把自己接到上游 DRA 扩展资源标准(KEP-5004),让"device-plugin 语义的整卡 GPU 请求"能在 DRA-only 节点上由 DRA 分配器满足——这是 device-plugin→DRA 过渡期的关键兼容层,与本日 gpu-operator/dra-driver 的 DRA 推进同频。仍显式不支持:分数/共享(fractional/gpu-memory)GPU 在 DRA 节点上,说明 KAI 的软切分能力尚未迁到 DRA。证据覆盖类型/准入/记账三处,未展开 binder 侧 `dra.go`(157 行)对合成 claim 的实际绑定实现。

## 本期无实质改动(折叠)
<details>
- NVIDIA/gpu-driver-container:仅 RHEL8/9/10 UBI base image digest bump + vgpu-manager ubuntu24.04 CUDA 13.3.0→13.3.1 基础镜像补丁位,无逻辑/OS 矩阵结构变化(ahead=4/files=4)
- NVIDIA/nvidia-container-toolkit:无新提交
- NVIDIA/k8s-device-plugin:仅 bump/CI(ahead=2/files=1)
- NVIDIA/dcgm-exporter:无新提交
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=8ea2298899680793312bd95bd9a4351fa1df8206 branch=main release=v26.3.3 scanned=2026-07-30 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1151f013074712dc6dabd00752b6b57d6637fdeb branch=main release=v1.20.0-rc.1 scanned=2026-07-30 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=661378a6e44b41ef4557da54ed96fb3ab9c89851 branch=main release=— scanned=2026-07-30 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5f27eeeee7eb7f7a4c0581aa10abeda7e4604ed2 branch=main release=v0.19.3 scanned=2026-07-30 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=48760d6e9c39ecf97d130bdf1dcfe8f983f2d386 branch=main release=v0.4.1 scanned=2026-07-30 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-30 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-30 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5f3f9d78cd4c6b0b77165b81b8e0dacebdcb825c branch=main release=v0.14.4 scanned=2026-07-30 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=c0d44f203bb2b0744224f3bdc2f35a4b50d4e3b1 branch=main release=v0.16.8 scanned=2026-07-30 -->
