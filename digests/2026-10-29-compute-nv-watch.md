# NVIDIA 算力栈 diff 雷达 2026-10-29

## 摘要
- 两仓有实质代码:container-toolkit 给 CDI spec 补了 **`void` 哨兵设备(mount 版)**,堵住"env-var + volume-mounts 两套设备策略并存时被 NVIDIA Container Runtime 二次注入设备"的坑;KAI-Scheduler 一个大 feat 把 NUMA 插件从"设备/CPU 对齐"升级为**内存感知的 NUMA 调度**(新增 memory-group 账本,按 NUMA mask 记录每 pod 内存归属并做容量/冲突校验)。
- container-toolkit 另一半是构建侧加固:driver/toolkit init-container 用的 busybox 从 debian `busybox-static` 换成官方 `busybox:1.37.0-musl`,并新增构建期检查脚本,若 busybox 启了 `CONFIG_FEATURE_PREFER_APPLETS=y` 直接 fail build——因为那会让 `chroot <host> modprobe` 跑成 busybox applet、吞掉 softdeps 导致内核模块加载失败(关联 k8s-driver-manager#299,直接影响 L1 驱动容器化)。
- mig-parted 仅 Go 1.27.2→1.27.3 + distroless base bump,无功能改动;gpu-operator/device-plugin/DRA/dcgm 等 6 仓相对 10-28 锚点无新提交或仅 bump。无 CRD `_types.go` 字段增删、无弃用、无版本跨档。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力] CDI 公共 edits 新增 `void` 哨兵 mount(/dev/null → /var/run/nvidia-container-devices/void),与既有 `NVIDIA_VISIBLE_DEVICES=void` env 对齐,两套设备发现路径都能"声明无设备"以防运行时重复注入。证据 pkg/nvcdi/wrapper.go / internal/config/image/cuda_image.go。 https://github.com/NVIDIA/nvidia-container-toolkit/compare/03a06084d10d73a8943990ba7c32e4af7f70696e...3f548afafd3912edf1dfd6c6f1f84d7e1568cee1
- kai-scheduler/KAI-Scheduler [新能力] NUMA 插件新增内存组(memory-group)账本并接管 NumaPlacementFn,从"仅设备/CPU NUMA 对齐"扩到"按 NUMA mask 做内存容量与冲突校验的内存感知调度"。证据 pkg/scheduler/api/node_info/memory_groups.go + pkg/scheduler/plugins/numa/memory_{allocation,seed}.go。 https://github.com/kai-scheduler/KAI-Scheduler/compare/374cbb796ecff07c4a9140e59286f3e3a280e84b...0243c4e948b722893897cfd72e7f15cb8e371725

## NVIDIA/nvidia-container-toolkit: 03a06084 -> 3f548afa
- 比较: 03a06084d10d73a8943990ba7c32e4af7f70696e -> 3f548afa | ahead=16 | files=147 | Release: v1.20.1
- 比较链接 https://github.com/NVIDIA/nvidia-container-toolkit/compare/03a06084d10d73a8943990ba7c32e4af7f70696e...3f548afafd3912edf1dfd6c6f1f84d7e1568cee1

### AI 总结重点(源码 diff 为据)
- **`void` 从单一 env 升级为"双通道哨兵":CDI 公共 edits 现在同时注入 env 和一个 mount 设备**。`wrapper.GetCommonEdits()` 在原有 `NVIDIA_VISIBLE_DEVICES=void` env 之外,再 append 一个 `/dev/null → <DeviceListAsVolumeMountsRoot>/void`(ro/nosuid/nodev/bind)的 mount。注释点明动机:当启用了 `volume-mounts` 设备策略时,防止 NVIDIA Container Runtime 在 CDI 已注入设备后再重复注入一遍。
  <details><summary>代码依据 pkg/nvcdi/wrapper.go(+11/-0)</summary>

  ```diff
  +	// Configure NVIDIA_VISIBLE_DEVICES=void to prevent duplicate device
  +	// injection from NVIDIA Container Runtime.
   	edits.Env = append(edits.Env, image.EnvVarNvidiaVisibleDevices+"=void")
  +	// Configure a void volume mount device to prevent duplicate device
  +	// injection from NVIDIA Container Runtime when the 'volume-mounts'
  +	// device strategy is enabled.
  +	edits.Mounts = append(edits.Mounts, &specs.Mount{
  +		HostPath:      "/dev/null",
  +		ContainerPath: filepath.Join(image.DeviceListAsVolumeMountsRoot, "void"),
  +		Options:       []string{"ro", "nosuid", "nodev", "bind"},
  +	})
  ```
  </details>
- **消费侧对称:`void` mount 被识别为"无设备"哨兵**。`cuda_image.go` 新增常量 `volumeMountDeviceVoid = "void"`,`visibleDevicesFromMounts()` 在遍历 mount 请求时,一旦遇到 `void` 立即 `return nil`——即 mount 通道里出现 void 等价于"本容器不请求任何设备",与 env 通道 `NVIDIA_VISIBLE_DEVICES=void` 语义一致。
  <details><summary>代码依据 internal/config/image/cuda_image.go(+5/-0)</summary>

  ```diff
  +	volumeMountDeviceVoid = "void"
  ...
  // visibleDevicesFromMounts returns the set of visible devices requested as mounts.
  +// If the void device is requested, no devices are returned.
   func (i CUDA) visibleDevicesFromMounts() []string {
   	var devices []string
   	for _, device := range i.requestsFromMounts() {
   		switch {
  +		case device == volumeMountDeviceVoid:
  +			return nil
   		case strings.HasPrefix(device, volumeMountDevicePrefixImex):
  ```
  </details>
- **构建侧:busybox 来源从 debian `busybox-static` 换成官方 `busybox:1.37.0-musl`,并加构建期 applet 检查闸门**。Dockerfile `shell` stage 改基镜像;新增 `scripts/check-busybox-prefer-applets.sh`,在镜像构建里跑:往 PATH 前插一个 fake `modprobe`,若 `busybox chroot / modprobe` 没执行 fake 而是跑了 busybox 内建 applet,则判定该 busybox 带 `CONFIG_FEATURE_PREFER_APPLETS=y` 并 `exit 1` fail build。注释说明其危害:`chroot <hostRoot> modprobe` 跑成 applet 会无视 softdeps,破坏依赖 softdeps 的内核模块加载(关联 k8s-driver-manager#299)。同时 distroless go base `v4.1.7 → v4.1.8`。
  <details><summary>代码依据 deployments/container/Dockerfile(+11/-7) 与新增脚本</summary>

  ```diff
  -FROM debian:trixie-slim AS shell
  -RUN apt-get update \
  - && apt-get install -y --no-install-recommends busybox-static \
  - && rm -rf /var/lib/apt/lists/* \
  - && mkdir /busybox \
  +FROM busybox:1.37.0-musl AS shell
  +RUN mkdir /busybox \
    && cp /bin/busybox /busybox/busybox \
    && /busybox/busybox --install -s /busybox
  +COPY scripts/check-busybox-prefer-applets.sh /tmp/check-busybox-prefer-applets.sh
  +RUN /tmp/check-busybox-prefer-applets.sh /busybox/busybox
  ```
  ```sh
  # check-busybox-prefer-applets.sh(节选):fake modprobe 必须被 busybox chroot 执行
  output=$(PATH="$FAKEBIN:$PATH" "$BUSYBOX" chroot / modprobe x 2>&1 | head -n1 || true)
  if [ "$output" != "FAKE-MODPROBE" ]; then
  	echo "$BUSYBOX is built with CONFIG_FEATURE_PREFER_APPLETS=y" >&2
  	exit 1
  fi
  ```
  </details>

### 后续发展方向 [AI]
- `void` 双通道哨兵是为 CDI 与 legacy NVIDIA Container Runtime 并存期做的"去重补丁":当 operator 用 CDI 注入设备、而某些路径仍启用 volume-mounts 策略时,靠 void 显式声明"运行时别再注入"。方向上仍是 CDI 收口、legacy runtime 注入逐步退场,但现阶段两条路要共存。证据只覆盖 wrapper/cuda_image 两处 edits 生成与消费逻辑,未见 operator 侧如何下发该策略。
- busybox applet 闸门把一个运行期才暴露的 driver 模块加载故障前移到镜像构建期拦截——是 L1 驱动容器化可靠性加固,非功能新增。证据只覆盖 Dockerfile + 检查脚本,未见 driver 容器实际 modprobe 调用链。

## kai-scheduler/KAI-Scheduler: 374cbb79 -> 0243c4e9
- 比较: 374cbb796ecff07c4a9140e59286f3e3a280e84b -> 0243c4e9 | ahead=3 | files=31 | Release: v0.16.14
- 比较链接 https://github.com/kai-scheduler/KAI-Scheduler/compare/374cbb796ecff07c4a9140e59286f3e3a280e84b...0243c4e948b722893897cfd72e7f15cb8e371725

### AI 总结重点(源码 diff 为据)
- **核心:NUMA 拓扑新增"内存组账本",NumaPlacementFn 从 `placement` 换成 `evaluate`**。新文件 `node_info/memory_groups.go` 定义 `MemoryGroupState{Known bool; Groups map[NUMAMask]*MemoryGroup}` 与 `MemoryGroup{Owners map[UID]ResourceList}`——即"每个 NUMA mask 上的内存被哪些 owner 占了多少"的账本;`NumaTopology` 结构体新增 `MemoryGroups *MemoryGroupState` 字段并进 `Clone()`;新增 `NumaTopology.MemoryCapacity(mask, name)` 按 mask 内各 zone 的 Allocatable 累加(含溢出保护)。`numa.go` 的 `OnSessionOpen` 加 `seedMemoryGroups(ssn)`,且 `AddNumaPlacementFn` 由 `pp.placement` 改注册 `pp.evaluate`。
  <details><summary>代码依据 node_info/memory_groups.go(新增)+ numa_topology.go(+6/-4)</summary>

  ```diff
  +type MemoryGroupState struct {
  +	Known  bool
  +	Groups map[pod_info.NUMAMask]*MemoryGroup
  +}
  +type MemoryGroup struct {
  +	Owners map[types.UID]v1.ResourceList
  +}
  +func (topo *NumaTopology) MemoryCapacity(mask pod_info.NUMAMask, name v1.ResourceName) int64 { ... }
  ...
   type NumaTopology struct {
  -	Policy    TopologyManagerPolicy
  +	Policy       TopologyManagerPolicy
  +	MemoryGroups *MemoryGroupState
  ```
  </details>
- **分配器:新增 `memorySolver`,按 NUMA mask 做内存容量/冲突校验**。新文件 `memory_allocation.go` 定义 `memorySolver`,`allocateUnit` 对每个 container 的受管内存请求求 `finalMemoryMask` 再 `allocateMemory`;三类错误常量 `errMemoryGroupConflict`(NUMA 内存放置冲突)、`errMemoryGroupCapacity`(NUMA 内存容量不足)、`errMemoryStateUnknown`(节点内存组状态未知)。`MemoryGroupState.Compatible(mask)` 拒绝与已有组相交(Intersects)但不相等的 mask,即保证内存组之间 NUMA 边界不交叉。
  <details><summary>代码依据 memory_allocation.go / memory_groups.go</summary>

  ```diff
  +var errMemoryGroupConflict = errors.New("NUMA memory placement conflict")
  +var errMemoryGroupCapacity = errors.New("Insufficient NUMA memory capacity")
  +var errMemoryStateUnknown = errors.New("node memory group state is unknown")
  +type memorySolver struct { taskUID; topology; resources; groups *node_info.MemoryGroupState; allocations []pod_info.MemoryGroupPlacement; hints }
  ...
  +func (state *MemoryGroupState) Compatible(mask pod_info.NUMAMask) bool {
  +	for existing := range state.Groups {
  +		if existing != mask && existing.Intersects(mask) { return false }
  +	}
  ```
  </details>
- **播种:内存组可来自"观测"或"预测"两源**。`memory_seed.go` 的 `resolveMemoryGroups` 先看 pod 注解 `NumaMemoryGroupsObserved`(kubelet 实际放置,解析不完整则判 Unknown),否则回退到 `BindRequest.Spec.PredictedNUMAMemoryGroups`(调度器预测);对应三态 `memoryGroupsUnknown/Predicted/Observed`。消费的是 API 类型 `schedulingv1alpha2.NUMAMemoryGroupPlacement`——内存感知放置已进 kai-scheduler 的 scheduling v1alpha2 API 面。
  <details><summary>代码依据 memory_seed.go(新增)</summary>

  ```diff
  +func resolveMemoryGroups(ssn *framework.Session, pod *v1.Pod) ([]schedulingv1alpha2.NUMAMemoryGroupPlacement, memoryGroupSource) {
  +	if raw, exists := pod.Annotations[commonconstants.NumaMemoryGroupsObserved]; exists { ... return groups, memoryGroupsObserved }
  +	if request := ssn.ClusterInfo.BindRequests.GetBindRequestForPod(pod); request != nil &&
  +		request.BindRequest.Spec.PredictedNUMAMemoryGroups != nil {
  +		return request.BindRequest.Spec.PredictedNUMAMemoryGroups, memoryGroupsPredicted
  ```
  </details>
- **请求模型重构:`podNumaRequests` 从 podScope/concurrent/serial 三组向量,简化为 `podScope + units []admissionUnit`,并把内存从 pod 级向量里剥离单独处理**。`buildNumaRequests` 现在先从 `podReq` 删掉所有内存类资源(`IsMemoryResource`),把内存按 `longRunningContainers` 累加,其余走 `admissionUnits`——即 CPU/设备仍走原对齐单元,内存改由 memorySolver 独立结算。配套把 `hasModeledNodes` 更名 `hasScoredNodes`。
  <details><summary>代码依据 requests.go(+65/-34)</summary>

  ```diff
  -type podNumaRequests struct {
  -	podScope   []resource_info.ResourceVector
  -	concurrent []resource_info.ResourceVector
  -	serial     []resource_info.ResourceVector
  +type admissionUnit struct { container *v1.Container; request resource_info.ResourceVector; ordinaryInit bool }
  +type podNumaRequests struct { podScope resource_info.ResourceVector; units []admissionUnit }
  ...
  +	for name := range podReq { if commonresources.IsMemoryResource(name) { delete(podReq, name) } }
  ```
  </details>

### 后续发展方向 [AI]
- KAI 的 NUMA 调度正从"设备/CPU 对齐"走向**完整内存感知**:不仅算内存够不够(MemoryCapacity),还跨 pod 维护 NUMA mask 级的内存归属账本并拒绝交叉放置。配合 observed/predicted 双源播种,路线是"调度器预测放置 → kubelet 实际放置回填校正",意在让大内存/多 NUMA 节点上的 Guaranteed 负载获得确定性的 NUMA 内存局部性。证据覆盖 memory_groups/allocation/seed + numa.go 接线,未展开 evaluator.go 里 mask 求解与 scoring 如何消费这些组(evaluator 大幅重写 +212/-232,hunk 截断未全读)。
- 内存放置已进 `scheduling/v1alpha2` API(`NUMAMemoryGroupPlacement`、`BindRequest.Spec.PredictedNUMAMemoryGroups`),属 CRD/API 面扩张但本次 diff 未命中 `*_types.go` 本体(引用在 scheduler 侧),需后续在 kai-scheduler/api 仓确认字段定义。

## 本期无实质改动(折叠)
<details><summary>仅 bump / 无新提交的仓</summary>

- NVIDIA/mig-parted:仅 Go 1.27.2→1.27.3 + distroless base v4.1.6→v4.1.8,无功能改动。
- NVIDIA/gpu-operator:相对 10-28 锚点无新提交(Release v26.7.2)。
- NVIDIA/gpu-driver-container:无新提交。
- NVIDIA/k8s-device-plugin:ahead=2 仅 bump/CI/merge。
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(v0.5.1)。
- NVIDIA/dcgm-exporter:无新提交(4.8.4)。
- NVIDIA/DCGM:无新提交(master)。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ff1e0171b6cea17a04fcd0eab78cdbbad50c64f3 branch=main release=v26.7.2 scanned=2026-10-29 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3f548afafd3912edf1dfd6c6f1f84d7e1568cee1 branch=main release=v1.20.1 scanned=2026-10-29 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f5d915c1324483b8166f6da5f9c40bc8299e8c9f branch=main release=— scanned=2026-10-29 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=e2a65758dcc510af97a526fdad13e830d34300ca branch=main release=v0.20.1 scanned=2026-10-29 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=43ce288759a2748748b5c9cacd7a34a8b4e89648 branch=main release=v0.5.1 scanned=2026-10-29 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-29 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-29 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=912e13f9ff8e31d6a1bf5c66a5c58b343fadf9b8 branch=main release=v0.15.1 scanned=2026-10-29 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=0243c4e948b722893897cfd72e7f15cb8e371725 branch=main release=v0.16.14 scanned=2026-10-29 -->
