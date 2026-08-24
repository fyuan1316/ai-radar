# 昇腾算力栈 diff 雷达 2026-08-25

## 摘要
- mind-cluster 的 **ascend-for-volcano 调度插件全面"旁路"DRA 任务**:新增 `IsDRATask/IsDRAJob`(判据 = Pod 是否声明 `ResourceClaims`),并在调度全生命周期十余处让路——凡走 K8s 原生 DRA 的作业,昇腾 Volcano 插件不再介入校验/打分/抢占/回收/分配,交由 DRA driver(对应 openFuyao/npu-dra-plugin)接管。这是昇腾从"注解式 NPU 分配"向"原生 DRA 路径"共存过渡的明确架构信号。
- 其余 8 个 openFuyao NPU 栈仓相对上期锚点均无新提交,仅保锚点续链。

## 当日重要改变
- mind-cluster [架构方向] ascend-for-volcano 调度插件与 K8s DRA 共存:DRA 作业绕过全部昇腾专有调度逻辑(校验/打分/抢占/回收/故障预选/分配回收),让位给 DRA driver。证据 `component/ascend-for-volcano/npu.go`、`plugin/{job,factory,task,node}.go`、`common/util/util.go`。https://gitcode.com/Ascend/mind-cluster/compare/22bb3d98...b0f79f5a

## mind-cluster: 22bb3d98 -> b0f79f5a
- 比较: 22bb3d98..b0f79f5a | tag: v26.1.0 | commits=8 | truncated=false
- 源链接:https://gitcode.com/Ascend/mind-cluster/compare/22bb3d98...b0f79f5a

### AI 总结重点(源码 diff 为据)
- **新增 DRA 识别原语**:`common/util/util.go` 加 `IsDRATask`(`nT.Pod.Spec.ResourceClaims` 长度 >0 即判为 DRA)与 `IsDRAJob`(任一 task 为 DRA 即整 job 为 DRA)。这是整套旁路逻辑的统一判据——只看 Pod 是否声明了 ResourceClaim,与昇腾自有的 NPU 注解/资源名解耦。

  <details><summary>代码依据 component/ascend-for-volcano/common/util/util.go</summary>

  ```diff
  +// IsDRATask reports whether the task requests devices through Kubernetes Dynamic Resource Allocation.
  +func IsDRATask(nT *api.TaskInfo) bool {
  +	if nT == nil || nT.Pod == nil {
  +		return false
  +	}
  +	return len(nT.Pod.Spec.ResourceClaims) > 0
  +}
  +
  +// IsDRAJob reports whether any task of the job uses DRA.
  +func IsDRAJob(job *api.JobInfo) bool {
  +	if job == nil { return false }
  +	for _, task := range job.Tasks {
  +		if IsDRATask(task) { return true }
  +	}
  +	return false
  +}
  ```
  </details>

- **调度回调全链路让路**:`npu.go` 在 `jobPipelined`(→Abstain)、`addBatchNodeOrderFn`(打分直接 `return nil,nil` 不参与节点排序)、`addPreemptableFn`/`addReclaimableFn`(→Abstain,不参与抢占/回收)、`jobReady`(DRA job 直接 `return true`)、`AllocateFunc`/`DeallocateFunc` 事件处理(DRA task 直接 return 不走 `NPUAllocateFunc/NPUDeallocateFunc`)统一插入 DRA 短路。含义:DRA 作业的节点绑定/资源账本完全不进昇腾插件的状态机。

  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
   func addBatchNodeOrderFn(ssn *framework.Session, tp *huaweiNPUPlugin) {
   	ssn.AddBatchNodeOrderFn(tp.Name(), func(task *api.TaskInfo, nodes []*api.NodeInfo) (map[string]float64, error) {
  +		if util.IsDRATask(task) {
  +			klog.V(util.LogInfoLev).Infof("batchNodeOrderFn: bypass DRA task <%s>.", task.Name)
  +			return nil, nil
  +		}
   ...
   func addPreemptableFn(ssn *framework.Session, tp *huaweiNPUPlugin) {
   	ssn.AddPreemptableFn(tp.Name(), func(preemptor *api.TaskInfo, preemptees []*api.TaskInfo) ([]*api.TaskInfo, int) {
  +		if util.IsDRATask(preemptor) {
  +			return nil, util.Abstain
  +		}
  ```
  </details>

- **JobValid 语义改写 + DRA 全绕过**:`plugin/job.go` 把原来 `sHandle == nil || *sHandle.FrameAttr.IsFirstSession` 的合并判空拆开——先只判 `sHandle == nil`;随后若 `IsDRAJob` 直接 `return nil`(表示校验通过,**跳过首会话、PodGroup、虚拟设备等全部昇腾校验**);普通作业才继续走 first-session 拒绝逻辑。即 DRA 作业连"首会话未就绪"这类护栏都不再拦。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go</summary>

  ```diff
  -	if sHandle == nil || *sHandle.FrameAttr.IsFirstSession {
  +	if sHandle == nil {
   		return &api.ValidateResult{Pass: false, Reason: objectNilError, ...}
   	}
   ...
  +	// DRA jobs are allocated by the DRA driver. Bypass all Ascend validation,
  +	// including the first-session, PodGroup and virtual-device checks.
  +	if util.IsDRAJob(job) {
  +		return nil
  +	}
  +	if *sHandle.FrameAttr.IsFirstSession {
  +		return &api.ValidateResult{Pass: false, Reason: objectNilError, ...}
  +	}
  ```
  </details>

- **作业初始化 / 任务排序 / 分配回收 / 节点预选同样绕过**:`plugin/factory.go` 的 `InitJobsFromSsn` 对 DRA job `continue`(根本不纳入昇腾 SchedulerJob 集合);`TaskOrderFn` 对 DRA task 返回同优先级;`plugin/task.go` 的 `NPUAllocateFunc/NPUDeallocateFunc` 早退;`plugin/node.go` 的 `NodePredicate` 在故障预选前对 DRA task `return nil`——**DRA Pod 不会被 NPU 故障处理逻辑拒绝**。配套新增 `TestIsDRATaskAndJob`、`TestJobValidBypassDRAJobInFirstSession`、`TestJobValidRejectNormalJobInFirstSession` 三组单测,守住"DRA 放行 / 普通作业仍在首会话被拒"的边界。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/{factory,node}.go</summary>

  ```diff
   // factory.go InitJobsFromSsn
   	for jobID, jobInfo := range ssn.Jobs {
  +		if util.IsDRAJob(jobInfo) {
  +			continue
  +		}
   // node.go NodePredicate(故障预选前)
  +	if util.IsDRATask(taskInfo) {
  +		return nil
  +	}
   	if sHandle.FaultHandle != nil {
   		if err := sHandle.FaultHandle.CheckNodeNPUByTask(taskInfo, &vcNode); err != nil {
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾正把"混合调度"落到代码:同一 Volcano 会话里,**注解式 NPU 作业仍走昇腾插件的拓扑亲和/故障重调度,DRA 作业则完全交给 npu-dra-plugin**,两条路互不干扰。判据仅凭 `ResourceClaims` 存在与否,说明当前是"非此即彼"的粗粒度切换,尚未见二者混排在同一 job 内的处理。
- 证据只覆盖 ascend-for-volcano 侧的"让路"改动;**未见** DRA driver(npu-dra-plugin,本期 EMPTY)侧对应的 claim 分配/拓扑感知实现,也未见 DRA 路径下如何补偿丢失的昇腾故障重调度能力——这是共存方案后续要填的坑。
- 对我们产品的启示:昇腾生态的 DRA 迁移已进入"存量调度器主动退让"阶段,若我们自研调度栈也要兼容 NPU,应预留同类"DRA 短路"开关,避免自有调度逻辑与 DRA driver 双重记账冲突。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo(仅保锚点)</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=b0f79f5ac2436f3f19cbd4d71732475ce8065d6c tag=v26.1.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b33edd6dc28f0dc96f908ee7de414af931bb8fe1 tag=v26.6.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-25 -->
