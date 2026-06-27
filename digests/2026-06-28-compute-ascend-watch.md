# 昇腾算力栈 diff 雷达 2026-06-28

## 摘要
- mind-cluster 围绕 **A5 超节点(Superpod)** 推进全栈适配:infer-operator 新增 nodepodcleaner 控制器(节点 NotReady 即强删推理 pod 加速重建);ascend-for-volcano 重构 4P mesh 亲和选卡逻辑;clusterd 为机架(rack)亲和作业补"先机架重调度再刷全局故障"的时序门控。
- npu-exporter 修一类潜在指标错位 bug:把 UB/光模块/网络采集对 PortMap 的随机序 range 改为固定 dieID[0,1]+排序,并把更新循环上界从 GetCount() 改为实际切片长度。
- openFuyao 全部 8 仓本期 EMPTY(无新提交),保锚点链。

## 当日重要改变
- mind-cluster [新能力] infer-operator 新增独立 package `pkg/controller/nodepodcleaner`:NodePodCleanerReconciler 监听 Node,节点转 NotReady 即 grace-period=0 强删该节点上 infer-operator 托管 pod,绕过 pod-eviction-timeout 让上层 workload 控制器在健康节点快速重建。证据 component/infer-operator/pkg/controller/nodepodcleaner/node_pod_cleaner_controller.go(新增 204 行)+ main.go 注册。 https://gitcode.com/Ascend/mind-cluster/commit/1f52b28fb17293606d492ff64e9c2432f715b0bd
- mind-cluster [架构方向] A5 超节点调度链路成型:volcano action 增强支持 350 标卡 + 4P mesh 亲和选卡重构(ascend-for-volcano);clusterd 为机架亲和作业新增 dealWithRackScheduling 时序门控。证据 component/ascend-for-volcano/internal/npu/policy/chip4nodex/frame.go、component/clusterd/pkg/application/recover/controller.go。 https://gitcode.com/Ascend/mind-cluster/compare/37905df6593785dad11df642a639c28d8406a5ed...1f52b28fb17293606d492ff64e9c2432f715b0bd

## mind-cluster: 37905df6 -> 1f52b28f
- 比较: 37905df6593785dad11df642a639c28d8406a5ed..1f52b28f | tag: v26.0.1 | commits=20 | truncated=false
- 比较页: https://gitcode.com/Ascend/mind-cluster/compare/37905df6593785dad11df642a639c28d8406a5ed...1f52b28fb17293606d492ff64e9c2432f715b0bd

### AI 总结重点(源码 diff 为据)

- **infer-operator 新增节点级 pod 清理控制器**:新包 nodepodcleaner 注册一个 Reconciler 监听 Node 状态;节点 NotReady(关机/重启)时强制删除(grace-period=0)该节点上 infer-operator 托管的 pod,使 StatefulSet/Deployment 控制器立即在健康节点重建,而不必等 kubelet 恢复或 pod-eviction-timeout。对应中文流水账"节点not ready时,删除该节点上推理相关pod"。
  <details><summary>代码依据 component/infer-operator/pkg/controller/nodepodcleaner/node_pod_cleaner_controller.go + main.go</summary>

  ```diff
  +// NodePodCleanerReconciler watches Node status. When a node turns NotReady, it
  +// force-deletes (grace-period=0) all infer-operator managed pods scheduled on
  +// that node so that the owning workload controllers can recreate them on
  +// healthy nodes without waiting for kubelet recovery or pod-eviction-timeout.
  +type NodePodCleanerReconciler struct {
  +	client.Client
  +	Scheme *runtime.Scheme
  +}
  +	if isNodeReady(node) {
  +		// node recovered or transient flip; nothing to do
  +		return ctrl.Result{}, nil
  +	}
  // main.go:
  +	nodePodCleanerReconciler := nodepodcleaner.NewNodePodCleanerReconciler(mgr)
  +	if err := nodePodCleanerReconciler.SetupWithManager(mgr); err != nil {
  +		hwlog.RunLog.Errorf("unable to setup node pod cleaner reconciler: %v", err)
  +		os.Exit(1)
  +	}
  ```
  </details>

- **ascend-for-volcano 4P mesh 亲和选卡逻辑抽取并增强**:从 Preemptable 内联代码抽出 `selectFeasibleCardsByMeshAffinity`,新增"单 mesh best-fit"分支——任务需求小于单 mesh 容量时,从所有 freeCount≥需求的卡里按"剩余空闲最少"best-fit 选一张;需求≥单 mesh 时仍走"凑齐完整 mesh"逻辑((reqNPUNum+maxCardNPUNum-1)/maxCardNPUNum 个完整 mesh)。前者是新增的细粒度选卡能力,提升碎片利用率。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip4nodex/frame.go</summary>

  ```diff
  +func selectFeasibleCardsByMeshAffinity(reqNPUNum, maxCardNPUNum int,
  +	cardFreeCount map[int]int) map[int]struct{} {
  +	if !is4PmeshAffinity(reqNPUNum) {
  +		return nil
  +	}
  +	// Single mesh: task needs fewer NPUs than one mesh provides
  +	if reqNPUNum < maxCardNPUNum {
  +		var candidates []int
  +		...
  +		// best-fit: prefer the mesh with the least extra free NPUs
  +		sort.Slice(candidates, func(i, j int) bool {
  +			extraI := cardFreeCount[candidates[i]] - reqNPUNum
  +			extraJ := cardFreeCount[candidates[j]] - reqNPUNum
  +			...
  -	// 4P mesh affinity: only select complete mesh groups (freeCount == maxCardNPUNum)
  -	if is4PmeshAffinity(reqNPUNum) && reqNPUNum >= maxCardNPUNum {
  -		...内联逻辑移入新函数...
  ```
  </details>

- **clusterd 机架亲和作业新增"先机架重调度再刷全局故障"门控**:handleNotifyGlobalFault 在通知全局故障前插入 dealWithRackScheduling;仅对 A5 作业且 PodGroup 带 `ra-block` 注解生效,轮询等待作业重新 Running(最多 MaxRackReschedulingRetryTimes=3 次、每次 sleep RackReschedulingDelayTimeOut=3s),否则全局故障信息会不完整。对应"修复框重调度导致的进程级恢复故障下发不全"。
  <details><summary>代码依据 component/clusterd/pkg/application/recover/controller.go + constants.go</summary>

  ```diff
  +	// If rack affinity is enabled, pod rescheduling is performed before chassis rescheduling.
  +	ctl.dealWithRackScheduling()
  +func (ctl *EventController) dealWithRackScheduling() {
  +	if !ctl.isA5Job() { return }
  +	pgInfo := podgroup.GetPodGroup(ctl.jobInfo.JobId)
  +	if _, ok := pgInfo.Annotations[constant.RackBlockSchedulingKey]; !ok { return }
  +	for !podgroup.JudgeIsRunningByJobKey(ctl.jobInfo.JobId) {
  +		if rackReschedulingRetryTimes > constant.MaxRackReschedulingRetryTimes { break }
  +		...time.Sleep(... RackReschedulingDelayTimeOut ...)
  // constants.go:
  +	RackBlockSchedulingKey        = "ra-block"
  +	MaxRackReschedulingRetryTimes = 3
  +	RackReschedulingDelayTimeOut  = 3
  ```
  </details>

- **npu-exporter 修指标采集随机序/越界隐患**:UB、光模块、网络三个 collector 把对 NpuDevPortInfos.GetPortMap() 的 `for dieID, portIDs := range` 改为固定 `dieIDs := []int{0,1}` + 对 portIDs `sort.Ints`(注释 "udie only has 0 and 1, fixed order"),消除 map 遍历随机序导致的指标 desc/值错位;同时把更新循环上界从全局 `GetCount()` 改为本次实际数据切片 `len(ubInfo)/len(opticalInfo)/len(netInfo)`,避免按全局计数越界访问 nil。对应"npu-exporter修复port获取的map在使用时强制排序使用"。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_ub.go(同样改动见 optical/network)</summary>

  ```diff
  -	for dieID, portIDs := range colcommon.NpuDevPortInfos.GetPortMap() {
  +	// udie only has 0 and 1, fixed order
  +	dieIDs := []int{0, 1}
  +	for _, dieID := range dieIDs {
  +		portIDs, ok := colcommon.NpuDevPortInfos.GetPortMap()[dieID]
  +		if !ok || len(portIDs) == 0 { continue }
  +		sort.Ints(portIDs)
  -	for i := 0; i < colcommon.NpuDevPortInfos.GetCount(); i++ {
  +	for i := 0; i < len(ubInfo); i++ {
  ```
  </details>

### 后续发展方向 [AI]
- A5 超节点是本期主线:选卡(volcano 4P mesh best-fit)、故障恢复(clusterd 机架重调度门控)、推理 pod 生命周期(infer-operator NotReady 强删)三处协同,指向"超节点级整柜调度 + 进程级断点续训"的闭环。证据覆盖 frame.go/controller.go/node_pod_cleaner_controller.go 三处 hunk;未见 A5 superpod association 的设备发现侧代码(该 commit 文件未进信号节选)。
- npu-exporter 的修复属可观测正确性 hardening(udie 固定双口模型),非新指标;若后续 UB die 数超过 2 需回改这处硬编码 dieIDs[0,1],是个已知约束点。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(保锚点)</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:本期无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=1f52b28fb17293606d492ff64e9c2432f715b0bd tag=v26.0.1 scanned=2026-06-28 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-28 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-28 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-28 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-28 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-28 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b28f10a1e98ec0c2af8be45928e08e689d4a7fb4 tag=1.0.1 scanned=2026-06-28 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-28 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-28 -->
