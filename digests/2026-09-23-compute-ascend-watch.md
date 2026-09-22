# 昇腾算力栈 diff 雷达 2026-09-23

## 摘要
- mind-cluster 本期两条实打实的能力改动:①ascend-for-volcano 调度器新增 **RunningRestoreHook / RestoreAnnotation** 机制,修复"抢占/回收驱逐被撤销(unevict rollback)后 Running Pod 重新走 AllocateFunc 会错误重选卡、错误更新节点资源"的问题——现在从 pod 自身 annotation 原样恢复芯片,不重选;②clusterd 关联故障处理新增 **ExpiredRelationFaults + clearTimeOutRecoveredRelationFault**,让 A3 job 的已恢复 linkdown 故障"超时后再判 CQE 关联分离",收紧分离触发时机。
- openFuyao 全 8 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期均无新提交。

## 当日重要改变
- mind-cluster [新能力] ascend-for-volcano 新增 `RunningRestoreHook` 接口 + `RestoreAnnotation` 实现(plugin/base/chip/controller 四层),补齐"驱逐回滚不重选卡"的恢复路径,同时把 `NPUAllocateFunc` 前置校验抽成 `isTaskNeedNPUAllocated`、分配主体拆成 `allocateOrRestoreNode`/`applyNodeAllocation`/`postAllocateTask`。证据文件 component/ascend-for-volcano/plugin/plugin.go、internal/npu/base/frame.go、internal/npu/affinity/chip/chip.go、internal/controller.go、plugin/task.go。https://gitcode.com/Ascend/mind-cluster/compare/b3fbd192b9a785c689d5c3857ffbed5eca756cb4...1e8de3e03f2f6a331ceccb613202f5abaace6831
- mind-cluster [新能力] clusterd relationfault 新增 `ExpiredRelationFaults` 字段与 `clearTimeOutRecoveredRelationFault`,实现"已恢复 linkdown 超时后触发 CQE 关联分离策略"。证据文件 component/clusterd/pkg/application/faultmanager/jobprocess/relationfault/relation_fault_processor.go。https://gitcode.com/Ascend/mind-cluster/compare/b3fbd192b9a785c689d5c3857ffbed5eca756cb4...1e8de3e03f2f6a331ceccb613202f5abaace6831

## mind-cluster: b3fbd192 -> 1e8de3e0
- 比较: b3fbd192b9a785c689d5c3857ffbed5eca756cb4..1e8de3e0 | tag: v26.1.1 | commits=24 | truncated=false
- 源:https://gitcode.com/Ascend/mind-cluster/compare/b3fbd192b9a785c689d5c3857ffbed5eca756cb4...1e8de3e03f2f6a331ceccb613202f5abaace6831

### AI 总结重点(源码 diff 为据)

- **ascend-for-volcano 调度器补齐"驱逐回滚"恢复语义:新增 `RunningRestoreHook` 可选能力接口 + 各层 `RestoreAnnotation` 实现。** 昇腾调度里,一个已 Running 的 task 只有在"抢占/回收发起的驱逐被撤销(unevict rollback)"时才会重新进入 `NPUAllocateFunc`。此前该路径会走 `policyHandler.UseAnnotation` 重新选卡并改写 pod annotation,导致节点资源被错误更新;现在新增的 restore 路径直接读 pod 自身 annotation 里已分配的 chipIDs、把它们重新登记到 `ChipTopo` 树(`TryAllocate`)并从节点 free-top annotation 再扣减(`UpdateNodeInfo`),**不重选、不改写 pod**。对应提交"修复Running Pod Allocate错误更新节点资源信息问题"。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/plugin.go</summary>

  ```diff
  +// RunningRestoreHook is an optional capability for policy handlers to re-apply
  +// an already-Running task's allocation on the node from the pod's existing
  +// annotation (unevict rollback after a discarded preempt/reclaim eviction),
  +// instead of re-selecting chips. The node free-top annotation and chip tree are
  +// restored to the pre-eviction state; the pod annotation is left untouched.
  +type RunningRestoreHook interface {
  +	RestoreAnnotation(*api.TaskInfo, NPUNode) *NPUNode
  +}
  ```
  </details>
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/chip.go</summary>

  ```diff
  +func (tp *chipHandler) RestoreAnnotation(task *api.TaskInfo, node plugin.NPUNode) *plugin.NPUNode {
  +	...
  +	chipIDs := util.GetAllocatedChipIDsFromPod(task.Pod)
  +	if len(chipIDs) == 0 { ...; return nil }
  +	if err := root.TryAllocate(string(task.Pod.UID), chipIDs); err != nil { ...; return nil }
  +	return tp.UpdateNodeInfo(node, chipIDs)
  +}
  ```
  </details>
  <details><summary>代码依据 component/ascend-for-volcano/internal/controller.go(按 handler 是否实现 RunningRestoreHook 分发)</summary>

  ```diff
  +func (c *Controller) RestoreAnnotation(task *api.TaskInfo, node plugin.NPUNode) *plugin.NPUNode {
  +	...
  +	for _, handler := range c.PolicyHandler {
  +		hook, ok := handler.(plugin.RunningRestoreHook)
  +		if !ok { continue }
  +		if newNode := hook.RestoreAnnotation(task, node); newNode != nil { node = *newNode }
  +	}
  +	return &node
  +}
  ```
  </details>

- **`NPUAllocateFunc` 从"一坨顺序逻辑"重构为分层小函数,分配路径显式区分 allocate vs restore。** 原函数把 nil 校验、DRA bypass、`isTaskNeedNPUAllocated` 判断、分布式标注、选卡、扣资源、故障通知全写在一起;现在前置校验抽成 `isTaskNeedNPUAllocated`(nil / DRA / 非 NPU task 三种情况统一返回 false),分布式/单机标注抽成 `markDistributionMode`(纯依赖 job 形状、恢复路径也幂等),主体改为 `allocateOrRestoreNode` + `applyNodeAllocation` + `postAllocateTask`(后者记录 pod→node 映射并同步 SuperPods)。这同时修了"节点内通用亲和调度策略未正确释放节点资源"的另一半。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/task.go</summary>

  ```diff
  -	if task == nil { ...; return }
  -	if util.IsDRATask(task) { ...; return }
  -	if !sHandle.isTaskNeedNPUAllocated(task) { ...; return }
  +	if !sHandle.isTaskNeedNPUAllocated(task) { return }
   	...
  +	sHandle.markDistributionMode(task, vcJob)
  +	newNode := sHandle.allocateOrRestoreNode(task, vcJob, node, nodeName)
  +	sHandle.applyNodeAllocation(task, vcJob, nodeName, newNode)
  +	if sHandle.FaultHandle != nil { sHandle.FaultHandle.UseAnnotation(task) }
  +	sHandle.postAllocateTask(task, &vcJob, nodeName)
  ```
  </details>

- **clusterd 关联故障:新增"已恢复但未超时"的中间态跟踪,收紧 A3 job 的 CQE 关联分离触发。** `FaultJob` 结构体新增 `ExpiredRelationFaults []*constant.FaultInfo` 字段;`preStartProcess` 遍历 `TMOutRelationFaults` 时,把"已过 `DealMaxTime` 窗口"的故障单独挑进 `expiredRelationFaults` 而非直接丢弃;`preStopProcess` 新增调用 `clearTimeOutRecoveredRelationFault`。语义:A3 job 的 linkdown 故障已恢复(移入 TMOutRelationFaults)但尚未超时时,只有等它真正超时,才回看 deal max time 窗口内是否出现 CQE trigger fault,再决定是否分离——即 CQE 关联分离只在 linkdown 故障超时后触发,而不是恢复即触发。对应提交"支持已恢复linkdown超时后触发CQE关联分离策略"。
  <details><summary>代码依据 component/clusterd/.../relationfault/relation_fault_processor.go</summary>

  ```diff
   type FaultJob struct {
   	...
  +	ExpiredRelationFaults []*constant.FaultInfo
   	...
   }
   func (fJob *FaultJob) preStartProcess() {
  +	expiredRelationFaults := make([]*constant.FaultInfo, 0)
   	for _, fault := range fJob.TMOutRelationFaults {
   		if now-fault.FaultTime > fault.DealMaxTime*constant.Kilo {
  +			expiredRelationFaults = append(expiredRelationFaults, fault)
   			continue
   		}
   		tmpTMOutRelationFaults = append(tmpTMOutRelationFaults, fault)
   	}
  +	fJob.ExpiredRelationFaults = expiredRelationFaults
   }
   func (fJob *FaultJob) preStopProcess() {
   	fJob.clearProcessedAndTimeOutFault()
  +	fJob.clearTimeOutRecoveredRelationFault()
   	fJob.processFaultStrategies()
   }
  ```
  </details>

- **文档:ascend-for-volcano README 整体重写(320→178 行),对外口径升级。** 从"NPU亲和性调度算法设计说明与开发指导"改为标准的"Ascend for Volcano"组件文档结构,明确列出功能集:HCCS 亲和性/整卡调度/超节点调度/多级调度、**静态硬切分/动态硬切分/软切分**三种切分模式、以及故障感知重调度。ascend-operator README 修正断点续训文档路径编号(`04_fault_recovery`→`05_fault_recovery`)。属对外能力叙事,非代码行为改动。

### 后续发展方向 [AI]
- unevict rollback 恢复路径是这次的核心:`RunningRestoreHook` 用可选接口(type assertion 分发)接入,意味着后续其他 policy handler(如 nslb TorHandler,注释已明确它不参与节点 annotation 管理)可以按需实现而不动主流程——调度器在往"驱逐/回滚全生命周期资源账本一致"方向收敛。证据只覆盖 chip/base 两个 handler 的 restore 实现 + controller 分发,未见 DRA 路径或 vNPU 软切分场景下的 restore 行为。
- clusterd 的 `ExpiredRelationFaults` 引入了"已恢复未超时"这一显式中间态,是把 A3 超节点网络故障的 CQE 关联判定从"瞬时"改为"带超时窗口的两阶段",降低误分离。证据只覆盖 preStartProcess 挑拣 + preStopProcess 触发 clear,`clearTimeOutRecoveredRelationFault` 的完整判定体(CQE trigger fault 窗口匹配逻辑)因 hunk 截断未全部覆盖。

## 本期无实质改动(折叠)
<details><summary>openFuyao 8 仓本期无新提交</summary>

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
<!-- ANCHOR repo=mind-cluster sha=1e8de3e03f2f6a331ceccb613202f5abaace6831 tag=v26.1.1 scanned=2026-09-23 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-23 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-23 -->
