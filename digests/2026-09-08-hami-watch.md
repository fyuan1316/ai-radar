# HAMi diff 雷达 2026-09-08

## 摘要
- **HAMi 主仓昇腾 vNPU 迎来第三种切分模式 `template`(硬切分)**:此前只区分 `hami-core`(软切分)与隐式,现显式引入 `template` 常量,并在准入/调度双侧落地——core 请求缺 mode 注解时自动推断为 hami-core,template 与 hami-core 节点互斥过滤。这是 HAMi 昇腾软/硬切分语义的一次收敛。
- 调度器修一处**注解缺失删除会漏清配额**的隐患:onDelPod 改以 UID-keyed 缓存为真相源,不再依赖删除对象上的 `AssignedNodeAnnotations`。
- NVIDIA device-plugin 加一道 `Allocate` 空 DevicesIds 防护,堵 index-out-of-range panic。其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI)全 EMPTY。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 昇腾 vNPU 新增 `template`(硬切分)模式常量 `VNPUModeTemplate`,与既有 `hami-core` 软切分并列成三态语义。证据 pkg/device/ascend/device.go,PR https://github.com/Project-HAMi/HAMi/pull/2970 与 https://github.com/Project-HAMi/HAMi/pull/2975

## Project-HAMi/HAMi: a0523ebd -> 1092ba20
- 比较: https://github.com/Project-HAMi/HAMi/compare/a0523ebd240d2db334ff94864777de565ec2e5be...1092ba203998fb5acb77aefc149cad715cd67719 | ahead=4 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **昇腾 vNPU 引入第三种模式 `template`(硬切分),补齐 hami-core(软切分)之外的常量语义**。新增常量 `VNPUModeTemplate = "template"`,与既有 `VNPUModeHamiCore = "hami-core"` 并列;`Fit()` 里新增 `isTemplate` 判定,当 pod 请求 template 模式但落到支持 hami-core 的节点时,直接以 `ModeNotFit` 过滤该节点——即软/硬切分节点互斥,不再只有"是否支持 hami-core"单向判断。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  	VNPUModeHamiCore           = "hami-core"
  +	VNPUModeTemplate           = "template"
  ...
  	isHAMiCore := (vnpuMode == VNPUModeHamiCore)
  +	isTemplate := (vnpuMode == VNPUModeTemplate)
  ...
  +	if isTemplate && nodeSupportHamiCore {
  +		reason[common.ModeNotFit]++
  +		klog.V(4).InfoS("Node filtered: pod requests template mode but node uses hami-core", "pod", klog.KObj(pod))
  +		return false, nil, common.GenReason(reason, len(devices))
  +	}
  ```
  </details>

- **准入侧:core 资源请求缺 `vnpu-mode` 注解时,不再直接拒绝,而是自动推断为 hami-core 并回写注解(#2975)**。旧逻辑是"非 hami-core 却请求了 core 资源 → 一律报错拒绝";新逻辑收窄为:仅当显式声明为 `template` 时才拒 core 请求,注解缺失则推断成 hami-core、写回 `p.Annotations` 并 log。等于把"core 资源"当作 hami-core 软切分的隐式信号,降低用户忘写注解时的准入摩擦。
  <details><summary>代码依据 pkg/device/ascend/device.go (MutateAdmission)</summary>

  ```diff
  -		if ok && coreQ.Value() > 0 {
  -			return false, fmt.Errorf("%s is only supported in hami-core (soft split) mode", dev.config.ResourceCoreName)
  +		if ok && coreQ.Value() > 0 {
  +			if vnpuMode == VNPUModeTemplate {
  +				return false, fmt.Errorf("%s is only supported in hami-core (soft split) mode", dev.config.ResourceCoreName)
  +			}
  +			if p.Annotations == nil {
  +				p.Annotations = map[string]string{}
  +			}
  +			p.Annotations[VNPUModeAnnotation] = VNPUModeHamiCore
  +			isHAMiCore = true
  +			klog.InfoS("Inferred hami-core vnpu mode from core request", "pod", klog.KObj(p), "core", coreQ.Value())
  ```
  </details>

- **调度器 `onDelPod`:注解缺失的删除事件不再被静默跳过,改以 UID-keyed 缓存做清理真相源(#2968)**。旧逻辑先检查 `pod.Annotations[util.AssignedNodeAnnotations]`,不存在就 `return`——但 informer 的 delete 通知常带残缺 Pod 对象(注解可能已丢),导致该删的配额没删。新逻辑删掉这层前置检查,直接走 `TakeAndDeletePod`(按不可变 UID 键)清 `quotaManager` 用量。测试同时覆盖 tombstone(`DeletedFinalStateUnknown`)、幂等重复删、旧 UID 不误删同名替换 pod 三种边界。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	_, ok = pod.Annotations[util.AssignedNodeAnnotations]
  -	if !ok {
  -		return
  -	}
  +	// Delete notifications can contain incomplete Pod objects. The cached
  +	// allocation, keyed by the immutable UID, is the cleanup source of truth.
  	if pi, ok := s.podManager.TakeAndDeletePod(pod); ok {
  		s.quotaManager.RmUsage(pod, pi.Devices)
  	}
  ```
  </details>

- **NVIDIA device-plugin `Allocate` 加空 DevicesIds 防护,堵 index-out-of-range panic(#2956)**。kubelet 发来空 `DevicesIds` 的 container 请求时,旧代码后续按下标取设备会越界 panic;新逻辑提前判 `len(req.DevicesIds) == 0` 即标记 `PodAllocationFailed` 并返错,对齐上游 k8s-device-plugin 同款守卫。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  	for idx, req := range reqs.ContainerRequests {
  +		if len(req.DevicesIds) == 0 {
  +			PodAllocationFailed(nodename, current, NodeLockNvidia)
  +			return nil, fmt.Errorf("invalid allocation request with no devices requested")
  +		}
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾 vNPU 的软/硬切分正在从"隐式约定"走向"显式三态状态机"**:`hami-core`(软切分)/ `template`(硬切分)/ 缺省推断,配合调度侧节点互斥过滤。证据覆盖 device.go 的常量、MutateAdmission、Fit 三处;`device_test.go` 里 `Template{Name:"vir08", Memory:8738, AICore:8}` 显示 template 模式会把切分固化为预置规格(`temp` 字段编码),而非 hami-core 的自由 core/memory。证据只覆盖准入/调度的模式分流与注解回写,**未见 HAMi-core 侧对 template 硬切分的运行时 enforcement 改动**(HAMi-core 本期 EMPTY),硬切分的实际隔离是否落在 device-plugin/驱动层尚不能从本 diff 判断。
- 调度器这轮修复方向是**生命周期清理的健壮性**(残缺删除对象、tombstone、UID 复用),属配额账本正确性收口,非新能力;与近日 scheduler_pod_lifecycle 系列测试连续加固一脉相承。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 f01e9f23,无 release tag)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 f6ae9160,release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=1092ba203998fb5acb77aefc149cad715cd67719 branch=master release=v2.10.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-08 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-08 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-08 -->
