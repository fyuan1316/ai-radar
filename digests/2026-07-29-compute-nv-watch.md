# NVIDIA 算力栈 diff 雷达 2026-07-29

## 摘要
- **gpu-operator 收紧 NVIDIADriver 的三处校验/兼容边界**:①多个 default NVIDIADriver 并存时 validator 直接报错并把 CR 条件改成 `ReconcileFailed`(而非原来的 `ConflictingNodeSelector`),语义更准;②`ImagePath` 对残缺 image spec(repository/image/version 任一为空)快速失败,防止部分 CR 字段被环境变量"救回"拼出错误镜像;③OS 镜像 tag 矩阵新增 Oracle Linux(`ol`),与 rocky/rhel 一样省略次版本号。
- **KAI-Scheduler 给抢占路径做性能优化**:把 victim 候选集的发现(过滤)与队列构建拆开,新增 `NewCachedVictimsQueueGenerator`——候选集在多次 scenario 探测间只发现一次、每次返回全新可变队列,应用到 reclaim/preempt/无限候选 consolidation 三条 action,避免每轮重复过滤全量 PodGroup。
- 其余 7 仓(nvidia-container-toolkit / gpu-driver-container / dra-driver-nvidia-gpu / dcgm-exporter / DCGM 无新提交,k8s-device-plugin / mig-parted 仅 bump/CI)无实质代码改动,保锚点。

## 当日重要改变
- NVIDIA/gpu-operator [修复] 多个 default NVIDIADriver 并存时,validator 返回 `ErrMultipleDefaultNVIDIADrivers`,reconciler 把条件原因从 `ConflictingNodeSelector` 改为 `ReconcileFailed` https://github.com/NVIDIA/gpu-operator/pull/2678
- NVIDIA/gpu-operator [修复] `ImagePath` 拒绝残缺 image spec(repository/image/version 任一空即报错),阻断环境变量兜底拼出错误镜像 https://github.com/NVIDIA/gpu-operator/pull/2682
- NVIDIA/gpu-operator [新能力] driver 容器 OS tag 矩阵新增 Oracle Linux(`ol`),与 rocky/rhel 同样省略 minor 版本 https://github.com/NVIDIA/gpu-operator/pull/2687
- kai-scheduler/KAI-Scheduler [新能力] 新增 `NewCachedVictimsQueueGenerator`,victim 候选集跨 scenario 探测缓存一次,应用于 reclaim/preempt/consolidation https://github.com/kai-scheduler/KAI-Scheduler/pull/1862

## NVIDIA/gpu-operator: 7adc442d -> f3f9415b
- 比较: https://github.com/NVIDIA/gpu-operator/compare/7adc442d10bc102f39d1ca04cac9f5cc45633a5f...f3f9415b6e4f406b99bb7a8c4b6558b52ee71c17 | ahead=8 | files=17 | Release: v26.3.3

### AI 总结重点(源码 diff 为据)

- **多个 default NVIDIADriver 并存的状态语义修正**:`nodeSelectorValidator.Validate` 新增逻辑——遍历所有 NVIDIADriver,收集 `IsDefault() && !HasDeletionTimestamp()` 的名字到 `defaultDriverNames`,超过 1 个时返回哨兵错误 `ErrMultipleDefaultNVIDIADrivers`(附排序后的名字列表)。配套 `nvidiadriver_controller.go` 的 `Reconcile`:校验失败时若 `errors.Is(err, ErrMultipleDefaultNVIDIADrivers)`,把条件原因从默认的 `ConflictingNodeSelector` 换成 `ReconcileFailed`——即"多 default"不再被误报成节点选择器冲突,而是明确的 reconcile 失败。
  <details><summary>代码依据 internal/validator/validator.go</summary>

  ```diff
  +var ErrMultipleDefaultNVIDIADrivers = errors.New("multiple default NVIDIADrivers found")
  ...
  +	defaultDriverNames := []string{}
  	for _, driver := range drivers.Items {
  		if err := driver.ValidateNodeSelector(); err != nil {
  			return err
  		}
  +		if driver.IsDefault() {
  +			if !driver.HasDeletionTimestamp() {
  +				defaultDriverNames = append(defaultDriverNames, driver.Name)
  +			}
  +		}
  +	}
  +	if len(defaultDriverNames) > 1 {
  +		sort.Strings(defaultDriverNames)
  +		return fmt.Errorf("%w: %v", ErrMultipleDefaultNVIDIADrivers, defaultDriverNames)
  +	}
  ```
  </details>
  <details><summary>代码依据 controllers/nvidiadriver_controller.go</summary>

  ```diff
  -		if condErr := r.conditionUpdater.SetConditionsError(ctx, instance, conditions.ConflictingNodeSelector, err.Error()); condErr != nil {
  +		conditionReason := conditions.ConflictingNodeSelector
  +		if errors.Is(err, validator.ErrMultipleDefaultNVIDIADrivers) {
  +			conditionReason = conditions.ReconcileFailed
  +		}
  +		if condErr := r.conditionUpdater.SetConditionsError(ctx, instance, conditionReason, err.Error()); condErr != nil {
  ```
  </details>

- **`ImagePath` 拒绝残缺镜像规格**:`internal/image/image.go` 与 `api/nvidia/v1/clusterpolicy_types.go` 中同名 `imagePath/ImagePath` 的非 kbld 分支(repository/image/version 显式给定时)新增前置校验——三者任一为空即返回 `invalid image specification` 错误,而非继续拼串。测试点明意图:即使设置了 `DRIVER_IMAGE` 环境变量,残缺的 CR spec 也不能被环境值"救回"(fail fast)。注意:命中的 `clusterpolicy_types.go` 改的是镜像拼接 helper 函数,**非新增/删除 CRD 字段**,不构成 CRD schema 变更。
  <details><summary>代码依据 internal/image/image.go</summary>

  ```diff
  	} else {
  +		if repository == "" || image == "" || version == "" {
  +			return "", fmt.Errorf("invalid image specification: repository, image and version must all be set (repository=%s, image=%s, version=%s)", repository, image, version)
  +		}
  		// use @ if image digest is specified instead of tag
  		if strings.HasPrefix(version, "sha256:") {
  ```
  </details>

- **driver 容器 OS tag 矩阵纳入 Oracle Linux**:`internal/state/nodepool.go` 的 `getOSTag` 与 `controllers/state_manager.go` 的 `getGPUNodeOSInfo` 两处 switch 都把 `ol` 加入"省略 minor 版本"的分支(原仅 `rocky`、`rhel`)——即 Oracle Linux 节点构造 driver 镜像 tag 时只取主版本号,与 RHEL/Rocky 对齐,预编译/OS 镜像矩阵新增一个受支持发行版。
  <details><summary>代码依据 internal/state/nodepool.go</summary>

  ```diff
  -	// If the OS is RockyLinux or RHEL, we will omit the minor version when constructing the os image tag
  +	// If the OS is RockyLinux, Oracle Linux or RHEL, we will omit the minor version when constructing the os image tag
  	switch osRelease {
  -	case "rocky", "rhel":
  +	case "ol", "rocky", "rhel":
  		osTagSuffix = strings.Split(osVersion, ".")[0]
  ```
  </details>

### 后续发展方向 [AI]
- 三处均为 NVIDIADriver-as-CRD 路径的健壮性打磨(延续 07-28 的 driver-as-CRD 成熟化主线):default driver 唯一性、镜像 spec 完整性、OS 矩阵扩展,都是把 driver 容器化的边界条件补齐,无新 CRD 字段、无架构转向。证据覆盖 validator/reconciler/image/nodepool 四处 hunk。
- Oracle Linux 进 OS tag 矩阵只是 tag 构造逻辑,实际预编译镜像是否已发布(gpu-driver-container 侧)本次 diff 未见,该仓今日无新提交,可下期留意其 OS 构建矩阵是否同步加 `ol`。

## kai-scheduler/KAI-Scheduler: aeb57eae -> f03607a8
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/aeb57eaefe70ef778298501616b1b8f3d773d5e5...f03607a860579953aed8d3268a37635d412d6f7d | ahead=2 | files=10 | Release: v0.16.7

### AI 总结重点(源码 diff 为据)

- **victim 候选发现与队列构建解耦,新增跨探测缓存**:`utils/action.go` 把原 `GetVictimsQueue`(一次性发现候选并构建队列)拆成 `GetVictimCandidates`(只做过滤、返回候选 map)+ `newVictimsQueueFromCandidates`(从候选构建可变队列);再新增 `NewCachedVictimsQueueGenerator`——闭包内 `candidates` 惰性发现一次(`initialized` 标志),之后每次调用都基于同一候选集 `newVictimsQueueFromCandidates` 返回**全新可变队列**。目的:solver 在多次 scenario 探测中复用候选发现结果,避免重复扫描全量 `PodGroupInfos` 并重复过滤。
  <details><summary>代码依据 pkg/scheduler/actions/utils/action.go</summary>

  ```diff
  +// NewCachedVictimsQueueGenerator discovers candidates once and creates a fresh mutable queue for each call.
  +func NewCachedVictimsQueueGenerator(
  +	ssn *framework.Session,
  +	getCandidates func() map[common_info.PodGroupID]*podgroup_info.PodGroupInfo,
  +	options JobsOrderInitOptions,
  +) func() *JobsOrderByQueues {
  +	var candidates map[common_info.PodGroupID]*podgroup_info.PodGroupInfo
  +	initialized := false
  +	return func() *JobsOrderByQueues {
  +		if !initialized {
  +			candidates = getCandidates()
  +			initialized = true
  +		}
  +		return newVictimsQueueFromCandidates(ssn, candidates, options)
  +	}
  +}
  ```
  </details>

- **reclaim/preempt/consolidation 三条 action 接入缓存生成器**:`reclaim.go` 的 `getOrderedVictimsQueue` 从"每次闭包内重新遍历 `PodGroupInfos` 过滤"改为直接返回 `NewCachedVictimsQueueGenerator`(候选发现抽到 `getReclaimVictimCandidates`);`preempt.go` 同样改造;`consolidation.go` 仅在**无候选数量限制**(`maxPreempteesToTest == noConsolidationPreempteesRestrcition`)时走缓存路径,有限制时仍每次重建(因过滤带计数副作用不可缓存)。行为不变、语义等价,纯性能优化(changelog 归 `Fixed`,对应 issue #1850)。
  <details><summary>代码依据 pkg/scheduler/actions/consolidation/consolidation.go</summary>

  ```diff
  +func getOrderedVictimsQueue(ssn *framework.Session, preemptor *podgroup_info.PodGroupInfo) solvers.GenerateVictimsQueue {
  +	maxPreempteesToTest := ssn.GetMaxNumberConsolidationPreemptees()
  +	if maxPreempteesToTest != noConsolidationPreempteesRestrcition {
  +		return func() *utils.JobsOrderByQueues {
  +			return buildConsolidationVictimsQueue(ssn, preemptor)
  +		}
  +	}
  +	return utils.NewCachedVictimsQueueGenerator(
  +		ssn,
  +		func() map[common_info.PodGroupID]*podgroup_info.PodGroupInfo {
  +			filter := buildPreemptibleFilterFunc(preemptor, maxPreempteesToTest)
  +			return utils.GetVictimCandidates(ssn, filter)
  +		},
  +		utils.JobsOrderInitOptions{FilterNonPreemptible: true, FilterNonActiveAllocated: true},
  +	)
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 这是纯调度器内核性能优化,延续 KAI 近期"求解器热路径提速"方向;新增单测(reclaim/preempt/consolidation 三个 `*_victim_queue_test.go` + Benchmark)验证"跨调用复用候选但每次返回独立队列、且队列重建时会重新读动态 pod 状态"。证据覆盖 action.go/reclaim.go/preempt.go/consolidation.go 四处 hunk。
- consolidation 的缓存有条件启用(有 `maxPreempteesToTest` 限制时禁用)说明过滤函数带计数副作用与缓存不兼容,是精细取舍;无新 API/CRD/调度语义变化,不影响用户可见行为。docs 侧另修了多副本 HA 下 snapshot 抓取指南(改用 lease 定位 leader、gzip→zip 命名),属可观测性文档,非能力变化。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit、NVIDIA/gpu-driver-container、kubernetes-sigs/dra-driver-nvidia-gpu、NVIDIA/dcgm-exporter、NVIDIA/DCGM:无新提交。
- NVIDIA/k8s-device-plugin(ahead=2)、NVIDIA/mig-parted(ahead=2):仅 bump/CI/merge,无实质代码改动。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=f3f9415b6e4f406b99bb7a8c4b6558b52ee71c17 branch=main release=v26.3.3 scanned=2026-07-29 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1151f013074712dc6dabd00752b6b57d6637fdeb branch=main release=v1.20.0-rc.1 scanned=2026-07-29 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0ad335fb28b96957aa3f9fdda6dfdab9040e69e9 branch=main release=— scanned=2026-07-29 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=fb9452e0e72606d5abc19748f405794ca273931a branch=main release=v0.19.3 scanned=2026-07-29 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=b0a51e353fbabab0230639b027e02f1ab29e8cab branch=main release=v0.4.1 scanned=2026-07-29 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-29 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-29 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5f3f9d78cd4c6b0b77165b81b8e0dacebdcb825c branch=main release=v0.14.4 scanned=2026-07-29 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f03607a860579953aed8d3268a37635d412d6f7d branch=main release=v0.16.7 scanned=2026-07-29 -->
