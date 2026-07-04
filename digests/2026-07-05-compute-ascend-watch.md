# 昇腾算力栈 diff 雷达 2026-07-05

## 摘要
- **本期主线仍在推理超节点调度与容错的收敛,分两条**:①`ascend-for-volcano` 把 `sameRacks` 的 map key 从裸 `rackID`(int32)升格为 `superPodID<<32 | rackID` 的复合 key(int64),修复"不同 SuperPod 复用同一 RackID 时机架空闲统计相互覆盖"的隐藏冲突——延续 07-03/07-04 8RA64SP 选点死循环的同一片代码继续硬化;②`infer-operator` 给 pod 删除→重建 workload 加了 **gang 调度门禁**:未配 gang 的 workload 掉一个 pod 不再触发整个通信域重建。
- **infer-operator 容器快照(断点续训/续推)校验耗时优化**:把 `IsSnapshotValid` 这类重校验从 Reconcile 主链路挪进 `go func()` 异步执行,快照状态存在即先放行/进 load 模式,校验失败再异步清理;`cleanupSnapshotPath` 从 `SnapshotChecker` 方法降为包级函数以便异步复用。
- **device-plugin 跟进 07-04 的 `NpuDevPortInfo` 公共库改造修编译**:`hang_detector` 的 `npuDevPortInfos` 从 `map[int][]int` 改为 `map[int][]NpuDevPortInfo`,UB 流量采集改读 `portInfo.PortID`。属 07-04 端口结构化重构的收尾,无新语义。
- openFuyao 8 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期全部无新提交。

## 当日重要改变
- **mind-cluster [Bugfix/调度] ascend-for-volcano** `sameRacks` 改复合 key 避免多 SuperPod 间同 RackID 冲突:新增 `rackKey(spID,rackID)=(spID<<32)|uint32(rackID)`,map 类型 `map[int32]→map[int64]`。证据:`component/ascend-for-volcano/internal/npu/policy/chip8node8ra64sp/infer_service.go`。 https://gitcode.com/Ascend/mind-cluster/commit/22d6b29877a3
- **mind-cluster [行为变更/容错] infer-operator** pod 删除只在 instanceSet 配了 gang 调度(`Labels[GangScheduleLabelKey]=="true"`)时才触发 workload 重建;非 gang workload 掉 pod 直接 skip。证据:`component/infer-operator/pkg/controller/rescheduling/rescheduling.go` 新增 `isGangScheduled`。 https://gitcode.com/Ascend/mind-cluster/commit/3f8bdc74486b
- **mind-cluster [性能] infer-operator** 快照有效性校验从 Reconcile 同步链路移到异步 goroutine,校验失败再异步清理,减少续训/续推快照校验对协调循环的阻塞。证据:`component/infer-operator/pkg/snapshot/instanceset_snapshot_controller.go`、`snapshot_checker.go`。 https://gitcode.com/Ascend/mind-cluster/commit/cefd06db2655
- **mind-cluster [重构跟进] ascend-device-plugin** hang_detector 适配 07-04 的 `NpuDevPortInfo` 结构化端口,修公共库变更导致的编译问题。证据:`component/ascend-device-plugin/pkg/device/hangdetection/hang_detector.go`。 https://gitcode.com/Ascend/mind-cluster/commit/ddd5820dd97c

## mind-cluster: 95a0438b -> 238ddec9
- 比较: 95a0438b..238ddec9 | tag: v26.0.1 | commits=14 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/95a0438b7f7bccdb1437cf4180ea38c7c09552af...238ddec9ca5dad91516ab18fce8282c05b3c3d28

### AI 总结重点(源码 diff 为据)
- **`sameRacks` 索引键从"仅 RackID"升格为"SuperPod+Rack 复合键",消除跨超节点的 RackID 别名冲突**。8RA64SP 推理亲和在收集/丰富机架空闲信息时,原用 `map[int32]*inferServiceRackInfo` 以 `sn.RackID` 为键;当两个不同 SuperPod 各有一个同号 RackID 时,后写者会覆盖前者的 `freeNodes` 统计,导致选点误判。本次新增常量 `superPodIDShift=32` 与 `rackKey(superPodID, rackID) = (int64(superPodID)<<32) | int64(uint32(rackID))`,把 `sameRacks`、`getInferServiceScheduledInfo`、`enrichRackAndSPInfo` 的键类型统一改为 `int64` 并全部走 `rackKey(...)`;同时补了多条 `klog.V(LogDebugLev)` 采集/丰富轨迹日志。这是 07-03/07-04 同一片 8RA64SP 选点逻辑的第三次硬化,方向从"选点循环边界"转到"机架统计正确性"。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8ra64sp/infer_service.go</summary>

  ```diff
  +	superPodIDShift = 32
  +func rackKey(superPodID, rackID int32) int64 {
  +	return (int64(superPodID) << superPodIDShift) | int64(uint32(rackID))
  +}
  -	sameRacks := make(map[int32]*inferServiceRackInfo)
  +	sameRacks := make(map[int64]*inferServiceRackInfo)
  ...
  -				if _, exist := sameRacks[sn.RackID]; !exist {
  -					sameRacks[sn.RackID] = &inferServiceRackInfo{
  +				if _, exist := sameRacks[rackKey(sn.SuperPodID, sn.RackID)]; !exist {
  +					sameRacks[rackKey(sn.SuperPodID, sn.RackID)] = &inferServiceRackInfo{
  ...
  -			if info, ok := sameRacks[rackID]; ok {
  +			if info, ok := sameRacks[rackKey(spID, rackID)]; ok {
  ```
  </details>

- **推理 workload 重建加 gang 调度门禁,单 pod 删除不再无条件重建整个通信域**。`Rescheduler.handlePodDelete` 在校验通过后新增分支:若 pod 所属 instanceSet 未开 gang 调度,则打日志 skip、不进 `processFaultEvent`。新增 helper `isGangScheduled` 复用 `getWorkLoadNameAndInstanceSetName` 取 instanceSet,读 `instanceSet.Labels[common.GangScheduleLabelKey]==common.TrueBool`(与 statefulset/deployment handler 同一约定)。注释点明动机:一个 STS/Deployment 的多副本共同组成一个推理实例(一个通信域),只有 gang 语义下掉一个 pod 才需整体重建;非 gang 场景重建整组是过度反应。
  <details><summary>代码依据 component/infer-operator/pkg/controller/rescheduling/rescheduling.go</summary>

  ```diff
  +	if !r.isGangScheduled(pod) {
  +		hwlog.RunLog.Infof("pod %s/%s deleted, but gang scheduling is not configured, skip workload rebuild", ...)
  +		return
  +	}
  +func (r *Rescheduler) isGangScheduled(pod *corev1.Pod) bool {
  +	_, instanceSetName := r.getWorkLoadNameAndInstanceSetName(pod)
  +	...
  +	return instanceSet.Labels[common.GangScheduleLabelKey] == common.TrueBool
  +}
  ```
  </details>

- **容器快照校验解阻塞:重校验/清理移出 Reconcile 主链路**。`InstanceSetSnapshotReconciler.Reconcile` 原为 `IsSnapshotStatusExists && IsSnapshotValid` 同步双判后返回;改为只同步判 `IsSnapshotStatusExists`,把 `IsSnapshotValid` 失败→`cleanupSnapshotPath` 的清理丢进 `go func()` 异步执行。`PodSnapshotReconciler` 侧亦去掉 `IsSnapshotValid` 前置条件,状态存在即置 load 模式并就地 `updateSnapshotConfigMap`(原在 Reconcile 尾部无条件调用,现收敛到 load 分支内)。配套把 `cleanupSnapshotPath` 从 `(sc *SnapshotChecker)` 方法降为包级函数,供异步 goroutine 与 checker 共用。对应"容器快照校验耗时问题修复"——`IsSnapshotValid` 疑为重 IO,同步执行拖慢协调循环。
  <details><summary>代码依据 component/infer-operator/pkg/snapshot/instanceset_snapshot_controller.go + pod_snapshot_controller.go + snapshot_checker.go</summary>

  ```diff
  -	if common.IsSnapshotStatusExists(hostSnapshotPath) &&
  -		common.IsSnapshotValid(hostSnapshotPath) {
  +	if common.IsSnapshotStatusExists(hostSnapshotPath) {
  +		go func() {
  +			if !common.IsSnapshotValid(hostSnapshotPath) {
  +				if err := cleanupSnapshotPath(hostSnapshotPath); err != nil { ... }
  +			}
  +		}()
  		return ctrl.Result{}, nil
  	}
  ```
  ```diff
  -func (sc *SnapshotChecker) cleanupSnapshotPath(snapshotPath string) error {
  +func cleanupSnapshotPath(snapshotPath string) error {
  ```
  </details>

- **hang_detector 适配 07-04 `NpuDevPortInfo` 端口结构化,修公共库变更的编译错误**。`HangDetector.npuDevPortInfos` 与 `getNpuDevNetPortInfos` 返回值从 `map[int][]int` 全部改为 `map[int][]npuCommon.NpuDevPortInfo`;`collectUBTraffic` 遍历 `portInfos` 后改用 `portInfo.PortID` 调 `GetNPUUbStatInfo`。纯类型跟进,无新监控语义——07-04 端口从裸 int 升格为结构体的改造扩散到了 hang 检测这条 UB 流量采集路径。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/hangdetection/hang_detector.go</summary>

  ```diff
  -	npuDevPortInfos map[int][]int
  +	npuDevPortInfos map[int][]npuCommon.NpuDevPortInfo
  ...
  -	for udieID, portIDs := range hd.npuDevPortInfos {
  -		for _, portID := range portIDs {
  -			ubStat, err := hccn.GetNPUUbStatInfo(logicID, int32(udieID), int32(portID))
  +	for udieID, portInfos := range hd.npuDevPortInfos {
  +		for _, portInfo := range portInfos {
  +			ubStat, err := hccn.GetNPUUbStatInfo(logicID, int32(udieID), int32(portInfo.PortID))
  ```
  </details>

- 另有 `ascend-operator/pkg/ranktable/utils/util_test.go` 大改(179 行)与 `chip8node8ra64sp/infer_service_test.go`、`rescheduling_test.go` 等测试重构(抽 `newRankTableJob` helper、拆分用例),属上述生产改动的配套测试,不单列。`ttfhw skill适配`/`更新mindformers资料` 未命中 component 信号文件(前者疑在非 component 目录或 skill 资产,后者纯 docs)。

### 后续发展方向 [AI]
- 昇腾推理超节点(8SP/8RA64SP)调度连续四天(07-03 死循环主改 → 07-04 二改 `item=nil` → 07-05 复合 key)都在同一片 `chip8node8ra64sp` 代码打补丁,说明 A3 超节点大规模推理实例的**拓扑感知选点在 v26.0.1 仍处逐条纠错的稳定化阶段**,尚未见结构性重写。证据仅覆盖 for-volcano 该策略文件;是否波及 8SP 无机架维度的对称路径,本区间无 hunk 佐证。
- infer-operator 这轮(gang 门禁 + 快照校验异步化)把重心从"快照正确性"转向"容错触发的精确性与协调循环性能":重建只对 gang workload 生效、重校验不阻塞 Reconcile。方向是把断点续训/续推的容错做得更省、更贴合通信域语义。证据覆盖 rescheduling + snapshot 两个 controller,但 `GangScheduleLabelKey` 的下发方(谁给 instanceSet 打这个 label)未在本区间出现,门禁的实际触发面待下一区间确认。

## 本期无实质改动(折叠)
<details><summary>8 个 repo 无新提交</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- vNPU(75efcb9f,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(dbffd794,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=238ddec9ca5dad91516ab18fce8282c05b3c3d28 tag=v26.0.1 scanned=2026-07-05 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-07-05 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-07-05 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-07-05 -->
<!-- ANCHOR repo=vNPU sha=75efcb9f42057ad1549fdccc4edb64ba8f8657be tag=v0.1.0 scanned=2026-07-05 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-07-05 -->
<!-- ANCHOR repo=npu-dra-plugin sha=dbffd7942b003f1bd4880861c167aa7a0410c9ca tag=1.0.1 scanned=2026-07-05 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-05 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-07-05 -->
