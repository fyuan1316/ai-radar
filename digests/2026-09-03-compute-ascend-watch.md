# 昇腾算力栈 diff 雷达 2026-09-03

## 摘要
- 本期唯一有实质代码的是 `Ascend/mind-cluster`(20 commits),主线两条:①**AscendJob 引入 `TTLSecondsAfterFinished` 自动清理**——operator 侧新增周期扫描器 + 完成时按 TTL requeue,对齐 K8s Job 的 ttl-after-finished 语义;②**新增 Atlas 950-SuperPod-Flex(`chip8-node16-sp`,16 NPU/节点)超节点调度支持**,把原来写死"每节点 8 卡"的 chip8node8sp 插件泛化成"环大小固定 8、每节点卡数按策略取(8 或 16)"。
- 另有三处功能/修复:device-plugin 新增 `topologyAnnotator` 在启动时把静态表查到的 NPU 拓扑写进 `npu.topology` 注解喂给拓扑调度插件;infer-operator 修复 HPA external 指标注入把用户自带 selector 覆盖导致 prometheus-adapter 拉不到指标;ascend-docker-runtime 安装时 `--injection-mode` 缺省落 `legacy` 到 install.info。
- 8 个 openFuyao 仓中 7 个全 EMPTY(tag 停 v26.6.0 / v0.1.0 / v1.9.0),`ub-network-device-plugin` 仅一条给 shell 脚本加可执行权限(0 行代码改动)视同无实质变更。

## 当日重要改变
- mind-cluster `[新能力]` AscendJob 支持 `TTLSecondsAfterFinished` 自动清理:新增周期扫描器 `StartTTLCleanupScanner` + `checkTTLAndCleanup`,`--jobScanInterval` 默认 300s。证据 `ascendjob_controller.go`/`job.go`。 https://gitcode.com/Ascend/mind-cluster/compare/0343f91646e4abdc9672b7ddbf7bf40249762fac...e70e6d37f5cf7bbbd0625a9bdea4d033c1152377
- mind-cluster `[新能力/架构方向]` 新增 Atlas 950-SuperPod-Flex 16 卡/节点超节点调度策略 `chip8-node16-sp`,chip8node8sp 插件由"节点 8 卡写死"泛化为按策略取节点卡数。证据 `frame.go`/`type.go`/`constants.go`/`factory.go`。 https://gitcode.com/Ascend/mind-cluster
- mind-cluster `[新能力]` device-plugin 上报节点 NPU 拓扑:新增 `topologyAnnotator` 写 `npu.topology` 注解。证据 `labelers.go`/`manager.go`。 https://gitcode.com/Ascend/mind-cluster
- mind-cluster `[Bug]` infer-operator 修 HPA external 指标 selector 被自动标签覆盖致 "unable to fetch metrics from external metrics API"。证据 `scaling_manager.go`。 https://gitcode.com/Ascend/mind-cluster

## mind-cluster: 0343f916 -> e70e6d37
- 比较: 0343f916..e70e6d37 | tag: v26.2.0.beta.1 | commits=20 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/0343f91646e4abdc9672b7ddbf7bf40249762fac...e70e6d37f5cf7bbbd0625a9bdea4d033c1152377

### AI 总结重点(源码 diff 为据)

- **AscendJob 完成后 TTL 自动清理(对齐 K8s ttl-after-finished)**:`ASJobReconciler` 新增字段 `jobScanInterval int` 与 `ttlRequeues sync.Map`;`handleFinishedJob` 里原来无条件 `CleanupJob` 改为 `checkTTLAndCleanup(ji)`——读 `runPolicy.TTLSecondsAfterFinished`,`ttlExpireTime` 由 `status.CompletionTime + TTL` 算到期时刻:未到期就把剩余时长存进 `ttlRequeues` 并让 `Reconcile` 结尾 `LoadAndDelete` 出来做 `RequeueAfter`;已到期才 `r.Delete(obj)`。另加兜底 `StartTTLCleanupScanner`→`scanExpiredTTLJobs` 周期性 List 所有已完成 job 扫过期。扫描间隔由新 flag `--jobScanInterval`(默认 `DefaultAcjobScanInterval=300`,上限 `MaxAcjobScanInterval=86400`)经 `getJobScanInterval` 钳位。
  <details><summary>代码依据 ascend-operator/pkg/controllers/v1/{ascendjob_controller,job,utils,consts}.go + main.go</summary>

  ```diff
  // ascendjob_controller.go —— 字段 + 周期扫描器 + Reconcile 尾部 requeue
  +	jobScanInterval int
  +	ttlRequeues sync.Map
  +	if value, ok := r.ttlRequeues.LoadAndDelete(req.NamespacedName.String()); ok {
  +		return ctrl.Result{RequeueAfter: value.(time.Duration)}, nil
  +func (r *ASJobReconciler) scanExpiredTTLJobs(ctx context.Context) {
  +		if !util.IsSucceeded(job.Status) && !util.IsFailed(job.Status) { continue }
  // job.go —— 完成时按 TTL 分支
  -	if err := r.CleanupJob(ji.runPolicy, *ji.status, ji.job); err != nil {
  +	if err := r.checkTTLAndCleanup(ji); err != nil {
  +func (r *ASJobReconciler) checkTTLAndCleanup(ji *jobInfo) error {
  +	if time.Now().Before(expireTime) { r.ttlRequeues.Store(ji.jobKey, time.Until(expireTime)); return nil }
  +	if err := r.Delete(context.Background(), obj); err != nil { return err }
  // consts.go
  +	DefaultAcjobScanInterval = 300
  +	MaxAcjobScanInterval = 86400
  // main.go
  +	flag.IntVar(&jobScanInterval, "jobScanInterval", v1.DefaultAcjobScanInterval, ...)
  -	v1.NewReconciler(mgr, enableGangScheduling)...
  +	v1.NewReconciler(mgr, enableGangScheduling, jobScanInterval)...
  ```
  </details>

- **新增 Atlas 950-SuperPod-Flex 超节点调度(16 卡/节点)**:volcano 插件 `chip8node8sp` 从"每节点固定 8 卡"泛化。`New()` 里 `SetMaxNodeNPUNum` 原来传常量 `nodeNPUNumber(=8)`,改为 `getNodeNPUNumByHandler(name)`——`8p-8-sp` 返 8、`8p-16-sp` 返 16;同时 `SetMaxCardNPUNum(cardsNumPerRing=8)` 明确"环大小固定 8"。`checkSpBlock` 里所有 `nodeNPUNumber` 常量引用换成实例字段 `tp.MaxNodeNPUNum`,使 sp-block 校验按每节点卡数动态算。新增策略常量 `SchedulePolicy8Px16Sp="8p-16-sp"`、`maxNodeNPUNumX16=16`,删除写死的 `nodeNPUNumber=8`。
  <details><summary>代码依据 ascend-for-volcano/internal/npu/policy/chip8node8sp/{frame,type}.go</summary>

  ```diff
  // frame.go
  -	m.SetMaxNodeNPUNum(nodeNPUNumber)
  +	m.SetMaxNodeNPUNum(getNodeNPUNumByHandler(name))
  +	m.SetMaxCardNPUNum(cardsNumPerRing)
  +func getNodeNPUNumByHandler(name string) int {
  +	case SchedulePolicy8Px16Sp: return maxNodeNPUNumX16
  +	case SchedulePolicy8Px8Sp:  return maxNodeNPUNumX8
  -	if tp.SpBlockNPUNum%nodeNPUNumber != 0 {
  +	if tp.SpBlockNPUNum%tp.MaxNodeNPUNum != 0 {
  // type.go
  -	nodeNPUNumber       = 8
  +	SchedulePolicy8Px16Sp = "8p-16-sp"
  +	cardsNumPerRing = 8
  +	maxNodeNPUNumX16 = 16
  ```
  </details>

- **配套:950-Flex 策略在 util 常量 / IsSuperPodJob / factory 注册全链打通**:`util.Chip8Node16Sp="chip8-node16-sp" // 950-SuperPod-Flex, 16 npu per node` 加入策略常量表;`IsSuperPodJob()` 的注解白名单加上 `Chip8Node16Sp`(否则该策略作业不被认成超节点作业);`factory.go` 的 `policy910HandlerMap` 与 `initCard910Factory` 两处注册把外部策略名 `chip8-node16-sp` 映射到插件 handler `8p-16-sp` 并注册构造函数。即"用户注解 → 是否超节点判定 → 插件工厂"三段都补了 16 卡分支。
  <details><summary>代码依据 ascend-for-volcano/common/util/{constants,job}.go + internal/npu/factory.go</summary>

  ```diff
  // constants.go
  +	Chip8Node16Sp      = "chip8-node16-sp"     // 950-SuperPod-Flex, 16 npu per node
  // job.go IsSuperPodJob
  -		return policy == Chip2Node16Sp || policy == Chip2Node8Sp || policy == Chip8Node8Sp || policy == Chip8Node8Ra64Sp
  +		return policy == Chip2Node16Sp || policy == Chip2Node8Sp ||
  +			policy == Chip8Node8Sp || policy == Chip8Node16Sp || policy == Chip8Node8Ra64Sp
  // factory.go
  +	util.Chip8Node16Sp:       chip8node8sp.SchedulePolicy8Px16Sp,
  +	card910Factory[chip8node8sp.SchedulePolicy8Px16Sp] = func() base.AscendHandler { return chip8node8sp.New(chip8node8sp.SchedulePolicy8Px16Sp) }
  ```
  </details>

- **device-plugin 启动时上报节点 NPU 拓扑注解**:新增 `topologyAnnotator`,注册进 `initMarkerGroups` 的 annotationGroup(启动时写一次,周期更新循环不碰)。`Write` 调 `GetDmgr().GetNodeTopo()`(A2/910B 读 boardId 表、其他型号读 mainBoardId 表,两 ID 命名空间不混),把结果写进 `annotation.NPUTopologyAnnotation`(`npu.topology`),供拓扑调度插件消费;异构节点、已有该注解、或查表 miss 三种情况跳过。
  <details><summary>代码依据 ascend-device-plugin/pkg/server/{labelers,manager}.go</summary>

  ```diff
  // manager.go initMarkerGroups
  +		&topologyAnnotator{hdm: hdm},
  // labelers.go
  +type topologyAnnotator struct { hdm *HwDevManager }
  +func (a *topologyAnnotator) Write(annotations map[string]string, ctx *label.NodeContext) error {
  +	if ctx.IsHeterogeneous { return nil }
  +	if topo, exist := ctx.Node.Annotations[annotation.NPUTopologyAnnotation]; exist { return nil }
  +	topo := a.hdm.manager.GetDmgr().GetNodeTopo()
  +	if topo == "" { return nil }
  +	writeValue(annotations, topo, annotation.NPUTopologyAnnotation)
  ```
  </details>

- **infer-operator 修 HPA external 指标标签注入覆盖用户 selector**:`injectMetricSelectorLabels` 遍历 external 指标时,新增"若该指标的 `Selector.MatchLabels` 已非空则 `continue`",即用户在 HPA 里自带 matchLabels 就不再往里塞自动标签。对应提交"修复通过 prometheus adapter 提供推理实例负载指标提示 unable to fetch metrics from external metrics API"——原逻辑无条件注入自动标签,把用户的 external metric selector 污染成 adapter 查不到的组合。
  <details><summary>代码依据 infer-operator/pkg/controller/scaling/scaling_manager.go</summary>

  ```diff
   		if external.Metric.Selector.MatchLabels == nil {
   			external.Metric.Selector.MatchLabels = make(map[string]string)
   		}
  +		if len(external.Metric.Selector.MatchLabels) > 0 {
  +			continue
  +		}
  ```
  </details>

- **ascend-docker-runtime 安装缺省 injection-mode=legacy**:`run_main.sh` 的 `save_install_args` 在写 install.info 前,若 `INJECTION_MODE` 为空则置 `legacy`,避免 `--injection-mode` 未显式指定时 install.info 记成空值。
  <details><summary>代码依据 ascend-docker-runtime/build/scripts/run_main.sh</summary>

  ```diff
   function save_install_args() {
  +    if [[ -z "${INJECTION_MODE}" ]]; then
  +        INJECTION_MODE=legacy
  +    fi
       { echo -e "version=v${PACKAGE_VERSION}" ...
  ```
  </details>

### 后续发展方向 [AI]
- 超节点(SuperPod)形态在往"节点密度可变"扩:上期是 950-SuperPod-Flex 相关的 DPU/RDMA 容错,本期补齐 **16 卡/节点** 的调度形态(`chip8-node16-sp`),且把 chip8node8sp 插件里写死的"环=节点=8"解耦成"环固定 8、节点卡数按策略"。方向是同一超节点插件族支撑多种节点卡密度(8/16),证据覆盖到策略常量→IsSuperPodJob→factory 全链,但 16 卡节点的实际拓扑/亲和打分逻辑(`checkSpBlock` 之外)本区间未展开读到。
- operator 侧在补齐与原生 K8s Job 对齐的生命周期语义:本期 `TTLSecondsAfterFinished` 让 AscendJob 完成后能像原生 Job 一样按 TTL 自动回收,既走完成时 requeue 又有周期扫描兜底。证据只到 operator 的删除路径,未见对应 CRD 字段是否新增(RunPolicy.TTLSecondsAfterFinished 复用了 kubeflow common 的既有字段,非本仓 `*_types.go` 改动)。
- 提交列表另含 `test(coordinator)`/`docs(container-manager) 分布式协调功能文档`(跨节点 NPU 自愈协调器的测试与文档),但代码文件不在本 task 限定的 component 前缀内,未读到 hunk 不做符号级判断;若要跟"跨节点 NPU 自愈协调器"这条线,需把 coordinator/container-manager 目录纳入 PATHPREFIX(上期已提示,本期仍在积累)。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY / 仅琐碎(仅保锚点)</summary>

- npu-operator(无新提交,tag v26.6.0)
- npu-container-toolkit(无新提交,tag v26.6.0)
- npu-driver-installer(无新提交,tag v26.6.0)
- vNPU(无新提交,tag v0.1.0)
- npu-node-provision(无新提交,tag v26.6.0)
- npu-dra-plugin(无新提交,tag v26.6.0)
- volcano-ext(无新提交,tag v1.9.0)
- ub-network-device-plugin(仅 "Add executable permission to shell scripts",0 行代码改动,视同无实质变更,tag 1.0.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=e70e6d37f5cf7bbbd0625a9bdea4d033c1152377 tag=v26.2.0.beta.1 scanned=2026-09-03 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=npu-dra-plugin sha=1084df7c16dbb60173b0dbc8e4cd561dd45b430d tag=v26.6.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-09-03 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=ef44c337d16e208fc1557b8e56a77447f30bc2a7 tag=1.0.2 scanned=2026-09-03 -->
