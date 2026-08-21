# NVIDIA 算力栈 diff 雷达 2026-08-21

## 摘要
- **dra-driver-nvidia-gpu 解锁 Dynamic MIG 设备的 NVML 健康监控**:删掉了 `DynamicMIG` 与 `NVMLDeviceHealthCheck` 两个 feature gate 的互斥校验,配套把 `DeviceState.Unprepare` 改为返回 `taintRemoved bool` —— 动态 MIG 设备 unprepare 时若清除了 XID taint 会触发 ResourceSlice 重发。此前动态 MIG 与设备健康检查不能同开,本窗口打通。
- **同仓重构 NVML 健康事件注册时序,修 plugin 重启丢 XID 竞态**:健康监控从「按 parent-UUID→GI→CI 三元组索引」改为「按 PCI Bus ID 遍历 `perGPUAllocatable`」,并把 `Start()` 拆成 `RegisterEvents()`+`Start()`,在 kubelet server 暴露 Prepare/Unprepare **之前**先注册 NVML 事件(NVML 不保留注册前发生的事件,重启窗口内的 XID 会丢)。代码里留 TODO 明说 taint 未持久化、重启后故障设备可能被误报健康。
- **gpu-operator 进入 v26.7.0 发版工程**:`olm.skipRange`/CSV name/channel 全部从 26.3.3 跳到 **26.7.0**,一并把 device-plugin v0.20.0、mig-manager v0.15.0、driver-manager v0.12.0、dra-driver v0.5.0、vgpu-device-manager v0.5.0、kubevirt/sandbox/cc-manager 等随附镜像整体滚前;DRA driver 镜像源从 `registry.k8s.io/dra-driver-nvidia` 迁到 **`nvcr.io/nvidia`(NGC)**;dcgm 从 4.6.1 **回退**到 4.6.0。无 ClusterPolicy CRD 字段增删。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [新能力·feature gate] 删除 `DynamicMIG × NVMLDeviceHealthCheck` 互斥校验,并让 `Unprepare` 返回 taintRemoved 触发 ResourceSlice 重发 —— 动态 MIG 设备现可纳入 NVML 健康监控/打 taint。证据 pkg/featuregates/featuregates.go、cmd/gpu-kubelet-plugin/device_state.go。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/4400a6d5eb6abfcfd00efed51b275ff8b059511b...d682267c7dd84a76c61663feeaf36d04ac6ebfef
- kubernetes-sigs/dra-driver-nvidia-gpu [架构方向] NVML 健康事件注册重排:`Start()` 拆为 `RegisterEvents()`+`Start()`,在 kubelet 暴露 Prepare/Unprepare 前先注册,修 plugin 重启期 XID 丢失竞态;健康路由由 UUID 三元组改为按 PCI Bus ID 遍历既有 GPU 清单。证据 cmd/gpu-kubelet-plugin/driver.go、device_health.go。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/4400a6d5eb6abfcfd00efed51b275ff8b059511b...d682267c7dd84a76c61663feeaf36d04ac6ebfef
- NVIDIA/gpu-operator [版本跨档] 下一发版从 v26.3.3 跨到 v26.7.0(olm.skipRange `<26.3.3`→`<26.7.0`、channel v26.3→v26.7),随附组件镜像整体滚前(device-plugin v0.20.0/mig-manager v0.15.0/driver-manager v0.12.0/dra-driver v0.5.0/vgpu-device-manager v0.5.0)。证据 bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml、deployments/gpu-operator/values.yaml。https://github.com/NVIDIA/gpu-operator/compare/7ab78b49190ffaac5af656d911fb8e80e68cea15...10ee5b3638b89e11e949412aafa5ba99279c3721
- NVIDIA/gpu-operator [分发变更] DRA driver 镜像源从 `registry.k8s.io/dra-driver-nvidia` 改为 `nvcr.io/nvidia`(NGC),tag v0.4.1→v0.5.0;dcgm 随附镜像从 4.6.1-1 回退到 4.6.0-1(Revert)。证据 bundle CSV relatedImages、values.yaml。https://github.com/NVIDIA/gpu-operator/compare/7ab78b49190ffaac5af656d911fb8e80e68cea15...10ee5b3638b89e11e949412aafa5ba99279c3721

## kubernetes-sigs/dra-driver-nvidia-gpu: 4400a6d5 -> d682267c
- 比较: 4400a6d5 -> d682267c | ahead=5 | files=11 | Release: v0.5.0(VERSION 已进 0.6.0-dev)
- 比较页: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/4400a6d5eb6abfcfd00efed51b275ff8b059511b...d682267c7dd84a76c61663feeaf36d04ac6ebfef

### AI 总结重点(源码 diff 为据)
- **解锁 Dynamic MIG × 设备健康检查同开(能力边界扩张)**。`ValidateFeatureGates` 删掉了 `DynamicMIG` 与 `NVMLDeviceHealthCheck` 的互斥断言,两个 gate 现可同时启用;仓内动态 MIG 设备第一次能被 NVML 健康监控覆盖。这是本窗口最实质的能力变化——之前互斥意味着用动态 MIG 就没有 XID/ECC 健康上报。
  <details><summary>代码依据 pkg/featuregates/featuregates.go</summary>

  ```diff
  -	if Enabled(DynamicMIG) && Enabled(NVMLDeviceHealthCheck) {
  -		return fmt.Errorf("feature gate %s is currently mutually exclusive with %s", DynamicMIG, NVMLDeviceHealthCheck)
  -	}
  -
   	if Enabled(DynamicMIG) && Enabled(MPSSupport) {
   		return fmt.Errorf("feature gate %s is currently mutually exclusive with %s", DynamicMIG, MPSSupport)
   	}
  ```
  </details>

- **`Unprepare` 改签名返回 `taintRemoved bool`,驱动 ResourceSlice 重发**。原 `Unprepare(ctx, claimRef) error` 改为 `(bool, error)`;当 unprepare 清掉某动态 MIG 设备上的 XID taint 时返回 true,调用方据此重新发布 ResourceSlice(把恢复健康的设备重新放出)。`unprepareDevices` 也相应改为返回 taintRemoved。这是让动态 MIG 的健康态变化真正反映到可调度资源面。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  -func (s *DeviceState) Unprepare(ctx context.Context, claimRef kubeletplugin.NamespacedObject) error {
  +// Unprepare returns true when cleanup removes a Dynamic MIG XID taint and the
  +// caller must republish the ResourceSlice.
  +func (s *DeviceState) Unprepare(ctx context.Context, claimRef kubeletplugin.NamespacedObject) (bool, error) {
   ...
  -	case ClaimCheckpointStatePrepareCompleted:
  -		if err := s.unprepareDevices(ctx, claimUID, pc.PreparedDevices, checkpoint); err != nil {
  -			return fmt.Errorf("unprepare devices failed for claim %s: %w", claimRef.String(), err)
  +	case ClaimCheckpointStatePrepareCompleted:
  +		taintRemoved, err = s.unprepareDevices(ctx, claimUID, pc.PreparedDevices, checkpoint)
  +		if err != nil {
  +			return false, fmt.Errorf("unprepare devices failed for claim %s: %w", claimRef.String(), err)
   		}
  ...
  -	return nil
  +	return taintRemoved, nil
  ```
  </details>

- **NVML 事件注册时序重排,修 plugin 重启丢 XID 竞态(正确性)**。`nvmlDeviceHealthMonitor` 的索引从 `deviceByPlacement devicePlacementMap`(parent UUID→GI→CI 三元组)换成 `perGPUAllocatable *PerGPUAllocatableDevices` + `gpuInfosByUUID`;`registerEventsForDevices` 从 `DeviceGetHandleByUUID` 遍历改为按 `allocatablesMap` 的 **PCI Bus ID** 用 `DeviceGetHandleByPciBusId` 取句柄。同时 `Start()` 拆为 `RegisterEvents()`(建 event set、开始录事件)与 `Start()`(起等待循环),`NewDriver` 里把 `RegisterEvents()` 挪到 `kubeletplugin.Start` 暴露 Prepare/Unprepare **之前**。注释点明:重启时已 prepared 的设备可能在 kubelet service 就绪前就发 XID,而 NVML 不保留注册前的事件,故必须先注册。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/driver.go</summary>

  ```diff
  +	// Register NVML events before kubeletplugin.Start exposes Prepare/Unprepare.
  +	// On plugin restart, previously prepared devices and their workloads can remain
  +	// live and emit an XID before the kubelet service is available. NVML does not
  +	// retain events that occur before registration.
  +	if featuregates.Enabled(featuregates.NVMLDeviceHealthCheck) {
  +		deviceHealthMonitor, err := newNvmlDeviceHealthMonitor(config, state.perGPUAllocatable, state.nvdevlib)
  +		...
  +		if err := deviceHealthMonitor.RegisterEvents(); err != nil {
  +			return nil, fmt.Errorf("failed to register NVML device events: %w", err)
  +		}
  +	}
  ```
  </details>
  已知残留(代码内 TODO):NVML 不重放注册前的 XID,且 health taint 未持久化,重启后一个故障设备可能被重新广告为健康,除非故障再次发事件——作者自己标注为待办(持久化健康态或恢复校验)。

- **配套新增设备查找/taint 辅助方法**。`allocatable.go` 给 `GetDevice`/`partitions.go` 的 `PartGetDevice` 统一在返回前挂 `dev.Taints = d.Taints()`(taint 现随设备一并暴露);新增 `RemoveTaint(key)`、`GetGPUDeviceByUUID`、`GetMigStaticDeviceByLiveTuple`、`GetMigDynamicDeviceByTuple` 一组按标识反查 AllocatableDevice 的方法,供健康路由按 live/spec 三元组定位动态 MIG 设备。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/allocatable.go</summary>

  ```diff
  +	dev.Taints = d.Taints()
  +	return dev
   }
  +
  +func (d *AllocatableDevice) RemoveTaint(key string) (resourceapi.DeviceTaint, bool) { ... }
  +func (d AllocatableDevices) GetGPUDeviceByUUID(uuid string) *AllocatableDevice { ... }
  +func (d AllocatableDevices) GetMigStaticDeviceByLiveTuple(tuple *MigLiveTuple) *AllocatableDevice { ... }
  +func (d AllocatableDevices) GetMigDynamicDeviceByTuple(tuple *MigSpecTuple) *AllocatableDevice { ... }
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 featuregates 互斥删除、Unprepare 签名改造、事件注册时序重排、taint 查找辅助四处真实 hunk,未逐行读 device_health_test.go(+216)的全部用例。方向明确:dra-driver 正把「设备健康(XID/ECC)→ DeviceTaint → ResourceSlice 重发」这条链路补齐到**动态 MIG** 粒度,让 DRA 原生路径的故障隔离对齐 full-GPU;下一步值得盯 TODO 里点名的 **健康态持久化/重启恢复校验**是否落地(否则重启误报健康是真实运维坑),以及 VERSION 已进 0.6.0-dev,0.6.0 大概率把该能力从实验推向默认。

## gpu-operator: 7ab78b49 -> 10ee5b36
- 比较: 7ab78b49 -> 10ee5b36 | ahead=28 | files=40 | Release: v26.3.3
- 比较页: https://github.com/NVIDIA/gpu-operator/compare/7ab78b49190ffaac5af656d911fb8e80e68cea15...10ee5b3638b89e11e949412aafa5ba99279c3721

### AI 总结重点(源码 diff 为据)
- **进入 v26.7.0 发版工程,组件镜像整体滚前**。CSV `olm.skipRange` 从 `>=1.9.0 <26.3.3` 抬到 `<26.7.0`、CSV name → `gpu-operator-certified.v26.7.0`、bundle channel `v26.3`→`v26.7`;随附镜像成批前滚:device-plugin/GFD v0.19.3→v0.20.0、mig-manager v0.14.5→v0.15.0、driver-manager(含 vfio/vgpu)v0.11.0→v0.12.0、vgpu-device-manager v0.4.2→v0.5.0、cc-manager v0.4.2→v0.4.3、kubevirt-gpu-device-plugin v1.5.0→v1.6.0、sandbox-device-plugin v0.0.4→v0.0.5。这是一次跨小版本(26.3→26.7)的发版档位跳变,非单点功能。
  <details><summary>代码依据 bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml</summary>

  ```diff
  -    olm.skipRange: '>=1.9.0 <26.3.3'
  +    olm.skipRange: '>=1.9.0 <26.7.0'
  -  name: gpu-operator-certified.v26.3.3
  +  name: gpu-operator-certified.v26.7.0
  ...
  -      image: nvcr.io/nvidia/k8s-device-plugin:v0.19.3@sha256:25cc340f...
  +      image: nvcr.io/nvidia/k8s-device-plugin:v0.20.0@sha256:a61ba9fd...
  -      image: nvcr.io/nvidia/cloud-native/k8s-mig-manager:v0.14.5@...
  +      image: nvcr.io/nvidia/cloud-native/k8s-mig-manager:v0.15.0@...
  ```
  </details>

- **DRA driver 镜像源迁 NGC + dcgm 回退**。DRA driver 从 `registry.k8s.io/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.4.1` 改为 `nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.0`(提交 "use dra driver image from NGC",alm-examples 里 draDriver.repository 也从 `registry.k8s.io/dra-driver-nvidia` → `nvcr.io/nvidia`);dcgm 随附镜像被 Revert 回 4.6.0-1(CSV digest 与 values.yaml `dcgm.version` 4.6.1→4.6.0 同步回退)。前者是发行分发口径统一到 NGC,后者说明 4.6.1 dcgm 在集成侧被撤回。
  <details><summary>代码依据 CSV relatedImages / values.yaml</summary>

  ```diff
  -      image: registry.k8s.io/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.4.1@sha256:eefe6739...
  +      image: nvcr.io/nvidia/dra-driver-nvidia-gpu:v0.5.0@sha256:9b46984c...
  -      image: nvcr.io/nvidia/cloud-native/dcgm:4.6.1-1-ubi10@sha256:039e197a...
  +      image: nvcr.io/nvidia/cloud-native/dcgm:4.6.0-1-ubi10@sha256:92080d86...
  ```
  </details>

- **OpenShift DriverToolkit 告警/指标语义澄清(措辞收敛,非新能力)**。Prometheus rule 与 `operator_metrics.go` 里把 "DriverToolkit is enabled but NFD too old" 一类文案改为 "was requested but could not be enabled because ...",并点明缺的是 NFD 暴露的 **OSTREE labels**;指标 help 文本同步改。语义上从「已启用但…」修正为「请求了但因故未能启用」,更准确描述 -1 状态,不改指标名/取值。
  <details><summary>代码依据 controllers/operator_metrics.go</summary>

  ```diff
  -				Help:      "1 if OCP DriverToolkit is enabled but NFD doesn't expose OSTREE labels, 0 otherwise",
  +				Help:      "1 if OCP DriverToolkit was requested but NFD does not expose the required OSTREE labels, 0 otherwise",
  ```
  </details>

- **构建侧供应链加固(非运行时)**:`docker/Dockerfile` 把 golang/ubi9/debian/distroless 各 base 镜像从浮动 tag 钉到 `@sha256` digest;`Makefile`/`Dockerfile.devel` 删除 `GOLANG_VERSION`/`BUILDER_IMAGE` build-arg,devel 直接钉死 `golang:1.26.6@sha256:...`。探测器报「无 API/CRD 路径命中」,ClusterPolicy/NVIDIADriver `*_types.go` 无字段增删。

### 后续发展方向 [AI]
- 证据覆盖 CSV/values 版本滚前、DRA 镜像迁 NGC、dcgm 回退、告警措辞、Dockerfile 钉 digest 五处 hunk,未见任何 CRD 字段或 driver 矩阵能力改动。本窗口 operator 是纯发版工程(26.3→26.7 档位跳 + 组件整体前滚 + 分发口径统一到 NGC),能力信号在被滚前的子组件里(尤见 dra-driver v0.5.0)。可盯 v26.7.0 正式发版时 ClusterPolicy 是否随子组件新增字段,以及 dcgm 4.6.1 为何回退(集成兼容问题?)。

## 本期无实质改动(折叠)
<details><summary>7 仓无实质代码改动(EMPTY / 仅 CI / 仅 release 打 tag)</summary>

- NVIDIA/nvidia-container-toolkit(ahead=2/files=1,唯一改动是 `.github/scripts/backport.js`:backport 提交经 Git Data API 重建以获得 Verified 签名——纯 CI 供应链工具,无运行时/CDI/hook 改动)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交,HEAD 未变;但 **release 已从 v0.19.3 打到 v0.20.0**——即昨日预备的 0.20.0 已在原 sha 1b826acc 上正式发 tag,无新代码)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交,branch=master)
- NVIDIA/mig-parted(无新提交,HEAD 未变;但 **release 已从 v0.14.5 打到 v0.15.0**——原 sha e2d5ad1f 上打 tag,无新代码)
- kai-scheduler/KAI-Scheduler(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=10ee5b3638b89e11e949412aafa5ba99279c3721 branch=main release=v26.3.3 scanned=2026-08-21 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=357b970814261fb17d9b4991b1d2636bce71d442 branch=main release=v1.20.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-21 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1b826acc6af3079d8923bac395c3124b8861a9a6 branch=main release=v0.20.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d682267c7dd84a76c61663feeaf36d04ac6ebfef branch=main release=v0.5.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-21 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-21 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=e2d5ad1fc72b9d298ea6d04b885cf2d7dbe56941 branch=main release=v0.15.0 scanned=2026-08-21 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2914d320160fbb389f69a2c2968a0a6acefb9f76 branch=main release=v0.14.8 scanned=2026-08-21 -->
</content>
</invoke>
