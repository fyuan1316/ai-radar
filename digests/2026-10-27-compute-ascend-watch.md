# 昇腾算力栈 diff 雷达 2026-10-27

## 摘要
- 唯一实质改动落在 `mind-cluster` 的 **ascend-for-volcano 调度器**:把"pod-error 故障卡退避"从**打分时现查跨会话缓存**重构成**节点级静态状态物化到 ChipTopo**(新增 `ChipNode.podErrorTime` 字段),并在故障处理记录完 pod-error 卡后**同会话刷新** ChipTopo,消除原先退避要等下一个调度会话才生效的"一会话延迟"。与 silent-fault 卡走同一套机制,是 26.3.0 落地的 silent/pod-error 故障退避的实现级收敛,非新能力。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期均无新提交;DRA 主线(ascend-dynamic-resource-allocation / ascend-common)本窗口亦无改动。
- 无 API/CRD/弃用/架构方向/版本跨档信号,**当日重要改变:无**。

## 当日重要改变(命中信号才列)
- 无(本次 mind-cluster 改动是内部重构 + 一致性修复,未触及 `*_types.go`/CRD/弃用/`docs/proposals`/版本跨档)。

## mind-cluster: a1ba9a44 -> 1bcc4592
- 比较: a1ba9a44c56109a57f9c63911bb20c5860f20ac6..1bcc4592 | tag: v26.2.0 | commits=2 | truncated=false
- 实质提交: `[volcano] 重构poderrortime的设置方式`
- 源对比: https://gitcode.com/Ascend/mind-cluster/compare/a1ba9a44c56109a57f9c63911bb20c5860f20ac6...1bcc459240f595c7d10e39eb2dc004eb1464f798

### AI 总结重点(源码 diff 为据)

- **`ChipNode` 结构体新增 `podErrorTime int64` 字段**,与 `faulty/netUnhealthy/silentFault` 并列成为"节点级静态故障状态"的一员;`Init()` 签名新增 `podError map[int]int64`(chip-id → 故障 unix 秒)入参,初始化时把每个叶子的 `podErrorTime` 一并清零/回填。即 pod-error 退避数据从"调度时临时查"升级为"随拓扑树持久化"。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/topo/chipnode.go</summary>

  ```diff
   type ChipNode struct {
   	faulty       int
   	netUnhealthy int
   	silentFault  int
  +	podErrorTime int64
   	allocated    int
   	ownedBy      []string

  -func (n *ChipNode) Init(faulty, netUnh, silent map[int]struct{}, owners map[string][]int) {
  +func (n *ChipNode) Init(faulty, netUnh, silent map[int]struct{}, podError map[int]int64,
  +	owners map[string][]int) {
   ...
  -		leaf.faulty, leaf.netUnhealthy, leaf.silentFault, leaf.allocated, leaf.ownedBy =
  -			0, 0, 0, 0, nil
  +		leaf.faulty, leaf.netUnhealthy, leaf.silentFault, leaf.podErrorTime, leaf.allocated, leaf.ownedBy =
  +			0, 0, 0, 0, 0, nil
  +		if t, ok := podError[id]; ok {
  +			leaf.podErrorTime = t
  +		}
  ```
  </details>

- **新增 `ChipNode.PodErrorChips()` 与 `SetPodErrorTimes()` 两个方法**:前者返回"有 pod-error 记录的 chip-id → 故障秒"(与 `SilentFaultChips()` 对称,是否withhold交由消费者按容忍窗口决定);后者在不碰 faulty/net/silent/allocated/owners 的前提下,仅刷新全部叶子的 pod-error 时间到最新缓存,**注释明确目的是"避免一会话延迟"**。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/topo/chipnode.go</summary>

  ```diff
  +// PodErrorChips returns the chip ids of every leaf with a pod-error record,
  +// mapped to its failure unix second. Like SilentFaultChips it is node-level
  +// static state; whether to withhold them is decided by the consumer via its
  +// tolerance window.
  +func (n *ChipNode) PodErrorChips() map[int]int64 { ... }
  +
  +// SetPodErrorTimes ... so the node's ChipTopo reflects the latest cache without a one-session
  +// delay. Only the pod-error state is touched ...
  +func (n *ChipNode) SetPodErrorTimes(podError map[int]int64) { ... }
  ```
  </details>

- **`excludedChipIDs()`(打分时决定要withhold哪些卡)的 pod-error 取数源从 `cache.PodErrorCards(node.Name)` 改为 `root.PodErrorChips()`**,并去掉了原来逐卡名→chip-id 的现场解析(解析提前到物化阶段)。容忍窗口门闩 `PodErrorToleranceAfterTime` 逻辑不变。注释也从"pod-error 是 per-job(只有报错的 job 退避)"改写成"silent-fault 与 pod-error 均为节点级静态状态,分别受各自容忍窗口门闩"——语义表述向 silent-fault 对齐。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/chip.go</summary>

  ```diff
  -			for card, faultTime := range cache.PodErrorCards(node.Name) {
  +			for id, faultTime := range root.PodErrorChips() {
   				if util.TimeGateAllows(tp.NPUJob.ToleranceConfig.PodErrorToleranceAfterTime, now-faultTime) {
   					continue
   				}
  -				for id := range node.ChipIDsFromCardNames([]string{card}) {
  -					set[id] = struct{}{}
  -				}
  +				set[id] = struct{}{}
   			}
  ```
  </details>

- **物化入口接线**:`NPUNode.ParseChipTopology` 调 `Init` 时传入新增的 `podErrorChipTimes()`(把 pod-error 卡名经 `ChipIDsFromCardNames` 换算成 chip-id,同一 chip 多卡命中取最晚故障时间);重调度 `Execute` 流程里 `recordPodErrorCardsToNodes` 更名为 `recordAndRefreshPodErrorCardsToNodes(env)`,**记录完 pod-error 卡后立即遍历 `env.Nodes` 调 `RefreshPodErrorTime()`**——这是"同会话生效、消除一会话延迟"的落点。
  <details><summary>代码依据 plugin/node.go + internal/rescheduling/frame.go</summary>

  ```diff
  # plugin/node.go
  -	n.ChipTopo.Init(faulty, netUnh, silent, n.buildOwners())
  +	n.ChipTopo.Init(faulty, netUnh, silent, n.podErrorChipTimes(), n.buildOwners())
  +func (n *NPUNode) RefreshPodErrorTime() {
  +	if n == nil || n.ChipTopo == nil { return }
  +	n.ChipTopo.SetPodErrorTimes(n.podErrorChipTimes())
  +}

  # internal/rescheduling/frame.go
  -	reScheduler.recordPodErrorCardsToNodes()
  +	reScheduler.recordAndRefreshPodErrorCardsToNodes(env)
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 Volcano 调度器正把"故障卡退避"的三种来源(faulty / net-unhealthy / silent-fault / pod-error)统一收敛到 ChipTopo 的节点级静态状态模型 + 容忍窗口门闩,pod-error 这次补齐后四态已同构。方向是**可预测的卡级故障隔离/退避**,而非驱逐 Pod;下一步可留意是否把这套状态暴露成可观测指标或注解(本次 diff 未见)。
- 注意:证据只覆盖 ascend-for-volcano 调度侧的 pod-error 重构,**未见** DRA(ascend-dynamic-resource-allocation)、device-plugin、npu-exporter 等其他 component 本窗口有改动;"per-job 退避"措辞被删是否意味行为从 per-job 变 per-node,仅凭本次 hunk 无法断定(取数源 `cache.PodErrorCards` 仍是节点级缓存,门闩仍挂在 `tp.NPUJob` 上,倾向于纯表述对齐而非行为翻转)。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY,保锚点</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:均无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=1bcc459240f595c7d10e39eb2dc004eb1464f798 tag=v26.2.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v26.9.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=npu-dra-plugin sha=031dc691f082fdb90610f77eab3bcf91ad8e9aa3 tag=v26.9.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-27 -->
</content>
</invoke>
