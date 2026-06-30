# NVIDIA 算力栈 diff 雷达 2026-07-01

## 摘要
- **gpu-operator** 一天两大重构:① 把驱动升级策略下沉到 **NVIDIADriver CRD**(新增 `upgradePolicy`,per-instance 自动升级/并行度/MaxUnavailable),升级控制器按 ClusterPolicy/NVIDIADriver 两条路径分叉;② 新建 **NodeLabelingReconciler** 把所有节点打标写操作集中到一个控制器,state_manager 退化为只读发现——两处 TODO 都明说是在为"GPU Operator 集成 NVIDIA DRA Driver"解耦。
- **container-toolkit** NRI 插件把 management CDI 设备注入从"仅 toolkit 单命名空间"放开到**多命名空间白名单**(新 flag/env);**mig-parted** systemd 修启动死锁 + 按算力等级在开机时(而非装包时)选 hooks 文件;**KAI-Scheduler** v0.16.2 修 GPU 显存配额换算(min/max 双口径 + nil 语义)。
- **dra-driver-nvidia-gpu** 仅新增 KubeVirt VFIO 直通文档,但暴露了 `PassthroughSupport`/`DeviceMetadata` 两个 Alpha 特性门与"驱动自动切 vfio-pci"能力信号。其余 3 仓(driver-container / k8s-device-plugin / dcgm-exporter / DCGM)无实质改动。

## 当日重要改变
- gpu-operator [API/CRD变更] NVIDIADriver CRD 新增 `upgradePolicy`(autoUpgrade/maxParallelUpgrades/maxUnavailable=25%/drain/podDeletion/waitForCompletion),驱动升级从 ClusterPolicy 全局策略转为**每个 NVIDIADriver 实例独立策略**。证据 `api/nvidia/v1alpha1/nvidiadriver_types.go`、`config/crd/bases/nvidia.com_nvidiadrivers.yaml`。https://github.com/NVIDIA/gpu-operator/compare/a37981bd...4b786010
- gpu-operator [架构方向] 新增 `NodeLabelingReconciler` 集中所有节点 label 写操作,删除 `nvidiadriver_migration.go`,`state_manager.go` 的 `labelGPUNodes`/`applyDriverAutoUpgradeAnnotation` 改为只读 `discoverGPUNodes`;代码注释明确为后续 DRA Driver 与 GPU Operator 集成铺路。证据 `controllers/nodelabeling_controller.go`(新增 509 行)。https://github.com/NVIDIA/gpu-operator/compare/a37981bd...4b786010
- container-toolkit [新能力] NRI 插件支持向**多个命名空间**注入 management CDI 设备(新 flag `--nri-management-cdi-device-namespaces` / env `NRI_MANAGEMENT_CDI_DEVICE_NAMESPACES`)。证据 `cmd/nvidia-ctk-installer/container/runtime/nri/plugin.go`。https://github.com/NVIDIA/nvidia-container-toolkit/compare/41dd4444...05e941df

## NVIDIA/gpu-operator: a37981bd -> 4b786010
- 比较 / 最新 Release:a37981bd -> 4b786010 | ahead=4 | files=19 | Release: v26.3.3
- https://github.com/NVIDIA/gpu-operator/compare/a37981bd...4b786010

### AI 总结重点(源码 diff 为据)
- **驱动升级策略下放到 NVIDIADriver CRD**:`NVIDIADriverSpec` 新增 `UpgradePolicy *DriverUpgradePolicySpec`,字段含 `AutoUpgrade`(默认 true)、`MaxParallelUpgrades`(默认 1,0=不限)、`MaxUnavailable`(IntOrString,默认 "25%")、以及复用 `k8s-operator-libs` 的 `PodDeletion`/`WaitForCompletion`/`Drain`。配套 `GetUpgradePolicyWithDefaults()` 在字段未设时回退默认值。意味着多份 NVIDIADriver 实例可各自定义升级节奏,不再被 ClusterPolicy 一刀切。

  <details><summary>代码依据 api/nvidia/v1alpha1/nvidiadriver_types.go</summary>

  ```diff
  +	// UpgradePolicy allows to control automatic upgrade of the driver on nodes
  +	UpgradePolicy *DriverUpgradePolicySpec `json:"upgradePolicy,omitempty"`
  ...
  +type DriverUpgradePolicySpec struct {
  +	// +kubebuilder:default=true
  +	AutoUpgrade bool `json:"autoUpgrade,omitempty"`
  +	// +kubebuilder:default=1  +kubebuilder:validation:Minimum=0
  +	MaxParallelUpgrades int `json:"maxParallelUpgrades,omitempty"`
  +	// +kubebuilder:default="25%"
  +	MaxUnavailable    *intstr.IntOrString    `json:"maxUnavailable,omitempty"`
  +	PodDeletion       *PodDeletionSpec       `json:"podDeletion,omitempty"`
  +	WaitForCompletion *WaitForCompletionSpec `json:"waitForCompletion,omitempty"`
  +	DrainSpec         *DrainSpec             `json:"drain,omitempty"`
  +}
  ```
  </details>

- **升级控制器按 CRD 类型分叉**:`UpgradeReconciler.Reconcile` 顶部判断 `clusterPolicy.Spec.Driver.UseNvidiaDriverCRDType()`,走 NVIDIADriver 即调新 `reconcileNVIDIADriverUpgrades`(遍历 `NVIDIADriverList`,任一实例 `AutoUpgrade` 开启即进升级流程,且只用 component label 抓全部驱动 Pod,含 ClusterPolicy 遗留的孤儿 Pod),否则走 `reconcileClusterPolicyDriverUpgrades`(原逻辑)。`clusterpolicy_types.go` 同步加 `DriverSpec.IsAutoUpgradeEnabled()`。

  <details><summary>代码依据 controllers/upgrade_controller.go</summary>

  ```diff
  +	if clusterPolicy.Spec.Driver.UseNvidiaDriverCRDType() {
  +		return r.reconcileNVIDIADriverUpgrades(ctx, reqLogger)
  +	}
  +	return r.reconcileClusterPolicyDriverUpgrades(ctx, reqLogger, clusterPolicy)
  ...
  +func (r *UpgradeReconciler) reconcileNVIDIADriverUpgrades(...) (ctrl.Result, error) {
  +	nvidiaDriverList := &nvidiav1alpha1.NVIDIADriverList{}
  +	... for _, nvd := range nvidiaDriverList.Items {
  +		upgradePolicy := nvd.Spec.GetUpgradePolicyWithDefaults()
  +		if upgradePolicy.AutoUpgrade { noAutoUpgradesEnabled = false; break }
  +	}
  ```
  </details>

- **节点打标集中化**:新 `NodeLabelingReconciler`(单例 name="cluster")接管所有 `nodes` 的 `update;patch`,无 ClusterPolicy CR 时直接早退不打标(注释:待 DRA Driver 集成后放宽)。`state_manager.go` 净删 150 行——原 `labelGPUNodes`/`applyDriverAutoUpgradeAnnotation`(直接 List+Update 节点)被拆走,留下只读 `discoverGPUNodes`(只数 NFD/GPU 节点,不再写);`nvidiadriver_migration.go`(给孤儿 ClusterPolicy 驱动 Pod 节点打 upgrade-required 标的迁移逻辑)整文件删除。

  <details><summary>代码依据 controllers/state_manager.go(净 +22/-150)</summary>

  ```diff
  -func (n *ClusterPolicyController) applyDriverAutoUpgradeAnnotation() error { ... 直接 List nodes 并 Update 注解 ... }
  -func (n *ClusterPolicyController) labelGPUNodes() (bool, int, error) {
  +// discoverGPUNodes reads all cluster nodes ... Node label writes are handled by NodeLabelingReconciler.
  +func (n *ClusterPolicyController) discoverGPUNodes() (bool, int, error) {
  -	err := n.client.List(ctx, list, opts...)
  +	if err := n.client.List(ctx, list); err != nil { ... }
  ```
  </details>

### 后续发展方向 [AI]
- 两处 TODO(`upgrade_controller.go`、`nodelabeling_controller.go`)都明指**为 GPU Operator 原生集成 NVIDIA DRA Driver 解耦**:把"节点打标"与"驱动升级"从 ClusterPolicy 强绑定中抽出,是 ClusterPolicy → NVIDIADriver/DRA 这条多年迁移的又一步。证据覆盖 controllers 层重构与 CRD 字段,未见 DRA Driver 一侧的对接代码(本仓本期无 DRA 相关文件)。
- `upgradePolicy` 进 CRD 后,GPU 驱动滚动升级的并行度/可用性预算变成声明式、可分组(每 NVIDIADriver 实例独立),对多机型/多池集群的灰度驱动升级是直接利好。证据仅 CRD 字段与控制器分叉,未见 e2e 升级编排细节。

## NVIDIA/nvidia-container-toolkit: 41dd4444 -> 05e941df
- 比较 / 最新 Release:41dd4444 -> 05e941df | ahead=4 | files=4 | Release: v1.19.1
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/41dd4444...05e941df

### AI 总结重点(源码 diff 为据)
- **management CDI 注入放开到多命名空间**:NRI 插件的 `Plugin.namespace string` 改为 `namespaces []string`,`NewPlugin` 签名同步改;`parseCDIDevices` 里对 `management.nvidia.com/gpu` 设备的命名空间校验从 `p.namespace != pod.Namespace` 改为 `!slices.Contains(p.namespaces, pod.Namespace)`。安装器新增 `--nri-management-cdi-device-namespaces`(env `NRI_MANAGEMENT_CDI_DEVICE_NAMESPACES`),在 toolkit 自身命名空间之外再追加一组允许接收 management CDI 设备的命名空间。

  <details><summary>代码依据 cmd/nvidia-ctk-installer/container/runtime/nri/plugin.go + main.go</summary>

  ```diff
  -	namespace string
  +	namespaces []string
  -func NewPlugin(ctx context.Context, logger logger.Interface, namespace string) *Plugin {
  +func NewPlugin(ctx context.Context, logger logger.Interface, namespaces []string) *Plugin {
  ...
  -		if p.namespace != pod.Namespace {
  +		if !slices.Contains(p.namespaces, pod.Namespace) {
  ...
  // main.go:
  +	nriNamespaces := append([]string{opts.nriNamespace}, opts.nriManagementCDIDeviceNamespaces...)
  +	plugin := nri.NewPlugin(ctx, a.logger, nriNamespaces)
  ```
  </details>

- distroless 基础镜像 `nvcr.io/nvidia/distroless/go` v4.0.7 → v4.0.8(build+application 两阶段)。

### 后续发展方向 [AI]
- management CDI 设备(driver 容器自身可见性的根)注入解除"仅 toolkit 单命名空间"约束,直接服务于"driver/toolkit 拆到不同命名空间部署"或多 operator 实例场景。证据仅 NRI 插件路径,经典 runtime hook 路径本期未动。

## NVIDIA/mig-parted: 5dc3caa4 -> bb6399f0
- 比较 / 最新 Release:5dc3caa4 -> bb6399f0 | ahead=4 | files=3 | Release: v0.14.2
- https://github.com/NVIDIA/mig-parted/compare/5dc3caa4...bb6399f0

### AI 总结重点(源码 diff 为据)
- **开机启动驱动服务改非阻塞,避免死锁**:`start_driver_services` 在系统仍在 boot(`systemctl is-system-running` ≠ running/degraded)时给 `start_systemd_services` 传 `--no-block`。原因注释说明:driver 服务 `After=nvidia-gpu-reset.target` 而本服务 `Before` 该 target,开机同步启动会形成"本服务等驱动服务、驱动服务等 target、target 等本服务完成"的死锁;运行期重配置时仍同步启动以便等待并报错。

  <details><summary>代码依据 deployments/systemd/hooks.sh</summary>

  ```diff
  -	nvidia-mig-manager::service::start_systemd_services driver_services
  +	state="$(systemctl is-system-running 2>/dev/null)"
  +	if [ "${state}" != "running" ] && [ "${state}" != "degraded" ]; then
  +		start_args="--no-block"
  +	fi
  +	nvidia-mig-manager::service::start_systemd_services driver_services "${start_args}"
  ```
  </details>

- **hooks 文件选择从装包时移到开机时**:新增 `select_hooks_file()`,在 service 启动时按 `nvidia-smi --query-gpu=compute_cap` 选 hooks 文件——算力 ≥ 90(Hopper 及以上)用 `hooks-minimal.yaml`,否则 `hooks-default.yaml`;若 nvidia-smi 仍不可用(OS 镜像构建期)则保持现状不猜。解决装包时 GPU 不可查导致 hooks 选错的问题。用户手动指向别处的 `hooks.yaml` 软链不被覆盖。

  <details><summary>代码依据 deployments/systemd/utils.sh + service.sh</summary>

  ```diff
  +function nvidia-mig-manager::service::select_hooks_file() {
  +	compute_cap="$(nvidia-smi -i 0 --query-gpu=compute_cap --format=csv,noheader)"
  +	local desired="hooks-default.yaml"
  +	if [ "${compute_cap/./}" -ge "90" ] 2>/dev/null; then
  +		desired="hooks-minimal.yaml"
  +	fi
  +	... ln -sf "${desired}" "${link}"
  +}
  // service.sh 启动时调用:
  +nvidia-mig-manager::service::select_hooks_file
  ```
  </details>

### 后续发展方向 [AI]
- 这两条都是 MIG 静态切分在**裸机/OS 镜像预装**场景的健壮性打磨(boot 时序、镜像构建期 GPU 不可查),非切分语义变化。证据仅 systemd 脚本,MIG 配置 schema 本期未动。

## kai-scheduler/KAI-Scheduler: 6ee3494e -> 4a9f6e6a
- 比较 / 最新 Release:6ee3494e -> 4a9f6e6a | ahead=6 | files=34 | Release: v0.16.2
- https://github.com/kai-scheduler/KAI-Scheduler/compare/6ee3494e...4a9f6e6a

### AI 总结重点(源码 diff 为据)
- **GPU 显存配额换算改 min/max 双口径 + nil 语义(#1792)**:`ClusterInfo.MinNodeGPUMemory int64` 改为 `MinNodeGPUMemoryMiB *int64`,并新增 `MaxNodeGPUMemoryMiB *int64`,二者在无 GPU 节点时为 nil(原先回退 `DefaultGpuMemory` 常量)。`snapshotNodes` 同步返回两值并以指针累计 min/max。

  <details><summary>代码依据 pkg/scheduler/api/cluster_info.go + cache/cluster_info/cluster_info.go</summary>

  ```diff
  -	MinNodeGPUMemory int64
  +	MinNodeGPUMemoryMiB *int64 // nil if no node has GPUs
  +	MaxNodeGPUMemoryMiB *int64 // nil if no node has GPUs
  ...
  -	var minGPUMemory int64 = node_info.DefaultGpuMemory
  +	minimalNodeGPUMemory = nil
  +	maximalNodeGPUMemory = nil
  +		if minimalNodeGPUMemory == nil || *minimalNodeGPUMemory > nodeGPUMemory { minimalNodeGPUMemory = &nodeGPUMemory }
  +		if maximalNodeGPUMemory == nil || *maximalNodeGPUMemory < nodeGPUMemory { maximalNodeGPUMemory = &nodeGPUMemory }
  ```
  </details>

- **配额检查用 max 显存做最保守换算**:`capacity_policy` 由 `minNodeGPUMemory` 改用 `maxNodeGPUMemoryMiB`——把 GPU 显存请求换算成 GPU 占比时用最大除数得最小分数,若连最小分数都超限即可直接判超额(无需模拟)。而 reclaim/queue-order 仍用 min(最保守地估计 reclaimer 自身占用)。两套除数被显式分流:`GetTasksToAllocateInitResourceVector` 的缓存不按除数 key,注释强制其只能用 min,需要 max 的 capacity_policy 自己算。

  <details><summary>代码依据 pkg/scheduler/plugins/proportion/{proportion.go,capacity_policy/capacity_policy.go}</summary>

  ```diff
  -	capacityPolicy := cp.New(pp.queues, pp.minNodeGPUMemory)
  +	capacityPolicy := cp.New(pp.queues, ssn.ClusterInfo.MaxNodeGPUMemoryMiB)
  ...
  -func getRequiredQuota(tasksToAllocate, minNodeGPUMemory int64) {
  +// max divisor → smallest fraction. If even the smallest fraction is over the limit → over limit now, no simulation.
  +func getRequiredQuota(tasksToAllocate, maxNodeGPUMemory *int64) {
  +		if maxNodeGPUMemory != nil { quota[rs.GpuResource] += pod.GpuRequirement.GpuMemoryAsGpuFraction(*maxNodeGPUMemory) }
  ```
  </details>

- **热路径减分配抖动(#1698)**:`logNodeSetsPluginResult` 在非 V(7) 日志级别下直接早退,避免每调度周期为日志构造 `[][]string` 节点名切片;构造逻辑也从拷贝整个 `NodeSet` 改为只收集 name 字符串。属纯 GC/分配优化。

  <details><summary>代码依据 pkg/scheduler/framework/session_plugins.go</summary>

  ```diff
  +	if !log.InfraLogger.IsVerbose(7) {
  +		return
  +	}
  -	nodeSetsByNames := make([]node_info.NodeSet, 0, len(nodeSets))
  +	nodeSetNames := make([][]string, 0, len(nodeSets))
  ```
  </details>

- **chart 加守卫**:scalingpod 命名空间与 resourcereservation ServiceAccount 创建加条件守卫(#1733),新增"跳过 reservation 命名空间创建"的 flag(#1797),删 `queuecontroller.certSecretName`/`admission.certSecretName` 未用值(#1791)。

### 后续发展方向 [AI]
- v0.16.2 延续对**显存级配额(GPU memory request → GPU fraction)**精度的打磨:min(估自身占用)/max(判超额下界)双口径分流,nil 语义替代魔数 fallback,使无 GPU 集群与异构显存集群的配额判定更准。证据覆盖 cluster_info / capacity_policy / proportion 三处,未见对 reclaim 场景搜索(上期 `FilterVictim`)的进一步改动。

## 本期无实质改动(折叠)
<details>
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — ahead=4 仅 bump/CI/merge
- kubernetes-sigs/dra-driver-nvidia-gpu — ahead=4 仅新增 KubeVirt VFIO 直通文档(`site/content/docs/guides/kubevirt-vfio-gpu-passthrough.md`)+ golang 1.26.3→1.26.4,无代码逻辑改动;但文档披露 `PassthroughSupport`/`DeviceMetadata` 两 Alpha 特性门(v0.4.0+)与"驱动自动切 vfio-pci 并自动禁/复位 persistence mode"能力,DCGM v4.5.0+/dcgm-exporter v4.5.0+ 可配合自动释放 GPU。Release v0.4.1-rc.1 → v0.4.1。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/a1c1b674...391d5ca8
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交(master)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=4b786010456bb6d43414df59f8931003bc14470a branch=main release=v26.3.3 scanned=2026-07-01 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=05e941dffa81b88e42f0dc65909ac43fe1254f82 branch=main release=v1.19.1 scanned=2026-07-01 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f41a0200e00d232bd7e257b22600883346eea079 branch=main release=— scanned=2026-07-01 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=7d9fe09cf6b70ed55b25f5f409af999f490210e6 branch=main release=v0.19.3 scanned=2026-07-01 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=391d5ca8d7ed478e0d7e5aeb8883a85409742ff6 branch=main release=v0.4.1 scanned=2026-07-01 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-01 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=bb6399f0976dafc69f9e059ec968db34ac59a302 branch=main release=v0.14.2 scanned=2026-07-01 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4a9f6e6a257159ad2af0066816807c3de98e2580 branch=main release=v0.16.2 scanned=2026-07-01 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-07-01 -->
</content>
</invoke>
