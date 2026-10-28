# 昇腾算力栈 diff 雷达 2026-10-29

## 摘要
- **mind-cluster 一天内三条实质主线全是"故障/亚健康的调度退避"工程化**:ascend-for-volcano 新增"基于时长的亚健康(sub-health)退避"——卡级与交换机级亚健康资源在 job 的容忍窗口内被所有调度策略扣留、超时才释放;ascend-device-plugin 给 A950 UB 端口故障恢复加 600s 上报窗口,堵住 Flex 机型重启因端口恢复时间不齐触发的 1002 误隔离;DRA 侧修 DCMI uint64→int64 溢出(ResourceSlice 显存/算力容量上报被污染)。
- **npu-dra-plugin 向 K8s 1.37 DRA 规范对齐**:改用上游标准属性常量 `resource.kubernetes.io/numaNode`(deviceattribute 包)、实现新的 `WatchHealthStatus` kubelet-plugin 接口(暂返不支持)、proto 字段 `CDIDeviceIDs`→`CdiDeviceIds` 重生成,构建基镜像 Go 1.25→1.26.8。
- **vNPU 推进"优先级抢占"设计**(仅设计文档迭代,无代码):高优先级在线 vNPU 可抢占同卡所有低优先级(含 fixed-share 保底),算力维度永不阻塞在线调度;放置改为节点级+设备级两级串行均衡;已依据旧版 vCANN 源码验证灰度兼容。

## 当日重要改变
- mind-cluster [新能力] ascend-for-volcano 引入"亚健康卡/交换机按时长退避"调度:新增 `huawei.com/subhealthy.tolerance.after-time` 注解(默认 10s)+ `NodeFaultChips` 聚合结构 + `SubHealthChips()`,容忍窗内扣留、超时释放。证据 component/ascend-for-volcano/internal/npu/base/node.go、plugin/job.go、internal/rescheduling/reschedule.go。https://gitcode.com/Ascend/mind-cluster/commit/de37936c1bccda4f4b11516da296ac521dfe7aab
- mind-cluster [BUG] DRA 流程修 DCMI 容量 uint64→int64 溢出:新增 `maxInt64ResourceValue`/`maxAICoreFloatBound` 哨兵,超界值当损坏数据丢弃而非当容量上报到 ResourceSlice。证据 component/ascend-dynamic-resource-allocation/internal/device/generation_910.go。https://gitcode.com/Ascend/mind-cluster/compare/6241d029f7c049db6be0baf051af9497c2fcebd2...de37936c1bccda4f4b11516da296ac521dfe7aab
- npu-dra-plugin [新能力/版本跨档] 适配 K8s 1.37 DRA 规范:改用标准 NUMA 属性常量、实现 `WatchHealthStatus` 接口。证据 Ascend-npu-dra-plugin/internal/profiles/npu/{npu,dcmi}.go、cmd/.../driver.go。https://gitcode.com/openFuyao/npu-dra-plugin/compare/f4b6f12153e346ee928bc05e22892f25f933bb7b...32fc8e917d59a26904b8025f97bf6e3eddeb56d3
- vNPU [架构方向] docs/design 推进 vNPU 优先级抢占(在线/离线混部)设计,尚无代码落地。https://gitcode.com/openFuyao/vNPU/commit/529e48a62557698ce7a0b4a8c6df5f095d626572

## mind-cluster: 6241d029 -> de37936c
- 比较: 6241d029..de37936c | tag: v26.2.0 | commits=12 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/6241d029f7c049db6be0baf051af9497c2fcebd2...de37936c1bccda4f4b11516da296ac521dfe7aab

### AI 总结重点(源码 diff 为据)

- **ascend-for-volcano 新增完整的"亚健康(sub-health)退避"调度链路**,与既有的 silent-fault / pod-error 退避平级。新增 job 级注解 `huawei.com/subhealthy.tolerance.after-time`,默认 `DefaultSubHealthyToleranceAfterTime=10`(秒):亚健康卡/交换机在 job 排队的前 10s 被扣留、超时后放开。`clampSubHealthyTolerance` 把负值(含 -1)钳到下界 0、超限钳到 `MaxSubHealthyToleranceAfterTime`。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go</summary>

  ```diff
  +	sJob.setSubHealthyTolerance()
  ...
  +// setSubHealthyTolerance reads the huawei.com/subhealthy.tolerance.after-time
  +// annotation and populates NPUJob.ToleranceConfig.SubHealthyToleranceAfterTime,
  +// defaulting to 10: sub-healthy cards and switches are withheld for the first
  +// 10 pending seconds, then released.
  +func (sJob *SchedulerJob) setSubHealthyTolerance() {
  +	sJob.NPUJob.ToleranceConfig.SubHealthyToleranceAfterTime = util.DefaultSubHealthyToleranceAfterTime
  +	val, ok := sJob.Annotation[util.SubHealthyToleranceAnnoKey]
  +	...
  +	sJob.NPUJob.ToleranceConfig.SubHealthyToleranceAfterTime = clampSubHealthyTolerance(sJob.Name, tolerance)
  +}
  ```
  </details>

- **节点侧把分散的三组 fault-id map 聚合成 `NodeFaultChips` 结构体,并扩出第四类 `SubHealth`**。`ChipNode.Init` 的签名从 `(faulty, netUnh, silent map, podError, owners)` 收敛为 `(faults *NodeFaultChips, podError, owners)`;`parseDeviceHealthAnnotations` 返回类型同步从三个 map 变成单个 `NodeFaultChips`。新增 `ChipNode.subHealth int` 字段与 `SubHealthChips(nodeName)` 查询。这是把"节点级静态故障态"统一建模、便于再加故障类别的重构。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/affinity/chip/topo/chipnode.go</summary>

  ```diff
  +// NodeFaultChips groups the node-level static chip-id fault sets that seed a
  +// ChipNode topology: faulty, network-unhealthy, silent-fault and sub-healthy.
  +type NodeFaultChips struct {
  +	Faulty    map[int]struct{}
  +	NetUnh    map[int]struct{}
  +	Silent    map[int]struct{}
  +	SubHealth map[int]struct{}
  +}
  +
  +func (n *ChipNode) Init(faults *NodeFaultChips, podError map[int]int64, owners map[string][]int) {
  ...
  +		if has(faults.SubHealth, id) {
  +			leaf.subHealth = 1
  +		}
  ```
  </details>

- **退避在两个层面生效:卡级(device/handler)和节点级(交换机/rescheduling)**。卡级:`removeBackoffCards` 与 `chipHandler.excludedChipIDs` 都在 `subHealthyToleranceAllows()` 返回 false(窗口内)时把 `SubHealthChips` 并入扣留集。节点级:`reschedule.go` 在交换机亚健康(`HasSwitchSubHealthFault`)且仍在窗口内时,对该节点直接返回 `NPUResourceUnavailableError`,从所有调度策略里摘除,超时才允许选中。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/reschedule.go</summary>

  ```diff
  +	if fNode.HasSwitchSubHealthFault && subHealthyBackoffWithinWindow(schedulerJob) {
  +		return fmt.Errorf("%s node<%s> is switch sub-healthy and within backoff window, can not be selected",
  +			util.NPUResourceUnavailableError, vcNode.Name)
  +	}
  +func subHealthyBackoffWithinWindow(schedulerJob plugin.SchedulerJob) bool {
  +	elapsed, _ := cache.SessionElapsed(schedulerJob.Name)
  +	return util.TimeGateAllows(schedulerJob.NPUJob.ToleranceConfig.SubHealthyToleranceAfterTime, elapsed)
  +}
  ```
  </details>

- **ascend-device-plugin 给 A950 UB(超平面/hyper-plane)端口故障恢复加了 600s 上报窗口**,解决 Flex 机型重启时各 NPU 端口恢复时间不一致触发 1002(UBSeparateFault)误隔离。新增常量 `UBSeparateFaultReportWindow int64 = 600` 与全局 `ubFaultRecoverTime`:恢复期首次观测到端口仍 down 时锚定时间戳、只重新上报原始故障码,等窗口到期才升级为 1002;全节点全端口 down(交换机故障)则重置窗口开新故障周期。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
  +	// UBSeparateFaultReportWindow is the window (in seconds) during which the UB separate fault
  +	// is not reported after a hyper plane fault recovery...
  +	UBSeparateFaultReportWindow int64 = 600
  ...
  -				tmpFaultInfo.EventID = UBSeparateFaultCode
  -				device.FaultCodes = append(device.FaultCodes, UBSeparateFaultCode)
  +				if ubFaultRecoverTime == 0 {
  +					ubFaultRecoverTime = time.Now().Unix()
  +					hwlog.RunLog.Infof("UB ports still down after hyper plane fault recover, device: %d, "+
  +						"UB separate fault report is delayed for %d seconds", logicID, UBSeparateFaultReportWindow)
  +				}
  ```
  </details>

- **DRA 侧修 DCMI 容量上报的整型溢出**。DCMI 以 uint64 报容量,但 ResourceSlice 属性是 int64;新增 `maxInt64ResourceValue (1<<63-1)` 与 `maxAICoreFloatBound (1<<63)` 哨兵,超界的值视作哨兵/损坏数据而非真实容量。同时把 `ListNpuDevices` 的逐卡枚举重构为 `collectNpuDevicesByLogicID`,用 `skippableInvalidDeviceCount` 计数被剔除出 ResourceSlice 的坏卡,新增按卡查 HBM 的 `getChipHBM`。对应提交"【BUG】DRA流程中ResourceSlice上报DCMI-memorysize的问题"。
  <details><summary>代码依据 component/ascend-dynamic-resource-allocation/internal/device/generation_910.go</summary>

  ```diff
  +const (
  +	maxInt64ResourceValue uint64 = 1<<63 - 1
  +	maxAICoreFloatBound float64 = 1 << 63
  +)
  ...
  -		physical, err := g.buildNpuDevice(devList[i])
  +		validDevices, foundSkippableInvalidDevice, err := g.collectNpuDevicesByLogicID(devList[i])
  ...
  +	if skippableInvalidDeviceCount > 0 {
  +		hwlog.RunLog.Errorf("Ascend910 left %d physical devices out of the ResourceSlice", skippableInvalidDeviceCount)
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾的"故障感知调度"正在把**故障分级 + 按时长的软退避**做成统一框架:faulty / net-unhealthy / silent-fault / pod-error 之后再加 sub-health,且每一类都挂一个 job 级容忍注解 + `TimeGateAllows` 时间门。方向是从"硬摘除故障卡"转向"按容忍窗口分级让位",减少亚健康抖动对调度的扰动。证据只覆盖 for-volcano 的退避链路与 device-plugin 的 1002 窗口,未见对应的 CRD/annotation 文档化定义(`MaxSubHealthyToleranceAfterTime` 常量定义本次 patch 未摘到)。
- DRA 路径(ascend-dynamic-resource-allocation)本期仅是容量上报的健壮性修复,未见动态 vNPU 切分的新能力;与 npu-dra-plugin 的 1.37 对齐是两套 DRA 实现各自推进。

## npu-dra-plugin: f4b6f121 -> 32fc8e91
- 比较: f4b6f121..32fc8e91 | tag: v26.9.0 | commits=2 | truncated=false
- https://gitcode.com/openFuyao/npu-dra-plugin/compare/f4b6f12153e346ee928bc05e22892f25f933bb7b...32fc8e917d59a26904b8025f97bf6e3eddeb56d3

### AI 总结重点(源码 diff 为据)
- **向 K8s 1.37 DRA 规范对齐 NUMA 属性**:原来硬编码字符串 `"resource.kubernetes.io/numaNode"` 改为引用上游 `k8s.io/dynamic-resource-allocation/deviceattribute` 包的 `StandardDeviceAttributeNUMANode` 常量,软切分设备(`getSoftDeviceAttributes`)和物理设备(`buildDevice`)两处都改。这让 NPU 的 NUMA 亲和属性与 kube-scheduler 1.37 的标准设备属性对齐,DRA 可按 NUMA 做拓扑感知分配。
  <details><summary>代码依据 Ascend-npu-dra-plugin/internal/profiles/npu/dcmi.go</summary>

  ```diff
  +	"k8s.io/dynamic-resource-allocation/deviceattribute"
  ...
  -		attributes["resource.kubernetes.io/numaNode"] = resourceapi.DeviceAttribute{IntValue: ptr.To(int64(*spec.NumaNode))}
  +		attributes[deviceattribute.StandardDeviceAttributeNUMANode] = resourceapi.DeviceAttribute{IntValue: ptr.To(int64(*spec.NumaNode))}
  ```
  </details>

- **实现新的 kubelet-plugin `WatchHealthStatus` 接口**(1.37 DRA 新增的设备健康上报),当前返回 `kubeletplugin.ErrHealthNotSupported` 占位——先补齐接口满足编译/注册,健康上报尚未落地。
  <details><summary>代码依据 Ascend-npu-dra-plugin/cmd/ascend-npu-dra-kubeletplugin/driver.go</summary>

  ```diff
  +func (d *driver) WatchHealthStatus(ctx context.Context, reports chan<- kubeletplugin.DeviceHealthReport) error {
  +	return kubeletplugin.ErrHealthNotSupported
  +}
  ```
  </details>

- **DRA proto 字段随上游重生成 `CDIDeviceIDs`→`CdiDeviceIds`**(驼峰风格变化,drapb 生成码口径跟随上游),state.go/driver.go 及测试同步改;构建基镜像从 `golang:1.25-bookworm` 换成 `cr.openfuyao.cn/openfuyao/golang:1.26.8`(自建仓镜像 + Go 版本上移)。
  <details><summary>代码依据 Ascend-npu-dra-plugin/cmd/ascend-npu-dra-kubeletplugin/state.go</summary>

  ```diff
  -				CDIDeviceIDs: s.cdi.GetClaimDevices(string(claim.UID), []string{result.Device}),
  +				CdiDeviceIds: s.cdi.GetClaimDevices(string(claim.UID), []string{result.Device}),
  ```
  </details>

### 后续发展方向 [AI]
- npu-dra-plugin 在紧跟 K8s DRA 的最新 GA/规范节奏(1.37、标准设备属性、设备健康接口),但健康上报仅占位、未见动态容量/切分逻辑改动——本期是"规范对齐"而非"能力新增"。证据只覆盖 NUMA 属性、WatchHealthStatus、proto 字段三处,未见 ResourceSlice 发布逻辑或 vNPU 分配策略变化。

## vNPU: 6282df8d -> 529e48a6
- 比较: 6282df8d..529e48a6 | tag: v26.9.0 | commits=2 | truncated=false
- https://gitcode.com/openFuyao/vNPU/commit/529e48a62557698ce7a0b4a8c6df5f095d626572

### AI 总结重点(源码 diff 为据)
- **仅设计文档迭代,无代码落地**:`docs/design/0003-support-VNPU-Priority-Preemption.md` 细化 vNPU 优先级抢占方案。要点:高优先级(在线)vNPU 算力维度永不阻塞调度——无需声明 `vnpu-cores`、不占算力配额(`applySoftModeDevice` 记账贡献 0),可抢占同卡所有低优先级 vNPU(含 fixed-share 保底),抢占期可满载用卡;显存+单卡切分数(20)是仅存的准入硬条件。
  <details><summary>代码依据 docs/design/0003-support-VNPU-Priority-Preemption.md</summary>

  ```diff
  +   - **集群均衡放置(两级配合)**:节点级排序确定目标节点(集群均衡、避免个别节点压力过大),设备级排序在该节点内确定目标卡(最小化同卡在线争抢)——两级串行决策、因子一致
  ...
  +| 3 | 旧版兼容 | 已依据当前(旧版)vCANN源码验证:load_config逐行解析,未知键仅产生 Undefined config key 告警...新device-plugin多写vnpu_priority键对旧vCANN无功能影响,灰度组合功能正常 | 已确认 |
  ```
  </details>
- **可观测适配明确为 vNPU 粒度指标 `xpu_vnpu_priority`**(Gauge,0/1):由 `VxpuDevice` 结构新增 `Priority int32` 承载,xpu-exporter 按 pod_uuid/container_name 标签输出,支撑"每节点/每卡在线 vNPU 数"与在线抢占及时性、离线让位充分性的混部运营观测。

### 后续发展方向 [AI]
- vNPU 在补齐"在线/离线混部优先级抢占"这块——对标 HAMi vGPU 的 task-priority 抢占语义,但昇腾走的是 vCANN 底层(`sched_policy=3` best-effort + 优先级覆盖算力配额)。本期只是设计定稿,下一步应看 device-plugin/vCANN 解析 `vnpu_priority` 键的实现落地与 `xpu_vnpu_priority` 指标代码。证据仅为设计文档,无任何 .go/.c 代码改动。

## 本期无实质改动(折叠)
- npu-operator(无新提交,tag v26.9.0)
- npu-container-toolkit(无新提交,tag v26.9.0)
- npu-driver-installer(无新提交,tag v26.9.0)
- npu-node-provision(无新提交,tag v26.6.0)
- volcano-ext(无新提交,tag v1.9.0)
- ub-network-device-plugin(无新提交,tag v26.9.0)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=de37936c1bccda4f4b11516da296ac521dfe7aab tag=v26.2.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=npu-dra-plugin sha=32fc8e917d59a26904b8025f97bf6e3eddeb56d3 tag=v26.9.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-29 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=v26.9.0 scanned=2026-10-29 -->
