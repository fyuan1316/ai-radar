# NVIDIA 算力栈 diff 雷达 2026-08-25

## 摘要
- **KAI-Scheduler 落地 KEP-1287 原地扩缩容(in-place pod resize)全链路**:新增 `InPlacePodResize` 准入 CRD 字段 + 独立 resize 校验 webhook,把队列层级配额检查接到 `pods/resize` 子资源上;资源核算改为委托 k8s `component-helpers` 并读 status 生效值。NVIDIA(原 Run:ai)调度器开始支持 Pod 不重建改配额。
- KAI-Scheduler 另新增 `gpujoborder` 插件(可配置 JobOrderFn 平局判定,按 GPU 维度排序)。
- gpu-operator 修复 SUSE(sles/sl-micro)预编译驱动的 `/lib/modules` 挂载(此前被错嵌在订阅配置块内,SUSE 预编译路径拿不到宿主内核模块);其余为 Go 1.27 工具链、Helm OCI chart e2e 等工程改动。
- 其余七仓(nvidia-container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)相对上期锚点无新提交,仅保锚点续链。

## 当日重要改变
- **kai-scheduler/KAI-Scheduler [API/CRD变更][新能力]** 准入 API 新增 `InPlacePodResize`(含 `ValidateQuota` 默认 true、`BlockUpsizeOnBoundedQueues` 默认 false)并同步进 CRD;配套新增 `PodResizeValidator` webhook 对 KEP-1287 原地扩缩容做层级队列配额准入。证据:`pkg/apis/kai/v1/admission/admission.go`、`pkg/admission/webhook/v1alpha2/podhooks/pod_resize_validator.go`、`deployments/kai-scheduler/crds/kai.scheduler_configs.yaml`。https://github.com/kai-scheduler/KAI-Scheduler/pull/2021
- **kai-scheduler/KAI-Scheduler [新能力]** 新增 `gpujoborder` 调度插件(可配置的 JobOrderFn 平局判定)。证据:`pkg/scheduler/plugins/gpujoborder/gpujoborder.go`、`pkg/scheduler/framework/session_plugins.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1995

## NVIDIA/gpu-operator: a22dbf67 -> 90e932f1
- 比较: a22dbf67...90e932f1 | ahead=17 | files=23 | Release: v26.7.0 | https://github.com/NVIDIA/gpu-operator/compare/a22dbf67...90e932f1

### AI 总结重点(源码 diff 为据)
- **SUSE 预编译驱动的 `/lib/modules` 挂载被从内层块提到外层**:此前 `UsePrecompiledDrivers() && osRelease∈{sles,sl-micro}` 的挂载逻辑嵌在前一个订阅配置(subscription volume)`if` 块内,意味着不走该分支的 SUSE 预编译驱动 Pod 拿不到宿主 `/lib/modules`(挂到 `/run/host/lib/modules` 只读)。改动把它拆成独立的顶层判断,并把日志措辞从 "into the driver container" 改为 "into the driver pod"。属驱动容器化 OS 矩阵的功能性修复,直接影响 SUSE 上预编译驱动能否加载内核模块。
  <details><summary>代码依据 internal/state/driver_volumes.go</summary>

  ```diff
  +	}
   
  -		// Mount /lib/modules for precompiled drivers on SUSE distributions.
  -		if cr.Spec.UsePrecompiledDrivers() && (pool.osRelease == "sles" || pool.osRelease == "sl-micro") {
  -			logger.Info("Mounting /lib/modules into the driver container")
  +	if cr.Spec.UsePrecompiledDrivers() && (pool.osRelease == "sles" || pool.osRelease == "sl-micro") {
  +		logger.Info("Mounting /lib/modules into the driver pod")
  +		libModulesVolMount := corev1.VolumeMount{
  +			Name:      "lib-modules",
  +			MountPath: "/run/host/lib/modules",
  +			ReadOnly:  true,
  +		}
  ```
  </details>
- **升级控制器去掉冗余的 `Requeue: true`**:`reconcileClusterPolicyDriverUpgrades` 与 `reconcileNVIDIADriverUpgrades` 的返回值只保留 `RequeueAfter: plannedRequeueInterval`。controller-runtime 中设了 `RequeueAfter` 再叠 `Requeue: true` 属冗余(新版会告警),行为不变,纯清理。
  <details><summary>代码依据 controllers/upgrade_controller.go</summary>

  ```diff
  -	return ctrl.Result{Requeue: true, RequeueAfter: plannedRequeueInterval}, nil
  +	return ctrl.Result{RequeueAfter: plannedRequeueInterval}, nil
  ```
  </details>
- **工程/CI**:Go 工具链 1.26.6→1.27.0、golangci-lint v2.12.2→v2.13.1(`versions.mk`);e2e 改为可对"已发布的 Helm OCI chart"做安装校验(`.definitions.sh` 引入 `HELM_CMD_ARGS`,`publish-helm-oci-chart.yaml` 导出 chart_reference/version)。不涉能力面。

### 后续发展方向 [AI]
- 证据只覆盖本区间 diff:SUSE 挂载修复表明 gpu-operator 仍在补齐非 RHEL 发行版的预编译驱动矩阵(sl-micro = SUSE Linux Micro,边缘/不可变 OS 方向)。未见 ClusterPolicy/NVIDIADriver CRD 字段增删(本区间 `*_types.go` 无命中),故非架构级变化。

## kai-scheduler/KAI-Scheduler: 2914d320 -> 920e8a01
- 比较: 2914d320...920e8a01 | ahead=2 | files=39 | Release: v0.14.8 | https://github.com/kai-scheduler/KAI-Scheduler/compare/2914d320...920e8a01

### AI 总结重点(源码 diff 为据)
- **Pod 资源核算改为委托 k8s `component-helpers`,并启用 `UseStatusResources`**:`getPodResourceRequest` 删掉 KAI 自研的 `initContainerEffects` / `getPodResourceWithoutInitContainers`(手工模拟 kubelet 的原生 sidecar KEP-753 稳态求和 + init 峰值),改调 `resourcehelpers.AggregateContainerRequests(pod, PodResourcesOptions{UseStatusResources: true})`。语义变化:调度核算的"有效请求"现在会读 Pod status 里 resize 实际生效/已分配的值,而非只看 spec —— 这是支撑原地扩缩容记账的前提。
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
  -	result := getPodResourceWithoutInitContainers(pod)
  -	sidecarSum, initPhasePeak := initContainerEffects(pod)
  -	logIfErr(pod, result.Add(sidecarSum))
  -	logIfErr(pod, result.SetMaxResource(initPhasePeak))
  +	reqs := resourcehelpers.AggregateContainerRequests(pod, resourcehelpers.PodResourcesOptions{
  +		UseStatusResources: true,
  +	})
  +	result := resource_info.RequirementsFromResourceList(reqs)
  ```
  </details>
- **准入 API 新增 `InPlacePodResize` 结构体(KEP-1287)**:`Admission` 增字段,含 `ValidateQuota`(默认 true,开启对 pods/resize 的层级队列配额尽力校验)与 `BlockUpsizeOnBoundedQueues`(默认 false,任何"祖先队列有有限 CPU/内存 limit"的 upsize 一律拒,防并发 resize 竞态突破硬上限);`SetDefaultsWhereNeeded` 补默认值,CRD yaml 同步。
  <details><summary>代码依据 pkg/apis/kai/v1/admission/admission.go</summary>

  ```diff
  +	// InPlacePodResize configures in-place pod resize (KEP-1287) behaviour.
  +	InPlacePodResize *InPlacePodResize `json:"inPlacePodResize,omitempty"`
  +}
  +type InPlacePodResize struct {
  +	ValidateQuota *bool `json:"validateQuota,omitempty"`
  +	BlockUpsizeOnBoundedQueues *bool `json:"blockUpsizeOnBoundedQueues,omitempty"`
  +}
  ```
  </details>
- **新增 `PodResizeValidator` 准入 webhook**:实现 `admission.Validator[*corev1.Pod]`,仅对 `schedulerName` 命中 KAI 的 Pod 生效;`ValidateUpdate` 校验 resize,`validateQuota=false` 时直接放行;取 Pod 的 `PodGroupAnnotationForPod` 找到队列后做层级配额比对(队列 `Memory.Limit` 以 MB 计,`memoryLimitBytesPerUnit=1_000_000` 换算成字节)。是上面 CRD 开关的执行体。
  <details><summary>代码依据 pkg/admission/webhook/v1alpha2/podhooks/pod_resize_validator.go</summary>

  ```diff
  +type PodResizeValidator struct {
  +	kubeClient                 client.Client
  +	schedulerName              string
  +	validateQuota              bool
  +	blockUpsizeOnBoundedQueues bool
  +}
  +func (v *PodResizeValidator) ValidateUpdate(ctx context.Context, oldPod, newPod *corev1.Pod) (admission.Warnings, error) {
  +	if newPod.Spec.SchedulerName != v.schedulerName { return nil, nil }
  +	return nil, v.validateResize(ctx, oldPod, newPod)
  +}
  ```
  </details>
- **PodGroup GPU 请求量加缓存**:`PodGroupInfo` 新增 `aliveTasksRequestedGPUs *float64`,`GetAliveTasksRequestedGPUs` 首算后 memoize、`invalidateTasksCache` 时清空。纯性能优化(避免每次遍历所有 task 累加 GPU 请求)。
  <details><summary>代码依据 pkg/scheduler/api/podgroup_info/job_info.go</summary>

  ```diff
  +	aliveTasksRequestedGPUs           *float64
  ...
  -	tasksTotalRequestedGPUs := float64(0)
  -	for _, task := range pgi.GetAllPodsMap() { ... }
  -	return tasksTotalRequestedGPUs
  +	if pgi.aliveTasksRequestedGPUs == nil { ... pgi.aliveTasksRequestedGPUs = ptr.To(tasksTotalRequestedGPUs) }
  +	return *pgi.aliveTasksRequestedGPUs
  ```
  </details>
- **新增 `gpujoborder` 插件**:`pkg/scheduler/plugins/gpujoborder/gpujoborder.go`(新独立 package),提供可配置的 `JobOrderFn` 平局判定,按 GPU 维度给作业排序,在 `session_plugins.go` 注册。为 GPU 优先级排队提供额外的 tiebreak 手段。

### 后续发展方向 [AI]
- 证据覆盖:in-place resize 在 KAI 里目前是"记账 + 准入校验"闭环(读 status 有效请求 + webhook 拦 upsize),尚未见到调度器主动触发 resize 或抢占逻辑(本区间无 preemption/allocate 侧改动)。方向明确指向让 GPU/CPU 队列配额与 K8s 1.33 GA 的原地扩缩容协同——运行中 Pod 改配额不再需重建、且不会绕过队列硬限。
- `getPodResourceRequest` 从自研 init 核算切到上游 `component-helpers`,降低了与 kubelet 语义漂移的风险,也说明 KAI 在向"贴合上游 K8s 资源模型"收敛;后续依赖 bump 时需盯 `AggregateContainerRequests` 行为变化(新增的 resize 记账测试即为此设的护栏)。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- NVIDIA/nvidia-container-toolkit:无新提交(HEAD 仍 d34b3046,Release v1.20.0)
- NVIDIA/gpu-driver-container:无新提交(HEAD 仍 06a208ca,Release —)
- NVIDIA/k8s-device-plugin:无新提交(HEAD 仍 1b826acc,Release v0.20.0)
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(HEAD 仍 d682267c,Release v0.5.0)
- NVIDIA/dcgm-exporter:无新提交(HEAD 仍 181290c3,Release 4.6.0-4.8.3)
- NVIDIA/DCGM:无新提交(HEAD 仍 64df9f89,分支 master,Release —)
- NVIDIA/mig-parted:无新提交(HEAD 仍 bd7160f4,Release v0.15.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=90e932f1efbc9b4caeca966ae3f90dec3422cfda branch=main release=v26.7.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d34b3046758cb1a5db606b2a39519c731bbf9f56 branch=main release=v1.20.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=06a208ca9747c82b1ba99b76ecdcf2469b0a0207 branch=main release=— scanned=2026-08-25 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1b826acc6af3079d8923bac395c3124b8861a9a6 branch=main release=v0.20.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=d682267c7dd84a76c61663feeaf36d04ac6ebfef branch=main release=v0.5.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-25 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-08-25 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=bd7160f43f16462eeb21e1eda5e67b5b6b03fd7d branch=main release=v0.15.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=920e8a015168c31ccc811403a0323bd078e6c9d6 branch=main release=v0.14.8 scanned=2026-08-25 -->
</content>
</invoke>
