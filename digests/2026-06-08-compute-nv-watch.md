# NVIDIA 算力栈 diff 雷达 2026-06-08

> 区间:各仓以 6/07 锚点为 base → 今日 HEAD(单日增量)。

## 摘要
- **本日无实质功能改动**:9 仓中 8 仓无新提交/仅 bump;唯一新提交在 `KAI-Scheduler`,且为纯测试/基准代码(1 笔,#1669),无任何生产代码行为变化,未命中重要改变信号。
- KAI 这笔虽是测试,但内容透露方向:给 reclaim action 补"**不可调度的分布式(gang)作业**"场景的回归测试 + 多规模基准,断言此类作业即便发起 reclaim 也**不得产生任何牺牲者**(无 Releasing/Pipelined),即守护 reclaim 对 gang 作业的"全有或全无"语义。

## 当日重要改变
- 无(KAI 唯一提交为测试/基准代码,未触 API/CRD、未弃用、未新增 package、未跨版本)。

## kai-scheduler/KAI-Scheduler: a55228f7 -> 3ef912ec
- 比较: a55228f7 -> 3ef912ec | ahead=1 | files=3 | Release: v0.14.5
- 比较页 https://github.com/kai-scheduler/KAI-Scheduler/compare/a55228f7804177655e50857ad8127238289c5d3b...3ef912ec076fb989180f29da22b9ac3ef2dc3e18
- 实质提交仅 1 笔:`test(scheduler): add unschedulable reclaim benchmarks (#1669)`。改动 3 文件,全为测试/基准 + Makefile 基准配置,无生产逻辑改动。

### AI 总结重点(源码 diff 为据)
- **新增"不可调度分布式作业 reclaim"行为回归测试 `TestUnschedulableDistributedReclaimTopology`**:构造一个即便 reclaim 也无法被调度的分布式作业拓扑,执行 `reclaim.New().Execute(ssn)` 后断言三点——① reclaim 确实尝试求解(`onJobSolutionStartCalls != 0`);② 该分布式作业全部 task 仍为 `Pending`(数量 == `PodsPerDistributedJob`);③ **集群内任何作业都不得有 `Releasing`(已提交的牺牲者)或 `Pipelined` task**。即把"分布式作业 reclaim 失败时不得部分驱逐/产生无效牺牲"这一全有或全无语义固化为测试。
  <details><summary>代码依据 pkg/scheduler/actions/integration_tests/reclaim/reclaim_benchmark_test.go</summary>

  ```diff
  +func TestUnschedulableDistributedReclaimTopology(t *testing.T) {
  +	params := defaultUnschedulableDistributedReclaimParams(10)
  +	topology := buildUnschedulableDistributedReclaimTopology(params)
  +	ssn := test_utils.BuildSession(topology, ctrl)
  +	...
  +	action := reclaim.New(); action.Execute(ssn)
  +	if len(job.PodStatusIndex[pod_status.Pending]) != params.PodsPerDistributedJob { t.Fatalf(...) }
  +	for _, clusterJob := range ssn.ClusterInfo.PodGroupInfos {
  +		if len(clusterJob.PodStatusIndex[pod_status.Releasing]) != 0 { t.Fatalf("expected no committed reclaimees ...") }
  +		if len(clusterJob.PodStatusIndex[pod_status.Pipelined]) != 0 { t.Fatalf("expected no pipelined tasks after failed reclaim ...") }
  +	}
  +}
  ```
  </details>
- **新增多规模基准 `BenchmarkReclaimUnschedulableDistributedJob_{10,50,100,200,500,1000}Node`**:在 `pkg/scheduler/actions/reclaim/reclaim_benchmark_test.go`(新文件)用 `b.Loop()` 在 10→1000 节点(每节点 8 GPU)规模下跑 reclaim,度量不可调度分布式作业场景下 reclaim 的性能/复杂度。
  <details><summary>代码依据 pkg/scheduler/actions/reclaim/reclaim_benchmark_test.go(新增)</summary>

  ```diff
  +func BenchmarkReclaimUnschedulableDistributedJob_10Node(b *testing.B)  { benchmarkReclaimUnschedulableDistributedJob(b, 10) }
  +func BenchmarkReclaimUnschedulableDistributedJob_1000Node(b *testing.B){ benchmarkReclaimUnschedulableDistributedJob(b, 1000) }
  +func benchmarkReclaimUnschedulableDistributedJob(b *testing.B, numNodes int) {
  +	topology := buildUnschedulableDistributedReclaimBenchmarkTopology(defaultUnschedulableDistributedReclaimBenchmarkParams(numNodes))
  +	action := reclaim.New()
  +	for b.Loop() { ssn := test_utils.BuildSession(topology, NewController(b)); action.Execute(ssn) }
  +}
  ```
  </details>
- **Makefile 把新基准纳入 CI 的 `-benchtime=1x` 专属子集**:`BENCH_SPECIAL_REGEX` 从只匹配 `BenchmarkReclaimWithMissingPVCJobs` 扩成同时匹配 `BenchmarkReclaimUnschedulableDistributedJob_(10|50|100)Node`,即仅这三档(非 200/500/1000 大档)进 CI 跑一次,避免基准拖慢 CI。
  <details><summary>代码依据 Makefile</summary>

  ```diff
  -BENCH_SPECIAL_REGEX := '^BenchmarkReclaimWithMissingPVCJobs$$'
  +BENCH_SPECIAL_REGEX := '^BenchmarkReclaim(WithMissingPVCJobs|UnschedulableDistributedJob_(10|50|100)Node)$$'
  ```
  </details>

### 后续发展方向 [AI]
- 证据全在测试侧:KAI 正把 reclaim action 在"分布式/gang 作业不可调度"边界上的语义(尝试求解但不留无效牺牲者)用测试固化,并铺多规模基准为后续性能优化做基线。这通常预示生产侧 reclaim 逻辑近期会有针对 gang 作业的调整(否则不会先补这类回归护栏与基准)。证据只覆盖测试/基准与 Makefile,未见 reclaim 生产代码本身改动,生产侧是否随后调整可在后续区间盯 `pkg/scheduler/actions/reclaim/` 非 `_test.go` 文件。

## 本期无实质改动
<details><summary>EMPTY 的 8 仓(保留锚点,详见末尾)</summary>

- NVIDIA/gpu-operator — 无新提交(仍 v26.3.2)。
- NVIDIA/nvidia-container-toolkit — 无新提交(仍 v1.19.1)。
- NVIDIA/gpu-driver-container — 无新提交。
- NVIDIA/k8s-device-plugin — 无新提交(仍 v0.19.2)。
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(仍 v0.4.0)。
- NVIDIA/dcgm-exporter — 无新提交。
- NVIDIA/DCGM — 无新提交(master)。
- NVIDIA/mig-parted — 无新提交(仍 v0.14.2)。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=2a8a94d3d99fbc771a37d0412d686202396000ab branch=main release=v26.3.2 scanned=2026-06-08 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=e0bcfd493755f5c11ae18c56c5a1f172d061af5c branch=main release=v1.19.1 scanned=2026-06-08 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=df698c2732758def060fb551d433f013866437ac branch=main release=— scanned=2026-06-08 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=db1ea9481054448d97ae43bd082147e7d6ba5501 branch=main release=v0.19.2 scanned=2026-06-08 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=f51778e2e66c6bf9364d8ae319cdd5ad609ec4a3 branch=main release=v0.4.0 scanned=2026-06-08 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-08 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-08 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=b24528651efb64b358e7fc169d4cb18d9ac06347 branch=main release=v0.14.2 scanned=2026-06-08 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=3ef912ec076fb989180f29da22b9ac3ef2dc3e18 branch=main release=v0.14.5 scanned=2026-06-08 -->
