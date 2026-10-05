# HAMi diff 雷达 2026-10-06

## 摘要
- HAMi 主仓:remote-gpu(Lupine)server 选择由"只看首容器请求"改为"按 Pod 内每个容器请求逐一校验",调度结果不再依赖容器列表顺序——承接昨日"一 Pod 一 server"约束的正确性补课。
- HAMi-WebUI:把所有指标图表收敛到单一 `MetricChart.vue` 组件 + `chart-presets.mjs` 预设,删掉各视图里重复的 `config.js`/`getOptions.js`;另修"未配置加速卡混入分配率""概览工作负载计数"等口径 bug。
- 当日无 API/CRD/proposal 路径命中,无弃用/移除,无版本跨档;HAMi-core / volcano-vgpu / ascend-device-plugin 三仓无新提交。

## 当日重要改变
- 无(未命中弃用、API/CRD、架构方向、版本跨档、新顶层 package 等信号)。本期改动均为既有能力的正确性修复与前端重构。

## Project-HAMi/HAMi: 43a8cffb -> 717f0164
- 比较: 43a8cffb -> 717f0164 | ahead=1 | files=3 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/pull/3166

### AI 总结重点(源码 diff 为据)
- `RemoteGPUDevices.Fit` 原来给 `tryFit` 只传当前容器的 `request` 来挑 Lupine server;现在当无 prior 提交记录时,先调新函数 `podRequests(pod)` 取出 Pod 内**所有**容器的请求,作为 `requirements` 一并传入,server 候选必须同时满足每个容器的请求才算 fit。效果:首容器选定的 server 不会被后续 init/sidecar/app 容器的请求推翻,选择结果与容器列表顺序无关。
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
     prior, committed := committedAllocation(allocated)
  +  requirements := []device.ContainerDeviceRequest{request}
     if prior != "" {
       servers = []string{prior}
  +  } else if podRequests, err := dev.podRequests(pod); err != nil {
  +    return false, map[string]device.ContainerDevices{}, err.Error()
  +  } else if len(podRequests) > 0 {
  +    // The first container chooses the endpoint for the whole pod. Qualify
  +    // candidates against each container's request independently ...
  +    requirements = podRequests
     }
  -  fit, tmpDevs, reason := dev.tryFit(byServer, servers, request, pod, committed)
  +  fit, tmpDevs, reason := dev.tryFit(byServer, servers, request, requirements, pod, committed)
  ```
  </details>
- 新增 `podRequests(pod)`:遍历 `pod.Spec.InitContainers` + `pod.Spec.Containers`,对每个容器调 `GenerateResourceRequests`,仅收集 `Nums>0` 的请求(原生 sidecar 在 InitContainers 里,故两个列表都走)。`tryFit` 签名随之在 `request` 与 `pod` 之间插入 `requirements []device.ContainerDeviceRequest` 形参。
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
  +func (dev *RemoteGPUDevices) podRequests(pod *corev1.Pod) ([]device.ContainerDeviceRequest, error) {
  +  if pod == nil { return nil, nil }
  +  requests := make([]device.ContainerDeviceRequest, 0, len(pod.Spec.InitContainers)+len(pod.Spec.Containers))
  +  add := func(ctr *corev1.Container) error {
  +    request, err := dev.GenerateResourceRequests(ctr)
  +    if err != nil { return err }
  +    if request.Nums > 0 { requests = append(requests, request) }
  +    return nil
  +  }
  +  // ... range InitContainers 再 range Containers ...
  +}
  -func (dev *RemoteGPUDevices) tryFit(..., request device.ContainerDeviceRequest, pod *corev1.Pod, ...)
  +func (dev *RemoteGPUDevices) tryFit(..., request device.ContainerDeviceRequest, requirements []device.ContainerDeviceRequest, pod *corev1.Pod, ...)
  ```
  </details>
- `Fit` 现允许 `pod` 为 nil:nil 时 `podRequests` 返回空,退回只校验当前容器请求。测试里 `TestFit_ConfinesAllocationToOneServer` 改为显式传 nil pod 验证该退路;原 `TestRemoteGPU_MultiContainerRejectsOtherServerFallback` 被重写为 `TestRemoteGPU_ServerSelectionIsContainerOrderIndependent`,用两种容器顺序断言都选中 gpu-b。
  <details><summary>代码依据 pkg/device/remotegpu/device_test.go</summary>

  ```diff
  -  fit, _, reason := dev.Fit(devices, request(2, 0), &corev1.Pod{}, nil, nil)
  +  // Fit can be called without pod metadata; in that case it falls back to
  +  // validating the current container request.
  +  fit, _, reason := dev.Fit(devices, request(2, 0), nil, nil, nil)
  ```
  </details>

### 后续发展方向 [AI]
- remote-gpu(Lupine)这条"远程 GPU 池化/解耦"路径在连续两日打磨多容器调度正确性:昨日锁"一 Pod 固定一 server",今日补"server 选择要满足 Pod 内全部容器且与顺序无关"。方向是把远程 GPU 池从单容器场景做到可承载 init/sidecar/多容器工作负载。证据只覆盖 `Fit/tryFit/podRequests` 的候选筛选逻辑,未见端点注入侧(仍是每容器单一 `LUPINE_SERVER` 端点)放开多端点的改动——该约束仍是能力上界。

## Project-HAMi/HAMi-WebUI: 4263a44d -> c8c6e808
- 比较: 4263a44d -> c8c6e808 | ahead=4 | files=36 | Release: v1.3.0
- https://github.com/Project-HAMi/HAMi-WebUI/pull/314 · https://github.com/Project-HAMi/HAMi-WebUI/pull/320 · https://github.com/Project-HAMi/HAMi-WebUI/pull/321 · https://github.com/Project-HAMi/HAMi-WebUI/pull/322

### AI 总结重点(源码 diff 为据)
- 图表渲染架构收敛:新增单一组件 `MetricChart.vue`(统一管理 loading/ready/error 状态、刷新遮罩——`blocking` 时拦住 hover 与 zoom,延迟 `UPDATING_DELAY_MS=250ms` 才显示刷新指示器,快刷不闪),并新增 `metrics/chart-presets.mjs` 提供 `buildTimeSeriesOptions`/`buildDonutOptions` 预设。各视图里手写的 ECharts option 被成批删除。
  <details><summary>代码依据 packages/web/projects/vgpu/components/MetricChart.vue(新增 +185)</summary>

  ```diff
  +const UPDATING_DELAY_MS = 250;
  +const blocking = computed(() => props.refreshing && !isLoading.value);
  +// Over the previous chart while it refreshes: blocks hover and zoom at once, shows itself after a delay.
  ```
  </details>
- 重复代码清除:`card/admin/Detail.vue` 手搓的两块 `getRangeOptions([...])` 趋势图(含 `#5B8FF9`/`#42C090` 硬编码色、`VChart` 内联 option)被删(+90/-187);`monitor/overview/getOptions.js` 从内联 `CARD_PIE_COLORS` 常量数组 + 完整 pie option 改为调 `buildDonutOptions` + `categoricalColor(index)`(该文件 -189);`components/config.js`(-152)、`node/admin/getOptions.js`(-109)、`card/admin/getOptions.js`(-77)整文件删除。
  <details><summary>代码依据 packages/web/projects/vgpu/views/monitor/overview/getOptions.js</summary>

  ```diff
  -import { buildRangeDataZoom, buildRangeLineSeries, formatRangeTooltipValue, normalizeRangeValues } from '../../../metrics/range-vector-state.mjs';
  +import { buildDonutOptions } from '../../../metrics/chart-presets.mjs';
  +import { categoricalColor } from '../../../metrics/chart-colors.mjs';
  -const CARD_PIE_COLORS = ['#76B900','#9FCB98','#F59E0B','#4F8F87','#14B8A6','#6B7280'];
       itemStyle: {
  -      color: CARD_PIE_COLORS[index % CARD_PIE_COLORS.length],
  +      color: categoricalColor(index),
       },
  ```
  </details>
- 口径修复三则(提交标题 + 文件落点为据,未逐行读 hunk):#321 "keep unconfigured accelerators out of allocation rates" 把未配置的加速卡从分配率统计里剔除;#322 "count overview workloads from the workload list total" 概览工作负载数改为取工作负载列表的 total;#320 节点资源卡片按可用宽度自适应。
  <details><summary>代码依据(提交标题)</summary>

  ```
  fix(web): keep unconfigured accelerators out of allocation rates (#321)
  fix(web): count overview workloads from the workload list total (#322)
  fix(web): adapt node resource cards to available width (#320)
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 在做工程债收敛(单组件 + 预设集中),是控制台走向可维护/可商业化成熟度的信号,而非功能面扩张;同期三处修复集中在"监控口径正确性"(分配率、工作负载计数)。证据只覆盖 vgpu 监控/概览前端,未见后端 API 或新纳管能力改动。标题类修复(#320/#321/#322)的 hunk 未逐行展开,行为细节以 PR 为准。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=717f016405f93337d6f5caa25434f20069419272 branch=master release=v2.10.0 scanned=2026-10-06 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-06 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-06 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-06 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c8c6e8086ee2bf76592ba7926ee032a129cc1216 branch=main release=v1.3.0 scanned=2026-10-06 -->
</content>
</invoke>
