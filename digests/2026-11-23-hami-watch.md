# HAMi diff 雷达 2026-11-23

## 摘要
- 当日只有 HAMi 主仓动了 1 个提交(#3505),HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓零新提交。无严格信号命中:无 API/CRD 改动、无 proposal/design 改动、无新增顶层 package、Release 仍停在 v2.11.0。
- 调度器可观测性补上"零值序列":新增 `allocationFailureReasons`(phase→failure_reason 白名单)与 `SchedulerOutcomeMetrics.InitDeviceType()`,在 `scheduler.register()` 里对**节点上真实存在的每种设备厂商**预先 `Add(0)` 出 13 条 counter 序列 + 1 条 duration 直方图。此前序列只在首次自增时才出现,`rate()` 必然漏掉第一次事件,`timeout` 这类稀有 reason 每次重启后会从 SLI 里消失。
- 这是 SLI 提案 #3376 "metric changes" 清单的收尾项之一;代码里刻意留了口子——`hami_scheduler_bind_rollbacks_total` 和 refit 路径的 `conflict` reason **不做零值播种**,首次自增盲区在这两处仍存在。

## 当日重要改变
- 无。本期改动全部落在 `pkg/metrics/` 与 `pkg/scheduler/`,未命中 `[弃用/移除]`(无 deprecate/remove/drop 提交、无删字段删 flag)、`[API/CRD变更]`(helper 的 API/CRD/proposal 路径探测返回"无命中")、`[架构方向]`(无 docs/proposals、无 /design/、无新增或删除顶层 package)、`[版本跨档]`(v2.11.0 未变)、`[新能力]`(仅在已有 `pkg/metrics` 包内加方法,未新增包或子目录)。

## Project-HAMi/HAMi: e5eff95e -> 7e92d065
- 比较: e5eff95e47111c9a2ba7ac83ea792a66cba5b5e9 -> 7e92d065 | ahead=1 | files=4 | Release: v2.11.0(未变)
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/e5eff95e47111c9a2ba7ac83ea792a66cba5b5e9...7e92d065eca7f9248bc908aa160adad775d337a8
- 唯一实质提交: `feat(metrics): start allocation outcome counters at 0` — https://github.com/Project-HAMi/HAMi/pull/3505
- 4 个改动文件里 2 个是单测(`pkg/scheduler/scheduler_test.go` +46、`pkg/metrics/scheduler_test.go` +34),生产代码只有 +20/-0,patch 节选完整未截断。

### AI 总结重点(源码 diff 为据)
- **新增包级变量 `allocationFailureReasons`,第一次把"哪个 phase 能报哪些 failure_reason"固化成数据结构**(`pkg/metrics/scheduler.go`)。此前 phase 与 reason 的配对只隐含在各调用点的 `ObserveAllocationFailure(...)` 实参里,没有任何地方枚举全集。新 map 给出三档:`filter` → `no_fit`/`internal`/`annotation_patch`,`bind` → `lookup`/`identity`/`lock`/`annotation_patch`/`bind`,`allocate` → `device_plugin`/`timeout`。值得注意的是已存在的常量 `FailureReasonConflict`(`"conflict"`)**没有**进这张表——它只由 `pkg/scheduler/numa_refit_handler.go` 的 refit 路径发出,因此被排除在播种范围外。提交: https://github.com/Project-HAMi/HAMi/pull/3505
  <details><summary>代码依据 pkg/metrics/scheduler.go</summary>

  ```diff
   	FailureReasonTimeout         SchedulerFailureReason = "timeout"
   )
   
  +// allocationFailureReasons lists the failure reasons each allocation phase can report.
  +var allocationFailureReasons = map[string][]SchedulerFailureReason{
  +	"filter":   {FailureReasonNoFit, FailureReasonInternal, FailureReasonAnnotationPatch},
  +	"bind":     {FailureReasonLookup, FailureReasonIdentity, FailureReasonLock, FailureReasonAnnotationPatch, FailureReasonBind},
  +	"allocate": {FailureReasonDevicePlugin, FailureReasonTimeout},
  +}
  +
   // newSchedulerCounter creates an outcome counter with the shared label contract.
  ```
  </details>
- **新增方法 `(*SchedulerOutcomeMetrics).InitDeviceType(deviceType string)`,按设备类型一次性播种 14 条序列**。遍历上面的 map:每个 phase 对 `allocations` 播一条 `failure_reason="none"` 的成功序列(3 条),再对该 phase 的每个 reason 对 `allocationFailures` 播一条(3+5+2=10 条),最后用 `allocationDuration.WithLabelValues(deviceType)` 把该设备类型的 duration 直方图实例化出来。counter 用 `Add(0)` 而非 `Inc()`,所以对已存在的序列是幂等无副作用的——这点很关键,因为调用点在周期性的 register 循环里。**行为差:**改动前 `/metrics` 里一条序列只在首次自增时才出现(首次出现即为 1),Prometheus 的 `rate()` 看不到这第一次跃变;改动后序列从节点注册那一刻就以 0 存在,第一次真实失败能被 `rate()` 捕获。
  <details><summary>代码依据 pkg/metrics/scheduler.go</summary>

  ```diff
  +// InitDeviceType exports zero values for the outcomes of a device type, so
  +// rate() sees the first increase of each series.
  +func (m *SchedulerOutcomeMetrics) InitDeviceType(deviceType string) {
  +	for phase, reasons := range allocationFailureReasons {
  +		m.allocations.With(m.labels(phase, deviceType, FailureReasonNone)).Add(0)
  +		for _, reason := range reasons {
  +			m.allocationFailures.With(m.labels(phase, deviceType, reason)).Add(0)
  +		}
  +	}
  +	m.allocationDuration.WithLabelValues(deviceType)
  +}
  +
   // ObserveAllocation records a successful allocation.
  ```
  </details>
- **`m.bindRollbacks` 被明确排除在播种之外**。`SchedulerOutcomeMetrics` 结构体有四个成员(`allocations`/`allocationFailures`/`bindRollbacks`/`allocationDuration`),`InitDeviceType` 只碰了其中三个。核对 HEAD(`7e92d065`)的 `pkg/metrics/scheduler.go` 全文确认:`bindRollbacks` 仅在 `ObserveBindRollback` 里被 `Inc()`。结论:`rate(hami_scheduler_bind_rollbacks_total[...])` 仍然漏首次自增,回滚率这类指标的盲区没有被这次改动覆盖。PR 描述里也写明 "refit and `hami_scheduler_bind_rollbacks_total` are left out for now"。
  <details><summary>代码依据 pkg/metrics/scheduler.go(HEAD 全文,非 diff)</summary>

  ```go
  type SchedulerOutcomeMetrics struct {
  	allocations        *prometheus.CounterVec
  	allocationFailures *prometheus.CounterVec
  	bindRollbacks      *prometheus.CounterVec   // ← InitDeviceType 未触及
  	allocationDuration *prometheus.HistogramVec
  }
  ```
  </details>
- **调用点插在 `Scheduler.register()` 的"厂商确实有健康设备"之后、`!needUpdate` 提前返回之前**(`pkg/scheduler/scheduler.go`,+1 行)。核对 HEAD 该函数上下文:`InitDeviceType` 之前有三条 `continue` 分支(设备不健康走 `NodeCleanUp`+`rmNodeDevices`、`err != nil` 走 `ForgetRegisteredDevices`、`len(nodedevices) == 0` 清理陈旧缓存),都会跳过播种;插入位置紧跟在这三条之后。放在 `!needUpdate` 之前是有意的——稳态下 register 循环每轮 `needUpdate` 多为 false,若放在其后则播种只在设备信息变化时才发生。因此**播种范围 = 节点上实际注册到的厂商**,而不是 `device.DevicesMap` 里编译进去的全部厂商。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
   			if len(nodedevices) == 0 {
   				...
   				continue
   			}
  +			s.GetAllocationMetrics().InitDeviceType(devhandsk)
   			if !needUpdate {
   				klog.V(5).InfoS("No update needed for device", "nodeName", val.Name, "deviceVendor", devhandsk)
   				continue
   			}
  ```
  </details>
- **单测把"只播种节点上存在的厂商"这条语义钉死了**。`Test_register_InitsOutcomeMetricsForNodeDevices` 把 `device.DevicesMap` 设成 NVIDIA + Tecorigin 两家,但节点注解只有 `hami.io/node-tecorigin-register`、allocatable 只有 `tecorigin.com/gpucore`;断言 `hami_scheduler_allocations_total` 只有 3 条序列、`hami_scheduler_allocation_failures_total` 只有 10 条,且全部 `device_type="Tecorigin"`。NVIDIA 一条序列都不产生。这也说明多厂商混部集群的指标基数是按**实际注册厂商数**线性增长的(每厂商 13 counter + 1 直方图),不会因为编译进了 10 家后端就炸出 130 条空序列。
  <details><summary>代码依据 pkg/scheduler/scheduler_test.go</summary>

  ```diff
  +	device.DevicesMap = map[string]device.Devices{
  +		nvidia.NvidiaGPUDevice: nvidia.InitNvidiaDevice(nvidia.NvidiaConfig{}),
  +		tecorigin.TecoDevice:   tecorigin.InitTecoDevice(tecorigin.TecoConfig{ResourceCountName: "tecorigin.com/gpucore"}),
  +	}
  +	// The node only has Tecorigin devices.
  +	...
  +	s.register(labels.Everything())
  +
  +	require.Equal(t, 3, promtestutil.CollectAndCount(s.GetAllocationMetrics(), "hami_scheduler_allocations_total"))
  +	require.Equal(t, 10, promtestutil.CollectAndCount(s.GetAllocationMetrics(), "hami_scheduler_allocation_failures_total"))
  +	require.NoError(t, promtestutil.CollectAndCompare(s.GetAllocationMetrics(), strings.NewReader(`
  +hami_scheduler_allocations_total{device_type="Tecorigin",failure_reason="none",phase="allocate"} 0
  +hami_scheduler_allocations_total{device_type="Tecorigin",failure_reason="none",phase="bind"} 0
  +hami_scheduler_allocations_total{device_type="Tecorigin",failure_reason="none",phase="filter"} 0
  +`), "hami_scheduler_allocations_total"))
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 的调度器正在从"有指标"走向"有 SLI 契约",而且契约是先写死在代码里的数据结构,不是文档。** 今天这个 `allocationFailureReasons` map 的意义超出零值播种本身:它第一次让"phase × failure_reason 的合法组合"成为可被代码遍历的全集。顺着 PR 里的 `Part of #3376` 查到提案 https://github.com/Project-HAMi/HAMi/issues/3376(Proposal: SLIs for HAMi and the metrics they need,仍 open),里面定义了 6 条 SLI(Availability / Reliability / Latency / Correctness / Freshness / Completeness)和一张 "metric changes" 清单;对照本月 digest 链,清单第 1 项的各子条(`phase="allocate"`、Bind 成功计数、leader-only 计数、`failure_reason="timeout"`、`allocation_duration_seconds`)分别在 #3474 等 PR 落地(见 2026-11-20 digest),"start them at 0" 是其中最后一条,今天收尾;第 2 项 `hami_scheduler_last_sync_success_timestamp_seconds` 经代码搜索在 HEAD 已有命中,也已落地。**证据边界**:提案清单的完成度是用 code search 命中数 + 本任务 digest 链交叉核对的,没有逐 PR 展开确认每条子项的实现细节。
- **仍未播种的两处是下一步的确定性缺口,不是疏漏。** `bindRollbacks` 与 refit 路径(`conflict` reason,来自 `pkg/scheduler/numa_refit_handler.go`)被显式留在外面,PR 的理由是"只覆盖 SLI 用到的序列"。这意味着提案里 6 条 SLI 的计算不依赖回滚率和 refit——换句话说 NUMA refit 这条线目前**不在 HAMi 自定义的 SLO 范围内**。如果后续要把 refit 纳入 SLI,必然需要一次 `InitDeviceType` 的扩展或一条独立的播种路径;可以把这当成判断 "refit 是否从实验特性转为承诺特性" 的前瞻指标。**证据边界**:只看了 `pkg/metrics/scheduler.go` 全文与今日 diff,没有读 `numa_refit_handler.go` 的实现。
- **对我们产品的启示:**(1)播种锚在 `register()` 而不是进程启动,是一个值得照抄的设计——指标序列的生命周期跟"节点上真实存在的厂商"绑定,既消灭了 `rate()` 首次自增盲区,又避免了"编译进 N 家后端就产出 N×13 条空序列"的基数浪费;我们自己的多厂商纳管面板如果按"全部支持厂商"预建序列,基数会白涨一个数量级。(2)HAMi 把 SLI 定义在"只覆盖自己可控的部分"(明确排除容量与硬件故障),并把 SLO 目标值交给运维方自己设、指南放到 `website` 仓——这套"厂商给 SLI 定义、客户定 SLO 目标"的切分方式,比我们直接承诺绝对可用性数字更可辩护,企业交付文档可以参考。(3)`phase`/`failure_reason` 这组有界标签契约(`schedulerOutcomeLabels` 三标签、reason 为封闭枚举)已经稳定多期,可以直接作为对接 HAMi 的告警规则基准;今天起这些序列在首次事件前就存在,告警规则不必再用 `or vector(0)` 兜底。**证据边界**:`website` 仓不在本 task 的 5 个数据源内,SLO 指南是否已成文未核实。

## 本期无实质改动(折叠)
<details><summary>4 个仓零新提交</summary>

- `Project-HAMi/HAMi-core`:HEAD 仍为 `4314e0a7`,无新提交(与 2026-11-22 锚点一致)。
- `Project-HAMi/volcano-vgpu-device-plugin`:HEAD 仍为 `5357e807`,无新提交;Release 仍 `volcano-vgpu-device-plugin-1.13.0`。
- `Project-HAMi/ascend-device-plugin`:HEAD 仍为 `9325759b`,无新提交;Release 仍 `ascend-device-plugin-0.2.2`。
- `Project-HAMi/HAMi-WebUI`:HEAD 仍为 `19a0f955`,无新提交;Release 仍 `v1.3.0`。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=7e92d065eca7f9248bc908aa160adad775d337a8 branch=master release=v2.11.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=4314e0a7750eb53dbe865c86abe88b59143390cc branch=main release=— scanned=2026-11-23 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5357e807398dcf2aae6d82a9bffa3bfaef7f701f branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-23 -->
