# 昇腾算力栈 diff 雷达 2026-10-01

## 摘要
- 唯一实质改动在 `mind-cluster/clusterd` 的**原地恢复(recover-in-place / 断点续训)**故障处理:`getFaultDevices` 在采集待恢复故障设备时,除 L1 故障外**新增排除"预隔离 NPU(PreSeparateNPU)"**,即已被预隔离的卡不再进入原地恢复的故障设备清单。
- 其余均为文档/README 提交(infer-operator 快照说明、dpu-exporter README、故障类型 Excel、clusterops-agent 文档),无代码信号。
- openFuyao 全部 8 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期均无新提交。

## 当日重要改变
- mind-cluster [行为变更] clusterd 原地恢复的故障设备采集逻辑收窄:`getFaultDevices` 遍历 `FaultDeviceList` 时,过滤条件由"仅跳过 L1 故障"改为"跳过 L1 故障**或** FaultLevel==PreSeparateNPU"。效果:处于"预隔离"态的 NPU 不再被纳入原地恢复的故障设备,其故障码/故障时间也不会写入 `FaultDetail`。提交 https://gitcode.com/Ascend/mind-cluster/commit/acf44a9753e5
  - 注:未命中本 task 预设的形式化信号([API/CRD变更]/[架构方向] 等);属可观测的故障处理语义变化,单列以便跟踪断点续训恢复策略走向。

## mind-cluster: 721f79b6 -> 3779de1d
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/721f79b617a1ff64729e1146b2fb165ffa691a00...3779de1d5dd633929d21066767a6c9efedbeb937 | tag: v26.1.1(未变)| commits=12 | truncated=false
- 信号文件全部落在 `component/clusterd/pkg/application/faultmanager/.../recoverinplace/` 与 `recover/controller.go`;其余提交为纯文档。

### AI 总结重点(源码 diff 为据)
- **原地恢复采集故障设备时排除"预隔离 NPU"**:`recoverInplaceFaultProcessor.getFaultDevices` 的 continue 判据由 `IsL1Fault(fault.FaultLevel)` 扩为 `IsL1Fault(fault.FaultLevel) || fault.FaultLevel == constant.PreSeparateNPU`。语义上,"预隔离"这一介于健康与正式隔离之间的中间态,现被视为"无需(或不应)走原地恢复流程的故障",从恢复设备清单中剔除。新增单测明确:同一卡上同时存在 RestartRequest 与 PreSeparateNPU 两条故障时,结果 `FaultCodeLevel` 只保留 restartRequest 码、`FaultTime` 取 RestartRequest 的时间(而非更早的 PreSeparate 时间),即预隔离故障被完全忽略。
  <details><summary>代码依据 component/clusterd/pkg/application/faultmanager/cmprocess/recoverinplace/recover_inplace_processor.go</summary>

  ```diff
  	for _, deviceFaults := range deviceInfo.FaultDeviceList {
  		for _, fault := range deviceFaults {
  -			if faultdomain.IsL1Fault(fault.FaultLevel) {
  +			if faultdomain.IsL1Fault(fault.FaultLevel) || fault.FaultLevel == constant.PreSeparateNPU {
  				continue
  			}
  ```
  </details>
  <details><summary>代码依据 component/clusterd/pkg/application/faultmanager/cmprocess/recoverinplace/recover_inplace_processor_test.go(新增用例)</summary>

  ```diff
  +	t.Run("getFaultDevices, exclude PreSeparateNPU", func(t *testing.T) {
  +		...
  +		res := RecoverInplaceProcessor.getFaultDevices(nodeName, deviceInfo)
  +		faultDetail := res.DeviceInfo[deviceName].FaultDetail
  +		assert.Equal(t, map[string]string{faultCode: constant.RestartRequest}, faultDetail.FaultCodeLevel)
  +		assert.Equal(t, currentTime, faultDetail.FaultTime)   // 取 RestartRequest 时间,非 PreSeparate 的 oldTime
  +	})
  ```
  </details>
- **recover/controller.go 仅工程性微调**:给 `clusterd/pkg/interface/grpc/recover` 包加 `pb` 别名导入,并在 `updateRestartProcessOrPodInfo` 合并 pod-rank 故障后加一行 Debug 日志(`update pod rank fault ...`),无行为变化。
  <details><summary>代码依据 component/clusterd/pkg/application/recover/controller.go</summary>

  ```diff
  -	"clusterd/pkg/interface/grpc/recover"
  +	pb "clusterd/pkg/interface/grpc/recover"
  ...
  		podRankFault.FaultType = podRankFault.FaultType | fault.FaultType
  +		hwlog.RunLog.Debugf("jobId=%s, update pod rank fault %v", ctl.jobInfo.JobId, podRankFault)
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾断点续训/原地恢复对"故障分级"的处理在持续精细化:此前已区分 L1/RestartRequest/SeparateNPU,本次把 **PreSeparateNPU(预隔离)** 独立出恢复路径,说明故障状态机在"健康 → 预隔离 → 正式隔离"之间做了更明确的边界——预隔离态不触发原地重启恢复,避免对尚未正式隔离的卡做无谓恢复动作。证据仅覆盖 `getFaultDevices` 这一采集入口,**未见** PreSeparateNPU 的产生/流转(谁把卡置为预隔离、何时升级为 SeparateNPU)对应的代码,方向判断限于恢复侧消费逻辑。
- 对我们产品的启示:若自研故障自愈/断点续训也在做 NPU/GPU 故障分级,需同样引入"预隔离"这类中间态并明确各态是否进入自动恢复,否则对刚探测到疑似故障、尚未确诊的卡反复触发恢复会放大抖动。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- npu-operator:无新提交(tag v26.6.0)
- npu-container-toolkit:无新提交(tag v26.6.0)
- npu-driver-installer:无新提交(tag v26.6.0)
- vNPU:无新提交(tag v0.1.0)
- npu-node-provision:无新提交(tag v26.6.0)
- npu-dra-plugin:无新提交(tag v26.6.0)
- volcano-ext:无新提交(tag v1.9.0)
- ub-network-device-plugin:无新提交(tag 1.0.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=3779de1d5dd633929d21066767a6c9efedbeb937 tag=v26.1.1 scanned=2026-10-01 -->
<!-- ANCHOR repo=npu-operator sha=c806e3c8e0ef6a8a271293497d08fdf848dd0e1a tag=v26.6.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-10-01 -->
</content>
</invoke>
