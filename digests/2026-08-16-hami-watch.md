# HAMi diff 雷达 2026-08-16

## 摘要
- HAMi 主仓 2 个 fix 提交,全是**厂商后端资源请求解析的健壮性加固**:hygon(DCU)/metax(sGPU)给 count/core/memory 补 int32 越界守卫(超界即返回空请求而非静默溢出),awsneuron 修正 init-container 存在时的容器索引错位。
- 无 API/CRD/proposal 变更,无弃用/版本跨档;软切分(vGPU/vNPU)核心语义本期未动。
- HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI 四仓无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- 无

## Project-HAMi/HAMi: 18323932 -> 51c593c0
- 比较: https://github.com/Project-HAMi/HAMi/compare/183239325af912a8ecd5cff19f99f1251c9acf8d...51c593c01a6a37cf41a6438feaa65ac1b62b16aa | ahead=2 | files=6 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)
- **hygon(DCU)`GenerateResourceRequests` 在 count / memory / core 三处补 int32 越界守卫**:此前 `n.AsInt64()`、`memnums.AsInt64()`、`corenums.AsInt64()` 拿到的 int64 直接 `int()`/`int32()` 窄化,超 `math.MaxInt32` 会静默截断成错误值。现在每处先判 `<=0 || > math.MaxInt32`(memory 还额外在 `*MemoryFactor` 之后再判一次溢出),超界直接 `klog.ErrorS` + 返回空 `ContainerDeviceRequest{}`,即拒绝该请求而非发出错误设备量。PR #2388,https://github.com/Project-HAMi/HAMi/pull/2388
  <details><summary>代码依据 pkg/device/hygon/device.go</summary>

  ```diff
  +		if n <= 0 || n > math.MaxInt32 {
  +			klog.ErrorS(nil, "dcu device count request is out of range", "container", ctr.Name, "request", n)
  +			return device.ContainerDeviceRequest{}
  +		}
   		klog.Info("Found dcu devices")
  ...
  +					if MemoryFactor > 1 {
  						rawMemnums := memnums
  						memnums = memnums * int64(MemoryFactor)
  +						if memnums > math.MaxInt32 {
  +							klog.ErrorS(nil, "dcu device memory request overflows int32 after applying memory factor", ...)
  +							return device.ContainerDeviceRequest{}
  +						}
  ```
  </details>
- **metax(sGPU)同一函数补对称守卫,且修正一处单位换算 bug**:vcount / vcore / vmemory 分别加 int32 范围判断;无单位分支原来是 `mem = v * MemoryFactor`(int × 常量,易溢出),改为先判 `v > math.MaxInt32/MemoryFactor` 再 `mem = v * int64(MemoryFactor)` 提升到 int64 运算,末尾再判 `mem > math.MaxInt32`。即从"乘完再看"改为"乘前拦 + int64 运算 + 乘后兜底"。新引入 `math` import。同 PR #2388。
  <details><summary>代码依据 pkg/device/metax/sdevice.go</summary>

  ```diff
  +	if count <= 0 || count > math.MaxInt32 {
  +		klog.ErrorS(nil, "metax sgpu device count request is out of range", ...)
  +		return device.ContainerDeviceRequest{}
  +	}
  ...
  -				mem = v * MemoryFactor
  +				if v < 0 || v > int64(math.MaxInt32)/int64(MemoryFactor) {
  +					klog.ErrorS(nil, "metax sgpu device memory request is out of range", ...)
  +					return device.ContainerDeviceRequest{}
  +				}
  +				mem = v * int64(MemoryFactor)
  ```
  </details>
- **awsneuron `PatchAnnotations` 修正 init-container 索引错位**:原代码用扁平索引 `pod.Spec.Containers[ctridx]` 取容器,当 Pod 含 InitContainers 时该索引对不上(设备列表的 ctridx 是跨 init+普通容器连续编号的),会取错容器甚至越界。新增 `getContainerByIndex` 先在 `InitContainers` 里找、减去其长度再落到 `Containers`,找不到返回 nil 并 `continue`。这修正了 init 容器申请 neuron 设备时注解索引写错的问题。PR #2173,https://github.com/Project-HAMi/HAMi/pull/2173
  <details><summary>代码依据 pkg/device/awsneuron/device.go</summary>

  ```diff
  +			ctr := getContainerByIndex(pod, ctridx)
  +			if ctr == nil {
  +				continue
  +			}
  			for _, val := range dp {
  -				devValue, ok := pod.Spec.Containers[ctridx].Resources.Limits[...]
  +				devValue, ok := ctr.Resources.Limits[...]
  ...
  +func getContainerByIndex(pod *corev1.Pod, ctridx int) *corev1.Container {
  +	if ctridx < len(pod.Spec.InitContainers) {
  +		return &pod.Spec.InitContainers[ctridx]
  +	}
  +	ctridx -= len(pod.Spec.InitContainers)
  +	if ctridx < len(pod.Spec.Containers) {
  +		return &pod.Spec.Containers[ctridx]
  +	}
  +	return nil
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 三个厂商后端(hygon/metax + 上期已见的 vastai/nvidia 线)在 `GenerateResourceRequests` 上正被逐个做**输入越界收敛**,模式一致(拒绝而非截断)。这是把"资源请求解析"从各后端各写一遍的散装校验往统一健壮性基线拉;但证据只覆盖 hygon/metax 两家本期改动,未见有人把这段守卫抽成公共 helper——目前仍是每个后端复制粘贴同款 int32 判断,存在后续统一抽象的空间。
- awsneuron 的修复暴露出一个通用假设:多个后端的 `PatchAnnotations`/索引逻辑可能都默认"设备索引 == Containers 下标",在有 initContainer 时同样会错。证据只覆盖 awsneuron 一家引入了 `getContainerByIndex`,未核查 nvidia/其它后端是否也有同类扁平索引写法待修。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core(5496322f,无新提交)
- Project-HAMi/volcano-vgpu-device-plugin(abe6919b,无新提交)
- Project-HAMi/ascend-device-plugin(771e19f8,无新提交)
- Project-HAMi/HAMi-WebUI(fa9b560d,Release hami-webui-1.2.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=51c593c01a6a37cf41a6438feaa65ac1b62b16aa branch=master release=v2.9.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-16 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=abe6919b389e98d33af1d8dd1c7d4fee6874102c branch=main release=— scanned=2026-08-16 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-16 -->
