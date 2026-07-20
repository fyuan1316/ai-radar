# HAMi diff 雷达 2026-07-21

## 摘要
- HAMi 主仓落地全新 **mutex GPU 调度策略**(#2011):在 nvidia/vastai/kunlun 三类设备的 `Fit` 里把"共享到已占用卡"改成"整卡独占",vastai die 模式下一颗 die 被占则同卡所有 die 均不可分配——软切分中间件补齐"整卡独占"这档调度语义。
- 同批引入 **numa-bind 亲和**(#1806 关联):`DeviceUsageList` 新增 `NumaBind` 字段,由 Pod 注解 `nvidia.NumaBind` 触发,让 `Fit` 能按 NUMA 连续累积同组设备。
- 另有 init-container GPU 配额核算的**设计文档**(#2064,仅设计未实现)和 Bind 的 goto→闭包重构(#2089)。HAMi-core/volcano/ascend/WebUI 四仓本日无实质改动。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增 mutex GPU 调度策略 `GPUSchedulerPolicyMutex`,整卡独占分配,横跨 nvidia/vastai/kunlun,冲突走 `ExclusiveDeviceAllocateConflict` 原因码 — pkg/scheduler/policy/gpu_policy.go、pkg/device/vastai/device.go、pkg/device/kunlun/vdevice.go — https://github.com/Project-HAMi/HAMi/pull/2011
- Project-HAMi/HAMi [新能力] 新增 numa-bind 亲和:`DeviceUsageList.NumaBind` 字段 + Pod 注解 `nvidia.NumaBind` 驱动同 NUMA 连续分配 — pkg/scheduler/scheduler.go、pkg/scheduler/policy/gpu_policy.go — https://github.com/Project-HAMi/HAMi/commit/06d9b907

## Project-HAMi/HAMi: 125c8c62 -> 53da8247
- 比较: 125c8c62 -> 53da8247 | ahead=4 | files=38 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/125c8c627e20fc85b82e1728a684ae5757741a5b...53da8247b1c2868b9b70de8fbf5462542950375b

### AI 总结重点(源码 diff 为据)

- **新增 `GPUSchedulerPolicyMutex` 排序档:排序把"忙卡在前、空闲卡置尾",配合 `Fit` 从尾部倒序遍历优先选到空闲整卡。**同时把原来 binpack/spread 里"NUMA 相等才比 Score"的两分支重写为 Score 主键、NUMA 兜底(#1806),并新增 `NumaBind` 分支保持 NUMA 组连续。
  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
   func (l DeviceUsageList) Less(i, j int) bool {
  -	if l.Policy == util.GPUSchedulerPolicyBinpack.String() {
  -		if l.DeviceLists[i].Device.Numa == l.DeviceLists[j].Device.Numa {
  -			return l.DeviceLists[i].Score < l.DeviceLists[j].Score
  +	si, sj := l.DeviceLists[i].Score, l.DeviceLists[j].Score
  +	ni, nj := l.DeviceLists[i].Device.Numa, l.DeviceLists[j].Device.Numa
  +	binpack := l.Policy == util.GPUSchedulerPolicyBinpack.String()
  +
  +	// mutex: busy GPUs first, idle GPUs at tail so Fit picks idle ones.
  +	if l.Policy == util.GPUSchedulerPolicyMutex.String() {
  +		ui, uj := l.DeviceLists[i].Device.Used, l.DeviceLists[j].Device.Used
  +		if ui != uj {
  +			return ui > uj
  +		}
  +		return ni < nj
  +	}
  ```
  </details>

- **`DeviceUsageList` 新增 `NumaBind bool` 字段**,并在 `DeepCopy` 里一并复制;含义:true 时 Fit 按 NUMA 分组累积同组设备,false 时 Score 主键、NUMA 仅做 tiebreaker。
  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
   type DeviceUsageList struct {
   	DeviceLists []*DeviceListsScore
   	Policy      string
  +	// NumaBind groups devices by NUMA so Fit can accumulate a same-NUMA run.
  +	// When false, Score is the primary key and NUMA only breaks ties (#1806).
  +	NumaBind bool
   }
  ```
  </details>

- **numa-bind 由 Pod 注解触发:新增 `numaBindingRequested(task)` 解析注解 `nvidia.NumaBind`(ParseBool),`buildNodeUsage` 据此给 `DeviceUsageList.NumaBind` 赋值**——调度亲和从"全局策略"细化到"按 Pod 声明"。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +// numaBindingRequested reports whether the pod requests numa-bind affinity.
  +func numaBindingRequested(task *corev1.Pod) bool {
  +	v, ok := task.Annotations[nvidia.NumaBind]
  +	if !ok {
  +		return false
  +	}
  +	enforce, err := strconv.ParseBool(v)
  +	return err == nil && enforce
  +}
   ...
   		Devices: policy.DeviceUsageList{
   			Policy:      userGPUPolicy,
  +			NumaBind:    numaBindingRequested(task),
  ```
  </details>

- **vastai 设备把 mutex 落到"物理卡(AIC)独占":die 模式下预计算 `occupiedAIC` 集合,某卡任一 die 被占则其兄弟 die 也判 `ExclusiveDeviceAllocateConflict`**——软切分设备也能表达"整物理卡独占",不只是"整逻辑设备独占"。
  <details><summary>代码依据 pkg/device/vastai/device.go</summary>

  ```diff
  +	isMutex := util.GetGPUSchedulerPolicyByPod(device.GPUSchedulerPolicy, pod) == util.GPUSchedulerPolicyMutex.String()
   	dieMode := isDieMode(devices)
  +	var occupiedAIC map[string]bool
  +	if isMutex && dieMode {
  +		occupiedAIC = make(map[string]bool)
  +		for _, d := range devices {
  +			if d.Used > 0 {
  +				if aic, ok := aicID(d.CustomInfo); ok {
  +					occupiedAIC[aic] = true
  +				}
  +			}
  +		}
  +	}
   ...
  +		if isMutex {
  +			conflict := dev.Used > 0
  +			if !conflict && dieMode {
  +				if aic, ok := aicID(dev.CustomInfo); ok && occupiedAIC[aic] {
  +					conflict = true
  +				}
  +			}
  +			if conflict {
  +				reason[common.ExclusiveDeviceAllocateConflict]++
  ```
  </details>

- **kunlun 设备 mutex:把 `graghSelect` 的 fit 函数替换为"仅 `d.Used == 0` 的空闲设备可选",且无空闲时回填 `ExclusiveDeviceAllocateConflict` 原因(而非笼统的 `NumaNotFit`)**,让拒绝原因对独占场景可解释。
  <details><summary>代码依据 pkg/device/kunlun/vdevice.go</summary>

  ```diff
  -	alloc := graghSelect(devices, request, FitVXPU)
  +	isMutex := util.GetGPUSchedulerPolicyByPod(device.GPUSchedulerPolicy, pod) == util.GPUSchedulerPolicyMutex.String()
  +	fitFn := FitFn(FitVXPU)
  +	if isMutex {
  +		// mutex: only idle devices are eligible, no sharing onto a used device.
  +		fitFn = func(d *device.DeviceUsage, r device.ContainerDeviceRequest) bool {
  +			return d.Used == 0 && FitVXPU(d, r)
  +		}
  +	}
  +	alloc := graghSelect(devices, request, fitFn)
  ```
  </details>

- **Bind 流程重构:删掉 `goto ReleaseNodeLocks` 标签,改成 `fail(e error)` 闭包统一"释放锁+记失败事件+返回 error"**,锁获取/注解 patch/Bind 三处失败均走同一收敛路径。纯重构,行为等价但错误处理路径更清晰。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +	fail := func(e error) (*extenderv1.ExtenderBindingResult, error) {
  +		klog.InfoS("Release node locks", "node", args.Node)
  +		s.releaseAllDevices(node, current)
  +		s.recordScheduleBindingResultEvent(current, EventReasonBindingFailed, []string{}, e)
  +		...
  +	}
   	if err = s.acquireNodeLocks(node, current); err != nil {
  -		goto ReleaseNodeLocks
  +		return fail(err)
   	}
  ```
  </details>

- **仅设计、未实现:新增 `docs/develop/initContainer-design.md`,提出 Pod GPU 占用应按 `effective = max(sum(app requests), max(single init request))` 核算**,修正当前 webhook 配额检查/`calcScore`/`AddUsage` 都把 init 与 app 容器请求简单相加、导致 init+app 顺序执行却被当作并发占用而误拒的问题。当前仅落文档三张 SVG 示意图,无对应代码改动。
  <details><summary>代码依据 docs/develop/initContainer-design.md</summary>

  ```diff
  +When a pod has both init containers and app containers requesting GPU
  +resources, HAMi allocates the resources simultaneously/parallelly. But
  +Kubernetes runs the init container sequentially to completion before any
  +app container starts, so init and app containers never execute at the same time.
  +...
  +effective = max( sum(app container requests), max(single init container request) )
  ```
  </details>

### 后续发展方向 [AI]
- mutex 策略目前已接线 nvidia/vastai/kunlun 三类设备,证据只覆盖这三处 `Fit`;其余厂商设备(cambricon/metax/enflame 等,本期只见 `_test.go` 改动)是否同步支持整卡独占,diff 未见,需后续跟踪。方向上 HAMi 正把调度语义从"共享优先"扩展到"独占/亲和可选",逐步逼近原生 device-plugin 的整卡分配能力,同时保留软切分。
- init-container 配额核算目前只有设计文档(#2064),`webhook.go`/`score.go`/`AddUsage` 的实际改造尚未落地;这是一条已明确的待实现路线,证据只覆盖设计文档本身,未见实现 PR。
- numa-bind 从注解驱动看是"按 Pod 声明的 NUMA 亲和",证据覆盖排序与 NodeUsage 构建,但 Fit 里"同 NUMA 连续累积"的具体消费逻辑本期 hunk 未完整展开(截断),需下期确认。

## 本期无实质改动(折叠)
<details><summary>4 仓 EMPTY(仅保锚点)</summary>

- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=53da8247b1c2868b9b70de8fbf5462542950375b branch=master release=v2.9.0 scanned=2026-07-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-21 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-21 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f062939e14354a96fb8bfabd3c103d9d8f6de6c2 branch=main release=— scanned=2026-07-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-21 -->
