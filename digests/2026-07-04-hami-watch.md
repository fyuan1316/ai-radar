# HAMi diff 雷达 2026-07-04

## 摘要
- **HAMi-WebUI 修掉一个 init container 场景下设备解码错位/越界的 bug**:控制台之前解码 Pod 设备注解时,容器索引只按 `Spec.Containers` 计数,而注解本身是按 initContainers+containers 的合并顺序编码的——带 init 容器的 Pod 会导致设备/优先级张冠李戴甚至下标越界 panic。修复把索引空间统一到"含 init 容器"。
- 其余 4 仓(HAMi 主仓、HAMi-core、volcano-vgpu、ascend-device-plugin)本日无新提交。
- 本日无"重要改变"信号命中(WebUI 变更是纯 bugfix,不涉及 API/CRD/弃用/新能力)。

## 当日重要改变
- 无(WebUI 的改动属正确性 bugfix,未命中弃用/API-CRD/架构/版本跨档/新能力任一信号)

## Project-HAMi/HAMi-WebUI: 8f42445d -> c59f7769
- 比较: 8f42445d -> c59f7769 | ahead=2 | files=3 | Release: hami-webui-1.2.0
- 比较链接: https://github.com/Project-HAMi/HAMi-WebUI/compare/8f42445d325736655d467842cb762b75f2612d25...c59f77693238dc2f08b83c42c9e410bca04e81ed
- 修复提交: https://github.com/Project-HAMi/HAMi-WebUI/commit/7c3dc77312d8e86d85ad49fafe730cbd3c328f79 (PR #104: https://github.com/Project-HAMi/HAMi-WebUI/pull/104)

### AI 总结重点(源码 diff 为据)
- **设备解码的容器索引空间从"仅 Containers"扩到"initContainers + Containers"**:`DecodePodDevices` 里原来用 `len(pod.Spec.Containers)` 作为注解分片(按 `;` 切)的上界,现改用新增的 `podContainerCount(pod) = len(InitContainers)+len(Containers)`。因为 HAMi 调度侧写注解时是按 init+普通容器的合并顺序逐段编码的,WebUI 之前少算 init 容器数,带 init 容器的 Pod 会提前 `break` 丢分片或错位。NVIDIA / Hygon 两个分支的上界判断都同步改了。
  <details><summary>代码依据 server/internal/provider/util/util.go</summary>

  ```diff
  +func podContainerCount(pod *corev1.Pod) int {
  +	return len(pod.Spec.InitContainers) + len(pod.Spec.Containers)
  +}
  ...
   		case NvidiaGPUDevice:
   			for i, s := range strings.Split(str, OnePodMultiContainerSplitSymbol) {
  -				if i >= len(pod.Spec.Containers) {
  +				if i >= podContainerCount(pod) {
   					break
   				}
  ```
  </details>
- **不再丢弃空设备分片,保留位置占位**:同函数里删掉了 NVIDIA/Hygon 分支中 `if len(cd) == 0 { continue }` 的跳过逻辑——现在即使某容器(如 init 容器)不带设备,也会把空 `cd` 追加进结果,以保证下标与容器序一一对应。这是配合下游按位取值的前提。
  <details><summary>代码依据 server/internal/provider/util/util.go</summary>

  ```diff
   				if err != nil {
   					return PodDevices{}, nil
   				}
  -				if len(cd) == 0 {
  -					continue
  -				}
   				pd[devType] = append(pd[devType], cd)
  ```
  </details>
- **优先级提取同步纳入 init 容器,并抽出单容器 helper**:`GetContainerPriorities` 把原来内联的取值逻辑抽成 `getContainerPriority(ctr)`(优先取 Limits 再取 Requests 的 `nvidia.com/priority`),然后**先遍历 InitContainers 再遍历 Containers**,切片按合并长度预分配。保证优先级序列与上面的设备序列对齐。
  <details><summary>代码依据 server/internal/provider/util/util.go</summary>

  ```diff
  -func GetContainerPriorities(pod *corev1.Pod) []string {
  -	var priorities []string
  -	nvidiaPriority := corev1.ResourceName(NVIDIAPriority)
  -	for _, ctr := range pod.Spec.Containers {
  -		...
  -	}
  +func getContainerPriority(ctr corev1.Container) string { ... }
  +
  +func GetContainerPriorities(pod *corev1.Pod) []string {
  +	priorities := make([]string, 0, len(pod.Spec.InitContainers)+len(pod.Spec.Containers))
  +	for _, ctr := range pod.Spec.InitContainers {
  +		priorities = append(priorities, getContainerPriority(ctr))
  +	}
  +	for _, ctr := range pod.Spec.Containers {
  +		priorities = append(priorities, getContainerPriority(ctr))
  +	}
   	return priorities
   }
  ```
  </details>
- **消费端按 initContainerOffset 对齐取值,并加越界兜底**:`pod.go` 的 `fetchContainerInfo` 之前用 `bizContainerDevices[i]`(i 为普通容器序)直接取,与含 init 的注解序列错位、且可能越界 panic;现改为 `deviceIdx = len(InitContainers) + i`,并在 `deviceIdx < len(bizContainerDevices)` 时才取,否则用空值。优先级也从对齐后的 `containerDevices[0].Priority` 取。
  <details><summary>代码依据 server/internal/data/pod.go</summary>

  ```diff
  +	initContainerOffset := len(pod.Spec.InitContainers)
   	for i, ctr := range pod.Spec.Containers {
  +		deviceIdx := initContainerOffset + i
  +		var containerDevices biz.ContainerDevices
  +		if deviceIdx < len(bizContainerDevices) {
  +			containerDevices = bizContainerDevices[deviceIdx]
  +		}
   		c := &biz.Container{
   			...
  -			ContainerDevices: bizContainerDevices[i],
  +			ContainerDevices: containerDevices,
   		}
  -		if len(bizContainerDevices[i]) > 0 {
  -			c.Priority = bizContainerDevices[i][0].Priority
  +		if len(containerDevices) > 0 {
  +			c.Priority = containerDevices[0].Priority
  ```
  </details>

### 后续发展方向 [AI]
- 这是一次**控制台与调度侧注解编码约定对齐**的修复,信号是:HAMi 的 per-container 设备注解把 init 容器算进合并序列,是所有消费方(不止 WebUI)都必须遵守的隐式契约。WebUI 之前踩坑,说明该约定缺少显式规范/共享解码库,后续可能出现"把这套 decode 逻辑下沉成公共包"的重构诉求。证据只覆盖 WebUI 的 `util.go`/`pod.go` 两文件 + 新增测试,未见调度主仓侧的编码代码,无法确认双方是否已抽出共享实现。
- 新增的 `TestDecodePodDevicesWithInitContainers` 用例明确锚定了预期(init 容器占一个空槽、main 容器拿到设备与 priority),说明该路径此前无回归覆盖;方向上 WebUI 的 provider/util 测试正在补齐。

## 本期无实质改动(折叠)
<details><summary>本日无新提交的 repo(仅保锚点)</summary>

- Project-HAMi/HAMi(master, v2.9.0)— 无新提交
- Project-HAMi/HAMi-core(main)— 无新提交
- Project-HAMi/volcano-vgpu-device-plugin(main)— 无新提交
- Project-HAMi/ascend-device-plugin(main)— 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=430b458c75c37092b2ea48c8b17bd6d1cfcf45f4 branch=master release=v2.9.0 scanned=2026-07-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=8f3a89c67b037d8fdfe6c4cd4d8c4f0cd6504811 branch=main release=— scanned=2026-07-04 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-04 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=d7b365d2fce33fabefc779d24bab249d0cc4bbed branch=main release=— scanned=2026-07-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-04 -->
