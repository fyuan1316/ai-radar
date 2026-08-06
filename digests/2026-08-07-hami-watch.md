# HAMi diff 雷达 2026-08-07

## 摘要
- HAMi 主仓本期主线是"**健壮性硬化 + 配额语义修正**":多处 `panic` 改为优雅降级(P2P 非对称链路、metrics、monitor 越界),并给 `ResourceQuota` 加 `LimitSet` 字段——让"显式配额 0"真正当硬阻断,且 Update 事件不再有"限额被瞬时清零→漏拦"的窗口。
- Ascend 910C vNPU 分配修正:请求 >1 卡时强制走整模块对(2 NPU/卡)组合并校验数量,不足即拒,堵住"欠分配"路径(#2369)。
- volcano-vgpu 暴露显存切分模型的一条硬边界:显存被逐单位注册成独立 device,单节点条目数超 kubelet gRPC 4MB 上限(约 6 万)会被整条丢弃、资源归零,新增告警并建议调大 `gpuMemoryFactor`。

## 当日重要改变
- Project-HAMi/HAMi [调度语义变更] `Quota` 新增 `LimitSet bool`,`FitQuota` 从 `limit != 0` 改判 `LimitSet`——显式 `ResourceQuota=0` 从"被读成无上限"变为"硬阻断";并把 update 事件从 del+add 合并成单锁 `UpdateQuota` 消除漏拦窗口。https://github.com/Project-HAMi/HAMi/pull/2313 https://github.com/Project-HAMi/HAMi/pull/2386
- Project-HAMi/HAMi [Ascend vNPU 分配修正] 910C 请求多卡时用 `computeBestCombination910C` 强制整模块对分配并校验 `len(combination)==originReq`,否则返回 `AllocatedCardsInsufficientRequest` 拒绝,防欠分配。https://github.com/Project-HAMi/HAMi/pull/2369
- Project-HAMi/volcano-vgpu-device-plugin [运行边界] 新增 `deviceEntryLimit=60000` 与 `checkDeviceEntries`,ListAndWatch 设备条目超限即告警(超 kubelet 4MB gRPC 接收上限会被丢弃→资源为 0)。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/abe6919b389e98d33af1d8dd1c7d4fee6874102c

## Project-HAMi/HAMi: e6d09024 -> 87d9795a
- 比较: e6d090245b79a22fb9a58fab2a1167f7b161d32d -> 87d9795a | ahead=19 | files=36 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/e6d090245b79a22fb9a58fab2a1167f7b161d32d...87d9795a

### AI 总结重点(源码 diff 为据)
- **配额:显式 0 当硬阻断,而非"无上限"**。`Quota` 结构体加 `LimitSet bool`,`FitQuota` 的两处判断从 `limit != 0 && ...` / `coreQuota.Limit != 0 && ...` 改成 `memQuota.LimitSet && ...` / `coreQuota.LimitSet && ...`。之前用量追踪自动建的条目 `Limit=0` 会被当成"没配上限",导致管理员显式写的 `ResourceQuota: 0`(想禁掉该命名空间用卡)被无视;现在只有真正配过的条目才 `LimitSet=true`,`0` 生效为拒绝一切请求。
  <details><summary>代码依据 pkg/device/quota.go</summary>

  ```diff
   type Quota struct {
   	Used  int64
   	Limit int64
  +	// LimitSet distinguishes an explicitly configured limit (including an
  +	// explicit 0, which blocks all usage) from an entry auto-created by usage
  +	// tracking ... FitQuota gates on this rather than Limit != 0
  +	LimitSet bool
   }
  -		if limit != 0 && memQuota.Used+memreq > limit {
  +		if memQuota.LimitSet && memQuota.Used+memreq > limit {
  -	if ok && coreQuota.Limit != 0 && coreQuota.Used+coresreq > coreQuota.Limit {
  +	if ok && coreQuota.LimitSet && coreQuota.Used+coresreq > coreQuota.Limit {
  ```
  </details>
- **配额:Update 事件改单锁原子换值,消除漏拦窗口**。`onUpdateQuota` 原来是 `onDelQuota(old)` + `onAddQuota(new)` 两步;两步之间限额被清零,而 FitQuota 把零读成"无限额",落在这个间隙的调度检查会被放行。新增 `QuotaManager.UpdateQuota(old,new)` 在同一把锁内先 `delQuotaLocked` 再 `addQuotaLocked`;并抽出 `asResourceQuota` 统一处理 informer tombstone。kube quota controller 每个 pod 事件都会改写 `status.used`,调度高峰期 update 极密集,这个窗口是真实可触发的。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
   func (s *Scheduler) onUpdateQuota(oldObj, newObj any) {
  -	s.onDelQuota(oldObj)
  -	s.onAddQuota(newObj)
  +	oldQuota, ok := asResourceQuota(oldObj)
  +	if !ok { return }
  +	newQuota, ok := asResourceQuota(newObj)
  +	if !ok { return }
  +	s.quotaManager.UpdateQuota(oldQuota, newQuota)
   }
  ```
  </details>
- **Ascend 910C:多卡请求强制整模块对分配 + 数量校验**。`Devices.Fit` 里对 `Ascend910CType && originReq > 1` 新增独立分支:调 `computeBestCombination910C` 求组合,`len(combination) != originReq` 就写 `AllocatedCardsInsufficientRequest` 理由并 `return false` 拒绝;同时简单路径下 910C 多卡不再递减 `k.Nums`(避免提前判成功)。910C 每物理卡 2 NPU,之前多卡场景可能欠分配拿到不成对的 NPU。另外 `computeBestCombination910C` 里卡排序从升序(`len<len`)改成降序(`len>len`),优先用 NPU 更满的卡。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  -			if !needTopology {
  +			if !needTopology && (k.Type != Ascend910CType || originReq <= 1) {
   				k.Nums--
  +	if k.Type == Ascend910CType && originReq > 1 {
  +		combination := npu.computeBestCombination910C(nodeInfo, int(originReq), tmpDevs[k.Type])
  +		if len(combination) != int(originReq) {
  +			reason[common.AllocatedCardsInsufficientRequest] = len(combination)
  +			return false, tmpDevs, common.GenReason(reason, int(originReq))
  +		}
  +		tmpDevs[k.Type] = combination
  +		return true, tmpDevs, ""
  +	}
  ```
  </details>
- **拓扑打分:P2P 非对称链路从 panic 改为降级**。`calculateGPUPairScore` 原本发现两卡 P2P 链路数不对称就 `panic`;现改为 `klog.Warning` 记录并把该对打 0 分,返回值多带一个 `bool` 标记是否出现非对称(经 `calculateGPUScore`/`CalculateGPUScore` 逐层上传,签名都加了 bool)。硬件/驱动异常(NVLink)不再拖垮整个 scheduler 进程。
  <details><summary>代码依据 pkg/device/nvidia/calculate_score.go</summary>

  ```diff
  -func calculateGPUPairScore(gpu0 *Device, gpu1 *Device) int {
  +func calculateGPUPairScore(gpu0 *Device, gpu1 *Device) (int, bool) {
   	if len(gpu0.Links[gpu1.Index]) != len(gpu1.Links[gpu0.Index]) {
  -		err := fmt.Errorf("...P2PLinks between 2 GPUs should be bidirectional")
  -		panic(err)
  +		klog.Warningf("asymmetric P2P link data for GPU pair ... scoring pair as 0 (possible NVLink hardware or driver issue)", ...)
  +		return 0, true
   	}
  ```
  </details>
- **新增 `EmitNodeWarningEvent`:把节点级异常上报成 K8s Warning Event(带去重)**。`pkg/util/util.go` 新增该函数:按 `involvedObject`+`reason` field selector 查最近同类事件,`dedupWindow` 内命中就 `Count++`/更新时间戳,否则新建 `EventTypeWarning`(Source `hami-device-plugin`)。配合上面 P2P 非对称等降级路径,把原来只进日志的异常升级为集群可见事件。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  +// EmitNodeWarningEvent emits a Warning event on the given Node with deduplication.
  +func EmitNodeWarningEvent(node *corev1.Node, reason, message string, dedupWindow time.Duration) {
  +	...
  +		if latest != nil && now.Sub(latest.LastTimestamp.Time) <= dedupWindow {
  +			latest.Count++
  +			latest.LastTimestamp = now
  +			...Events(...).Update(ctx, latest, ...)
  +			return
  +		}
  +	event := &corev1.Event{ ... Type: corev1.EventTypeWarning, Source: corev1.EventSource{Component: "hami-device-plugin"} }
  ```
  </details>
- **scheduler metrics:去 `MustNewConstMetric`,采集路径不再 panic**。`cmd/scheduler/metrics.go` 把一批 `ch <- prometheus.MustNewConstMetric(...)` 替换成 `sendMetric(...)`/`sendLegacyMetric(...)` 帮手,标签/值非法时返回 error 记 V(4) 日志而非 panic,防止一条坏指标打挂整个 `/metrics` 抓取。属同批"panic→降级"硬化(另见 monitor 侧 clamp maxDevices、跳过未初始化短 UUID 等多条 fix)。
  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  -			ch <- prometheus.MustNewConstMetric(nodevGPUMemoryLimitDesc, prometheus.GaugeValue, ...)
  +			if err := sendMetric(ch, nodevGPUMemoryLimitDesc, prometheus.GaugeValue, ...); err != nil {
  +				klog.V(4).Infof("Failed to send nodevGPUMemoryLimitDesc metric: %v", err)
  +			}
  ```
  </details>
- **新增可导入 Grafana 面板 + 说明**(#2301)。`dashboards/hami-vgpu-dashboard.json`(+842)与 `dashboards/README.md` 落地官方 vGPU 监控盘,面板分 Cluster overview / 物理 GPU / 调度分配 / 每容器 vGPU 四组,并成文列出当前 `hami_*` 指标口径(如 `hami_gpu_memory_limit_bytes`、`hami_vgpu_memory_used_bytes`、`hami_container_device_utilization_ratio`,利用率/占比一律 0-100)。可用性/可观测性信号。
  <details><summary>代码依据 dashboards/README.md</summary>

  ```diff
  +| `hami_gpu_memory_limit_bytes` | scheduler | Schedulable GPU memory per device. |
  +| `hami_vgpu_memory_used_bytes` | vGPU monitor | Per-container vGPU memory used. |
  +| `hami_container_device_utilization_ratio` | vGPU monitor | Per-container utilization (0-100). |
  ```
  </details>

### 后续发展方向 [AI]
- 本期证据集中在"**稳态可靠性**":scheduler / monitor / device-plugin 三处把会崩进程的 panic 系统性替换为降级+日志+(新)节点 Warning Event。方向是把 HAMi 从"异常即整机失守"推向"异常局部隔离、集群可观测"。证据只覆盖 P2P 打分、metrics 采集、monitor 越界几条 hunk,未见是否有统一的 panic-recover 中间件。
- 配额子系统正在从"够用"走向"语义严谨":显式 0、update 原子性都是把 HAMi 配额向标准 `ResourceQuota` 语义对齐,利于多租户硬隔离场景。证据是 quota.go/scheduler.go 两文件,未展开 quota 与实际调度记账(GenerateResourceRequests / MemoryFactor,昨日 #2347 的方向)如何联动。
- Ascend 910C 的整模块对约束反复被修(本期 #2369),说明 HAMi 的昇腾 vNPU 拓扑分配仍在收敛;证据仅 device.go 的 Fit/组合逻辑,未见 ascend-device-plugin 侧(本期 EMPTY)配套变化。

## Project-HAMi/volcano-vgpu-device-plugin: 6561f1c1 -> abe6919b
- 比较: 6561f1c10e98589002939768194f332e44edddaf -> abe6919b | ahead=2 | files=3 | Release: —
- https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/6561f1c10e98589002939768194f332e44edddaf...abe6919b

### AI 总结重点(源码 diff 为据)
- **给"显存逐单位注册成 device"模型加了一条 kubelet gRPC 容量护栏**。`pkg/plugin/server.go` 新增常量 `deviceEntryLimit=60000` 与 `checkDeviceEntries(count, factor)`:一个显存 device 条目约 66 字节,kubelet 用默认 4MB gRPC 接收上限拨号,约 6.35 万条封顶,取整到 6 万留余量。`apiDevices()` 在返回前(只 ListAndWatch 走到、加 `entryLimitWarned` 单次标记)校验条目数,超限就 `klog.Warning` 提示"把 `gpuMemoryFactor` 调到至少 N"。超限时 kubelet 会整条丢弃 ListAndWatch,资源停在 0 或上一次可接受值——这类"显存切太细导致注册失败、资源归零"的坑现在有显式告警而非静默。`doc/design.md` 同步写明:节点总量 `显存MB/gpu-memory-factor ≤ 60000`,单张 80GB 卡需 factor≥2,八卡节点需 11。
  <details><summary>代码依据 pkg/plugin/server.go</summary>

  ```diff
  +	// deviceEntryLimit is how many devices fit in one ListAndWatch response.
  +	// Kubelet ... 4MB applies. A memory device entry costs about 66 bytes ... ~63500, rounded down here
  +	deviceEntryLimit = 60000
  +func checkDeviceEntries(count int, factor uint) error {
  +	if count <= deviceEntryLimit { return nil }
  +	needed := (factor*uint(count) + deviceEntryLimit - 1) / deviceEntryLimit
  +	return fmt.Errorf("%d memory devices exceed the %d kubelet can receive, set gpuMemoryFactor to at least %d", count, deviceEntryLimit, needed)
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 这条改动暴露了 HAMi/volcano 走"显存=离散 device 计数"这套软切分实现的固有 scale 天花板(单节点约 6 万单位)。护栏只到"告警+建议调 factor",未见自动调整 factor 或换用连续量表示。对我们产品的启示:若走同类 device-plugin 显存切分,需把 `gpu-memory-factor` 与节点显存总量做成部署期校验,别等 kubelet 静默丢列表。证据仅 server.go/design.md,未覆盖是否有 e2e 覆盖大节点场景。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓库(仅保锚点)</summary>

- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=87d9795adc4d73042efe1751351c8d04488270cf branch=master release=v2.9.0 scanned=2026-08-07 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-07 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=abe6919b389e98d33af1d8dd1c7d4fee6874102c branch=main release=— scanned=2026-08-07 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-07 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-07 -->
