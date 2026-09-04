# 昇腾算力栈 diff 雷达 2026-09-05

## 摘要
- 本期只有 `Ascend/mind-cluster` 有实质改动(8 commits,全落在 `ascend-for-volcano` 调度器 + `npu-exporter`),主题是**给昨日新建的 chip-affinity/拓扑感知调度补数据入口 + 修两处网络故障感知的调度正确性**:①`huawei.com/schedule.mode`(hard/soft,即昨日 chip-affinity `Request.Mode`)现在可从 **Pod 注解**读取(PodGroup 优先、Pod 兜底);②单机任务(`NPUTaskNum<=1`)**无条件容忍参数面网络故障**,修单机任务无法调度到 linkdown 节点;③节点含 vNPU 卡时整卡拓扑串解析不再因 vnpu token 解析失败而整体作废,修"有 vnpu 时整卡分布式调度感知不到 linkdown"。
- 无 CRD/API 类型变更(`type.go` 改的是注解 key 白名单 slice,非 `_types.go`),无新增/删除包。npu-exporter 仅日志文案与 `Debug→Debugf` 格式化修正。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)全 EMPTY,无新提交。

## 当日重要改变
- mind-cluster `[新能力]` `huawei.com/schedule.mode` 注解加入 `plugin/type.go` 的注解传播白名单(`getJobAnnotationFromJobInfo` 消费),使昨日 chip-affinity 的 hard/soft 调度模式可**从 Pod 注解设置**;测试确认 PodGroup 注解优先、缺失时回退读 task Pod 注解。证据 `ascend-for-volcano/plugin/type.go`、`plugin/job_test.go`。 https://gitcode.com/Ascend/mind-cluster/compare/6a2e299e85af9de5a06c8bb81a17b7640bf86923...38399a0e7916e826574b50d230988b60dcf1dcfd
- mind-cluster `[调度修复]` `setParameterPlaneUnhealthyTolerance` 增 `|| sJob.NPUTaskNum <= 1`:单机/零任务 NPU 作业**无条件**容忍参数面网络亚健康,修"单机任务无法调度到网络故障节点"。证据 `ascend-for-volcano/plugin/job.go`。 https://gitcode.com/Ascend/mind-cluster
- mind-cluster `[调度修复]` `ChangeTopToIntArray` 把 Atoi 失败时的 `return nil` 改为 `continue`:节点存在 vNPU 卡(如 `Ascend910-2c-100-0`)时不再让整卡拓扑串解析整体作废,修"有 vnpu 时整卡分布式调度感知不到 linkdown"。证据 `ascend-for-volcano/common/util/util.go`。 https://gitcode.com/Ascend/mind-cluster

## mind-cluster: 6a2e299e -> 38399a0e
- 比较: 6a2e299e..38399a0e | tag: v26.2.0.beta.1 | commits=8 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/6a2e299e85af9de5a06c8bb81a17b7640bf86923...38399a0e7916e826574b50d230988b60dcf1dcfd

### AI 总结重点(源码 diff 为据)

- **`huawei.com/schedule.mode` 接入注解传播白名单——chip-affinity 的 hard/soft 模式现在可按 Pod 注解设置**。`plugin/type.go` 里那段 `var (...)` 注解 key 列表(与 `InferServiceScheduleAnnoKey`/`AffinityConfig`/`ParameterPlaneUnhealthyToleranceAnnoKey` 并列,由 `getJobAnnotationFromJobInfo` 从 PodGroup/Pod 收集到 job 级 `Annotation`)新增 `util.ScheduleModeAnnoKey`。`plugin/job_test.go` 新增两个用例确认语义:**PodGroup 上的 `schedule.mode` 优先于 Pod**,PodGroup 缺失时**回退读 task Pod 的注解**(用例 06 单 Pod `hard` → 生效;用例 07 PodGroup `soft` + Pod `hard` → 取 `soft`)。这把昨日 `chip-affinity` 里 `Request.Mode`/`ParseScheduleMode`(只有字面量 `"hard"` 才是硬模式)的**数据入口**打通了——之前只有解析逻辑,现在有了从工作负载注解取值的链路。
  <details><summary>代码依据 ascend-for-volcano/plugin/type.go + plugin/job_test.go</summary>

  ```diff
  // type.go —— 注解 key 传播白名单
   var (
   		util.InferServiceScheduleAnnoKey,
   		util.AffinityConfig,
   		util.ParameterPlaneUnhealthyToleranceAnnoKey,
  +		util.ScheduleModeAnnoKey,
   	}
   )
  // job_test.go —— 语义:PodGroup 优先,Pod 兜底
  +	name: "06-getJobAnnotationFromJobInfo fallback schedule.mode from task pod annotation",
  +	args: ...Tasks: {"task1": Pod{Annotations: {ScheduleModeAnnoKey: "hard"}}}...
  +	want: {ScheduleModeAnnoKey: "hard"},
  +	name: "07-getJobAnnotationFromJobInfo podgroup schedule.mode takes precedence over pod",
  +	args: ...PodGroup{Annotations: {ScheduleModeAnnoKey: "soft"}}, Tasks: {...Pod: "hard"}...
  +	want: {ScheduleModeAnnoKey: "soft"},
  ```
  </details>

- **单机/零任务 NPU 作业无条件容忍参数面网络亚健康**。`plugin/job.go` 的 `setParameterPlaneUnhealthyTolerance` 判定由 `if ok && val == "true"` 扩为 `if ok && val == "true" || sJob.NPUTaskNum <= 1`——即除了显式 `huawei.com/parameterplane.unhealthy-tolerance=true` 注解外,**只要作业 NPU 任务数 ≤1**(单机/无分布式)就把 `ParameterPlaneUnhealthyTolerance` 置 true。语义:单机任务不依赖参数面(跨机)网络,linkdown 节点对它无害,故放行调度。对应提交"修复单机任务无法调度到网络故障节点"。测试同步改造(`TestSetParameterPlaneUnhealthyTolerance` 全部用例加 `npuTaskNum` 维度、原 05 条改为多任务)。
  <details><summary>代码依据 ascend-for-volcano/plugin/job.go</summary>

  ```diff
   func (sJob *SchedulerJob) setParameterPlaneUnhealthyTolerance() {
   	val, ok := sJob.Annotation[util.ParameterPlaneUnhealthyToleranceAnnoKey]
  -	if ok && val == "true" {
  +	if ok && val == "true" || sJob.NPUTaskNum <= 1 {
   		sJob.NPUJob.ParameterPlaneUnhealthyTolerance = true
   	}
   }
  ```
  </details>

- **vNPU 卡不再打断整卡拓扑串解析(修 linkdown 感知)**。`common/util/util.go` 的 `ChangeTopToIntArray`(把形如 `Ascend910-0,Ascend910-1` 的拓扑字符串转成卡号 int 数组)在 `strconv.Atoi` 失败时,由 `return nil`(整个解析作废)改为 `continue`(跳过该 token)。场景:节点上有 vNPU 卡时,拓扑串里混入 `Ascend910-2c-100-0` 这类切分卡 token,去前缀后是 `2c-100-0`、Atoi 失败——旧逻辑直接返回 nil,导致该节点整卡拓扑为空、**整卡分布式调度感知不到 linkdown 故障**;新逻辑跳过 vnpu token 保留整卡。测试 `05-ChangeTopToIntArray skip vnpu card`:`"Ascend910-0,Ascend910-2c-100-0,Ascend910-2"` → `[0,2]`(旧行为返回 nil)。注意这也改变了空/非法输入的返回:全非法输入现在返回 `[]int{}` 而非 `nil`(见 `util_test.go` 用例 03 want 从 `nil` 改 `[]int{}`),下游若区分 nil/empty 需留意。
  <details><summary>代码依据 ascend-for-volcano/common/util/util.go</summary>

  ```diff
   func ChangeTopToIntArray(topStr string, npuCardPreName string) []int {
   		cardInt, err := strconv.Atoi(v)
   		if err != nil {
   			klog.V(LogErrorLev).Infof("ChangeTopToIntArray conv failed %v.", err)
  -			return nil
  +			continue
   		}
   		topInt = append(topInt, cardInt)
  ```
  </details>

- **npu-exporter:采集日志文案纠偏 + `Debug`→`Debugf` 格式化修正**(次要)。`collector/common/npu_collector.go` 里两条采集日志把误导性的"by hccn_tool"/"by dcmi" 改为"in multi goroutine"/"in single goroutine"(实际采集器是动态的 `dueCollectors`,原文案把手段写死了),并把 `logger.Debug("...%v...", ...)` 修成 `logger.Debugf(...)`——`Debug` 不接受格式化参数,原写法占位符不会被填充。纯可观测性修正,无采集逻辑变化。
  <details><summary>代码依据 npu-exporter/collector/common/npu_collector.go</summary>

  ```diff
  -	logger.Debug("start to collect npu info by hccn_tool, phyID: %v, collectors: %v", ...)
  +	logger.Debugf("start to collect npu info in multi goroutine, phyID: %v, collectors: %v", ...)
  -	logger.Infof("end to collect npu info by hccn_tool, ...")
  +	logger.Infof("end to collect npu info in multi goroutine, ...")
  -	logger.Debugf("start to collect npu info by dcmi, collectors: %v", ...)
  +	logger.Debugf("start to collect npu info in single goroutine, collectors: %v", ...)
  ```
  </details>

### 后续发展方向 [AI]
- 本期是昨日 chip-affinity/拓扑感知调度大改的**配套收尾**:昨天建了 `ScheduleMode`(hard/soft)解析与拓扑树,今天把 `huawei.com/schedule.mode` 接进注解传播链(PodGroup 优先、Pod 兜底),意味着 hard/soft 模式对用户是**Pod 级可配**的了。趋势清楚——先落调度内核、再补用户可配的注解入口;但注解值到 `chip-affinity` 内核的完整消费路径(`getJobAnnotationFromJobInfo` → `ParseScheduleMode` → `Request.Mode`)本区间只见到入口白名单一段,未读到中间赋值 hunk。
- 两处修复都指向**参数面(跨机)网络故障感知**的边界打磨:单机任务放行到 linkdown 节点、vNPU 混部节点整卡拓扑解析不再被切分卡 token 打断。说明昇腾在把"网络故障→调度决策"这条链在**单机/vNPU 混部**等边缘场景上补齐正确性,而非加新功能。证据只覆盖两个判定点的改法,未见对应的端到端故障注入测试。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY(仅保锚点,无新提交)</summary>

- npu-operator(无新提交,tag v26.6.0)
- npu-container-toolkit(无新提交,tag v26.6.0)
- npu-driver-installer(无新提交,tag v26.6.0)
- vNPU(无新提交,tag v0.1.0)
- npu-node-provision(无新提交,tag v26.6.0)
- npu-dra-plugin(无新提交,tag v26.6.0)
- volcano-ext(无新提交,tag v1.9.0)
- ub-network-device-plugin(无新提交,tag 1.0.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=38399a0e7916e826574b50d230988b60dcf1dcfd tag=v26.2.0.beta.1 scanned=2026-09-05 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f3cfd270f0dda85b259f4041d6c99824920e17e5 tag=v26.6.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-09-05 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=ef44c337d16e208fc1557b8e56a77447f30bc2a7 tag=1.0.2 scanned=2026-09-05 -->
