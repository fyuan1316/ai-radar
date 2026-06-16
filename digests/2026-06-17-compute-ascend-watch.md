# 昇腾算力栈 diff 雷达 2026-06-17

## 摘要
- **mind-cluster 押注 UB(Unified Bus)超节点**:device-plugin / noded / npu-exporter 三个 openEuler 基础镜像统一引入 `UMDK_PKG`(umdk-urma 一套,libnl3-devel),坐实"950&850 产品型态支持 UB 通信"——超节点 fabric 进入算力栈底座;faultCode.json 同步新增整片 `8f1802xx` UB 故障码 + 新故障类别 `PreSeparateNPUCodes`(隔离前预警)。
- **ascend-for-volcano 断点续训亲和大改**:`prefer-previous-node` 回原节点打分从 +4 提到 +100(从"微调"变"强约束"),TaskOrderFn 改为 rank 序优先 / 回原节点次之,`GetPreferredNodeMap` 由"rank 区间"改"全量快照"并在 session 起始预载进 job;device-plugin 热复位钩子加 goroutine 超时网兜(防钩子忽略 ctx 卡死)。
- **vNPU 新增节点级分配锁**:为防同一节点并发 Pod 抢分 vNPU,引入两层锁(进程内 per-node `sync.Mutex` + 节点 annotation 锁),锁值由 `/proc/uptime` 改 `namespace/podName` 可溯源,失败回滚、成功只释放内存锁。

## 当日重要改变
- **mind-cluster [新能力/架构方向]** UB(Unified Bus)通信能力进入算力栈基础镜像:device-plugin/noded/npu-exporter 的 `Dockerfile.openeuler` 新增 `UMDK_PKG` ARG + umdk-urma rpm 安装,faultCode.json 新增 UB 故障码段。https://gitcode.com/Ascend/mind-cluster/compare/c51d2697...21a6d2f4
- **mind-cluster [行为变更]** ascend-for-volcano `defaultPreferPreviousScore` 4.0 → 100.0,回原节点从软偏好变硬偏好(component/ascend-for-volcano/plugin/const.go)。
- **mind-cluster [API变更]** `PodNodeAffinityCache.GetPreferredNodeMap` 签名由 `(ownerUID, startRank, endRank)` 收为 `(ownerUID)`,语义从区间取数改全量快照(component/ascend-for-volcano/common/cache/previous_node.go)。
- **vNPU [新能力]** 新增 `volcano-xpu-plugin/nodelock` 包 + 节点级两层分配锁,AllocateXPUForTask 接入(防同节点并发抢分)。https://gitcode.com/openFuyao/vNPU/compare/a30d9493...d78592e5

## mind-cluster: c51d2697 -> 21a6d2f4
- 比较 / 最新 Release:c51d2697..21a6d2f4 | tag v26.0.1 | commits=16 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/c51d2697...21a6d2f4

### AI 总结重点(源码 diff 为据)
- **UB(Unified Bus / UMDK-urma)通信能力下沉到三个组件的基础镜像**。三个 `Dockerfile.openeuler`(device-plugin / noded / npu-exporter)统一新增 `ARG UMDK_PKG`:给了离线包就 `rpm -ivh` 装,没给就 `yum install umdk-urma-bin/devel/lib/tools`,并补 `libnl3-devel`。这是"950&850 产品型态支持 UB 通信"的落地——昇腾超节点的统一总线运行时进了 K8s 侧组件镜像,不再只是宿主机驱动。
  <details><summary>代码依据 component/noded/build/Dockerfile.openeuler(device-plugin/npu-exporter 同构)</summary>

  ```diff
  +ARG UMDK_PKG=""
  +COPY ./${UMDK_PKG} /tmp
   RUN yum update -y && \
  -    yum install -y wget unzip shadow && \
  +    yum install -y wget unzip shadow libnl3-devel && \
  +    if [ -n "${UMDK_PKG}" ] && [ -f "/tmp/${UMDK_PKG}" ]; then \
  +        mkdir /tmp/umdk_pkgs; tar -mzxf "/tmp/${UMDK_PKG}" -C /tmp/umdk_pkgs; rpm -ivh /tmp/umdk_pkgs/*.rpm; \
  +    else \
  +        yum install -y umdk-urma-bin umdk-urma-devel umdk-urma-lib umdk-urma-tools; \
  +    fi && \
  ```
  </details>

- **faultCode.json 引入"隔离前预警"故障类别 + 整片 UB 故障码**。新增 `PreSeparateNPUCodes` 数组(`8f1802xx`/`8f184cxx` 等),`SeparateNPUCodes` 也批量灌入 `8f18xxxx` 段;`RestartBusinessCodes` 把若干码迁出、`RestartRequestCodes`/`FreeRestartNPUCodes`/`RestartNPUCodes` 各有增补。`8f18` 前缀成片出现,与上面 UB 镜像改动呼应——UB fabric 的链路/端口类故障被单列。
  <details><summary>代码依据 component/ascend-device-plugin/build/faultCode.json</summary>

  ```diff
  +  "PreSeparateNPUCodes":[
  +    "110001024","81B18603",
  +    "8118043c","8118045a","8f180220",...  (整段 8f1802xx UB 码)
  +  ],
     "SeparateNPUCodes":[
  -    ...,"80818c00","80818C05","80DF8402","80818C00","020001002"
  +    ...,"80818c00","80818C05","80DF8402","020001002",
  +    "8f180200","8f180201",...  (大段 8f18xxxx)
  ```
  </details>

- **device-plugin 热复位钩子链加 goroutine 超时网兜**。新增 `executeHookWithTimeout`:把 `PreReset/CustomReset/AfterReset` 各插件调用放进 goroutine + `context.WithTimeout`,用 `select` 等结果或超时,超时返回 `"plugin execution timeout after %v"`。旧写法只是建了 timeout context 直接同步调钩子,钩子若忽略 ctx 取消仍会卡死整链;新写法保证主流程一定能在超时后继续。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/plugin/plugin_manager.go</summary>

  ```diff
  +func executeHookWithTimeout(ctx context.Context, timeout time.Duration, hookFn func(context.Context) error) error {
  +	resultCh := make(chan hookResult, 1)
  +	hookCtx, cancel := context.WithTimeout(ctx, timeout); defer cancel()
  +	go func() { resultCh <- hookResult{err: hookFn(hookCtx)} }()
  +	select {
  +	case result := <-resultCh: return result.err
  +	case <-hookCtx.Done(): return fmt.Errorf("plugin execution timeout after %v", timeout)
  +	}
  +}
   func (pm *PluginManager) ExecutePreReset(...) {
   	for _, p := range chain {
  -		pluginCtx, cancel := context.WithTimeout(ctx, PreResetTimeout)
  -		err := p.PreReset(pluginCtx, deviceList); cancel()
  +		err := executeHookWithTimeout(ctx, PreResetTimeout, func(hookCtx context.Context) error {
  +			return p.PreReset(hookCtx, deviceList) })
  ```
  </details>

- **ascend-for-volcano 回原节点(断点续训亲和)从软偏好升为硬偏好**。`defaultPreferPreviousScore` 由 `4.0` 改 `100.0`——回原节点的打分加成现在足以压过其他打分项,故障恢复后 Pod 回原节点的确定性大幅提高。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/const.go</summary>

  ```diff
  -	preferPreviousNodeKey        = "prefer-previous-node"
  -	defaultPreferPreviousScore   = 4.0   // +4 score bonus for original node
  +	preferPreviousNodeKey      = "prefer-previous-node"
  +	defaultPreferPreviousScore = 100.0   // +100 score bonus for original node
  ```
  </details>

- **TaskOrderFn 改为"rank 序优先、回原节点次之",删掉原"故障 Pod 排healthy 之后"逻辑**。PodGroup 调度(`PodGroupScheduleKey`)下直接按 rank index 升序定序;否则在 `PreferPreviousNode` 开启时,有缓存原节点的 task 排前。配套 `initAffinityCache` 在 session 起始把每个活跃 job 的 `PrefNodeMap` 用 `GetPreferredNodeMap` 预载进 `sHandle.Jobs[jobID]`,打分阶段不再回查缓存。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/factory.go(hunk 截断,未覆盖全部)</summary>

  ```diff
  -	lFault := sHandle.isFaultPod(taskInfoA, job)
  -	rFault := sHandle.isFaultPod(taskInfoB, job)
  -	if lFault != rFault { ... }
  +	rRankId := sHandle.resolveRankIndex(taskInfoB, job)
  +	lRankId := sHandle.resolveRankIndex(taskInfoA, job)
  +	if exist && podGroupEnable == PodGroupScheduleValue {
  +		lRank,_ := strconv.Atoi(lRankId); rRank,_ := strconv.Atoi(rRankId)
  +		if lRank < rRank { return taskOrderHighPriority }
  +		return taskOrderLowPriority
  +	}
  +	if sHandle.FrameAttr.PreferPreviousNode {
  +		lNode := sHandle.AffinityCache.GetPreferredNode(job.Owner.UID, lRankId) ...
  +	}
  // initAffinityCache:
  +	job.PrefNodeMap = sHandle.AffinityCache.GetPreferredNodeMap(job.Owner.UID)
  +	sHandle.Jobs[jobID] = job
  ```
  </details>

- **`GetPreferredNodeMap` 签名/语义变更**(配合上条预载):由按 `[startRank,endRank)` 区间取数,改为返回该 owner 全部 rank→node 缓存项;无效 rank key 跳过并 debug 日志。
  <details><summary>代码依据 component/ascend-for-volcano/common/cache/previous_node.go</summary>

  ```diff
  -func (c *PodNodeAffinityCache) GetPreferredNodeMap(ownerUID types.UID, startRank, endRank int) map[int]string {
  -	for rank := startRank; rank < endRank; rank++ { ... }
  +func (c *PodNodeAffinityCache) GetPreferredNodeMap(ownerUID types.UID) map[int]string {
  +	for rankStr, entry := range rankNodes {
  +		rank, err := strconv.Atoi(rankStr); if err != nil { ...continue }
  +		result[rank] = entry.Node
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- UB/UMDK 进基础镜像是本期最强信号:昇腾正把"超节点统一总线"做成算力栈一等公民(镜像内运行时 + 专属故障码 + 隔离前预警),方向对标 NVLink/NVSwitch fabric 的可观测与故障隔离。证据只覆盖镜像构建 + faultCode.json,未见 device-plugin 上报 UB 资源/拓扑的 Go 代码(本区间 patch 未出现),后续值得盯 npu-exporter/noded 是否新增 UB 链路指标。
- ascend-for-volcano 这套(回原节点 +100、rank 序、PrefNodeMap 预载)指向断点续训/超节点定位调度的确定性强化;证据是打分常量 + TaskOrderFn + 缓存 API,未逐 PR 展开,未见对应 e2e。

## vNPU: a30d9493 -> d78592e5
- 比较 / 最新 Release:a30d9493..d78592e5 | tag v0.1.0 | commits=7 | truncated=false
- https://gitcode.com/openFuyao/vNPU/compare/a30d9493...d78592e5

### AI 总结重点(源码 diff 为据)
- **新增节点级分配锁,根治同节点并发 Pod 抢分 vNPU 冲突**。新建 `volcano-xpu-plugin/nodelock` 包:Layer 1 是进程内 `nodeLockManager`(per-node `sync.Mutex`,允许不同节点并发、同节点串行),配 `CleanupNodeLock`/`GetNodeMemoryLock`。这是 vXPU 调度器的内存级互斥,补在节点 annotation 锁之上。
  <details><summary>代码依据 volcano-xpu-plugin/nodelock/nodelock.go(新增,287 行,hunk 截断)</summary>

  ```diff
  +type nodeLockManager struct { mu sync.Mutex; locks map[string]*sync.Mutex }
  +func (m *nodeLockManager) getLock(nodeName string) *sync.Mutex { ... }
  +func CleanupNodeLock(nodeName string) { nodeLocks.deleteLock(nodeName) }
  +func GetNodeMemoryLock(nodeName string) *sync.Mutex { return nodeLocks.getLock(nodeName) }
  ```
  </details>

- **节点 annotation 锁:锁值由 `/proc/uptime` 改 `namespace/podName`,可溯源 + TTL 5 分钟**。`xpu-device-plugin/pkg/lock/nodelock.go` 删掉 `getUptime()`/读 `/proc/uptime` 的旧实现,改 `formatLockValue(namespace, podName)` 写锁,新增 `retryUpdateNode`(get-deepcopy-modify-update 重试 `maxLockRetry=5` 次);`lockExpiredInterval=300.0`(秒,float)换成 `lockExpiredTime = 5*time.Minute`,`lockRetryInterval` 变 `100*time.Millisecond`。锁里带 Pod 身份,排障时能直接看出哪个 Pod 占了锁。
  <details><summary>代码依据 xpu-device-plugin/pkg/lock/nodelock.go</summary>

  ```diff
  -	maxLockRetry        = 5
  -	lockRetryInterval   = 100
  -	lockExpiredInterval = 300.0
  -	uptimeFilePath = "/proc/uptime"
  +	maxLockRetry      = 5
  +	lockRetryInterval = 100 * time.Millisecond
  +	lockExpiredTime   = 5 * time.Minute
  -func setNodeLock(nodeName string, lockName string) error {
  +func retryUpdateNode(ctx context.Context, nodeName string, modify func(*corev1.Node)) error { ... }
  +func setNodeLock(nodeName string, lockName string, namespace string, podName string) error {
  -	newNode.ObjectMeta.Annotations[lockName] = uptime
  +	newNode.ObjectMeta.Annotations[lockName] = formatLockValue(namespace, podName)
  ```
  </details>

- **调度器分配路径接入锁:失败回滚、成功只释放内存锁**。`AllocateXPUForTask` 接收者改指针,分配前 `LockNodeWithPod`(`reducedLockRetries=3`,间隔 500ms),`Allocate` 失败时 `ReleaseNodeLockWithPod` 完整回滚,成功时只 `ReleaseNodeMemoryLockOnly`(保留 annotation 锁直到设备实际绑定),分两层锁的生命周期由此分开管理。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/task.go</summary>

  ```diff
  +	nodelock.UseClient(ssn.KubeClient())
  +	for attempt := 0; attempt < reducedLockRetries; attempt++ {
  +		lockErr = nodelock.LockNodeWithPod(nodeName, util.VXPULockName, task.Pod)
  +		if lockErr == nil { break }
  +		time.Sleep(lockRetryInterval)
  +	}
   	err := sJob.handler.Allocate(...)
  +	if err != nil { nodelock.ReleaseNodeLockWithPod(...) } else { nodelock.ReleaseNodeMemoryLockOnly(nodeName) }
  ```
  </details>

### 后续发展方向 [AI]
- vNPU 这轮全在解决"分数级 vNPU 在节点上的并发安全",两层锁(内存 mutex + 节点 annotation 带 Pod 身份)是把单调度进程内的竞态和跨进程/跨调度周期的占用分开治。证据覆盖 nodelock 包 + task.go + device-plugin lock,未见 Predicate 阶段如何用 `GetNodeMemoryLock` 的完整调用(hunk 截断);本区间另有大量 CI 脚本重构(抽 `_common_utils.sh`/`_volcano_common.sh`,CANN 8.5.1 + Ascend HDK 25.5.1 910b),属工程化非能力面,不展开。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY(仅保锚点)</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=21a6d2f4f0bba1332fc694d97a43bd088f2698b4 tag=v26.0.1 scanned=2026-06-17 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-17 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-17 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-17 -->
<!-- ANCHOR repo=vNPU sha=d78592e58199e20054a999052616dd48f1bce3b3 tag=v0.1.0 scanned=2026-06-17 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-17 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-17 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-17 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-17 -->
