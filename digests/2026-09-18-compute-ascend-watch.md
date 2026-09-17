# 昇腾算力栈 diff 雷达 2026-09-18

## 摘要
- mind-cluster 本期一次落三件事:**npu-exporter 把 network 大组拆成 network_bandwidth(实时带宽,60s)+ network_link(链路状态,600s)并弃用旧 NetworkCollector**;**ascend-for-volcano 给 ParseChipTopology 加 base-device-info 剪枝(Prune),用物理实存卡清理 stale 的 npu.topology,防止陈旧拓扑超额准入**;ascend-docker-runtime 去掉 UB 场景默认挂载 `/etc/hccl_rootinfo.json`。
- 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期全部无新提交。

## 当日重要改变
- mind-cluster [弃用/移除] npu-exporter `NetworkCollector` 标 Deprecated,采集拆为 bandwidth/link 两个独立并行 collector,监控指标分组重构。https://gitcode.com/Ascend/mind-cluster/compare/062c438225f78a31264784488a1f121b2a65f88f...a8e1df68db7c990575c805b7ff7084c4b4496a7c
- mind-cluster [调度正确性] ascend-for-volcano 新增 `ChipNode.Prune` + `pruneChipTopology`,以 base-device-infos 实存卡集合修剪拓扑树,无幸存叶子则清空 ChipTopo(fail-closed),堵住"拓扑声明卡数 > 节点实际卡数"导致的超额调度。https://gitcode.com/Ascend/mind-cluster
- mind-cluster [行为变更] ascend-docker-runtime 从 UB 挂载清单删除 `/etc/hccl_rootinfo.json` 默认挂载项。同上 compare 链接

## mind-cluster: 062c4382 -> a8e1df68
- 比较: 062c4382..a8e1df68 | tag: v26.1.1 | commits=24 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/062c438225f78a31264784488a1f121b2a65f88f...a8e1df68db7c990575c805b7ff7084c4b4496a7c

### AI 总结重点(源码 diff 为据)

- **npu-exporter:network 采集组一分为二,老 collector 进入弃用期。** 新增两个文件 `collector_for_network_bandwidth.go`(262 行)和 `collector_for_network_link.go`(292 行),各自实现独立 `NetworkBandwidthCollector` / `NetworkLinkCollector`,均 `IsParallel=true`(强制并行 goroutine 采集)且 `DcmiSupported=false`(走 hccn 而非 dcmi)。旧 `NetworkCollector` 加 `Deprecated:` 注释。注册表 `candidateCollectors` 同时挂进新旧三者,默认配置里 `network` 组被注释为 deprecated、由 `network_bandwidth`(60s)与 `network_link`(600s)取代,`optical` 采集间隔从 60s 放宽到 600s(新增 `intervalSeconds600` 常量)。
  <details><summary>代码依据 collector/config/metrics_config.go + metricConfiguration.json</summary>

  ```diff
  +		groupNetworkBandwidth: &metrics.NetworkBandwidthCollector{},
  +		groupNetworkLink:      &metrics.NetworkLinkCollector{},
  ...
  +	intervalSeconds600     = 600
  ...
  -		buildDefaultConfig(groupOptical, stateOn, defaultIntervalSeconds),
  -		buildDefaultConfig(groupNetwork, stateOn, defaultIntervalSeconds),
  +		buildDefaultConfig(groupOptical, stateOn, intervalSeconds600),
  +		// network group is deprecated, replaced by network_bandwidth and network_link
  +		buildDefaultConfig(groupNetworkBandwidth, stateOn, defaultIntervalSeconds),
  ```
  ```diff
  -  {"metricsGroup": "optical", "state": "ON", "intervalSeconds": 60},
  -  {"metricsGroup": "network", "state": "ON", "intervalSeconds": 60},
  +  {"metricsGroup": "optical", "state": "ON", "intervalSeconds": 600},
  +  {"metricsGroup": "network_bandwidth", "state": "ON", "intervalSeconds": 60},
  +  {"metricsGroup": "network_link", "state": "ON", "intervalSeconds": 600},
  ```
  ```diff
  +// NetworkCollector collects the network info
  +// Deprecated: use NetworkBandwidthCollector and NetworkLinkCollector instead.
   type NetworkCollector struct {
  ```
  </details>
  设计取向:把"高频变化的带宽指标"与"低频变化的链路状态指标"按不同采集周期解耦,降低 hccn 查询压力;这与提交里 "Atlas 950 SuperPoD Flex 光模块指标" 是一条线——大规模 fabric 下监控项精细化。

- **ascend-for-volcano:ParseChipTopology 拆函数 + 引入拓扑剪枝,防陈旧拓扑超额准入。** 原来一个大函数被拆成 `topologyRaw` / `pruneChipTopology` / `buildChipPods` / `parseDeviceHealthAnnotations` / `buildOwners`。核心新增逻辑:`realChipIDsFromBaseDeviceInfo()` 解析 `huawei.com/npu.base-device-infos` 注解拿到节点物理实存卡 id 集合,再用 `ChipNode.Prune(exist)` 递归重建只保留实存叶子的拓扑树;若无叶子幸存则 `ChipTopo=nil` 直接返回(fail-closed,不给该节点排任何 NPU 任务)。Prune 保留 branch 结构与 `Raw` 字段,使 ParseChipTopology 里的 Raw-equality 缓存继续生效。
  <details><summary>代码依据 plugin/node.go + chip/topo/chipnode.go</summary>

  ```diff
  +	if !n.pruneChipTopology(raw) {
  +		return
  +	}
  ...
  +func (n *NPUNode) pruneChipTopology(raw string) bool {
  +	exist := n.realChipIDsFromBaseDeviceInfo()
  +	if len(exist) == 0 { return true }
  +	pruned := n.ChipTopo.Prune(exist)
  +	if pruned == nil {
  +		n.ChipTopo = nil
  +		return false
  +	}
  +	n.ChipTopo = pruned
  +	return true
  +}
  ```
  ```diff
  +// Prune rebuilds a tree containing only the leaves whose chip id is present in exist ...
  +func (n *ChipNode) Prune(exist map[int]struct{}) *ChipNode {
  +	if len(n.children) == 0 {
  +		if _, ok := exist[n.chipID]; !ok { return nil }
  +		return &ChipNode{chipID: n.chipID, total: 1}
  +	}
  +	pruned := &ChipNode{Raw: n.Raw}
  +	for _, c := range n.children {
  +		if kept := c.Prune(exist); kept != nil {
  +			pruned.children = append(pruned.children, kept)
  +			pruned.total += kept.total
  +		}
  +	}
  +	if len(pruned.children) == 0 { return nil }
  +	return pruned
  +}
  ```
  </details>
  对应提交 "根据 base-device-info 清理 npu.topology 中不存在的卡 id" 与 "huawei.com/npu.topology 与节点实际芯片数量不一致情况说明"——把注解声明的拓扑当"可疑输入",以设备清单为准做交叉校验,是一处准入安全加固而非新功能。

- **ascend-for-volcano:调度校验日志暴露"参数面网络不健康容忍度"决策项。** `CheckNodeNPUByTask` 的 debug 日志新增打印 `allowNetUnhealthy=<tp.ParameterPlaneUnhealthyTolerance>`,紧邻 `root.Fit(...)` 调用。说明 chipHandler 已带 `ParameterPlaneUnhealthyTolerance` 字段并参与 Fit 决策(本 diff 只暴露日志,未见字段定义 hunk)。
  <details><summary>代码依据 chip/chip.go</summary>

  ```diff
  -	klog.V(...).Infof("%s CheckNodeNPUByTask task<%s> node<%s> req<%d> mode<%v> chips[%s]",
  -		tp.GetPluginName(), task.Name, node.Name, reqNum, tp.ScheduleMode, root.State())
  +	klog.V(...).Infof("%s CheckNodeNPUByTask ... mode<%v> allowNetUnhealthy<%v> chips[%s]",
  +		..., tp.ScheduleMode, tp.ParameterPlaneUnhealthyTolerance, root.State())
  ```
  </details>

- **ascend-docker-runtime:UB 场景默认不再挂载 hccl_rootinfo.json。** `addUBMount` 的挂载清单删去 `hcclRootInfo`(`/etc/hccl_rootinfo.json`),常量本身也删除,只保留 `topoDirPath`(`/usr/local/Ascend/driver/topo`)。对应提交 "删除默认挂载 hccl_rootinfo.json 逻辑"。
  <details><summary>代码依据 ascend-docker-runtime/hook/process/process.go</summary>

  ```diff
  -	hcclRootInfo           = "/etc/hccl_rootinfo.json"
  ...
   	ubMountItems := []string{
  -		hcclRootInfo,
   		topoDirPath,
   	}
  ```
  </details>
  含义:HCCL rootinfo(建链引导信息)不再由 runtime 默认注入容器,改由上层(作业/framework)自行提供;减少 runtime 对固定宿主机文件的隐式依赖。

### 后续发展方向 [AI]
- 监控侧走"按指标性质分频采集"路线(带宽高频、链路/光模块低频),后续新增卡型(Atlas 950 SuperPoD Flex / Ascend910A5 分支已在 Describe 里分叉)大概率继续按此模板加 collector。证据只覆盖 network/optical 两组的拆分与调频,未见其它组同步改造。
- 调度侧本期是"信任但校验"注解的加固(Prune + 参数面网络不健康容忍),方向是把 stale/不一致的节点状态挡在准入前;`ParameterPlaneUnhealthyTolerance` 值得下期跟——它决定参数面网络不健康时是否仍可调度。证据只见其日志暴露,未见字段定义与 Fit 内消费逻辑。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=a8e1df68db7c990575c805b7ff7084c4b4496a7c tag=v26.1.1 scanned=2026-09-18 -->
<!-- ANCHOR repo=npu-operator sha=802e269728d3528e7864b4d8c04a915c12d1169b tag=v26.6.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-18 -->
