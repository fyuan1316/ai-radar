# 昇腾算力栈 diff 雷达 2026-07-24

## 摘要
- **mind-cluster** 三条实质改动:①ascend-for-volcano 打通"交换机(switch)+ noded 上报的节点/设备故障"到重调度链路——新增 `FaultDevList` 独立类型、`NodeFaultList`/`SwitchFaultCode/Level` 字段与 `setSwitchAndNodeFaultReason`,让交换机与节点级故障也能作为重调度理由展示/驱动;②infer-operator 修低版本 K8s 兼容——用 discovery 探测 `autoscaling/v2` 是否存在,新增 `SupportHPAScaling` 开关,缺 HPA/v2 的老集群不再 watch/reconcile HPA 而是降级跳过;③ascend-for-volcano **移除** `scoreByChipCount` 按空闲芯片数+驱逐成本的节点打分逻辑。
- **npu-driver-installer** 新增 **25.5.2** 与 **26.0.RC1** 两个驱动版本的下载清单(310p/910b/A3 × aarch64/x86_64),驱动容器化底座向 26.0 RC 线推进。
- **vNPU** 三处修复:修"非 XPU 任务被 XPU 调度插件错误接管"(改判 `ReqXPUNum<=0` 直接跳过并删除 `IsVXPUTask` 字段)、serve goroutine 收到 stop 后不再无谓重启、空模板名选择改为按 key 排序取确定性首个。
- 当日**重要改变**命中 2 条:`[弃用/移除]` ascend-for-volcano 删打分逻辑;`[新能力]` npu-driver-installer 新增两驱动版本(含 26.0.RC1 新 RC 线)。其余 6 个 openFuyao 仓 EMPTY 保锚点。

## 当日重要改变(命中信号才列)
- **mind-cluster** `[弃用/移除]` ascend-for-volcano 从 `BatchNodeOrderFn` 移除 `scoreByChipCount` 节点打分(连带删 `chipCountNodeRank` 结构与 `sort` 导入),对应提交"【fix】【volcano】移除驱逐成本打分逻辑"。 https://gitcode.com/Ascend/mind-cluster/commit/c5ec0ca9f56c625b153ce6c5c2767c831c4e257b
- **npu-driver-installer** `[新能力]` 新增 `downloader/NPU/25.5.2/config.json` 与 `downloader/NPU/26.0.RC1/config.json` 两个驱动版本目录,支持 26.0.RC1 新 RC 驱动线的容器化安装。 https://gitcode.com/openFuyao/npu-driver-installer/commit/bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3

## mind-cluster: d66a9d0f -> c5ec0ca9
- 比较: d66a9d0f6cf3e49a65770a734748cc3dd4dfbcea..c5ec0ca9 | tag: v26.1.0.beta.2 | commits=14 | truncated=false
- 源链接: https://gitcode.com/Ascend/mind-cluster/compare/d66a9d0f6cf3e49a65770a734748cc3dd4dfbcea...c5ec0ca9f56c625b153ce6c5c2767c831c4e257b

### AI 总结重点(源码 diff 为据)
- **ascend-for-volcano 打通交换机/节点级故障到重调度理由链**:新增 `setSwitchAndNodeFaultReason(fNode)` 在 `setTaskCardHealthCode` 里把 `fNode.SwitchFault`(交换机故障码+级别)与 `fNode.NodeFault`(noded 上报的节点故障列表)展开成 `FaultReasonList` 追加进重调度理由。配套:`CommonNode` 新增 `NodeFaultList []k8s.FaultDevList`/`SwitchFaultCode []string`/`SwitchFaultLevel string` 三字段,`syncAnnotation` 在同步 switch info(第 3 步)时落 `SwitchFaultCode/Level`、把 noded 的 `FaultDevList` 拷进 `NodeFaultList`;`setNodeHealthyByNodeD`/`setNodeHealthyBySwitch` 分别把这些填进 `FaultNode.NodeFault`/`SwitchFault`。这落实"volcano添加交换机与nodeD上报故障信息展示"——即多机训练 fabric 的交换机故障、节点级故障现在能作为独立故障理由参与重调度判定。

  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go</summary>

  ```diff
  @@ func (reScheduler ReScheduler) setTaskCardHealthCode(fTask *FaultTask) error {
  +		switchNodeReason := setSwitchAndNodeFaultReason(fNode)
  +		reasonList = append(reasonList, switchNodeReason...)

  +func setSwitchAndNodeFaultReason(fNode *FaultNode) []FaultReasonList {
  +	reasonList := make([]FaultReasonList, 0)
  +	if fNode.SwitchFault.FaultLevel != "" {
  +		var reason FaultReasonList
  +		reason.FaultCode = strings.Join(fNode.SwitchFault.FaultCode, ",")
  +		reason.FaultLevel = fNode.SwitchFault.FaultLevel
  +		reasonList = append(reasonList, reason)
  +	}
  +	for _, nodeFault := range fNode.NodeFault { ... }
  +	return reasonList
  +}
  ```
  </details>

- **`FaultDevList` 提为独立命名类型**:`common/k8s/type.go` 把 `NodeDNodeInfo.FaultDevList` 原来的匿名内联 struct 提取为具名 `FaultDevList{DeviceType/DeviceId/FaultCode/FaultLevel}`,以便 plugin 层跨结构体复用(`CommonNode.NodeFaultList` 直接引用之)。是纯内部类型(非 `*_types.go`/CRD),不算 API 变更,但是上面故障链打通的支撑改动。

  <details><summary>代码依据 component/ascend-for-volcano/common/k8s/type.go</summary>

  ```diff
   type NodeDNodeInfo struct {
  -	FaultDevList []struct {
  -		DeviceType string
  -		DeviceId   int
  -		FaultCode  []string
  -		FaultLevel string
  -	}
  -	NodeStatus string
  +	FaultDevList []FaultDevList
  +	NodeStatus   string
  +}
  +type FaultDevList struct {
  +	DeviceType string
  +	DeviceId   int
  +	FaultCode  []string
  +	FaultLevel string
   }
  ```
  </details>

- **移除按芯片数/驱逐成本的节点打分**:`BatchNodeOrderFn` 删掉 `sHandle.scoreByChipCount(vcJob, task, scoreMap)` 调用,并整段删除 `scoreByChipCount` 函数与 `chipCountNodeRank{name,freeChip,evictCost}` 结构(约 55 行)。原逻辑:按节点空闲芯片数排序、不足时算 `evictCost=taskNPU-free`,再给排名靠前的节点叠加 `totalNodes-rank` 分,倾向"刚好够放/驱逐成本低"的节点。现在这套打分被彻底移除,节点打分回退到剩余权重逻辑。提交标题"移除驱逐成本打分逻辑"。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory.go</summary>

  ```diff
  @@ func (sHandle *ScheduleHandler) BatchNodeOrderFn(task *api.TaskInfo, ...
   	for nodeName := range scoreMap {
   		scoreMap[nodeName] *= scoreWeight
   	}
  -	sHandle.scoreByChipCount(vcJob, task, scoreMap)

  -type chipCountNodeRank struct { name string; freeChip int; evictCost int }
  -func (sHandle *ScheduleHandler) scoreByChipCount(...) { ... 整段删除 ... }
  ```
  </details>

- **infer-operator 修低版本 K8s 兼容(HPA 可选化)**:`InstanceSetReconciler` 新增 `SupportHPAScaling bool`;`NewInstanceSetReconciler` 多收一个 `supportHPAScaling` 入参;`Reconcile` 只在开启时才 `reconcileScalingResources`+更新 scaling 状态;`SetupWithManager` 只在开启时才 `Owns(&autoscalingv2.HorizontalPodAutoscaler{})`。开关由 `main.go` 用新 helper `APIGroupVersionExists(cfg, "autoscaling/v2")`(discovery 探测 GV 是否存在)决定,老集群缺 `autoscaling/v2` 时打 Warn 并降级为 `false`。对应"修复inferoperator不兼容低版本k8s问题"——避免在没有 HPA v2 的集群上 watch 不存在的 GVK 而启动失败。

  <details><summary>代码依据 component/infer-operator/main.go + pkg/common/client-go/crd.go</summary>

  ```diff
  // main.go
  +	supportHPAScaling := false
  +	if err := util.APIGroupVersionExists(ctrl.GetConfigOrDie(), "autoscaling/v2"); err == nil {
  +		supportHPAScaling = true
  +	} else { hwlog.RunLog.Warnf("autoscaling/v2 API not available, HPA scaling will be disabled: %v", err) }
  -	instanceSetReconciler := clusterctrlv1.NewInstanceSetReconciler(mgr, registerWorkLoadHandlersFunc())
  +	instanceSetReconciler := clusterctrlv1.NewInstanceSetReconciler(mgr, supportHPAScaling, registerWorkLoadHandlersFunc())

  // crd.go
  +func APIGroupVersionExists(cfg *rest.Config, groupVersion string) error {
  +	discoveryClient, _ := discovery.NewDiscoveryClientForConfig(cfg)
  +	_, err = discoveryClient.ServerResourcesForGroupVersion(groupVersion)
  +	if err != nil { return fmt.Errorf("API group version %s not found: %v", groupVersion, err) }
  +	return nil }
  ```
  </details>

### 后续发展方向 [AI]
- 故障容错链继续下沉到 **fabric/交换机维度**:此前重调度主要看卡级/软件故障,本次把交换机故障与 noded 节点故障并入重调度理由,呼应 7-23 digest 里 UB/RDMA fabric 的铺垫——多机训练网络故障正被纳入调度容错。证据覆盖 `setSwitchAndNodeFaultReason` 与三处 fault 填充,但未见这些理由如何映射到具体重调度动作(PreSeparate/隔离级别),需看 `FaultReasonList` 下游消费。
- infer-operator 明确面向**老版本 K8s 落地**做能力降级(HPA 可选),说明昇腾推理 operator 在向异构/低版本客户环境适配;证据仅覆盖 autoscaling/v2 一处探测,未见是否还有其他 GVK(如 PodGroup 已有 CRDExists 探测)走同套降级。
- 移除 `scoreByChipCount` 方向存疑:驱逐成本打分被删可能因其与新故障/重调度路径冲突或效果不佳,但 diff 未给替代打分,无法判断是回退还是让位给别处逻辑(证据只覆盖删除,未见新增打分)。

## npu-driver-installer: c898c929 -> bd1b2a9e
- 比较: c898c929187bba8051e2ebed87f609bc820ead68..bd1b2a9e | tag: v26.6.0 | commits=2 | truncated=false
- 源链接: https://gitcode.com/openFuyao/npu-driver-installer/compare/c898c929187bba8051e2ebed87f609bc820ead68...bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3

### AI 总结重点(源码 diff 为据)
- **新增两条驱动版本的容器化下载清单**:`downloader/NPU/25.5.2/config.json` 与 `downloader/NPU/26.0.RC1/config.json` 各 42 行,声明 `310p`/`910b`/`A3` 三机型 × `aarch64`/`x86_64` 的 HDK zip 文件名与华为云 OBS 下载 URL。安装器据此按机型+架构拉取对应驱动包,26.0.RC1 是相对现有版本的新 RC 线。这是驱动容器化底座扩版本支持,非逻辑改动。

  <details><summary>代码依据 downloader/NPU/26.0.RC1/config.json</summary>

  ```diff
  +{
  +  "name": "NPU", "version": "26.0.RC1",
  +  "other": [
  +    { "310p_aarch64": { "filename": "Ascend-hdk-310p-npu_26.0.rc1_linux-aarch64.zip", "url": ".../Ascend-hdk-310p-npu_26.0.rc1_linux-aarch64.zip" } },
  +    { "910b_x86_64":  { "filename": "Ascend-hdk-910b-npu_26.0.rc1_linux-x86-64.zip",  "url": "..." } },
  +    { "A3_aarch64":   { "filename": "Atlas-A3-hdk-npu_26.0.rc1_linux-aarch64.zip",    "url": "..." } }
  +  ]
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 驱动安装器以"版本目录 + config.json 清单"为扩展单元,新增版本 = 加一个目录,便于跟随华为 HDK 发版节奏。证据只覆盖两个 config.json,机型集合固定为 310p/910b/A3(未见 910c/新机型条目),后续新卡型上市可据此目录判断是否已被驱动容器化支持。

## vNPU: 257e1cb6 -> f37099fb
- 比较: 257e1cb64bbc0390cc81f2e82c2654e9199c2ea0..f37099fb | tag: v0.1.0 | commits=6 | truncated=false
- 源链接: https://gitcode.com/openFuyao/vNPU/compare/257e1cb64bbc0390cc81f2e82c2654e9199c2ea0...f37099fbc69589fa5473a7b98d315cc66b30f45e

### AI 总结重点(源码 diff 为据)
- **修"非 XPU 任务被 XPU 调度插件误接管"**:`GetJobXPUTasks` 原逻辑对每个 task 都建 `XPUTask` 并用 `ReqXPUCores != ReqXPUNum*100 || ReqXPUMemPercentage != ReqXPUNum*100` 判 `isVXPUTask`,导致连没申请 XPU 的任务也进 `resultMap`、被 XPU 插件处理;改为 `if tr.ReqXPUNum <= 0 { continue }` 直接跳过非 XPU 任务,并**删除 `IsVXPUTask` 字段**(连带 `util.XPUTask` 结构去掉该字段)。`initJobInfo` 的空判也从 `tasks == nil` 收紧为 `len(tasks) == 0`。对应"修改判断是否是xpu任务逻辑,原逻辑会导致不是xpu的任务也使用xpu调度插件"。

  <details><summary>代码依据 volcano-xpu-plugin/plugin/job.go + util/task.go</summary>

  ```diff
  // job.go GetJobXPUTasks
  -		isVXPUTask := false
  -		if tr.ReqXPUCores != tr.ReqXPUNum*util.Base100 || tr.ReqXPUMemPercentage != tr.ReqXPUNum*util.Base100 {
  -			isVXPUTask = true
  -		}
  +		// task is not xpu task, continue
  +		if tr.ReqXPUNum <= 0 { continue }
   		resultMap[taskID] = &util.XPUTask{ ...
  -			IsVXPUTask:   isVXPUTask,
   		}
  // task.go
   type XPUTask struct { ...
  -	IsVXPUTask bool
   }
  ```
  </details>

- **device-plugin serve goroutine 收到 stop 不再无谓重启**:`DevicePlugin.serve()` 的重启循环里,在每次 `server.Serve(sock)` 前后各加一段 `select { case <-m.stop: return; default: }`,server 正常停止后直接退出 goroutine,避免 crash-restart 逻辑把主动 stop 误当崩溃再拉起。对应"avoid unnecessary restart after server stop in serve goroutine"。

  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/plugin.go</summary>

  ```diff
   	for {
  +		select { case <-m.stop: return; default: }
   		err := m.server.Serve(sock)
   		if err == nil { break }
  +		select {
  +		case <-m.stop:
  +			log.Infof("GRPC server for '%s' stopped", m.resourceName)
  +			return
  +		default: }
   		log.Errorf("GRPC server for '%s' crashed with error: %v", ...)
  ```
  </details>

- **空模板名的模板选择改为确定性**:`getTemplateByName` 当 `templateName==""` 时原来用 `for _, t := range templates { return t }`(map 遍历顺序随机),改为把 key 收集后 `sort.Strings` 再取首个,保证空名场景选到的切分模板稳定可复现。对应"deterministic template selection for empty name"。

  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/config/template.go</summary>

  ```diff
   	if templateName == "" && len(templates) > 0 {
  -		for _, t := range templates { return t }
  +		keys := make([]string, 0, len(templates))
  +		for k := range templates { keys = append(keys, k) }
  +		sort.Strings(keys)
  +		return templates[keys[0]]
   	}
  ```
  </details>

### 后续发展方向 [AI]
- vNPU 本轮全是**健壮性收敛**:调度插件只认真正申请 XPU 的任务(去掉 `IsVXPUTask` 这套按 cores/mem 是否满额反推"是否虚拟"的隐式判断,改用 `ReqXPUNum>0` 显式过滤)、device-plugin 生命周期干净退出、模板选择去随机性。证据覆盖三个修复点,均未涉及切分算法/vCANN 资源计算本身,方向是"把 v0.1.0 的边界 bug 磨平"而非加新切分能力。
- `IsVXPUTask` 字段被删意味着 vNPU 内部不再区分"整卡 XPU vs 虚拟切分 XPU"任务,统一按 XPUTask 处理;后续若要对 vXPU 做差异化调度(如只在虚拟任务上叠加显存约束),需重新引入区分标记,当前 diff 未见替代。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅锚点)</summary>

- npu-operator | 无新提交
- npu-container-toolkit | 无新提交
- npu-node-provision | 无新提交
- npu-dra-plugin | 无新提交
- volcano-ext | 无新提交
- ub-network-device-plugin | 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=c5ec0ca9f56c625b153ce6c5c2767c831c4e257b tag=v26.1.0.beta.2 scanned=2026-07-24 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=vNPU sha=f37099fbc69589fa5473a7b98d315cc66b30f45e tag=v0.1.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-24 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-24 -->
</content>
</invoke>
