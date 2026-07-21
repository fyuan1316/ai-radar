# 昇腾算力栈 diff 雷达 2026-07-22

## 摘要
- 仅 `Ascend/mind-cluster` 有实质改动(8 openFuyao 仓全 EMPTY 保锚点)。当日两条重点均在 K8s 算力栈边缘/推理侧:① ascend-device-plugin 给 **kubelet 直连模式补齐真正的 Pod Informer**——新增 357 行轮询式 `kubeletPodInformer`,并给热复位 SyncResetCM 加 nil-guard,修掉此前 kubelet 场景 `PodInformer` 为 nil 直接空指针 panic 的问题;② ascend-for-volcano 把抢占/回收失败分支从 `Abstain` 全线改为 `Reject`,并修 chip4node8(4P mesh)亲和场景下的可用 chip 判据。
- GitCode compare `truncated=true`(files 列表 300 上限截断),本篇 hunk 手动拉取补齐关键信号文件,但可能有次要文件未覆盖。

## 当日重要改变
- mind-cluster [新能力+修复] ascend-device-plugin kubelet 模式从"跳过 pod informer"升级为真正的轮询式 Pod Informer(5s 拉取 kubelet /pods,diff 合成 add/update/delete 事件),使无 apiserver 直连的边缘/推理节点也能驱动热复位、soft-share 删除等 pod 事件 handler;配套修掉 kubelet 场景 `PodInformer==nil` 的空指针 panic。证据 `component/ascend-device-plugin/pkg/kubeclient/kubelet_informer.go`(新增)+ `pkg/kubeclient/pod_manager.go` + `pkg/device/ascendtolerance.go`。https://gitcode.com/Ascend/mind-cluster/commit/b6e6717ee5c39e4e7d68c3d285d69fdefff056ae
- mind-cluster [调度语义] ascend-for-volcano 抢占/回收(preemptableFn/reclaimableFn)所有失败分支由 `util.Abstain`(弃权、放行下游)改为 `util.Reject`(明确否决),避免"filtered 列表为空却仍被当作可抢占";并给 chip4node8 mesh 亲和补 `is4PmeshAffinity` 判据,不可行时直接拒绝而非 fallback 跨卡聚合。证据 `component/ascend-for-volcano/npu.go` + `plugin/task.go` + `internal/npu/policy/chip4nodex/frame.go`。https://gitcode.com/Ascend/mind-cluster/compare/9dbe2a11...b6e6717e

## mind-cluster: 9dbe2a11 -> b6e6717e
- 比较: 9dbe2a11..b6e6717e | tag: v26.1.0.beta.2 | commits=18 | truncated=true(files 截断,hunk 手动补拉)

### AI 总结重点(源码 diff 为据)

- **kubelet 模式真正实现 Pod Informer(此前是空转)**。`Kubelet.InitPodInformer` 从只打一条 "get pod from kubelet, skip pod informer" 日志、把 `client.PodInformer` 留空,改为 `new` 一个轮询式 informer、注册两组 handler(UpdatePodList 事件 + `ResourceEventHandler(PodResource, checkPod)`)、`go Run` 起来。这样 apiserver 模式与 kubelet 模式共用同一套 pod 事件驱动路径。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/kubeclient/pod_manager.go</summary>

  ```diff
   func (k *Kubelet) InitPodInformer() {
  -	hwlog.RunLog.Info("get pod from kubelet, skip pod informer")
  +	podInformer := newKubeletPodInformer(k.client)
  +	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
  +		AddFunc:    func(obj interface{}) { k.client.UpdatePodList(obj, EventTypeAdd) },
  +		UpdateFunc: func(oldObj, newObj interface{}) {
  +			if !reflect.DeepEqual(oldObj, newObj) { k.client.UpdatePodList(newObj, EventTypeUpdate) }
  +		},
  +		DeleteFunc: func(obj interface{}) { k.client.UpdatePodList(obj, EventTypeDelete) },
  +	})
  +	podInformer.AddEventHandler(k.client.ResourceEventHandler(PodResource, checkPod))
  +	k.client.PodInformer = podInformer
  +	go podInformer.Run(make(chan struct{}))
  +	hwlog.RunLog.Info("kubelet pod informer initialized")
   }
  ```
  </details>

- **新增 `kubeletPodInformer`(357 行)——用轮询模拟 SharedIndexInformer**。因 kubelet /pods 端点不支持 watch,实现里以 `kubeletPodResyncInterval = 5 * time.Second` 定时拉取,对本地 `store`(namespace/name → *v1.Pod)做 diff 合成 add/update/delete;实现 `AddEventHandler`/`GetStore`/`Run` 等接口以对齐 `cache.SharedInformer`。定位注释明说"为让 kubelet 模式提供非 nil 的 PodInformer、驱动与 apiserver 模式相同的 handler"。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/kubeclient/kubelet_informer.go(新增)</summary>

  ```diff
  +const kubeletPodResyncInterval = 5 * time.Second
  +// kubeletPodInformer implements cache.SharedIndexInformer by polling the
  +// kubelet /pods endpoint ... so that kubelet mode (where the apiserver pod
  +// informer is unavailable) can still provide a non-nil PodInformer and drive
  +// the same pod event handlers (handlePodAddEvent, soft-share delete, etc.)
  +type kubeletPodInformer struct {
  +	client   *ClientK8s
  +	store    map[string]*v1.Pod // key: namespace/name
  +	handlers []cache.ResourceEventHandler
  +	...
  +}
  ```
  </details>

- **热复位 SyncResetCM 加 nil-guard,修 kubelet 场景 panic**。原先无条件 `hrt.podIndexer = client.PodInformer.GetIndexer()`,kubelet 模式 PodInformer 为 nil 时直接空指针 panic(即"修复kubelet场景panic问题");现改为 `if client.PodInformer != nil` 才取 indexer,并把它按需加进 `WaitForCacheSync` 列表。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendtolerance.go</summary>

  ```diff
  -	hrt.podIndexer = client.PodInformer.GetIndexer()
   	hrt.cmIndexer = cmInformer.GetIndexer()
  -	cache.WaitForCacheSync(ctx.Done(), cmInformer.HasSynced, client.PodInformer.HasSynced)
  +	syncs := []cache.InformerSynced{cmInformer.HasSynced}
  +	if client.PodInformer != nil {
  +		hrt.podIndexer = client.PodInformer.GetIndexer()
  +		syncs = append(syncs, client.PodInformer.HasSynced)
  +	}
  +	cache.WaitForCacheSync(ctx.Done(), syncs...)
  ```
  </details>

- **ascend-for-volcano 抢占/回收失败分支 Abstain → Reject**。`addPreemptableFn`/`addReclaimableFn` 的全部拒绝路径(maxCardNPUNum<=0、preemptees 空、preemptee 无 node、node 不在 cache、无 feasible victims)返回值由 `util.Abstain` 改为 `util.Reject`。语义差异:Abstain 是弃权(不表态、交由框架继续),Reject 是明确否决——对应"抢占回收失败返回正确状态值,解决资源判断导致的 filtered 列表为空问题"。同时 `isResourceShortageError` 把 `NodeNotMeetTopologyWarning` 也判为资源短缺。

  <details><summary>代码依据 component/ascend-for-volcano/npu.go</summary>

  ```diff
   func isResourceShortageError(err error) bool {
  -	return strings.Contains(msg, util.NPUResourceShortageError)
  +	return strings.Contains(msg, util.NPUResourceShortageError) ||
  +		strings.Contains(msg, util.NodeNotMeetTopologyWarning)
   }
   ...
  -		klog....Infof("preemptableFn: task<%s> maxCardNPUNum=0, Abstain", preemptor.Name)
  -		return nil, util.Abstain
  +		klog....Infof("preemptableFn: task<%s> maxCardNPUNum=0, Reject", preemptor.Name)
  +		return nil, util.Reject
   ...
  -		klog....Infof("preemptableFn: task<%s> on node<%s> no feasible victims, Abstain", ...)
  -		return nil, util.Abstain
  +		return nil, util.Reject
  ```
  </details>

- **chip4node8(4P mesh)亲和判据:引入可用 chip 集合 + 拒绝不可行 fallback**。`plugin.CalcCardFreeCount` 签名新增 `availableChipIDs []int`;chip4nodex 的 Preemptable/Reclaimable 从节点注解 `util.ChangeTopToIntArray(...)` 解析出可用 chip 传入;并在非亲和 fallback 前加 `if is4PmeshAffinity(reqNPUNum)` 判断——mesh 亲和要求但不可行时直接 `return nil, false`,不再退化到默认跨卡聚合路径(保 4P mesh 拓扑正确性)。配套 `getAllocatedChipIDsFromPod` 由只解析单一 `AscendNPUCore` 注解重写为遍历多卡型注解前缀映射(910/310P/310/910b/通用)。

  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip4nodex/frame.go + plugin/task.go</summary>

  ```diff
  -	cardFreeCount := plugin.CalcCardFreeCount(vcNode, preemptees, maxCardNPUNum)
  +	availableChipIDs := util.ChangeTopToIntArray(vcNode.Annotation[tp.GetAnnoName(tp.ReqNPUName)],
  +		tp.GetAnnoPreVal(tp.ReqNPUName))
  +	cardFreeCount := plugin.CalcCardFreeCount(vcNode, preemptees, maxCardNPUNum, availableChipIDs)
   ...
  -	// Non-affinity path (5/6/7 etc): use default cross-card aggregation
  +	if is4PmeshAffinity(reqNPUNum) {
  +		klog....Infof("Preemptable(chip4nodex): task<%s> mesh affinity required but not feasible ...")
  +		return nil, false
  +	}
  ```
  ```diff
  -func CalcCardFreeCount(vcNode *NPUNode, preemptees []*api.TaskInfo, maxCardNPUNum int) map[int]int {
  +func CalcCardFreeCount(vcNode *NPUNode, preemptees []*api.TaskInfo, maxCardNPUNum int,
  +	availableChipIDs []int) map[int]int {
  ```
  </details>

### 后续发展方向 [AI]
- kubelet 直连 informer 的落地,信号指向昇腾 device-plugin 在**无 apiserver / 边缘推理场景**(950 单实例推理服务在本篇文档 commit 也被提及)持续补齐——此前 kubelet 模式是功能降级的二等公民,现要与 apiserver 模式能力对齐(热复位、soft-share)。证据只覆盖 informer/panic 修复这一段,轮询 5s 对大规模 pod churn 的性能影响未见测试数据。
- ascend-for-volcano 的 Abstain→Reject 是 volcano 抢占语义的正确性硬修,配合 4P mesh 亲和判据,方向是把**大规格跨卡(910 4P mesh / chip4node8)拓扑亲和调度**做扎实。证据只覆盖 chip4nodex 与顶层 preempt/reclaim 入口,其余 policy(chip8node8sp 等)本期仅 4 行小改、未见同类判据下沉。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- npu-operator | npu-container-toolkit | npu-driver-installer | vNPU | npu-node-provision | npu-dra-plugin | volcano-ext | ub-network-device-plugin:均无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=b6e6717ee5c39e4e7d68c3d285d69fdefff056ae tag=v26.1.0.beta.2 scanned=2026-07-22 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=npu-driver-installer sha=c898c929187bba8051e2ebed87f609bc820ead68 tag=v26.6.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=vNPU sha=29117ffcf0d144543dd4c0336c77f9abe6a612cd tag=v0.1.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-22 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-22 -->
</content>
</invoke>
