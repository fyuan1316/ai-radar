# 昇腾算力栈 diff 雷达 2026-10-15

## 摘要
- **mind-cluster 本期是两处健壮性修复,无能力/架构/API 改动**:①infer-operator 快照控制器在 StatefulSet `Spec.Replicas` 为 nil 时回退 `DefaultReplicas`,消除 `*stsSpec.Replicas` 空指针 panic;②ascend-device-plugin 的 hyper plane(超平面网络)故障事件处理新增"设备不健康且已超 5 分钟"的补偿触发条件,避免首刷/订阅失败之外的漏处理。另有 Go module 版本升到 1.26.0(非功能)。
- 其余 8 仓(openFuyao 全部:npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期**无新提交**,全 EMPTY。
- 无 `[弃用/移除]`/`[API/CRD变更]`/`[架构方向]`/`[新能力]` 信号命中,当日重要改变为"无"。

## 当日重要改变
- 无(本期仅 bug 修复 + 补偿逻辑收口,未命中重要改变信号)。

## mind-cluster: 2d551d3f -> 363fcc79
- 比较:2d551d3f..363fcc79 | tag: v26.1.1 | commits=6 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/2d551d3fee466af0a4b65f5a7a6abbc3a2a47c51...363fcc798b562c2d85ef3eb39703b043261bc8fd

### AI 总结重点(源码 diff 为据)

- **infer-operator 快照控制器修空指针 panic:`stsSpec.Replicas` 为 nil 时回退到 `common.DefaultReplicas`**。原代码直接解引用 `*stsSpec.Replicas` 传给 `TrackInstanceSet`,而 `shouldProcessInstanceset` 只校验了顶层 `Spec.Replicas`、不保证内嵌 StatefulSetSpec 的 `Replicas` 非空(用户下发的 `instanceSpec` 可缺省该字段),故会 panic。改为先取 `podReplicas := common.DefaultReplicas`,仅当 `stsSpec.Replicas != nil` 才覆盖为实际值,与 workload 的 defaulting 语义对齐。
  <details><summary>代码依据 component/infer-operator/pkg/snapshot/instanceset_snapshot_controller.go</summary>

  ```diff
  +	// stsSpec.Replicas may be nil since shouldProcessInstanceset only guards the top-level
  +	// Spec.Replicas; fall back to DefaultReplicas, consistent with workload defaulting
  +	podReplicas := common.DefaultReplicas
  +	if stsSpec.Replicas != nil {
  +		podReplicas = *stsSpec.Replicas
  +	}
  	trackerKey := r.SnapshotChecker.getInstanceSetKey(instanceSet.Namespace, instanceSet.Name)
  	r.SnapshotChecker.removeTracker(trackerKey)
  -	if err := r.SnapshotChecker.TrackInstanceSet(instanceSet, selectLabels, *stsSpec.Replicas); err != nil {
  +	if err := r.SnapshotChecker.TrackInstanceSet(instanceSet, selectLabels, podReplicas); err != nil {
  ```
  </details>
  配套单测 `TestInstanceSetSnapshotReconcilerReconcile2` 新增一例:`instanceSpec` 的 StatefulSetSpec 不设 `Replicas` 时,Reconcile 不报错且 tracker 的 `Replicas == common.DefaultReplicas`。证据边界:只改了 `TrackInstanceSet` 入参路径,未见 `DefaultReplicas` 取值本身或其他解引用点是否还有同类风险。

- **ascend-device-plugin 超平面故障处理新增"持续不健康超 5 分钟"的补偿触发项**。`HandleLostHyperPlaneFaultEvents` 原触发条件是 `isFirstFlushFault || Contains(initLogicIDs, device.LogicID) || common.SubscribeFailed`(首次刷新 / 初始逻辑 ID 命中 / 订阅失败三种)。新增第四项 `|| (device.Health == v1beta1.Unhealthy && moreThanFiveMin(device))`:当设备已判定 Unhealthy 且不健康持续超过 5 分钟时,也进入"丢失超平面故障"处理分支,堵住前三条件都不满足、但设备长时间不健康导致超平面故障事件被漏处理的窗口。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  	needHandleLostHyperPlaneFaultCondition := isFirstFlushFault || (common.Int32Tool.Contains(initLogicIDs,
  -		device.LogicID)) || common.SubscribeFailed
  +		device.LogicID)) || common.SubscribeFailed || (device.Health == v1beta1.Unhealthy && moreThanFiveMin(device))
  	if !needHandleLostHyperPlaneFaultCondition {
  		return
  	}
  ```
  </details>
  证据边界:patch 只展示了触发条件这一行,`moreThanFiveMin(device)` 的实现(以何时间戳起算、是否可配)未在本次 hunk 中出现;提交标题「加入设备不健康超过5分钟的补偿逻辑」与代码一致,但 5 分钟是否硬编码、与前述 SilentFault/pod-error 卡级退避(10-14 期)是否同一容错体系,本期 diff 不足以判断。

- **Go module 版本升到 1.26.0**(提交「【MindCluster】 Go module version 修改为1.26.0」),属工具链 bump,非功能改动,不展开。

### 后续发展方向 [AI]
- 两处改动都是**故障/异常路径的健壮性收口**,延续昇腾栈近期"把漏判的故障/异常态显式纳入处理"的主线:上期(10-14)是卡级 SilentFault/pod-error 时间窗退避,本期是超平面网络故障的"长时间不健康"补偿触发 + 快照控制器的空值防御。方向上昇腾在 infer-operator(推理实例快照/续训)与 device-plugin(网络故障感知)两层持续补边界条件,而非新增能力。证据仅覆盖 `HandleLostHyperPlaneFaultEvents` 的触发条件与快照 Reconcile 的 nil 防御,未见超平面故障的上报/恢复全链路。
- openFuyao 侧(npu-operator / vNPU / npu-container-toolkit / npu-driver-installer 等)连续多日零提交,驱动容器化与 NPU 虚拟化方向本期无增量信号可读。

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
<!-- ANCHOR repo=mind-cluster sha=363fcc798b562c2d85ef3eb39703b043261bc8fd tag=v26.1.1 scanned=2026-10-15 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-15 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-15 -->
