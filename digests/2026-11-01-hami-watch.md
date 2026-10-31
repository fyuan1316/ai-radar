# HAMi diff 雷达 2026-11-01

## 摘要
- 仅 `Project-HAMi/HAMi` 主仓 1 个实质提交(#3339),主线是**把 ResourceQuota 显存限额的 memoryFactor 缩放从"每次 FitQuota 检查时临时乘"下沉到"配额加载时一次性换算"**:`FitQuota` 签名删掉 `memoryFactor` 入参,新增带 int64 溢出保护的 `scaledQuotaLimit`,并补齐"两后端共用同一显存资源名却声明不同 memoryFactor"的配置期冲突检测。属调度配额记账正确性加固,非 API/CRD 变更。
- HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI 四仓本期无新提交(保锚点)。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期改动未命中弃用/移除、API/CRD、架构方向、版本跨档、新能力任一信号)

## Project-HAMi/HAMi: def0bf82 -> 2b8f4e29
- 比较: def0bf82074ca7aff940800c18d5d3402eef5cff -> 2b8f4e29 | ahead=2 | files=17 | Release: v2.10.0
- 提交: fix(scheduler): store quota memory limits scaled by memoryFactor (#3339)
  https://github.com/Project-HAMi/HAMi/commit/2b8f4e29c48bca376d4f6123d7c6ae7627aef579
  https://github.com/Project-HAMi/HAMi/pull/3339

### AI 总结重点(源码 diff 为据)
- **`QuotaManager.FitQuota` 删掉 `memoryFactor int64` 入参,检查时不再临时放大 limit**。旧逻辑在每次判定时 `if memoryFactor > 1 { limit = limit * memoryFactor }` 再比 `Used+memreq > limit`;新逻辑直接比 `memQuota.Limit`(此 Limit 已是缩放后的单位),去掉了检查路径里的乘法分支。这把"记录用量是缩放单位、配额 limit 是未缩放单位"的单位错配从每次检查时弥合,改为在配额入库时就统一到缩放单位。
  <details><summary>代码依据 pkg/device/quota.go</summary>

  ```diff
  -func (q *QuotaManager) FitQuota(ns string, memreq int64, memoryFactor int64, coresreq int64, deviceName string) bool {
  +func (q *QuotaManager) FitQuota(ns string, memreq int64, coresreq int64, deviceName string) bool {
   	...
  -		limit := memQuota.Limit
  -		if memoryFactor > 1 {
  -			limit = limit * memoryFactor
  -		}
  -		if memQuota.LimitSet && memQuota.Used+memreq > limit {
  +		if memQuota.LimitSet && memQuota.Used+memreq > memQuota.Limit {
   			return false
   		}
  ```
  </details>

- **新增 `scaledQuotaLimit(resourceName, limit)`:配额加载期按"拥有该显存资源名的后端"的 MemoryFactor 把 limit 换算到用量单位,并对 `limit * MemoryFactor` 做 int64 溢出检测(溢出返 `(0, false)`)**。这是把缩放语义集中到入库一处的落点,也是本提交标题 "store quota memory limits scaled by memoryFactor" 的字面实现。
  <details><summary>代码依据 pkg/device/quota.go</summary>

  ```diff
  +func scaledQuotaLimit(resourceName string, limit int64) (int64, bool) {
  +	for _, val := range GetDevices() {
  +		names := val.GetResourceNames()
  +		if names.ResourceMemoryName != resourceName || names.MemoryFactor <= 1 {
  +			continue
  +		}
  +		if limit > math.MaxInt64/names.MemoryFactor {
  +			return 0, false
  +		}
  +		return limit * names.MemoryFactor, true
  +	}
  +	return limit, true
  +}
  ```
  </details>

- **`addQuotaLocked` 新增一个 warn 布尔参数;`UpdateQuota` 用 `equality.Semantic.DeepEqual(oldQuota.Spec.Hard, newQuota.Spec.Hard)` 算 `hardChanged`,只有 hard 限额真变了才重复告警**,避免每次无关 Update 都刷 warning。
  <details><summary>代码依据 pkg/device/quota.go</summary>

  ```diff
  -		q.addQuotaLocked(newQuota)
  +		hardChanged := oldQuota == nil || !equality.Semantic.DeepEqual(oldQuota.Spec.Hard, newQuota.Spec.Hard)
  +		q.addQuotaLocked(newQuota, hardChanged)
  ```
  </details>

- **配置校验 `validateRegisteredDevices` 新增 `memoryOwners`/`memoryFactors` 两张表:若两个后端声明同一个 `ResourceMemoryName` 却带不同 memoryFactor,直接报错**("其配额限额无法同时为两者缩放")。因为缩放现在是入库一次性完成、同一资源名只能有一个缩放系数,这是把该前提从隐含约定升级为启动期硬校验。
  <details><summary>代码依据 pkg/scheduler/config/config.go</summary>

  ```diff
  +		if names.ResourceMemoryName != "" {
  +			factor := max(names.MemoryFactor, 1)
  +			if previous, taken := memoryOwners[names.ResourceMemoryName]; !taken {
  +				memoryOwners[names.ResourceMemoryName] = commonWord
  +				memoryFactors[names.ResourceMemoryName] = factor
  +			} else if memoryFactors[names.ResourceMemoryName] != factor {
  +				errs = append(errs, fmt.Errorf("%s and %s both claim memory resource %q with different memoryFactor values; its quota limit cannot be scaled for both", previous, commonWord, names.ResourceMemoryName))
  +			}
  +		}
  ```
  </details>

- **nvidia 后端删掉包级 `MemoryFactor int64 = 1` 全局变量及其在 `InitNvidiaDevice` 里的赋值**;所有调用点(numa_refit_handler、webhook、score 的 awsneuron、cambricon、amd)同步去掉传给 `FitQuota` 的 memoryFactor 实参。缩放既已下沉到配额加载,检查侧不再需要各后端持有并透传这个系数。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -	MemoryFactor             int64 = 1
   	...
  -	MemoryFactor = nvconfig.MemoryFactor
   	...
  -	return device.GetLocalCache().FitQuota(ns, mem, MemoryFactor, core, NvidiaGPUDevice)
  +	return device.GetLocalCache().FitQuota(ns, mem, core, NvidiaGPUDevice)
  ```
  </details>

### 后续发展方向 [AI]
- 证据指向 HAMi 在**多后端共存(nvidia/cambricon/amd/awsneuron)下的 ResourceQuota 记账一致性**上继续收口:把"用量缩放单位 vs 限额未缩放单位"的历史错配收敛到配额入库单点,并以配置期校验堵住"多后端争同一显存资源名、缩放系数不唯一"的歧义。溢出保护(`math.MaxInt64/MemoryFactor`)说明已在防范大限额 × 大 factor 的 int64 回绕。证据只覆盖 quota/config/各后端 device.go 的签名与缩放改动,未见对应 e2e 或 ResourceQuota CRD 字段变更(本次无 `*_types.go`/`config/crd` 命中)。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=2b8f4e29c48bca376d4f6123d7c6ae7627aef579 branch=master release=v2.10.0 scanned=2026-11-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6736b0589049390ec945bd40dfb4769f9f043def branch=main release=— scanned=2026-11-01 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=77206460af6fa83cd0655b780a6df3ddb8578413 branch=main release=— scanned=2026-11-01 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=fff306dbb379c1e0e0a7935e3608db6a8b98cf7c branch=main release=ascend-device-plugin-0.2.1 scanned=2026-11-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-11-01 -->
