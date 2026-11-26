# HAMi diff 雷达 2026-11-27

## 摘要

- **HAMi-core 补上软切分最大的一个计量漏洞:CUDA Graph 回放此前完全绕过算力限流器**。`cuGraphLaunch` 不经过 `cuLaunchKernel`,因此整条 graph 的 kernel 从不调用 `rate_limiter`,graph-heavy 进程可以远超 `CUDA_DEVICE_SM_LIMIT`。本期在实例化时遍历 graph 的 kernel/child-graph/conditional 节点累加 grid×block,launch 时整图一次计费(#431/#434)。同一期还修了 non-Debug 构建 `-fvisibility=hidden` 把 `cu*`/`nvml*` hook 符号藏起来的问题,改用版本脚本 `src/libvgpu.map` 精确导出(#435)。HAMi 主仓已把 `libvgpu` 子模块 bump 到含这组改动的 `1b9824e`。
- **HAMi 主仓开始搭"厂商中立的互联拓扑模型"**:新增 `pkg/scheduler/topology` 包与 `--topology-tier-labels` 参数,从节点标签(`hami.io/rackid`、`hami.io/superpodid`)构建分层树,用最近公共祖先(LCA)的 tier 表示两节点的网络距离。本期**只建模型 + 维护缓存,放置逻辑明确留给后续 PR**。另外昨天那个"建好但没接线"的 `pkg/tracing` 本期真正接到了 admission / Filter / Bind 三处 span(#3540)。
- **弃用清理按期落地**:v2.11.0 标记弃用的 `hami_container_device_memory_bytes` 指标与 `hami_resource_quota_used` 的 `limit` 标签从 master 移除(目标 v2.12.0)。HAMi-WebUI 则把散在各处的厂商 if/else 重构成 Inventory/Allocation/Telemetry 三类 Dialect 接口 + 新 `provider/registry` 包。

## 当日重要改变

- **Project-HAMi/HAMi [新能力][架构方向]** 新增顶层子包 `pkg/scheduler/topology`(401 行)与调度器参数 `--topology-tier-labels`,把机架/超节点层级抽象成厂商中立的 HyperNode 树;`cmd/scheduler/main.go` 注册该 flag,`pkg/scheduler/topology_model.go` 维护快照缓存。证据:`pkg/scheduler/topology/topology.go`、`cmd/scheduler/main.go` — https://github.com/Project-HAMi/HAMi/pull/3528
- **Project-HAMi/HAMi [弃用/移除]** 从 `pkg/monitor/metrics/schema.go` 删除 `ContainerDeviceMemory` desc,vGPUmonitor 不再上报 `hami_container_device_memory_bytes`(仅 `--legacy-metrics=true` 下保留旧名 `Device_memory_desc_of_container`)。证据:`cmd/vGPUmonitor/metrics.go`、`pkg/monitor/metrics/schema.go` — https://github.com/Project-HAMi/HAMi/pull/3536
- **Project-HAMi/HAMi [弃用/移除]** `hami_resource_quota_used` / 旧名 `QuotaUsed` 的 `limit` 标签删除,标签集从 `{namespace,quota_name,limit}` 收窄为 `{namespace,quota_name}`,配额上限只能读 `hami_resource_quota_limit`。证据:`cmd/scheduler/metrics.go` — https://github.com/Project-HAMi/HAMi/pull/3538
- **Project-HAMi/HAMi [新能力]** OpenTelemetry 落到调度全链路:新增 `pkg/scheduler/tracing.go`、`pkg/tracing/attributes.go`,`cmd/scheduler/main.go` 调 `tracing.Setup`,webhook 向 Pod 注入 `hami.io/traceparent`,Bind 内部再细分 lock node / patch pod / bind pod 三个子 span。证据:`pkg/scheduler/tracing.go`、`pkg/scheduler/scheduler.go` — https://github.com/Project-HAMi/HAMi/pull/3540
- **Project-HAMi/HAMi-core [新能力]** CUDA Graph 启动纳入 SM 限流:`src/cuda/graph.c` 新增 65536 槽的开放寻址 launch-cost 表,`submit_graph` 在非 upload 路径调 `rate_limiter(threads, 1)`;新 hook `cuGraphExecUpdate(_v2)` / `cuGraphExecKernelNodeSetParams(_v2)` / `cuGraphExecNodeSetParams` / `cuGraphExecChildGraphNodeSetParams` 负责改图后重算费用;`cuLaunchKernel` 在 stream capture 期间不再重复计费。证据:`src/cuda/graph.c`、`src/cuda/memory.c`、`src/cuda/hook.c` — https://github.com/Project-HAMi/HAMi-core/pull/431 和 https://github.com/Project-HAMi/HAMi-core/pull/434
- **Project-HAMi/HAMi-core [架构方向]** 新增 `src/libvgpu.map` 链接器版本脚本并从 release 构建去掉 `-fvisibility=hidden`:此前非 Debug 构建把 hook 全部隐藏,LD_PRELOAD 符号插桩实际失效。证据:`CMakeLists.txt`、`src/CMakeLists.txt`、`src/libvgpu.map` — https://github.com/Project-HAMi/HAMi-core/pull/435
- **Project-HAMi/HAMi-WebUI [架构方向]** 新增 `server/internal/provider/registry` 与 `server/internal/provider/internal/hamiwire` 两个包,`provider` 包新增 `InventoryDialect` / `AllocationDialect` / `TelemetryDialect` 三套接口,`providerfacts.Build` 的厂商 if/else 被 dialect 循环替换,exporter 侧删除 `dcgm_samples.go`(348 行)、`node_observations.go`、`metax_observations.go`。证据:`server/internal/provider/dialect.go`、`server/internal/providerfacts/snapshot.go`、`server/internal/provider/registry/registry.go` — https://github.com/Project-HAMi/HAMi-WebUI/pull/368 和 https://github.com/Project-HAMi/HAMi-WebUI/pull/370

## Project-HAMi/HAMi: 7a18e230 -> 3d600ea7

- 比较: 7a18e230656ac91db561a0c314d08176b8db61d7 -> 3d600ea7 | ahead=13 | files=30 | Release: v2.11.0
- 比较链接:https://github.com/Project-HAMi/HAMi/compare/7a18e230656ac91db561a0c314d08176b8db61d7...3d600ea70324d4a4d60c59806ce0a78ab9810a7d

### AI 总结重点(源码 diff 为据)

- **新增 `pkg/scheduler/topology` 包:把互联层级建成 HyperNode 树,tier 0 是节点本身,tier 从 1 向上按 `--topology-tier-labels` 的给定顺序编号(最小域在前)。两节点的"距离"= LCA 所在 tier**。`ParseTiers` 支持 `key=N` 显式指定 tier,但**禁止 `key=N` 与裸 key 混用**(避免 `rack=2,superpodid` 里 superpodid 被静默分到 tier 1),且 tier 上限 `MaxTierLevel=64`;只接受节点 **label**,注解前缀被拒。`Build` 的关键语义:缺中间层标签**跳过而不截断链路**(可选的 rackid 不会把节点从更大的域里踢出去),域身份由"本层值 + 所有更高层值(含空值)"共同构成,所以两个超节点里同名的 rack-A 不会被合并。无任何 tier 值的节点仍得到只含自己的链,配对时报 `UnknownTier = MaxTier()+1`。
  <details><summary>代码依据 pkg/scheduler/topology/topology.go</summary>

  ```diff
  +// Tier 0 is the node itself. Configured tiers are numbered from 1 upward in the
  +// order given on --topology-tier-labels (smallest domain first). The lowest
  +// common ancestor of two nodes is their distance: the smaller its tier, the
  +// closer they sit on the fabric.
  +const (
  +	NodeTier = 0
  +	MaxTierLevel = 64
  +	domainIDSeparator = "\x00"
  +)
  +	if hasExplicit && hasPlain {
  +		return nil, fmt.Errorf("topology tiers mix explicit key=N levels with plain keys; use one style for all entries")
  +	}
  +// LCA returns the lowest common ancestor of a and b: the deepest tier both
  +// nodes belong to, including NodeTier when they are the same node.
  +func (t *Tree) LCA(a, b string) *HyperNode {
  +	for level := range min(len(left), len(right)) {
  +		if left[level] == nil || right[level] == nil {
  +			continue
  +		}
  +		if left[level] == right[level] {
  +			return left[level]
  +		}
  +	}
  +// TierOf returns the tier of the lowest common ancestor of a and b, which is
  +// UnknownTier when they share no configured domain.
  ```
  </details>

- **模型只"热着",不参与放置**:`Scheduler` 新增 `topology atomic.Pointer[topologyView]` 字段,`register` 复用已 list 的节点重建树(不新增 watch、不新增 CRD、不新增 controller),`onUpdateNode` 在配置的 tier 标签变化时立即触发重建而不是等 15s ticker,失去 leader 时置 nil。注释明确写了"Placement that consumes it lands in later PRs"。
  <details><summary>代码依据 pkg/scheduler/topology_model.go / pkg/scheduler/scheduler.go</summary>

  ```diff
  +// topologyView is one immutable snapshot of the cluster interconnect hierarchy
  +// built from node labels. Placement decisions that consume this view land in
  +// later PRs; this file only keeps the cache fresh.
  +func (s *Scheduler) rebuildTopology(nodes []*corev1.Node) {
  +	tiers, err := topology.ParseTiers(config.TopologyTierLabels)
  +	if err != nil {
  +		klog.ErrorS(err, "Ignoring invalid topology tier labels", "tierLabels", config.TopologyTierLabels)
  +		s.topology.Store(nil)
   	if oldNode.Annotations[common.DeviceCordonAnnotation] != newNode.Annotations[common.DeviceCordonAnnotation] {
   		s.doNodeNotify()
  +		return
   	}
  +	s.notifyIfTopologyChanged(oldNode, newNode)
  ```
  </details>

- **`--topology-tier-labels` 走启动期强校验**:`validateSchedulerOptions` 新增 `validateTopologyConfig`,参数写错直接启动失败,而不是运行期静默忽略。
  <details><summary>代码依据 cmd/scheduler/scheduler_options.go / cmd/scheduler/main.go</summary>

  ```diff
  +	rootCmd.Flags().StringVar(&config.TopologyTierLabels, "topology-tier-labels", "", "comma-separated node label keys describing the interconnect hierarchy, from the smallest domain to the largest, e.g. 'hami.io/rackid,hami.io/superpodid'. Use key=N to pin an explicit tier level. Only node labels are accepted. Empty disables the topology model.")
  +func validateTopologyConfig() error {
  +	if _, err := topology.ParseTiers(config.TopologyTierLabels); err != nil {
  +		return fmt.Errorf("invalid --topology-tier-labels: %w", err)
  +	}
  ```
  </details>

- **弃用指标真删了**:`ContainerDeviceMemory`(`hami_container_device_memory_bytes`)从 schema 和 vGPUmonitor 的 Describe/Collect 全链路删除;`hami_resource_quota_used` 的 `limit` 标签从 desc 与 `sendMetric` 实参里一起删掉。SKILL.md 同步改成"没有 `hami_resource_quota_limit` 序列"而不是过去的"`limit=0`"判据——**这是面向用户的告警/看板破坏性变更**。
  <details><summary>代码依据 pkg/monitor/metrics/schema.go / cmd/scheduler/metrics.go</summary>

  ```diff
  -	ContainerDeviceMemory = prometheus.NewDesc(
  -		"hami_container_device_memory_bytes",
  -		`Container device memory usage in bytes (DEPRECATED: use hami_vgpu_memory_used_bytes, deprecated in v2.11.0, removed in v2.12.0)`,
  -		[]string{"namespace", "pod", "container", "vdevice_index", "device_uuid"}, nil,
  -	)
  -		"resourcequota usage for a certain device (DEPRECATED: the limit label is deprecated in v2.11.0, removed in v2.12.0; use hami_resource_quota_limit instead)",
  -		[]string{"namespace", "quota_name", "limit"}, nil,
  +		"resourcequota usage for a certain device",
  +		[]string{"namespace", "quota_name"}, nil,
  ```
  </details>

- **tracing 从"有包无调用"变成全链路接线**:webhook 用 `wh.WithContextFunc = tracing.ExtractRequest` 从 HTTP header 取上游 trace,admission 结束前**先删掉 Pod 上已有的 `hami.io/traceparent` 再按需重注**(防伪造),所有 Denied 分支都打 `tracing.SetError`。Bind 侧 lock node / patch pod / bind pod 各自一个子 span,失败时按 `metrics.FailureReason*` 打 `hami.failure_reason` 属性,klog 行通过 `tracing.WithTraceID` 带上 traceID。Filter 失败做了**去重**:同一 Pod 重复同因失败只累加 `hami.filter.skipped_attempts`,不再每轮生成一条 span。
  <details><summary>代码依据 pkg/scheduler/webhook.go / pkg/scheduler/tracing.go</summary>

  ```diff
   	wh := &admission.Webhook{Handler: &webhook{decoder: decoder}}
  +	wh.WithContextFunc = tracing.ExtractRequest
  +	delete(pod.Annotations, tracing.TraceparentAnnotation)
  +	if hasResource {
  +		pod.Annotations = tracing.Inject(ctx, pod.Annotations)
  +	}
  +	last, seen := s.filterFailures[pod.UID]
  +	if seen && last.summary == fmt.Sprint(reason, message, rejectionCounts(failedNodes)) {
  +		last.skipped++
  +		s.filterFailures[pod.UID] = last
  +		return
  +	}
  ```
  </details>

- **`PodManager` 新增 `Traceparent` 字段**:Filter 写进 Pod 注解的 trace 上下文同时存进内存,**Bind 不必等 informer 看到 Filter 的 patch** 就能拿到父 span;`bindParentContext` 先读内存再退回读注解。
  <details><summary>代码依据 pkg/device/pods.go</summary>

  ```diff
  +	// Traceparent is the trace context Filter wrote to the pod, kept so Bind
  +	// can read it before the informer shows Filter's patch.
  +	Traceparent string
  +func (m *PodManager) SetTraceparent(pod *corev1.Pod, traceparent string) {
  +	if pi, exists := m.pods[pod.UID]; exists {
  +		pi.Traceparent = traceparent
  +	}
  ```
  </details>

- **配额准入与 Filter 共用一份"Pod 峰值请求"算法**:`fitResourceQuota` 里那段 init/sidecar/app 容器取峰值的逻辑抽成 `podDeviceRequestTotal(pod, dev)`,既去重又让 tracing 能复用它上报 `hami.request.memory`/`hami.request.cores`。顺带 `privilegedContainerName` 改成索引遍历,避免每个容器复制一次 `Container` 结构体(#3499)。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  -	for _, ctr := range pod.Spec.InitContainers {
  -		if isPrivilegedContainer(&ctr) {
  -			return ctr.Name, true
  +	for i := range pod.Spec.InitContainers {
  +		if isPrivilegedContainer(&pod.Spec.InitContainers[i]) {
  +			return pod.Spec.InitContainers[i].Name, true
  -		var appMemoryReq, appCoresReq int64
  -		for i := range pod.Spec.Containers {
  -			...
  +		memoryReq, coresReq, err := podDeviceRequestTotal(pod, dev)
  +		if err != nil {
  +			return err
  +		}
  ```
  </details>

- **`libvgpu` 子模块 bump `d8b6c45` -> `1b9824e`**(#3537,dependabot),即把 HAMi-core 的 CUDA Graph 计费那组改动拉进主仓镜像。注意 `1b9824e` 正是 HAMi-core 本期 #434 的 merge commit,主仓**尚未**包含更晚的 #435 导出表修复。
  <details><summary>代码依据 libvgpu(submodule)</summary>

  ```diff
  -Subproject commit d8b6c459bc6bed03a02aebfeb62d460f62e6fc53
  +Subproject commit 1b9824e48b2810dc7cab60535928800dbf57dceb
  ```
  </details>

### 后续发展方向 [AI]

- 拓扑模型的落点已经写在注释里:`LCA`/`TierOf`/`UnknownTier` 这组 API 是给"同一分布式作业的成员留在同一网络域内"用的,`UnknownTier = MaxTier()+1` 的设计注释直接写了"so a later hard tier limit rejects such a pair",说明下一步会出**硬性 tier 约束的亲和策略**(很可能以 Pod 注解表达"最多允许跨到第 N 层")。它刻意不引入 CRD、不引入 controller、只吃节点 label,与 Volcano HyperNode(需要 CRD)是两条路线:HAMi 选的是零 CRD、调度器内存建模。证据只覆盖本期 diff,未见任何消费该模型的 Filter/Score 代码。
- `hami.io/rackid` / `hami.io/superpodid` 被标为"canonical node keys shared with superpod-aware scheduling",而 `webhook.go` 里已有的 `injectSuperpodAffinity` 仍是独立实现。证据边界:本期没有把 superpod 亲和改走 topology 树,两套机制目前并存,**合流与否未见代码**。
- 可观测性方向明确从"指标"转向"指标 + 分布式链路":一边删弃用指标收窄标签基数,一边给 admission/Filter/Bind 铺 span 并做失败去重(`FilterSkippedAttemptsKey`)。对我们产品的启示:若用户看板依赖 `hami_container_device_memory_bytes` 或 `QuotaUsed` 的 `limit` 标签,**v2.12.0 升级会直接断图**,需要提前在升级说明里给出 `hami_vgpu_memory_used_bytes` / `hami_resource_quota_limit` 的替换映射;同时 HAMi 已把 traceparent 打通到 Bind,接 OTel collector 可以直接拿到"排队-Filter-Bind"分段耗时,这是我们之前只能靠日志拼的部分。证据只覆盖 scheduler 侧,device-plugin / vGPUmonitor 是否接 span 未见。

## Project-HAMi/HAMi-core: d8b6c459 -> 7e686fe2

- 比较: d8b6c459bc6bed03a02aebfeb62d460f62e6fc53 -> 7e686fe2 | ahead=16 | files=18 | Release: —
- 比较链接:https://github.com/Project-HAMi/HAMi-core/compare/d8b6c459bc6bed03a02aebfeb62d460f62e6fc53...7e686fe2b46d206fb6fcb11d24d65df8f6f72151

### AI 总结重点(源码 diff 为据)

- **这是本期最重要的能力边界修正:CUDA Graph 回放此前完全不受算力限流约束**。注释把漏洞说得很直白——graph replay 不经过 `cuLaunchKernel`,所以不触发 `rate_limiter`,"a graph-heavy process could run far above `CUDA_DEVICE_SM_LIMIT`"。修法是在实例化时遍历 graph 节点,按 `kernel_threads = (gx*gy*gz) * (bx*by*bz)` 累加(用 `saturating_add` 防溢出),存进 `launch_costs[65536]` 开放寻址表(key 为 `CUgraphExec`,删除时做回移保持探测短);`submit_graph` 在 launch(非 upload)路径上以整图总量调一次 `rate_limiter(threads, 1)`。
  <details><summary>代码依据 src/cuda/graph.c</summary>

  ```diff
  +/* A graph replay never passes through cuLaunchKernel, so its kernels would skip
  + * rate_limiter and a graph-heavy process could run far above CUDA_DEVICE_SM_LIMIT.
  + * Each executable graph is charged, at every launch, the summed threads
  + * (grid x block) of the kernel nodes it was instantiated from */
  +#define LAUNCH_COST_SLOTS 65536  /* power of two */
  +#define LAUNCH_COST_MAX_DEPTH 8  /* child-graph nesting followed when summing */
   static CUresult submit_graph(cuda_sym_t submit, CUgraphExec exec, CUstream stream, int per_thread, int upload) {
  +    if (!upload) {
  +        ENSURE_RUNNING();
  +        pre_launch_kernel();
  +        if (pidfound == 1) {
  +            int64_t threads = launch_cost_get(exec);
  +            if (threads > 0) rate_limiter(threads, 1);
  +        }
  +    }
  ```
  </details>

- **计费覆盖 child graph 与 conditional 节点**:`graph_kernel_threads` 递归 child graph(深度上限 8 层),对 CUDA 12.3+ 的 `CU_GRAPH_NODE_TYPE_CONDITIONAL` 节点取各分支 body 的**最大值**(`conditional_threads` 里 `if (threads > most) most = threads`),conditional body 的句柄只能在 `cuGraphAddNode` 时拿到,所以新增 `graph_conditional_added` 在建节点时登记、`conditional_forget` 在销毁时回收。驱动缺少 `cuGraphGetNodes`/`cuGraphNodeGetType` 等查询能力时"leaves the graph uncharged, as before",**降级行为保持旧语义**。
  <details><summary>代码依据 src/cuda/graph.c / src/cuda/memory.c</summary>

  ```diff
  +    /* A driver without the node queries leaves the graph uncharged, as before. */
  +    if (CUDA_FIND_ENTRY(cuda_library_entry, cuGraphGetNodes) == NULL ||
  +        CUDA_FIND_ENTRY(cuda_library_entry, cuGraphNodeGetType) == NULL || ...)
  +        return 0;
  +#if CUDA_VERSION >= 12030
  +            } else if (type == CU_GRAPH_NODE_TYPE_CONDITIONAL) {
  +                int64_t threads = conditional_threads(nodes[i], depth);
  +                total = saturating_add(total, threads);
  +#endif
  +#if CUDA_VERSION >= 12030
  +    /* Conditional bodies are only reported here; the compute limiter needs them for launch costs. */
  +    if (res == CUDA_SUCCESS && params != NULL && params->type == CU_GRAPH_NODE_TYPE_CONDITIONAL)
  +        graph_conditional_added(*node, graph, params->conditional.phGraph_out, params->conditional.size);
  +#endif
  ```
  </details>

- **防重复计费:stream capture 期间的 kernel 不再立即扣费**。新增 `kernel_charged(stream)`,用 `cuStreamGetCaptureInfo_v3/_v2` 判断 stream 是否处于捕获态;捕获态下 kernel 只是被录进 graph、并没有真正执行,改为在 graph launch 时统一计费。`cuLaunchKernel`/`cuLaunchKernelEx`/`cuLaunchCooperativeKernel` 三处的 `if (pidfound==1)` 全部换成 `if (kernel_charged(...))`。
  <details><summary>代码依据 src/cuda/memory.c</summary>

  ```diff
  +/* A kernel launched into a capturing stream is only recorded, not run. It is charged
  + * every time the captured graph is launched instead (see submit_graph in graph.c). */
  +static int kernel_charged(CUstream stream) {
  +    ...
  +    return graph_capture_info(stream, &cap, &id, &graph) != CUDA_SUCCESS || cap == CU_STREAM_CAPTURE_STATUS_NONE;
  +}
  -    if (pidfound==1){ 
  +    if (kernel_charged(hStream)){
           rate_limiter((int64_t)gridDimX * gridDimY * gridDimZ, ...);
  ```
  </details>

- **改图后重算费用:新增 6 个 exec-update hook**。`cuGraphExecUpdate` / `cuGraphExecUpdate_v2` 整图重算,`cuGraphExecKernelNodeSetParams(_v2)` / `cuGraphExecNodeSetParams` / `cuGraphExecChildGraphNodeSetParams` 单节点重算——因为 `cuGraphExec*NodeSetParams` 能在不生成新 graph 的前提下改掉某个节点的 launch 尺寸,旧费用会失真。对 12.0 之前只有旧签名的驱动,`load_cuda_libraries` 把 `_v2` 槽留空(不回退到名字相近的旧符号),hook 直接返回 `CUDA_ERROR_NOT_SUPPORTED`。
  <details><summary>代码依据 src/cuda/graph.c / src/cuda/hook.c</summary>

  ```diff
  +CUresult cuGraphExecUpdate_v2(CUgraphExec hGraphExec, CUgraph hGraph, CUgraphExecUpdateResultInfo *resultInfo) {
  +    if (CUDA_FIND_ENTRY(cuda_library_entry, cuGraphExecUpdate_v2) == NULL) return CUDA_ERROR_NOT_SUPPORTED;
  +    CUresult res = CUDA_OVERRIDE_CALL(cuda_library_entry, cuGraphExecUpdate_v2, hGraphExec, hGraph, resultInfo);
  +    if (res == CUDA_SUCCESS) launch_cost_record(hGraphExec, hGraph, 1);
  -                if (i == OVERRIDE_cuGraphAddNode_v2 || i == OVERRIDE_cuGraphAddNode_v3) continue;
  +                /* Older spellings of these take other arguments; leave the slot empty instead. */
  +                if (i == OVERRIDE_cuGraphAddNode_v2 || i == OVERRIDE_cuGraphAddNode_v3 ||
  +                    i == OVERRIDE_cuGraphExecUpdate_v2 || i == OVERRIDE_cuGraphExecKernelNodeSetParams_v2)
  +                    continue;
  ```
  </details>

- **release 构建的 hook 符号此前是隐藏的,等于 LD_PRELOAD 插桩失效**。`CMakeLists.txt` 去掉 `-fvisibility=hidden`,改用版本脚本 `src/libvgpu.map` 精确导出:`dlsym`、`vgpu_hostpid_found`、`cu[A-Z]*`、`nvml[A-Z]*` 为 global,分配器内部函数 `cuMemoryAllocate`/`cuMemoryFree` 与其余一律 local。注释写明理由:"A program that links libcuda or libnvidia-ml directly reaches the hooks through LD_PRELOAD symbol interposition, so every cu* and nvml* hook must be exported."
  <details><summary>代码依据 CMakeLists.txt / src/libvgpu.map</summary>

  ```diff
  -    set(LIBRARY_COMPILE_FLAGS -shared -fPIC -D_GNU_SOURCE -fvisibility=hidden -Wall)
  +    # src/libvgpu.map decides which symbols are exported. Do not compile with
  +    # -fvisibility=hidden: a hidden symbol cannot be exported by the version
  +    # script, and the cu* and nvml* hooks must be exported.
  +    set(LIBRARY_COMPILE_FLAGS -shared -fPIC -D_GNU_SOURCE -Wall)
  +{
  +  global:
  +    dlsym;
  +    vgpu_hostpid_found;
  +    cu[A-Z]*;
  +    nvml[A-Z]*;
  +  local:
  +    cuMemoryAllocate;
  +    cuMemoryFree;
  +    *;
  +};
  ```
  </details>

- **`dlsym` 分派不再依赖"自己导出了什么"**:`libvgpu_dlsym_dispatch` 原来用 `real_dlsym(vgpulib, symbol)` 在自身库里查符号,隐藏可见性下查不到;改成走表 `__dlsym_hook_section_exported`。同时 `DLSYM_HOOK_FUNC` 增加 `exported_names` 开关区分"表里写的名字"和"经 cuda.h 宏展开后的导出名",保证 dlsym 要 `cuDeviceGetUuid` 时拿到原生 v1 而不是 `_v2` hook;`cuGetProcAddress` 之外的路径不再刷 `NEED TO RETURN NULL` 警告。
  <details><summary>代码依据 src/libvgpu.c / src/include/libvgpu.h</summary>

  ```diff
  -        void *f = real_dlsym(vgpulib,symbol);
  +        /* Look the hook up in the table rather than with dlsym on this
  +         * library, which only sees exported symbols and so finds nothing
  +         * when the library is built with -fvisibility=hidden. */
  +        void *f = __dlsym_hook_section_exported(symbol);
  -    if (0 == strcmp(symbol, #f)) {                               \
  +    if (0 == strcmp(symbol, exported_names ? DLSYM_HOOK_NAME(f) : #f)) { \
  -                LOG_WARN("NEED TO RETURN NULL");
  +                if (!exported_names)
  +                    LOG_WARN("NEED TO RETURN NULL");
  ```
  </details>

- **primary context 的显存记账改为"最后一次释放才退费"**。`cuDevicePrimaryCtxRelease_v2` 原来一进函数就按 `ctx_activate[dev]==1` 退掉 `context_size`,导致还有其他引用存在时显存被提前减记;现在改到调用 `cuDevicePrimaryCtxGetState` 确认 context 已 inactive 之后才退费。
  <details><summary>代码依据 src/cuda/context.c</summary>

  ```diff
  -    if (ctx_activate[dev] == 1) {
  -        rm_gpu_device_memory_usage(getpid(),dev,context_size,0);
  -    }
  -    ctx_activate[dev] = 0;
  +        // Keep the charge while the context lives, so a release that
  +        // leaves another reference does not uncount it.
           if (CUDA_OVERRIDE_CALL(cuda_library_entry, cuDevicePrimaryCtxGetState, dev,
  -                               &flags, &active) == CUDA_SUCCESS && !active)
  +                               &flags, &active) == CUDA_SUCCESS && !active) {
  +            if (ctx_activate[dev] == 1) {
  +                rm_gpu_device_memory_usage(getpid(),dev,context_size,0);
  +            }
  +            ctx_activate[dev] = 0;
  ```
  </details>

### 后续发展方向 [AI]

- 软切分的**算力(SM)隔离正在从"按 kernel 调用计费"升级为"覆盖 CUDA 执行图的全部提交路径"**。这件事的产品含义很具体:vLLM、TensorRT-LLM 这类推理栈默认开 CUDA Graph capture,在本次修复之前,它们的稳态推理阶段几乎全部 kernel 都走 graph replay,`CUDA_DEVICE_SM_LIMIT` 对它们**基本不生效**——这正好解释了"HAMi 限了算力但推理 Pod 仍能打满 GPU"这类现场反馈。证据是 `submit_graph` 新增的计费分支与注释本身,没有逐 PR 展开看是否有基准数据。
- 计费精度仍有**已被作者自己标注的缺口**:提交里有两条 docs commit 明确记录 "while loops are undercharged"(conditional 取分支最大值,循环体执行多次只算一次)与 "graphs are charged to one device"(`rate_limiter` 只认当前 device,跨多卡的 graph 全算在一张卡上)。对我们产品的启示:若要对外承诺算力隔离精度,这两点要写进已知限制,尤其多卡单 graph 场景会出现"另一张卡无限流"。证据来自 commit 标题与 `submit_graph` 的注释,未见对应测试。
- 导出表(`libvgpu.map`)这一步把 HAMi-core 从"编译出来能用就行"推向**可控 ABI 表面**:显式只导出 `cu*`/`nvml*`/`dlsym`,内部分配器函数转 local。这既是修 bug 也是为后续新增 hook 家族(NPU / 其他厂商 runtime)留出干净的符号边界。证据只覆盖本期三个 commit,未见其他 runtime 的 hook 落地。
- 计量加固的方向与昨天一致(昨天是共享内存 slot 生命周期与 pidfd 判活,今天是 context 退费时机与 graph 计费),说明 **HAMi-core 当前主线是"把记账算准",而不是加新隔离维度**。

## Project-HAMi/volcano-vgpu-device-plugin: 327cd25b -> 4781e41d

- 比较: 327cd25b4a6e8b1c408db9e522428b5e31216cf2 -> 4781e41d | ahead=8 | files=15 | Release: volcano-vgpu-device-plugin-1.13.0
- 比较链接:https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/327cd25b4a6e8b1c408db9e522428b5e31216cf2...4781e41df9edac3c30e882a5183409601643c644

### AI 总结重点(源码 diff 为据)

- **本期没有功能/调度逻辑改动,8 个提交里 7 个是 dependabot 版本 bump(ubuntu 基础镜像、actions/setup-go 7.1.0、codeql 4.39.4、mig-parted 0.15.1→0.15.2、scorecard-action 2.6.0 等),唯一的实质提交 #265 是发版流程治理**:新增 `CHANGELOG.md` 回溯补齐 v1.9.x~v1.13.0 的发版说明,新增 `hack/verify-release-notes.py` 在 helm-release / release-image 工作流里做闸门——打 tag 前 `CHANGELOG.md` 必须有且仅有一条对应标题(`## v<version>` 或 `## Helm chart <version>`)且下面有条目,否则 CI 失败。README 挂上 OpenSSF Best Practices 徽章(项目号 16915)。
  <details><summary>代码依据 hack/verify-release-notes.py / .github/workflows/helm-release.yml</summary>

  ```diff
  +"""Require a reviewed changelog entry before publishing a release."""
  +def verify(changelog, version, kind):
  +    title = "v" + version.removeprefix("v") if kind == "plugin" else f"Helm chart {version}"
  +    heading = f"## {title}"
  +    matches = [i for i, line in enumerate(lines) if line.rstrip() == heading]
  +    if len(matches) != 1:
  +        raise ValueError(f"expected one '{heading}' in {changelog}, found {len(matches)}")
  +      - name: Verify release notes
  +        run: python3 hack/verify-release-notes.py --kind chart --version "${CHART_VERSION}"
  ```
  </details>

- 回溯的 CHANGELOG 顺带披露了 v1.13.0 的 CVE 修复范围(CVE-2026-84303 / 84445 / 84304 / 33186 / 25680 / 41579,均为依赖升级),以及一条使用约束:**CDI 与 nvml-mock 不能同时开启**。这是文档化既有行为,不是本期代码改动。
  <details><summary>代码依据 CHANGELOG.md</summary>

  ```diff
  +- Supports device and node configuration, CDI, `runtimeClassName` and GPU-free
  +  testing through nvml-mock. CDI and nvml-mock cannot be enabled together.
  +- Updates HAMi-core, Go and other dependencies, and adds keyless signing to
  +  release images. Dependency upgrades and removals address CVE-2026-84303, ...
  ```
  </details>

### 后续发展方向 [AI]

- HAMi × Volcano 这条集成路径**本期在代码层面是静止的**,动的是供应链与发版合规(OpenSSF 徽章、release-notes 闸门、镜像 keyless 签名)。对我们产品的启示:若把该插件作为 Volcano 场景的上游依赖,它的 CVE 修复节奏现在可以直接从 `CHANGELOG.md` 追踪,不必逐个 release 页翻。证据仅覆盖本期 diff,未见任何 vGPU 分配/调度代码改动。

## Project-HAMi/HAMi-WebUI: 19a0f955 -> 43298757

- 比较: 19a0f955a652ba7f7e4af5a9315686829e884328 -> 43298757 | ahead=20 | files=121 | Release: v1.3.0
- 比较链接:https://github.com/Project-HAMi/HAMi-WebUI/compare/19a0f955a652ba7f7e4af5a9315686829e884328...43298757f33c5e36e39eb1d0e79a84f6c695daa9

### AI 总结重点(源码 diff 为据)

- **厂商适配从"散在业务代码里的 if/else"收敛为三套 Dialect 接口**:新增 `InventoryDialect`(节点注册解析 + 资源归属 + catalog 映射)、`AllocationDialect`(Pod 分配注解解码)、`TelemetryDialect`(物理遥测查询),以及新包 `server/internal/provider/registry` 统一注册内置厂商实现。最直观的证据是 `providerfacts.Build` 的签名多了 `dialects []provider.InventoryDialect` 参数,函数体里 NVIDIA/HCU/DCU/Metax/Ascend 五段 `if selected("X")` 被一个 dialect 循环整体替换。
  <details><summary>代码依据 server/internal/providerfacts/snapshot.go</summary>

  ```diff
  -	"vgpu/internal/provider/ascend"
  -	"vgpu/internal/provider/hygon"
  -	"vgpu/internal/provider/metax"
  -	"vgpu/internal/provider/mlu"
  -	"vgpu/internal/provider/nvidia"
  +	"vgpu/internal/provider"
  -func Build(nodes []*corev1.Node, ..., nodeEvidence *viewv1.Coverage) resourceview.Snapshot {
  +func Build(nodes []*corev1.Node, ..., nodeEvidence *viewv1.Coverage, dialects []provider.InventoryDialect) resourceview.Snapshot {
  -		if selected("NVIDIA") {
  -			if raw, present := node.Annotations[nvidia.RegisterAnnos]; present {
  -				records, err := nvidia.RegistrationFacts(raw, logger)
  -				appendRegistrationFacts(&out, &fact, node, catalog, "NVIDIA", "nvidia", "NVIDIA", records, err)
  -			}
  -		}
  -		if selected("HCU") { ... }
  +		for _, dialect := range dialects {
  +			if dialect == nil {
  +				continue
  ```
  </details>

- **registry 把"有注册注解的厂商"和"只有原生资源池的厂商"统一成一种东西**:`DefaultInventoryDialects()` 列出 nvidia / hygon(HCU+DCU) / metax(SGPU) / ascend / mlu,再加一个 `resourcePoolDialect{name:"native-accelerator-pools"}` 覆盖 `mthreads.com/{gpu,vgpu,sgpu-core,sgpu-memory}` 与 `amd.com/gpu*`——这类卡没有 HAMi 注册注解,所以该 dialect 的 `SelectorKey()` 返回空、`ExtractNode` 返回空清单,只实现 `OwnsResource` 做资源名归属。`DefaultAllocationDialects` 还带 `AllocationConfig{AscendAnnotationlessPolicy}`,说明昇腾"无注解 Pod"的处置策略现在是显式配置项。
  <details><summary>代码依据 server/internal/provider/registry/registry.go</summary>

  ```diff
  +func DefaultInventoryDialects() []provider.InventoryDialect {
  +	return []provider.InventoryDialect{
  +		nvidia.NewInventoryDialect(), hygon.NewHCUDialect(), hygon.NewDCUDialect(),
  +		metax.NewSGPUDialect(), ascend.NewDialect(), mlu.NewDialect(),
  +		resourcePoolDialect{
  +			name: "native-accelerator-pools",
  +			exact: map[string]bool{"mthreads.com/gpu": true, ..., "amd.com/gpu": true},
  +			prefixes: []string{"amd.com/gpu-"},
  +type AllocationConfig struct {
  +	AscendAnnotationlessPolicy string
  +}
  ```
  </details>

- **exporter 侧删掉三个按厂商分叉的文件,改走 TelemetryDialect**:`dcgm_samples.go`(348 行)、`node_observations.go`(120 行)、`metax_observations.go`(79 行)整体删除,新增 `provider/{nvidia,ascend,metax,hygon}/telemetry_dialect.go`。exporter 保留的厂商特判被压缩成一个 `legacyPhysicalQueryAllowed` 白名单函数(Cambricon 恒允许、原生 MetaX 需 AliasId 异于 Id、Hygon 仅旧式数字 DCU 命名),注释写清了每条例外的来由。
  <details><summary>代码依据 server/internal/exporter/exporter.go</summary>

  ```diff
  +	telemetryDialects []provider.TelemetryDialect
  +func (s *MetricsGenerator) activeTelemetryDialects() []provider.TelemetryDialect {
  +	if len(s.telemetryDialects) > 0 {
  +		return s.telemetryDialects
  +	}
  +	return registry.DefaultTelemetryDialects()
  +func legacyPhysicalQueryAllowed(device *biz.DeviceInfo) bool {
  +	case biz.MetaxGPUDevice:
  +		// Native MetaX (metax-tech.com/gpu) has no sGPU node annotation; its AliasId is "<node>-metax-<index>".
  +		return device.AliasId != "" && device.AliasId != device.Id
  ```
  </details>

- **大规模集群的内存与查询开销被正面处理**:新增 `server/internal/data/informer_transform.go`,给 Node/Pod informer 装 `SetTransform`,进 indexer 前按字段白名单重建对象(Pod 只留 NodeName/SchedulerName/Affinity/容器资源等,Node 只留 Capacity/Allocatable/Taints/Conditions),并显式删掉 `kubectl.kubernetes.io/last-applied-configuration` 注解。注释把三个坑都标了:不可原地改(client-go v0.30.1 的 Resync 会把缓存对象再喂一遍 transformer)、不可清空 ResourceVersion、不可返回非 nil error(会让对象从缓存里消失)。
  <details><summary>代码依据 server/internal/data/informer_transform.go</summary>

  ```diff
  +// trimInformerObject returns an independent, field-whitelisted copy of Node and
  +// Pod objects before they enter the shared informer indexer. Never mutate the
  +// input object in place (client-go v0.30.1 Resync replays cached items through
  +// the transformer), never clear ResourceVersion, and never return a non-nil
  +// error (which drops objects from the informer cache).
  +const lastAppliedConfigAnnotation = "kubectl.kubernetes.io/last-applied-configuration"
  +	annotations := maps.Clone(meta.Annotations)
  +	delete(annotations, lastAppliedConfigAnnotation)
  ```
  </details>

- **新增不可变快照 + 代际发布机制 `ClusterCapture` / `CaptureStore`**:每次发布构造一份深拷贝快照,预建 5 张主键索引(DeviceID / NodeUID / NodeName / PodUID / ContainerKey),查询侧拿到 O(1) 查找且读路径无锁(`atomic.Pointer`),写侧用 mutex 保证代号严格单调递增。这是把过去"每次请求现场扫列表"改成"读一份定格快照"。
  <details><summary>代码依据 server/internal/data/cluster_capture.go</summary>

  ```diff
  +// ClusterCapture is an immutable, generation-stamped snapshot of cluster facts
  +// with prebuilt primary-key lookup indexes. Callers obtain O(1) lookup by
  +// canonical DeviceID, NodeUID, NodeName, PodUID, or ContainerKey
  +type CaptureStore struct {
  +	mu      sync.Mutex
  +	seq     uint64
  +	current atomic.Pointer[ClusterCapture]
  +}
  +func (s *CaptureStore) Load() *ClusterCapture {
  +	return s.current.Load()
  +}
  ```
  </details>

- **前端彻底去掉 Vuex**:`src/store/` 四个文件(index/getters/modules/global/layout)全删,`main.js` 不再挂 store;新增 `src/utils/safe-storage.mjs` 做 storage 降级(禁用 localStorage 的浏览器/隐私模式下不崩);详情页请求全部带 `signal` 支持取消并用 `errorFeedback: 'inline'`,卡片详情对 `404 + RESOURCE_GPU_NOT_FOUND` 返回空对象而非抛错——对应服务端新增的 `GetGPU` 错误契约。
  <details><summary>代码依据 packages/web/projects/vgpu/api/card.js</summary>

  ```diff
  -  getCardDetail(params) {
  -    return request({ url: apiPrefix + '/v1/gpu', method: 'get', params });
  +  async getCardDetail(params, signal) {
  +    try {
  +      return await request({ url: apiPrefix + '/v1/gpu', method: 'get', errorFeedback: 'inline', params, signal });
  +    } catch (error) {
  +      if (error.response?.status === 404 && error.response.data?.reason === 'RESOURCE_GPU_NOT_FOUND') {
  +        return {};
  +      }
  +      throw error;
  +    }
  ```
  </details>

- **测试/CI 基建同步加码**:新增单二进制 Go smoke 测试(`server/cmd/hami-webui/smoke_test.go`,491 行)、Playwright 浏览器 smoke(`test/web-entry/unified-smoke.browser.test.mjs`)、HTTP 契约金样(`test/contracts/http-goldens/*.json` + `server/internal/server/http_goldens_test.go`),以及 `test/legacy-ui-boundary.test.mjs` 防旧 UI 残留回流;Helm 侧 `scripts/verify-chart.sh` 加最小 RBAC 校验。

### 后续发展方向 [AI]

- WebUI 的多厂商纳管方式**已经从"按厂商加一套 provider + init 注册"变成"按能力维度实现三个 Dialect 并在 registry 注册"**。接新加速卡的工作量结构也随之变化:只有遥测需求的卡只实现 `TelemetryDialect`,只有原生资源池、没有 HAMi 注册注解的卡(mthreads/amd 这类)只需在 `resourcePoolDialect` 里加资源名。这比之前那套"provider struct + `node-*-register` 注解发现"的模板门槛更低、分层更清楚。证据是 `dialect.go` 三个接口定义与 `registry.go` 的注册表,没有看到对应的开发者文档更新。
- 性能工作集中在**控制台在大集群下的读放大**:informer transform 砍对象体积、ClusterCapture 预建索引换 O(1) 查找、exporter 合并重复 Prometheus 查询(删 `dcgm_samples.go` 与两个 `*_observations.go`)。配合 v1.3.0 还没动,说明这些是下一个版本的底盘改造。证据只覆盖 diff,未见基准数字或内存占用对比。
- 服务端开始对外提供**显式错误契约**(`GetGPU` 的 `RESOURCE_GPU_NOT_FOUND`)并用 HTTP 金样锁住响应形状,前端同步改成 inline 错误 + 可取消请求。对我们产品的启示:若自家控制台复用 HAMi-WebUI 的 HTTP 接口,金样文件(`test/contracts/http-goldens/`)现在是判断接口是否破坏性变更最省力的入口。证据只覆盖本期新增的两个金样文件(overview-inventory、workloads-page)。

## 本期无实质改动(折叠)

- Project-HAMi/ascend-device-plugin:9325759b,无新提交(连续第二日零提交)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=3d600ea70324d4a4d60c59806ce0a78ab9810a7d branch=master release=v2.11.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=7e686fe2b46d206fb6fcb11d24d65df8f6f72151 branch=main release=— scanned=2026-11-27 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4781e41df9edac3c30e882a5183409601643c644 branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-27 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=43298757f33c5e36e39eb1d0e79a84f6c695daa9 branch=main release=v1.3.0 scanned=2026-11-27 -->
