# NVIDIA 算力栈 diff 雷达 2026-08-28

## 摘要
- gpu-operator 修 devicePlugin 关闭时的误告警:新增 `DEVICE_PLUGIN_ENABLED` 环境变量贯穿到 node-status-exporter,关闭时把 `gpu_operator_node_device_plugin_devices_total` 置 -1,让 `== 0` 的 PrometheusRule 不再误触发(PR #2238)。
- k8s-device-plugin 给 GFD 的 PCI vendor capability 解析加边界校验,修畸形 config 空间导致的越界读(PR #1928,修 issue #1891)。
- KAI-Scheduler 把 resource-reservation ServiceAccount 补进 OpenShift SCC 白名单(PR #2103);dra-driver-nvidia-gpu 仅补测 + bump k8s 到 1.37.0,无功能改动。

## 当日重要改变
- **NVIDIA/gpu-operator** [新能力/可观测] devicePlugin 显式关闭时不再产生虚假 "GPUOperatorNodeDeploymentFailed" 告警——新增 env 传播 + 指标哨兵值 -1。证据 `cmd/nvidia-validator/metrics.go`、`controllers/object_controls.go`、`assets/state-node-status-exporter/0800_prometheus_rule_openshift.yaml`,提交 https://github.com/NVIDIA/gpu-operator/commit/9b079ef4df6a96bd24a388d27f1ce230db5264ae
- **NVIDIA/k8s-device-plugin** [稳定性] GFD PCI 能力链解析加两处边界检查,防越界 slice。证据 `internal/vgpu/pciutil.go`,提交 https://github.com/NVIDIA/k8s-device-plugin/commit/9abbec8b4a71f93a8ad4d80b8354162132b7f6ee

## NVIDIA/gpu-operator: 7c0baff9 -> 476868ab
- 比较 7c0baff9 -> 476868ab | ahead=4 | files=7 | Release: v26.7.0
### AI 总结重点(源码 diff 为据)
- **新增 `DEVICE_PLUGIN_ENABLED` 环境变量(常量 `DevicePluginEnabledEnvName`),并由 `TransformNodeStatusExporter` 注入 node-status-exporter 容器**:根据 `config.DevicePlugin.IsEnabled()` 写 "true"/"false"。这是把 ClusterPolicy 里 devicePlugin 的开关状态下沉到 exporter 运行时的通道。
  <details><summary>代码依据 controllers/object_controls.go</summary>

  ```diff
  +	// DevicePluginEnabledEnvName indicates whether the device plugin is enabled in the ClusterPolicy
  +	DevicePluginEnabledEnvName = "DEVICE_PLUGIN_ENABLED"
  ...
  +	devicePluginEnabled := "true"
  +	if !config.DevicePlugin.IsEnabled() {
  +		devicePluginEnabled = "false"
  +	}
  +	setContainerEnv(&(obj.Spec.Template.Spec.Containers[0]), DevicePluginEnabledEnvName, devicePluginEnabled)
  ```
  </details>
- **validator 的 metrics loop 据此跳过 device-plugin 校验,并把 deviceCount 置 -1**:此前无条件 `go nm.watchDevicePluginValidation()`,现在当 `DEVICE_PLUGIN_ENABLED=false` 时改为把 gauge 主动设成 -1。原因是 promauto 自动注册的 gauge 默认 0,而告警表达式是 `== 0`,不置 -1 就会误报。
  <details><summary>代码依据 cmd/nvidia-validator/metrics.go</summary>

  ```diff
  -	go nm.watchDevicePluginValidation()
  +	if os.Getenv("DEVICE_PLUGIN_ENABLED") != "false" {
  +		go nm.watchDevicePluginValidation()
  +	} else {
  +		// Set to -1 so the alert (expr: == 0) does not fire.
  +		nm.deviceCount.Set(-1)
  +		log.Info("metrics: DevicePlugin is disabled in ClusterPolicy, skipping device plugin validation")
  +	}
  ```
  </details>
- **配套改 OpenShift PrometheusRule 注释,说明 -1 语义**:告警 `GPUOperatorNodeDeploymentFailed`(`gpu_operator_node_device_plugin_devices_total == 0`, for 30m)现在明确 -1 时不触发。表达式本身未改,靠哨兵值绕过。
  <details><summary>代码依据 assets/state-node-status-exporter/0800_prometheus_rule_openshift.yaml</summary>

  ```diff
  -      # There is no GPU exposed on the node,
  +      # There is no GPU exposed on the node.
  +      # When the device plugin is intentionally disabled in the ClusterPolicy
  +      # (devicePlugin.enabled: false), the metric is set to -1, so this
  +      # alert will not fire in that case.
         expr: |
           gpu_operator_node_device_plugin_devices_total == 0
  ```
  </details>
- 另一提交为 CI 修复(cherrypick.yml 用中间 step 捕获 base ref 以规避 OpenSSF dangerous-workflow 误报),非算力栈功能。
### 后续发展方向 [AI]
- 这是"devicePlugin 可被显式关闭"这一部署形态的收尾补丁:说明官方支持只跑 DRA 或第三方 device-plugin(如 HAMi)、把 NVIDIA 经典 device-plugin 关掉的用法,并把告警噪声消掉。证据只覆盖 exporter/告警侧的 -1 哨兵,未见 device-plugin→DRA 的正式迁移开关或 CRD 字段变化。

## NVIDIA/k8s-device-plugin: ad174fb0 -> d75aac2a
- 比较 ad174fb0 -> d75aac2a | ahead=2 | files=2 | Release: v0.20.0
### AI 总结重点(源码 diff 为据)
- **`PCIDevice.GetVendorSpecificCapability()` 遍历 PCI 能力链时加两处越界防护**:进循环先校验 `pos + PciCapabilityLength + 1` 不超 config 长度,取 vendor-specific 能力体时再校验 `pos + PciCapabilityListID + length` 不超界,越界即 break 返回 nil。修畸形 config(如 length=100 但空间不足)导致的 slice 越界 panic(issue #1891)。这是 GFD(gpu-feature-discovery,已并入本仓)读 vGPU 设备 PCI 空间的路径。
  <details><summary>代码依据 internal/vgpu/pciutil.go</summary>

  ```diff
  +		capHeaderEnd := int(pos) + int(PciCapabilityLength) + 1
  +		if capHeaderEnd > len(d.Config) {
  +			break
  +		}
  ...
  -			capability := d.Config[pos+PciCapabilityListID : pos+PciCapabilityListID+length]
  +			capEnd := int(pos) + int(PciCapabilityListID) + int(length)
  +			if capEnd > len(d.Config) {
  +				break
  +			}
  +			capability := d.Config[pos+PciCapabilityListID : capEnd]
  ```
  </details>
### 后续发展方向 [AI]
- 纯健壮性修复,针对 vGPU 场景下读到不规范 PCI 配置空间的崩溃面。证据仅覆盖 vgpu/pciutil 一处解析,未见 time-slicing/MPS 配置面或 DRA 迁移相关改动。

## kai-scheduler/KAI-Scheduler: 49dd9849 -> a20cb84e
- 比较 49dd9849 -> a20cb84e | ahead=1 | files=2 | Release: v0.14.8
### AI 总结重点(源码 diff 为据)
- **OpenShift SCC 模板补入 resource-reservation ServiceAccount**:此前 SCC 只放行 node-scale-adjuster/crd-manager/topology-migration 等固定 SA,现在按 `global.resourceReservation.namespace`/`.serviceAccount` 值动态加入 users 与 RoleBinding subjects。修 resource-reservation Pod 在 OpenShift 上因缺 SCC 授权起不来的问题(PR #2103)。
  <details><summary>代码依据 deployments/kai-scheduler/templates/rbac/scc.yaml</summary>

  ```diff
   - system:serviceaccount:{{ .Release.Namespace }}:kai-topology-migration
  +- system:serviceaccount:{{ .Values.global.resourceReservation.namespace }}:{{ .Values.global.resourceReservation.serviceAccount }}
  ...
  +  - kind: ServiceAccount
  +    name: {{ .Values.global.resourceReservation.serviceAccount }}
  +    namespace: {{ .Values.global.resourceReservation.namespace }}
  ```
  </details>
### 后续发展方向 [AI]
- 纯 OpenShift 部署适配,延续该仓近期把 resource-reservation 拆成可配 namespace/SA 的方向(resource-reservation 是 KAI 占位 Pod 机制的核心)。证据仅 chart RBAC,无调度逻辑改动。

## dra-driver-nvidia-gpu: 71dd3635 -> ad6e0ec7
- 比较 71dd3635 -> ad6e0ec7 | ahead=6 | files=6 | Release: v0.5.0
### AI 总结重点(源码 diff 为据)
- **本期只有测试与依赖 bump,无功能改动**:新增 `cmd/gpu-kubelet-plugin/mig_test.go`(覆盖 MIG 设备规范名 `MigSpecTuple.ToCanonicalName`/`NewMigSpecTupleFromCanonicalName` 的往返:点号剥除、大写折叠、'+'→'-' 的 RFC1123 处理)与 `nvlib_test.go`(覆盖 NVML-free 的 `prependPathListEnvvar` 路径拼接),另有一条 `build(deps): bump Kubernetes to 1.37.0`。测试暴露的是既有内部约定,非新能力。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/mig_test.go(新增,节选)</summary>

  ```diff
  +		"plus becomes hyphen": {
  +			tuple:       MigSpecTuple{ParentMinor: 3, ProfileID: 19, PlacementStart: 4},
  +			profileName: "1g.5gb+me",
  +			want:        "gpu-3-mig-1g5gb-me-19-4",
  +		},
  ```
  </details>
### 后续发展方向 [AI]
- 仅补测 + 跟进 k8s 1.37.0(DRA resource.k8s.io v1 已 GA,主仓刚 8/26 GA),说明 DRA 驱动在锁定 v1 API 并补齐测试覆盖。证据仅测试文件与 deps bump,未见 DeviceClass/ResourceClaim 处理逻辑变更。

## 本期无实质改动(折叠)
<details><summary>5 个 repo 无实质改动(仅 bump/CI/merge 或无新提交)</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=476868abe0ab2f71c934443e370040c08ad2f880 branch=main release=v26.7.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=b5a4721daa18ec48fb3bcc2c9e04cbd6baff373a branch=main release=v1.20.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-28 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d75aac2a65e366afd31285dc2c6011ef0b9fa39f branch=main release=v0.20.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ad6e0ec73dc5eb2abcdb177a6192a6710f64794a branch=main release=v0.5.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-28 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-28 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=8bac7a587a30504efbce56f0416b0cd9330c618e branch=main release=v0.15.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=a20cb84efddef6cfb62ae5190e8a9bba66fdb6e1 branch=main release=v0.14.8 scanned=2026-08-28 -->
</content>
</invoke>
