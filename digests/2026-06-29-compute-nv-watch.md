# NVIDIA 算力栈 diff 雷达 2026-06-29

## 摘要
- 仅 **KAI-Scheduler**(v0.16.0 → v0.16.1,3 提交)有实质改动,主题是**对 GitOps/外部托管资源更友好**:operand Deployment 打 `app.kubernetes.io/managed-by=kai-operator` 标签、卸载只删自管资源不再 `delete --all`;podgrouper 不再覆盖外部写入的 TopologyConstraint;chart 把 4 个 PriorityClass 收进可关的 `defaultPriorityClasses` 开关(并把 Helm value `priorityClasses` 重命名)。
- 其余 8 仓(gpu-operator / container-toolkit / gpu-driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)自 06-28 起无新提交。
- 无 ClusterPolicy CRD / device-plugin / DRA 层代码变化;NVIDIA 核心算力栈本日静默。

## 当日重要改变
- **kai-scheduler/KAI-Scheduler** [API/配置面破坏] Helm value `priorityClasses` 重命名为 `defaultPriorityClasses`,且 4 个 PriorityClass(train/inference/build/build-preemptible)模板整体加 `{{- if .Values.defaultPriorityClasses.enabled }}` 门控——已有 values 覆盖会失效,升级需改键名。证据见下,提交 https://github.com/kai-scheduler/KAI-Scheduler/pull/1785

## kai-scheduler/KAI-Scheduler: 58708edb -> 09289b24
- 比较 https://github.com/kai-scheduler/KAI-Scheduler/compare/58708edb4083f81b35a3656327c021889f0d0829...09289b24d231197e829c1dfd0cf68b85f74d7407 | ahead=3 | files=14 | 最新 Release v0.16.1

### AI 总结重点(源码 diff 为据)
- **卸载从"清空命名空间"收窄为"只删 operator 自管 deployment"**。`common.go` 新增常量 `OperatorManagedByLabelKey = "app.kubernetes.io/managed-by"` / `OperatorManagedByLabelValue = "kai-operator"`,并在 `DeploymentForKAIConfig` 构造时给 deployment 打这个标签;配套 post-delete hook 把 `kubectl delete deployment --all` 改成 `--selector=app.kubernetes.io/managed-by=kai-operator`。意味着 KAI 卸载不再误删同命名空间下他方的 deployment,且 kai-config 的删除被 `kaiConfigDeployer.enabled` 门控(关掉则既不建也不删,交外部管)。
  <details><summary>代码依据 pkg/operator/operands/common/common.go + post-delete-job.yaml</summary>

  ```diff
  +const (
  +	OperatorManagedByLabelKey   = "app.kubernetes.io/managed-by"
  +	OperatorManagedByLabelValue = "kai-operator"
  +)
   	deployment := deploymentObj.(*appsv1.Deployment)
  +	deployment.Labels[OperatorManagedByLabelKey] = OperatorManagedByLabelValue
  ```
  ```diff
  -              echo "Deleting deployments..."
  -              kubectl -n {{ .Release.Namespace }} delete deployment --all --ignore-not-found=true
  +              echo "Deleting KAI operator-managed deployments..."
  +              kubectl -n {{ .Release.Namespace }} delete deployment --selector=app.kubernetes.io/managed-by=kai-operator --ignore-not-found=true
  +              {{- if .Values.kaiConfigDeployer.enabled }}
                 echo "Deleting kai-config..."
                 kubectl delete Config kai-config --ignore-not-found
  +              {{- end }}
  ```
  </details>
- **podgrouper 不再覆盖外部写入的拓扑约束**。`Handler.ignoreFields` 新增:当传入的新 PodGroup `Spec.TopologyConstraint.Topology == ""` 时,保留旧 PodGroup 的 `TopologyConstraint`。原先注释只提"pod-group-assigner 负责的字段",现改为泛指"external services"——即除内置 assigner 外,任意外部组件给 PodGroup 写的拓扑约束都不会被 podgrouper 的 reconcile 抹掉。
  <details><summary>代码依据 pkg/podgrouper/podgroup/handler.go</summary>

  ```diff
  -	// to avoid overriding the fields that the pod-group-assigner is responsible for
  +	// to avoid overriding the fields that external services are responsible for
  	newPodGroupCopy := newPodGroup.DeepCopy()
   ...
  +	if newPodGroupCopy.Spec.TopologyConstraint.Topology == "" {
  +		newPodGroupCopy.Spec.TopologyConstraint = oldPodGroup.Spec.TopologyConstraint
  +	}
  ```
  </details>
- **chart 默认 PriorityClass 改为可关,且 value 键重命名**。新增 `defaultPriorityClasses.enabled`(默认 true),train=50 / inference=125 / build=100 / build-preemptible=75 四个 cluster-scoped PriorityClass 模板整体被该开关门控;原 `priorityClasses` value 被重命名为 `defaultPriorityClasses`(PR #1785)。供"PriorityClass 由外部统一管理"的集群关闭内置定义。
  <details><summary>代码依据 values.yaml + templates/priorityclasses/train.yaml</summary>

  ```diff
  +# defaultPriorityClasses controls the chart-managed build, train, inference, and
  +# build-preemptible PriorityClasses. Disable when these cluster-scoped resources
  +# are managed externally.
  +defaultPriorityClasses:
  +  enabled: true
  ```
  ```diff
  +{{- if .Values.defaultPriorityClasses.enabled }}
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata:
     name: train
  -value: 50
  +value: 50
  +{{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- 三处改动共同指向**让 KAI 在 GitOps / 外部托管场景里"可被外部系统接管"**:卸载不越界(managed-by 选择器)、拓扑约束让位外部 writer、PriorityClass 可外部统一定义。对标我们产品,这是把调度器从"自成闭环安装"往"可嵌入企业既有平台治理"演进的信号,多租户/平台集成方向值得跟。证据只覆盖 chart + podgrouper handler + operator common 这 3 处 hunk,未见调度内核(plugin/fairness)层改动;v0.16.1 是 patch 档,无 CRD 字段增删。

## 本期无实质改动(折叠)
<details><summary>8 仓自 06-28 起无新提交</summary>

- NVIDIA/gpu-operator(a37981bd,Release v26.3.3)
- NVIDIA/nvidia-container-toolkit(41dd4444,Release v1.19.1)
- NVIDIA/gpu-driver-container(f41a0200)
- NVIDIA/k8s-device-plugin(25e49358,Release v0.19.3)
- kubernetes-sigs/dra-driver-nvidia-gpu(779a7dd0,Release v0.4.1-rc.1)
- NVIDIA/dcgm-exporter(d5e5f510,Release 4.5.3-4.8.2)
- NVIDIA/DCGM(d646460f,master)
- NVIDIA/mig-parted(5dc3caa4,Release v0.14.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=a37981bdf128ace73550200724b00958d1d1db18 branch=main release=v26.3.3 scanned=2026-06-29 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=41dd4444a23ffc387262e7159b4696fb688553a2 branch=main release=v1.19.1 scanned=2026-06-29 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f41a0200e00d232bd7e257b22600883346eea079 branch=main release=— scanned=2026-06-29 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.3 scanned=2026-06-29 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=779a7dd0506915a9fa96df11bbdd5010d53a199a branch=main release=v0.4.1-rc.1 scanned=2026-06-29 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-29 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5dc3caa478807fec0fc6a2160ef9e8f056300e4e branch=main release=v0.14.2 scanned=2026-06-29 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=09289b24d231197e829c1dfd0cf68b85f74d7407 branch=main release=v0.16.1 scanned=2026-06-29 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-29 -->
