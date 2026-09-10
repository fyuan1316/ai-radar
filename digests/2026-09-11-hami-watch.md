# HAMi diff 雷达 2026-09-11

## 摘要
- 仅主仓 `HAMi` 2 个提交,均为 bugfix、无 API/CRD/切分内核变动:调度器把 `printedLog` 从 `RegisterFromNodeAnnotations` 的循环局部变量提升为 `Scheduler` 结构体字段,并在节点删除时清理,修复了节点摘除后日志去重表泄漏、同名节点重建后不再打"新增"日志的问题;另一条修 CI 覆盖率脚本写文件。
- HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓本期无新提交,能力边界与切分内核无演进。
- 当日无重要改变信号(无弃用/API/架构/版本/新能力命中)。

## 当日重要改变
- 无

## Project-HAMi/HAMi: b5ec6b14 -> d872cee1
- 比较: b5ec6b143a322e33a7ace339dff840cccb2e55ac -> d872cee1 | ahead=2 | files=4 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/b5ec6b143a322e33a7ace339dff840cccb2e55ac...d872cee1959c70ac99c3bf41c49663a28c50f7aa

### AI 总结重点(源码 diff 为据)
- **`printedLog` 从函数内局部变量提升为 `Scheduler` 结构体字段,并纳入节点删除时的清理路径(#2939)**。改前 `printedLog := map[string]bool{}` 声明在 `RegisterFromNodeAnnotations` 的循环外、作为参数逐层传进 `register(labelSelector, printedLog)`,`onDelNode`/`cleanupNodeUsage` 无法触及它;改后成为 `s.printedLog`,在 `NewScheduler` 里 `make`,`register` 签名去掉该参数直接读写 `s.printedLog`。带来两处行为差异:①这张"哪些节点已在 info 级打过日志"的去重表现在会随节点删除被 `delete(s.printedLog, nodeID)` 修剪,节点大规模churn下不再无界增长;②同名节点被删后重建时,因表项已清,会重新按"Node device added"(info 级)而非"Node device updated"(V(5) 级)打印。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	eventRecorder  record.EventRecorder
  -	started        uint32 // 0 = false, 1 = true
  +	// printedLog records the nodes whose devices have already been logged at
  +	// info level, so a re-registration logs at V(5) instead. It is pruned when
  +	// a node is deleted, both to keep it bounded under node churn and so a node
  +	// that returns under the same name is logged as newly added again.
  +	printedLog    map[string]bool
  +	eventRecorder record.EventRecorder

   func NewScheduler() *Scheduler {
   	s := &Scheduler{
   		overviewstatus: make(map[string]*NodeUsage),
  +		printedLog:     make(map[string]bool),

   func (s *Scheduler) cleanupNodeUsage(nodeID string) {
   		delete(s.overviewstatus, nodeID)
   		klog.V(4).InfoS("Removed node from overviewstatus", "node", nodeID)
   	}
  +	delete(s.printedLog, nodeID)

  -	printedLog := map[string]bool{}
   	for {
  -		s.register(labelSelector, printedLog)
  +		s.register(labelSelector)

  -func (s *Scheduler) register(labelSelector labels.Selector, printedLog map[string]bool) {
  +func (s *Scheduler) register(labelSelector labels.Selector) {
   ...
  -			if printedLog[val.Name] {
  +			if s.printedLog[val.Name] {
   				klog.V(5).InfoS("Node device updated", ...)
   			} else {
   				klog.InfoS("Node device added", ...)
  -				printedLog[val.Name] = true
  +				s.printedLog[val.Name] = true
   			}
  ```
  </details>
- **CI 覆盖率脚本 `hack/unit-test.sh` 修正 profile 文件写法(#2935)**:mode 行与 profile 数据必须落到同一文件,否则 `go tool cover` 因首行非 mode 报错;改用截断重定向 `>${outF}` 防止本地重复跑追加出第二份数据。纯测试基建,无运行时/切分逻辑影响。
  <details><summary>代码依据 hack/unit-test.sh</summary>

  ```diff
  -echo "mode: atomic" >coverage.out
  -cat ${mergeF} >>./_output/coverage/coverage.out
  -go tool cover -func=coverage.out
  +outF="./_output/coverage/coverage.out"
  +echo "mode: atomic" >${outF}
  +cat ${mergeF} >>${outF}
  +go tool cover -func=${outF}
  ```
  </details>

### 后续发展方向 [AI]
- 本轮是纯正确性打磨,方向信号弱:调度器长跑内存有界性 + 日志观测一致性是当前被逐步收口的点(继上一轮 `cleanupNodeUsage` 清 `overviewstatus` metrics 后,这轮把日志去重表也挂进同一清理路径),反映 HAMi 调度器正把"节点生命周期状态全部集中在 `Scheduler` 结构体、统一在删除时回收"作为一致模式在推进。证据只覆盖 `scheduler.go` 的 register/cleanup 两段 hunk,未见切分/配额/打分逻辑变动,vGPU/vNPU 软切分内核与 API 本期零改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 f01e9f23,无 release tag)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 f6ae9160,release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=d872cee1959c70ac99c3bf41c49663a28c50f7aa branch=master release=v2.10.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-11 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-11 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-11 -->
