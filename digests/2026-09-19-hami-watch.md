# HAMi diff 雷达 2026-09-19

## 摘要
- ascend-device-plugin 落地 **hami-core 算力超售**:新增 `deviceCoreScaling` 全局/按节点配置,hami-core 模式下向 HAMi 注册 `Devcore = round(100 × scale)`,同时删除已废弃的 `HamiVnpuCoreMaxPercent`——vNPU 软切分从"固定 100 分算力预算"迈向"可超售"(仅算力,显存不动)。
- HAMi 主仓本期无 NVIDIA hami-core 软切分改动,集中在**多厂商 device plugin 正确性**:awsneuron 改为按节点推导 core 几何(修混合机型误切分)、iluvatar 修多卡 `-core` 百分比语义、scheduler 容器指标由线性扫描改 UUID 索引降复杂度。
- volcano-vgpu-device-plugin / HAMi-core / HAMi-WebUI 三仓 EMPTY,仅续锚点。

## 当日重要改变
- Project-HAMi/ascend-device-plugin [新能力] hami-core vNPU 引入算力超售系数 `deviceCoreScaling`(默认 1=100 分预算,1.5→注册 Devcore=150),`AdvertisedDevcore()` 落地,Helm value + schema 校验(<1 拒绝)。证据 `internal/vnpu.go`。 https://github.com/Project-HAMi/ascend-device-plugin/compare/4b977f92853a9e797f7d219204e575524e740ee0...074d93a8e1ca4f357fb1f4946f0566ced93641a6
- Project-HAMi/ascend-device-plugin [弃用/移除] 删除未使用的 `HamiVnpuCoreMaxPercent` 配置项。证据同上 compare。
- Project-HAMi/HAMi [行为变更] iluvatar `-core` 请求语义从"必须 0-100"改为"允许 >100 的多卡总量并按卡数回除到 per-card";awsneuron core 几何从"结构体缓存首节点值"改为"按节点推导",修混合机型误切分。证据 `pkg/device/iluvatar/device.go`、`pkg/device/awsneuron/device.go`。 https://github.com/Project-HAMi/HAMi/compare/9e111e9dde51a1194dbb6c2c842200e3c819f664...3452ead0b971b1fd1fb3814a074e020b5ce2fe51

## Project-HAMi/ascend-device-plugin: 4b977f92 -> 074d93a8
- 比较: https://github.com/Project-HAMi/ascend-device-plugin/compare/4b977f92853a9e797f7d219204e575524e740ee0...074d93a8e1ca4f357fb1f4946f0566ced93641a6 | ahead=8 | files=19 | Release: ascend-device-plugin-0.1.0

### AI 总结重点(源码 diff 为据)
- **新增 hami-core 算力超售系数 `DeviceCoreScaling`**:`VNPUsConfig` 与 `NodeConfig` 各加一个 `deviceCoreScaling float64` 字段,新增纯函数 `AdvertisedDevcore(isHamiCore, scale, hardwareAICore)` 决定向 HAMi 注册的 core 容量。非 hami-core(模板/硬切分)仍注册硬件 AICore;hami-core 下注册 `round(100 × scale)`。默认 1 → 100 分预算(现状不变),1.5 → 150,即一张卡可容纳 `-core:30 ×3 + -core:20 ×1` 共 4 个 pod。**只超售算力,显存不缩放**,且每卡 pod 密度仍受 `vDeviceCount` 约束。
  <details><summary>代码依据 internal/vnpu.go</summary>

  ```diff
  +	// DeviceCoreScaling is the hami-core compute oversell ratio.
  +	// When hami-core is on, registerHAMi advertises Devcore = round(100 * DeviceCoreScaling).
  +	DeviceCoreScaling float64      `json:"deviceCoreScaling,omitempty"`
  ...
  +func AdvertisedDevcore(isHamiCore bool, scale float64, hardwareAICore int32) int32 {
  +	if !isHamiCore {
  +		return hardwareAICore
  +	}
  +	switch {
  +	case math.IsNaN(scale) || math.IsInf(scale, 0): ... return hamiCorePercentBase
  +	case scale == 0:  return hamiCorePercentBase
  +	case scale < 1:   ... return hamiCorePercentBase   // hami-core 无法欠配算力
  +	}
  +	budget := math.Round(hamiCorePercentBase * scale)
  +	if budget > math.MaxInt32 { ... return hamiCorePercentBase }
  +	return int32(budget)
  +}
  ```
  </details>
- **scale<1 显式拒绝(fail-safe 回退到 100)**:设计上说明 HAMi 分不清"欠配的百分比(如 50)"和"硬件 AICore 计数",故欠配会被调度侧静默忽略,因此 <1、NaN、Inf、溢出一律回退到 100 并告警。这是把"不可表达的语义"挡在注册边界而非放进调度器。(依据同上 hunk 的 switch 分支。)
- **`Manager` 接口新增 `DeviceCoreScaling() float64`,按节点覆盖优先于全局**:override=0 视作"未设置"(匹配 omitempty),其余值(含非法值)原样返回给 `AdvertisedDevcore` 判定,避免节点静默继承全局比率。
  <details><summary>代码依据 internal/manager/manager.go</summary>

  ```diff
   type Manager interface {
   	IsHamiVnpuCore() bool
  +	DeviceCoreScaling() float64
   }
  +func (am *AscendManager) DeviceCoreScaling() float64 {
  +	if am.nodeConfig != nil && am.nodeConfig.DeviceCoreScaling != 0 {
  +		return am.nodeConfig.DeviceCoreScaling
  +	}
  +	return am.globalConfig.VNPUs.DeviceCoreScaling
  +}
  ```
  </details>
- **删除未使用的 `HamiVnpuCoreMaxPercent`**:提交 `chore: remove unused HamiVnpuCoreMaxPercent` + `docs: correct HamiVnpuCoreMaxPercent comment for oversell`,超售能力改由 `deviceCoreScaling` 承担,旧的"最大百分比"常量退场。(依据:实质提交标题 + vnpu.go 中该字段消失;hunk 未单独截出删除行,判据为文件级信号。)
- Helm 侧:`hamiVnpuCore.deviceCoreScaling` 暴露为 value(默认 1),`values.schema.json` 校验拒绝 <1;README 新增 "Compute Oversell" 段,提示分数比率须用 `--set-json`(`--set 1.5` 会被当字符串被 schema 拒)。另加了一批 issue/PR 模板(非功能)。
  <details><summary>代码依据 charts/ascend-device-plugin/README.md</summary>

  ```diff
  +### Compute Oversell
  +`hamiVnpuCore.deviceCoreScaling` sets how much compute the plugin advertises for
  +hami-core. The plugin registers `Devcore = round(100 * deviceCoreScaling)` ...
  +Only compute is oversold. Device memory is never scaled, and pod density per card is
  +still capped by `vDeviceCount`, so raising the ratio alone may not admit more pods.
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 vNPU 的 hami-core 路径正在补齐 NVIDIA 侧早有的"算力超售"能力,且刻意做成"只超算力、不动显存、密度仍受 vDeviceCount 封顶"的克制形态——对标我们做多租户 NPU 切分时,超售系数应是"per-node 可覆盖 + 非法值 fail-safe 回 100"的注册期约束,而非调度期临时判断。
- 证据只覆盖 `internal/vnpu.go` / `manager.go` / chart,未见调度器侧如何消费 `Devcore=150`(HAMi 主仓 admission 逻辑本期无改动),超售后的抢占/驱逐语义未见 diff,未覆盖。

## Project-HAMi/HAMi: 9e111e9d -> 3452ead0
- 比较: https://github.com/Project-HAMi/HAMi/compare/9e111e9dde51a1194dbb6c2c842200e3c819f664...3452ead0b971b1fd1fb3814a074e020b5ce2fe51 | ahead=8 | files=13 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)
- **awsneuron core 几何从"结构体缓存首节点值"改为"按节点推导"**:删除 `AWSNeuronDevices.coresPerAWSNeuron`/`coremask` 两个字段及 `coresPerDevice()` 方法;`GetNodeDevices` 现在每次从节点 Capacity 现算 `coresPerDevice = coresTotal / counts`,并校验整除、上下界,再经 `CustomInfo[AWSCoresPerNeuronDevice]` 下发。旧逻辑把首个见到的节点几何缓存在共享 struct 上,混合 inf1/inf2 机型集群会用错 core 数;新逻辑无状态、按节点独立。
  <details><summary>代码依据 pkg/device/awsneuron/device.go</summary>

  ```diff
   type AWSNeuronDevices struct {
   	resourceCountName string
   	resourceCoreName  string
  -	coresPerAWSNeuron uint
  -	coremask          uint
   }
  -func (dev *AWSNeuronDevices) coresPerDevice() int64 { ... 首节点缓存回退 cap ... }
  ...
  -	if dev.coresPerAWSNeuron == 0 {
  -		dev.coresPerAWSNeuron = uint(coresTotal) / uint(counts)
  +	if coresTotal%counts != 0 {
  +		return ..., fmt.Errorf("%s capacity %d is not divisible by %s capacity %d", ...)
  +	}
  +	coresPerDevice := coresTotal / counts
  ```
  </details>
- **iluvatar `-core` 请求从"必须 0-100"改为"识别多卡总量并回除 per-card"**:`GenerateResourceRequests` 里,当 `corenums > 100` 时视为 admission webhook 把 limit 改写成 `count×100` 的多卡总量,按请求设备数 `n` 回除(要求整除),再做 per-device 0-100 范围校验。兼容 webhook 关闭/绕过时运维直接写 per-card 值(≤100 原样保留)。
  <details><summary>代码依据 pkg/device/iluvatar/device.go</summary>

  ```diff
  -				corenums, ok := core.AsInt64()
  -				if !ok || corenums < 0 || corenums > 100 { ... out of range ... }
  +				corenums, parsed := core.AsInt64()
  +				if !parsed || corenums < 0 { ... not a non-negative integer ... }
  +				if corenums > 100 {
  +					if corenums%n != 0 { ... does not divide evenly ... }
  +					corenums /= n
  +				}
  +				if corenums > 100 { ... out of range (must be 0-100 per device) ... }
  ```
  </details>
- **scheduler 容器指标由"每设备线性扫描全集群"改为"每次 scrape 建一次 UUID 索引"**:删除 `findNodeDeviceUsage`(按 UUID 遍历所有节点所有设备),换成 `newDeviceMetaIndex` 一次性建 `map[uuid]deviceMeta`,`collectContainerMetrics` 改吃这张索引。抓取复杂度由 O(已分配设备 × 节点 × 每节点设备)降为 O(已分配设备)。重复 UUID 保留首个、node-agnostic(与被替换的扫描一致,不回归 AMD 归一化)。
  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  -func findNodeDeviceUsage(nu *map[string]*schedulerpkg.NodeUsage, uuid string) (totalcore int32, deviceType string, ok bool) {
  -	for _, ni := range *nu { for _, dls := range ni.Devices.DeviceLists {
  -		if dls.Device != nil && dls.Device.ID == uuid { return dls.Device.Totalcore, dls.Device.Type, true } } }
  -	return 0, "", false
  +func newDeviceMetaIndex(nu *map[string]*schedulerpkg.NodeUsage) map[string]deviceMeta {
  +	index := make(map[string]deviceMeta, total)
  +	for _, ni := range *nu { for _, dls := range ni.Devices.DeviceLists {
  +		if dls.Device == nil { continue }
  +		if _, ok := index[dls.Device.ID]; ok { continue }
  +		index[dls.Device.ID] = deviceMeta{ totalcore: dls.Device.Totalcore, deviceType: dls.Device.Type } } }
  +	return index }
  ```
  </details>

### 后续发展方向 [AI]
- 主仓本期是"多厂商 device plugin 正确性 + 调度器可观测性伸缩性"的收口:AWS Neuron/Iluvatar 两条非 NVIDIA 路径都在修"跨机型/多卡语义"这类边界 bug,说明 HAMi 的软切分抽象在往"一套 core 百分比语义统一覆盖异构卡"收敛。
- 证据只覆盖 awsneuron/iluvatar/metrics 三处,**本窗口未见 NVIDIA hami-core hook 侧改动**(HAMi-core 仓 EMPTY),核心显存/算力软隔离内核无变化;超售系数在主仓调度侧如何被消费也未见 diff。

## 本期无实质改动(折叠)
<details><summary>3 仓 EMPTY(仅锚点续链)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=3452ead0b971b1fd1fb3814a074e020b5ce2fe51 branch=master release=v2.10.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a5231c7f4524e5d98f5200fde47f97b06356fcbe branch=main release=— scanned=2026-09-19 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-19 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=074d93a8e1ca4f357fb1f4946f0566ced93641a6 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=b2af8ecc94a2330a6f11ab189522f16f328495bd branch=main release=v1.3.0 scanned=2026-09-19 -->
