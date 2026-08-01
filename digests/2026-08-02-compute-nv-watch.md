# NVIDIA 算力栈 diff 雷达 2026-08-02

## 摘要
- **gpu-operator DRA driver 落地 GPU 直通(PassthroughSupport)支持**:`state-dra-driver` daemonset 新增受 `PassthroughSupport` feature gate 门控的 `/lib/modules`、`/sys`、`/proc` 三个 host 挂载(+ 相应 hostPath volume),供 go-nvlib 的 `nvpassthrough` 包探测该给 GPU 用哪种 vfio-pci 驱动变体;同批加 `HOST_ROOT=/host` env。这是 DRA 栈从"共享/切分"往"整卡 VFIO 直通给 VM/容器"扩能力的信号。配套把 `FEATURE_GATES` 的渲染从 Go 预渲染字符串改成模板函数 `convertStringMapToCommaSeparatedString`(feature gate 现以 `map[string]bool` 一路传到模板),并让 node-labeling controller 监听单例 CR 的 **create** 事件(此前只认 generation 变更,新建 CR 要等下一次 update 才打标)。
- **KAI-Scheduler 抛出「队列准入门控(queue-admission-gating)」设计提案**:用 K8s scheduling gate(`kai.scheduler/queue-admission`)把配额受阻的 pod 挡在调度前,让它们对 Karpenter/CA 等 autoscaler 不可见(不写 `Unschedulable`),避免为永远不会被准入的 GPU 负载错误扩容;并把全 gated 的 podgroup 从 allocate/preempt/reclaim 的输入里剔掉降低 session 开销。机制:mutating webhook 只"傻"打 gate 不算配额,新增 `ungate` scheduler action 每 session 末按配额 oracle 贪心放行,pending 未分配需求计入 `Reserved` 桶防超发。对标 Volcano/Kueue 已有的"配额阻塞 pod 不暴露给 autoscaler"。同批把 `GlobalConfig.PriorityClassName` 提成 CRD 字段,给 KAI 控制面 pod 统一挂 PriorityClass。
- **dra-driver-nvidia-gpu 修单节点 NVLink 系统 fabric 误报崩溃**:compute-domain kubelet-plugin 在 `FabricManagerPartitioning` feature gate 开启且检测到本机是单节点 NVLink(有 NVSwitch)系统时,对未完成的 NVLink fabric 注册状态从"拒绝启动"改成"忽略并 fallback 无 clique"——因 FabricManager 多租户分区模式下 GPU 要等分区激活才注册。
- container-toolkit / gpu-driver-container / k8s-device-plugin / dcgm-exporter / DCGM / mig-parted 六仓本期无新提交。

## 当日重要改变
- **NVIDIA/gpu-operator** [新能力] DRA driver daemonset 引入 `PassthroughSupport` feature gate:开启时给 kubelet-plugin 容器加 `/lib/modules`(ro)、`/sys`、`/proc`(Bidirectional)挂载与 hostPath volume,注释指明供 `github.com/NVIDIA/go-nvlib/pkg/nvpassthrough` 探测 vfio-pci 驱动变体;新增 `HOST_ROOT=/host` env。`manifests/state-dra-driver/0500_daemonset.yaml`(+32/-2) https://github.com/NVIDIA/gpu-operator/compare/fd8f324ca2f61b54842b50cb29075550e153c2e7...14ca11b974fe3f4bb71df8741b31dc027193fee4
- **NVIDIA/gpu-operator** [行为变更] node-labeling controller 改用 `singletonCRPredicate` 监听 ClusterPolicy/GPUCluster 的 create/delete/spec-change,替换原 `TypedGenerationChangedPredicate`(不触发 create);operator 启动后新建的 CR 现在立即触发给 GPU 节点打标,不再等下一次 update。`controllers/nodelabeling_controller.go`(+23/-2) https://github.com/NVIDIA/gpu-operator/compare/fd8f324ca2f61b54842b50cb29075550e153c2e7...14ca11b974fe3f4bb71df8741b31dc027193fee4
- **kai-scheduler/KAI-Scheduler** [架构方向] 新增设计提案 `docs/developer/designs/queue-admission-gating/README.md`(Proposed):用 scheduling gate 让配额受阻 pod 对 autoscaler 隐身 + `ungate` 新 action 每 session 末按配额放行,引入 `Reserved` 桶防超发,新增 `QueueSpec.AdmissionGating` 与 `global.queueAdmissionGating` 开关。https://github.com/kai-scheduler/KAI-Scheduler/compare/b8730e3499435a046ae9ddf879dd46131cd1aaed...ada8bf545b60860da9e2c03595d39d4ad222ba0c
- **kai-scheduler/KAI-Scheduler** [API/CRD变更] `GlobalConfig` 新增 `PriorityClassName *string` 字段(CRD `kai.scheduler_configs.yaml` 同步),operand 把它写进所有控制面 Deployment/DaemonSet 的 `spec.priorityClassName`。`pkg/apis/kai/v1/global.go`(+6) https://github.com/kai-scheduler/KAI-Scheduler/compare/b8730e3499435a046ae9ddf879dd46131cd1aaed...ada8bf545b60860da9e2c03595d39d4ad222ba0c
- **kubernetes-sigs/dra-driver-nvidia-gpu** [健壮性/多租户] compute-domain kubelet-plugin 在 `FabricManagerPartitioning` 开启且本机单节点 NVLink 系统时,忽略未完成的 NVLink fabric 注册而非拒绝启动(fabric 分区未激活场景)。`cmd/compute-domain-kubelet-plugin/nvlib.go`(+38/-6) https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/50e0e3568f633d87266e3aabf8afa510843d6c7d...a7e5ba36376efcaebac3d8b273523e756996d516

## NVIDIA/gpu-operator: fd8f324c -> 14ca11b9
- 比较: fd8f324ca2f61b54842b50cb29075550e153c2e7 -> 14ca11b9 | ahead=6 | files=11 | Release: v26.3.3
- https://github.com/NVIDIA/gpu-operator/compare/fd8f324ca2f61b54842b50cb29075550e153c2e7...14ca11b974fe3f4bb71df8741b31dc027193fee4

### AI 总结重点(源码 diff 为据)
- **DRA driver 增 `PassthroughSupport` feature gate,开启即给 kubelet-plugin 容器注入 host 内核态挂载,为 GPU VFIO 直通做准备**。`0500_daemonset.yaml` 在 GPUs kubelet-plugin 容器与 pod 卷两处新增受 `and (index .FeatureGates "PassthroughSupport") .FeatureGates.PassthroughSupport` 门控的块:挂 `/lib/modules`(readOnly)、`/sys`(Bidirectional)、`/proc`(Bidirectional),并配 hostPath volume;注释明确"供 go-nvlib 的 nvpassthrough 包探测该 GPU 用哪种 vfio-pci 驱动变体"。同时给容器加 `HOST_ROOT=/host`。这不是软切分,是把整卡从 host 解绑交给 vfio-pci 做直通的能力入口。
  <details><summary>代码依据 manifests/state-dra-driver/0500_daemonset.yaml</summary>

  ```diff
  +        - name: HOST_ROOT
  +          value: "/host"
  ...
  +        {{- if and .FeatureGates (and (index .FeatureGates "PassthroughSupport") .FeatureGates.PassthroughSupport) }}
  +        - name: lib-modules
  +          mountPath: /lib/modules/
  +          mountPropagation: HostToContainer
  +          readOnly: true
  +        - name: sysfs
  +          mountPath: /sys/
  +          mountPropagation: Bidirectional
  +        - name: procfs
  +          mountPath: /proc/
  +          mountPropagation: Bidirectional
  +        {{- end }}
  ...
  +      # This is needed by `https://github.com/NVIDIA/go-nvlib/pkg/nvpassthrough` pkg
  +      # to detect the vfio-pci driver variant to use with a GPU.
  +      - name: lib-modules
  +        hostPath:
  +          path: /lib/modules/
  +          type: Directory
  ```
  </details>
- **feature-gate 渲染从 Go 预渲染字符串重构为模板函数,map 一路传到模板**。删掉 `dra_driver.go` 里的 `renderDRAFeatureGates()`(原在 Go 侧把 `map[string]bool` 排序拼成 `Key=Value,...` 字符串),改为在 `dra_driver.go` 直接把 `cr.Spec.DRADriver.FeatureGates`(map)塞进 render data;`types.go` 的 `draDriverRenderData.FeatureGates` 字段类型从 `string` 改回 `map[string]bool`;新逻辑落到 `render.go` 新增的模板函数 `convertStringMapToCommaSeparatedString`(同样排序拼 `key=value`),三处 manifest 的 `FEATURE_GATES` env 从 `{{ .FeatureGates | quote }}` 改成 `{{ convertStringMapToCommaSeparatedString .FeatureGates | quote }}`。行为等价(排序保证 reconcile 不churn),纯为让模板里能按 key 判断某个 gate 是否开(如上面的 PassthroughSupport 条件),这是引入 gate 门控挂载的前置改造。
  <details><summary>代码依据 internal/state/dra_driver.go(-20) / internal/render/render.go(+19)</summary>

  ```diff
  # dra_driver.go
  -		FeatureGates:          renderDRAFeatureGates(cr.Spec.DRADriver.FeatureGates),
  +		FeatureGates:          cr.Spec.DRADriver.FeatureGates,
  -func renderDRAFeatureGates(gates map[string]bool) string { ... 整函数删除 ... }
  # render.go
  +		"convertStringMapToCommaSeparatedString": convertStringMapToCommaSeparatedString,
  +func convertStringMapToCommaSeparatedString(m map[string]bool) string {
  +	keys := ... sort.Strings(keys) ...
  +	pairs = append(pairs, fmt.Sprintf("%s=%t", k, m[k]))
  +	return strings.Join(pairs, ",")
  +}
  ```
  </details>
- **node-labeling controller 现在对单例 CR 的 create 事件也触发 reconcile**。新增泛型 `singletonCRPredicate[T]()`,`CreateFunc`/`DeleteFunc` 恒返回 true、`UpdateFunc` 只在 generation 变更时触发;`SetupWithManager` 把 ClusterPolicy 与 GPUCluster 两个 watch 的谓词从 `TypedGenerationChangedPredicate`(不 fire create)换成它。效果:operator 启动后再创建 CR,GPU 节点会立即被打标,无需等一次后续 update——修的是"CR 后建则节点迟迟不打标"的时序缺口。
  <details><summary>代码依据 controllers/nodelabeling_controller.go</summary>

  ```diff
  +func singletonCRPredicate[T interface{ client.Object; GetGeneration() int64 }]() predicate.TypedFuncs[T] {
  +	return predicate.TypedFuncs[T]{
  +		CreateFunc: func(e event.TypedCreateEvent[T]) bool { return true },
  +		UpdateFunc: func(e event.TypedUpdateEvent[T]) bool { return e.ObjectNew.GetGeneration() != e.ObjectOld.GetGeneration() },
  +		DeleteFunc: func(e event.TypedDeleteEvent[T]) bool { return true },
  +	}
  +}
  -		predicate.TypedGenerationChangedPredicate[*gpuv1.ClusterPolicy]{},
  +		singletonCRPredicate[*gpuv1.ClusterPolicy](),
  ```
  </details>

### 后续发展方向 [AI]
- gpu-operator 的 DRA 栈本期从"共享/切分"向"整卡 VFIO 直通"扩边界:`PassthroughSupport` gate + go-nvlib nvpassthrough 探测 vfio-pci,是把 GPU 从 host 内核解绑直通给 VM/受限容器的地基。这与近几日观察到的"DRA 栈作为一等公民硬化"是同一条线,但方向从"给容器分片"拓到"整卡直通",指向 KubeVirt / 机密计算类场景。证据只覆盖 daemonset 的挂载/env 与 feature-gate 渲染改造,未见 nvpassthrough 的实际 vfio 绑定逻辑(在 dra-driver 侧,本仓只是 operator 编排),该 gate 的默认值与 CRD 暴露方式也未在本 diff 出现。node-labeling 的 create 谓词修复属稳定性收尾,非方向性改动。

## kubernetes-sigs/dra-driver-nvidia-gpu: 50e0e356 -> a7e5ba36
- 比较: 50e0e3568f633d87266e3aabf8afa510843d6c7d -> a7e5ba36 | ahead=2 | files=1 | Release: v0.4.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/50e0e3568f633d87266e3aabf8afa510843d6c7d...a7e5ba36376efcaebac3d8b273523e756996d516

### AI 总结重点(源码 diff 为据)
- **compute-domain kubelet-plugin 在 FabricManager 分区模式下不再因单节点 NVLink 系统的未完成 fabric 注册而拒绝启动**。`deviceLib` 新增 `isSingleNodeNVLinkSystem` 字段;`newDeviceLib` 在 `FabricManagerPartitioning` gate 开启时调新增的 `checkIsSingleNodeNVLinkSystem()`(经 `pkg/fabricmanager.HasFabricManagerFabric(devRoot)` 判断本机是否有本地 fabric / NVSwitch)。`getCliqueIDStrict()` 原逻辑:GPU fabric state 非 `GPU_FABRIC_STATE_COMPLETED` 即 `return fmt.Errorf(... refusing to start)`;新逻辑在 gate 开启且是单节点 NVLink 系统时改为 `klog.Infof("no-clique fallback ...")` 并 `return nil`。注释点明:FabricManager 多租户模式下 GPU 要等所属分区激活才注册,当前无法区分"真 NVLink 故障"与"分区未激活",故一律忽略。
  <details><summary>代码依据 cmd/compute-domain-kubelet-plugin/nvlib.go</summary>

  ```diff
  +	isSingleNodeNVLinkSystem bool
  ...
  +	if featuregates.Enabled(featuregates.FabricManagerPartitioning) {
  +		isSingleNodeNVLinkSystem, err := d.checkIsSingleNodeNVLinkSystem()
  +		...
  +		d.isSingleNodeNVLinkSystem = isSingleNodeNVLinkSystem
  +	}
  ...
  		if info.State != nvml.GPU_FABRIC_STATE_COMPLETED {
  +			if featuregates.Enabled(featuregates.FabricManagerPartitioning) && l.isSingleNodeNVLinkSystem {
  +				klog.Infof("no-clique fallback: ignoring incomplete NVLink registration ...")
  +				return nil
  +			}
  			return fmt.Errorf("NVLink fabric not attached ...: refusing to start")
  		}
  +func (l deviceLib) checkIsSingleNodeNVLinkSystem() (bool, error) {
  +	hasLocalFabric, err := fm.HasFabricManagerFabric(l.devRoot)
  +	...
  +	return hasLocalFabric, nil
  +}
  ```
  </details>

### 后续发展方向 [AI]
- `FabricManagerPartitioning` feature gate 的存在说明 compute-domain(NVLink/IMEX 域调度)正为 FabricManager 多租户分区做适配——同一 NVSwitch 系统按分区切给不同租户,GPU 注册时机随分区激活而异。本期只是把"单节点 NVLink 系统 fabric 未就绪"的崩溃兜住(fallback 无 clique),尚未见分区感知的 clique 分配正逻辑。证据仅一文件,未覆盖 `pkg/fabricmanager` 的 fabric 探测实现与该 gate 的其他消费点。

## kai-scheduler/KAI-Scheduler: b8730e34 -> ada8bf54
- 比较: b8730e3499435a046ae9ddf879dd46131cd1aaed -> ada8bf54 | ahead=2 | files=11 | Release: v0.16.8
- https://github.com/kai-scheduler/KAI-Scheduler/compare/b8730e3499435a046ae9ddf879dd46131cd1aaed...ada8bf545b60860da9e2c03595d39d4ad222ba0c

### AI 总结重点(源码 diff 为据)
- **新增「队列准入门控」设计提案(Proposed),核心是用 K8s scheduling gate 把配额受阻 pod 挡在调度前**。`docs/developer/designs/queue-admission-gating/README.md` 提出:配额只在 allocation 时强制,被队列策略挡住的 pod 仍会被创建、标 `Unschedulable` 并每 session 复查,带来两类成本——① autoscaler(Karpenter/CA)把 `Unschedulable` pod 当需求给 GPU 机型错误扩容(Volcano/Kueue 会挡,KAI 不挡);② session action 成本随提交量而非容量增长。方案:给 pod 打 `kai.scheduler/queue-admission` scheduling gate,gated pod 对 autoscaler 隐身(永不写 `Unschedulable`),且已被现有机制排除在 session readiness 外。**核心原则**:gate 只是配额裁决的缓存、绝非新强制机制,allocation 时强制仍是唯一权威;两条单向保证——安全(仅配额 oracle 肯定准入后才摘 gate)、活性(每 session 复查、可准入即摘)。
  <details><summary>代码依据 docs/developer/designs/queue-admission-gating/README.md(新增 +149)</summary>

  ```diff
  +spec:
  +  schedulingGates:
  +    - name: kai.scheduler/queue-admission
  +
  +type QueueSpec struct {
  +    // AdmissionGating enables queue-admission scheduling gates for pods in this queue.
  +    AdmissionGating *bool `json:"admissionGating,omitempty"`
  +}
  +spec:
  +  global:
  +    queueAdmissionGating:
  +      enabled: false
  ```
  </details>
- **机制拆分:mutating webhook 只"傻"打 gate,新增 `ungate` scheduler action 负责按配额放行,`Reserved` 桶防超发**。提案指定:新的 mutating-admission 插件在 pod CREATE 时给 `schedulerName: kai-scheduler` 且队列 opt-in 的 pod 追加 gate,webhook **不做任何配额计算**(准入时队列用量不可靠知);所有配额智能留在 scheduler。新增 `ungate` action 排在 action 列表最后(观察到本 session 分配/驱逐后的队列末态),每 session:收集仅带 KAI gate 的 gated podgroup → 按现有 queue/job 排序保公平 → 对配额 oracle 贪心准入(每次准入即计入模拟 queue share,N 次准入不超配额)→ 摘 gate 或记录配额原因。为防"ungate 后未 allocate 的需求被重复放行超发",把 pending ungated 需求计入 `Reserved` 桶:非抢占 `Deserved ≥ AllocatedNotPreemptible + ReservedNotPreemptible + requested`,limit `MaxAllowed ≥ Allocated + Reserved + requested`。两开关组合为"master 全局开关 + 每队列 opt-in"。
  <details><summary>代码依据 docs/developer/designs/queue-admission-gating/README.md</summary>

  ```diff
  +A new mutating-admission plugin ... appends the gate at pod CREATE ... performs no quota computation
  +A new scheduler action, appended last in the action list so it observes end-of-session queue state
  +  - non-preemptible: admissible iff Deserved ≥ AllocatedNotPreemptible + ReservedNotPreemptible + requested
  +  - limit: admissible iff MaxAllowed ≥ Allocated + Reserved + requested
  ```
  </details>
- **`GlobalConfig` 新增 `PriorityClassName` 字段,给 KAI 控制面 pod 统一挂 PriorityClass**。`pkg/apis/kai/v1/global.go` 加 `PriorityClassName *string`(optional),`SetDefaultWhereNeeded` 默认置空串;CRD `kai.scheduler_configs.yaml` 同步字段;`common.go` 的 `DeploymentForKAIConfig`/`DaemonSetForKAIConfig` 把 `ptr.Deref(Global.PriorityClassName, "")` 写进 pod spec;Helm `operator.yaml`/`_helpers.tpl` 与 `values.yaml`(默认 `""`)同步暴露 `global.priorityClassName`。让 KAI operator/service/daemonset 在资源紧张时不被优先驱逐。
  <details><summary>代码依据 pkg/apis/kai/v1/global.go / pkg/operator/operands/common/common.go</summary>

  ```diff
  +	// PriorityClassName defines the priority class for KAI operators & services.
  +	PriorityClassName *string `json:"priorityClassName,omitempty"`
  ...
  +	g.PriorityClassName = common.SetDefault(g.PriorityClassName, ptr.To(""))
  # common.go
  +	deployment.Spec.Template.Spec.PriorityClassName = ptr.Deref(kaiConfig.Spec.Global.PriorityClassName, "")
  +	ds.Spec.Template.Spec.PriorityClassName = ptr.Deref(kaiConfig.Spec.Global.PriorityClassName, "")
  ```
  </details>

### 后续发展方向 [AI]
- queue-admission-gating 把 KAI 往"配额感知的准入层"推进一步,补齐它相对 Volcano/Kueue 在 autoscaler 协同上的短板:配额阻塞 pod 不再骗 autoscaler 扩 GPU 机器,且大规模超配额提交时 session 调度开销从 O(提交量) 收敛到可调度集。设计强调 gate 只是配额缓存、fail-open 一律退化到今日行为,是稳健的增量。**注意目前只是 Proposed 文档,尚无实现代码**——`QueueSpec.AdmissionGating` 字段、`ungate` action、mutating 插件、`Reserved` 桶均未落地,证据仅覆盖提案本身与 PriorityClassName 这一独立小改动。对我们产品的启示:若自研调度器同样把配额只在 allocation 时判、把 Unschedulable pod 暴露给 CA,会踩同样的 GPU 错误扩容坑,scheduling-gate 缓存 + 独立 ungate action 是可借鉴的低侵入解法。

## 本期无实质改动(折叠)
<details>

- NVIDIA/nvidia-container-toolkit:无新提交
- NVIDIA/gpu-driver-container:无新提交
- NVIDIA/k8s-device-plugin:无新提交
- NVIDIA/dcgm-exporter:无新提交
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=14ca11b974fe3f4bb71df8741b31dc027193fee4 branch=main release=v26.3.3 scanned=2026-08-02 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=828fc6ce327ddca61d6f179a13c18ab94e0c658c branch=main release=v1.20.0-rc.1 scanned=2026-08-02 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=c08f0e543625568736a3531c207cceed44b5f2c5 branch=main release=— scanned=2026-08-02 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5f27eeeee7eb7f7a4c0581aa10abeda7e4604ed2 branch=main release=v0.19.3 scanned=2026-08-02 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=a7e5ba36376efcaebac3d8b273523e756996d516 branch=main release=v0.4.1 scanned=2026-08-02 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-02 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-02 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=589c033a8ef273613111245da67e1c6a0f78931b branch=main release=v0.14.4 scanned=2026-08-02 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=ada8bf545b60860da9e2c03595d39d4ad222ba0c branch=main release=v0.16.8 scanned=2026-08-02 -->
