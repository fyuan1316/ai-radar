# HAMi diff 雷达 2026-08-01

## 摘要
- HAMi 主仓本期 12 提交,主线是**健壮性收口**:调度器 metrics 采集去掉全局单例改注接口 + 对 `Totalmem==0` 的设备不再吐 NaN 显存占比;Enflame profile 转 int32 前补边界校验防溢出回绕。
- **架构方向信号**:`IsPodGroupMember` 除原有 `hami.io/podgroup` label 外,开始识别 K8s v1.36+ 原生 `Pod.Spec.SchedulingGroup.PodGroupName` 字段 —— HAMi 的 gang/coscheduling 判定正往上游原生 SchedulingGroup 对齐(#2206)。
- 昇腾 vNPU 模板改名纠偏:`vir05_1c_8g`→`vir05_1c_16g`、`vir10_3c_16g`→`vir10_3c_32g`(内存值不变,原名与实际显存不符)。HAMi-core/volcano/ascend-device-plugin 三仓本期静默。

## 当日重要改变
- Project-HAMi/HAMi [架构方向] gang 调度判定接入 K8s v1.36+ 原生 `SchedulingGroup` 字段,不再只认 HAMi 自有 podgroup label。证据 `pkg/util/util.go` / PR #2206 https://github.com/Project-HAMi/HAMi/pull/2206
- Project-HAMi/HAMi [新能力/配置] 昇腾 vNPU 切分模板重命名以对齐真实显存(`vir05_1c_8g`→`vir05_1c_16g` 等),影响 vNPU 调度时的内存标定语义。证据 `charts/hami/templates/scheduler/device-configmap.yaml` / PR #2223 https://github.com/Project-HAMi/HAMi/pull/2223

## Project-HAMi/HAMi: 05e6c800 -> c7891ded
- 比较: https://github.com/Project-HAMi/HAMi/compare/05e6c800b41c5544356682ad5b6bf19d8d6fe838...c7891ded87b71e402a36f5f29ae7d245e0de70b2 | ahead=12 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)
- **gang 调度成员判定接入上游原生 SchedulingGroup**:`IsPodGroupMember` 从"仅当 `PodGroupLabel` 非空为真"扩为"label 非空 **或** `pod.Spec.SchedulingGroup.PodGroupName` 非空为真"。这意味着 HAMi 开始承认 K8s v1.36+ 引入的原生 `Pod.Spec.SchedulingGroup` 字段作为 coscheduling 成员依据,而不再只绑自己的 `hami.io/podgroup` 注解。配套 PR #2206 "adopt to gangScheduling feature gates on k8s v1.36+"。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -// Coscheduling PodGroup, based on the presence of the PodGroupLabel.
   func IsPodGroupMember(pod *corev1.Pod) bool {
   	if pod == nil {
   		return false
   	}
  -	return pod.Labels[PodGroupLabel] != ""
  +	if pod.Labels[PodGroupLabel] != "" {
  +		return true
  +	}
  +	if sg := pod.Spec.SchedulingGroup; sg != nil && sg.PodGroupName != nil && *sg.PodGroupName != "" {
  +		return true
  +	}
  +	return false
   }
  ```
  </details>
- **昇腾 vNPU 模板改名纠偏**:device-configmap 里 `vir05_1c_8g`(注释自承"实际给 16GB")直接改名 `vir05_1c_16g`,`vir10_3c_16g`→`vir10_3c_32g`,`memory` 值(16384/32768)与 aiCore/aiCPU 均不变。即模板名此前撒谎、与调度用的真实显存不符,本次让名字回归实义。注意昇腾 runtime 侧模板名若也被约束需同步(旧注释"names ... fixed by Ascend runtime and must not be changed"被删),说明这批名称已确认可改。
  <details><summary>代码依据 charts/hami/templates/scheduler/device-configmap.yaml</summary>

  ```diff
  -          # Template vir05_1c_8g actually provides 16GB memory,
  -          - name: vir05_1c_8g
  +          - name: vir05_1c_16g
             memory: 16384
             aiCore: 5
             aiCPU: 1
  -          # Template vir10_3c_16g actually provides 32GB memory
  -          - name: vir10_3c_16g
  +          - name: vir10_3c_32g
             memory: 32768
             aiCore: 10
             aiCPU: 3
  ```
  </details>
- **调度器 metrics 采集去全局单例、改依赖注入**:`ClusterManagerCollector` 新增 `metricsProvider schedulerMetricsProvider` 接口字段(暴露 `InspectAllNodesUsage/GetQuotaManager/GetPodManager`),`Collect` 里 `sher.InspectAllNodesUsage()` 改为 `cc.metricsProvider.InspectAllNodesUsage()`。从直接引用包级全局 `sher` 转为可注入接口,利于测试与解耦(同期新增 metrics_test.go 120 行)。
  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  +type schedulerMetricsProvider interface {
  +	InspectAllNodesUsage() *map[string]*schedulerpkg.NodeUsage
  +	GetQuotaManager() *device.QuotaManager
  +	GetPodManager() *device.PodManager
  +}
   type ClusterManagerCollector struct {
  -	ClusterManager *ClusterManager
  +	ClusterManager  *ClusterManager
  +	metricsProvider schedulerMetricsProvider
   }
  -	nu := sher.InspectAllNodesUsage()
  +	nu := cc.metricsProvider.InspectAllNodesUsage()
  ```
  </details>
- **显存占比指标防除零/NaN**:`nodeGPUMemoryPercentage` 与 `legacyMemoryPercentage` 两处 `Usedmem/Totalmem` 计算前新增 `if devs.Device.Totalmem > 0` 守卫。此前当设备 `Totalmem` 未知(=0)时会 emit `x/0`(NaN/Inf)污染 Prometheus,现改为该设备直接不吐这条 gauge。PR #2204。
  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  -			ch <- prometheus.MustNewConstMetric(
  -				nodeGPUMemoryPercentage, prometheus.GaugeValue,
  -				float64(devs.Device.Usedmem)/float64(devs.Device.Totalmem), ...)
  +			if devs.Device.Totalmem > 0 {
  +				ch <- prometheus.MustNewConstMetric(
  +					nodeGPUMemoryPercentage, prometheus.GaugeValue,
  +					float64(devs.Device.Usedmem)/float64(devs.Device.Totalmem), ...)
  +			}
  ```
  </details>
- **Enflame profile 转 int32 前补溢出边界**:`Fit` 里把 `int32(profile.Size)`、`int32(profile.MemoryGB*1024)`、`int32(profile.CorePercent)` 的裸转换,改为先判 `>math.MaxInt32`(MemoryGB 判 `>MaxInt32/1024`)则直接 `ModeNotFit` 拒绝,避免大 profile 值转 int32 静默回绕成负数骗过 `<=0` 校验。行为差异:旧代码 `CorePercent<=0` 会兜底置 1,新代码删除该兜底(仅拦上界)。PR #2190。
  <details><summary>代码依据 pkg/device/enflame/device.go</summary>

  ```diff
  -	requiredSlice := int32(profile.Size)
  -	if requiredSlice <= 0 {
  +	if profile.Size <= 0 || profile.Size > math.MaxInt32 {
   		reason[common.ModeNotFit]++
   		return false, tmpDevs, common.GenReason(reason, len(devices))
   	}
  -	profileCorePercent := int32(profile.CorePercent)
  -	if profileCorePercent <= 0 {
  -		profileCorePercent = 1
  +	if profile.CorePercent > math.MaxInt32 {
  +		reason[common.ModeNotFit]++
  +		return false, tmpDevs, common.GenReason(reason, len(devices))
   	}
  +	profileMemoryMiB := int32(profile.MemoryGB * 1024)
  +	profileCorePercent := int32(profile.CorePercent)
  ```
  </details>
- **构建镜像 pin 单一来源化**:`hack/build.sh` 里硬编码的 `GOLANG_IMAGE`/`NVIDIA_IMAGE` 改为从 `version.mk` `sed` 读取,读不到则 exit 1。此前硬编码会与 version.mk 的 digest 钉悄悄漂移。属工程/供应链卫生,非能力面。

### 后续发展方向 [AI]
- gang 调度正双轨兼容:既留 HAMi 自有 `hami.io/podgroup` label,又接 K8s v1.36+ 原生 `SchedulingGroup`。证据只覆盖 `IsPodGroupMember` 这一判定点的 `||` 扩展,**未见**调度器主循环里 SchedulingGroup 的 group 名如何映射到 HAMi coscheduling 队列/nodelock —— 是否只是"识别成员"还是"完整走原生 gang 语义"本次 diff 不足以判定,下期可盯 `pkg/scheduler` 内对 `SchedulingGroup` 的消费点。
- 昇腾 vNPU 侧动作仍是"配置纠偏"而非新切分能力:本次只改模板名与注释,`memory/aiCore/aiCPU` 三元组未动,说明 vNPU 规格集本身稳定。证据仅 configmap,一并留意 ascend-device-plugin 仓是否同步这批新模板名(本期该仓 EMPTY,尚未跟进,存在名称对不齐风险)。

## Project-HAMi/HAMi-WebUI: c59f7769 -> fa9b560d
- 比较: https://github.com/Project-HAMi/HAMi-WebUI/compare/c59f77693238dc2f08b83c42c9e410bca04e81ed...fa9b560dfbe6caba65d5af48151d4ba544c8730f | ahead=2 | Release: hami-webui-1.2.0

### AI 总结重点(源码 diff 为据)
- **多设备节点采集丢设备 bug 修复**:`updateLocalNodes` 内层 `append` 的目标从 `bizNode.Devices`(节点级快照,循环外取的旧值)改为 `n[node.UID].Devices`(map 内实时累加值)。旧代码每次迭代都基于同一份 `bizNode.Devices` 追加,导致同节点多张卡时后一次覆盖前一次、只保留最后一张;修复后按 UID 在 map 里真正累加。影响:WebUI 上多 GPU 节点的设备列表此前会缺卡。
  <details><summary>代码依据 server/internal/data/node.go</summary>

  ```diff
   				for _, device := range devices {
  -					n[node.UID].Devices = append(bizNode.Devices, &biz.DeviceInfo{
  +					n[node.UID].Devices = append(n[node.UID].Devices, &biz.DeviceInfo{
   						Index:    int(device.Index),
  ```
  </details>

## 本期无实质改动(折叠)
<details><summary>3 仓无实质改动</summary>

- Project-HAMi/HAMi-core:无新提交(时分软切分内核本期静默)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交(尚未跟进主仓昇腾 vNPU 模板改名)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=c7891ded87b71e402a36f5f29ae7d245e0de70b2 branch=master release=v2.9.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-08-01 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-08-01 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ffadaa96270de157fbe461be321f7b17c79a16de branch=main release=— scanned=2026-08-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-01 -->
</content>
</invoke>
