# 昇腾算力栈 diff 雷达 2026-07-03

## 摘要
- **mind-cluster 修掉"推理亲和性重调度死循环"**:`ascend-for-volcano` 两个超节点拓扑策略(chip8node8sp / chip8node8ra64sp)的 `selectNodesForInferService` 把优先队列从"每轮重建 + `i--` 回退"改为"建一次队列 + 内层循环弹出跳过无效项",从根上消除了 `i--` 导致的 for 循环卡死。同期 infer-operator 补 `DeleteFunc` 事件钩子:强删 pod(update 事件丢失、DeletionTimestamp 被 grace 逻辑跳过)现在也能可靠触发工作负载重建。
- **vNPU 路线图重定位(仅 README,信号级)**:从"CANN ACL Runtime 劫持的软切分工具"升格为"NPU 算力切分+动态调度一体化方案";AICore 切分粒度从 5% 细到 1%,新增弹性/抢占式 AICore 调度模式,软切性能开销声明 <5%,并把 DRA 调度([npu-dra-plugin])纳入官方路径。
- **npu-dra-plugin 单测覆盖率冲到 90.1%**:大批 `*_test.go`,顺带暴露两处生产能力面——NUMA 亲和属性(`numaNode`)已进 DRA device attributes、硬切 vNPU 走 `npu-smi` 的 `NPUSMIManager`(证据仅见测试,生产 hunk 未在本区间)。

## 当日重要改变
- **mind-cluster [Bugfix/调度]** 推理亲和场景 `selectNodesForInferService` 死循环修复(优先队列重构,消除 `i--` 回退)。证据:`component/ascend-for-volcano/internal/npu/policy/chip8node8sp/infer_service.go`。 https://gitcode.com/Ascend/mind-cluster/commit/6e193d89245f496c314f2e2ef8e7dc299027a831
- **mind-cluster [新能力/容错]** infer-operator 新增 pod 删除事件处理,支持"杀 pod 触发实例重调度"。证据:`component/infer-operator/pkg/controller/rescheduling/rescheduling.go` 新增 `handlePodDelete`。 https://gitcode.com/Ascend/mind-cluster/commits/master
- **vNPU [架构方向]** README 改写显示软切能力/调度模式扩档(1% 粒度、弹性/抢占、DRA 官方化)。证据:`README-en.md`。 https://gitcode.com/openFuyao/vNPU/commit/92cd047907d2c8919594c4707b881276e7da5ca8

## mind-cluster: f93bbaab -> 6e193d89
- 比较: f93bbaab..6e193d89 | tag: v26.0.1 | commits=18 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/f93bbaab77dedfe2e831ed97995b4e052c1b3daa...6e193d89245f496c314f2e2ef8e7dc299027a831

### AI 总结重点(源码 diff 为据)
- **推理超节点选点从"每轮重建队列 + `i--` 回退"改成"建一次队列 + 内层跳过循环",根除死循环**。旧逻辑在每次 `for i` 迭代里 `buildInferServicePriorityQueue`,弹出的 item 若容量不足就 `i--; continue` 重来——但队列每轮重建、被跳过的项又原样回到堆里,遇到"始终没有满足 spBlock 的超节点"时 `i` 永远回退,构成死循环(对应提交"开启推理亲和性后重调度偶现死循环")。新逻辑把 `pq := buildInferServicePriorityQueue(...)` 提到循环外,用内层 `for pq.Len()>0` 弹出并跳过无效超节点/机架,弹空则 `item==nil` 直接 `break` 退出;每选中一块再 `enrich*` 后重建 pq。两个拓扑策略(8SP 无机架、8RA64SP 带机架维度)同构修改。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8sp/infer_service.go</summary>

  ```diff
  +	pq := tp.buildInferServicePriorityQueue(superPodTop, sameSPs)
   	for i := 0; i < spBlockCount; i++ {
  -		pq := tp.buildInferServicePriorityQueue(superPodTop, sameSPs)
  -		if pq.Len() == 0 {
  +		var item *inferServicePQItem
  +		for pq.Len() > 0 {
  +			item = heap.Pop(pq).(*inferServicePQItem)
  +			sp, ok := superPodTop[item.superPodID]
  +			if !ok || len(sp) < tp.spBlock {
  +				item = nil
  +				continue
  +			}
   			break
   		}
  -		item := heap.Pop(pq).(*inferServicePQItem)
  -		sp, ok := superPodTop[item.superPodID]
  -		if !ok || len(sp) < tp.spBlock {
  -			i--
  -			continue
  +		if item == nil {
  +			break
   		}
   		...
  +		pq = tp.buildInferServicePriorityQueue(superPodTop, sameSPs)
   	}
  ```
  </details>

- **infer-operator 重调度器新增 pod 删除钩子,补齐"强删/优雅删"两类丢事件场景**。`SetupWithManager` 的 informer 从只挂 `UpdateFunc` 增加 `DeleteFunc: r.handlePodDelete`。注释点明动机:强删时 update 事件(DeletionTimestamp)可能丢失,优雅删时 `isValidFaultPod` 又会跳过已带 DeletionTimestamp 的 pod——所以 DeleteFunc 是唯一可靠信号。一个 STS/Deployment 的副本组成一个推理实例(通信域),丢任一 pod 即需重建该负载,同 instanceSet 下其他负载不受影响。对应提交"支持通过杀 pod 触发实例重调度"。
  <details><summary>代码依据 component/infer-operator/pkg/controller/rescheduling/rescheduling.go</summary>

  ```diff
   	podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
   		UpdateFunc: r.handlePodUpdate,
  +		DeleteFunc: r.handlePodDelete,
   	})
  +// handlePodDelete handles pod delete event (both grace and force delete).
  +func (r *Rescheduler) handlePodDelete(obj interface{}) {
  +	pod, ok := obj.(*corev1.Pod)
  +	if !ok { return }
  +	if !r.isValidInferPod(pod) { return }
  +	if err := r.processFaultEvent(pod); err != nil { ... }
  +}
  ```
  </details>

- **`recordWorkLoadFault` 把故障原因注解读取从 3 次内联收敛成一次取值,消除 nil-annotation 隐患**。改动把 `pod.Annotations[common.PodStatusAnnotationKey]` 抽成局部 `faultReason` 变量(注释标 "safe even if pod.Annotations is nil or key absent (returns \"\")"),后续 map 写入、`HasSuffix` 判断、日志复用同一值——配合上面的 handlePodDelete(健康 pod 被强删时无该注解),避免重复读取和潜在空 map 访问。
  <details><summary>代码依据 component/infer-operator/pkg/controller/rescheduling/rescheduling.go</summary>

  ```diff
  -	r.faultWorkLoadMap[currentFaultWorkLoad] = pod.Annotations[common.PodStatusAnnotationKey]
  -	if strings.HasSuffix(pod.Annotations[common.PodStatusAnnotationKey], common.PodFailed) {
  +	faultReason := pod.Annotations[common.PodStatusAnnotationKey]
  +	r.faultWorkLoadMap[currentFaultWorkLoad] = faultReason
  +	if strings.HasSuffix(faultReason, common.PodFailed) {
  ```
  </details>

- **openeuler 版 volcano 镜像补 agreement.txt 权限收敛(440)**。scheduler/controller 两个 Dockerfile 在 chmod 链末尾加 `chmod 440 /usr/local/agreement.txt`,属交付镜像的小幅权限硬化(此前该文件权限未显式设定)。
  <details><summary>代码依据 component/ascend-for-volcano/output/openeuler/Dockerfile-scheduler</summary>

  ```diff
  -    chmod 400 /plugins/*.so
  +    chmod 400 /plugins/*.so && \
  +    chmod 440 /usr/local/agreement.txt
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾推理栈的重心明显在**大规模推理实例的容错重调度**(超节点拓扑选点 + pod 生命周期事件闭环):本区间把"选不到满足 spBlock 的超节点"这类边界从"死循环"改成"干净退出",并把强删/优雅删都纳入重建触发。证据只覆盖 8SP/8RA64SP 两个拓扑策略与 infer-operator rescheduling,未见 clusterd 侧 UB 链路故障(commit 提到 81B38002 抑制但本区间 component/clusterd 仅测试文件命中)的生产 hunk。

## vNPU: 299afce4 -> 92cd0479
- 比较: 299afce4..92cd0479 | tag: v0.1.0 | commits=2 | truncated=false
- https://gitcode.com/openFuyao/vNPU/compare/299afce43a428027ccbe7baf863414071d657d1a...92cd047907d2c8919594c4707b881276e7da5ca8

### AI 总结重点(源码 diff 为据)
- **本区间仅 README-en.md 改写,无生产代码**;但文档实质改写暴露了 vNPU 的能力/路线重定位,作为产品对标信号记录(非代码变更)。关键差异:
  - 定位从"基于 CANN ACL Runtime 劫持 + volcano 的软切分"升级为"在容器平台上构建 NPU **算力切分 + 动态调度**一体化方案"。
  - AICore 软切粒度描述从 **5%** 细化到 **1%**(memory 仍 1Gi);新增 "fixed quota / elastic / preemptive" 三种 AICore 调度策略(原文档只提 binpack 资源调度);软切性能开销首次给出量化声明 **<5%**。
  - 把 **DRA 调度**([npu-dra-plugin])写入官方调度策略清单,与 volcano 插件并列;硬切分基于 Ascend HDK。
  - 新增"约束与限制"章:单容器最多 1 个 vNPU、单 vNPU 仅一个进程、仅切 AICore+显存(不含 AI CPU/VPC/VDEC/JPEGD)、业务容器不得特权。
  - 首次列出代码结构:`volcano-xpu-plugin` / `xpu-device-plugin` / `client_update`(软切拦截库部署)/ `xpu-exporter` / `ci` / `charts`。
  <details><summary>代码依据 README-en.md</summary>

  ```diff
  -    - AICore partitioning granularity is minimum 5%, memory ... 1Gi.
  +    - Maximum 1-to-20 slicing, with AICore slicing granularity as small as 1% and memory ... 1Gi
  +    - Multiple AICore scheduling strategies, supporting fixed quota mode, elastic mode, and preemptive mode
  +    - Performance overhead less than 5%
  +  - [DRA-based scheduling](https://gitcode.com/openFuyao/npu-dra-plugin)
  ```
  </details>

### 后续发展方向 [AI]
- 文档改写是"能力已就绪的官宣"还是"路线宣示"需看后续代码:1% 粒度、弹性/抢占调度、<5% 开销这些若已落地,应在 `volcano-xpu-plugin` / `client_update` 出现对应 hunk。证据仅 README,未见任何 `.go`/chart 变更,**不能据此判定能力已可用**;但方向清晰——vNPU 正从纯软切工具向"软切+硬切+DRA 三模统一调度平面"收拢,与 HAMi ascend-device-plugin 的 vNPU 路径直接竞争。

## npu-dra-plugin: 0876c67f -> dbffd794
- 比较: 0876c67f..dbffd794 | tag: 1.0.1 | commits=3 | truncated=false
- https://gitcode.com/openFuyao/npu-dra-plugin/compare/0876c67f9bea29da06e97e09bb7def5c0039a30b...dbffd7942b003f1bd4880861c167aa7a0410c9ca

### AI 总结重点(源码 diff 为据)
- **本区间全是单测扩容(覆盖率 90.1%)+ 删 `.golangci-lint.yml`,无生产逻辑 hunk**;但新增/改写的测试断言暴露了两处已落地的生产能力面(生产源码变更应在更早区间,已归档过或未被本 compare 覆盖):
  - **DRA device attributes 新增 `numaNode` 整型属性**:`dcmi_test.go` 的 `TestBuildDeviceAttributesWithNuma` 把 `assert.Len(t, attrs, 3)` 改成 `4`,并断言 `attrs["numaNode"].IntValue == 0`,读取路径 `/sys/bus/pci/devices/<BDF>/numa_node`——说明 `buildDeviceAttributes` 已把 NUMA 亲和暴露给 DRA 调度器。
  - **硬切 vNPU 走 `npu-smi` 的 `NPUSMIManager`**:新增 `internal/vnpu/npusmi_manager_test.go` 测 `CreateVNPU`/`DeleteVNPU`,删除引用格式 `npuID:chipID:vnpuID`(如 `1:2:7`),模板如 `vir08`——印证 DRA 路径已支持硬切 vNPU 创建/回收。
  <details><summary>代码依据 internal/profiles/npu/dcmi_test.go</summary>

  ```diff
  +	patches := gomonkey.ApplyFunc(os.ReadFile, func(path string) ([]byte, error) {
  +		expectedPath := "/sys/bus/pci/devices/0000:01:00.0/numa_node"
  +		if path == expectedPath { return []byte("0"), nil }
  +		return nil, os.ErrNotExist
  +	})
   	attrs := buildDeviceAttributes(head, physicalID, busID, topoGroups)
  -	assert.Len(t, attrs, 3)
  +	assert.Len(t, attrs, 4)
  +	numaNodeAttr, exists := attrs["numaNode"]
  +	assert.Equal(t, int64(0), *numaNodeAttr.IntValue)
  ```
  </details>

### 后续发展方向 [AI]
- npu-dra-plugin 已进入"补测试稳质量"阶段(1.0.1 已发,覆盖率冲 90%),说明 DRA 路径本身趋于成熟。证据只覆盖测试文件,`numaNode` 属性与 `NPUSMIManager` 的生产实现未在本 compare 出现,**上述能力判断系从测试反推,需在生产源码确认**。方向上与 vNPU README 把 DRA 官方化互为印证:昇腾正把 NUMA 拓扑亲和 + 硬切 vNPU 收进 K8s 原生 DRA 抽象。

## 本期无实质改动(折叠)
<details><summary>6 个 repo 无新提交/仅 EMPTY</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- npu-node-provision(717ef777,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=6e193d89245f496c314f2e2ef8e7dc299027a831 tag=v26.0.1 scanned=2026-07-03 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-07-03 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-07-03 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-07-03 -->
<!-- ANCHOR repo=vNPU sha=92cd047907d2c8919594c4707b881276e7da5ca8 tag=v0.1.0 scanned=2026-07-03 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-07-03 -->
<!-- ANCHOR repo=npu-dra-plugin sha=dbffd7942b003f1bd4880861c167aa7a0410c9ca tag=1.0.1 scanned=2026-07-03 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-03 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-07-03 -->
</content>
</invoke>
