# NVIDIA 算力栈 diff 雷达 2026-07-26

## 摘要
- **gpu-operator 落地全新 `GPUCluster` v1alpha1 CRD——一条与 ClusterPolicy 并行的 DRA 原生部署路径**:不管 driver/device-plugin(driver 交给宿主或 NVIDIADriver CR,就绪后才继续),只编排 DRA driver(gpus+computeDomains)、DCGM、DCGM-Exporter;同时把 DRA 侧 `ComputeDomain`/`ComputeDomainClique`(IMEX/多节点 NVLink)两个 CRD 一并纳入 operator 仓,并新增"逐节点在 device-plugin 与 DRA 之间选栈"。这是 operator 从"ClusterPolicy 单一入口"向"DRA 软启用栈"演进的结构性信号。
- **dra-driver-nvidia-gpu 修正 VFIO passthrough 的驱动名解析**:`getVfioDriverName` 从"无脑把下划线换横杠"改成查 `/sys/bus/pci/drivers` 实际目录名再回退,并把加载内核模块/解析驱动名提到绑定校验之前;GPU 直通路径的健壮性补强。
- **KAI-Scheduler 重构不可调度 fit error**:per-node map 改成按 reason 聚合计数(compact),并新增 `detailed-fit-errors` 开关按需重算逐节点诊断——大集群下省内存/CPU 的调度可观测性改动。

## 当日重要改变
- gpu-operator [API/CRD变更][架构方向] 新增 `GPUCluster` v1alpha1(group `nvidia.com`,Cluster 作用域,单例,shortName `gc`)+ `resource.nvidia.com` 的 `ComputeDomain`/`ComputeDomainClique` v1beta1 三个 CRD;定位为 DRA 原生软启用栈,与 ClusterPolicy 共存。证据 `api/nvidia/v1alpha1/gpucluster_types.go`、`deployments/gpu-operator/crds/nvidia.com_gpuclusters.yaml` https://github.com/NVIDIA/gpu-operator/commit/cb71b4755401140cf565723f945f28d875793277
- dra-driver-nvidia-gpu [新能力/健壮性] VFIO 驱动名解析改为查 `/sys/bus/pci/drivers` 实际目录名并返回 error,修正 passthrough 绑定。证据 `cmd/gpu-kubelet-plugin/vfio-device.go` https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/b0a51e353fbabab0230639b027e02f1ab29e8cab
- KAI-Scheduler [架构方向] `TasksFitErrors` 由 `nodes map` 改为 `reasonCounts map`,新增 `detailed-fit-errors` 调度器参数(默认关)按需重算详细诊断。证据 `pkg/scheduler/api/common_info/pod_errors.go` https://github.com/kai-scheduler/KAI-Scheduler/commit/a4bee801c06a32d213993b45f45e5ec4c8345809

## NVIDIA/gpu-operator: eaadd226 -> cb71b475
- 比较: eaadd226089ca67ae0f30d4ffff5f77ad9429596 -> cb71b475 | ahead=22 | files=144 | Release: v26.3.3
- https://github.com/NVIDIA/gpu-operator/compare/eaadd226089ca67ae0f30d4ffff5f77ad9429596...cb71b4755401140cf565723f945f28d875793277

### AI 总结重点(源码 diff 为据)
- **新增 `GPUClusterSpec`:一条不碰 driver/device-plugin 的 DRA 软启用栈**。字段为 `DRADriver DRADriverSpec`(gpus 恒部署+computeDomains 自带 enabled)、`DCGM *DCGMSpec`(默认关,关时 dcgm-exporter 用内嵌 nv-hostengine)、`DCGMExporter *DCGMExporterSpec`(默认开)、`HostPaths`、`Daemonsets`。注释明确"与 ClusterPolicy 不同,它不管理 NVIDIA driver 或 device-plugin;driver 单独安装(宿主或 NVIDIADriver CR),GPUCluster 等 driver 就绪后再继续"。这把 operator 拆成"传统 ClusterPolicy(全栈)"与"GPUCluster(DRA 子栈)"两条腿。
  <details><summary>代码依据 api/nvidia/v1alpha1/gpucluster_types.go</summary>

  ```go
  // GPUClusterSpec defines the desired state of GPUCluster, the DRA-based
  // software-enablement stack. Unlike ClusterPolicy, it does not manage the NVIDIA driver
  // or the device-plugin; the driver is installed separately ... and GPUCluster waits for driver readiness before proceeding.
  type GPUClusterSpec struct {
  	DRADriver    DRADriverSpec              `json:"draDriver"`
  	DCGM         *nvidiav1.DCGMSpec         `json:"dcgm,omitempty"`
  	DCGMExporter *nvidiav1.DCGMExporterSpec `json:"dcgmExporter,omitempty"`
  	HostPaths    nvidiav1.HostPathsSpec     `json:"hostPaths,omitempty"`
  	Daemonsets   nvidiav1.DaemonsetsSpec    `json:"daemonsets,omitempty"`
  }
  // DRADriverSpec ... There is no top-level enabled toggle; the gpus capability is always
  // deployed and computeDomains has its own enabled field.
  ```
  </details>
- **`DRADriverSpec` 无顶层 enabled 开关**:gpus 能力恒部署,只有 computeDomains 有独立 enabled;复用了 v1 的 DCGMSpec/DCGMExporterSpec 但注释警告其 `enabled` 无 server-side default 且 `IsEnabled()` 把 nil 当 enabled,故 controller 必须显式把 nil 默认成 disabled(DCGM)。说明 GPUCluster 是围绕 DRA driver 为核心、DCGM 监控为可选件的组合。
  <details><summary>代码依据 api/nvidia/v1alpha1/gpucluster_types.go</summary>

  ```go
  type DRADriverSpec struct {
  	Repository      string `json:"repository,omitempty"`
  	Image           string `json:"image,omitempty"`   // +kubebuilder:validation:Pattern=^[a-zA-Z0-9\-]+$
  	Version         string `json:"version,omitempty"`
  	ImagePullPolicy string `json:"imagePullPolicy,omitempty"`
  	// ... gpus 恒部署,computeDomains 自带 enabled
  }
  ```
  </details>
- **新 CRD `gpuclusters.nvidia.com`:Cluster 作用域、单例、shortName `gc`**,打印列 `.status.state`;controller 对重复实例置 `Ignored` 状态(单例语义)。同时新增 `resource.nvidia.com` 组的 `ComputeDomain`(Namespaced,v1beta1)与 `ComputeDomainClique`——前者带 `numNodes`/`channel.allocationMode`(All|Single)+ `IMEXDaemonsWithDNSNames` 特性门(默认 true),后者记录 IMEX daemon 的 `(CliqueID, Index)` 与 Ready/NotReady 状态,面向多节点 NVLink/IMEX 显存交换。
  <details><summary>代码依据 deployments/gpu-operator/crds/nvidia.com_gpuclusters.yaml + resource.nvidia.com_computedomaincliques.yaml</summary>

  ```yaml
  # gpuclusters.nvidia.com
  names: { kind: GPUCluster, plural: gpuclusters, shortNames: [gc], singular: gpucluster }
  scope: Cluster
  # computedomaincliques.resource.nvidia.com
  daemons.items.properties:
    cliqueID: {type: string}
    index:    # (CliqueID, Index) 2-tuple 保证 IMEX 域内 IP↔DNS 名唯一
    status:   { default: NotReady, enum: [Ready, NotReady] }  # IMEX daemon 就绪态
  ```
  </details>
- **新增 GPUCluster controller、DRA/DCGM/DCGM-Exporter operand 与"逐节点选栈"**(commit 主题+新增文件为据,未见 hunk):`controllers/gpucluster_controller.go`(329 行,单例状态+GPU 节点打标)、`internal/state/dra_driver.go`(带 driver-validation init 容器)、`internal/state/dcgm_exporter.go`、`internal/state/dcgm.go`,以及 `manifests/state-dra-driver/`(daemonset+controller-deployment)、`manifests/state-dcgm-exporter/`;并有 "Add per-node stack selection between device-plugin and DRA" 提交,意味着可在同集群按节点分别走经典 device-plugin 或 DRA。生成的 client-gen(`api/versioned/typed/nvidia/v1alpha1/gpucluster.go` 等)证实 GPUCluster 进入了 typed client。
  <details><summary>代码依据 api/versioned/typed/nvidia/v1alpha1/nvidia_client.go</summary>

  ```go
  type NvidiaV1alpha1Interface interface {
  	RESTClient() rest.Interface
  +	GPUClustersGetter
  	NVIDIADriversGetter
  }
  +func (c *NvidiaV1alpha1Client) GPUClusters() GPUClusterInterface { return newGPUClusters(c) }
  ```
  </details>

### 后续发展方向 [AI]
- operator 正把"DRA 原生栈"做成一等公民:GPUCluster 只负责 DRA driver + 监控,driver 生命周期解耦给 NVIDIADriver CR/宿主。对标产品若自建 GPU operator,需评估是否要跟进"ClusterPolicy(全栈)+ GPUCluster(DRA 子栈)双 CRD 并存 + 逐节点选栈"这套灰度迁移形态,而非一次性切 DRA。
- ComputeDomain/ComputeDomainClique 进入 operator,说明 IMEX/多节点 NVLink(GB200/NVL 机型的 fabric 显存共享)被纳入 operator 编排范围——这是超节点场景的关键拼图。证据只覆盖 CRD schema 与 spec 字段,未见 controller 如何驱动 IMEX daemon 拓扑(controller/operand 的 hunk 未纳入本次 patch 节选,需看源链接展开)。

## kubernetes-sigs/dra-driver-nvidia-gpu: 50b7c91b -> b0a51e35
- 比较: 50b7c91b58a7c0ea23fdc693fd0b3f92446edaed -> b0a51e35 | ahead=4 | files=11 | Release: v0.4.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/50b7c91b58a7c0ea23fdc693fd0b3f92446edaed...b0a51e353fbabab0230639b027e02f1ab29e8cab

### AI 总结重点(源码 diff 为据)
- **`getVfioDriverName` 从字符串替换改为查 sysfs 真实目录名并返回 error**:旧实现无脑 `strings.ReplaceAll(vfioModule, "_", "-")`(假设 `vfio_pci`→`vfio-pci`),新实现基于"modules.alias 里模块名只含下划线,而 `/sys/bus/pci/drivers/` 目录名可能不同"这一事实,先查目录是否存在、不存在再回退换横杠,并把签名改为 `(string, error)`。同时 `Configure` 里把"加载 vfio 内核模块 + 解析 vfio 驱动名"提到"读取当前 GPU 绑定驱动"之前,失败即报错。这修正了 passthrough 场景下驱动名误判导致的绑定失败。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/vfio-device.go</summary>

  ```diff
  +	pciDriversPath = "/sys/bus/pci/drivers"
  ...
  -func getVfioDriverName(vfioModule string) string {
  -	return strings.ReplaceAll(vfioModule, "_", "-")
  +// Module names in modules.alias only contain underscores; the dir name under
  +// /sys/bus/pci/drivers may differ. Check the module name exists there, else
  +// retry with underscores→dashes.
  +func getVfioDriverName(vfioModule string) (string, error) {
  ...
  +	if loaded, err := vm.checkKernelModuleLoaded(info.vfioModule); err == nil { ... 提前加载模块 ... }
  +	vfioDriver, err := getVfioDriverName(info.vfioModule)   // 提前解析并处理 error
  ```
  </details>
- 其余为跨文件的 `%v`→`%w` 错误包装(`nvlib.go`/`device_state.go`/`checkpoint.go`/`device_health.go`,gpu 与 compute-domain 两个 kubelet-plugin 均涉及),让 NVML/checkpoint 错误可被 `errors.Is/As` 解包,便于上层判错;无行为语义变化。

### 后续发展方向 [AI]
- DRA driver 的 VFIO passthrough(`featuregates.PassthroughSupport`)仍在打磨绑定路径细节,方向是让"整卡直通给 VM/裸金属"在 DRA 语义下稳定可用。证据仅覆盖驱动名解析与错误包装,未见 passthrough 的分配/回收主流程改动。

## kai-scheduler/KAI-Scheduler: 2d50f265 -> a4bee801
- 比较: 2d50f2650339abe031a851d48ba381f376524e0a -> a4bee801 | ahead=1 | files=15 | Release: v0.16.6
- https://github.com/kai-scheduler/KAI-Scheduler/compare/2d50f2650339abe031a851d48ba381f376524e0a...a4bee801c06a32d213993b45f45e5ec4c8345809

### AI 总结重点(源码 diff 为据)
- **`TasksFitErrors` 从"逐节点存 error"改为"按 reason 聚合计数"**:结构体 `nodes map[string]*TasksFitError` 换成 `reasonCounts map[string]int`;删掉 `SetNodeError`/`AddNodeErrors`,新增 `AddNodeError`(按 fitError.Reasons 累加计数)、`AddReasonCounts`、`HasNodeErrors`、`ReasonCount`、`UniqueReasonCount`。`Error()` 输出变成聚合形式(如 "2 node(s) didn't have enough resources: GPUs")。这是 perf 改动:大集群下不再为每个失败节点保留完整 fit error,只留紧凑计数。
  <details><summary>代码依据 pkg/scheduler/api/common_info/pod_errors.go</summary>

  ```diff
   type TasksFitErrors struct {
  -	nodes map[string]*TasksFitError
  -	err   string
  +	reasonCounts map[string]int
  +	err          string
   }
  -func (f *TasksFitErrors) SetNodeError(nodeName string, err error) { ... }
  +func (f *TasksFitErrors) AddNodeError(err error) {   // 按 fitError.Reasons 累加 reasonCounts
  +func (f *TasksFitErrors) ReasonCount(reason string) int { return f.reasonCounts[reason] }
  +func (f *TasksFitErrors) UniqueReasonCount() int { return len(f.reasonCounts) }
  ```
  </details>
- **新增 `detailed-fit-errors` 调度器参数(默认关)+ 按需重算逐节点诊断**:`Session.RecomputeDetailedFitErrors` 在状态上报阶段对失败 task 重新遍历候选节点、产出 node-by-node 详细诊断,作为回调 `resolveDetailedFitErrors` 一路穿透 `RecordJobStatusEvent`(Cache→StatusUpdater interface 签名都改了)。文档明确该开关在大集群会增加调度周期 CPU,建议排障时临时开、用完关。
  <details><summary>代码依据 pkg/scheduler/framework/session.go + docs/operator/scheduler-config-customization.md</summary>

  ```go
  func (ssn *Session) RecomputeDetailedFitErrors(job *podgroup_info.PodGroupInfo, task *pod_info.PodInfo) ([]*common_info.TasksFitError, error) {
  	// PrePredicate → 遍历 ssn.ClusterInfo.Nodes → isTaskAllocatableOnNode / PredicateFn → 收集 nodeErrors
  }
  ```
  ```yaml
  # SchedulingShard / Helm values
  spec: { args: { detailed-fit-errors: "true" } }   # 默认关,排障时开
  ```
  </details>

### 后续发展方向 [AI]
- 调度器往"平时省内存/CPU(紧凑计数)、排障时按需重算详细诊断"分级可观测性走,契合 GPU 大集群 pending 堆积时的诊断成本控制。证据覆盖 fit error 数据结构、回调穿透与配置开关,未见默认路径下 pending 事件文案的端到端变化验证。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit:仅 `cmd/nvidia-container-runtime/README.md` 用法示例修正(create/start/delete 替代 run),无代码/API 改动。
- NVIDIA/gpu-driver-container:无新提交。
- NVIDIA/k8s-device-plugin:仅 bump/CI/merge。
- NVIDIA/dcgm-exporter、NVIDIA/DCGM、NVIDIA/mig-parted:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=cb71b4755401140cf565723f945f28d875793277 branch=main release=v26.3.3 scanned=2026-07-26 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=f7cb44c51c3552a76ee62fd3c4acfc8eb1c6c148 branch=main release=v1.20.0-rc.1 scanned=2026-07-26 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0ad335fb28b96957aa3f9fdda6dfdab9040e69e9 branch=main release=— scanned=2026-07-26 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=23e25265ddba8545edb8737a04cf393a982cb9da branch=main release=v0.19.3 scanned=2026-07-26 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=b0a51e353fbabab0230639b027e02f1ab29e8cab branch=main release=v0.4.1 scanned=2026-07-26 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-26 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-26 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f484af1ba590265e0cb429ca71e3c08cb8374a5d branch=main release=v0.14.4 scanned=2026-07-26 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=a4bee801c06a32d213993b45f45e5ec4c8345809 branch=main release=v0.16.6 scanned=2026-07-26 -->
