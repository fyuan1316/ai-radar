# NVIDIA 算力栈 diff 雷达 2026-10-07

## 摘要
- gpu-operator:把所有 operand(DCGM/exporter/MPS/MIG-manager/device-plugin/GFD)的 `toolkit-validation` 启动门控从"nvidia 模块是否出现在 `/proc/modules`"收紧为"`/sys/module/nvidia/initstate` 是否为 `live`"——从"已加载"升级到"已初始化完成"才放行 operand,堵住模块加载中途抢跑的窗口。
- dra-driver-nvidia-gpu:MIG 创建逻辑从单一 `Profile` 改为多候选 `CandidateProfiles`,解决同名 GI profile 下存在多个 CI profile(如 `1g.37gb` 与其 rev1,SM 数不同)时选错的问题,创建时择优并校验一致性。
- KAI-Scheduler:两处调度正确性修复——over-quota 余量改为逐优先级就地分配(高优先级队列未满足前不外溢到低优先级);事件广播器按 UID+Type+Reason 计配额,防止重复状态事件把 Evict 事件挤丢。

## 当日重要改变
- NVIDIA/gpu-operator [架构方向] operand 就绪门控语义变更:由检测 `/proc/modules` 中 `^nvidia ` 行存在,改为 `grep -qsx live /sys/module/nvidia/initstate`,要求驱动模块进入 `live` 态才启动下游 operand。证据 assets/state-dcgm/0400_dcgm.yml 等 6 个 daemonset。 https://github.com/NVIDIA/gpu-operator/commit/aa22a3852d45cacb03438140fba6bfe98d586f6f
- kubernetes-sigs/dra-driver-nvidia-gpu [新能力] MIG 分片的 CI profile 多候选择优:`MigSpec.Profile` → `MigSpec.CandidateProfiles []nvdev.MigProfile`,新增 `validateMigProfiles()`/`selectCIProfile()`,偏好多处理器(SM)数最高的 CI profile。证据 cmd/gpu-kubelet-plugin/mig.go、nvlib.go。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/4c1a872b2ba86588f9e85cb0d13fc36674189b35
- kai-scheduler/KAI-Scheduler [行为修正] over-quota 公平分配改为逐优先级一遍到位,杜绝舍入余量先漏给低优先级队列。证据 pkg/scheduler/plugins/proportion/resource_division/resource_division.go。 https://github.com/kai-scheduler/KAI-Scheduler/commit/a1481143d674cee3fe0f260369fd9edf17e48669

## NVIDIA/gpu-operator: 1b64815e -> 3d141d8e
- 比较 1b64815e...3d141d8e | ahead=6 | files=21 | Release: v26.7.1 | https://github.com/NVIDIA/gpu-operator/compare/1b64815e64068b618856c9f7c7f3f8bb3d13f9bf...3d141d8e66bf4851a3a95b1e12789d6cb679faea

### AI 总结重点(源码 diff 为据)
- **operand 启动门控从"模块已加载"收紧为"模块已初始化(live)"**。所有带 `toolkit-validation` initContainer 的 operand(DCGM、dcgm-exporter、MPS control daemon、MIG manager、device-plugin、GFD)的等待条件,由 `grep -q '^nvidia ' /proc/modules`(只要内核模块出现在 /proc/modules 即视为就绪)改为 `grep -qsx live /sys/module/nvidia/initstate`(整行精确匹配 `live`、`-s` 静默报错)。差异在于:模块刚 insmod 但 `init_module` 尚未跑完时它已在 /proc/modules 出现,旧判据会提前放行;新判据要求 sysfs initstate 进入 `live`,即模块初始化真正完成,避免 operand 抢在驱动可用前启动。
  <details><summary>代码依据 assets/state-dcgm/0400_dcgm.yml(exporter/mps/mig-manager/device-plugin/gfd 同款)</summary>

  ```diff
  -        args: ["until [ -f /run/nvidia/validations/toolkit-ready ] && { grep -q '^nvidia ' /proc/modules || [ -e /dev/dxg ]; }; do echo waiting for nvidia container stack to be setup; sleep 5; done"]
  +        args: ["until [ -f /run/nvidia/validations/toolkit-ready ] && { grep -qsx live /sys/module/nvidia/initstate || [ -e /dev/dxg ]; }; do echo waiting for nvidia container stack to be setup; sleep 5; done"]
  ```
  </details>
- **跨 GPU 栈统一加 `app.kubernetes.io/component` 标签,并把它列为"受保护标签"不许用户覆盖**。DCGM/dcgm-exporter 的 daemonset(assets 与 manifests 两处模板)新增 `app.kubernetes.io/component: nvidia-dcgm`/`nvidia-dcgm-exporter`;object_controls.go 把原 `applyCommonDaemonsetMetadata` 内联的标签处理拆出 `applyCommonDaemonsetLabel`,对 `app.kubernetes.io/component` 这类组件标签在冲突时跳过用户覆盖并记日志,同时保留原有对 `app`/`app.kubernetes.io/part-of`(DaemonSet 不可变 selector 依赖)的保护。
  <details><summary>代码依据 controllers/object_controls.go + manifests/state-dcgm/0500_daemonset.yaml</summary>

  ```diff
  +// applyCommonDaemonsetLabel merges a custom label while preserving existing component
  +// labels and pod identity labels.
  +func applyCommonDaemonsetLabel(obj *appsv1.DaemonSet, labelKey, labelValue string, logger logr.Logger) {
  +	hasComponentLabel := labelKey == "app.kubernetes.io/component" &&
  +		(daemonsetValue != "" || podValue != "")
  +	...
  +	if hasComponentLabel {
  +		if componentConflict { logger.Info("Skipping custom label override for protected operand labels", ...) }
  +		return
  +	}
  ```
  ```diff
       labels:
         app: nvidia-dcgm-dra
  +      app.kubernetes.io/component: nvidia-dcgm
         {{- range $k, $v := .Daemonsets.Labels }}
  -      {{- if and (ne $k "app") (ne $k "app.kubernetes.io/part-of") }}
  +      {{- if and (ne $k "app") (ne $k "app.kubernetes.io/part-of") (ne $k "app.kubernetes.io/component") }}
  ```
  </details>
- **CSV bundle 里 vgpu-device-manager 镜像改钉多架构 index 摘要**。`vgpu-device-manager:v0.5.1` 的 sha256 由 `0b20d3f4…`(单架构 manifest)换成 `a846793e…`(multi-arch index digest),bundle 的 spec 与环境变量 `VGPU_DEVICE_MANAGER_IMAGE` 同步改,使其在 amd64/arm64 都能拉取。
  <details><summary>代码依据 bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml</summary>

  ```diff
  -      image: nvcr.io/nvidia/cloud-native/vgpu-device-manager:v0.5.1@sha256:0b20d3f41754048531d732d0180d2f1648feffedb6cf6f2cfa19fff8f9c35150
  +      image: nvcr.io/nvidia/cloud-native/vgpu-device-manager:v0.5.1@sha256:a846793e78fac0d88156ee08f9835b9e29d99b0b316a165ea4a3acf0e27ad0fd
  ```
  </details>

### 后续发展方向 [AI]
- operand 门控改用 sysfs initstate,是把"驱动就绪"判据标准化到内核真实初始化状态——证据覆盖 6 个 daemonset 的 initContainer,未见对 `driver-validation`/sandbox 路径或非 operand 组件的同步改动,也未改 ClusterPolicy CRD 字段(本期无 `*_types.go` 命中)。
- `app.kubernetes.io/component` 统一化指向监控/发现侧的 label 对齐(DCGM 栈优先),为按组件做 ServiceMonitor/anti-affinity 选择打基础;证据只到 DCGM 两组件 daemonset + 通用标签合并逻辑,未见其它 operand(device-plugin/toolkit)同批补 component 标签。

## NVIDIA/gpu-driver-container: 599fbecb -> 74705e23
- 比较 599fbecb...74705e23 | ahead=4 | files=9 | Release: — | https://github.com/NVIDIA/gpu-driver-container/compare/599fbecbc0fff74106d08918e5e3e0418a06f1c0...74705e23cb2b04e85e42c7e467a413eb266a5b80

### AI 总结重点(源码 diff 为据)
- **多架构驱动镜像构建从 QEMU 跨架构模拟改为"各架构原生构建 + 事后合并 manifest"**。CI 把 `image` job 的 runner 由固定 `linux-amd64-cpu4` 改为 `linux-${matrix.arch}-cpu4`,matrix 新增 `arch: [amd64, arm64]`,删除 `setup-qemu-action`(注释原说明 ubuntu26.04 arm64 userland 需 qemu-v10.1.3、旧 v6.2.0 会挂),并把 `BUILD_MULTI_ARCH_IMAGES` 恒设为 true、按 arch 传 `DOCKER_BUILD_PLATFORM_OPTIONS`;新增 `image-manifest` job 用各 arch 原生产物拼多架构 index。native-only.mk 相应新增 `HOST_ARCH`(`uname -m`)→`NATIVE_ARCH` 映射,默认平台跟随宿主架构而非写死 amd64。
  <details><summary>代码依据 .github/workflows/image.yaml + native-only.mk</summary>

  ```diff
  -    runs-on: linux-amd64-cpu4
  +    runs-on: linux-${{ matrix.arch }}-cpu4
       strategy:
         matrix:
  +        arch:
  +          - amd64
  +          - arm64
  -      - name: Set up QEMU
  -        uses: docker/setup-qemu-action@v4
  ```
  ```diff
  -DOCKER_BUILD_PLATFORM_OPTIONS ?= --platform=linux/amd64
  +HOST_ARCH ?= $(shell uname -m)
  +NATIVE_ARCH ?= $(if $(filter x86_64 amd64,$(HOST_ARCH)),amd64,$(if $(filter aarch64 arm64,$(HOST_ARCH)),arm64,$(HOST_ARCH)))
  +DOCKER_BUILD_PLATFORM_OPTIONS ?= --platform=linux/$(NATIVE_ARCH)
  ```
  </details>
- **Ubuntu 基础镜像日期 tag 例行滚动**(renovate):resolute `20260912→20260927`、noble `20260911→20260917`、jammy `20260901.2→20260924.1`,改动遍及 base/Dockerfile 与 ubuntu22.04/24.04/26.04 的 Dockerfile 及 precompiled 变体,纯 OS 基线更新,无逻辑改动。

### 后续发展方向 [AI]
- 原生多架构构建坐实 arm64 为一等公民(此前靠 QEMU 模拟且在 ubuntu 26.04 上不稳),意味着后续预编译/OS 矩阵的 arm64 组合会更可靠地产出——证据限于 CI workflow 与 make 变量,未见镜像内驱动打包内容本身变化。

## kubernetes-sigs/dra-driver-nvidia-gpu: 53bae861 -> 76468d20
- 比较 53bae861...76468d20 | ahead=5 | files=13 | Release: v0.5.0 | https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/53bae861d6188eef85c6e2b4275aec504181c5a6...76468d20eff7635a5eee2980b610a2a4407dfd2f

### AI 总结重点(源码 diff 为据)
- **MIG 规格从"单一 Profile"重构为"多候选 CI profile,创建时择优"**。`MigSpec` 结构把 `Profile nvdev.MigProfile`/`GIProfileInfo` 单值改为 `CandidateProfiles []nvdev.MigProfile`。动机(注释直述):同一 GI profile 下可存在多个同名但 SM 消耗不同的 CI profile(如 `1g.37gb` 与 `1g.37gb rev1`),且只有在 GI 创建后才能确定该用哪个,故先保存全部候选,创建时再选有效者;并为将来通过 opaque config 覆盖选择另一 CI profile 留口。`createMigDevice` 不再直接取单 profile,而是先 `validateMigProfiles()` 校验候选集 GIProfileID 与名称一致,GI 创建后调 `selectCIProfile(gi, CandidateProfiles)` 选 CI(commit 标题:偏好 SM 数最高者)。`CanonicalName()`/`Attributes()`/`GetPerGpuAllocatableDevices` 等全部改用 `CandidateProfiles[0]`。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/mig.go + nvlib.go</summary>

  ```diff
   type MigSpec struct {
  -	Parent        *GpuInfo
  -	Profile       nvdev.MigProfile
  -	GIProfileInfo nvml.GpuInstanceProfileInfo
  +	Parent *GpuInfo
  +	// For the same GI profile, there can be multiple CI profiles (eg: 1g37gb and 1g37gb rev1).
  +	// ... prefer the CI profile that has the same number of multiprocessors as the GI profile.
  +	CandidateProfiles []nvdev.MigProfile
  +	GIProfileInfo     nvml.GpuInstanceProfileInfo
   }
  +func (m *MigSpec) validateMigProfiles() error {
  +	if len(m.CandidateProfiles) < 2 { return nil }
  +	... // 校验所有候选 GIProfileID 与 name 一致
  +}
  ```
  ```diff
  -	ciProfileInfo, ret := gi.GetComputeInstanceProfileInfo(profileInfo.CIProfileID, profileInfo.CIEngProfileID)
  -	if ret != nvml.SUCCESS { return nil, fmt.Errorf("error getting Compute instance profile info for '%v': %w", profile, ret) }
  +	ciProfileInfo, err := l.selectCIProfile(gi, migspec.CandidateProfiles)
  +	if err != nil { return nil, fmt.Errorf("error selecting valid CI profile for %q: %w", profileName, err) }
  ```
  </details>
- **文档侧(非代码):新增多节点 nvbandwidth 校验示例与排障指南**。install.md 增 staging/dev build 安装说明;compute-domain-workloads.md 增跨两节点、每节点 4 GPU 的 nvbandwidth MPIJob 示例,用 `podAffinity` 钉在 `nvidia.com/gpu.clique` 拓扑键上确保两 worker 落同一 NVLink 域,验证 ComputeDomain channel 跨节点;另加 troubleshooting.md(日志采集/`LOG_VERBOSITY` 调节,需重启 pod 生效)。hugo.toml 把 demo/specs/imex 的示例挂进文档站 static/assets。
  <details><summary>代码依据 site/content/docs/guides/compute-domain-workloads.md</summary>

  ```diff
  +## Multi-node `nvbandwidth` test (with MPI)
  +The worker pods use `podAffinity` on the `nvidia.com/gpu.clique` topology key so both workers land in the same NVLink domain.
  ```
  </details>

### 后续发展方向 [AI]
- CandidateProfiles 的引入把 MIG rev 变体(同名不同 SM)的选择从"启动时猜"推迟到"GI 建成后定",并显式预留 opaque-config 覆盖——指向未来允许用户/策略指定非默认 CI 变体的能力;证据在 mig.go/nvlib.go/partitions.go 结构与调用点,未见对应 CRD/API 字段落地(本期无 `_types.go`/`config/crd` 命中),覆盖只到内部实现。
- 多节点 nvbandwidth + clique 亲和示例显示 ComputeDomain 的重点仍在 NVLink 域内跨节点 GPU 直连带宽验证;证据仅文档与 demo spec,无调度/channel 代码改动。

## kai-scheduler/KAI-Scheduler: 9fceedff -> 532d0c09
- 比较 9fceedff...532d0c09 | ahead=3 | files=7 | Release: v0.18.3 | https://github.com/kai-scheduler/KAI-Scheduler/compare/9fceedff7808fd3c603ba64a49e33310b8446d3a...532d0c093f13be6f54f5770c9e45a1d6e10506ee

### AI 总结重点(源码 diff 为据)
- **over-quota 公平分配:舍入余量改为逐优先级就地消化,高优先级未满足不外溢**。`divideOverQuotaResource` 原本分两阶段——先对每个优先级跑 `divideUpToFairShare` 把 `remainingRequested` 攒进一个按优先级索引的 map,再在第二个循环里分舍入余量。问题是第二阶段可能把余量发给低优先级队列而高优先级队列尚未满足。重构后合并为单循环:按优先级从高到低,`divideUpToFairShare` 后立刻对本优先级的 `remainingRequested` 调 `divideRemainingResource`,余量先被同一(更高)优先级吃掉再降级。新增测试验证 3 个 over-quota GPU 全被两个高优先级队列吸收、低优先级队列只保留应得的 1。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/resource_division/resource_division.go</summary>

  ```diff
  -	remainingRequested := make(map[int]map[common_info.QueueID]*remainingRequestedResource)
  -	for _, priority := range priorities {
  -		remainingAmount, newRemainingRequested = divideUpToFairShare(...)
  -		maps.Copy(remainingRequested[priority], newRemainingRequested)
  -	}
  -	for _, priority := range priorities {
  -		if remainingAmount <= 0 { break }
  -		remaining, ok := remainingRequested[priority]
  -		...
  -		remainingAmount = divideRemainingResource(remainingAmount, remainingRequested[priority], resourceName)
  +	for _, priority := range priorities {
  +		if remainingAmount <= 0 { break }
  +		var remainingRequested map[common_info.QueueID]*remainingRequestedResource
  +		remainingAmount, remainingRequested = divideUpToFairShare(remainingAmount, kValue, queuesByPriority[priority], resourceName)
  +		if remainingAmount <= 0 || len(remainingRequested) == 0 { continue }
  +		remainingAmount = divideRemainingResource(remainingAmount, remainingRequested, resourceName)
   	}
  ```
  </details>
- **事件广播器按 (UID, Type, Reason) 计 spam 配额,防止重复状态事件挤掉 Evict 事件**。cache.go 把 `record.NewBroadcaster()` 换成自定义 `newEventBroadcaster()`,后者设 `CorrelatorOptions.SpamKeyFunc = UID + "/" + Type + "/" + Reason`。client-go 原本按涉及对象(UID)聚合限流,PodGroup 上反复发 Unschedulable/StaleJob/NotReady 会耗尽该对象的事件预算,导致关键的 Evict 事件被丢弃;改为每(对象,类型,原因)独立预算后,Evict 不再被状态事件饿死。
  <details><summary>代码依据 pkg/scheduler/cache/cache.go</summary>

  ```diff
  -	broadcaster := record.NewBroadcaster()
  +	broadcaster := newEventBroadcaster()
  +func newEventBroadcaster() record.EventBroadcaster {
  +	return record.NewBroadcaster(record.WithCorrelatorOptions(record.CorrelatorOptions{
  +		SpamKeyFunc: func(e *v1.Event) string {
  +			return string(e.InvolvedObject.UID) + "/" + e.Type + "/" + e.Reason
  +		},
  +	}))
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 两处均为调度正确性/可观测性修复(公平分配的优先级语义、事件不丢),无 API/调度框架结构变化;over-quota 修复坐实"优先级高的队列在 over-quota 余量分配上严格优先"的语义,证据限于 resource_division.go 单函数与其测试,未触及 reclaim/preempt 路径。

## 本期无实质改动(折叠)
<details><summary>5 个 repo 无新提交/仅 EMPTY</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=3d141d8e66bf4851a3a95b1e12789d6cb679faea branch=main release=v26.7.1 scanned=2026-10-07 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-07 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=74705e23cb2b04e85e42c7e467a413eb266a5b80 branch=main release=— scanned=2026-10-07 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d5dce58aff4ddf572dc52666f949b37d6be2846c branch=main release=v0.20.1 scanned=2026-10-07 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=76468d20eff7635a5eee2980b610a2a4407dfd2f branch=main release=v0.5.0 scanned=2026-10-07 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-07 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-07 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=87f9e3c6be56020a346e9d25379734291cfc9cca branch=main release=v0.15.1 scanned=2026-10-07 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=532d0c093f13be6f54f5770c9e45a1d6e10506ee branch=main release=v0.18.3 scanned=2026-10-07 -->
