# NVIDIA 算力栈 diff 雷达 2026-10-31

## 摘要
- **DRA 主线落地一处运行时安全闸**:dra-driver-nvidia-gpu 在 `Prepare` 真正改 MIG/共享/passthrough/FabricManager 状态**之前**,先校验 nvcdi 是否真的发现了必需的宿主设备节点(`/dev/nvidiactl`、`/dev/nvidia-uvm` 及每卡 `/dev/nvidiaN`),不完整的 CDI spec 直接拒发且**不进缓存**——防止 driver root 被部分填充(如 `nvidia-uvm-tools` 缺失)时把容器"准备成功"但少设备节点。
- **跨仓供应链/工具链收敛**:gpu-operator、k8s-device-plugin、mig-parted 同日把 `golang.org/x/mod/semver` 换成 `Masterminds/semver/v3`(或整型比较)并把 renovate `rebaseWhen` 从 `always` 调成 `behind-base-branch`,属机群级依赖/CI 口径统一,非能力改动,但 semver 库替换带来若干边界行为差异(无效版本、image digest、两位数 major)。
- **Blackwell 信号**:k8s-device-plugin 的 MPS `isAtLeastVolta` 改写后显式支持两位数 major(compute capability `10.0`),侧面确认 CC 10.0 代设备在 MPS 路径上的判定正确。

## 当日重要改变
- dra-driver-nvidia-gpu [新能力/安全] `Prepare` 前新增 `validateClaimCDIDeviceNodes` + nvcdi 设备节点校验(`validateCommonDeviceNodes`/`validateGPUDeviceNodes`),不完整 spec 不缓存;新增导出方法 `InvalidateDeviceSpec` 处理 rebind/MIG 模式切换后 minor 漂移。证据 `cmd/gpu-kubelet-plugin/cdi.go`、`device_state.go`。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/c22815de796dd8af176fb536846e513ca3189112
- k8s-device-plugin [行为变更] MPS `isAtLeastVolta` 弃用 semver 比较改整型拆分,显式支持 CC `10.0` 两位数 major,空/非法 CC 回退为非 Volta(16 clients)。证据 `cmd/mps-control-daemon/mps/device.go`。https://github.com/NVIDIA/k8s-device-plugin/commit/62cd70687d62b27e0dd28943c2be7a9d7967c1d2
- gpu-operator [API 文件改动/非 schema] `api/nvidia/v1alpha1/nvidiadriver_types.go` 的 `IsOpenKernelModulesRequired` 随 semver 库替换改写:无效/空版本从旧路径语义改为显式返回 `false`,image digest(`sha256:...`)现判定为需要 OpenRM(`true`)。无 CRD 字段增删。https://github.com/NVIDIA/gpu-operator/commit/f925d27e396deb925f155a2d427d65e08ec246ff
- gpu-driver-container [可靠性修复] 预编译 driver 启动脚本把 GSP 固件 staging 从"仅首次配置搜索路径时"改为"每次启动都 stage",修复搜索路径配置残留而固件来自上一个容器的错配。证据 `rhel9/precompiled/nvidia-driver`、`rhel10/...`。https://github.com/NVIDIA/gpu-driver-container/commit/062dd15acb16c7e2beeabf5b3378b439ef533910

## kubernetes-sigs/dra-driver-nvidia-gpu: 43ce2887 -> c22815de
- 比较 / 最新 Release:https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/43ce288759a2748748b5c9cacd7a34a8b4e89648...c22815de796dd8af176fb536846e513ca3189112 | Release v0.5.1 | ahead=2 files=4

### AI 总结重点(源码 diff 为据)
- **`Prepare` 新增前置设备节点校验闸**:在 updateCheckpoint 写 `PreparedClaims` 之前插入 `validateClaimCDIDeviceNodes(claim)`,该函数遍历 claim 的 allocation results,把 GPU/MigStatic/MigDynamic 三类都归结到物理父 GPU 的 UUID(VFIO 跳过,因其用 `/dev/vfio` 而非 NVIDIA 节点),再逐个调 `GetCommonEditsCached` 与 `GetDeviceSpecsByUUIDCached` 确认节点可被发现;任一失败即 `unable to prepare claim ...` 拒绝,避免在设备节点不全时就去改 MIG/共享/passthrough/FabricManager 状态。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  +	// Check host device-node readiness before prepareDevices can mutate MIG,
  +	// sharing, passthrough, or Fabric Manager state. A retry first rolls back
  +	// mutations left by its prior incomplete attempt above.
  +	if err := s.validateClaimCDIDeviceNodes(claim); err != nil {
  +		return nil, fmt.Errorf("unable to prepare claim %v: %w", claimUID, err)
  +	}
  ...
  +func (s *DeviceState) validateClaimCDIDeviceNodes(claim *resourceapi.ResourceClaim) error {
  +	...
  +		switch device.Type() {
  +		case GpuDeviceType:        gpus[device.Gpu.UUID] = struct{}{}
  +		case MigStaticDeviceType:  gpus[device.MigStatic.ParentUUID] = struct{}{}
  +		case MigDynamicDeviceType: gpus[device.MigDynamic.Parent.UUID] = struct{}{}
  +		case VfioDeviceType:       continue
  +		}
  +	...
  +	if _, err := s.cdi.GetCommonEditsCached(); err != nil {
  +		return fmt.Errorf("failed to validate CDI common device nodes: %w", err)
  +	}
  +	for uuid := range gpus {
  +		if _, err := s.cdi.GetDeviceSpecsByUUIDCached(uuid); err != nil {
  +			return fmt.Errorf("failed to validate CDI device node for GPU %q: %w", uuid, err)
  +		}
  +	}
  ```
  </details>
- **nvcdi 发现结果必须包含全局/每卡必需节点,否则不缓存**:`GetCommonEditsCached` / `GetDeviceSpecsByUUIDCached` 在写 `specCache` 前分别过 `validateCommonDeviceNodes`(要求 `/dev/nvidiactl`、`/dev/nvidia-uvm` 等)与 `validateGPUDeviceNodes`(按 UUID 匹配 `/dev/nvidiaN`,新增正则 `^/dev/nvidia(0|[1-9]\d?)$`)。nvcdi 的字符设备发现器按 devRoot 解析路径、不存在就静默省略,此校验把"部分填充的 driver root"从静默漏节点变成显式报错。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/cdi.go</summary>

  ```diff
  +var nvidiaGPUDeviceNodePattern = regexp.MustCompile(`^/dev/nvidia(0|[1-9]\d?)$`)
  ...
  	v, err := cdi.nvcdiClaim.GetCommonEdits()
  -
  	if err != nil { return nil, err }
  +	if err := validateCommonDeviceNodes(v); err != nil {
  +		return nil, err
  +	}
  	cdi.specCache.Set(key, v, time.Duration(5*time.Minute))
  ...
  +// validateCommonDeviceNodes verifies that nvcdi emitted the global NVIDIA
  +// control and UVM device nodes required by GPU and MIG workloads.
  +	requiredPaths := []string{ "/dev/nvidiactl", "/dev/nvidia-uvm", ... }
  ```
  </details>
- **rebind/MIG 模式切换后 minor 漂移处理**:新增导出方法 `InvalidateDeviceSpec(uuid)` 删缓存,配套内部 `getDeviceSpecsByUUIDAndMinor` 先按预期 minor 校验、不符就失效重取一次;`discoverSiblingAllocatables` 在把 VFIO 设备 rebind 回 nvidia 驱动后**无条件** invalidate(即便 minor 未变),因为同-minor 的旧缓存可能掩盖已失效的宿主节点。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  		device.Vfio.parent = gpu.Gpu
  +		// Always invalidate after rebinding, even if the minor is unchanged.
  +		// getDeviceSpecsByUUIDAndMinor only refreshes entries with a mismatched
  +		// minor, so a same-minor cache entry could hide a stale host device node.
  +		s.cdi.InvalidateDeviceSpec(gpu.Gpu.UUID)
  ```
  </details>
- 配套新增单测 `cmd/gpu-kubelet-plugin/cdi_test.go`(+366,fakeNVCDI 覆盖 common/per-device 校验与缓存计数)与 bats 鲁棒性用例(删 `nvidia-uvm-tools` 节点验证"不完整 CDI 失败且不缓存")。

### 后续发展方向 [AI]
- 该 commit 把 DRA 原生路径的失败模式从"准备看似成功、容器跑起来才发现少设备节点"前移到 Prepare 阶段显式拒绝,是 DRA GPU 驱动走向生产健壮性的典型补洞(rebind/MIG 模式切换是触发源)。证据只覆盖 kubelet-plugin 的 CDI/DeviceState 路径,未见对 ResourceSlice 发布侧或调度器侧的联动改动。

## NVIDIA/k8s-device-plugin: 29dad4b6 -> 62cd7068
- 比较 / 最新 Release:https://github.com/NVIDIA/k8s-device-plugin/compare/29dad4b682b5abc1df469d50a2bfe1f57abc7132...62cd70687d62b27e0dd28943c2be7a9d7967c1d2 | Release v0.20.1 | ahead=7 files=31

### AI 总结重点(源码 diff 为据)
- **MPS `isAtLeastVolta` 弃 semver 改整型比较**:原用 `golang.org/x/mod/semver` 对 compute capability 做 canonical 比较(`v7.5`),改为 `strings.Cut` 拆 major/minor 后 `strconv.Atoi` 比,判定 `major>7 || (major==7 && minor>=5)`。解析失败(空串、`abc`)返回 `false`→回退非 Volta 的 16 clients;新测用例显式加入 `10.0`(两位数 major,判 Volta+、48 clients)。此为 commit "remove dependency on golang.org/x/mod" 一揽子的一部分(中途有 revert 又重做)。
  <details><summary>代码依据 cmd/mps-control-daemon/mps/device.go</summary>

  ```diff
  -	"golang.org/x/mod/semver"
  +	"strconv"
  ...
  -	vCc := "v" + strings.TrimPrefix(d.ComputeCapability, "v")
  -	return semver.Compare(semver.Canonical(vCc), semver.Canonical("v7.5")) >= 0
  +	majorStr, minorStr, _ := strings.Cut(strings.TrimPrefix(d.ComputeCapability, "v"), ".")
  +	major, err := strconv.Atoi(majorStr)
  +	if err != nil { return false }
  +	minor, err := strconv.Atoi(minorStr)
  +	if err != nil { return false }
  +	return major > 7 || (major == 7 && minor >= 5)
  ```
  </details>

### 后续发展方向 [AI]
- 纯依赖收敛 + 边界健壮化,无新设备能力;两位数 major 测试用例坐实了 Blackwell(CC 10.x)在 MPS 容量判定路径上被正确当作 ≥Volta。证据仅覆盖 MPS 子模块,time-slicing/DRA 路径未动。

## NVIDIA/gpu-operator: f3126ac2 -> f925d27e
- 比较 / 最新 Release:https://github.com/NVIDIA/gpu-operator/compare/f3126ac2b4a535dd03f0b540cbed179800d336ff...f925d27e396deb925f155a2d427d65e08ec246ff | Release v26.7.2 | ahead=9 files=12

### AI 总结重点(源码 diff 为据)
- **semver 库迁移触及 `nvidiadriver_types.go` 的 OpenRM 判定逻辑**(非 CRD 字段改动):`IsOpenKernelModulesRequired` 从 `semver.Compare` 改 `Masterminds/semver/v3` 的 `NewVersion`/`Compare`;无效版本字符串从旧路径显式改为返回 `false`,新测用例坐实 `image digest`(`sha256:...`)判 `true`、`not-a-version`/空判 `false`。`state_manager.go`(k8s 版本校验)、`object_controls.go`(`RuntimeClasses` 的 nodev1 API 版本门限,无效版本按"低于最小值"回退 legacy API)同步改。
  <details><summary>代码依据 api/nvidia/v1alpha1/nvidiadriver_types.go + controllers/object_controls.go</summary>

  ```diff
  -	"golang.org/x/mod/semver"
  +	"github.com/Masterminds/semver/v3"
  ...
  -	gdsVersion := d.GPUDirectStorage.Version
  -	if !strings.HasPrefix(gdsVersion, "v") { gdsVersion = fmt.Sprintf("v%s", gdsVersion) }
  -	if semver.Compare(gdsVersion, consts.MinimumGDSVersionForOpenRM) >= 0 { return true }
  -	return false
  +	gdsVersion, err := semver.NewVersion(d.GPUDirectStorage.Version)
  +	if err != nil { return false }
  +	return gdsVersion.Compare(semver.MustParse(consts.MinimumGDSVersionForOpenRM)) >= 0
  ...
  -	if semver.Compare(n.k8sVersion, nodev1MinimumAPIVersion) <= 0 {
  +	// An unparseable version is treated as older than the minimum, so fall back to the legacy API.
  +	k8sVersion, err := semver.NewVersion(n.k8sVersion)
  +	if err != nil || k8sVersion.Compare(semver.MustParse(nodev1MinimumAPIVersion)) <= 0 {
  		createRuntimeClassFunc = transformRuntimeClassLegacy
  ```
  </details>
- 另:distroless/cc 基镜像 `v4.1.6`→`v4.1.8`(digest pin)、renovate `rebaseWhen: always→behind-base-branch`。

### 后续发展方向 [AI]
- ClusterPolicy / NVIDIADriver CRD **字段无增删**,本期是 semver 库统一带来的判定边界微调(主要影响 GDS→OpenRM 必需性与 RuntimeClass API 选择的非法输入处理)。证据仅覆盖 types/controllers,未见新功能面。

## NVIDIA/gpu-driver-container: ec01bc0b -> 062dd15a
- 比较:https://github.com/NVIDIA/gpu-driver-container/compare/ec01bc0b4e83362b8cb68603a0547b23c9a0d429...062dd15acb16c7e2beeabf5b3378b439ef533910 | Release — | ahead=2 files=2

### AI 总结重点(源码 diff 为据)
- **GSP 固件重复启动 staging 修复**(rhel9/rhel10 预编译路径):原逻辑把固件拷贝嵌在"配置固件搜索路径"的 else 分支内,即仅首次配置时 stage;改为无论搜索路径是否已配置,**每次启动**只要 `/opt/lib/firmware/nvidia/${DRIVER_VERSION}` 存在就重建目标目录并 `cp gsp_*.bin`——因为已配置的搜索路径会比上一个容器的固件"活得更久",重启/换容器后需重新落固件,否则 GSP 固件缺失致模块加载异常。
  <details><summary>代码依据 rhel9/precompiled/nvidia-driver</summary>

  ```diff
  -        if [ -d "/opt/lib/firmware/nvidia/${DRIVER_VERSION}" ]; then
  -            rm -rf $nv_fw_search_path/nvidia/${DRIVER_VERSION}
  -            mkdir -p $nv_fw_search_path/nvidia/${DRIVER_VERSION}
  -            cp /opt/lib/firmware/nvidia/${DRIVER_VERSION}/gsp_*.bin $nv_fw_search_path/nvidia/${DRIVER_VERSION}
  -        fi
  +    fi
  +    # A configured search path may outlive the firmware from a previous container.
  +    # Stage this driver's firmware on every startup before loading modules.
  +    if [ -d "/opt/lib/firmware/nvidia/${DRIVER_VERSION}" ]; then
  +        mkdir -p "$nv_fw_search_path/nvidia/${DRIVER_VERSION}"
  +        cp /opt/lib/firmware/nvidia/"${DRIVER_VERSION}"/gsp_*.bin \
  +            "$nv_fw_search_path/nvidia/${DRIVER_VERSION}/"
  +    fi
  ```
  </details>

### 后续发展方向 [AI]
- 驱动容器化可靠性补丁,聚焦 GSP 固件在容器重启场景的幂等 staging;rhel8 未在本 diff 出现(hunk 仅 rhel9/rhel10),未见预编译 OS 矩阵本身的增删。

## 本期无实质改动(折叠)
- NVIDIA/mig-parted:仅 CUDA 基镜像 patch bump(`13.4.2-base-ubi8`→`13.4.3`)+ renovate `rebaseWhen` 调整,无能力/配置面改动(ahead=8/files=53 主要是被过滤的 bump/CI 噪声)。
- NVIDIA/nvidia-container-toolkit:无新提交(release v1.20.1)。
- NVIDIA/dcgm-exporter:无新提交(release 4.8.4)。
- NVIDIA/DCGM:无新提交(master)。
- kai-scheduler/KAI-Scheduler:无新提交(release v0.16.14)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=f925d27e396deb925f155a2d427d65e08ec246ff branch=main release=v26.7.2 scanned=2026-10-31 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1d479dac4bd652cfb131d67b3662e72a31855a8d branch=main release=v1.20.1 scanned=2026-10-31 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=062dd15acb16c7e2beeabf5b3378b439ef533910 branch=main release=— scanned=2026-10-31 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=62cd70687d62b27e0dd28943c2be7a9d7967c1d2 branch=main release=v0.20.1 scanned=2026-10-31 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c22815de796dd8af176fb536846e513ca3189112 branch=main release=v0.5.1 scanned=2026-10-31 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-31 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-31 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=080132489de972ec5f7ae63be2150931c02aa79b branch=main release=v0.15.1 scanned=2026-10-31 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=0243c4e948b722893897cfd72e7f15cb8e371725 branch=main release=v0.16.14 scanned=2026-10-31 -->
</content>
</invoke>
