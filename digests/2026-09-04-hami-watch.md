# HAMi diff 雷达 2026-09-04

## 摘要
- HAMi 主仓两个 bugfix:**修 padded 调度策略静默降级为 spread** 的正确性 bug——`" binpack "` 这类带空格注解通过校验却在排序时匹配不到任何分支、被当 spread 排,现统一 trim 归一(#2854);顺手删掉 numa_refit_handler 里重复的 `effectivePodDeviceUsage`(#2955)。
- 改动全在**调度器策略排序 + 计账辅助函数**层,未触及 HAMi-core CUDA hook 软切分,无 vNPU/昇腾/WebUI 侧变化。
- 其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI)本期全 EMPTY。

## 当日重要改变
- Project-HAMi/HAMi [正确性/无信号路径命中] `--gpu-scheduler-policy` 与 pod 注解里 padded(带首尾空格)的单值策略先前通过 `IsValidGPUSchedulerPolicy`(按逗号 token 逐个 trim 校验)却被原样存下,`DeviceUsageList.Less` 拿整串比对匹配不到 binpack/mutex 分支、静默落到 spread 默认分支——**binpack 注解实际按 spread 排,放置意图被反转**。修复:`GetGPUSchedulerPolicyByPod` 出口 trim 归一 + `Less` 内再防御性 trim。证据见下。https://github.com/Project-HAMi/HAMi/pull/2854

## Project-HAMi/HAMi: 95530c6a -> f47cd28a
- 比较: https://github.com/Project-HAMi/HAMi/compare/95530c6ad09c4f3cf8651cfe53a89eda69238a85...f47cd28ac603e9bb1a6bbfccfa310cc4747f1af4  | ahead=2 | 最新 Release v2.10.0

### AI 总结重点(源码 diff 为据)
- 新增 `normalizeSchedulerPolicy(policy)`:按逗号拆分后对每个 token `TrimSpace` 再 join,产出所有下游消费者(`Less` 整串比对、chain 分派 split)都能识别的规范形。这是这次修复的核心工具函数。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  +// normalizeSchedulerPolicy trims every comma-separated token so consumers
  +// that compare whole strings or split without trimming see canonical values.
  +func normalizeSchedulerPolicy(policy string) string {
  +	parts := strings.Split(policy, ",")
  +	for i := range parts {
  +		parts[i] = strings.TrimSpace(parts[i])
  +	}
  +	return strings.Join(parts, ",")
  +}
  ```
  </details>
- `GetGPUSchedulerPolicyByPod` 两处出口都过 `normalizeSchedulerPolicy`:(a) 集群默认 `--gpu-scheduler-policy` 是无校验自由串,padded 默认值同样会污染排序,故入口即归一;(b) 注解值即便通过校验也重新归一后再存。行为差异:此前 padded 单值原样透传到 `Less`,现在到达 `Less` 前已是 canonical 形。附带修一处日志——注解被拒时原来打印裸 `defaultPolicy`,现改打印实际生效的 `userGPUPolicy`。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -	userGPUPolicy := defaultPolicy
  +	// --gpu-scheduler-policy is a free-form string that nothing validates, so
  +	// a padded cluster default reaches DeviceUsageList.Less the same way a
  +	// padded annotation would.
  +	userGPUPolicy := normalizeSchedulerPolicy(defaultPolicy)
   	if task != nil && task.Annotations != nil {
   		if value, ok := task.Annotations[GPUSchedulerPolicyAnnotationKey]; ok {
   			if IsValidGPUSchedulerPolicy(value) {
  -				userGPUPolicy = value
  +				userGPUPolicy = normalizeSchedulerPolicy(value)
   			} else {
   				klog.Warningf("ignoring unrecognized %s=%q on pod %s/%s, using configured policy %q",
  -					GPUSchedulerPolicyAnnotationKey, value, task.Namespace, task.Name, defaultPolicy)
  +					GPUSchedulerPolicyAnnotationKey, value, task.Namespace, task.Name, userGPUPolicy)
  ```
  </details>
- `DeviceUsageList.Less` 内做二次防御:开头取 `policy := strings.TrimSpace(l.Policy)`,之后逗号判定、`GPUSchedulerPolicyNuma`/`binpack`/`mutex` 三处整串比对全改用 trim 后的 `policy`。原因:`Policy` 字段除了走 `GetGPUSchedulerPolicyByPod` 还会被直接从 `--gpu-scheduler-policy` 赋值,两条入口都要兜住。chain 路径(逗号形)不受影响——`gpuSortKeyChain` 早已对每个 token 自行 trim。
  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
   func (l DeviceUsageList) Less(i, j int) bool {
  +	policy := strings.TrimSpace(l.Policy)
  +
  -	if strings.Contains(l.Policy, ",") || l.Policy == util.GPUSchedulerPolicyNuma.String() {
  +	if strings.Contains(policy, ",") || policy == util.GPUSchedulerPolicyNuma.String() {
   		return l.lessByChain(i, j)
   	}
  -	binpack := l.Policy == util.GPUSchedulerPolicyBinpack.String()
  +	binpack := policy == util.GPUSchedulerPolicyBinpack.String()
  -	if l.Policy == util.GPUSchedulerPolicyMutex.String() {
  +	if policy == util.GPUSchedulerPolicyMutex.String() {
  ```
  </details>
- 删除 `numa_refit_handler.go` 里的重复函数 `effectivePodDeviceUsage`(按 `initReleased` 分派 `SteadyStateDeviceUsage` / `CollapseInitContainerUsage`)。这正是 9-03 digest 记录的那个"区分 init/app 计账"辅助函数——本次判定它与 device 包里同名逻辑重复,收敛到单一实现,消除双份维护面。
  <details><summary>代码依据 pkg/scheduler/numa_refit_handler.go</summary>

  ```diff
  -// effectivePodDeviceUsage mirrors the accounting shape stored by PodManager.
  -func effectivePodDeviceUsage(pod *corev1.Pod, raw device.PodDevices, initReleased bool) device.PodDevices {
  -	if initReleased {
  -		return device.SteadyStateDeviceUsage(pod, raw)
  -	}
  -	return device.CollapseInitContainerUsage(pod, raw)
  -}
  ```
  </details>

### 后续发展方向 [AI]
- 连续两日改动都在**调度策略/计账的边界正确性**收口:9-03 是 NUMA refit 的 init/app 计账竞态,今日是 padded 策略串归一 + 删重复计账辅助。方向是把 v2.10 GA 后暴露的"配置解析/排序一致性"长尾 bug 逐个夯实,而非加新能力。证据仅覆盖本次 util/policy/numa_refit 三文件 hunk,未验证 device 包内 `SteadyStateDeviceUsage`/`CollapseInitContainerUsage` 是否即 #2955 收敛的目标实现。
- 归一化选择了"出口 + 消费点双重 trim"而非单点治理,说明 `Policy` 字段有多条赋值入口(`--gpu-scheduler-policy` 直赋 + 注解路径),短期内不会重构成强类型枚举。证据只到 `Less` 与 `GetGPUSchedulerPolicyByPod` 两处,未排查是否还有第三条 `Policy` 赋值路径未被 trim 覆盖。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 f01e9f23,无 release tag)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 f6ae9160,release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=f47cd28ac603e9bb1a6bbfccfa310cc4747f1af4 branch=master release=v2.10.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-04 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-04 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-04 -->
