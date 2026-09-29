# 昇腾算力栈 diff 雷达 2026-09-30

## 摘要
- **mind-cluster / infer-operator 落地推理弹性伸缩(KPA)新能力**:新增集群命名空间级 CRD `PodAutoscaler`(短名 `pa`),按每 Pod 暴露的 Prometheus 指标伸缩 `InstanceSet` 副本;算法是 Knative 风格 KPA——稳态窗口(默认 180s)+ 恐慌窗口(默认 60s)双窗口,恐慌期只增不减(`MaxPanicReplicas` 记高水位)。这是昇腾把推理服务自动扩缩从"外接 K8s HPA"内化进自研 infer-operator 的信号,对标 KServe/Knative 的 pod autoscaler。
- **故障处置策略微调**:故障码 `80E21008` 从"需重启 NPU(RestartNPU)"下调为"免重启恢复(FreeRestartNPU)",device-plugin 的 `faultCode.json` 与 container-manager 的默认码表同步改;另有 grpc→v1.83.2 / containerd→v1.7.36 的 CVE 修复(CVE-2026-84304、CVE-2026-53493)。
- **两个调度/可靠性修复**:ascend-for-volcano 修 chip8node8sp 超节点选点 bug(误自增 superPod 下标致跨超节点错选);clusterd 静默故障检测配置补齐上下界校验与默认值。npu-operator 本期纯文档(补齐 architecture/reconcile/crd-reference 三篇设计文档 + CHANGELOG,后者剧透 26.9.0 将上 vNPU/DRA/组件冲突检测)。其余 7 个 openFuyao 仓无新提交。

## 当日重要改变
- mind-cluster [新能力][API/CRD变更] infer-operator 新增 `PodAutoscaler` CRD + KPA 弹性伸缩控制器,对 `InstanceSet` 做指标驱动扩缩。证据见下。https://gitcode.com/Ascend/mind-cluster/compare/145617f3510414bdd72091132d6d713ce1782bac...721f79b617a1ff64729e1146b2fb165ffa691a00
- mind-cluster [故障策略] 故障码 `80E21008` 由 RestartNPU 降级为 FreeRestartNPU(免重启恢复),减少一类故障对训练作业的中断代价。device-plugin faultCode.json + container-manager 码表双改。
- mind-cluster [安全] 升级 grpc v1.83.2、containerd v1.7.36 修复 CVE-2026-84304 与 CVE-2026-53493(go.mod/go.sum,依赖 bump,未涉逻辑)。
- mind-cluster [bugfix] ascend-for-volcano chip8node8sp 超节点选点循环误自增 `superPodIndex`,删除该自增修复跨超节点错选。证据见下。
- mind-cluster [配置硬化] clusterd 静默故障检测配置补齐上界(MaxSilentTaskCards/MaxConsecutiveTimes/MaxWindowSeconds 等)与一批默认值,并把 0→48h 的兜底从读取处移到加载期归一化。证据见下。
- npu-operator [文档/架构] 补齐三篇设计文档 + CHANGELOG/CONTRIBUTING,**纯文档无代码逻辑**;CHANGELOG 剧透 26.9.0(Unreleased):新增 vNPU/DRA 组件与配置段、组件冲突检测。https://gitcode.com/openFuyao/npu-operator

## mind-cluster: 145617f3 -> 721f79b6
- 比较: 145617f3..721f79b6 | tag: v26.1.1 | commits=24 | truncated=false
- 源: https://gitcode.com/Ascend/mind-cluster/compare/145617f3510414bdd72091132d6d713ce1782bac...721f79b617a1ff64729e1146b2fb165ffa691a00

### AI 总结重点(源码 diff 为据)

- **新增 `PodAutoscaler` CRD(group `mindcluster.huawei.com`,namespaced,短名 `pa`),伸缩目标是 `InstanceSet`,指标源是每 Pod 暴露的 Prometheus 端点**。Spec 关键字段:`scaleTargetRef`(指向 InstanceSet)、`minReplicas`(默认 1)、`maxReplicas`(必填)、`metricsSources`(每条含 name/value/port/path,至少 1 条)、`scalingStrategy`(枚举仅 `KPA`,预留算法扩展点)、`stableWindowSeconds`/`panicWindowSeconds`。infer-operator RBAC 同步加了 podautoscalers 的 get/list/watch 及 status patch。
  <details><summary>代码依据 component/infer-operator/pkg/api/v1/podautoscaler_types.go + build/infer-operator.yaml</summary>

  ```diff
  +// ScalingStrategyKPA identifies the Knative-style pod autoscaling algorithm.
  +const ScalingStrategyKPA = "KPA"
  +type PodAutoscalerSpec struct {
  +	ScaleTargetRef ScaleTargetRef `json:"scaleTargetRef"`
  +	MinReplicas int32 `json:"minReplicas,omitempty"`   // +kubebuilder:default=1
  +	MaxReplicas int32 `json:"maxReplicas"`
  +	// +kubebuilder:validation:Enum=KPA  +kubebuilder:default=KPA
  +	ScalingStrategy string `json:"scalingStrategy,omitempty"`
  +	MetricsSources []MetricSource `json:"metricsSources"`   // +MinItems=1
  +	StableWindowSeconds *int32 `json:"stableWindowSeconds,omitempty"`
  +	PanicWindowSeconds  *int32 `json:"panicWindowSeconds,omitempty"`
  +}
  ```
  ```diff
  -    resources: [ "inferservicesets", "inferservices", "instancesets" ]
  +    resources: [ "inferservicesets", "inferservices", "instancesets", "podautoscalers" ]
  +  name: podautoscalers.mindcluster.huawei.com   # 新增 CRD,scope: Namespaced, shortNames: [pa]
  ```
  </details>

- **KPA 算法是 Knative 风格的"稳态/恐慌"双窗口,恐慌期只增不减**。`inPanic := panicValue >= targetValue*PanicThreshold` 触发恐慌模式,取 panic 窗口观测值算目标副本;`desiredReplicas` 按 观测值/目标值 比例算原始副本(带 ScaleUp/ScaleDownTolerance 死区),再过 `applyRateLimits`(MaxScaleUpRate/MaxScaleDownRate)限速,最后 `constrain` 到 [min,max]。恐慌期用 `MaxPanicReplicas` 记高水位——只允许升不允许降,退出恐慌才清零。
  <details><summary>代码依据 component/infer-operator/pkg/autoscaling/algorithm/kpa.go</summary>

  ```diff
  +	inPanic := panicValue >= targetValue*request.Policy.PanicThreshold
  +	observed := stableValue; mode := "stable"
  +	if inPanic { observed = panicValue; mode = "panic" }
  +	rawDesired := desiredReplicas(request.CurrentReplicas, observed, targetValue,
  +		request.Policy.ScaleUpTolerance, request.Policy.ScaleDownTolerance)
  +	rateLimited := applyRateLimits(request.CurrentReplicas, rawDesired,
  +		request.Policy.MaxScaleUpRate, request.Policy.MaxScaleDownRate)
  +	desired := rateLimited
  +	if inPanic {
  +		if desired < request.RuntimeState.MaxPanicReplicas { desired = request.RuntimeState.MaxPanicReplicas
  +		} else { request.RuntimeState.MaxPanicReplicas = desired }
  +	} else { request.RuntimeState.MaxPanicReplicas = 0 }
  ```
  </details>

- **指标聚合走 bucket 化时间窗口 `TimeWindow`**:按 granularity 分桶存值、按 duration 滑动淘汰过期桶,`Avg()` 给稳态/恐慌均值。稳态窗口默认 180s、恐慌窗口默认 60s(`defaultStableWindow`/`defaultPanicWindow`)。控制器侧 `runtimeStateStore` 按 namespace/name 存每个 PA 的运行态(evaluation + 近期 recommendation 列表 + configSignature),`stabilize` 做建议平滑。
  <details><summary>代码依据 component/infer-operator/pkg/autoscaling/types/window.go</summary>

  ```diff
  +func (window *TimeWindow) Record(timestamp time.Time, value float64) {
  +	bucket := timestamp.UnixNano() / int64(window.granularity)
  +	window.buckets[bucket] = value
  +	cutoff := timestamp.Add(-window.duration).UnixNano() / int64(window.granularity)
  +	for key := range window.buckets { if key < cutoff { delete(window.buckets, key) } }
  +	... // 重排 values 供 Avg()
  +}
  ```
  </details>

- **故障码 `80E21008` 从 RestartNPU 迁到 FreeRestartNPUCodes**:该码此前在需整卡重启的码表里,现改为免重启恢复级。device-plugin 的构建期码表 `faultCode.json` 与 container-manager 的运行期默认码表 `defaultFreeRestartNPUCodes`/`defaultRestartNPUCodes` 两处同步改,保证发布件与运行默认一致。
  <details><summary>代码依据 component/ascend-device-plugin/build/faultCode.json + component/container-manager/pkg/fault/domain/config.go</summary>

  ```diff
     "FreeRestartNPUCodes":[
  -    "80AD8009","81CB8003","81CB8009"
  +    "80AD8009","81CB8003","81CB8009","80E21008"
     ],
     "RestartNPUCodes":[
  -    "80E18000","80E21008","80C98001","80E58005",...
  +    "80E18000","80C98001","80E58005",...
  ```
  </details>

- **ascend-for-volcano chip8node8sp 超节点选点 bug 修复**:`selectNodesFromSuperPods` 循环里多了一句 `superPodIndex++`,使得每选一个未就绪虚拟 Pod 就跳到下一个超节点,导致本应集中在同一超节点内选点的逻辑跨超节点乱选。删除该自增即修复。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8sp/frame.go</summary>

  ```diff
   		superPods[superPodIndex] = tp.selectNodesFromSuperPod(
   			unReadyVirtualPodIDs[*remainingToSelect-1], superPods[superPodIndex], selectNodesMap)
   		*remainingToSelect--
  -		superPodIndex++
   	}
  ```
  </details>

- **clusterd 静默故障检测配置硬化**:新增一批上界常量(`MaxSilentTaskCards=1e7`、`MaxConsecutiveTimes=10000`、`MaxHwWindowSeconds=24h`、`MaxWindowSeconds=365d`、`MaxFaultFreeSeconds=365d`)与默认值(`DefaultMinTaskCards=16`、`DefaultConsecutiveTimes=3`、`DefaultHwWindowSeconds=30`、`DefaultWindowSeconds=10800`即3h、`DefaultFaultFreeSeconds=48h`);把原先在读取处 `0→48h` 的兜底删掉,改为在配置加载期归一化(`GetSilentReleaseSeconds` 不再内联判 0)。等于给静默故障策略补了完整取值域校验。
  <details><summary>代码依据 component/clusterd/pkg/domain/conf/config.go</summary>

  ```diff
  +	DefaultMinTaskCards = 16
  +	DefaultConsecutiveTimes = 3
  +	DefaultWindowSeconds = 10800
  +	DefaultFaultFreeSeconds = 48 * 60 * 60
  +	MaxSilentTaskCards = 10000000
  +	MaxWindowSeconds = 365 * 24 * 60 * 60
  -// GetSilentReleaseSeconds ... 0 means default 48 hours
  +// ... normalized to a default ... during config loading, so 0 is never stored here.
   func GetSilentReleaseSeconds() int64 {
  -	if second == 0 { return DefaultSilentReleaseSeconds }
  -	return int64(second)
  +	return int64(config.SilentFaultPolicy.Release.FaultFreeSecond)
   }
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾正把推理服务的**弹性伸缩内化进自研 infer-operator**:此前 InstanceSet 只能定副本或靠外部 HPA,现引入 KPA(Knative 风格)双窗口算法直接扩缩 InstanceSet。证据只覆盖 KPA 一种策略(`scalingStrategy` 枚举当前仅 KPA,但字段留了扩展点),恐慌阈值/rate-limit/tolerance 等 Policy 参数在本次 hunk 未见其默认取值来源(EvaluationContext.Refresh 未展开),未确认这些是 CRD 可配还是硬编码。这是昇腾对标 KServe/Knative pod autoscaler 的关键一步,我方若做昇腾推理平台需评估是接其 PodAutoscaler 还是继续走 K8s HPA/KEDA。
- 故障处置在做**分级精细化**:把 80E21008 从"整卡重启"降到"免重启恢复"是把可软恢复的故障从重代价路径挪走,减少训练中断——趋势是按故障码维护三级(FreeRestart/Restart/其他)可恢复性表。证据仅一个码的迁移,未见批量重分级。
- 对我们产品的启示:(1) 昇腾把故障码可恢复性做成**发布件码表 + 运行期默认双份**并保持同步,我方做多厂商故障自愈时应对齐这种"数据驱动、码表可下发"的设计而非硬编码 switch;(2) clusterd 这次给静默故障检测补全上下界+默认值,说明其静默故障(算力悄悄劣化)检测在走向生产可配,值得跟踪其检测算法(DetectInterval=60s、consecutive/window 参数)后续是否开放给用户调参。

## 本期无实质改动(折叠)
<details><summary>npu-operator 纯文档 + 7 个 openFuyao 仓无新提交</summary>

- npu-operator (v26.6.0) — 仅新增 design 文档/CHANGELOG/CONTRIBUTING,无代码逻辑变更(锚点推进)
- npu-container-toolkit (v26.6.0) — 无新提交
- npu-driver-installer (v26.6.0) — 无新提交
- vNPU (v0.1.0) — 无新提交
- npu-node-provision (v26.6.0) — 无新提交
- npu-dra-plugin (v26.6.0) — 无新提交
- volcano-ext (v1.9.0) — 无新提交
- ub-network-device-plugin (1.0.2) — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=721f79b617a1ff64729e1146b2fb165ffa691a00 tag=v26.1.1 scanned=2026-09-30 -->
<!-- ANCHOR repo=npu-operator sha=c806e3c8e0ef6a8a271293497d08fdf848dd0e1a tag=v26.6.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-30 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-30 -->
</content>
</invoke>
