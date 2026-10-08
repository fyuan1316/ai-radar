# HAMi diff 雷达 2026-10-09

## 摘要
- **Ascend 第三种软切分模式 ENPU 落地(#3110)**:vNPU 配置从布尔 `hamiVnpuCore` 升级为字符串 `hamiVnpuMode`(template/hami-core/enpu,旧布尔标 Deprecated),新增 ENPU 三档调度策略(fixed-share/elastic/best-effort)与"同 DIE 不混模式"隔离——HAMi 对昇腾软切分的能力边界从"切显存"扩到"带 QoS 策略的弹性切分"。
- **分配越界校验抽成 vendor 共享内核(#3125)**:原本只在 NVIDIA 插件里的 `validateContainerAllocation`(issue #3041)上移为 `pkg/device/allocation.go` 的 `device.ValidateContainerAllocation`,并用 `CoresUnit` 类型区分各 backend 的算力记账单位——一处逻辑护住所有厂商插件,防 scheduler 写错 annotation 导致超分。
- **AMD 向 NVIDIA 功能对齐三连**:新增 `gpumem-percentage` 显存百分比请求(#3179)、`amd.com/numa-bind` 多卡 NUMA 亲和(#3186)、core 请求向上取整到整 WGP(#3174)。

## 当日重要改变
- Project-HAMi/HAMi [新能力][弃用/移除] Ascend 新增 ENPU 软切分模式,`VNPUs.HamiVnpuCore bool` 弃用、代之以 `HamiVnpuMode string`;证据 pkg/device/ascend/{vnpu.go,device.go} https://github.com/Project-HAMi/HAMi/pull/3110
- Project-HAMi/HAMi [新能力] 新增顶层文件 pkg/device/allocation.go,导出跨厂商 `ValidateContainerAllocation` + `CoresUnit` 类型;证据 pkg/device/allocation.go、pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go https://github.com/Project-HAMi/HAMi/pull/3125
- Project-HAMi/HAMi [新能力] AMD 新增 `amd.com/numa-bind` 注解与 `resourceMemoryPercentageName` 配置字段;证据 pkg/device/amd/device.go https://github.com/Project-HAMi/HAMi/pull/3186 https://github.com/Project-HAMi/HAMi/pull/3179

## Project-HAMi/HAMi: b5696344 -> 7b7d0381
- 比较: https://github.com/Project-HAMi/HAMi/compare/b56963440b27e6f2e5f6755315d148fdce6d8fd4...7b7d038150813eafe421dff3a2d93d7bf6f1f7bf | ahead=10 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **Ascend vNPU 配置模型从布尔改字符串,`hamiVnpuCore` 正式弃用(#3110)**。`VNPUs` 结构体删 `HamiVnpuCore bool`→主字段改 `HamiVnpuMode string`(template/hami-core/enpu),旧布尔降级为 `omitempty` Deprecated 字段、仅在新字段为空时作兜底;新增 `mode()` 解析 + `UnmarshalYAML` 在 scheduler 启动前就拒绝非法模式。这是配置契约变更(非 CRD,是 helm/yaml device config)。
  <details><summary>代码依据 pkg/device/ascend/vnpu.go</summary>

  ```diff
  -type VNPUs struct {
  -	HamiVnpuCore     bool         `yaml:"hamiVnpuCore"`
  +type VNPUs struct {
  +	HamiVnpuMode     string       `yaml:"hamiVnpuMode,omitempty"`
  +	EnpuPolicy       string       `yaml:"enpuPolicy,omitempty"`
   	OverwriteEnv     bool         `yaml:"overwriteEnv"`
   	RuntimeClassName string       `yaml:"runtimeClassName"`
   	Configs          []VNPUConfig `yaml:"configs"`
  +	// Deprecated: use HamiVnpuMode. Only applies when HamiVnpuMode is empty.
  +	HamiVnpuCore bool `yaml:"hamiVnpuCore,omitempty"`
  +}
  +func (v VNPUs) mode() (string, error) {
  +	switch mode := strings.ToLower(strings.TrimSpace(v.HamiVnpuMode)); mode {
  +	case "":
  +		if v.HamiVnpuCore { return VNPUModeHamiCore, nil }
  +		return VNPUModeTemplate, nil
  +	case "hamicore", VNPUModeHamiCore: return VNPUModeHamiCore, nil
  +	case VNPUModeTemplate, VNPUModeENPU: return mode, nil
  +	default: return "", fmt.Errorf("vnpus.hamiVnpuMode must be template, hami-core (or hamiCore), or enpu, got %q", v.HamiVnpuMode)
  ```
  </details>

- **ENPU 模式引入新注解与常量族,admission 对其专门放行(#3110)**。device.go 新增常量 `VNPUModeENPU="enpu"`、节点能力注解 `VNPUNodeENPUAnnotation="hami.io/enpu"`、`effectiveVNPUModeKey="hami.io/effective-vnpu-mode"`;`Devices` 结构体把 `hamiVnpuCore bool` 换成 `vnpuMode string`+`enpuPolicy string`。ENPU 容器只允许恰好 1 个 Ascend 设备、显存走精确 request(不做 template 裁剪),并把算力识别为"软切分"(`isSoftSlice`)。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  +	VNPUModeENPU               = "enpu"
  +	VNPUNodeENPUAnnotation     = "hami.io/enpu"
  +	effectiveVNPUModeKey       = "hami.io/effective-vnpu-mode"
  ...
  +	isSoftSlice := isHAMiCore || isENPU
  +	if isENPU && reqNum != 1 {
  +		return false, fmt.Errorf("ENPU mode supports exactly one Ascend device per container, got %d", reqNum)
  +	}
  +	if isENPU {
  +		if err := dev.validateENPUPolicy(p); err != nil { return false, err }
  +		p.Annotations["huawei.com/enpu-policy"] = dev.enpuPolicyForPod(p)
  ```
  </details>

- **ENPU 三档调度策略 + 同卡策略一致性/跨模式 DIE 隔离(#3110)**。新增策略归一化 `normalizeENPUPolicy`(fixed-share / best-effort / 默认 elastic),策略来源优先级:Pod 注解 `huawei.com/enpu-policy` > `huawei.com/scheduler.softShareDev.policy` 注解 > 同名 label。调度期 `enpuPolicyCompatible` 保证同一卡上已有 ENPU pod 策略必须一致才可共置;`softSliceModeCompatible` 保证 hami-core 与 ENPU 不落同一物理 DIE。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  +func normalizeENPUPolicy(value string) string {
  +	switch strings.ToLower(strings.TrimSpace(value)) {
  +	case "1", "fixed", "fixed-share", "fixed_share": return "fixed-share"
  +	case "3", "best-effort", "best_effort", "besteffort": return "best-effort"
  +	default: return "elastic"
  +	}
  +}
  +// softSliceModeCompatible keeps hami-core and ENPU on separate physical DIEs.
  +func softSliceModeCompatible(usage *device.DeviceUsage, enpu, nodeHamiCore bool) bool {
  +	for _, info := range usage.PodInfos {
  +		mode := info.Annotations[VNPUModeAnnotation]
  +		if enpu && (mode == VNPUModeHamiCore || (mode == "" && nodeHamiCore)) { return false }
  +		if !enpu && isENPUMode(mode) { return false }
  ```
  </details>

- **Fit 阶段按候选节点模式做过滤,并对"未声明 mode"的 Pod 延迟解析(#3110 + #3107)**。Fit 新增 ENPU 节点匹配(`isENPU && !nodeSupportENPU` 过滤)、ENPU 节点要求显式 `huawei.com/vnpu-mode: enpu`、template 不得落软切分节点;mode 为空的 Pod 的 template 显存裁剪从 admission 推迟到 Fit(因为 admission 不知道最终落哪个节点、节点模式才决定是否裁剪),`k` 是 per-Fit 副本不互相污染。
  <details><summary>代码依据 pkg/device/ascend/device.go (Fit)</summary>

  ```diff
  +	if isENPU && !nodeSupportENPU {
  +		reason[common.ModeNotFit]++
  +		return false, nil, common.GenReason(reason, len(devices))
  +	}
  +	if !isENPU && nodeSupportENPU && !nodeSupportHamiCore {
  +		klog.V(4).InfoS("Node filtered: ENPU node requires explicit huawei.com/vnpu-mode: enpu", ...)
  +	// Mode-agnostic Pods preserve their requested memory through admission.
  +	// Resolve template memory only after the candidate node's mode is known.
  +	if vnpuMode == "" && !nodeSupportHamiCore && npu.config.MemoryAllocatable > 0 && k.Memreq > 0 {
  +		trimmedMem, _ := npu.trimMemory(int64(k.Memreq))
  ```
  </details>

- **分配越界校验提升为跨厂商共享函数(#3125,issue #3041)**。新建 `pkg/device/allocation.go` 导出 `ValidateContainerAllocation` + 回调 `CardMemoryMB` + 枚举 `CoresUnit`;NVIDIA 插件删掉本地 `validateContainerAllocation`/`memoryLimitMB` 内联实现,改为一行调用共享函数并传 `CoresInRequestUnits`。`CoresUnit` 显式分流:NVIDIA/Hygon/Cambricon/Iluvatar/Mthreads/Biren/VastAI 按请求单位记账(可比对超分),AMD(存 CU 数)/AWS Neuron(存 bitmask)为 `CoresVendorEncoded` 只校验显存,MIG 因按 profile 容量计费直接跳过。
  <details><summary>代码依据 pkg/device/allocation.go(新增)+ nvidiadevice/.../util.go</summary>

  ```diff
  +// pkg/device/allocation.go(新文件)
  +type CoresUnit bool
  +const (
  +	CoresInRequestUnits CoresUnit = true   // NVIDIA/Hygon/Cambricon/Iluvatar/Mthreads/Biren/VastAI
  +	CoresVendorEncoded  CoresUnit = false  // AMD(CU 数)/AWS Neuron(bitmask)仅校验显存
  +)
  +func ValidateContainerAllocation(ctrName string, req ContainerDeviceRequest, allocated ContainerDevices, cardMemory CardMemoryMB, cores CoresUnit) error { ... }

  // util.go:NVIDIA 插件删本地实现改调共享
  -	for _, each := range allocated { ... plugin.memoryLimitMB(...) ... }
  -	return nil
  +	return device.ValidateContainerAllocation(ctr.Name, req, allocated, plugin.registeredMemoryMB, device.CoresInRequestUnits)
  ```
  </details>

- **AMD 支持显存百分比请求 + NUMA 亲和(#3179、#3186)**。`AMDConfig`/`AMDDevices` 新增 `ResourceMemoryPercentageName`,`memoryPercentage()` 校验 0–100 并在 `GenerateResourceRequests` 填进 `MemPercentagereq`,Fit 里按 `Totalmem*pct/100` 换算为实际 MB;新增 `amd.com/numa-bind` 注解,`assertNuma`+`prevnuma` 使一组多卡请求必须坐落同一 NUMA node(换 NUMA 即重置累积)。
  <details><summary>代码依据 pkg/device/amd/device.go</summary>

  ```diff
  +	AMDNumaBind     = "amd.com/numa-bind"
  +func assertNuma(annos map[string]string) bool {
  +	enforce, err := strconv.ParseBool(annos[AMDNumaBind]); return err == nil && enforce
  +}
  +	// numa-bind: a run of GPUs must share one NUMA node, so a new node starts the run over.
  +	if numa && prevnuma != dev.Numa {
  +		k.Nums = originReq; prevnuma = dev.Numa; tmpDevs = make(map[string]device.ContainerDevices)
  +	}
  +	if memReq <= 0 && k.MemPercentagereq > 0 && dev.Totalmem > 0 {
  +		memReq = max(int32(int64(dev.Totalmem)*int64(k.MemPercentagereq)/100), 1)
  ```
  </details>

- **nodelock:过期锁在 holder 仍待分配时不交给他人(#3127,issue #3096)**。新增 `podAwaitingAllocation`:锁过期(>NodeLockTimeout)时,若原 holder 仍 Pending 且注解 `hami.io/bind-phase=allocating`,则不把锁交给其它 pod——因为 kubelet 不向 device plugin 传 pod 身份,plugin 靠读这把锁判断在为谁分配,交错会让 holder 读到别人的分配。锁时间戳从 RFC3339 升级为 RFC3339Nano(同秒内与 pod 创建时间可比序)。
  <details><summary>代码依据 pkg/util/nodelock/nodelock.go</summary>

  ```diff
  +func podAwaitingAllocation(ctx context.Context, ns, name string, lockTime time.Time) (bool, error) {
  +	pod, err := client.GetClient().CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
  +	if pod.CreationTimestamp.After(lockTime) { return false, nil }
  +	return pod.Status.Phase == corev1.PodPending &&
  +		pod.Annotations[deviceBindPhaseAnnotation] == deviceBindAllocating, nil
  +	}
  // LockNode:过期分支
  +		if ns != pods.Namespace || previousPodName != pods.Name {
  +			waiting, err := podAwaitingAllocation(ctx, ns, previousPodName, lockTime)
  +			if waiting { return fmt.Errorf("node %s lock expired while %s/%s still waits to be allocated: %w", ...) }
  ```
  </details>

- **scheduler:缓存记账与解码失败事件修正(#2959)**。`onAddPod`/`onUpdatePod` 调整顺序——terminated 状态的 Pod 即使更新对象省略了 annotations 也要 `TakeAndDeletePod`+`RmUsage`(否则已完成 Pod 的用量一直挂账);解码 Pod 设备失败时新增 `recordAllocationDecodeFailureEvent` 向 Pod 发事件上报。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	nodeID, ok := pod.Annotations[util.AssignedNodeAnnotations]
  -	if !ok { return }
   	if util.IsPodInTerminatedState(pod) {
   		if pi, ok := s.podManager.TakeAndDeletePod(pod); ok { s.quotaManager.RmUsage(pod, pi.Devices) }
   		return
   	}
  +	assignedNodeName, ok := pod.Annotations[util.AssignedNodeAnnotations]
  +	if !ok { return }
  ...
  +		if pod.Spec.NodeName != "" { s.recordAllocationDecodeFailureEvent(pod, pod.Spec.NodeName, err) }
  ```
  </details>

- **vGPUmonitor:MIG 锁等待改为可被 context 取消(#3159)**。`WatchLockFile` 的信号通道从 `chan bool`(携带 create/remove 语义)改为无 payload 的 `chan struct{}`,watcher 停止时 `close(sigChan)`;新增 `IsMigApplyLockExist` 让调用方每次唤醒后主动查当前锁状态,从而等待循环能响应取消而非阻塞在布尔信号上。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/lock.go</summary>

  ```diff
  +func IsMigApplyLockExist() bool { return isMigApplyLockExist(MigApplyLockFile) }
  -func WatchLockFile() (chan bool, error) { ... }
  +func WatchLockFile() (chan struct{}, error) { ... }
  -		sigChan := make(chan bool, 1)
  +		sigChan := make(chan struct{}, 1)
  +		defer close(sigChan)
  ```
  </details>

- **打分与 Fit 的显存口径对齐(#3106)**。`DeviceListsScore.ComputeScore` 改为 Memreq 优先、仅在 Memreq 为 0 时才用百分比估算——与各 backend 在 Fit 里的解析顺序一致,避免"打分从百分比算、Fit 实按 Memreq 占用"导致设备看起来比真实更空。
  <details><summary>代码依据 pkg/scheduler/policy/gpu_policy.go</summary>

  ```diff
  -		if container.MemPercentagereq != 0 && container.MemPercentagereq != 101 {
  +		if container.Memreq == 0 && container.MemPercentagereq != 0 && container.MemPercentagereq != 101 {
   			mem += int32((int64(ds.Device.Totalmem) * int64(container.MemPercentagereq)) / 100)
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾软切分路线向"多后端 + QoS 策略"分层**:ENPU 作为独立于 hami-core 的第三后端,配 fixed-share/elastic/best-effort 三档策略与跨模式 DIE 隔离,说明 HAMi 不再把昇腾软切分当单一"切显存"能力,而是按底层虚拟化后端(template/hami-core/enpu,ENPU 还别名 ubs-virt/vcann-rt)分流调度。证据只覆盖 scheduler/admission 侧 diff(模式解析、节点过滤、策略一致性),未见 ENPU 运行时如何实际施加算力配额(HAMi-core/昇腾驱动侧本期 EMPTY)。
- **多厂商能力对齐正在被"共享内核化"推动**:越界校验上移到 `pkg/device/allocation.go` 并用 `CoresUnit` 显式编码各 backend 记账差异,是把"每厂商各写一份"的插件逻辑收敛为"一处定义+厂商声明单位"的信号;AMD 本期补齐显存百分比与 NUMA 亲和,也是沿 NVIDIA 的 annotation/config 范式填平差距。证据只覆盖 allocation.go + nvidia/amd 两处调用点,未逐一核对其余厂商插件是否都已切到共享函数。

## 本期无实质改动(折叠)
<details><summary>4 仓 EMPTY</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交(Release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI — 无新提交(Release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=7b7d038150813eafe421dff3a2d93d7bf6f1f7bf branch=master release=v2.10.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-09 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-09 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-09 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=54d4bdf02cb1a6d733c418809eb81d82d72c8d9e branch=main release=v1.3.0 scanned=2026-10-09 -->
</content>
</invoke>
