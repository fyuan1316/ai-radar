# HAMi diff 雷达 2026-07-17

## 摘要
- **HAMi 主仓**给 vGPU 副本加了 opt-in 的 NUMA 拓扑透传:开 `enableNumaTopology` 后每个 vGPU 副本会带上物理卡的 NUMA node,让 kubelet TopologyManager 能对齐 CPU/GPU NUMA;默认关以保持现有 admission 行为。另修了 scheduler `register()` 读节点缓存的竞态(可能 nil 解引用)。
- **ascend-device-plugin**新增 per-node `filterDevices`(按 UUID/index 排除昇腾卡),并让 `VDeviceCount()` 优先吃 nodeConfig 覆盖值;监控侧改用 `honorLabels` 保住工作负载 namespace/pod 标签。
- HAMi-core / volcano-vgpu-device-plugin / HAMi-WebUI 三仓本期无实质改动。

## 当日重要改变
- Project-HAMi/HAMi [新能力] vGPU 副本可选透传物理卡 NUMA 拓扑(新增 `enableNumaTopology` 配置项 + `NodeDefaultConfig.EnableNUMATopology` 字段),供 TopologyManager 做 CPU/GPU NUMA 对齐 https://github.com/Project-HAMi/HAMi/pull/2065
- Project-HAMi/ascend-device-plugin [新能力] 新增 per-node `filterDevices`(UUID/index 黑名单)排除指定昇腾设备,UpdateDevice/GetIDs 全链路生效 https://github.com/Project-HAMi/ascend-device-plugin/commits/main

## Project-HAMi/HAMi: 3166c1a2 -> 03be4d85
- 比较: 3166c1a23d9821d03769b059a212debf4792b666 -> 03be4d85 | ahead=3 | files=13 | Release: v2.9.0
- 比较页: https://github.com/Project-HAMi/HAMi/compare/3166c1a23d9821d03769b059a212debf4792b666...03be4d85fdab0a3d532a610b5f420c5375551aeb

### AI 总结重点(源码 diff 为据)
- **vGPU 副本 NUMA 拓扑从"永远 nil"改为可选透传物理卡拓扑**:`Devices.GetPluginDevices` 签名加了 `numaTopology bool` 参数;为 true 时把 `dev.Topology`(物理 GPU 的 NUMA 归属)写进每个 vGPU 副本的上报 `Device`,为 false 时仍置 nil。之前无论如何都写死 `Topology: nil`,导致 kubelet TopologyManager 看不到 GPU 的 NUMA 位置、无法与 CPU 对齐。顺带加了 `len(ds)==0` 空设备保护。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/rm/devices.go</summary>

  ```diff
  -func (ds Devices) GetPluginDevices(count uint) []*kubeletdevicepluginv1beta1.Device {
  +func (ds Devices) GetPluginDevices(count uint, numaTopology bool) []*kubeletdevicepluginv1beta1.Device {
   	var res []*kubeletdevicepluginv1beta1.Device
  +	if len(ds) == 0 {
  +		return res
  +	}
   	if !strings.Contains(ds.GetIDs()[0], "MIG") {
   		for _, dev := range ds {
  +			topology := dev.Topology
  +			if !numaTopology {
  +				topology = nil
  +			}
   			for i := uint(0); i < count; i++ {
  -					Topology: nil,
  +					Topology: topology,
  ```
  </details>

- **新增 opt-in 开关 `enableNumaTopology`,默认 false**:`NodeDefaultConfig` 加了 `EnableNUMATopology *bool` 字段(yaml `enableNumaTopology`/json `enablenumatopology`);device-plugin 的 `apiDevices()` 据此把布尔透给上面的 `GetPluginDevices`。指针类型 + 默认 false 明确是为了不破坏 `single-numa-node` 策略下的既有准入行为(注释原话:changes admission behavior when topologyManagerPolicy is single-numa-node)。

  <details><summary>代码依据 pkg/device/nvidia/device.go + plugin/server.go + charts/hami/values.yaml</summary>

  ```diff
  // pkg/device/nvidia/device.go — NodeDefaultConfig
  +	// EnableNUMATopology advertises the physical GPU's NUMA node on each vGPU
  +	// replica so kubelet's TopologyManager can align CPU and GPU NUMA nodes.
  +	EnableNUMATopology *bool `yaml:"enableNumaTopology" json:"enablenumatopology"`

  // plugin/server.go — apiDevices()
  -	return plugin.Devices().GetPluginDevices(*plugin.schedulerConfig.DeviceSplitCount)
  +	numaTopology := plugin.schedulerConfig.EnableNUMATopology != nil && *plugin.schedulerConfig.EnableNUMATopology
  +	return plugin.Devices().GetPluginDevices(*plugin.schedulerConfig.DeviceSplitCount, numaTopology)

  // charts/hami/values.yaml — devicePlugin
  +  enableNumaTopology: false
  ```
  </details>

- **修复 scheduler `register()` 回读节点缓存的竞态**:原代码日志分支里判断 `s.nodes[val.Name] != nil` 并回读 `s.nodes[val.Name].Devices`,与 `onDelNode->rmNode` 并发时 `s.nodes[val.Name]` 可能已被删,存在竞态读/nil 解引用风险。改为直接用本地刚构建好的 `nodeInfo`,不再回读全局 map,并从日志里去掉 `totalDevices` 字段。

  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -			if s.nodes[val.Name] != nil && len(nodeInfo.Devices) > 0 {
  +			// Log the locally built nodeInfo; reading it back from s.nodes raced with onDelNode->rmNode.
  +			if len(nodeInfo.Devices) > 0 {
   				if printedLog[val.Name] {
  -					klog.V(5).InfoS("Node device updated", ..., "totalDevices", s.nodes[val.Name].Devices)
  +					klog.V(5).InfoS("Node device updated", ..., "nodeInfo", nodeInfo)
   				} else {
  -					klog.InfoS("Node device added", ..., "totalDevices", s.nodes[val.Name].Devices)
  +					klog.InfoS("Node device added", ..., "nodeInfo", nodeInfo)
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 软切分正在补齐"拓扑感知"这块短板**:此前 vGPU 副本一律不带 NUMA 信息,拓扑对齐是硬隔离/整卡方案(DRA、MIG)的优势项;这次把物理卡 NUMA 透给 kubelet TopologyManager,意味着 HAMi 想在时分软切分下也能吃到 CPU-GPU NUMA 亲和的性能收益。证据只覆盖"上报 Device 带 Topology + 一个开关",未见调度器侧(scheduler)是否也据 NUMA 做打分/过滤——需盯后续 `pkg/scheduler` 是否出现 NUMA 亲和评分逻辑来闭环。默认关且指针可空说明官方对 `single-numa-node` 策略下的准入副作用仍持谨慎态度。

## Project-HAMi/ascend-device-plugin: f8ae57c3 -> f062939e
- 比较: f8ae57c30dd6e8311815bb3327a2991e34293b1d -> f062939e | ahead=17 | files=25 | Release: —
- 比较页: https://github.com/Project-HAMi/ascend-device-plugin/compare/f8ae57c30dd6e8311815bb3327a2991e34293b1d...f062939e14354a96fb8bfabd3c103d9d8f6de6c2

### AI 总结重点(源码 diff 为据)
- **新增 per-node `filterDevices` 设备黑名单能力**:`internal/vnpu.go` 加了 `FilterDevices{UUID []string, Index []int32}` 结构并挂到 `NodeConfig`,配 `IsEmpty()`/`HasUUID()` 辅助方法。manager 新增 `shouldIgnoreDevice(uuid,index)`/`shouldCheckIgnored()`,在 `UpdateDevice()`(跳过被过滤卡的健康采集)和 `GetIDs()`(从可分配 ID 列表里剔除)两处生效——让运维能按 UUID 或物理 index 在单节点粒度排除特定昇腾卡(如故障卡、留给其他用途的卡)。

  <details><summary>代码依据 internal/vnpu.go + internal/manager/manager.go</summary>

  ```diff
  // internal/vnpu.go
  +type FilterDevices struct {
  +	UUID  []string `json:"uuid,omitempty" yaml:"uuid,omitempty"`
  +	Index []int32  `json:"index,omitempty" yaml:"index,omitempty"`
  +}
  +func (fd FilterDevices) IsEmpty() bool { return len(fd.UUID) == 0 && len(fd.Index) == 0 }
   type NodeConfig struct {
  -	Name         string `json:"name"`
  +	Name          string        `json:"name" yaml:"name"`
  +	FilterDevices FilterDevices `json:"filterDevices,omitempty" yaml:"filterDevices,omitempty"`
   }

  // internal/manager/manager.go — GetIDs() 剔除被过滤卡
  +	availableIDs := make([]int32, 0, len(IDs))
  +	for _, id := range IDs {
  +		...
  +		if !am.shouldIgnoreDevice(uuid, cardID) { availableIDs = append(availableIDs, id) }
  +	}
  +	return availableIDs
  ```
  </details>

- **`VDeviceCount()` 优先吃 per-node override**:原实现只从 `am.config.Templates` 推导 vNPU 数量;现改为先看 `am.nodeConfig.VDeviceCount > 0`,有就直接用,和 `IsHamiVnpuCore()` 的 per-node 覆盖语义对齐。意味着单节点可独立设定切分份数,不再被全局模板集绑死。

  <details><summary>代码依据 internal/manager/manager.go</summary>

  ```diff
   func (am *AscendManager) VDeviceCount() int {
  +	// Prefer the per-node override when present, mirroring IsHamiVnpuCore().
  +	if am.nodeConfig != nil && am.nodeConfig.VDeviceCount > 0 {
  +		return am.nodeConfig.VDeviceCount
  +	}
   	if len(am.config.Templates) == 0 {
   		return 1
  ```
  </details>

- **监控 ServiceMonitor 改用 `honorLabels` 保住工作负载标签**:`ascend-vnpu-monitor-integration.yaml` 去掉了把 `pod→exported_pod`、`namespace→exported_namespace` 改名的 `metricRelabelings`,改为 `honorLabels: true` + 把 device-plugin 自身 pod 名单独 relabel 成 `plugin_pod`。前后差异:之前 Prometheus Operator 会用 device-plugin pod 覆盖 exporter 上报的 namespace/pod(需靠 exported_* 找回真实工作负载),现在直接保留 exporter 原始的工作负载 namespace/pod 标签,监控口径回归到"指标归属真实业务 Pod"。

  <details><summary>代码依据 ascend-vnpu-monitor-integration.yaml</summary>

  ```diff
  +      # honorLabels keeps the exporter's workload namespace/pod (else the Operator overwrites them with the device-plugin pod)
  +      honorLabels: true
         relabelings:
  -      metricRelabelings:
  -        - action: replace
  -          sourceLabels: [pod]
  -          targetLabel: exported_pod
  -        - action: replace
  -          sourceLabels: [namespace]
  -          targetLabel: exported_namespace
  +        - action: replace
  +          sourceLabels: [__meta_kubernetes_pod_name]
  +          targetLabel: plugin_pod
  ```
  </details>

- **HAMi 注册注解序列化改用标准 `json.Marshal`**:`internal/server/register.go` 里把设备上报注解从自定义的 `device.MarshalNodeDevices(apiDevices)` 换成 `json.Marshal(apiDevices)`,统一走标准 JSON 编码(顺带把 `NetworkID` 局部变量改小写、`c.Close()` 显式忽略返回值等 lint 整理)。注意这可能改变注解的 wire 格式,需与 HAMi 主仓消费端保持兼容。

  <details><summary>代码依据 internal/server/register.go</summary>

  ```diff
  +	data, err := json.Marshal(apiDevices)
  +	if err != nil {
  +		return fmt.Errorf("marshal node devices error: %w", err)
  +	}
   	annos := make(map[string]string)
  -	annos[ps.registerAnno] = device.MarshalNodeDevices(apiDevices)
  +	annos[ps.registerAnno] = string(data)
  ```
  </details>

- **新增 910c 系列 vNPU 切分模板**:`ascend-device-configmap.yaml` 给某设备档补了 `vir05_1c_16g`(5 aiCore/1 aiCPU/16G)与 `vir10_3c_32g`(10 aiCore/3 aiCPU/32G)两个切分模板,对应 commit "feat: add 910c template"——扩了昇腾 910c 的软切分规格覆盖。

  <details><summary>代码依据 ascend-device-configmap.yaml</summary>

  ```diff
  +        templates:
  +          - name: vir05_1c_16g
  +            memory: 16384
  +            aiCore: 5
  +            aiCPU: 1
  +          - name: vir10_3c_32g
  +            memory: 32768
  +            aiCore: 10
  +            aiCPU: 3
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾侧在补齐"运维可控性"与主仓对齐两条线**:filterDevices(排除卡)+ per-node VDeviceCount(单节点份数)都是把配置粒度下沉到节点、给运维更多手动干预口子,是软切分走向生产可运维的信号;而 `json.Marshal` 替自定义 marshal、honorLabels 修监控口径,都是与 HAMi 主仓/Prometheus 生态对齐的收敛动作。证据只覆盖 device-plugin 仓自身 diff,未见主仓消费端是否已适配新注解格式——若主仓仍按旧 `MarshalNodeDevices` 解析,存在跨仓兼容风险,需盯 HAMi 主仓 register 解析侧的对应改动。910c 模板落地说明昇腾新档硬件的软切分适配仍在持续跟进,未见对应硬件能力上限说明。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点,无新提交)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release: hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=03be4d85fdab0a3d532a610b5f420c5375551aeb branch=master release=v2.9.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-17 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-17 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f062939e14354a96fb8bfabd3c103d9d8f6de6c2 branch=main release=— scanned=2026-07-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-17 -->
