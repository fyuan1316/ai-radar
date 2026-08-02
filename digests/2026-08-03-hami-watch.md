# HAMi diff 雷达 2026-08-03

## 摘要
- 主仓 HAMi 单提交:修 vGPU 调度器 `onDelQuota` 无法处理 informer tombstone(`DeletedFinalStateUnknown`)的缺陷——删 ResourceQuota 时若走 tombstone 路径,旧逻辑直接类型断言失败、静默返回,导致该命名空间的 GPU 显存配额上限残留、后续调度按幽灵配额卡额。属多租户配额记账正确性修复。
- 其余 4 仓(HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI)本期无新提交,软切分内核与昇腾 vNPU 路径继续静默。

## 当日重要改变
无(未命中弃用/API-CRD/架构/版本跨档/新能力信号;本期唯一改动为调度器 bugfix)。

## Project-HAMi/HAMi: 57bda659 -> 65f59ae4
- 比较 / 最新 Release:57bda659af113fb2941d5ae93ed2cceb3c9a67ec -> 65f59ae4 | ahead=1 | files=2 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)
- `pkg/scheduler/scheduler.go` 的 `onDelQuota(obj any)` 从"单一类型断言 + 失败即弃"改为 `switch` 双分支:除直接的 `*corev1.ResourceQuota` 外,新增 `cache.DeletedFinalStateUnknown` 分支,从 tombstone 的 `.Obj` 里还原 ResourceQuota 再交给 `s.quotaManager.DelQuota(quota)`。前:informer 在 watch 断连/重放时投递的删除事件被包成 `DeletedFinalStateUnknown`,旧代码断言失败只打印 `unknown del object type` 并 `return`,`DelQuota` 从不执行——该命名空间的 GPU 显存配额上限(`Limit`)永久残留;后:tombstone 也能正确清账,`default` 分支才落到"未知类型"错误。

  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  func (s *Scheduler) onDelQuota(obj any) {
  -	quota, ok := obj.(*corev1.ResourceQuota)
  -	if !ok {
  -		klog.Errorf("unknown del object type")
  +	var quota *corev1.ResourceQuota
  +
  +	switch t := obj.(type) {
  +	case *corev1.ResourceQuota:
  +		quota = t
  +	case cache.DeletedFinalStateUnknown:
  +		var ok bool
  +		quota, ok = t.Obj.(*corev1.ResourceQuota)
  +		if !ok {
  +			klog.Errorf("resource quota tombstone contained object of type %T", t.Obj)
  +			return
  +		}
  +	default:
  +		klog.Errorf("unknown resource quota delete object type %T", obj)
  		return
  	}
  +
  	s.quotaManager.DelQuota(quota)
  }
  ```
  </details>

- 配套新增两个单测锁定行为:`TestSchedulerOnDelQuotaClearsLimitFromTombstone` 断言通过 tombstone 删除后 `namespaceQuota[resourceName].Limit` 从 1024 归 0(证明清账生效);`TestSchedulerOnDelQuotaIgnoresInvalidObjects` 断言非法对象不误伤已有配额。用的是 NVIDIA GPU 的 `ResourceMemoryName` 显存配额维度,佐证此路径专治 vGPU 显存配额记账。

  <details><summary>代码依据 pkg/scheduler/scheduler_test.go</summary>

  ```diff
  +	s.onDelQuota(cache.DeletedFinalStateUnknown{
  +		Key: namespace + "/" + quota.Name,
  +		Obj: quota,
  +	})
  +
  +	quotas = s.quotaManager.GetResourceQuota()
  +	namespaceQuota, ok = quotas[namespace]
  +	require.True(t, ok)
  +	require.Equal(t, int64(0), (*namespaceQuota)[resourceName].Limit)
  ```
  </details>

### 后续发展方向 [AI]
- 纯健壮性修复,非能力扩张:证据只覆盖 `onDelQuota` 一条事件回调 + 两个单测,反映 HAMi 在把 ResourceQuota 作为 vGPU 多租户配额上限载体后,正逐一补齐 informer 生命周期边角(tombstone/重放)的账目一致性。未见配额语义本身(如新增算力/显存维度、跨命名空间配额)的改动,不宜外推为配额模型升级。

## 本期无实质改动(折叠)
<details><summary>4 仓无实质改动</summary>

- Project-HAMi/HAMi-core:无新提交(CUDA hook 时分软切分内核本期静默)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交(昇腾 vNPU 虚拟化路径本期静默)
- Project-HAMi/HAMi-WebUI:无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=65f59ae495ce9b52fd15406c310d14295bb675c8 branch=master release=v2.9.0 scanned=2026-08-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a branch=main release=— scanned=2026-08-03 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-08-03 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ffadaa96270de157fbe461be321f7b17c79a16de branch=main release=— scanned=2026-08-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-03 -->
