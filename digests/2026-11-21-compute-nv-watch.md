# NVIDIA 算力栈 diff 雷达 2026-11-21

## 摘要
- **DRA 驱动动了 VFIO 直通的公开 API**:`VfioDeviceConfig` 新增 `driverOverride` 字段(目前只认 `vfio-pci`),用来在 Grace 这类平台上把默认的 `nvgrace_gpu_vfio_pci` 变体覆盖回标准 `vfio-pci`。直通配置面第一次把"绑哪个内核驱动"交给用户声明。
- **DRA 驱动的 XID 健康判定换了判据**:从"内置非致命 XID 清单(13/31/43/45/68/109)"改成"每次事件向 NVML 查 recovery action 再分类",`--additional-xids-to-ignore` 的语义从"追加到内置清单"变成"无条件覆盖"。本期 diff 里是文档落地,代码在本窗口之前已合入(本期只见测试+文档改动)。
- **gpu-operator 支持多副本 HA**:`operator.replicaCount` + PDB + podAntiAffinity + `--leader-election-warmup`,standby 副本预热 informer 缓存但不注册 reconcile 指标。同时认证套件删掉 nvidia-peermem RDMA 用例,TS1006~TS1008 重编号为 TS1006/TS1007。

## 当日重要改变
- kubernetes-sigs/dra-driver-nvidia-gpu [API/CRD变更] `api/nvidia.com/resource/v1beta1/vfiodeviceconfig.go` 新增 `DriverOverride *PassthroughDriver` 字段与 `PassthroughDriver` 类型(枚举只有 `vfio-pci`),`docs/reference/api.md` 同步新增 `driverOverride` 字段说明。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/3b0f381151
- kubernetes-sigs/dra-driver-nvidia-gpu [弃用/移除] 内置非致命 XID 清单被移除,`--additional-xids-to-ignore` 从"追加"降级为"覆盖";文档明确写 "In v0.5.0 and earlier ... The built-in list is removed and the argument is now an override"。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/42069c02ea
- NVIDIA/gpu-operator [新能力] operator 自身支持多副本:`operator.replicaCount`、`podDisruptionBudget`、`podAntiAffinity`、`--leader-election-warmup` 四个新配置项 + 新模板 `poddisruptionbudget.yaml`。 https://github.com/NVIDIA/gpu-operator/pull/3103
- NVIDIA/gpu-operator [弃用/移除] 认证套件删除 `EnableRDMA`/`isHostMOFED` 与非 DMA-BUF 的 RDMA 路径,`RDMA.DMABuf` 字段消失,测试编号 TS1006(RDMA)/TS1007(RDMA+DMA-BUF)/TS1008(GDRCopy)压缩为 TS1006(RDMA+DMA-BUF)/TS1007(GDRCopy)。 https://github.com/NVIDIA/gpu-operator/pull/3267

## kubernetes-sigs/dra-driver-nvidia-gpu: e775fdb6 -> 9ca111cf
- 比较: e775fdb63e593a121b40fc1cc4c9a9c89955e635 -> 9ca111cf | ahead=19 | files=28 | Release: v0.5.1
- https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/e775fdb63e593a121b40fc1cc4c9a9c89955e635...9ca111cffd06cf9686b704ea5eb85771781cc2b0

### AI 总结重点(源码 diff 为据)
- **VFIO 直通新增 `driverOverride` 配置项,并把它贯通到内核模块加载**:`VfioDeviceConfig` 从"只有 `Iommu` 一个字段"变成多了 `DriverOverride *PassthroughDriver`;`Validate()` 先校验 override 合法性再校验 IOMMU;新增 `PassthroughDriver.Validate()` 只放行 `vfio-pci`。

  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/vfiodeviceconfig.go</summary>

  ```diff
   type VfioDeviceConfig struct {
   	metav1.TypeMeta `json:",inline"`
  -	Iommu           *IOMMUConfig `json:"iommu,omitempty"`
  +	// DriverOverride specifies the passthrough driver to use for the VFIO device.
  +	// This is relevant in systems like the NVIDIA Grace where we may want to
  +	// override the default `nvgrace_gpu_vfio_pci` passthrough driver variant
  +	// Supported values are:
  +	// - vfio-pci: Use the plain `vfio-pci` driver.
  +	DriverOverride *PassthroughDriver `json:"driverOverride,omitempty"`
  +	Iommu          *IOMMUConfig       `json:"iommu,omitempty"`
   }

   func (c *VfioDeviceConfig) Validate() error {
  +	if c.DriverOverride != nil {
  +		if err := c.DriverOverride.Validate(); err != nil {
  +			return err
  +		}
  +	}
   	if c.Iommu == nil {
   		return nil
   	}
  +
  +const (
  +	// PassthroughDriverVfioPci is the vfio-pci driver.
  +	PassthroughDriverVfioPci PassthroughDriver = "vfio-pci"
  +)
  ```
  </details>

- **`VfioPciManager.Configure` 签名从 `(ctx, info)` 变成 `(ctx, config, info)`**:模块名不再只来自探测结果 `info.vfioModule`,而是在 config 指定 override 时用 `getVfioModuleName()` 把驱动名里的 `-` 换成 `_`(`vfio-pci` → `vfio_pci`)后再 `checkKernelModuleLoaded`/`loadKernelModule`。调用方 `applyVfioDeviceConfig` 同步把 config 传了下去。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/vfio-device.go + cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  -func (vm *VfioPciManager) Configure(ctx context.Context, info *VfioDeviceInfo) error {
  -	loaded, err := vm.checkKernelModuleLoaded(info.vfioModule)
  +func (vm *VfioPciManager) Configure(ctx context.Context, config *configapi.VfioDeviceConfig, info *VfioDeviceInfo) error {
  +	vfioModule := info.vfioModule
  +	// Use driver override if specified in the config.
  +	if config != nil && config.DriverOverride != nil {
  +		vfioDriver := string(*config.DriverOverride)
  +		vfioModule = getVfioModuleName(vfioDriver)
  +	}
  +
  +	loaded, err := vm.checkKernelModuleLoaded(vfioModule)

  +// Module names will only ever contain underscore characters and not dashes.
  +func getVfioModuleName(vfioDriver string) string {
  +	return strings.ReplaceAll(vfioDriver, "-", "_")
  +}

   	for i, r := range results {
  -		if err := s.vfioPciManager.Configure(ctx, infos[i]); err != nil {
  +		if err := s.vfioPciManager.Configure(ctx, config, infos[i]); err != nil {
  ```
  </details>

- **XID 分类判据改为 NVML recovery action**(本期为文档落地):新文档给出 action→分类映射表,`NONE`/`RECOVER IMEX DOMAIN` 判非致命打 `None` taint,`GPU RESET`/`NODE REBOOT`/`DRAIN P2P`/`DRAIN AND RESET` 判致命打 `NoSchedule`;查不到 recovery action(例如拿不到父 GPU handle)时**默认判致命**。另一处行为明确化:同一 key 上的 `NoSchedule` taint 不会被后来的非致命事件降级成 `None`。

  <details><summary>代码依据 site/content/docs/guides/gpu-health-checking.md</summary>

  ```diff
  -By default, the driver classifies the following XID errors as non-fatal ...
  -| Code | Description |
  -| 13 | Graphics Engine Exception |
  -| 31 | GPU memory page fault |
  -| 43 | GPU stopped processing |
  -| 45 | Preemptive cleanup, due to previous errors |
  -| 68 | Video processor exception |
  -| 109 | Context Switch Timeout Error |
  -You can classify additional XID errors as non-fatal by specifying ... `--additional-xids-to-ignore`
  +For each XID event, the driver queries the recovery action that NVML currently reports for the parent GPU and classifies the event from that action:
  +| `NONE` | Non-fatal | `None` |
  +| `RECOVER IMEX DOMAIN` | Non-fatal | `None` |
  +| `GPU RESET` | Fatal | `NoSchedule` |
  +| `NODE REBOOT` | Fatal | `NoSchedule` |
  +| `DRAIN P2P` | Fatal | `NoSchedule` |
  +| `DRAIN AND RESET` | Fatal | `NoSchedule` |
  +If the driver cannot query the recovery action ... the driver treats the event as fatal unless the XID is listed in `--additional-xids-to-ignore`.
  +> In v0.5.0 and earlier, the driver classified XIDs 13, 31, 43, 45, 68, and 109
  +> as non-fatal from a built-in list, and `--additional-xids-to-ignore` added to
  +> that list. The built-in list is removed and the argument is now an override.
  -  key. If multiple XID events occur on the same device, only the most recent value is retained.
  +  key. Once a device carries a `NoSchedule` taint for a key, later events on that
  +  key do not change it; ... so a subsequent non-fatal XID cannot downgrade it to `None`.
  ```
  </details>

- **MIG 回收不再"算不清就拆"**:新增 `PreparedClaim.GetHeldDevices()` 返回 `([]DeviceName, bool)` 并在遍历 `Status.Allocation.Devices.Results` 时**跳过 `r.Driver != DriverName` 的其他驱动结果**;`DestroyUnknownMIGDevices` 一旦有任一 claim 的持有设备算不出来就整体 `return`(放弃本轮 teardown)而不是把不在清单里的 MIG 设备全销毁;`deleteMigDevIfExistsAndNotUsedByCompletedClaim` 同样改为"算不出来就保留设备";`rollbackPartiallyPreparedMIGDevices` 对 `Status.Allocation == nil` 的 claim 直接早退。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/prepared.go + device_state.go</summary>

  ```diff
  +func (c *PreparedClaim) GetHeldDevices() ([]DeviceName, bool) {
  +	if c.Status.Allocation != nil {
  +		for _, r := range results {
  +			if r.Driver != DriverName {
  +				continue
  +			}
  +			names = append(names, r.Device)
  +		}
  +		return names, true
  +	}
  +	for _, group := range c.PreparedDevices {
  +		if group == nil {
  +			return nil, false
  +		}
  +		for _, device := range group.Devices {
  +			name, ok := device.CheckpointedName()
  +			if !ok {
  +				return nil, false
  +			}

  -	for _, cpclaim := range filtered {
  -		for _, res := range cpclaim.Status.Allocation.Devices.Results {
  -			expectedDeviceNames = append(expectedDeviceNames, res.Device)
  +	for uid, cpclaim := range filtered {
  +		names, ok := cpclaim.GetHeldDevices()
  +		if !ok {
  +			// Everything not on this list is about to be destroyed.
  +			klog.Errorf("%s: skip teardown: cannot tell which devices claim %s holds", ...)
  +			return
   		}
  +		expectedDeviceNames = append(expectedDeviceNames, names...)

  +	if pc.Status.Allocation == nil {
  +		// A claim in this state has no PreparedDevices checkpointed yet ...
  +		return nil
  +	}
  ```
  </details>

- **ComputeDomain 守护配置文件改走 `os.Root` 写入,并把"全量校验→再生效"前置**:`WriteConfigFile` 不再 `os.WriteFile(s.configTmplPath, ...)`,而是 `os.OpenRoot(configFilesRoot)` → `configRoot.OpenRoot(domainID)` → `domainRoot.WriteFile("imexd.cfg.tmpl", ...)`,阻断 per-domain 目录里的 symlink 把写入重定向到别的 domain 目录或 config root 之外(该目录是读写 bind-mount 进守护容器的);`Prepare` 里的 `os.MkdirAll` 被移走。同时 `Prepare` 新增 `buildPreparePlan` 预检:在 overlap 检查和 checkpoint 之前就把 claim 判死,拆出的 `validateConfigs` 把所有 config 先 Normalize+Validate 完再 apply,并把这些确定性失败包成 `permanentError` 不再重试。

  <details><summary>代码依据 cmd/compute-domain-kubelet-plugin/computedomain.go + device_state.go</summary>

  ```diff
  -	configBytes, err := os.ReadFile(ComputeDomainDaemonConfigTemplatePath)
  +	configBytes, err := os.ReadFile(s.templateSourcePath)
  -	if err := os.WriteFile(s.configTmplPath, configBytes, 0644); err != nil {
  +	// ... write through an os.Root scoped to that directory: a symlink there can't redirect the write to
  +	// another domain's directory or outside the config root.
  +	configRoot, err := os.OpenRoot(s.manager.configFilesRoot)
  +	domainRoot, err := configRoot.OpenRoot(s.domainID)
  +	if err := domainRoot.WriteFile("imexd.cfg.tmpl", configBytes, 0644); err != nil {

  +	// The preflight reads only the claim and state fixed for this process, so a
  +	// claim it rejects can never succeed. Fail it permanently before the
  +	// retryable overlap check, and before checkpointing an entry that Unprepare
  +	// may be unable to clear.
  +	plan, err := s.buildPreparePlan(claim)
  -	preparedDevices, err := s.prepareDevices(ctx, claim)
  +	preparedDevices, err := s.applyPreparePlan(ctx, claim, plan)

  +// validateConfigs normalizes and validates every config selected for the claim
  +// ... Nothing is applied until this returns, so one bad config cannot land after a good one has taken effect.
  -			return nil, fmt.Errorf("error normalizing config: %w", err)
  +			return nil, permanentError{fmt.Errorf("error normalizing config: %w", err)}
  ```
  </details>

- **新增一页"GPU sharing"概念文档,把共享模型正式二分为 user-mediated / system-mediated**:前者多 workload 引用同一 `ResourceClaim`(受命名空间约束,默认 CUDA 时分,可配时分间隔或 MPS),后者靠 consumable capacity 让 scheduler 把同一设备分给多个独立 claim(可跨命名空间)。文档同时给出硬边界:consumable capacity 只是**调度账面**,运行时不限显存/算力,启用后**不能用 MPS**;`MPSSupport` 与 `DynamicMIG` 互斥;配置化时分/MPS/consumable capacity 三者**都还是 Alpha 且默认关**,consumable capacity 还要 K8s ≥ v1.34 并开 `DRAConsumableCapacity` 门控。

  <details><summary>代码依据 site/content/docs/concepts/gpu-sharing.md(新增)</summary>

  ```diff
  +- In user-mediated sharing, you configure workloads to reference one `ResourceClaim`.
  +- In system-mediated sharing, Kubernetes can allocate independent `ResourceClaim` objects to the same device.
  +System-mediated sharing uses consumable capacity.
  +Nothing enforces the request after a workload starts, so a workload can use more than it requested.
  +If you enable consumable capacity for the driver, no workload can use MPS.
  +Configured CUDA time-slicing, MPS, and consumable capacity are Alpha driver features and are disabled by default.
  +| Consumable capacity | `ConsumableShares`, plus a `consumableShares` Helm value | v1.34 or later, with the [`DRAConsumableCapacity`] feature gate enabled on v1.34 and v1.35 |
  +You cannot enable `MPSSupport` and `DynamicMIG` together.
  ```
  </details>

- **MPS 的 shm 大小计算被参数化以便测试**:`getDefaultShmSize()` 变成 `getDefaultShmSize(meminfoPath string)`,`/proc/meminfo` 提成常量 `procMeminfoPath`,行为不变(读不到仍回落 `65536k`)。

  <details><summary>代码依据 cmd/gpu-kubelet-plugin/sharing.go</summary>

  ```diff
  +	// procMeminfoPath is the file the kernel exposes memory statistics through.
  +	procMeminfoPath = "/proc/meminfo"
  -	sizeArg := fmt.Sprintf("size=%v", getDefaultShmSize())
  +	sizeArg := fmt.Sprintf("size=%v", getDefaultShmSize(procMeminfoPath))
  -func getDefaultShmSize() string {
  +func getDefaultShmSize(meminfoPath string) string {
  ```
  </details>

### 后续发展方向 [AI]
- **直通(passthrough)正在从"驱动自己探测"转向"用户声明式指定内核绑定"**:`driverOverride` 现在枚举只有 `vfio-pci` 一个值,但 `PassthroughDriver` 被做成了独立类型 + `Validate()` 开关式校验,扩位点已经留好——Grace/GB200 这类有厂商专用 vfio 变体的平台后续很可能再加值。证据只覆盖 `vfiodeviceconfig.go` + `vfio-device.go` 两个文件的改动,未见对应的 e2e/实机验证。
- **健康判定的事实源从"驱动内置静态表"迁到"NVML 实时 recovery action"**,配套语义是"查不到就当致命"+"NoSchedule 不可被降级"。对运维的直接影响是:同一个 XID 在不同 driver 版本/不同卡上可能给出不同 taint,`--additional-xids-to-ignore` 从兜底参数变成唯一的人工逃生阀。证据只有文档与测试改动,分类函数本体不在本窗口 diff 内,未逐 PR 展开核对实现。
- **DRA 驱动在"不确定就不动手"方向上连续加固**:`GetHeldDevices` 的 `(值, 可判定)` 双返回被同时接到 teardown、MIG 删除、部分回滚三条路径上,且都选择"算不清→保留/放弃本轮"。这类改动的动因通常是生产上出现过误删 MIG 设备;配合 `permanentError` 的引入,kubelet plugin 正在把"可重试错误"和"确定性失败"明确分层。证据覆盖 prepared.go/device_state.go 的 hunk,未见对应的 release note 说明是否算行为变更。
- **共享能力的产品叙事被显式定成两条路**:user-mediated(同一 claim + 时分/MPS)与 system-mediated(独立 claim + consumable capacity),且官方自己把 consumable capacity 定性为"只做调度账面、无运行时隔离"。这正好是 HAMi 这类 hook 式软切分的差异区间——DRA 原生路径短期内不打算做显存硬限。证据只有新增文档页,未见 consumable capacity 的实现代码改动。

## NVIDIA/gpu-operator: 304898f7 -> bf7ada64
- 比较: 304898f717631a3e6da35526385cc44262d60125 -> bf7ada64 | ahead=10 | files=27 | Release: v26.7.3
- https://github.com/NVIDIA/gpu-operator/compare/304898f717631a3e6da35526385cc44262d60125...bf7ada64c97d46edb98b4a7cf54db85e493fac71

### AI 总结重点(源码 diff 为据)
- **operator Deployment 从硬编码 `replicas: 1` 变成 `replicaCount` 可配,并补齐了多副本所需的三件套**:新增 `_helpers.tpl` 里的 `gpu-operator.selectorLabels`(注释明确"Deployment selector 不可变,别放会随 release 变的 label")被 Deployment selector / podAntiAffinity / PDB 三处复用;副本数 > 1 且未自定义 `podAntiAffinity` 时自动注入 `preferredDuringSchedulingIgnoredDuringExecution` 按 hostname 打散;新增 `poddisruptionbudget.yaml`(`minAvailable: 1` + `unhealthyPodEvictionPolicy: AlwaysAllow`,同样只在 `replicaCount > 1` 时渲染);`validations.yaml` 加了 `replicaCount < 1` 直接 `fail` 的护栏。values.yaml 的注释还特意警告:单节点集群上这个 PDB 会堵住 drain。

  <details><summary>代码依据 deployments/gpu-operator/templates/operator.yaml + poddisruptionbudget.yaml + values.yaml + _helpers.tpl</summary>

  ```diff
  -  replicas: 1
  +  replicas: {{ .Values.operator.replicaCount | default 1 }}
     selector:
       matchLabels:
  -      app.kubernetes.io/component: "gpu-operator"
  -      app: "gpu-operator"
  +      {{- include "gpu-operator.selectorLabels" . | nindent 6 }}

  +{{- $addPodAntiAffinity := and (dig "enabled" true $podAntiAffinity) (gt (int .Values.operator.replicaCount) 1) (not (hasKey $affinity "podAntiAffinity")) }}
  +        podAntiAffinity:
  +          preferredDuringSchedulingIgnoredDuringExecution:
  +          - weight: 100
  +            podAffinityTerm:
  +              topologyKey: kubernetes.io/hostname

  +{{- if and (dig "enabled" true $pdb) (gt (int .Values.operator.replicaCount) 1) }}
  +kind: PodDisruptionBudget
  +spec:
  +  minAvailable: 1
  +  unhealthyPodEvictionPolicy: AlwaysAllow

  -  # leaderElection:
  -  #   renewDeadline: 60s
  +  replicaCount: 1
  +  leaderElection:
  +    # renewDeadline: 60s
  +    warmup: false
  +  podAntiAffinity:
  +    enabled: true
  +  podDisruptionBudget:
  +    # Created when operator.replicaCount > 1.
  +    # If only one node can run operator pods, this budget can block draining that node.

  +{{- if and (hasKey .Values.operator "replicaCount") (lt (int .Values.operator.replicaCount) 1) }}
  +{{- fail "operator.replicaCount must be at least 1" }}
  ```
  </details>

- **新增 `--leader-election-warmup` 开关 + `LeaderElectionReleaseOnCancel: true`**:standby 副本可以提前预热 informer 缓存(`options.Controller.EnableWarmup`),leader 退出时主动释放 lease 缩短接管时间;两者都只在 `--leader-elect` 下生效。

  <details><summary>代码依据 cmd/gpu-operator/main.go</summary>

  ```diff
  +	var leaderElectionWarmup bool
  +	flag.BoolVar(&leaderElectionWarmup, "leader-election-warmup", false,
  +		"Enable informer cache warmup for the operator's standby replicas. "+
  +			"Only enabled when the --leader-elect flag is set.")
  -		LeaderElectionID:        "53822513.nvidia.com",
  +		LeaderElectionID:              "53822513.nvidia.com",
  +		LeaderElectionReleaseOnCancel: true,
  +	if enableLeaderElection && leaderElectionWarmup {
  +		options.Controller.EnableWarmup = &leaderElectionWarmup
  +	}
  ```
  </details>

- **Prometheus 指标注册时机从"进程启动"推迟到"拿到 lease 之后"**:`InitOperatorMetrics()` 不再 `metrics.Registry.MustRegister(...)`,改为只构造对象;`OperatorMetrics` 实现 `manager.Runnable`(`Start()` 里才注册)+ `LeaderElectionRunnable`(`NeedLeaderElection() = true`),由 `mgr.Add(operatorMetrics)` 挂上。效果:standby 副本不会暴露 reconcile 指标,避免多副本下同一指标被多实例重复上报。

  <details><summary>代码依据 controllers/operator_metrics.go + cmd/gpu-operator/main.go</summary>

  ```diff
  -// InitOperatorMetrics registers all GPU operator Prometheus metrics with the
  -// controller-runtime registry and returns the initialised OperatorMetrics.
  +// InitOperatorMetrics creates GPU operator Prometheus metrics. The metrics are
  +// registered after the manager becomes leader.
  +// Start implements manager.Runnable. It registers metrics with the
  +// controller-runtime registry.
  +func (m *OperatorMetrics) Start(context.Context) error {
  +	m.register(metrics.Registry)
  +	return nil
  +}
  -	metrics.Registry.MustRegister(
  +// NeedLeaderElection implements manager.LeaderElectionRunnable. Returning true
  +// makes the manager call Start only after this replica acquires the lease, so that a
  +// standby replica does not also expose reconciliation metrics.
  +func (m *OperatorMetrics) NeedLeaderElection() bool { return true }
  +	if err := mgr.Add(operatorMetrics); err != nil {
  +		setupLog.Error(err, "unable to add operator metrics registration")
  ```
  </details>

- **认证套件砍掉 nvidia-peermem 这条 RDMA 路径,只留 DMA-BUF**:`RDMA` 结构体从 `struct { DMABuf bool }` 变成空结构体,测试名固定为 `gpudirect-rdma-dmabuf`,`ib_write_bw` 命令永远带 `--use_cuda_dmabuf`;原来非 DMA-BUF 分支里"打开 `rdma.enabled` → 删 driver pod → 等 driver/device-plugin 就绪"三步(连带 `k8s.Clients.EnableRDMA()` 和 `isHostMOFED()` 两个方法)被整段删除。对外可见的影响是认证用例编号压缩:TS1006/TS1007 两个 RDMA 用例合为 TS1006,GDRCopy 从 TS1008 前移到 TS1007。

  <details><summary>代码依据 internal/certification/testsuite/clusterpolicy/rdma.go + internal/certification/k8s/driver.go + deployments/gpu-operator-certification/kustomization.yaml</summary>

  ```diff
  -// RDMA runs a GPUDirect RDMA bandwidth test between two GPU nodes.
  -type RDMA struct {
  -	DMABuf bool
  -}
  +// RDMA runs a GPUDirect RDMA bandwidth test over DMA-BUF between two GPU nodes.
  +type RDMA struct{}
  -	b.WriteString("/mofed/bin/ib_write_bw --use_cuda=0")
  -	if dmaBuf {
  -		b.WriteString(" --use_cuda_dmabuf")
  -	}
  +	b.WriteString("/mofed/bin/ib_write_bw --use_cuda=0 --use_cuda_dmabuf")
  -	// Step 1: Enable RDMA if not using DMA-BUF. The rdma.enabled field controls
  -	// nvidia_peermem, which is unnecessary with DMA-BUF.
  -	if !t.DMABuf {
  -		if err := clients.EnableRDMA(ctx); err != nil {
  -		// Step 2: Restart driver pods to pick up RDMA config (OnDelete update strategy)
  -		if err := clients.DeletePodsByLabel(ctx, cfg.Namespace, k8s.DriverLabelSelector); err != nil {

  -// EnableRDMA enables GPUDirect RDMA on the appropriate resource.
  -func (c *Clients) EnableRDMA(ctx context.Context) error {
  -// isHostMOFED detects whether MOFED is host-installed by checking for the
  -func (c *Clients) isHostMOFED(ctx context.Context) bool {

  -      #   TS1006 - GPUDirectRDMA               — skipped if fewer than 2 GPU nodes with RDMA hardware
  -      #   TS1007 - GPUDirectRDMA with DMA-BUF  — skipped if fewer than 2 GPU nodes with RDMA hardware
  -      #   TS1008 - GDRCopy                     — skipped if no operator-managed driver pods
  +      #   TS1006 - GPUDirectRDMA with DMA-BUF  — skipped if fewer than 2 GPU nodes with RDMA hardware
  +      #   TS1007 - GDRCopy                     — skipped if no operator-managed driver pods
  ```
  </details>

- **`hack/must-gather.sh` 适配多副本**:变量 `OPERATOR_POD_NAME` 改名为复数 `OPERATOR_PODS`,pod 状态/yaml 用 `-lapp=gpu-operator` 标签取而不是取单个名字,日志改为 for 循环逐副本落盘(文件名带 pod 名),并新增 dump operator 命名空间下的 `leases`(排查 leader 争用用);跳过自身 pod 的判断从 `==` 比较改成 `grep -Fqx` 在列表里找。

  <details><summary>代码依据 hack/must-gather.sh</summary>

  ```diff
  -OPERATOR_POD_NAME=$($K get pods -lapp=gpu-operator -oname -A)
  +OPERATOR_PODS=$($K get pods -lapp=gpu-operator -oname -A)
  -echo "Get the GPU Operator Pod logs"
  -$K logs "${OPERATOR_POD_NAME}" \
  +echo "Get the Leases in ${OPERATOR_NAMESPACE}"
  +$K get leases -oyaml \
  +    > "${ARTIFACT_DIR}/gpu_operator_namespace_leases.yaml"
  +for operator_pod in ${OPERATOR_PODS}; do
  +    operator_pod_name=$(echo "$operator_pod" | cut -d/ -f2)
  +        > "${ARTIFACT_DIR}/gpu_operator_pod_${operator_pod_name}.log"
  -    if [ "${pod}" == "${OPERATOR_POD_NAME}" ]; then
  +    if echo "${OPERATOR_PODS}" | grep -Fqx "${pod}"; then
  ```
  </details>

### 后续发展方向 [AI]
- **gpu-operator 自身开始按"企业级控制面"要求补 HA**:这一轮不是改 GPU 能力,而是把 operator 做成可多副本 + 可打散 + 有 PDB + lease 可观测 + 指标只由 leader 上报。值得抄的点是指标注册绑 `NeedLeaderElection`——多副本 operator 最容易踩的就是 standby 把 reconcile 指标一起上报导致监控翻倍。证据覆盖 main.go/operator_metrics.go/chart 模板,未见 e2e 验证双副本切换时 driver DaemonSet 不被重复 reconcile。
- **RDMA 的官方认证基线已经单边倒向 DMA-BUF,nvidia_peermem 在认证层面被判为 legacy**:判据是整条"开 `rdma.enabled` 再重启 driver pod"的编排被删,而不只是跳过用例。注意这只影响认证套件,`ClusterPolicy.spec.driver.rdma.*` 字段本身没动(本期无 `clusterpolicy_types.go` 改动),所以是"认证不再测"而非"API 废弃"。
- **ISV 自认证用例编号不稳定**:昨天(2026-11-20)刚引入 TS1000~TS1008,今天就压缩成 TS1000~TS1007。任何把 TS 编号写进交付文档或流水线的做法现在都会被下一次重构打断。证据为 kustomization.yaml 的注释块改动。

## kai-scheduler/KAI-Scheduler: 17f87cd1 -> 4c565e5e
- 比较: 17f87cd114655a001631ccabf695b9a0be057ca2 -> 4c565e5e | ahead=9 | files=26 | Release(helper): v0.16.18;**仓库最大 semver 实为 v0.19.0**(helper 取的是 release-0.16 分支的 backport)
- https://github.com/kai-scheduler/KAI-Scheduler/compare/17f87cd114655a001631ccabf695b9a0be057ca2...4c565e5ed2e1543cb8d603b606833472e4e388e3

### AI 总结重点(源码 diff 为据)
- **多卡小数分配的 PodGroup 账面漏乘设备数**:`calculateAllocatedFraction` 原来直接 `return` 单卡 fraction(`req.Portion` 或由显存请求换算出的值),现在统一先算出 `fraction` 再 `fraction.Mul(req.NumDevices)`,乘法溢出时报错而不是静默。影响面是 PodGroup 的 `allocated GPUs` 状态——此前一个"2 卡 × 0.5"的 pod 只被计 0.5 卡。

  <details><summary>代码依据 pkg/podgroupcontroller/controllers/resources/fraction.go</summary>

  ```diff
  +	var fraction resource.Quantity
   	if req.Portion > 0 {
  -		return resource.MustParse(fmt.Sprintf("%g", req.Portion)), nil
  +		fraction = resource.MustParse(fmt.Sprintf("%g", req.Portion))
  +	} else {
  +		fraction, err = getFractionFromMemoryRequest(ctx, req.Memory.Value()/resources.BytesInMiB, pod.Spec.NodeName, kubeClient)
  +	}
  +	fractionStr := fraction.String()
  +	if ok := fraction.Mul(req.NumDevices); !ok {
  +		return resource.Quantity{}, fmt.Errorf("failed to multiply gpu fraction by device count. fraction <%s>, count: %d",
  +			fractionStr, req.NumDevices)
   	}
  -	return getFractionFromMemoryRequest(ctx, req.Memory.Value()/resources.BytesInMiB, pod.Spec.NodeName, kubeClient)
  +	return fraction, nil
  ```
  </details>

- **binder 不再把"绑定 API 响应丢了"当成绑定失败**:`Binder` 新增 `apiReader client.Reader`(未走 cache 的直读)字段,构造函数签名变为 `NewBinder(kubeClient, apiReader, rrs, plugins)`;`Bind` 在 `SubResource("binding").Create` 返错后调用新方法 `isBindingConfirmed()`,用 5s 超时(新常量 `bindingConfirmationTimeout`)直读同名 Pod,UID 与 `spec.nodeName` 都对上就认定绑定已提交、继续走 `PostBind`。

  <details><summary>代码依据 pkg/binder/binding/binder.go</summary>

  ```diff
  +// Keep confirmation from extending a failed binding request indefinitely.
  +const bindingConfirmationTimeout = 5 * time.Second
   type Binder struct {
   	kubeClient                 client.Client
  +	apiReader                  client.Reader
   	if err = b.kubeClient.SubResource("binding").Create(ctx, pod, binding); err != nil {
  -		return fmt.Errorf("failed to bind pod <%s/%s> to node <%s>: %w", ...)
  +		// A lost response can follow a committed bind. Only an uncached read of the
  +		// same Pod on the requested node can confirm that this binding succeeded.
  +		if !b.isBindingConfirmed(ctx, pod, node.Name) {
  +			return fmt.Errorf("failed to bind pod <%s/%s> to node <%s>: %w", ...)
  +		}
  +		logger.Info("Pod binding confirmed after API request returned an error", ...)
   	}
  +func (b *Binder) isBindingConfirmed(ctx context.Context, pod *v1.Pod, nodeName string) bool {
  +	boundPod := &v1.Pod{}
  +	if err := b.apiReader.Get(ctx, client.ObjectKeyFromObject(pod), boundPod); err != nil {
  +		return false
  +	}
  +	return boundPod.UID == pod.UID && boundPod.Spec.NodeName == nodeName
  +}
  ```
  </details>

- **podgrouper 日志不再打整个 owner 对象(含环境变量泄漏)**:`GetPGMetadata` 里 `"topOwner", topOwner` 改为只打 `namespace/name` 与 `GroupKind` 字符串,注释写明"owner 对象内嵌了完整 pod spec,env 值也在里面"。这是一条日志侧的敏感信息收敛。

  <details><summary>代码依据 pkg/podgrouper/podgrouper/podgrouper.go</summary>

  ```diff
  +	// Log a reference only: the owner object embeds the full pod spec, env values included.
   	logger.V(1).Info(fmt.Sprintf("Using %v plugin for pod.", plugin.Name()),
  -		"pod", fmt.Sprintf("%s/%s", pod.Namespace, pod.Name), "topOwner", topOwner)
  +		"pod", fmt.Sprintf("%s/%s", pod.Namespace, pod.Name),
  +		"topOwner", fmt.Sprintf("%s/%s", topOwner.GetNamespace(), topOwner.GetName()),
  +		"topOwnerKind", topOwner.GroupVersionKind().GroupKind().String())
  ```
  </details>

### 后续发展方向 [AI]
- **KAI 这一轮全是"分数 GPU 账本正确性 + 绑定幂等"的生产加固**,没有新调度能力。多卡 fractional(`NumDevices > 1` 且每卡只占一部分)已经是被正式支持且被 bug 覆盖到的形态,说明 KAI 的软切分账本要同时处理"卡数 × 每卡份额"二维,不只是单卡分片。证据为 fraction.go 单个函数的改动,未见 scheduler 侧配额计算是否有同样的漏乘。
- **binder 开始区分"API 调用失败"与"响应丢失"**,用非 cache 直读做二次确认。对自研调度器有直接参考价值:binding subresource 的重试必须幂等,否则一次丢包会让 pod 既绑上又被判失败回滚。证据覆盖 binder.go 的 hunk 与新测试文件 `pkg/binder/controllers/bind_response_test.go`(192 行,未逐条读)。

## 本期无实质改动(折叠)
<details><summary>6 个仓库</summary>

- NVIDIA/gpu-driver-container:ahead=2,只有 "ci: pin GitHub Actions to commit SHA"(6 个 workflow 把 `actions/checkout@v7`、`docker/login-action@v4.8.0`、`NVIDIA/holodeck@v0.5.1` 等从 tag 钉到 commit SHA),无代码/镜像矩阵改动。 https://github.com/NVIDIA/gpu-driver-container/compare/3ac6796228bda663fef350bda0f768d1bc5b35da...db5ac9ce7c25f3c9cbece0c41d0bd02e6919d2bd
- NVIDIA/mig-parted:ahead=4,同样是 workflow Action 钉 SHA,外加 `deployments/container/Dockerfile` 基镜像 `nvcr.io/nvidia/distroless/go` v4.2.1→v4.2.2(v0.15.2)。 https://github.com/NVIDIA/mig-parted/compare/ea1cf1d0bab07cd430c1568667c9c6f69a06ca14...9e4154330f5124ee62bf8f724892f6dcfa1a7145
- NVIDIA/k8s-device-plugin:ahead=2,仅 dependabot 把容器基镜像 distroless/go bump 到 v4.2.2(v0.20.2)。 https://github.com/NVIDIA/k8s-device-plugin/pull/2179
- NVIDIA/nvidia-container-toolkit:无新提交(v1.20.2)
- NVIDIA/dcgm-exporter:无新提交(4.9.0)
- NVIDIA/DCGM:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=bf7ada64c97d46edb98b4a7cf54db85e493fac71 branch=main release=v26.7.3 scanned=2026-11-21 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d8041cb623e601ebc085e2198725d2ce8277ab5a branch=main release=v1.20.2 scanned=2026-11-21 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=db5ac9ce7c25f3c9cbece0c41d0bd02e6919d2bd branch=main release=— scanned=2026-11-21 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=057b54be3946886765dc2700ce1ab80ce6bcf4ba branch=main release=v0.20.2 scanned=2026-11-21 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9ca111cffd06cf9686b704ea5eb85771781cc2b0 branch=main release=v0.5.1 scanned=2026-11-21 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-21 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-21 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9e4154330f5124ee62bf8f724892f6dcfa1a7145 branch=main release=v0.15.2 scanned=2026-11-21 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=4c565e5ed2e1543cb8d603b606833472e4e388e3 branch=main release=v0.16.18 scanned=2026-11-21 -->
