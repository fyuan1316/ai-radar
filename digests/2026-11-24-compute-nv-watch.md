# NVIDIA 算力栈 diff 雷达 2026-11-24

## 摘要
- **9 个仓库里还是只有 KAI-Scheduler 有新提交(3 个)**。L1(gpu-operator / container-toolkit / gpu-driver-container)、L2(k8s-device-plugin / dra-driver-nvidia-gpu)、L3(dcgm-exporter / DCGM / mig-parted)已连续第 2 天零提交，最新提交和 11-23 锚点一致。
- **KAI 的 `nodeassignment` 插件从“只打分”变成“打分 + 过滤”**:新加的 `predicateFn` 不让**别的队列里不可抢占(含半可抢占)的 Pod** 调度到已归属某个队列的节点上;可抢占 Pod 仍然可以借用。设计意图很明确：外来 Pod 占了归属节点，必须能被 reclaim 赶走，所以队列对自己节点的“软所有权”才能保住。
- 副作用：标签写错(队列不存在 / 不是叶子队列 / 属于别的 shard)的节点，以前只是对所有 Pod 打 0 分，现在**对所有不可抢占 Pod 硬性不可调度**。另有一个 operator 小修复:Prometheus 关掉后会清空缓存的期望状态，operand 状态不会再卡在旧值上。

## 当日重要改变
- `kai-scheduler/KAI-Scheduler` **[行为变更·调度约束]** `pkg/scheduler/plugins/nodeassignment/nodeassignment.go` 在 `OnSessionOpen` 里新注册了 `ssn.AddPredicateFn(p.predicateFn)`。别的队列里的 non-preemptible / semi-preemptible Pod 在归属节点上会返回 `FitError`(reason:`node(s) are assigned to another queue; non-preemptible pods of other queues are not allowed`)。插件仍是 alpha，默认关闭(见 11-23 期)。 https://github.com/kai-scheduler/KAI-Scheduler/commit/b9eceb612afdf90045c2f06b938cfa8cd9f0d7bf https://github.com/kai-scheduler/KAI-Scheduler/issues/2465
- 其余信号类型(`[弃用/移除]` / `[API/CRD变更]` / `[架构方向]` / `[版本跨档]` / `[新能力]`)本期都没有命中:helper 没探测到 API/CRD 路径变化;helper 报的 Release `v0.18.9`(2026-11-23)是 0.18 分支的 backport,releases 列表里最大 semver 仍是 **v0.19.0**(2026-11-11),不算跨档。

## kai-scheduler/KAI-Scheduler: f828d415 -> 41a8c429
- 比较: f828d415b3c84a2240783e5fb5b2de2cc41bbe4b -> 41a8c429 | ahead=3 | files=11 | Release: v0.18.9(0.18 分支 backport;releases 最大 semver 仍是 v0.19.0,不算跨档)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/f828d415b3c84a2240783e5fb5b2de2cc41bbe4b...41a8c429ec6b97beab30fbf8188838bb261d56e9
- 提交:
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/b9eceb612afdf90045c2f06b938cfa8cd9f0d7bf feat(scheduler): keep foreign non-preemptible pods off assigned nodes (#2660)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/41a8c429ec6b97beab30fbf8188838bb261d56e9 fix(operator): clear stale status after disabling Prometheus (#2754)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/241c67ca4b347063463d088d926658567247f2cb docs: fix broken links and image path in design docs (#2679)(只是文档链接修正，不展开)

### AI 总结重点(源码 diff 为据)

- **`nodeassignment` 新增 predicate:节点归属从“偏好”升级成“对不可抢占的外来 Pod 有排他性”。** `OnSessionOpen` 在原有 `AddNodeOrderFn` 之后，又注册了 `AddPredicateFn(p.predicateFn)`。`predicateFn` 只有以下 4 种情况放行：节点不在 `owners` 表里(无主节点)、`job == nil`、`job.IsPreemptibleJob()` 为真、Pod 属于节点的归属队列(`isNative`)。其余情况，也就是**别的队列里不可抢占的 Pod 想上归属节点**,返回 `NewFitErrorWithDetailedMessage`。注释说明了动机:"keeps owned nodes free of pods that reclaim can't evict"——外来 Pod 只要可被 reclaim 赶走，归属队列随时能把节点收回来;不可抢占的 Pod 一旦落上去就收不回，所以直接挡掉。
  <details><summary>代码依据 pkg/scheduler/plugins/nodeassignment/nodeassignment.go(+25/-2)</summary>

  ```diff
  +// Non-preemptible pods of other queues are not allowed on owned nodes.
   package nodeassignment
  ...
  +	foreignNonPreemptibleReason = "node(s) are assigned to another queue; non-preemptible pods of other queues are not allowed"
  ...
   	ssn.AddNodeOrderFn(p.nodeOrderFn)
  +	ssn.AddPredicateFn(p.predicateFn)
  ...
  +// predicateFn keeps owned nodes free of pods that reclaim can't evict. Semi-preemptible jobs count as
  +// non-preemptible, since their protected core can change.
  +func (p *nodeAssignmentPlugin) predicateFn(
  +	task *pod_info.PodInfo, job *podgroup_info.PodGroupInfo, node *node_info.NodeInfo,
  +) error {
  +	owner, assigned := p.owners[node.Name]
  +	if !assigned || job == nil || job.IsPreemptibleJob() || isNative(owner, job) {
  +		return nil
  +	}
  +	return common_info.NewFitErrorWithDetailedMessage(task.Name, task.Namespace, node.Name,
  +		[]string{foreignNonPreemptibleReason},
  +		fmt.Sprintf("node is assigned to queue %s; non-preemptible pods of other queues are not allowed",
  +			node.Node.Labels[p.labelKey]))
  +}
  ```
  </details>

- **semi-preemptible 按不可抢占处理。** 注释原话是 "Semi-preemptible jobs count as non-preemptible, since their protected core can change":半可抢占作业有一部分受保护的核心 Pod,这部分的边界会变，插件不去判断哪些 Pod 能被驱逐，统一挡掉。单测 `TestPredicate` 里,`v2alpha2.SemiPreemptible` 的用例和 `NonPreemptible` 期望同样的 `wantDetail`。
  <details><summary>代码依据 pkg/scheduler/plugins/nodeassignment/nodeassignment_test.go(+66)</summary>

  ```diff
  +		{
  +			name:           "semi-preemptible pod on a node owned by another queue",
  +			nodeLabel:      map[string]string{DefaultLabelKey: "team-b"},
  +			preemptibility: v2alpha2.SemiPreemptible,
  +			wantDetail:     "node is assigned to queue team-b; non-preemptible pods of other queues are not allowed",
  +		},
  +		{
  +			name:           "non-preemptible pod on a node owned by a queue that does not exist",
  +			nodeLabel:      map[string]string{DefaultLabelKey: "missing"},
  +			preemptibility: v2alpha2.NonPreemptible,
  +			wantDetail:     "node is assigned to queue missing; non-preemptible pods of other queues are not allowed",
  +		},
  ```
  </details>

- **抽出 `isNative()`,让标签非法的节点从“全局 0 分”变成“对不可抢占 Pod 硬排除”。** `score()` 里的内联判断 `owner != unknownQueue && owner == job.Queue` 抽成了 `isNative(owner, job)`,打分和过滤共用。标签非法的节点在 `buildOwners()` 里登记为 `unknownQueue`(`assigned == true`),而 `isNative` 对 `unknownQueue` 恒为 false,所以这类节点对任何不可抢占 Pod 的 predicate 都不通过。单测 "queue that does not exist" 这个用例正好锁住了这个行为。11-23 期提到的“标签写错 = 全局最不优先”的坑，现在对不可抢占负载升级成“完全不可用”。
  <details><summary>代码依据 pkg/scheduler/plugins/nodeassignment/nodeassignment.go</summary>

  ```diff
  -	job, found := p.ssn.ClusterInfo.PodGroupInfos[task.Job]
  -	if found && owner != unknownQueue && owner == job.Queue {
  +	if job, found := p.ssn.ClusterInfo.PodGroupInfos[task.Job]; found && isNative(owner, job) {
   		return 2 * scores.NodeAssignment
   	}
   	return 0
   }
  +
  +func isNative(owner common_info.QueueID, job *podgroup_info.PodGroupInfo) bool {
  +	return owner != unknownQueue && owner == job.Queue
  +}
  ```
  </details>

- **集成测试确认了端到端语义：无主节点满了以后，不可抢占 Pod 宁可 Pending 也不借别的队列的节点。** `allocate_node_assignment_test.go` 原来的用例改名为 "preemptible pod uses another queue's node when unassigned nodes are full",限定了借用只对可抢占 Pod 成立。新增两个用例：一个用 `constants.PriorityBuildNumber` 构造不可抢占作业 `job-c`(queue-c),node-2 被占满、只剩 queue-a 的 node-3 空闲时，期望 `Status: pod_status.Pending`;另一个是同为不可抢占的 `job-a`(queue-a),期望正常落到自己的 node-3。queue-c 的 `DeservedGPUs` 从 2 调到 4,目的是排除配额不足导致 Pending 的干扰，让 Pending 只能归因于 predicate。
  <details><summary>代码依据 pkg/scheduler/actions/integration_tests/allocate/allocate_node_assignment_test.go(+45)</summary>

  ```diff
  -		{Name: "queue-c", DeservedGPUs: 2},
  +		{Name: "queue-c", DeservedGPUs: 4},
  ...
  -			Name: "pod uses another queue's node when unassigned nodes are full",
  +			Name: "preemptible pod uses another queue's node when unassigned nodes are full",
  ...
  +			Name: "non-preemptible pod stays pending when only other queues' nodes are free",
  ...
  +					"job-c":     {GPUsRequired: 1, Status: pod_status.Pending},
  ...
  +func nodeAssignmentNonPreemptibleJob(name, queue string) *jobs_fake.TestJobBasic {
  +	job := nodeAssignmentPendingJob(name, queue)
  +	job.Priority = constants.PriorityBuildNumber
  +	return job
  +}
  ```
  </details>

- **operator:Prometheus 关掉后清空 `lastDesiredState`,operand 状态不再停留在旧值。** `Prometheus.DesiredState()` 走到 `len(prometheus) == 0` 分支、准备返回空对象集时，先把 `p.lastDesiredState = nil`。新单测的流程是：先启用并生成对象，再设 `Enabled=false` 重新求期望状态，然后断言 `IsDeployed` / `IsAvailable` 都返回 true。由此推断，修复前 operand 一直拿上一次缓存的对象去检查是否部署 / 可用，于是报出旧的“未就绪”状态(hunk 只有 1 行，没覆盖 `IsDeployed` 的实现，这条推断依据的是测试断言)。
  <details><summary>代码依据 pkg/operator/operands/prometheus/prometheus.go(+1)/ prometheus_test.go(+19)</summary>

  ```diff
   		if len(prometheus) == 0 {
  +			p.lastDesiredState = nil
   			return nil, nil
   		}
  ```
  ```diff
  +				kaiConfig.Spec.Prometheus.Enabled = ptr.To(false)
  +				objects, err = prometheus.DesiredState(ctx, fakeKubeClient, kaiConfig)
  +				Expect(err).NotTo(HaveOccurred())
  +				Expect(objects).To(BeEmpty())
  +
  +				deployed, err := prometheus.IsDeployed(ctx, fakeKubeClient)
  +				...
  +				Expect(deployed).To(BeTrue())
  ```
  </details>

### 后续发展方向 [AI]
- **KAI 的“队列专属节点”语义已经成型：可抢占 Pod 可以借用，不可抢占 Pod 有排他性，再靠 reclaim 把节点收回来。** 11-23 期只有 NodeOrder 打分，当时判断为“偏好不独占”,还标了个疑问:reclaim 会不会感知节点归属。本期 predicate 从另一侧补齐：不是让 reclaim 感知归属，而是在入口就保证归属节点上只会出现能被 reclaim 赶走的外来 Pod,**闭环靠“谁能上”而不是“谁先被赶”**。对我们产品的启示：做“部门专属 GPU 节点池 + 闲时借用”时，这套语义可以直接对标——训练类不可抢占作业不准借、推理 / 实验类可抢占作业可以借，不需要 taint/toleration。证据只覆盖 nodeassignment 包与 allocate 集成测试,**没看到** reclaim action 本身优先驱逐归属节点上外来 Pod 的逻辑，也就是“能收回”目前靠的是通用 reclaim,不是定向回收。
- **多 shard 场景下的隔离副作用被放大了。** 同一个节点标签在别的 shard 看来是 `unknownQueue`,本期起，别的 shard 的不可抢占 Pod 会被这类节点硬过滤。效果上已经接近“跨 shard 节点硬隔离(仅限不可抢占负载)”,但仍然不是显式设计，只有 `buildOwners()` 里一条 V(2) 告警。插件还是 alpha、默认关闭，进 beta 之前大概率要补标签校验(admission 或状态上报)。证据是 `isNative` + 单测 "queue that does not exist",**没看到**任何多 shard 文档。
- **L1/L2/L3 连续两天静默。** gpu-operator 620 驱动跨档、DRA LocalIPC alpha gate 合入以后都在消化期，本期没有新证据。

<details>
<summary>## 本期无实质改动(8 仓)</summary>

- NVIDIA/gpu-operator:无新提交(HEAD 仍 d338c6bd,Release v26.7.3)
- NVIDIA/nvidia-container-toolkit:无新提交(HEAD 仍 d8041cb6,Release v1.20.2)
- NVIDIA/gpu-driver-container:无新提交(HEAD 仍 6be32fc9)
- NVIDIA/k8s-device-plugin:无新提交(HEAD 仍 057b54be,Release v0.20.2)
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(HEAD 仍 44cf296c,Release v0.5.1)
- NVIDIA/dcgm-exporter:无新提交(HEAD 仍 4e663a52,Release 4.9.0)
- NVIDIA/DCGM:无新提交(HEAD 仍 9fae2867,master 分支)
- NVIDIA/mig-parted:无新提交(HEAD 仍 9e415433,Release v0.15.2)

</details>

## 扫描锚点(机器可读，勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=d338c6bd60db03ef29db86f5ef411b0dca35a85b branch=main release=v26.7.3 scanned=2026-11-24 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d8041cb623e601ebc085e2198725d2ce8277ab5a branch=main release=v1.20.2 scanned=2026-11-24 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6be32fc94f4599b2cfc35f113a170607980cdd03 branch=main release=— scanned=2026-11-24 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=057b54be3946886765dc2700ce1ab80ce6bcf4ba branch=main release=v0.20.2 scanned=2026-11-24 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=44cf296cdfb787ec2155a5ffae11763cb7e92c7e branch=main release=v0.5.1 scanned=2026-11-24 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-24 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-24 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9e4154330f5124ee62bf8f724892f6dcfa1a7145 branch=main release=v0.15.2 scanned=2026-11-24 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=41a8c429ec6b97beab30fbf8188838bb261d56e9 branch=main release=v0.18.9 scanned=2026-11-24 -->
