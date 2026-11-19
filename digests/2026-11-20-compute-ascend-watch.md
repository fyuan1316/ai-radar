# 昇腾算力栈 diff 雷达 2026-11-20

> 正常日增量:mind-cluster 38 个 commit,其中 19 个非 merge,truncated=false,深度模式。PATHPREFIX 在 task 默认清单外补了 `component/ascend-dynamic-resource-allocation component/ascend-common`。另对区间做了一次无 prefix 的全量 compare,PATHPREFIX 外的改动是 `ascend-faultdiag`(19 文件)、`ascend-clusterops-agent`(6 文件，该目录在 base 已存在，不算新组件)、`mindio`(3 文件)和 docs,下文已摘要并标注。openFuyao 8 仓都没有新提交。
>
> 本期定性:**修复和可观测性重构为主，没有新能力或 API/CRD 变更**。

## 摘要
- **mind-cluster volcano 修复 2 处调度侧状态问题**:
  - 故障 Pod 的 `PodFailedTime` 原来取 kubelet 写的容器 `FinishedAt`(Pod 所在节点的时钟),现在改为 volcano 判定为故障任务时取自己的 `time.Now()`,避免节点之间时钟偏差让退避窗口算错。
  - `syncAnnotation` 跨 session 保留的节点注解，从"只保留 NPU 资源键"扩大到同时保留 `-Unhealthy / -NetworkUnhealthy / -Fault / -Recovering` 健康列表键。修复前，这些键会在 device-info CM 下一次更新前从调度视图里消失。
- **mind-cluster ascend-common 把 DCMI 错误码结构化**:新增 `dcmi.DcmiError`(私有字段 code/desc/rendered)和 `Classify()` 四分类(Unknown / NotSupported -8255 / FuncNotFound -99998 / Fault)。v1 / v2 两套 dcmi 封装的 `fmt.Errorf` 全部改为 `dcmiErrorf(retCode, ...)`,devmanager 层改用 `%w` 透传错误链。原来靠 `strings.Contains(err, "-8255")` 判断"不支持"，现在改走错误码，并保留字符串兜底作为过渡。device-plugin 首个消费点是 CPU 亲和查询：返回"不支持"时(如 A3 SuperPod)日志降为 Debug。
- **mind-cluster device-plugin 的可选能力降级更明确**:`initDevManager` 不再返回 switch 管理器，拆出 `initSwitchDevManager`。它把 `liblingqu-dcmi.so` 的三类失败区分为哨兵错误 lib-not-found / load-failed / init-failed,并按 reason 打日志。`RAS_NET_ROOT_PATH` 未配置时返回哨兵 `ErrRasNetRootPathNotSet`,`RasTopoWriteTask` 打一条 Info 后跳过，不再刷 Error。版本:最新 tag 为 v26.3.0-beta.2(2026-11-18 打),是 26.3 线的第二个预发布，不算跨档。

## 当日重要改变
严格信号([弃用/移除] [API/CRD变更] [架构方向] [版本跨档] [新能力])本期都没有命中。下面按惯例列出扩展类行为变化:
- mind-cluster [行为变化] volcano 故障退避的 Pod 失败时间改由调度器时钟决定：删除 `getPodFailedTime`(原取容器 `FinishedAt`),改为在 `createFaultTaskHandler` 中设置 `faultTask.PodFailedTime = time.Now().Unix()`。commit `7f51aac6da6b` https://gitcode.com/Ascend/mind-cluster/commit/7f51aac6da6b422bff37ebddccf7b74e5458a38d
- mind-cluster [行为修复] volcano 节点 NPU 健康列表注解跨 session 保留:新增 `util.IsNPUDeviceInfoAnnotation`,`syncAnnotation` 改用它判断要保留哪些键。commit `8923063475f2` https://gitcode.com/Ascend/mind-cluster/commit/8923063475f28a4e3991e0ceba962bed2d38a775
- mind-cluster [公共库接口] ascend-common 新增 `devmanager/errors.go` 与 `devmanager/dcmi/errors.go`(`DcmiError` / `IsNotSupported` / `IsFuncNotFound` / `GetErrorCode` / `Classify`)。commit `7c98a89868ac` https://gitcode.com/Ascend/mind-cluster/commit/7c98a89868acf5afebe7e5e410c544a306bdaa2e
- mind-cluster [版本] 最新 tag v26.3.0-beta.2(11-18),上一个 26.3 预发布 beta.1 是 10-27 打的，不算跨档。昨日锚点写的 v26.2.1 是 helper 取 tag 的顺序有抖动。tags: https://gitcode.com/Ascend/mind-cluster/tags

## mind-cluster: 171c2fda -> 20e6be78
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/171c2fda6b763f88cccd683520139b318bbdd9d0...20e6be7896e34988e554b1fcd5e5b281863e4050 | tag: v26.3.0-beta.2 | commits=38 | truncated=false

### AI 总结重点(源码 diff 为据)
- **volcano 故障时间源从"节点时钟"改为"调度器时钟"**。原 `getPodFailedTime` 遍历 `ContainerStatuses` 的 `State.Terminated` 与 `LastTerminationState.Terminated`,取最大的 `FinishedAt`(时间由 Pod 所在节点的 kubelet 写入);拿不到时退回 `time.Now()`。现在整个函数删除，任务一旦被 `getTaskHealthState` 判为故障，就直接在 `createFaultTaskHandler` 里写入 `time.Now().Unix()`。效果：退避窗口和 pod error 判定都只用 volcano 所在主机的时钟，节点之间的时钟偏差不再导致误判。代价是故障时间变成"调度器观测到的时刻"，不再是"容器真实退出的时刻",会比实际晚最多一个调度周期。是否每个 session 都会重写这个时间(从而推后窗口),本期 hunk 里看不到，未核实。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go + job.go</summary>

  ```diff
  		if isFaultTask {
  +			faultTask.PodFailedTime = time.Now().Unix()
  			klog.V(util.LogInfoLev).Infof("task %s is fault task: %v, health state: %s", task.Name, isFaultTask,
  ...
  -		if isFaultTask {
  -			podFailedTime, err := getPodFailedTime(task)
  -			if err != nil {
  -				klog.V(util.LogWarningLev).Infof("getPodFailedTime %s %s", task.Name, err)
  -			} else {
  -				faultTask.PodFailedTime = podFailedTime
  -			}
  -		}
  ...(job.go)
  -func getPodFailedTime(task *api.TaskInfo) (int64, error) {
  -	for _, status := range task.Pod.Status.ContainerStatuses {
  -		for _, term := range []*v1.ContainerStateTerminated{
  -			status.State.Terminated,
  -			status.LastTerminationState.Terminated,
  ...
  -			if u := term.FinishedAt.Unix(); u > latest {
  ```
  </details>
- **volcano 节点健康注解跨 session 丢失的修复**。`syncAnnotation` 每个 session 都会重建节点注解 map,而 `updateNPUNodeDeviceInfos` 只在 device-info CM 的 `UpdateTime` 前进时才重新合并 CM。旧代码从上个 session 只保留 `IsNPUResource` 的键(资源列表本身)。因此 `huawei.com/Ascend910-Unhealthy`、`-NetworkUnhealthy`、`-Fault`、`-Recovering` 这类健康列表在 CM 没有变化的 session 里会消失，调度器可能把不健康的卡当成健康卡使用。新函数 `IsNPUDeviceInfoAnnotation` 把这 4 类后缀(要求带 `HwPreName` 前缀)也列为需要保留的键;`GetRecoveringDevInfo` 里的字面量 `"-Recovering"` 同时收敛为常量 `RecoveringSuffix`。commit 标题写的是"存在 vNPU 时",但 hunk 是通用逻辑，与是否切 vNPU 无关。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/node.go + common/util/util.go</summary>

  ```diff
  	// 2. last session device infos
  	for annoKey, annoValue := range n.Annotation {
  -		if util.IsNPUResource(v1.ResourceName(annoKey)) {
  +		if util.IsNPUDeviceInfoAnnotation(annoKey) {
  			existAnno[annoKey] = annoValue
  ...
  +func IsNPUDeviceInfoAnnotation(key string) bool {
  +	if IsNPUResource(v1.ResourceName(key)) {
  +		return true
  +	}
  +	if !strings.HasPrefix(key, HwPreName) {
  +		return false
  +	}
  +	return strings.HasSuffix(key, NPUUnhealthySuffix) ||
  +		strings.HasSuffix(key, NPUNetworkUnhealthy) ||
  +		strings.HasSuffix(key, DeviceFaultCmKeySuffix) ||
  +		strings.HasSuffix(key, RecoveringSuffix)
  +}
  ```
  </details>
- **DCMI 错误码结构化(ascend-common,被 device-plugin、npu-exporter 等复用)**:
  - 新类型 `dcmi.DcmiError{code ErrorCode; desc; rendered}` 字段全部不导出，只能经 `dcmiErrorf` / `Errorf` 构造。`Error()` 原样返回旧文本，日志格式不变。
  - `Classify()` 把错误分成 4 类:NotSupported(-8255,视为正常)、FuncNotFound(-99998,需升级驱动)、其余 Fault(真实故障)、非 DcmiError 归 Unknown。
  - dcmi.go(v1:urma / UB ping mesh / HCCS ping mesh 等)和 dcmi_v2.go(Init / ShutDown / Version / Health / Temperature 等)全部改为 `dcmiErrorf(retCode, ...)`。
  - devmanager 的 `GetDeviceHealth` / `GetDeviceTemperature` / `GetDeviceVoltage` 等原来吞掉底层 err、只返回 logicID,现在改为 `%w` 包装。
  - `GetDeviceUtilizationRate` 的"不支持缓存"短路也带上 -8255 码，判断从 `strings.Contains(err.Error(), common.NotSupportErrorCode)` 改为 `IsNotSupported(err)`。devmanager 层的 `IsNotSupported` 保留字符串兜底，注释写明"整条链结构化后移除"。
  <details><summary>代码依据 component/ascend-common/devmanager/dcmi/errors.go + devmanager.go + errors.go</summary>

  ```diff
  +type DcmiError struct {
  +	code     ErrorCode // unique source of truth, from the bottom libdcmi interface
  +	desc     string    // from dcmiErrMap; "unknown error code" if not found
  +	rendered string    // original v1/v2 text, returned as-is by Error()
  +}
  ...
  +func Classify(err error) ErrCategory {
  +	c, ok := GetErrorCode(err)
  +	if !ok {
  +		return CategoryUnknown
  +	}
  +	switch c {
  +	case NotSupportErrorCodeInt:
  +		return CategoryNotSupported
  +	case FuncNotFoundErrorCodeInt:
  +		return CategoryFuncNotFound
  +	default:
  +		return CategoryFault
  ...(devmanager.go)
  -		return common.UnRetError, fmt.Errorf("device type %s is not supported (cached)", deviceType.Name)
  +		return common.UnRetError, dcmi.Errorf(dcmi.NotSupportErrorCodeInt,
  +			"device type %s is not supported (cached)", deviceType.Name)
  ...
  -		if strings.Contains(err.Error(), common.NotSupportErrorCode) {
  +		if IsNotSupported(err) {
  ...(devmanager/errors.go)
  +func IsNotSupported(err error) bool {
  +	if dcmi.IsNotSupported(err) {
  +		return true
  +	}
  +	return err != nil && strings.Contains(err.Error(), common.NotSupportErrorCode)
  +}
  ```
  </details>
- **device-plugin 首个消费点:CPU 亲和查询"不支持"时降级日志**。`setNumaNodesByAffinityCpu` 在 `GetAffinityCpuInfo` 失败时，若 `devmanager.IsNotSupported` 为真(注释举例 A3 SuperPod),只打 Debug;-99998 FuncNotFound 被明确排除在外，仍打 Error。返回值不变，只改变日志级别。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/numa_utils.go</summary>

  ```diff
  -		hwlog.RunLog.Errorf("get affinity cpu info for npu %d failed, error: %v", dev.LogicID, errCpu)
  +		if devmanager.IsNotSupported(errCpu) {
  +			hwlog.RunLog.Debugf("get affinity cpu info for npu %d not supported, error: %v", dev.LogicID, errCpu)
  +		} else {
  +			hwlog.RunLog.Errorf("get affinity cpu info for npu %d failed, error: %v", dev.LogicID, errCpu)
  +		}
  ```
  </details>
- **device-plugin 的 switch 故障检测拆成独立的可选能力**:
  - `initDevManager` 从返回三元组 `(devM, switchDevM, err)` 改为二元组，只负责必需的 devmanager。新函数 `initSwitchDevManager(devM)` 不会返回错误，失败时返回 nil。
  - 910A5 直接跳过(reason=unsupported-device);其他型号都会尝试加载 `liblingqu-dcmi.so`,注释特别说明不要收窄为只在 910A3 上加载。
  - `InitSwitchDev` 的三处失败分别包装成哨兵错误 `ErrSwitchLibNotFound`(Warn)/ `ErrSwitchLibLoadFailed` / `ErrSwitchLibInitFailed`(Error)。
  - `entry.go` 里 `EnableSwitchFault` 简化为 `switchDevM != nil`,语义与原来一致。
  <details><summary>代码依据 pkg/next/devicefactory/driver_init.go + deviceswitch/ascend_switch.go</summary>

  ```diff
  -func initDevManager() (devmanager.DeviceInterface, *deviceswitch.SwitchDevManager, error) {
  +func initDevManager() (devmanager.DeviceInterface, error) {
  ...
  +func initSwitchDevManager(devM devmanager.DeviceInterface) *deviceswitch.SwitchDevManager {
  +	devType := devM.GetDevType()
  +	if devType == api.Ascend910A5 {
  ...
  +	case errors.Is(initErr, deviceswitch.ErrSwitchLibNotFound):
  +		hwlog.RunLog.Warnf("switch fault detection: disabled (reason=lib-not-found, lib=%s), "+
  ...(ascend_switch.go)
  +const SwitchLibName = "liblingqu-dcmi.so"
  +var (
  +	ErrSwitchLibNotFound   = errors.New("switch library not found")
  +	ErrSwitchLibLoadFailed = errors.New("switch library load failed")
  +	ErrSwitchLibInitFailed = errors.New("switch library init failed")
  +)
  ```
  </details>
- **慢网诊断从"未配置即报错"改为"未配置即关闭"**。`slownet.GetRasNetRootPath` 在环境变量 `RAS_NET_ROOT_PATH` 为空时返回哨兵 `ErrRasNetRootPathNotSet`,`GetSuperPodInfoFilePath` / `GetConfigPathForDetect` 不再各打一条 Error。`RasTopoWriteTask` 对未配置的情况打 Info 后 return,对配置了但不是目录的情况仍打 Error。另有 `utils.parseLibFromLdCmd` 的修复:`grep` 退出码 1(无匹配，即库不在 ld cache 中)不再被记为"command exec failed"。
  <details><summary>代码依据 ascend-common/api/slownet/fault_net.go + ascend-device-plugin/pkg/topology/rack_topology.go + common-utils/utils/path.go</summary>

  ```diff
  +var ErrRasNetRootPathNotSet = errors.New("env " + rasNetRootPathKey +
  +	" not exists, please config it before starting")
  ...
  -		return "", fmt.Errorf("env %s not exists, please config it before starting", rasNetRootPathKey)
  +		return "", ErrRasNetRootPathNotSet
  ...(rack_topology.go)
  +		if errors.Is(err, slownet.ErrRasNetRootPathNotSet) {
  +			hwlog.RunLog.Info("RAS_NET_ROOT_PATH is not configured, slow network diagnosis is disabled, " +
  ...(path.go)
  +		waitErr := grepCmd.Wait()
  +		if waitErr == nil || isGrepNoMatch(waitErr) {
  +			return
  +		}
  ```
  </details>
- **PATHPREFIX 外补读**(全量 compare,只扫 hunk 摘要，未逐行精读):
  - `ascend-faultdiag`:UB 链路诊断改以 kernel.log 的 `aubdfx_net_dfx_info_print` 为主数据源，用 `KERNEL_DFX_METRIC_MAP` 把指标名映射回旧 ubctl 指标名，下游规则层不用改。新增"端侧主动丢包"判定：比较 lcne `[HCCL_SHAPSHOT]` 中 6 个丢包计数(如 `PPP_RLT_DROP_NUM`、`UB_TX_L2_ERR_DROP_PKT_CNT`)的 before/after,只要增长就输出新细分码 `Comp_Custom_*_LOST_PKG_EAD`。新增掉卡类细分码 `COMP_LOST_DEV_HBM_MAIN_MIRROR_CUSTOM` / `UCE_PANIC` / `HBM_THERMAL_OSOOM` / `AIC_ECC` / `AICPU_CE` 等，加上 memcache / memfabric 故障模式，都属于诊断知识库扩充。commits https://gitcode.com/Ascend/mind-cluster/commit/6db4c217959a6283f955b8a1fb7ded447008242b / https://gitcode.com/Ascend/mind-cluster/commit/a7e98a25bf3e7f6f53f521b74023da65515ef640 / https://gitcode.com/Ascend/mind-cluster/commit/35309ebf4e83093f164fc9df136459c5ba6ba52b
  - `ascend-clusterops-agent`:新增 pydantic 查询契约 `query_schemas.py`(fault / isolation / resource / job 四个只读查询工具，统一封装为 `QueryResult` 信封，status 取 ok/partial/error)和数据源常量表 `datasources/sources.py`。数据源是只读 ClusterD 的 CM:`mindx-dl/cluster-info-device-*`(label `mx-consumer-volcano=true`)、`cluster-info-node-cm`、`cluster-info-switch` / `cluster-info-dpu`,以及 DP 的 `kube-system/mindx-dl-deviceinfo-<node>`。commit https://gitcode.com/Ascend/mind-cluster/commit/5a4706599ac7d5b24ed2084d7da9078db1e4301c

### 后续发展方向 [AI]
- **DCMI 错误分类会推广到 npu-exporter、noded 等消费方**。证据：devmanager 层的注释要求业务代码统一经 devmanager 做 `IsNotSupported/Classify`,并写明"整条链结构化后移除字符串兜底"。可以预期后续会按 `ErrCategory` 统一日志级别和上报策略，把"不支持"和"需升级驱动"从真实故障里分出来，减少异构代际混部(A3/A5)时的误告警。证据只覆盖 ascend-common 与 device-plugin 的 numa 一处，尚未看到 exporter 或 noded 接入。
- **调度侧故障状态在向"以调度器为准"收敛**。证据：故障时间改用 volcano 时钟，健康列表注解跨 session 持久化。两处都在消除 volcano 视图与节点或 CM 视图之间的时间差和状态差，结合上期把降级退避改为全局默认开启，昇腾的故障重调度链路在加固。证据只覆盖 rescheduling 与 node.go 两处 hunk,没有逐 PR 展开测试用例。
- **ClusterOps Agent 在为 LLM Agent 打确定性的只读数据面**。证据:query_schemas 注释写"keep constraints in the schema so discovery and Agent inputs describe the same rules",数据源只读 ClusterD 与 DP 的 CM。方向是把集群故障、隔离、资源、作业状态包装成工具供智能运维 Agent 调用。证据只有契约和数据源层，尚未看到 HTTP 服务或 Agent 编排代码。

### 对我们产品的启示
- volcano 的这两处修复对我们的 GPU 故障重调度同样适用：故障时间别依赖节点上报的时间戳;每个 session 都会重建的缓存注解，要确认健康类键会跨 session 保留。
- DcmiError 的四分类(不支持 / 需升级驱动 / 真实故障 / 未知)可以直接借鉴到我们的 NVML 错误处理(`ERROR_NOT_SUPPORTED` vs `ERROR_FUNCTION_NOT_FOUND`),用来做异构代际混部时的告警降噪。

## 本期无实质改动(折叠)
- npu-operator:无新提交(ddcf0eb7)
- npu-container-toolkit:无新提交(c720a3b8)
- npu-driver-installer:无新提交(bd1b2a9e;本次 tags 接口正常返回，锚点 tag 恢复为 v26.9.0,这是 2026-07-23 的旧 tag,不是新版本)
- vNPU:无新提交(529e48a6)
- npu-node-provision:无新提交(717ef777)
- npu-dra-plugin:无新提交(f0654355)
- volcano-ext:无新提交(0f265f98)
- ub-network-device-plugin:无新提交(37a1d669)

## 扫描锚点(机器可读，勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=20e6be7896e34988e554b1fcd5e5b281863e4050 tag=v26.3.0-beta.2 scanned=2026-11-20 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=37a1d669b4f5ad815110d509c541d321c0c4fab5 tag=v26.9.0 scanned=2026-11-20 -->
