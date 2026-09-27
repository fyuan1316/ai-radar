# 昇腾算力栈 diff 雷达 2026-09-28

## 摘要
- 追踪的 9 个仓中,8 个 openFuyao 仓无新提交(EMPTY);mind-cluster 本期有 2 个追踪清单内 component 的实质改动:**npu-exporter** 把 UB 端口采集从"全节点共享一份 die→port 映射"改为**按 logicID(单卡)隔离**,修多卡节点 UB 端口拓扑串卡的正确性问题;**clusterd** 把上报 ConfigMap 里的空切片/空 map 从序列化成 `null` 规范化为 `[]`/`{}`。
- 均无 API/CRD/架构方向/版本跨档变更,不命中重要改变信号,tag 仍 v26.1.1 未跨档。npu-exporter 这条虽不命中信号,但改变了对外暴露指标的数据形状(每卡 UB 端口),对下游消费方有实际影响,值得记一笔。

## 当日重要改变
无(本日无命中 [弃用/移除]/[API/CRD变更]/[架构方向]/[版本跨档]/[新能力] 的改动)。

## mind-cluster: 90fb72cf -> ec7c1608
- 比较: 90fb72cf..ec7c1608 | tag: v26.1.1 | commits=6(含 merge + 1 条 ClusterOPS 文档提交,范围外)
- 源链接: https://gitcode.com/Ascend/mind-cluster/compare/90fb72cfef5c23e53cb19b517681eb53f3015bf0...ec7c16088795169038f600732259c57524d672c3
- 追踪清单内命中两个 component:`npu-exporter`(UB 端口指标)、`clusterd`(DPU/交换机上报 CM 序列化)。

### AI 总结重点(源码 diff 为据)
- **npu-exporter:UB 端口映射从"全局单份"升为"按 logicID 分卡存储",修多卡串卡**。核心数据结构 `NpuDevPortsInfo.devPortMap` 由 `map[int][]NpuDevPortInfo`(die→ports)扩成 `map[int32]map[int][]NpuDevPortInfo`(logicID→die→ports)。原 `SetPortMap` 直接 `e.devPortMap = devMap` 整体覆盖,多卡循环时**后一张卡覆盖前一张**,全节点只剩最后一张卡的端口拓扑;新版按 `logicID` 落各自的子 map,并惰性初始化外层 map。`Init()` 累加总端口数也相应改为双层遍历(logicID→die→ports 求和)。这是一条**多卡节点 UB 端口指标正确性修复**,不是新能力。
  <details><summary>代码依据 component/npu-exporter/collector/common/common.go</summary>

  ```diff
  -// SetPortMap init set npu ports info
  -func (e *NpuDevPortsInfo) SetPortMap(devMap map[int][]common.NpuDevPortInfo) {
  +// SetPortMap init set npu ports info for the specified logicID
  +func (e *NpuDevPortsInfo) SetPortMap(logicID int32, devMap map[int][]common.NpuDevPortInfo) {
  +	if e.devPortMap == nil {
  +		e.devPortMap = make(map[int32]map[int][]common.NpuDevPortInfo)
  +	}
   	// Sort port list for each die to ensure consistent order
  -	for _, ports := range devMap {
  +	for dieID, ports := range devMap {
   		sort.Slice(ports, func(i, j int) bool { return ports[i].PortID < ports[j].PortID })
  +		...logger.Infof("...logicID=%d, dieID=%d, portIDs=%v", logicID, dieID, portIDs)
   	}
  -	e.devPortMap = devMap
  +	e.devPortMap[logicID] = devMap
   }
  ```
  </details>

- **新增 `GetMergedPortMap()`,给"不带 logicID 的 legacy 指标描述符"用**。`GetPortMap()` 改签名为 `GetPortMap(logicID int32)` 返回单卡子 map;但 legacy 描述符构建路径(`buildLegacyDescMap`/`buildLegacyDescSlice`)没有 logicID 上下文,故新增 `GetMergedPortMap()` 返回跨所有 logicID 的 die→ports 并集(注释点明"同型号芯片 die/port 结构一致,故可用合并视图建 legacy 描述符")。即:**per-card 采集走 `GetPortMap(logicID)`,legacy 全局描述符走 `GetMergedPortMap()`**,两条路径分流。
  <details><summary>代码依据 collector/common/common.go + metrics/collector_for_ub_legacy.go</summary>

  ```diff
  +// GetMergedPortMap returns the union of dieID->ports across all logicIDs.
  +// Same-type chips share identical die/port structure, so this merged view is
  +// used to build legacy metric descriptors which do not carry a logicID.
  +func (e *NpuDevPortsInfo) GetMergedPortMap() map[int][]common.NpuDevPortInfo {
  +	merged := make(map[int][]common.NpuDevPortInfo)
  +	for _, diePortMap := range e.devPortMap {
  +		for dieID, ports := range diePortMap { merged[dieID] = ports }
  +	}
  +	return merged
  +}
  ```
  ```diff
  // collector_for_ub_legacy.go(buildLegacyDescMap / buildLegacyDescSlice 各一处)
  -		portIDs, ok := colcommon.NpuDevPortInfos.GetPortMap()[dieID]
  +		portIDs, ok := colcommon.NpuDevPortInfos.GetMergedPortMap()[dieID]
  ```
  </details>

- **各 UB/网络/光模块采集器改为按当前 logicID 取端口**。`collector_for_ub.go`(`probeUbDcmi` 用 `logicIDs[0]`、`collectUbInfo` 用入参 `logicID`)、`collector_for_optical.go`、`collector_for_network.go`、`collector_for_network_link.go` 全部把 `GetPortMap()[dieID]` 替换为 `GetPortMap(logicID)[dieID]`。行为差异:每张卡采集时只看自己那份端口列表(die 0/1),不再误用全局共享映射。另外 `getNpuDevNetPortInfos` 里对 `GetNpuDevNetPortInfo(logicID)` 失败的卡新增 Warn 日志后 `continue`(原来静默跳过)。
  <details><summary>代码依据 metrics/collector_for_ub.go / collector_for_network.go / collector_for_optical.go</summary>

  ```diff
  // collector_for_ub.go probeUbDcmi
  -	portMap := colcommon.NpuDevPortInfos.GetPortMap()
  +	portMap := colcommon.NpuDevPortInfos.GetPortMap(logicIDs[0])
  // collectUbInfo / collectNetworkNpuInfo / collectOpticalNpuInfo / collectNetworkNpuStatusInfo
  -		portIDs, ok := colcommon.NpuDevPortInfos.GetPortMap()[dieID]
  +		portIDs, ok := colcommon.NpuDevPortInfos.GetPortMap(logicID)[dieID]
  ```
  </details>

- **clusterd:上报 ConfigMap 的空切片/空 map 规范化为 `[]`/`{}` 而非 `null`**。`getReportDpuInfo` 原本直接拷贝 `v.DpuInfoCfg`,新增 `normalizeDpuInfoCfg`:把 `DPUInfo.DPUList`、每个 DPU 项的 `FaultList`/`AffectedNPU`、`NodeEvent.FaultList` 的 nil 切片替换为空切片,使序列化进 `cluster-info-dpu-x` CM 时无故障场景显示 `[]` 而非 `null`(提交标题:空切片显示为 null 不符合规范)。交换机侧 `getReportSwitchInfo` 同理把 `FaultTimeAndLevelMap` 的 nil 兜底为空 map。**纯序列化契约修复,不改字段语义**。
  <details><summary>代码依据 clusterd/pkg/domain/dpu/dpu_util.go + switchinfo/switch_util.go</summary>

  ```diff
  +func normalizeDpuInfoCfg(v *constant.DpuInfo) *constant.DpuInfoCfg {
  +	cfg := v.DpuInfoCfg
  +	if cfg.DPUInfo.DPUList == nil { cfg.DPUInfo.DPUList = []constant.DpuItem{} }
  +	for i := range cfg.DPUInfo.DPUList {
  +		if cfg.DPUInfo.DPUList[i].FaultList == nil { cfg.DPUInfo.DPUList[i].FaultList = []constant.DpuFaultDetail{} }
  +		if cfg.DPUInfo.DPUList[i].AffectedNPU == nil { cfg.DPUInfo.DPUList[i].AffectedNPU = []int{} }
  +	}
  +	if cfg.DPUInfo.NodeEvent != nil && cfg.DPUInfo.NodeEvent.FaultList == nil {
  +		cfg.DPUInfo.NodeEvent.FaultList = []constant.DpuFaultDetail{} }
  +	return &cfg
  +}
  ```
  ```diff
  // switch_util.go
  +		faultTimeAndLevelMap := v.FaultTimeAndLevelMap
  +		if faultTimeAndLevelMap == nil { faultTimeAndLevelMap = map[string]constant.FaultTimeAndLevel{} }
  -				FaultTimeAndLevelMap: v.FaultTimeAndLevelMap,
  +				FaultTimeAndLevelMap: faultTimeAndLevelMap,
  ```
  </details>

### 后续发展方向 [AI]
- 证据覆盖 npu-exporter 的 UB/网络/光模块端口采集数据模型与 clusterd 上报 CM 序列化,两条都是**观测/上报数据面的正确性收敛**,非调度/驱动语义变化。npu-exporter 这条揭示昇腾在往**多卡节点每卡独立 UB 端口拓扑**采集靠拢——此前全局单份映射在多卡节点(UB fabric 多机训练)下会串卡,现按 logicID 隔离并保留 legacy 合并视图做兼容。方向指向 UB 超低时延 fabric 监控的细粒度化(与 ub-network-device-plugin 是同一 fabric 主题的监控侧)。未见指标名/label 的 schema 变更(只改了内部映射结构),下游 Prometheus 消费方指标名应无感,但**每卡端口值会从"全节点雷同"变为"各卡实际"**,做告警基线的要留意。
- clusterd 这条属于 CM 契约健壮性(null→[]),对我们产品的启示:昇腾集群态仍以 ConfigMap 承载 DPU/交换机故障信息(`cluster-info-dpu-x`),消费方按 JSON 数组解析,空值规范很重要——做同类基于 CM 的集群态上报时,序列化前统一 nil 兜底可避免下游解析分支膨胀。未见 API/CRD 化迹象,仍是 CM-as-state。

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
<!-- ANCHOR repo=mind-cluster sha=ec7c16088795169038f600732259c57524d672c3 tag=v26.1.1 scanned=2026-09-28 -->
<!-- ANCHOR repo=npu-operator sha=817e8a2372642f0e5b143a0faf1928d30cc12bdf tag=v26.6.0 scanned=2026-09-28 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-28 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-28 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-28 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-28 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-09-28 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-28 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-28 -->
</content>
</invoke>
