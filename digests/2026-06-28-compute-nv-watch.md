# NVIDIA 算力栈 diff 雷达 2026-06-28

## 摘要
- **gpu-operator 把 OperatorMetrics 从 ClusterPolicyController 的包级单例解耦成独立对象**:`main.go` 启动时 `InitOperatorMetrics()` 一次,作为字段注入 ClusterPolicy 与 Upgrade 两个 Reconciler,删掉散落各处的 `if ...operatorMetrics != nil` 空判——指标对象生命周期与控制器解绑,可独立初始化/测试。属内部重构,无 ClusterPolicy CRD 字段改动。
- **dra-driver-nvidia-gpu 补齐参考文档(纯 docs)**:新增 time-slicing 指南 + API/feature-gates/helm-values 三份 reference,系统化披露了 `resource.nvidia.com/v1beta1` 的共享能力面(GpuConfig 的 TimeSlicing/MPS、9 个 feature gate 的 stage/默认值/互斥约束)。无代码/API 改动,但首次把能力矩阵集中成文,对照价值高。
- 其余 7 仓全 EMPTY(无新提交或仅 bump/CI)。

## 当日重要改变
- 无硬信号命中(无 CRD 字段增删、无弃用/移除、无版本跨档、无新增顶层 package)。下列两条为重构/文档类,列作上下文而非 breaking 信号。
- NVIDIA/gpu-operator [重构] OperatorMetrics 解耦为独立注入对象,移除 nil 守卫,指标初始化前移到 main。证据 `cmd/gpu-operator/main.go`、`controllers/upgrade_controller.go`、`controllers/clusterpolicy_controller.go`。 https://github.com/NVIDIA/gpu-operator/compare/a02dd1afd1bd394f74f667a7968a6cd42e527525...a37981bdf128ace73550200724b00958d1d1db18
- kubernetes-sigs/dra-driver-nvidia-gpu [文档/能力面] 集中文档化 v1beta1 共享 API 与全部 feature gate(含互斥/依赖约束)。证据 `site/content/docs/reference/feature-gates.md`、`reference/api.md`。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/a89291ec6dfffaf06d6bb3f9b46231c36086007e...779a7dd0506915a9fa96df11bbdd5010d53a199a

## NVIDIA/gpu-operator: a02dd1af -> a37981bd
- 比较 / Release: https://github.com/NVIDIA/gpu-operator/compare/a02dd1afd1bd394f74f667a7968a6cd42e527525...a37981bdf128ace73550200724b00958d1d1db18 | ahead=4 | files=17 | Release: v26.3.3

### AI 总结重点(源码 diff 为据)
- **OperatorMetrics 从「ClusterPolicyController 包级单例」改为「显式注入的独立对象」**:此前指标只挂在 `clusterPolicyCtrl.operatorMetrics`(包级变量),Upgrade/ClusterPolicy 两个 Reconciler 用它前都得 `if ... != nil` 防空。现在 `main.go` 在 setup 阶段调一次 `controllers.InitOperatorMetrics()`,把结果作为 `OperatorMetrics *OperatorMetrics` 字段注入两个 Reconciler;UpgradeReconciler 内所有 `clusterPolicyCtrl.operatorMetrics.xxx` 改成 `r.OperatorMetrics.xxx` 且去掉 nil 判断。
  <details><summary>代码依据 cmd/gpu-operator/main.go</summary>

  ```diff
  +	setupLog.Info("initializing operator metrics")
  +	operatorMetrics := controllers.InitOperatorMetrics()
  +
   	if err = (&controllers.ClusterPolicyReconciler{
  -		Namespace: operatorNamespace,
  -		Client:    mgr.GetClient(),
  ...
  +		Namespace:       operatorNamespace,
  +		Client:          mgr.GetClient(),
  +		OperatorMetrics: operatorMetrics,
   	}).SetupWithManager(ctx, mgr); err != nil {
  ...
   	if err = (&controllers.UpgradeReconciler{
  -		StateManager: clusterUpgradeStateManager,
  +		StateManager:    clusterUpgradeStateManager,
  +		OperatorMetrics: operatorMetrics,
   	}).SetupWithManager(ctx, mgr); err != nil {
  ```
  </details>
  <details><summary>代码依据 controllers/upgrade_controller.go(去 nil 守卫)</summary>

  ```diff
  -	if clusterPolicyCtrl.operatorMetrics != nil {
  -		clusterPolicyCtrl.operatorMetrics.upgradesInProgress.Set(float64(r.StateManager.GetUpgradesInProgress(state)))
  -		...
  -	}
  +	r.OperatorMetrics.upgradesInProgress.Set(float64(r.StateManager.GetUpgradesInProgress(state)))
  +	r.OperatorMetrics.upgradesDone.Set(float64(r.StateManager.GetUpgradesDone(state)))
  +	r.OperatorMetrics.upgradesAvailable.Set(...)
  ```
  </details>
- **过渡期保留包级别名以兼容旧路径**:`ClusterPolicyReconciler.SetupWithManager` 里新增 `clusterPolicyCtrl.operatorMetrics = r.OperatorMetrics`,即仍把注入对象回填给老的包级变量——说明解耦是分步进行,ClusterPolicy 主 reconcile 链路尚未完全切到 `r.OperatorMetrics`。
  <details><summary>代码依据 controllers/clusterpolicy_controller.go</summary>

  ```diff
   type ClusterPolicyReconciler struct {
  +	OperatorMetrics  *OperatorMetrics
   	conditionUpdater conditions.Updater
   }
  ...
  +	clusterPolicyCtrl.operatorMetrics = r.OperatorMetrics
  ```
  </details>
- **CI 供应链加固(harden git workflows)**:多份 `.github/workflows/*.yaml` 给 checkout 加 `persist-credentials: false`、给 job 补 `permissions: contents: read`。属安全收紧,与算力运行时无关,记一笔不展开。

### 后续发展方向 [AI]
- 指标子系统正从「与 ClusterPolicyController 强绑定的包级状态」往「可独立构造/注入的对象」迁移,利于多控制器共享与单测;但本期只迁完 Upgrade 链路、ClusterPolicy 链路靠回填别名兼容,后续应有第二步把 `clusterPolicyCtrl.operatorMetrics` 包级变量彻底删除。证据仅覆盖两个 reconciler 的注入与 upgrade 链路改写,未见 operator_metrics.go 内部结构变化。
- 本期 **ClusterPolicy CRD 无任何字段增删**(API/CRD 路径探测为空),`clusterpolicy_types.go` 未动,功能面无变化。

## kubernetes-sigs/dra-driver-nvidia-gpu: a89291ec -> 779a7dd0
- 比较 / Release: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/a89291ec6dfffaf06d6bb3f9b46231c36086007e...779a7dd0506915a9fa96df11bbdd5010d53a199a | ahead=7 | files=16 | Release: v0.4.1-rc.1

### AI 总结重点(源码 diff 为据)
- **纯文档:新增 4 份参考/指南页,首次把 `resource.nvidia.com/v1beta1` 共享能力面集中成文**(无 `cmd/`/`api/`/helm 模板代码改动,API/CRD 路径探测为空)。`api.md` 文档化 `GpuConfig`/`MigDeviceConfig` 的 `sharing` 配置:strategy 取 `TimeSlicing`|`MPS`,MPS 支持 `defaultActiveThreadPercentage`、`defaultPinnedDeviceMemoryLimit`、`defaultPerDevicePinnedMemoryLimit`(按 device index/UUID 覆盖)。
  <details><summary>代码依据 site/content/docs/reference/api.md</summary>

  ```diff
  +### GpuConfig
  +sharing:
  +  strategy: TimeSlicing
  +  timeSlicingConfig:
  +    interval: Default       # Default | Short | Medium | Long
  +---
  +sharing:
  +  strategy: MPS
  +  mpsConfig:
  +    defaultActiveThreadPercentage: 50
  +    defaultPinnedDeviceMemoryLimit: "4Gi"
  +    defaultPerDevicePinnedMemoryLimit:
  +      "0": "2Gi"
  ```
  </details>
- **feature-gates.md 给出完整 gate 矩阵 + 互斥/依赖约束**,这是判断 DRA 驱动能力成熟度的最佳信号:`TimeSlicingSettings`/`MPSSupport`/`PassthroughSupport`/`DynamicMIG`/`NVMLDeviceHealthCheck`/`DeviceMetadata` 均 Alpha 默认关;`IMEXDaemonsWithDNSNames`/`ComputeDomainCliques`/`CrashOnNVLinkFabricErrors` 已 Beta 默认开。明确列出 `DynamicMIG` 与 Passthrough/NVMLHealthCheck/MPS 互斥,`DeviceMetadata` 依赖 `PassthroughSupport` 等。
  <details><summary>代码依据 site/content/docs/reference/feature-gates.md</summary>

  ```diff
  +| `TimeSlicingSettings` | Alpha | `false` | 自定义 CUDA 时分参数 |
  +| `MPSSupport` | Alpha | `false` | GpuConfig/MigDeviceConfig 的 MPS 共享 |
  +| `IMEXDaemonsWithDNSNames` | Beta | `true` | IMEX 用 DNS 名而非裸 IP;ComputeDomainCliques 依赖项 |
  +| `PassthroughSupport` | Alpha | `false` | VfioDeviceConfig 的 VFIO 直通分配 |
  +| `DynamicMIG` | Alpha | `false` | 动态 MIG 分配与重配;K8s 1.33–1.35 需 DRAPartitionableDevices |
  +| `ComputeDomainCliques` | Beta | `true` | 用 ComputeDomainClique CRD 跟踪 IMEX 守护成员 |
  +| `CrashOnNVLinkFabricErrors` | Beta | `true` | NVLink fabric 错误时 crash 而非回退非 fabric |
  ```
  </details>
- **helm-values.md 披露两条关键约束**:① `gpuResourcesEnabledOverride` 必须置 `true` 才能开 GPU 分配——因为在 [KEP 5004](https://github.com/kubernetes/enhancements/issues/5004) GA 前,DRA 驱动不能与传统 device plugin 共存;② `resourceApiVersion` 留空时自动探测 `v1 > v1beta2 > v1beta1`,可应对集群 API 能力上报错误。GPU 与 ComputeDomain 两套插件可独立 enable/disable。
  <details><summary>代码依据 site/content/docs/reference/helm-values.md</summary>

  ```diff
  +| `gpuResourcesEnabledOverride` | `false` | 须 true 才能开 GPU 分配;KEP 5004 GA 前不能与标准 device plugin 共存 |
  +| `resourceApiVersion` | `""` | 空则自动取最高:v1 > v1beta2 > v1beta1 |
  +| `resources.computeDomains.enabled` | `true` | 部署 ComputeDomain 控制器+kubelet 插件 |
  ```
  </details>

### 后续发展方向 [AI]
- 文档把 DRA 驱动的共享路径(TimeSlicing/MPS/MIG/VFIO 直通)与昔日 device-plugin 的 time-slicing/MPS 配置面完整对齐,印证 NVIDIA 把 GPU 共享主线压到 DRA `resource.nvidia.com/v1beta1` 上;但 TimeSlicing/MPS/DynamicMIG/Passthrough 全是 Alpha 默认关,生产成熟度仍受 KEP 5004(device plugin 共存)未 GA 制约。证据仅文档,未见对应特性代码改动,各 gate 的真实实现状态需回查 `pkg/featuregates`。
- 本期为 v0.4.1-rc.1 的发布前文档收尾,版本号继续走 hugo `driver_release_tag` 参数化(承接 06-27)。实质 API/控制面无新增。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅 bump/CI/merge 或无新提交)</summary>

- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(master,无新提交)
- NVIDIA/mig-parted(无新提交)
- kai-scheduler/KAI-Scheduler(无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=a37981bdf128ace73550200724b00958d1d1db18 branch=main release=v26.3.3 scanned=2026-06-28 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=41dd4444a23ffc387262e7159b4696fb688553a2 branch=main release=v1.19.1 scanned=2026-06-28 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=f41a0200e00d232bd7e257b22600883346eea079 branch=main release=— scanned=2026-06-28 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.3 scanned=2026-06-28 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=779a7dd0506915a9fa96df11bbdd5010d53a199a branch=main release=v0.4.1-rc.1 scanned=2026-06-28 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-28 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=5dc3caa478807fec0fc6a2160ef9e8f056300e4e branch=main release=v0.14.2 scanned=2026-06-28 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=58708edb4083f81b35a3656327c021889f0d0829 branch=main release=v0.16.0 scanned=2026-06-28 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-28 -->
