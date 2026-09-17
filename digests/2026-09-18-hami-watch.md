# HAMi diff 雷达 2026-09-18

## 摘要
- HAMi-WebUI 数据层做可靠性/性能加固:两个 informer 工厂收敛为 `Data` 上一份共享工厂,`assignedNode` 由"每个 Pod 事件打一次 API server"改为读共享 Node 缓存(#313);`fetchNodeInfo` 容忍尚无 status 的 Node 并规范化 OS/Arch 大小写(#315)。指向大规模集群下控制台自身开销与鲁棒性,无新能力/无 API 变更。
- 其余四仓(HAMi 主仓、HAMi-core、volcano-vgpu、ascend-device-plugin)本期无新提交。

## 当日重要改变
- 无(WebUI 两笔均为 server 数据层 perf/fix,未命中弃用/API-CRD/proposal/版本跨档/新 package 任一信号)。

## Project-HAMi/HAMi-WebUI: 96aa960a -> b2af8ecc
- 比较: https://github.com/Project-HAMi/HAMi-WebUI/compare/96aa960a04764ec9057561c1b69e53b8423e49e2...b2af8ecc94a2330a6f11ab189522f16f328495bd | ahead=2 files=5 | Release: v1.3.0
- PR: https://github.com/Project-HAMi/HAMi-WebUI/pull/313 https://github.com/Project-HAMi/HAMi-WebUI/pull/315

### AI 总结重点(源码 diff 为据)
- **两个独立 informer 工厂收敛为 `Data` 上的一份共享工厂**。之前 `podRepo.init()` 和 `nodeRepo.init()` 各自 `informers.NewSharedInformerFactoryWithOptions(r.data.k8sCl, time.Hour*1)` 建自己的工厂并各自 Start/WaitForCacheSync——同一集群跑两份 Pod/Node watch 缓存。现在 `Data` 结构体新增字段 `informers informers.SharedInformerFactory` + `stopCh`、常量 `informerResyncPeriod = time.Hour`、方法 `startInformers()`(Start + WaitForCacheSync),两个 repo 共用这一份。
  <details><summary>代码依据 server/internal/data/data.go</summary>

  ```diff
  +const informerResyncPeriod = time.Hour
   type Data struct {
   	k8sCl    kubernetes.Interface
   	eventsCl kubernetes.Interface
   	promCl   *prom.Client
  +	// Shared by the repositories, so each resource has one cache.
  +	informers informers.SharedInformerFactory
  +	stopCh    chan struct{}
   }
  +// startInformers starts the informers requested so far and waits for their caches.
  +func (d *Data) startInformers() {
  +	d.informers.Start(d.stopCh)
  +	d.informers.WaitForCacheSync(d.stopCh)
  +}
  ```
  </details>
- **`assignedNode(pod)` 由每 Pod 事件一次 API 调用改为读共享缓存**。`podRepo` 新增 `nodeLister listerscorev1.NodeLister` 字段;旧逻辑 `r.data.k8sCl.CoreV1().Nodes().Get(ctx, pod.Spec.NodeName, ...)` 直打 API server,新逻辑走 `nodeLister`(缓存),另加常量 `nodeReadTimeout = 10 * time.Second`。测试 `TestPodEventsReadTheirNodeFromTheCache` 断言 Pod 事件后 `fake.Clientset.Actions()` 长度为 0——零 API 调用。
  <details><summary>代码依据 server/internal/data/pod.go</summary>

  ```diff
  +const nodeReadTimeout = 10 * time.Second
  +// assignedNode reads the Pod's node from the shared cache, so Pod events cost no API requests.
   func (r *podRepo) assignedNode(pod *corev1.Pod) *corev1.Node {
   	if pod.Spec.NodeName == "" {
   		return nil
   	}
  -	node, err := r.data.k8sCl.CoreV1().Nodes().Get(context.Background(), pod.Spec.NodeName, metav1.GetOptions{})
  ```
  </details>
- **初始化错误处理从 panic 改为向上返回**。`podRepo.init()`/`nodeRepo.init()` 由 `panic(err)` 改为 `return fmt.Errorf("index pods: %w", err)` / `"watch pods/nodes: %w"`;构造函数 `NewNodeRepo`/`NewPodRepo` 签名从返回单值改为 `(..., error)`。
  <details><summary>代码依据 server/internal/data/node.go</summary>

  ```diff
  -func NewNodeRepo(...) biz.NodeRepo {
  +func NewNodeRepo(...) (biz.NodeRepo, error) {
  -	nodeRepo.init()
  -	return nodeRepo
  +	if err := nodeRepo.init(); err != nil {
  +		return nil, err
  +	}
  +	return nodeRepo, nil
  ```
  </details>
- **`fetchNodeInfo` 容忍尚无 status 的 Node,并规范化 OS/Arch 大小写**(#315)。新增 `capitalize(value string)`(首字母大写、余下小写);无 kubelet 上报 status 的 Node(NodeInfo 空)返回空 OS/Arch 而不崩,有 status 的经 capitalize 归一("linux"/"amd64" → "Linux"/"AMD64")。
  <details><summary>代码依据 server/internal/data/node.go + node_test.go</summary>

  ```diff
  +// A Node that no kubelet created can lack nodeInfo.
  +func capitalize(value string) string {
  +	runes := []rune(value)
  +	if len(runes) == 0 { return "" }
  +	return strings.ToUpper(string(runes[0])) + strings.ToLower(string(runes[1:]))
  +}
  +func TestNodeInventoryReadsANodeWithoutStatus(t *testing.T) {
  +	node := repo.fetchNodeInfo(&corev1.Node{ObjectMeta: metav1.ObjectMeta{Name: "pending-node"}})
  +	if node.Name != "pending-node" || node.OperatingSystem != "" || node.Architecture != "" { ... }
  +	ready := repo.fetchNodeInfo(...linux/amd64...)
  +	if ready.OperatingSystem != "Linux" || ready.Architecture != "AMD64" { ... }
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 在 `server/internal/data` 层做集群规模化下的自身开销与鲁棒性收口:去掉重复 informer 缓存、Pod 事件去 API 化、容错未就绪节点。方向是控制台从"能看"往"大集群下不拖累 apiserver、不因半初始化节点崩"演进。
- 证据只覆盖 server/internal/data(pod/node/data)三文件,未见前端与新厂商 provider 改动;昇腾相关仅体现在既有测试仍引用 `ascend.NodeHamiCoreAnnotation` / `hami-vnpu-core` 注解与 `ascend.Decoder`,本期无 provider 层新增,未见此前 #310 vNPU 感知的后续。

## 本期无实质改动(折叠)
<details><summary>4 仓 EMPTY(仅锚点续链)</summary>

- Project-HAMi/HAMi — 无新提交
- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=9e111e9dde51a1194dbb6c2c842200e3c819f664 branch=master release=v2.10.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a5231c7f4524e5d98f5200fde47f97b06356fcbe branch=main release=— scanned=2026-09-18 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-18 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=b2af8ecc94a2330a6f11ab189522f16f328495bd branch=main release=v1.3.0 scanned=2026-09-18 -->
</content>
</invoke>
