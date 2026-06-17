# NVIDIA 算力栈 diff 雷达 2026-06-18

## 摘要
- **gpu-operator 启动"ClusterPolicy → NVIDIADriver"驱动管理范式迁移**:`NVIDIADriverSpec` 新增 `default bool` 字段(配 CEL 校验:default 驱动不得带 nodeSelector),新增 `internal/nvidiadriver` 的 `AssignOwners`(给每个 GPU 节点打"由哪个 NVIDIADriver 管"的 owner 标签,非默认驱动按 nodeSelector 优先、其余落到唯一的 default 兜底)与 `nvidiadriver_migration.go`(把 ClusterPolicy 遗留的孤儿 driver pod 纳入 NVIDIADriver 升级流)。驱动 DaemonSet 的真正所有权正从单一 ClusterPolicy.driver 转到多个 NVIDIADriver CR + 默认兜底模型。
- **KAI-Scheduler `numa` 调度插件本体落地**(昨日仅设计文档 + NPE exporter):新增 `pkg/scheduler/plugins/numa` 全包 + `node_info/numa_topology.go`(从 NRT CRD 解析每节点 Topology Manager policy/scope/zone,复刻 kubelet 的 none/best-effort/restricted/single-numa-node 语义)+ `pod_info/numa_placement.go`(per-zone 落位记录),并把 NUMA 落位序列化进 `numa-placement-observed`/`numa-placement-predicted` 注解;Config CRD 新增 `numaPlacementExporter` 配置块(tri-state 自动部署)。
- k8s-device-plugin 仅 v0.19.3 发版准备(版本号 0.19.2→0.19.3 全量 bump),内容里值得记一笔的是"撤销 mofed/gdrcopy 默认开启(#1837)"——但该撤销本体不在本区间可见 hunk,仅见于 CHANGELOG。其余 6 仓(container-toolkit / gpu-driver-container / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)无实质改动。

## 当日重要改变
- `NVIDIA/gpu-operator` [API/CRD变更][架构方向] `NVIDIADriverSpec` 新增 `default` 必填字段 + CEL 校验"default 驱动禁用 nodeSelector",并落地 ClusterPolicy→NVIDIADriver 迁移逻辑(节点 owner 标签分配 + 孤儿 driver pod 纳管)。证据 `api/nvidia/v1alpha1/nvidiadriver_types.go`、`internal/nvidiadriver/nvidiadriver.go`、`controllers/nvidiadriver_migration.go`、`config/crd/bases/nvidia.com_nvidiadrivers.yaml`。 https://github.com/NVIDIA/gpu-operator/compare/4a456ddf5cb48b97f8d2194cff9cc9b0530c13c5...9b198ba801ee9f1754dea0d74d85384659bea1c9
- `kai-scheduler/KAI-Scheduler` [新能力][API/CRD变更][架构方向] NUMA 拓扑感知调度从设计文档转为可运行代码:新增 `numa` 调度插件包 + NRT 解析的 `NumaTopology` + per-zone 落位模型 + 落位注解,Config CRD 新增 `numaPlacementExporter` 块。证据 `pkg/scheduler/plugins/numa/numa.go`、`pkg/scheduler/api/node_info/numa_topology.go`、`pkg/apis/scheduling/v1alpha2/numa_placement_types.go`、`deployments/kai-scheduler/crds/kai.scheduler_configs.yaml`。 https://github.com/kai-scheduler/KAI-Scheduler/compare/38951dc7b9dc31256df3759648cfdae6e0283567...5ccedbad0e37d849e0760853adbc2d0a03b44fb5
- `NVIDIA/k8s-device-plugin` [版本跨档] v0.19.2 → v0.19.3 发版准备;CHANGELOG 记载"撤销 mofed/gdrcopy 默认开启(#1837)",但撤销本体未在本区间 hunk 出现。证据 `CHANGELOG.md`。 https://github.com/NVIDIA/k8s-device-plugin/compare/3171a238ce1cce34a41ea56e087300382b0d6669...25e493580ca8d18413c7ec6a912d3bd2af2b135a

## NVIDIA/gpu-operator: 4a456ddf -> 9b198ba8
- 比较 / Release:ahead=4, files=45 | Release v26.3.2 | https://github.com/NVIDIA/gpu-operator/compare/4a456ddf5cb48b97f8d2194cff9cc9b0530c13c5...9b198ba801ee9f1754dea0d74d85384659bea1c9

### AI 总结重点(源码 diff 为据)
- **`NVIDIADriver` 新增"默认兜底驱动"语义(CRD 字段 + CEL 不变式)**:`NVIDIADriverSpec` 加 `Default bool`(必填,默认 false),CRD 同步加 `default` 到 spec、required 列表与 printcolumn,并加 `x-kubernetes-validations`:default=true 时不允许设 nodeSelector。新增 `IsDefault()`、`HasDeletionTimestamp()`、`ValidateNodeSelector()`(默认驱动带 nodeSelector 或选用保留标签 `NVIDIADriverOwnerLabel` 直接报错)。即:一个集群可有多个按 nodeSelector 命中的非默认 NVIDIADriver,外加最多一个无 selector 的"兜底"驱动管所有未命中节点。

  <details><summary>代码依据 api/nvidia/v1alpha1/nvidiadriver_types.go</summary>

  ```diff
  +// +kubebuilder:validation:XValidation:rule="has(self.default) && self.default ? !has(self.nodeSelector) || size(self.nodeSelector) == 0 : true",message="default NVIDIADriver must not use nodeSelector"
   type NVIDIADriverSpec struct {
  +	// Default indicates that this NVIDIADriver acts as the fallback driver daemon set manager for GPU nodes
  +	// that do not match any non-default NVIDIADriver nodeSelector.
  +	// +kubebuilder:default=false
  +	Default bool `json:"default"`
  +func (d *NVIDIADriver) IsDefault() bool { return d != nil && d.Spec.Default }
  +func (d *NVIDIADriver) ValidateNodeSelector() error {
  +	if d.IsDefault() && len(d.Spec.NodeSelector) > 0 {
  +		return fmt.Errorf("default NVIDIADriver %q cannot use nodeSelector", d.Name) }
  +	if _, ok := d.Spec.NodeSelector[consts.NVIDIADriverOwnerLabel]; ok {
  +		return fmt.Errorf("...nodeSelector cannot use reserved label %q", ...) }
  ```
  </details>

- **节点 owner 标签分配:谁来管这台 GPU 节点的 driver pod**:新增 `internal/nvidiadriver/nvidiadriver.go` 的 `AssignOwners`——列出全部 NVIDIADriver,按 default/非 default 分类,>1 个 default 直接 fail closed;遍历带 `GPUPresentLabel=true` 的节点算 `desiredOwnerForNode`(非默认驱动的 nodeSelector 优先,未命中则归 default owner),只在 owner 标签需变更时才写节点。这是把"驱动 DaemonSet 调度到哪些节点"从 ClusterPolicy 的隐式逻辑改成显式的 per-node owner 标签路由。

  <details><summary>代码依据 internal/nvidiadriver/nvidiadriver.go</summary>

  ```go
  // AssignOwners labels GPU nodes with the NVIDIADriver that should manage their driver pods.
  // Non-default NVIDIADrivers take precedence over the default fallback, and conflicts fail closed...
  func AssignOwners(ctx context.Context, c client.Client) (bool, error) {
      defaultDrivers, nonDefaultDrivers, err := classifyDrivers(drivers.Items)
      if len(defaultDrivers) > 1 {
          return false, fmt.Errorf("multiple default NVIDIADrivers found: %v", ...) }
      // list nodes with consts.GPUPresentLabel="true" -> desiredOwnerForNode(node, nonDefaultDrivers, defaultOwner)
  ```
  </details>

- **ClusterPolicy 遗留 driver pod 的在线迁移**:新增 `controllers/nvidiadriver_migration.go` 的 `labelNodesWithOrphanedDriverPods`——找出 NVIDIADriver 已纳管节点上仍存在的、`OwnerReferences` 为空(孤儿)的旧 ClusterPolicy driver pod,给节点打 `upgrade.UpgradeStateUpgradeRequired` 标签,交给既有 driver 升级控制器在常规受控升级流里替换它们。配套 e2e 脚本 `migrate-clusterpolicy-to-nvidiadriver.sh`(等遗留 DaemonSet 删除、等孤儿 pod、等 default NVIDIADriver 渲染出来)。说明迁移路径是"不中断 GPU 工作负载、走升级控制器灰度替换"。

  <details><summary>代码依据 controllers/nvidiadriver_migration.go</summary>

  ```go
  // labelNodesWithOrphanedDriverPods marks NVIDIADriver-owned nodes that still have orphaned
  // ClusterPolicy driver pods so the driver upgrade controller can replace those pods...
  for _, pod := range pods.Items {
      if len(pod.OwnerReferences) > 0 || pod.Status.Phase != corev1.PodRunning ... { continue }
      if !nodeOwnedByNVIDIADriver(node, nvidiaDrivers.Items) { continue }
      if !isDriverUpgradeRequestAllowed(upgradeState) { continue }
      node.Labels[upgradeStateLabel] = upgrade.UpgradeStateUpgradeRequired
  ```
  </details>

### 后续发展方向 [AI]
- gpu-operator 在把 GPU 驱动生命周期的主权从 `ClusterPolicy.spec.driver`(单一全局)迁到独立 `NVIDIADriver` CR 多实例 + 默认兜底,长期看是为"同集群异构驱动版本/多 driverType 并存"和更细粒度灰度铺路——对标 OAI 的我们若也用 ClusterPolicy 心智,需评估这条迁移路径的兼容窗口。证据覆盖 CRD 字段、owner 分配、迁移控制器三处,但 `AssignOwners`/迁移在 reconcile 主循环的调用时机与 feature gate 开关未在本区间 hunk 完整展开(只见函数本体),下期看 `nvidiadriver_controller.go` 接线。
- CEL 不变式("default 驱动禁用 nodeSelector"+ 保留 owner 标签)说明这是带强约束的正式 API,而非实验字段;`>1 default 即 fail closed` 是显式安全闸。

## kai-scheduler/KAI-Scheduler: 38951dc7 -> 5ccedbad
- 比较 / Release:ahead=4, files=46 | Release v0.15.2 | https://github.com/kai-scheduler/KAI-Scheduler/compare/38951dc7b9dc31256df3759648cfdae6e0283567...5ccedbad0e37d849e0760853adbc2d0a03b44fb5

### AI 总结重点(源码 diff 为据)
- **`numa` 调度插件从设计文档变为可运行代码**(昨日 06-17 只落了 NPE exporter + README):新增 `pkg/scheduler/plugins/numa` 整包(`numa.go`/`evaluator.go`/`requests.go`/`reconstruct.go`/`seed_placements.go`),`pkg/scheduler/api/types.go` 新增 `NumaPlacementFn` 回调类型(插件向框架注册"给 task 在某 node 上算 NUMA 落位"的钩子),`PodInfo` 新增 `NUMAPlacement` 字段并纳入 `Clone()`。即调度框架现在原生携带每 task 的 NUMA 落位状态。

  <details><summary>代码依据 pkg/scheduler/api/types.go + pod_info/pod_info.go</summary>

  ```diff
  +type NumaPlacementFn func(task *pod_info.PodInfo, node *node_info.NodeInfo) pod_info.NUMAPlacement
  // pod_info.go
  +	NUMAPlacement NUMAPlacement
  +		NUMAPlacement:          pi.NUMAPlacement.Clone(),
  ```
  </details>

- **NRT(NodeResourceTopology)解析层:复刻 kubelet Topology Manager 语义**:新增 `node_info/numa_topology.go` 定义 `TopologyManagerPolicy`(none/best-effort/restricted/single-numa-node)与 `TopologyManagerScope`(container/pod),从 NRT Zone(仅建模 `Type=="Node"` 的 NUMA zone)解析出每 zone 的 `Available`/`Allocatable` 资源量;`attrTopologyManagerPolicy`/`attrTopologyManagerScope` 从 NRT 属性读策略。调度器据此在自己侧做与 kubelet 一致的 NUMA 准入判定。

  <details><summary>代码依据 pkg/scheduler/api/node_info/numa_topology.go</summary>

  ```go
  type TopologyManagerPolicy int
  const ( TopologyPolicyNone TopologyManagerPolicy = iota
      TopologyPolicyBestEffort; TopologyPolicyRestricted; TopologyPolicySingleNUMANode )
  type NumaZone struct {
      ID string; Available map[v1.ResourceName]resource.Quantity
      Allocatable map[v1.ResourceName]resource.Quantity }
  // zoneTypeNode = "Node"; attrTopologyManagerPolicy/Scope read from NRT attributes
  ```
  </details>

- **落位的内部表示 vs 持久化表示分层**:`pod_info/numa_placement.go` 的 `ZonePlacement` 用 **ZoneIndex**(指向 numa 插件 per-cycle 的 `nodeTopology.zones`,调度内部用),而持久化(BindRequest 字段 + pod 注解)时翻译成 NRT 的**耐久 zone id**。新增 `pkg/apis/scheduling/v1alpha2/numa_placement_types.go` 的 `NUMAZonePlacement{Zone, Amount}` 即注解序列化结构,写入 `kai.scheduler/numa-placement-observed`(NPE 观测)与 `kai.scheduler/numa-placement-predicted`(调度器预测)两个注解。observed/predicted 双轨与昨日 NPE 文档对得上。

  <details><summary>代码依据 pkg/apis/scheduling/v1alpha2/numa_placement_types.go</summary>

  ```go
  // NUMAZonePlacement is a pod's durable per-zone placement record... Serialized to
  // kai.scheduler/numa-placement-observed and kai.scheduler/numa-placement-predicted.
  type NUMAZonePlacement struct {
      Zone   string          `json:"zone"`
      Amount v1.ResourceList `json:"amount"`
  }
  ```
  </details>

- **Config CRD 新增 `numaPlacementExporter` 配置块 + operator 自动部署 NPE**:`pkg/apis/kai/v1/config_types.go` 的 `ConfigSpec` 加 `NumaPlacementExporter`,CRD `kai.scheduler_configs.yaml` +1104 行落地该块(`pollInterval` 默认 1s 本地读 podresources、`driftResyncInterval` 默认 60s 校正注解漂移、`nodeSelector` 故意不套全局 selector)。`Service.Enabled` 设计成 **tri-state**:nil=auto(任一 shard 启用 numa 插件即部署)、true=总是、false=从不;昨日还是 `deployments/numa-placement-exporter/numa-placement-exporter.yaml` 静态 yaml(本期 -112 行删除),现改由 operator operand(`pkg/operator/operands/numa_placement_exporter`)按需渲染。

  <details><summary>代码依据 pkg/apis/kai/v1/numa_placement_exporter/numa_placement_exporter.go</summary>

  ```go
  // Service.Enabled is used as a tri-state: nil = auto (deploy iff the numa plugin is
  // enabled in some shard), true = always deploy, false = never.
  func (n *NumaPlacementExporter) SetDefaultsWhereNeeded() {
      enabled := n.Service.Enabled
      n.Service.SetDefaultsWhereNeeded(imageName)
      n.Service.Enabled = enabled  // preserve tri-state (nil = auto)
      setResourceDefault(...Requests, CPU, "50m"); ...Memory, "64Mi"
      setResourceDefault(...Limits, CPU, "200m"); ...Memory, "128Mi"
  ```
  </details>

### 后续发展方向 [AI]
- KAI 的 NUMA 感知现在是完整闭环:NRT 解析(node_info)→ 插件 filter/落位(plugins/numa)→ 预测注解 → NPE 观测注解校正,且 exporter 从静态 yaml 升级为 operator tri-state 按需部署,工程成熟度明显高于昨日。这是把 kubelet Topology Manager 的 single-numa-node/restricted 准入判定上移到调度器侧,主打 GPU↔CPU↔NIC 亲和的训练吞吐场景。证据覆盖插件包、NRT 解析、落位类型、CRD 四处;但 `evaluator.go`/`reconstruct.go` 的具体 filter/打分算法本体 hunk 被截断(每文件 80 行),per-cycle zone 消耗跟踪细节下期看。
- snapshot-tool 也加了 NodeResourceTopologies(`cmd/snapshot-tool/main.go` +55),说明 NUMA 调度已被纳入可复现的离线调度仿真链路,便于回归测试抢占场景。证据仅 main.go 改动,未见仿真用例。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 近 EMPTY 的 repo</summary>

- `NVIDIA/nvidia-container-toolkit`:无新提交(HEAD 仍 6d1a53db)。
- `NVIDIA/gpu-driver-container`:无新提交。
- `kubernetes-sigs/dra-driver-nvidia-gpu`:无新提交(HEAD 仍 ed0d0e55,v0.4.1-rc.1)。
- `NVIDIA/dcgm-exporter`:无新提交。
- `NVIDIA/DCGM`:无新提交(master)。
- `NVIDIA/mig-parted`:无新提交。
- `NVIDIA/k8s-device-plugin`:实质仅 v0.19.3 发版准备(0.19.2→0.19.3 版本号全量 bump + distroless/go、golang 1.26.4、x/net bump);CHANGELOG 记"撤销 mofed/gdrcopy 默认开启(#1837)",撤销本体不在本区间 hunk。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9b198ba801ee9f1754dea0d74d85384659bea1c9 branch=main release=v26.3.2 scanned=2026-06-18 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6d1a53dbd83f7b95eff3645afedf2335466014f2 branch=main release=v1.19.1 scanned=2026-06-18 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d5f839873900dc0f985eae0ff4d975c9aacff0b4 branch=main release=— scanned=2026-06-18 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.2 scanned=2026-06-18 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba branch=main release=v0.4.1-rc.1 scanned=2026-06-18 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-18 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-18 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=d8348422bc7338fba3e112fa3f733e7eecaf51da branch=main release=v0.14.2 scanned=2026-06-18 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=5ccedbad0e37d849e0760853adbc2d0a03b44fb5 branch=main release=v0.15.2 scanned=2026-06-18 -->
</content>
</invoke>
