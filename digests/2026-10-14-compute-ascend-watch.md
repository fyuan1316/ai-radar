# 昇腾算力栈 diff 雷达 2026-10-14

## 摘要
- **mind-cluster / ascend-for-volcano 落地"卡级退避容错"**:新增两类时间窗退避——静默故障卡(SilentFault)与 Pod 出错卡(pod-error),调度预选/打分/选卡阶段把退避卡当作临时故障从拓扑树剔除,窗口到期自动恢复。新增进程级 pod-error 缓存包 `common/cache`,配套两个 Pod 注解可调容忍时间。对应提交「[volcano] 静默故障节点降级和Pod fail节点降级」。
- 其余 8 仓(mind-cluster 外的 openFuyao 全部 + npu-operator/vNPU/npu-driver-installer 等)本期**无新提交**,全 EMPTY。
- 无 CRD/API 结构体改动;本期是调度器容错逻辑的纯新增能力。

## 当日重要改变
- **mind-cluster** `[新能力]` ascend-for-volcano 新增静默故障/Pod 出错卡的卡级退避容错,新增独立包 `common/cache`(pod-error 跨 session 缓存)+ 两个容忍注解 `huawei.com/silent.unhealthy-tolerance.after-time`、`huawei.com/pod.error-tolerance.after-time`。证据:新增文件 `component/ascend-for-volcano/common/cache/pod_error.go`、`plugin/job.go`、`chip/chip.go`、`chip/topo/chipnode.go`、`common/util/constants.go`。https://gitcode.com/Ascend/mind-cluster/commit/2d551d3fee466af0a4b65f5a7a6abbc3a2a47c51

## mind-cluster: fe3bf792 -> 2d551d3f
- 比较:fe3bf792..2d551d3f | tag: v26.1.1 | commits=36 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/fe3bf7923fc9526fb1d8825f73d352435c9f055d...2d551d3fee466af0a4b65f5a7a6abbc3a2a47c51

### AI 总结重点(源码 diff 为据)

- **新增"卡级退避"模型:静默故障卡 + Pod 出错卡两类临时不可用,窗口到期自动恢复**。`chipHandler` 在预选 `CheckNodeNPUByTask`、打分 `ScoreBestNPUNodes`、选卡 `UseAnnotation` 三处都先对拓扑树做 `root.Exclude(tp.excludedChipIDs(node))`,把当前仍在容忍窗口内的退避卡当作硬故障剔除,再判断剩余健康卡能否满足请求;选卡时在剔除后的 **view** 上选、但在真实树上登记占用,保证本 session 占用一致。这是区别于以往"整节点降级"的**卡粒度**退避。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/chip.go</summary>

  ```diff
  +	root = root.Exclude(tp.excludedChipIDs(node))      // CheckNodeNPUByTask
  +	root = root.Exclude(tp.excludedChipIDs(nNode))     // ScoreBestNPUNodes
  -	selected := root.SelectChips(&util.Request{
  +	view := root.Exclude(tp.excludedChipIDs(node))     // UseAnnotation
  +	selected := view.SelectChips(&util.Request{
  +func (tp *chipHandler) excludedChipIDs(node plugin.NPUNode) map[int]struct{} {
  +	set := make(map[int]struct{})
  +	if root := node.ChipTopo; root != nil {
  +		if !tp.silentToleranceAllows() {
  +			for id := range root.SilentFaultChips() { set[id] = struct{}{} }
  +		}
  +		if tp.NPUJob != nil {
  +			now := time.Now().Unix()
  +			for card, faultTime := range cache.PodErrorCards(node.Name) {
  +				if util.TimeGateAllows(tp.NPUJob.ToleranceConfig.PodErrorToleranceAfterTime, now-faultTime) { continue }
  +				for id := range node.ChipIDsFromCardNames([]string{card}) { set[id] = struct{}{} }
  +			}
  +		}
  +	}
  ```
  </details>

- **拓扑树 `ChipNode` 增 `silentFault` 位,新增 `Exclude`/`SilentFaultChips` 方法**。`Exclude` 克隆一棵树、把指定 chipID 的叶子标 `faulty=1`(临时退避只作用于克隆,session 树不动);`SilentFaultChips` 返回所有静默故障叶子的 chipID(节点级静态状态,是否withhold由消费方按容忍窗口决定)。`Init` 签名从 `(faulty, netUnh, owners)` 扩成 `(faulty, netUnh, silent, owners)`。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/topo/chipnode.go</summary>

  ```diff
   type ChipNode struct {
   	faulty       int
   	netUnhealthy int
  +	silentFault  int
  -func (n *ChipNode) Init(faulty, netUnh map[int]struct{}, owners map[string][]int) {
  +func (n *ChipNode) Init(faulty, netUnh, silent map[int]struct{}, owners map[string][]int) {
  +		if has(silent, id) { leaf.silentFault = 1 }
  +func (n *ChipNode) Exclude(chips map[int]struct{}) *ChipNode {
  +	c := n.Clone()
  +	for id := range chips { if leaf, ok := c.leafIndex[id]; ok { leaf.faulty = 1 } }
  +	return c }
  +func (n *ChipNode) SilentFaultChips() map[int]struct{} { ... leaf.silentFault == 1 ... }
  ```
  </details>

- **新增进程级 pod-error 缓存包 `common/cache/pod_error.go`:node→card→首次故障 unix 秒 的 map,互斥锁保护**。`RecordPodError` 按卡记录出错时间(更晚的时间覆盖更早,重复上报不刷新),并顺带 `expirePodErrorLocked` 清理超过最大容忍窗口的旧记录。语义是**按卡退避**:某卡让某 Pod 出错后,所有 job 对该卡退避到窗口过去(注:注释写 card-level,`excludedChipIDs` 侧则按 job 的 PodErrorTolerance 过滤,实际 withhold 粒度结合 job)。
  <details><summary>代码依据 component/ascend-for-volcano/common/cache/pod_error.go(新增 119 行)</summary>

  ```diff
  +type podErrorStore struct {
  +	mu sync.Mutex
  +	records map[string]map[string]int64  // node -> card -> fault unix second
  +}
  +func RecordPodError(nodeName string, cards []string, faultTime int64) {
  +	...
  +	if existing, ok := cardTime[card]; !ok || faultTime > existing { cardTime[card] = faultTime }
  +	expirePodErrorLocked(time.Now().Unix())
  +}
  ```
  </details>

- **job 侧读两个新注解填充 `ToleranceConfig`,并带 clamp 边界**。`setSilentUnhealthyTolerance` 读 `huawei.com/silent.unhealthy-tolerance.after-time`(默认 0 立即释放,clamp 到 `[-1, 1800]`,-1=永久扣留);`setPodErrorTolerance` 读 `huawei.com/pod.error-tolerance.after-time`(默认 30s,clamp 到 `[0, 300]`,因 pod-error 是临时退避不允许 -1 永久)。两者在 `initNPUJob` 中与既有 `setParameterPlaneUnhealthyTolerance` 并列调用。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go + common/util/constants.go</summary>

  ```diff
  +	sJob.setSilentUnhealthyTolerance()
  +	sJob.setPodErrorTolerance()
  +	SilentUnhealthyToleranceAnnoKey = "huawei.com/silent.unhealthy-tolerance.after-time"
  +	PodErrorToleranceAnnoKey        = "huawei.com/pod.error-tolerance.after-time"
  +	DefaultSilentUnhealthyToleranceAfterTime = 0
  +	MaxSilentUnhealthyToleranceAfterTime int64 = 1800
  +	DefaultPodErrorToleranceAfterTime = 30
  +	MaxPodErrorToleranceAfterTime int64 = 300
  +	ToleranceForbidden int64 = -1
  +	SilentFault = "SilentFault"
  +	DeviceFaultCmKeySuffix = "-Fault"
  ```
  </details>

- **静默故障卡的来源:节点 `-Fault` 注解(设备故障 JSON 数组)里 `fault_level==SilentFault` 的卡**。节点侧 `parseDeviceHealthAnnotations` 签名加返回 `silent` 集合,新增 `silentFaultCardsFromAnno` 解析 `-Fault` 注解把卡名解析成 chipID;rescheduling 侧 `FaultNode.setSilentUnhealthyNPU`/`IsSilentFaultNode` 收集静默故障卡。整节点(超节点 super-pod)作业因独占整节点,预选入口新增 `rejectSuperPodNodeWithBackoffCards` 提前否决仍在容忍窗口内含退避卡的节点。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/node.go + internal/rescheduling/node.go</summary>

  ```diff
  +	if err := vcJob.rejectSuperPodNodeWithBackoffCards(vcNode); err != nil { return err }
  -func (n *NPUNode) parseDeviceHealthAnnotations() (faulty, netUnh map[int]struct{}, maxCardID int) {
  +func (n *NPUNode) parseDeviceHealthAnnotations() (faulty, netUnh, silent map[int]struct{}, maxCardID int) {
  +		if strings.HasSuffix(key, util.DeviceFaultCmKeySuffix) {
  +			for id := range n.silentFaultCardsFromAnno(val, pre) { ... silent[id] = struct{}{} }
  +func (fNode *FaultNode) setSilentUnhealthyNPU() { ... fault.FaultLevel == SilentFault ... }
  ```
  </details>

- **rescheduling 把静默容忍接入健康判定,并把出错卡回灌 pod-error 缓存**。`getTaskHealthState` 参数增 `silentUnhealthyTolerance int64`;故障任务记录 `PodFailedTime = getPodFailedTime(task)`;新增 `recordPodErrorCardsToNodes` 把各故障 job 的故障任务所用卡(`UseCardName` + `PodFailedTime`)写进 `cache.RecordPodError`——pod-error 按 job 退避(只有出错的 job 对该卡退避)。另 `FaultDeviceList` 类型从 rescheduling 包迁到 `k8s` 包复用。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go</summary>

  ```diff
  +		silentTolerance := reScheduler.jobSilentUnhealthyTolerance(faultJob.JobUID)
  -		isFaultTask, healthState := reScheduler.getTaskHealthState(&faultTask, task, faultJob.SubHealthyStrategy, faultJob.ReScheduleKey)
  +		isFaultTask, healthState := reScheduler.getTaskHealthState(&faultTask, task, faultJob.SubHealthyStrategy, faultJob.ReScheduleKey, silentTolerance)
  +		if isFaultTask { faultTask.PodFailedTime = getPodFailedTime(task) }
  +func (reScheduler *ReScheduler) recordPodErrorCardsToNodes() {
  +	for _, fJob := range reScheduler.FaultJobs { for i := range fJob.FaultTasks {
  +		cache.RecordPodError(fTask.NodeName, fTask.UseCardName, fTask.PodFailedTime) } }
  ```
  </details>

- **clusterd 故障管理小修**:`faultDuration` 加载失败时回退默认故障持续时间配置(提交「fix(faultmanager): faultDuration加载失败时使用默认故障持续时间配置」),`relation_fault_processor.go` 关联故障处理改动约 30 行;device-plugin/clusterd 修 NPU 改名问题(`main.go`/`pod_util.go`)。这些是运维健壮性修复,非能力新增,不展开。

### 后续发展方向 [AI]
- 昇腾调度容错正从"整节点降级/重调度"细化到**卡级时间窗退避**:同一节点内坏卡与好卡解耦,好卡仍可调度,坏卡临时扣留到窗口过期。证据覆盖 `chip.Exclude`/`excludedChipIDs`/`TimeGateAllows` 的预选-打分-选卡三处接入;未见该退避如何与既有整节点 rescheduling 决策的优先级冲突处理(只看到 super-pod 作业的前置否决),也未展开 `silentToleranceAllows` 的 job 级门控实现。
- 静默故障(SilentFault)被显式建模为一类独立 fault_level,来源是设备侧 `-Fault` 注解。方向上静默故障(算得出但结果错/慢的"亚健康"卡)正被纳入调度可见性——此前多靠硬故障注解。证据仅覆盖注解解析与容忍窗口,未见静默故障的**检测/上报**侧(应在 npu-exporter/noded,本期未改)。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(保锚点)</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=2d551d3fee466af0a4b65f5a7a6abbc3a2a47c51 tag=v26.1.1 scanned=2026-10-14 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-14 -->
</content>
</invoke>
