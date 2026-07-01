# NVIDIA 算力栈 diff 雷达 2026-07-02

## 摘要
- **gpu-operator** 给驱动升级加了一条"原地重启"快路径:新增 `RestartOnlyPredicate`,当运行中 driver Pod 与目标 DaemonSet 模板的 `DRIVER_CONFIG_DIGEST` 相同(即仅 `helm.sh/chart` 等非安装相关 label 变了)时,直接重启 Pod 而不走整节点排空/重装的完整升级流程——省掉纯 chart 版本升级触发的无谓驱动重装。
- **KAI-Scheduler** 一批 API/CRD 收敛:① [破坏性] 从 `PodGroup`(scheduling.run.ai/v2alpha2)删掉 5 个从未被写过的 status 字段(`phase/running/succeeded/failed/pending`)及 `PodGroupPhase` 类型;② numa-placement-exporter 的 podresources socket / host 路径 / sysfs 路径改为 CRD 可配(为仿真/非 kubelet 场景);③ GPU fraction 注解校验挡住 NaN 与不可解析值。
- **k8s-device-plugin** 修 time-slicing 分配的一个平铺缺陷:`distributedAlloc` 在 sort-key 打平时改为优先选"本次分配还没碰过的物理 GPU",让副本更均匀铺到不同物理卡而非堆在同一张卡上。
- 其余:gpu-driver-container 仅数据中心驱动分支补丁位 `580.167.08→580.173.02` + UBI base 镜像摘要 bump(无代码逻辑)。container-toolkit / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted 五仓无新提交。

## 当日重要改变
- KAI-Scheduler [API/CRD变更/移除] 从 `PodGroup` v2alpha2 schema 删除 `status.phase/running/succeeded/failed/pending` 五字段及 `PodGroupPhase` 类型(#1670),理由:无任何控制器写过它们,判活改用 `status.resourcesStatus` / `status.schedulingConditions`。证据 `pkg/apis/scheduling/v2alpha2/podgroup_types.go`、`deployments/kai-scheduler/crds/scheduling.run.ai_podgroups.yaml`。https://github.com/kai-scheduler/KAI-Scheduler/compare/4a9f6e6a...6fc7f975
- KAI-Scheduler [API/CRD变更] `NumaPlacementExporter` CRD 新增 `podResourcesHostPath` / `podResourcesSocket` / `sysfsHostPath` 三字段(#1807),把此前硬编码的 kubelet podresources 套接字与 `/sys` 路径开放为可覆盖(仿真/非 kubelet 部署)。证据 `pkg/apis/kai/v1/numa_placement_exporter/numa_placement_exporter.go`、`deployments/kai-scheduler/crds/kai.scheduler_configs.yaml`。https://github.com/kai-scheduler/KAI-Scheduler/compare/4a9f6e6a...6fc7f975
- gpu-operator [新能力] 新增 `internal/predicates/restart_only.go` 的 `DriverPodRestartOnly` 谓词并挂到 upgrade state manager,`DRIVER_CONFIG_DIGEST` 一致时驱动 Pod 走原地重启而非完整升级流程。证据 `internal/predicates/restart_only.go`、`cmd/gpu-operator/main.go`。https://github.com/NVIDIA/gpu-operator/compare/4b786010...7b38b138

## NVIDIA/gpu-operator: 4b786010 -> 7b38b138
- 比较 / 最新 Release:4b786010 -> 7b38b138 | ahead=2 | files=12 | Release: v26.3.3
- https://github.com/NVIDIA/gpu-operator/compare/4b786010...7b38b138

### AI 总结重点(源码 diff 为据)
- **驱动升级新增"原地重启"快路径**:新建 `predicates` 包,`DriverPodRestartOnly(log)` 返回一个 `upgrade.RestartOnlyPredicate`——比较 running 与 desired PodSpec 的 `DRIVER_CONFIG_DIGEST`,两者非空且相等即返回 `true`(允许原地重启),任一缺失则返回 `false` 走完整升级流程。谓词经 `main.go` 的 `WithRestartOnlyPredicate(...)` 注册到 `clusterUpgradeStateManager`。语义:只有非安装相关字段(如 `helm.sh/chart` label)变化、digest 不变时才快路径重启,避免纯 chart bump 触发整节点驱动重装。

  <details><summary>代码依据 internal/predicates/restart_only.go + cmd/gpu-operator/main.go</summary>

  ```diff
  +func DriverPodRestartOnly(log logr.Logger) upgrade.RestartOnlyPredicate {
  +	return func(running, desired *corev1.PodSpec) (bool, error) {
  +		desiredDigest := driverconfig.DriverConfigDigestFromPodSpec(desired)
  +		runningDigest := driverconfig.DriverConfigDigestFromPodSpec(running)
  +		if desiredDigest == "" || runningDigest == "" {
  +			... return false, nil   // digest missing → full upgrade flow
  +		}
  +		restartOnly := desiredDigest == runningDigest
  +		return restartOnly, nil
  +	}
  +}
  // main.go:
  -	clusterUpgradeStateManager = clusterUpgradeStateManager.WithPodDeletionEnabled(...).WithValidationEnabled(...)
  +	clusterUpgradeStateManager = clusterUpgradeStateManager.
  +		WithPodDeletionEnabled(gpuPodSpecFilter).
  +		WithValidationEnabled("app=nvidia-operator-validator").
  +		WithRestartOnlyPredicate(predicates.DriverPodRestartOnly(upgradeLogger))
  ```
  </details>

- **digest 读取抽成可复用工具函数**:`internal/config` 导出常量 `DriverConfigDigestEnvName = "DRIVER_CONFIG_DIGEST"` 与 `DriverConfigDigestFromPodSpec(spec)`——按 initContainer 优先、再主容器的顺序取第一个非空 digest env;`object_controls.go` 中三处写 digest(`k8s-driver-manager` init 容器、`nvidia-driver-ctr`、OCP `openshift-driver-toolkit-ctr`)的字面量 `"DRIVER_CONFIG_DIGEST"` 全部替换为该常量。纯读侧新增,写侧只是常量化,digest 计算口径(`DriverInstallState`)本期未动。

  <details><summary>代码依据 internal/config/driver_config_digest.go</summary>

  ```diff
  +const DriverConfigDigestEnvName = "DRIVER_CONFIG_DIGEST"
  +func DriverConfigDigestFromPodSpec(spec *corev1.PodSpec) string {
  +	... for _, initCtr := range spec.InitContainers { if v := digestFromEnv(initCtr.Env); v != "" { return v } }
  +	for _, ctr := range spec.Containers { if v := digestFromEnv(ctr.Env); v != "" { return v } }
  +	return ""
  +}
  ```
  </details>

### 后续发展方向 [AI]
- 这是驱动升级流程在"配置未变、仅元数据/chart 变"场景下的开销优化,直接减少 GitOps/helm 频繁 reconcile 引发的无谓驱动重装与节点排空。证据仅覆盖 predicate 注册与 digest 读取工具,升级状态机对该谓词的具体消费路径(何时真走原地重启 vs 完整流程)在本仓 `k8s-operator-libs` 依赖侧,本期 diff 未含。

## NVIDIA/k8s-device-plugin: 7d9fe09c -> 10fd1c08
- 比较 / 最新 Release:7d9fe09c -> 10fd1c08 | ahead=4 | files=12 | Release: v0.19.3
- https://github.com/NVIDIA/k8s-device-plugin/compare/7d9fe09c...10fd1c08

### AI 总结重点(源码 diff 为据)
- **time-slicing 分配平铺修复:sort-key 打平时优先未触碰的物理卡**:`distributedAlloc` 原本仅按 `replicas[id].total - replicas[id].available`(已分配差值)排序取候选,差值相等时次序不定,可能把同次请求的多个副本堆到同一张物理 GPU。新增 `pickedFrom map[string]int` 记录本次分配已从每张物理卡取过几次,作为 sort 的二级 tie-break——差值相同时选 `pickedFrom` 更小(碰得更少)的物理卡,每选一个即 `pickedFrom[id]++`。效果:副本更均匀铺到不同物理 GPU。

  <details><summary>代码依据 internal/rm/allocate.go</summary>

  ```diff
  +	pickedFrom := make(map[string]int)
   	for i := 0; i < needed; i++ {
   		sort.Slice(candidates, func(i, j int) bool {
   			idiff := replicas[iid].total - replicas[iid].available
   			jdiff := replicas[jid].total - replicas[jid].available
  -			return idiff < jdiff
  +			if idiff != jdiff {
  +				return idiff < jdiff
  +			}
  +			return pickedFrom[iid] < pickedFrom[jid]
   		})
   		id := AnnotatedID(candidates[0]).GetID()
  +		pickedFrom[id]++
   		replicas[id].available--
  ```
  </details>

### 后续发展方向 [AI]
- 属 time-slicing(副本共享)分配质量修复,非新配置面/新能力;对同一 Pod 请求多个共享副本时的物理卡分散度有直接改善。证据仅 `distributedAlloc` 一函数 + 单测,MPS/DRA 路径本期未动。

## kai-scheduler/KAI-Scheduler: 4a9f6e6a -> 6fc7f975
- 比较 / 最新 Release:4a9f6e6a -> 6fc7f975 | ahead=5 | files=17 | Release: v0.16.2
- https://github.com/kai-scheduler/KAI-Scheduler/compare/4a9f6e6a...6fc7f975

### AI 总结重点(源码 diff 为据)
- **[破坏性] PodGroup status 五字段整体删除**:`PodGroupStatus` 删掉 `Phase PodGroupPhase`、`Running/Succeeded/Failed/Pending int32` 五个字段及 `PodGroupPhase string` 类型定义,CRD YAML 同步删对应 openAPI schema。CHANGELOG 明说这些字段"从未被任何控制器写过",判活改用 `status.resourcesStatus` / `status.schedulingConditions`。对读取过这些字段的外部消费者是破坏性变更。

  <details><summary>代码依据 pkg/apis/scheduling/v2alpha2/podgroup_types.go(-22)</summary>

  ```diff
   type PodGroupStatus struct {
  -	Phase PodGroupPhase `json:"phase,omitempty" ...`
   	Conditions []PodGroupCondition `json:"conditions,omitempty" ...`
  -	Running int32 `json:"running,omitempty" ...`
  -	Succeeded int32 `json:"succeeded,omitempty" ...`
  -	Failed int32 `json:"failed,omitempty" ...`
  -	Pending int32 `json:"pending,omitempty" ...`
   	SchedulingConditions []SchedulingCondition `json:"schedulingConditions,omitempty" ...`
   }
  -// PodGroupPhase is the phase of a pod group at the current time.
  -type PodGroupPhase string
  ```
  </details>

- **numa-placement-exporter 的宿主机路径全面可配**:`NumaPlacementExporter` CRD 新增 `PodResourcesHostPath`(podresources 套接字所在宿主目录,默认 `/var/lib/kubelet/pod-resources`)、`PodResourcesSocket`(dial 的 gRPC 套接字,默认 `.../kubelet.sock`)、`SysfsHostPath`(CPU→NUMA 解析用 sysfs,默认 `/sys`)。`resources.go` 引入 `effectivePodResourcesDir/Socket/SysfsHostPath` 三个 helper 在未配置时回退默认,DaemonSet 的 volume/volumeMount/args 全部改用 effective 值。目的:把 exporter 指向仿真 podresources 套接字或合成 sysfs 树(测试/非标准 kubelet 场景)。

  <details><summary>代码依据 pkg/apis/kai/v1/.../numa_placement_exporter.go + operands/.../resources.go</summary>

  ```diff
  +	PodResourcesHostPath string `json:"podResourcesHostPath,omitempty"`
  +	PodResourcesSocket string `json:"podResourcesSocket,omitempty"`
  +	SysfsHostPath string `json:"sysfsHostPath,omitempty"`
  // resources.go:
  +	podResHostPath := effectivePodResourcesDir(config)
  +	sysHostPath := effectiveSysfsHostPath(config)
  -		fmt.Sprintf("--podresources-socket=%s", consts.DefaultPodResourcesSocket),
  +		fmt.Sprintf("--podresources-socket=%s", effectivePodResourcesSocket(config)),
  ```
  </details>

- **GPU fraction 注解校验挡 NaN 与不可解析值(#1798)**:`validateGpuFractionAnnotation` 新增两道校验——`math.IsNaN(gpuFraction)` 直接报错,并用 `resource.ParseQuantity(gpuFractionFromAnnotation)` 确认注解原始串能被解析为 quantity。堵住此前 NaN 绕过"0<x<1.0"数值区间检查混入准入的口子。

  <details><summary>代码依据 pkg/binder/plugins/gpusharing/gpu-request/gpu_request_validator.go</summary>

  ```diff
  +	if math.IsNaN(gpuFraction) {
  +		return fmt.Errorf("gpu-fraction annotation value must be a valid number. NaN is not allowed")
  +	}
  +	_, err := resource.ParseQuantity(gpuFractionFromAnnotation)
  +	if err != nil {
  +		return fmt.Errorf("gpu-fraction annotation value must be a float ... given value: %s", gpuFractionFromAnnotation)
  +	}
  ```
  </details>

- **chart 加 `createServiceAccount` 守卫 + v0.14 迁移指南**:新增 `global.resourceReservation.createServiceAccount`(默认 true)以便父 chart 自建 SA 时跳过创建(#1799,承接上期 `createNamespace`);新增 `docs/migrationguides/v0.14.0/README.md` 记录 v0.14 的 `global.vpa`/`prometheus` 新字段、`replicaCount>1` 自动开 leader election、`--reuse-values` 因缺 `prometheus` key 触发 nil 指针的已知问题及 workaround。

### 后续发展方向 [AI]
- 本期 KAI 集中在 API 表面收敛(删死字段)与部署可移植性(exporter 路径可配、chart 守卫),延续 v0.16.x 的准入健壮性打磨(继上期显存配额 min/max 后本期堵 NaN)。证据覆盖 apis/crds/binder/operator 四处;调度核心算法(proportion/reclaim)本期未动。

## 本期无实质改动(折叠)
<details>

- NVIDIA/gpu-driver-container — ahead=8,仅数据中心驱动分支补丁位 `DRIVER_VERSIONS 580.167.08→580.173.02`(595.71.05 不变)+ RHEL9/10 UBI base 镜像摘要 bump + renovate action 版本,无 Dockerfile 逻辑/OS 矩阵结构变化。https://github.com/NVIDIA/gpu-driver-container/compare/f41a0200...25b232fc
- NVIDIA/nvidia-container-toolkit — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/mig-parted — 无新提交
- NVIDIA/DCGM — 无新提交(master)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7b38b13887ac4054d2f958d9e178d25f6b72ef8a branch=main release=v26.3.3 scanned=2026-07-02 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=05e941dffa81b88e42f0dc65909ac43fe1254f82 branch=main release=v1.19.1 scanned=2026-07-02 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=25b232fcb8fff88e1c633e2abfad88bd82ce6091 branch=main release=— scanned=2026-07-02 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-02 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=391d5ca8d7ed478e0d7e5aeb8883a85409742ff6 branch=main release=v0.4.1 scanned=2026-07-02 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-02 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=bb6399f0976dafc69f9e059ec968db34ac59a302 branch=main release=v0.14.2 scanned=2026-07-02 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=6fc7f975a27be15f4c1ff6d5ca69ef799c52bdda branch=main release=v0.16.2 scanned=2026-07-02 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-07-02 -->
</content>
</invoke>
