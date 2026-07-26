# NVIDIA 算力栈 diff 雷达 2026-07-27

## 摘要
- KAI-Scheduler NUMA 插件落地 **v2 拓扑感知打分**:插件从"只做可行性预判(predicate)"扩展到 `AddNodeOrderFn` 节点打分——按"任务能对齐到的最少 NUMA 区数"排序,并首次覆盖 `best-effort` 策略(kubelet 不拒但会静默跑非对齐,靠打分把 pod 导向能真正对齐的节点);同时把 GPU 共享等既有打分档全体 ×10、在最低位新插 `Numa=100` 档。
- 同仓修复分段弹性 PyTorchJob 未遵守 `minReplicas`:超出 `workerMinAvailable` 的 worker 段现标记为弹性(`MinAvailable=0`),不再因凑不齐全部 worker 而卡调度。
- 其余 8 仓(gpu-operator / nvidia-container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)无新提交,保锚点。

## 当日重要改变
- KAI-Scheduler [新能力] NUMA 插件新增节点打分(v2),`best-effort` 首次纳入拓扑优化;打分档权重重排(新增 Numa 档、其余全体 ×10) https://github.com/kai-scheduler/KAI-Scheduler/pull/1965
- KAI-Scheduler [修复] 分段弹性 PyTorchJob 现遵守 minReplicas,超额 worker 段转弹性不阻塞调度 https://github.com/kai-scheduler/KAI-Scheduler/pull/1971

## kai-scheduler/KAI-Scheduler: a4bee801 -> 4ca07f4c
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/a4bee801c06a32d213993b45f45e5ec4c8345809...4ca07f4c0f80333e020f671629ce8a4e2c150e8d | ahead=2 | Release: v0.16.6

### AI 总结重点(源码 diff 为据)

- **NUMA 插件从纯 predicate 升级为参与节点打分**:`OnSessionOpen` 新注册 `AddNodePreOrderFn(pp.nodePreOrder)` 与 `AddNodeOrderFn(pp.nodeScore)`,即插件除原有的 `PrePredicate/Predicate/Placement` 外,现在还给每个候选节点打分。`numaPlugin` 结构体新增两个字段:`maxZones int`(全集群单节点最大 NUMA 区数,无 NRT 节点的假定跨度,为 0 时禁用打分)与 `awareDeviceIndices sets.Set[int]`(被打分节点上按区拆分的设备资源索引并集,驱动 `wantsNuma` 判定)。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/numa.go</summary>

  ```diff
  +	// maxZones is the largest per-node NUMA-zone count in the cluster; the assumed span for a node
  +	// with no NRT. Zero when no node reports topology, disabling scoring.
  +	maxZones int
  +	// awareDeviceIndices is the union, over scored nodes, of the shared-map indices of per-zone
  +	// device resources (non cpu/memory/hugepages, minus ignoreList); drives wantsNuma.
  +	awareDeviceIndices sets.Set[int]
  ...
  +	ssn.AddNodePreOrderFn(pp.nodePreOrder)
  +	ssn.AddNodeOrderFn(pp.nodeScore)
  ```
  </details>

- **判定口径从"modeled policy"放宽到"scored policy"**:`initCaches` 遍历节点的过滤条件由"topo 为空或非 modeled 策略就跳过"改为"topo 为空才跳过;先累计 maxZones;再对非 scored 策略 continue;仅 modeled 策略才置 `hasModeledNodes`"。`reconstruct.go` 里重算按区可用量的门槛同步从 `isModeledPolicy` 换成 `isScoredPolicy`。含义:打分覆盖面比原可行性判定更广(纳入 best-effort),而 modeled 专属逻辑(如 predicate 硬过滤)仍只对 modeled 生效。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/numa.go</summary>

  ```diff
  -		if topo == nil || !isModeledPolicy(topo.Policy) {
  +		if topo == nil {
   			continue
   		}
  -		pp.hasModeledNodes = true
  +		if len(topo.Zones) > pp.maxZones {
  +			pp.maxZones = len(topo.Zones)
  +		}
  +		if !isScoredPolicy(topo.Policy) {
  +			continue
  +		}
  +		if isModeledPolicy(topo.Policy) {
  +			pp.hasModeledNodes = true
  +		}
  ```
  </details>

- **evaluator 新增 best-effort 求解路径,并把"是否该处理该节点"的门控从 `solveTask` 抽到调用方**:`feasibleMask` 的 `if 单区策略…else 用 restricted` 改为三分支 `switch`——`SingleNUMANode` 用 `singleNUMAEvaluator`、新增 `BestEffort` 用 `bestEffortEvaluator`、其余走 `restricted`。`allocatable/evaluate` 各自在入口用 `shouldFilter/shouldScore` 门控(node 为空或不需过滤/打分即透传 true),`solveTask` 因此不再自带 `shouldHandle` 短路,成为"调用方已 gate 过"的纯求解器。新增 `stackAware = 16` 与既有 `stackZones = 16` 并列,给按设备维度的栈缓冲定界(超出退堆)。
  <details><summary>代码依据 pkg/scheduler/plugins/numa/evaluator.go</summary>

  ```diff
  -	if topo.Policy == node_info.TopologyPolicySingleNUMANode {
  +	switch topo.Policy {
  +	case node_info.TopologyPolicySingleNUMANode:
   		return singleNUMAEvaluator{}.fit(topo, aware, req, consumed, width, maskBuf)
  +	case node_info.TopologyPolicyBestEffort:
  +		return bestEffortEvaluator{}.fit(topo, aware, req, consumed, width, maskBuf)
  +	default:
  +		return restrictedEvaluator{}.fit(topo, aware, req, consumed, width, maskBuf)
   	}
  ```
  </details>

- **打分档权重重排:新增最低位 `Numa=100`,其余档全体 ×10**:`scores/scores.go` 的常量表在 `Availability` 之下插入 `Numa=100`,并把 `Availability`(100→1000)、`GpuSharing`(1000→10000)、`Topology`(10000→100000)、`K8sPlugins`(→1000000)、`NominatedNode`(→10000000)整体上移一个数量级。含义:NUMA 打分是权重最低的偏好档(低于 Availability/GpuSharing),只在更高档打平时做 tie-break,不会盖过 GPU 共享/亲和等既有决策。
  <details><summary>代码依据 pkg/scheduler/plugins/scores/scores.go</summary>

  ```diff
  -	Availability   = 100
  -	GpuSharing     = 1000
  -	Topology       = 10000
  -	K8sPlugins     = 100000
  -	NominatedNode  = 1000000
  +	Numa           = 100
  +	Availability   = 1000
  +	GpuSharing     = 10000
  +	Topology       = 100000
  +	K8sPlugins     = 1000000
  +	NominatedNode  = 10000000
  ```
  </details>

- **设计文档改写 v2 语义:核心是 `best-effort` 引流 + "沉底不可行节点让 predicate 短路"**。打分统一走 `alignmentSpan(task, node) → (zones int, aligned bool)`:`aligned=false` 沉到最差分,aligned 节点里 zones 越少分越高。对 `single-numa-node`/`restricted` 两个会拒的策略,`aligned` 与 predicate 同一个 bit,打分只重排漏斗顺序让 `FittingNode` 先命中可行节点、跳过不可行的;对 `best-effort`(kubelet 从不拒)则用"贪心最窄能覆盖请求的区掩码"算跨度,全 N 区都盖不住时 `aligned=false`(仍可选,最差但有限分)。明确 **v2 不含 NUMA 距离感知**(只数区数,不吃 `Zone.Costs`)。
  <details><summary>代码依据 docs/developer/designs/numa-topology/README.md</summary>

  ```diff
  +| Policy | `alignmentSpan` when aligned | `aligned=false` when | Predicate outcome |
  +| `single-numa-node` | `1` | no single zone fits by `Available` | rejects (filtered) |
  +| `restricted` | the forced preferred width `w` | preferred widths disagree, or no width-`w` mask fits | rejects (filtered) |
  +| `best-effort` | greedy narrowest zone mask that fits by `Available` (width = span) | even all N zones can't cover the request (pod runs unaligned) | passes (best-effort never rejects) |
  ```
  </details>

- **分段弹性 PyTorchJob 遵守 minReplicas**:`buildWorkerSubGroups` 新增 `mandatorySegments = ceil(workerMinAvailable / segmentSize)`,首 pod 索引落在 `workerMinAvailable` 内的段为强制段、其余为弹性段——弹性段直接置 `MinAvailable=0`,不再阻塞调度(原逻辑只对最后一个不整除段设 `partialSegmentSize`)。
  <details><summary>代码依据 pkg/podgrouper/podgrouper/plugins/kubeflow/pytorch/pytorch_grouper.go</summary>

  ```diff
  +	// Segments whose first pod index is within workerMinAvailable are mandatory;
  +	// the rest are elastic and must not block scheduling.
  +	mandatorySegments := (int(workerMinAvailable) + segmentSize - 1) / segmentSize
  ...
  -		if partialSegmentSize != 0 && i == numSegments-1 {
  +		if i >= mandatorySegments {
  +			subGroup.MinAvailable = 0
  +		} else if partialSegmentSize != 0 && i == numSegments-1 {
   			subGroup.MinAvailable = int32(partialSegmentSize)
  ```
  </details>

### 后续发展方向 [AI]
- NUMA 插件的演进路线在设计文档里已排到 v3(pod-level NUMA policy,调度器强制),v2 这批只落"可行性+跨度打分"、明确不吃 `Zone.Costs` 距离信息;下一步若做距离感知会是 v3 的独立"minimax"轴。证据只覆盖 evaluator/scores/design 三处 diff 与新注册的两个打分回调,未见 `bestEffortEvaluator.fit`、`nodeScore`、`alignmentSpan` 的完整实现体(hunk 均在截断处),best-effort 贪心掩码的具体算法待后续 PR 展开确认。
- 打分档整体 ×10 是为给 `Numa` 腾最低位、保持既有相对次序不变,属机制性重排而非策略转向;证据为常量表,未见调用方对新档权重的消费点。

## 本期无实质改动(折叠)
- NVIDIA/gpu-operator、NVIDIA/nvidia-container-toolkit、NVIDIA/gpu-driver-container、NVIDIA/k8s-device-plugin、kubernetes-sigs/dra-driver-nvidia-gpu、NVIDIA/dcgm-exporter、NVIDIA/DCGM、NVIDIA/mig-parted:均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=cb71b4755401140cf565723f945f28d875793277 branch=main release=v26.3.3 scanned=2026-07-27 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=f7cb44c51c3552a76ee62fd3c4acfc8eb1c6c148 branch=main release=v1.20.0-rc.1 scanned=2026-07-27 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0ad335fb28b96957aa3f9fdda6dfdab9040e69e9 branch=main release=— scanned=2026-07-27 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=23e25265ddba8545edb8737a04cf393a982cb9da branch=main release=v0.19.3 scanned=2026-07-27 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=b0a51e353fbabab0230639b027e02f1ab29e8cab branch=main release=v0.4.1 scanned=2026-07-27 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-27 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-27 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f484af1ba590265e0cb429ca71e3c08cb8374a5d branch=main release=v0.14.4 scanned=2026-07-27 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4ca07f4c0f80333e020f671629ce8a4e2c150e8d branch=main release=v0.16.6 scanned=2026-07-27 -->
