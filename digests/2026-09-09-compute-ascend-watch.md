# 昇腾算力栈 diff 雷达 2026-09-09

## 摘要
- **仅 `Ascend/mind-cluster` 活跃**(12 提交),集中在故障检测/隔离与推理重调度三处:device-plugin 给参数面链路 down 的恢复探测加了「先密后疏」退避阶梯(5s 起爬到 5min),把原来固定 5 分钟的恢复轮询提速;修了「全卡 UB 端口 down 偶现 020001002 隔离故障」——用延迟一个周期确认再升级 SeparateFault,规避跨周期误报;infer-operator 新增 `external-force-pod-failed` 重调度模式(与昨日报告预告的 Pod 级重调度对齐)。
- 无 CRD/API/proposal 改动;无版本跨档(mind-cluster 仍 v26.2.0.beta.1)。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期全 EMPTY,无新提交,内核零演进。

## 当日重要改变
- mind-cluster [新能力] infer-operator 重调度模式新增第三种取值 `external-force-pod-failed`,与 `external-force` 共用「立即 GracePeriodSeconds(0) 强删」路径,只强删 PodFailed 业务故障而不触发硬件级重调度。证据 `component/infer-operator/pkg/controller/workload/workload_common.go`。https://gitcode.com/Ascend/mind-cluster/commits/master
- mind-cluster [新能力] device-plugin 新增参数面链路 down 恢复的退避阶梯常量 `RecoverNetworkQueryBackoff`(14 档 5→270 秒)+ `recoverBackoff` 状态机,把恢复检测周期从固定 5 分钟改为初期高频、逐步退回 5 分钟。证据 `component/ascend-device-plugin/pkg/common/constants.go` / `pkg/device/ascendcommon.go`。
- mind-cluster [行为变更] 修复全卡 UB 端口 down 时偶现 UBSeparate(020001002)误隔离:改为延迟一个周期确认后再升级 SeparateFault。证据 `component/ascend-device-plugin/pkg/common/fault_code.go`。

## mind-cluster: 8aa01572 -> 38933c22
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/8aa0157273178f9ea33fc3f75d6eac6c22606af6...38933c22 | tag: v26.2.0.beta.1 | commits=12 | truncated=false

### AI 总结重点(源码 diff 为据)

- **device-plugin 参数面链路 down 恢复检测加「先密后疏」退避阶梯**:原逻辑对已知 down 的参数面链路按固定 `EveryNetworkQueryDuration`(5 分钟)轮询,恢复慢;新增常量 `RecoverNetworkQueryBackoff = {5,10,...,270}` 秒 + `recoverBackoff{step,lastCheck}` 状态机,`interval()` 按 step 取阶梯值、走完阶梯后收敛回 5 分钟。配套两张按 phyID 索引的 map:外层 `parameterPlaneRecoverProbeBackoff`(短恢复探测退避)与内层 `parameterPlaneDownQueryBackoff`(已知 down 的查询节流),对应提交「81078603 故障码产生后…5 分钟轮询间隔太长需临时缩短检测周期」。首次探测(lastCheck 为零)立即放行。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/constants.go</summary>

  ```diff
  +// RecoverNetworkQueryBackoff is the escalating re-check interval (in seconds) applied when the parameter
  +// plane link is down, so recovery is detected promptly at first and progressively less frequently. Once the
  +// ladder is exhausted the re-check converges to the original five-minute cadence (EveryNetworkQueryDuration).
  +var RecoverNetworkQueryBackoff = []int64{5, 10, 15, 20, 30, 40, 60, 80, 100, 130, 160, 190, 230, 270}
  ```
  </details>
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  +func (b *recoverBackoff) interval() time.Duration {
  +	step := b.step
  +	if step >= len(common.RecoverNetworkQueryBackoff) {
  +		return common.EveryNetworkQueryDuration * time.Minute
  +	}
  +	return time.Duration(common.RecoverNetworkQueryBackoff[step]) * time.Second
  +}
  +func (b *recoverBackoff) elapsed(now time.Time) bool {
  +	return b.lastCheck.IsZero() || now.Sub(b.lastCheck) >= b.interval()
  +}
  ```
  </details>

- **修复全卡 UB 端口 down 偶现误隔离(020001002/UBSeparate)**:原来 `a950HyperPlaneFaultOccur` 一旦发现 UB down 就当场生成 `UBSeparateFaultCode`;当多卡故障分散在不同处理周期到达时会误报一次隔离故障。新增 `ubPortDownConfirmedMap` + `delayReportUBSeparateFault`:第一次见到 UBPortDown 只记 pending 不升级,第二个周期仍未收敛才升级为 SeparateFault;故障恢复(FaultCodes 不再含 UBPortDownCode)时清除 confirm 标志,保证再次故障仍延迟一个周期。生成 Separate 的逻辑从 `a950HyperPlaneFaultOccur` 移除、下沉到延迟路径。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
  +	// ubPortDownConfirmedMap records the devices whose UB port down fault was already seen
  +	// in a previous processing cycle
  +	ubPortDownConfirmedMap = make(map[int32]bool, GeneralMapSize)

  +func delayReportUBSeparateFault(devices []*NpuDevice) {
  +	for _, device := range devices {
  +		if !Int64Tool.Contains(device.FaultCodes, UBPortDownCode) {
  +			delete(ubPortDownConfirmedMap, device.LogicID)   // 恢复即清标志
  +			continue
  +		}
  +		if !ubPortDownConfirmedMap[device.LogicID] {
  +			ubPortDownConfirmedMap[device.LogicID] = true    // 第一周期只记 pending
  +			continue
  +		}
  +		// 第二周期仍未收敛 → 升级 UBSeparateFaultCode
  ```
  </details>

- **infer-operator 推理重调度新增 `external-force-pod-failed` 模式**:`deletePodsForExternalRescheduling` 原只认 `external-force`(立即强删)与 `external-grace`(按 Pod 优雅期定时强删)两种模式,现把新常量 `ExternalForcePodFailedReschedulingValue` 并入准入判断和 switch,与 `external-force` 共用 `forceDeletePodList` 立即 GracePeriodSeconds(0) 强删路径。语义上是「只对业务 Pod 故障(PodFailed)做重调度」的独立开关,和硬件故障重调度解耦。
  <details><summary>代码依据 component/infer-operator/pkg/controller/workload/workload_common.go</summary>

  ```diff
   	if mode != common.ExternalForceReschedulingValue &&
  -		mode != common.ExternalGraceReschedulingValue {
  +		mode != common.ExternalGraceReschedulingValue &&
  +		mode != common.ExternalForcePodFailedReschedulingValue {
   		return nil
   	}
   	switch mode {
  -	case common.ExternalForceReschedulingValue:
  +	case common.ExternalForceReschedulingValue,
  +		common.ExternalForcePodFailedReschedulingValue:
   		forceDeletePodList(ctx, cli, podList.Items)
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾这两天的主线是 **UB(超节点 fabric)故障处理的精细化**:昨天是 super pod 级重调度,今天是端口 down 的误报抑制 + 恢复探测提速。证据集中在 device-plugin 的 `fault_code.go`/`ascendcommon.go` 与 A950(910A5/超节点)相关分支,说明 A5 超节点大规模组网下的链路抖动误隔离是当前主要打磨点;证据只覆盖 device-plugin 侧故障码与探测节奏,未见对应的 volcano 调度侧消费改动。
- infer-operator 的 `external-force-pod-failed` 把「业务 Pod 故障」从「硬件故障重调度」里拆出成独立触发,方向是**推理服务重调度的触发源分层**(业务失败 vs 硬件失败走不同门禁)。证据只是模式取值与强删路径,未见该 label 的写入方(何时打这个 label、由谁判定 PodFailed)。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin —— 均无新提交(EMPTY)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=38933c2284091216438336a1adf5ff9df985d7b4 tag=v26.2.0.beta.1 scanned=2026-09-09 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f3cfd270f0dda85b259f4041d6c99824920e17e5 tag=v26.6.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=ef44c337d16e208fc1557b8e56a77447f30bc2a7 tag=1.0.2 scanned=2026-09-09 -->
