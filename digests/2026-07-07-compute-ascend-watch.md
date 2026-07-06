# 昇腾算力栈 diff 雷达 2026-07-07

## 摘要
- mind-cluster 单仓活跃(8 提交):device-plugin 抽象出 `PodManager` 接口,读 Pod 可**从 kubelet 本地 `/pods` 端点走**(而非只走 apiserver),给大规模集群卸 apiserver 压力;clusterd 把 device/node/switch 三处 ConfigMap 分片从"按条数固定切"重构为"按序列化字节数二分贪心切"(800KB/片),根治大 entry 撑爆 1MB CM 限制;故障码新增"亚健康网络故障(SubHealthFaultNetworkCodes)"分类。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)全无新提交。

## 当日重要改变
- mind-cluster [新能力] ascend-device-plugin 新增 `pkg/kubeclient/pod_manager.go`(228 行),定义 `PodManager` 接口 + `Apiserver`/`Kubelet` 两实现,由 `common.ParamOption.GetPodFromKubelet` 开关选择读 Pod 走 kubelet 还是 apiserver —— 目标是把 device-plugin 的 Pod 读流量从 apiserver 卸到节点本地 kubelet。证据文件 component/ascend-device-plugin/pkg/kubeclient/pod_manager.go、kubeclient.go。https://gitcode.com/Ascend/mind-cluster/compare/238ddec9ca5dad91516ab18fce8282c05b3c3d28...d46e4038f24e1e473ecd9ba3c851fc18192ba33a
- mind-cluster [架构方向] clusterd ConfigMap 安全分片从"按 entry 条数(2000/1000 条)"重构为"按序列化字节数二分贪心(≤800KB/片)",device/node/switch 三个 domain 统一收敛到泛型 `util.SplitMapToSafeChunks[T]`。证据文件 component/clusterd/pkg/common/util/util.go、pkg/domain/{device,node,switchinfo}/*_util.go。同上 compare 链接
- mind-cluster [新能力] 故障码体系新增 `SubHealthFaultNetworkCodes`(亚健康网络故障),`GetNetworkFaultTypeByCode` 增一分支返回 `SubHealthFault`。证据文件 component/ascend-device-plugin/pkg/common/fault_code.go

## mind-cluster: 238ddec9 -> d46e4038
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/238ddec9ca5dad91516ab18fce8282c05b3c3d28...d46e4038f24e1e473ecd9ba3c851fc18192ba33a | tag: v26.0.1 | commits=8 | truncated=false

### AI 总结重点(源码 diff 为据)

- **Pod 读写路径抽象为 `PodManager` 接口,支持"kubelet 直读"降 apiserver 负载**。新增 `PodManager` 接口(`GetPod/PatchPod/GetActivePodList/GetAllPodList/…`),两实现 `Apiserver{client}` 与 `Kubelet{client}`;`ClientK8s` 加 `apiserver`/`kubelet` 两字段,构造时 `initPodManagers()` 装配;`getChannel()` 依 `common.ParamOption.GetPodFromKubelet` 返回 kubelet 或 apiserver。原来直接 `ki.Clientset.CoreV1().Pods(...).Get(...)` 的调用点(`getPod`/`GetAllPodListCache`/`UpdatePodList`/`PodInformerInspector` 等)全部改为 `ki.getChannel().Xxx(...)` 转发,原实现降级为小写私有方法(`getPodFromApiserver`/`patchPodToApiserver`/`getActivePodListFromApiserver`…)。`GetPod` 签名加了 `ctx context.Context`(旧版硬编码 `context.Background()`)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/kubeclient/pod_manager.go + kubeclient.go</summary>

  ```diff
  + type PodManager interface {
  + 	GetPod(ctx context.Context, pod *v1.Pod) (*v1.Pod, error)
  + 	PatchPod(pod *v1.Pod, data []byte) (*v1.Pod, error)
  + 	GetActivePodList() ([]v1.Pod, error)
  + 	GetAllPodList() (*v1.PodList, error)
  + 	GetAllPodListCache() []v1.Pod
  + 	...
  + }
  + type Apiserver struct { client *ClientK8s }
  + type Kubelet   struct { client *ClientK8s }
  + func (ki *ClientK8s) getChannel() PodManager {
  + 	ki.initPodManagers()
  + 	if common.ParamOption.GetPodFromKubelet { return ki.kubelet }
  + 	return ki.apiserver
  + }
  ```
  ```diff
  - func (ki *ClientK8s) GetPod(pod *v1.Pod) (*v1.Pod, error) {
  + func (ki *ClientK8s) GetPod(ctx context.Context, pod *v1.Pod) (*v1.Pod, error) {
  + 	return ki.getChannel().GetPod(ctx, pod)
  + }
  + func (ki *ClientK8s) getPodFromApiserver(ctx context.Context, pod *v1.Pod) (*v1.Pod, error) {
  - 	v1Pod, err := ki.Clientset.CoreV1().Pods(pod.Namespace).Get(context.Background(), pod.Name, ...)
  + 	v1Pod, err := ki.Clientset.CoreV1().Pods(pod.Namespace).Get(ctx, pod.Name, ...)
  ```
  </details>

- **ConfigMap 分片:从"按条数固定切"改为"按序列化字节数二分贪心切"**。旧逻辑 `GetSafeData` 用常量 `safeDeviceSize=1000`/`safeNodeSize=2000`/`safeSwitchSize=2000` 按 map 条数切;新逻辑删掉这些常量,统一走泛型 `util.SplitMapToSafeChunks[T](data, maxCmDataSize, serialize)`,`maxCmDataSize = 800*1024`(注释:1MB CM 限制留 800KB 安全边际)。核心 `splitToCmChunks` 先整体序列化,超限则 `binarySearchMaxFit` 二分找"序列化后 ≤800KB 的最多前缀 key 数"切左片、递归切右片;单条就超限则单独成片并 `hwlog.Warnf("entry exceeds configmap size limit")`。旧法按条数切在"每条很大"时仍会撑爆 1MB、在"每条很小"时又浪费片数,新法按真实字节贴边打包。
  <details><summary>代码依据 component/clusterd/pkg/common/util/util.go + pkg/domain/device/device_util.go</summary>

  ```diff
  + func SplitMapToSafeChunks[T any](data map[string]T, maxSize int, serialize func(map[string]T) string) []string {
  + 	if len(data) == 0 { return []string{} }
  + 	return splitToCmChunks(data, maxSize, serialize)
  + }
  + func binarySearchMaxFit[T any](data map[string]T, keys []string, maxSize int, serialize ...) int {
  + 	low, high := 1, len(keys)
  + 	for low <= high {
  + 		mid := (low + high) / 2
  + 		// 序列化前 mid 个 key,≤maxSize 则右移,否则左移
  + 		if len(serialize(subset)) <= maxSize { low = mid + 1 } else { high = mid - 1 }
  + 	}
  + 	return high
  + }
  ```
  ```diff
  - const safeDeviceSize = 1000
  + const maxCmDataSize = 800 * 1024
  - // GetSafeData get data every 1000 DeviceInfo
  - if len(deviceInfos) <= safeDeviceSize { return []string{util.ObjToString(deviceInfos)} }
  - // ...按 %safeDeviceSize==0 切片
  + return util.SplitMapToSafeChunks(deviceInfos, maxCmDataSize,
  + 	func(m map[string]*constant.DeviceInfo) string { return util.ObjToString(m) })
  ```
  </details>

- **故障码新增"亚健康网络故障"分类 `SubHealthFaultNetworkCodes`**。`FaultTypeCode` 与 `faultFileInfo` 各加一字段;`LoadFaultCode` 加载并 `registerFaultCodeFormats`;`mappingChipFaultToNetworkFaultCodesSupport` 把命中 `NetworkFaultCodes` 的 `SubHealthFaultCodes` 归入网络故障;`GetNetworkFaultTypeByCode` 增一 `case` 返回 `SubHealthFault`。另附带:A950 参数面(parameter plane)故障发生/恢复补 Info 级日志打印(logicID + hex code + assertion + alarmRaisedTime),且默认分支的故障码日志格式 `%v`→`%x`(十六进制,便于对故障码手册)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
    type FaultTypeCode struct {
    	SubHealthFaultCodes        []int64
  + 	SubHealthFaultNetworkCodes []int64
    }
  + for _, faultCode := range faultTypeCode.SubHealthFaultCodes {
  + 	if NetworkFaultCodes.Has(faultCode) {
  + 		faultTypeCode.SubHealthFaultNetworkCodes = append(faultTypeCode.SubHealthFaultNetworkCodes, faultCode)
  + 	}
  + }
    // GetNetworkFaultTypeByCode:
  + case Int64Tool.SameElement(faultTypeCode.SubHealthFaultNetworkCodes, faultCodes):
  + 	return SubHealthFault
  - hwlog.RunLog.Debugf("not record fault code : %v, ...", faultCodes)
  + hwlog.RunLog.Debugf("not record fault code : %x, ...", faultCodes)
  ```
  </details>

- **提交标题另含两条 bugfix,但本次 patch 节选未覆盖对应 hunk,仅据标题记录不作符号级研判**:`rankTable level3 roce port 填充为 "d2h"`、`0x110000002 configmap 显示预隔离级别 bug 修复 + 日志整改`。前者关 rankTable(分布式训练组网表)三级 RoCE 端口填充值;后者关某故障码的预隔离(pre-separate)级别在 ConfigMap 的显示——与上面 fault_code.go 的日志整改/`%x` 改动应属同一批。(hunk 未见,证据仅提交标题)

### 后续发展方向 [AI]
- **device-plugin 去 apiserver 化**:`GetPodFromKubelet` 开关 + `Kubelet` 实现已落地接口骨架,方向是让每节点 device-plugin 读 Pod 走本地 kubelet `/pods`,规模化集群下显著降 apiserver QPS。证据只覆盖接口/转发层与 `getChannel` 分流,`Kubelet.GetPod` 具体 HTTP 拉取实现的 hunk 未在节选内(被 80 行截断),未见其如何解析 kubelet 返回、如何与 informer 缓存协同。
- **状态上报按字节控大**:ConfigMap 分片改字节贪心,指向"超大集群(数千节点/设备)下 device/node/switch 状态 CM 频繁触顶 1MB"的真实压力;泛型 `SplitMapToSafeChunks` 收敛三处重复逻辑,后续 switch/rankTable 类大对象大概率复用同一分片器。证据只覆盖分片算法本身,未见调用方对"多片 CM 命名/读侧重组"的改动。
- **故障语义细化到"亚健康 × 网络"象限**:故障码从"隔离/预隔离/亚健康"向"亚健康且属网络面"细分,配合 A950 参数面故障日志,指向 RoCE/参数面网络亚健康的可观测与差异化处置。证据只覆盖分类字段与 case 分支,未见上层(noded/调度)如何消费 `SubHealthFault` 网络类型做差异动作。

## 本期无实质改动(折叠)
<details><summary>8 个 openFuyao 仓无新提交</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- vNPU(75efcb9f,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(dbffd794,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=d46e4038f24e1e473ecd9ba3c851fc18192ba33a tag=v26.0.1 scanned=2026-07-07 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=v26.6.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=v26.6.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=vNPU sha=75efcb9f42057ad1549fdccc4edb64ba8f8657be tag=v0.1.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=npu-dra-plugin sha=dbffd7942b003f1bd4880861c167aa7a0410c9ca tag=v26.6.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-07 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-07 -->
