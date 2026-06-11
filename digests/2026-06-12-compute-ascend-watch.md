# 昇腾算力栈 diff 雷达 2026-06-12

## 摘要(3 条内)
- **ascend-for-volcano 新增"调度回历史节点"亲和能力**:新增 `common/cache` 包(`PodNodeAffinityCache`,owner UID→rankIndex 两层映射、72h TTL、跨调度 session 存活),多级调度引入 `SuperPodsVerified` 缓存校验与 `resolveSuperPodsForReschedule`/`tryScheduleWithHistory` 分支,被驱逐 pod 优先重回原节点。**默认关闭**(`PreferPreviousNode` 配置开关,且区间末尾专门提交"默认关闭")。
- **npu-exporter 采集架构大改**:配置从 `[]map[string]string` 升级为结构化 `MetricsGroupConfig`、支持**按分组配置采集周期**(1/5/10/30/60s 档位)与**配置热加载**(新增 `collector_schedule.go` 订阅/`dynamic_reload.go`、`SetChains`/`GetChainsSnapshot` 原子换链);利用率采集从 `BaseInfoCollector` 拆出独立 `UtilizationCollector`/`groupUtilization`。
- ascend-device-plugin:标卡场景误报 UBOE 故障修复 + 启动/复位后主动查询上报 UBOE 状态 + A5 离线热复位适配(commit/信号文件可见,本期 patch 节选未覆盖其 hunk)。openFuyao 8 仓本期全部无新提交。

## 当日重要改变(命中信号才列)
- mind-cluster `[新能力]` ascend-for-volcano 新增顶层 `common/cache/previous_node.go`(`PodNodeAffinityCache`),实现 pod→历史节点亲和缓存,支撑驱逐后重调度回原节点。证据见下。 https://gitcode.com/Ascend/mind-cluster/commit/b7790ce9300210248d47f75856bee8f87d1c3231
- mind-cluster `[新能力]` npu-exporter 新增 `collector/common/collector_schedule.go` + `collector/config/dynamic_reload.go`,引入配置热加载与按组采集周期。证据见下。 https://gitcode.com/Ascend/mind-cluster
- mind-cluster `[架构方向]` npu-exporter 利用率采集从 `BaseInfoCollector` 拆为独立 `UtilizationCollector`(新增 `collector_for_utilization.go`,删 `collector_for_npu.go` 中对应字段/desc),采集职责按指标组解耦。证据见下。 https://gitcode.com/Ascend/mind-cluster

## mind-cluster: 3c7cf49f -> b7790ce9
- 比较:3c7cf49f6035d42355c3a6e803cc1b0509d6b8fd..b7790ce9 | tag: v26.0.1 | commits=54 | truncated=false
- 源:https://gitcode.com/Ascend/mind-cluster

### AI 总结重点(源码 diff 为据)

- **ascend-for-volcano 新增 pod→节点亲和缓存,实现"重建/驱逐后调度回原节点"。** 新包 `common/cache` 定义 `PodNodeAffinityCache`:第一层 key 是 owner UID(PodGroup 的 owner,如 Deployment UID,确保 PodGroup 以新 UID 重建后映射仍续),第二层 rankIndex→`RankNodeEntry{Node, Previous}`;`Previous` 作回滚锚点(DeallocateFunc Pending 时从 Previous 还原)。注释明确**无锁**(依赖 Volcano 单 goroutine 串行调度),TTL 默认 72h 防内存泄漏。
  <details><summary>代码依据 component/ascend-for-volcano/common/cache/previous_node.go (added)</summary>

  ```diff
  +const (
  +	// DefaultTTL is the default time-to-live for cache entries (72 hours).
  +	DefaultTTL = 72 * time.Hour
  +)
  +// RankNodeEntry stores the current and previous node assignment for a single rank.
  +type RankNodeEntry struct {
  +	Node     string // current node assignment
  +	Previous string // previous assignment (rollback anchor), empty if first-time
  +}
  +type PodNodeAffinityCache struct {
  +	// key: ownerUID, value: rankIndex → RankNodeEntry
  +	OwnerToRankNodes map[string]map[string]*RankNodeEntry
  +	UpdateTime map[string]int64
  +}
  ```
  </details>

- **该能力由配置开关 `PreferPreviousNode` 控制,且本期默认关闭。** `factory.go` 的 `initDynamicParameters` 读取 `getPreferPreviousNodeConfig(configs)` 写入 `FrameAttr.PreferPreviousNode`;`InitNPUSession` 新增 `initAffinityCache()`——仅当开关开启才建缓存,冷启动(调度器重启)时用当前 pod→node 分配播种,后续 session 只刷时间戳/逐过期项。区间末尾提交 `<fix>[volcano]默认关闭优先调度回原节点` 把默认值落到关闭,属灰度/保守上线信号。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory.go (modified)</summary>

  ```diff
  +	sHandle.initAffinityCache()
  +	sHandle.ClusterCache.AffinityCache = sHandle.AffinityCache
  ...
  +	sHandle.FrameAttr.PreferPreviousNode = getPreferPreviousNodeConfig(configs)
  ...
  +func (sHandle *ScheduleHandler) initAffinityCache() {
  +	if !sHandle.FrameAttr.PreferPreviousNode {
  +		return
  +	}
  +	if sHandle.AffinityCache == nil {
  +		sHandle.AffinityCache = cache.NewPodNodeAffinityCache()
  +		// One-time cold start: seed cache from currently running pods.
  ```
  </details>

- **多级调度引入 SuperPods 缓存校验,避免每个 pod 重复算树。** `multilevelscheduling/frame.go` 新增 `rescheduleContext`(打包 task/superPods/missingNodes/fJob)与 `tryUseCachedSuperPods`:job 已有缓存 SuperPods 时,`SuperPodsVerified` 标志位保证一个 session 内只校验一次,失效则 `recomputing`;`scheduleMultipleLevelPodsForJob` 改为先 `resolveSuperPodsForReschedule`,命中历史走 `tryScheduleWithHistory`、否则回落 `scheduleFromAllNodes`。原"job ready 即 skip"的简单判断被替换为带失效检测的缓存路径。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/multilevelscheduling/frame.go (modified)</summary>

  ```diff
  -	if *job.JobReadyTag && len(job.SuperPods) != 0 {
  -		klog.V(util.LogErrorLev).Infof("%s ...: job is ready, skip", ...)
  +	if mh.tryUseCachedSuperPods(&job, task, nodes) {
  		return nil
  	}
  ...
  +	job.SuperPodsVerified = true
  ...
  -	resourceTrees, getErr := plugin.GetResourceTrees(...)
  +	rctx := mh.resolveSuperPodsForReschedule(task, nodes)
  +	if rctx == nil {
  +		return mh.scheduleFromAllNodes(task, nodes)
  +	}
  +	sm, err := mh.tryScheduleWithHistory(rctx, nodes)
  ```
  </details>

- **npu-exporter:采集配置从扁平 map 升级为结构化类型,并引入按组采集周期。** `metrics_config.go` 把 `presetConfigs`/`pluginConfigs` 从 `[]map[string]string` 改为 `[]MetricsGroupConfig`,删除硬编码的 `defaultPresetConfigs`/`defaultPluginConfigs`,新增周期常量 `intervalSeconds1/5/10/30`、`defaultIntervalSeconds=60`、`maxIntervalSeconds=86400`(1 天上限);`groupUtilization` 加入单 goroutine 采集 map。即每个指标组可独立配采集频率,不再全局统一周期。
  <details><summary>代码依据 component/npu-exporter/collector/config/metrics_config.go (modified)</summary>

  ```diff
  +		groupUtilization: &metrics.UtilizationCollector{},
  ...
  -	presetConfigs      = make([]map[string]string, 0)
  -	defaultPresetConfigs = []map[string]string{ ... groupNodeBase ... }
  +	presetConfigs      = make([]MetricsGroupConfig, 0)
  ...
  -	metricsGroup = "metricsGroup"
  -	state        = "state"
  +	defaultIntervalSeconds = 60
  +	intervalSeconds1       = 1
  +	maxIntervalSeconds     = 86400 // 1 day
  ```
  </details>

- **npu-exporter:新增配置热加载机制,运行中可重建采集链而不重启。** 新文件 `collector_schedule.go` 定义唤醒原因枚举 `wakeByContext/wakeByTimer/wakeByConfigReload` 与订阅模型 `subscribeConfigReload`/`unsubscribeConfigReload`(广播 channel);`npu_collector.go` 新增 `chainsMu sync.RWMutex` 与 `SetChains`/`GetChainsSnapshot` 对三条采集链(single/multi/plugin)做原子替换,`GetUpdateTime` 注释说明 `updateTime>0`=旧版统一周期兼容、`==0`=按组周期。配合提交"修复 configmap 场景下检测配置变更失效问题",指向 ConfigMap 改动可热生效。
  <details><summary>代码依据 component/npu-exporter/collector/common/{collector_schedule.go(added), npu_collector.go(modified)}</summary>

  ```diff
  +const (
  +	wakeByContext waitResult = iota
  +	wakeByTimer
  +	wakeByConfigReload
  +)
  +func subscribeConfigReload() <-chan struct{} { ... }
  ...
  +	chainsMu sync.RWMutex
  +func SetChains(single, multi, plugin []MetricsCollector) {
  +	chainsMu.Lock(); defer chainsMu.Unlock()
  +	ChainForSingleGoroutine = single ...
  +func GetChainsSnapshot() (single, multi, plugin []MetricsCollector) { ... }
  ```
  </details>

- **npu-exporter:利用率采集从 BaseInfoCollector 拆出独立 UtilizationCollector。** 新文件 `collector_for_utilization.go` 定义 `chipUtilizationCache`(util/overall/vector/cube 四类利用率)与 `UtilizationCollector`,并把芯片支持矩阵(`notSupportedVectorUtilDevices`=910、`supportedOverallUtilDevices`=910B/A3/A5、`supportedCubeDevices`=910B/A3)迁入;`collector_for_npu.go` 同步删除 `chipCache` 里的四个利用率字段、`BaseInfoCollector.realGetDeviceUtilizationRateInfoFunc` 及 `descUtil/descOverUtil/...`、`container_npu_utilization`。采集职责按指标域解耦,利用率成为可独立配置周期的组。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/{collector_for_utilization.go(added), collector_for_npu.go(modified)}</summary>

  ```diff
  // collector_for_utilization.go (added)
  +type UtilizationCollector struct {
  +	colcommon.MetricsCollectorAdapter
  +	realGetDeviceUtilizationRateInfoFunc func(logicID int32, dmgr devmanager.DeviceInterface, chip *chipUtilizationCache)
  +}
  // collector_for_npu.go (modified) —— 同名字段/desc 整体迁出
  -	notSupportedVectorUtilDevices = map[string]bool{ common.Ascend910: true }
  -	descUtil = colcommon.BuildDesc("npu_chip_info_utilization", ...)
  -	npuCtrUtilization = colcommon.BuildDesc("container_npu_utilization", ...)
  -	Utilization int `json:"utilization"`   // 从 chipCache 删除
  ```
  </details>

- **ascend-device-plugin:UBOE 故障上报与 A5 热复位适配(本期 patch 节选未覆盖其 hunk,以下据 commit + 信号文件,置信度低)。** 信号文件命中 `pkg/device/ascendcommon.go`(143 改)与 `pkg/server/hot_reset_manager.go`(53 改),配合提交"修复标卡场景错误上报 UBOE 故障""device-plugin 启动与 NPU 复位后主动查询上报 UBOE 状态""A5 离线热复位适配及热复位超时时间修改"。方向:UBOE(UB over Ethernet)故障检测在标卡(非超节点)场景误报被修,且复位后主动补查状态;A5 离线热复位流程与超时参数适配。**未读到对应 diff hunk,不下符号级结论。**

### 后续发展方向 [AI]
- 调度侧主线是**"亲和性记忆 + 重调度回原节点"**:`PodNodeAffinityCache` 跨 session 存活、用 owner UID 抗 PodGroup 重建,典型场景是断点续训/故障驱逐后让 rank 回到原 NPU 节点以复用本地数据与拓扑。证据覆盖缓存数据结构、factory 初始化与多级调度的缓存校验三处;**默认关闭**说明仍在灰度,未见 Deallocate/Allocate 事件写缓存的完整链路 hunk(`RecordAssignment` 调用点本期 patch 节选未全覆盖)。
- 监控侧从"全局统一周期 + 单体 BaseInfoCollector"转向**"按指标组配频 + 热加载 + 采集器拆分"**,降低高频指标(利用率)与低频指标(版本/光模块)的采集耦合与开销,并让 ConfigMap 改动免重启生效。证据覆盖配置结构体升级、调度/热加载新文件、利用率采集拆分;未见 `MetricsGroupConfig` 的字段定义与 JSON 解析 hunk(在 metrics_config.go 截断段之后),也未见 devmanager 层 `GetDeviceUtilizationRateCommon` 实现(属 ascend-common 子模块,本区间未命中)。
- device-plugin 持续打磨 **UBOE 故障检测与热复位**(标卡误报修复 + 复位后主动补查 + A5 超时适配),属可靠性收敛而非新能力;证据仅到 commit/文件层,需后续区间补 hunk 才能定性。

## 本期无实质改动(折叠)
<details><summary>openFuyao 8 仓本期均无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:全部 `无新提交`(SHA 与上期一致)。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=b7790ce9300210248d47f75856bee8f87d1c3231 tag=v26.0.1 scanned=2026-06-12 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=vNPU sha=8eb5e3c8e3f1a29f4f2e4c246fb3c00538b132af tag=v0.1.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-12 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-12 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-12 -->
