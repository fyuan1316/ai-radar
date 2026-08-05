# HAMi diff 雷达 2026-08-06

## 摘要
- **HAMi 主仓把 ResourceQuota 准入检查从"仅 NVIDIA"扩到"所有 device backend"**(#2347):`fitResourceQuota` 不再直接读容器 spec、不再硬编码 `nvidia.MemoryFactor`,改为调用各后端自己的 `GenerateResourceRequests()` 拿请求量,并给 `ResourceNames` 结构体新增 `MemoryFactor` 字段让每家(mthreads=512/cambricon=256/metax=1024/iluvatar=256/nvidia=config)自报换算因子——目的是让"准入拒绝"与"调度记账"用同一套数字,消除只有 NVIDIA 有配额、其余厂商 vGPU 逃逸配额的漏洞。
- vGPUmonitor 修 `Describe()` 漏报 metric descriptor(#2240):补上 `ctrDeviceLastKernelDesc`、`ctrDeviceMigInfo` 两个之前未注册的描述符,Prometheus 抓取不再丢这两项指标。
- 其余 4 仓(HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI)本期无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力/行为变更] ResourceQuota 从 NVIDIA 专属扩为全后端通用,新增 `ResourceNames.MemoryFactor` 字段统一 vmemory→MiB 换算 | pkg/scheduler/webhook.go + pkg/device/devices.go | https://github.com/Project-HAMi/HAMi/pull/2347

## Project-HAMi/HAMi: 2cabe290 -> e6d09024
- 比较: https://github.com/Project-HAMi/HAMi/compare/2cabe290b6dd49843555fcbd0e1344970e19d978...e6d090245b79a22fb9a58fab2a1167f7b161d32d | ahead=2 | files=12 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)

- **`fitResourceQuota` 去掉"只支持 NVIDIA"的早退分支,改为对每个注册后端逐一做配额检查**。旧代码 `if deviceName != nvidia.NvidiaGPUDevice { continue }` 直接跳过所有非 N 卡设备;新代码只在"该后端既不暴露 memory 也不暴露 core 资源名"时才跳过,其余厂商 vGPU(寒武纪/摩尔线程/沐曦/天数/海光/昇腾)也纳入配额校验。这是把配额从单厂商能力升级为异构通用能力的关键改动。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  -		// Only supports NVIDIA
  -		if deviceName != nvidia.NvidiaGPUDevice {
  -			continue
  -		}
  -		memoryFactor := nvidia.MemoryFactor
   		resourceNames := dev.GetResourceNames()
  +		if len(resourceNames.ResourceMemoryName) == 0 && len(resourceNames.ResourceCoreName) == 0 {
  +			// Nothing this backend exposes can carry a quota.
  +			continue
  +		}
  ```
  </details>

- **配额用量不再由 webhook 自己从 container spec 解析,而是委托给后端的 `GenerateResourceRequests()`**。旧逻辑手写 `getRequest()` 闭包读 Limits/Requests 再 `memReq*req`;新逻辑调 `dev.GenerateResourceRequests(&ctr)` 拿 `req.Memreq/req.Coresreq/req.Nums`,注释点明动机:后端会施加自己的 memory factor、默认值和模板取整,这些正是调度器后续记为 used 的数字——让准入和调度对齐同一套算法,避免两处口径不一致导致的误判/逃逸。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  +		var memoryReq, coresReq int64
  +		for i := range pod.Spec.Containers {
  +			req := dev.GenerateResourceRequests(&pod.Spec.Containers[i])
  +			if req.Nums == 0 {
  +				continue
  +			}
  +			memoryReq += int64(req.Memreq) * int64(req.Nums)
  +			coresReq += int64(req.Coresreq) * int64(req.Nums)
  +		}
  -		if !device.GetLocalCache().FitQuota(pod.Namespace, memoryReq, memoryFactor, coresReq, deviceName) {
  +		if !device.GetLocalCache().FitQuota(pod.Namespace, memoryReq, resourceNames.MemoryFactor, coresReq, deviceName) {
  ```
  </details>

- **`ResourceNames` 结构体新增 `MemoryFactor int32` 字段**,承载"pod spec 里的 vmemory 单位 → HAMi 内部 MiB 记账"的缩放系数。注释说明:记账用的是缩放后单位、ResourceQuota limit 写的是未缩放单位,所以配额校验必须把 limit 按同一因子放大;不做缩放的后端把它留 0。这是让 `FitQuota` 能按后端拿到正确因子的数据通路。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
   type ResourceNames struct {
   	ResourceCountName  string
   	ResourceMemoryName string
   	ResourceCoreName   string
  +	// MemoryFactor is the scale GenerateResourceRequests applies to the memory
  +	// value read off the container spec. Recorded usage is in scaled units
  +	// while a ResourceQuota limit is written in unscaled ones, so a quota check
  +	// has to bring the limit up by the same factor. Backends that do not scale
  +	// leave this zero.
  +	MemoryFactor int32
   }
  ```
  </details>

- **各后端在 `GetResourceNames()` 里回填 `MemoryFactor`,同时把散落的魔法数字换成命名常量**:mthreads=512、cambricon=256、iluvatar=256、metax=1024(bare vmemory 按 Gi 读),nvidia 用 `dev.config.MemoryFactor`。既是可读性重构也是让每家把自己的换算口径显式暴露给配额层。
  <details><summary>代码依据 pkg/device/mthreads/device.go(cambricon/iluvatar/metax/nvidia 同型)</summary>

  ```diff
  +	// MemoryFactor converts the vmemory unit used in the pod spec into the MiB
  +	// HAMi accounts internally. One mthreads vmemory unit is 512 MiB.
  +	MemoryFactor = 512
  ...
  -			Devmem:       int32(memoryTotal * 512 * coresPerMthreadsGPU / cores),
  +			Devmem:       int32(memoryTotal * MemoryFactor * coresPerMthreadsGPU / cores),
  ...
   		ResourceCoreName:   MthreadsResourceCores,
  +		MemoryFactor:       MemoryFactor,
  ```
  </details>

- **vGPUmonitor 的 `Describe()` 从 DescribeByCollect 简化实现改为显式发送全部描述符,补齐 `ctrDeviceLastKernelDesc` 与 `ctrDeviceMigInfo`**。旧注释声称"Collect 永远只返回同样两个 metric",实际 collector 已扩出更多指标,导致这两个描述符从未在 Prometheus registry 注册。修复后指标不再漏报(#2240)。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go</summary>

  ```diff
  -// Describe is implemented with DescribeByCollect. That's possible because the
  -// Collect method will always return the same two metrics with the same two
  -// descriptors.
  +// Describe sends all the metrics descriptors that the collector might use.
   func (cc ClusterManagerCollector) Describe(ch chan<- *prometheus.Desc) {
   	ch <- ctrDeviceUtilizationdesc
  +	ch <- ctrDeviceLastKernelDesc
  +	ch <- ctrDeviceMigInfo
   	ch <- ctrDeviceMemoryContextDesc
  ```
  </details>

### 后续发展方向 [AI]
- HAMi 正把"配额/记账"从 NVIDIA 中心化设计往异构通用抽象收敛:`MemoryFactor` 进 `ResourceNames`、准入委托 `GenerateResourceRequests`,意味着后续新增厂商后端只要正确实现这两个契约就自动享有 ResourceQuota,而不用改 webhook。证据只覆盖 webhook.go + devices.go + 5 个后端 device.go 的 diff,未见 `FitQuota`/LocalCache 端如何用新因子做实际比较(该文件本期未改)。
- 可观测性侧在补齐 Describe/Collect 一致性,属稳健性打磨而非新指标能力;证据仅覆盖 metrics.go 的 Describe 段,未展开新增的 metrics_test.go 断言内容。

## 本期无实质改动(折叠)
<details><summary>4 仓 EMPTY</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=e6d090245b79a22fb9a58fab2a1167f7b161d32d branch=master release=v2.9.0 scanned=2026-08-06 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-06 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-08-06 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-06 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-06 -->
</content>
</invoke>
