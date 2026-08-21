# 昇腾算力栈 diff 雷达 2026-08-22

## 摘要
- npu-exporter 重构采集并发模型:`MetricsCollector` 接口方法 `SupportDcmi` 改名为 `IsParallel` 且语义反转,新增 dcmi 单次调用耗时探测(阈值 10ms),按实测耗时而非静态"是否支持 dcmi"决定单协程/多协程采集——采集调度从能力驱动转向性能驱动。
- ascend-device-plugin 加固故障码配置加载:configmap 拉取失败时区分 `IsNotFound`(降级读本地文件)与其他 API 错误(保持现有配置不覆盖),并给本地文件加载加去重哨兵 + 全部成功才置位,避免瞬时 API 抖动清空故障配置。
- noded 修 CVE-2026-46600;仓内另见"ascend dra 插件"提交(patch 未落入本次 component 信号文件,仅提交级可见)。openFuyao 全部 8 仓本日无新提交。

## 当日重要改变
- mind-cluster [API/接口变更] npu-exporter 的 `MetricsCollector` 接口方法 `SupportDcmi(*NpuCollector) bool` 重命名为 `IsParallel(*NpuCollector) bool` 且默认值/语义反转,所有 collector 实现同步改写。 https://gitcode.com/Ascend/mind-cluster/commit/22bb3d987bc0208c3eb7395e222b661276133c58
- mind-cluster [新能力] npu-exporter 新增 dcmi 接口耗时探测,`DcmiProbeLatencyThreshold = 10 * time.Millisecond`,慢调用自动切多协程采集。 https://gitcode.com/Ascend/mind-cluster/commit/22bb3d987bc0208c3eb7395e222b661276133c58
- mind-cluster [安全] noded 处理 CVE-2026-46600(证据仅到提交标题级,本次 component 信号文件未含其 patch)。 https://gitcode.com/Ascend/mind-cluster/commits

## mind-cluster: 98533d14 -> 22bb3d98
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/98533d14f12746d39a27efb40549fbbc44d98a59...22bb3d987bc0208c3eb7395e222b661276133c58 | tag: v26.1.0 | commits=16 | truncated=false

### AI 总结重点(源码 diff 为据)

- **npu-exporter 采集并发模型从"dcmi 是否支持"改为"实测耗时"驱动**。接口方法 `SupportDcmi` → `IsParallel`,语义反转:旧模型 `SupportDcmi=true` 的 collector 进 `singleGoroutineMap`(dcmi 快,单协程);新模型 `IsParallel=true` 的进 `multiGoroutineMap`。适配器基类默认值也从 `SupportDcmi=true`(默认单协程)翻成 `IsParallel=false`(默认单协程,语义对齐但表达反向)。分类逻辑 `classifyCollectors` 相应把 if/else 两支对调。

  <details><summary>代码依据 component/npu-exporter/collector/common/metrics_collector.go + config/metrics_config.go</summary>

  ```diff
  - // SupportDcmi reports whether this collector can collect via dcmi instead of hccn_tool.
  - SupportDcmi(*NpuCollector) bool
  + // IsParallel reports whether this collector should run in parallel goroutines.
  + // Base returns false (single goroutine). Collectors with slow operations override to return true.
  + IsParallel(*NpuCollector) bool

  - // SupportDcmi default true; multi chain collectors override to probe dcmi.
  - func (c *MetricsCollectorAdapter) SupportDcmi(*NpuCollector) bool { return true }
  + // IsParallel default false; collectors with slow operations override to return true.
  + func (c *MetricsCollectorAdapter) IsParallel(*NpuCollector) bool { return false }

  # classifyCollectors 两支对调:
  -   if c.SupportDcmi(n) { singleGoroutineMap[name] = c } else { multiGoroutineMap[name] = c }
  +   if c.IsParallel(n)  { multiGoroutineMap[name] = c  } else { singleGoroutineMap[name] = c }
  ```
  </details>

- **UbCollector 新增 dcmi 耗时探测,慢于 10ms 即切多协程**。`probeUbDcmi` 返回值从 `bool` 扩展为 `(bool, time.Duration)`,`IsParallel` 判据为「dcmi 不支持(回退到更慢的 HCCN shell 命令)**或** 单次调用耗时 > `DcmiProbeLatencyThreshold`(10ms)」。删除旧的 `SupportDcmi` 与 `isDcmiFuncMissingErr` 辅助函数,错误路径改为直接日志 + 返回实测 elapsed。新增常量 `DcmiProbeLatencyThreshold = 10 * time.Millisecond`。

  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_ub.go + common/constants.go</summary>

  ```diff
  + // IsParallel probes dcmi and measures latency. Returns true (parallel) if:
  + // - dcmi is not supported (falls back to slow HCCN shell commands), or
  + // - dcmi is supported but single call latency > 10ms (too slow for single goroutine).
  + func (c *UbCollector) IsParallel(n *colcommon.NpuCollector) bool {
  +   supported, elapsed := probeUbDcmi(n)
  +   c.DcmiSupported = supported
  +   parallel := !c.DcmiSupported || elapsed > colcommon.DcmiProbeLatencyThreshold
  +   return parallel
  + }
  - func probeUbDcmi(n *colcommon.NpuCollector) bool {
  + func probeUbDcmi(n *colcommon.NpuCollector) (bool, time.Duration) {
  +   start := time.Now()
  +   _, err := n.Dmgr.GetPortPktStatsInfo(logicIDs[0], int32(udie), int32(ports[0].PortID))
  +   elapsed := time.Since(start)

  + // DcmiProbeLatencyThreshold if a single dcmi call exceeds this, use parallel goroutines.
  + DcmiProbeLatencyThreshold = 10 * time.Millisecond
  ```
  </details>

- **Roce/Optical/Network 三个 collector 恒定走多协程**。旧代码里它们 `SupportDcmi` 恒返 false(即当时就已走多协程链,但注释是"等 dcmi 接口就绪再探测");新代码直接改成 `IsParallel` 恒返 true,行为等价但表达从"暂不支持 dcmi"转为"明确声明需要并行"。

  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_roce.go(optical/network 同构)</summary>

  ```diff
  - // SupportDcmi returns false for now; will probe dcmi once the interface is ready.
  - func (c *RoceCollector) SupportDcmi(n *colcommon.NpuCollector) bool {
  -   c.DcmiSupported = false
  -   return c.DcmiSupported
  + // IsParallel returns true so RoceCollector always runs in parallel goroutines.
  + func (c *RoceCollector) IsParallel(n *colcommon.NpuCollector) bool {
  +   c.DcmiSupported = false
  +   return true
  ```
  </details>

- **ascend-device-plugin 故障码配置加载加固**。`loadFaultCode` 拉 configmap 失败时,旧逻辑不分错误类型一律 `initFaultInfoFromFile()` 降级读本地;新逻辑用 `apierrors.IsNotFound` 区分:configmap 确实不存在→降级读本地(Info 级),其他 API 错误(如超时/权限)→保持当前配置不动、只记 Warn,避免瞬时 API 故障把已加载的故障码清空。`initFaultInfoFromFile` 增加去重哨兵 `faultConfigLocalVersion = "local file"`:已成功加载过则直接 return;并用 `loadFailed` 标志确保**所有**故障码文件(含 910A3 交换机故障码)全部加载成功才置位 `resourceVersion`,任一失败则不置位以便后续 configmap 建好时重载。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager.go</summary>

  ```diff
  - hwlog.RunLog.Debugf("cannot find '%s' configmap, reason: %v", common.FaultCodeCMName, err)
  - initFaultInfoFromFile()
  + if apierrors.IsNotFound(err) {
  +   hwlog.RunLog.Infof("configmap '%s' not found, fallback to local fault config", common.FaultCodeCMName)
  +   initFaultInfoFromFile()
  + } else {
  +   hwlog.RunLog.Warnf("cannot access '%s' configmap, keep current config, reason: %v", common.FaultCodeCMName, err)
  + }

  func initFaultInfoFromFile() {
  +   if resourceVersion == faultConfigLocalVersion { return }   // 已加载过则跳过
  +   loadFailed := false
      ... // 各 LoadXxxFromFile 失败时置 loadFailed=true 而非直接 return
  +   if !loadFailed { resourceVersion = faultConfigLocalVersion }  // 全部成功才置位
  }
  ```
  </details>

### 后续发展方向 [AI]
- npu-exporter 这轮把采集调度的判据从"硬件是否支持 dcmi"迁到"单次调用实测耗时",本质是为 310P 等 dcmi 初始化慢/回退 HCCN shell 的场景做自适应并发——配合本区间那条"修复 310P openeuler 镜像 dcmi 初始化失败"提交,方向是提升异构/老卡环境下监控采集的鲁棒性与吞吐。证据只覆盖 Ub/Roce/Optical/Network 四类 collector 的 IsParallel 改写与阈值常量,未见调度器实际按 map 分发协程的执行侧改动(不在本次信号文件)。
- ascend-device-plugin 的故障配置改动指向"控制面(configmap)不可用时不牺牲已有故障感知"的可用性目标,IsNotFound 与其他错误分流是典型的生产加固。证据只覆盖 manager.go 的 loadFaultCode/initFaultInfoFromFile,未展开 configmap 频率故障级别(fault_code.go)的具体解析改动。
- 本区间提交标题另有"ascend dra 插件""nodeD CVE-2026-46600",但其 patch 未落入本次 component/ 前缀的信号文件(可能改在非 component 路径或被 vendor/generated 过滤),仅提交级可见,方向判断需下期或看源链接确认。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo(仅保锚点)</summary>

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
<!-- ANCHOR repo=mind-cluster sha=22bb3d987bc0208c3eb7395e222b661276133c58 tag=v26.1.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b33edd6dc28f0dc96f908ee7de414af931bb8fe1 tag=v26.6.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-22 -->
