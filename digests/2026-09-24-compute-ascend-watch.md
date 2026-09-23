# 昇腾算力栈 diff 雷达 2026-09-24

## 摘要
- mind-cluster 的 ascend-for-volcano 重调度模块本期做了两处治理:①推理任务"Pod 级重调度且原因为 external-force-pod-failed"时,不再把重调度原因写入 job-reschedule-reason configmap(避免污染 job 级统计);②给输出 configmap 引入 Labels 机制并给重调度原因 CM 打 consumer 标签,同时 RescheduleReason 记录里补 JobUID。
- npu-dra-plugin 让每个昇腾设备(含软切分 vNPU)在原有自定义 `numaNode` 属性外,再暴露 K8s DRA **标准属性键 `resource.kubernetes.io/numaNode`**,向上游 DRA 原生 NUMA 亲和对齐。
- 其余 7 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / volcano-ext / ub-network-device-plugin)本期无新提交。

## 当日重要改变
- npu-dra-plugin [API/属性对齐] 昇腾 DRA 设备新增标准键 `resource.kubernetes.io/numaNode`,让 kube-scheduler 原生 NUMA 感知无需识别厂商私有属性即可消费昇腾拓扑 https://gitcode.com/openFuyao/npu-dra-plugin/compare/5d7339c517d971eaeb0b915bd19ed3d90db3c44c...a091c78614ecd0c00412b15aa8a0d2ecd717ba39
- mind-cluster [行为变更] ascend-for-volcano 收窄 job-reschedule-reason configmap 的写入条件:Pod 级重调度 + external-force-pod-failed 不再计入 https://gitcode.com/Ascend/mind-cluster/compare/1e8de3e03f2f6a331ceccb613202f5abaace6831...fc5ebd5f6693824842f77b9147909ed6e209a952

## mind-cluster: 1e8de3e0 -> fc5ebd5f
- 比较: 1e8de3e0..fc5ebd5f | tag: v26.1.1 | commits=28 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/1e8de3e03f2f6a331ceccb613202f5abaace6831...fc5ebd5f6693824842f77b9147909ed6e209a952

### AI 总结重点(源码 diff 为据)
- **`doRestartJob` 新增 `skipRecordReason` 分支:当 `ReScheduleKey == JobExternalForcePodFailedReschedulingPrefix` 且 `IsJobSingleRescheduling`(即 Pod 级/单 Pod 重调度)为真时,跳过 `updateRescheduleReason` 不写 configmap**。语义:外部强制 Pod 失败触发的 Pod 级重调度属于"外力"而非调度器决策,不应污染 job 级重调度原因统计。前:所有 doRestartJob 成功分支都无条件累计原因;后:上述组合被显式跳过并打 warning 日志。

  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go</summary>

  ```diff
  -		reScheduler.JobRecentRescheduleRecords[restartFaultJob.JobUID] =
  -			updateRescheduleReason(reScheduler.JobRecentRescheduleRecords[restartFaultJob.JobUID], restartFaultJob)
  +		// skip recording reschedule reason when pod-level rescheduling is external-force-pod-failed
  +		skipRecordReason := restartFaultJob.ReScheduleKey == JobExternalForcePodFailedReschedulingPrefix &&
  +			restartFaultJob.IsJobSingleRescheduling(&schedulerJob)
  +		if skipRecordReason {
  +			klog.V(util.LogWarningLev).Infof("job<%s> skip recording reschedule reason to configmap, "+
  +				"because pod-level rescheduling is external-force-pod-failed", restartFaultJob.JobUID)
  +		} else {
  +			reScheduler.JobRecentRescheduleRecords[restartFaultJob.JobUID] =
  +				updateRescheduleReason(...)
  +		}
  ```
  </details>

- **`RescheduleReason` 结构体新增 `JobUID api.JobID` 字段**,由 `fJob.UUID` 填充,与既有 `JobID`(逻辑 job id)并列。此前原因记录只有 JobID;现在同时记 K8s 对象 UUID,便于跨重建(同名 job 重建后 UID 变)精确定位记录。

  <details><summary>代码依据 internal/rescheduling/type.go + reschedule.go</summary>

  ```diff
   type RescheduleReason struct {
   	// JobID the job id of this record
   	JobID api.JobID
  +	// JobUID the job uid of this record
  +	JobUID api.JobID
   ...
   	Reasons = &RescheduleReason{
  -		JobID: fJob.JobUID,
  +		JobID:  fJob.JobUID,
  +		JobUID: api.JobID(fJob.UUID),
   	}
  ```
  </details>

- **输出缓存 `ScheduleCache` 新增 `Labels map[string]map[string]string`,并在 `saveCacheToCm` 把 `Labels[spName]` 写到生成 configmap 的 `ObjectMeta.Labels`**;`setRescheduleReasonToCache` 据此给重调度原因 CM 打上 `{NormalCmConsumer: CmConsumerValue}` 标签。以前 output CM 无标签,消费方只能靠名字识别;现在可用 label selector 过滤"哪些 CM 是给谁消费的"。

  <details><summary>代码依据 plugin/factory.go + plugin/type.go + internal/rescheduling/cache.go</summary>

  ```diff
   type ScheduleCache struct {
   	Names, Namespaces map[string]string
   	Data              map[string]map[string]string
  +	// Labels labels of each cm keyed by the cm key
  +	Labels map[string]map[string]string
   }
  ...
   	ObjectMeta: metav1.ObjectMeta{
   		Name:      cmName,
   		Namespace: nameSpace,
  +		Labels:    sHandle.ScheduleEnv.OutputCache.Labels[spName],
   	},
  ...
  +	env.OutputCache.Labels[ReschedulingReasonKey] =
  +		map[string]string{util.NormalCmConsumer: util.CmConsumerValue}
  ```
  </details>

### 后续发展方向 [AI]
- ascend-for-volcano 的重调度语义在做精细化:区分"调度器决策的重调度"与"外部强制 Pod 失败",且用 JobUID + CM label 让下游(如 clusterd/监控)更精确消费重调度原因。方向是让故障重调度链路的可观测/归因更严谨。证据只覆盖 rescheduling 模块的 configmap 写入路径,未见消费端(读该 label 的组件)改动。
- 本区间 28 commit 里其余多为文档(弹性扩缩容原理图、断点续训示例、MindSpore 26.2.0 不再支持进程级重调度/恢复的说明)、DPU-exporter 去掉 cardType 启动参数改默认端口、故障诊断(FD)源文件配置修正,均非核心算力栈能力变更,未逐一展开。

## npu-dra-plugin: 5d7339c5 -> a091c786
- 比较: 5d7339c5..a091c786 | tag: v26.6.0 | commits=4 | truncated=false
- 源: https://gitcode.com/openFuyao/npu-dra-plugin/compare/5d7339c517d971eaeb0b915bd19ed3d90db3c44c...a091c78614ecd0c00412b15aa8a0d2ecd717ba39

### AI 总结重点(源码 diff 为据)
- **在设备属性构造两处(`buildDevice` 处理物理设备、`getSoftDeviceAttributes` 处理软切分 vNPU)都新增了 K8s DRA 标准键 `resource.kubernetes.io/numaNode`,与既有厂商私有键 `numaNode` 同值并存**。意义:K8s 1.34+ DRA 的原生 NUMA 亲和/拓扑对齐能力识别的是标准键 `resource.kubernetes.io/numaNode`,此前昇腾只暴露私有 `numaNode`,调度器无法直接消费;现在软/硬切分设备都能被上游标准 NUMA 逻辑纳管。

  <details><summary>代码依据 Ascend-npu-dra-plugin/internal/profiles/npu/dcmi.go + npu.go</summary>

  ```diff
   // dcmi.go buildDevice(物理设备)
   	if spec.NumaNode != nil && *spec.NumaNode >= 0 {
   		attributes["numaNode"] = resourceapi.DeviceAttribute{IntValue: ptr.To(int64(*spec.NumaNode))}
  +		attributes["resource.kubernetes.io/numaNode"] = resourceapi.DeviceAttribute{IntValue: ptr.To(int64(*spec.NumaNode))}
   	}

   // npu.go getSoftDeviceAttributes(软切分 vNPU)
   		if numaNode, ok := physDev.Attributes["numaNode"]; ok {
   			attributes["numaNode"] = numaNode
  +			attributes["resource.kubernetes.io/numaNode"] = numaNode
   		}
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 DRA 插件在主动向 K8s DRA 上游语义靠拢:用官方保留属性前缀 `resource.kubernetes.io/` 暴露拓扑,减少对厂商私有 CEL 表达式的依赖,让原生调度器直接做 NUMA 亲和。这与 NVIDIA/上游 DRA 的演进方向一致。证据仅覆盖 numaNode 一个属性的标准化,未见其他拓扑属性(HCCS ring 等)是否也计划标准化。
- 另 3 处改动为 README-zh 里用户手册链接从个人仓 `panchaolai/sig-orchestration-engine` 修正到 `openFuyao/sig-orchestration-engine`(仓库归属转正,非能力变更)。

## 本期无实质改动(折叠)
<details><summary>7 个仓无新提交</summary>

- npu-operator(无新提交)
- npu-container-toolkit(无新提交)
- npu-driver-installer(无新提交)
- vNPU(无新提交)
- npu-node-provision(无新提交)
- volcano-ext(无新提交)
- ub-network-device-plugin(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=fc5ebd5f6693824842f77b9147909ed6e209a952 tag=v26.1.1 scanned=2026-09-24 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-24 -->
