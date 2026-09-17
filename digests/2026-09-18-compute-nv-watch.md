# NVIDIA 算力栈 diff 雷达 2026-09-18

## 摘要
- **KAI-Scheduler NvFractions 从"注解地基"落到"调度+绑定+计算模式全链路"**:昨天(09-17)只到请求校验/转换,今天 binder 绑定插件(#2042)、scheduler 显存记账(#2041)、admission GPU-sharing 模式(#2043)一并落地;类型层用 `FractionalGpuGroup{ID, ComputeSharingMode}` 取代裸 `GPUGroups []string`,并首次引入 **sm-sharing**(SM 计算切分)与 time-slicing 并列为"计算共享模式";全局新增 `GpuSharingMode` 预设(NonMemoryEnforced/HamiCore/NvFractions/Disabled)统一 admission+binder 默认插件集。GPU 软共享方向从"显存额度"扩到"算力切分",且与 HAMi-core 并列为可选后端。
- **dra-driver-nvidia-gpu 重构 XID 健康判定**:废弃硬编码"非致命 XID 白名单"(13/31/43/45/68/109),改由 NVML 上报的 GPU recovery action 决定是否致命;`additional-xids-to-ignore` flag 从"补充忽略列表"降级为纯管理员覆盖项。NoSchedule 污点改为"粘性",不再被后到的同键事件覆盖,直到显式恢复才摘除。
- 其余:gpu-operator 新增 Cluster Autoscaler scale-from-zero 的 startup-taint 门控示例(NPD 发 `nvidia.com/GPUReady` 条件 + NRC 摘污点,operator 本体不变)+ cc-manager v0.4.3→v0.4.4。container-toolkit/dcgm-exporter/DCGM/mig-parted 无实质改动。

## 当日重要改变
- kai-scheduler [新能力/计算模式] 新增 sm-sharing 计算共享模式与 `FractionalGpuGroup` 类型(`ComputeSharingMode: time-slicing|sm-sharing`),binder 落地绑定、scheduler 落地显存记账、admission 落地 GPU-sharing 模式;PR #2041/#2042/#2043/#2046 https://github.com/kai-scheduler/KAI-Scheduler/pull/2046
- kai-scheduler [API/CRD变更] BindRequest CRD 新增 `selectedFractionalGpuGroups`(带 computeSharingMode 枚举),旧 `selectedGPUGroups` 标记 Deprecated;新增顶层 `GpuSharingMode` 预设枚举收敛 admission+binder 默认插件;PR #2045 https://github.com/kai-scheduler/KAI-Scheduler/pull/2045
- kai-scheduler [健壮性] hamicore 无法算出 GPU 显存 limit 时 binder 改为 fail-closed(拒绝绑定而非放行);PR #2157 https://github.com/kai-scheduler/KAI-Scheduler/pull/2157
- dra-driver-nvidia-gpu [架构方向/行为变更] XID 致命性判定由硬编码白名单改为读 NVML recovery action;NoSchedule 污点变粘性,不再被后续事件覆盖;PR 见 compare https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/5baf08f63bd266129dbdd27b28e77bb0ad91fd28...2b0257ccc35d54968756fb0db10c6740ae923826
- gpu-operator [新能力/示例] 新增 Cluster Autoscaler 集成示例:NPD 发布 `nvidia.com/GPUReady` 节点条件、NRC 据 `NodeReadinessRule` 摘 `readiness.k8s.io/` startup taint,解决 scale-from-zero 下 GPU 未就绪就被调度的窗口(operator 本体不变);compare https://github.com/NVIDIA/gpu-operator/compare/8fe3fd61821ba51f6ddd2e7668388360c9655e2f...93c0ff560ca71e761d6c1782d904765bb88de3db

## kai-scheduler/KAI-Scheduler: e22f6543 -> 716b92d8
- 比较 https://github.com/kai-scheduler/KAI-Scheduler/compare/e22f6543c96a1c3aeabd29c38176c3ada9a21120...716b92d81a5507805fbe6dd0038ca73b5f9c0db3 | ahead=20 | files=190 | Release: v0.17.2
### AI 总结重点(源码 diff 为据)
- **新增 sm-sharing 计算共享模式,GPU 组从字符串升级为带模式的结构体**:`bindrequest_types.go` 新增 `GPUComputeSharingMode` 枚举(`time-slicing`/`sm-sharing`)与 `FractionalGpuGroup{ID, ComputeSharingMode}`;`pod_info.go` 把 `GPUGroups []string` 整体换成 `FractionalGpuGroups []FractionalGpuGroup`,并加 `RequestedGPUComputeSharingMode()`(从 Pod 注解取,缺省 time-slicing)。这是把"分数 GPU"从"只分显存/时分"扩到"可声明 SM 算力切分",且模式随 GPU 组一路带到绑定。
  <details><summary>代码依据 pkg/apis/scheduling/v1alpha2/bindrequest_types.go & pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
  +// +kubebuilder:validation:Enum=time-slicing;sm-sharing
  +type GPUComputeSharingMode string
  +const (
  +	GPUComputeSharingModeTimeSlicing GPUComputeSharingMode = "time-slicing"
  +	GPUComputeSharingModeSMSharing   GPUComputeSharingMode = "sm-sharing"
  +)
  +type FractionalGpuGroup struct {
  +	ID                 string                `json:"id,omitempty"`
  +	ComputeSharingMode GPUComputeSharingMode `json:"computeSharingMode,omitempty"`
  +}
  ```
  ```diff
  -	GPUGroups []string
  +	FractionalGpuGroups []schedulingv1alpha2.FractionalGpuGroup
  ...
  +func (pi *PodInfo) RequestedGPUComputeSharingMode() schedulingv1alpha2.GPUComputeSharingMode {
  +	if pi.Pod == nil { return schedulingv1alpha2.GPUComputeSharingModeTimeSlicing }
  +	_, rawMode, _ := resources.ExtractGpuComputeSharingModeAnnotation(pi.Pod)
  +	return schedulingv1alpha2.DefaultGPUComputeSharingMode(schedulingv1alpha2.GPUComputeSharingMode(rawMode))
  +}
  ```
  </details>
- **调度侧按"计算模式兼容性"约束节点选择**:`gpu_sharing_node_info.go` 新增 `IsGpuGroupComputeSharingModeCompatible()`——同一 GPU 组内已存在的 reservation pod / 现有分数任务的 sharing mode 必须与新任务请求的 mode 一致,否则不可复用该组(缺省 time-slicing)。即 sm-sharing 与 time-slicing 的任务不会被混排进同一物理 GPU 组。
  <details><summary>代码依据 pkg/scheduler/api/node_info/gpu_sharing_node_info.go</summary>

  ```diff
  +func (ni *NodeInfo) IsGpuGroupComputeSharingModeCompatible(gpuGroup string, task *pod_info.PodInfo) bool {
  +	requestedMode := task.RequestedGPUComputeSharingMode()
  +	if mode, found := ni.getReservationPodGpuGroupComputeSharingMode(gpuGroup); found { return mode == requestedMode }
  +	if mode, found := ni.getGpuGroupComputeSharingMode(gpuGroup); found { return mode == requestedMode }
  +	...
  +	return requestedMode == schedulingv1alpha2.GPUComputeSharingModeTimeSlicing
  +}
  ```
  </details>
- **新增顶层 `GpuSharingMode` 预设,统一 admission+binder 的默认插件集**:`common/gpu_sharing_mode.go` 定义四态枚举(NonMemoryEnforced/HamiCore/NvFractions/Disabled);`config_types.go` 的 `resolveGpuSharingMode()` 显式值优先,未设时从 legacy 字段推断(hamicore 插件开=HamiCore、admission.gpuSharing=true→NonMemoryEnforced/false→Disabled),缺省 NonMemoryEnforced——保证老集群升级行为不变。binder 据此模式装配 `gpusharing`/`hamicore`/`nvfractions` 插件三选一。
  <details><summary>代码依据 pkg/apis/kai/v1/common/gpu_sharing_mode.go & config_types.go & binder/binder.go</summary>

  ```diff
  +// +kubebuilder:validation:Enum=NonMemoryEnforced;HamiCore;NvFractions;Disabled
  +type GpuSharingMode string
  +const (
  +	GpuSharingModeNonMemoryEnforced GpuSharingMode = "NonMemoryEnforced" // 默认
  +	GpuSharingModeHamiCore          GpuSharingMode = "HamiCore"          // 叠加 HAMI-core 显存强隔离
  +	GpuSharingModeNvFractions       GpuSharingMode = "NvFractions"       // 专用 nvfractions 插件,不走 shared configmap
  +	GpuSharingModeDisabled          GpuSharingMode = "Disabled"          // 分数请求被 admission 拒绝
  +)
  ```
  ```diff
  +	NvFractionsPluginName      = "nvfractions"
  ...
  +	NvFractionsPluginName:      90,   // 优先级介于 gpusharing(100) 与 hamicore(50) 之间
  -func (b *Binder) setDefaultPlugins() {
  +func (b *Binder) setDefaultPlugins(gpuSharingMode common.GpuSharingMode) {
  +	nvFractionsEnabled := gpuSharingMode == common.GpuSharingModeNvFractions
  ```
  </details>
- **BindRequest CRD 增字段、弃旧字段**:`selectedFractionalGpuGroups`(items 带 computeSharingMode 枚举 + id)进入 CRD,`selectedGPUGroups` 标 Deprecated;`SelectedFractionalGpuGroupsOrDefault()` 做旧→新兼容(旧字段按 time-slicing 补默认)。CRD 加载器新增 `LoadEmbeddedCRDsUnstructured()` 走非类型化路径以便 server-side apply 原样下发。
  <details><summary>代码依据 deployments/kai-scheduler/crds/scheduling.run.ai_bindrequests.yaml</summary>

  ```diff
  +              selectedFractionalGpuGroups:
  +                items:
  +                  properties:
  +                    computeSharingMode:
  +                      enum: [time-slicing, sm-sharing]
  +                      type: string
  +                    id: { type: string }
               selectedGPUGroups:
  +                  Deprecated: Use SelectedFractionalGpuGroups instead
  ```
  </details>
- 另有 binder fail-closed(#2157:hamicore 算不出显存 limit 时拒绝绑定而非放行)、queue quota 校验在 create/update 对齐(#2167)、helm-hooks 换 distroless helm-hooks 二进制并新增 topology migration hook(#2181/#2184)、node-affinity 约束匹配加缓存(perf #2183)。(190 文件区间,以上抓 API/类型/调度核心 hunk,未逐一展开测试与 chart 文件)
### 后续发展方向 [AI]
- sm-sharing 一旦有 binder 侧真正下发(本期 `nv_fractions.go` 绑定插件已建),KAI 的 GPU 软共享将同时覆盖"时分 + SM 算力切分 + 显存额度",与 HAMi-core 从"竞争"转为"可并存的后端选项"(`GpuSharingMode` 里 HamiCore 与 NvFractions 平级)。证据覆盖类型/CRD/config/binder 装配,未见 sm-sharing 在节点上如何落到 CUDA MPS/MIG 的具体机制(需看 gpu-sharing operator 子仓)。
- `GpuSharingMode` 预设从 legacy 字段推断的兼容逻辑说明官方在为"多后端 GPU 共享"做配置面统一;后续可留意 legacy `admission.gpuSharing`/hamicore 插件开关是否进一步废弃。

## kubernetes-sigs/dra-driver-nvidia-gpu: 5baf08f6 -> 2b0257cc
- 比较 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/5baf08f63bd266129dbdd27b28e77bb0ad91fd28...2b0257ccc35d54968756fb0db10c6740ae923826 | ahead=6 | files=5 | Release: v0.5.0
### AI 总结重点(源码 diff 为据)
- **XID 致命性判定从"硬编码白名单"改为"读 NVML 当前 recovery action"**:旧 `xidsToSkip()` 内置一组默认非致命 XID(13/31/43/45/68/109),命中即认为 GPU 仍健康;新版删掉内置分类,改由父 GPU 的 recovery action 决定调度影响,`xidsToSkip(input)` 只解析管理员显式配置的覆盖列表(返回 `map[uint64]bool`)。语义从"这些 XID 一律忽略"变为"默认信任 NVML 判致命性,管理员列表仅作强制放行"。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_health.go</summary>

  ```diff
  -func getAdditionalXids(input string) []uint64 {   // 补充忽略列表,叠加到内置白名单
  +// The built-in list is no longer used for classification. The parent GPU's
  +// current recovery action determines the scheduling impact. This configured
  +// list remains as an explicit administrator override.
  +func xidsToSkip(input string) map[uint64]bool {
  ...
  -	ignoredXids := []uint64{13, 31, 43, ...}   // 内置默认非致命 XID,已删除
  ```
  </details>
- **NoSchedule 污点改为"粘性"**:`AddOrUpdateTaint()` 旧逻辑对同键污点"总以最新事件覆盖 value/effect"(如 XID 48 后收到 XID 63 会被改写);新逻辑遇到已存在的 NoSchedule 污点直接 `return false` 不改,直到显式恢复摘除。避免一次真实致命故障的污点被后续较轻事件冲淡。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/allocatable.go</summary>

  ```diff
  +			// Keep the NoSchedule taint until recovery explicitly removes the taint.
  +			if existing.Effect == resourceapi.DeviceTaintEffectNoSchedule {
  +				return false
  +			}
  ```
  </details>
- flag `additional-xids-to-ignore` 用法文案同步改为"treat as non-fatal, overriding the NVML-reported GPU recovery action",且明确 action 仍会被查询与记录,仅不产生 NoSchedule 污点。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/main.go</summary>

  ```diff
  -			Usage:       "A comma-separated list of additional XIDs to ignore.",
  +			Usage:       "A comma-separated list of XIDs to treat as non-fatal, overriding the NVML-reported GPU recovery action.",
  ```
  </details>
### 后续发展方向 [AI]
- DRA 驱动的设备健康从"静态 XID 黑白名单"转向"跟随 NVML/驱动的动态恢复动作",意味着 GPU 故障→ResourceSlice 污点→调度规避的准确性更依赖驱动侧 recovery action 语义;这是 DRA 原生路径(非 HAMi 软切分)在可靠性上的收敛。证据仅覆盖 kubelet-plugin 的 XID→taint 路径,未见 ResourceSlice 侧消费方如何处理粘性污点的解除。

## gpu-operator: 8fe3fd61 -> 93c0ff56
- 比较 https://github.com/NVIDIA/gpu-operator/compare/8fe3fd61821ba51f6ddd2e7668388360c9655e2f...93c0ff560ca71e761d6c1782d904765bb88de3db | ahead=4 | files=9 | Release: v26.7.0
### AI 总结重点(源码 diff 为据)
- **新增 Cluster Autoscaler scale-from-zero 门控示例(operator 本体零改动)**:纯 `examples/cluster-autoscaler/` 文档+YAML,给出三件套——node pool 模板在新 GPU 节点上打 `readiness.k8s.io/nvidia-gpu-not-ready=pending:NoSchedule` startup taint;NPD 自定义插件跑 nvidia-smi 探针、发布 `nvidia.com/GPUReady` 节点条件;NRC 据 `NodeReadinessRule`(CRD 强制 `readiness.k8s.io/` 前缀)在条件 True 后摘污点。解决"GPU 节点 Ready 早于驱动/toolkit/device-plugin 装完就被调度"的窗口,operator operand 靠既有 toleration 容忍该污点。
  <details><summary>代码依据 examples/cluster-autoscaler/node-readiness-rule.yaml</summary>

  ```diff
  +apiVersion: readiness.node.x-k8s.io/v1alpha1
  +kind: NodeReadinessRule
  +spec:
  +  conditions:
  +    - type: nvidia.com/GPUReady
  +      requiredStatus: "True"
  +  taint:
  +    key: readiness.k8s.io/nvidia-gpu-not-ready
  +    effect: NoSchedule
  +  enforcementMode: bootstrap-only   # continuous 可做 day-2 重新门控
  ```
  </details>
- cc-manager 镜像 v0.4.3→v0.4.4(CSV + ClusterPolicy env 同步),无字段增删。
  <details><summary>代码依据 bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml</summary>

  ```diff
  -      image: nvcr.io/nvidia/cloud-native/k8s-cc-manager:v0.4.3@sha256:61fe0f5c...
  +      image: nvcr.io/nvidia/cloud-native/k8s-cc-manager:v0.4.4@sha256:09b376f2...
  ```
  </details>
### 后续发展方向 [AI]
- 这是把"GPU 就绪门控"从 operator 内部逻辑外移到通用 NRC/NPD 生态的示例信号——NVIDIA 倾向用上游 Node Readiness Controller(`readiness.node.x-k8s.io`)而非自造 taint 管理。证据仅为 example 文档,ClusterPolicy CRD 无字段变化,operator 未内建此流程。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 未动),Release v1.20.0。
- NVIDIA/dcgm-exporter — 无新提交,Release 4.6.0-4.8.3。
- NVIDIA/DCGM(master)— 无新提交。
- NVIDIA/mig-parted — 无新提交,Release v0.15.0。
- NVIDIA/gpu-driver-container — 仅 typo 修正(choosen→chosen、pleae→please、opertor→operator 等)+ Ubuntu base 镜像日期 bump(resolute-20260901→20260912、noble-20260905→20260911),无功能变化。
- NVIDIA/k8s-device-plugin — 仅新增 `AGENTS.md`(AI coding agent 指引文档),无代码/配置变化,Release v0.20.0。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=93c0ff560ca71e761d6c1782d904765bb88de3db branch=main release=v26.7.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3a6c050d9c0c7b2516ce17e2190fb7e71b741f82 branch=main release=v1.20.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=03b7c1d1be459bbfb1cbf1cebe8d54c232657ea5 branch=main release=— scanned=2026-09-18 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=674f626b4a6bd353e0cb2e01b5ef6f9d75adb4f2 branch=main release=v0.20.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=2b0257ccc35d54968756fb0db10c6740ae923826 branch=main release=v0.5.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-18 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-18 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f9613a3bb99dd2b9c01b41a1ebaf11ef17fdbc03 branch=main release=v0.15.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=716b92d81a5507805fbe6dd0038ca73b5f9c0db3 branch=main release=v0.17.2 scanned=2026-09-18 -->
