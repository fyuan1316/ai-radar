# NVIDIA 算力栈 diff 雷达 2026-10-08

## 摘要
- **KAI-Scheduler 动作最大**:NUMA 放置导出器(NPE)新增「内存组(Memory Manager groups)」观测能力 + 新 API 类型 `NUMAMemoryGroupPlacement`,并把导出器从「轮询 + 定时 drift」重构为 informer 事件驱动;同时**驱逐指标体系大改**——`pod_group_evicted_pods_total` 去掉 `uid` 标签、新增 owner_* 一组标签,并加了一个新计数器 `pod_group_eviction_events_total`(此为仪表盘/告警潜在破坏性变更)。
- **ComputeDomain(IMEX 多节点 NVLink 域)两仓联动收尾**:dra-driver 与 gpu-operator 同步给 ComputeDomain daemon 补 `delete` 权限;gpu-operator 侧针对 OpenShift 上 MPS/ComputeDomain 做 SCC/RBAC 硬化(hostPID、anyuid 绑定、SERVICE_ACCOUNT_NAME 注入)。
- 其余 5 仓(container-toolkit / k8s-device-plugin / dcgm-exporter / DCGM / mig-parted)本期无新提交;gpu-driver-container 仅删了一段无用 CI 脚本,无生产改动。

## 当日重要改变
- **KAI-Scheduler [API/CRD变更][指标破坏性]** 驱逐指标重打标签:`pod_group_evicted_pods_total` 删除 `uid` label、改为按 owner(group/kind/name/uid)+subgroup 归因;另加新 counter `pod_group_eviction_events_total` 计「已提交的驱逐决策」。依赖旧 `uid` label 的仪表盘/告警会断。证据 pkg/scheduler/metrics/metrics.go https://github.com/kai-scheduler/KAI-Scheduler/pull/2114
- **KAI-Scheduler [新能力][API/CRD变更]** NPE 新增 NUMA 内存组观测:新 API 类型 `NUMAMemoryGroupPlacement{MemoryNodes, Amount}`,新 annotation `kai.scheduler/numa-memory-groups-observed`,新文件 pkg/npe/placement/memory_groups.go(184 行)。证据 pkg/apis/scheduling/v1alpha2/numa_placement_types.go https://github.com/kai-scheduler/KAI-Scheduler/pull/2314
- **KAI-Scheduler [API/CRD变更]** 拓扑 nodeLabel 不可变校验从 CRD 的 CEL XValidation 下沉到 admission webhook。证据 deployments/kai-scheduler/crds/kai.scheduler_topologies.yaml + pkg/admission/webhook/topologyhooks/topology_validator.go https://github.com/kai-scheduler/KAI-Scheduler/pull/2293
- **dra-driver-nvidia-gpu / gpu-operator [权限]** ComputeDomain daemon 新增 `delete`(cliques / rbac),配合 IMEX 域生命周期回收。证据见下两节。

## KAI-Scheduler: 532d0c09 -> 41a22cda
- 比较: 532d0c093f13be6f54f5770c9e45a1d6e10506ee -> 41a22cda | ahead=8 | files=51 | Release: v0.18.3
- https://github.com/kai-scheduler/KAI-Scheduler/compare/532d0c093f13be6f54f5770c9e45a1d6e10506ee...41a22cdaf9100b6aba7db3d345daff70581b0fed

### AI 总结重点(源码 diff 为据)
- **驱逐指标重构,去 uid、改 owner 归因,并新增「驱逐事件」计数器**。`pod_group_evicted_pods_total` 的标签集从 `{podgroup,namespace,uid,nodepool,action}` 变为 `{podgroup,namespace,nodepool,action,owner_group,owner_kind,owner_name,owner_uid,subgroup}`——即 **pod uid 标签被移除**(降基数),改为从 PodGroup 的 `TopOwnerMetadataKey` annotation 解析顶层 owner(yaml 反序列化)做归因;同时新增 `pod_group_eviction_events_total`,语义是「已提交(committed)的驱逐决策数」,区别于「实际被驱逐的 pod 数」。这是工作负载为中心(workload-centric)的驱逐可观测性改造。
  <details><summary>代码依据 pkg/scheduler/metrics/metrics.go</summary>

  ```diff
  -        }, []string{"podgroup", "namespace", "uid", "nodepool", "action"})
  +        }, []string{
  +            "podgroup", "namespace", "nodepool", "action",
  +            "owner_group", "owner_kind", "owner_name", "owner_uid", "subgroup",
  +        })
  +
  +    podGroupEvictionEventsTotal = promauto.NewCounterVec(
  +        prometheus.CounterOpts{
  +            Name:      "pod_group_eviction_events_total",
  +            Help:      "Total number of committed eviction decisions per pod group",
  +        }, []string{"podgroup","namespace","nodepool","action","owner_group","owner_kind","owner_name","owner_uid"})
  +type topOwnerMetadata struct { Name string; UID string; Group string; Kind string }
  +func ownerLabels(podGroup *enginev2alpha2.PodGroup) topOwnerMetadata { ... yaml.Unmarshal(TopOwnerMetadataKey) ... }
  ```
  </details>
- **NUMA 放置导出器新增「内存组」维度,并引入 Memory Manager 多 NUMA 节点跨域语义**。新增 API 类型 `NUMAMemoryGroupPlacement{MemoryNodes []string, Amount v1.ResourceList}`,导出器通过新 annotation `kai.scheduler/numa-memory-groups-observed` 发布每 pod 的内存组(一组 NUMA 节点集合 + 预留量,按相同 node mask 跨容器聚合 memory/hugepages)。非 Guaranteed pod 返回 `[]`;观测不完整/非法返回字符串 `"null"`(区别于 JSON null,后者会删 key);已观测过的 pod 不回退到空串,避免被预测值覆盖。
  <details><summary>代码依据 pkg/apis/scheduling/v1alpha2/numa_placement_types.go + pkg/npe/placement/memory_groups.go</summary>

  ```diff
  +type NUMAMemoryGroupPlacement struct {
  +    MemoryNodes []string        `json:"memoryNodes"`
  +    Amount      v1.ResourceList `json:"amount"`
  +}
  ```
  ```go
  // MemoryGroupsValue: non-Guaranteed→"[]"; 未开始→""; 不完整/非法→"null"(incompleteMemoryGroups); 完整→json 组列表
  const incompleteMemoryGroups = "null"
  ```
  </details>
- **NPE 导出器从「轮询 + 定时 API drift 回扫」改为 informer 事件驱动**。删除 `driftResyncInterval` 字段(`New` 的该参数被忽略,签名保留占位 `_`),用 node-scoped pod informer(`corelisters.PodLister` + `events chan`)驱动 reconcile;写缓存从「namespace/name→annotation 值」改为「pod UID 集合 `writtenGroups`」,避免 pod 名复用导致串台。pods RBAC verb 从 `get;list;patch` 增加 `watch`。
  <details><summary>代码依据 pkg/npe/exporter.go</summary>

  ```diff
  -// +kubebuilder:rbac:groups=core,resources=pods,verbs=get;list;patch
  +// +kubebuilder:rbac:groups=core,resources=pods,verbs=get;list;watch;patch
  -    driftResyncInterval time.Duration
  -    written map[string]string
  +    writtenGroups map[types.UID]struct{}
  +    pods          corelisters.PodLister
  +    events        chan struct{}
  ```
  </details>
- **拓扑 nodeLabel 不可变性校验,从 CRD CEL 规则迁到准入 webhook**。CRD `topologies` 的 `self.map(l, l.nodeLabel) == oldSelf.map(...)` XValidation 规则被删除(`topology_types.go` 的对应 kubebuilder marker 也删),改由 `pkg/admission/webhook/topologyhooks/topology_validator.go` 在 webhook 里校验「结构不可变,仅 alias 可改」。
  <details><summary>代码依据 deployments/kai-scheduler/crds/kai.scheduler_topologies.yaml</summary>

  ```diff
  -                - message: nodeLabel structure is immutable; only aliases may be edited
  -                  rule: self.map(l, l.nodeLabel) == oldSelf.map(l, l.nodeLabel)
                   - message: nodeLabel must be unique
  ```
  </details>
- 另有若干行为修复/增强(非符号级深读,据 commit 标题 + PR):允许「容忍 cordon」的 pod 调度到被 cordon 节点(#2225);operator 支持用 Helm 配置 ServiceMonitor(#2339);DRA extended resources 门控到 k8s 1.34+(#2292)。

### 后续发展方向 [AI]
- KAI 把可观测性重心从「pod 实例」抬到「workload/owner」层:驱逐指标按 owner 聚合 + 新增「驱逐事件」计数,配合 NUMA 内存组观测,指向更细粒度的 NUMA/内存亲和调度闭环(调度器消费 observed 放置、不可用时回退预测)。证据只覆盖 metrics.go / npe 这几处 diff,未展开调度器 plugin 侧如何消费 memory-groups annotation。
- 把拓扑不可变校验从 CEL 迁 webhook,通常是 CEL 表达能力/升级兼容受限的信号(例如要跨字段或给出更友好报错);证据仅见 CRD 删规则 + webhook 文件改动,未读 webhook 内部实现细节。

## gpu-operator: 3d141d8e -> 57378e9c
- 比较: 3d141d8e66bf4851a3a95b1e12789d6cb679faea -> 57378e9c | ahead=4 | files=13 | Release: v26.7.1
- https://github.com/NVIDIA/gpu-operator/compare/3d141d8e66bf4851a3a95b1e12789d6cb679faea...57378e9c2bcc707fb5f30e78cbfa745d361bb14b

### AI 总结重点(源码 diff 为据)
- **针对 OpenShift 上 DRA 驱动跑 MPS,放开 SCC 的 hostPID**。DRA driver 的 SCC 把 `allowHostPID: false → true`,原因是 MPS 控制守护进程 pod 需要 hostPID(测试 `TestDRADriverSCCAllowsMPSHostPID` 断言)。
  <details><summary>代码依据 manifests/state-dra-driver/0450_scc.openshift.yaml</summary>

  ```diff
  -allowHostPID: false
  +allowHostPID: true
  ```
  </details>
- **DaemonSet 注入 SERVICE_ACCOUNT_NAME 与 IMAGE_PULL_SECRETS 环境变量**。MPS daemon 模板不再自动继承 kubelet plugin 的 ServiceAccount,而是显式从 `spec.serviceAccountName`(fieldRef)注入 `SERVICE_ACCOUNT_NAME`;另按 `DRADriver.Spec.ImagePullSecrets` 注入 `IMAGE_PULL_SECRETS`。
  <details><summary>代码依据 manifests/state-dra-driver/0500_daemonset.yaml</summary>

  ```diff
  +        {{- if .DRADriver.Spec.ImagePullSecrets }}
  +        - name: IMAGE_PULL_SECRETS
  +          value: {{ join "," .DRADriver.Spec.ImagePullSecrets | quote }}
  +        {{- end }}
  +        - name: SERVICE_ACCOUNT_NAME
  +          valueFrom:
  +            fieldRef:
  +              fieldPath: spec.serviceAccountName
  ```
  </details>
- **ComputeDomain daemon 在 OpenShift 上绑定 anyuid SCC,并给 operator 补 `use securitycontextconstraints/anyuid` 权限 + 对相关资源加 `delete` verb**。`0120_compute-domain-daemon-rbac.yaml` 在 `.OpenshiftVersion` 下新增 ClusterRoleBinding `compute-domain-daemon-openshift-anyuid-role-binding → system:openshift:scc:anyuid`,并加 `delete`;operator RBAC(role.yaml / 控制器 kubebuilder marker / CSV)同步增 `use anyuid`。
  <details><summary>代码依据 controllers/gpucluster_controller.go + manifests/state-dra-driver/0120_compute-domain-daemon-rbac.yaml</summary>

  ```diff
  +//+kubebuilder:rbac:groups=security.openshift.io,resources=securitycontextconstraints,verbs=use,resourceNames=anyuid
  ```
  ```diff
  +{{- if .OpenshiftVersion }}
  +kind: ClusterRoleBinding
  +metadata:
  +  name: compute-domain-daemon-openshift-anyuid-role-binding
  +roleRef:
  +  name: system:openshift:scc:anyuid
  +{{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- 本期 gpu-operator 全是 **DRA ComputeDomain + MPS 在 OpenShift 上的落地硬化**(SCC/anyuid/hostPID/SA 注入),说明 NVIDIA 把「DRA 原生共享 + IMEX 多节点域」在 OCP 平台的可部署性当作当前收尾重点。证据仅覆盖 manifests/RBAC,未见控制器业务逻辑变更(controllers 仅加 kubebuilder marker)。

## dra-driver-nvidia-gpu: 76468d20 -> a59b797a
- 比较: 76468d20eff7635a5eee2980b610a2a4407dfd2f -> a59b797a | ahead=6 | files=7 | Release: v0.5.0
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/76468d20eff7635a5eee2980b610a2a4407dfd2f...a59b797ab04c23412d22368c7e65f48e22393d7b

### AI 总结重点(源码 diff 为据)
- **ComputeDomain daemon 获得对 `computedomaincliques` 的 `delete` 权限**(resource.nvidia.com),与 gpu-operator 侧同步,用于 IMEX 域 clique 的生命周期回收。
  <details><summary>代码依据 deployments/helm/dra-driver-nvidia-gpu/templates/rbac-compute-domain-daemon.yaml</summary>

  ```diff
  - resources: ["computedomaincliques"]
  -  verbs: ["get", "list", "watch", "create", "update", "patch"]
  +  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  ```
  </details>
- **ComputeDomain 状态指标在「状态未变」路径下也上报,修复控制器重启后计数丢失**。`updateGlobalStatus` 在 `newStatus == 当前状态` 提前返回前,先调 `metrics.ObserveComputeDomainStatus(uid, status)`——保证重启后已是最新状态、不再发 update 的 ComputeDomain 仍被 `nvidia_dra_compute_domain_info` gauge 计入(测试 `TestUpdateGlobalStatusObservesUnchangedStatus` 断言 resync 不重复计数)。
  <details><summary>代码依据 cmd/compute-domain-controller/computedomain.go</summary>

  ```diff
   	if newCD.Status.Status == newStatus {
  +		metrics.ObserveComputeDomainStatus(string(newCD.UID), newStatus)
   		return nil
   	}
  ```
  </details>
- 另:etcd 依赖升级到 v3.7.2 修 CVE-2026-73500(安全 bump,非功能)。

### 后续发展方向 [AI]
- 与 gpu-operator 对看,两仓本期都在打磨 **ComputeDomain(IMEX)控制面的权限完整性与可观测性**(delete 回收 + 重启后状态计数),属多节点 NVLink/GB200 场景的运维稳态收尾,非新功能面扩张。证据覆盖 rbac + 一处 metrics 调用点,未见 clique 分配算法变更。

## 本期无实质改动(折叠)
- NVIDIA/gpu-driver-container:仅删除无用 CI 脚本 `ci/gitlab-get-driver-tags.sh`(76 行),无生产/构建矩阵改动。https://github.com/NVIDIA/gpu-driver-container/compare/74705e23cb2b04e85e42c7e467a413eb266a5b80...9287a5418573da037ba0d287e059812aa4740e45
- NVIDIA/nvidia-container-toolkit:无新提交(release v1.20.1)
- NVIDIA/k8s-device-plugin:无新提交(release v0.20.1)
- NVIDIA/dcgm-exporter:无新提交(release 4.8.4)
- NVIDIA/DCGM:无新提交(master)
- NVIDIA/mig-parted:无新提交(release v0.15.1)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=57378e9c2bcc707fb5f30e78cbfa745d361bb14b branch=main release=v26.7.1 scanned=2026-10-08 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-08 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9287a5418573da037ba0d287e059812aa4740e45 branch=main release=— scanned=2026-10-08 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d5dce58aff4ddf572dc52666f949b37d6be2846c branch=main release=v0.20.1 scanned=2026-10-08 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=a59b797ab04c23412d22368c7e65f48e22393d7b branch=main release=v0.5.0 scanned=2026-10-08 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-08 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-08 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=87f9e3c6be56020a346e9d25379734291cfc9cca branch=main release=v0.15.1 scanned=2026-10-08 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=41a22cdaf9100b6aba7db3d345daff70581b0fed branch=main release=v0.18.3 scanned=2026-10-08 -->
