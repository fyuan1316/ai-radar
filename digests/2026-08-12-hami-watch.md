# HAMi diff 雷达 2026-08-12

## 摘要
- 主仓 HAMi 本期 7 条实质提交,全是**并发安全硬化**:scheduler 的 nodeManager 和 device 的 PodManager 从"存/发调用方指针"改为**读写路径一律 DeepCopy**,堵住 metrics 采集协程与 informer 写入之间的 data race(尤其 cambricon 的 node lock 会原地改共享 Node 对象)。
- vGPUmonitor 侧修了两处 cache 读取:UUID 有效性判断收敛到 `IsValidUUID`,v0 共享内存 cache 的识别从硬编码 magic size `1197897` 改为 `[v0.MinSize, v1.MinSize)` 尺寸区间判别。
- 无 API/CRD/弃用/新 package 信号;HAMi-core、volcano-vgpu、ascend-device-plugin、WebUI 四仓无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- 无(本期无弃用/API-CRD/架构方向/版本跨档/新能力 信号命中;均为 bugfix 与文档)

## Project-HAMi/HAMi: 91f02483 -> 634bf2b3
- 比较: https://github.com/Project-HAMi/HAMi/compare/91f024838dc5cd428f428a08f3a6f259efa1bd1f...634bf2b3 | ahead=7 | files=14 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)
- **scheduler `nodeManager.addNode` 改为深拷贝存储**:此前更新已存在节点时直接把 `nodeInfo.Devices[vendor]` 指针塞进 map、并把 `nodeInfo.Node` 指针整体挂上;现在每个 vendor 的设备切片走 `device.DeepCopyDeviceInfos`,`Node` 走 `Node.DeepCopy()`,新建节点也用独立分配的 `stored` 结构。动机(见新增注释)是 `RegisterFromNodeAnnotations` 传进来的 `*corev1.Node` 直接取自 nodeLister 的共享 informer,cambricon 释放 node lock 时会原地写这同一个对象,导致 `GetNode`/`ListNodes` 在深拷贝时与之竞争。
  <details><summary>代码依据 pkg/scheduler/nodes.go</summary>

  ```diff
  -		if len(nodeInfo.Devices) > 0 {
  -			for vendor := range nodeInfo.Devices {
  -				m.nodes[nodeID].Devices[vendor] = nodeInfo.Devices[vendor]
  -			}
  +		for vendor := range nodeInfo.Devices {
  +			m.nodes[nodeID].Devices[vendor] = device.DeepCopyDeviceInfos(nodeInfo.Devices[vendor])
  +		}
  +		if nodeInfo.Node != nil {
  +			m.nodes[nodeID].Node = nodeInfo.Node.DeepCopy()
  +		} else {
  +			m.nodes[nodeID].Node = nil
  		}
  -		m.nodes[nodeID].Node = nodeInfo.Node
  	} else {
  -		m.nodes[nodeID] = nodeInfo
  +		stored := &device.NodeInfo{ ID: nodeInfo.ID, Devices: make(...) }
  +		if nodeInfo.Node != nil { stored.Node = nodeInfo.Node.DeepCopy() }
  +		for vendor, devices := range nodeInfo.Devices {
  +			stored.Devices[vendor] = device.DeepCopyDeviceInfos(devices)
  +		}
  +		m.nodes[nodeID] = stored
  	}
  ```
  </details>
- **`PodManager.GetPod` / `GetScheduledPods` 改为返回深拷贝**:`GetPod` 原样返回 map 里的 `*PodInfo`,现改成 miss 时返回 `(nil,false)`、命中时 `pi.DeepCopy()`;`GetScheduledPods` 原用 `maps.Copy` 只浅拷贝 map(键值仍是存储的 `*PodInfo` 指针),现逐条 `pi.DeepCopy()`。因为 metrics collector 在自己协程里 range `Devices`,而 `AddPod`/`UpdatePod` 会原地重写同一个 `PodInfo`,浅拷贝挡不住"concurrent map iteration and map write"。
  <details><summary>代码依据 pkg/device/pods.go</summary>

  ```diff
   func (m *PodManager) GetPod(pod *corev1.Pod) (*PodInfo, bool) {
  -	pi, ok := m.pods[pod.UID]
  -	return pi, ok
  +	pi, ok := m.pods[pod.UID]
  +	if !ok { return nil, false }
  +	return pi.DeepCopy(), true
   }
   ...
  -	// Return a shallow copy of the pods map to avoid race conditions.
  -	maps.Copy(podsCopy, m.pods)
  +	// Copy the entries, not just the map. ... AddPod and UpdatePod write to the
  +	// stored *PodInfo in place.
  +	for uid, pi := range m.pods {
  +		podsCopy[uid] = pi.DeepCopy()
  +	}
  ```
  </details>
- **vGPUmonitor 采集路径的 UUID 校验收敛到 `IsValidUUID`**:原来手写 `len(uuid) < 40` 判未初始化、再 `uuid[0:40]` 截断;现改为先 `c.Info.IsValidUUID(i)` 统一判定(#2465 同类 fix 用于 scrape path),再取 `DeviceUUID(i)[0:40]`,减少"共享内存未初始化时长度判断"的散落逻辑。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go</summary>

  ```diff
  -		uuid := c.Info.DeviceUUID(i)
  -		if len(uuid) < 40 {
  -			klog.Warningf("...invalid UUID length %d (shared memory not yet initialised)...", ...)
  +		if !c.Info.IsValidUUID(i) {
  +			klog.Warningf("...UUID not yet initialised; skipping until next scrape", ...)
  			continue
  		}
  -		uuid = uuid[0:40] // Ensure UUID is truncated to 40 characters
  +		uuid := c.Info.DeviceUUID(i)[0:40]
  ```
  </details>
- **v0 共享内存 cache 的识别从硬编码 size 改为版本尺寸区间**:新增 `v0.MinSize()`(= `unsafe.Sizeof(sharedRegionT{})`),`loadCache` 把"是不是 v0"从 `info.Size() == 1197897` 这个魔数等值判断,改成 `Size() >= v0.MinSize() && Size() < v1.MinSize()` 的区间判断,兼容 v0 结构体尺寸变化、并和 v1 的判别对齐。
  <details><summary>代码依据 pkg/monitor/nvidia/v0/spec.go + cudevshr.go</summary>

  ```diff
  +func MinSize() int {
  +	return int(unsafe.Sizeof(sharedRegionT{}))
  +}
  ...
  -	if info.Size() == 1197897 {
  +	if info.Size() >= int64(v0.MinSize()) && info.Size() < int64(v1.MinSize()) {
  		klog.Infoln("casting......v0")
  		usage.Info = v0.CastSpec(usage.data)
  ```
  </details>
- **文档:补充 ResourceQuota 与 init 容器配额核算的交互说明**(非代码行为变更):`initContainer-design.md` 新增一节,澄清 kube-apiserver 的 `requests.nvidia.com/gpumem` 配额按 `max(sum(app), max(init))` 在 Pod 创建时一次性计入、直到 Pod 进入 terminal 才释放——不随 init 容器结束而收缩,所以 HAMi 内部"init 结束后收缩配额"的设计只释放 HAMi 侧容量,apiserver 侧配额不动;这解释了"无配额能跑、设了配额反而被拒"的现象。
  <details><summary>代码依据 docs/develop/initContainer-design.md</summary>

  ```diff
  +## Interaction with Kubernetes ResourceQuota
  +... the apiserver ... charges this value only once, when the pod is created,
  +and it keeps the charge while the pod is non-terminal ...
  +It does not react when init containers finish, so the shrink in this design
  +only frees capacity inside HAMi.
  ```
  </details>

### 后续发展方向 [AI]
- 主线是**把 scheduler/monitor 里"共享 informer 对象被并发读写"的历史欠账逐个补深拷贝**:本期覆盖 nodeManager 与 PodManager 两处读路径,并配了针对性并发回归测试(`TestGetScheduledPodsCopiesEntries`、`TestAddNodeCopiesSharedNodeObject`,均用 20000 次读 + 后台写压测)。证据只覆盖 node/pod 两个 manager 的 get 路径,未见对其它缓存(如 device registry、annotation 缓存)是否也存在同类共享指针问题的处理。
- 监控子系统在向**多版本 cache 格式共存**演进:v0.MinSize/v1.MinSize 的尺寸区间判别取代魔数,说明共享内存结构还在迭代且要兼容旧文件;证据只覆盖 v0 判别与 UUID 校验收敛,未见 v1 结构本身是否有字段变更。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core(5496322f,无新提交)
- Project-HAMi/volcano-vgpu-device-plugin(abe6919b,无新提交)
- Project-HAMi/ascend-device-plugin(771e19f8,无新提交)
- Project-HAMi/HAMi-WebUI(fa9b560d,Release hami-webui-1.2.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=634bf2b32e68e07d3fbcbd6da1ee079392fc07c1 branch=master release=v2.9.0 scanned=2026-08-12 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-12 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=abe6919b389e98d33af1d8dd1c7d4fee6874102c branch=main release=— scanned=2026-08-12 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-12 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-12 -->
