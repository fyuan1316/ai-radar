# NVIDIA 算力栈 diff 雷达 2026-07-28

## 摘要
- **gpu-operator 修 ClusterPolicy 在 NVIDIADriver 升级期间状态抖动**:当 driver 走 CRD 类型(`NVIDIADriver`)时,只要有节点处于 pending/in-progress/failed 升级态,ClusterPolicy 就锁定为 `NotReady`;且升级态不再靠 5s 周期轮询驱动,改由 Node 升级标签的 watch 事件触发,避免 reconcile 抖动。同期上架 vGPU 20.0 默认切分档(新增 6000D / B300X / DC 系列 profile),GPUCluster 加 finalizer 改用乐观锁 PATCH。
- **KAI-Scheduler 给 pod-grouper 补 PDB、并堵住已删 PodGroup 的 status-updater 重试死循环**:pod-grouper 纳入 operator 侧 PDB(replicas>1 时生成);status-updater 新增"终态错误(NotFound/Conflict)不重试直接丢弃",此前 `NotFound`(PodGroup 已删)会被反复重试。
- 其余 6 仓(nvidia-container-toolkit 仅打包压缩微调、gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)无实质代码改动,保锚点。

## 当日重要改变
- NVIDIA/gpu-operator [新能力] vGPU 20.0 默认切分档上架:configmap 新增 6000D / B300X / DC 系列 vGPU profile(如 `B300X-7-269C`、`DC-1-2QGFX`) https://github.com/NVIDIA/gpu-operator/pull/2625
- NVIDIA/gpu-operator [修复] ClusterPolicy 在 NVIDIADriver(CRD 类型)升级未完成时锁定 NotReady,升级态改由 Node 标签 watch 驱动而非 5s 轮询 https://github.com/NVIDIA/gpu-operator/pull/2665
- kai-scheduler/KAI-Scheduler [新能力] pod-grouper 纳入 operator 侧 PDB(`podgrouper.podDisruptionBudget`,replicas>1 生成),并把 admission/scheduler 的 PDB 模板收进条件块 https://github.com/kai-scheduler/KAI-Scheduler/pull/1955
- kai-scheduler/KAI-Scheduler [修复] status-updater 对终态错误(NotFound/Conflict)不再重试,堵住已删 PodGroup 的状态更新死循环 https://github.com/kai-scheduler/KAI-Scheduler/pull/1949

## NVIDIA/gpu-operator: cb71b475 -> 7adc442d
- 比较: https://github.com/NVIDIA/gpu-operator/compare/cb71b4755401140cf565723f945f28d875793277...7adc442d10bc102f39d1ca04cac9f5cc45633a5f | ahead=13 | files=59 | Release: v26.3.3

### AI 总结重点(源码 diff 为据)

- **ClusterPolicy 升级期状态治理:CRD 类型 driver 升级未完成时锁 NotReady,且升级态改走 Node 标签 watch**:`Reconcile` 新增分支——当 `singleton.Spec.Driver.UseNvidiaDriverCRDType()` 为真时调 `nvidiaDriverUpgradeIncomplete(ctx)` 判断是否有节点处于 pending/active/failed 升级态,是则把 `overallStatus` 置 `NotReady` 并追加两条 `notReadyReasons`。关键行为差异:原逻辑无论何种 not-ready 都 `RequeueAfter 5s` 周期重排,新逻辑仅在 `len(statesNotReady)>0`(真有 operand 未就绪)时才 5s 轮询;若"仅升级未完成",则返回空 `Result{}`,不轮询——靠 Node 升级标签的 watch 事件重新入队,消除 reconcile 抖动。新增 `clusterPolicyNotReadyMessage` 把 operand 状态与升级原因拼成条件消息。
  <details><summary>代码依据 controllers/clusterpolicy_controller.go</summary>

  ```diff
  +	if clusterPolicyCtrl.singleton.Spec.Driver.UseNvidiaDriverCRDType() {
  +		upgradeIncomplete, err := r.nvidiaDriverUpgradeIncomplete(ctx)
  ...
  +		if upgradeIncomplete {
  +			overallStatus = gpuv1.NotReady
  +			notReadyReasons = append(notReadyReasons,
  +				"NVIDIADriver upgrade has not completed",
  +				"one or more NVIDIADriver-owned Nodes are marked pending, in-progress, or failed",
  +			)
  +		}
  +	}
  ...
  -		return ctrl.Result{RequeueAfter: time.Second * 5}, nil
  +		if len(statesNotReady) > 0 {
  +			return ctrl.Result{RequeueAfter: time.Second * 5}, nil
  +		}
  +		return ctrl.Result{}, nil
  ```
  </details>

- **升级控制器的 Node watch 谓词从"只看升级状态标签"扩到"升级参与度标签"**:`upgrade_controller.go` 把 `upgradeStateLabelPredicate`(只比对 `GetUpgradeStateLabelKey()`)改名并重写为 `upgradeNodeLabelPredicate`,底层 `upgradeNodeLabelsChanged` 同时比对升级状态标签**和** `GetUpgradeSkipNodeLabelKey()`(跳过升级标签)——即某节点被标记 skip/取消 skip 也会触发 ClusterPolicy 重算,与上面"升级态由 watch 驱动"配套。
  <details><summary>代码依据 controllers/upgrade_controller.go</summary>

  ```diff
  +// upgradeNodeLabelsChanged reports Node label changes that require the upgrade
  +// controller to re-evaluate upgrade participation or progress.
  +func upgradeNodeLabelsChanged(oldLabels, newLabels map[string]string) bool {
  +	return oldLabels[upgrade.GetUpgradeStateLabelKey()] != newLabels[upgrade.GetUpgradeStateLabelKey()] ||
  +		oldLabels[upgrade.GetUpgradeSkipNodeLabelKey()] != newLabels[upgrade.GetUpgradeSkipNodeLabelKey()]
  +}
  ```
  </details>

- **GPUCluster finalizer 加锁改用乐观锁 PATCH(替代 Update)**:新增 `utils.EnsureFinalizer`,幂等——对象已删或已含 finalizer 直接返回,否则 `DeepCopy` 原对象后用 `client.MergeFromWithOptimisticLock` 做 Patch;`gpucluster_controller.go` 把原先"手动 `AddFinalizer` + `r.Update`"整段替换为一行 `utils.EnsureFinalizer`。含义:从整对象 Update 收窄为带 resourceVersion 校验的合并补丁,减少与其他写者的冲突覆盖面。
  <details><summary>代码依据 internal/utils/utils.go</summary>

  ```diff
  +func EnsureFinalizer(ctx context.Context, c client.Client, o client.Object, finalizer string) error {
  +	if !o.GetDeletionTimestamp().IsZero() || controllerutil.ContainsFinalizer(o, finalizer) {
  +		return nil
  +	}
  +	original := o.DeepCopyObject().(client.Object)
  +	controllerutil.AddFinalizer(o, finalizer)
  +	return c.Patch(ctx, o, client.MergeFromWithOptions(original, client.MergeFromWithOptimisticLock{}))
  +}
  ```
  </details>

- **vGPU 20.0 默认切分档上架**:`state-vgpu-device-manager/0500_configmap.yaml` 新增一大批 vGPU profile 到默认设备配置,覆盖新硬件——6000D 系列(如 `6000D-1-42CGFX`)、Blackwell B300X 系列(`B300X-1-34C` … `B300X-7-269C`、整卡 `B300X-269C`)、DC 系列(`DC-1-2QGFX` 48 份 … `DC-1-12CGFX` 8 份)。每档给出 `vgpu-devices` 可切分份数,是 vGPU device-manager 的开箱切分风向标。
  <details><summary>代码依据 assets/state-vgpu-device-manager/0500_configmap.yaml</summary>

  ```diff
  +        B300X-7-269C:
  +            - devices: all
  +              vgpu-devices:
  +                B300X-7-269C: 1
  +        DC-1-2QGFX:
  +            - devices: all
  +              vgpu-devices:
  +                DC-1-2QGFX: 48
  ```
  </details>

### 后续发展方向 [AI]
- 三处改动共同指向 driver-as-CRD(`NVIDIADriver`)路径的成熟化:升级期状态语义、watch 驱动的事件模型、乐观锁写入,都是把 operator 从"周期轮询 + 整对象 Update"迁向"事件驱动 + 精细补丁"。证据覆盖 reconcile 分支、watch 谓词、finalizer 三处 hunk;`nvidiaDriverUpgradeIncomplete` 具体如何枚举 NVIDIADriver-owned 节点的判定体在截断处未见(仅见 `IsIncompleteDriverUpgradeState` 测试列出 UpgradeRequired/Failed/PodRestartRequired/UncordonRequired 为 incomplete),完整判定待源链接确认。
- vGPU 20.0 profile 全属数据面配置扩容(configmap),非代码逻辑变化;B300X(Blackwell)进默认档说明 operator 侧已对齐最新硬件的 vGPU 切分几何,但本次未见 mig/DRA 侧同步适配。

## kai-scheduler/KAI-Scheduler: 4ca07f4c -> aeb57eae
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/4ca07f4c0f80333e020f671629ce8a4e2c150e8d...aeb57eaefe70ef778298501616b1b8f3d773d5e5 | ahead=4 | files=19 | Release: v0.16.7

### AI 总结重点(源码 diff 为据)

- **pod-grouper 纳入 operator 侧 PDB,并修正 admission/scheduler 的 PDB 模板未做存在性门控**:`common.go` 的 `PodDisruptionBudgetImplementedServices` 白名单新增 `pod-grouper`;`resources.go` 加 `podDisruptionBudgetForKAIConfig` 复用 `common.PodDisruptionBudgetForKAIConfig`(按 `config.Replicas` 生成);Helm `values.yaml` 给 `podgrouper` 补 `podDisruptionBudget{enabled:true, maxUnavailable:1}`,并注明"仅 replicas>1 时生成"。`_helpers.tpl` 里 admission/scheduler 两处原本无条件渲染的 `podDisruptionBudget` 块现被 `{{- if .Values.X.podDisruptionBudget }}` 包住——修的是未配置 PDB 时仍渲染空块的隐患。
  <details><summary>代码依据 pkg/operator/operands/common/common.go</summary>

  ```diff
   var PodDisruptionBudgetImplementedServices = map[string]struct{}{
  -	"admission": {},
  -	"scheduler": {},
  +	"admission":   {},
  +	"scheduler":   {},
  +	"pod-grouper": {},
   }
  ```
  </details>

- **status-updater 对"终态错误"停止重试,堵住已删 PodGroup 的更新死循环**:新增 `isTerminalUpdateError(err) = IsNotFound(err) || IsConflict(err)`。原逻辑只对 status 的 `IsConflict` 做"删 in-flight、下轮再排"的短路;新逻辑对 status 与 patch 两路都算 `statusRetryable/patchRetryable`,两者皆不可重试时统一丢弃并 `inFlightPodGroups.Delete(key)`。关键新增:`IsNotFound` 也归为终态——PodGroup 已被删除时的状态更新不再被反复重试。
  <details><summary>代码依据 pkg/scheduler/cache/status_updater/concurrency.go</summary>

  ```diff
  +		statusRetryable := statusErr != nil && !isTerminalUpdateError(statusErr)
  +		patchRetryable := patchErr != nil && !isTerminalUpdateError(patchErr)
  +		if !statusRetryable && !patchRetryable {
  ...
  +			su.inFlightPodGroups.Delete(key)
  +			return
  +		}
  ...
  +func isTerminalUpdateError(err error) bool {
  +	return apierrors.IsNotFound(err) || apierrors.IsConflict(err)
  +}
  ```
  </details>

- **semi-preemptible 设计文档扩写:核心/弹性切分下沉到子组树的每一层(minSubGroup),不加新 API 字段**:HLD 从"podgroup 在 `min-members` 内非抢占、超出部分弹性可抢占"扩展为"在子组树**每个节点**的最小需求(叶子 PodSet 的 `minMember` + 中间节点的 `minSubGroup`)内非抢占,超出即弹性"。明确复用现有 `preemptibility` 字段/label,不引入新 API;明确把 `kai.scheduler/segment-size` 自动分段路径列为 out-of-scope 且与 semi-preemptible 互斥;quota scale-down 不做特殊缓解(与 non-preemptible 行为一致)。
  <details><summary>代码依据 docs/developer/designs/semi-preemptible/README.md</summary>

  ```diff
  -We want to add a new 3rd mode, named **semi-preemptible**, where the podgroup will be non-preemptible up to the `min-members`, and any extra pods are "elastic" pods and preemptible.
  +We want to add a new 3rd mode, named **semi-preemptible**, where the podgroup is non-preemptible up to its **minimum required shape** — `minMember` pods at each leaf PodSet and `minSubGroup` child subgroups at each intermediate node — and anything beyond that minimum is "elastic" and preemptible. Elasticity therefore applies at **every level of the subgroup tree**, not just to pods.
  ```
  </details>

### 后续发展方向 [AI]
- PDB 三服务(admission/scheduler/pod-grouper)现已齐全,配合上一批 podgrouper 的分段弹性/PyTorchJob minReplicas 修复,KAI-Scheduler 的控制面 HA 与调度语义在持续补齐;证据覆盖白名单/资源/模板/values 四处,PDB 仅在 replicas>1 生成的实际 operator 生成逻辑在 `common.PodDisruptionBudgetForKAIConfig` 内(未在本次 diff 展开)。
- semi-preemptible 仍停在 HLD 阶段(本次仅文档),但方向明确:复用现有 API、把弹性从"pod 级"提升到"子组树逐层级",并与自动分段互斥。实现 PR 未见,`minSubGroup` 在调度器求解侧的落地待后续跟踪。

## 本期无实质改动(折叠)
- NVIDIA/nvidia-container-toolkit:唯一实质提交 "Use XZ RPM compression during rpmrebuild"——`Dockerfile.rpmrebuild` 加 `--define "_binary_payload w2.xzdio"` 走 XZ 压缩,并 bump `libnvidia-container` 子模块;纯打包/构建变更,无运行时或 API 影响。
- NVIDIA/gpu-driver-container、kubernetes-sigs/dra-driver-nvidia-gpu、NVIDIA/dcgm-exporter、NVIDIA/DCGM:无新提交。
- NVIDIA/k8s-device-plugin(ahead=6)、NVIDIA/mig-parted(ahead=2):仅 bump/CI/merge,无实质代码改动。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=7adc442d10bc102f39d1ca04cac9f5cc45633a5f branch=main release=v26.3.3 scanned=2026-07-28 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=1151f013074712dc6dabd00752b6b57d6637fdeb branch=main release=v1.20.0-rc.1 scanned=2026-07-28 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0ad335fb28b96957aa3f9fdda6dfdab9040e69e9 branch=main release=— scanned=2026-07-28 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=7ce521311d346843c40328e1f04ab2d9bf6b8f03 branch=main release=v0.19.3 scanned=2026-07-28 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=b0a51e353fbabab0230639b027e02f1ab29e8cab branch=main release=v0.4.1 scanned=2026-07-28 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-28 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-28 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=45a99420afe38cfdcb00182d9fe5fa55cf69b103 branch=main release=v0.14.4 scanned=2026-07-28 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=aeb57eaefe70ef778298501616b1b8f3d773d5e5 branch=main release=v0.16.7 scanned=2026-07-28 -->
