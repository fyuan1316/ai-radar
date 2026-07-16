# 昇腾算力栈 diff 雷达 2026-07-17

## 摘要
- **npu-exporter 大改指标模型:UB/光模块/网络的 dieId+portId 从"指标名后缀"改为 Prometheus label(`udie`/`port`)**。此前每个 die/port 组合各生成一条独立命名的 Desc(如 `optical_tx_power_0_<dieID>_<portID>`,存于 `[]*prometheus.Desc` 切片),现改为单条 `*prometheus.Desc` + 标签维度。这是对齐 Prometheus 惯例的 schema 收敛,直接影响下游 dashboard/告警的 PromQL 写法。
- **同批引入 legacy 兼容层**:新增 `collector_for_{ub,optical,network}_legacy.go`,由新开关 `colcommon.EnableLegacyMetrics` 门控,继续吐旧的 `_X_Y` 后缀指标,注释明说是"为 Atlas 350 向后兼容,兼容期结束后删除"——即新旧指标并存过渡,给存量监控留迁移窗口。
- **telegraf 上报路径从"同步攒 map 再批量 AddFields"重构为"channel 流式生产/消费"**:`Gather` 起 `consumeAndReport` goroutine + 带缓冲 channel(128),各 collector 的 `UpdateTelegraf` 签名从返回 `map[string]map[string]interface{}` 改为向 `chan<- TelegrafMetric` 推送。vNPU 另修了一处 pod get 未判 err 的 nil 指针 panic。其余 7 仓无实质改动。

## 当日重要改变
- mind-cluster/npu-exporter [API/CRD变更] UB/光模块/网络指标的 dieId、portId 从指标名后缀改为 label(`udie`/`port`),多条 per-port Desc 收敛为单条带标签 Desc;下游 PromQL 需相应调整。 https://gitcode.com/Ascend/mind-cluster/compare/3801f827...30b8dc80
- mind-cluster/npu-exporter [新能力] 新增 `EnableLegacyMetrics` 开关 + `*_legacy.go` 兼容层,过渡期并行输出旧 `_X_Y` 后缀指标(Atlas 350 向后兼容,标注兼容期后移除)。 https://gitcode.com/Ascend/mind-cluster/compare/3801f827...30b8dc80
- mind-cluster/npu-exporter [架构方向] telegraf 上报从同步 map 累积重构为 channel 流式生产/消费,`UpdateTelegraf` 接口签名随之变更。 https://gitcode.com/Ascend/mind-cluster/compare/3801f827...30b8dc80

## mind-cluster: 3801f827 -> 30b8dc80
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/3801f827...30b8dc80 | tag: v26.1.0.beta.2 | commits=28 | truncated=false
- 信号集中在 `component/npu-exporter/`(其余为 docs/dockerfile/devcontainer/CI 噪声,已过滤)

### AI 总结重点(源码 diff 为据)
- **dieId/portId 从指标名后缀改为 label**:新增常量 `ubDieIDLabel="udie"`、`ubPortIDLabel="port"`;UB/光模块/网络三类 collector 里,原来"每个 (dieID, portID) 组合生成一条独立命名 Desc、存入 `[]*prometheus.Desc` 切片"的模型,改为**单条 `*prometheus.Desc`**(端口维度下沉为标签)。以光模块为例,`initNpuOpticalDesc()` 里那段"遍历 dieIDs×portIDs、用 `BuildDescSlice` 拼 `optical_tx_power_0_<dieID>_<portID>` 名字"的循环被整段删除。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_optical.go + collector_for_ub.go</summary>

  ```diff
  + ubDieIDLabel  = "udie"
  + ubPortIDLabel = "port"
  ```
  ```diff
    // Npu specific metrics
  - opticalIndexDesc    []*prometheus.Desc
  - opticalTxPower0Desc []*prometheus.Desc
    ...
  + opticalIndexDesc    *prometheus.Desc
  + opticalTxPower0Desc *prometheus.Desc
  + opticalDescOnce sync.Once
  ```
  ```diff
    func initNpuOpticalDesc() {
  -   // udie only has 0 and 1, fixed order
  -   dieIDs := []int{0, 1}
  -   for _, dieID := range dieIDs {
  -       portIDs, ok := colcommon.NpuDevPortInfos.GetPortMap()[dieID]
  -       ...
  -           colcommon.BuildDescSlice(&opticalTxPower0Desc, fmt.Sprint(api.MetricsPrefix, "optical_tx_power_0_",
  -               strconv.Itoa(dieID), "_", strconv.Itoa(portID)), ...)
  -       ...
  -   }
  ```
  </details>
- **新增 legacy 兼容层,由 `colcommon.EnableLegacyMetrics` 门控**:新增 `collector_for_ub_legacy.go`/`_optical_legacy.go`/`_network_legacy.go`,用 `buildLegacyDescSlice`/`buildLegacyDescMap` 重建旧的带 `_<dieID>_<portID>` 后缀的 Desc,并通过 `tryEmit*LegacyMetric`/`addNetWorkLegacyMetricsDesc` 在开关打开时并行发射。文件头注释明确"legacy metrics with `_X_Y` suffix for Atlas 350 backward compatibility. It will be removed after the compatibility period ends"。即新 label 模型与旧命名模型过渡期共存。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_optical_legacy.go(新增)</summary>

  ```diff
  + // This file contains legacy metrics with _X_Y suffix for Atlas 350 backward compatibility.
  + // It will be removed after the compatibility period ends.
  + func initOpticalLegacyDesc() {
  +     if !colcommon.EnableLegacyMetrics {
  +         return
  +     }
  +     opticalTxPower0LegacyDescs = buildLegacyDescSlice("optical_tx_power_0", "optical tx power lane 0 on ub port")
  +     ...
  + }
  + func addNetWorkLegacyMetricsDesc(ch chan<- *prometheus.Desc) {
  +     if colcommon.EnableLegacyMetrics {
  +         for _, desc := range linkStatusLegacyDescs { ... }
  ```
  </details>
- **telegraf `Gather` 从"同步攒 fieldsMap 再批量 AddFields"改为"channel 流式生产/消费"**:`WatchNPU.Gather` 新建带缓冲 channel(`chanCacheSize=128`)与 `done` 信号,起 goroutine `consumeAndReport(acc, ch, devTagValue)`,主流程对 single/multi/plugin 三条链调 `npu.collectChain(ch, ...)` 推指标、`close(ch)` 后 `<-done`。原先 `fieldsMap map[string]map[string]interface{}` 累积 + 末尾遍历 `acc.AddFields` 的写法被删除;`device`/`vdev_id` tag 提为常量 `deviceTagKey`/`vDevTagKey`,cardType→tag 值的分支抽成 `getDevTagValue()`。
  <details><summary>代码依据 component/npu-exporter/platforms/inputs/npu/npu.go</summary>

  ```diff
  - fieldsMap := make(map[string]map[string]interface{})
  - ...
  - fieldsMap = npu.gatherChain(fieldsMap, single, containerMap, chips)
  - handleGeneralMetrics(acc, fieldsMap, devName, devTagValue)
  - for key, fields := range fieldsMap {
  -     ids := strings.Split(key, "_")
  -     devTag := map[string]string{"device": devTagValue + "-" + ids[0]}
  -     if len(ids) >= num2 { devTag["vdev_id"] = ids[1] }
  -     acc.AddFields(devName, fields, devTag)
  - }
  + devTagValue := getDevTagValue(npu.collector.Dmgr.GetDevType())
  + ch := make(chan common.TelegrafMetric, chanCacheSize)
  + done := make(chan struct{})
  + go func() { consumeAndReport(acc, ch, devTagValue); close(done) }()
  + for _, chain := range [][]common.MetricsCollector{single, multi, plugin} {
  +     npu.collectChain(ch, chain, containerMap, chips)
  + }
  + close(ch)
  + <-done
  ```
  </details>
- **`UpdateTelegraf` 接口签名随流式化改变**:各 collector 的 `UpdateTelegraf` 从"接收并返回 `map[string]map[string]interface{}`"改为"向 `ch chan<- colcommon.TelegrafMetric` 推 `NewDeviceMetric(logicID)`,无返回值";各 Desc 初始化加 `sync.Once`(`networkDescOnce`/`opticalDescOnce`/`ubDescOnce`/`ubCardLabelOnce`)避免重复注册。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_network.go</summary>

  ```diff
  - func (c *NetworkCollector) UpdateTelegraf(fieldsMap map[string]map[string]interface{}, n *colcommon.NpuCollector,
  -     containerMap map[int32]container.DevicesInfo, chips []colcommon.HuaWeiAIChip) map[string]map[string]interface{} {
  + func (c *NetworkCollector) UpdateTelegraf(ch chan<- colcommon.TelegrafMetric, n *colcommon.NpuCollector,
  +     containerMap map[int32]container.DevicesInfo, chips []colcommon.HuaWeiAIChip) {
      ...
  -         fieldMap := getFieldMap(fieldsMap, cache.chip.LogicID)
  -         telegrafUpdateNetInfo(cache, fieldMap)
  +         metric := colcommon.NewDeviceMetric(cache.chip.LogicID)
  +         telegrafUpdateNetInfo(cache, metric.Fields)
  +         ch <- metric
  ```
  </details>

### 后续发展方向 [AI]
- 指标模型这次改动是"面向规模化与标准化"的:把端口维度从名字提到 label,配合 channel 流式上报,方向是**多 die/多 port 的 UB fabric(Atlas 350/910A5 超节点)监控在高基数下的采集与查询效率**。对我们产品的启示——若已接入昇腾 npu-exporter 做 NPU/网络监控,需评估:①升级后旧 `_<die>_<port>` 后缀指标默认是否还在(取决于 `EnableLegacyMetrics` 默认值,本次未见 main.go 该 flag 的默认取值,需在部署侧确认);②dashboard/告警的 PromQL 要从"按指标名匹配端口"迁到"按 `udie`/`port` label 过滤"。证据覆盖 Desc 定义、init、Gather/UpdateTelegraf 三处路径,但 `main.go`(25 行改动,推测是 `EnableLegacyMetrics` flag 接线)与 `consumeAndReport`/`collectChain` 主体的 hunk 未在本次节选内,未逐行验证发射一致性。
- legacy 层带明确"兼容期后删除"注释,说明昇腾把这视为**有时限的迁移过渡**而非长期双写。对齐我们产品时应把握该窗口,避免长期依赖旧命名。证据仅到"开关门控 + 注释声明",未见具体废弃时间表。

## vNPU: 2198069b -> 4bd4002c
- 比较: https://gitcode.com/openFuyao/vNPU/compare/2198069b...4bd4002c | tag: v0.1.0 | commits=2 | truncated=false

### AI 总结重点(源码 diff 为据)
- **修 `PodAllocationTrySuccess` 里 pod get 未判错导致的 nil 指针 panic**:`lock.GetClient()...Pods().Get()` 的 error 原先被 `_` 丢弃,拿到 nil `refreshed` 后直接访问 `.Annotations` 会 panic;现加 `if err != nil { log.Errorf(...); return }` 提前返回。属稳健性修复,不改分配语义。
  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/util/util.go</summary>

  ```diff
  - refreshed, _ := lock.GetClient().CoreV1().Pods(pod.Namespace).Get(context.Background(), pod.Name, metav1.GetOptions{})
  + refreshed, err := lock.GetClient().CoreV1().Pods(pod.Namespace).Get(context.Background(), pod.Name, metav1.GetOptions{})
  + if err != nil {
  +     log.Errorf("PodAllocationTrySuccess: get pod error: %v, pod: %s/%s", err, pod.Namespace, pod.Name)
  +     return
  + }
    annos := refreshed.Annotations[xpu.AssignedIDsToAllocate]
  ```
  </details>

### 后续发展方向 [AI]
- 纯 bugfix,无能力/架构信号。证据仅此一处 util 函数,vNPU 切分主逻辑本期未动。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓(7 仓)</summary>

- openFuyao/npu-operator — 无新提交(HEAD 53299373 未动,tag v26.6.0)
- openFuyao/npu-container-toolkit — 无新提交(HEAD d54256e0 未动,tag v26.6.0)
- openFuyao/npu-driver-installer — 无新提交(HEAD c898c929 未动,tag v26.6.0)
- openFuyao/npu-node-provision — 无新提交(HEAD 717ef777 未动,tag v26.6.0)
- openFuyao/npu-dra-plugin — 无新提交(HEAD 98f8fa5e 未动,tag v26.6.0)
- openFuyao/volcano-ext — 无新提交(HEAD c9be5c4c 未动,tag v1.9.0)
- openFuyao/ub-network-device-plugin — 无新提交(HEAD 263d6387 未动,tag v26.6.0)

另 mind-cluster 区间内还有 infer-operator "修复 role workload 主备场景下优先级调度致非 ready"、clusterd golang 版本回退等提交,但落在 component/ 过滤外或仅 test/CI/docs,未纳入研判。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=30b8dc80b3741bcdea0eed2640e690350e8446cc tag=v26.1.0.beta.2 scanned=2026-07-17 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=npu-driver-installer sha=c898c929187bba8051e2ebed87f609bc820ead68 tag=v26.6.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=vNPU sha=4bd4002cfdb0d8a1786cb2fd9f8cfa583cf4b7c6 tag=v0.1.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-17 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-17 -->
