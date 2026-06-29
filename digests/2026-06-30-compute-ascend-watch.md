# 昇腾算力栈 diff 雷达 2026-06-30

## 摘要
- mind-cluster 把昇腾故障模型从"卡级+网络"二分重构为 **Chip / 参数面(ParameterPlane) / 超平面(HyperPlane) 三平面分类**:device-plugin 新增 UB/UBOE 的"预隔离/亚健康"精细子故障码(int64 化)、按平面拆分故障缓存与上报通道,并新增多卡整体故障判定(`SetHyperPlaneNewOverallFault`)。
- infer-operator 落地**外部重调度(external rescheduling)级联删 Pod**:`external-force` 立即强删(grace=0)、`external-grace` 读 Pod 自身 `TerminationGracePeriodSeconds` 起定时器超时后强删,用 inferService/instanceSet 三标签精确定位本工作负载的 Pod。
- openFuyao/vNPU 新增 **spread/binpack 两级(节点级+设备级)调度策略**,vNPU 插件自带 `computeNodeScore` 打分并在 volcano 配置里**关掉通用 nodeorder 插件**自己接管节点排序。

## 当日重要改变
- mind-cluster [架构方向] device-plugin 故障分类从"网络/非网络"升级为 Chip/参数面/超平面三平面(`ClassifyFaultInfos` + 三个 `*FaultKey` 常量),并删除 `DevManager` 接口的 `HandleUBOELinkDownCheck`/`DoHandleUboeLinkDownCheck` 两个方法。证据:`component/ascend-device-plugin/pkg/device/ascendcommon.go`、`pkg/common/constants.go`。https://gitcode.com/Ascend/mind-cluster/commit/43913f29d3e387d8009f3dbeccbdd29eea431163
- mind-cluster [新能力] 新增 UB/UBOE "预隔离+亚健康"精细故障码与精确子码映射表(`UBOEPreSeparateFaultCode`/`UBOESubHealFaultCode`/`UBSeparateFaultCode`/`UBSubHealFaultCode` + `UBOEPreciseFaultCodesMap`/`UBPreciseFaultCodesMap`)。证据:`component/ascend-device-plugin/pkg/common/fault_code.go`。
- mind-cluster [新能力] infer-operator 新增 `workload_common.go`,实现 external-force/external-grace 两种外部重调度的 Pod 级联删除。证据:`component/infer-operator/pkg/controller/workload/workload_common.go`、`pkg/common/constant.go`。
- vNPU [新能力] 新增 `huawei.com/vnpu-pod-node-scheduler-policy` / `huawei.com/vnpu-pod-device-scheduler-policy` 两个调度策略注解(spread/binpack,默认 binpack)。证据:`volcano-xpu-plugin/util/type.go`、`plugin/node.go`。https://gitcode.com/openFuyao/vNPU/commit/dae5c9f541fc402bd0703b17764bb89b98e63b2c

## mind-cluster: 2b57acd0 -> 43913f29
- 比较: 2b57acd0763f9f9220c3e8e54ebed79da4cbac06..43913f29 | tag: v26.0.1 | commits=14 | truncated=false
- 源链接:https://gitcode.com/Ascend/mind-cluster/compare/2b57acd0763f9f9220c3e8e54ebed79da4cbac06...43913f29d3e387d8009f3dbeccbdd29eea431163

### AI 总结重点(源码 diff 为据)
- **故障平面三分类落地**:`flushFaultCodesWithInit` 改名为 `flushFaultCodesWithInitForSingleDevice`,内部不再直接调"网络/非网络"两条上报,而是先 `ClassifyFaultInfos` 把一卡的故障按 Chip/参数面/超平面分桶,再分别走 `SetNewFaultAndCacheOnceRecoverFault`(芯片)/`SetNetworkNewFaultAndCacheOnceRecoverFault`(参数面)/新增的 `SetHyperPlaneNewFaultAndCacheOnceRecoverFault`(超平面);并在多卡循环外新增 `modifyFaultCodesForMultiDevices`→`SetHyperPlaneNewOverallFault` 做跨卡整体判定。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  -			tool.flushFaultCodesWithInit(device, devFaultInfoMap)
  +			tool.flushFaultCodesWithInitForSingleDevice(device, devFaultInfoMap)
   			common.CountFaultDuration(device, devFaultInfoMap)
  +		}
  +		tool.modifyFaultCodesForMultiDevices(devices)
  +		for _, device := range devices {
  -	common.SetNewFaultAndCacheOnceRecoverFault(device.LogicID, devFaultInfoMap[logicID], device, curFaultCodesMap)
  -	common.SetNetworkNewFaultAndCacheOnceRecoverFault(device.LogicID, devFaultInfoMap[logicID], device)
  +	classified := common.ClassifyFaultInfos(devFaultInfoMap[logicID])
  +	common.SetNewFaultAndCacheOnceRecoverFault(device.LogicID, classified[common.ChipFaultKey], device, curFaultCodesMap)
  +	common.SetNetworkNewFaultAndCacheOnceRecoverFault(device.LogicID, classified[common.ParameterPlaneFaultKey], device)
  +	common.SetHyperPlaneNewFaultAndCacheOnceRecoverFault(device.LogicID, classified[common.HyperPlaneFaultKey], device)
  ```
  </details>

- **命名从"network"统一改成"parameterPlane"**:`networkStatus`/`networkLimiterMap`/`networkStatusCache` 全部重命名为 `parameterPlaneStatus`/`parameterPlaneLimiterMap`/`parameterPlaneStatusCache`,且字段从 `upPortsNum` 改为 `downPortsNum`(从"统计在线端口"转为"统计掉线端口")。这与上面三平面分类配套——原"网络"语义被收窄为"参数面"。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  -type networkStatus struct {
  -	status     string
  -	upPortsNum int
  +type parameterPlaneStatus struct {
  +	status       string
  +	downPortsNum int
  ```
  </details>

- **UB/UBOE 精细故障码 + 平面集合拆分**:新增 4 个 int64 故障码(UBOE 预隔离 `110001024` / UBOE 亚健康 `110000002` / UB 隔离 `020001002` / UB 亚健康 `020000002`),所有故障码常量补 `int64` 显式类型;原 `NetworkFaultCodes`/`ParameterPlaneFaultCodes` 二集合改为 `NetworkFaultCodes`(挂 UBOE 系)+ 新 `HyperPlaneFaultCodes`(挂 UB 系),并加 `UBOEPreciseFaultCodesMap`/`UBPreciseFaultCodesMap` 记录主码→精确子码。clusterd 侧同步补 UBOE 子码与 `ParameterPlaneFaultCodes` 集合。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
  +	UBSeparateFaultCode int64 = 0x020001002
  +	UBSubHealFaultCode int64 = 0x020000002
  +	UBOEPreSeparateFaultCode int64 = 0x110001024
  +	UBOESubHealFaultCode int64 = 0x110000002
  -	NetworkFaultCodes = sets.NewInt64(LinkDownFaultCode, UBOEPortDownCode, UBPortDownCode)
  -	ParameterPlaneFaultCodes = sets.NewInt64(LinkDownFaultCode, UBOEPortDownCode)
  +	NetworkFaultCodes = sets.NewInt64(LinkDownFaultCode, UBOEPortDownCode, UBOESubHealFaultCode, UBOEPreSeparateFaultCode)
  +	HyperPlaneFaultCodes = sets.NewInt64(UBPortDownCode, UBSeparateFaultCode, UBSubHealFaultCode)
  ```
  </details>

- **A950/910A5 卡型判定 + 故障处理链抽象**:新增 `isA950CardType()`(判 `Ascend910A5`)与 `FaultHandlingStep{Name, Do func()}` 命名步骤结构,故障处理从硬编码转为可串联步骤链(hunk 截断,未覆盖链的装配处)。同时 `faultCustomization.json` 删掉了 `81B18603`(UB 端口 down)的 5s 超时 `PreSeparateNPU` 定制项,`device.go` 删除 `WithoutParameterPlane()` 函数——参数面有无改由新分类逻辑承载。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go / device.go</summary>

  ```diff
  +func isA950CardType() bool {
  +	return ParamOption.RealCardType == Ascend910A5
  +}
  +type FaultHandlingStep struct {
  +	Name string
  +	Do   func()
  -// WithoutParameterPlane indicate device has no parameter plane
  -func WithoutParameterPlane() bool { ... }
  ```
  </details>

- **infer-operator 外部重调度级联删 Pod**:新增 `deletePodsForExternalRescheduling`,只在工作负载带 `fault-scheduling=external-force|external-grace` 标签时生效;用 `inferServiceName`+`instanceSetName`+`instanceSetIndex` 三标签精确 List 本负载的 Pod。force 走 `forceDeletePodList`(grace=0)立即强删;grace 读 Pod 自身 `TerminationGracePeriodSeconds`(无则默认 30s)起定时器,超时后强删残留 Pod。

  <details><summary>代码依据 component/infer-operator/pkg/controller/workload/workload_common.go(新增)</summary>

  ```diff
  +	case common.ExternalForceReschedulingValue:
  +		forceDeletePodList(ctx, cli, podList.Items)
  +	default:
  +		waitSeconds := int64(common.DefaultTerminationGracePeriodSeconds)
  +		if grace := podList.Items[0].Spec.TerminationGracePeriodSeconds; grace != nil && *grace > 0 {
  +			waitSeconds = *grace
  ```
  </details>

### 后续发展方向 [AI]
- "参数面 vs 超平面"双平面是昇腾把 **UB(超节点内部超平面)与 UBOE(以太承载参数面)的故障域彻底分治**的信号:这次只完成了故障码分类与上报通道拆分,下一步大概率把超平面整体故障(`SetHyperPlaneNewOverallFault`)接到调度/重调度的卡级健康口径上。证据只覆盖 device-plugin 的分类与缓存写入,未见调度侧(for-volcano)消费超平面健康的改动。
- infer-operator 的 external-force/external-grace 把"重调度时谁来删旧 Pod"从控制器内置策略改成**由外部(调度器/上层编排)下发标签触发**,配合"亚健康/预隔离"故障码,指向昇腾在做"故障感知→温和迁移(grace)/强制迁移(force)"的推理实例自愈闭环。证据只覆盖删 Pod 路径,未见谁写入 `fault-scheduling` 标签的上游逻辑。

## vNPU: ed90d497 -> dae5c9f5
- 比较: ed90d497b78be919aa5c571daf7b8914bc89c7fe..dae5c9f5 | tag: v0.1.0 | commits=4 | truncated=false
- 源链接:https://gitcode.com/openFuyao/vNPU/compare/ed90d497b78be919aa5c571daf7b8914bc89c7fe...dae5c9f541fc402bd0703b17764bb89b98e63b2c

### AI 总结重点(源码 diff 为据)
- **两级 spread/binpack 调度策略**:新增节点级 `huawei.com/vnpu-pod-node-scheduler-policy` 与设备级 `huawei.com/vnpu-pod-device-scheduler-policy` 注解,取值 binpack(紧凑,集中到少数节点/设备)/spread(打散,分散到更多节点/设备),默认 binpack;`GetNodeSchedulerPolicy`/`GetDeviceSchedulerPolicy` 对非法值告警并回落 binpack。

  <details><summary>代码依据 volcano-xpu-plugin/util/type.go / util.go</summary>

  ```diff
  +	NodeSchedulerPolicyAnnotation   = "huawei.com/vnpu-pod-node-scheduler-policy"
  +	DeviceSchedulerPolicyAnnotation = "huawei.com/vnpu-pod-device-scheduler-policy"
  +	SchedulerPolicyBinpack          = "binpack"
  +	SchedulerPolicySpread           = "spread"
  +	if policy != SchedulerPolicyBinpack && policy != SchedulerPolicySpread {
  +		klog...Infof("invalid scheduler policy ... fallback to %s", ...)
  +		return SchedulerPolicyBinpack
  ```
  </details>

- **节点打分由插件自算 + 关掉 volcano 通用 nodeorder**:新增 `computeNodeScore` 按节点上所有 vNPU 设备的 used/total cores(硬切分只看 cores)及 mem 算占用率得分;`NodePredicateForTask` 里 spread 策略把得分取反(`maxScore - nodeScore`,软 200/硬 100),实现"打散优先选低占用节点"。volcano 配置同步给 priority/gang/conformance/drf/predicates/proportion/binpack 全部 `enableNodeOrder: false` 并删除 `nodeorder` 插件——节点排序完全交给 vNPU 插件自己。

  <details><summary>代码依据 volcano-xpu-plugin/plugin/plugin.go / node.go / charts/yaml/volcano-deployment.yaml</summary>

  ```diff
  +	nodeScore := computeNodeScore(node.Name, sh.getNodeXPUDevices(node.Name), podMode)
  +	nodePolicy := util.GetNodeSchedulerPolicy(task.Pod)
  +	if nodePolicy == util.SchedulerPolicySpread {
  +		nodeScore = float64(maxScore) - nodeScore
  -      - name: nodeorder
  +      - name: binpack
  +        enableNodeOrder: false
  ```
  </details>

- **软/硬切分分配重构为 check+apply 两段**:`allocateSoftModeDevice` 拆为 `checkSoftModeDevice`(只判定+算分,不改设备状态)+ `applySoftModeDevice`(真正占用 mem/cores、分配 vid);`allocateHardModeDevice` 拆出 `checkHardModeDevice` 返回 `hardModeResult`;新增 `candidateDevice`/`ScheduleConfig` 等结构。这是为"先打分排序、再落实分配"的设备级 spread/binpack 铺路。

  <details><summary>代码依据 volcano-xpu-plugin/plugin/vxpu.go</summary>

  ```diff
  -func allocateSoftModeDevice(device *common.XPUDevice, val *util.ContainerResource) (bool, *common.ContainerDevice, float64) {
  +func checkSoftModeDevice(device *common.XPUDevice, val *util.ContainerResource) (bool, int, float64) {
  +func applySoftModeDevice(device *common.XPUDevice, val *util.ContainerResource, realReqXPUMem int) *common.ContainerDevice {
  +type candidateDevice struct { ... }
  +type ScheduleConfig struct { Templates TemplateInfos; Policy string; PodMode string }
  ```
  </details>

- **fix: npu-smi hostPath 强制为文件**:device-plugin daemonset 把挂载的 npu-smi hostPath 类型约束为 File(防止目录/不存在时静默成功),1 行变更(`charts/vnpu/templates/npu-device-plugin-daemonset.yaml`)。

### 后续发展方向 [AI]
- vNPU 把节点排序从 volcano 通用 nodeorder 收回到自己插件,意味着昇腾 vNPU 调度要做**自洽的 cores+mem 双维打分**,后续设备级 spread/binpack(`DeviceSchedulerPolicyAnnotation`)应会落到 `checkHardModeDevice`/候选设备排序里。证据只覆盖节点级打分与策略取反,设备级策略的注解已定义但本期 hunk 未见其在设备选择中的实际消费点。
- check/apply 两段式分配是典型的"两阶段提交"调度重构,为同一调度周期内多设备候选比较打基础;结合 `huawei.com/vnpu-mode` 默认值文档从"调度器自动选"改为"默认 soft",vNPU 在向"显式策略可控、行为可预期"的产品化方向收敛。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓本期无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:自 06-29 锚点以来无新提交,保锚点链。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=43913f29d3e387d8009f3dbeccbdd29eea431163 tag=v26.0.1 scanned=2026-06-30 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-30 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-30 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-30 -->
<!-- ANCHOR repo=vNPU sha=dae5c9f541fc402bd0703b17764bb89b98e63b2c tag=v0.1.0 scanned=2026-06-30 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-30 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b28f10a1e98ec0c2af8be45928e08e689d4a7fb4 tag=1.0.1 scanned=2026-06-30 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-30 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-30 -->
