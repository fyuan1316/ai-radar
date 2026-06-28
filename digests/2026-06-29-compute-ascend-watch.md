# 昇腾算力栈 diff 雷达 2026-06-29

## 摘要
- mind-cluster:ascend-for-volcano 调度器给**分布式作业的抢占可调度判断**接入"网络故障感知"——当 `NPUTaskNum>1` 时,从节点可用 NPU 总数里**扣减被标为网络不健康(NetworkUnhealthy annotation)的卡**再判断能否抢占,避免把训练任务调到 fabric 已故障的卡上。
- infer-operator 修了一个**死锁**:`recordWorkLoadFault` 早返回路径漏放锁,改用 `defer r.Unlock()`。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期全无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- mind-cluster [新能力] ascend-for-volcano 抢占调度新增网络故障感知:分布式作业 total 卡数扣除 NetworkUnhealthy 卡,新增 `subtractNetUnhealthyNPU` / `getNetworkUnhealthyNPUKey` 函数。证据 component/ascend-for-volcano/npu.go,提交 https://gitcode.com/Ascend/mind-cluster/commit/3c49dbed391b
- mind-cluster [弃用/移除] 无;[修复] infer-operator rescheduling 死锁修复(锁泄漏),component/infer-operator/pkg/controller/rescheduling/rescheduling.go,提交 https://gitcode.com/Ascend/mind-cluster/commit/213145ab2033

## mind-cluster: 1f52b28f -> 2b57acd0
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/1f52b28fb17293606d492ff64e9c2432f715b0bd...2b57acd0763f9f9220c3e8e54ebed79da4cbac06 | tag: v26.0.1 | commits=8 | truncated=false

### AI 总结重点(源码 diff 为据)
- **抢占可调度判断对分布式作业增加"网络不健康卡"扣减**。`isNPUSchedulableByPreemption` 原来直接用 `vcNode.GetChipCount()` 返回的 `total` 与请求数比较;现在新增分支:当 `vcJob.NPUJob.NPUTaskNum > 1`(即分布式/多 task 作业)时,先调用 `subtractNetUnhealthyNPU` 把网络故障卡从 total 里减掉再判断。语义上是把"卡在线但 fabric 通信不健康"的卡视为不可用于分布式训练抢占——单机作业(NPUTaskNum≤1)行为不变。

  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
   	_, total, _ := vcNode.GetChipCount(v1.ResourceName(vcTask.ReqNPUName))
  +	// for distributed job, need to remove the net unhealthy npu from total
  +	if vcJob.NPUJob.NPUTaskNum > 1 {
  +		total = subtractNetUnhealthyNPU(vcNode, vcTask.ReqNPUName, total)
  +	}
   	result := vcTask.ReqNPUNum <= total
  ```
  </details>

- **新增两个辅助函数定义"网络不健康卡"的来源与口径**。`getNetworkUnhealthyNPUKey` 按请求卡型拼 annotation key:`NPUCardName` 走 `<NPUCardName>-NetworkUnhealthy`,其余(910 系)走 `<HwPreName><Ascend910>-NetworkUnhealthy`;`subtractNetUnhealthyNPU` 读节点该 annotation,用 `util.ChangeTopToIntArray` 解析成卡号数组,total 减去其长度。即**故障卡清单由节点 annotation 携带**(很可能由 noded/故障诊断链路写入),调度器只做消费。

  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
  +func subtractNetUnhealthyNPU(node plugin.NPUNode, reqNPUName string, total int) int {
  +	netUnhealthyKey := getNetworkUnhealthyNPUKey(reqNPUName)
  +	netUnhealthyStr, ok := node.Annotation[netUnhealthyKey]
  +	if !ok || netUnhealthyStr == "" {
  +		return total
  +	}
  +	annoPreVal := util.NPU910CardNamePre
  +	if reqNPUName == util.NPUCardName {
  +		annoPreVal = util.NPUCardNamePre
  +	}
  +	netUnhealthyTop := util.ChangeTopToIntArray(netUnhealthyStr, annoPreVal)
  +	return total - len(netUnhealthyTop)
  +}
  ```
  </details>

- **infer-operator rescheduling 死锁修复**。`recordWorkLoadFault` 在 `r.Lock()` 后,若该 workload 已在 `faultWorkLoadMap` 里会走早返回(只处理首个故障),原代码把 `r.Unlock()` 放在函数体末尾,早返回路径不经过它→锁泄漏导致后续所有取锁挂死。改为 `r.Lock()` 紧跟 `defer r.Unlock()`,所有返回路径都释放。配套测试用 `TryLock`/超时回归该早返回路径。

  <details><summary>代码依据 component/infer-operator/pkg/controller/rescheduling/rescheduling.go</summary>

  ```diff
   	r.Lock()
  +	defer r.Unlock()
   	// if a workload has multi faults, only process the first fault to reschedule workload
   	_, exists := r.faultWorkLoadMap[currentFaultWorkLoad]
   	...
  -	r.Unlock()
   	hwlog.RunLog.Infof("record fault: %s for workload %s/%s", ...)
  ```
  </details>

### 后续发展方向 [AI]
- 网络故障感知正从"故障检测"向"**调度面消费**"闭环:这次只动了抢占路径(`isNPUSchedulableByPreemption`),后续大概率会把 NetworkUnhealthy 口径推广到普通 predicate/打分与 reschedule 触发。证据只覆盖抢占判断这一处 hunk,未见普通分配路径与 annotation 写入侧改动。
- 故障卡的"通信级健康"与传统"卡级健康"被分成两套口径(NetworkUnhealthy 独立 annotation),说明昇腾把多机训练 fabric(RoCE/HCCS)健康度当一等公民纳入调度——与 ub-network-device-plugin 方向呼应,但本期未见两者代码联动。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓本期无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:自 06-28 锚点以来无新提交,保锚点链。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=2b57acd0763f9f9220c3e8e54ebed79da4cbac06 tag=v26.0.1 scanned=2026-06-29 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-29 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-29 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-29 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-29 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-29 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b28f10a1e98ec0c2af8be45928e08e689d4a7fb4 tag=1.0.1 scanned=2026-06-29 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-29 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-29 -->
