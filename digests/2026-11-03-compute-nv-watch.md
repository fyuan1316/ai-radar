# NVIDIA 算力栈 diff 雷达 2026-11-03

## 摘要
- **KAI-Scheduler 落地 KEP-5836「deferred in-place pod resize」抢占支持**:新增 `deferredresize` action 子包 + `pod_resize.go`,为延迟生效的原地扩容构造"pending 占位任务(resize stand-in)",并让 reclaim/preempt 动作据此在同节点腾挪资源——调度器开始正面支持 K8s 原地垂直扩缩(VPA in-place)语义。
- **k8s-device-plugin 把 compute capability 11.x(Jetson Thor)并入 blackwell 家族标签**:`getArchFamily` 由 `case 10,12` 扩为 `case 10,11,12`,边缘/Thor 卡的 `nvidia.com/gpu.family=blackwell` 标签就位。
- 其余 7 仓:gpu-operator 仅 CI/发版自动化(无 ClusterPolicy 改动),dra-driver-nvidia-gpu 虽 ahead=6/files=90 但全是 bump/merge,其余 5 仓无新提交。

## 当日重要改变
- **KAI-Scheduler [新能力][架构方向]** 新增原地扩容调度支持:`pkg/scheduler/actions/common/deferredresize/deferred_resize.go` 子包 + 设计文档 `docs/developer/designs/in-place-pod-resize/deferred-resize-preemption.md`;对接 K8s `PodResizePending/Deferred` 条件,扩容放不下时触发 reclaim/preempt。证据见下。 https://github.com/kai-scheduler/KAI-Scheduler/pull/2510
- **NVIDIA/k8s-device-plugin [新能力/硬件支持]** compute capability 11.x(Jetson Thor)归入 blackwell 家族,节点 GPU family 标签正确化。 https://github.com/NVIDIA/k8s-device-plugin/compare/62cd70687d62b27e0dd28943c2be7a9d7967c1d2...5699a52c7d3197f2ee105e19661e6063596d3c33

## kai-scheduler/KAI-Scheduler: 4e6fcbd3 -> a937d103
- 比较: 4e6fcbd30ce4eea1405e1f2845ee0c876869b147 -> a937d103 | ahead=2 | files=43 | Release: v0.18.7
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/4e6fcbd30ce4eea1405e1f2845ee0c876869b147...a937d1030b1f9bca1972927f5387f2fe4b7c7051
- PR: https://github.com/kai-scheduler/KAI-Scheduler/pull/2510

### AI 总结重点(源码 diff 为据)
- **新增"延迟 resize 识别"入口 `IsDeferredResizeTask`**:仅当任务处于 `Running`、Pod 带 `PodResizeDeferred` 条件、且确有"目标 request > 当前已分配"的待扩容(`hasPendingUpsize`)时才判为延迟扩容任务;`hasPendingUpsize` 显式防御"先扩后缩导致 Deferred 条件残留"的 stale 场景(desired 必须大于 current 才返回 true)。这是把 K8s 1.33+ 的 in-place resize(`PodResizePending/Deferred`)语义接入 KAI 调度循环的识别层。
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_resize.go(新增)</summary>

  ```diff
  +var resizableResources = []v1.ResourceName{v1.ResourceCPU, v1.ResourceMemory}
  +
  +func IsDeferredResizeTask(task *PodInfo) bool {
  +	if task == nil || task.Pod == nil || task.Status != pod_status.Running {
  +		return false
  +	}
  +	pod := task.Pod
  +	return resourcehelpers.IsPodResizeDeferred(pod) && hasPendingUpsize(pod)
  +}
  +
  +// NewResizeStandIn returns a pending stand-in for a deferred resize task. It requests nothing,
  +// as KEP-5836's request minus cached footprint: the node already charges the task at its target size.
  +func NewResizeStandIn(task *PodInfo) *PodInfo {
  +	standIn := task.Clone()
  +	standIn.Status = pod_status.Pending
  +	standIn.IsResizeStandIn = true
  +	standIn.ResReqVector = make(resource_info.ResourceVector, len(task.ResReqVector))
  +	standIn.GpuRequirement = *resource_info.NewGpuResourceRequirement()
  +	return standIn
  +}
  ```
  </details>
- **`PodInfo` 新增字段 `IsResizeStandIn`,并由 `NewResizeStandIn` 产出"零请求 pending 占位"**:占位任务请求向量清零、GPU 需求置空(节点已按目标尺寸计费,故占位本身不再重复请求),`Clone()` 同步复制该字段。这是"把原地扩容伪装成一个可被调度/抢占逻辑识别的 pending 任务"的核心载体——它永不被真正 place。
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
   	Status          pod_status.PodStatus
   	IsVirtualStatus bool
   	IsLegacyMIGtask bool
  +	// IsResizeStandIn marks a pending copy of a running pod with a deferred resize; it is never placed.
  +	IsResizeStandIn bool
  ```
  </details>
- **节点新增 `IsInPlaceResizeAllocatable`:原地扩容只在任务自身所在节点判定是否过量分配**:要求 `task.NodeName == ni.Name` 且 CPU/Memory 的 `NonAllocatedResource`(= Idle+Releasing)≥0——即允许借助"正在释放中的资源"覆盖扩容缺口,这正是触发 reclaim/preempt 腾地的判据。
  <details><summary>代码依据 pkg/scheduler/api/node_info/node_info.go</summary>

  ```diff
  +// IsInPlaceResizeAllocatable checks the task's own node, which already charges the task at its target
  +// size, for over-commitment (KEP-5836).
  +func (ni *NodeInfo) IsInPlaceResizeAllocatable(task *pod_info.PodInfo) bool {
  +	return task.NodeName == ni.Name &&
  +		ni.NonAllocatedResource(v1.ResourceCPU) >= 0 && ni.NonAllocatedResource(v1.ResourceMemory) >= 0
  +}
  ```
  </details>
- **PodGroup 层新增 `IsResizeStandIn()`:当一个 job 的所有 pending 任务都是 resize 占位时返回 true**,供 reclaim/preempt(`reclaim.go` +139、`preempt.go` +121,hunk 未全展开)区分"真要调度的新任务"与"为既有任务扩容腾地"两种 pending,避免把扩容占位当普通待调度 job 处理。
  <details><summary>代码依据 pkg/scheduler/api/podgroup_info/job_info.go</summary>

  ```diff
  +func (pgi *PodGroupInfo) IsResizeStandIn() bool {
  +	pending := pgi.PodStatusIndex[pod_status.Pending]
  +	for _, task := range pending {
  +		if !task.IsResizeStandIn {
  +			return false
  +		}
  +	}
  +	return len(pending) > 0
  +}
  ```
  </details>

### 后续发展方向 [AI]
- KAI 正把"原地垂直扩缩"纳入抢占/回收决策闭环:占位任务(stand-in)+ 同节点过量分配判定 + reclaim/preempt 腾地,意味着运行中的 GPU/CPU 作业可在不重调度的前提下就地扩容,放不下时按队列公平性抢占低优先级作业让路。对标我们产品:若支持 KServe/推理服务的弹性扩容,这是"原地扩容而非重建 Pod"路线的调度侧参考实现。
- 证据边界:只读了 `pod_resize.go`/`node_info.go`/`pod_info.go`/`job_info.go` 的完整 hunk 与一段 e2e;`reclaim.go`(+139)/`preempt.go`(+121)的腾地算法改动 hunk 未在本次节选中展开,具体抢占选择策略(选谁、是否跨队列)未逐行核实,仅能从占位/判定接口推断其用法。

## NVIDIA/k8s-device-plugin: 62cd7068 -> 5699a52c
- 比较: 62cd70687d62b27e0dd28943c2be7a9d7967c1d2 -> 5699a52c | ahead=2 | files=2 | Release: v0.20.1
- compare: https://github.com/NVIDIA/k8s-device-plugin/compare/62cd70687d62b27e0dd28943c2be7a9d7967c1d2...5699a52c7d3197f2ee105e19661e6063596d3c33

### AI 总结重点(源码 diff 为据)
- **`getArchFamily` 将 compute capability 11.x 并入 blackwell 家族**:原注释称 Blackwell 分叉为 10.0/12.0 两档、分支 `case 10, 12`;改为 `case 10, 11, 12` 并注明 11.x 对应 Jetson Thor。效果是 Jetson Thor 卡节点能被打上与 Blackwell 一致的 `nvidia.com/gpu.family` 标签,供调度器/亲和性按家族选卡,而非落到未知家族。
  <details><summary>代码依据 internal/lm/resource.go</summary>

  ```diff
   	case 9:
   		return "hopper"
  -	// The Blackwell GPU family is bifurcated into two cuda compute capabilities 10.0 and 12.0
  -	case 10, 12:
  +	// The Blackwell GPU family spans the cuda compute capabilities 10.x, 11.x
  +	// (Jetson Thor) and 12.x
  +	case 10, 11, 12:
  		return "blackwell"
   	case 13:
  		return "rubin"
  ```
  </details>

### 后续发展方向 [AI]
- 纯硬件家族枚举扩充,无架构面改动;信号意义在于 NVIDIA 持续把边缘/Jetson Thor(sm_11x)纳入统一 GPU family 标签体系,利于用同一套节点标签/调度规则覆盖数据中心 Blackwell 与边缘 Thor。证据仅覆盖 family 映射与其单测,未见 MPS/time-slicing/DRA 相关改动。

## NVIDIA/gpu-operator: af4995c9 -> 1fb59b09
- 比较: af4995c9103d4ea4936fe8658f96a6db81321fdf -> 1fb59b09 | ahead=3 | files=4 | Release: v26.7.2
- compare: https://github.com/NVIDIA/gpu-operator/compare/af4995c9103d4ea4936fe8658f96a6db81321fdf...1fb59b09d022001a4fea575fce2355e7a126e0e5

### AI 总结重点(源码 diff 为据)
- **本期改动全部落在 `.github/` 发版自动化,无 ClusterPolicy CRD、无 operand/控制器逻辑改动**,属低信号,仅记录不展开为能力结论。两点:(1) `get-latest-images.sh` 从"取单个最新 commit"改为"检查最近 30 个 commit 并逐个 `regctl manifest head` 验证镜像是否已发布",对 24h 内无镜像的 operand 走回退并产出 `outdated-images.txt`,publish-main-chart 工作流据此发 Slack 告警;(2) 新增 `NumericStringQuotingDumper` 强制给形如 `08013248` 的 8 位短 SHA 镜像 tag 加引号,避免 Helm 按 YAML 1.2 当数字解析。
  <details><summary>代码依据 .github/scripts/get-latest-images.sh / merge-yaml.py</summary>

  ```diff
  -readonly MAX_RETRIES=5
  +readonly MAX_COMMITS_TO_CHECK=30
  +readonly OUTDATED_IMAGE_AGE_HOURS=24
  +readonly MANIFEST_CHECK_ATTEMPTS=3
  ...
  +NumericStringQuotingDumper.add_implicit_resolver(
  +    "tag:yaml.org,2002:float",
  +    re.compile(r"^[-+]?(0[oO][0-7_]+|(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?)$"),
  +    list("-+.0123456789"),
  +)
  ```
  </details>

### 后续发展方向 [AI]
- 无产品/能力方向可推断;纯 CI/发版健壮性。证据仅覆盖 4 个 `.github/` 文件,ClusterPolicy 无命中。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM(master)— 无新提交
- NVIDIA/mig-parted — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — ahead=6/files=90,但实质提交经滤后仅剩 bump/CI/merge,无能力改动

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=1fb59b09d022001a4fea575fce2355e7a126e0e5 branch=main release=v26.7.2 scanned=2026-11-03 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=f18b57912a20e967c5f045475f512191d24ef821 branch=main release=v1.20.1 scanned=2026-11-03 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=c9baa54d84c1e41c1c5ba3af82676fc7f0b0549d branch=main release=— scanned=2026-11-03 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5699a52c7d3197f2ee105e19661e6063596d3c33 branch=main release=v0.20.1 scanned=2026-11-03 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=e775fdb63e593a121b40fc1cc4c9a9c89955e635 branch=main release=v0.5.1 scanned=2026-11-03 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-11-03 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-03 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=080132489de972ec5f7ae63be2150931c02aa79b branch=main release=v0.15.1 scanned=2026-11-03 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=a937d1030b1f9bca1972927f5387f2fe4b7c7051 branch=main release=v0.18.7 scanned=2026-11-03 -->
