# NVIDIA 算力栈 diff 雷达 2026-07-24

## 摘要
- **DRA 主线两处强信号**:NVIDIA DRA driver 的一批 feature gate 默认值集体翻转为 enabled(MPSSupport / DynamicMIG / NVMLDeviceHealthCheck / TimeSlicingSettings 从 disabled 转 enabled),并新增 4 个 gate;同时修掉 MPS 拆除后 GPU 算力模式卡在 EXCLUSIVE_PROCESS 的残留 bug。
- **KAI-Scheduler 落两份架构提案 + 一处 API 扩字段**:PodGroup 新增 `StalenessGracePeriod`(陈旧 gang 驱逐宽限期,含 CRD);提出 DRA-backed 扩展资源(KEP-5004,让 `nvidia.com/gpu: N` 跑在 DRA-only 节点)与 AccountedResource CRD(按 H200/GB200/GPU 显存等任意维度限额)。
- **container-toolkit 新增 CDI hook `update-application-profile`**:把容器内 EGL/Vulkan 的 GPU 可见性收窄到实际挂载的 GPU;gpu-operator 侧对 nvidia-smi 定位做多路径 + 可执行文件校验的安全加固。

## 当日重要改变
- dra-driver-nvidia-gpu [新能力/默认变更] feature gate 默认矩阵集体前移:MPSSupport、DynamicMIG、NVMLDeviceHealthCheck、TimeSlicingSettings 从 `(disabled)` 变 `(enabled)`,并新增 DRAListTypeAttributes/DeviceMetadata/FabricManagerPartitioning/HostManagedIMEXDaemon 四个 gate(证据:`.github/ISSUE_TEMPLATE/bug_report.yml`)。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/6f2ff2eb7d311016f05bcfdde7067bf415093179...50b7c91b58a7c0ea23fdc693fd0b3f92446edaed
- KAI-Scheduler [API/CRD变更] PodGroup v2alpha2 新增 `StalenessGracePeriod *metav1.Duration`(含 CRD 字段 + ParseStalenessGracePeriod),负值可禁用本组陈旧驱逐。https://github.com/kai-scheduler/KAI-Scheduler/pull/1942
- KAI-Scheduler [架构方向] 两份设计文档落地:DRA-backed 扩展资源(对接 KEP-5004,GA v1.37)与 AccountedResource CRD(任意资源/GPU 型号/显存限额)。https://github.com/kai-scheduler/KAI-Scheduler/pull/1938 https://github.com/kai-scheduler/KAI-Scheduler/pull/1635
- nvidia-container-toolkit [新能力] 新增 CDI hook `update-application-profile`,写 `EGLVisibleDGPUDevices` 把 EGL/Vulkan 可见 GPU 限制为容器内实际挂载的 `/dev/nvidiaN`。https://github.com/NVIDIA/nvidia-container-toolkit/compare/1cddfb0dc179136cd720090f0a13e6ce0de611ed...cee12f9654220e3a2c83c5aee5f0a5c06741712f

## kubernetes-sigs/dra-driver-nvidia-gpu: 6f2ff2eb -> 50b7c91b
- 比较 base 6f2ff2eb → HEAD 50b7c91b | ahead=4 | Release: v0.4.1 | https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/6f2ff2eb7d311016f05bcfdde7067bf415093179...50b7c91b58a7c0ea23fdc693fd0b3f92446edaed

### AI 总结重点(源码 diff 为据)
- **feature gate 默认状态整体前移**:issue 模板里的 gate 清单是各 gate 当前默认值的权威快照。本次 MPSSupport、DynamicMIG、NVMLDeviceHealthCheck、TimeSlicingSettings 四项从 `(disabled)` 改标 `(enabled)`,说明这批共享/健康检查能力已从 alpha 试验转为默认开;并新引入 DRAListTypeAttributes/DeviceMetadata/FabricManagerPartitioning/HostManagedIMEXDaemon 四个新 gate。对我们产品的启示:NVIDIA DRA 路径的 GPU 共享(MPS/time-slicing)与动态 MIG 已进入"默认可用"阶段,评估 DRA 驱动时的默认行为基线要随之更新。
  <details><summary>代码依据 .github/ISSUE_TEMPLATE/bug_report.yml</summary>

  ```diff
  -        - "TimeSlicingSettings (disabled)"
  -        - "MPSSupport (disabled)"
  -        - "PassthroughSupport (enabled)"
  -        - "DynamicMIG (disabled)"
  -        - "NVMLDeviceHealthCheck (disabled)"
  -        - "IMEXDaemonsWithDNSNames (disabled)"
           - "ComputeDomainCliques (disabled)"
           - "CrashOnNVLinkFabricErrors (disabled)"
  +        - "DRAListTypeAttributes (enabled)"
  +        - "DeviceMetadata (enabled)"
  +        - "DynamicMIG (enabled)"
  +        - "FabricManagerPartitioning (enabled)"
  +        - "HostManagedIMEXDaemon (enabled)"
  +        - "IMEXDaemonsWithDNSNames (disabled)"
  +        - "MPSSupport (enabled)"
  +        - "NVMLDeviceHealthCheck (enabled)"
  +        - "PassthroughSupport (enabled)"
  +        - "TimeSlicingSettings (enabled)"
  ```
  </details>
- **修 MPS 拆除后算力模式残留**:`MpsControlDaemon.Stop` 在删除 deployment 后补一步把这批 GPU 的 compute mode 从 EXCLUSIVE_PROCESS 复位回 DEFAULT;此前 Start 设成 EXCLUSIVE_PROCESS 却无对称复位,MPS 共享退租后 GPU 会卡在独占进程模式,导致后续普通/非 MPS 负载无法共用该卡。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/sharing.go</summary>

  ```diff
   	if err := ... delete deployment ...; err != nil {
   		return fmt.Errorf("failed to delete deployment: %w", err)
   	}
  +	// Start() sets the compute mode of these GPUs to EXCLUSIVE_PROCESS as
  +	// required by MPS. Reset it back to DEFAULT here so the GPUs are not left
  +	// stuck in EXCLUSIVE_PROCESS after teardown.
  +	if err := m.manager.nvdevlib.setComputeMode(m.devices.GpuUUIDs(), "DEFAULT"); err != nil {
  +		return fmt.Errorf("error resetting compute mode to DEFAULT: %w", err)
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- gate 默认前移是节奏信号,不是代码实现——证据只覆盖 issue 模板的默认标注,未见对应 gate 实现代码的 diff;要确认真实默认值仍需查 featuregate 定义。但方向明确:MPS/time-slicing/动态 MIG/健康检查正走向 GA 默认开。
- MPS 复位补丁揭示共享退租的状态清理是当前打磨重点,值得留意 time-slicing / MIG 拆除路径是否也有类似残留待补(本次未见)。

## kai-scheduler/KAI-Scheduler: ba7e186f -> 2d50f265
- 比较 base ba7e186f → HEAD 2d50f265 | ahead=11 | files=40 | Release: v0.16.4 → v0.16.6 | https://github.com/kai-scheduler/KAI-Scheduler/compare/ba7e186ff71d496db9f43164e7008af45b33b71d...2d50f2650339abe031a851d48ba381f376524e0a

### AI 总结重点(源码 diff 为据)
- **PodGroup 新增 `StalenessGracePeriod` 字段(API + CRD)**:v2alpha2 PodGroupSpec 加 `StalenessGracePeriod *metav1.Duration`(protobuf tag 10),并配 `ParseStalenessGracePeriod` 解析器与 CRD schema。语义:陈旧 gang(有运行 pod 但已不满足 gang 条件)在被驱逐前的最小保留窗口,负值禁用本组陈旧驱逐,缺省用调度器全局默认(60s)。也支持 pod 注解 `kai.scheduler/staleness-grace-period`。这是把"部分失败的 gang 立即被驱逐"改成"给宽限期等待瞬态恢复"。
  <details><summary>代码依据 pkg/apis/scheduling/v2alpha2/podgroup_types.go + CRD</summary>

  ```diff
  +	// StalenessGracePeriod is the minimum duration a stale PodGroup it allowed to remain in stale
  +	// status before stale workloads may be evicted to make room. Negative values disable stale gang
  +	// eviction for this PodGroup. Defaults to the scheduler's global staleness grace period.
  +	// +optional
  +	StalenessGracePeriod *metav1.Duration `json:"stalenessGracePeriod,omitempty" protobuf:"bytes,10,opt,name=stalenessGracePeriod"`
  ```
  ```diff
  # deployments/kai-scheduler/crds/scheduling.run.ai_podgroups.yaml
  +              stalenessGracePeriod:
  +                description: |-
  +                  StalenessGracePeriod is the minimum duration a stale PodGroup it allowed to remain in stale ...
  +                type: string
  ```
  </details>
- **DRA-backed 扩展资源设计提案**:新增 `docs/developer/designs/dra-extended-resources/README.md`,对接 KEP-5004(GA v1.37)。核心:DRA-only 节点的 `node.Status.Allocatable` 不再有 `nvidia.com/gpu` 条目,经典扩展资源语法会全线失效;方案让 KAI 接受 `nvidia.com/gpu: N` 落到 DRA 节点,通过 DeviceClass 的 ExtendedResourceName 映射把配额/公平份额/抢占记账保持正确。非目标明确排除了 MIG-via-DRA、分数 GPU、非 GPU 扩展资源的配额记账。
  <details><summary>代码依据 docs/developer/designs/dra-extended-resources/README.md</summary>

  ```diff
  +# DRA-Backed Extended Resources
  +Related: [KEP-5004](https://kep.k8s.io/5004) (alpha v1.34, beta-on-by-default v1.36, GA v1.37)
  +- Accept `nvidia.com/gpu: N` on pods targeting DRA-only nodes, with correct quota, fairshare, fit, and preemption accounting.
  +A DeviceClass can declare an `ExtendedResourceName`, and the scheduler synthesizes a special ResourceClaim ...
  ```
  </details>
- **AccountedResource CRD 提案(phase-1 限额)**:新增 `docs/developer/designs/accounted-resource-api.md`,提出 cluster-scoped `AccountedResource` CRD,让队列按任意逻辑资源限额——扩展资源(EFA)、通用 GPU 数、具体型号(H200/GB200)、跨整卡与分数卡的 GPU 显存、DRA 选中设备属性。支持"同一次分配记多个逻辑资源"(如 H200 节点上一张卡同时记 `gpu` 与 `gpu-h200`)。phase-1 只做 limit,不含 fair share/reclaim/deserved quota。
  <details><summary>代码依据 docs/developer/designs/accounted-resource-api.md</summary>

  ```diff
  +# AccountedResource API Proposal for KAI
  +The proposal is to add a cluster-scoped `AccountedResource` CRD. ... Queues then reference
  +these resources through `spec.accountedResources` and set per-queue limits.
  +- specific GPU products such as H200 or GB200;
  +- GPU memory across full GPUs and fractional GPUs;
  ```
  </details>
- **operator 纳管 PodDisruptionBudget**:新增 `known_types/poddisruptionbudgets.go` 并在 init 注册 `registerPodDisruptionBudgets()`,operator 现在会 collect/own PDB 资源(配套 "admission and scheduler PDB reconciliation loop" 修复 #1937),把 PDB 纳入 KAI operator 的 reconcile 闭环。
  <details><summary>代码依据 pkg/operator/operands/known_types/known_types.go</summary>

  ```diff
   	registerVerticalPodAutoscalers()
  +	registerPodDisruptionBudgets()
  ```
  </details>

### 后续发展方向 [AI]
- 两份提案都指向"DRA 成为 GPU 记账主线":DRA 扩展资源解决迁移期兼容,AccountedResource 解决按型号/显存的细粒度配额——证据是设计文档,尚无实现 diff,落地形态待后续 PR。
- StalenessGracePeriod 已是可用字段(API+CRD+解析器齐全),对多租户 gang 调度的稳定性直接有用;可预期后续补 time-slicing/抢占路径上对该字段的消费逻辑。

## NVIDIA/nvidia-container-toolkit: 1cddfb0d -> cee12f96
- 比较 base 1cddfb0d → HEAD cee12f96 | ahead=4 | files=13 | Release: v1.20.0-rc.1 | https://github.com/NVIDIA/nvidia-container-toolkit/compare/1cddfb0dc179136cd720090f0a13e6ce0de611ed...cee12f9654220e3a2c83c5aee5f0a5c06741712f

### AI 总结重点(源码 diff 为据)
- **新增 CDI hook `update-application-profile`(EGL/Vulkan 可见性收窄)**:新 package `cmd/nvidia-cdi-hook/update-application-profile` + `internal/discover/application_profile.go`,在 CreateContainer 阶段枚举容器内 `/dev` 下的 `nvidiaN` char 设备,把 minor 号写进驱动 application profile 的 `EGLVisibleDGPUDevices`(`etc/nvidia/nvidia-application-profiles-rc.d/10-container.conf`),使容器内 EGL/Vulkan 只看到实际挂载的 GPU。新 HookName `ApplicationProfileHook` 注册进 hook 类型表并接入 `common-nvml` discoverer。补齐了图形栈下 GPU 可见性隔离的一环(此前 EGL/Vulkan 可能看到宿主全部 GPU)。
  <details><summary>代码依据 internal/discover/hooks.go + commands.go</summary>

  ```diff
  +	// An ApplicationProfileHook updates driver settings through "application
  +	// profiles". It currently restricts EGL/Vulkan GPU visibility inside the
  +	// container to the GPUs actually mounted.
  +	ApplicationProfileHook = HookName("update-application-profile")
  ```
  ```diff
   	case CreateSymlinksHook, ChmodHook, DisableDeviceNodeModificationHook, EnableCudaCompatHook, UpdateLDCacheHook, ApplicationProfileHook:
   		return OCIHookTypeCreateContainer
  ```
  </details>
- **驱动库匹配从通配改为精确驱动版本**:`graphicsDriverLibraries` 引入 `driverVersion` 字段,`isDriverLibrary` 从 `libraryName + ".*.*"` 的 glob 匹配改为 `== libraryName + "." + driverVersion` 的精确匹配;`libnvidia-allocator.so`/`libnvidia-vulkan-producer.so`/`libglxserver_nvidia.so` 均改用显式驱动版本后缀。消除 `.*.*` 误匹配到非当前驱动版本库的风险。
  <details><summary>代码依据 internal/discover/graphics.go</summary>

  ```diff
  -	// TODO: Instead of `.*.*` we could use the driver version.
  -	pattern := strings.TrimSuffix(libraryName, ".") + ".*.*"
  -	match, _ := filepath.Match(pattern, filename)
  -	return match
  +	return filename == strings.TrimSuffix(libraryName, ".")+"."+d.driverVersion
  ```
  </details>

### 后续发展方向 [AI]
- application-profile hook 目前只写 EGL/Vulkan 一项(EGLVisibleDGPUDevices),usage 明确写"currently";可预期后续扩展到其它 application profile 键位,是图形/推理容器 GPU 隔离的新扩展点。证据只覆盖当前 hook 实现,未见更多 profile 键。

## NVIDIA/gpu-operator: c37a3850 -> eaadd226
- 比较 base c37a3850 → HEAD eaadd226 | ahead=10 | files=10 | Release: v26.3.3 | https://github.com/NVIDIA/gpu-operator/compare/c37a3850b40db6dbd850aa75119dd479f75935ec...eaadd226089ca67ae0f30d4ffff5f77ad9429596

### AI 总结重点(源码 diff 为据)
- **validator 定位 nvidia-smi 改多路径 + 可执行校验加固**:`resolveHostNvidiaSMI` 从只查 `/usr/bin/nvidia-smi` 单一路径,改为遍历 `hostNvidiaSMISearchPaths`(/usr/bin、/usr/sbin、/bin、/sbin、WSL 路径、/opt/bin),且每个候选必须是"常规、非空、可执行(perm&0o111)"文件才接受,返回值从 `os.FileInfo` 改为解析后的路径字符串,`validateHostDriver` 的 `chroot` 参数改用该路径。既支持 NixOS/WSL 等非标准布局,又防止特权 validator 误 exec 非标准路径下的伪 nvidia-smi。
  <details><summary>代码依据 cmd/nvidia-validator/main.go</summary>

  ```diff
  +var hostNvidiaSMISearchPaths = []string{
  +	"/usr/bin/nvidia-smi", "/usr/sbin/nvidia-smi", "/bin/nvidia-smi",
  +	"/sbin/nvidia-smi", wslNvidiaSMIPath, "/opt/bin/nvidia-smi",
  +}
  -func resolveHostNvidiaSMI(hostRootCtrPath string) (os.FileInfo, error) {
  -	f, err := pathrs.OpenInRoot(hostRootCtrPath, "/usr/bin/nvidia-smi")
  +func resolveHostNvidiaSMI(hostRootCtrPath string) (string, error) {
  +	for _, nvidiaSMIPath := range hostNvidiaSMISearchPaths {
  +		...
  +		if !fileInfo.Mode().IsRegular() || fileInfo.Size() == 0 || fileInfo.Mode().Perm()&0o111 == 0 {
  +			continue  // skip non-executable / empty / non-regular
  +		}
  +		return nvidiaSMIPath, nil
  ```
  </details>
- **镜像摘要查找改用带版本 RepoTags 而非 latest**:commit "update digest lookup to use versioned RepoTags instead of latest",避免解析镜像摘要时命中 `latest` 标签造成版本漂移(patch 未进前 8 大文件节选,依据取自实质提交与信号文件列表)。

### 后续发展方向 [AI]
- 本期以 validator 稳健性/安全加固与 CI(renovate)为主,无 ClusterPolicy CRD 字段变更;`api/nvidia/v1/clusterpolicy_types.go` 未命中,CRD 面本期稳定。

## 本期无实质改动(折叠)
<details>

- NVIDIA/gpu-driver-container — 仅 RHEL UBI base 镜像 digest 刷新(ubi8 8.10、ubi9 9.8、ubi10 10.2 同版本 digest 更新),无 OS/预编译矩阵变化,不单列正文。
- NVIDIA/k8s-device-plugin — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=eaadd226089ca67ae0f30d4ffff5f77ad9429596 branch=main release=v26.3.3 scanned=2026-07-24 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=cee12f9654220e3a2c83c5aee5f0a5c06741712f branch=main release=v1.20.0-rc.1 scanned=2026-07-24 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0ad335fb28b96957aa3f9fdda6dfdab9040e69e9 branch=main release=— scanned=2026-07-24 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=88a79d7e98c146e13a6bbb48fff6effdc87e541d branch=main release=v0.19.3 scanned=2026-07-24 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=50b7c91b58a7c0ea23fdc693fd0b3f92446edaed branch=main release=v0.4.1 scanned=2026-07-24 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-24 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-24 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f484af1ba590265e0cb429ca71e3c08cb8374a5d branch=main release=v0.14.4 scanned=2026-07-24 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2d50f2650339abe031a851d48ba381f376524e0a branch=main release=v0.16.6 scanned=2026-07-24 -->
