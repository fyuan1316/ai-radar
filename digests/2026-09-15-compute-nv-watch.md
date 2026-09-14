# NVIDIA 算力栈 diff 雷达 2026-09-15

## 摘要
- **container-toolkit 新增官方"CUDA 显存限额"CDI hook**:`apply-cuda-memory-limits` 读 `NVIDIA_GPU_MEMORY_REQUEST/LIMIT`(单位 MiB)给容器内 GPU 设置 CUDA 显存软/硬上限——NVIDIA 官方栈第一次在 CDI 层直接做显存限额,是对标 HAMi 显存软切分的信号,但走 nvml `DEVICE_MEMORY_LIMIT` + cgroup v2 而非 hook 拦截。
- KAI-Scheduler 修 inter-pod affinity 索引:把本调度周期自己驱逐的 victim(Releasing+virtual)剔出亲和性索引,否则每次 reclaim/preempt 都会让 required (anti-)affinity 判定失败。
- 其余 7 仓无实质改动。

## 当日重要改变
- NVIDIA/nvidia-container-toolkit [新能力] 新增 CDI hook `apply-cuda-memory-limits` + 新 package `pkg/nvcdi/cuda-memory-limits.go`、`internal/info/cgroup`,官方栈首次在容器创建期设 GPU CUDA 显存上限。https://github.com/NVIDIA/nvidia-container-toolkit/commit/bd3398db7f0002529d00d97640b1e70ed016087f
- KAI-Scheduler [架构方向] 调度器亲和性索引语义修正,影响 reclaim/preempt 正确性(见下)。https://github.com/kai-scheduler/KAI-Scheduler/pull/2116

## NVIDIA/nvidia-container-toolkit: b4df7711 -> bd3398db
- 比较: b4df771174daa9485036a8ee2fa535dbbbffe2bf -> bd3398db | ahead=6 | files=14 | Release: v1.20.0
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/b4df771174daa9485036a8ee2fa535dbbbffe2bf...bd3398db7f0002529d00d97640b1e70ed016087f

### AI 总结重点(源码 diff 为据)
- **新增 CDI hook `apply-cuda-memory-limits`,给容器内每块 GPU 设 CUDA 显存软/硬上限。** hook 从 OCI spec 反查容器进程,读环境变量 `NVIDIA_GPU_MEMORY_REQUEST`(软)与 `NVIDIA_GPU_MEMORY_LIMIT`(硬),值为 MiB 整数,上限受 `nvml.DEVICE_MEMORY_LIMIT_MAX` 约束;命令挂在 `--driver-root` + 多个 `--gpu-id` 之下。这是 NVIDIA 官方栈第一次把"显存限额"做进容器工具链——此前显存超卖/切分只能靠 HAMi 这类 hook 拦截层。

  <details><summary>代码依据 cmd/nvidia-cdi-hook/apply-cuda-memory-limits/apply-cuda-memory-limits.go</summary>

  ```diff
  +const (
  +	GPUMemoryRequestEnvName = "NVIDIA_GPU_MEMORY_REQUEST"
  +	GPUMemoryLimitEnvName   = "NVIDIA_GPU_MEMORY_LIMIT"
  +	mebiByteMultiplier = 1024 * 1024
  +	maxMebiBytes       = nvml.DEVICE_MEMORY_LIMIT_MAX / mebiByteMultiplier
  +)
  +		Usage: "Set the soft and hard limits of CUDA memory usage on GPU device(s) in the container. " +
  +			"It introspects the OCI container spec and fetches the memory limits from the environment variables:\n" +
  +			"1) NVIDIA_GPU_MEMORY_REQUEST\n2) NVIDIA_GPU_MEMORY_LIMIT\nThe values must be valid integers and are in MebiBytes.",
  ```
  </details>

- **hook 类型是 `OCIHookTypeCreateRuntime`(不是 CreateContainer),且被接进 full-GPU discoverer,所以普通整卡直通场景默认就会走这条 discoverer。** 新增 HookName 常量并在 `getOCIHookType` 里单列 create-runtime 分支;`isDisabled` 要求必须带 args 才生效;`transformArgs` 把首个 arg 转成 `--driver-root`、其余转成 `--gpu-id`。

  <details><summary>代码依据 internal/discover/hooks.go + pkg/nvcdi/full-gpu-nvml.go</summary>

  ```diff
  +	// ApplyCudaMemoryLimitsHook is used to assign soft and hard limits of CUDA memory usage to a container
  +	ApplyCudaMemoryLimitsHook = HookName("apply-cuda-memory-limits")
  @@ func (c cdiHookCreator) getOCIHookType
  +	case ApplyCudaMemoryLimitsHook:
  +		return OCIHookTypeCreateRuntime
  @@ transformArgs
  +	case ApplyCudaMemoryLimitsHook:
  +		transformedArgs = append(transformedArgs, "--driver-root", args[0])
  +		for _, arg := range args[1:] {
  +			transformedArgs = append(transformedArgs, "--gpu-id", arg)
  @@ pkg/nvcdi/full-gpu-nvml.go
  +	cudaMemoryLimitsHook, err := (*nvcdilib)(l.nvmllib).newCudaMemoryLimits(d)
  +	discoverers = append(discoverers, deviceNodes, deviceFolderPermissionHooks, cudaMemoryLimitsHook)
  ```
  </details>

- **配套新增 cgroup v2 定位工具 `internal/info/cgroup`。** `IsCgroupV2()` 用 statfs 魔数 `0x63677270` 判 unified 挂载;`GetAbsolutePath(pid)` 解析 `/proc/<pid>/cgroup` 里 `0::` 前缀行拼出绝对 cgroup 路径——说明显存限额落地依赖 cgroup v2,老 v1 环境大概率不支持。

  <details><summary>代码依据 internal/info/cgroup/cgroup_path.go</summary>

  ```diff
  +	v2FsMagicNumber = 0x63677270
  +	rootDirectory   = "/sys/fs/cgroup"
  +	unifiedPrefix   = "0::"
  +func IsCgroupV2() bool { ... return s.Type == v2FsMagicNumber }
  +func parseCgroupProcFile(b []byte) (string, error) { // 取 "0::" 行
  ```
  </details>

- **修 create-symlinks hook 的间歇性 EBADF。** 原来拿 `linkDirInRoot.Fd()` 后未持有 `*os.File`,GC finalizer 可能在 Symlinkat 和 Renameat 之间把 fd 关掉;加 `defer ...Close()` 保活。属稳定性修复,不改行为。

  <details><summary>代码依据 cmd/nvidia-cdi-hook/create-symlinks/container-root_linux.go</summary>

  ```diff
  +	// Keeps the *os.File alive while its raw fd is in use; otherwise the GC's
  +	// finalizer can close it between Symlinkat and Renameat (EBADF).
  +	defer linkDirInRoot.Close()
  	linkDirFd := int(linkDirInRoot.Fd())
  ```
  </details>

- **修启用 CDI 时误清 Docker 其它 feature flag。** `daemon.json` 的 `features` 字段实际是 `map[string]any`,原代码按 `map[string]bool` 断言,一旦有非 bool 值(或类型不符)断言失败就重建空 map,把用户已有 feature 抹掉;改成 `map[string]any` 保留原有键。

  <details><summary>代码依据 pkg/config/engine/docker/docker.go</summary>

  ```diff
  -	features, ok := config["features"].(map[string]bool)
  +	features, ok := config["features"].(map[string]any)
  	if !ok {
  -		features = make(map[string]bool)
  +		features = make(map[string]any)
  	}
  	features["cdi"] = true
  ```
  </details>

### 后续发展方向 [AI]
- 这条 CUDA 显存限额 hook 是 NVIDIA 官方栈往"单卡多租显存隔离"迈的一步,但语义与 HAMi 不同:它靠 nvml `DEVICE_MEMORY_LIMIT` + cgroup v2 在容器创建期设上限,不是运行时拦截 CUDA malloc,所以更像"驱动级配额"而非"软切分虚拟化"。证据只覆盖 hook 注入与环境变量读取,**未见**上层 device-plugin/DRA 如何把 `NVIDIA_GPU_MEMORY_REQUEST/LIMIT` 注入 Pod、也未见超限时的行为(OOM/拒绝分配),需盯 k8s-device-plugin 与 dra-driver 后续是否加对应字段。

## kai-scheduler/KAI-Scheduler: 30c25346 -> d942b921
- 比较: 30c25346ee013e67d2e14df0429bec52f1885131 -> d942b921 | ahead=3 | files=14 | Release: v0.17.1
- https://github.com/kai-scheduler/KAI-Scheduler/compare/30c25346ee013e67d2e14df0429bec52f1885131...d942b921b8025257207bc0a687e23cc1a6fcc1c5

### AI 总结重点(源码 diff 为据)
- **修:被本调度周期自己驱逐的 victim 要剔出节点的 inter-pod affinity 索引。** 新增 `excludedFromPodAffinity(task)`:仅当 `task.Status==Releasing && task.IsVirtualStatus`(即本 session 通过 Statement.Evict 标记的虚拟释放)才为 true。`addTask` 跳过给这类 task 建索引,`RemoveTask` 也对称跳过(否则 k8s NodeInfo.RemovePod 会因从未加入而报错)。原因:这些 victim 资源已按"未来空闲"处理、放置到其上是 Pipelined 从不真正 bind,若仍留在索引里,会让针对 victim 的 required (anti-)affinity 在每次 reclaim/preempt 场景都判失败。独立终止(Releasing 但非 virtual)的 pod 仍保留索引,对齐 kube-scheduler。

  <details><summary>代码依据 pkg/scheduler/api/node_info/node_info.go</summary>

  ```diff
  -	ni.PodAffinityInfo.AddPod(task.Pod)
  +	if !excludedFromPodAffinity(task) {
  +		ni.PodAffinityInfo.AddPod(task.Pod)
  +	}
  +func excludedFromPodAffinity(task *pod_info.PodInfo) bool {
  +	return task.Status == pod_status.Releasing && task.IsVirtualStatus
  +}
  @@ RemoveTask
  +	if excludedFromPodAffinity(task) {
  +		return nil
  +	}
  +	return ni.PodAffinityInfo.RemovePod(task.Pod)
  ```
  </details>

- **配套:`Statement.Evict` 把 `IsVirtualStatus=true` 的赋值提到 `node.UpdateTask` 之前,并在 UpdateTask 失败时回滚。** 保证节点重建索引时能看到"这是本 session 驱逐"从而不建索引;顺序错了(原来在 UpdateTask 之后)索引就会先建后漏删。

  <details><summary>代码依据 pkg/scheduler/framework/statement.go</summary>

  ```diff
  +	// Mark the eviction as this session's before re-indexing ...
  +	reclaimeeTask.IsVirtualStatus = true
  	if err := node.UpdateTask(reclaimeeTask); err != nil {
  +		reclaimeeTask.IsVirtualStatus = previousIsVirtualStatus
  		...
  	}
  -	reclaimeeTask.IsVirtualStatus = true
  ```
  </details>

- **chart:允许 post-delete cleanup job 在 OpenShift 上跑。** SCC 的 users/subjects 加入 `postCleanup.serviceAccountName`,否则 OpenShift 上卸载时清理 job 因缺 SCC 权限起不来。运维/OpenShift 适配,不改调度逻辑。

  <details><summary>代码依据 deployments/kai-scheduler/templates/rbac/scc.yaml</summary>

  ```diff
  +- system:serviceaccount:{{ .Release.Namespace }}:{{ .Values.postCleanup.serviceAccountName }}
  @@ subjects
  +  - kind: ServiceAccount
  +    name: {{ .Values.postCleanup.serviceAccountName }}
  +    namespace: {{ .Release.Namespace }}
  ```
  </details>

- 另有一批 CI 加固:把 `${{ inputs.* }}`/`${{ github.head_ref }}` 从 shell 内联改为经 `env:` 传入(防脚本注入),涉及 setup-e2e-cluster、release-prepare、benchmark 三个 workflow,无产品代码影响。

### 后续发展方向 [AI]
- 这批全是 correctness/运维修复,非能力扩展:affinity 索引 bug 说明 KAI 的 reclaim/preempt 与 inter-pod (anti-)affinity 组合此前存在系统性误判,修复后抢占场景下带亲和性约束的作业可调度性会改善。证据只覆盖 node_info 索引与 Statement.Evict 时序,**未见**对 gang/topology 调度路径的影响;OpenShift SCC 补丁是 v0.17.x 持续做企业发行版适配的延续。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY</summary>

- NVIDIA/gpu-operator — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=3fc63e234ea12cd1de83d0ef698d438805f86aa7 branch=main release=v26.7.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=bd3398db7f0002529d00d97640b1e70ed016087f branch=main release=v1.20.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=dcbb9031dbb95da2e449fbb632e4b69e5c3d1ba1 branch=main release=— scanned=2026-09-15 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d415f49223cb9344081cf167461ea0eada141695 branch=main release=v0.20.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5baf08f63bd266129dbdd27b28e77bb0ad91fd28 branch=main release=v0.5.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-15 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-15 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=377f931e2d64f1a7e716d57e4084257f4cc09757 branch=main release=v0.15.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=d942b921b8025257207bc0a687e23cc1a6fcc1c5 branch=main release=v0.17.1 scanned=2026-09-15 -->
</content>
</invoke>
