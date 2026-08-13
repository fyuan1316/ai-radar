# HAMi diff 雷达 2026-08-14

## 摘要
- HAMi 主仓把 `gpu-scheduler-policy` 从**单值**升级为**逗号分隔的有序策略链**(#2621):新增 `numa` 排序键,binpack/spread/numa 按书写顺序链式排序,mutex/topology-aware 解耦为过滤器(经新 `PolicyContains` 在各后端 `Fit()` 里判断)。这是本期唯一新能力,改变了调度策略的语义模型。
- 两个稳定性修复:nvidia 设备在节点删除时清理 `ReportedGPUNum`/`ReportedRegisterAnnos`,堵住 map 无界增长 + 节点名复用后残留脏健康态(#2590);cambricon `ReleaseNodeLock` 从"改内存副本 + 全量 Update"改为"实时 Get + `MergePatch` 置 nil",修三个锁 bug(#2329)。
- 架构信号:新增 457 行设计文档,规划让 Cluster Autoscaler 复用 HAMi `/filter` 逻辑做扩容模拟,区分 warm / cold-zero 节点组的设备信息来源(#2528)。

## 当日重要改变
- Project-HAMi/HAMi [新能力] `gpu-scheduler-policy` 支持逗号分隔组合,新增 `numa` 排序键常量,mutex/topology-aware 由精确等值改为 `PolicyContains` 成员判断 —— pkg/util/types.go、pkg/scheduler/policy/gpu_policy.go、pkg/util/util.go https://github.com/Project-HAMi/HAMi/pull/2621
- Project-HAMi/HAMi [架构方向] 新增 CA scale-up 模拟设计文档 docs/develop/dry-run-filter-design.md(规划 CA 通过 HAMi filter 判断节点组扩容可行性) https://github.com/Project-HAMi/HAMi/pull/2528

## Project-HAMi/HAMi: 634bf2b3 -> 18323932
- 比较: https://github.com/Project-HAMi/HAMi/compare/634bf2b32e68e07d3fbcbd6da1ee079392fc07c1...18323932 | ahead=6 | files=25 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)

- **`gpu-scheduler-policy` 从单值精确匹配升级为逗号分隔的有序链**。此前 `DeviceUsageList.Less` 只按单一 policy 字符串等值判 binpack/spread;现在只要 policy 含 `,` 或裸值为 `numa` 就走新的 `lessByChain`,由 `gpuSortKeyChain` 把逗号串解析成去重的有序排序键(binpack/spread/numa),按书写顺序逐键比较。同时**新增 `numa` 作为排序键常量**(此前 numa 只是 `NumaBind` 隐式行为,无独立 policy 值)。

  <details><summary>代码依据 pkg/util/types.go</summary>

  ```diff
   	GPUSchedulerPolicyMutex SchedulerPolicyName = "mutex"
  +	// GPUSchedulerPolicyNuma is GPU use numa scheduler, chained as a sort key alongside binpack/spread.
  +	GPUSchedulerPolicyNuma SchedulerPolicyName = "numa"
  ```
  </details>

  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
  +var gpuSortKeyOrder = []util.SchedulerPolicyName{
  +	util.GPUSchedulerPolicyBinpack,
  +	util.GPUSchedulerPolicySpread,
  +	util.GPUSchedulerPolicyNuma,
  +}
  +// gpuSortKeyChain parses policy as a comma-separated ordered list ... deduplicated.
  +func gpuSortKeyChain(policy string) []util.SchedulerPolicyName { ... }

   func (l DeviceUsageList) Less(i, j int) bool {
  +	if strings.Contains(l.Policy, ",") || l.Policy == util.GPUSchedulerPolicyNuma.String() {
  +		return l.lessByChain(i, j)
  +	}
  +	// Single policy value: unchanged behavior.
   	si, sj := l.DeviceLists[i].Score, l.DeviceLists[j].Score
  ```
  </details>

- **mutex / topology-aware 与"排序键"解耦,改用 `PolicyContains` 成员判断**,使其可在组合链里生效。新增 `util.PolicyContains(policy, name)` 把 policy 当逗号串做成员测试;nvidia、vastai 的 `Fit()` 里 `isMutex`/`needTopology` 从 `== xxx.String()` 精确等值改为 `PolicyContains(...)`。含义:组合策略如 `binpack,mutex` 里,binpack 当排序键、mutex 当过滤器,两者不再互斥。

  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  +// PolicyContains reports whether policy names name, treating policy as a
  +// comma-separated ordered list (e.g. "binpack,numa"). A single value with no
  +// comma is compared directly, so existing single-policy callers are unaffected.
  +func PolicyContains(policy string, name SchedulerPolicyName) bool {
  +	target := name.String()
  +	for p := range strings.SplitSeq(policy, ",") {
  +		if strings.TrimSpace(p) == target { return true }
  +	}
  +	return false
  +}
  ```
  </details>

  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -	needTopology := gpuPolicy == util.GPUSchedulerPolicyTopology.String()
  -	isMutex := gpuPolicy == util.GPUSchedulerPolicyMutex.String()
  +	needTopology := util.PolicyContains(gpuPolicy, util.GPUSchedulerPolicyTopology)
  +	isMutex := util.PolicyContains(gpuPolicy, util.GPUSchedulerPolicyMutex)
  ```
  </details>

- **`lessByChain` 在链未命名任何排序键时回退 spread;`NumaBind` 场景强制把 numa 提到链首**,保证 Fit 的同-NUMA 连续累积不被打断。

  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
  +func (l DeviceUsageList) lessByChain(i, j int) bool {
  +	chain := gpuSortKeyChain(l.Policy)
  +	if len(chain) == 0 {
  +		chain = []util.SchedulerPolicyName{util.GPUSchedulerPolicySpread}
  +	}
  +	if l.NumaBind && chain[0] != util.GPUSchedulerPolicyNuma {
  +		// force numa as the primary key if the chain omits it.
  +		...
  +	}
  ```
  </details>

- **nvidia 设备在节点删除时清理 per-node 健康簿记,防 map 无界增长**。新增 `NvidiaGPUDevices.NodeDeleted(nn)`,在锁内 `delete` `ReportedGPUNum`、`ReportedRegisterAnnos`;`NodeCleanUp` 调它,`Scheduler.onDelNode` 遍历 `device.GetDevices()` 对 nvidia 实例调它。此前节点删除只清 lock 与 usage,健康簿记 map 会残留 → 无界增长 + 节点名复用时读到旧健康态。

  <details><summary>代码依据 pkg/device/nvidia/device.go / pkg/scheduler/scheduler.go</summary>

  ```diff
  +func (dev *NvidiaGPUDevices) NodeDeleted(nn string) {
  +	dev.mu.Lock(); defer dev.mu.Unlock()
  +	delete(dev.ReportedGPUNum, nn)
  +	delete(dev.ReportedRegisterAnnos, nn)
  +}
   func (dev *NvidiaGPUDevices) NodeCleanUp(nn string) error {
  +	dev.NodeDeleted(nn)
   	return util.MarkAnnotationsToDelete(HandshakeAnnos, nn)
   }
  --- scheduler.go onDelNode ---
  +	for _, devInstance := range device.GetDevices() {
  +		if nd, ok := devInstance.(*nvidia.NvidiaGPUDevices); ok {
  +			nd.NodeDeleted(nodeName)
  +		}
  +	}
  ```
  </details>

- **cambricon `ReleaseNodeLock` 修三 bug:实时 Get 替代传入的内存态、`MergePatch` 置 nil 替代全量 `Update`、重试内重读并短路**。原实现用传入的 `n`(可能过期)判 annotation、`DeepCopy`+`delete`+`Update`(整对象覆盖,易丢并发写);新实现先从 API `Get` 最新 node,用 `MergePatch` 把 `DsmluLockTime` 置 `nil`,重试时重新 Get、若锁已消失直接返回。`setNodeLock` 同步:去掉"已锁即报错"的前置判、`StrategicMergePatchType` 改 `MergePatchType`。

  <details><summary>代码依据 pkg/device/cambricon/device.go</summary>

  ```diff
   func (dev *CambriconDevices) ReleaseNodeLock(n *corev1.Node, p *corev1.Pod) error {
  -	if n.Annotations == nil { return nil }
  -	if _, ok := n.Annotations[DsmluLockTime]; !ok { ... return nil }
  -	newNode := n.DeepCopy()
  -	delete(newNode.Annotations, DsmluLockTime)
  -	_, err := client...Nodes().Update(ctx, newNode, metav1.UpdateOptions{})
  +	current, err := client...Nodes().Get(ctx, nodeName, metav1.GetOptions{})
  +	...
  +	patchData, _ := json.Marshal(map[string]any{"metadata": map[string]map[string]any{
  +		"annotations": {DsmluLockTime: nil}}})
  +	_, err = client...Nodes().Patch(ctx, nodeName, types.MergePatchType, patchData, ...)
  +	for i := 0; i < retry && err != nil; i++ {
  +		current, err = client...Nodes().Get(ctx, nodeName, ...)
  +		if current.Annotations == nil || current.Annotations[DsmluLockTime] == "" { return nil }
  +		_, err = client...Nodes().Patch(ctx, nodeName, types.MergePatchType, patchData, ...)
  +	}
  ```
  </details>

- **新增 CA scale-up 模拟设计文档(457 行,纯设计,未落地代码)**。docs/develop/dry-run-filter-design.md 论证 Cluster Autoscaler 无法只靠 Node `Allocatable` 表达 HAMi 的显存/算力/MIG/拓扑,需让 CA 复用 HAMi `/filter` 逻辑在内存快照里做假想调度;区分 warm 组(可从存量节点复用注册注解)与 cold-zero 组(size=0,需 provider 或额外配置提供 device profile)。当前仅设计,标注"未逐 PR 展开实现"。

  <details><summary>代码依据 docs/develop/dry-run-filter-design.md(节选)</summary>

  ```diff
  +# HAMi Scale-Up Simulation Design for Cluster Autoscaler
  +HAMi-managed device memory, compute shares, MIG configuration, and device
  +topology are not fully represented by [Capacity/Allocatable] fields. Without
  +consulting HAMi, CA sees an incomplete device model.
  +- A warm node group ... may be retained in the template.
  +- A cold-zero node group has a current size of 0 ... cannot copy the registration result
  ```
  </details>

### 后续发展方向 [AI]
- 调度策略正从"单一枚举值"走向"可组合的排序键链 + 过滤器"两层模型:`gpuSortKeyOrder` 明确把 binpack/spread/numa 归为排序键,mutex/topology-aware 归为过滤器(`PolicyContains` 判断)。这为后续叠加更多排序维度留了扩展点。证据只覆盖 gpu 后端(nvidia/vastai 改了 `PolicyContains`),未见 cambricon/ascend 等其它后端是否同步改用组合语义。
- CA 集成是明确的下一步架构方向,但**当前仅设计文档、无实现代码**:证据只覆盖 dry-run-filter-design.md 的问题陈述与 warm/cold-zero 分类,未见 filter extender 侧或 provider 侧的落地 PR,cold-zero 组的 device profile 来源仍是开放问题。
- nvidia 的 `NodeDeleted` 用类型断言 `*nvidia.NvidiaGPUDevices` 挂在 onDelNode 里,是设备接口尚未统一抽象出 `NodeDeleted` 方法的过渡形态;证据只覆盖 nvidia 一家有 per-node 健康簿记,未见接口层是否会把它提升为通用方法。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core(5496322f,无新提交)
- Project-HAMi/volcano-vgpu-device-plugin(abe6919b,无新提交)
- Project-HAMi/ascend-device-plugin(771e19f8,无新提交)
- Project-HAMi/HAMi-WebUI(fa9b560d,Release hami-webui-1.2.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=183239325af912a8ecd5cff19f99f1251c9acf8d branch=master release=v2.9.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-14 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=abe6919b389e98d33af1d8dd1c7d4fee6874102c branch=main release=— scanned=2026-08-14 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-14 -->
