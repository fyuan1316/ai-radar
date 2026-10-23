# NVIDIA 算力栈 diff 雷达 2026-10-24

## 摘要
- **gpu-operator**:GDS(GPUDirect Storage)的驱动校验从已废弃的 `useOpenKernelModules` 布尔迁到 `kernelModuleType` 枚举(auto/open/proprietary),弃用字段不再能覆盖新字段的校验——OpenRM 的配置面正式以 `kernelModuleType` 为准。
- **dra-driver-nvidia-gpu**:Fabric Manager 分区匹配从「按 NVML gpuModuleID 数值比对」重写为「按 UUID / PCI 地址建索引匹配」,修掉 HGX A100 等 module ID ≠ FM physical ID 平台上的多卡 VFIO 分区错配。DRA 主线在补多卡 fabric 切分的正确性。
- 另:container-toolkit 把 CDI hook 的 driver params 文件改用新 fd-based 挂载 API 只读挂载(安全硬化);driver-container 驱动矩阵小步 bump。

## 当日重要改变
- **NVIDIA/gpu-operator** [弃用/字段迁移] GDS 开放内核模块校验从 `useOpenKernelModules`(已废弃)切到 `kernelModuleType=proprietary` 判定,错误提示引导用户改用 `kernelModuleType=open|auto`。证据 `controllers/nvidiadriver_controller.go`。https://github.com/NVIDIA/gpu-operator/compare/e136269e743140a5e9669a8fd9d525aff422f99c...5c77de84882c1f0c13a1ac3f3dbf2cb62687b7ac
- **kubernetes-sigs/dra-driver-nvidia-gpu** [新能力/正确性] Fabric Manager 分区成员匹配由 gpuModuleID 数值改为 UUID/PCI 身份索引,启动时建索引并拒绝不一致身份;module ID 仅作 H100+ 的 fallback。证据 `pkg/fabricmanager/identity.go`、`cmd/gpu-kubelet-plugin/device_state.go`。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/63e98d305bb66cb9f2a07a0669661329d320ee3f...9b0ddb6ca64ef4a41dea94ca06e4978b3230b6f8

## NVIDIA/gpu-operator: e136269e -> 5c77de84
- 比较: e136269e -> 5c77de84 | ahead=2 | files=3 | Release: v26.7.2
- https://github.com/NVIDIA/gpu-operator/compare/e136269e743140a5e9669a8fd9d525aff422f99c...5c77de84882c1f0c13a1ac3f3dbf2cb62687b7ac

### AI 总结重点(源码 diff 为据)
- `NVIDIADriverReconciler.Reconcile` 里 GDS 的「必须开 OpenRM」校验重写:旧逻辑三条件 `IsGDSEnabled() && IsOpenKernelModulesRequired() && !IsOpenKernelModulesEnabled()`,错误文案要求 `useOpenKernelModules=true`;新逻辑简化为 `IsOpenKernelModulesRequired() && KernelModuleType == "proprietary"`,文案改为要求 `kernelModuleType=open` 或 `kernelModuleType=auto`(由驱动容器按 GPU/驱动分支自选模块类型)。含义:**`useOpenKernelModules` 这个 bool 字段被 `kernelModuleType` 枚举接管,且显式设 `proprietary` 会被拦截**——配置面从「开/不开 OpenRM」升级为三态(auto/open/proprietary)。
  <details><summary>代码依据 controllers/nvidiadriver_controller.go</summary>

  ```diff
  -	if instance.Spec.IsGDSEnabled() && instance.Spec.IsOpenKernelModulesRequired() && !instance.Spec.IsOpenKernelModulesEnabled() {
  -		err := fmt.Errorf("GPUDirect Storage driver '%s' is only supported with NVIDIA OpenRM drivers. Please set 'useOpenKernelModules=true' to enable OpenRM mode", instance.Spec.GPUDirectStorage.Version)
  +	if instance.Spec.IsOpenKernelModulesRequired() && instance.Spec.KernelModuleType == "proprietary" {
  +		err := fmt.Errorf("GPUDirect Storage driver '%s' requires NVIDIA open kernel modules and cannot be used with 'kernelModuleType=proprietary'. Set 'kernelModuleType=open', or use 'kernelModuleType=auto' to let the driver container select the module type based on the GPU and driver branch", instance.Spec.GPUDirectStorage.Version)
  ```
  </details>
- 新增测试 `TestReconcileGDSKernelModuleType` / `TestDriverGDSKernelModuleType` 固化行为:driver 容器据 `kernelModuleType` 注入环境变量——非空时注 `KERNEL_MODULE_TYPE=<值>`,仅 `open` 时注 `OPEN_KERNEL_MODULES_ENABLED=true`;且显式验证**废弃字段 `UseOpenKernelModules` 不能覆盖 `kernelModuleType` 的校验**(用例注释 `Verify the deprecated field cannot override kernelModuleType validation`)。
  <details><summary>代码依据 internal/state/driver_manifest_test.go</summary>

  ```diff
  +			value, present := envValue(driverContainer, "KERNEL_MODULE_TYPE")
  +			require.Equal(t, moduleType != "", present)
  +			require.Equal(t, moduleType, value)
  +			value, present = envValue(driverContainer, "OPEN_KERNEL_MODULES_ENABLED")
  +			require.Equal(t, moduleType == "open", present)
  ```
  </details>

### 后续发展方向 [AI]
- `useOpenKernelModules` 进入事实废弃期,OpenRM 选择权下沉到 driver 容器的 `kernelModuleType=auto`(按 GPU 代次/驱动分支自选)。做 OAI 对标时,driver CRD 的开放内核模块配置应以 `kernelModuleType` 三态为准,老的 bool 字段仅作兼容。证据只覆盖 GDS 这一条校验路径与 driver manifest 的环境变量注入,未见 CRD `*_types.go` 本体改动(本期无 api/ 路径命中),字段是否同步标 deprecation 需另查。

## NVIDIA/nvidia-container-toolkit: d2454dea -> 57a2c442
- 比较: d2454dea -> 57a2c442 | ahead=2 | files=2 | Release: v1.20.1
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/d2454dea06a2e851f321d396ba1ef650dc19d350...57a2c44242d4163098fc110ca1bf92beca587d5b

### AI 总结重点(源码 diff 为据)
- CDI hook `disable-device-node-modification` 的 `createParamsFileInContainer` 把 driver params 文件的只读绑定挂载从「单次 `unix.Mount(MS_BIND|MS_RDONLY|...)`」重构为新 fd-based 挂载 API:`bindMountReadOnly` 走 `OpenTree(OPEN_TREE_CLONE)` + `MountSetattr(MOUNT_ATTR_RDONLY|MOUNT_ATTR_NODEV)` + `MoveMount`,并在挂载后再设 `MS_PRIVATE`(注释说明共享父挂载会覆盖挂载前设的传播属性)。遇内核不支持(`ENOSYS`)时回退 `bindMountReadOnlyLegacy`——先 `MS_BIND` 再 `MS_REMOUNT|MS_RDONLY`(因为 `mount(2)` 在 `MS_BIND` 时会忽略 `MS_RDONLY`)。即:**用更可靠的内核挂载语义保证 params 文件真正只读**,兜住老内核。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/disable-device-node-modification/params_linux.go</summary>

  ```diff
  -	if err := unix.Mount(utils.GetProcFdPath(modifiedParamsFile), utils.GetProcFdPath(nvidiaDriverParamsFile), "",
  -		unix.MS_BIND|unix.MS_RDONLY|unix.MS_NODEV|unix.MS_PRIVATE|unix.MS_NOSYMFOLLOW, ""); err != nil {
  +	err = bindMountReadOnly(modifiedParamsFile, nvidiaDriverParamsFile)
  +	if errors.Is(err, unix.ENOSYS) {
  +		return bindMountReadOnlyLegacy(containerRoot, modifiedParamsFile, nvidiaDriverParamsFile, nvidiaDriverParamsPath[1:])
  +	}
  +	return err
  +}
  +func bindMountReadOnly(source *os.File, target *os.File) error {
  +	treeFd, err := unix.OpenTree(int(source.Fd()), "", unix.AT_EMPTY_PATH|unix.OPEN_TREE_CLONE|unix.OPEN_TREE_CLOEXEC)
  +	...
  +	if err := unix.MountSetattr(treeFd, "", unix.AT_EMPTY_PATH, &unix.MountAttr{Attr_set: unix.MOUNT_ATTR_RDONLY | unix.MOUNT_ATTR_NODEV}); err != nil {
  ```
  </details>

### 后续发展方向 [AI]
- container-toolkit 在往新内核挂载 API(mount_setattr/move_mount 系列)迁移,目的在于让 CDI 注入的敏感文件挂载语义确定可控(只读+nodev+private)。对我们产品的启示:若基于 CDI 做设备注入,需关注运行节点内核版本,老内核仍走 remount 兼容路径。证据仅覆盖这一个 hook,未见其他 hook 同步改造。

## NVIDIA/gpu-driver-container: d6d82abe -> 3e9a7e8b
- 比较: d6d82abe -> 3e9a7e8b | ahead=3 | files=13 | Release: —
- https://github.com/NVIDIA/gpu-driver-container/compare/d6d82abedb448b8f67992f1b59c86f163df24772...3e9a7e8bbcfdbf5e1cd18d76cf66a734ec4dcd17

### AI 总结重点(源码 diff 为据)
- 驱动版本矩阵整体小步上移:三条活跃数据中心分支 `580.178.04 → 580.196.07`、`595.91.07 → 595.112.07`、`615.71.09 → 615.71.10`,`versions.mk`、`.common-ci.yml`、`.github/workflows/image.yaml` 同步;golang 构建版本 `1.27.1 → 1.27.3`。属例行版本跟进,非能力变化。
  <details><summary>代码依据 versions.mk</summary>

  ```diff
  -DRIVER_VERSIONS ?= 580.178.04 595.91.07 615.71.09
  +DRIVER_VERSIONS ?= 580.196.07 595.112.07 615.71.10
  -GOLANG_VERSION := 1.27.1
  +GOLANG_VERSION := 1.27.3
  ```
  </details>
- 多个发行版入口脚本(rhel8/9/10 的 `nvidia-driver`、precompiled 版、vgpu-manager 版)在 `_mount_rootfs` 的 SELinux 兼容分支里新增一段:若存在 `${RUN_DIR}/driver/lib/firmware` 目录,则对其 `chcon -R -t container_file_t`。即**为 OpenShift 等开启 SELinux 的主机把驱动 firmware 目录也打上容器可访问的安全上下文**(此前只处理 `driver/dev`),否则 firmware 加载会被 SELinux 拦。
  <details><summary>代码依据 rhel9/nvidia-driver(其余发行版同形)</summary>

  ```diff
           chcon -R -t container_file_t ${RUN_DIR}/driver/dev
  +        if [ -d ${RUN_DIR}/driver/lib/firmware ]; then
  +            echo "Change firmware files security context for selinux compatibility"
  +            chcon -R -t container_file_t ${RUN_DIR}/driver/lib/firmware
  +        fi
  ```
  </details>

### 后续发展方向 [AI]
- firmware 目录的 SELinux relabel 覆盖全发行版矩阵,说明新驱动分支(含 615.x)开始依赖 `/lib/firmware` 下的固件文件,OpenShift 场景需确保该 relabel 生效。对标 OAI:自家 driver 容器在 SELinux 节点上同样要处理 firmware 目录上下文,否则特定 GPU 固件加载失败。证据为 shell 脚本,未涉及驱动本体。

## kubernetes-sigs/dra-driver-nvidia-gpu: 63e98d30 -> 9b0ddb6c
- 比较: 63e98d30 -> 9b0ddb6c | ahead=7 | files=19 | Release: v0.5.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/63e98d305bb66cb9f2a07a0669661329d320ee3f...9b0ddb6ca64ef4a41dea94ca06e4978b3230b6f8

### AI 总结重点(源码 diff 为据)
- 新增 `pkg/fabricmanager/identity.go`:`normalizePCIBusID` 统一 FM/NVML 八位域与 sysfs 四位域的 PCI BDF 表示;`gpuIdentity{uuid, pci}` 结构;`Manager.PhysicalIDForGPU(uuid, pciBusID, moduleID)` 按 UUID/PCI 索引解析物理 ID,**仅当整幅拓扑都缺 UUID/PCI 身份(H100 及更新,FM physical ID == NVML module ID)时才用 module ID 兜底**,且 UUID 与 PCI 若都已知必须一致,否则报冲突。核心修复:此前用数值 gpuModuleID 直接比对,在 HGX A100 等 module ID ≠ FM physical ID 的平台会错配分区。
  <details><summary>代码依据 pkg/fabricmanager/identity.go</summary>

  ```diff
  +func (m *Manager) PhysicalIDForGPU(uuid, pciBusID string, moduleID int) (int, bool, error) {
  +	pci, err := normalizePCIBusID(pciBusID)
  +	...
  +	if len(m.physicalIDByUUID) == 0 && len(m.physicalIDByPCI) == 0 {
  +		if _, found := m.identityByPhysicalID[moduleID]; moduleID > 0 && found {
  +			return moduleID, true, nil   // H100+ fallback: FM physical ID == NVML module ID
  +		}
  +		return 0, false, nil
  +	}
  +	uuidID, uuidFound := m.physicalIDByUUID[uuid]
  +	pciID, pciFound := m.physicalIDByPCI[pci]
  +	if uuidFound && pciFound && uuidID != pciID {
  +		return 0, false, fmt.Errorf("fabricmanager: GPU UUID %q PCI %q conflicts: physical IDs %d and %d", ...)
  ```
  </details>
- `Manager` 结构新增三张索引 `physicalIDByUUID / physicalIDByPCI / identityByPhysicalID`,在 `recordsPartitions` 记录分区时同步建立并做一致性校验(同一 UUID/PCI 映射到多个 physical ID、或同一 physical ID 身份冲突均报错;全零 BDF+空 UUID 视为不可用)。即**身份索引在启动记录拓扑时一次性建好并校验**,不再运行时临时按 module ID 猜。
  <details><summary>代码依据 pkg/fabricmanager/manager.go</summary>

  ```diff
   type Manager struct {
  -	client         Client
  -	partitionsByID map[int]Partition
  +	client               Client
  +	partitionsByID       map[int]Partition
  +	physicalIDByUUID     map[string]int
  +	physicalIDByPCI      map[string]int
  +	identityByPhysicalID map[int]gpuIdentity
  ```
  </details>
- kubelet-plugin 侧 `resolveFabricPartition` / `attachFabricManagerPartitions` 改用 `PhysicalIDForGPU` 和 `FindPartitionByPhysicalIDs`(替换旧 `FindPartitionByModuleIDs`),错误信息也从 "GPU module set ... does not match" 改为 "GPU physical ID set ..."。对 vfio-pci 已绑定、module ID 解析不出的 GPU,不再直接报无 moduleID,而是按 UUID/PCI 找 FM 成员。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  -		if gpu == nil || gpu.gpuModuleID == 0 {
  -			return 0, fmt.Errorf("fabric manager: no gpuModuleID for GPU at PCI %q", pci)
  +		physicalID, found, err := s.fmManager.PhysicalIDForGPU(gpu.UUID, gpu.pciBusID, gpu.gpuModuleID)
  +		if !found {
  +			return 0, fmt.Errorf("fabric manager: no member for GPU UUID %q PCI %q (NVML module ID %d)", gpu.UUID, gpu.pciBusID, gpu.gpuModuleID)
  -	partitionID, ok := s.fmManager.FindPartitionByModuleIDs(moduleIDs)
  +	partitionID, ok := s.fmManager.FindPartitionByPhysicalIDs(physicalIDs)
  ```
  </details>
- 文档侧(mig.md)明确 `DynamicMIG` 语义:Ampere 若 MIG 已开且启用 `DynamicMIG`,驱动只广告 MIG 分区、不再广告整卡,因此请求整卡的 claim(含监控/校验组件的 management claim)无法在该卡调度——这是对 DynamicMIG 行为边界的说明,非代码改动。

### 后续发展方向 [AI]
- DRA 驱动在补「NVSwitch/NVLink fabric 多卡分区」的身份正确性:从数值 module ID 升级到 UUID/PCI 身份索引 + 严格一致性校验,是让 HGX A100 这类平台的多卡 VFIO passthrough 分区可靠的前置。方向上 DRA 路径正把「物理拓扑→可分配资源」的映射做扎实,这是整卡/分区级共享(区别于 HAMi 软切分)的底座。证据覆盖 fabricmanager 包与 kubelet-plugin 的分区解析,未见 ResourceSlice 属性 schema 本体变化(`resourceslice-attributes.md` 仅小改)。

## 本期无实质改动(折叠)
<details><summary>5 个 repo 无新提交或仅 bump/CI</summary>

- NVIDIA/k8s-device-plugin(无新提交,v0.20.1)
- NVIDIA/dcgm-exporter(无新提交,4.8.4)
- NVIDIA/DCGM(无新提交,master)
- NVIDIA/mig-parted(无新提交,v0.15.1)
- kai-scheduler/KAI-Scheduler(无新提交,v0.16.13)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=5c77de84882c1f0c13a1ac3f3dbf2cb62687b7ac branch=main release=v26.7.2 scanned=2026-10-24 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=57a2c44242d4163098fc110ca1bf92beca587d5b branch=main release=v1.20.1 scanned=2026-10-24 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=3e9a7e8bbcfdbf5e1cd18d76cf66a734ec4dcd17 branch=main release=— scanned=2026-10-24 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-24 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9b0ddb6ca64ef4a41dea94ca06e4978b3230b6f8 branch=main release=v0.5.1 scanned=2026-10-24 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-24 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-24 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-24 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=96eb3764caadc87dfb1508af848970868dfbb8b4 branch=main release=v0.16.13 scanned=2026-10-24 -->
</content>
</invoke>
