# 昇腾算力栈 diff 雷达 2026-09-02

## 摘要
- 本期唯一有实质代码的是 `Ascend/mind-cluster`(46 commits),主线一句话:**把 DPU 亚健康/故障正式纳入 NPU 训练作业的调度过滤与断点续训容错闭环**——调度侧新增"RDMA 整卡任务遇 DPU 亚健康节点则拒绝落位",故障侧新增"DPU 故障映射到作业 NPU 设备生成 FaultRank 触发续训",两端由新的 `DpuCm` 配置与 `IsRdmaTask` 收窄(仅整 DPU 卡)串起来。
- 另有三处独立 bug 修复:超节点 `super-pod-size/reserve-nodes` 解析改成返回 error 区分"配置缺失"与"合法 0 值";ascend-operator 用 owner uid 拦截同名 stale service 复用;新增参数面网络 `parameterplane.unhealthy-tolerance` 注解让作业容忍 linkdown。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期全 EMPTY,tag 均停在 v26.6.0 / v0.1.0 未动。

## 当日重要改变
- mind-cluster `[新能力]` DPU 亚健康主动触发断点续训:调度过滤 + 故障排名两条路径落地,证据见 `reschedule.go` / `job_fault_rank_processor.go` / `type.go`。 https://gitcode.com/Ascend/mind-cluster/commits/master
- mind-cluster `[Bug]` 超节点调度:`getSuperPodInfoFromConfig` 由返回裸 int 改成 `(int, error)`,修 "配置缺失被当成合法 0" 的误判。 https://gitcode.com/Ascend/mind-cluster
- mind-cluster `[Bug]` ascend-operator `getOrCreateSvc` 拦截不属于同一 AscendJob 的同名残留 service。 https://gitcode.com/Ascend/mind-cluster

## mind-cluster: 61fdac50 -> 0343f916
- 比较: 61fdac50..0343f916 | tag: v26.2.0.beta.1 | commits=46 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/61fdac5097b681e450353a46e346a01bb15fe5d6...0343f91646e4abdc9672b7ddbf7bf40249762fac

### AI 总结重点(源码 diff 为据)

- **DPU 亚健康作为调度过滤条件**:`ReScheduler.checkNodeCurNodeIsFault` 新增判定——若任务是 RDMA 整卡任务(`util.IsRdmaTask`)、节点有 DPU 亚健康故障(新函数 `hasDpuNodeSubHealthFault` 扫 `FaultDpuList` 里 `SubHealthFault` 级别)、且作业亚健康策略不是 `SubHealthyIgnore`,则该节点直接判不可用返回 error。此前只判 card/switch 亚健康与 DPU 掉卡(separate),DPU 亚健康是新增的第三条 RDMA 落位约束。
  <details><summary>代码依据 internal/rescheduling/reschedule.go + task.go</summary>

  ```diff
  +	if util.IsRdmaTask(task, vcNode.Annotation) && hasDpuNodeSubHealthFault(fNode.FaultDpuList) &&
  +		schedulerJob.SubHealthyStrategy != util.SubHealthyIgnore {
  +		return fmt.Errorf("node has dpu subhealth fault, not suitable for rdma full card task")
  +	}
   	if util.IsRdmaTask(task, vcNode.Annotation) && hasDpuNodeSeparateFault(fNode.DpuNodeEvent) {
  // task.go 新增:
  +func hasDpuNodeSubHealthFault(faultDpuList []k8s.DPUItem) bool {
  +	for _, dpu := range faultDpuList {
  +		for _, fault := range dpu.FaultList {
  +			if fault.FaultLevel == SubHealthFault { return true }
  ```
  </details>

- **`IsRdmaTask` 语义收窄为"申请整 DPU 卡"**:原来只要 ScalarResources 里命中 RDMA 资源名即算 RDMA 任务;现在额外要求资源量换算后等于 `DpuFullCardNum`(`int(v/NPUHexKilo) == DpuFullCardNum`)。即只有独占整张 DPU 卡的任务才会受上面 DPU 故障过滤影响,共享/部分 DPU 不触发。这是把 DPU 容错精确限定到"整卡 RDMA"场景。
  <details><summary>代码依据 common/util/util.go</summary>

  ```diff
  -// IsRdmaTask check whether the task requests rdma resources.
  +// IsRdmaTask check whether the task requests rdma resources and full dpu cards.
  -	for k := range nT.Resreq.ScalarResources {
  -		if rdmaResSet[string(k)] {
  +	for k, v := range nT.Resreq.ScalarResources {
  +		if rdmaResSet[string(k)] && int(v/NPUHexKilo) == DpuFullCardNum {
   			return true
  ```
  </details>

- **DPU 故障映射到作业 NPU 设备生成 FaultRank(clusterd 侧断点续训数据源)**:`jobRankFaultInfoProcessor` 把 `findNodeDeviceAndSwitchFault` 改名 `findNodeDeviceSwitchAndDpuFault` 并新增 `dpuInfos map[string]*DpuInfo` 入参;新增 `getDpuFaultRankAndDevice`——先用 `isJobUseRdmaOnNode` 过滤,再按 `DpuInfoPrefix+nodeName` 取该节点 DPU 信息,遍历 `DPUList` 的 `FaultList`,用 `mapDpuFaultLevel` 换算故障级别,把 `AffectedNPU`(受影响 NPU 索引)映射到作业的 `server.DeviceList` 生成 FaultRank/FaultDevice。这是 clusterd 把 DPU 故障翻译成"哪些 rank 要重调度"的核心。
  <details><summary>代码依据 clusterd/.../faultrank/job_fault_rank_processor.go</summary>

  ```diff
  -		faultList, nodeStatusList, faultDeviceList := processor.findNodeDeviceAndSwitchFault(serverList,
  -			allConfigmap.NodeCm, allConfigmap.SwitchCm, allConfigmap.DeviceCm, jobId)
  +		faultList, nodeStatusList, faultDeviceList := processor.findNodeDeviceSwitchAndDpuFault(serverList,
  +			allConfigmap.NodeCm, allConfigmap.SwitchCm, allConfigmap.DeviceCm, allConfigmap.DpuCm, jobId)
  +func getDpuFaultRankAndDevice(...) {
  +	if !isJobUseRdmaOnNode(nodeName, node, info) { return ... }
  +	dpuInfo, ok := dpuInfos[constant.DpuInfoPrefix+nodeName]
  +	for _, dpuItem := range dpuInfo.DPUInfo.DPUList {
  +		for _, fault := range dpuItem.FaultList {
  +			mappedLevel := mapDpuFaultLevel(fault.FaultLevel)
  +			for _, affectedNpuIdx := range dpuItem.AffectedNPU {
  +				for _, device := range server.DeviceList { ... }
  ```
  </details>

- **配套数据结构:`DpuCm` 与 `ResourceRequests`**:`AllConfigmapContent` 新增 `DpuCm map[string]*DpuInfo`(DPU 故障信息从 configmap 进入故障处理链);`SimplePodInfo` 新增 `ResourceRequests map[string]int64`,`GetSimplePodByJobId` 现在遍历每个容器把 requests 按资源名累加填入——这是 `isJobUseRdmaOnNode` 判定作业是否在该节点申请了 RDMA/DPU 的依据。
  <details><summary>代码依据 clusterd/pkg/common/constant/type.go + pkg/domain/pod/pod_storage.go</summary>

  ```diff
   type AllConfigmapContent struct {
  +	DpuCm    map[string]*DpuInfo
   type SimplePodInfo struct {
  -	PodUid   string; PodRank  string; NodeName string
  +	PodUid string; PodRank string; NodeName string; ResourceRequests map[string]int64
  // pod_storage.go:
  +		for _, container := range pod.Spec.Containers {
  +			for resName, quantity := range container.Resources.Requests {
  +				reqTotal[string(resName)] += quantity.Value()
  ```
  </details>

- **参数面网络容忍 linkdown(新注解)**:`SchedulerJob.initNPUJob` 新增 `setParameterPlaneUnhealthyTolerance()`,读注解 `huawei.com/parameterplane.unhealthy-tolerance`,值为 `"true"` 时把 `NPUJob.ParameterPlaneUnhealthyTolerance` 置真;仅对 `Ascend910`/`npu` 资源类型生效。对应提交 "参数面网络忽略 linkdown 故障"——让训练作业显式声明可容忍参数面网络亚健康,不因 linkdown 被误判故障重调度。
  <details><summary>代码依据 plugin/job.go + common/util/constants.go</summary>

  ```diff
  +	sJob.setParameterPlaneUnhealthyTolerance()
  +func (sJob *SchedulerJob) setParameterPlaneUnhealthyTolerance() {
  +	if sJob.NPUJob.ReqNPUName != util.NPU910CardName && sJob.NPUJob.ReqNPUName != util.NPUCardName { return }
  +	if val, ok := sJob.Annotation[util.ParameterPlaneUnhealthyToleranceAnnoKey]; ok && val == "true" {
  +		sJob.NPUJob.ParameterPlaneUnhealthyTolerance = true
  +// constants.go:
  +	ParameterPlaneUnhealthyToleranceAnnoKey = "huawei.com/parameterplane.unhealthy-tolerance"
  ```
  </details>

- **超节点调度 bug:配置解析区分 error 与 0**:`getSuperPodInfoFromConfig` 从返回 `int` 改为 `(int, error)`,所有失败分支(map 为空 / key 不存在 / 非数字 / 负数)现在返回具体 error 而非静默返 0。`getSizeOfSuperPod` 改用 `err != nil || superPodSize == 0` 判定;`getReserveNodes` 关键修复——当配置合法为 0 时直接 `return 0`(而非套用 `defaultReserveNodes`),即 "reserve-nodes=0" 现在是有效值,不再被默认值覆盖。
  <details><summary>代码依据 plugin/factory.go</summary>

  ```diff
  -func getSuperPodInfoFromConfig(key string, configurations map[string]string) int {
  +func getSuperPodInfoFromConfig(key string, configurations map[string]string) (int, error) {
  -		return 0            // key 不存在等分支
  +		return 0, fmt.Errorf("%s configuration not exist", key)
  // getReserveNodes:
  +	if reserve == 0 {
  +		return 0
  +	}
  ```
  </details>

- **ascend-operator 拦截同名 stale service 复用**:`getOrCreateSvc` 拿到同名 service 后先过 `isSvcOwnedByJob`(`metav1.IsControlledBy(svc, job)` 比 owner uid),若不属于当前 AscendJob 则报错等其被删后重建,避免删除后重建的同名 job 复用旧 job 遗留的 service。
  <details><summary>代码依据 ascend-operator/pkg/controllers/v1/jobinfo.go + service.go</summary>

  ```diff
  +		if !isSvcOwnedByJob(svc, job) {
  +			return nil, fmt.Errorf("service %s/%s is not owned by job<%s/%s>", ...)
  +		}
  +func isSvcOwnedByJob(svc *corev1.Service, job *mindxdlv1.AscendJob) bool {
  +	return metav1.IsControlledBy(svc, job)
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾故障容错的"第三平面"正在成形:此前重调度域是 NPU 卡故障 + switch(HCCS/参数面交换机)故障,本期把 **DPU(数据面/RDMA 网卡)** 补成对等的一等故障源——从 configmap(`DpuCm`)采集 → clusterd 映射到 rank(`getDpuFaultRankAndDevice`)→ 调度过滤(`reschedule.go`)→ 断点续训,链路已闭合。证据只覆盖到"整卡 RDMA 任务"路径(`IsRdmaTask` 收窄到 `DpuFullCardNum`),共享 DPU / 部分卡场景的容错本期未见代码。
- 容错策略从"硬故障即重调度"往"分级 + 可声明容忍"演进:DPU 亚健康受 `SubHealthyStrategy`(非 Ignore 才拦)约束,参数面网络新增作业级 `parameterplane.unhealthy-tolerance` 注解退出重调度。方向是把亚健康的处置权交给作业/策略而非一刀切。证据仅到注解读取与调度过滤,注解如何贯穿到 clusterd 续训决策未在本区间 diff 中出现。
- 提交里另有 `feat(coordinator): container-manager 添加分布式协调器,支持跨节点 NPU 自愈 part1/part2`、`dra 补充 ckpt 相关代码`、`fix(cdi/mount) handle hostRoot prefix in glob/symlink`,但对应文件不在本 task 限定的 component 前缀内(coordinator/container-manager、dra、cdi 挂载),**未读到 hunk,不做符号级判断**;若后续要跟"跨节点 NPU 自愈协调器"这条线,需把 container-manager / dra 组件目录纳入 PATHPREFIX。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY(仅保锚点)</summary>

- npu-operator(无新提交,tag v26.6.0)
- npu-container-toolkit(无新提交,tag v26.6.0)
- npu-driver-installer(无新提交,tag v26.6.0)
- vNPU(无新提交,tag v0.1.0)
- npu-node-provision(无新提交,tag v26.6.0)
- npu-dra-plugin(无新提交,tag v26.6.0)
- volcano-ext(无新提交,tag v1.9.0)
- ub-network-device-plugin(无新提交,tag 1.0.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=0343f91646e4abdc9672b7ddbf7bf40249762fac tag=v26.2.0.beta.1 scanned=2026-09-02 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=npu-dra-plugin sha=1084df7c16dbb60173b0dbc8e4cd561dd45b430d tag=v26.6.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=475aefcdd1c522d10ca4b9cfdb0acc1c07606171 tag=1.0.2 scanned=2026-09-02 -->
</content>
</invoke>
