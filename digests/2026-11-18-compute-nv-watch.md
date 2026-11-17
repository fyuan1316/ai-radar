# NVIDIA 算力栈 diff 雷达 2026-11-18

> 区间说明:上一篇是 2026-11-03,中间 15 天没跑,所以这一期 base..HEAD 跨了约两周。gpu-operator(ahead=68)和 dcgm-exporter(files=300,被 API 截断)走了**大区间概览**;其余仓按深度模式读了 hunk。

## 摘要
- **dcgm-exporter 4.9.0 是一次破坏性升级**:按 DCGM 4.7 的新字段名重命名了 23 个默认/profiling 指标,其中 11 个同时换了单位(MHz→Hz、MiB→bytes、百分比→0~1 比例、mJ→J);`dcp-metrics-included.csv` 弃用,改用 `default-counters.csv`;MIG 场景下整卡级指标(功耗/温度/时钟/PCIe)改成每张物理卡只报一次。gpu-operator 已经跟进:默认采集清单切到新 CSV,OpenShift PrometheusRule 用 `新名 换算 or 旧名` 的写法兼容新旧两种指标。
- **KAI-Scheduler 发布 v0.19.0(从 v0.18.x 跨 minor)**:调度器开始"看穿"正在终止的 Pod:如果 Pod 只有等这些终止中的 Pod 释放 NUMA、DRA 设备、hostPort 或亲和性占用之后才放得下,就先 pipeline 过去,不再判为不可调度。另外把公平份额算法抽成无依赖的顶层包 `pkg/fairshare`(注释写明供模拟器、准入、UI 复用),binder 给独立 DRA ResourceClaim 补上删除保护 finalizer。
- **gpu-driver-container 把 615 驱动分支移出构建矩阵,换成 620.70.06**:620 及以上的 fabricmanager/IMEX 改装 `*-direct` 新包(RHEL 系固定 2.0.0),Ubuntu 额外装 `nvidia-driver-pinning-<ver>`。k8s-device-plugin v0.20.2 修了 MPS 子进程环境变量丢失,并收紧 `devices` 列表解析(`null` 会报错)。

## 当日重要改变
- **NVIDIA/dcgm-exporter [版本跨档][弃用/移除]** 4.8.4 → 4.9.0:默认指标改名并换单位,`dcp-metrics-included.csv` 和 `1.x-compatibility-metrics.csv` 弃用,开启 pod label 时空 allowlist 的语义从"全部 label"改为必须非空(要全部就写 `.*`)。依据是 release note(本区间是单个 squash 提交,files=300 被截断,没有逐文件读 hunk)。 https://github.com/NVIDIA/dcgm-exporter/releases/tag/4.9.0
- **NVIDIA/gpu-operator [API/CRD变更·仅生成器]** `config/crd/bases/nvidia.com_{clusterpolicies,nvidiadrivers,gpuclusters}.yaml` 都被命中,但已核实 hunk **只是 `controller-gen.kubebuilder.io/version` v0.22.0→v0.23.0**,ClusterPolicy 没有字段增删。真正的行为变化在 dcgm-exporter 4.9 适配上(见正文)。 https://github.com/NVIDIA/gpu-operator/commit/06a5bb206d7fbd56f4ef77a349dd55cf63be56c3
- **kai-scheduler/KAI-Scheduler [版本跨档]** v0.18.7 → v0.19.0(2026-11-11 发布)。helper 显示的 Release 是 v0.16.18,那是 11-15 发布的旧分支 backport,按发布时间排在了最前面。 https://github.com/kai-scheduler/KAI-Scheduler/releases/tag/v0.19.0
- **kai-scheduler/KAI-Scheduler [新能力][架构方向]** 新增顶层包 `pkg/fairshare`,proportion 插件的 `resource_division.go`(-281 行)改为调用它;另新增 `framework/terminating_pods*.go`,支持 pipeline 到终止中 Pod 占着的资源上。 https://github.com/kai-scheduler/KAI-Scheduler/pull/2572 https://github.com/kai-scheduler/KAI-Scheduler/pull/2583
- **NVIDIA/gpu-driver-container [弃用/移除]** `versions.mk` 里标注为"all active datacenter branches"的 `DRIVER_VERSIONS`,615.71.10 被移除、620.70.06 加入;`.nvidia-ci.yml` 的 `PUBLISH_VERSIONS` 只剩 620.70.06。 https://github.com/NVIDIA/gpu-driver-container/commit/1f82ec89457177b022604bbd6756183d616fa143
- **NVIDIA/k8s-device-plugin [API/CRD变更·校验收紧]** `api/config/v1/replicas.go` 的 `ReplicatedDevices.UnmarshalJSON` 现在拒绝 `null` 条目,报错里带出原始坏值。time-slicing/MPS 配置里如果有 `devices: [null]` 之类的写法,以前会被当作 GPU 0 静默放行,现在直接报错。 https://github.com/NVIDIA/k8s-device-plugin/commit/256cbd67abe89fa8a0c96d5b6070c74483cfbfdf

---

## kai-scheduler/KAI-Scheduler: a937d103 -> f348ba24
- 比较: a937d1030b1f9bca1972927f5387f2fe4b7c7051 -> f348ba24 | ahead=26 | files=150 | Release: v0.16.18(最新 minor 是 v0.19.0,见上)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/a937d1030b1f9bca1972927f5387f2fe4b7c7051...f348ba244ce9ac5cbd0858e71beb8f3ef6353279

### AI 总结重点(源码 diff 为据)
- **`Session.FittingNode` 签名和语义都改了:从返回 `bool` 改为返回 `(fits, mustPipeline)`**。真实分配时先按集群当前状态跑 `PredicateFn`,通过就直接 bind。失败时,如果 `terminatingPodsMatter` 为真(本节点有终止中 Pod,或者亲和性受它们影响),再调 `fitsWithoutTerminatingPods`,在"假设这些 Pod 已经走掉"的视图里重跑 predicate。这样放得下就返回 `mustPipeline=true`,任务只 pipeline、不 bind。模拟模式(`isSimulation`)始终在去掉终止中 Pod 的视图里检查。此前终止中 Pod 的资源虽然算作 Releasing,但它们占着的 hostPort、亲和性计数和 DRA 设备仍会让 predicate 失败,任务就被判为不可调度。(PR #2583)
  <details><summary>代码依据 pkg/scheduler/framework/session.go</summary>

  ```diff
  -func (ssn *Session) FittingNode(task *pod_info.PodInfo, node *node_info.NodeInfo, writeFittingDelta bool) bool {
  +func (ssn *Session) FittingNode(
  +	task *pod_info.PodInfo, node *node_info.NodeInfo, isSimulation bool,
  +) (fits bool, mustPipeline bool) {
  ...
  +	if !isSimulation {
  +		if currentErr = ssn.PredicateFn(task, job, node); currentErr == nil {
  +			return true, false
  +		}
  +		logPredicateFailure(task, node, currentErr)
  +		if !ssn.terminatingPodsMatter(task, node) {
  +			addNodeFitError(task, job, currentErr)
  +			return false, false
  +		}
  +	}
  +
  +	if err := ssn.fitsWithoutTerminatingPods(task, job, node); err != nil {
  ...
  +	return true, true
  ```
  </details>
- **新增 `terminatingPods` 会话级索引和 `WithoutTerminatingPods` 视图切换**。会话打开时就已处于 `Releasing`(且不是本会话驱逐的 `!IsVirtualStatus`)的 Pod 按节点建索引,带 ResourceClaim 的单独记入 `draHolders`。如果集群里有 `NodeName` 为空的 ResourceSlice(跨节点共享设备池),`terminatingPodsFor` 会把**其他节点**上的 DRA 持有者也纳入,因为共享池里的设备可以分到任何节点。视图切换的做法是:开一个临时 `Statement`,用正常驱逐路径 `Evict` 这些 Pod,跑完回调后 `Rollback(0)`。另外 `fitsWithoutTerminatingPods` 会再做一次 `IsTaskAllocationOnNodeOverCapacityFn` 复核,因为驱逐会从队列用量里扣掉这些 Pod,而它们本来就没计入队列用量,不复核的话容量检查会过于宽松。
  <details><summary>代码依据 pkg/scheduler/framework/terminating_pods.go(新增)</summary>

  ```diff
  +// terminatingPods are the pods that were already terminating when the session opened: Releasing,
  +// but not evicted by this session. Their resources already count as releasing, yet they still hold
  +// their host ports, inter-pod affinity and DRA devices until they exit.
  ...
  +	for _, slice := range ssn.ClusterInfo.ResourceSlices {
  +		if ptr.Deref(slice.Spec.NodeName, "") == "" {
  +			t.hasSharedDevicePool = true
  ...
  +	// Queue usage never counted the terminating pods, yet evicting them subtracts them, so the capacity
  +	// check inside the predicates passes too easily. Recheck it against the restored usage.
  +	if result := ssn.IsTaskAllocationOnNodeOverCapacityFn(task, job, node); !result.IsSchedulable {
  ...
  +	stmt := ssn.Statement()
  +	for _, pod := range pods {
  +		if !isTerminating(pod) { continue }
  +		if err := stmt.Evict(pod, "", eviction_info.EvictionMetadata{}); err != nil {
  ...
  +	fn()
  +	if err := stmt.Rollback(0); err != nil {
  ```
  </details>
- **分配路径按 `mustPipeline` 分流,`isPipelineOnly` 拆成两个含义**。`allocateTaskToNode` 在 `mustPipeline` 时把 NUMA 放置和分数 GPU 选卡都放进 `WithoutTerminatingPods` 视图里执行,保证放置和检查用的是同一个视图。能否 bind 的条件从 `!isPipelineOnly && IsTaskAllocatable` 收紧为 `!isSimulation && !mustPipeline && IsTaskAllocatable`。`Statement.Pipeline` 的第三个参数从 `updateTaskIfExistsOnNode` 改名为 `canUndoEviction`,而且**语义取反**:`ConvertAllAllocatedToPipelined` 和 redo 处原来传 `true`,现在传 `false`(#2569 重命名)。分数 GPU 路径变成 `isPipelineOnly := mustPipeline || gpuForSharing.IsReleasing`。
  <details><summary>代码依据 pkg/scheduler/actions/common/allocate.go / framework/statement.go</summary>

  ```diff
  -		if !ssn.FittingNode(task, node, !isPipelineOnly) {
  +		fits, mustPipeline := ssn.FittingNode(task, node, isSimulation)
  +		if !fits {
  ...
  +	ssn.WithoutTerminatingPods(task, node, func() {
  +		success = placeTaskOnNode(ssn, stmt, task, node, isSimulation, mustPipeline)
  +	})
  ...
  -	if taskAllocatable := node.IsTaskAllocatable(task); !isPipelineOnly && taskAllocatable {
  +	if canBind := !isSimulation && !mustPipeline && node.IsTaskAllocatable(task); canBind {

  -	if foundOnNode && !updateTaskIfExistsOnNode && !gpuPlacementChanged && !numaPlacementChanged {
  +	if foundOnNode && canUndoEviction && !gpuPlacementChanged && !numaPlacementChanged {
  ```
  </details>
- **新增 `SessionClaimTracker`,给 DRA 已分配设备做引用计数**。注释指出,上游 `ResourceClaimTracker` 的已分配集合不计数:两个 claim 共用一台设备时,un-assume 其中一个就会把设备整体移出已分配集合,即使另一个 claim 还占着。新 tracker 按 `DeviceID → holders` 建索引,在 `GatherAllocatedState` / `ListAllAllocatedDevices` 之后把仍有持有者的共享设备补回去。上面"临时驱逐再回滚"的模拟要在 DRA 场景下正确运行,依赖的就是这一层。
  <details><summary>代码依据 pkg/common/k8s_utils/session_claim_tracker.go(新增,hunk 截断)</summary>

  ```diff
  +// SessionClaimTracker indexes, per dedicated device, the claims allocated to it. The upstream
  +// allocated set is not reference counted: un-assuming one of two claims allocated to a device
  +// drops the device although the other claim still holds it.
  ...
  +func (t *SessionClaimTracker) GatherAllocatedState() (*structured.AllocatedState, error) {
  +	state, err := t.ResourceClaimTracker.GatherAllocatedState()
  ...
  +	t.insertHeldSharedDevices(state.AllocatedDevices)
  ```
  </details>
- **公平份额算法抽成无依赖的顶层包 `pkg/fairshare`**。`fairshare.Divide(total, kValue, queues)` 分两步:先按 deserved 分配(`min(deserved, min(MaxAllowed, Request))`,`-1` 表示 Unlimited),剩余部分再由 `DivideOverQuota` 按优先级从高到低、同优先级内按 OverQuotaWeight 分配,取整留下的零头按优先级逐个单位发放。`resource_division.setResourceShare` 现在只负责把 `QueueAttributes` 转成 `fairshare.Queue`、调用 `Divide`,再通过 `SetFairShare` 写回结果(写回时会让缓存失效)。包注释直接写明了外部复用的用途。
  <details><summary>代码依据 pkg/fairshare/fairshare.go(新增)/ resource_division.go</summary>

  ```diff
  +// Package fairshare divides one resource between queues the way the scheduler's proportion plugin does: deserved
  +// quota first, then the over-quota remainder by priority and weight. It has no dependencies, so tools that need to
  +// predict the scheduler's fair share (simulators, admission or UI services) can use the scheduler's own code.
  ...
  +func Divide(total, kValue float64, queues []*Queue) (remaining float64) {
  +	remaining = setDeservedResource(total, queues)
  +	if remaining <= 0 {
  +		return 0
  +	}
  +	return DivideOverQuota(remaining, kValue, queues)
  +}

  -	remainingAmount := setDeservedResource(totalAmount, queues, resourceName)
  -	if remainingAmount > 0 {
  -		remainingAmount = divideOverQuotaResource(remainingAmount, kValue, queues, resourceName)
  +	fq, attributes := toFairshareQueues(queues, resourceName)
  +	remaining := fairshare.Divide(totalAmount, kValue, fq)
  +	storeFairShare(fq, attributes, resourceName)
  ```
  </details>
- **请求计算接入 Pod 级资源(KEP-2837)**。`getPodResourceRequest` 从 `AggregateContainerRequests`(只累加容器级 request)改为 `PodRequests(..., ExcludeOverhead: true)`,Pod 级 `spec.resources` 会被计入,RuntimeClass overhead 仍然排除。in-place resize 的准入校验 `podResizeDelta` 也做了同样替换,和 11-03 那期落地的 deferred resize 口径对齐。(PR #2456)
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
  -	reqs := resourcehelpers.AggregateContainerRequests(pod, resourcehelpers.PodResourcesOptions{
  +	reqs := resourcehelpers.PodRequests(pod, resourcehelpers.PodResourcesOptions{
   		UseStatusResources: true,
  +		ExcludeOverhead:    true,
   	})
  ```
  </details>
- **binder 在 `bindResourceClaim` 中给 ResourceClaim 补 `resourceapi.Finalizer`**。claim 上没有这个 finalizer 时,先单独 `Update` 写入,再走 `UpdateStatus`(注释说明 UpdateStatus 改不了 finalizer)。之前 KAI 自己绑定的独立 claim 缺少这个 finalizer,控制器就无法回收没用上的分配。(PR #2591)
  <details><summary>代码依据 pkg/binder/plugins/k8s-plugins/dynamicresources/dra.go</summary>

  ```diff
  +		// The controller needs this finalizer to release unused allocations.
  +		// Persist it before UpdateStatus, which cannot update finalizers.
  +		if !slices.Contains(claim.Finalizers, resourceapi.Finalizer) {
  +			claim.Finalizers = append(claim.Finalizers, resourceapi.Finalizer)
  +			claim, err = drp.client.ResourceV1().ResourceClaims(pod.Namespace).Update(ctx, claim, metav1.UpdateOptions{})
  ```
  </details>
- **拓扑插件 `lowestCommonDomainID` 在 required level 处停止下钻**。原先只在 preferred level(`leastCommonLevel`)停止,如果 required level 比 job 的最低公共域更高,域会被算得过低,导致 required 约束检查用错子树的空闲资源。(PR #2594)
  <details><summary>代码依据 pkg/scheduler/plugins/topology/common.go</summary>

  ```diff
  -		if leastCommonLevel == level.NodeLabel {
  +		if leastCommonLevel == level.NodeLabel || topologyConstraint.RequiredLevel == level.NodeLabel {
  ```
  </details>
- **operator / binder 两处修正**:operator 的 informer cache 由 `ByObject` 白名单(只限 Pod/Lease/EndpointSlice 在 KAI 命名空间)改为 `DefaultNamespaces` 默认把所有命名空间级资源限定在 KAI 命名空间,只豁免 `ServiceAccount` 全局缓存,目的是让 operator 内存不再随集群规模线性增长(PR #2676)。binder 的 reservation pod 资源改为在 `NewService` 启动时 `DeepCopy` 后剔除 `nvidia.com/gpu`,不再每次创建 Pod 时 `delete` 共享配置对象(PR #2557)。
  <details><summary>代码依据 cmd/operator/app/app.go / resource_reservation.go</summary>

  ```diff
  +		DefaultNamespaces: map[string]cache.Config{
  +			namespace: {},
  +		},
  +		ByObject: map[client.Object]cache.ByObject{
  +			&corev1.ServiceAccount{}: {
  +				Namespaces: map[string]cache.Config{ cache.AllNamespaces: {} },

  -		podResources:                        podResources,
  +		podResources:                        withoutGPUResource(podResources),
  ```
  </details>

### 后续发展方向 [AI]
- **"抢占/回收后要等多久才能调度"这段空窗在被压缩**。终止中 Pod 视图、DRA 引用计数、claim finalizer 三处改动指向同一个目标:被驱逐的 Pod 还在优雅退出时,新任务就能先预订它的 GPU/DRA 设备和 NUMA 区,不用等它彻底消失后再走下一轮调度。11-03 那期的 deferred resize 也是同一类"让 pending 语义更精确"的工作。证据只覆盖 framework/allocate/binder 的 hunk,`reclaim_releasing_*` 和 `allocate_*_releasing_test.go` 只看了文件名,没有读。
- **DRA 跨节点共享设备池(`ResourceSlice.Spec.NodeName==""`)已经被 KAI 当作一等场景处理**,这和 NVLink/IMEX 域级设备(如 ComputeDomain)的方向一致。证据是 `hasSharedDevicePool` 分支;这一期 dra-driver-nvidia-gpu 本身没有提交,看不到两边的联动改动。
- **`pkg/fairshare` 对外开放,意味着 KAI 想让队列配额可以在调度器外部预测**(包注释点名了模拟器、准入、UI)。可以预期后续会出现 quota 模拟或 what-if 类工具。证据只有包注释和这次纯重构的 diff,还没有看到调用方。

---

## NVIDIA/gpu-driver-container: c9baa54d -> 3ac67962
- 比较: c9baa54d84c1e41c1c5ba3af82676fc7f0b0549d -> 3ac67962 | ahead=26 | files=38 | Release: —
- compare: https://github.com/NVIDIA/gpu-driver-container/compare/c9baa54d84c1e41c1c5ba3af82676fc7f0b0549d...3ac6796228bda663fef350bda0f768d1bc5b35da
- 关键提交: https://github.com/NVIDIA/gpu-driver-container/commit/1f82ec89457177b022604bbd6756183d616fa143

### AI 总结重点(源码 diff 为据)
- **活跃数据中心驱动分支轮换:615 下线,620 上线**。`versions.mk` 的 `DRIVER_VERSIONS`(注释为"latest version in all active datacenter branches")、`.common-ci.yml` 的所有矩阵(含 ubuntu26.04、rhel10)以及 GitHub `image.yaml` 都把 `615.71.10` 换成了 `620.70.06`。`.nvidia-ci.yml` 的 `PUBLISH_VERSIONS` 从三个版本收窄为只剩 `620.70.06`(可能只是本次发版的单次发布集合,需要下次复核)。
  <details><summary>代码依据 versions.mk / .nvidia-ci.yml</summary>

  ```diff
   # DRIVER_VERSIONS contains latest version in all active datacenter branches
  -DRIVER_VERSIONS ?= 580.196.07 595.112.07 615.71.10
  +DRIVER_VERSIONS ?= 580.196.07 595.112.07 620.70.06

  -  PUBLISH_VERSIONS: 580.196.07 595.112.07 615.71.10
  +  PUBLISH_VERSIONS: 620.70.06
  ```
  </details>
- **620 起 fabricmanager / IMEX 换成 `*-direct` 新包,并引入驱动版本 pinning 包**。在 ubuntu22.04/24.04 和 rhel8/9/10 的 `install.sh` 中,`fabricmanager_install` 和 `imex_install` 加了 `DRIVER_BRANCH >= 620` 分支:不再装与驱动同版本号的 `nvidia-fabricmanager=${DRIVER_VERSION}` / `nvidia-imex=${DRIVER_VERSION}`,改装 `nvidia-fabricmanager-direct(-dev/-devel)`、`nvidia-imex-direct`,同时单独锁定 `libnvidia-fmdrv` / `libnvidia-imex`。RHEL 把 direct 包版本固定为 `2.0.0`、lib 跟随驱动版本;Ubuntu 在 `extra_pkgs_install` 里额外装 `nvidia-driver-pinning-${DRIVER_VERSION}`。由此可见,从 620 开始 FM/IMEX 用户态和驱动版本号**解耦**,只有 lib 层随驱动走。
  <details><summary>代码依据 rhel9/install.sh(rhel8/10 相同)/ ubuntu24.04/install.sh</summary>

  ```diff
   fabricmanager_install() {
  +  if [ "${DRIVER_BRANCH}" -ge "620" ]; then
  +    local fabricmanager_direct_version="2.0.0"
  +    dnf install -y "nvidia-fabricmanager-direct-${fabricmanager_direct_version}*" "nvidia-fabricmanager-direct-devel-${fabricmanager_direct_version}*" "libnvidia-fmdrv-${DRIVER_VERSION}"
  +    dnf versionlock add nvidia-fabricmanager-direct nvidia-fabricmanager-direct-devel libnvidia-fmdrv
  +    return 0
  +  fi
  ...
   imex_install() {
  +  if [ "${DRIVER_BRANCH}" -ge "620" ]; then
  +    apt-get install -y --no-install-recommends nvidia-imex-direct
  +    apt-mark hold nvidia-modprobe nvidia-imex-direct libnvidia-imex1
  +    return 0
  +  fi
  ...
  +      if [ "${DRIVER_BRANCH}" -ge "620" ]; then
  +        apt-get install -y --no-install-recommends "nvidia-driver-pinning-${DRIVER_VERSION}"
  +      fi
  ```
  </details>
- **OS 底座例行刷新**:Rocky 9.8→9.9-ubi、10.2→10.3-ubi;vgpu-manager 的 rhel10 基础镜像 UBI 10.2→10.3,ubuntu24.04 基础镜像 CUDA 13.4.3→13.5.0;Ubuntu jammy/noble/resolute 基础镜像日期 tag 更新。OS 矩阵没有增删。
  <details><summary>代码依据 Makefile / vgpu-manager/*/Dockerfile</summary>

  ```diff
  -build-rocky9%: DOCKER_BUILD_ARGS = --build-arg BASE_IMAGE=rockylinux/rockylinux:9.8-ubi
  +build-rocky9%: DOCKER_BUILD_ARGS = --build-arg BASE_IMAGE=rockylinux/rockylinux:9.9-ubi
  -FROM registry.access.redhat.com/ubi10/ubi:10.2-1792744468
  +FROM registry.access.redhat.com/ubi10/ubi:10.3-1794519911
  ```
  </details>

### 后续发展方向 [AI]
- 620 分支是 NVLink 域管理(FM/IMEX)打包方式的分界点。下游 gpu-operator 的 driver 状态机或 NVIDIADriver CR 后续可能需要适配 `*-direct` 包和 IMEX 版本解耦。这一期 gpu-operator 的 hunk 里还没有看到对应改动(概览模式,证据有限)。
- 615 是短生命周期分支,被移出构建矩阵后,预编译镜像的支持面变成 580/595/620 三条线。

---

## NVIDIA/nvidia-container-toolkit: f18b5791 -> 07b6bee0
- 比较: f18b57912a20e967c5f045475f512191d24ef821 -> 07b6bee0 | ahead=14 | files=21 | Release: v1.20.2(11-17 发布,v1.20.1 → v1.20.2 是 patch 版)
- compare: https://github.com/NVIDIA/nvidia-container-toolkit/compare/f18b57912a20e967c5f045475f512191d24ef821...07b6bee0b6e45ed5848375aa6ab613353e8d3fb6

### AI 总结重点(源码 diff 为据)
- **toolkit 安装失败时不再清掉现有安装**。`os.RemoveAll(toolkitRoot)` 从 `toolkit.Installer.Install` 开头(早于收集库文件和可执行文件)移到 `ToolkitInstaller.Install` 内部,在 `executables` 收集成功、真正写文件之前才执行。原来的行为是:先删旧安装,后面收集库时失败(如 `failed to collect libraries`),节点上就既没有旧 runtime 也没有新 runtime。新增测试 `TestInstallFailureKeepsExistingInstallation` 锁定了"失败后旧 `nvidia-container-runtime` 原样保留"。这对 gpu-operator 滚动升级 toolkit DaemonSet 时的节点可用性有直接影响。 https://github.com/NVIDIA/nvidia-container-toolkit/commit/7660c77b8f143b876fc760874186ac1363d63b14
  <details><summary>代码依据 cmd/nvidia-ctk-installer/toolkit/{toolkit.go,installer/installer.go}</summary>

  ```diff
  # toolkit.go
  -	t.logger.Infof("Removing existing NVIDIA container toolkit installation")
  -	err := os.RemoveAll(t.toolkitRoot)
  -	if err != nil && !opts.ignoreErrors {
  -		return fmt.Errorf("error removing toolkit directory: %v", err)
  # installer.go(在 installers = append(installers, executables...) 之后)
  +	t.logger.Infof("Removing existing NVIDIA container toolkit installation")
  +	if err := os.RemoveAll(destDir); err != nil {
  +		if !t.ignoreErrors {
  +			return fmt.Errorf("error removing toolkit directory: %v", err)
  ```
  </details>
- **Docker `AddRuntime(setAsDefault=false)` 现在会清除指向自己的 `default-runtime`**。之前只在 `setAsDefault=true` 时写入 `default-runtime`,从来不清除,所以把 nvidia 从默认改回非默认后,`daemon.json` 里还残留 `"default-runtime":"nvidia"`。 https://github.com/NVIDIA/nvidia-container-toolkit/commit/07fdb2dd41878c31e4c96bd810e01e530f104acf
  <details><summary>代码依据 pkg/config/engine/docker/docker.go</summary>

  ```diff
   	if setAsDefault {
   		config["default-runtime"] = name
  +	} else if defaultRuntime, ok := config["default-runtime"].(string); ok && defaultRuntime == name {
  +		delete(config, "default-runtime")
   	}
  ```
  </details>
- **文档更正了 CDI 默认设备名**:`nvidia-ctk cdi generate` 默认生成 `nvidia.com/gpu={INDEX}`、`{GPU}:{MIG}`、`{UUID}` 三类名字;旧文档写的 `gpu0` / `mig0:0` 只在 `--device-name-strategy=type-index` 下才会生成。这只是文档修正,代码行为没变。
  <details><summary>代码依据 cmd/nvidia-ctk/README.md</summary>

  ```diff
  -* An `nvidia.com/gpu=gpu{INDEX}` device for each non-MIG-enabled full GPU in the system
  +* An `nvidia.com/gpu={INDEX}` device for each non-MIG-enabled full GPU in the system
  +* An `nvidia.com/gpu={UUID}` device for each full GPU or MIG-device, using its GPU or MIG UUID
  ```
  </details>

### 后续发展方向 [AI]
- 这一期都是安装器健壮性方面的收口,没有 CDI 或 runtime hook 的能力变化。证据覆盖了全部非 CI 代码 hunk。

---

## NVIDIA/k8s-device-plugin: 5699a52c -> 69439afc
- 比较: 5699a52c7d3197f2ee105e19661e6063596d3c33 -> 69439afc | ahead=12 | files=27 | Release: v0.20.2(patch 版)
- compare: https://github.com/NVIDIA/k8s-device-plugin/compare/5699a52c7d3197f2ee105e19661e6063596d3c33...69439afcc740f6ea85a9f7f5a449c93e395deb73

### AI 总结重点(源码 diff 为据)
- **MPS control daemon 的子进程开始继承父进程环境**。`Daemon.Start()` 和 `EchoPipeToControl()` 里 `exec.Command` 的 `Env` 原来是 `append(mpsDaemon.Env, ...)`;`Env` 初始为 nil,结果子进程**只拿到**几个 `CUDA_MPS_*` 变量,连 `PATH` 都没有,`nvidia-cuda-mps-control` 按名字找 `nvidia-cuda-mps-server` 时就会失败。现在改为 `slices.Concat(mpsDaemon.Environ(), d.EnvVars().toSlice())`:继承完整环境,daemon 自己的 `CUDA_MPS_PIPE_DIRECTORY/LOG_DIRECTORY` 追加在后面并覆盖父进程的旧值。新增的 `daemon_test.go` 用假二进制同时验证了"PATH 被继承"和"stale 变量被覆盖"。 https://github.com/NVIDIA/k8s-device-plugin/commit/98826e588a29f45af7dcdcb93b65ff274e3daf07
  <details><summary>代码依据 cmd/mps-control-daemon/mps/daemon.go</summary>

  ```diff
   	mpsDaemon := exec.Command(mpsControlBin, "-d")
  -	mpsDaemon.Env = append(mpsDaemon.Env, d.EnvVars().toSlice()...)
  +	mpsDaemon.Env = slices.Concat(mpsDaemon.Environ(), d.EnvVars().toSlice())
  ```
  </details>
- **`ReplicatedDevices.UnmarshalJSON` 拒绝 `null`,报错带原文**。用 `*uint64` 接收数字:JSON `null` 能反序列化成功但指针为 nil,原来这种情况会被当成 index 0(即 GPU 0)静默接受,现在会落到报错分支。报错信息从 `unsupported type ...: %v, %T` 改为 `unsupported entry in devices list: <原始 JSON>`,测试覆盖了 `null`、`true`、`1.5`、`{"a":1}`、`[0, null]`。这会影响 time-slicing/MPS 的 `sharing.*.resources[].devices` 配置校验。 https://github.com/NVIDIA/k8s-device-plugin/commit/256cbd67abe89fa8a0c96d5b6070c74483cfbfdf
  <details><summary>代码依据 api/config/v1/replicas.go</summary>

  ```diff
  -			var index uint64
  -			if err = json.Unmarshal(s, &index); err == nil {
  -				result[i] = ReplicatedDeviceRef(strconv.FormatUint(index, 10))
  +			var index *uint64
  +			if err = json.Unmarshal(s, &index); err == nil && index != nil {
  +				result[i] = ReplicatedDeviceRef(strconv.FormatUint(*index, 10))
  ...
  -			return fmt.Errorf("unsupported type for device in devices list: %v, %T", item, item)
  +			return fmt.Errorf("unsupported entry in devices list: %v", string(s))
  ```
  </details>
- **v0.20.2 发版**:CHANGELOG 列出 go-nvml 升到 v0.13.4-1 并新增 `device.GetArchitecture` 支持(#2138)、MPS 版本比较简化并去掉 `golang.org/x/mod`(#2141)、改用上游 BusyBox 镜像(#2136)、toolkit 升到 v1.20.2。这几条的代码不在本区间,只依据 CHANGELOG 列出。

### 后续发展方向 [AI]
- 经典 device-plugin 只在修 MPS 和 time-slicing 配置面的健壮性,没有新的共享模式,和"共享/分片能力往 DRA 迁"的判断一致。证据边界:这一期 dra-driver-nvidia-gpu 没有提交,无法对比 DRA 侧的进展。

---

## NVIDIA/gpu-operator: 1fb59b09 -> 246a9ca6(大区间概览,未逐文件读代码)
- 比较: 1fb59b09d022001a4fea575fce2355e7a126e0e5 -> 246a9ca6 | ahead=68 | files=300(被 API 截断)| Release: v26.7.2
- compare: https://github.com/NVIDIA/gpu-operator/compare/1fb59b09d022001a4fea575fce2355e7a126e0e5...246a9ca660db6e2e5f136346203be055afff7d4f

### 方向主题(据实质提交标题 + 热点目录聚类)
1. **跟进 dcgm-exporter 4.9.0 / DCGM 4.7 字段名**(06a5bb20)。热点目录 `assets/state-dcgm-exporter`、`manifests/state-dcgm-exporter`。这是信号文件,**额外抽读了 hunk**:
   - 默认采集清单 `DCGM_EXPORTER_COLLECTORS` 从 `dcp-metrics-included.csv` 换成 `default-counters.csv`;去掉 liveness/readiness 的 `initialDelaySeconds: 45`,改用 `startupProbe`(5s×60,最多 5 分钟),适配多卡大指标文件冷启动慢的情况。
   - OpenShift `PrometheusRule` 的 `accelerator_*` 记录规则改成"新名并换回旧单位 `or` 旧名",对外暴露的 series 单位保持不变(百分比、MiB、MHz),兼容滚动升级、固定在 4.8.x 的 exporter 以及自定义 CSV。
  <details><summary>代码依据 assets/state-dcgm-exporter/{0800_daemonset.yaml,1000_prometheus_rule_openshift.yaml}</summary>

  ```diff
  -          value: "/etc/dcgm-exporter/dcp-metrics-included.csv"
  +          value: "/etc/dcgm-exporter/default-counters.csv"
  +        startupProbe:
  +          httpGet: { port: 9400, path: /health }
  +          periodSeconds: 5
  +          failureThreshold: 60
  ...
  -      expr: DCGM_FI_DEV_GPU_UTIL
  +      expr: (DCGM_FI_DEV_GPU_UTIL_RATIO * 100) or DCGM_FI_DEV_GPU_UTIL
  -      expr: DCGM_FI_DEV_FB_TOTAL
  +      expr: (DCGM_FI_DEV_FB_CAPACITY_BYTES / 1048576) or DCGM_FI_DEV_FB_TOTAL
  -      expr: DCGM_FI_DEV_SM_CLOCK
  +      expr: (DCGM_FI_DEV_SM_CLOCK_HERTZ / 1000000) or DCGM_FI_DEV_SM_CLOCK
  ```
  </details>
2. **NVIDIADriver / 驱动 DaemonSet 生命周期修复**:"Fix driver DaemonSet deletion during ownership migration"(58a2202b)、"Honor spec.gds.imagePullPolicy in NVIDIADriver DaemonSet"(6baaf845)、"Filter DaemonSet watch updates to readiness changes"(热点 `controllers/predicate`)。这几条只有标题,没读 hunk。
3. **CRD**:三个 CRD yaml 都被命中,核实后只是 controller-gen 注解 v0.22.0→v0.23.0;在截断后的 300 个文件里**没有** `api/nvidia/v1/clusterpolicy_types.go`。
4. **e2e 测试迁移到 Ginkgo 并跑前向兼容**(热点 `tests/e2e` 30 个文件),再加上 triage 和 backport 签名等治理改动。

### 后续发展方向 [AI]
- operator 处理指标破坏性变更的方式是:在 recording rule 层吸收单位变化,让外部看到的契约保持稳定。只有 OpenShift 规则这样做了,vanilla Helm 的 ServiceMonitor 等部署方式是否有同样的兼容层,这次没有看到(概览模式,证据有限)。

---

## NVIDIA/dcgm-exporter: fafd1511 -> 4e663a52(大区间概览,未逐文件读代码)
- 比较: fafd151148052628061a80450b4ee037a5fa0c3c -> 4e663a52 | ahead=1 | files=300(被 API 截断)| Release: 4.9.0
- 单个 squash 提交 "feat: release DCGM-Exporter 4.9.0 (#768)",热点目录 `internal/e2e`(143)、`deployment/templates`(15)、`build/toolchains`、`hack/*`。**以下结论全部依据 release note,不是代码 hunk**: https://github.com/NVIDIA/dcgm-exporter/releases/tag/4.9.0

### 方向主题(依据 release note)
1. **指标契约破坏性变更**:按 DCGM 4.7 新名重命名 23 个默认/profiling 字段,其中 11 个换单位;驱动版本 label `DCGM_FI_DRIVER_VERSION` 改为 `DCGM_FI_SYSTEM_DRIVER_VERSION`;默认新增采集 `DCGM_FI_DEV_FB_CAPACITY_BYTES`;`dcp-metrics-included.csv` 和 `1.x-compatibility-metrics.csv` 弃用,使用时启动打告警。Pod 级的 `DCGM_FI_DEV_GPU_UTIL_RATIO` 可以超过 1.0(多进程利用率累加)。
2. **MIG 语义修正**:整卡级字段(功耗、温度、时钟、PCIe)在监控 MIG 实例时只按物理卡报一次,不再带 MIG label,跨实例求和也不会重复计数;XID 按 MIG GI/CI/父卡分别报告;镜像设置 `NVIDIA_MIG_MONITOR_DEVICES=all`,补齐 MIG 卡的 PCIe/DRAM profiling 指标(4.8.4 下是空的)。
3. **DRA 和 IMEX 可观测性**:DRA 与 vGPU 映射同时开启时保留未分配 GPU 的指标;GPU 的 pod label 不再打到 CPU/NVSwitch 指标上;新增 IMEX 域恢复 health code,以及可选的 `DCGM_EXP_SYSTEM_HEALTH_STATUS`(需要 DCGM 4.7.1,镜像内置的 4.7.0 不支持)。
4. **Enrichment 语义收紧**:Kubernetes/container/DRA/HPC label 开关支持 `true/false/auto`;开启 pod label 时 allowlist 必须非空(以前空 allowlist 表示全部);Prometheus label 名冲突时加 `_conflictN` 后缀。

### 后续发展方向 [AI]
- DCGM 指标正在统一为 SI 单位(Hz/bytes/秒/0~1 比例)。所有基于 `DCGM_FI_DEV_*` 的告警、HPA 和计费口径,升级 4.9 时都需要逐条迁移。从 MIG 去重和 DRA label 的改动看,exporter 正在把"物理卡 / MIG 实例 / DRA claim"三层归属理清楚。证据边界:只读了 release note,没有核对代码。

---

## 本期无实质改动(折叠)
- kubernetes-sigs/dra-driver-nvidia-gpu:e775fdb6 无新提交
- NVIDIA/DCGM:9fae2867 无新提交
- NVIDIA/mig-parted:080132489 -> ea1cf1d0。helper 没有判为 EMPTY,但人工核实全部是 triage 治理、依赖升级(k8s.io、x/net 修 CVE、go 1.27.4、CUDA 13.5.0 基础镜像)和 v0.15.2 patch 发版,没有功能代码改动。 https://github.com/NVIDIA/mig-parted/compare/080132489de972ec5f7ae63be2150931c02aa79b...ea1cf1d0bab07cd430c1568667c9c6f69a06ca14
- 跨仓治理信号(不算功能变化):gpu-operator、container-toolkit、driver-container、device-plugin、mig-parted 同期引入同一套 triage 流程:外部 PR 必须先有 `accepted` 且已指派的 issue,新增 `/assign` 工作流和 AI 使用规范。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=246a9ca660db6e2e5f136346203be055afff7d4f branch=main release=v26.7.2 scanned=2026-11-18 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=07b6bee0b6e45ed5848375aa6ab613353e8d3fb6 branch=main release=v1.20.2 scanned=2026-11-18 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=3ac6796228bda663fef350bda0f768d1bc5b35da branch=main release=— scanned=2026-11-18 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=69439afcc740f6ea85a9f7f5a449c93e395deb73 branch=main release=v0.20.2 scanned=2026-11-18 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=e775fdb63e593a121b40fc1cc4c9a9c89955e635 branch=main release=v0.5.1 scanned=2026-11-18 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-18 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=ea1cf1d0bab07cd430c1568667c9c6f69a06ca14 branch=main release=v0.15.2 scanned=2026-11-18 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f348ba244ce9ac5cbd0858e71beb8f3ef6353279 branch=main release=v0.16.18 scanned=2026-11-18 -->
