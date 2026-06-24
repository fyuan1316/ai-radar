# 昇腾算力栈 diff 雷达 2026-06-25

## 摘要
- mind-cluster(clusterd)把训练任务统计 `JobStatistic` 整体升级为 `JobStatisticV2`,新增独立 `faultcodeevent` 处理器 + `PodErrorInfo`/`FaultCodeAndTimestamp` 字段,给每条硬件故障/Pod 失败打上**时间戳并写进 job event log**——故障可观测性从"有没有故障"细化到"何时、哪个节点/卡故障",服务于断点续训的精准定位。
- ascend-for-volcano 修复 deployment 扩缩容时 rankIndex 被重复改写的异常:`setRankIndex` 改为**已有 rankIndex 注解就早退**,保证幂等。
- ascend-device-plugin 加固 `CreateFileIfNotExist`,补目录冲突检测 + 递归建父目录,关联"软切分场景挂载共享配置到容器 /dev/shm 内容被清空"的修复。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期无新提交。

## 当日重要改变
- mind-cluster [新能力] clusterd 新增 `faultcodeevent` 子包 + `FaultCodeEventLogProcessor`,把活跃任务的故障码去重后落 job event log。证据 `component/clusterd/pkg/application/faultmanager/jobprocess/faultcodeevent/fault_code_event_processor.go`(新增 136 行) https://gitcode.com/Ascend/mind-cluster/commit/5b2835306bb329a9fc6073042ea389cfe413d2fe
- mind-cluster [API/结构变更] job 统计结构从 `JobStatistic` 迁到 `JobStatisticV2`(内嵌前者 + Version/故障码时间戳/Pod 错误时间戳),`CurrJobStatistic.JobStatistic` map 值类型整体换型。证据 `component/clusterd/pkg/common/constant/type.go`。注:这是内部 Go 结构,非 k8s CRD。
- mind-cluster [稳定性] ascend-for-volcano `setRankIndex` 幂等化,修扩缩容 rankIndex 异常。证据 `component/ascend-for-volcano/internal/npu/base/task.go`。

## mind-cluster: 0f88ecd6 -> 5b283530
- 比较 / 最新 Release:0f88ecd6..5b283530 | tag v26.0.1 | commits=20 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/0f88ecd66b0922e8e3c953def81460e04d9b9c27...5b2835306bb329a9fc6073042ea389cfe413d2fe

### AI 总结重点(源码 diff 为据)

- **新增 `faultcodeevent` 处理器:把活跃任务的故障码去重落 event log。** `FaultCodeEventLogProcessor.Process` 从 `faultrank.JobFaultRankProcessor` 拉每个 job 的故障列表,用 `buildFaultDigest`(对 ServerId|FaultCode|FaultLevel|FaultTime|DeviceId 排序拼串)做指纹;指纹未变则跳过,变了才 `UpdateJobStatistic` 写入 `FaultCodesAndTimestamp` 并打 `Job Event` 日志。配套 `processedFaults` map 随 job 消失而清理,避免泄漏。这是把"故障码 → 任务事件日志"做成有状态去重管道。

  <details><summary>代码依据 component/clusterd/pkg/application/faultmanager/jobprocess/faultcodeevent/fault_code_event_processor.go</summary>

  ```diff
  +var Processor = &FaultCodeEventLogProcessor{
  +	processedFaults: make(map[string]string),
  +}
  +func (p *FaultCodeEventLogProcessor) Process(info any) any {
  +	jobFaultInfos := faultrank.JobFaultRankProcessor.GetJobFaultRankInfos()
  +	for jobId := range p.processedFaults {
  +		if _, ok := jobFaultInfos[jobId]; !ok { delete(p.processedFaults, jobId) }
  +	}
  +	for k8sJobID, jobFaultInfo := range jobFaultInfos {
  +		faultDigest := buildFaultDigest(jobFaultInfo.FaultDevice)
  +		if p.processedFaults[k8sJobID] == faultDigest { continue }
  +		p.processedFaults[k8sJobID] = faultDigest
  +		faultCodes := collectActiveFaultCodes(&jobFaultInfo)
  +		statistics.JobStcMgrInst.UpdateJobStatistic(k8sJobID, func(jobStc *constant.JobStatisticV2) {
  +			jobStc.FaultCodesAndTimestamp = appendFaultCodes(k8sJobID, jobStc.FaultCodesAndTimestamp, faultCodes)
  +			logs.JobEventLog.Infof("Job Event: %s", util.ObjToString(jobStc))
  +		})
  +	}
  +}
  ```
  </details>

- **job 统计结构升级 `JobStatistic` → `JobStatisticV2`。** 新结构内嵌旧 `JobStatistic`,加 `Version`(`VersionStr` 类型,空值 marshal 默认 "2")、`FaultCodesAndTimestamp []FaultCodeAndTimestamp`、`PodErrorTimestamp []PodErrorInfo`。`CurrJobStatistic.JobStatistic` 的 map 值类型、`init`/`parseCMData`/`initStcJob` 全部换型;新增 `UpdateJobStatistic(id, fn)` 在写锁内做 get-改-set 原子更新。是把 event_job.log 从"快照"扩成"带版本 + 故障时间序列"的载体。

  <details><summary>代码依据 component/clusterd/pkg/common/constant/type.go + job_collect_utils.go</summary>

  ```diff
  -	JobStatistic map[string]JobStatistic
  +	JobStatistic map[string]JobStatisticV2
  +type FaultCodeAndTimestamp struct {
  +	FaultCode string; Timestamp int64; NodeName string; DeviceId string; FaultLevel string
  +}
  +type PodErrorInfo struct { Timestamp int64; NodeName string; PodName string }
  +type VersionStr string
  +func (v VersionStr) MarshalJSON() ([]byte, error) {
  +	if v == "" { return json.Marshal("2") }
  +	return json.Marshal(string(v))
  +}
  +type JobStatisticV2 struct { JobStatistic; Version VersionStr `json:"version"` ... }
  +// UpdateJobStatistic get, modify and set job statistic atomically under write lock
  +func (j *JobStcMgr) UpdateJobStatistic(k8sJobID string, fn func(*constant.JobStatisticV2)) { ... }
  ```
  </details>

- **Pod 失败时记录错误时间戳/节点/Pod 名。** jobv2 collector 在 Add/Update/Delete 路径接入 `recordPodErrorOnFailure`:仅当 Pod 新转 `PodFailed`(旧态非 Failed)且有 NodeName 时,把 (时间, 节点, podName) 追加进 `PodErrorTimestamp`,满 `MaxTimestampRecords` 则丢最旧(环形)。让任务失败有了精确到 Pod 的时间线。

  <details><summary>代码依据 component/clusterd/pkg/application/jobv2/collector.go</summary>

  ```diff
  +func recordPodErrorOnFailure(oldPodInfo, newPodInfo *v1.Pod, operator string) {
  +	if operator == constant.AddOperator || operator == constant.UpdateOperator {
  +		if newPodInfo.Status.Phase != v1.PodFailed { return }
  +		if oldPodInfo != nil && oldPodInfo.Status.Phase == v1.PodFailed { return }
  +	}
  +	...
  +	statistics.JobStcMgrInst.UpdateJobStatistic(jobKey, func(jobStc *constant.JobStatisticV2) {
  +		jobStc.PodErrorTimestamp = appendPodErrorTimestamp(jobKey, jobStc.PodErrorTimestamp, nowTime, newPodInfo.Spec.NodeName, newPodInfo.Name)
  +	})
  +}
  ```
  </details>

- **故障设备贯通 `FaultTime` 时间戳。** faultrank 多处(`findFaultRankForJob`、`getFaultDeviceInfoByRelationFault`、`getFautDeviceInfoByFaultRank`、`getFaultDeviceInfoByNodeInfo`、`getFaultDeviceInfoBySwitchInfo`)把故障时间从 `FaultTimeAndLevelMap`/`AlarmRaisedTime`/节点 `UpdateTime` 灌进 `FaultDevice.FaultTime`;node_util 新增 `parseUpdateTime` 把 NodeInfo configmap 的 `updateTime`(RFC3339)解析成 UnixMilli 作为节点级故障时间戳。补齐上面两条新结构所需的时间来源。

  <details><summary>代码依据 faultrank/job_fault_rank_processor.go + domain/node/node_util.go</summary>

  ```diff
  +	if faultTimeLevel, ok := fault.FaultTimeAndLevelMap[fault.FaultCode]; ok {
  +		faultRank.FaultTime = faultTimeLevel.FaultTime
  +	}
  +		faultDevice.FaultTime = nodeInfo.UpdateTime
  +func parseUpdateTime(updateTimeStr string) int64 {
  +	parsed, err := time.Parse(time.RFC3339, updateTimeStr)
  +	...; return parsed.UnixMilli()
  +}
  ```
  </details>

- **ascend-for-volcano `setRankIndex` 幂等化,修扩缩容 rankIndex 异常。** 函数开头新增:Pod 已带 `PodRankIndexKey` 注解就直接返回;ReplicaSet 分支设置后也补 `return`;原先散落在条件里的 `== ""` 判空收敛到入口统一短路。防止 deployment 扩缩容时把已分配的 rankIndex 覆盖掉。

  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/base/task.go</summary>

  ```diff
  +	if task.Pod.Annotations[plugin.PodRankIndexKey] != "" {
  +		klog.V(util.LogDebugLev).Infof("task %s already has rankIndex %s, skip setting", ...)
  +		return
  +	}
  	if job.Owner.Kind == plugin.ReplicaSetType {
  		task.Pod.Annotations[plugin.PodRankIndexKey] = strconv.Itoa(job.Tasks[task.UID].Index)
  +		return
  	}
  -	if _, ok := tp.Annotation[util.MinAvailableKey]; ok && task.Pod.Annotations[plugin.PodRankIndexKey] == "" {
  +	if _, ok := tp.Annotation[util.MinAvailableKey]; ok {
  ```
  </details>

- **ascend-device-plugin `CreateFileIfNotExist` 加固。** 原先靠 `isFileNotExist` 单判后建文件;重写为 stat 三态:文件已存在→跳过、同名是目录→返回 path conflict 错误、不存在→递归建父目录再建空文件,且每条路径加 error 日志。关联本期 device-plugin 修复"软切分场景共享配置文件挂到容器 /dev/shm 被清空"问题,避免误把目录当文件 / 父目录缺失导致写空。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/file_manager.go</summary>

  ```diff
  -	if !isFileNotExist(path) { return nil }
  -	...
  -func isFileNotExist(path string) bool {
  	info, err := os.Stat(path)
  	if err == nil {
  -		return info.IsDir() == false
  +		if !info.IsDir() { return nil }
  +		return fmt.Errorf("path conflict: target name is a directory, ... path=%s", path)
  	}
  -	return os.IsNotExist(err)
  +	if os.IsNotExist(err) { ... openAndCheckFile(...O_CREATE|O_TRUNC...); return nil }
  +	return err
  ```
  </details>

### 后续发展方向 [AI]
- clusterd 这轮全是**训练任务故障可观测性**的纵深:V2 统计结构 + 故障码事件日志 + Pod 失败时间线 + FaultTime 贯通,合起来是为断点续训/重调度提供"精确到卡和时刻"的故障证据链。证据覆盖 clusterd 与 faultrank,未见这些时间戳被上游 operator/调度器消费的下游代码(本区间无 ascend-operator/infer-operator 改动)。
- ascend-for-volcano 仅一处幂等修复,未见拓扑/亲和调度算法层改动;方向是稳定性补丁而非调度策略演进。
- 8 个 openFuyao 仓连续无提交,扶摇侧 NPU 驱动容器化/vNPU 线本期静默。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(保锚点)</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=5b2835306bb329a9fc6073042ea389cfe413d2fe tag=v26.0.1 scanned=2026-06-25 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-25 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-25 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-25 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-25 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-25 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b28f10a1e98ec0c2af8be45928e08e689d4a7fb4 tag=1.0.1 scanned=2026-06-25 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-25 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-25 -->
