# 昇腾算力栈 diff 雷达 2026-08-04

## 摘要
- **npu-operator 落地本 task 迄今最大一次架构合并**(!109 `feat: add vNPU and DRA component`):一个 `NPUClusterPolicy` CR 里新增 `vnpu`、`dra`、`volcano` 三个顶层 spec,把「昇腾软切分 vNPU 全栈」+「K8s DRA 原生路径」+「自管 Volcano(含 admission webhook)」全部纳入 operator 编排。这是 openfuyao-weekly 上周报道的产品化路线在**代码层的兑现**。
- 同时补齐 operator 的**调度放置能力**:新增 `PlacementSpec`(nodeSelector+tolerations)inline 进几乎所有组件 spec,`daemonsets` 也加了公共 `nodeSelector`——之前只能配 tolerations。
- 其余 8 个仓(含 mind-cluster component/ 全部子目录、vNPU、npu-dra-plugin、npu-driver-installer 等)本期在跟踪范围内**无代码改动**;mind-cluster 虽有 4 个提交,但全落在 `helm-deploy-tool`/`mindio tft` 测试,不在 `component/` 跟踪路径内。

## 当日重要改变
- **npu-operator [API/CRD变更][新能力][架构方向]** `NPUClusterPolicySpec` 新增 `VNPU VNPUSpec`、`DRA DRASpec`、`Volcano VolcanoSpec` 三个顶层字段,operator 从「管驱动/device-plugin/调度」扩到「管 vNPU 软切分 + DRA + 自管 Volcano webhook」。证据:`api/v1/npuclusterpolicy_types.go`、新增 `assets/volcano/vnpu-crds/*`(9 个 Volcano CRD)、`internal/controller/resources_workload.go`。https://gitcode.com/openFuyao/npu-operator/merge_requests/109
- **npu-operator [新能力]** DRA 路径引入 **CEL selector 驱动的 DeviceClass 模板** + NUMA 亲和设备属性(`device.attributes["npu.huawei.com"].numaNode`),软切分 `ShareCount` 默认 **16**(每物理 NPU 的 soft-share vNPU 实例数)。证据:`api/v1/npuclusterpolicy_types.go`(`DRADeviceClassTemplate.SelectorCEL`、`DRASoftVNPUSpec.ShareCount`)、`outputs/manual-validation/dra-cel-selector.yaml`。
- **npu-operator [API/CRD变更]** 全组件新增 `PlacementSpec`(nodeSelector + tolerations)inline,`daemonsets.nodeSelector` 从无到有。证据:`api/v1/npuclusterpolicy_types.go`、`charts/npu-operator/values.yaml`。

## npu-operator: 53299373 -> 7cddacb5
- 比较: 53299373d36e46a82415a093cde55e7df240d7f7..7cddacb5 | tag: v26.6.0 | commits=2(实为单个 !109 合并)| truncated=false
- 源:https://gitcode.com/openFuyao/npu-operator/merge_requests/109

### AI 总结重点(源码 diff 为据)

- **`NPUClusterPolicySpec` 增三个顶层组件族:vNPU 软切分、DRA 原生分配、自管 Volcano**。之前 spec 只有 driver/ociRuntime/vcscheduler/vccontroller/operator/mindio 等;此次加 `Volcano`、`VNPU`、`DRA` 三个新字段(全 `omitempty`,默认关)。意味着 operator 的职责边界从「昇腾底座 + 独占调度」正式扩到「软虚拟化 + DRA + 调度器生命周期」全托管。
  <details><summary>代码依据 api/v1/npuclusterpolicy_types.go</summary>

  ```diff
   	// Volcano component spec
  +	Volcano      VolcanoSpec    `json:"volcano,omitempty"`
   	VCScheduler  SchedulerSpec  `json:"vcscheduler"`
   	VCController ControllerSpec `json:"vccontroller"`
  @@
  +	// vNPU component spec
  +	VNPU VNPUSpec `json:"vnpu,omitempty"`
  +	// Dynamic Resource Allocation component spec
  +	DRA DRASpec `json:"dra,omitempty"`
  ```
  </details>

- **vNPU 软切分栈拆成 4 个受管组件**:`ClientUpdate`(acl-client-update,注入运行时劫持)、`DevicePlugin`(npu-device-plugin)、`Exporter`(xpu-exporter,默认 `Managed=false`)+ 顶层 `VNPUSpec` 携 `NodeModeConfig`/`VirtualTemplateConfig`(对应昇腾 `vnpu.node-mode.config` 与 `vnpu.virtual-template.config` 两份配置)。这与 HAMi-ascend 走 CANN Runtime API 劫持是同一机制家族,但这里由 operator 统一下发模板。
  <details><summary>代码依据 api/v1/npuclusterpolicy_types.go</summary>

  ```diff
  +type VNPUSpec struct {
  +	// +default=false
  +	Managed bool `json:"managed,omitempty"`
  +	PlacementSpec `json:",inline"`
  +	// Node mode config used by vnpu.node-mode.config
  +	NodeModeConfig string `json:"nodeModeConfig,omitempty"`
  +	// Virtual template config used by vnpu.virtual-template.config
  +	VirtualTemplateConfig string `json:"virtualTemplateConfig,omitempty"`
  +	ClientUpdate VNPUComponentSpec `json:"clientUpdate,omitempty"`
  +	DevicePlugin VNPUDevicePluginSpec `json:"devicePlugin,omitempty"`
  +	// vNPU exporter daemonset
  +	// (VNPUExporterSpec: Managed +default=false)
  ```
  </details>

- **DRA 路径:CEL selector + NUMA 属性 + 软切 ShareCount=16**。`DRASpec` 带 `DriverName`(须与 DeviceClass selector 匹配)、`DeviceProfile`、`CDIRoot`、`NumDevices`、`HealthcheckPort`(<0 关健康检查);`DRADeviceClassTemplate` 用 `SelectorCEL` 表达式选设备;`DRASoftVNPUSpec.ShareCount` 默认 16(每物理 NPU 软切实例数)+ shm 目录/设备配置目录/profile 配置。手动验证样例证实 DeviceClass 用 `device.attributes["npu.huawei.com"].numaNode == 4` 这类 CEL 做 NUMA 亲和选卡。
  <details><summary>代码依据 api/v1/npuclusterpolicy_types.go + outputs/manual-validation/dra-cel-selector.yaml</summary>

  ```diff
  +type DRADeviceClassTemplate struct {
  +	Name string `json:"name,omitempty"`
  +	// CEL selector expression
  +	SelectorCEL string `json:"selectorCEL,omitempty"`
  +}
  +type DRASoftVNPUSpec struct {
  +	// Number of soft-share vNPU instances per physical NPU
  +	// +default=16
  +	ShareCount int32 `json:"shareCount,omitempty"`
  +	SoftShareShmDir string `json:"softShareShmDir,omitempty"`
  +	NPUProfileConfigPath string `json:"npuProfileConfigPath,omitempty"`
  +}
  ```
  ```yaml
  # outputs/manual-validation/dra-cel-selector.yaml
  kind: DeviceClass
  metadata: { name: numa4.npu.huawei.com }
  spec:
    selectors:
      - cel:
          expression: device.driver == "npu.huawei.com" && device.attributes["npu.huawei.com"].numaNode == 4
  ```
  </details>

- **operator 现在自管 Volcano admission webhook 全生命周期**。`resources.go` 常量表新增 `volcanoAdmissionDeploymentName`、`volcanoAdmissionInitJobName`、`volcanoAdmissionSecretName`、`volcanoAdmissionCAKey`、`volcanoSystemNamespace`,并新增 `volcanoAdmissionSecretHashAnnotation` 做 secret 变更追踪。`VolcanoSpec` 有 `Flavor`(枚举 `mindcluster`/`vnpu`/`external`)决定用哪套 Volcano 资产,`external` 表示 Volcano 由 operator 外部托管。这让「默认 Volcano」与「vNPU 专用 Volcano」两套调度器资产可切换。
  <details><summary>代码依据 internal/controller/resources.go + types.go</summary>

  ```diff
  +	volcanoAdmissionSecretHashAnnotation = "openfuyao.com/volcano-admission-secret-hash"
  +	volcanoAdmissionDeploymentName   = "volcano-admission"
  +	volcanoAdmissionInitJobName      = "volcano-admission-init"
  +	volcanoAdmissionSecretName       = "volcano-admission-secret"
  +	volcanoAdmissionCAKey            = "ca.crt"
  +	volcanoSystemNamespace           = "volcano-system"
  ```
  ```diff
  +// +kubebuilder:validation:Enum=mindcluster;vnpu;external
  +type VolcanoFlavor string
  +	VolcanoFlavorMindCluster VolcanoFlavor = "mindcluster"
  +	VolcanoFlavorVNPU        VolcanoFlavor = "vnpu"
  +	VolcanoFlavorExternal    VolcanoFlavor = "external"
  ```
  </details>

- **DRA kubelet-plugin / vcannrt-installer / dra-webhook 三个新 daemonset/deployment 进入 operator 编排**。`resources.go` 新增常量 `draKubeletPluginDaemonSetName`(npu-dra-kubeletplugin)、`draVCANNRTInstallerDaemonSetName`(vcannrt-installer)、`draWebhookDeploymentName`/`draWebhookServiceName`,以及 vNPU 侧 `vnpuClientUpdateDaemonSetName`、`vnpuDevicePluginDaemonSetName`、`vnpuExporterDaemonSetName`(xpu-exporter)。控制器逻辑拆分成 `resources_workload.go`(Deployment reconcile hooks + transformer 链)、`resources_basic_hooks.go`(SA/Role/ClusterRole/Secret/Job 等基础资源 hooks,引入 volcano batch/flow/scheduling apis)、`resources_getters.go`(各组件 LogRotate/Resources getter,新增 vnpu*/dra* getter)。
  <details><summary>代码依据 internal/controller/resources.go</summary>

  ```diff
  +	vnpuClientUpdateDaemonSetName    = "npu-client-update-daemonset"
  +	vnpuDevicePluginDaemonSetName    = "npu-device-plugin-daemonset"
  +	vnpuExporterDaemonSetName        = "xpu-exporter-daemonset"
  +	draKubeletPluginDaemonSetName    = "npu-dra-kubeletplugin"
  +	draVCANNRTInstallerDaemonSetName = "vcannrt-installer"
  +	draWebhookDeploymentName         = "dra-webhook"
  ```
  </details>

- **DRA webhook 是 ValidatingWebhookConfiguration**(带 `CABundle`/`FailurePolicy` 枚举 Ignore;Fail、`Port` 默认 443、TLS 证书/私钥路径),配套 `dra-webhook-service`。但 `values.yaml` 里 `draVCANNRTInstaller` 与 `draWebhook` 镜像仍指向 `docker.io/library/...` 占位且注释「no official chart image yet; override before enabling」——**DRA webhook 与 vcannrt-installer 尚未有官方公开镜像,启用前需自建/覆盖**,说明这条 DRA 链路还处于「代码就绪、镜像未 GA」状态。
  <details><summary>代码依据 charts/npu-operator/values.yaml</summary>

  ```diff
  +  draVCANNRTInstaller:
  +    # DRA br_init_dev keeps this installer image under docker.io/library, but it is not publicly pullable ...
  +    repository: docker.io/library/acl_client_update
  +  draWebhook:
  +    # DRA br_init_dev has webhook code but no official chart image yet; override before enabling.
  +    repository: docker.io/library/ascend-npu-dra-webhook
  ```
  </details>

- **全组件放置能力补齐**:新增 `PlacementSpec{ NodeSelector, Tolerations }` 并 inline 进 Driver/OCIRuntime/VCScheduler/VCController/Trainer 等;`DaemonsetsSpec` 加公共 `NodeSelector`。此前 daemonset 只能配 tolerations,现在可按 nodeSelector 精确投放(如把 vNPU/DRA 组件只投到特定型号昇腾节点)。
  <details><summary>代码依据 api/v1/npuclusterpolicy_types.go + values.yaml</summary>

  ```diff
  +type PlacementSpec struct {
  +	NodeSelector map[string]string `json:"nodeSelector,omitempty"`
  +	Tolerations []corev1.Toleration `json:"tolerations,omitempty"`
  +}
  @@ DaemonsetsSpec
  +	// Common node selector
  +	NodeSelector map[string]string `json:"nodeSelector,omitempty"`
  ```
  </details>

### 后续发展方向 [AI]
- **operator 正在成为昇腾侧「vNPU + DRA + Volcano」的单一控制面**,与 openfuyao-weekly 报道的产品化路线一致;从代码看,vNPU(软切/CANN 劫持)与 DRA(原生 K8s 资源分配 + CEL/NUMA 选卡)是**两条并行接入路径**,同一 CR 内可分别启停(`VNPUSpec.Managed`/`DRASpec.Managed` 默认均 false)。证据覆盖 spec 定义与常量/资产注册,**未覆盖 reconcile 主循环如何按 flavor 分发**(components.go 的 patch 未在本次节选完整读到,只见常量与 hooks 拆分)。
- **DRA 链路距 GA 尚有镜像缺口**:webhook/vcannrt-installer 镜像仍为占位,启用需自建。软切 `ShareCount` 默认 16、DeviceClass 走 CEL——这套「按 NUMA 属性 + CEL 表达式选卡」的 DRA 模型值得对标我们产品的 GPU DRA 设计。证据仅到 spec/样例 yaml,**未见 kubelet-plugin 侧如何上报 `numaNode` 设备属性**(npu-dra-plugin 仓本期无改动)。
- **Volcano flavor 抽象(mindcluster/vnpu/external)** 说明昇腾栈开始正视「用户已自带 Volcano」的场景(external),避免与既有调度器冲突;这对多租户/已有 Volcano 集群的接入友好度是正向信号。证据仅到枚举定义,未见 external 分支的具体跳过逻辑。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- mind-cluster:区间有 4 提交,但均在 `helm-deploy-tool`(版本替换/清理)与 `mindio tft`(删测试私钥),**不落在跟踪的 `component/*` 子目录**,组件代码无改动。
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交(注:operator 侧 DRA 编排已就绪,但 driver 本仓未跟进,存在「编排先行、驱动/镜像待补」的时间差)
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=4d1408a113ead8e0df64a656a0e12337ae707799 tag=v26.1.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=vNPU sha=5366f8e44a2f114584ed0f0099a25cf487aa63b7 tag=v0.1.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b6d9bffb26ce91cef9e7ceb70736f7eddbfa6a58 tag=v26.6.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-04 -->
</content>
</invoke>
