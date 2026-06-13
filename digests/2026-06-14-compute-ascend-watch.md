# 昇腾算力栈 diff 雷达 2026-06-14

## 摘要(≤3 条)
- mind-cluster `ascend-for-volcano` 给 SuperPod 调度加了**缓存校验 + 故障重建回原节点**能力:新增 `VerifyCachedSuperPods`/`IsCachedSuperPodsValid` 与 `SuperPodsVerified` 字段,断点续训/故障重调度时,只有缓存的 SuperPod 节点仍在候选集且开启 `preferPreviousNode` 才直接复用原节点,否则重新调度。
- 同仓改 `volcano-v1.12.0.yaml` 调度器配置:把抢占/回收能力从 `gang` 上摘掉,改挂到 `volcano-npu_v6.0.RC1` 插件(`enablePreemptable/enableReclaimable: true`),为"volcano action 增强需求"做前置适配。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期均无新提交。

## 当日重要改变
- mind-cluster [新能力] SuperPod 故障重建回原节点 + 缓存有效性校验(新增 `VerifyCachedSuperPods`/`IsCachedSuperPodsValid` 方法、`SuperPodsVerified` 字段),三类 SuperPod 策略(chip8node8ra64sp / chip8node8sp / ascend910a3 superpod)统一改走此入口 — component/ascend-for-volcano/plugin/job.go — https://gitcode.com/Ascend/mind-cluster/compare/d0d8491bdfd04ff035e776ab1bbb3dae1a06c1c3...fe62b6328a073aed59f25fcfcff0b9a8672a93c2
- mind-cluster [架构方向] Volcano 调度器插件配置调整:抢占/回收(preempt/reclaim)由 gang 插件迁移到 volcano-npu 插件,为 volcano action 增强前置适配 — component/ascend-for-volcano/build/volcano-v1.12.0.yaml — 同上 compare 链接

## mind-cluster: d0d8491b -> fe62b632
- 比较: d0d8491bdfd04ff035e776ab1bbb3dae1a06c1c3..fe62b632 | tag: v26.0.1 | commits=8 | truncated=false
- compare: https://gitcode.com/Ascend/mind-cluster/compare/d0d8491bdfd04ff035e776ab1bbb3dae1a06c1c3...fe62b6328a073aed59f25fcfcff0b9a8672a93c2

### AI 总结重点(源码 diff 为据)

- **新增 SuperPod 缓存校验入口 `VerifyCachedSuperPods(nodes, preferPreviousNode)`,把"job 已 ready 就跳过重调度"的判断从"只看 `JobReadyTag && len(SuperPods)!=0`"收紧为"还要校验缓存节点仍可用 + 用户开启了回原节点偏好"。** 前:策略直接判断 `*job.JobReadyTag && len(job.SuperPods) != 0`(或 `tp.isJobCacheSuperPod`)就 return 复用缓存;后:走新方法,先用 `SuperPodsVerified` 做一次性短路(校验过直接 true),否则要求 `IsCachedSuperPodsValid(nodes) && preferPreviousNode` 都成立才复用,否则返回 false 触发重新调度。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go</summary>

  ```diff
  +func (sJob *SchedulerJob) VerifyCachedSuperPods(nodes []*api.NodeInfo, preferPreviousNode bool) bool {
  +	if !*sJob.JobReadyTag || len(sJob.SuperPods) == 0 {
  +		return false
  +	}
  +	if sJob.SuperPodsVerified {
  +		return true
  +	}
  +	sJob.SuperPodsVerified = true
  +	if sJob.IsCachedSuperPodsValid(nodes) && preferPreviousNode {
  +		...cached super pods are still available, schedule directly from cache...
  +		return true
  +	}
  +	...cached super pods are invalid or prefer-previous-node is disabled, need to reschedule...
  +	return false
  +}
  ```
  </details>

- **新增 `IsCachedSuperPodsValid(nodes)`:逐个比对缓存的 SuperPod 节点是否仍在当前候选节点集里;关键细节是"pod 仍在运行的节点"被显式排除(它们被占用、本就不在候选集中),避免误判缓存失效。** 任一缓存节点既不在 running 集合也不在候选集合,就判定缓存无效返回 false。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/job.go</summary>

  ```diff
  +func (sJob *SchedulerJob) IsCachedSuperPodsValid(nodes []*api.NodeInfo) bool {
  +	nodeSet := make(map[string]struct{}, len(nodes))
  +	for _, n := range nodes { nodeSet[n.Name] = struct{}{} }
  +	runningNodes := make(map[string]struct{})
  +	for _, task := range sJob.Tasks {
  +		if task.NodeName != "" { runningNodes[task.NodeName] = struct{}{} }
  +	}
  +	for _, sp := range sJob.SuperPods {
  +		for _, sn := range sp {
  +			if _, running := runningNodes[sn.Name]; running { continue }
  +			if _, ok := nodeSet[sn.Name]; !ok { return false }
  +		}
  +	}
  +	return true
  +}
  ```
  </details>

- **三类 SuperPod 调度策略统一改走新入口,并在选定节点后置 `SuperPodsVerified = true`。** chip8node8ra64sp / chip8node8sp / ascend910a3-superpod 三个 `ScoreBestNPUNodes` 的缓存命中分支从各自的内联判断(`isJobCacheSuperPod` 或 `*job.JobReadyTag && len(job.SuperPods)!=0`)统一替换为 `job.VerifyCachedSuperPods(nodes, tp.FrameAttr.PreferPreviousNode)`;新选出 SuperPod 后同步把 `SuperPodsVerified` 标真,避免后续轮次重复校验。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8sp/frame.go(另两处同构)</summary>

  ```diff
  -	if *job.JobReadyTag && len(job.SuperPods) != 0 {
  +	if job.VerifyCachedSuperPods(nodes, tp.FrameAttr.PreferPreviousNode) {
   		klog.V(util.LogDebugLev).Infof("%s ScoreBestNPUNodes %s: job is ready, skip", ...)
   		return nil
   	}
   	...
   	*job.JobReadyTag = true
   	job.SuperPods = selectedNodes
  +	job.SuperPodsVerified = true
  ```
  </details>

- **Volcano 调度器内置配置 `volcano-v1.12.0.yaml`:抢占/回收能力从 gang 插件迁到 volcano-npu 插件,并调整 tier 内插件顺序。** 前:`priority`(enableNodeOrder:false)排首、`gang` 次之、`volcano-npu_v6.0.RC1` 排末且无 preempt/reclaim 开关;后:`gang` 显式 `enablePreemptable:false / enableReclaimable:false`,`volcano-npu_v6.0.RC1` 上调到 priority 之前且开 `enablePreemptable:true / enableReclaimable:true`。即抢占/回收决策权交给昇腾 NPU 插件,而非通用 gang。
  <details><summary>代码依据 component/ascend-for-volcano/build/volcano-v1.12.0.yaml</summary>

  ```diff
  -      - name: priority
  -        enableNodeOrder: false
         - name: gang
           enableNodeOrder: false
  +        enablePreemptable: false
  +        enableReclaimable: false
  +      - name: volcano-npu_v6.0.RC1_linux-x86_64
  +        enablePreemptable: true
  +        enableReclaimable: true
  +      - name: priority
  +        enableNodeOrder: false
         - name: conformance
           enableNodeOrder: false
  -      - name: volcano-npu_v6.0.RC1_linux-x86_64
  ```
  </details>

- 配套:新增单测 `TestVerifyCachedSuperPods`(覆盖 JobReadyTag=false、SuperPods 空、已校验短路、缓存有效+preferPreviousNode 等用例);`validJobFn` 删了一处冗余括号(`(a||b)` → `a||b`);多文件 copyright 年限 bump 到 2026、`v1 "k8s.io/api/core/v1"` 改为匿名导入等 gofmt 噪声。两条 `<doc>` 提交(删除 DP 热复位插件预留文档、断点续训删除 ipv6 限制)落在 docs 目录、被 component PATHPREFIX 滤掉,无代码依据,不展开。

### 后续发展方向 [AI]
- 这批改动指向**昇腾大规模训练的故障自愈/断点续训调度**:核心是让故障 pod 在重调度时优先回到原 SuperPod 节点(`preferPreviousNode`),同时用 `IsCachedSuperPodsValid` 防止原节点已不可用时盲目复用脏缓存。证据只覆盖 ascend-for-volcano 调度侧的"回原节点"判定逻辑,未见 noded/clusterd 侧的故障检测与节点摘除如何触达此路径。
- yaml 把 preempt/reclaim 从 gang 迁到 volcano-npu 插件,配合提交标题"volcano action 增强需求前置适配",方向是**昇腾插件接管抢占/回收语义**(可能对接增强版 Volcano 的 enqueue/allocate/backfill/reclaim action)。证据只到配置层,未见 NPU 插件内 `Preemptable/Reclaimable` 回调的具体实现 diff,实际抢占算法是否改动待下期看 internal 下相关文件。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:本期无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=fe62b6328a073aed59f25fcfcff0b9a8672a93c2 tag=v26.0.1 scanned=2026-06-14 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-14 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-14 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-14 -->
<!-- ANCHOR repo=vNPU sha=8eb5e3c8e3f1a29f4f2e4c246fb3c00538b132af tag=v0.1.0 scanned=2026-06-14 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-14 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-14 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-14 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-14 -->
