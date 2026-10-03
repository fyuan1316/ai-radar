# HAMi diff 雷达 2026-10-04

## 摘要
- 主仓 HAMi 新增 `--report-node-capacity` 能力:device-plugin 可把聚合后的 vGPU 显存/算力(默认 `nvidia.com/gpumem`、`nvidia.com/gpucores`)写进 **Node `.status.capacity` 与 `.allocatable`**,让软切分资源以标准 Node 资源形态被 `kubectl describe node`、原生配额与第三方调度器直接看见(opt-in,默认关闭)。
- HAMi-WebUI 把"算力分配率"的语义从"遇到无法解码的分配就整段隐藏"改为"**保留可测部分并显式标注为下界(lower bound)**",新增 `buildUnknownComputeShareQuery` 统计 WebUI 无法解码(多为昇腾)的分配条数。
- 其余三仓(HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin)本期无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- Project-HAMi/HAMi [新能力] device-plugin 新增把 vGPU 显存/算力上报到 Node capacity/allocatable 的开关,新增 `--report-node-capacity` flag、chart value `devicePlugin.reportNodeCapacity`、`NodeDefaultConfig.ReportNodeCapacity` 配置字段,并给 monitor role 补了 `nodes/status` RBAC。证据:`cmd/device-plugin/nvidia/vgpucfg.go`、`pkg/device/nvidia/device.go`、`charts/hami/templates/device-plugin/monitorrole.yaml` https://github.com/Project-HAMi/HAMi/pull/2874

## Project-HAMi/HAMi: a3107198 -> dc0ff8ea
- 比较: a3107198fb5766bff1a41049f6953239d24909d2 -> dc0ff8ea | ahead=1 | files=12 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/a3107198fb5766bff1a41049f6953239d24909d2...dc0ff8ea68acff7115da80d1a9f5c5b9477f2ecd

### AI 总结重点(源码 diff 为据)
- **新增 `PatchNodeStatusCapacity`:HAMi 第一次直接写 Node 的 `.status.capacity`/`.allocatable`(而非仅打 annotation)。** 该函数用 `MergePatchType` 对 `nodes` 的 `status` 子资源做 patch,把传入的 `ResourceList` 同时填进 capacity 与 allocatable 两个字段。这是软切分资源从"HAMi 私有 annotation 语义"向"标准 Kubernetes Node 资源语义"暴露的一步——写进 capacity 后,`kubectl describe node`、原生 ResourceQuota、以及非 HAMi 的调度器/监控都能直接读到这些虚拟资源量。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  +func PatchNodeStatusCapacity(node *corev1.Node, resources corev1.ResourceList) error {
  +	if len(resources) == 0 {
  +		return nil
  +	}
  +	...
  +	type patchStatusDetails struct {
  +		Capacity    corev1.ResourceList `json:"capacity,omitempty"`
  +		Allocatable corev1.ResourceList `json:"allocatable,omitempty"`
  +	}
  +	p := patchStatusNode{Status: patchStatusDetails{Capacity: resources, Allocatable: resources}}
  +	...
  +	_, err = c.CoreV1().Nodes().
  +		Patch(context.Background(), node.Name, k8stypes.MergePatchType, bytes, metav1.PatchOptions{}, "status")
  ```
  </details>
- **上报内容=当前节点所有 `Health` 设备的 `Devmem`/`Devcore` 之和,资源名可配。** 在 `RegisterInAnnotation` 里,当 `ReportNodeCapacity` 为真时遍历 `*devices` 累加健康设备的显存与核数,写进 `ResourceMemoryName`(缺省 `nvidia.com/gpumem`)和 `ResourceCoreName`(缺省 `nvidia.com/gpucores`)两个资源,再调用上面的 patch。即上报的是"节点可售卖的总虚拟显存/算力",不是单卡粒度。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/register.go</summary>

  ```diff
  +	if plugin.schedulerConfig.ReportNodeCapacity != nil && *plugin.schedulerConfig.ReportNodeCapacity {
  +		var totalMemory int64
  +		var totalCores int64
  +		for _, dev := range *devices {
  +			if dev.Health {
  +				totalMemory += int64(dev.Devmem)
  +				totalCores += int64(dev.Devcore)
  +			}
  +		}
  +		memName := plugin.schedulerConfig.ResourceMemoryName   // 缺省 nvidia.com/gpumem
  +		coreName := plugin.schedulerConfig.ResourceCoreName    // 缺省 nvidia.com/gpucores
  +		resList := corev1.ResourceList{ ... }
  +		if patchErr := util.PatchNodeStatusCapacity(node, resList); patchErr != nil { ... }
  +	}
  ```
  </details>
- **开关走三层优先级:per-node Nodeconfig > chart 默认 > 关闭。** 新增 `resolveReportNodeCapacity(perNode, chartDefault)`:只要 per-node 配置非 nil 就用它,否则回落到 chart 级默认;另外 `LoadNvidiaDevicePluginConfig` 支持用环境变量 `REPORT_NODE_CAPACITY=true/1` 直接打开。注释明确指出 chart 总会显式传 `--report-node-capacity`(true 或 false),所以 chartDefault 在该部署下永不为 nil——没有这层 precedence,per-node override 会被 chart 默认永远盖掉。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  +	if os.Getenv("REPORT_NODE_CAPACITY") == "true" || os.Getenv("REPORT_NODE_CAPACITY") == "1" {
  +		t := true
  +		sConfig.NvidiaConfig.ReportNodeCapacity = &t
  +	}
  +func resolveReportNodeCapacity(perNode, chartDefault *bool) *bool {
  +	if perNode != nil {
  +		return perNode
  +	}
  +	return chartDefault
  +}
  +	sConfig.NvidiaConfig.ReportNodeCapacity = resolveReportNodeCapacity(sConfig.NvidiaConfig.ReportNodeCapacity, chartDefault)
  ```
  </details>
- **配置面三处同步落地:新 CLI flag、新 config 字段、新 chart value + RBAC。** `vgpucfg.go` 加 `--report-node-capacity` BoolFlag(env `REPORT_NODE_CAPACITY`,默认 false);`device.go` 在 `NodeDefaultConfig` 与 `DeviceConfig` 各加 `ReportNodeCapacity *bool`;chart 的 `values.yaml` 加 `devicePlugin.reportNodeCapacity: false`(注释注明"非 NVIDIA 专属,故放在 devicePlugin 顶层而非 devices.<vendor>"),daemonset 模板透传该 flag,`monitorrole.yaml` 的 RBAC 新增 `nodes/status`(写 status 子资源所必需)。
  <details><summary>代码依据 pkg/device/nvidia/device.go · charts/hami/templates/device-plugin/monitorrole.yaml</summary>

  ```diff
  // device.go
   type NodeDefaultConfig struct {
   	EnableNUMATopology *bool `yaml:"enableNumaTopology" json:"enablenumatopology"`
  +	ReportNodeCapacity *bool `yaml:"reportNodeCapacity" json:"reportnodecapacity"`
   }
   type DeviceConfig struct {
  +	ReportNodeCapacity *bool
   }
  // monitorrole.yaml
       resources:
         - nodes
  +      - nodes/status
  ```
  </details>

### 后续发展方向 [AI]
- 这步把 HAMi 的虚拟资源"双轨暴露":既保留原有 annotation/调度扩展路径,又新增标准 Node capacity 路径。方向上利于与原生 ResourceQuota / 第三方调度器 / 监控体系对接(无需懂 HAMi annotation 即可读到总量)。证据只覆盖 device-plugin 上报侧(register/util/config/chart),**未见调度器或 webhook 侧是否会据此 capacity 做二次判定**,也未见删除旧 annotation 路径的迹象——当前是增量叠加而非替换。
- 资源名默认写死 `nvidia.com/gpumem`/`nvidia.com/gpucores`,但注释强调该能力"非 NVIDIA 专属"。证据仅为缺省值与 chart 放置位置的注释,**未见昇腾等其它厂商走此路径的具体接入代码**;是否对 vNPU 生效需看后续 ascend 侧提交。

## Project-HAMi/HAMi-WebUI: 846c0e2d -> cb5acf01
- 比较: 846c0e2d3360cc7240bb61968e4cc7e3cea53443 -> cb5acf01 | ahead=3 | files=29 | Release: v1.3.0
- https://github.com/Project-HAMi/HAMi-WebUI/compare/846c0e2d3360cc7240bb61968e4cc7e3cea53443...cb5acf01c06150b36b9672bdb22f3324c10150fc

### AI 总结重点(源码 diff 为据)
- **算力分配率语义从"遇到无法解码的分配就整段抹掉"反转为"保留可测部分 + 标注为下界"。** 旧 `buildComputeAllocationQueries` 对查询套了 `excludeUnknownComputeAllocations`,用 `unless on () max(hami_container_vcore_allocation_known == 0)` 在出现任何未知分配时**移除整个 scope**,以免把已知子集当成全量;旧注释直言 absent 的 allocated-core series 可能是"昇腾分配 WebUI 无法解码"。新版删掉这层排除,`buildComputeAllocationQueries` 直接返回 `buildAllocationQueries` 结果,改为"求和即下界,从不高估"。
  <details><summary>代码依据 packages/web/projects/vgpu/metrics/query-contract.mjs</summary>

  ```diff
  -export const buildComputeAllocationQueries = (options = {}) => {
  -  const queries = buildAllocationQueries({ ... });
  -  return {
  -    query: excludeUnknownComputeAllocations(queries.query, options),
  -    totalQuery: queries.totalQuery,
  -    percentQuery: excludeUnknownComputeAllocations(queries.percentQuery, options),
  -  };
  -};
  +// ...these sums are a lower bound of what is allocated. They never overstate it...
  +export const buildComputeAllocationQueries = (options = {}) =>
  +  buildAllocationQueries({
  +    allocatedMetric: METRICS.computeAllocated,
  +    capacityMetric: METRICS.computeCapacity,
  +    ...options,
  +  });
  ```
  </details>
- **新增 `buildUnknownComputeShareQuery`:显式 `count` 有多少条分配是 HAMi 没给出算力份额的(`hami_container_vcore_allocation_known == 0`),按 `(container_pod_uuid, device_uuid)` 先 `max` 去掉 exporter 多副本重复计数。** 这把"未知量"从"隐藏"变成"可量化显示",页面据此告诉用户分配率至少漏算了几条。
  <details><summary>代码依据 packages/web/projects/vgpu/metrics/query-contract.mjs</summary>

  ```diff
  +export const buildUnknownComputeShareQuery = ({ selector = '', groupLabel = '' } = {}) => {
  +  validateGroupLabel(groupLabel);
  +  const identity = [...new Set([groupLabel, 'container_pod_uuid', 'device_uuid'].filter(Boolean))].join(', ');
  +  const unknown = `max by (${identity}) (${metricSeries(METRICS.computeAllocationKnown, selector)} == 0)`;
  +  return groupLabel ? `count by (${groupLabel}) (${unknown})` : `count(${unknown})`;
  +};
  ```
  </details>
- **前端新增 `uncounted.mjs` 一组纯函数,把"下界/无法测量"的判定与文案收敛成可测试的小模块。** `readUncounted`(ready→数值、missing→0、loading→undefined、不可读→null)、`isLowerBound`(未知计数 null 或 >0 即视为下界)、`isNothingCounted`(有未知且实测为 0 时不显示具体数字)、`lowerBoundMessage/nothingCountedMessage` 产出 i18n 文案;并新增 `uncounted.test.mjs`(105 行)锁定"刷新失败不得沿用上次计数""一个样本漏算即整条 series 为下界"等语义。Detail.vue/overview 据此在算力卡片加 tooltip 与 `refreshFailedShowingPreviousResult` 提示。
  <details><summary>代码依据 packages/web/projects/vgpu/metrics/uncounted.mjs</summary>

  ```diff
  +export const readUncounted = (status, value) => {
  +  if (status === REQUEST_STATUS.READY) {
  +    const count = Number(value);
  +    return Number.isFinite(count) && count > 0 ? count : 0;
  +  }
  +  if (status === REQUEST_STATUS.MISSING) return 0;
  +  if (status === REQUEST_STATUS.LOADING) return undefined;
  +  return null;
  +};
  +export const isLowerBound = (uncounted) => uncounted === null || uncounted > 0;
  +export const isNothingCounted = (measured, uncounted) => uncounted > 0 && Number(measured) === 0;
  ```
  </details>
- 另有提交 `fix(server): keep a container's device order stable across device types` (#317,改 `server/internal/data/pod.go`、`exporter.go`),本期 patch 节选未覆盖其服务端 hunk,**无代码依据,不展开符号级结论**,仅记在此待后续增量核。`test(release): ...` (#319) 为发布 CI 校验,非运行时能力。 https://github.com/Project-HAMi/HAMi-WebUI/pull/317

### 后续发展方向 [AI]
- WebUI 对"无法解码的分配"(注释明确指向昇腾)的处理策略从"宁可不显示"转向"显示可测下界+量化未知数",是**把多厂商混合纳管下的监控不确定性显式暴露给用户**而非回避。证据覆盖 query 构造 + 前端 uncounted 模块 + 测试,**未见 exporter 端 `hami_container_vcore_allocation_known` 指标是如何为昇腾分配置 0 的源头逻辑**——即"为何无法解码"的根因不在本次 diff 内。
- 结合主仓 #2874 把 vGPU 资源上报 Node capacity,两仓本期都在补"虚拟资源可观测性"的缺口(一个在 API 面暴露总量,一个在监控面标注测量边界),但方向独立、无交叉引用证据。

## 本期无实质改动(折叠)
<details><summary>3 仓本期无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=dc0ff8ea68acff7115da80d1a9f5c5b9477f2ecd branch=master release=v2.10.0 scanned=2026-10-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-04 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-04 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=cb5acf01c06150b36b9672bdb22f3324c10150fc branch=main release=v1.3.0 scanned=2026-10-04 -->
