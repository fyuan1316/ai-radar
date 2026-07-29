# 昇腾算力栈 diff 雷达 2026-07-30

## 摘要
- **mind-cluster/ascend-device-plugin 改软切(vNPU)ID 分配语义**:从"永远取最大 vNPU_id + 1(单调递增)"改为"扫 0..99 补最小空洞、复用已释放 ID",同时把节点缓存锁从 `Mutex` 换成 `RWMutex` 并给 informer 的 `checkPod` 加读锁,修软切下发 pod 时并发读写 annotation map 的竞态。
- **openFuyao/vNPU(xpu-exporter)修采集器挂死**:vNPU 信息采集 goroutine 在 `GetAllVxpuInfo()` 报错时未取消上下文导致进程 hang,现把 `context.CancelFunc` 一路透传到采集循环、出错即 `cancel()` 退出。
- 其余 7 仓(npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)自 07-29 锚点无新提交。

## 当日重要改变
- mind-cluster [语义变更·软切分配] vNPU_id 从"max+1 单调递增"改为"0..99 补洞复用",避免长期创建/销毁 vNPU 后 ID 只增不减、逼近 int 上限;新增常量 `maxVnpuID=99` 划定 vNPU 每卡上限。证据 `component/ascend-device-plugin/pkg/common/common.go`。https://gitcode.com/Ascend/mind-cluster/commit/8727fd96085c
- mind-cluster [并发修复] 软切下发 pod 时 annotation map 并发读写竞态:`kube_cache.go` 锁改 `sync.RWMutex`、`cur_node_informer.go` 的 `checkPod` 读注解前加 `RLock`。同一提交。https://gitcode.com/Ascend/mind-cluster/commit/8727fd96085c
- vNPU [健壮性·可用性] xpu-exporter NPU 采集器错误未取消 context 致进程挂死,现出错即调 cancel 退出。证据 `xpu-exporter/collector/npuservice/npu_collector_service.go`。https://gitcode.com/openFuyao/vNPU/commit/e972459566b7

## mind-cluster: 868f2774 -> 4e219436
- 比较: 868f2774..4e219436 | tag: v26.1.0.beta.2 | commits=4(2 实质,其余为 merge / dump 日志文案)
### AI 总结重点(源码 diff 为据)
- **vNPU_id 分配从"取最大+1"改为"补最小空洞、复用释放 ID"**。函数 `GetMaxVirtualIDByPhysicalID` → 重命名 `GetNextVirtualIDByPhysicalID`;底层 `calculateMaxVirtualID`(返回最大 vid)→ `calculateNextVirtualID`(用 `seen` 集合扫 `0..maxVnpuID(=99)` 返回第一个未占用 ID,全占满才回退 `max+1`)。plugin.go 侧同步去掉 `+1`:旧 `annotations.vNPUId = strconv.Itoa(maxVirtualID + 1)` → 新 `strconv.Itoa(nextVirtualID)`(自增语义移进 next 函数内)。空集合旧返回 `-1`、新返回 `0`,base case 行为不变。含义:vNPU 反复创建/销毁后不再单调涨号、可回收孔位,规避号段耗尽/逼近 `math.MaxInt`(该上限保护判断仍保留)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/common.go</summary>

  ```diff
  +const (
  +	maxVnpuID = 99
  +)

  -func calculateMaxVirtualID(virtualIDs []int) int {
  -	maxVID := -1
  +func calculateNextVirtualID(virtualIDs []int) int {
  +	seen := make(map[int]struct{}, len(virtualIDs))
  +	nextVID := 0
   	for _, vid := range virtualIDs {
  +		seen[vid] = struct{}{}
  -		if vid > maxVID { maxVID = vid }
  +		if vid > nextVID { nextVID = vid }
   	}
  -	return maxVID
  +	for i := 0; i <= maxVnpuID; i++ {
  +		if _, ok := seen[i]; !ok { return i }
  +	}
  +	return nextVID + 1
  }
  ```
  </details>
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/plugin.go</summary>

  ```diff
  -	maxVirtualID, err := common.GetMaxVirtualIDByPhysicalID(physicalID)
  +	nextVirtualID, err := common.GetNextVirtualIDByPhysicalID(physicalID)
   	...
  -	annotations.vNPUId = strconv.Itoa(maxVirtualID + 1)
  +	annotations.vNPUId = strconv.Itoa(nextVirtualID)
  ```
  </details>
- **修软切下发 pod 时 annotation map 并发读写竞态**。node 级缓存锁 `lock` 从 `sync.Mutex` 升为 `sync.RWMutex`;informer 回调 `checkPod` 读 `pod.Annotations[api.HuaweiAscend910]` 前加 `RLock/RUnlock`。读多写少路径下用读锁并发、消除对 annotation map 的裸读。
  <details><summary>代码依据 pkg/kubeclient/{kube_cache.go,cur_node_informer.go}</summary>

  ```diff
  - lock                = sync.Mutex{}
  + lock = sync.RWMutex{}

    func checkPod(obj interface{}) bool {
    	...
  +	lock.RLock()
  +	defer lock.RUnlock()
    	_, exist := pod.Annotations[api.HuaweiAscend910]
    	return exist
    }
  ```
  </details>
### 后续发展方向 [AI]
- 软切(soft-share vNPU)分配器在向"号段可回收 + 并发安全"收敛,`maxVnpuID=99` 明确了单物理卡 vNPU 上限。证据只覆盖 device-plugin 侧 ID 生成与缓存锁,未见 for-volcano 调度侧或 noded 是否感知复用后的 ID(回收后被同号新 vNPU 复用时,监控/拓扑侧是否有陈旧关联未在本区间体现)。

## vNPU: 79931f49 -> 49ad0e7c
- 比较: 79931f49..49ad0e7c | tag: v0.1.0 | commits=2(1 实质 + 1 merge)
### AI 总结重点(源码 diff 为据)
- **xpu-exporter 的 vNPU 采集 goroutine 出错时取消上下文,防进程挂死**。`Start` 已持有的 `fn context.CancelFunc` 现一路透传:`vnpuInfoCollect(...)` / `setVnpuInfoToCache(...)` 均新增 `fn` 形参;采集循环内 `GetAllVxpuInfo()` 报错时,除原有 `log.Errorf` 外新增 `fn()` 后再 `return`。此前该 goroutine 出错只是静默退出、外层 `group.Wait()` 之外的 ctx 不被取消,导致依赖该 ctx 的进程 hang。
  <details><summary>代码依据 xpu-exporter/collector/npuservice/npu_collector_service.go</summary>

  ```diff
  -func vnpuInfoCollect(ctx context.Context, group *sync.WaitGroup, n *npuCollector) {
  +func vnpuInfoCollect(ctx context.Context, group *sync.WaitGroup, n *npuCollector, fn context.CancelFunc) {
   	...
   			vnpuInfo, err := client.GetAllVxpuInfo()
   			if err != nil {
   				log.Errorf("get vnpuInfo error: %v", err)
  +				fn()
   				return
   			}
  ```
  </details>
### 后续发展方向 [AI]
- vNPU 仓的 xpu-exporter 在补采集链路的错误传播/退出语义(fail-fast 而非静默挂死)。证据仅覆盖 npuservice 采集器单条错误路径,未见其它 collector 是否同样透传 cancel。

## 本期无实质改动(锚点保链)
- npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:自 07-29 锚点无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=4e2194363524c4f779e9755513dadf25ca151bf7 tag=v26.1.0.beta.2 scanned=2026-07-30 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=vNPU sha=49ad0e7c2faccd942fb181be17256d9451b7776d tag=v0.1.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-30 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-30 -->
