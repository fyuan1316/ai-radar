# 昇腾算力栈 diff 雷达 2026-09-04

## 摘要
- 本期主线是**昇腾调度往"真芯片级拓扑感知"整体演进**,两个仓同向发力:`Ascend/mind-cluster`(32 commits)新增独立包 `internal/npu/affinity/chip`——一套**节点内通用亲和性调度(`chip-affinity`)+ 拓扑树 + 拓扑感知抢占/驱逐**;`openFuyao/npu-dra-plugin`(5 commits)把 NPU 拓扑发现从**外挂 `npu-smi` 命令行解析改成 DCMI + HAL 库原生调用**,按 physicalID 上报芯片亲和属性。昨天 device-plugin 刚加的 `topologyAnnotator`(写 `npu.topology` 注解)本期正式被调度侧消费,拓扑链路打通。
- mind-cluster 第二条线:infer-operator 新增 **pod 级重调度**——故障时只删故障 pod 让 STS/Deployment 控制器重建,重试计数只由故障事件消费、且只对业务故障(pod-failed)计数,硬件故障直删不占重试额度,并修了 pod 删除事件二次扣减 `faultRetryTimesMap` 的隐患。
- 其余 7 个 openFuyao 仓全 EMPTY(tag 停 v26.6.0 / v0.1.0 / v1.9.0 / 1.0.2,无新提交)。

## 当日重要改变
- mind-cluster `[新能力/架构方向]` 新增顶层包 `internal/npu/affinity/chip`(+`topo` 子包):芯片级拓扑树 `ChipNode` + `chip-affinity` 调度策略 + 拓扑感知抢占/驱逐(hard/soft 两模式)。证据 `chip/chip.go`、`chip/topo/{chipnode,evict}.go`、`common/util/request.go`。 https://gitcode.com/Ascend/mind-cluster/compare/e70e6d37f5cf7bbbd0625a9bdea4d033c1152377...6a2e299e85af9de5a06c8bb81a17b7640bf86923
- mind-cluster `[新能力]` `plugin/node.go` 的 `NPUNode` 挂上 `ChipTopo`,`initNPUNodeByNodeInf` 调 `ParseChipTopology` 读 `huawei.com/npu.topology` 注解(缺失则按 NPU 容量 `BuildFlatTopology` 兜底)——即消费昨日 device-plugin 上报的拓扑注解。证据 `plugin/node.go`。 https://gitcode.com/Ascend/mind-cluster
- mind-cluster `[新能力]` infer-operator pod 级重调度:`processPodLevelRescheduling` 只删故障 pod 由 K8s 控制器重建,重试计数只对业务故障计数、硬件故障直删。证据 `infer-operator/pkg/controller/rescheduling/rescheduling.go`。 https://gitcode.com/Ascend/mind-cluster
- npu-dra-plugin `[新能力/架构方向]` 新增 `pkg/hal` 包(cgo dlopen 昇腾 HAL 库),NPU 拓扑发现由 `npu-smi` CLI 解析改成 DCMI+HAL 原生调用,按 physicalID 上报亲和,DCMI 主路径优先 + 双 ID 回退。证据 `pkg/hal/{manager_linux,topology}.go`、`internal/profiles/npu/dcmi.go`。 https://gitcode.com/openFuyao/npu-dra-plugin

## mind-cluster: e70e6d37 -> 6a2e299e
- 比较: e70e6d37..6a2e299e | tag: v26.2.0.beta.1 | commits=32 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/e70e6d37f5cf7bbbd0625a9bdea4d033c1152377...6a2e299e85af9de5a06c8bb81a17b7640bf86923

### AI 总结重点(源码 diff 为据)

- **新增独立包 `internal/npu/affinity/chip`:节点内通用亲和性调度策略 `chip-affinity`**。`chipHandler` 以 `PolicyName="chip-affinity"` 注册,`SetMaxNodeNPUNum(64)`、`SetMaxCardNPUNum(1)`——即**按单芯片粒度**做亲和(不再是 8/16 卡整环粒度)。`ShouldUseAffinity` 决定何时启用:任务带旧 `SchedulePolicyAnnoKey` 注解或 `AcceleratorTypeKeyDeprecated` selector 时**不走**新路径(与既有 sp/整环策略互斥)。核心判定 `CheckNodeNPUByTask` 调 `node.ChipTopo.Fit(&util.Request{...})`,把三态结果映射成调度错误:`FitNormal→nil`、`FitEvict→NPUResourceShortageError(可经驱逐满足)`、`FitFailed→NPUResourceUnavailableError(驱逐也满足不了)`。
  <details><summary>代码依据 ascend-for-volcano/internal/npu/affinity/chip/chip.go</summary>

  ```diff
  +const PolicyName = "chip-affinity"
  +const maxNodeNPUNum = 64
  +func New() base.AscendHandler {
  +	h := &chipHandler{}
  +	h.SetPluginName(PolicyName)
  +	h.SetMaxNodeNPUNum(maxNodeNPUNum)
  +	h.SetMaxCardNPUNum(1)      // 单芯片粒度
  +func ShouldUseAffinity(annotation, selector map[string]string) bool {
  +	if _, ok := annotation[util.SchedulePolicyAnnoKey]; ok { return false }
  +	if _, ok := selector[util.AcceleratorTypeKeyDeprecated]; ok { return false }
  +func (tp *chipHandler) CheckNodeNPUByTask(task *api.TaskInfo, node plugin.NPUNode) error {
  +	result := root.Fit(&util.Request{ReqNPUName: reqName, ReqNPUNum: reqNum,
  +		Mode: tp.ScheduleMode, AllowNetUnhealthy: tp.ParameterPlaneUnhealthyTolerance})
  +	case topo.FitEvict:  return ...NPUResourceShortageError...  // 可经驱逐满足
  +	default:             return ...NPUResourceUnavailableError... // FitFailed
  ```
  </details>

- **拓扑树 `ChipNode` + hard/soft 两种调度模式**(`common/util/request.go` + `topo/chipnode.go`)。新增 `ScheduleMode`(`hard`/`soft`)与 `Request{ReqNPUName,ReqNPUNum,Mode,AllowNetUnhealthy}`;`ParseScheduleMode` 语义**只有字面量 `"hard"` 才是硬模式,其余(空/非法)一律 soft**。`AllowNetUnhealthy` 对应 `huawei.com/parameterplane.unhealthy-tolerance` 注解——容忍参数面网络亚健康的芯片仍可被选中。拓扑树 `ChipNode` 带 `children/leafIndex/owners/faulty/netUnhealthy/allocated` 字段,`ParseTopology` 从 JSON 解析(深度上限 `maxTopoDepth=64`),`BuildFlatTopology(count)` 为无拓扑注解的节点造扁平拓扑兜底。
  <details><summary>代码依据 ascend-for-volcano/common/util/request.go</summary>

  ```diff
  +type ScheduleMode string
  +const (
  +	HardScheduleMode ScheduleMode = "hard"  // 请求芯片须落在单一拓扑域,否则拒绝该节点
  +	SoftScheduleMode ScheduleMode = "soft"  // 只要有足够可用/可驱逐芯片即可
  +type Request struct {
  +	ReqNPUName string; ReqNPUNum int; Mode ScheduleMode; AllowNetUnhealthy bool
  +func ParseScheduleMode(val string) ScheduleMode {
  +	if ScheduleMode(val) == HardScheduleMode { return HardScheduleMode }
  +	return SoftScheduleMode   // 只有 "hard" 是硬,其余全 soft
  ```
  </details>

- **拓扑感知抢占/驱逐:`Preemptable`/`Reclaimable` → `routeEviction` → `SelectEvictSoft`/`SelectEvictHard`**。抢占路由受全局开关 `TopologyAwarePreemptActive` 控制:开启走 `preemptOrReclaim`(拓扑感知,返回全部候选被驱逐者)、关闭走 `preemptOrReclaimSelect`(选择性,取能满足 req 的**最小前缀**受害者)。`Reclaimable` **恒走选择性**路径(注释:拓扑感知路径对 reclaim 过于激进)。soft 模式:先 `CountUsable(allow)>=req` 判零驱逐,否则按 preemptees 顺序累加 `CountEvictSet` 直到够 req;hard 模式:`SelectEvictHard` 与 `canFitHardCheck` 的放置类对齐(单叶组密排 / 整子树填满 / k 个同大小兄弟子树组合),`CanFitHardFor(...)==FitNormal` 即零驱逐。
  <details><summary>代码依据 ascend-for-volcano/internal/npu/affinity/chip/{preempt,preempt_v115}.go + topo/evict.go</summary>

  ```diff
  // preempt.go
  +var TopologyAwarePreemptActive bool
  +func (tp *chipHandler) Preemptable(...) { return tp.routeEviction(...) }
  +func (tp *chipHandler) Reclaimable(...) { return tp.preemptOrReclaimSelect(...) } // 恒选择性
  // preempt_v115.go (build tag volcano_v115)
  +func (tp *chipHandler) routeEviction(...) {
  +	if TopologyAwarePreemptActive { return tp.preemptOrReclaim(...) }  // 返回全部候选
  +	return tp.preemptOrReclaimSelect(...) }
  // topo/evict.go
  +func (n *ChipNode) SelectEvictSoft(req int, allow bool, preemptees []*api.TaskInfo) {
  +	if n.CountUsable(allow) >= req { return nil, true }  // 零驱逐
  +	// 按 framework 顺序累加最小前缀受害者,凑够 req 才返回
  +func (n *ChipNode) SelectEvictHard(req int, allow bool, ...) {
  +	if n.CanFitHardFor(req, allow, nil) == FitNormal { return nil, true }
  ```
  </details>

- **`NPUNode` 挂拓扑树,`initNPUNodeByNodeInf` 消费 `npu.topology` 注解**。`CommonNode` 新增 `ChipTopo *topo.ChipNode` 与 `ChipPods map[int]map[string]*v1.Pod`(芯片 ID → 占用它的 pod)。`ParseChipTopology` 优先读 `n.Annotation[util.TopologyAnnoKey]`(即昨日 device-plugin 写的 `huawei.com/npu.topology`),缺失则 `BuildFlatTopology(getNPUCapacity(node))` 按节点 NPU 容量兜底;`Raw` 变了才重建树(避免每轮重复解析)。同时 `NodePredicate` 重构出 `NodePredicateOnVCNode(taskInfo, vcNode)` 让判定可脱离 `api.NodeInfo` 直接对 `NPUNode` 跑(供 simulate 复用)。
  <details><summary>代码依据 ascend-for-volcano/plugin/node.go</summary>

  ```diff
   type CommonNode struct {
  +	ChipTopo       *topo.ChipNode
  +	ChipPods       map[int]map[string]*v1.Pod
  +func (sHandle *ScheduleHandler) NodePredicateOnVCNode(taskInfo *api.TaskInfo, vcNode NPUNode) error {
   func (n *NPUNode) initNPUNodeByNodeInf(...) {
  +	n.ParseChipTopology(npuNode)
  +func (n *NPUNode) ParseChipTopology(node *api.NodeInfo) {
  +	raw, exist := n.Annotation[util.TopologyAnnoKey]
  +	if !exist { raw = topo.BuildFlatTopology(getNPUCapacity(node)) }
  +	if n.ChipTopo == nil || n.ChipTopo.Raw != raw { n.ChipTopo = topo.ParseTopology(raw) }
  ```
  </details>

- **拓扑感知抢占的调度仿真钩子(build tag `volcano_v115`)**。`npu_simulate.go` 新增 `addSimulateFns`,向 volcano 注册 `AddSimulateRemoveTaskFn`/`AddSimulateAddTaskFn`——仿真"移除/加入某 task"时同步在 `simNode.ChipTopo` 上 `Rollback(pod.UID)` / 占位,使抢占预演结果与真实芯片拓扑一致。是否启用由 preempt action 的配置项 `enableTopologyAwarePreemption` 决定(`topologyAwarePreemptActive` 读 `framework.GetArgOfActionFromConf`)。整套仿真/抢占逻辑都挂在 `volcano_v115` 构建标签下,说明是**面向 volcano v1.15 新抢占框架**的适配。
  <details><summary>代码依据 ascend-for-volcano/npu_simulate.go</summary>

  ```diff
  +//go:build volcano_v115
  +const topologyAwarePreemptionKey = "enableTopologyAwarePreemption"
  +func topologyAwarePreemptActive(ssn *framework.Session) bool {
  +	args := framework.GetArgOfActionFromConf(ssn.Configurations, preemptActionName)
  +	args.GetBool(&active, topologyAwarePreemptionKey)
  +func addSimulateFns(ssn *framework.Session, tp *huaweiNPUPlugin) {
  +	ssn.AddSimulateRemoveTaskFn(tp.Name(), func(...) {
  +		if simNode.ChipTopo != nil && taskToRemove.Pod != nil {
  +			simNode.ChipTopo.Rollback(string(taskToRemove.Pod.UID))
  ```
  </details>

- **infer-operator:pod 级重调度(区别于原有实例级重建)**。`processFaultEvent` 新增分支:`isPodLevelRescheduling(pod)` 为真时走 `processPodLevelRescheduling`——只删故障 pod、删后递减重试计数,由 K8s STS/Deployment 控制器重建 pod;否则保持原实例级逻辑(记录故障 + 删整个 workload)。且 `handlePodDelete` 里 pod 删除事件在 pod 级重调度启用时**直接 return**,避免重复进入重调度流程二次扣减 `faultRetryTimesMap`。重试额度只对业务故障(`PodStatusAnnotationKey` 后缀为 `PodFailed`)计数,硬件故障直删不占额度。
  <details><summary>代码依据 infer-operator/pkg/controller/rescheduling/rescheduling.go</summary>

  ```diff
   func (r *Rescheduler) handlePodDelete(obj interface{}) {
  +	if r.isPodLevelRescheduling(pod) {
  +		// pod 级重调度:K8s 控制器会重建,跳过 workload 重建,避免二次扣减 faultRetryTimesMap
  +		return
   func (r *Rescheduler) processFaultEvent(pod *corev1.Pod) error {
  +	isPodLevel := r.isPodLevelRescheduling(pod)
  +	if isPodLevel { return r.processPodLevelRescheduling(pod, workLoadName, instanceSetName) }
  +func (r *Rescheduler) processPodLevelRescheduling(pod ...) error {
  +	// 重试额度只对业务故障(pod-failed)计数;硬件故障直删不占额度
  +	if faultReason := pod.Annotations[common.PodStatusAnnotationKey]; strings.HasSuffix(faultReason, common.PodFailed) {
  ```
  </details>

- **clusterd:节点预隔离故障统一处理 + 通算任务纳入负载统计**(次要)。`preseparate_fault_processor.go` 与 `pod/pod_util.go` 有改动,提交标题为"节点预隔离故障统一处理,任务负载统计包含添加 volcano 调度的通算任务"——即节点预隔离(pre-separate)故障走统一处理路径,且负载统计口径从"仅 NPU 任务"扩到"含 volcano 调度的通用计算任务"。本区间该文件 patch 未进前 8 优先(被 chip/ 新包挤出),仅从信号文件+标题判断,未逐 hunk 读符号,不做更细结论。

### 后续发展方向 [AI]
- 昇腾调度正从"整环/整卡粒度(8/16 卡 sp 策略)"下沉到"**单芯片粒度的拓扑树 + 拓扑感知抢占**":本期 `chip-affinity`(`SetMaxCardNPUNum(1)`)与上期 `chip8-node16-sp`(整环 16 卡)形成对照,`ShouldUseAffinity` 明确二者互斥(带旧策略注解就不走新路径),说明这是一条**新的、并行的**调度路径而非替换。全套 preempt/simulate 挂 `volcano_v115` 构建标签,证据指向对 volcano v1.15 新抢占/仿真框架的适配;但树的构建细节(`buildNode` 如何从 JSON 解析出 HCCS 域层级)、hard 模式三种放置类的打分权重本区间 patch 被截断,未完整读到。
- 拓扑数据链路已闭环:device-plugin(上期 `topologyAnnotator` 写 `npu.topology`)→ scheduler(本期 `ParseChipTopology` 读同一注解建树)。下一步可关注注解缺失时 `BuildFlatTopology` 兜底是否会掩盖真实 HCCS 拓扑导致亲和退化——证据只到"缺失走扁平树",未见告警/降级日志。
- infer-operator 的重调度粒度在细化:从"删整个 workload 重建"到"pod 级只删故障 pod",且把重试预算与故障类型(业务/硬件)解耦。方向是**推理实例故障恢复更精细、更省重建代价**;证据覆盖到删除路径与计数逻辑,但 `isPodLevelRescheduling` 具体读哪个 label/CRD 字段开关本区间未读到 hunk。

## npu-dra-plugin: 1084df7c -> f3cfd270
- 比较: 1084df7c..f3cfd270 | tag: v26.6.0 | commits=5 | truncated=false
- 源: https://gitcode.com/openFuyao/npu-dra-plugin/compare/1084df7c16dbb60173b0dbc8e4cd561dd45b430d...f3cfd270f0dda85b259f4041d6c99824920e17e5

### AI 总结重点(源码 diff 为据)

- **NPU 拓扑发现:从外挂 `npu-smi` 命令行解析改成 DCMI + HAL 库原生调用**。`dcmi.go` 删除 `runNpuSmiCommand`(`exec.CommandContext` 跑 `/usr/local/bin/npu-smi`)及其重试/超时常量(`npuSmiAttempts=3`/`npuSmiTimeout=3s`/`npuSmiRetryDelay`),改为两个接口:`dcmiDiscoveryManager`(`GetCardList`/`GetDeviceCount`/`GetLogicID`/`GetPhysicalIDByLogicID`/`GetPCIeBusID`/`GetDieID`…)与 `halTopologyManager`(`GetPairPhysicalTopology`)。工厂变量 `newDCMIManager=platformDCMIManager`、`newHALManager=hal.NewManager` 便于测试打桩。丢弃了对 `bufio`/`bytes`/`os/exec`/`time` 的依赖——不再解析 CLI 文本输出。
  <details><summary>代码依据 npu-dra-plugin/internal/profiles/npu/dcmi.go</summary>

  ```diff
  -	npuSmiPath         = "/usr/local/bin/npu-smi"
  -	npuSmiAttempts     = 3
  -	npuSmiTimeout      = 3 * time.Second
  -var runNpuSmiCommand = func(ctx context.Context, args ...string) ([]byte, error) {
  -	return exec.CommandContext(ctx, npuSmiPath, args...).Output()
  +type dcmiDiscoveryManager interface {
  +	GetCardList() ([]int, error); GetLogicID(cardID, deviceID int) (int, error)
  +	GetPhysicalIDByLogicID(logicID int) (int, error); ...
  +type halTopologyManager interface {
  +	GetPairPhysicalTopology(physicalID1, physicalID2 int) (hal.TopologyType, error)
  +var newDCMIManager = platformDCMIManager
  +var newHALManager = func() halTopologyManager { return hal.NewManager() }
  ```
  </details>

- **新增 `pkg/hal` 包:cgo dlopen 昇腾 HAL 库读芯片对拓扑关系**。`manager_linux.go`(`//go:build linux && cgo`)用 `dlfcn.h` 动态加载 HAL 库、查符号 `hal_get_pair_phy_devices_info`(`HAL_PAIR_INFO_TYPE_TOPOLOGY=0`),`manager_stub.go`(`!linux || !cgo`)返回"unavailable"。`topology.go` 定义 `TopologyType` 及 8 个关系值,注释明确**镜像 `ascend_hal_base.h`**:`HCCS(0)/PIX(1)/PIB(2)/PHB(3)/SYS(4)/SIO(5)/HCCSSW(6)/UB(7)`——即把 HAL 原生的芯片互联拓扑等级直接暴露给 DRA 亲和上报。
  <details><summary>代码依据 npu-dra-plugin/pkg/hal/{topology,manager_linux,manager_stub}.go</summary>

  ```diff
  // topology.go
  +type TopologyType int64
  +const (   // 镜像 ascend_hal_base.h
  +	TopologyTypeHCCS TopologyType = 0; TopologyTypePIX = 1; TopologyTypePIB = 2
  +	TopologyTypePHB = 3; TopologyTypeSYS = 4; TopologyTypeSIO = 5
  +	TopologyTypeHCCSSW = 6; TopologyTypeUB = 7 )
  // manager_linux.go (linux && cgo)
  +typedef int (*hal_get_pair_phy_devices_info_func)(uint32_t, uint32_t, int32_t, int64_t *);
  +enum { HAL_PAIR_INFO_TYPE_TOPOLOGY = 0, ... };
  // manager_stub.go (!linux || !cgo)
  +func (m *Manager) GetPairPhysicalTopology(int, int) (TopologyType, error) {
  +	return 0, errors.New("Ascend HAL topology is unavailable on this platform")
  ```
  </details>

- **DieType/芯片前缀常量迁出 `dcmi.go` 到独立 `pkg/dcmi/types.go` + 平台构建标签拆分**。`DieType`(`NDIE=0`/`VDIE=1`)、`ChipPrefixAscend910B`/`ChipPrefixAscend910` 从需要 cgo 的 `dcmi.go` 移到纯 Go 的 `types.go`,使非 cgo 构建也能引用这些类型。`platformDCMIManager` 按构建标签分裂:`dcmi_manager_linux.go` 返回真实 `dcmi.NewDCMIManager()`,`dcmi_manager_stub.go` 返回 `nil`——让整个 DRA plugin 在无昇腾库的平台(CI/交叉编译)可编译可测。对应提交"DCMI 拓扑主路径优先并兼容双 ID 回退":以 DCMI 查到的 physical/logic 双 ID 为主路径,失败再回退。
  <details><summary>代码依据 npu-dra-plugin/pkg/dcmi/types.go + internal/profiles/npu/dcmi_manager_{linux,stub}.go</summary>

  ```diff
  // pkg/dcmi/types.go (新文件,纯 Go 无 cgo)
  +type DieType int32
  +const ( ChipPrefixAscend910B = "910B"; ChipPrefixAscend910 = "Ascend910"
  +	NDIE DieType = 0; VDIE DieType = 1 )
  // pkg/dcmi/dcmi.go —— 从 cgo 文件里删掉,避免非 cgo 构建拿不到
  -type DieType int32
  -	ChipPrefixAscend910B = "910B" ...
  // dcmi_manager_linux.go / dcmi_manager_stub.go
  +func platformDCMIManager() dcmiDiscoveryManager { return dcmi.NewDCMIManager() }  // linux&&cgo
  +func platformDCMIManager() dcmiDiscoveryManager { return nil }                    // !linux||!cgo
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 DRA 路径正把"设备发现/拓扑"从**脆弱的 CLI 文本抓取**换成**HAL/DCMI 原生库调用**,拿到的是芯片对之间的真实互联等级(HCCS/SIO/UB…),精度和稳定性都上一个台阶——这与 mind-cluster 侧 `chip-affinity` 拓扑树是**同一趋势的两端**(采集端拿真拓扑、调度端按真拓扑亲和/抢占)。证据到接口与 HAL 符号定义;`GetPairPhysicalTopology` 的返回值如何聚合成节点级拓扑树(供 DRA `ResourceSlice` 上报)本区间 patch 被截断,未读到。
- 构建标签拆分(linux&&cgo vs stub)是工程化信号:昇腾组件在补齐"无硬件/无 HAL 库平台可编译可 UT"的能力(`dcmi_test.go` 增 1044 行、新增 `dcmi_topology_test.go` 527 行),便于 CI 与跨平台交付。方向是把强依赖昇腾底座的代码用接口 + 桩隔离;证据覆盖到 stub 实现与工厂变量,未见 CI 配置改动。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(仅保锚点,无新提交)</summary>

- npu-operator(无新提交,tag v26.6.0)
- npu-container-toolkit(无新提交,tag v26.6.0)
- npu-driver-installer(无新提交,tag v26.6.0)
- vNPU(无新提交,tag v0.1.0)
- npu-node-provision(无新提交,tag v26.6.0)
- volcano-ext(无新提交,tag v1.9.0)
- ub-network-device-plugin(无新提交,tag 1.0.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=6a2e299e85af9de5a06c8bb81a17b7640bf86923 tag=v26.2.0.beta.1 scanned=2026-09-04 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f3cfd270f0dda85b259f4041d6c99824920e17e5 tag=v26.6.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=ef44c337d16e208fc1557b8e56a77447f30bc2a7 tag=1.0.2 scanned=2026-09-04 -->
</content>
</invoke>
