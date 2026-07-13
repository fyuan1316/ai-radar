# HAMi diff 雷达 2026-07-14

## 摘要
- HAMi 主仓落地**模板节点模拟打分**(`buildTransientNodeInfo` + `NodeUsage.NodeInfo`),调度器可对尚未注册进缓存的"虚拟节点"做设备契合度打分——为 cluster-autoscaler 扩容前置模拟铺路。
- HAMi 重构**节点握手状态机**:注册时不再打 `Deleted_<ts>` 注解并等 60s 恢复,改为直接 merge-patch 删除注解(`RemoveNodeAnnotation`),`CheckHealth` 里整段"Deleted 恢复"逻辑被删,握手状态从三态收敛回两态。
- ascend-device-plugin 给 Helm chart 加了**可选 vNPU Prometheus 监控栈**(Service + ServiceMonitor + PrometheusRule,默认关),昇腾 vNPU 侧的可观测性开始产品化。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 调度器支持对未注册的模板/瞬态节点打分,支撑扩容模拟 filtering(#2046) https://github.com/Project-HAMi/HAMi/pull/2046
- Project-HAMi/HAMi [弃用/移除] 移除节点 `Deleted_<ts>` 握手注解与其 stale 恢复逻辑,注册时直接删注解(#2052)https://github.com/Project-HAMi/HAMi/pull/2052
- Project-HAMi/ascend-device-plugin [新能力] Helm chart 新增 vNPU 监控集成资源(Service/ServiceMonitor/PrometheusRule) https://github.com/Project-HAMi/ascend-device-plugin/commit/678ae765c803cc00ed7b893647ee775acfb174c7

## Project-HAMi/HAMi: 1dc4fb71 -> a1b418c7
- 比较: 1dc4fb716e7c93689b32946b97234e0ae1973f1f -> a1b418c7 | ahead=9 | files=36 | Release: v2.9.0
- 比较页: https://github.com/Project-HAMi/HAMi/compare/1dc4fb716e7c93689b32946b97234e0ae1973f1f...a1b418c7a439948e3e22192a397e1716ceecff34

### AI 总结重点(源码 diff 为据)
- **调度器新增"瞬态节点"路径,可对未注册进缓存的节点打分。** 新函数 `buildTransientNodeInfo(node)` 直接从 `corev1.Node` 现场枚举各 vendor 的 `GetNodeDevices`,组装出 `NodeInfo`(无设备则返回 `node unregistered`);配套 `buildNodeUsage` 把它转成打分用的 `NodeUsage`。这条路径让调度不再强依赖 informer 缓存里已注册的节点,是"模板节点模拟 filtering"(#2046)的地基。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +func buildTransientNodeInfo(node *corev1.Node) (*device.NodeInfo, error) {
  +	nodeInfo := &device.NodeInfo{ID: node.Name, Node: node.DeepCopy(), Devices: make(map[string][]device.DeviceInfo)}
  +	for _, devInstance := range device.GetDevices() {
  +		nodedevices, err := devInstance.GetNodeDevices(*node)
  +		if err != nil || len(nodedevices) == 0 { continue }
  +		for _, deviceInfo := range nodedevices {
  +			nodeInfo.Devices[deviceInfo.DeviceVendor] = append(nodeInfo.Devices[deviceInfo.DeviceVendor], *deviceInfo)
  +		}
  +	}
  +	if len(nodeInfo.Devices) == 0 { return nil, fmt.Errorf("node unregistered") }
  +	return nodeInfo, nil
  +}
  ```
  </details>
- **`NodeUsage` 结构体新增 `NodeInfo *device.NodeInfo` 字段,`calcScore` 优先用它、缓存缺失才回退 `s.GetNode`。** 之前打分强制 `s.GetNode(nodeID)`,节点不在缓存就直接 `errCh <- err` 退出;现在 `nodeInfo := node.NodeInfo`,为 nil 才走 GetNode。这正是瞬态/模板节点能进入打分循环的关键——它们不在缓存里也不会报错中断。
  <details><summary>代码依据 pkg/scheduler/nodes.go + score.go</summary>

  ```diff
   type NodeUsage struct {
  -	Node    *corev1.Node
  -	Devices policy.DeviceUsageList
  +	Node     *corev1.Node
  +	NodeInfo *device.NodeInfo
  +	Devices  policy.DeviceUsageList
   }
  ```
  ```diff
  -			nodeInfo, err := s.GetNode(nodeID)
  -			if err != nil { klog.ErrorS(err, ...); errCh <- err; return }
  +			nodeInfo := node.NodeInfo
  +			if nodeInfo == nil {
  +				var err error
  +				nodeInfo, err = s.GetNode(nodeID)
  +				if err != nil { klog.ErrorS(err, ...); errCh <- err; return }
  +			}
  ```
  </details>
- **`calcScore` 拆出带开关的 `calcScoreWithOptions(..., recordEvents, detailedFailureReason)`。** 老 `calcScore` 变成 `calcScoreWithOptions(..., true, false)` 的薄封装。`recordEvents=false` 时跳过"0 节点可调度"的失败事件上报;`detailedFailureReason=true` 时把 `failedNodes[nodeID]` 写成具体 reason 而非笼统 `NodeUnfitPod`。模拟打分场景不该污染真实调度事件,这个开关就是为它准备的。
  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
  +func (s *Scheduler) calcScore(...) (*policy.NodeScoreList, error) {
  +	return s.calcScoreWithOptions(nodes, resourceReqs, task, failedNodes, true, false)
  +}
  +func (s *Scheduler) calcScoreWithOptions(..., recordEvents bool, detailedFailureReason bool) (...) {
  ...
  +				if detailedFailureReason { failedNodes[nodeID] = reason }
  ...
  -	if len(res.NodeList) == 0 {
  +	if recordEvents && len(res.NodeList) == 0 {
  ```
  </details>
- **注册时的节点握手从"标记 Deleted_ 时间戳 + 60s 内恢复"简化为"直接删注解"。** `MarkAnnotationsToDelete` 原本 `PatchNodeAnnotations(devType="Deleted_"+now)`,现在改调新增的 `RemoveNodeAnnotation(n, devType)`——用 JSON merge-patch 把注解值置 nil 真正删除。同时 `CheckHealth` 里整段 `strings.Contains(handshake, "Deleted")` 的 stale 恢复分支(解析时间戳、超 60s 则重置为 Requesting_)被删掉。握手状态机从 Requesting/Deleted/Success 三态收敛,去掉了易出错的时间戳恢复路径。
  <details><summary>代码依据 pkg/util/util.go + pkg/device/devices.go</summary>

  ```diff
   func MarkAnnotationsToDelete(devType string, nn string) error {
  -	tmppat := make(map[string]string)
  -	tmppat[devType] = "Deleted_" + time.Now().Format(time.DateTime)
   	n, err := GetNode(nn)
  -	return PatchNodeAnnotations(n, tmppat)
  +	return RemoveNodeAnnotation(n, devType)
   }
  +func RemoveNodeAnnotation(node *corev1.Node, annotationKeys ...string) error {
  +	annos := make(map[string]any, len(annotationKeys))
  +	for _, key := range annotationKeys { annos[key] = nil }
  +	patch := map[string]any{"metadata": map[string]any{"annotations": annos}}
  +	... c.CoreV1().Nodes().Patch(ctx, node.Name, k8stypes.MergePatchType, bytes, ...)
  ```
  ```diff
  -	} else if strings.Contains(handshake, "Deleted") {
  -		... 解析 Deleted_<ts>,超 60s 则重置为 Requesting_<now> 并 (true,true)
  -	}
  ```
  </details>
- **各 vendor 的 use/nouse 卡型匹配逻辑归一到 `device.CheckType`,空注解视为无约束。** hygon 的 `checkDCUtype` 从 30 行手写 InUse/NoUse 逗号拆分匹配,收敛成一行 `device.CheckType(annos, cardtype, DCUInUse, DCUNoUse)`。配合 #2045,空的 use/nouse gpuuuid 注解不再被当成"匹配失败",而是当无约束放行。
  <details><summary>代码依据 pkg/device/hygon/device.go</summary>

  ```diff
   func checkDCUtype(annos map[string]string, cardtype string) bool {
  -	if inuse, ok := annos[DCUInUse]; ok { ... 逗号拆分 + ToUpper Contains ... }
  -	if nouse, ok := annos[DCUNoUse]; ok { ... }
  -	return true
  +	return device.CheckType(annos, cardtype, DCUInUse, DCUNoUse)
   }
  ```
  </details>
- **修复 `ListPodsInfo` 数据竞争:返回深拷贝。** 新增 `DeviceInfo.DeepCopy()`(对 `MIGTemplate`/`CustomInfo`/`DevicePairScore.Scores` 逐一 clone)与 `DeepCopyDeviceInfos([]DeviceInfo)`;`nodes.go` 里原来的浅 `copy()` 改用它。之前多协程共享同一 DeviceInfo 切片会 race(#2055)。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
  +func (d DeviceInfo) DeepCopy() DeviceInfo {
  +	dup := d
  +	if d.MIGTemplate != nil { dup.MIGTemplate = make([]Geometry, len(d.MIGTemplate)); for i, g := range d.MIGTemplate { dup.MIGTemplate[i] = slices.Clone(g) } }
  +	if d.CustomInfo != nil { dup.CustomInfo = maps.Clone(d.CustomInfo) }
  +	if d.DevicePairScore.Scores != nil { dup.DevicePairScore.Scores = maps.Clone(d.DevicePairScore.Scores) }
  +	return dup
  +}
  ```
  </details>
- **清理死代码。** 删除 `cmd/device-plugin/nvidia/watchers.go`(`newFSWatcher`/`newOSWatcher` 已无引用);`cmd/vGPUmonitor/feedback.go` 删掉 `setcGgroupDriver`/`getUsedGPUPid`/`cgroupDriver` 变量(#2060)。纯瘦身,无行为变化。
  <details><summary>代码依据 cmd/vGPUmonitor/feedback.go</summary>

  ```diff
  -var cgroupDriver int
  -func setcGgroupDriver() int { ... 读 /hostvar/lib/kubelet/config.yaml 判 systemd/cgroupfs ... }
  -func getUsedGPUPid() ([]uint, nvml.Return) { ... }
  ```
  </details>

### 后续发展方向 [AI]
- 模拟打分三件套(`buildTransientNodeInfo` + `NodeUsage.NodeInfo` + `calcScoreWithOptions` 的 recordEvents/detailedFailureReason 开关)拼在一起,方向明确指向**扩容前置模拟**:对尚不存在或未注册的"模板节点"做一次静默(不发事件)、带详细失败原因的设备契合度打分。证据只覆盖调度器内部数据结构与打分入口,未见调用方(是否接了 cluster-autoscaler/Karpenter 的 template node、以及模拟结果如何回传)——需跟 #2046 的上层 caller 才能确认落地形态。
- 握手状态机去掉 Deleted 时间戳恢复,是往**幂等、少状态**收敛:register 直接删注解而非留时间戳靠超时清理。证据只覆盖 `MarkAnnotationsToDelete`/`CheckHealth` 两处,未逐一核对所有 vendor 是否都走同一注册路径。

## Project-HAMi/ascend-device-plugin: fce6ed64 -> 678ae765
- 比较: fce6ed645c14ae8eac21582acff59edba5d8933a -> 678ae765 | ahead=2 | files=3 | Release: —
- 比较页: https://github.com/Project-HAMi/ascend-device-plugin/compare/fce6ed645c14ae8eac21582acff59edba5d8933a...678ae765c803cc00ed7b893647ee775acfb174c7

### AI 总结重点(源码 diff 为据)
- **Helm chart 新增可选 vNPU 监控集成模板(默认关闭)。** 新文件 `vnpu-monitor-integration.yaml` 由 `vnpuMonitor.enabled` 门控,一次生成三类资源:headless `Service`(9395/monitorport)、`ServiceMonitor`(Prometheus Operator,15s 抓取、按 node 打标、把 pod/namespace relabel 成 exported_*)、`PrometheusRule`(recording rules,如 `kantaloupe_gpu_mem_used`)。`values.yaml` 补齐 `vnpuMonitor` 配置块,ServiceMonitor/PrometheusRule 默认 create=true 但依赖已装 Prometheus Operator CRD。
  <details><summary>代码依据 charts/ascend-device-plugin/values.yaml</summary>

  ```diff
  +vnpuMonitor:
  +  enabled: false
  +  service:
  +    name: hami-ascend-device-plugin-metrics
  +  serviceMonitor:
  +    create: true
  +    name: hami-ascend-vnpu-monitor
  +    namespace: monitoring
  +    interval: 15s
  +    path: /metrics
  +  prometheusRule:
  +    create: true
  +    groupName: ascend-vnpu
  +    interval: 15s
  ```
  </details>
  <details><summary>代码依据 charts/ascend-device-plugin/templates/vnpu-monitor-integration.yaml</summary>

  ```diff
  +{{- if .Values.vnpuMonitor.enabled }}
  +kind: Service        # clusterIP: None, port 9395 monitorport
  +{{- if .Values.vnpuMonitor.serviceMonitor.create }}
  +kind: ServiceMonitor # monitoring.coreos.com/v1, endpoints port monitorport, relabel node/exported_pod/exported_namespace
  +{{- if .Values.vnpuMonitor.prometheusRule.create }}
  +kind: PrometheusRule # groups: ascend-vnpu, record: kantaloupe_gpu_mem_used
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 vNPU 的可观测性开始"开箱即用化":从裸暴露 metrics 端口,进到 chart 直接生成 ServiceMonitor + 录制规则。recording rule 沿用 `kantaloupe_*` 命名,暗示指标口径向 Kantaloupe/WebUI 生态对齐,便于同一套面板消费 GPU 与 vNPU。证据只覆盖 chart 模板,未见 device-plugin 侧实际 export 的 metric 名单是否已含这些 recording rule 的原始序列——需看 vnpu-monitor 容器的 /metrics 输出才能确认闭环。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo(仅锚点,无正文)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=a1b418c7a439948e3e22192a397e1716ceecff34 branch=master release=v2.9.0 scanned=2026-07-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-14 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-14 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=678ae765c803cc00ed7b893647ee775acfb174c7 branch=main release=— scanned=2026-07-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-14 -->
