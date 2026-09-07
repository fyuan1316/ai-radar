# 昇腾算力栈 diff 雷达 2026-09-08

## 摘要
- **mind-cluster / ascend-for-volcano**:推理服务(infer service)调度新增 **pod 级重调度**分支——故障作业不再整体重排,healthy super pod 原样保留、只补故障 slot;为此把 inferservice 基础包的优先级队列/选点函数全部导出(private→Public)供各拓扑策略复用。
- **mind-cluster / rescheduling**:新增故障调度策略 `external-force-pod-failed`——只处理业务 PodFailed、显式跳过所有硬件故障(卡/网络不健康),补齐"仅业务故障外部强删重调度"语义。
- **mind-cluster / clusterd**:版本汇总目标组件新增 `ascend-dra`,配合本区间 dra 组件打印 version+commitid、写节点 annotation、clusterD 收集——DRA 路径继续工程化(版本可观测)。openFuyao 供应商栈 8 仓中 7 仓 EMPTY,volcano-ext 仅 design docs 拼写修正。

## 当日重要改变
- mind-cluster [新能力] ascend-for-volcano 推理服务调度新增 pod 级重调度路径(保留 healthy super pod、只补故障 slot),3 个拓扑策略 + 基础包同步改造。https://gitcode.com/Ascend/mind-cluster/compare/9d6a0171cd3c973ba2db488dbb5bfa093d609412...8aa0157273178f9ea33fc3f75d6eac6c22606af6
- mind-cluster [新能力] rescheduling 新增 `external-force-pod-failed` 策略:只重调度 PodFailed 业务故障、跳过硬件故障。https://gitcode.com/Ascend/mind-cluster/compare/9d6a0171cd3c973ba2db488dbb5bfa093d609412...8aa0157273178f9ea33fc3f75d6eac6c22606af6
- mind-cluster [架构方向] clusterd 版本汇总纳入 `ascend-dra`,DRA 组件版本进入跨节点可观测面。https://gitcode.com/Ascend/mind-cluster/compare/9d6a0171cd3c973ba2db488dbb5bfa093d609412...8aa0157273178f9ea33fc3f75d6eac6c22606af6

## mind-cluster: 9d6a0171 -> 8aa01572
- 比较:9d6a0171...8aa01572 | tag: v26.2.0.beta.1 | commits=20 | truncated=false
- 源:https://gitcode.com/Ascend/mind-cluster/compare/9d6a0171cd3c973ba2db488dbb5bfa093d609412...8aa0157273178f9ea33fc3f75d6eac6c22606af6

### AI 总结重点(源码 diff 为据)
- **推理服务调度新增"pod 级重调度"分支,三个拓扑策略统一入口分流**。`chip8node8sp` / `chip8node8ra64sp` / `ascend910a3.superpod` 三个 `selectNodesForInferService` 顶部统一加故障作业判断:命中 `fJob.IsFaultJob && ifPodLevelRescheduling(fJob)` 时转入新函数 `selectNodesForInferServicePodLevel`,否则走原有整超节点(super-pod)选点。语义从"故障即整作业重排"收窄为"故障作业保留健康超节点、只补故障槽位"。

  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8sp/infer_service.go</summary>

  ```diff
  +	// pod-level rescheduling: keep healthy super pods, refill fault slots only
  +	rescheduleCache := rescheduling.GetReSchedulerCache()
  +	if rescheduleCache != nil {
  +		fJob := rescheduleCache.FaultJobs[task.Job]
  +		if fJob != nil && fJob.IsFaultJob && tp.ifPodLevelRescheduling(fJob) {
  +			return tp.selectNodesForInferServicePodLevel(task, nodes, fJob)
  +		}
  +	}
  +	// full super-pod selection for job-level rescheduling or first scheduling
   	return inferservice.SelectNodesForInferService(inferservice.InferServiceReq{
  ```
  </details>

- **`selectNodesForInferServicePodLevel` 复用故障作业升级链的 Stage 1-3,Stage 4 回退到推理服务优先级队列;并刻意跳过 `selectNodesForFaultJob` 的 schedulable 门禁**(该门禁以 job 级语义校验资源总量,会误伤 pod 级的 Stage 2-4)。Stage 1 保留健康超节点 → Stage 2 同物理超节点内选全新节点组 → Stage 3 同超节点内替换故障节点槽位 → 全 ready 则直接返回,否则进 Stage 4。

  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/ascend910/ascend910a3/superpod/infer_service.go</summary>

  ```diff
  +	// Stage 1: keep healthy super pods. selectNodeFromOriginVSuperPod restores
  +	// SuperPodReschdInfo first, then dispatches by ifPodLevelRescheduling
  +	notReadySuperPod, _ := tp.selectNodeFromOriginVSuperPod(fJob, nil,
  +		selectNodes, totalNodes, vSuperPodID)
  +	// Stage 2: select brand-new node group within the same physical super pod
  +	tp.selectNodeFromOriginSuperPod(fJob, notReadySuperPod, totalNodes, vSuperPodID, selectNodes)
  +	// Stage 3: replace fault node slots within the same physical super pod
  +	tp.selectNodeForPodLevelRescheduling(fJob, notReadySuperPod, totalNodes, vSuperPodID, selectNodes)
  ```
  </details>

- **inferservice 基础包把优先级队列/选点三函数从 private 导出为 Public,供各策略的 pod 级路径复用;`SelectNodesFromSP` 的 spIndex 参数由 `int` 改为 `string`**(调用方直接传字符串 key,去掉包内的 `strconv.Itoa`)。同时新增 `SelectInferServiceSPForPodLevel` 作为 pod 级 Stage 4 回退——用推理服务优先级队列(同 service 超节点优先、其他兜底)填充未 ready 的逻辑超节点,循环内重建队列并把新选中的 SP 并入 sameSPs 以强化后续轮次亲和。

  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/base/inferservice/infer_service.go</summary>

  ```diff
  -	pq := buildPriorityQueue(req.SuperPodTop, sameSPs, req.SpBlock)
  +	pq := BuildPriorityQueue(req.SuperPodTop, sameSPs, req.SpBlock)
   	for i := 0; i < spBlockCount; i++ {
  -		item := popValidSP(pq, req.SuperPodTop, req.SpBlock)
  +		item := PopValidSP(pq, req.SuperPodTop, req.SpBlock)
  -		selectNodesFromSP(req.SuperPodTop[item.SuperPodID], i, req.SpBlock, selectedNodes)
  +		SelectNodesFromSP(req.SuperPodTop[item.SuperPodID], strconv.Itoa(i), req.SpBlock, selectedNodes)
  ...
  +// SelectInferServiceSPForPodLevel fills unready logical super pods for pod-level
  +// rescheduling using the infer service priority queue (same-service SP first, others
  +// as fallback).
  ```
  </details>

- **`chip8node8ra64sp` 把内联的选点+亲和更新逻辑抽成 `selectNodesFromRack` / `updateInferServiceAffinity` 两个方法**(原来在主循环里手动拼 `plugin.SuperNode`、维护 sameRacks/sameSPs),为其 pod 级分支复用同一套 rack 级选点。这是与 pod 级重调度配套的重构,非纯风格改动。

  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8ra64sp/infer_service.go</summary>

  ```diff
  -		sp := superPodMap[item.superPodID]
  -		rackGroup := transferSuperPodToRackIdMap(sp)
  -		nodesInRack := rackGroup[item.rackID]
  -		selectedNodes[spIndex] = make([]plugin.SuperNode, 0, tp.spBlock)
  -		for j := 0; j < tp.spBlock; j++ { ... delete(sp, nodesInRack[j].name) }
  +		selectedNodes[spIndex] = tp.selectNodesFromRack(item, superPodMap)
  -		sameRacks[rackKey(...)] = &inferServiceRackInfo{...}
  -		tp.enrichRackAndSPInfo(superPodMap, sameRacks, sameSPs)
  +		tp.updateInferServiceAffinity(item, superPodMap, sameRacks, sameSPs)
  ```
  </details>

- **新增故障调度策略 `external-force-pod-failed`,`getTaskHealthState` 增加 reScheduleKey 参数并对其走 fast path:只把 PodFailed(业务故障)标记为需重调度,跳过所有硬件故障**(cardUnhealthy / networkUnhealthy 等);且仍受 job 级 `IsFaultRetryEnable`(FaultRetryTimes)门禁——关闭时故障任务不标记,整条重调度流程不触发。type.go 定义常量,job.go 的 `restartSingleFaultJob` switch 把该前缀并入"通过写 pod 状态 annotation 外部删除"分支。

  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go / type.go</summary>

  ```diff
  +	if reScheduleKey == JobExternalForcePodFailedReschedulingPrefix {
  +		if isFailedTask(task) && fTask.IsFaultRetryEnable {
  +			return true, PodFailed
  +		}
  +		return false, PodHealthy
  +	}
  ...
  +	// JobExternalForcePodFailedReschedulingPrefix Force delete reschedule job with external
  +	// rescheduling, only handle pod-failed (business fault), skip hardware fault
  +	JobExternalForcePodFailedReschedulingPrefix = "external-force-pod-failed"
  ```
  </details>

- **clusterd 版本汇总纳入 `ascend-dra` 组件**。`buildVersionSummary` 的 targetComponents 从 `{device-plugin, k8s-rdma-shared-dp, noded}` 扩为加入 `ascend-dra`,即 DRA 组件版本进入 clusterD 跨节点版本汇总(与本区间"dra 二进制打印 version+commitid、节点加 annotation、clusterD 收集 dra 版本"提交对应)。

  <details><summary>代码依据 component/clusterd/pkg/interface/kube/informer.go</summary>

  ```diff
  -	targetComponents := []string{"device-plugin", "k8s-rdma-shared-dp", "noded"}
  +	targetComponents := []string{"ascend-dra", "device-plugin", "k8s-rdma-shared-dp", "noded"}
  ```
  </details>

### 后续发展方向 [AI]
- **推理服务的容错粒度正从"作业级"下探到"pod 级"**:证据是三拓扑策略统一分流 + `selectNodesForInferServicePodLevel` 的 Stage 1-3 复用故障升级链、只补故障槽。方向是 A3 SuperPod 上大规模推理服务的**部分故障快速自愈**(不动健康副本),减少整作业重排的抖动。证据只覆盖 selectNodes 侧的选点逻辑,未见 pod 删除/重建的下发端(那部分提交在 PATHPREFIX 外)。
- **故障重调度策略在按"故障来源"细分**:`external-force-pod-failed` 明确把业务故障(PodFailed)与硬件故障解耦,配合外部强删。指向上层(训练/推理框架或运维系统)可精确控制"只因业务失败而重调度、不误判为硬件故障"。证据只覆盖 health state 判定与 restart 分支,未见外部触发方如何下发该 ReScheduleKey。
- **DRA 路径持续工程化(可观测优先)**:ascend-dra 进入 clusterD 版本汇总 + helm 部署支持(提交标题,代码在 PATHPREFIX 外),说明昇腾 DRA 尚在补运维基建(版本/部署),而非核心分配语义突破。证据仅 informer 一行 + 提交标题。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交(软切分/vCANN 面本区间零演进)
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- ub-network-device-plugin:无新提交
- volcano-ext:仅 `docs/design/*.md` 拼写修正(seperate→separate、preffer→prefer 等)+ CHANGELOG typo,无代码/设计实质变更,视同无实质改动。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=8aa0157273178f9ea33fc3f75d6eac6c22606af6 tag=v26.2.0.beta.1 scanned=2026-09-08 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f3cfd270f0dda85b259f4041d6c99824920e17e5 tag=v26.6.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=ef44c337d16e208fc1557b8e56a77447f30bc2a7 tag=1.0.2 scanned=2026-09-08 -->
