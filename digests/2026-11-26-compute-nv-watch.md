# NVIDIA 算力栈 diff 雷达 2026-11-26

## 摘要
- **KAI 调度器补上了 device-plugin → DRA 迁移期的一个错配。** 节点 GPU 只经 DRA 暴露(`HasDRAGPUs`)时,如果 Pod 请求 `nvidia.com/gpu` / `amd.com/gpu` 这类扩展资源，节点 `Allocatable` 里没有它，也没有任何 DeviceClass 通过 `extendedResourceName` 映射它，新谓词 `gpuResourceWithoutDeviceSource` 会直接把该节点判为 FitError。修复前这类 Pod 会被绑到一个实际给不了卡的节点上。同批 KAI 还有三项改动:允许**空 action 列表**(只维持缓存、对外提供 `/get-snapshot`,不写回集群);新增插件扩展点 `AddConsolidationVictimFilterFn`;chart 开放 `admission.queueLabelSelector`。
- **k8s-device-plugin 的 MPS 客户端上限按真实 Volta 门槛计算。** `isAtLeastVolta()` 的判定从 `major>7 || (major==7 && minor>=5)` 改为 `major>=7`,算力 7.0/7.2 的设备(V100、Xavier 等)可配的 MPS replicas 上限从 16 提到 48。
- L1/DRA 层只有例行维护。gpu-driver-container 把三条活跃驱动分支的小版本前移(580.196.11 / 595.112.13 / 620.70.10),公开发布也从只发 620 改为三条分支都发。DRA driver 的 `flock.Acquire` 每轮加锁前先检查 ctx 是否已取消。gpu-operator 和 container-toolkit 只升级了 distroless 基础镜像。dcgm-exporter、DCGM、mig-parted 没有新提交。

## 当日重要改变
- `kai-scheduler/KAI-Scheduler` **[API/CRD变更·helper 路径命中]** helper 命中的是 `pkg/scheduler/api/node_info`、`resource_info`。这两个是调度器内部 Go 包，不是 CRD,但行为有变化:`PredicateByNodeResourcesType` 新增 DRA-only 节点的 GPU 扩展资源来源校验;`isGpuResource` 导出为 `IsGpuResourceName`。这是本 task 关注的“device-plugin → DRA 迁移”信号。 https://github.com/kai-scheduler/KAI-Scheduler/commit/1695095737b627f8edd5cd9823839d0f49eb24c7
- `kai-scheduler/KAI-Scheduler` **[配置语义变更]** 调度器配置里显式写 `actions: ""` 时，过去会回退到默认 actions,现在表示不执行任何 action:不更新 PodGroup 状态，不发 Event,不清理过期 BindRequest。不写 `actions` 字段时仍使用默认值，因为 `loadSchedulerConf` 现在以默认配置为底再叠加。 https://github.com/kai-scheduler/KAI-Scheduler/commit/78af182ca4abe8270e6d67d906912f5047546650
- `[版本跨档]` 本期未命中:9 仓 Release 均与上期相同。KAI 的 releases 列表最大 semver 仍是 v0.19.0(2026-11-11),helper 报的 v0.18.9 是 backport。
- 本期无 `[弃用/移除]`、`[架构方向]`、`[新能力]`(新增独立 package)命中，也没有改动 `clusterpolicy_types.go`。

## kai-scheduler/KAI-Scheduler: 31139362 -> 8e0d52c2
- 比较: 3113936297208d9ba2cab734964f1ff7b74595ab -> 8e0d52c2 | ahead=8 | files=45 | Release: v0.18.9(0.18 分支 backport;releases 最大 semver 仍为 v0.19.0,不算跨档)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/3113936297208d9ba2cab734964f1ff7b74595ab...8e0d52c26a117f3f4212a80a15cc82a10b1c1ea1
- 提交:
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/1695095737b627f8edd5cd9823839d0f49eb24c7 fix(scheduler): do not bind GPU requests to DRA-only nodes without a DeviceClass mapping (#2648)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/78af182ca4abe8270e6d67d906912f5047546650 feat(scheduler): allow an empty action list (#2761)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/8e0d52c26a117f3f4212a80a15cc82a10b1c1ea1 feat(scheduler): add a consolidation victim filter for plugins (#2665)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/6c80dab4aa077cdeead5bc1052056b0214436d24 feat(chart): Support configuring `queueLabelSelector` for admission (#2121)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/9f78c77415968d7ecb197c56a0b050f303fe9430 fix(podgrouper): read the KubeRay suspend field for Ray worker groups (#2670)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/aa18a47a178e53584a628ec0d09aaa38e00ddfb7 fix(podgrouper): fetch the top owner through the uncached client (#2474)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/ff10d121f42f0b53cb484cba0a06fbaab2bda2a7 fix(numa-placement-exporter): log JSON when global.jsonLog is set (#2657)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/2f5cd74651900dfa5d72e473c8497a682a68a3ab test(scheduler): expect NUMA rejection for cross-zone Burstable GPU pods (#2755)

### AI 总结重点(源码 diff 为据)
- **DRA-only 节点上，没有 DeviceClass 映射的 GPU 扩展资源请求会在谓词阶段被拒。** `PredicateByNodeResourcesType` 在 `ni.HasDRAGPUs` 时调用新方法 `gpuResourceWithoutDeviceSource(pod)`。该方法用 `resourcehelper.PodRequests` 汇总 Pod 请求，包含 init 容器(测试覆盖了“仅 init 容器请求 GPU”的情况)。对每个 `IsGpuResourceName` 为真且数量非零的资源，只要 `DeviceClassByResource.GetDeviceClass(name)` 为空、节点 `Allocatable` 里也没有，就记为缺失，返回排序后的第一个，FitError 文案会写明 “its GPUs are only available through DRA, and no DeviceClass maps X to DRA”。反过来说，只要集群里存在 `spec.extendedResourceName: nvidia.com/gpu` 的 DeviceClass(即 K8s DRA extended resource 映射),旧写法 `resources.limits: nvidia.com/gpu` 仍可调度到 DRA-only 节点。新增的集成测试 `TestGpuRequestOnDRAOnlyNode` 断言：不带 claim 的 `nvidia.com/gpu` Pod 不会被调度到 DRA-only 节点。
  <details><summary>代码依据 pkg/scheduler/api/node_info/node_info.go</summary>

  ```diff
  +	if ni.HasDRAGPUs {
  +		if name, found := ni.gpuResourceWithoutDeviceSource(task.Pod); found {
  +			return common_info.NewFitError(task.Name, task.Namespace, ni.Name,
  +				fmt.Sprintf("node reports no %s, its GPUs are only available through DRA, and no DeviceClass maps %s to DRA",
  +					name, name))
  +		}
  +	}
  ...
  +	for name, quantity := range resourcehelper.PodRequests(pod, resourcehelper.PodResourcesOptions{}) {
  +		if !resource_info.IsGpuResourceName(name) || quantity.IsZero() {
  +			continue
  +		}
  +		if ni.DeviceClassByResource.GetDeviceClass(name) != nil {
  +			continue
  +		}
  +		if allocatable, ok := ni.Node.Status.Allocatable[name]; ok && !allocatable.IsZero() {
  +			continue
  +		}
  +		missing = append(missing, name)
  +	}
  ```
  </details>
  <details><summary>代码依据 pkg/scheduler/api/resource_info/resource_vector.go</summary>

  ```diff
  -func isGpuResource(resourceName v1.ResourceName) bool {
  +// IsGpuResourceName reports whether the resource is one of the GPU resources a pod can request.
  +func IsGpuResourceName(resourceName v1.ResourceName) bool {
   	switch string(resourceName) {
   	case constants.GpuResource, GPUResourceName, amdGpuResourceName:
  ```
  </details>
- **空 action 列表成为合法配置，含义是“只读调度器”。** 新增 `SchedulerConfiguration.ActionNames()` / `NoActions()`。`NoActions` 时有四处跳过写操作:
  - `SchedulerCache` 不启动 Event 广播(`StartRecordingToSink`);
  - `StatusUpdater` 换成新增的 `status_updater.NewNoop()`(所有方法都为空);
  - `Snapshot()` 跳过 `cleanStaleBindRequest`;
  - `closeSession` 不再对每个 PodGroup 调用 `RecordJobStatusEvent`。

  配置加载方面,`ResolveConfigurationFromFile` 删掉了“`Actions` 为空就回填默认值”的分支，改由 `loadSchedulerConf` 在非默认配置时先复制默认配置再 Unmarshal。所以字段缺省时仍走默认 actions,只有显式写成空串才表示不执行任何 action。`GetActionsFromConfig` 跳过空名，不再因为 `""` 报 “failed to find Action”。文档和 values 说明了用途：用一个 shard 专门对外提供 `/get-snapshot`。
  <details><summary>代码依据 pkg/scheduler/conf/scheduler_conf.go / cache/cache.go / framework/session.go / conf_util/scheduler_conf_util.go</summary>

  ```diff
  +func (c *SchedulerConfiguration) NoActions() bool {
  +	return c != nil && len(c.ActionNames()) == 0
  +}
  ```
  ```diff
  -	broadcaster.StartRecordingToSink(&corev1.EventSinkImpl{Interface: sc.kubeClient.CoreV1().Events("")})
  +	if !schedulerCacheParams.NoActions {
  +		broadcaster.StartRecordingToSink(&corev1.EventSinkImpl{Interface: sc.kubeClient.CoreV1().Events("")})
  +	}
  ...
  +	if schedulerCacheParams.NoActions {
  +		sc.StatusUpdater = status_updater.NewNoop()
  +	}
  ...
  +	// Deleting stale BindRequests is a cluster write, which a NoActions scheduler must not do.
  +	if !sc.noActions {
  ```
  ```diff
  -	if len(schedulerConfigFromCM.Actions) == 0 {
  -		schedulerConfigFromCM.Actions = defaultConfig.Actions
  -	}
  ...
  +	if confStr != defaultSchedulerConf {
  +		defaultConfig, err := GetDefaultSchedulerConf()
  +		...
  +		copied := *defaultConfig
  +		schedulerConf = &copied
  +	}
  ```
  </details>
- **consolidation 动作新增插件扩展点。** `Session` 新增 `ConsolidationVictimFilterFns`、`AddConsolidationVictimFilterFn` 和 `ConsolidationVictimFilter()`(所有过滤函数都返回 true 才放行)。`buildPreemptibleFilterFunc` 改为接收 `ssn`,并在计数 `preempteeJobsCounter` 之前调用该过滤器。至此 reclaim、preempt、consolidation 三类受害者选择都有了插件可挂的过滤点，例如可以挂“最短运行时保护”。
  <details><summary>代码依据 pkg/scheduler/actions/consolidation/consolidation.go / framework/session_plugins.go(compare API 补拉，helper 节选未含)</summary>

  ```diff
  -func buildPreemptibleFilterFunc(preemptor *podgroup_info.PodGroupInfo, maxPreempteesToTest int) func(*podgroup_info.PodGroupInfo) bool {
  +func buildPreemptibleFilterFunc(ssn *framework.Session, preemptor *podgroup_info.PodGroupInfo, maxPreempteesToTest int) func(*podgroup_info.PodGroupInfo) bool {
  ...
  +		if !ssn.ConsolidationVictimFilter(preemptor, job) {
  +			return false
  +		}
  ```
  ```diff
  +func (ssn *Session) AddConsolidationVictimFilterFn(cf api.VictimFilterFn) {
  +	ssn.ConsolidationVictimFilterFns = append(ssn.ConsolidationVictimFilterFns, cf)
  +}
  ```
  </details>
- **chart 开放 `admission.queueLabelSelector`。** 原先模板里硬编码为 `false`,现在取 values,默认仍为 false。设为 true 后，admission webhook 只作用于带 `global.queueLabelKey`(默认 `kai.scheduler/queue`)标签的 namespace,便于和其他调度器在多租户集群里共存。
  <details><summary>代码依据 deployments/kai-scheduler/templates/_helpers.tpl / values.yaml(补拉)</summary>

  ```diff
  -    queueLabelSelector: false
  +    queueLabelSelector: {{ .Values.admission.queueLabelSelector | default false }}
  ```
  </details>
- **podgrouper 两处修复。** 一是 Ray 分组读取 worker group 挂起状态的字段名由 `suspended` 改为 KubeRay 实际使用的 `suspend`。修复前，被挂起的 worker group(例如 RayJob 的 DeleteWorkers 删除策略)仍按原副本数计入 gang 的 minMember。二是 `getTopOwnerInstance` 改用 `clientWithoutCache.Get`,避免读到 informer 缓存里尚未同步的 top owner。无 owner 的 Pod 改由 `podAsUnstructured` 直接转换。
  <details><summary>代码依据 pkg/podgrouper/podgrouper/plugins/ray/ray_grouper.go / podgrouper.go</summary>

  ```diff
  -	suspendedWorkerGroup, found, err := unstructured.NestedBool(workerGroupSpec, "suspended")
  +	suspendedWorkerGroup, found, err := unstructured.NestedBool(workerGroupSpec, "suspend")
  ```
  ```diff
  -	err := pg.client.Get(ctx, key, topOwnerInstance)
  +	err := pg.clientWithoutCache.Get(ctx, key, topOwnerInstance)
  ```
  </details>
- numa-placement-exporter 的 `buildArgsList` 新增 `jsonLog` 参数，通过 `common.AddControllerRuntimeJSONLogArg` 继承 `global.jsonLog`。属于运维一致性修复。
  <details><summary>代码依据 pkg/operator/operands/numa_placement_exporter/resources.go</summary>

  ```diff
  -	container.Args = buildArgsList(config)
  +	container.Args = buildArgsList(config, kaiConfig.Spec.Global.JSONLog)
  ...
  -	return args
  +	return common.AddControllerRuntimeJSONLogArg(jsonLog, args)
  ```
  </details>

### 后续发展方向 [AI]
- **KAI 在为“同一集群里 device-plugin 节点和 DRA-only 节点并存”做兼容。** 它沿用 K8s 的 DeviceClass `extendedResourceName` 机制，让旧的 `nvidia.com/gpu` 请求在 DRA 节点上被映射或被明确拒绝，不再静默绑错节点。对我们的启示：做 GPU 调度时，节点 GPU 来源有三种状态(device-plugin / DRA / 两者都有),每种都要有显式的谓词，否则迁移期会出现“调度成功但容器拿不到卡”。证据只覆盖谓词这一层;上期的 `"fractional/shared GPU pods are not yet supported on DRA-only nodes"` 限制仍在,fraction 走 DRA 的路径尚未出现。
- **空 action 的“只读 shard”加上 `/get-snapshot`,让 KAI 的调度器可以作为集群状态观察器或仿真输入源旁路部署。** 配合 consolidation 过滤扩展点，可以看出 KAI 在把受害者选择策略插件化。证据只有配置和 session 层，还没有看到使用新扩展点的内置插件。

## NVIDIA/k8s-device-plugin: a817d82f -> a46c3947
- 比较: a817d82f45389f99869f9040e6980be6a1fcbe35 -> a46c3947 | ahead=2 | files=2 | Release: v0.20.2
- compare: https://github.com/NVIDIA/k8s-device-plugin/compare/a817d82f45389f99869f9040e6980be6a1fcbe35...a46c39473c5d6c4807bd91ccef86a6998fdaf58a
- 提交: https://github.com/NVIDIA/k8s-device-plugin/commit/20510e936173536cf759586fb423338c2d24ce0e Allow 48 MPS clients on Volta devices(PR #2117)

### AI 总结重点(源码 diff 为据)
- **`mpsDevice.isAtLeastVolta()` 的阈值从 7.5 改为 7.0。** 旧实现名为 “Volta”,实际要求 `major>7 || (major==7 && minor>=5)`,也就是 Turing 才达标，导致 V100(7.0)、Xavier(7.2)被当成 pre-Volta,`maxClients()` 只给 16。新实现为 `major>=7`,这两类设备上限变为 48。边界处理：用 `strings.Cut` 的 `ok` 拒绝没有 minor 的 `"7"`,minor 仍须是数字(`"7."`、`"7.invalid"` 均判否)。空 compute capability(如 WSL)仍按保守的 16 处理,`Replicas: 17` 会触发 `errInvalidDevice`。
  <details><summary>代码依据 cmd/mps-control-daemon/mps/device.go</summary>

  ```diff
  -	majorStr, minorStr, _ := strings.Cut(strings.TrimPrefix(d.ComputeCapability, "v"), ".")
  +	majorStr, minorStr, ok := strings.Cut(strings.TrimPrefix(d.ComputeCapability, "v"), ".")
  +	if !ok {
  +		return false
  +	}
  ...
  -	return major > 7 || (major == 7 && minor >= 5)
  +
  +	return major >= 7
  ```
  </details>
  <details><summary>代码依据 cmd/mps-control-daemon/mps/device_test.go</summary>

  ```diff
  -				ComputeCapability: "7.0",
  +				ComputeCapability: "6.1",
   			},
   			expectedIsAtLeastVolta: false,
   			expectedMaxClients:     16,
  ...
  +			description: "volta clients max",
  +				ComputeCapability: "7.2",
  +				Replicas:          48,
  +			expectedIsAtLeastVolta: true,
  +			expectedMaxClients:     48,
  ```
  </details>

### 后续发展方向 [AI]
- 经典 device-plugin 的 MPS 路径仍在修正确性 bug,没有冻结。不过这次只改了上限判定,MPS 配置面没有新增能力。我们若在 MPS 之上做软切分，客户端上限应按 compute capability ≥7.0 取 48,不要沿用旧的 7.5 门槛。证据只覆盖 `device.go`。

## kubernetes-sigs/dra-driver-nvidia-gpu: 6b1b335c -> 5da6f625
- 比较: 6b1b335c654357de6f418b4e265b4ef40bc005ab -> 5da6f625 | ahead=3 | files=2 | Release: v0.5.1
- compare: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/6b1b335c654357de6f418b4e265b4ef40bc005ab...5da6f62540fe3f807ba7023cc5b0690451072b3d
- 提交: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/1239f45517c13d0f51b899317b5d059ec7ece36f flock: honor canceled context before acquiring the lock;https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/11052ea90385f2e5e341ce60577ea1d6c90ae294 test: add unit tests for pkg/flock(PR #1619)

### AI 总结重点(源码 diff 为据)
- **`Flock.Acquire` 的轮询循环每次尝试 `syscall.Flock(LOCK_EX|LOCK_NB)` 之前，先检查 `ctx.Err()`。** 若 ctx 已取消，就关闭 fd 并返回包装后的错误。修复前，取消只在后面的 `select` 中判断：如果 `ctx.Done()` 和 ticker 同时就绪，`select` 可能选中 ticker,已取消的调用方仍可能拿到锁，并开始执行受锁保护的 Prepare/Unprepare。另外新增 161 行 `flock_test.go`,覆盖获取/释放、超时、取消等场景。
  <details><summary>代码依据 pkg/flock/flock.go</summary>

  ```diff
   	for {
  +		// Honor cancellation before every attempt, so that a caller whose
  +		// context is already done never acquires the lock (and never starts
  +		// the work the lock protects). ...
  +		if err := ctx.Err(); err != nil {
  +			f.Close()
  +			return nil, fmt.Errorf("error acquiring lock (%s): %w", l.path, err)
  +		}
  +
   		flerr := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
  ```
  </details>

### 后续发展方向 [AI]
- 上期大规模合入 ComputeDomain 之后，本期转入节点侧并发原语的加固，和上期修复 Prepare goroutine 泄漏是同一方向。证据只覆盖 `pkg/flock`,没有 API 或 CRD 变化。

## NVIDIA/gpu-driver-container: fdae62a6 -> 24e26a1a
- 比较: fdae62a6b79a3584267e6361e9fa743d5136b1b8 -> 24e26a1a | ahead=2 | files=4 | Release: —
- 提交: https://github.com/NVIDIA/gpu-driver-container/commit/37b75e34fd84390734ea89154e3b6cd68b6f4235 Add support for drivers 580.196.11, 595.112.13 and 620.70.10, bump golang to 1.27.4(PR #1097)

### AI 总结重点(源码 diff 为据)
- **三条活跃数据中心分支的驱动小版本整体前移:`580.196.07→580.196.11`、`595.112.07→595.112.13`、`620.70.06→620.70.10`。** `versions.mk`、`.common-ci.yml`(含 ubuntu24.04 / ubuntu26.04 / rhel10 矩阵)和 GitHub workflow 同步更新。ubuntu26.04 仍排除 580 分支。golang 从 1.27.3 升到 1.27.4。另一处值得注意:`.nvidia-ci.yml` 的 `PUBLISH_VERSIONS` 由只发 `620.70.06` 改为三条分支都发，说明 580 LTS 和 595 的新补丁镜像也会公开发布，不再只发最新分支。OS 和预编译矩阵的维度没有增减。
  <details><summary>代码依据 versions.mk / .nvidia-ci.yml</summary>

  ```diff
  -DRIVER_VERSIONS ?= 580.196.07 595.112.07 620.70.06
  +DRIVER_VERSIONS ?= 580.196.11 595.112.13 620.70.10
  -GOLANG_VERSION := 1.27.3
  +GOLANG_VERSION := 1.27.4
  ```
  ```diff
  -  PUBLISH_VERSIONS: 620.70.06
  +  PUBLISH_VERSIONS: 580.196.11 595.112.13 620.70.10
  ```
  </details>

### 后续发展方向 [AI]
- gpu-operator 的默认驱动(上期为 620.70.06)大概率会随后跟进到 620.70.10。下期请看 gpu-operator 的 `values.yaml` 和 CSV 中带 `Bump` 前缀的提交。证据只覆盖 driver-container 的构建矩阵。

<details>
<summary>## 本期无实质改动(5 仓)</summary>

- NVIDIA/gpu-operator:只有 `chore(deps)` 把 distroless/cc 从 v4.2.2 升到 v4.2.3(`docker/Dockerfile`),已用 compare API 核对全量提交标题。 https://github.com/NVIDIA/gpu-operator/commit/82257f4601
- NVIDIA/nvidia-container-toolkit:只有 dependabot 把 distroless/go 从 v4.2.0 升到 v4.2.3(`deployments/container/Dockerfile`),已核对。 https://github.com/NVIDIA/nvidia-container-toolkit/commit/9038b2aa76
- NVIDIA/dcgm-exporter:无新提交(HEAD 仍是 4e663a52,Release 4.9.0)
- NVIDIA/DCGM:无新提交(HEAD 仍是 9fae2867,master 分支)
- NVIDIA/mig-parted:无新提交(HEAD 仍是 6cf77a2b,Release v0.15.2)

</details>

## 扫描锚点(机器可读，勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=f6acfb9ee0ab4a041ff1a035ebb851d306583327 branch=main release=v26.7.3 scanned=2026-11-26 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=6cf77a2b52a528d2bac5468b7a33abb7bf45ac68 branch=main release=v0.15.2 scanned=2026-11-26 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=24e26a1ab32df265a298e95a4ec9116789d0b140 branch=main release=— scanned=2026-11-26 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=8abf947869fd1f97019c267e9f02397c3ce4dc97 branch=main release=v1.20.2 scanned=2026-11-26 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5da6f62540fe3f807ba7023cc5b0690451072b3d branch=main release=v0.5.1 scanned=2026-11-26 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=a46c39473c5d6c4807bd91ccef86a6998fdaf58a branch=main release=v0.20.2 scanned=2026-11-26 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=8e0d52c26a117f3f4212a80a15cc82a10b1c1ea1 branch=main release=v0.18.9 scanned=2026-11-26 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-26 -->
