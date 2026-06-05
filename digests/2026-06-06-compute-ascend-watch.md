# 昇腾算力栈 diff 雷达 2026-06-06

## 摘要
- mind-cluster 本期主线在 **ascend-device-plugin 的网络故障处理**:新增 UBOE(UB over Ethernet)链路 down 检测,核心是"按掉链端口数判断隔离粒度"——部分卡掉链就隔离(Separate),全节点都掉链则只标亚健康(SubHeal)不连坐隔离,避免 fabric 级故障误隔离整机;配套新增两个 UBOE 端口故障码与故障码分类表更新。
- infer-operator 修了一个对账顺序 bug:把扩缩容(scaling)状态回写从"依附 workload 对账成功"中解耦出来独立提交,workload 调谐失败不再吞掉 scaling 状态更新。其余为大量 DT(开发者测试)用例补充。
- tag 从 `v26.0.0` 跨到 `v26.1.0.beta.1`(minor 进 beta)。8 个 openFuyao 仓本期均无新提交。

## 当日重要改变
- mind-cluster [新能力] ascend-device-plugin 新增 UBOE 链路 down 检测,`HandleUBOELinkDownCheck`/`DoHandleUboeLinkDownCheck` 按掉链设备数决定上报"隔离"还是"亚健康"故障码,仅对 Atlas950/9501D/850 主板生效;新增故障码 `UBOEPortDownCode1=0x81B18603`、`UBOEPortDownCode2=0x81078607`。证据 `component/ascend-device-plugin/pkg/device/ascendcommon.go`、`pkg/common/fault_code.go`。 https://gitcode.com/Ascend/mind-cluster/blob/21ad9f7e8b50d308bb63f1c811eafb1024238d63/component/ascend-device-plugin/pkg/device/ascendcommon.go
- mind-cluster [版本跨档] tag 从 v26.0.0 进到 v26.1.0.beta.1(minor 跨档,进 beta 通道)。 https://gitcode.com/Ascend/mind-cluster/releases

## mind-cluster: a1074aba -> 21ad9f7e
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/a1074aba3b01ca9ced1973e98874801a19991745...21ad9f7e8b50d308bb63f1c811eafb1024238d63 | tag v26.1.0.beta.1 | commits=18 | truncated=false(信号已按 component/ 限定)

### AI 总结重点(源码 diff 为据)

- **ascend-device-plugin:新增 UBOE 链路 down 检测,"按掉链规模决定隔离 vs 亚健康"**。`DevManager` 接口新增 `HandleUBOELinkDownCheck(device, *devices)` 与 `DoHandleUboeLinkDownCheck(devices)`。检测仅在主板属于 `{Atlas950, Atlas9501D, Atlas850(×3 板型)}` 时启用;读 `GetDeviceAllErrorCode`,命中 `UBOEPortDownCode1`(0x81B18603)的设备先收集进切片,命中 `UBOEPortDownCode2`(0x81078607)的走 bonding 口状态判定。关键策略在 `generateOrdinaryUboeFaultEvents`:**若掉链设备数 ≠ 全部设备数 → 上报 `UBOESeparateFaultCode`(隔离);若全部设备都掉链 → 上报 `UBOESubHealFaultCode`(亚健康,不隔离)**。即把"端口/链路 down"从"逐卡硬隔离"改成"局部坏才隔离、整体坏只降级",避免交换机/fabric 级故障把整机误隔离。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  +func (tool *AscendTools) HandleUBOELinkDownCheck(device *common.NpuDevice, devices *[]*common.NpuDevice) {
  +	serverPodIdList := sets.NewInt(api.Atlas950MainBoardID, api.Atlas9501DMainBoardID, api.Atlas850MainBoardID, ...)
  +	if !serverPodIdList.Has(int(tool.dmgr.GetMainBoardId())) { return }
  +	_, errCodes, err := tool.dmgr.GetDeviceAllErrorCode(device.LogicID)
  +	if slices.Contains(errCodes, common.UBOEPortDownCode1) { *devices = append(*devices, device); return }
  +	if slices.Contains(errCodes, common.UBOEPortDownCode2) { tool.generateUboeBondingFaultEvents(device); return }
  +}
  +func (tool *AscendTools) generateOrdinaryUboeFaultEvents(devices []*common.NpuDevice) {
  +	devNum, _, err := tool.dmgr.GetDeviceList()
  +	var eventID int64
  +	if devNum != int32(len(devices)) { eventID = npuCommon.UBOESeparateFaultCode  // 部分掉链 → 隔离
  +	} else { eventID = npuCommon.UBOESubHealFaultCode }                            // 全掉链 → 仅亚健康
  +	for _, device := range devices { ... DoSaveDevFaultInfo(faultInfo, false) }
  +}
  ```
  </details>

- **检测挂进周期性故障订阅循环,按设备组批处理**。`manager.go` 的 `mendSubscribeFaultEvents` 在每个 `groupDevice` 内逐卡调 `HandleUBOELinkDownCheck` 把掉链卡收集到组级 `uboeDownDevices`,组遍历完后再调一次 `DoHandleUboeLinkDownCheck`——这样"是否整组都掉链"的判断才有完整分母,印证上面的"按规模决定隔离/亚健康"逻辑落在组粒度上。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager.go</summary>

  ```diff
   func (hdm *HwDevManager) mendSubscribeFaultEvents() {
   	for _, npuDevices := range hdm.groupDevice {
  +		var uboeDownDevices []*common.NpuDevice
   		for _, npuDevice := range npuDevices {
   			hdm.manager.HandleLostNetworkFaultEvents(npuDevice, initLogicIDs)
  +			hdm.manager.HandleUBOELinkDownCheck(npuDevice, &uboeDownDevices)
   			hdm.manager.HandleHangCardFaultEvents(npuDevice)
   		}
  +		hdm.manager.DoHandleUboeLinkDownCheck(uboeDownDevices)
   	}
   }
  ```
  </details>

- **故障码分类表更新(faultCode.json + 常量)**。`fault_code.go` 新增 `UBOEPortDownCode1=0x81B18603`、`UBOEPortDownCode2=0x81078607` 两个常量;`build/faultCode.json` 把 `020001002` 加进 `SeparateNPUCodes`(直接隔离)、新增 `PreSeparateNPUCodes:["110001024"]`(预隔离)、`SubHealthFaultCodes` 增加 `110000002`。说明本期不止加了 UBOE 一类,故障分级表整体在细化"隔离 / 预隔离 / 亚健康"三档。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go + build/faultCode.json</summary>

  ```diff
  +	// UBOEPortDownCode1 uboe port down fault code
  +	UBOEPortDownCode1 = 0x81B18603
  +	// UBOEPortDownCode2 uboe port down fault code
  +	UBOEPortDownCode2 = 0x81078607
  ```
  ```diff
  -    ...,"80DF8402","80818C00"
  +    ...,"80DF8402","80818C00","020001002"
  -  "PreSeparateNPUCodes":[],
  +  "PreSeparateNPUCodes":["110001024"],
  -    "81B18605","81078607"
  +    "81B18605","81078607","110000002"
  ```
  </details>

- **infer-operator:扩缩容状态回写与 workload 对账解耦(bugfix)**。原 `Reconcile` 先 `reconcileWorkLoads` 再处理 scaling,且 scaling 状态搭 workload 一起在 `updateStatus` 回写;一旦 workload 调谐失败(非 requeue 错误)就走不到回写,scaling 状态被吞。改后顺序调成**先 scaling 后 workload**,且 scaling 状态走独立的 `updateStatusForScaling`(带 `RetryOnConflict` + 仅 diff 才写);同时 `updateStatus` 回写 workload 状态时显式保存/恢复 `ScalingResourceStatus` 与 `LabelSelector`,防止两条回写路径互相覆盖。提交标题即"workload调谐失败不更新scalingstatus"。
  <details><summary>代码依据 component/infer-operator/pkg/controller/v1/instanceset_controller.go</summary>

  ```diff
  -	// 4. reconcile workloads
  -	workloadErr := r.reconcileWorkLoads(ctx, instanceSet)
  -	// 5. reconcile scaling resources
  +	// 4. reconcile scaling resources, anyway it will continue to reconcile workloads
   	scalingStatus, scalingErr := r.reconcileScalingResources(ctx, instanceSet)
  +	if scalingErr == nil {
  +		if err := r.updateStatusForScaling(ctx, instanceSet, scalingStatus); err != nil { ... }
  +	}
  +	// 5. reconcile workloads
  +	workloadErr := r.reconcileWorkLoads(ctx, instanceSet)
   	if common.IsRequeueError(workloadErr) || workloadErr == nil {
  -		instanceSet.Status.ScalingResourceStatus = scalingStatus
   		if err := r.updateStatus(ctx, instanceSet); err != nil { ... }
   func (r *InstanceSetReconciler) updateStatus(...) error {
  +		// ensure that updateStatus does not overwrite the value updated by updateStatusForScaling
  +		savedScalingStatus := latestInstanceSet.Status.ScalingResourceStatus
  +		latestInstanceSet.Status = newStatus
  +		latestInstanceSet.Status.ScalingResourceStatus = savedScalingStatus
  ```
  </details>

> 仅见提交标题、未落入 component/ 信号文件(在我限定的 8 个子目录之外,多属 ascend-common / fault-diag),不展开符号级:`[ascend-common]增加dcmi接口 dcmi_get_device_multi_utilization_rate_period`(新增多卡利用率周期采样 DCMI 接口,利好 npu-exporter 后续接入)、`[feat][FD]bmc fault update`、`[feat][FD]Precise link positioning`、`[FD][Fix]support parse ipv6 addr in socket error log`、`remove AISW_CANN_AICPU_08`、`【docs】【FD】链路诊断工具增加set_config_dir命令`。

### 后续发展方向 [AI]
- 昇腾 DP 的故障处理正从"逐卡硬隔离"走向"故障分级 + 规模感知隔离":本期 UBOE 链路用"局部坏才隔离、整组坏只降级"避免 fabric/交换机故障误连坐整机,叠加 faultCode.json 把故障码细分成 Separate/PreSeparate/SubHealth 三档——指向大规模 UB 组网超节点下"网络抖动不轻易踢卡"。证据覆盖 ascendcommon.go(规模判定)、manager.go(组级批处理)、fault_code.go/faultCode.json(分级),**未见**上层调度器(noded/clusterd/for-volcano)如何消费 UBOESeparate/SubHeal 这两类新事件、亚健康卡是否仍可调度,需后续区间确认闭环。
- infer-operator 把 scaling 状态机做成独立回写路径(RetryOnConflict + 防覆盖),是上期 HPA 弹性扩缩容能力的稳态化收尾,而非新功能;证据为本期纯 controller 逻辑 + DT 补充、无 `*_types.go` 字段变更。**未见**扩缩容指标源是否接入新加的 DCMI 多卡利用率接口。

## 本期无实质改动(保锚点)
- npu-operator、npu-container-toolkit、npu-driver-installer、vNPU、npu-node-provision、npu-dra-plugin、volcano-ext、ub-network-device-plugin:无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=21ad9f7e8b50d308bb63f1c811eafb1024238d63 tag=v26.1.0.beta.1 scanned=2026-06-06 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=vNPU sha=1c407018907f5a41b9ffba929aa98453ca7798d3 tag=v0.1.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-06 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-06 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-06 -->
</content>
</invoke>
