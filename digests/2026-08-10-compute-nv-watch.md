# NVIDIA 算力栈 diff 雷达 2026-08-10

## 摘要
- 9 仓仅 KAI-Scheduler 有 1 条实质提交(#2003):给 binder 组件补上 PodDisruptionBudget(HA 收口),其余 8 仓无新提交。
- 无 API/CRD 字段增删、无 driver/device-plugin/DRA 层能力变化,昇腾/HAMi 无关。
- 属运营侧高可用能力补全,非算力语义或调度能力演进。

## 当日重要改变
- 无(KAI-Scheduler 的 PDB 属 HA 运营能力补全,未命中 API/CRD/proposal 路径,不作重要改变上报)

## kai-scheduler/KAI-Scheduler: d5bc503a -> 46a09dd1
- 比较: d5bc503a146317e51037d89775d77172c6d12f71 -> 46a09dd1 | ahead=1 | files=9 | Release: v0.17.0
- 提交: feat(binder): Add binder PDB (#2003) https://github.com/kai-scheduler/KAI-Scheduler/pull/2003

### AI 总结重点(源码 diff 为据)
- **binder 被纳入"支持 PDB 的服务白名单"**:在 `common.go` 的 `PodDisruptionBudgetImplementedServices` map 里新增 `"binder"` 键,此前只有 admission/scheduler/pod-grouper 三个组件能被 operator 渲染出 PDB。这是把 binder(负责把 pod 真正 bind 到节点、含 GPU 资源预留/绑定的关键路径组件)纳入高可用治理的开关前提。

  <details><summary>代码依据 pkg/operator/operands/common/common.go</summary>

  ```diff
   var PodDisruptionBudgetImplementedServices = map[string]struct{}{
   	"admission":   {},
   	"scheduler":   {},
   	"pod-grouper": {},
  +	"binder":      {},
   }
  ```
  </details>

- **operator 的 binder 期望态里插入 PDB 资源生成函数**:`Binder.DesiredState` 的 `resourceFunc` 列表在 deployment 之后、serviceAccount 之前插入 `b.podDisruptionBudgetForKAIConfig`,使每次 reconcile 都会连带产出 PDB 对象。

  <details><summary>代码依据 pkg/operator/operands/binder/binder.go</summary>

  ```diff
   	for _, resourceFunc := range []resourceForKAIConfig{
   		b.deploymentForKAIConfig,
  +		b.podDisruptionBudgetForKAIConfig,
   		b.serviceAccountForKAIConfig,
   		b.serviceForKAIConfig,
  ```
  </details>

- **新增 `podDisruptionBudgetForKAIConfig` 方法,复用公共 PDB 构造器**:委托给 `common.PodDisruptionBudgetForKAIConfig`,传入 namespace、BaseResourceName、`config.Replicas`、`config.Service`;当返回 `pdbObj == nil` 时不产出对象。结合下方 values.yaml 注释可知:**PDB 仅在 binder replicas > 1 时才创建**(单副本不设 PDB,避免锁死驱逐)。

  <details><summary>代码依据 pkg/operator/operands/binder/resources.go</summary>

  ```diff
  +func (b *Binder) podDisruptionBudgetForKAIConfig(
  +	ctx context.Context, runtimeClient client.Reader, kaiConfig *kaiv1.Config,
  +) ([]client.Object, error) {
  +	config := kaiConfig.Spec.Binder
  +	pdbObj, err := common.PodDisruptionBudgetForKAIConfig(
  +		ctx, runtimeClient, kaiConfig.Spec.Namespace,
  +		b.BaseResourceName, config.Replicas, config.Service,
  +	)
  +	if err != nil { return nil, err }
  +	if pdbObj == nil { return nil, nil }
  +	return []client.Object{pdbObj}, nil
  +}
  ```
  </details>

- **Helm 配置面新增 `binder.podDisruptionBudget`**:values.yaml 暴露 `enabled: true` / `maxUnavailable: 1`,`_helpers.tpl` 把这两个字段透传进渲染出的 KAIConfig 的 `spec.binder.service.podDisruptionBudget`。注释明确 HA 用法:`operator.replicaCount: 2`(或在 Config 里 override `binder.replicas`)。默认 `maxUnavailable: 1`。

  <details><summary>代码依据 deployments/kai-scheduler/values.yaml</summary>

  ```diff
   binder:
     ports:
       metricsPort: 8080
     affinity: {}
  +  # PDB is created only when binder replicas > 1 (operator.replicaCount / binder.replicas).
  +  # For HA: set operator.replicaCount: 2 (or override binder.replicas in Config).
  +  podDisruptionBudget:
  +    enabled: true
  +    maxUnavailable: 1
  ```
  </details>

### 后续发展方向 [AI]
- 方向是把 KAI(原 Run:ai)调度器控制面各组件逐个补齐 HA/PDB 治理,binder 是继 admission/scheduler/pod-grouper 之后被纳入的第四个;至此调度器数据面关键组件的 PDB 覆盖基本闭环。证据只覆盖 operator operand 层(白名单 map + DesiredState + 新方法 + Helm values)与其单测,**未触及调度算法、GPU 共享/分片语义、CRD 字段**——本期无任何 gpusharing/DRA/device-plugin 侧改动,纯运营高可用收口。
- 值得留意的边界:PDB 走的是 `spec.binder.service.podDisruptionBudget` 而非顶层 CRD 新字段(命中探测为 0),说明 KAI 的 Config CRD schema 本期未变,配置仍从 Helm values 透传;未见对 binder 绑定逻辑本身的改动。

## 本期无实质改动(折叠)
<details>
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
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=cfabcc9a8c4cc071a7120d320d0d8db79984a166 branch=main release=v26.3.3 scanned=2026-08-10 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a996390117806acd2a73fd0e5b3e6a17755f3ae4 branch=main release=v1.20.0-rc.1 scanned=2026-08-10 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=dd8eab6bdea9de694423120038415b81357555dc branch=main release=— scanned=2026-08-10 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=04fc23c27961f42346bcba90e7d00fc2ed818fa0 branch=main release=v0.19.3 scanned=2026-08-10 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=95932046683719c43b6a0dd9613c2e5aad5d6703 branch=main release=v0.4.1 scanned=2026-08-10 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-10 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-10 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f35ad98cc3718a432fd5d1e49d20dbc28fcaedcd branch=main release=v0.14.4 scanned=2026-08-10 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=46a09dd1ec1f4e934168b3e1b7ae289e20bd9157 branch=main release=v0.17.0 scanned=2026-08-10 -->
