# 昇腾算力栈 diff 雷达 2026-06-26

## 摘要
- mind-cluster 本期都是稳定性收尾,无新能力/无 API 变更:① clusterd 修内存泄漏——把 Pod Update 事件从"复用 SavePod"改成独立 `UpdatePod(old,new)`,补齐旧 key 在多级缓存里的迁移;② ascend-device-plugin 把 rackid 拓扑 label/cm 收窄为仅 1D/2D 超节点形态(非 950 形态不再带 rackid);③ npu-exporter/noded 日志备份上限 30→180。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)全 EMPTY,无新提交。
- 无硬信号命中([弃用/移除]/[API/CRD变更]/[架构方向]/[版本跨档]/[新能力] 均无)。

## 当日重要改变
- 无(本期改动均为 bug 修复 / 行为收窄,未触及 CRD、顶层 package、proposal 或版本跨档)。

## mind-cluster: 5b283530 -> 88b0fddd
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/5b2835306bb329a9fc6073042ea389cfe413d2fe...88b0fddd758e171dfa61c4ebecc3109621ca0bd0 | tag: v26.0.1 | commits=22 | truncated=false

### AI 总结重点(源码 diff 为据)
- **clusterd 内存泄漏修复:Pod Update 不再走 SavePod,新增独立 `UpdatePod(oldPod,newPod)`**。原先 collector 对 Add 和 Update 两类事件都调 `pod.SavePod(newPod)`,而 SavePod 只按 newPod 的 key 往 `podMap/nodePodMap/jobPodMap` 写;当 Pod 更新导致 NodeName 或 jobKey 变化时,旧 key 在 nodePodMap/jobPodMap 里不会被清,长期 reschedule/热迁移场景下三级缓存膨胀。本期把 Update 分支拆出走 `UpdatePod`(内部 `updatePodInCache(old,new)` 做旧→新迁移),SavePod/DeletePod 也抽成 `addPodInCache/deletePodInCache` 复用同一把锁。
  <details><summary>代码依据 component/clusterd/pkg/application/jobv2/collector.go</summary>

  ```diff
   	switch operator {
  -	case constant.AddOperator, constant.UpdateOperator:
  +	case constant.AddOperator:
   		pod.SavePod(newPodInfo)
   		refreshCmWhenPodRescheduleInPlace(oldPodInfo, newPodInfo)
   		recordPodErrorOnFailure(oldPodInfo, newPodInfo, operator)
  +	case constant.UpdateOperator:
  +		pod.UpdatePod(oldPodInfo, newPodInfo)
  +		refreshCmWhenPodRescheduleInPlace(oldPodInfo, newPodInfo)
  +		recordPodErrorOnFailure(oldPodInfo, newPodInfo, operator)
   	case constant.DeleteOperator:
  ```
  </details>
  <details><summary>代码依据 component/clusterd/pkg/domain/pod/pod_storage.go</summary>

  ```diff
   func SavePod(podInfo *v1.Pod) {
  -	if podInfo == nil { ... return }
   	podManager.podMapMutex.Lock()
  -	if len(podManager.podMap) > maxPodNum { ... return }
  -	podKey := GetPodKey(podInfo)
  -	jobKey := GetJobKeyByPod(podInfo)
  -	podManager.podMap[podKey] = *podInfo
  -	...nodePodMap / jobPodMap 手写赋值...
  +	podKey, jobKey := addPodInCache(podInfo)
   	podManager.podMapMutex.Unlock()
  +// UpdatePod save pod with lock
  +func UpdatePod(oldPod *v1.Pod, newPod *v1.Pod) {
  +	podManager.podMapMutex.Lock()
  +	podKey, jobKey := updatePodInCache(oldPod, newPod)
  +	podManager.podMapMutex.Unlock()
  +	...热迁移 running 事件投递...
  +}
  ```
  </details>

- **rackid 拓扑标签收窄为仅 1D/2D 超节点形态**。device-plugin 给节点打 `TopoLabelRackId` 以及写入 NodeDeviceInfo 缓存的 `RackID` 字段,原先只要 `GetRackID()>=0`(910A5 场景)就无条件带上;现在加 `GetSuperPodType()` 闸门,仅 `ProductType1D / ProductType2D` 才带 rackid——对应提交"非950形态label 和cm不应有rackid"。顺带修了一处日志 bug:打 rackid 时误打了 `superPodId`,改回 `rackId`。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager.go</summary>

  ```diff
  -		rackId := hdm.manager.GetRackID()
  -		if int(rackId) >= 0 {
  -			hwlog.RunLog.Infof("npu device add rackid label: %d", superPodId)
  -			newLabelMap[npuCommon.TopoLabelRackId] = strconv.Itoa(int(rackId))
  +		superPodType := hdm.manager.GetSuperPodType()
  +		if superPodType == common.ProductType1D || superPodType == common.ProductType2D {
  +			rackId := hdm.manager.GetRackID()
  +			if int(rackId) >= 0 {
  +				hwlog.RunLog.Infof("npu device add rackid label: %d", rackId)
  +				newLabelMap[npuCommon.TopoLabelRackId] = strconv.Itoa(int(rackId))
  +			}
   		}
  ```
  </details>
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
   	if common.ParamOption.RealCardType == api.Ascend910A5 {
  -		rackID := tool.GetRackID()
  -		nodeDeviceData.RackID = &rackID
  +		superPodType := tool.GetSuperPodType()
  +		if superPodType == common.ProductType1D || superPodType == common.ProductType2D {
  +			rackID := tool.GetRackID()
  +			nodeDeviceData.RackID = &rackID
  +		}
   	}
  ```
  </details>

- **新增/调整故障码处置策略**(faultCode.json):新增 `81B38010` 进首个故障码列表、`81B38002` 进 `RestartBusinessCodes`(可重启业务码);同时把 `81B18603` 从 `PreSeparateNPUCodes`(预隔离)移除——即该码不再触发预隔离。对应"新增故障码0x81B38010和0x81B38002"。
  <details><summary>代码依据 component/ascend-device-plugin/build/faultCode.json</summary>

  ```diff
  -    "81B78009","81AF8009"
  +    "81B78009","81AF8009",
  +    "81B38010"
     ],
     "RestartBusinessCodes":[
  -    "B406000D","B4060014","B4060010","B4060011","80E01801"
  +    "B406000D","B4060014","B4060010","B4060011","80E01801","81B38002"
     ],
     "PreSeparateNPUCodes":[
  -    "110001024","81B18603",
  +    "110001024",
  ```
  </details>

- **PodGroup 缓存防空 key 写入**:clusterd `SavePodGroup` 在 `GetJobKeyByPG(pg)==""` 时直接 return,避免空 key 污染 `pgMap`(配合上面的内存泄漏修复一同收敛缓存健壮性)。
  <details><summary>代码依据 component/clusterd/pkg/domain/podgroup/pg_storage.go</summary>

  ```diff
  -	pgManager.pgMap[GetJobKeyByPG(pgInfo)] = *pgInfo
  +	key := GetJobKeyByPG(pgInfo)
  +	if key == "" {
  +		return
  +	}
  +	pgManager.pgMap[key] = *pgInfo
  ```
  </details>

- **日志备份文件上限 30→180**:npu-exporter 与 noded 的 `--maxBackups` 默认值由 `hwlog.DefaultMaxBackups` 改为 `hwlog.DefaultBackups`,帮助文案 range 由 `(0, 30]` 改为 `(0, 180]`——提高运维场景下的日志留存上限。对应"修改日志保存个数最大值"。
  <details><summary>代码依据 component/npu-exporter/cmd/npu-exporter/main.go(noded/main.go 同改)</summary>

  ```diff
  -	flag.IntVar(&logger.HwLogConfig.MaxBackups, maxBackupsStr, hwlog.DefaultMaxBackups,
  -		"Maximum number of backup log files, range is (0, 30]")
  +	flag.IntVar(&logger.HwLogConfig.MaxBackups, maxBackupsStr, hwlog.DefaultBackups,
  +		"Maximum number of backup log files, range is (0, 180]")
  ```
  </details>

### 后续发展方向 [AI]
- clusterd 缓存层(pod/podgroup)正在做一轮系统性健壮化:Update 走独立路径、空 key 拦截、抽公共 `*InCache` 函数。证据只覆盖 pod_storage / pg_storage 两文件的 hunk,未见是否还有 job/device 维度缓存的同类整改。
- rackid 按 superPodType 分形态下发,说明拓扑标签(superPodId/rackId/serverIndex)的"分形态精细化"在推进——950(1D/2D 超节点)与非 950 的标签集开始分化。证据仅 device-plugin 打标这一段,未见消费侧(for-volcano 调度)是否已据 superPodType 区分排布。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin —— 均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=88b0fddd758e171dfa61c4ebecc3109621ca0bd0 tag=v26.0.1 scanned=2026-06-26 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b28f10a1e98ec0c2af8be45928e08e689d4a7fb4 tag=1.0.1 scanned=2026-06-26 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-26 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-26 -->
