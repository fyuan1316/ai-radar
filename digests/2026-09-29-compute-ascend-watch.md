# 昇腾算力栈 diff 雷达 2026-09-29

## 摘要
- **mind-cluster / ascend-for-volcano 落地"调度超时降级"新能力**:作业在严格拓扑约束下等待超时后,按等待窗口逐级放宽约束回退,避免长期 pending。annotation 开关 `huawei.com/scheduler.downgrade`,默认关。首个落地策略是 A3 超节点(Atlas 900 A3 SuperPod)的 sp-block 减半阶梯。
- 状态管理拆成两个 process-wide 缓存(纯计时的等待时钟 + 降级快照),且降级结果写进 pod annotation 可持久化、重启可恢复——从内存态升级为可观测/可恢复的契约。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期均无新提交。

## 当日重要改变
- mind-cluster [新能力] ascend-for-volcano 新增"调度超时降级"框架:新增 `common/downgrade`、`common/cache/schedule_timeout`、`internal/npu/base/downgrade.go` 三个包 + A3 SuperPod 策略。证据见下。https://gitcode.com/Ascend/mind-cluster/compare/ec7c16088795169038f600732259c57524d672c3...145617f3510414bdd72091132d6d713ce1782bac
- mind-cluster [API/契约变更] 新增 3 个作业级 annotation 契约:开关 `huawei.com/scheduler.downgrade`、生效时间戳 `huawei.com/scheduler.downgrade.timestamp`、生效约束快照 `huawei.com/scheduler.downgrade.effected-config`(后两者为可观测 pod 标记)。
- mind-cluster [bugfix] noded 修复节点宕机重启后自定义故障等级配置丢失(commit 标题;信号文件命中 `component/noded/pkg/monitoring/config/configurator.go`,patch 节选未覆盖,未逐行读)。

## mind-cluster: ec7c1608 -> 145617f3
- 比较: ec7c1608..145617f3 | tag: v26.1.1 | commits=42 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/ec7c16088795169038f600732259c57524d672c3...145617f3510414bdd72091132d6d713ce1782bac

### AI 总结重点(源码 diff 为据)

- **新增"调度超时降级"总入口 `DowngradeConstraintIfTimeout`,annotation 门控、默认关**。`IsDowngradeEnabled` 读作业 annotation `huawei.com/scheduler.downgrade == "true"`;入口先 `restoreDowngradedConstraint`(把已沉降的约束重新套到本轮仍在等待的任务上,保证同一约束下 rank 计算一致),再 `downgradeConstraintOnTimeout`(按本 session 等到的窗口数一次性沉降到对应等级)。策略通过 `nextConfig`(窗口数→约束)/`applyConfig`(应用并回报是否生效)两个回调可插拔。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/base/downgrade.go</summary>

  ```diff
  +// IsDowngradeEnabled reports the huawei.com/scheduler.downgrade annotation,
  +// the feature is off by default.
  +func (tp *NPUHandler) IsDowngradeEnabled() bool {
  +	if tp == nil { return false }
  +	return tp.Annotation[util.SchedulerDowngradeAnnoKey] == "true"
  +}
  +
  +func (tp *NPUHandler) DowngradeConstraintIfTimeout(jobID api.JobID,
  +	nextConfig func(windows int) (string, int, bool), applyConfig func(config string) bool) {
  +	if tp == nil || jobID == "" || nextConfig == nil || applyConfig == nil || !tp.IsDowngradeEnabled() {
  +		return
  +	}
  +	tp.restoreDowngradedConstraint(jobID, applyConfig)
  +	tp.downgradeConstraintOnTimeout(jobID, nextConfig, applyConfig)
  +}
  ```
  </details>

- **A3 超节点(Atlas 900 A3 SuperPod)是首个落地 policy:约束单位是 sp-block(每 sp-block 的 NPU 数),超时后按等待窗口数把 sp-block 规模每窗口减半(`DefaultDowngradedFactor=2`),不满整节点的等级直接落到单节点底线(`MaxNodeNPUNum`)**。用位移 `configuredNPUNum >> windows` 一次性沉降,而非逐级走阶梯;等于/超过原配置则返回"无更低等级"。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/ascend910/ascend910a3/superpod/downgrade.go</summary>

  ```diff
  +func (tp *module910SuperPod) DowngradeConstraint(jobID api.JobID) {
  +	if tp == nil { return }
  +	tp.DowngradeConstraintIfTimeout(jobID, tp.spBlockOfWaitedWindows, tp.applySpBlockConfig)
  +}
  +
  +func (tp *module910SuperPod) spBlockOfWaitedWindows(windows int) (string, int, bool) {
  +	if tp.configuredSpBlock <= 0 || tp.MaxNodeNPUNum <= 0 || windows <= 0 { return "", 0, false }
  +	if bottomLevel := tp.spBlockBottomLevel(); windows > bottomLevel { windows = bottomLevel }
  +	configuredNPUNum := tp.configuredSpBlock * tp.MaxNodeNPUNum
  +	npuNum := configuredNPUNum >> uint(windows)
  +	if npuNum < tp.MaxNodeNPUNum || npuNum%tp.MaxNodeNPUNum != 0 { npuNum = tp.MaxNodeNPUNum }
  +	if npuNum >= configuredNPUNum { return "", 0, false }
  +	data, err := json.Marshal(spBlockConfig{SpBlock: npuNum})
  +	...
  +}
  ```
  </details>

- **跨 session 状态拆成两个 process-wide 缓存,时间与降级解耦**。`common/cache/schedule_timeout.go` 纯计时:每 job 一个等待时钟,`RecordWaitStart` 首记为准(job 级重调度也不重置),`WaitStartTime` 读取。`common/downgrade/downgrade.go` 只存已沉降的约束快照 + 生效时间(`RecordDowngrade`/`downgradeState{config,effectTime,effective}`),自身不持有时钟,等级由消费方从等待时钟推导。二者都用 mutex 保护(volcano 会并行跑节点谓词)。
  <details><summary>代码依据 component/ascend-for-volcano/common/cache/schedule_timeout.go</summary>

  ```diff
  +func RecordWaitStart(jobID api.JobID) {
  +	if jobID == "" { return }
  +	timeoutCache.mu.Lock(); defer timeoutCache.mu.Unlock()
  +	if _, ok := timeoutCache.waitStart[jobID]; ok { return }  // 首记为准
  +	timeoutCache.waitStart[jobID] = timeoutCache.nowFunc().Unix()
  +}
  ```
  </details>

- **降级结果落 pod annotation → 可持久化、进程重启后可恢复种子**。`readDowngradeSeed` 从已放置(bound/running/succeeded)的 NPU 任务 pod 上读 `scheduler.downgrade.timestamp` + `scheduler.downgrade.effected-config`,newest effect time wins、config 字符串小者破平局(与 task map 遍历顺序无关),把内存态降级恢复为持久态。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go</summary>

  ```diff
  +func readDowngradeSeed(vcJob *api.JobInfo) (string, int64) {
  +	config, effectTime := "", int64(0)
  +	for _, task := range vcJob.Tasks {
  +		if !util.IsNPUTask(task) || isTerminatingTask(task) || !isPlacedTask(task) { continue }
  +		rawTime, hasTime := task.Pod.Annotations[util.SchedulerDowngradedAnnoKey]
  +		markerConfig, hasConfig := task.Pod.Annotations[util.SchedulerDowngradedLevelAnnoKey]
  +		...
  +		if markerTime < effectTime || (markerTime == effectTime && markerConfig > config) { continue }
  +		config, effectTime = markerConfig, markerTime
  +	}
  +	return config, effectTime
  +}
  ```
  </details>

- **会话级一次性 reconcile 接入调度主循环**。`InitNPUSession` 新增 `reconcileTimingState(ssn.Jobs)`:先 `collectRoundInfo` 冻结一轮 job 状态(`roundTaskCount{scoped,pending,scheduled}`、`allWaiting`、`downgrade` 开关),再 `reconcileDowngrade` 先于 `reconcileWaitClock`(降级的 seed gate 必须只看历史 session 带来的等待时钟,否则本轮新起的时钟会掩盖进程重启)。新增动态参数 `SchedulerDowngradeTimeout`(`getSchedulerDowngradeTimeout`)。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory.go</summary>

  ```diff
  @@ func (sHandle *ScheduleHandler) InitNPUSession(ssn *framework.Session) error {
   	sHandle.initCache()
   	sHandle.initAffinityCache()
  +	sHandle.reconcileTimingState(ssn.Jobs)
   	sHandle.startFaultHandler(ssn)
  @@ func (sHandle *ScheduleHandler) initDynamicParameters(...) {
  +	sHandle.FrameAttr.SchedulerDowngradeTimeout = getSchedulerDowngradeTimeout(configs)
  +func (sHandle *ScheduleHandler) reconcileTimingState(ssnJobs map[api.JobID]*api.JobInfo) {
  +	rounds := sHandle.collectRoundInfo(ssnJobs)
  +	sHandle.reconcileDowngrade(rounds)   // 先降级
  +	sHandle.reconcileWaitClock(rounds)   // 再等待时钟
  +}
  ```
  </details>

- **新增作业级 annotation/常量契约**(constants.go):开关 `huawei.com/scheduler.downgrade`、生效时间戳 `huawei.com/scheduler.downgrade.timestamp`、生效约束快照 `huawei.com/scheduler.downgrade.effected-config`、降级因子 `DefaultDowngradedFactor=2`。
  <details><summary>代码依据 component/ascend-for-volcano/common/util/constants.go</summary>

  ```diff
  +// constants for schedule downgrade
  +const (
  +	SchedulerDowngradeAnnoKey       = "huawei.com/scheduler.downgrade"
  +	SchedulerDowngradedAnnoKey      = "huawei.com/scheduler.downgrade.timestamp"
  +	SchedulerDowngradedLevelAnnoKey = "huawei.com/scheduler.downgrade.effected-config"
  +	DefaultDowngradedFactor         = 2
  +)
  ```
  </details>

- npu-exporter README 大改(196 行):重写为标准组件文档(简介/软件架构/上下游依赖/mermaid 组件架构图),明确数据链路 = CRI 拿容器信息 + hccn_tool 拿网络 + DCMI(dlopen/dlsym)拿芯片信息,新增支持 Telegraf 上报(此前只提 Prometheus)。纯文档,不涉逻辑。
  <details><summary>代码依据 component/npu-exporter/README.md</summary>

  ```diff
  +  - 从驱动中获取芯片、网络的各项数据信息,并支持 Prometheus、Telegraf 两种方式上报。
  +  1. 通过 gRPC 服务调用 K8s 中的标准化接口 CRI,获取容器相关信息。
  +  2. 通过 exec 调用 hccn_tool 工具,获取芯片的网络信息。
  +  3. 通过 dlopen/dlsym 调用 DCMI 接口,获取芯片信息,并上报给 Prometheus。
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾在 Volcano 调度上正把"拓扑亲和"从**硬约束**改造为**可超时降级的软约束**:核心抽象是 `nextConfig(windows)→(约束, 等级, 是否有更低级)` 的策略阶梯,当前证据只覆盖 A3 SuperPod 的 sp-block 减半一种 policy(superpod/downgrade.go),`base/downgrade.go` 的可插拔接口 + 通用 store 说明后续会给 910B/其他机型补各自阶梯——未见非 A3 机型的 ladder 实现。
- 降级链路已具备"内存态 + pod annotation 持久态"双写(readDowngradeSeed 从 pod 标记恢复),证据边界:只看到读种子逻辑,写 pod annotation 的落点(markDowngraded 之后如何 patch pod)patch 节选未覆盖,未确认写入时机。
- 对我们产品的启示:多机训练/超节点的"等不到理想拓扑就降级放置"是企业级刚需;昇腾把降级状态做成**可观测 pod 标记**(timestamp + effected-config),我方若做类似弹性调度可直接对标此契约做监控/告警/审计,而非藏在调度器内存里。注意其默认关(annotation 显式开),避免误伤对拓扑强依赖的作业。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓无新提交</summary>

- npu-operator (v26.6.0) — 无新提交
- npu-container-toolkit (v26.6.0) — 无新提交
- npu-driver-installer (v26.6.0) — 无新提交
- vNPU (v0.1.0) — 无新提交
- npu-node-provision (v26.6.0) — 无新提交
- npu-dra-plugin (v26.6.0) — 无新提交
- volcano-ext (v1.9.0) — 无新提交
- ub-network-device-plugin (1.0.2) — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=145617f3510414bdd72091132d6d713ce1782bac tag=v26.1.1 scanned=2026-09-29 -->
<!-- ANCHOR repo=npu-operator sha=817e8a2372642f0e5b143a0faf1928d30cc12bdf tag=v26.6.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-29 -->
