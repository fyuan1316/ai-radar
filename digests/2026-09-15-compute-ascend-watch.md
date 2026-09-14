# 昇腾算力栈 diff 雷达 2026-09-15

## 摘要
- **mind-cluster 调度侧两处硬隔离/生效性修复**:①ascend-for-volcano 新增 `rejectWholeCardOnSoftShareNode` —— VCANN-RT 软切节点(`softShareDev.enable=true`)的物理卡被虚拟成软切片后**只接软切任务、拒整卡任务**,堵住"整卡任务被调度到软切节点"的资源逃逸;②`updatePgAnnotation` 现按 `EnableDequeueAnnoKey` 三态开关限定,且 enqueue/dequeue 注解变更后补打 dirty condition,修"pg annotation 改了不生效"。
- **容器 runtime 修 CDI 误注入**:ascend-docker-runtime `processDevicesCDI` 无设备时提前返回,防系统 Pod(无昇腾卡)被塞进昇腾驱动 bind-mount —— 对标 nvidia CDI 路径同类洁净性修复。
- **npu-operator 让 volcano 调度插件名跟随节点架构**:configMap hook 现按节点 `NodeInfo.Architecture` 把 `volcano-npu_v7.3.0_linux-aarch64` 改写成 `_linux-x86_64`,修 x86 控制面上插件名 arch 后缀不匹配。其余 7 仓 EMPTY。

## 当日重要改变
- mind-cluster [新能力/调度隔离] 软切(VCANN-RT)节点拒绝整卡任务,防整卡任务落到已软切物理卡上 —— 证据 `component/ascend-for-volcano/plugin/job.go`+`plugin/node.go`(commit 974202897d) https://gitcode.com/Ascend/mind-cluster/commit/974202897d
- mind-cluster [bugfix/容器runtime] CDI 模式无昇腾设备时跳过 CDI 注入,避免系统 Pod 被注入昇腾驱动 bind-mount —— 证据 `component/ascend-docker-runtime/runtime/process/process.go`(commit ad4d5f1a95) https://gitcode.com/Ascend/mind-cluster/commit/ad4d5f1a95
- mind-cluster [调度] PodGroup condition 类型参数化 + dequeue 注解变更补 dirty condition,修 pg annotation 改了不生效 —— 证据 `component/ascend-for-volcano/npu.go`(commit 830788c6e7) https://gitcode.com/Ascend/mind-cluster/commit/830788c6e7
- mind-cluster [监控] npu-exporter node_base_info 指标新增 dcmiVersion 标签(dcmi_get_driver_version 接口),device-plugin driverVersion labeler 改用 GetDriverVersion —— 证据 `component/npu-exporter/collector/metrics/collector_for_node_base.go`+`component/ascend-device-plugin/pkg/server/labelers.go`(commit c568b6d90a) https://gitcode.com/Ascend/mind-cluster/commit/c568b6d90a
- npu-operator [Operator/调度适配] volcano 调度插件名按节点架构改写(aarch64→x86_64)—— 证据 `internal/controller/resources_basic_hooks.go`(PR !117) https://gitcode.com/openFuyao/npu-operator/pulls/117

## mind-cluster: 7537ed62 -> 7ec21612
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/7537ed628111e89f82e4823cd36b2c983d86ab6b...7ec21612e08b67dc4478cc1262e7fc49ed48bd42 | tag: v26.2.0.beta.1 | commits=24 | truncated=false

### AI 总结重点(源码 diff 为据)
- **软切节点整卡任务拒绝(资源隔离新逻辑)**:`NodePredicateOnVCNode` 谓词链新插入 `rejectWholeCardOnSoftShareNode`。逻辑:节点带 `SchedulerSoftShareDevEnableNodeLabel=true` 且任务**不同时**满足"带 `SchedulerSoftShareDevPolicyKey` 标签 + `SchedulePolicyAnnoKey==chip1-softShareDev` 注解"时,直接 predicate 失败拒绝。即软切(VCANN-RT)节点上物理卡被虚拟成软切片后不再接整卡独占请求。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go + plugin/node.go</summary>

  ```diff
  +// rejectWholeCardOnSoftShareNode rejects a whole-card task when the node enables chip soft-share (VCANN-RT)
  +func (sJob SchedulerJob) rejectWholeCardOnSoftShareNode(task *api.TaskInfo, node NPUNode) error {
  +	if node.Label[util.SchedulerSoftShareDevEnableNodeLabel] != "true" {
  +		return nil
  +	}
  +	_, hasSoftSharePolicyLabel := sJob.Label[util.SchedulerSoftShareDevPolicyKey]
  +	if hasSoftSharePolicyLabel && sJob.Annotation[util.SchedulePolicyAnnoKey] == util.Chip1ShareShareDev {
  +		return nil
  +	}
  +	return fmt.Errorf("node %s enables chip soft share dev, whole-card task %s is not allowed", node.Name, task.Name)
  +}
  ```
  ```diff
  // NodePredicateOnVCNode
  +	if err := vcJob.rejectWholeCardOnSoftShareNode(taskInfo, vcNode); err != nil {
  +		klog.V(util.LogDebugLev).Infof("NodePredicateOnVCNode err: %v", err)
  +		return err
  +	}
   	if err := vcJob.preCheckNodePredicate(taskInfo, vcNode); err != nil {
  ```
  </details>

- **CDI 无设备提前返回(修系统 Pod 误注入)**:`processDevicesCDI` 开头新增 `if len(devices) == 0 { return nil }`,并把原来包在 `if len(devices) != 0` 里的 vDevice 解析/设备类型解析提到顶层。此前无设备也会走完 CDI 注入流程,导致系统 Pod 被塞昇腾驱动 bind-mount。

  <details><summary>代码依据 component/ascend-docker-runtime/runtime/process/process.go</summary>

  ```diff
   func processDevicesCDI(spec *specs.Spec, devices []int) error {
  +	if len(devices) == 0 {
  +		return nil
  +	}
   	runtimeOpts := getValueByKey(spec.Process.Env, ascendRuntimeOptions)
  -	var devType, productType string
  -	var useVirtual bool
  -	if len(devices) != 0 {
  -		npuWorker, err := dcmi.GetMatchingNpuWorker()
  -		...
  -	}
  +	npuWorker, err := dcmi.GetMatchingNpuWorker()
  +	devices, useVirtual, err := resolveVDevice(spec, npuWorker, devices)
  +	devType, productType, err := resolveDeviceTypes(npuWorker)
  ```
  </details>

- **PodGroup condition 类型参数化 + dequeue 注解 dirty 化(修 pg annotation 不生效)**:`addPodGroupCondition` 签名加 `condType scheduling.PodGroupConditionType`(此前硬编码 `PodGroupUnschedulableType`),匹配去重也按 condType。`updatePgAnnotation` 现只对开了 `EnableDequeueAnnoKey==EnableDequeueOnVal` 的作业动注解,且 enqueue 写入/dequeue 删除后调 `addJobDirtyConditionWhenAnnoChanged`,让注解变更被下游感知生效。

  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
  +		if val, exist := jobInfo.PodGroup.Annotations[util.EnableDequeueAnnoKey]; !exist || val != util.EnableDequeueOnVal {
  +			continue
  +		}
   		if jobInfo.PodGroup.Status.Phase == util.PodGroupInqueue {
   			if _, exist := annoMap[util.EnqueueTimeAnnoKey]; !exist {
   				annoMap[util.EnqueueTimeAnnoKey] = strconv.FormatInt(time.Now().UnixMilli(), util.Base10)
  +				addJobDirtyConditionWhenAnnoChanged(jobInfo, ssn, "PodGroup Inqueue")
   			}
  -func addPodGroupCondition(job *api.JobInfo, sessionID types.UID, reason, message string) {
  -	jc := scheduling.PodGroupCondition{ Type: scheduling.PodGroupUnschedulableType, ...
  +func addPodGroupCondition(job *api.JobInfo, sessionID types.UID, condType scheduling.PodGroupConditionType, reason, message string) {
  +	jc := scheduling.PodGroupCondition{ Type: condType, ...
  ```
  </details>

- **chip 拓扑 State() 快照 + 调度全链路 debug 日志(DT/可观测)**:`ChipNode` 新增 `State()`,按 chip id 升序输出紧凑快照 `id:free`/`id:F`(故障)/`id:n`(网络不健康)/`id:a(owner)`(已分配)。`chipHandler` 的 CheckNodeNPUByTask/ScoreBestNPUNodes/UseAnnotation/ReleaseAnnotation 均补 debug 日志打印 `root.State()`,且 UseAnnotation 的 select 日志从 Info 降到 Debug。

  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/topo/chipnode.go + chip.go</summary>

  ```diff
  +func (n *ChipNode) State() string {
  +	...
  +	case leaf.faulty > 0:        parts = append(parts, fmt.Sprintf("%d:F", id))
  +	case leaf.netUnhealthy > 0:  parts = append(parts, fmt.Sprintf("%d:n", id))
  +	case len(leaf.ownedBy) > 0:  parts = append(parts, fmt.Sprintf("%d:a(%s)", id, leaf.ownedBy[0]))
  +	default:                     parts = append(parts, fmt.Sprintf("%d:free", id))
  +	return strings.Join(parts, " ")
  +}
  ```
  ```diff
  +	klog.V(util.LogDebugLev).Infof("%s CheckNodeNPUByTask task<%s> node<%s> req<%d> mode<%v> chips[%s]",
  +		tp.GetPluginName(), task.Name, node.Name, reqNum, tp.ScheduleMode, root.State())
  -	klog.V(util.LogInfoLev).Infof("%s UseAnnotation task<%s> select %v", ...)
  +	klog.V(util.LogDebugLev).Infof("%s UseAnnotation task<%s> select %v", ...)
  ```
  </details>

- **监控:node_base_info 增 dcmiVersion 标签,driver labeler 改用真实驱动版本**:新增 dcmi_get_driver_version 接口,npu-exporter node_base_info 指标加 dcmiVersion 标签;device-plugin `driverVersionLabeler.Write` 从 `GetDcmiVersion()` 改调 `GetDriverVersion()`(此前把 dcmi 版本误当驱动版本),并把一批 label 日志改用 label 常量(`label.NPUChipNameLabel` 等)。README 补:自定义指标名/label 仅允许字母数字下划线、不得数字开头。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/labelers.go</summary>

  ```diff
   func (l *driverVersionLabeler) Write(labels map[string]string, ctx *label.NodeContext) error {
  -	driverVersion := l.hdm.manager.GetDmgr().GetDcmiVersion()
  +	driverVersion := l.hdm.manager.GetDmgr().GetDriverVersion()
  ```
  </details>

- **syncAnnotation NPU 资源判定收窄**:跨 session 保留注解的判定从模糊的 `strings.Contains(annoKey, util.HwPreName)` 改为 `util.IsNPUResource(v1.ResourceName(annoKey))`,精确识别 NPU 资源注解(配合"支持非 NPU 资源类型 node annotation 更新")。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/node.go</summary>

  ```diff
   	for annoKey, annoValue := range n.Annotation {
  -		if strings.Contains(annoKey, util.HwPreName) {
  +		if util.IsNPUResource(v1.ResourceName(annoKey)) {
   			existAnno[annoKey] = annoValue
  ```
  </details>

### 后续发展方向 [AI]
- 软切隔离在**调度谓词层**做硬拒绝(整卡任务落软切节点报错),说明 VCANN-RT 软切与整卡是节点级互斥,而非卡级混部;后续可关注是否演进成同节点整卡+软切混排。证据只覆盖 predicate 拒绝逻辑,未见软切片分配/回收路径。
- 调度器大量补 `State()` 快照与 debug 日志,是在为拓扑亲和/超节点(PC16 单机场景 commit 12da414d1f)排障铺路;证据只覆盖日志与快照方法,未见 PC16 单机调度的具体算法 hunk。

## npu-operator: 5c41aa83 -> 802e2697
- 比较: https://gitcode.com/openFuyao/npu-operator/compare/5c41aa83e7e810159f5a7be3c5327c3a350a54bd...802e269728d3528e7864b4d8c04a915c12d1169b | tag: v26.6.0 | commits=2 | truncated=false

### AI 总结重点(源码 diff 为据)
- **volcano 调度插件名按节点架构自适应改写**:configMap reconcile hook `transform` 重构 —— 抽出 `updateConfigMapData`(统一 vNPU 模板/node-mode/DRA profile/chip-capabilities 的 ConfigMap 写入)与 `volcanoPluginVersion`(从 image tag 取版本),并新增对 `volcanoSchedulerConfigMapName` 的处理走 `updateVolcanoSchedulerConfigMap`。由测试可断定行为:按节点 `Status.NodeInfo.Architecture`(amd64)把 volcano-scheduler.conf 里的插件名 arch 后缀从 `volcano-npu_v7.3.0_linux-aarch64` 改写为 `_linux-x86_64`,修 x86 控制面上插件名 arch 不匹配导致调度插件加载失败。

  <details><summary>代码依据 internal/controller/resources_basic_hooks.go + resources_test.go</summary>

  ```diff
  -	case draChipCapabilitiesConfigMapName:
  -		if r.instance.Spec.DRA.SoftVNPU.ChipCapabilities != "" { ... obj.Data["capabilities.yaml"] = ... }
  +	case draChipCapabilitiesConfigMapName:
  +		updateConfigMapData(obj, "capabilities.yaml", r.instance.Spec.DRA.SoftVNPU.ChipCapabilities)
  +	case volcanoSchedulerConfigMapName:
  +		if err := updateVolcanoSchedulerConfigMap(ctx, r, obj); err != nil { return err }
  ```
  ```diff
  // resources_test.go: TestConfigMapReconcileHooksUpdatesDefaultVolcanoConfigArch
  +	// node Architecture: "amd64"
  +	assert.Contains(t, configMap.Data["volcano-scheduler.conf"], "volcano-npu_v7.3.0_linux-x86_64")
  +	assert.NotContains(t, configMap.Data["volcano-scheduler.conf"], "volcano-npu_v7.3.0_linux-aarch64")
  ```
  </details>

### 后续发展方向 [AI]
- operator 把节点架构注入 volcano 调度配置,说明其管理面开始按**异构 arch 集群**(x86 控制面 + aarch64/x86 NPU 节点混合)自适应下发调度插件;证据只覆盖 configMap 改写与单测,未见多节点 arch 不一致时的取值优先级。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(仅保锚点)</summary>

- npu-container-toolkit — 无新提交
- npu-driver-installer — 无新提交
- vNPU — 无新提交
- npu-node-provision — 无新提交
- npu-dra-plugin — 无新提交
- volcano-ext — 无新提交
- ub-network-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=7ec21612e08b67dc4478cc1262e7fc49ed48bd42 tag=v26.2.0.beta.1 scanned=2026-09-15 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=vNPU sha=d88907ed4061c5d63babbb79b453a368b55f14d6 tag=v0.1.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-15 -->
</content>
