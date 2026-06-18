# 昇腾算力栈 diff 雷达 2026-06-19

## 摘要
- **mind-cluster / ascend-for-volcano 本日大改:昇腾 Volcano 插件首次引入抢占(preempt)+ 回收(reclaim)两个 action,并配套"拓扑感知抢占"——按 910A/910B/910A3 各自的 HCCS/Die 约束选受害者(`Preemptable()` per-chip override),同时把所有"资源不足"错误统一打 `NPUResourceShortageError` 标记,predicate 据此区分 `Unschedulable`(可抢占)vs `UnschedulableAndUnresolvable`(抢占也救不了)。**这是昇腾批调度从"只会 gang/binpack 摆放"迈向"高优抢占低优"的关键能力补齐。**
- 同期 ascend-for-volcano 落地 **Atlas 950/850 SuperPod 大 EP 推理亲和调度**(新增 chip8node8sp / chip8node8ra64sp 两套 policy 的 infer_service.go,按 inferServiceID 标签做 same-rack / same-SP 聚合落位),并修了 chip 计数缓存(allocate/deallocate 双向维护 + Pending 回滚清理)。
- 其余:vNPU 仅 README/构建链重构(无 Go 逻辑改动,但 README 把产品定位从"软切分"扩成"软+硬双模式切分 + 多样化 AICore 调度策略",AICore 粒度宣称 5%→1%);npu-dra-plugin、ub-network-device-plugin 仅 CVE 依赖/基础镜像升级。npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / volcano-ext 本期无实质改动。

## 当日重要改变
- **mind-cluster** `[新能力]` ascend-for-volcano 注册 preempt + reclaim action,新增 `addPreemptableFn`/`addReclaimableFn`,`jobOrderFn` 透传 `tp.Scheduler` —— 证据 `component/ascend-for-volcano/npu.go` https://gitcode.com/Ascend/mind-cluster/compare/21a6d2f4...2a06af1c
- **mind-cluster** `[新能力]` 拓扑感知抢占:910A/910B/910A3 各实现 `Preemptable()`,910A3 多芯任务只选完整 Die(freeCount==maxCardNPUNum)、单芯任意 Die,910A 按 HCCS 组选 —— 证据 `internal/npu/ascend910/ascend910a3/base.go`、`ascend910b/base.go`、`ascend910old/module910x8/frame.go`
- **mind-cluster** `[新能力]` SuperPod 大 EP 推理亲和:新增 `internal/npu/policy/chip8node8sp/infer_service.go` 与 `chip8node8ra64sp/infer_service.go`(same-rack/same-SP 聚合)—— 证据见同上 compare
- **mind-cluster** `[行为变更]` predicate 把"资源不足"错误从笼统 error 改为带 `NPUResourceShortageError` 前缀,并据此返回 `Unschedulable`(可被抢占救)或 `UnschedulableAndUnresolvable`(不可救)—— 证据 `component/ascend-for-volcano/npu.go` 的 `convertToNPUFitError`/`isNPUSchedulableByPreemption`

## mind-cluster: 21a6d2f4 -> 2a06af1c
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/21a6d2f4...2a06af1c | tag: v26.0.1 | commits=44 | truncated=false
- 信号文件全部落在 `component/ascend-for-volcano`(调度)与 `component/ascend-device-plugin`/`component/npu-exporter`,本期方向高度集中在**调度器**。

### AI 总结重点(源码 diff 为据)
- **昇腾 Volcano 插件首次接入 preempt / reclaim 两个 action**。`OnSessionOpen` 在原有 predicate/batchNodeOrder/jobReady 之外新增 `addPreemptableFn(ssn, tp)` 与 `addReclaimableFn(ssn, tp)`;`AddJobOrderFn` 的回调签名从 `jobOrderFn(l, r)` 改为 `jobOrderFn(l, r, tp.Scheduler)`(排序需要感知调度器全局态以支持抢占优先级)。
  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
   	ssn.AddJobOrderFn(tp.Name(), func(l interface{}, r interface{}) int {
  -		return jobOrderFn(l, r)
  +		return jobOrderFn(l, r, tp.Scheduler)
   	})
   	addBatchNodeOrderFn(ssn, tp)
  +	addPreemptableFn(ssn, tp)
  +	addReclaimableFn(ssn, tp)
   	ssn.AddJobReadyFn(tp.Name(), func(obj interface{}) bool {
  ```
  </details>
- **predicate 改为"可抢占性分类"**。原 `addPredicateFn` 直接把 `NodePredicate` 的 error 透传返回;现在经 `convertToNPUFitError` 判断:若 `isResourceShortageError`(错误串含 `NPUResourceShortageError`)且节点/作业在缓存中,则返回 `api.Unschedulable`(留给 preempt action 通过抢占低优任务来腾资源);否则返回 `api.UnschedulableAndUnresolvable`(抢占也无解,直接放弃该节点)。这是抢占能生效的前提——Volcano 只对 `Unschedulable` 的 task 触发 preempt。
  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
  +func convertToNPUFitError(...) error {
  +	if isNPUSchedulableByPreemption(tp, taskInfo, nodeInfo, predicateErr) {
  +		return api.NewFitErrWithStatus(taskInfo, nodeInfo, &api.Status{
  +			Code:   api.Unschedulable, Reason: predicateErr.Error()})
  +	}
  +	return api.NewFitErrWithStatus(taskInfo, nodeInfo, &api.Status{
  +		Code:   api.UnschedulableAndUnresolvable, Reason: predicateErr.Error()})
  +}
  +func isNPUSchedulableByPreemption(...) bool {
  +	if !isResourceShortageError(predicateErr) { return false }
  +	...
  ```
  </details>
- **全量"资源不足"错误打统一标记**。910A/910B/910A3/base 各 `SelectNPUFromNode`/`Judge…NodeAndTaskNPU` 的报错从随意文案改为统一前缀 `util.NPUResourceShortageError`,供上面的 `isResourceShortageError` 识别。这是把"不可调度"语义结构化的工程基础。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/base/frame.go</summary>

  ```diff
  -		return fmt.Errorf("node don't have enough npu resource, req<%d>, idle<%d>",
  -			taskNPU, len(nodeNPUTopology))
  +		return fmt.Errorf("%s node don't have enough resource, req<%d>, idle<%d>",
  +			util.NPUResourceShortageError, taskNPU, len(nodeNPUTopology))
  ```
  </details>
- **拓扑感知的 Preemptable():按芯片型号选受害者**。`base.AscendHandler` 新增 `WithMaxCardNum`/`GetMaxCardNPUNum`,各型号实现差异化抢占策略:910A3 多芯任务只能选**完整 Die**(`freeCount == maxCardNPUNum`),单芯任意 freeCount≥1 的 Die;910A(module910x8)按 HCCS 组选 freeCount≥reqNPUNum 的卡。共用 `plugin.CalcCardFreeCount` 算各卡释放后空闲数、`plugin.FilterPreempteesByFeasibleCards` 过滤受害者。即抢占不只看"够不够数",还保证抢完后拓扑(HCCS 亲和/整 Die)依然合法。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/ascend910/ascend910a3/base.go</summary>

  ```diff
  +// Preemptable override: multi-chip tasks must select complete Dies only
  +func (tp *Base910A3) Preemptable(preemptor *api.TaskInfo, preemptees []*api.TaskInfo,
  +	vcNode *plugin.NPUNode) ([]*api.TaskInfo, bool) {
  +	cardFreeCount := plugin.CalcCardFreeCount(vcNode, preemptees, maxCardNPUNum)
  +	// Multi-chip: only select complete Dies (freeCount == maxCardNPUNum)
  +	for id, fc := range cardFreeCount {
  +		if fc == maxCardNPUNum { fullDies = append(fullDies, dieInfo{id, fc}) }
  +	}
  ```
  </details>
- **Atlas 950/850 SuperPod 大 EP 推理亲和调度**。新增 chip8node8sp、chip8node8ra64sp 两套 policy 各自的 `infer_service.go`:用 Pod 上的 `inferServiceIDLabelKey` 标记同一推理服务,`getInferServiceScheduledInfo`/`getInferServiceScheduledSPs` 遍历同 inferServiceID 的其它 job,收集它们已落位的 `SuperPods`,按 RackID/SuperPodID 聚类(同 rack / 同 SP / 其它 SP 三档优先级),让大 EP(专家并行)推理实例尽量落在同 SuperPod / 同机柜以降通信时延。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8ra64sp/infer_service.go</summary>

  ```diff
  +const (
  +	inferServiceGroupSameRack = 1
  +	inferServiceGroupSameSP   = 2
  +	inferServiceGroupOtherSP  = 3
  +)
  +func (tp *chip8node8ra64sp) getInferServiceScheduledInfo() (
  +	map[int32]*inferServiceRackInfo, map[int32]*inferServiceSPInfo) {
  +	for jobID, job := range tp.ScheduleEnv.Jobs {
  +		jobInferID, ok := job.Label[inferServiceIDLabelKey]
  +		if !ok || jobInferID != tp.inferServiceID { continue }
  +		for _, spNodes := range job.SuperPods { ... sameRacks[sn.RackID] = ... }
  ```
  </details>
- **chip 计数缓存双向维护 + Pending 回滚清理**。`NPUAllocateFunc` 分配后调 `updateChipCountAfterAllocate`(把 Pod 写进 `vcNode.Chips[chipID].PodMap`,并把 `vcNode.Idle[npuResName]` 扣减 chip 数×NPUHexKilo,夹到 0);`NPUDeallocateFunc` 调 `updateChipCountAfterDeallocate` 反向回补;`releaseAnnotation` 对 `task.Status == api.Pending`(分配回滚/unpipeline)的情况直接删掉 Pod 上的 NPU 注解并 return,避免污染节点缓存。这是为抢占引入后频繁的"分配-回滚"场景做的缓存一致性加固。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/task.go</summary>

  ```diff
  -		// update node.
  +		npuResName := v1.ResourceName(vcJob.ReqNPUName)
  +		sHandle.updateChipCountAfterAllocate(task, vcNode, npuResName)
   		sHandle.Nodes[nodeName] = *vcNode
  ...
  +	if task.Status == api.Pending {
  +		delete(task.Pod.Annotations, util.AscendNPUPodRealUse)
  +		delete(task.Pod.Annotations, vcTask.ReqNPUName)
  +		delete(task.Pod.Annotations, util.Pod910DeviceKey)
  +		return
  +	}
  ```
  </details>
- **配套修复(commit 标题,无独立大段 hunk 但信号文件命中)**:npu-exporter 修 telegraf 场景指标数为空异常、删 intervalSeconds 配置后默认值异常、缓存有效期问题(`npu-exporter/...` 测试文件命中);device-plugin 软切分配置删除收窄为"仅当节点上所有 pod 都无该任务名才删任务目录"、补 deployment 场景按 pod 取任务名、调整 0x81AF8009 故障等级、卡死故障检测逻辑优化(`ascend-device-plugin/pkg/device/hangdetection/*`、`pkg/server/manager_test.go` 命中);golang 升级至 1.26。

### 后续发展方向 [AI]
- 昇腾批调度的**抢占链路**已成形(predicate 分类 → Unschedulable → preempt action → 拓扑感知选受害者 → chip 计数回滚清理),下一步大概率补 reclaim 在多队列/多租户配额(deserved/guarantee)间的实际回收策略,以及抢占与 gang(JobReady)的协同(避免抢占造成的部分腾出却无法成 gang)。证据只覆盖 npu.go + base.go + task.go 的 diff,未见 queue/proportion 层改动,reclaimable 的具体配额判定逻辑未在本次节选 hunk 中展开。
- SuperPod 大 EP 亲和目前是 chip8node8sp/chip8node8ra64sp 两个特定规格 policy 的硬编码三档(same-rack/same-SP/other-SP),证据未见把它抽象成通用拓扑评分;若 Atlas 950 推理大 EP 成为主场景,预期会沉淀成 base 层可复用的 rack/SP 亲和打分。

## 本期无实质改动(折叠)
<details><summary>仅 docs/构建/CVE 升级或无新提交的 repo</summary>

- **vNPU**: 比较 https://gitcode.com/openFuyao/vNPU/compare/d78592e5...ed90d497 —— 仅 `ci/build.sh` 构建链重构(抽 `init_build_env`/`copy_to_dest`、删 `xpu_pool/xpu_docker_build/*` 旧 Dockerfile、`_common_utils.sh` 移除 CANN 8.5.1/HDK 自动安装段)+ 新增 `docs/user-guide.md` + `README-zh.md` 重写。**无 Go 逻辑改动**,但 README 把定位从"软切分"扩为"软+硬双模式切分",AICore 切分粒度宣称由 5%→1%,新增固定配额/弹性/争抢三种 AICore 调度策略与 DRA 调度链接、性能损耗<5% 等能力声明(仅文档声明,代码未在本次 diff 体现)。
- **npu-dra-plugin**: 比较 https://gitcode.com/openFuyao/npu-dra-plugin/compare/77317874...c6dc2c73 —— 仅升级依赖修 CVE-2025-13281 / CVE-2026-33186(信号文件全在 vendor/go.mod,无业务代码 hunk)。
- **ub-network-device-plugin**: 比较 https://gitcode.com/openFuyao/ub-network-device-plugin/compare/c7e00375...263d6387 —— 仅升级 grpc 修 CVE-2026-33186 + 基础镜像 openeuler 24.03-lts-sp1→sp3。
- **npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / volcano-ext**: 无新提交。

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=2a06af1cd9a7bd4d803fcd1f5b602520ec7985c4 tag=v26.0.1 scanned=2026-06-19 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-19 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-19 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-19 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-19 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-19 -->
<!-- ANCHOR repo=npu-dra-plugin sha=c6dc2c73fd29c1e9b43392cae51b60a6168f521e tag=1.0.1 scanned=2026-06-19 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-19 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-19 -->
</content>
</invoke>
