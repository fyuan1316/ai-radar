# NVIDIA 算力栈 diff 雷达 2026-10-16

## 摘要
- **L1 gpu-operator** 修了一个真实的检测盲区:`gpuPodSpecFilter` 现在把"native sidecar"(init container 且 `restartPolicy=Always`)的 GPU 请求也算作 GPU Pod,否则驱动升级时这类常驻 sidecar 占着 GPU 却被 operator 漏判、可能被误 drain。普通 init container 仍不计入。
- **L2 DRA**:dra-driver-nvidia-gpu 给 controller 补了可选 PodDisruptionBudget,并硬性要求 `replicas>1` 时必须开 leaderElection(否则 helm 校验直接 fail)——ComputeDomain 控制面向多副本 HA 收口的信号。
- **L4 KAI-Scheduler** 一批 reclaim/抢占热路径的 perf:停止在 reclaim 场景搜索里反复 clone victim job(复用 representative)、把 PodInfo.Clone 的请求向量从深拷贝改为共享、队列层级路径用栈上数组免堆分配;elastic 插件改按 subgroup 树递归算 minAvailable 状态。纯性能/正确性,无调度语义改变。无任何 CRD/API 字段增删,无弃用,无跨 major/minor 版本。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [新能力] 新增 controller PodDisruptionBudget 模板 + values 里 `controller.pdb` 配置面,并在 `validation.yaml` 加硬校验:ComputeDomain 启用且 `replicas>1` 却未开 leaderElection 时直接 fail,防止多副本并发 reconcile。https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/6d5bdb8f19c2e6f50fe8f282fa77816503cb0571
- NVIDIA/gpu-operator [行为修正] `gpuPodSpecFilter` 纳入 native sidecar(`restartPolicy=Always` 的 init container)的 GPU 资源判定,修复驱动升级期这类常驻容器占用 GPU 却被漏判的问题。https://github.com/NVIDIA/gpu-operator/commit/dbb11e85129b601afe9fb502ac25b062ad094abd

## NVIDIA/gpu-operator: fbe79308 -> dbb11e85
- 比较: fbe793082611bfdba1621b614edefdd3461bf14d -> dbb11e85 | ahead=2 | files=2 | Release: v26.7.2

### AI 总结重点(源码 diff 为据)
- **`gpuPodSpecFilter` 新增 native sidecar 分支,把常驻 init container 的 GPU 请求纳入"是否 GPU Pod"判定**。原逻辑只遍历普通 containers;现在额外遍历 `pod.Spec.InitContainers`,仅当 `RestartPolicy != nil && *RestartPolicy == ContainerRestartPolicyAlways`(即 native sidecar,生命周期与 Pod 等长)且其 limits/requests 命中 `nvidia.com/gpu`/`nvidia.com/mig-` 时返回 true。普通 init container(无 Always restartPolicy)仍不计入。注释点明动机:native sidecar "run for the pod's lifetime, so their GPU resources must be considered"。测试补了 6 个 case 覆盖 native-sidecar 的 GPU limit/MIG request、普通 init container 不算、CPU-only 不算、Succeeded 相不算。
  <details><summary>代码依据 cmd/gpu-operator/main.go</summary>

  ```diff
  +		// Native sidecars (init containers with restartPolicy Always) run for the
  +		// pod's lifetime, so their GPU resources must be considered. Regular init
  +		// containers are not checked here.
  +		for _, ctr := range pod.Spec.InitContainers {
  +			if ctr.RestartPolicy != nil && *ctr.RestartPolicy == corev1.ContainerRestartPolicyAlways &&
  +				(gpuInResourceList(ctr.Resources.Limits) || gpuInResourceList(ctr.Resources.Requests)) {
  +				return true
  +			}
  +		}
  		return controllers.PodHasNVIDIAGPUClaim(ctx, c, &pod, false)
  ```
  </details>

### 后续发展方向 [AI]
- 这是对 K8s native sidecar(1.29+ 稳定的 `restartPolicy=Always` init container)在 GPU 场景下的补齐——operator 的驱动升级/节点排空逻辑依赖此过滤器正确识别"还在用 GPU 的 Pod"。证据只覆盖过滤器本身,未见升级流程里对 sidecar 的额外特殊处理;sidecar 化的 GPU 监控/代理(如把 dcgm/health agent 作为 workload sidecar)普及后,这类判定会越来越关键。

## NVIDIA/nvidia-container-toolkit: cec3a629 -> 3e112b4a
- 比较: cec3a629d1ae486b0b6c984a67c61acd0350027a -> 3e112b4a | ahead=4 | files=4 | Release: v1.20.1

### AI 总结重点(源码 diff 为据)
- **MPS IPC 挂载从 FileLocator 改为 DirectoryLocator**。`NewIPCDiscoverer` 里发现 MPS pipe 目录(`/tmp/nvidia-mps`)原先用 `lookup.NewFileLocator`,而默认 file locator 的 filter 会拒绝目录,导致 MPS pipe 目录发现不到、容器内 MPS 共享失效;改用 `lookup.NewDirectoryLocator`。测试补了"MPS pipe 目录能被发现""是普通文件时被忽略""socket 是目录时被忽略"等 case,明确区分 socket(文件)与 MPS pipe(目录)两类 IPC 路径。
  <details><summary>代码依据 internal/discover/ipc.go</summary>

  ```diff
  +	// The MPS pipe directory is a directory, so a directory locator is used.
  +	// The default file locator filter rejects directories.
  	mps := newMounts(
  		logger,
  -		lookup.NewFileLocator(
  +		lookup.NewDirectoryLocator(
  ```
  </details>
- **MIG capability 名校验收紧,拒绝"仅为前缀"的畸形名**。`MigCap.isValid` 用 `fmt.Sscanf` 解析 `gpu%d/gi%d/ci%d/access` 时,Sscanf 遇首个不匹配即停,原先只看匹配字段数 `n==3`/`n==2` 就判有效,会把 `gpu0/gi0/accessEXTRA` 这类尾部带脏字符的名字误判合法;现在追加 `m == NewComputeInstanceCap(gpu,gi,ci)` / `m == NewGPUInstanceCap(gpu,gi)` 的回构校验,要求重建出的 cap 必须等于整个 token。另外把 GI 分支的格式串从 `gpu%d/gi%d/access %d` 修正为 `gpu%d/gi%d/access`(原格式多了个 ` %d` 是 bug)。
  <details><summary>代码依据 internal/nvcaps/nvcaps.go</summary>

  ```diff
  -		n, _ := fmt.Sscanf(cap, "gpu%d/gi%d/ci%d/access", &gpu, &gi, &ci)
  -		if n == 3 {
  +		// Sscanf stops at the first mismatch, so the
  +		// reconstructed name has to be the whole token.
  +		n, _ := fmt.Sscanf(cap, "gpu%d/gi%d/ci%d/access", &gpu, &gi, &ci)
  +		if n == 3 && m == NewComputeInstanceCap(gpu, gi, ci) {
  			return true
  		}
  -		n, _ = fmt.Sscanf(cap, "gpu%d/gi%d/access %d", &gpu, &gi)
  -		if n == 2 {
  +		n, _ = fmt.Sscanf(cap, "gpu%d/gi%d/access", &gpu, &gi)
  +		if n == 2 && m == NewGPUInstanceCap(gpu, gi) {
  ```
  </details>

### 后续发展方向 [AI]
- 两处都是 IPC/MIG 可见性正确性修复(MPS 目录挂载、MIG cap 解析健壮性),无新能力。证据边界:只看了 discover/nvcaps 两层,未触及 CDI 生成或 runtime hook 主流程。MPS 这条说明 MPS 时分共享路径仍在被动打磨,与 device-plugin 侧 MPS 配置面是同一能力的两端。

## NVIDIA/k8s-device-plugin: a0d31ccb -> 0d020077
- 比较: a0d31ccbc26e83a4a4ebe027912a79bc3b909728 -> 0d020077 | ahead=6 | files=5 | Release: v0.20.1

### AI 总结重点(源码 diff 为据)
- **修正 `disable=all` 下显式 enable 某 XID 的健康检查逻辑**。`disabledXIDs.IsAllDisabled` 原先只要命中 `allXIDs` 键为 true 就返回"全禁";现在改为:全禁前提下再遍历,若存在任何被显式 enable(值为 false)的非-all XID,则返回 false(即健康检查整体没关)。配套 `IsDisabled` 对"没被点名"的 XID 从调 `IsAllDisabled` 改为直接返回 `h[allXIDs]`——否则一旦有人按名 enable 某个 XID,别的未点名 XID 会被错误地变成"被检查"。效果:`disable=all` + `enable=79` 时,79 仍被健康检查,其余仍静默。
  <details><summary>代码依据 internal/rm/health.go</summary>

  ```diff
  -	if allDisabled, ok := h[allXIDs]; ok {
  -		return allDisabled
  +	if allDisabled, ok := h[allXIDs]; !ok || !allDisabled {
  +		return false
  +	}
  +	// An XID the caller enabled explicitly is still checked for...
  +	for xid, disabled := range h {
  +		if xid != allXIDs && !disabled {
  +			return false
  +		}
  +	}
  +	return true
  ...
  -	return h.IsAllDisabled()
  +	// An XID nobody named is disabled exactly when all XIDs are.
  +	return h[allXIDs]
  ```
  </details>
- **config-manager 错误信息修正**:`updateConfigName` 在默认配置文件缺失时,报错里把变量从 `config`(未设时为空串)改为 `f.DefaultConfig`,日志能看到真正缺失的默认配置名。另外 Dockerfile 的 distroless/go 基础镜像从 `v4.1.4` bump 到 `v4.1.6`(application 阶段)。
  <details><summary>代码依据 cmd/config-manager/main.go</summary>

  ```diff
  -			return "", fmt.Errorf("specified config %v does not exist", config)
  +			return "", fmt.Errorf("specified config %v does not exist", f.DefaultConfig)
  ```
  </details>

### 后续发展方向 [AI]
- 均为健康检查/配置面的正确性修复,无 time-slicing/MPS/DRA 配置结构改动。XID 这条说明 per-XID 健康检查的 enable/disable 组合语义此前有边界 bug,运维若用 `disable=all` 白名单式开检需升到 v0.20.1。证据只覆盖 rm/health 与 config-manager,未见 device-plugin 分配主路径变化。

## kubernetes-sigs/dra-driver-nvidia-gpu: 35fa51e3 -> 6d5bdb8f
- 比较: 35fa51e30ba914fbe1b9b237c5eebba5bb2ac7ec -> 6d5bdb8f | ahead=2 | files=3 | Release: v0.5.1

### AI 总结重点(源码 diff 为据)
- **新增 controller 可选 PodDisruptionBudget + 多副本必须 leader election 的硬校验**。新模板 `controller-poddisruptionbudget.yaml` 仅在 `computeDomains.enabled && controller.pdb.enabled && replicas>1` 时渲染;`maxUnavailable` 优先于 `minAvailable`,两者都没设则 `minAvailable: 1`。`values.yaml` 加 `controller.pdb`(默认 `enabled:false`)并注释 `replicas>1 requires leaderElection.enabled=true`。关键是 `validation.yaml` 加了阻断式校验:ComputeDomain 启用、`replicas>1` 却未开 leaderElection 时 helm 直接 `fail`,文案点明"Without leader election, every replica reconciles ComputeDomains concurrently"。
  <details><summary>代码依据 deployments/helm/.../templates/validation.yaml</summary>

  ```diff
  +{{- if and .Values.resources.computeDomains.enabled (gt (int .Values.controller.replicas) 1) (not .Values.controller.leaderElection.enabled) }}
  +{{- $error = printf "%s\ncontroller.replicas is set to %d but controller.leaderElection.enabled is false." $error (int .Values.controller.replicas) }}
  +{{- $error = printf "%s\nWithout leader election, every replica reconciles ComputeDomains concurrently." $error }}
  +{{- fail $error }}
  +{{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- DRA 驱动的 ComputeDomain 控制面在向生产级 HA 收口:提供 PDB + 用校验把"多副本无 leader election 并发 reconcile"这个误配死路堵住。证据只覆盖 helm chart(部署面),未触及 controller 代码里 leader election 的实现本身;说明 ComputeDomain(GPU 跨节点互联域)已被当作需要高可用的核心控制器对待,是 DRA 从实验走向生产的信号。无 ResourceClaim/DeviceClass 等 API 字段改动。

## kai-scheduler/KAI-Scheduler: 85eb6560 -> e496b753
- 比较: 85eb6560a96d4cee09a5bd72b479f61bdc49947c -> e496b753 | ahead=5 | files=18 | Release: v0.18.6

### AI 总结重点(源码 diff 为据)
- **reclaim 场景搜索停止反复 clone victim job,改用 representative 复用**。`BaseScenario` 新增 `recordedVictimsRepresentatives` 字段;`appendTasksAsVictimJob` 签名加 `representative` 参数,传入且 pod 数匹配时直接复用,否则才 `originalJob.CloneWithTasks`。新增 `AddPotentialVictimsTasksWithRepresentative` 与 `ByNodeScenario.NewSubScenario()`(用已记录的 representatives 起一个空子场景)。目的是抢占/reclaim 搜索在枚举子场景时避免对同一组 victim 任务反复深拷贝 PodGroup(#2400)。
  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/scenario/base_scenario.go</summary>

  ```diff
  -	job := originalJob.CloneWithTasks(tasks)
  +	job := representative
  +	if job == nil || len(job.GetAllPodsMap()) != len(tasks) {
  +		job = originalJob.CloneWithTasks(tasks)
  +	}
  ```
  </details>
- **`PodInfo.Clone` 把请求向量从深拷贝改为共享**。`ResReqVector` 与 `GpuRequirement` 不再 `.Clone()`,直接赋值共享(注释:二者"only set while building the pod info",克隆后不会被改写);仅 `AcceptedResourceVector`/`AcceptedGpuRequirement` 仍深拷贝。测试断言 clone 后 `&cloned.ResReqVector[0] == &pi.ResReqVector[0]`(确认共享),而改 accepted 向量不影响原对象。减少每次 clone 的分配。
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
  -		GpuRequirement:         *pi.GpuRequirement.Clone(),
  +		GpuRequirement:         pi.GpuRequirement,
  -		ResReqVector:           resReqVectorClone,
  +		ResReqVector:           pi.ResReqVector,
  ```
  </details>
- **reclaimable 队列层级路径用栈上数组、消除头插与每次堆分配**。`getHierarchyPath`(会头插构建 root→queue 路径,`append([]{queue}, path...)` 每步重分配)改名为包级 `appendHierarchyPath`,追加到调用方传入的 buffer(`queuePathStackSize=8` 的栈上数组,注释"队列树通常两三层深")后 `slices.Reverse`,避免 reclaim 打分热路径上的反复分配(#2420)。
  <details><summary>代码依据 pkg/scheduler/plugins/proportion/reclaimable/reclaimable.go</summary>

  ```diff
  +	var reclaimersBuf, reclaimeesBuf [queuePathStackSize]*rs.QueueAttributes
  +	reclaimers := appendHierarchyPath(reclaimersBuf[:0], queues, reclaimerQueueID)
  ...
  -		hierarchyPath = append([]*rs.QueueAttributes{queue}, hierarchyPath...)
  +		path = append(path, queue)
  ...
  +	slices.Reverse(path)
  ```
  </details>
- **elastic 插件改按 subgroup 树递归判定 minAvailable 状态**。`minAvailableState` 原先平铺遍历 `GetAllPodSets()`;现在走 `RootSubGroupSet` → `subGroupSetState`(递归下探 `GetDirectSubgroupsSets()`)→ `podSetState`,任一 podSet 低于 minAvailable 即"below",正确反映嵌套 subgroup 的 gang 语义。另 `syncPodGroup` 抽出 `syncAnnotation`:in-flight 侧缺该 annotation key 时从 snapshot `delete` 掉,避免写入 `""` 值后续被 JSON patch 当作要从不存在该键的服务端对象上移除(#2429)。
  <details><summary>代码依据 pkg/scheduler/cache/status_updater/pod_group_status_sync.go</summary>

  ```diff
  +func syncAnnotation(snapshotPodGroup, inFlightPodGroup *enginev2alpha2.PodGroup, key string) {
  +	value, found := inFlightPodGroup.Annotations[key]
  +	if !found {
  +		delete(snapshotPodGroup.Annotations, key)
  +		return
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 本期 KAI-Scheduler 清一色是抢占/reclaim 热路径的内存与分配优化(victim job 复用、PodInfo 浅拷贝、层级路径栈分配)+ 两个正确性修复(嵌套 subgroup 的 elastic 状态、PodGroup annotation 同步)。延续上期 cache 瘦身的方向——大规模集群下调度器 CPU/内存足迹收敛。证据只覆盖 solver/elastic/status_updater/reclaimable,未触及打分策略或 GPU sharing 语义;`pod_info.go` 虽命中 api 路径探测,但属内部调度 API 非 CRD,无对外字段变更。

## 本期无实质改动(折叠)
<details><summary>下列 repo 本期仅 bump/CI/merge 或无新提交,未单列正文</summary>

- NVIDIA/gpu-driver-container:ahead=2 仅 bump/CI/merge,无实质代码(上期的 nvidia-64k arm64 flavor 已落地)。
- NVIDIA/dcgm-exporter:无新提交。
- NVIDIA/DCGM:无新提交(master 分支)。
- NVIDIA/mig-parted:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=dbb11e85129b601afe9fb502ac25b062ad094abd branch=main release=v26.7.2 scanned=2026-10-16 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3e112b4af299bf72a1b23193b4f5c3321475dd6d branch=main release=v1.20.1 scanned=2026-10-16 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-16 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=0d02007724768b4f4ac80cd8ad058d97a04000ee branch=main release=v0.20.1 scanned=2026-10-16 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=6d5bdb8f19c2e6f50fe8f282fa77816503cb0571 branch=main release=v0.5.1 scanned=2026-10-16 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-16 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-16 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-16 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=e496b7539d40d3c8428ce56d967933de4a9a0a05 branch=main release=v0.18.6 scanned=2026-10-16 -->
