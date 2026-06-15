# NVIDIA 算力栈 diff 雷达 2026-06-16

## 摘要
- KAI-Scheduler 修了一个**分数 GPU 共享的核心账目 bug**:同一 node 上同一 gpu-group 会被创建出多个 reservation pod、各占一块不同物理 GPU,污染调度器的 fractional-GPU 账目、把设备卡成不可调度;现改为按 (node, gpu-group) 生成**确定性 pod 名** + 把 AlreadyExists 当成功复用。
- gpu-operator 仅 1 条 CI 权限提交(放开 package write 以推 helm OCI 制品),无算力栈代码/CRD 改动;其余 7 仓全 EMPTY。
- 当日无 API/CRD/弃用/架构/版本跨档信号;唯一实质代码改动集中在 KAI 调度器的 GPU 共享路径。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [行为修正·分数GPU账目] binder 把 GPU reservation pod 名从"node + 5位随机串"改成按 (node, gpu-group) 的 sha256 确定性命名,并把创建时的 AlreadyExists 视为成功复用,根治同一 gpu-group 重复占多块物理 GPU 导致的 fractional-GPU 账目损坏/设备不可调度。证据 `pkg/binder/binding/resourcereservation/resource_reservation.go` https://github.com/kai-scheduler/KAI-Scheduler/pull/1693
  (非硬信号清单命中,但属 NVIDIA 调度器 GPU 共享核心正确性修复,故上报。)

## kai-scheduler/KAI-Scheduler: b54b6447 -> 255142d8
- 比较: b54b644742d1043ed8fac5ee9650f19f295f1e65 -> 255142d8 | ahead=4 | files=13 | Release: v0.15.2(与上期同档,无版本跨档)
- 比较链接:https://github.com/kai-scheduler/KAI-Scheduler/compare/b54b644742d1043ed8fac5ee9650f19f295f1e65...255142d8348faf0680b082a224f8a6c4dfd8fdaf

### AI 总结重点(源码 diff 为据)
- **reservation pod 命名从随机改为确定性,杜绝同 gpu-group 重复预留**。旧逻辑 `createGPUReservationPod` 用 `gpu-reservation-<node>-<rand(5)>` 命名,5 位随机串使并发/重试 bind 会在 API server 上各建一个新对象,各自落到不同物理 GPU 上 —— 调度器据此记的分数 GPU 账目因此重复计/错位,设备被"占满"而不可调度。新逻辑改用 `reservationPodName(node, gpuGroup)` = `gpu-reservation-<sha256(node+"/"+gpuGroup)[:8]>`,同一 (node, gpu-group) 必然撞同一对象名;并删掉 `reservationPodRandomCharacters=5` 常量与 `k8s.io/apimachinery/pkg/util/rand` 依赖。
  <details><summary>代码依据 pkg/binder/binding/resourcereservation/resource_reservation.go</summary>

  ```diff
  const (
  -	resourceReservation            = "resource-reservation"
  -	gpuReservationPodPrefix        = "gpu-reservation"
  -	gpuIndexAnnotationName         = "run.ai/reserve_for_gpu_index"
  -	numberOfGPUsToReserve          = 1
  -	reservationPodRandomCharacters = 5
  -	unknownGpuIndicator            = "-1"
  +	resourceReservation     = "resource-reservation"
  +	gpuReservationPodPrefix = "gpu-reservation"
  +	gpuIndexAnnotationName  = "run.ai/reserve_for_gpu_index"
  +	numberOfGPUsToReserve   = 1
  +	unknownGpuIndicator     = "-1"
  )
  ...
  -	podName := fmt.Sprintf("%s-%s-%s", gpuReservationPodPrefix, nodeName, rand.String(reservationPodRandomCharacters))
  +	podName := reservationPodName(nodeName, gpuGroup)
  ...
  +func reservationPodName(nodeName, gpuGroup string) string {
  +	hash := sha256.Sum256([]byte(nodeName + "/" + gpuGroup))
  +	return fmt.Sprintf("%s-%s", gpuReservationPodPrefix, hex.EncodeToString(hash[:8]))
  +}
  ```
  </details>
- **AlreadyExists 由错误变为"复用既有预留"**。创建 reservation pod 失败时,新逻辑先判 `apierrors.IsAlreadyExists`:命中即说明另一并发 bind/重试/另一 binder 副本已为该 gpu-group 建好预留,直接 `return pod, nil` 复用,不再当失败上抛 —— 与确定性命名配套,把"撞名"从冲突变成幂等收敛点。
  <details><summary>代码依据 pkg/binder/binding/resourcereservation/resource_reservation.go</summary>

  ```diff
  	pod, err := rsc.createResourceReservationPod(nodeName, gpuGroup, podName, resources)
  	if err != nil {
  +		// AlreadyExists 表示已有 actor(并发 bind/重试/另一 binder 副本)为该 gpu-group
  +		// 建好预留,复用而非在另一块物理 GPU 上再建一个。
  +		if apierrors.IsAlreadyExists(err) {
  +			logger.Info("GPU reservation pod already exists for gpu group, reusing", ...)
  +			return pod, nil
  +		}
  		logger.Error(err, "Failed to create GPU reservation pod on node", ...)
  		return nil, err
  	}
  ```
  </details>
- **Helm chart:prometheus RBAC 改为按 `prometheus.enabled` 开关,且用 release namespace**(#1684)。`prometheus-binding.yaml` / `prometheus-pod.yaml` 整体包进 `{{- if .Values.prometheus.enabled }}`,ClusterRoleBinding 的 subject namespace 由硬编码 `kai-scheduler` 改为 `{{ .Release.Namespace }}`。影响装包正确性(非默认命名空间安装、未开 prometheus 时不再误装 RBAC),非调度算法。
  <details><summary>代码依据 deployments/kai-scheduler/templates/rbac/prometheus-binding.yaml</summary>

  ```diff
  +{{- if .Values.prometheus.enabled }}
   subjects:
     - kind: ServiceAccount
       name: prometheus
  -    namespace: kai-scheduler
  +    namespace: {{ .Release.Namespace }}
  +{{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- 这次改动证明 KAI 的 fractional-GPU 共享走的是"用一个 reservation pod 占住整块物理 GPU、再在其上做分数账目"的路线,且对**并发/多 binder 副本**下的幂等性在补课 —— 与 HAMi 的 hook 时分路线不同,KAI 是"预留 pod + 账目"。证据只覆盖 reservation pod 命名/复用这一段 hunk,未见分数账目本身的分配算法(`numberOfGPUsToReserve=1` 仍是整卡预留粒度),无法判断是否在向更细粒度演进。
- 其余 3 条(确定性命名外的 coverage gate CI #1689、golangci 移到根 #1690、prometheus RBAC 门控 #1684)均为工程/装包侧,无 CRD/API 面变化;Config CR、podgrouper 等调度抽象本期未动。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- NVIDIA/gpu-operator:仅 1 条 CI 提交 "allow package write permission to push helm oci artifacts"(改 `.github/workflows`),无 ClusterPolicy CRD/operator 代码改动,按非实质处理,保锚点。
- NVIDIA/nvidia-container-toolkit:无新提交。
- NVIDIA/gpu-driver-container:无新提交。
- NVIDIA/k8s-device-plugin:无新提交。
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交。
- NVIDIA/dcgm-exporter:无新提交。
- NVIDIA/DCGM:无新提交。
- NVIDIA/mig-parted:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=cb50bd3c36c1a2295495d14448c565442f90b0a3 branch=main release=v26.3.2 scanned=2026-06-16 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=59c042086ec213caba72dc7570facffc911f38dd branch=main release=v1.19.1 scanned=2026-06-16 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=5c00b0e6bdb2ddc35a9ebd96e1221abe25049798 branch=main release=— scanned=2026-06-16 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=8993bf00afc77b8d4e7e076dd27de45b71b6b9e7 branch=main release=v0.19.2 scanned=2026-06-16 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=dccc5fee48302b3522369acd598af57420fbd6a1 branch=main release=v0.4.1-rc.1 scanned=2026-06-16 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-16 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-16 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=abc8f3b67eea982370a8d0f60838feec0691e051 branch=main release=v0.14.2 scanned=2026-06-16 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=255142d8348faf0680b082a224f8a6c4dfd8fdaf branch=main release=v0.15.2 scanned=2026-06-16 -->
</content>
</invoke>
