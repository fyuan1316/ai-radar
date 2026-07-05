# NVIDIA 算力栈 diff 雷达 2026-07-06

## 摘要
- KAI-Scheduler 单仓推进,两个 **API/CRD 结构性扩展**:①拓扑层新增 `alias` 字段(用户友好别名替代裸 nodeLabel 表达亲和约束),配套改写不可变性规则为"仅 nodeLabel 结构不可变、别名可自由编辑"并落地校验 webhook;②BindRequest 新增 `PredictedNUMAZones`,把调度器预测的 per-zone NUMA 放置持久化到 bind 阶段(NRT zone id + per-resource 量),为 NUMA 放置的可观测/可复算打基础。
- 其余 8 仓(gpu-operator / nvidia-container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)相对上期锚点均无新提交,锚点顺延。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [API/CRD变更][新能力] 拓扑 CRD 新增 `alias` 字段:workload 的 requiredTopologyLevel/preferredTopologyLevel 可用别名而非裸 nodeLabel,别名在快照构建时一次性解析回规范 label(`ResolveTopologyAliases`)。证据 `pkg/apis/kai/v1alpha1/topology_types.go`、`deployments/kai-scheduler/crds/kai.scheduler_topologies.yaml`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1788
- kai-scheduler/KAI-Scheduler [API/CRD变更] BindRequestSpec 新增 `PredictedNUMAZones []NUMAZonePlacement`(zone id + ResourceList),将调度器预测的 NUMA 放置持久化,序列化到 `kai.scheduler/numa-placement-predicted` / `-observed` 注解。证据 `pkg/apis/scheduling/v1alpha2/bindrequest_types.go`、`deployments/kai-scheduler/crds/scheduling.run.ai_bindrequests.yaml`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1715

## kai-scheduler/KAI-Scheduler: f2bed2c2 -> 1ce0bd23
- 比较: f2bed2c23d06539e13a04271b8a20fec08a37546 -> 1ce0bd23 | ahead=6 | files=98 | Release: v0.16.2
- Compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/f2bed2c23d06539e13a04271b8a20fec08a37546...1ce0bd236c324fba10731ed5268faff351addc2e

### AI 总结重点(源码 diff 为据)
- **拓扑层引入别名机制,`TopologyLevel` 加 `alias` 字段(可选,pattern 同 label 键)**。此前 workload 表达拓扑约束只能写裸 `nodeLabel`;现在可给每层起个 user-friendly 别名,在同一 Topology 内唯一且不得与任何 nodeLabel 冲突(由 webhook 强校验)。别名可自由编辑,空值时退回只认裸 label。
  <details><summary>代码依据 pkg/apis/kai/v1alpha1/topology_types.go</summary>

  ```diff
  	NodeLabel string `json:"nodeLabel"`
  +
  +	// alias is an optional user-friendly name for this level, usable in place of nodeLabel when
  +	// expressing a workload's topology constraint (requiredTopologyLevel / preferredTopologyLevel).
  +	// Must be unique within the Topology and must not collide with any nodeLabel (enforced by the
  +	// validating webhook). Aliases may be edited freely. When empty, only the raw nodeLabel is usable.
  +	Alias string `json:"alias,omitempty"`
  ```
  </details>
- **拓扑 levels 的不可变性/唯一性 CEL 规则从"整个 level 对象"收窄到"仅 nodeLabel 维度"**,以便别名可编辑。旧规则 `self == oldSelf`(整体不可变)+ `size(...j == i...)`(整体去重);新规则改为 `self.map(l, l.nodeLabel) == oldSelf.map(l, l.nodeLabel)`(只锁 nodeLabel 结构)+ 按 `j.nodeLabel == i.nodeLabel` 去重。
  <details><summary>代码依据 pkg/apis/kai/v1alpha1/topology_types.go</summary>

  ```diff
  -	// +kubebuilder:validation:XValidation:rule="self == oldSelf",message="field is immutable"
  -	// +kubebuilder:validation:XValidation:rule="size(self.filter(i, size(self.filter(j, j == i)) > 1)) == 0",message="must be unique"
  +	// +kubebuilder:validation:XValidation:rule="self.map(l, l.nodeLabel) == oldSelf.map(l, l.nodeLabel)",message="nodeLabel structure is immutable; only aliases may be edited"
  +	// +kubebuilder:validation:XValidation:rule="size(self.filter(i, size(self.filter(j, j.nodeLabel == i.nodeLabel)) > 1)) == 0",message="nodeLabel must be unique"
  ```
  </details>
- **别名解析下沉到快照构建期,消费侧只读规范 label**。新增 `TopologyConstraintInfo.ResolveAliases` 把约束里的 RequiredLevel/PreferredLevel 按 alias→nodeLabel 表改写,并清空缓存签名以按规范 level 重算;`PodGroupInfo.ResolveTopologyAliases` 递归遍历所有 subgroup/podset 一次性解析。设计意图明确:在源头解析,下游(topology plugin、solver)永不需自己处理别名。
  <details><summary>代码依据 pkg/scheduler/api/topology_info/topology_info.go + podgroup_info/job_info.go</summary>

  ```diff
  +func (tc *TopologyConstraintInfo) ResolveAliases(aliases map[string]string) {
  +	if tc == nil || len(aliases) == 0 { return }
  +	tc.RequiredLevel = resolveAlias(aliases, tc.RequiredLevel)
  +	tc.PreferredLevel = resolveAlias(aliases, tc.PreferredLevel)
  +	tc.schedulingConstraintsSignature = ""   // 清缓存,按规范 level 重算
  +}
  +// PodGroupInfo.ResolveTopologyAliases: snapshot 构建时递归 subgroup/podset 一次解析
  ```
  </details>
- **NUMA 放置从"仅内存态"升级为"持久化到 BindRequest"**。BindRequestSpec 新增 `PredictedNUMAZones []NUMAZonePlacement`,元素为 `{zone string, amount ResourceList}`,记录调度器在选定节点上预测的 per-zone NUMA 放置;CRD 同步加该数组字段(带 int-or-string 量校验)。配套 `NumaTopology.ZoneID(index)` 做"内部 index 表示 ↔ 持久化 zone id"的边界翻译。注释点明序列化到 `kai.scheduler/numa-placement-observed` / `-predicted` 注解。
  <details><summary>代码依据 pkg/apis/scheduling/v1alpha2/bindrequest_types.go + node_info/numa_topology.go</summary>

  ```diff
  +	// PredictedNUMAZones is the scheduler's predicted NUMA placement of the pod's resources on the
  +	// selected node.
  +	PredictedNUMAZones []NUMAZonePlacement `json:"predictedNUMAZones,omitempty"`
  ...
  +// ZoneID returns the durable id of the zone at the given index — internal index → 持久化 id 翻译
  +func (t *NumaTopology) ZoneID(index int) (string, bool) {
  +	if index < 0 || index >= len(t.Zones) { return "", false }
  +	return t.Zones[index].ID, true
  +}
  ```
  </details>
- 其余三条随 commit 标题带过(patch 节选未覆盖其 hunk,不做符号级断言):`fix(scheduler): exit on 401 Unauthorized`(API 返 401 时直接退出,避免带失效凭证空转)、`feat(podgrouper): pytorch/lws 插件校验 workerindex>0 并对 block 级分段大小设上限`、`feat(chart): 支持 ArgoCD/GitOps 部署`(新增 gitops e2e 套件与 argocd 渲染)。

### 后续发展方向 [AI]
- **拓扑亲和的产品化易用性在补齐**:别名机制是把"运维定义的物理拓扑(裸 node label)"与"用户表达的调度意图"解耦的一步——用户写 `block`/`rack` 这类别名而非 `topology.kai/xxx` 长键。证据只覆盖 CRD 字段+解析路径,webhook 具体校验逻辑(`topology_validator.go`,+83 行)未读 hunk,唯一性/冲突判定细节待后续确认。
- **NUMA 放置正从"调度期临时决策"走向"可持久化、可复算的契约"**:predicted 与 observed 双注解并存,意味着后续可能做"预测 vs 实际"偏差校正或重调度依据。证据只见字段与 ZoneID 翻译函数,消费预测值的 numa plugin/bind 侧逻辑(seed_placements.go 等)本次未读 hunk,尚不能断言闭环已成。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓</summary>

- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7b38b13887ac4054d2f958d9e178d25f6b72ef8a branch=main release=v26.3.3 scanned=2026-07-06 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=69c285d7fd8f23e2a45bf64efe71e1bdaa61c1de branch=main release=v1.19.1 scanned=2026-07-06 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=102ce377e0478c58cb3927c28cfda685c6bd3425 branch=main release=— scanned=2026-07-06 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-06 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=884f41fdd20204ae2f194ba9a94cce4b4200110b branch=main release=v0.4.1 scanned=2026-07-06 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-06 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=944764a9e9685d82279eb2d1ee216b7b2451e213 branch=main release=v0.14.3 scanned=2026-07-06 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=1ce0bd236c324fba10731ed5268faff351addc2e branch=main release=v0.16.2 scanned=2026-07-06 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-07-06 -->
