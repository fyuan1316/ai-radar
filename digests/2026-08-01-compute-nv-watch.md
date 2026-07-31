# NVIDIA 算力栈 diff 雷达 2026-08-01

## 摘要
- **gpu-operator 回退 ClusterPolicy×GPUCluster「同集群共存」设计,改为二者互斥**。上一版刚落地的"用 `nvidia.com/gpu-operator.resource-allocation.mode` 节点标签把 device-plugin 栈(ClusterPolicy)与 DRA 栈(GPUCluster)按节点分流共存"整套机制被**成片删除**(mode 标签常量/类型、`DEFAULT_GPU_ALLOCATION_MODE` 环境变量、`resolveDefaultMode`/`applyModeSelector` 全砍);现在两个 CR 同时存在时 Reconcile 直接报错置 NotReady。代码里留 `TODO: allow both CRs to co-exist`——这是一次显式的**临时收敛**:共存路由太复杂,先退回"一集群一栈"。
- **但同期把 DRA 栈往一等公民方向做实**:DRA 栈拿到独立的 DCGM 部署标签(`gpu.deploy.dcgm-dra` / `gpu.deploy.dcgm-exporter-dra`,与 device-plugin 栈的 DCGM 标签解耦);OLM bundle 逻辑开始把 DRA driver 镜像也当 related-image 覆盖/按 digest 钉版;compute-domain 默认打开 `GPU_CLIQUE_LABEL_ENABLED`。方向清楚:两栈从"节点级混布"改为"集群级二选一、各自独占监控/operand",DRA 栈继续向 GA 硬化。
- container-toolkit(仅 e2e 把 `FROM ubuntu` 钉成 `ubuntu:24.04` + dependabot PR 上限)、dra-driver-nvidia-gpu(Dockerfile 加 `GOPROXY`/`GO_MOD` 构建参数)本期均为构建/测试改动,无功能变更;gpu-driver-container / k8s-device-plugin / dcgm-exporter / DCGM / mig-parted / KAI-Scheduler 六仓无新提交。

## 当日重要改变
- **NVIDIA/gpu-operator** [架构方向/行为反转] 移除 ClusterPolicy 与 GPUCluster 的按节点共存路由,改为互斥:删掉 `resource-allocation.mode` 节点标签、`GPUAllocationMode` 类型、`DEFAULT_GPU_ALLOCATION_MODE` 环境变量、`resolveDefaultMode()`、`applyModeSelector()`,两个 Reconciler 现在检测到对方 CR 即报错。`internal/consts/consts.go`(-25)、`controllers/active_config.go`(-23)、`controllers/object_controls.go`(-21)、`controllers/clusterpolicy_controller.go` https://github.com/NVIDIA/gpu-operator/compare/9c0e917675f29f2a67995eec19d82a3c25844156...fd8f324ca2f61b54842b50cb29075550e153c2e7
- **NVIDIA/gpu-operator** [API/CRD变更] DRA(GPUCluster)栈获得独立 DCGM 部署标签:`gpuClusterStateLabels` 去掉共享的 `gpu.deploy.dcgm`/`gpu.deploy.dcgm-exporter`,新增 `gpu.deploy.dcgm-dra` 与 `gpu.deploy.dcgm-exporter-dra`,两栈监控 operand 彻底分栈调度。`controllers/state_manager.go` https://github.com/NVIDIA/gpu-operator/compare/9c0e917675f29f2a67995eec19d82a3c25844156...fd8f324ca2f61b54842b50cb29075550e153c2e7

## NVIDIA/gpu-operator: 9c0e9176 -> fd8f324c
- 比较: 9c0e917675f29f2a67995eec19d82a3c25844156 -> fd8f324c | ahead=8 | files=34 | Release: v26.3.3
- https://github.com/NVIDIA/gpu-operator/compare/9c0e917675f29f2a67995eec19d82a3c25844156...fd8f324ca2f61b54842b50cb29075550e153c2e7

### AI 总结重点(源码 diff 为据)
- **行为反转:ClusterPolicy(device-plugin 栈)与 GPUCluster(DRA 栈)从"同集群按节点标签共存"退回"整集群二选一、互斥"**。此前一版引入的分流机制——每个 GPU 节点带 `nvidia.com/gpu-operator.resource-allocation.mode` 标签(值 `device-plugin`/`dra`),两个 CR 可并存、每节点只跑所属栈的 operand,冲突时靠 `DEFAULT_GPU_ALLOCATION_MODE` 兜底——本期被整体删除。`ClusterPolicyReconciler.Reconcile` 新增:一旦发现存在任一 `GPUCluster`,直接报错、置 `NotReady`、设 `ReconcileFailed` 条件并返回;`NodeLabelingReconciler` 的结构注释也从"两者可共存"改为"每次 reconcile 二者恰有一个非空,同时存在则返回错误"。代码里明确留 `TODO: remove ... once both ... can co-exist`,说明是主动的临时收敛而非放弃 DRA。
  <details><summary>代码依据 controllers/clusterpolicy_controller.go</summary>

  ```diff
  +	// TODO: remove the below code block once both ClusterPolicy and GPUCluster can co-exist
  +	gpuClusters := &nvidiav1alpha1.GPUClusterList{}
  +	if err := r.List(ctx, gpuClusters); err != nil {
  +		return ctrl.Result{}, fmt.Errorf("failed to list GPUCluster objects: %w", err)
  +	}
  +	if len(gpuClusters.Items) > 0 {
  +		err := fmt.Errorf("conflicting GPUCluster resource %q detected; ClusterPolicy and GPUCluster cannot co-exist", gpuClusters.Items[0].Name)
  +		updateCRState(ctx, r, req.NamespacedName, gpuv1.NotReady)
  +		... return ctrl.Result{}, err
  +	}
  ```
  </details>
- **随之删掉整套 mode 路由原语**。`internal/consts/consts.go` 删掉 `GPUAllocationModeLabelKey`(`nvidia.com/gpu-operator.resource-allocation.mode`)、`GPUAllocationModeDevicePlugin`/`GPUAllocationModeDRA` 常量、`DefaultGPUAllocationModeEnvName`(`DEFAULT_GPU_ALLOCATION_MODE`)与 `GPUAllocationMode` 类型;`controllers/active_config.go` 删掉 `resolveDefaultMode()`(原来负责在两 CR 并存时按 env 选默认栈);`controllers/object_controls.go` 删掉 `applyModeSelector()`(原来给 ClusterPolicy operand DaemonSet 注入 mode nodeSelector,把它们限制到 device-plugin 节点);`state_manager.go` 相应删掉 `gpuClusterExists`/`allGPUNodesModeLabeled` 字段与 `discoverGPUNodes` 里逐节点检查 mode 标签的逻辑。
  <details><summary>代码依据 internal/consts/consts.go(-25)</summary>

  ```diff
  -	GPUAllocationModeLabelKey = "nvidia.com/gpu-operator.resource-allocation.mode"
  -	GPUAllocationModeDevicePlugin GPUAllocationMode = "device-plugin"
  -	GPUAllocationModeDRA GPUAllocationMode = "dra"
  -	DefaultGPUAllocationModeEnvName = "DEFAULT_GPU_ALLOCATION_MODE"
  -// GPUAllocationMode is the value set of the GPUAllocationModeLabelKey node label ...
  -type GPUAllocationMode string
  ```
  </details>
- **DRA 栈拿到独立的 DCGM / dcgm-exporter 部署标签,两栈监控 operand 分栈**。`state_manager.go` 的 `gpuClusterStateLabels`(GPUCluster/DRA 栈的 operand 门控标签集)从复用 `gpu.deploy.dcgm`/`gpu.deploy.dcgm-exporter` 改为专用的 `gpu.deploy.dcgm-dra`(`draDCGMDeployLabelKey`)与 `gpu.deploy.dcgm-exporter-dra`(`draDCGMExporterDeployLabelKey`)。配合上面的互斥,DRA 栈现在完整独占自己的 DCGM/dcgm-exporter DaemonSet,不与 device-plugin 栈共享部署标签。
  <details><summary>代码依据 controllers/state_manager.go</summary>

  ```diff
  +	draDCGMDeployLabelKey          = "nvidia.com/gpu.deploy.dcgm-dra"
  +	draDCGMExporterDeployLabelKey  = "nvidia.com/gpu.deploy.dcgm-exporter-dra"
   var gpuClusterStateLabels = map[string]string{
   	driverDeployLabelKey:          "true",
   	draDriverDeployLabelKey:       "true",
   	draValidatorDeployLabelKey:    "true",
  -	dcgmDeployLabelKey:         "true",
  -	dcgmExporterDeployLabelKey: "true",
  +	draDCGMDeployLabelKey:         "true",
  +	draDCGMExporterDeployLabelKey: "true",
   }
  ```
  </details>
- **OLM bundle 把 DRA driver 镜像纳入 related-image 覆盖与按 digest 钉版**。`.github/scripts/update-csv-images.py` 在 `RELATED_IMAGE_COMPONENTS`/`ENV_IMAGE_COMPONENTS` 加入 `nvidia-dra-driver-image`/`DRA_DRIVER_IMAGE`(→`draDriver`);新增 `split_repository_image_digest_version()` 支持 `@sha256:` digest 钉版;`update_alm_examples` 现在除 `NVIDIADriver` 外也处理 `GPUCluster` 类型样例(写 `spec.draDriver` 的 repository/image/version),并把 alm-examples 以 YAML 字面块(`LiteralBlock`)输出。即 operator 发行 bundle 开始正式携带并锁定 DRA driver 镜像。
  <details><summary>代码依据 .github/scripts/update-csv-images.py</summary>

  ```diff
  +    "nvidia-dra-driver-image": "draDriver",
  +    "DRA_DRIVER_IMAGE": "draDriver",
  +        elif example.get("kind") == "GPUCluster" and dra_driver_ref:
  +            dra_driver = spec.setdefault("draDriver", {})
  +            update_image_reference_fields(dra_driver, dra_driver_ref)
  ```
  </details>
- **另两处提交本期未纳入 patch 节选(hunk 未见,仅按提交标题+改动文件记录)**:①"Enable DCGM exporter DRA attribution when pod metadata is enabled"——触及 `manifests/state-dcgm-exporter/0210_clusterrole.yaml`(+8)、`0700_daemonset.yaml`(+7),推测为 dcgm-exporter 在 DRA 模式下按 pod metadata 做指标归属所需的 RBAC/env,**具体字段未读到 diff**;②"[state-dra-driver][compute-domain] set GPU_CLIQUE_LABEL_ENABLED to true by default"——触及 `manifests/state-dra-driver/0500_daemonset.yaml`(+2),把 compute-domain 的 clique 标签默认打开,**hunk 未见**。

### 后续发展方向 [AI]
- gpu-operator 对"device-plugin 栈 vs DRA 栈如何并存"的答案本期做了 180°:放弃刚落地的"节点级混布 + mode 标签路由",退回"集群级二选一、硬互斥"。判断是共存路由(逐节点标签收敛、operand nodeSelector 分流、env 兜底)在 v26.3.x 稳定线里风险/复杂度过高,先砍掉留 TODO。但这不是弃 DRA:同批把 DRA 栈做成结构对称的独立栈(专属 DCGM 部署标签、OLM related-image 携带 DRA driver 并 digest 钉版、clique 标签默认开),方向是 DRA 栈按自己的节奏向 GA 硬化,等成熟后再谈共存。证据覆盖互斥判定、mode 原语删除、DCGM 标签拆分、OLM 脚本;未覆盖 DCGM DRA attribution 与 clique 标签两处的具体 manifest hunk(patch 节选只取了 top-8 文件,这两处被挤出),其行为细节需回看源链接。

## 本期无实质改动(折叠)
<details>

- NVIDIA/nvidia-container-toolkit:仅 e2e 测试把 `FROM ubuntu` 钉成 `ubuntu:24.04`(并给 nvidiascape PoC 镜像补 `libc6-dev`)+ dependabot go 依赖 PR 上限设 10,无功能/API 变更(ahead=8/files=9,均为 tests/CI)。锚点已推进。
- kubernetes-sigs/dra-driver-nvidia-gpu:仅构建改动——`deployments/container/Dockerfile`/`Makefile` 新增 `GOPROXY` 与 `GO_MOD`(vendor/mod)构建参数,支持在线走 go proxy 拉模块;base 镜像 tag 从 `jammy-20260217` 升到 `jammy-20260627`。无源码/CRD 变更(ahead=5/files=2)。锚点已推进。
- NVIDIA/gpu-driver-container:无新提交
- NVIDIA/k8s-device-plugin:无新提交
- NVIDIA/dcgm-exporter:无新提交
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:无新提交
- kai-scheduler/KAI-Scheduler:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=fd8f324ca2f61b54842b50cb29075550e153c2e7 branch=main release=v26.3.3 scanned=2026-08-01 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=828fc6ce327ddca61d6f179a13c18ab94e0c658c branch=main release=v1.20.0-rc.1 scanned=2026-08-01 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=c08f0e543625568736a3531c207cceed44b5f2c5 branch=main release=— scanned=2026-08-01 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=5f27eeeee7eb7f7a4c0581aa10abeda7e4604ed2 branch=main release=v0.19.3 scanned=2026-08-01 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=50e0e3568f633d87266e3aabf8afa510843d6c7d branch=main release=v0.4.1 scanned=2026-08-01 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-01 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-01 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=589c033a8ef273613111245da67e1c6a0f78931b branch=main release=v0.14.4 scanned=2026-08-01 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=b8730e3499435a046ae9ddf879dd46131cd1aaed branch=main release=v0.16.8 scanned=2026-08-01 -->
