# 昇腾算力栈 diff 雷达 2026-06-07

## 摘要
- mind-cluster 本期唯一主线在 **ascend-for-volcano 的重调度(rescheduling)**:修"进程级恢复场景下节点宕机 volcano 不能快速重调度"——给故障任务新增 `ProcessException`(进程异常)故障类型,让"软件故障(进程级)"的 task 在新 pod 报错时**直接被判定为故障任务**触发重调度,不再等它命中 pod 级失败映射表。
- 8 个 openFuyao 仓本期均无新提交;tag 仍停在 `v26.1.0.beta.1`,无跨档。

## 当日重要改变
- mind-cluster [新能力] ascend-for-volcano 重调度链路新增进程级故障类型 `ProcessException`,`updateFaultJobWhenNewPodError` 对 `IsSoftwareFault` 的 task 直接置 `IsFaultTask=true` 并标 `faultType=ProcessException`,补齐"进程恢复场景节点宕机快速重调度"路径。证据 `component/ascend-for-volcano/internal/rescheduling/job.go`、`type.go`。 https://gitcode.com/Ascend/mind-cluster/compare/21ad9f7e8b50d308bb63f1c811eafb1024238d63...a93469f8f1ff26cb74366013f960c842aac3f6b6

## mind-cluster: 21ad9f7e -> a93469f8
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/21ad9f7e8b50d308bb63f1c811eafb1024238d63...a93469f8f1ff26cb74366013f960c842aac3f6b6 | tag v26.1.0.beta.1 | commits=2 | truncated=false(信号已按 component/ 限定)

### AI 总结重点(源码 diff 为据)

- **ascend-for-volcano:重调度新增"进程异常"故障类型,软件故障 task 在新 pod 报错时直接判故障**。`updateFaultJobWhenNewPodError` 遍历 `fJob.FaultTasks` 时,原逻辑只在 task 命中 `newFailedTask`(本轮新失败的 pod 集合,即 pod/硬件级失败)时才把它标成 `IsFaultTask=true`、`faultType=PodFailed`;本期在该判断**之前**插入一个分支:只要 `fTask.IsSoftwareFault` 为真,就直接 `IsFaultTask=true` 且 `faultType=ProcessException` 并 `continue`。即把"进程级软件故障"从"得等它体现为 pod 失败才被重调度"提前到"识别到软件故障即纳入故障任务",对应提交标题"修复进程级恢复场景节点宕机 volcano 不能快速重调度的问题"——进程恢复(process-recover)场景里节点宕机时,task 可能尚未被映射进 `newFailedTask`,旧逻辑漏判导致重调度滞后。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/job.go</summary>

  ```diff
   		if fTask.IsFaultTask {
   			continue
   		}
  +		if fTask.IsSoftwareFault {
  +			fJob.FaultTasks[i].IsFaultTask = true
  +			fJob.FaultTasks[i].faultType = ProcessException
  +			continue
  +		}
   		if _, ok := newFailedTask[fTask.TaskUID]; ok {
   			fJob.FaultTasks[i].IsFaultTask = true
   			fJob.FaultTasks[i].faultType = PodFailed
  ```
  </details>

- **新增故障状态常量 `ProcessException = "process-exception"`**,与既有 `PodFailed = "pod-failed"`、`PodHealthy = "pod-healthy"` 并列,把"pod 级失败"与"pod 内进程级异常"在故障类型枚举上正式区分开——这是上面新分支能落地的前提,也说明昇腾重调度模型从"pod 粒度故障"细化到"进程粒度故障"。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/type.go</summary>

  ```diff
   	// PodFailed the state of failed pod
   	PodFailed = "pod-failed"
  +	// ProcessException the state of failed process in the pod
  +	ProcessException = "process-exception"
   	// PodHealthy the state of healthy pod
   	PodHealthy = "pod-healthy"
  ```
  </details>

- 配套补 `TestUpdateFaultJobWhenNewPodError` 两条用例:校验 ① 无 `ProcessRecoverEnable` label 时早返回(`IsFaultTask` 仍 false)、② 已是 `IsFaultTask=true` 的 task 保持不变。印证该进程级故障判定受 `util.ProcessRecoverEnable` label 门禁,仅在开启进程恢复的 job 上生效,不影响普通 job。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/job_test.go</summary>

  ```diff
  +	t.Run("01-updateFaultJobWhenNewPodError return when labels not meet", func(t *testing.T) {
  +		fJob := &FaultJob{
  +			Labels:     map[string]string{},
  +			FaultTasks: []FaultTask{{IsSoftwareFault: true}},
  +		}
  +		fJob.updateFaultJobWhenNewPodError(jobInfo)
  +		if fJob.FaultTasks[0].IsFaultTask { t.Errorf("...should return early...") }
  +	})
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾重调度的故障模型在从"pod/硬件级"向"进程级(software fault)"下探:本期把进程异常做成独立故障类型并接进 `updateFaultJobWhenNewPodError`,配合 `ProcessRecoverEnable` label 门禁,指向"断点续训 / 进程级恢复(process-recover)"场景下更快的故障感知与重调度。证据覆盖 job.go(新分支)、type.go(新常量)、job_test.go(label 门禁);**未见**该 `IsSoftwareFault` 字段由谁置位(应在更上游的故障探测/CM 解析,本区间未落入 component/ 信号文件),也未见 `ProcessException` 类型下的重调度动作(retry 次数、是否原地拉起 vs 换节点)与 `PodFailed` 有何差异,需后续区间确认进程级与 pod 级重调度策略的分叉点。

## 本期无实质改动(保锚点)
- npu-operator、npu-container-toolkit、npu-driver-installer、vNPU、npu-node-provision、npu-dra-plugin、volcano-ext、ub-network-device-plugin:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=a93469f8f1ff26cb74366013f960c842aac3f6b6 tag=v26.1.0.beta.1 scanned=2026-06-07 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-07 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-07 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-07 -->
<!-- ANCHOR repo=vNPU sha=1c407018907f5a41b9ffba929aa98453ca7798d3 tag=v0.1.0 scanned=2026-06-07 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-07 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-07 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-07 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-07 -->
