# HAMi diff 雷达 2026-11-25

## 摘要
- HAMi 主仓新增**超节点(superpod)感知调度**(#3410)。用户在节点调度策略里加上 `superpod`,并给 Pod 打 `hami.io/taskid` 标签后,同一 task 的所有 Pod 会被硬约束收敛到同一个 `hami.io/superpodid` 节点组里。首个 Pod 落位前,调度器会先估算整个 task 的总副本数,把容量不够的超节点整组过滤掉;binpack 模式下只保留"刚好放得下"的那个超节点。落位后再按 `hami.io/rackid` 给同机架节点加分。这是 HAMi 调度器第一次在"单节点/单卡"之外引入**跨节点拓扑分组**语义,而且是基于标签约定实现的,没有新增 CRD。
- **抢占从透传改为设备感知**(#3524)。改动前,extender 的 `Preempt` 原样返回 kube-scheduler 给出的候选节点。改动后,它会删掉"把低优先级 Pod 全部驱逐后设备仍放不下"的节点,按 kube-scheduler 的 reprieve 算法补齐最小受害者集合,并把规划好的设备为 nominated Pod 预留 5 分钟,预留期内 Filter 会把这部分设备视为已占用。另有两处正确性修复:昇腾整卡请求改为受 ResourceQuota 约束(#3517);device plugin 取待分配 Pod 时校验节点锁指向的 Pod 身份(#3491)。
- volcano-vgpu-device-plugin 修了 3 个多容器 Pod 的分配 bug:按"下一个容器"的设备数匹配 Pod;容器索引只在 vGPU 容器里计;非 MIG 分配失败时释放节点锁。README 升到 Volcano v1.16 / K8s 1.37。HAMi-core、ascend-device-plugin、WebUI 零提交。HAMi 主仓的 libvgpu 子模块从 `6ef40c6` 同步到 `4314e0a`,即 HAMi-core 当前的 HEAD。

## 当日重要改变
- 无严格信号命中。逐条核对:
  - `[弃用/移除]`:实质提交标题均不含 deprecate/remove/drop,也没有删除 CRD 字段或 flag。
  - `[API/CRD变更]`:helper 两个仓的路径探测都是"无 API/CRD 路径命中"。
  - `[架构方向]`:没有 docs/proposals 或 /design/ 改动。新增的顶层目录 `skill/` 只有一份 agent 测试文档(SKILL.md),不是 Go package。
  - `[新能力]`:superpod 和抢占都写在已有的 `pkg/scheduler` 包内(新文件 `superpod.go`),没有新增独立 package,因此按规则不算命中。
  - `[版本跨档]`:HAMi v2.11.0、volcano-vgpu 1.13.0 均未变。
- 规则外提示:superpod 引入了 4 个新的用户面标签契约(`hami.io/taskid`、`hami.io/superpodid`、`hami.io/rackid`、`hami.io/superpod-total-request`)和一个策略值 `superpod`。调度器 ClusterRole 新增集群级 replicasets/statefulsets/jobs 的 list/watch 权限。实际能力影响超过不少"严格命中"的改动,见下文。

## Project-HAMi/HAMi: 508995fa -> 1e825e6b
- 比较: 508995fae6d47115765b964baedf87485a5a05d0 -> 1e825e6b | ahead=10 | files=35 | Release: v2.11.0(未变)
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/508995fae6d47115765b964baedf87485a5a05d0...1e825e6bd0d9634cd805622bedd9ed8aa6551614
- 实质提交:
  - `feat(scheduler): add superpod-aware scheduling with rack-level convergence` — https://github.com/Project-HAMi/HAMi/pull/3410 (e1a2a1c6)
  - `feat(scheduler): implement HAMi device-aware preemption` — https://github.com/Project-HAMi/HAMi/pull/3524 (1e825e6b)
  - `fix(ascend): enforce ResourceQuota for whole-card requests` — https://github.com/Project-HAMi/HAMi/pull/3517 (06e990c8)
  - `fix(util): serve only the pod the node lock was taken for` — https://github.com/Project-HAMi/HAMi/pull/3491 (c43869e6)
  - `docs: introduce an agent skill to test with nvml-mock` — https://github.com/Project-HAMi/HAMi/pull/3507 (22166e7b)
- 被 helper 过滤的 5 个 `build(deps)` 提交已用 compare API 核过:go-dcgm 1.4712.2→1.4801.0(#3519)、x/tools 0.52→0.53(#3518)、两项 CI action(#3520/#3521),以及 libvgpu 子模块 `6ef40c6`→`4314e0a`(#3522,与 HAMi-core 锚点一致)。这几项都不涉及默认版本跨档。
- helper 节选中 `superpod.go`(1125 行)、`preempt.go`、`scheduler.go`、`util.go`、`node_policy.go` 都被截断。已用 compare API 补拉完整 patch,并补看了 `pkg/util/types.go`、`score.go`、`common.go`、chart(clusterrole/deployment/values)这些节选里缺失的文件。下文结论覆盖了补拉的 hunk。`superpod.go` 里容量估算的细节(`countFittingPods`、`hostResourceFitLimits`、`collectAnchoredTaskReservations`)只读了函数签名和错误路径,没有逐行审。

### AI 总结重点(源码 diff 为据)
- **新增节点策略值 `superpod` 和 4 个标签契约**(`pkg/util/types.go`,#3410)。`superpod` 不是排序键,而是一个过滤器,可以和 binpack/spread 中的**一个**组合使用。`IsValidNodeSchedulerPolicy` 由原来的"单值 switch"改为"逗号分隔多值"校验,binpack 与 spread 同时出现时判为非法。Node 排序改走 `effectiveNodeSortKey`,只取第一个可识别的排序键,并跳过 `superpod`。
  <details><summary>代码依据 pkg/util/types.go / pkg/util/util.go</summary>

  ```diff
  +	NodeSchedulerPolicySuperpod SchedulerPolicyName = "superpod"
  ...
  +	TaskIDLabel = "hami.io/taskid"
  +	SuperPodIDLabel = "hami.io/superpodid"
  +	RackIDLabel = "hami.io/rackid"
  +	SuperpodTotalRequestLabel = "hami.io/superpod-total-request"
  ...
  -	switch SchedulerPolicyName(strings.TrimSpace(policy)) {
  -	case NodeSchedulerPolicyBinpack, NodeSchedulerPolicySpread:
  -		return true
  +	for p := range strings.SplitSeq(policy, ",") {
  +		switch SchedulerPolicyName(strings.TrimSpace(p)) {
  +		case NodeSchedulerPolicyBinpack:
  +			hasBinpack = true
  +		case NodeSchedulerPolicySpread:
  +			hasSpread = true
  +		case NodeSchedulerPolicySuperpod:
  ...
  +	return !hasBinpack || !hasSpread
  ```
  </details>
- **超节点收敛通过两层硬约束实现:webhook 注入 podAffinity,调度器 Filter 再过滤一次**。webhook 在 `fitResourceQuota` 之后调用 `injectSuperpodAffinity`,注入一条 `RequiredDuringScheduling` 的 podAffinity(selector 为 `hami.io/taskid=<id>`,topologyKey 为 `hami.io/superpodid`),同时做了去重。这样 kube-scheduler 自身也会执行这条约束。调度器侧的 `rejectNodesBySuperpod` 有 4 种拒绝原因:没有 superpodid 标签的节点一律拒(`SuperpodNodeOutside`);task 已落位(anchored)时,拒绝不在已落位超节点里的节点(`SuperpodMismatch`);首个 Pod 时,拒绝容量小于 task 总副本数的超节点(`SuperpodInsufficientCapacity`);非 spread 模式下,再拒绝容量大于"最小可容纳容量"的超节点(`SuperpodNotBestFit`,即 best-fit 装箱)。
  <details><summary>代码依据 pkg/scheduler/webhook.go / superpod.go</summary>

  ```diff
  +	if hasResource {
  +		injectSuperpodAffinity(pod)
  +	}
  ...
  +	term := corev1.PodAffinityTerm{
  +		LabelSelector: selector,
  +		TopologyKey:   util.SuperPodIDLabel,
  +	}
  ...
  +	if !ctx.TaskAnchored && ctx.totalPods > 0 &&
  +		!schedulerpolicy.NodePolicyUsesSpread(resolveNodeSchedulerPolicy(task)) {
  +		for _, capacity := range ctx.superpodCapacities {
  +			if capacity >= ctx.totalPods && (bestFitCapacity == 0 || capacity < bestFitCapacity) {
  +				bestFitCapacity = capacity
  ...
  +				case capacity < ctx.totalPods:
  +					reason = common.SuperpodInsufficientCapacity
  +				case bestFitCapacity > 0 && capacity > bestFitCapacity:
  +					reason = common.SuperpodNotBestFit
  ```
  </details>
- **task 总副本数(totalPods)按 4 级优先级推断**(`resolveSuperpodTotalRequest`)。依次为:① `hami.io/superpod-total-request` 标签,单位是设备份额,按单 Pod 请求向上取整换算成 Pod 数;② 同 namespace 内带相同 taskid 的所有 ReplicaSet 的 replicas 之和;③ Pod 自身 owner(ReplicaSet/StatefulSet 的 replicas,或 Job 的 `parallelism`);④ 兜底为 1。为了查 owner,调度器会在第一次遇到 superpod Pod 时**懒启动** RS/STS/Job 三个 informer(`ensureSuperpodInformers`,同步超时 30s,失败则 Filter 报错),chart 的 ClusterRole 也相应加了 `apps/replicasets,statefulsets` 和 `batch/jobs` 的 get/list/watch 权限。
  <details><summary>代码依据 superpod.go / scheduler.go / clusterrole.yaml</summary>

  ```diff
  +	if raw, ok := task.Labels[util.SuperpodTotalRequestLabel]; ok {
  +		declared, parseErr := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
  ...
  +			pods := declared / single
  +			if declared%single != 0 {
  +				pods++
  ...
  +	// Priority 2: same-taskid ReplicaSets.
  ...
  +	// Priority 3: owner controller replicas.
  ...
  +	return 1, nil
  ...
  +		if err == nil && job != nil && job.Spec.Parallelism != nil && *job.Spec.Parallelism > 0 {
  ...
  +	superpodInformerSyncTimeout    = 30 * time.Second
  ...
  +  - apiGroups: ["apps"]
  +    resources: ["replicasets", "statefulsets"]
  +    verbs: ["get", "list", "watch"]
  +  - apiGroups: ["batch"]
  +    resources: ["jobs"]
  ```
  </details>
- **机架级加分(rack boost)**(`applySuperpodRackBoost`,在 `calcScoreWithOptions` 中对每个通过 Filter 的节点调用)。task 已落位时,与已有 Pod 同 rack 的节点获得满额加分;首个 Pod 时,按"本 rack 能放下的 Pod 数 / 所有候选 rack 中的最大值"按比例加分。binpack 模式直接加分;spread 模式(分数越低越优先)改为减分,并把减分量上限设为 `baseScore/2`,以保持正分节点之间的相对顺序。加分值默认等于 `util.Weight`,可以通过 `HAMI_SUPERPOD_RACK_BOOST` 覆盖,chart 已暴露为 `scheduler.superpodRackBoost`(默认注释掉)。注释说明加分值"与芯片相关"。没有 rackid 标签的节点保持原分。
  <details><summary>代码依据 superpod.go / score.go / deployment.yaml</summary>

  ```diff
  +				if superpodCtx != nil {
  +					currentNode := s.currentNode(nodeID, node.Node)
  +					result.score.Score = applySuperpodRackBoost(superpodCtx, currentNode, nodeID, result.score.Score, userNodePolicy)
  ...
  +	boost := superpodRackBoost * float32(rackFittingPods) / float32(maxRackFittingPods)
  ...
  +func applyRackBoostToScore(baseScore, boost float32, spread bool) float32 {
  +	if !spread {
  +		return baseScore + boost
  +	}
  +	if baseScore > 0 && boost > baseScore/2 {
  +		boost = baseScore / 2
  +	}
  +	return baseScore - boost
  ...
  +          {{- if .Values.scheduler.superpodRackBoost }}
  +            - name: HAMI_SUPERPOD_RACK_BOOST
  ```
  </details>
- **`Preempt` 从透传改为设备感知的受害者选择**(`pkg/scheduler/preempt.go`,#3524)。改动前,无论什么情况都 `Returning preemption candidates unchanged`。改动后,先用 `authoritativePod` 取 live Pod;没有 HAMi 设备请求的 Pod 仍然透传。有设备请求时,在 `allocLock` 下对每个候选节点调用 `selectVictims`:先假设 kube-scheduler 提议的受害者和本节点所有更低优先级、持有 HAMi 设备的 Pod 都已移除,如果仍放不下就**把该节点从候选里删掉**;放得下则按 `moreImportantPod`(优先级高、启动早、UID 小者在前)逐个放回,放回后放不下的才计为受害者,并追加到 `proposed.Pods`。这与 kube-scheduler 的 reprieve 算法同构。fit 判断走新抽出的 `nodesUsageFrom(..., without)`,即排除指定 Pod 后**重建**设备用量;注释给出的原因是 core mask 和 MIG placement 无法做减法。
  <details><summary>代码依据 pkg/scheduler/preempt.go / scheduler.go</summary>

  ```diff
  -	klog.V(4).InfoS("Returning preemption candidates unchanged",
  -		"pod", klog.KObj(args.Pod), "uid", args.Pod.UID, "candidateNodes", len(candidates))
  +	if !hasDeviceRequest(resourceReqs) {
  +		klog.V(4).InfoS("Returning preemption candidates unchanged, pod requests no HAMi resource",
  ...
  +		victims, planned, fits := s.selectVictims(pod, resourceReqs, nodeName, podsByNode[nodeName], proposed)
  +		if !fits {
  ...
  +			delete(candidates, nodeName)
  ...
  +	for _, candidate := range candidates {
  +		delete(gone, candidate.UID)
  +		if devices, stillFits := s.fitsWithout(pod, resourceReqs, nodeName, nodePods, gone); stillFits {
  +			planned = devices
  +			continue
  +		}
  +		gone[candidate.UID] = struct{}{}
  +		victims = append(victims, candidate)
  ```
  </details>
- **抢占后为 nominated Pod 预留设备,防止受害者腾出的卡被别的 Pod 抢走**。`Preempt` 为每个节点记录一份 `preemptionPlan`(规划的设备,以及编码后的 MIG placement),按 Pod UID 存入 `s.preemptionPlans`。`Filter` 计算用量时,改为把 `nominatedReservations(pod)` 返回的占位 PodInfo 加进 `podsInfo`。只有当 nominated Pod 的 `NominatedNodeName` 落在计划内的节点上,且当前调度的 Pod 优先级**不高于**它时,才会生效预留。计划在以下情况下作废:超过 `preemptionPlanTimeout = 5m`、Pod 已绑定/终止/UID 变化,或该 Pod 自己 Filter 成功拿到设备。
  <details><summary>代码依据 pkg/scheduler/preempt.go / scheduler.go</summary>

  ```diff
  +const preemptionPlanTimeout = 5 * time.Minute
  ...
  +		if time.Since(plan.at) > preemptionPlanTimeout {
  +			delete(s.preemptionPlans, uid)
  ...
  +		nominated := live.Status.NominatedNodeName
  +		planned, ok := plan.nodes[nominated]
  +		if !ok || uid == task.UID || podPriority(live) < podPriority(task) {
  +			continue
  ...
  -	nodeUsage, _, failedNodes, err := s.getNodesUsage(args.NodeNames, pod)
  +	// Devices held back for nominated pods count as taken.
  +	podsInfo := append(s.podManager.ListPodsInfo(), s.nominatedReservations(pod)...)
  +	nodeUsage, _, failedNodes, err := s.nodesUsageFrom(args.NodeNames, pod, podsInfo, nil)
  ...
  +		// The pod got devices, so drop its plan.
  +		delete(s.preemptionPlans, pod.UID)
  ```
  </details>
- **昇腾 `Fit` 对整卡请求补上 ResourceQuota 检查,并对拓扑/910C 成对模式下的选中集合整体复核**(`pkg/device/ascend/device.go`,#3517)。循环内每张候选卡都先调用 `device.FitPodQuota`。在 topology 和 910C pair 模式下,`tmpDevs` 存的是全部候选卡而不是最终选择,所以循环内按单卡检查(`tentative = nil`),选出组合后再调用 `selectedFitQuota()` 对整组复核。如果配额拒绝了全部候选卡,就不再额外报 `AllocatedCardsInsufficientRequest`,只保留 `ResourceQuotaNotFit` 作为原因。测试 `TestFit_WholeCardRequestRespectsMemoryQuota` 的注释点明了原 bug:不设 memory 的请求会被解析为整卡,此前这条路径绕过了配额。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  +		tentative := tmpDevs[k.Type]
  +		if needTopology || pair910C {
  +			tentative = nil
  +		}
  +		if !device.FitPodQuota(pod, allocated, k.Type, tentative, device.ContainerDevice{
  +			UUID: dev.ID, Type: k.Type, Usedmem: memreq, Usedcores: k.Coresreq,
  +		}) {
  +			reason[common.ResourceQuotaNotFit]++
  ...
  +		tmpDevs[k.Type] = combination
  +		if !selectedFitQuota() {
  +			return false, tmpDevs, common.GenReason(reason, len(devices))
  +		}
  ```
  </details>
- **device plugin 的 `GetPendingPod` 增加身份三重校验**(`pkg/util/util.go`,#3491)。节点锁只记录 namespace/name,解析出来的 Pod 必须同时满足以下 3 个条件,否则 Allocate 报错拒绝服务:`Spec.NodeName == node`、`AssignedNodeAnnotations` 注解指向本节点、bind phase 为 `allocating`。注释说明没有改用"锁时间 vs Pod 创建时间"比较的原因:StatefulSet 重建同名 Pod 时会沿用旧锁,且两个时间来自不同的时钟。这与 11-24 的 #3494(patch 不得落到同名新 Pod 上)属于同一条"同名 Pod 身份"修复线。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  +	if err := checkPendingPod(pod, node); err != nil {
  +		return nil, err
  +	}
  ...
  +func checkPendingPod(pod *corev1.Pod, node string) error {
  +	if pod.Spec.NodeName != node {
  ...
  +	if assigned := pod.Annotations[AssignedNodeAnnotations]; assigned != node {
  ...
  +	if phase := pod.Annotations[DeviceBindPhase]; phase != DeviceBindAllocating {
  ```
  </details>
- **测试基建**(#3507):新增 `skill/hami-nvml-mock/SKILL.md`,教 agent 在没有 GPU 的 kind 集群上用 NVIDIA nvml-mock 测试调度器和 device plugin;`hack/deploy-helm.sh` 新增 `HELM_VALUES_FILE` 支持,`kubectl version` 改为显式带上 `--kubeconfig`。文档写明 nvml-mock 环境下 `CUDA_DISABLE_CONTROL=true` 时不会挂载 `ld.so.preload`,因此 HAMi-core 的软切分指标不可测。也就是说,这套 mock 只覆盖调度和 Allocate,覆盖不到 hook 隔离。
  <details><summary>代码依据 skill/hami-nvml-mock/SKILL.md</summary>

  ```diff
  +Lab 5 sets `CUDA_DISABLE_CONTROL=true` in its test containers. The kubelet still calls `Allocate` for vGPU requests, and `Allocate` omits the `/etc/ld.so.preload` mount that loads HAMi Core.
  +
  +For partial-GPU allocations in the lab, expect metrics that depend on HAMi Core shared memory, such as `hami_vgpu_memory_used_bytes`, to be absent.
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 调度器正从"单节点切卡"走向"多节点拓扑编排"**。superpod/rack 这两级标签、task 粒度的整组容量预判,以及 best-fit 选择超节点,针对的都是大模型训练/推理集群"一个作业要求落在同一高速互联域"的需求(注释称加分值与芯片相关,`hami.io/superpodid` 也与昇腾超节点的叫法同源)。实现上没有走 CRD 或 PodGroup,而是依赖标签约定、owner replicas 推断和 webhook 注入的 podAffinity,与 Volcano/KAI 的 gang/topology-aware 原生路径并行而不融合。证据只覆盖 #3410 的 diff,没有看 PR 讨论,无法判断后续是否会对接 Kueue TAS 或 Volcano HyperNode。
- **调度器逐步接管 kube-scheduler 的抢占语义**。#3524 让 extender 在设备层参与受害者选择和预留,补上了 HAMi 软切分(按显存/算力份额)下"kube-scheduler 只看扩展资源计数、看不到碎片"这个长期缺口。不过预留状态只存在调度器进程内存里(`preemptionPlans` map),重启或多副本 leader 切换后就会丢失;受害者只从持有 HAMi 设备且优先级更低的 Pod 中挑选。diff 中没有看到 PDB 相关处理,是否由 kube-scheduler 兜底,未逐 PR 核实。
- 配额和身份两条正确性主线还在持续收口:昇腾整卡配额这次补齐(此前 NVIDIA 路径已有 FitPodQuota);同名 Pod 身份校验从 e2e(#3494)延伸到了 device plugin 运行时(#3491)。以上均属于 HAMi 软切分路径,不涉及 DRA。

## Project-HAMi/volcano-vgpu-device-plugin: 5357e807 -> 327cd25b
- 比较: 5357e807398dcf2aae6d82a9bffa3bfaef7f701f -> 327cd25b | ahead=9 | files=8 | Release: volcano-vgpu-device-plugin-1.13.0(未变)
- 比较链接: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/5357e807398dcf2aae6d82a9bffa3bfaef7f701f...327cd25b4a6e8b1c408db9e522428b5e31216cf2
- 实质提交(9 个里有 4 个 merge):
  - `fix(plugin): release node lock when non-MIG allocate response fails` — https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/272 (e9c3219f)
  - `fix(util): map device requests to vGPU containers only` — https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/273 (eef13bc9)
  - `fix(util): match pending pod by the next container's device count` — https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/274 (645c8426)
  - `docs: refresh README for Volcano v1.16 and bump Go to 1.27.4` / `docs: point MIG support at NVIDIA's supported GPU list` — https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/277

### AI 总结重点(源码 diff 为据)
- **`getOldestPod` 改为按"下一个待分配容器"的设备数与 kubelet 请求匹配**。改动前取的是整个 Pod 的设备总数(`DecodePodDevices` 的 length),而 kubelet 是按容器逐个调用 Allocate 的。因此,如果一个 Pod 有两个 vGPU 容器,或单个容器的设备数与整个 Pod 不同,就永远匹配不上,分配会卡住。新函数 `nextDeviceCount` 返回注解中第一个非空容器条目的设备数,因为已分配的条目会按容器顺序被擦除。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -		_, deviceCount := DecodePodDevices(pod.Annotations[AssignedIDsToAllocateAnnotations])
  +		// Kubelet asks per container, so match the next container still waiting for devices.
  +		deviceCount := nextDeviceCount(pod.Annotations[AssignedIDsToAllocateAnnotations])
  ...
  +func nextDeviceCount(annotation string) int {
  +	for _, s := range strings.Split(annotation, ";") {
  +		if _, n := DecodeContainerDevices(s); n > 0 {
  +			return n
  ```
  </details>
- **`GetNextDeviceRequest` 的容器索引改为只在 vGPU 容器里计数**。调度器只为请求了 `vgpu-number` 或 `vgpu-memory` 的容器写注解条目,而旧代码用 `p.Spec.Containers[idx]` 在全部容器里按下标取值。只要 vGPU 容器前面有一个 sidecar,设备就会被映射到 sidecar 上。新增的 `vgpuContainers` 先过滤出 vGPU 容器;下标越界时返回错误,而不是取错容器。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  +	ctrs := vgpuContainers(p)
  ...
  -			return p.Spec.Containers[idx], res, nil
  +			if idx >= len(ctrs) {
  +				return v1.Container{}, res, fmt.Errorf("device request %d has no vGPU container", idx)
  +			}
  +			return ctrs[idx], res, nil
  ```
  </details>
- **非 MIG 路径的 `getAllocateResponse` 失败时,调用 `PodAllocationFailed` 释放节点锁并把 Pod 标记为失败**。此前只有 MIG 路径这样处理,非 MIG 路径直接 return error,节点锁要等过期才会释放,期间该节点无法再调度其他 vGPU Pod。
  <details><summary>代码依据 pkg/plugin/server.go</summary>

  ```diff
   			response, err := plugin.getAllocateResponse(deviceStrArray)
   			if err != nil {
  +				util.PodAllocationFailed(nodeName, current)
   				return nil, fmt.Errorf("failed to get allocate response: %v", err)
  ```
  </details>
- 文档与构建:README 的验证基线从 K8s 1.36 改为 K8s 1.37 + Volcano v1.16.0,给出的 scheduler 配置改为基于 v1.16 默认配置(新增 `overcommit`,gang/drf 加上 `enablePreemptable: false`)。MIG 的硬件要求从"Ampere 及以上"改为"支持 MIG 的 GPU(A30/A100/H100 等)",即承认并非所有 Ampere 卡都支持 MIG。Dockerfile 中 Go 版本从 1.27.3 升到 1.27.4。

### 后续发展方向 [AI]
- Volcano 集成路径这几期都在修**多容器 Pod 的 Allocate 对账**问题(容器顺序、sidecar、节点锁释放),与 HAMi 主仓 #3491/#3494 的"Pod 身份"修复是同一类问题:基于注解的分配协议在边界场景下容易出错。证据只覆盖这 3 个 hunk,未见 volcano-vgpu 侧有任何超节点/抢占能力的同步,主仓 #3410/#3524 目前只作用于 HAMi 自带的 extender 调度器。

## 本期无实质改动(折叠)
- Project-HAMi/HAMi-core:4314e0a7,无新提交
- Project-HAMi/ascend-device-plugin:9325759b,无新提交
- Project-HAMi/HAMi-WebUI:19a0f955,无新提交

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=1e825e6bd0d9634cd805622bedd9ed8aa6551614 branch=master release=v2.11.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=4314e0a7750eb53dbe865c86abe88b59143390cc branch=main release=— scanned=2026-11-25 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=327cd25b4a6e8b1c408db9e522428b5e31216cf2 branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-25 -->
