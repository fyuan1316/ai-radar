# NVIDIA 算力栈 diff 雷达 2026-07-31

## 摘要
- **dra-driver 落地 consumable-shares:GPU/MIG 在 DRA 上原生可分片共享**。新增 `ConsumableShares` feature gate + `--consumable-shares` 配置(unlimited / memory / 正整数 N 三模式),给设备打 `AllowMultipleAllocations=true` 并对 `memory` 容量挂 `CapacityRequestPolicy`,实现按显存额度/份额的多 claim 共享一张物理或 MIG GPU。这是 NVIDIA DRA 栈把"分数 GPU/软共享"能力直接做进 DRA 分配器的关键一步(此前 KAI 还显式不支持 DRA 节点上的分数 GPU)。
- **gpu-driver-container 新增 Ubuntu 26.04 驱动容器,首次改走包管理安装**:弃 `.run` installer,用 APT `nvidia-driver-pinning-<version>` 锁版本 + 把内核模块包烘焙进镜像内本地 `file:` repo + 启动时 DKMS 现场构建(nvidia-open/cuda-drivers 按 KERNEL_MODULE_TYPE 分流);同期基础镜像从 CUDA 镜像换成上游 Rocky Linux,binfmt QEMU 按发行版分别 pin(26.04 需 v10.1.3)。
- gpu-operator 本期以单元测试加固为主(conditions/info/nodeinfo/nvidiadriver/validator 等新增约 15 个测试文件),唯一行为变更是 OpenShift 告警规则改用原生 `for` 时长替代 `last_success_ts` 时间戳比较;KAI-Scheduler 仅一处 pod-affinity pre-score 分配优化(perf);container-toolkit / k8s-device-plugin / dcgm-exporter / DCGM / mig-parted 五仓无实质改动。

## 当日重要改变
- **kubernetes-sigs/dra-driver-nvidia-gpu** [新能力] `ConsumableShares` feature gate + `--consumable-shares` 配置落地,GPU/MIG 设备通过 `AllowMultipleAllocations=true` 与 `memory`/`shares` 的 `CapacityRequestPolicy` 支持多 claim 按量共享(unlimited/memory/N 三模式);Unprepare 侧新增"设备仍被其他 claim 占用则不重新广告 sibling VFIO 设备"的共享生命周期保护。`cmd/gpu-kubelet-plugin/consumable_shares.go`、`device_state.go` https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/75a2d69f43bd
- **NVIDIA/gpu-driver-container** [架构方向/新能力] 新增 Ubuntu 26.04 驱动容器,passthrough 类型从 `.run` installer 改为**包管理安装**(APT 固定版本 + 本地 file: repo 烘焙内核模块 + 启动时 DKMS 构建),并把基础镜像从 CUDA 镜像切到上游 Rocky Linux。`ubuntu26.04/{nvidia-driver,install.sh,Dockerfile}` https://github.com/NVIDIA/gpu-driver-container/commit/0c547950e606

## kubernetes-sigs/dra-driver-nvidia-gpu: 48760d6e -> 6515fed7
- 比较: 48760d6e9c39ecf97d130bdf1dcfe8f983f2d386 -> 6515fed7 | ahead=19 | files=36 | Release: v0.4.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/48760d6e9c39ecf97d130bdf1dcfe8f983f2d386...6515fed70bb2ff3cdb94a6e77d417976a3dbd09f

### AI 总结重点(源码 diff 为据)
- **consumable-shares:把"一张 GPU 被多个 claim 按量共享"做成 DRA 原生能力**。`applyConsumableShares` 给设备置 `AllowMultipleAllocations=true`,把 `memory` 容量按 1Mi 对齐后挂上 `CapacityRequestPolicy`,并按 `--consumable-shares` 取值切三种语义:`unlimited`(memory 请求 default=0/min=0/max=全显存/step=1Mi,不写显存请求即占 0 额度→无限并存);`memory`(default=全显存,claim 不显式声明就吃满整卡,声明分数则按量占用);正整数 `N`(memory 同 unlimited,另加一个 `shares` 容量项 value=N、请求 default=1/min=1/max=N/step=1,最多 N 个 claim 各占 1 份)。开关由 `ConsumableShares` feature gate 与非空非 `disabled` 的 flag 双重把关。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/consumable_shares.go</summary>

  ```diff
  +func isConsumableSharesEnabled(config *Config) bool {
  +	if !featuregates.Enabled(featuregates.ConsumableShares) { return false }
  +	if config == nil || config.flags == nil { return false }
  +	sharesOption := strings.TrimSpace(config.flags.consumableShares)
  +	return sharesOption != "" && sharesOption != "disabled"
  +}
  +func applyConsumableShares(dev *resourceapi.Device, config *Config) {
  +	...
  +	dev.AllowMultipleAllocations = new(true)
  +	// memory 容量按 1Mi 向下对齐,过 APIServer 校验
  +	maxBytes := (memCap.Value.Value() / stepBytes) * stepBytes
  +	switch sharesOption {
  +	case "unlimited":
  +		memCap.RequestPolicy = &resourceapi.CapacityRequestPolicy{
  +			Default: new(zero.DeepCopy()),  // 默认占 0 → 无限并存
  +			ValidRange: &resourceapi.CapacityRequestPolicyRange{Min: ..0, Max: ..maxMem, Step: ..1Mi},
  ```
  </details>
- **配套改共享生命周期:Unprepare 时若被释放的共享 GPU/MIG 仍被其他活跃 claim 占用,就不重新广告其 sibling VFIO 设备**(否则会把还在用的卡错误地重新放出)。`DeviceState.Unprepare` 全程传入 `checkpoint`,用 `isGpuUUIDInUseByOtherClaims` / `isMigDeviceInUseByOtherClaims` 判定占用;`deactivateFabricPartition` 签名也加上 `claimUID`+`checkpoint`。`DeviceConfigState` 另加 `MpsApplied *bool`、`MpsControlDaemonID` 转 `omitempty`。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  +			if isConsumableSharesEnabled(s.config) {
  +				var inUse bool
  +				if allocatableDevice.Type() == GpuDeviceType && allocatableDevice.Gpu != nil {
  +					inUse = isGpuUUIDInUseByOtherClaims(checkpoint, claimUID, allocatableDevice.Gpu.UUID)
  +				} else if allocatableDevice.IsStaticOrDynMigDevice() {
  +					inUse = isMigDeviceInUseByOtherClaims(checkpoint, claimUID, migUUID, device.DeviceName)
  +				}
  +				if inUse { // 仍被别的 claim 占用,跳过 sibling 重发现
  +					continue
  +				}
  +			}
  -		if err := s.deactivateFabricPartition(&pc); err != nil {
  +		if err := s.deactivateFabricPartition(claimUID, &pc, checkpoint); err != nil {
  ```
  </details>
- **文档侧补齐 MPS 与 NVML 健康检查两条能力线并明确互斥约束**:新增 `docs/guides/mps.md`(`MPSSupport` gate,Alpha 默认关,与 `DynamicMIG`/`NVMLDeviceHealthCheck` 互斥;把整卡 compute mode 设 `EXCLUSIVE_PROCESS`、每 claim 起一个 `mps-control-daemon-<id>` Deployment)与 `gpu-health-checking.md`(`NVMLDeviceHealthCheck` 用 NVML event monitor 给不健康设备在 ResourceSlice 上打 device taint:XID 致命/非致命、gpu-lost、unmonitored,只用 `None`/`NoSchedule`、从不 `NoExecute` 驱逐)。"Remove xids, use mutually exclusive" 提交把 gate 间约束收敛为互斥列表。
  <details><summary>代码依据 site/content/docs/guides/gpu-health-checking.md</summary>

  ```diff
  +| XID error (fatal)     | gpu.nvidia.com/xid         | NoSchedule | 关键 GPU 硬件/固件错误 |
  +| XID error (non-fatal) | gpu.nvidia.com/xid         | None       | 应用级错误,不代表硬件退化 |
  +| GPU lost              | gpu.nvidia.com/gpu-lost    | NoSchedule | GPU 对驱动不可访问 |
  +| Unmonitored           | gpu.nvidia.com/unmonitored | None       | NVML 无法监控该设备 |
  ```
  </details>

### 后续发展方向 [AI]
- consumable-shares 让 NVIDIA DRA 栈第一次原生具备"分数/共享 GPU"能力,补上了 device-plugin 时代 time-slicing/MPS 在 DRA 下缺失的软共享路径——且是靠上游 `AllowMultipleAllocations`+`CapacityRequestPolicy` 这套 K8s 1.34+ DRA 共享原语实现,不是自研切分。方向清楚:显存按量(memory 模式)与份额计数(N 模式)双轨,配合 MPS(并发)与 time-slicing(轮转)形成完整共享矩阵。证据覆盖 advertise 侧(consumable_shares.go)与 unprepare 生命周期,未展开 prepare 侧对共享 claim 的实际 CDI/额度绑定(device_state.go 的 prepareDevices 改动 hunk 被截断,+307/-99 未全见)。

## NVIDIA/gpu-driver-container: 661378a6 -> c08f0e54
- 比较: 661378a6e44b41ef4557da54ed96fb3ab9c89851 -> c08f0e54 | ahead=19 | files=18 | Release: —
- https://github.com/NVIDIA/gpu-driver-container/compare/661378a6e44b41ef4557da54ed96fb3ab9c89851...c08f0e543625568736a3531c207cceed44b5f2c5

### AI 总结重点(源码 diff 为据)
- **Ubuntu 26.04 驱动容器改用包管理安装,弃 `.run` installer**(passthrough/baremetal 类型)。构建期:`nvidia-driver-pinning-<version>` 把整棵驱动树钉到 `DRIVER_VERSION`,预装完整驱动 userspace(`nvidia-headless-no-dkms-open` + gl/decode/encode/fbc1 等),把内核模块包烘焙进镜像内本地 `file:` APT repo 后**移除 CUDA 网络 repo**;启动期只需联网装运行内核的 headers,再从本地 repo 装驱动 metapackage(`open`/`auto` → `nvidia-open`,`proprietary` → `cuda-drivers`)由 DKMS 现场编译内核模块。附带装 fabricmanager/nscq/imex/nvlsm/infiniband-diags 等 extra 包。
  <details><summary>代码依据 ubuntu26.04/install.sh</summary>

  ```diff
  +pin_driver_version() {
  +    apt-get install -y --no-install-recommends nvidia-driver-pinning-${DRIVER_VERSION}
  +}
  +userspace_install() {   # 预装 userspace,不含 dkms 内核模块(启动时才装)
  +    apt-get install -y --no-install-recommends \
  +        nvidia-headless-no-dkms-open libnvidia-gl libnvidia-decode \
  +        libnvidia-encode libnvidia-fbc1 libnvidia-extra dkms zstd
  +}
  ```
  </details>
- **基础镜像换血 + QEMU 按发行版 pin**。"Use upstream Rocky Linux base images instead of CUDA images":renovate 新增 `rockylinux/rockylinux` 数据源(8/9/10 各限 `-ubi` 版本),RHEL8/9/10 与 vgpu-manager 的 Dockerfile 从 CUDA 镜像切上游 Rocky。binfmt 因 26.04 arm64 userland 需更新 emulator——v6.2.0 会 hang、v8.1.5 报 ENOSYS、v9.2.2 报 EINVAL——故 CI 里 26.04 单独 pin `tonistiigi/binfmt:qemu-v10.1.3`,其余仍 v6.2.0。
  <details><summary>代码依据 .github/workflows/image.yaml</summary>

  ```diff
  -          image: tonistiigi/binfmt:qemu-v6.2.0
  +          # Ubuntu 26.04 arm64 userland 需更新 emulator,26.04 单独 pin v10.1.3
  +          image: tonistiigi/binfmt:${{ matrix.dist == 'ubuntu26.04' && 'qemu-v10.1.3' || 'qemu-v6.2.0' }}
  ```
  </details>

### 后续发展方向 [AI]
- 从 `.run` 到 APT 包 + 本地 repo + 启动期 DKMS,是 NVIDIA 驱动容器化在新 OS(Ubuntu 26.04)上的安装范式转向:把"版本锁定/userspace 预置"提前到构建期、把"内核模块编译"留到启动期匹配运行内核,减少对 `.run` 二进制与网络的运行时依赖。方向是 26.04 起以包管理为主路径(目前仅 595.71.05 单驱动版本进 26.04 矩阵)。证据覆盖 install.sh/Dockerfile/CI 矩阵,未见 nvidia-driver 主脚本(937 行)里 vgpu 类型仍走 `.run` 的完整分支逻辑(hunk 截断)。

## NVIDIA/gpu-operator: 8ea22988 -> 9c0e9176
- 比较: 8ea2298899680793312bd95bd9a4351fa1df8206 -> 9c0e9176 | ahead=11 | files=23 | Release: v26.3.3
- https://github.com/NVIDIA/gpu-operator/compare/8ea2298899680793312bd95bd9a4351fa1df8206...9c0e917675f29f2a67995eec19d82a3c25844156

### AI 总结重点(源码 diff 为据)
- **本期基本是测试加固,无 API/CRD/控制器逻辑改动**:新增约 15 个 `_test.go`(internal 的 conditions/info/nodeinfo/nvidiadriver/utils/validator + cmd/gpuop-cfg 各 validator),覆盖 condition set、版本拼装、NVIDIADriver AssignOwners/Validate 的错误路径等。唯一非测试行为变更是 OpenShift 告警规则:把"用 `time() - gpu_operator_reconciliation_last_success_ts_seconds > 3600` 手算陈旧度"改为原生 Prometheus `for: 1h`(第二条 NFD 相关告警同理改 `for: 30m`),语义从"最近成功时间戳超阈值"转为"失败状态持续满时长才告警",并删掉对 `last_success_ts` 指标的依赖。
  <details><summary>代码依据 assets/state-operator-metrics/0400_prometheus_rule_openshift.yaml</summary>

  ```diff
  -      expr: |
  -        gpu_operator_reconciliation_status != 1
  -        AND
  -        (time() - gpu_operator_reconciliation_last_success_ts_seconds > 3600)
  +      expr: gpu_operator_reconciliation_status != 1
  +      for: 1h
  ```
  </details>

### 后续发展方向 [AI]
- 无功能方向信号;这批是 v26.3.x 稳定线的测试覆盖率补齐 + 告警规则清理。证据覆盖告警 YAML 与测试文件清单,新增测试均针对既有代码路径,不引入新能力。

## KAI-Scheduler: c0d44f20 -> b8730e34
- 比较: c0d44f203bb2b0744224f3bdc2f35a4b50d4e3b1 -> b8730e34 | ahead=2 | files=7 | Release: v0.16.8
- https://github.com/kai-scheduler/KAI-Scheduler/compare/c0d44f203bb2b0744224f3bdc2f35a4b50d4e3b1...b8730e3499435a046ae9ddf879dd46131cd1aaed

### AI 总结重点(源码 diff 为据)
- **单点性能优化:pod-affinity 预打分去掉无谓的 NodeInfo 分配**(#1983)。`nodePreOrderFn` 原来为每个 fitting node 构造一个空 `k8sframework.NodeInfo` 切片再传给 `PrePodAffinity`;现在直接传 `nil`,省掉每次调度周期按候选节点数的切片分配与 GC 压力。纯性能改动,打分结果不变;配套加了 anti-affinity 的基准与单测(`AntiAffinity100Node`)。
  <details><summary>代码依据 pkg/scheduler/plugins/podaffinity/podaffinity.go</summary>

  ```diff
  -	return func(task *pod_info.PodInfo, fittingNodes []*node_info.NodeInfo) error {
  -		var nodes []ksf.NodeInfo
  -		for range fittingNodes {
  -			nodes = append(nodes, &k8sframework.NodeInfo{})
  -		}
  -		status := k8sPlugins.PrePodAffinity(task.Pod, nodes)
  +	return func(task *pod_info.PodInfo, _ []*node_info.NodeInfo) error {
  +		status := k8sPlugins.PrePodAffinity(task.Pod, nil)
  ```
  </details>

### 后续发展方向 [AI]
- 无架构/能力方向,属大集群调度热点路径的分配优化。证据仅覆盖 podaffinity 插件一处,不涉及 DRA/资源模型。

## 本期无实质改动(折叠)
<details>
- NVIDIA/nvidia-container-toolkit:无新提交
- NVIDIA/k8s-device-plugin:无新提交
- NVIDIA/dcgm-exporter:无新提交
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:仅 bump/CI/merge(ahead=2/files=1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9c0e917675f29f2a67995eec19d82a3c25844156 branch=main release=v26.3.3 scanned=2026-07-31 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1151f013074712dc6dabd00752b6b57d6637fdeb branch=main release=v1.20.0-rc.1 scanned=2026-07-31 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=c08f0e543625568736a3531c207cceed44b5f2c5 branch=main release=— scanned=2026-07-31 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5f27eeeee7eb7f7a4c0581aa10abeda7e4604ed2 branch=main release=v0.19.3 scanned=2026-07-31 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=6515fed70bb2ff3cdb94a6e77d417976a3dbd09f branch=main release=v0.4.1 scanned=2026-07-31 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-31 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-31 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=589c033a8ef273613111245da67e1c6a0f78931b branch=main release=v0.14.4 scanned=2026-07-31 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b8730e3499435a046ae9ddf879dd46131cd1aaed branch=main release=v0.16.8 scanned=2026-07-31 -->
