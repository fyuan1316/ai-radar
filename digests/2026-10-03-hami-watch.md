# HAMi diff 雷达 2026-10-03

## 摘要
- 主仓 HAMi 修复多 ResourceQuota 并存时的 GPU 配额判定:从"后写覆盖"改为跨对象取**最小值**生效,并跳过带 scope 的 ResourceQuota。企业级多租户 GPU 配额的正确性补强。
- 其余四仓(HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI)本期无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期唯一实质改动为配额判定 bugfix,未触及 API/CRD、弃用、架构方向、版本跨档或新 package 信号)

## Project-HAMi/HAMi: eb46ae6b -> a3107198
- 比较: eb46ae6b4b8c2ee83c5cae566c85c7a0e5bb77b9 -> a3107198 | ahead=2 | files=4 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/eb46ae6b4b8c2ee83c5cae566c85c7a0e5bb77b9...a3107198fb5766bff1a41049f6953239d24909d2

### AI 总结重点(源码 diff 为据)
- **多个 ResourceQuota 并存时,同一命名空间/资源的生效上限从"后写覆盖"改为跨对象取最小值。** 旧代码 `addQuotaLocked` 直接把每个 ResourceQuota 的 `value` 写进 `(*dp)[dn].Limit`,后处理的对象会覆盖先处理的——一个宽松配额能顶掉严格配额,导致实际上限被放大、配额失守。新代码加了 `QuotaManager.objectLimits`(`namespace -> quotaName -> resourceName -> limit`)逐对象留痕,再由新函数 `recalcLimitLocked` 遍历该命名空间下所有对象对同一资源取 `minLimit` 作为生效 `Limit`。`addQuotaLocked`/`delQuotaLocked` 改为"更新本对象条目 → 收集受影响资源 → 重算最小值"。(#3094)
  <details><summary>代码依据 pkg/device/quota.go</summary>

  ```diff
   type QuotaManager struct {
  -	Quotas map[string]*DeviceQuota
  -	mutex  sync.RWMutex
  +	Quotas       map[string]*DeviceQuota
  +	objectLimits map[string]map[string]map[string]int64 // namespace -> quotaName -> resourceName -> limit
  +	mutex        sync.RWMutex
   }

  +// recalcLimitLocked recalculates the effective limit for a namespace and resource
  +// by taking the minimum limit across all ResourceQuota objects in that namespace.
  +func (q *QuotaManager) recalcLimitLocked(namespace, resourceName string) {
  +	var minLimit int64
  +	var found bool
  +	if nsObjs, ok := q.objectLimits[namespace]; ok {
  +		for _, objLimits := range nsObjs {
  +			if limit, ok := objLimits[resourceName]; ok {
  +				if !found || limit < minLimit {
  +					minLimit = limit
  +					found = true
  +				}
  +			}
  +		}
  +	}
  +	...
  +		quotaInfo.Limit = minLimit
  +		quotaInfo.LimitSet = true

   // addQuotaLocked:旧逻辑直接覆盖,新逻辑先记对象条目再重算
  -			(*dp)[dn].Limit = value
  -			(*dp)[dn].LimitSet = true
  +			newObjLimits[dn] = value
  +			affectedResources[dn] = struct{}{}
  +	...
  +	for res := range affectedResources {
  +		q.recalcLimitLocked(quota.Namespace, res)
  +	}
  ```
  </details>
- **新增 `isScopedQuota`:带 `.Spec.Scopes` 或非空 `ScopeSelector.MatchExpressions` 的 ResourceQuota 被整体跳过(add 时不纳入、del 时也不触发全命名空间重算)。** 注释说明原因:HAMi 以命名空间粒度统计用量、`FitQuota` 不评估 pod scope,若纳入 scoped quota 会错误限制 scope 之外的 pod。即软切分配额的作用域被明确收窄为"仅无 scope 的 namespace 级 ResourceQuota"。
  <details><summary>代码依据 pkg/device/quota.go</summary>

  ```diff
  +// isScopedQuota returns true if the ResourceQuota defines scopes or non-empty scope selectors.
  +// HAMi tracks usage at namespace granularity and does not evaluate pod scopes in FitQuota,
  +// so scoped quotas are skipped to avoid over-restricting pods outside their scope.
  +func isScopedQuota(quota *corev1.ResourceQuota) bool {
  +	if quota == nil {
  +		return false
  +	}
  +	hasScopeSelector := quota.Spec.ScopeSelector != nil && len(quota.Spec.ScopeSelector.MatchExpressions) > 0
  +	return len(quota.Spec.Scopes) > 0 || hasScopeSelector
  +}

  + // addQuotaLocked 入口即挡掉 scoped quota
  +	if quota == nil || isScopedQuota(quota) {
  +		return
  +	}
  ```
  </details>
- 另一提交 `fix: disable cuda dnf repo to recover CI` (#3153) 仅为构建/CI 修复:两处 Dockerfile 把 `dnf install` 改为 `dnf --disablerepo=cuda install` 以恢复 CI,不涉及运行时能力。

### 后续发展方向 [AI]
- 配额子系统正从"单对象语义"向"多对象聚合语义"成熟:`objectLimits` 这层逐对象留痕是基础设施,后续可能在此之上支持更细的配额合并策略(当前只实现 min 取最严)。证据只覆盖 `quota.go` 的 add/del/recalc 路径,未见 `FitQuota` 消费侧是否同步调整,也未见对 `requests.` 维度(当前仅处理 `limits.`)的扩展。
- `isScopedQuota` 的注释显式承认 HAMi "不评估 pod scope、只做 namespace 粒度"——这是当前软切分配额的能力边界(对标原生 ResourceQuota 的 scope selector 尚是空白)。证据仅为该函数注释与跳过逻辑,未见 roadmap 层面是否计划补齐 scope 感知。

## 本期无实质改动(折叠)
<details><summary>4 仓本期无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=a3107198fb5766bff1a41049f6953239d24909d2 branch=master release=v2.10.0 scanned=2026-10-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-03 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-03 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=846c0e2d3360cc7240bb61968e4cc7e3cea53443 branch=main release=v1.3.0 scanned=2026-10-03 -->
