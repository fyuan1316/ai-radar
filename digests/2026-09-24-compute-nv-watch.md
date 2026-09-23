# NVIDIA 算力栈 diff 雷达 2026-09-24

## 摘要
- **k8s-device-plugin 新增第三种共享分配策略 `spread`**:在 distributed/packed 之外补上"单 Pod 尽量铺满不同物理 GPU"的语义,靠新引入的 `touched()`(pickedFrom+requiredReplicas)排序,是 time-slicing/MPS 副本放置面的能力扩展。
- **KAI-Scheduler 一次落两个重量级调度能力**:`semi-preemptible` 抢占档(gang 的最小满足形状 core 锁在配额内不可抢,超出部分弹性优先回收,新增 CRD 字段 `status.schedulingState.corePods`)+ `Background Pods` 插件(把运维/健康检查 Pod 从调度器视图里"虚拟驱逐",其占用算作空闲、按需真驱逐)。
- **dra-driver MIG 路径健壮性**:MIG 设备回滚新增按 GPU minor 回退查找、枚举时跳过 rev1/nvl 非标 CI profile 防不支持机型建 MIG 失败;gpu-operator 出 v26.7.1 补丁并新增 R615 驱动分支进矩阵。

## 当日重要改变
- k8s-device-plugin [新能力/配置面] 新增 `AllocationPolicySpread` 常量与 comparator,`--shared-devices-allocation-policy` 现接受 `[distributed|packed|spread]`。证据 `api/config/v1/consts.go`、`internal/rm/allocate.go` https://github.com/NVIDIA/k8s-device-plugin/commit/86142cf1a93fb68a99c5927b9599e13392e27e15
- KAI-Scheduler [API/CRD变更] `Preemptibility` enum 增 `semi-preemptible`,`PodGroupStatus` 增 `SchedulingState.CorePods`(仅调度器可写,其余组件只读),CRD 同步。证据 `pkg/apis/scheduling/v2alpha2/podgroup_types.go`、`deployments/kai-scheduler/crds/scheduling.run.ai_podgroups.yaml` https://github.com/kai-scheduler/KAI-Scheduler/pull/1804
- KAI-Scheduler [新能力] 新增 `pkg/scheduler/plugins/backgroundpods` 顶层插件包。证据 `backgroundpods.go`、`docs/background-pods/README.md` https://github.com/kai-scheduler/KAI-Scheduler/pull/2108
- dra-driver-nvidia-gpu [健壮性] MIG 枚举跳过 `1_SLICE_REV1` 与新增的 `7_SLICE_NVL` CI profile,防不支持机型建 MIG 失败;MIG 设备定位在 ParentPCIBusID 缺失时按 GPU minor 回退。证据 `cmd/gpu-kubelet-plugin/nvlib.go` https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/495bf4c59b9423080aa1fe2163955f44a495012c
- gpu-operator [矩阵] CSV/values 新增 R615 驱动分支(driver-image-615 / DRIVER_IMAGE-615),v26.7.1 补丁。证据 `bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml` https://github.com/NVIDIA/gpu-operator/commit/42052c45a53f8c50e607b72ddc410ecfb9865060

## NVIDIA/k8s-device-plugin: 3dd82d32 -> 86142cf1
- 比较: 3dd82d32 -> 86142cf1 | ahead=2 | files=4 | Release: v0.20.1
### AI 总结重点(源码 diff 为据)
- 新增 `AllocationPolicySpread = "spread"` 常量,与既有 distributed/packed 并列,作为 replicated(time-slicing)/MIG 资源的第三种共享分配策略。CLI flag `--shared-devices-allocation-policy` 与 `validateFlags` 的 switch 同步纳入 spread。
  <details><summary>代码依据 api/config/v1/consts.go & cmd/nvidia-device-plugin/main.go</summary>

  ```diff
  	AllocationPolicyDistributed = "distributed"
  	AllocationPolicyPacked      = "packed"
  +	AllocationPolicySpread      = "spread"

  -	Usage:   "the allocation policy for replicated and MIG resources:\n\t\t[distributed | packed]",
  +	Usage:   "the allocation policy for replicated and MIG resources:\n\t\t[distributed | packed | spread]",
  		case spec.AllocationPolicyPacked:
  +		case spec.AllocationPolicySpread:
  ```
  </details>
- comparator 签名从 `func(i, j *replicaCount)` 改为 `func(i, j *gpuAllocState)`,把优先级判据从"仅看 allocated() 计数"升级为"计数 + 本次分配已触碰量"的二级排序。distributed/packed 现在先比 `count.allocated()`、平手再比 `pickedFrom`;spread 则先比新引入的 `touched()`(= pickedFrom + requiredReplicas,即本次分配已铺到该卡的槽数),越少越优先——目的是让同一 Pod 的多个副本尽量分散到更多不同物理 GPU。
  <details><summary>代码依据 internal/rm/allocate.go</summary>

  ```diff
  -type replicaComparator func(i, j *replicaCount) bool
  +type replicaComparator func(i, j *gpuAllocState) bool

  +	spec.AllocationPolicySpread: func(i, j *gpuAllocState) bool {
  +		if i.touched() != j.touched() {
  +			return i.touched() < j.touched()
  +		}
  +		return i.count.allocated() < j.count.allocated()
  +	},

  +	requiredReplicas int  // required replicas already pinned to this GPU
  +func (s *gpuAllocState) touched() int {
  +	return s.pickedFrom + s.requiredReplicas
  +}
  ```
  </details>
- 优先队列 `gpuPriorityQueue.Less` 由"先比 allocated、平手比 pickedFrom 的硬编码两级"简化为直接委托给 policy comparator,统一了三种策略的排序入口;原先内置的 pickedFrom 兜底轮转逻辑被并入各 comparator 自身。
### 后续发展方向 [AI]
- spread 与既有 distributed 的差别是"跨物理卡覆盖最大化"而非"负载均摊",对多副本推理/需要 NVLink 拓扑分散的场景是放置粒度的补齐;证据只覆盖 comparator 与 flag 校验,未见调度器/GFD 侧对 spread 的标签暴露或文档,能否被 gpu-operator 的 devicePlugin.config 直接下发需后续确认。

## kubernetes-sigs/dra-driver-nvidia-gpu: b936bcbc -> 495bf4c5
- 比较: b936bcbc -> 495bf4c5 | ahead=13 | files=33 | Release: v0.5.0
### AI 总结重点(源码 diff 为据)
- MIG profile 枚举 `inspectMigProfilesAndPlacements` 的跳过条件从"仅跳 `1_SLICE_REV1`"扩到"同时跳 `7_SLICE_NVL`",注释点明 rev1 与 nvl 都是非标 CI profile、与既有 1_SLICE/7_SLICE 槽数相同会在不支持机型上导致 MIG 创建失败,故一并排除。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/nvlib.go</summary>

  ```diff
  -		if migProfile.GetInfo().CIProfileID == nvml.COMPUTE_INSTANCE_PROFILE_1_SLICE_REV1 {
  +		if info.CIProfileID == nvml.COMPUTE_INSTANCE_PROFILE_1_SLICE_REV1 || info.CIProfileID == nvml.COMPUTE_INSTANCE_PROFILE_7_SLICE_NVL {
  			return nil
  		}
  ```
  </details>
- MIG 设备回滚定位 `FindMigDevBySpec`:当 mig spec 由"已分配设备名"构造导致 `ParentPCIBusID` 为空时,改为按 `ParentMinor` 调 `getGpuInfoByMinor` 反查父 GPU 的 UUID/PCI,补上了原先直接用空 PCIBusID 查表拿不到 parent 的漏洞(commit 标题即 "fallback search by gpu minor for mig device rollback")。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/nvlib.go</summary>

  ```diff
  -	parentUUID := l.gpuUUIDbyPCIBusID[ms.ParentPCIBusID]
  +	if ms.ParentPCIBusID == "" {
  +		gpuInfo, err := l.getGpuInfoByMinor(ms.ParentMinor)
  +		...
  +		parentUUID = gpuInfo.UUID
  +	} else {
  +		parentUUID = l.gpuUUIDbyPCIBusID[parentPCIBusID]
  +	}
  ```
  </details>
- 一批 NVLink fabric/clique 检测与 MIG 清理日志从 `klog.Infof` 降级为 `klog.V(4)/V(6)`(compute-domain-kubelet-plugin 的 no-clique fallback、gpu-kubelet-plugin 的 CI-not-found/skip-MIG-disable),纯降噪、不改行为。
- 测试基建:bats 套件支持 `TEST_IMAGE` 自定义插件镜像(含 repo/tag 校验与 pull secret/policy 透传),并新增 `tests-gpu-dynmig-no-mig-mode-toggle` 目标——面向 MIG 模式永久开启、无法 toggle 的机型(如云上 A100),清理时只删 CI/GI 不再 `-mig 0`。
  <details><summary>代码依据 tests/bats/cleanup-from-previous-run.sh</summary>

  ```diff
  +if [ "${TEST_MIG_MODE_TOGGLE_SUPPORTED:-true}" = "false" ]; then
  +  nvmm all sh -c 'nvidia-smi mig -dci; nvidia-smi mig -dgi' ...
  +else
  +  # Skip on A100 cloud VMs (#883) ... nvidia-smi -mig 0
  ```
  </details>
### 后续发展方向 [AI]
- 本期 dra-driver 主线是"把 MIG 动态切分在异构/受限机型上跑稳"(nvl profile 排除、minor 回退、无-toggle 机型清理),证据集中在 gpu-kubelet-plugin 与测试,未见 DRA API/ResourceClaim 结构变化;compute-domain(IMEX/多节点 fabric)本期只有日志降级,无逻辑改动。

## kai-scheduler/KAI-Scheduler: 6e83bbca -> b4486893
- 比较: 6e83bbca -> b4486893 | ahead=8 | files=158 | Release: v0.18.0
### AI 总结重点(源码 diff 为据)
- 新增第三种抢占档 `SemiPreemptible = "semi-preemptible"`,并进 CRD enum。语义:PodGroup 的"最小满足形状"(每 leaf 的 minMember、每 node 的 minSubGroup)为 core,锁在配额内不可抢占/回收;超出该最小的部分是 elastic surplus(over-quota,优先回收)。
  <details><summary>代码依据 pkg/apis/scheduling/v2alpha2/podgroup_types.go</summary>

  ```diff
  -// +kubebuilder:validation:Enum=preemptible;non-preemptible
  +// +kubebuilder:validation:Enum=preemptible;non-preemptible;semi-preemptible
  +	SemiPreemptible Preemptibility = "semi-preemptible"
  ```
  </details>
- 新增 `PodGroupStatus.SchedulingState *PodGroupSchedulingState`,其中 `CorePods []string` 记录调度器保护、不参与抢占/回收的 core Pod 集合;注释强调"仅调度器写、其余 controller 只读"。CRD 同步暴露 `status.schedulingState.corePods`。
  <details><summary>代码依据 pkg/apis/scheduling/v2alpha2/podgroup_types.go & crds/scheduling.run.ai_podgroups.yaml</summary>

  ```diff
  +	SchedulingState *PodGroupSchedulingState `json:"schedulingState,omitempty" ...`
  +type PodGroupSchedulingState struct {
  +	CorePods []string `json:"corePods,omitempty" ...`
  +}
  +              schedulingState:
  +                properties:
  +                  corePods:
  ```
  </details>
- 驱逐路径 `GetTasksToEvict` 为 semi-preemptible 单开分支:只交出 elastic surplus,core 永不被驱逐,跳过 phase-3 全驱逐兜底;先收 stale 成员(既非 surplus 也非 core),再收 elastic,最后用 `GetCoreTasks` 过滤掉任何落进 core 的 task 作最终保险。core 成员选取按"已满足优先、再按名字"稳定排序(`coreMemberLess`),刻意不用会话的 SubGroupOrderFn,避免 core 集合随 Pod 增删漂移而逐个拆散 gang。
  <details><summary>代码依据 pkg/scheduler/api/podgroup_info/eviction_info.go</summary>

  ```diff
  +	if job.IsSemiPreemptibleJob() {
  +		tasks = collectStaleEviction(root, reverseTaskOrderFn)
  +		if len(tasks) == 0 {
  +			tasks = collectElasticEvictionFromSubGroupSet(...)
  +		}
  +		core := GetCoreTasks(job, taskOrderFn)
  +		tasks = slices.DeleteFunc(tasks, func(t *pod_info.PodInfo) bool { _, isCore := core[t.UID]; return isCore })
  ```
  </details>
- webhook `ValidateUpdate` 对 semi-preemptible PodGroup 加 immutability 校验:root 及各同名 SubGroup 的 `minMember`/`minSubGroup` 只许降不许升(升会扩大 non-preemptible 的配额占用),unset 字段按调度器实际生效值比较。
- 新增 Background Pods 插件包 `pkg/scheduler/plugins/backgroundpods`:OnSessionOpen 时按 label(默认 `kai.scheduler/background=true`)把运维/健康检查 Pod 从内存会话里"虚拟驱逐",使其占用算作可用容量参与放置/bin-packing;OnSessionClose 逐个还位,放不下的才在集群里真驱逐。设计上明确不最小化驱逐次数、不建议用于重启代价高的 Pod。
  <details><summary>代码依据 pkg/scheduler/plugins/backgroundpods/backgroundpods.go</summary>

  ```go
  // Package backgroundpods removes maintenance pods from the scheduler's view of the cluster for the
  // duration of a session, so that capacity they hold is treated as available. At session close, each
  // one is offered its place back; those that no longer fit are evicted for real.
  defaultLabelSelector = "kai.scheduler/background=true"
  ```
  </details>
- 新增 `resource_info.LessOrEqualWithTolerance`(1e-9 容差)修复分数资源边界的浮点舍入误判(commit "tolerate fractional resource boundary rounding")。
### 后续发展方向 [AI]
- KAI 本期把"弹性 gang 调度"做实:semi-preemptible = 保底最小形状 + 弹性扩缩,直接对标训练作业"至少 N 卡不可被抢、富余部分可被回收";Background Pods 则解决 DaemonSet 式运维负载吃掉可调度容量的老问题。两者都新增 CRD 表面(corePods 状态 / 插件 label 约定),对我们产品的启示:多租户抢占策略若只有 preemptible/non-preemptible 二档,面对训练弹性伸缩会偏硬,semi-preemptible 的 core/elastic 分层值得对标。证据覆盖 API/eviction/plugin 主体,未展开 proportion 插件对 core 的配额计费(coreRequiredQuota)细节,semi-preemptible 与 topology-aware 放置的交互未见测试覆盖。

## NVIDIA/gpu-operator: 50e3b56c -> 42052c45
- 比较: 50e3b56c -> 42052c45 | ahead=16 | files=17 | Release: v26.7.0(bundle 内标 v26.7.1)
### AI 总结重点(源码 diff 为据)
- CSV manifest 与 values.yaml 新增 R615 驱动分支:`driver-image-615` 与环境变量 `DRIVER_IMAGE-615` 各指向一份 driver 镜像 digest,olm.skipRange 与 bundle 名从 v26.7.0 抬到 v26.7.1(补丁级,非 major/minor 跨档)。
  <details><summary>代码依据 bundle/manifests/gpu-operator-certified.clusterserviceversion.yaml</summary>

  ```diff
  +    - name: driver-image-615
  +      image: nvcr.io/nvidia/driver@sha256:54d5e96c...
  +                  - name: "DRIVER_IMAGE-615"
  +                    value: "nvcr.io/nvidia/driver@sha256:54d5e96c..."
  -    olm.skipRange: '>=1.9.0 <26.7.0'
  +    olm.skipRange: '>=1.9.0 <26.7.1'
  ```
  </details>
- 编排组件版本 pin 同步上抬:device-plugin/GFD v0.20.0→v0.20.1、k8s-driver-manager(driver/vfio/vgpu 三处)v0.12.0→v0.12.1、vgpu-device-manager v0.5.0→v0.5.1;container-toolkit/dcgm/mig-manager 保持不变。
- CI 扫描步骤 `.scan` 重构:弃用 `docker pull + docker save` 落地 tar 的旧法,改由 pulse-cli 直接从 registry 拉取扫描(`scan-image -i $IMAGE --platform`),去掉 DinD 依赖与 IMAGE_ARCHIVE,产物从多个 json 收敛为 `scan-results/**/*`。属 CI 内务,不影响交付物。
### 后续发展方向 [AI]
- 本期 gpu-operator 是纯运维补丁:R615 驱动进认证矩阵 + 下游组件 patch 版本对齐,ClusterPolicy CRD 字段无增删(`clusterpolicy_types.go` 未命中)。R615 是新驱动分支(继 580/610 之后),指向对新一代 GPU/内核的滚动支持;证据仅镜像 digest,未见对应 driver 容器构建侧改动(gpu-driver-container 本期 EMPTY)。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 停在 v1.20.1)
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/dcgm-exporter — 无新提交(4.8.4)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — 仅 bump/CI/merge(v0.15.1)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=42052c45a53f8c50e607b72ddc410ecfb9865060 branch=main release=v26.7.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=84e2c2c182bfa0b2edab4fdca27e5197faba0ca7 branch=main release=v1.20.1 scanned=2026-09-24 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=575c9011c4fa4b94200c56818b1f97cdbcf610af branch=main release=— scanned=2026-09-24 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=86142cf1a93fb68a99c5927b9599e13392e27e15 branch=main release=v0.20.1 scanned=2026-09-24 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=495bf4c59b9423080aa1fe2163955f44a495012c branch=main release=v0.5.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-09-24 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-24 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=626a3f6a2c8597705f42b4be27a822f561fef706 branch=main release=v0.15.1 scanned=2026-09-24 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b44868939553e64c67b43467b8e0cc4939495d32 branch=main release=v0.18.0 scanned=2026-09-24 -->
