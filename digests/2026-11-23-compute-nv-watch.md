# NVIDIA 算力栈 diff 雷达 2026-11-23

## 摘要
- **9 仓里只有 KAI-Scheduler 有新提交(5 条)**,L1 驱动容器化(gpu-operator / container-toolkit / gpu-driver-container)、L2(k8s-device-plugin / dra-driver-nvidia-gpu)、L3(dcgm-exporter / DCGM / mig-parted)全部零新提交,HEAD 与 11-22 锚点一致。
- **KAI 新增 `nodeassignment` 调度插件(alpha,默认关闭)**:用节点标签 `kai.scheduler/assigned-queue=<queue>` 把节点"软归属"给叶子队列——本队列 Pod 得 2 倍分、未分配节点得 1 倍分、别队列的节点得 0 分。这是队列级节点亲和的第一版实现,语义是"偏好"不是"独占"。
- **两个 operator 侧可用性修复**:admission Deployment 从 `Recreate` 改成 `MaxUnavailable=0/MaxSurge=1` 的滚动更新(fail-closed webhook 升级期间不再拒 Pod 创建);`MergeAffinities` 在 affinity 为 nil 时不再提前返回,默认 podAntiAffinity 项得以生效(代价:所有未配 podAntiAffinity 的 KAI Deployment 升级时会重启一次)。

## 当日重要改变
- `kai-scheduler/KAI-Scheduler` **[新能力]** 新增顶层 package `pkg/scheduler/plugins/nodeassignment`(108 行实现 + 190 行单测 + 128 行 allocate 集成测试),并在 `pkg/scheduler/plugins/factory.go` 的 `InitDefaultPlugins()` 里注册 `nodeassignment.Name`;新增打分档位常量 `scores.NodeAssignment = 20000`。changelog 片段明确标 alpha + off by default。 https://github.com/kai-scheduler/KAI-Scheduler/commit/f828d415b3c84a2240783e5fb5b2de2cc41bbe4b https://github.com/kai-scheduler/KAI-Scheduler/issues/2465
- `kai-scheduler/KAI-Scheduler` **[行为变更·升级有重启]** `pkg/operator/operands/common/common.go` 的 `MergeAffinities` 改掉 nil 短路,使 `requireDefaultPodAntiAffinityTerm` 在 local/global affinity 均未配时也能注入默认反亲和;changelog 片段自述"Every KAI Deployment without a configured podAntiAffinity restarts once on upgrade"。 https://github.com/kai-scheduler/KAI-Scheduler/commit/b8b9334012847613cd81239958c25d2e796e79f5 https://github.com/kai-scheduler/KAI-Scheduler/issues/2527
- 其余信号类型(`[弃用/移除]` / `[API/CRD变更]` / `[架构方向]` / `[版本跨档]`)本期无命中:helper 的 API/CRD 路径探测为空;KAI releases 列表里最大 semver 仍是 **v0.19.0**(2026-11-11),helper 报的 `v0.16.18` 是旧分支 backport,不算跨档。

## kai-scheduler/KAI-Scheduler: 4c565e5e -> f828d415
- 比较: 4c565e5ed2e1543cb8d603b606833472e4e388e3 -> f828d415 | ahead=5 | files=27 | Release: v0.16.18(旧分支 backport;releases 最大 semver 仍 v0.19.0,不算跨档)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/4c565e5ed2e1543cb8d603b606833472e4e388e3...f828d415b3c84a2240783e5fb5b2de2cc41bbe4b

> 说明:helper 的 patch 节选槽位被本期大量文档改动(AGENTS.md -203 行、CONTRIBUTING.md、新增 4 篇 docs)挤占,下面的代码依据是用 compare API 按信号文件单独补拉的真实 hunk。

### AI 总结重点(源码 diff 为据)

- **新增 `nodeassignment` 插件:把"节点归属队列"做成 NodeOrder 打分,而不是硬性 taint/affinity。** `OnSessionOpen` 时 `buildOwners()` 扫一遍 `ssn.ClusterInfo.Nodes`,读节点标签 `p.labelKey`(默认常量 `DefaultLabelKey = "kai.scheduler/assigned-queue"`,可用插件参数 `labelKey` 覆盖),把 `node.Name -> QueueID` 存进 `p.owners`;**未打标签的节点不入表**(`owners` 里缺席 = unassigned)。打分函数 `score()` 三档:节点不在表里(未分配)→ `scores.NodeAssignment`;节点归属队列 == 该 Pod 所属 PodGroup 的 `job.Queue` → `2 * scores.NodeAssignment`;其余(归属别的队列,或标签非法)→ `0`。所以这是**偏好序**"自己队列的节点 > 无主节点 > 别队列的节点",别队列的节点只是最不优先,**不会被排除**。
  <details><summary>代码依据 pkg/scheduler/plugins/nodeassignment/nodeassignment.go(新增 +108)</summary>

  ```diff
  +const (
  +	Name            = "nodeassignment"
  +	DefaultLabelKey = "kai.scheduler/assigned-queue"
  +	labelKeyArg     = "labelKey"
  +
  +	// unknownQueue owns nodes whose label is invalid, so no pod is native to them.
  +	unknownQueue common_info.QueueID = ""
  +)
  +
  +func New(arguments framework.PluginArguments) framework.Plugin {
  +	labelKey := DefaultLabelKey
  +	if value, found := arguments[labelKeyArg]; found && value != "" {
  +		labelKey = value
  +	}
  +	return &nodeAssignmentPlugin{labelKey: labelKey}
  +}
  +
  +func (p *nodeAssignmentPlugin) OnSessionOpen(ssn *framework.Session) {
  +	p.ssn = ssn
  +	p.owners = p.buildOwners(ssn)
  +	ssn.AddNodeOrderFn(p.nodeOrderFn)
  +}
  +
  +func (p *nodeAssignmentPlugin) score(task *pod_info.PodInfo, node *node_info.NodeInfo) float64 {
  +	owner, assigned := p.owners[node.Name]
  +	if !assigned {
  +		return scores.NodeAssignment
  +	}
  +	job, found := p.ssn.ClusterInfo.PodGroupInfos[task.Job]
  +	if found && owner != unknownQueue && owner == job.Queue {
  +		return 2 * scores.NodeAssignment
  +	}
  +	return 0
  +}
  ```
  </details>

- **标签只认"本 shard 内的叶子队列",校验不过的节点被降级成"无人拥有"而不是报错。** `buildOwners()` 里若 `ssn.ClusterInfo.Queues[queueID]` 查不到、或 `!queue.IsLeafQueue()`,就写入 `owners[name] = unknownQueue`(空 QueueID),并收集进 `invalid` 列表,最后一条 `V(2).Warnf` 聚合告警。`unknownQueue` 在 `score()` 里被显式排除出"同队列"判定,故这类节点恒得 0 分——**比未打标签的节点还不优先**。这是个运维坑:标签写错(写成非叶子队列、或写了别 shard 的队列)不是"回退到无偏好",而是"全局最不优先"。
  <details><summary>代码依据 pkg/scheduler/plugins/nodeassignment/nodeassignment.go</summary>

  ```diff
  +		queueID := common_info.QueueID(value)
  +		if queue, found := ssn.ClusterInfo.Queues[queueID]; !found || !queue.IsLeafQueue() {
  +			owners[name] = unknownQueue
  +			invalid = append(invalid, fmt.Sprintf("%s=%s", name, value))
  +			continue
  +		}
  +		owners[name] = queueID
  +	}
  +
  +	if len(invalid) > 0 {
  +		slices.Sort(invalid)
  +		log.InfraLogger.V(2).Warnf(
  +			"%d nodes are assigned to a queue that is not a leaf queue in this shard; no queue is preferred on them: %s",
  +			len(invalid), strings.Join(invalid, ", "))
  +	}
  ```
  </details>

- **新档位 `NodeAssignment = 20000` 插在 `GpuSharing`(10000)与 `Topology`(100000)之间**,这是硬编码的优先级天花板语义:队列节点归属**压过** GPU 共享打包偏好,但**让位于**拓扑感知放置与 K8s 原生插件分(`K8sPlugins = 1000000`)、预留节点(`NominatedNode = 10000000`)。
  <details><summary>代码依据 pkg/scheduler/plugins/scores/scores.go(+1)</summary>

  ```diff
   	Numa           = 100
   	Availability   = 1000
   	GpuSharing     = 10000
  +	NodeAssignment = 20000
   	Topology       = 100000
   	K8sPlugins     = 1000000
   	NominatedNode  = 10000000
  ```
  </details>

- **注册 ≠ 开启。** `factory.go` 只在 `InitDefaultPlugins()` 里加了一行 `RegisterPluginBuilder(nodeassignment.Name, nodeassignment.New)`;本期**没有**改 shard 的默认插件清单(按新增的 `pkg/scheduler/README.md` 自述,默认插件及优先级定义在外部 api 模块 `github.com/kai-scheduler/api` 的 `schedulingshard_types.go`,不在本仓)。changelog 片段也写明 "off by default"。要用必须显式加进 SchedulingShard 的 plugin 列表。
  <details><summary>代码依据 pkg/scheduler/plugins/factory.go(+2)/ .changes/unreleased/Added-20261111-212928.yaml</summary>

  ```diff
  + 	"github.com/kai-scheduler/KAI-scheduler/pkg/scheduler/plugins/nodeassignment"
   ...
   	framework.RegisterPluginBuilder("topology", topology.New)
  +	framework.RegisterPluginBuilder(nodeassignment.Name, nodeassignment.New)
  ```
  ```diff
  +kind: Added
  +body: |-
  +  Alpha `nodeassignment` scheduler plugin (off by default): nodes labeled `kai.scheduler/assigned-queue=<queue>` are preferred by that queue's pods and avoided by other queues' pods
  ```
  </details>

- **admission Deployment 升级策略从 `Recreate` 换成零不可用滚动更新,原因是 Pod webhook fail-closed。** `deploymentForKAIConfig()` 原来显式把 `Strategy.Type` 设成 `RecreateDeploymentStrategyType` 并清空 `RollingUpdate`;现在整体替换成 `RollingUpdate` + `MaxUnavailable=0` / `MaxSurge=1`,注释点明"新 Pod 必须先就绪,旧 Pod 才能停"。此前的 Recreate 会出现 webhook 无后端的窗口,fail-closed 下**整集群 Pod 创建被拒**。
  <details><summary>代码依据 pkg/operator/operands/admission/resources.go(+10/-?)</summary>

  ```diff
  -	deployment.Spec.Strategy.Type = appsv1.RecreateDeploymentStrategyType
  -	deployment.Spec.Strategy.RollingUpdate = nil
  +	// The pod webhooks fail closed, so a new pod must be serving before an old one stops.
  +	deployment.Spec.Strategy = appsv1.DeploymentStrategy{
  +		Type: appsv1.RollingUpdateDeploymentStrategyType,
  +		RollingUpdate: &appsv1.RollingUpdateDeployment{
  +			MaxUnavailable: ptr.To(intstr.FromInt32(0)),
  +			MaxSurge:       ptr.To(intstr.FromInt32(1)),
  +		},
  +	}
  ```
  </details>

- **`MergeAffinities` 去掉 nil 短路,默认反亲和项不再被"未配 affinity"吞掉。** 原实现中 `localAffinity == nil` 直接 `return globalAffinity`、`globalAffinity == nil` 直接 `return localAffinity`,两条早退路径都绕过了后续注入 `requireDefaultPodAntiAffinityTerm` 的逻辑;改成把 nil 规整成 `&v1.Affinity{}` 继续走合并。效果是 chart 默认的 podAntiAffinity 终于对"没写 affinity 的组件"生效(`common_test.go` 同步改了 140 行覆盖),代价写在 changelog 里:**未配 podAntiAffinity 的每个 KAI Deployment 升级时会重启一次**。
  <details><summary>代码依据 pkg/operator/operands/common/common.go(+5/-?)</summary>

  ```diff
   	requireDefaultPodAntiAffinityTerm bool) *v1.Affinity {
  +	// Unset affinities are merged as empty ones so the default podAntiAffinity term is still added.
   	if localAffinity == nil {
  -		return globalAffinity
  +		localAffinity = &v1.Affinity{}
   	}
   
   	if globalAffinity == nil {
  -		return localAffinity
  +		globalAffinity = &v1.Affinity{}
   	}
  ```
  </details>

- **仓库工程规范大幅重写(非功能,但透露内部约束)**:`AGENTS.md` 从 209 行砍到 39 行,改为"scoped agent guidance",新增 `docs/contributing/{ISSUES,PR}.md`、`docs/developer/operator.md`、`pkg/scheduler/README.md`、`test/README.md`,并新增 `.claude/skills` 条目。其中 `pkg/scheduler/README.md` 把热路径约束写死:`plugins/`、`actions/`、`api/` 每个 Pod 每轮都跑,`V(5+)` 日志必须用 `.Do(...)` 包,改分配密集代码要跑 `make benchmark`。`CONTRIBUTING.md` 同时记录 **in-tree 的 `pkg/apis`、`pkg/common/{constants,podgroup}` 副本已被删除**(此前写的是"将被删除")——API 完全外迁到 `github.com/kai-scheduler/api` 这一步已经落地(该删除动作本体不在本区间 diff 内,仅据文档措辞变化)。
  <details><summary>代码依据 CONTRIBUTING.md / pkg/scheduler/README.md(新增 +25)</summary>

  ```diff
  -Do not edit the old in-tree copies under `pkg/apis/{scheduling,kai/v1alpha1,client}` and `pkg/common/{constants,resources,podgroup}`. Most code no longer imports them, so changes there usually have no effect, and they will be removed.
  +The in-tree copies under `pkg/apis` and `pkg/common/{constants,podgroup}` have been removed.
  ```
  ```diff
  +Hot path: code under `plugins/`, `actions/` and `api/` runs for every pod in every scheduling cycle.
  +- Guard V(5+) logs with `.Do(...)`. Do not build strings, slices or maps outside the guard.
  +- Run `make benchmark` (or `go test -bench` in `actions/`) when touching allocation-heavy code.
  ```
  </details>

### 后续发展方向 [AI]
- **KAI 在补"队列↔节点池"的软绑定能力,但刻意停在"偏好"而非"独占"。** 从 `score()` 的三档返回值看,设计上允许借用(别队列节点得 0 分但仍可被选中),这与 KAI 既有的 quota/reclaim 模型一致——节点归属是放置偏好,资源归属仍由 queue quota 管。对我们产品的启示:做"部门专属 GPU 节点池"时,KAI 这条路线用一个节点标签 + 一个打分插件就覆盖了 80% 诉求,不必引入 node taint + toleration 注入那套更重的机制;但要独占就必须另配 taint,KAI 本期没给。证据只覆盖 nodeassignment 包与 scores 常量,**未见** reclaim/preempt 动作是否感知节点归属(跨队列抢占时会不会优先回收"自己节点上的"外来 Pod),这是下一个值得盯的点。
- **`unknownQueue` 恒 0 分是个会咬人的默认值。** 多 shard 部署时,A shard 的 scheduler 看不到 B shard 的队列,于是"属于 B 队列的节点"在 A shard 眼里全是 invalid → 对 A 的所有 Pod 都是最低优先级。这在效果上近似实现了 shard 间节点隔离,但是靠副作用而非显式设计,且只有一条 V(2) 警告。证据为 `buildOwners()` + `score()` 两段 hunk,**未见** 文档或 CRD 层面对多 shard 场景的说明。
- **operator 侧两个修复指向同一个主题:KAI 开始认真处理"在线升级不中断"。** fail-closed webhook 的 Recreate→RollingUpdate(MaxUnavailable=0)是典型的企业级可用性补课;而 affinity 修复为了正确性接受了"全组件重启一次"的一次性代价。两者都发生在 `pkg/operator`,说明 KAI 的 operator 已经进入"存量集群平滑升级"阶段而非功能堆叠阶段。证据覆盖 admission/common 两个 operand 文件,**未见** scheduler/binder 自身是否也有对应的滚动策略约束。
- **L1/L2/L3 连续静默。** gpu-operator 自 11-22 的 595.91.07→620.70.06 驱动跨档后零提交,DRA 驱动在 LocalIPC alpha gate 合入后也零提交——这两条主线都刚落大改动,进入消化期。本期无新证据,仅记静默。

<details>
<summary>## 本期无实质改动(8 仓)</summary>

- NVIDIA/gpu-operator:无新提交(HEAD 仍 d338c6bd,Release v26.7.3)
- NVIDIA/nvidia-container-toolkit:无新提交(HEAD 仍 d8041cb6,Release v1.20.2)
- NVIDIA/gpu-driver-container:无新提交(HEAD 仍 6be32fc9)
- NVIDIA/k8s-device-plugin:无新提交(HEAD 仍 057b54be,Release v0.20.2)
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(HEAD 仍 44cf296c,Release v0.5.1)
- NVIDIA/dcgm-exporter:无新提交(HEAD 仍 4e663a52,Release 4.9.0)
- NVIDIA/DCGM:无新提交(HEAD 仍 9fae2867,master 分支)
- NVIDIA/mig-parted:无新提交(HEAD 仍 9e415433,Release v0.15.2)

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=d338c6bd60db03ef29db86f5ef411b0dca35a85b branch=main release=v26.7.3 scanned=2026-11-23 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d8041cb623e601ebc085e2198725d2ce8277ab5a branch=main release=v1.20.2 scanned=2026-11-23 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=6be32fc94f4599b2cfc35f113a170607980cdd03 branch=main release=— scanned=2026-11-23 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=057b54be3946886765dc2700ce1ab80ce6bcf4ba branch=main release=v0.20.2 scanned=2026-11-23 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=44cf296cdfb787ec2155a5ffae11763cb7e92c7e branch=main release=v0.5.1 scanned=2026-11-23 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-23 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-23 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9e4154330f5124ee62bf8f724892f6dcfa1a7145 branch=main release=v0.15.2 scanned=2026-11-23 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=f828d415b3c84a2240783e5fb5b2de2cc41bbe4b branch=main release=v0.16.18 scanned=2026-11-23 -->
