# NVIDIA 算力栈 diff 雷达 2026-08-04

## 摘要
- KAI-Scheduler 发布 v0.17.0(minor 跨档):落地 DRA-backed 扩展资源(KEP-5004)、抢占延迟(preemption-delay)、拓扑层别名、FIPS 镜像;并把 NUMA 插件对齐 kubelet static policy——分数 CPU 不再计入 NUMA 对齐,请 GPU 的非 Guaranteed pod 也做设备对齐。
- gpu-operator:DCGM-exporter 在 DRA 节点上的 pod 归因由"可选开关"改为**默认常开**——删掉 `PodMetadataEnabled` 门控,`KUBERNETES_ENABLE_DRA=true`、pods-read ClusterRole、SA token 挂载全部无条件渲染。
- dra-driver-nvidia-gpu:修 findFile 会被同名目录"遮蔽"真实库/二进制的问题,加正规文件校验;其余 5 仓 EMPTY。

## 当日重要改变
- NVIDIA/gpu-operator [新能力/默认行为变更] DCGM-exporter DRA 节点 pod 指标归因默认开启,不再需要开启 pod metadata 富化。证据:internal/state/types.go 删除 `PodMetadataEnabled` 字段、0700_daemonset.yaml 去掉 `{{- if .PodMetadataEnabled }}` 门控。 https://github.com/NVIDIA/gpu-operator/commit/2afd52ba483dd018d213944ebe06c5983b8879bf
- kai-scheduler/KAI-Scheduler [版本跨档] v0.16.8 -> v0.17.0(minor)。 https://github.com/kai-scheduler/KAI-Scheduler/releases/tag/v0.17.0
- kai-scheduler/KAI-Scheduler [新能力] DRA-backed 扩展资源(KEP-5004):pod 可只写 DeviceClass 的 extendedResourceName、无需 ResourceClaim,调度器自动走 DRA。证据见 v0.17.0 CHANGELOG。 https://github.com/kai-scheduler/KAI-Scheduler/issues/1943
- kai-scheduler/KAI-Scheduler [架构方向] NUMA 插件重写 CPU 请求核算,镜像 kubelet staticPolicy.guaranteedCPUs 语义。证据:pkg/scheduler/plugins/numa/requests.go 新增 guaranteedCPUMilli/podGuaranteedCPUMilli。 https://github.com/kai-scheduler/KAI-Scheduler/commit/f218c69bee5e5fc6031273ba555d09916b1ca89a

## NVIDIA/gpu-operator: 14ca11b9 -> 2afd52ba
- 比较: https://github.com/NVIDIA/gpu-operator/compare/14ca11b974fe3f4bb71df8741b31dc027193fee4...2afd52ba483dd018d213944ebe06c5983b8879bf | ahead=2 | Release: v26.3.3

### AI 总结重点(源码 diff 为据)
- **DCGM-exporter 在 DRA 节点上的 pod 归因从"可选"变为"默认常开"**:kubelet 上报 DRA 分配设备用的是 (pool, device) 名而非 GPU UUID,exporter 必须靠 ResourceSlice informer 才能把指标解析回 pod/namespace/container。旧代码把这套能力用 `PodMetadataEnabled` 门控起来(默认关),现在直接删除该门控字段,`KUBERNETES_ENABLE_DRA` 环境变量、pods-read ClusterRole/Binding、SA token 挂载全部无条件渲染。效果:DRA 节点上装了 operator 就自带 pod 级 GPU 指标归因,不必再显式打开 pod metadata 富化。
  <details><summary>代码依据 internal/state/types.go + 0700_daemonset.yaml</summary>

  ```diff
  // types.go:删除 dcgmExporterRenderData.PodMetadataEnabled 字段
  -	// PodMetadataEnabled mounts the ServiceAccount token and binds the pods-read ClusterRole.
  -	PodMetadataEnabled           bool

  // 0700_daemonset.yaml:SA token 从条件挂载改为常开
  -      automountServiceAccountToken: {{ .PodMetadataEnabled }}
  +      automountServiceAccountToken: true

  // KUBERNETES_ENABLE_DRA 去掉 if 门控,常置 true
  -        {{- if .PodMetadataEnabled }}
         - name: KUBERNETES_ENABLE_DRA
           value: "true"
  -        {{- end }}
  ```
  </details>
- **pods-read ClusterRole/ClusterRoleBinding 也去门控、无条件下发**:配套上面的改动,RBAC 从"仅富化开启时渲染"变成默认存在。测试断言同步:默认场景下 `kinds["ClusterRole"]` 从 0 改成 1、`AutomountServiceAccountToken` 从 false 改成 true。区分点:pod labels / pod UID 富化(`DCGM_EXPORTER_KUBERNETES_ENABLE_POD_LABELS/UID`)仍是可选、默认关,只有 DRA pod 归因这一层变默认。
  <details><summary>代码依据 0210_clusterrole.yaml / dcgm_exporter_test.go</summary>

  ```diff
  // clusterrole.yaml 去掉外层门控
  -{{- if .PodMetadataEnabled }}
   apiVersion: rbac.authorization.k8s.io/v1
   kind: ClusterRole
  ...
  -{{- end }}

  // 默认启用测试:归因常开,labels/uid 仍关
  +	assert.Equal(t, "true", env["KUBERNETES_ENABLE_DRA"])
  +	assert.NotContains(t, env, "DCGM_EXPORTER_KUBERNETES_ENABLE_POD_LABELS")
  +	assert.NotContains(t, env, "DCGM_EXPORTER_KUBERNETES_ENABLE_POD_UID")
  ```
  </details>

### 后续发展方向 [AI]
- gpu-operator 正把 DRA 当成 DCGM-exporter 的一等部署路径(daemonset 名就叫 `nvidia-dcgm-exporter-dra`、nodeSelector 走 `nvidia.com/gpu.deploy.dcgm-exporter-dra`),这次是把 DRA 节点的可观测性从"opt-in"下沉为默认基线。证据只覆盖 exporter 的渲染与 RBAC 门控删除,未见 ClusterPolicy CRD 字段增删(本次无 `*_types.go`/`config/crd` 命中),即 API 面暂稳定。

## kubernetes-sigs/dra-driver-nvidia-gpu: a7e5ba36 -> 9c52a7d5
- 比较: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/a7e5ba36376efcaebac3d8b273523e756996d516...9c52a7d50994adbf2fbb5f1ce2f6466fa3f9936f | ahead=6 | Release: v0.4.1

### AI 总结重点(源码 diff 为据)
- **findFile 加"仅正规文件"校验,防同名目录遮蔽真实库/二进制**:gpu-kubelet-plugin 与 compute-domain-kubelet-plugin 两个 root.go 里,库/二进制发现按搜索路径逐个尝试。旧逻辑只要 resolveLink 成功就返回该候选;若某靠前搜索路径下存在同名**目录**(如 `usr/lib64/libnvidia-ml.so.1/` 是目录),会被误当命中而"遮蔽"后面路径里真正的库文件。改动在 resolveLink 后追加 `os.Stat` + `info.Mode().IsRegular()` 判断,非正规文件跳过继续搜,并加 klog V(4) 记录跳过原因。两个插件同步改。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/root.go(compute-domain 同款)</summary>

  ```diff
   candidate, err := resolveLink(l)
   if err != nil {
  +	klog.V(4).Infof("Skipping candidate %q: %v", l, err)
  +	continue
  +	}
  +	info, err := os.Stat(candidate)
  +	if err != nil {
  +	klog.V(4).Infof("Skipping candidate %q: %v", candidate, err)
  +	continue
  +	}
  +	if !info.Mode().IsRegular() {
  +	klog.V(4).Infof("Skipping candidate %q: not a regular file (mode %s)", candidate, info.Mode())
   	continue
   }
   return candidate, nil
  ```
  </details>
- 附带 CI 修正:mock-nvml 把 gb200 期望产品名从 `NVIDIA GB200 NVL` 改回 `NVIDIA GB200`(hack/ci/mock-nvml/common.sh),纯测试夹具对齐,非运行时逻辑。新增 root_test.go(两插件各 124 行)覆盖上面的目录遮蔽场景。

### 后续发展方向 [AI]
- 属驱动库/二进制发现的健壮性修复,面向容器内 driver root 布局不规整(符号链接、同名目录)的边缘场景,非能力变更。证据仅覆盖 findFile 一处,未见 ResourceSlice/DeviceClass 等 DRA API 面改动。

## kai-scheduler/KAI-Scheduler: ada8bf54 -> f218c69b
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/ada8bf545b60860da9e2c03595d39d4ad222ba0c...f218c69bee5e5fc6031273ba555d09916b1ca89a | ahead=5 | Release: v0.17.0

### AI 总结重点(源码 diff 为据)
- **NUMA 插件 CPU 核算重写,镜像 kubelet static CPU policy 的"整核才独占对齐"语义**:旧 buildNumaRequests 直接把每个容器 `Resources.Requests` 原样求和参与 NUMA 对齐。新版为每个容器/pod 用 `guaranteedCPUMilli` 修正 CPU 值——只有 Guaranteed pod 且请求为**整数核**的容器才计入(分数核留在共享池、不约束任何 NUMA zone),否则该容器 CPU 归零。pod 级用 `podGuaranteedCPUMilli` 复刻 kubelet 的 init-peak vs long-running-sum 形状。避免了对分数 CPU pod 的"过约束"导致的错误不可调度。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/requests.go</summary>

  ```diff
  +func guaranteedCPUMilli(pod *v1.Pod, c *v1.Container) float64 {
  +	if pod.Status.QOSClass != v1.PodQOSGuaranteed {
  +		return 0
  +	}
  +	q := c.Resources.Requests[v1.ResourceCPU]
  +	if q.Value()*1000 != q.MilliValue() {   // 非整核 → 不做独占对齐
  +		return 0
  +	}
  +	return float64(q.MilliValue())
  +}
  // init 容器区分 native sidecar(RestartPolicy=Always)走 concurrent、否则 serial
  +func isNativeSidecar(c *v1.Container) bool {
  +	return c.RestartPolicy != nil && *c.RestartPolicy == v1.ContainerRestartPolicyAlways
  +}
  ```
  </details>
- **GPU 预留 pod 继承源工作负载的 tolerations**:分数 GPU 场景下 binder 会创建 reservation pod 占位。旧 createResourceReservationPod 不带 tolerations,可能被节点污点挡住、无法落在目标节点。改动把 sourcePod 一路透传进 acquireGPUIndexByGroup → createGPUReservationPod → createResourceReservationPod,并深拷贝其 Tolerations 赋给预留 pod。
  <details><summary>代码依据 pkg/binder/binding/resourcereservation/resource_reservation.go</summary>

  ```diff
  -func (rsc *service) createResourceReservationPod(nodeName, gpuGroup, podName string, resources ...) {
  +func (rsc *service) createResourceReservationPod(sourcePod *v1.Pod, nodeName, gpuGroup, podName string, resources ...) {
  +	var tolerations []v1.Toleration
  +	if sourcePod != nil {
  +		tolerations = sourcePod.Spec.DeepCopy().Tolerations
  +	}
  ```
  </details>
- **status-updater 丢弃终态/不可重试的 pod patch 错误**:旧代码任何 patch 失败都只打日志、留在 inFlightPods 里等下轮重试,pod 已删时会无限刷 NotFound。新版遇 `isTerminalUpdateError` 直接从 inFlightPods 删除并返回,止住日志洪水。
  <details><summary>代码依据 pkg/scheduler/cache/status_updater/concurrency.go</summary>

  ```diff
   if err != nil {
  +	if isTerminalUpdateError(err) {
  +		su.inFlightPods.Delete(key)
  +		return
  +	}
   	log.StatusUpdaterLogger.V(1).Errorf("Failed to patch pod %s/%s: %v", ...)
  ```
  </details>
- v0.17.0 release 里其余能力(从 CHANGELOG 读,非本区间逐文件 hunk,标注:未逐 PR 展开):DRA-backed 扩展资源(KEP-5004,pod 免 ResourceClaim 直接请求 DeviceClass extendedResourceName,#1943);抢占延迟 `kai.scheduler/preemption-delay` 注解(给 autoscaler 开一个先扩容再抢占的窗口,#1832);拓扑层 `alias`(可用 rack 等别名替代原始节点 label key,新增 Topology validating webhook,#1498);FIPS 140-3 镜像变体(`<version>-fips` + `global.fips` Helm 值,#1867);DRA GPU 设备计数饱和防 int64 溢出(#1873)。

### 后续发展方向 [AI]
- 两条主线清晰:①**向 DRA 原生对齐**——DRA-backed 扩展资源让 pod 不写 ResourceClaim 也能走 DRA 分片,是 device-plugin→DRA 迁移里降低用户改造成本的一步;②**NUMA/拓扑感知调度做深**——本区间 NUMA CPU 核算对齐 kubelet、请 GPU 的非 Guaranteed pod 也做设备对齐,配合 v0.17.0 的拓扑别名与 NUMA 打分,KAI 在"预测 kubelet Topology Manager 决策"上持续加码。证据:requests.go 的 guaranteed* 函数为真实 hunk;DRA/拓扑别名/抢占延迟仅见 CHANGELOG 条目,未逐文件核对实现。

## 本期无实质改动(折叠)
<details>

- NVIDIA/nvidia-container-toolkit:无新提交
- NVIDIA/k8s-device-plugin:无新提交
- NVIDIA/dcgm-exporter:无新提交
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:ahead=2,仅 bump/CI/merge,无实质代码
- NVIDIA/gpu-driver-container:ahead=6,仅 RHEL UBI 基础镜像 digest 上移(ubi8 8.10-1785301794→1785749648、ubi10 10.2-1785332302→1785719360)+ docker/login-action 固定到 v4.5.2 + renovate action bump,纯维护无功能变更
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=2afd52ba483dd018d213944ebe06c5983b8879bf branch=main release=v26.3.3 scanned=2026-08-04 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=828fc6ce327ddca61d6f179a13c18ab94e0c658c branch=main release=v1.20.0-rc.1 scanned=2026-08-04 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=62d1d78310bbd0dfdaa5d7fb0e362e24e9d9e584 branch=main release=— scanned=2026-08-04 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5f27eeeee7eb7f7a4c0581aa10abeda7e4604ed2 branch=main release=v0.19.3 scanned=2026-08-04 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9c52a7d50994adbf2fbb5f1ce2f6466fa3f9936f branch=main release=v0.4.1 scanned=2026-08-04 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-04 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-04 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=d371bfbfca29e90ce6125465f13af24d6ebd29e9 branch=main release=v0.14.4 scanned=2026-08-04 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f218c69bee5e5fc6031273ba555d09916b1ca89a branch=main release=v0.17.0 scanned=2026-08-04 -->
</content>
</invoke>
