# HAMi diff 雷达 2026-08-25

## 摘要
- HAMi 主仓落地**原生 sidecar 容器(K8s native sidecar = `restartPolicy: Always` 的 init 容器)GPU 资源核算**(#2723):调度、配额准入、init 容器折叠、资源回收四处统一改为"sidecar 与 app 容器并发常驻"的稳态模型,不再把 sidecar 当普通 init 容器在应用启动后释放显存/算力。
- 配套两条稳健性修复:vGPUmonitor 用安全 helper 替换会 panic 的 `MustNewConstMetric` 并把 init 容器纳入指标(#2716);nodelock 过期锁恢复改为串行化 + nil pod 防护(#2733)。
- 其余四仓(HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI)本期无新提交,仅保锚点续链。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增 `util.IsSidecarContainer()` 识别原生 sidecar,并把 sidecar 的显存/算力核算贯穿调度打分、配额准入、init 折叠与稳态回收全链路 https://github.com/Project-HAMi/HAMi/pull/2723 https://github.com/Project-HAMi/HAMi/commit/d961856d

## Project-HAMi/HAMi: 4707fb02 -> 2d42fb43
- 比较: 4707fb02c91c545bc7343ce26dba4c32919f9a3e -> 2d42fb43 | ahead=4 | files=15 | Release: v2.10.0
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/4707fb02...2d42fb43

### AI 总结重点(源码 diff 为据)

- **新增 sidecar 判定原语 `IsSidecarContainer()`**:以"init 容器且 `RestartPolicy == ContainerRestartPolicyAlways`"为准判定 K8s 原生 sidecar,成为后续所有核算分叉的开关。同时把 `AllInitContainersSucceeded` 重命名为 `AllNonSidecarInitContainersSucceeded`,改为遍历 `pod.Spec.InitContainers` 并按名字查 status,遇到 sidecar 直接 `continue`——否则常驻 sidecar 永远不"终止",资源回收永不触发。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  +func AllNonSidecarInitContainersSucceeded(pod *corev1.Pod) bool {
  +	if len(pod.Spec.InitContainers) == 0 {
  +		return false
  +	}
  +	statusByName := make(map[string]corev1.ContainerStatus, len(pod.Status.InitContainerStatuses))
  +	for _, s := range pod.Status.InitContainerStatuses {
  +		statusByName[s.Name] = s
  +	}
  +	for i := range pod.Spec.InitContainers {
  +		c := &pod.Spec.InitContainers[i]
  +		if IsSidecarContainer(c) {
  +			continue
  +		}
  +		s, ok := statusByName[c.Name]
  +		if !ok || s.State.Terminated == nil || s.State.Terminated.ExitCode != 0 {
  +			return false
  +		}
  +	}
  +func IsSidecarContainer(c *corev1.Container) bool {
  +	return c != nil && c.RestartPolicy != nil &&
  +		*c.RestartPolicy == corev1.ContainerRestartPolicyAlways
  +}
  ```
  </details>

- **资源回收从 "app-only" 改为 "steady-state"**:非 sidecar init 容器全部成功后,scheduler `onUpdatePod` 收缩用量时,把 `AppContainersOnlyDeviceUsage` 换成 `SteadyStateDeviceUsage`——稳态 = app 容器 + 常驻 sidecar,而非仅 app。日志也改成 "shrunk usage to steady state"。这是回收口径的语义修正:此前 sidecar 显存会在 init 阶段结束时被错误释放。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	if !pi.InitContainerResourceReleased && util.AllInitContainersSucceeded(newPod) {
  +	if !pi.InitContainerResourceReleased && util.AllNonSidecarInitContainersSucceeded(newPod) {
  ...
  -		appOnlyDevices := device.AppContainersOnlyDeviceUsage(newPod, rawDevices)
  -		oldDevices, ok := s.podManager.UpdatePodDevice(newPod, appOnlyDevices)
  +		steadyStateDevices := device.SteadyStateDeviceUsage(newPod, rawDevices)
  +		oldDevices, ok := s.podManager.UpdatePodDevice(newPod, steadyStateDevices)
  ```
  </details>

- **配额准入 `fitResourceQuota` 改用 peak 模型**:此前 init 请求取 `max(sum(app), max(init))`。新逻辑区分 sidecar 与普通 init:sidecar 累加(`sidecarMemoryReq += mem`)且并入 init 峰值,普通 init 取 `max(sidecarSum + 本容器)`;最终 `memoryReq = max(initPeak, sidecarSum + appSum)`。即准入时按"sidecar 常驻 + (init 峰值 或 app 全量)"的并发峰值收口,算力同理。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  -		var initMemoryReq, initCoresReq int64
  +		var initPeakMemoryReq, initPeakCoresReq int64
  +		var sidecarMemoryReq, sidecarCoresReq int64
  		for i := range pod.Spec.InitContainers {
  -			initMemoryReq = max(initMemoryReq, int64(req.Memreq)*int64(req.Nums))
  +			if util.IsSidecarContainer(c) {
  +				sidecarMemoryReq += mem
  +				initPeakMemoryReq = max(initPeakMemoryReq, sidecarMemoryReq)
  +				continue
  +			}
  +			initPeakMemoryReq = max(initPeakMemoryReq, sidecarMemoryReq+mem)
  		}
  -		memoryReq := max(appMemoryReq, initMemoryReq)
  +		memoryReq := max(initPeakMemoryReq, sidecarMemoryReq+appMemoryReq)
  ```
  </details>

- **打分/分配 `allocateInitContainers` 按容器类型走不同资源快照**:sidecar init 容器直接在 `appNodeCopy`(常驻、与 app 并发)上做 `fitInDevices` 并 `updatePeakUsage`;普通 init 容器仍在临时 `DeepCopy` 上试放(用后即弃)。另新增 `allocationTypeKeys()`,把请求侧类型(如 `NVIDIA`)与节点注册的型号级类型(如 `NVIDIA A100-SXM4-40GB`)取并集,避免补位时把已 fit 的行丢掉。(hunk 截断,未覆盖 `allocateAppContainers` 全量)
  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
  +		if _, isSidecar := sidecarIdx[i]; isSidecar {
  +			fit, reason := fitInDevices(appNodeCopy, req, task, nodeInfo, &initAllocs, weights)
  +			updatePeakUsage(peakUsage, appNodeCopy)
  +		} else {
  +			nodeCopy := appNodeCopy.DeepCopy()
  +			fit, reason := fitInDevices(nodeCopy, req, task, nodeInfo, &initAllocs, weights)
  +			updatePeakUsage(peakUsage, nodeCopy)
  +		}
  ```
  </details>

- **`CollapseInitContainerUsage` 重写为三态累积**:原用 `initPeak`/`appSum` 两个按 `deviceKey` 索引的 map,新版改为按 devType 分组、每 UUID 一个 `devState{sc, peak, app}`——`sc` 为已声明 sidecar 的滚动和、`peak` 为 init 阶段观测到的并发峰值、`app` 为 app 容器和。折叠有效用量的口径随之与上面几处对齐。(hunk 截断,未见最终合并公式)
  <details><summary>代码依据 pkg/device/initContainer.go</summary>

  ```diff
  -	initPeak := make(map[deviceKey]usage)
  -	appSum := make(map[deviceKey]usage)
  +	type devState struct {
  +		sc   usage // running sum of sidecars declared so far
  +		peak usage // peak concurrent usage observed during the init phase
  +		app  usage // sum over app containers
  +	}
  +		get := func(uuid string) *devState { ... }
  ```
  </details>

- **[稳健性] vGPUmonitor 去 panic + 纳入 init 容器**(#2716):把会在 channel 出错时 panic 的 `prometheus.MustNewConstMetric` 换成 `sendMetric()` 安全 helper(出错记日志不崩);`collectPodAndContainerInfo` 从只遍历 `pod.Spec.Containers` 改为拼接 `InitContainers + Containers` 一并采集——与上面 sidecar 常驻用量需要被监控到相呼应。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go</summary>

  ```diff
  -	ch <- prometheus.MustNewConstMetric(hostGPUdesc, prometheus.GaugeValue, float64(memory.Used), ...)
  +	if err := sendMetric(ch, hostGPUdesc, prometheus.GaugeValue, float64(memory.Used), ...); err != nil {
  +		klog.Errorf("Failed to send hostGPUdesc metric: %v", err)
  +	}
  -	for _, ctr := range pod.Spec.Containers {
  +	allContainers := make([]corev1.Container, 0, len(pod.Spec.InitContainers)+len(pod.Spec.Containers))
  +	allContainers = append(allContainers, pod.Spec.InitContainers...)
  +	allContainers = append(allContainers, pod.Spec.Containers...)
  +	for _, ctr := range allContainers {
  ```
  </details>

- **[并发修复] nodelock 过期锁恢复串行化**(#2733):`SetNodeLock`/`ReleaseNodeLock` 拆出 `*Locked` 内部实现;`LockNode` 现在自己先抢 per-node mutex 再读 annotation(此前直接委托 `SetNodeLock`,存在读-改-写竞态),并对 nil pod 早返回报错。避免多个 goroutine 同时"回收"同一个悬挂锁。
  <details><summary>代码依据 pkg/util/nodelock/nodelock.go</summary>

  ```diff
  +	if pods == nil {
  +		return fmt.Errorf("cannot lock node: pod is nil")
  +	}
  +	nodeLock := nodeLocks.getLock(nodeName)
  +	nodeLock.Lock()
  +	defer nodeLock.Unlock()
  	...
  -		return SetNodeLock(nodeName, lockname, pods)
  +		return setNodeLockLocked(nodeName, lockname, pods)
  ```
  </details>

### 后续发展方向 [AI]
- HAMi 正把资源核算模型从"init/app 二分"升级为"sidecar 常驻并发"三态,对齐 K8s 1.29+ 原生 sidecar(KEP-753)。证据覆盖调度打分、配额准入、init 折叠、稳态回收、监控五处的对称改动;**未见** CRD/API 层字段变更(本期无 `*_types.go`/`config/crd` 命中),说明这是纯行为语义修正而非接口扩展,存量用户无需改 YAML 即可获得正确的 sidecar 显存核算。
- 方向落点:对我们产品的启示——若产品栈也做 vGPU 配额/准入,需同样区分原生 sidecar(如 istio-proxy、日志/监控 agent 挂 GPU 的场景),否则会在 init 阶段结束时误释放常驻 sidecar 的显存,导致后续 app 容器 OOM 或超卖。证据只覆盖 HAMi 软切分路径,未见 DRA 原生路径的对应处理。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 b216ba1b)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 4fb76ba1)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,Release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 fa9b560d,Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=2d42fb43366252bea161000799e46bed103fad63 branch=master release=v2.10.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=b216ba1be1b8e21488d1c7370ed3357b3049aad1 branch=main release=— scanned=2026-08-25 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-25 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-25 -->
