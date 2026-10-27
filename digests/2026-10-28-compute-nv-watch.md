# NVIDIA 算力栈 diff 雷达 2026-10-28

## 摘要
- 又一近乎静默日:9 仓中 6 仓相对 10-27 锚点无新提交,k8s-device-plugin 本期 2 提交全为 CI bump(containerd 2.3.6 + 构建镜像 golang 1.27.3),唯一实质代码改动在 gpu-operator。
- gpu-operator 本期是**可观测性改造**:给三个 CR 控制器(GPUCluster/Upgrade/NVIDIADriver)统一套上 `loggingReconciler` 装饰器,每次 reconcile 落一行含起始时间/耗时/outcome(success/error/requeue/panic)的日志;同时把散落的 `r.Log` 字段全量迁到 `log.FromContext(ctx)`;并给 GPUCluster 路径补了 `gpu_nodes_total` 指标统计(此前仅 ClusterPolicy 路径上报,两条路径指标口径现一致)。
- 无 API/CRD/弃用/版本跨档/新 package 信号,当日重要改变为"无"。

## 当日重要改变
- 无

## NVIDIA/gpu-operator: e1547194 -> ff1e0171
- 比较: e15471941743c5588e07fcc5f1415d5815e92b55 -> ff1e0171 | ahead=2 | files=12 | Release: v26.7.2
- 比较链接 https://github.com/NVIDIA/gpu-operator/compare/e15471941743c5588e07fcc5f1415d5815e92b55...ff1e0171b6cea17a04fcd0eab78cdbbad50c64f3

### AI 总结重点(源码 diff 为据)
- **新增 `loggingReconciler` 装饰器,给每次 reconcile 落一行结构化日志**:新文件 `controllers/logging_reconciler.go` 定义 `loggingReconciler{inner reconcile.Reconciler}`,在 `defer` 里统一打印 `Reconcile finished`,带 `start`(RFC3339Nano)、`durationSeconds`、`outcome`。outcome 四态:`panic`(recover 到 panic)、`error`(err≠nil)、`requeue`(`RequeueAfter>0 || Requeue`)、否则 `success`;recover 后把 panic 原样 re-panic 交给 controller-runtime 上层。在 `SetupWithManager` 里把 `Reconciler: r` 换成 `Reconciler: newLoggingReconciler(r)`——GPUCluster / NodeLabeling / NVIDIADriver 三个控制器均已接入。
  <details><summary>代码依据 controllers/logging_reconciler.go(新增)</summary>

  ```diff
  +func (l *loggingReconciler) Reconcile(ctx context.Context, req reconcile.Request) (res reconcile.Result, err error) {
  +	start := time.Now()
  +	defer func() {
  +		p := recover()
  +		outcome := "success"
  +		switch {
  +		case p != nil:
  +			outcome = "panic"
  +		case err != nil:
  +			outcome = "error"
  +		case res.RequeueAfter > 0 || res.Requeue:
  +			outcome = "requeue"
  +		}
  +		log.FromContext(ctx).Info("Reconcile finished",
  +			"start", start.UTC().Format(time.RFC3339Nano),
  +			"durationSeconds", time.Since(start).Seconds(),
  +			"outcome", outcome,
  +		)
  +		if p != nil {
  +			panic(p)
  +		}
  +	}()
  +	return l.inner.Reconcile(ctx, req)
  +}
  ```
  </details>
- **日志来源从 struct 字段 `r.Log` 全量迁移到 `log.FromContext(ctx)`**:`UpgradeReconciler` 直接删掉 `Log logr.Logger` 字段,`main.go` 对应去掉 `Log: upgradeLogger` 注入;ClusterPolicy/NodeLabeling reconcile 入口改成 `logger := log.FromContext(ctx)`,后续所有 `r.Log.Error/Info` 换成 `logger.*`;`state_manager.go` 的 `ClusterPolicyController.init` 也把 `n.logger = reconciler.Log` 改为 `log.FromContext(ctx)`。即日志上下文(request 关联字段)改由 controller-runtime 注入,不再依赖控制器构造期固定的 logger 实例。
  <details><summary>代码依据 controllers/upgrade_controller.go + cmd/gpu-operator/main.go</summary>

  ```diff
   type UpgradeReconciler struct {
   	client.Client
  -	Log               logr.Logger
   	Scheme            *runtime.Scheme
   	StateManager      upgrade.ClusterUpgradeStateManager
   ...
  -	reqLogger := r.Log.WithValues("upgrade", req.NamespacedName)
  +	reqLogger := log.FromContext(ctx)
  ```
  </details>
- **GPUCluster 路径补齐 `gpu_nodes_total` 指标,与 ClusterPolicy 路径对齐口径**:`GPUClusterReconciler` 新增 `OperatorMetrics *OperatorMetrics` 字段(`main.go` 注入),Reconcile 一进来就调 `recordGPUNodeCount(ctx)`——按 `commonGPULabelKey=commonGPULabelValue` 标签 List 节点,把 `gpuNodesTotal` gauge 设为节点数。注释点明:必须在前置冲突检查(存在 ClusterPolicy 则 GPUCluster 让路)之前调用,这样即便本 GPUCluster 被冲突的 ClusterPolicy 挡下,GPU 节点计数仍被记录。
  <details><summary>代码依据 controllers/gpucluster_controller.go</summary>

  ```diff
  +	r.recordGPUNodeCount(ctx)
  +
   	if !instance.DeletionTimestamp.IsZero() {
   ...
  +func (r *GPUClusterReconciler) recordGPUNodeCount(ctx context.Context) {
  +	if r.OperatorMetrics == nil {
  +		return
  +	}
  +	list := &corev1.NodeList{}
  +	if err := r.List(ctx, list, client.MatchingLabels{commonGPULabelKey: commonGPULabelValue}); err != nil {
  +		log.FromContext(ctx).Error(err, "unable to list nodes for the GPU node count metric")
  +		return
  +	}
  +	r.OperatorMetrics.gpuNodesTotal.Set(float64(len(list.Items)))
  +}
  ```
  </details>
- 提交 https://github.com/NVIDIA/gpu-operator/commit/baa12bb360754b336a5e7113efb2fb7d4c15170b (PR #3095 reconcile-start-metric,作者 rajathagasthya)

### 后续发展方向 [AI]
- 纯运维可观测性投入,无能力/架构/API 含义:统一 reconcile 日志口径(便于按 outcome/耗时聚合排障)+ 把 request-scoped logger 收归 controller-runtime 注入 + 补齐 GPUCluster 与 ClusterPolicy 两条控制路径的节点计数指标口径。证据仅覆盖 `logging_reconciler.go` 新增与 6 处 `r.Log→log.FromContext` 迁移、`gpucluster_controller.go` 的 `recordGPUNodeCount`,未见任何 ClusterPolicy CRD 字段/算力调度逻辑改动。值得记一笔的信号:GPUCluster(新 CR)与 ClusterPolicy(旧 CR)正被逐步拉平到同等运维待遇(指标、日志),印证 gpu-operator 向 GPUCluster 迁移的长期方向,但本期仅触及指标层,未动 spec。

## 本期无实质改动(折叠)
<details><summary>6 仓无新提交 + k8s-device-plugin 仅 CI bump + 2 仓无新提交</summary>

- NVIDIA/k8s-device-plugin(2 提交全为 CI bump:holodeck e2e containerd 2.3.6、构建基础镜像 golang 1.27.2→1.27.3,无功能代码改动,v0.20.1)
- NVIDIA/nvidia-container-toolkit(ahead=8 但全为 bump/CI/merge,v1.20.1)
- NVIDIA/gpu-driver-container(无新提交,—)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交,v0.5.1)
- NVIDIA/dcgm-exporter(无新提交,4.8.4)
- NVIDIA/DCGM(无新提交,master)
- NVIDIA/mig-parted(无新提交,v0.15.1)
- kai-scheduler/KAI-Scheduler(无新提交,v0.16.14)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=ff1e0171b6cea17a04fcd0eab78cdbbad50c64f3 branch=main release=v26.7.2 scanned=2026-10-28 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=03a06084d10d73a8943990ba7c32e4af7f70696e branch=main release=v1.20.1 scanned=2026-10-28 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f5d915c1324483b8166f6da5f9c40bc8299e8c9f branch=main release=— scanned=2026-10-28 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=bfc6655ff930639aaeb80fe64efaf31aaf5eaa2b branch=main release=v0.20.1 scanned=2026-10-28 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=43ce288759a2748748b5c9cacd7a34a8b4e89648 branch=main release=v0.5.1 scanned=2026-10-28 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-28 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-28 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-28 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=374cbb796ecff07c4a9140e59286f3e3a280e84b branch=main release=v0.16.14 scanned=2026-10-28 -->
