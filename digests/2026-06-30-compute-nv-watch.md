# NVIDIA 算力栈 diff 雷达 2026-06-30

## 摘要
- 仅 KAI-Scheduler 有实质改动,且全在 **scheduler 内核**层:一条 reclaim 正确性修复(#1764)+ 两条 watch/cache 显存优化(filter terminal pods、shrink cached pod objects),无 ClusterPolicy CRD / device-plugin / DRA / driver 容器化改动。
- reclaim 受害者筛选新增 `AddReclaimVictimFilterFn` 钩子:修掉"队列排序里靠前的某个 under-deserved 队列把后面合法的 over-quota 受害者一起放弃"的 bug。
- 其余 8 仓全 EMPTY(gpu-operator / container-toolkit / driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted 无新提交或仅 bump)。

## 当日重要改变
- KAI-Scheduler [新能力] 新增 reclaim 受害者过滤钩子 `AddReclaimVictimFilterFn`,proportion 插件注册 `reclaimVictimFilterFn` → `FilterVictim`,把"不可回收的受害者"在场景搜索前剔除。证据 `pkg/scheduler/plugins/proportion/reclaimable/filter_victims.go`(新增)、`proportion.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1764 https://github.com/kai-scheduler/KAI-Scheduler/issues/1750

## kai-scheduler/KAI-Scheduler: 09289b24 -> 6ee3494e
- 比较 / 最新 Release:09289b24d231197e829c1dfd0cf68b85f74d7407 -> 6ee3494e | ahead=5 | files=15 | Release: v0.16.1

### AI 总结重点(源码 diff 为据)
- **reclaim 受害者多了一道前置过滤**:proportion 插件在 `OnSessionOpen` 新注册 `ssn.AddReclaimVictimFilterFn(pp.reclaimVictimFilterFn)`,委托到新文件 `filter_victims.go` 的 `Reclaimable.FilterVictim`。语义:若 reclaimer 加上自身请求后仍在 deserved quota 内(`ReclaimerFitsDeservedQuota`),则只保留"在被牵涉资源上 allocated > deserved"或"全维度都不低于 deserved"的受害者为候选;否则退化为 `FitsMaintainFairShare`(受害者剩余份额仍高于 allocatable 才可回收)。这把"逐受害者判定"从原来的整场景校验里拆出来,避免一个不合格受害者污染整批。

  <details><summary>代码依据 pkg/scheduler/plugins/proportion/proportion.go</summary>

  ```diff
   	ssn.AddCanReclaimResourcesFn(pp.CanReclaimResourcesFn)
  +	ssn.AddReclaimVictimFilterFn(pp.reclaimVictimFilterFn)
   	ssn.AddReclaimScenarioValidatorFn(pp.reclaimableFn)
  +
  +func (pp *proportionPlugin) reclaimVictimFilterFn(
  +	reclaimer *podgroup_info.PodGroupInfo, victim *podgroup_info.PodGroupInfo,
  +) bool {
  +	reclaimerInfo := pp.buildReclaimerInfo(reclaimer, pp.minNodeGPUMemory)
  +	return pp.reclaimablePlugin.FilterVictim(pp.queues, reclaimerInfo, victim.Queue)
  +}
  ```
  </details>

  <details><summary>代码依据 pkg/scheduler/plugins/proportion/reclaimable/filter_victims.go (新增)</summary>

  ```diff
  +func (r *Reclaimable) FilterVictim(queues ..., reclaimer *ReclaimerInfo, reclaimeeQueueID common_info.QueueID) bool {
  +	if reclaimer == nil { return true }
  +	reclaimerQueue, reclaimeeQueue := r.getLeveledQueues(queues, reclaimer.Queue, reclaimeeQueueID)
  +	if reclaimerQueue == nil || reclaimeeQueue == nil { return true }
  +	if !strategies.ReclaimerFitsDeservedQuota(reclaimer.RequiredResources, reclaimer.VectorMap, reclaimerQueue) {
  +		return strategies.FitsMaintainFairShare(reclaimeeQueue, reclaimeeQueue.GetAllocatedShare())
  +	}
  +	return canBeDeservedQuotaReclaimCandidate(reclaimer, reclaimeeQueue)
  +}
  +// canBeDeservedQuotaReclaimCandidate: 任一被牵涉资源 allocated>deserved → true;
  +// 否则若存在 allocated<deserved 的资源(hasUnderDeservedResource)→ false
  ```
  </details>

- **strategies.go 把内联布尔判断抽成 3 个导出函数**:`FitsMaintainFairShare`、`ReclaimerFitsDeservedQuota`、`ReclaimeeExceedsDeservedQuota`,供上面新 `FilterVictim` 复用。注意 `ReclaimerFitsDeservedQuota` 与旧 `reclaimerWillGoOverQuota` 语义取反(原返回"会超配",新返回"仍合规"),调用点同步改成 `if !ReclaimerFitsDeservedQuota(...)`,逻辑等价但语义更正向。

  <details><summary>代码依据 pkg/scheduler/plugins/proportion/reclaimable/strategies/strategies.go</summary>

  ```diff
  -	if reclaimerWillGoOverQuota(reclaimerResources, vectorMap, reclaimerQueue) {
  +	if !ReclaimerFitsDeservedQuota(reclaimerResources, vectorMap, reclaimerQueue) {
   		return false
  -	if reclaimeeRemainingShare.LessEqual(reclaimeeQueue.GetDeservedShare()) {
  +	if !ReclaimeeExceedsDeservedQuota(reclaimeeQueue, reclaimeeRemainingShare) {
  -func reclaimerWillGoOverQuota(...) bool {
  +func ReclaimerFitsDeservedQuota(...) bool {
   	reclaimerRequestedQuota.Add(utils.QuantifyVector(reclaimerResources, vectorMap))
  -	return !reclaimerRequestedQuota.LessEqual(reclaimerQueue.GetDeservedShare())
  +	return reclaimerRequestedQuota.LessEqual(reclaimerQueue.GetDeservedShare())
  ```
  </details>

- **watch 期就过滤掉终态 Pod,降低 cache 显存**:新 `registerSchedulerPodInformer` 用 `NewFilteredPodInformer` 给 Pod informer 挂 `filterTerminalPods`,生成 `status.phase!=Succeeded,status.phase!=Failed` 的 FieldSelector;`isTerminated` 也改为统一遍历新 `terminalPodPhases` 切片(Succeeded/Failed)。注意 CHANGELOG 说明仍会 watch 别的调度器绑定的 Pod 以计入 allocatable。

  <details><summary>代码依据 pkg/scheduler/cache/cache.go</summary>

  ```diff
  +func filterTerminalPods(options *metav1.ListOptions) {
  +	// status.phase!=Succeeded,status.phase!=Failed 拼进 FieldSelector
  +}
  +func registerSchedulerPodInformer(informerFactory informers.SharedInformerFactory) {
  +	informerFactory.InformerFor(&v1.Pod{}, func(...) k8scache.SharedIndexInformer {
  +		return corev1informers.NewFilteredPodInformer(client, metav1.NamespaceAll, resyncPeriod,
  +			k8scache.Indexers{...}, filterTerminalPods)
  +	})
  +}
  @@ newSchedulerCache
  +	registerSchedulerPodInformer(sc.informerFactory)
  +	if err := setSchedulerPodTransform(sc.informerFactory.Core().V1().Pods().Informer()); err != nil { ... }
  ```
  </details>

- **缓存的 Pod 对象被裁剪以省内存**:新 `pod_transform.go` 给 informer 设 `SetTransform(compactSchedulerPod)`,DeepCopy 后清掉 `ManagedFields`,容器只保留调度相关字段(Name/Ports/EnvFrom/Env/Resources/VolumeMounts/RestartPolicy),且 `compactEnvVars` 丢弃所有非 ConfigMap/Secret 引用的字面量 env 值(大块 env 不再常驻)。

  <details><summary>代码依据 pkg/scheduler/cache/pod_transform.go (新增)</summary>

  ```diff
  +func compactSchedulerPod(obj any) (any, error) {
  +	pod, ok := obj.(*v1.Pod); if !ok { return obj, nil }
  +	compact := pod.DeepCopy()
  +	compact.ManagedFields = nil
  +	compact.Spec.Containers = compactContainers(compact.Spec.Containers)
  +	...
  +}
  +func compactEnvVars(envVars []v1.EnvVar) []v1.EnvVar {
  +	// 仅保留 ValueFrom 指向 ConfigMapKeyRef / SecretKeyRef 的 env,字面量 Value 全部丢弃
  +}
  ```
  </details>

- **Helm 暴露 `global.nodePoolLabelKey`**:chart 把该值透传进 Config CR 的 `spec.global.nodePoolLabelKey`,服务于 KAI sharding 的节点池标签自定义(#1776/#1774)。

  <details><summary>代码依据 deployments/kai-scheduler/templates/_helpers.tpl</summary>

  ```diff
  +    {{- if .Values.global.nodePoolLabelKey }}
  +    nodePoolLabelKey: {{ .Values.global.nodePoolLabelKey | quote }}
  +    {{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- 这一批全是 scheduler 自身的**正确性 + 大规模显存韧性**打磨,延续 v0.16.x 把"大集群下调度器内存增长"当主攻方向(本期两条 perf:#1647 watch 过滤 + #1648 对象裁剪,接上一期 heap retention 优化)。证据只覆盖 cache/reclaimable 两个包的 diff,未见 GPU 分片/DRA 路径本身的改动。
- reclaim 链路正在从"整场景一把校验"细化为"逐受害者可回收性过滤"(新 `ReclaimVictimFilterFn` 钩子),意味着 KAI 的抢占决策粒度在变细;后续可能在其它插件(如 capacity/topology)上挂同类 victim-filter。证据仅 proportion 插件一处注册点,未见其它插件接入。

## 本期无实质改动(折叠)
<details>
- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — ahead=4 仅 bump/CI/merge
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=a37981bdf128ace73550200724b00958d1d1db18 branch=main release=v26.3.3 scanned=2026-06-30 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=41dd4444a23ffc387262e7159b4696fb688553a2 branch=main release=v1.19.1 scanned=2026-06-30 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f41a0200e00d232bd7e257b22600883346eea079 branch=main release=— scanned=2026-06-30 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.3 scanned=2026-06-30 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=a1c1b674b2b544f4ed60fd3f8741fc96d145b99d branch=main release=v0.4.1-rc.1 scanned=2026-06-30 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-30 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5dc3caa478807fec0fc6a2160ef9e8f056300e4e branch=main release=v0.14.2 scanned=2026-06-30 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=6ee3494ea35745bc850a285ce49d1f32a330e282 branch=main release=v0.16.1 scanned=2026-06-30 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-30 -->
