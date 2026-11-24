# NVIDIA 算力栈 diff 雷达 2026-11-25

## 摘要
- **dra-driver-nvidia-gpu 一次合入 37 个提交，是本周最大的 DRA 侧架构变化。** ComputeDomain 从“每个 CD 固定注入 channel 0、一节点一 CD”改为**按 NVLink clique 给每个 workload 模板分配独立 IMEX channel**(新字段 `spec.channels`,alpha gate `ComputeDomainChannelReservations`)。同时新增集群级 CRD **`ComputeDomainDaemonSet`**:每个节点常驻一个 IMEX daemon,由所有 CD 共享，按 clique 滚动升级(alpha gate `ComputeDomainDaemonSet`)。Helm 的 `imex.mode` / `imex.isolation` 被弃用，改由 `imex.daemonLifecycle` 取代。
- **k8s-device-plugin 调整了 XID 健康检查的默认忽略列表**:去掉 XID 109(上下文切换超时),新增 XID 32(PBDMA)和 69(图形引擎类错误)。即从本版起 **XID 109 会把 GPU 标成不健康**,32/69 不会。
- L1 层小步变化:container-toolkit 回滚了上期加入 CDI spec 的 `void` volume-mount 设备，改为在运行时用 `NVIDIA_VISIBLE_DEVICES=void` 压过 volume-mount 请求;gpu-driver-container 发版流水线新增 `rhel9.9`;mig-manager 写节点 ConfigMap 失败时由告警改为启动失败;KAI 修正了多设备 fraction 场景下预留 Pod 的槽位计数。

## 当日重要改变
- `kubernetes-sigs/dra-driver-nvidia-gpu` **[API/CRD变更]** `ComputeDomainSpec.Channel` 由必填改为可选，新增 `Channels []ComputeDomainReservedChannelSpec`(1–32 项，名称唯一),CEL 规则要求 `channel` 与 `channels` 二选一;`ComputeDomainChannelConfig` 新增 `channelRef`;新 CRD `computedomaindaemonsets.resource.nvidia.com`(cluster 级，短名 `cdds`,名称固定为 `default`)。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/e87667ab8ba29b26c074b328da312ae25c815d8c https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/ca8e54d2a8618a3199677e054bef2873d6696a25
- `kubernetes-sigs/dra-driver-nvidia-gpu` **[弃用/移除]** Helm `resources.computeDomains.imex.mode` 弃用(仍兼容:`hostManaged` 映射到 `daemonLifecycle=hostManaged`),`imex.isolation` 弃用且**被忽略**;改用 `imex.daemonLifecycle`,可选 `perComputeDomain` / `static` / `hostManaged`。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/5ac6d4a4f4abf290bb676b9fcf0e2df761478a75
- `kubernetes-sigs/dra-driver-nvidia-gpu` **[架构方向][新能力]** 新增两份 proposal,`0001-computedomain-channel-reservations`(provisional)和 `0002-static-imex-daemons`(implementable),以及两个 alpha gate(v0.6 引入，默认关闭)。 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/e44a7d62cf05a57a4a821e1d630b8bb36ad4e63c
- `NVIDIA/k8s-device-plugin` **[弃用/移除·健康语义]** `getDisabledHealthCheckXids()` 的硬编码忽略列表去掉 109,新增 32 和 69。 https://github.com/NVIDIA/k8s-device-plugin/commit/2e9cc606f10c8f6f31d02f68cb7506080fb7709c
- `NVIDIA/nvidia-container-toolkit` **[弃用/移除]** 回滚 CDI spec 里的 `/var/run/nvidia-container-devices/void` 挂载，删除常量 `volumeMountDeviceVoid`,改由 `voidRequestedByEnvVar()` 在 env 层兜住。 https://github.com/NVIDIA/nvidia-container-toolkit/commit/03730e36ee210a957db69f9aba8f3f79cbc82852 https://github.com/NVIDIA/nvidia-container-toolkit/commit/cbe4f6849538e91034b9e94c851cd45569c10a7c
- `[版本跨档]` 本期未命中:9 仓 Release 均与上期相同。KAI 的 releases 列表最大 semver 仍是 v0.19.0(2026-11-11),helper 报的 v0.18.9 是 backport。

## kubernetes-sigs/dra-driver-nvidia-gpu: 44cf296c -> 6b1b335c
- 比较: 44cf296cdfb787ec2155a5ffae11763cb7e92c7e -> 6b1b335c | ahead=37 | files=105 | Release: v0.5.1
- compare: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/44cf296cdfb787ec2155a5ffae11763cb7e92c7e...6b1b335c654357de6f418b4e265b4ef40bc005ab
- 合入的 PR(按 merge commit):
  - https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/e44a7d62cf05a57a4a821e1d630b8bb36ad4e63c Merge #1588 static_imex_daemonset(含 channel reservations + 静态 IMEX daemon 共 26 个提交，作者提交日期为 10-25~11-24)
  - https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/fc60c8283cd4bd9161abd8c98ecf1d0d2e3d16b1 / https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/3fffbd5aac8c89a62361dd19e39f14e09664e4e6 (#1630 time-slice 复位)
  - https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/c7818e0fbd5a8125acafa9c7ec46c987e0201e7b (#1632 ALT_PROC_DRIVER_PATH)
  - https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/commit/c9ec042a6266ae2573d280469e5083bc2491adb0 (#1636 goroutine 泄漏)
- 说明:helper 的 patch 节选全被 CRD / API / 大文件占满,featuregates、imex、values.yaml、gpu-kubelet-plugin、nvcaps、channelassignment 等文件的 hunk 是用 compare API **补拉**的。1094 行的 `computedomaindaemonset.go` 和 840 行的 `claimadmission.go` 只看了常量、函数签名和 proposal 文档，**没有逐行读**。

### AI 总结重点(源码 diff 为据)

- **ComputeDomain API 从“单 channel”扩展为“多 channel 列表”,并用 CEL 做互斥。** 原来 `Channel` 字段的 json tag 是 `channel`(必填),现在改为 `channel,omitempty`,并新增 `Channels`。`GetChannels()` 把两种写法统一成列表：单 `channel` 保留原 `AllocationMode`;`channels` 中的每一项一律设为 `AllocationModeSingle`。spec 本身仍然 immutable。
  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/computedomain.go</summary>

  ```diff
   // +kubebuilder:validation:XValidation:rule="self == oldSelf", message="A computeDomain.spec is immutable"
  +// +kubebuilder:validation:XValidation:rule="has(self.channel) != has(self.channels)", message="exactly one of channel and channels must be set"
  ...
  -	NumNodes int                       `json:"numNodes,omitempty"`
  -	Channel  *ComputeDomainChannelSpec `json:"channel"`
  +	NumNodes int `json:"numNodes,omitempty"`
  +	// +kubebuilder:validation:Optional
  +	Channel *ComputeDomainChannelSpec `json:"channel,omitempty"`
  +	// Channels lists workload ResourceClaimTemplates, each backed by its own
  +	// IMEX channel. Pods using the same template share its channel. Requires
  +	// the ComputeDomainChannelReservations feature gate.
  +	// +kubebuilder:validation:MinItems=1
  +	// +kubebuilder:validation:MaxItems=32
  +	Channels []ComputeDomainReservedChannelSpec `json:"channels,omitempty"`
  ...
  +func (s *ComputeDomainSpec) GetChannels() []ComputeDomainChannelSpec {
  +	if s.Channel != nil {
  +		return []ComputeDomainChannelSpec{*s.Channel}
  +	}
  +	...
  +			AllocationMode:        ComputeDomainChannelAllocationModeSingle,
  ```
  </details>

- **channel 由 controller 在“claim 准入”时按 clique 分配，不写 CD status。** 新增 `channelAssigner`,以 `channelKey{imexDomain, computeDomain, template}` 为键。每个 IMEX domain(即 NVLink clique)维护一张独立的 `channels` / `owners` 表。分配从 1 开始轮转(channel 0 保留给旧 CD 的 `legacySharedChannel`),`next` 指针保证刚释放的 channel 最后才被复用;controller 重启后，从已准入 claim 的 device status 里 `Restore`。上限是 Helm 新增的 `imex.maxChannels: 2048`(驱动硬上限)。另外 `ComputeDomainChannelConfig.ChannelRef` 写入模板名，让同一模板的 claim 共享同一个 channel。
  <details><summary>代码依据 cmd/compute-domain-controller/channelassignment.go(新增)/ computedomainconfig.go</summary>

  ```diff
  +type channelKey struct {
  +	imexDomain    string
  +	computeDomain string
  +	template      string
  +}
  ...
  +// Assign returns the channel of a claim's key, assigning a free one first.
  +// The legacy shared channel is never assigned this way.
  +func (a *channelAssigner) Assign(key channelKey, claim types.UID) (int, error) {
  ...
  +	for i := range a.maxChannels - 1 {
  +		channel := 1 + (d.next-1+i)%(a.maxChannels-1)
  +		if _, taken := d.owners[channel]; taken {
  +			continue
  +		}
  ...
  +	return 0, fmt.Errorf("all %d IMEX channels of %s are in use", a.maxChannels-1, key.imexDomain)
  ```
  ```diff
  +	// ChannelRef identifies the channel of the claim. With channel
  +	// reservations, the controller sets it to the name of the workload
  +	// ResourceClaimTemplate, so that claims of one template share a channel
  +	// in each NVLink clique.
  +	ChannelRef string `json:"channelRef,omitempty"`
  ```
  </details>

- **准入依赖 DRA 新机制：binding condition、多分配设备、设备污点。** `claimadmission.go` 中的 `needsAdmission()` 以 `BindingConditions` 是否包含 `imex.ChannelAdmittedCondition` 为判据。新增 DeviceClass `compute-domain-channel.nvidia.com`,只选择 `type == 'imex-channel'` 的共享 channel 设备。workload claim 模板在有 `.Owner` 时给 channel 请求加上 owner taint 的 toleration,对应 proposal 里的“per-CD daemon 模式下一节点仍只跑一个 CD,由调度器借 owner 属性看到、controller 在准入时强制”。feature-gates 文档列出的集群前置条件是：K8s v1.34+,开启 `DRAConsumableCapacity` 和 `DRAResourceClaimDeviceStatus`;perComputeDomain 模式下还需要 `DRADeviceBindingConditions` 和 `DRADeviceTaints`。
  <details><summary>代码依据 claimadmission.go / deviceclass-compute-domain-channel.yaml / compute-domain-workload-claim-template.tmpl.yaml</summary>

  ```diff
  +func needsAdmission(result *resourceapi.DeviceRequestAllocationResult) bool {
  +	return slices.Contains(result.BindingConditions, imex.ChannelAdmittedCondition) || result.Device == imex.ChannelDeviceName
  ```
  ```diff
  +  name: compute-domain-channel.nvidia.com
  +spec:
  +  selectors:
  +  - cel:
  +      expression: "device.driver == 'compute-domain.nvidia.com' && device.attributes['compute-domain.nvidia.com'].type == 'imex-channel'"
  ```
  ```diff
           deviceClassName: {{ .DeviceClassName }}
  +{{- if .Owner }}
  +          tolerations:
  +          - key: {{ .OwnerTaintKey }}
  +            operator: Equal
  +            value: "{{ .Owner }}"
  +            effect: NoSchedule
  +{{- end }}
  ```
  </details>

- **IMEX daemon 生命周期收敛为一个三选一的配置项 `imex.daemonLifecycle`,旧的两个值降级为兼容层。** `pkg/imex` 删除了 `Mode` / `Isolation` 类型(以及原本直接报错“未实现”的 `IsolationIMEXChannel`),新增 `DaemonLifecycle` 类型，取值 `perComputeDomain`(默认)、`static`、`hostManaged`。`ResolveConfig()` 对设置了 `mode` / `isolation` 的情况各打一条 deprecation warning;`mode=hostManaged` 与 `daemonLifecycle` 冲突时直接报错。新增 `SharedIMEXDaemons()`:static 和 hostManaged 都走“共享 IMEX domain、靠 channel 隔离”的路径。也就是说，上期还标着“not implemented”的 per-workload channel 隔离，这期以另一套 API 落地了。
  <details><summary>代码依据 pkg/imex/imex.go</summary>

  ```diff
  -	// IsolationIMEXChannel would give each workload a unique channel within
  -	// an IMEX domain. Not implemented/supported yet: currently rejected as
  -	// an error.
  -	IsolationIMEXChannel Isolation = "channel"
  +	DaemonLifecyclePerComputeDomain DaemonLifecycle = "perComputeDomain"
  +	DaemonLifecycleStatic DaemonLifecycle = "static"
  +	DaemonLifecycleHostManaged DaemonLifecycle = "hostManaged"
  ...
  +	if isolation != "" {
  +		warnings = append(warnings, fmt.Sprintf("imex.isolation is deprecated and ignored, IMEX channels follow the ComputeDomainChannelReservations feature gate (imex.isolation=%q)", isolation))
  +	}
  ...
  +	case mode == deprecatedModeHostManaged && config.DaemonLifecycle != DaemonLifecycleHostManaged:
  +		return Config{}, warnings, fmt.Errorf("imex.mode=%q contradicts imex.daemonLifecycle=%q, unset imex.mode", mode, lifecycle)
  ...
  +func (c Config) SharedIMEXDaemons() bool {
  +	return c.DaemonLifecycle == DaemonLifecycleHostManaged || c.DaemonLifecycle == DaemonLifecycleStatic
  +}
  ```
  </details>

- **新 CRD `ComputeDomainDaemonSet` 把 IMEX daemon 的生命周期从“跟着 workload 走”改为“跟着 fabric 走”。** 资源是 cluster 级单例(`ComputeDomainDaemonSetName = "default"`),更新策略有 `OnDelete` 和 `RollingUpdate` 两种。状态条件包括 `RolloutInProgress`(卡住时 reason 为 ProgressDeadlineExceeded)、`DeletionBlocked`(还有 workload 用着 channel 时不准删)、`UpdateBlocked`、`TemplateOutdated`(驱动升级只做标记，不重启 daemon,等下一次 spec 变更时一起生效)、`Degraded`;clique 状态分 Ready / NotReady / Stalled。gate 校验:`ComputeDomainDaemonSet` 依赖 `ComputeDomainCliques` 和 `ComputeDomainChannelReservations` 同时开启。按 proposal 0002:`maxNodesPerClique` 默认 18 且不可变;`RollingUpdate` 以整个 clique 为单位重启(`maxUnavailableCliques` 默认 1);NVLink 重新分区时绕过更新策略，立即重启对应节点的 daemon;目标规模是数千节点(“1,800 daemons / 100 cliques 一次 sync 约 1ms”)。
  <details><summary>代码依据 api/nvidia.com/resource/v1beta1/computedomaindaemonset.go(新增,hunk 截断)/ pkg/featuregates/featuregates.go</summary>

  ```diff
  +	// ComputeDomainDaemonSetName is the name of the only ComputeDomainDaemonSet.
  +	ComputeDomainDaemonSetName = "default"
  +	ComputeDomainDaemonSetUpdateStrategyOnDelete      = "OnDelete"
  +	ComputeDomainDaemonSetUpdateStrategyRollingUpdate = "RollingUpdate"
  ...
  +	// ComputeDomainDaemonSetConditionTemplateOutdated is true when the driver
  +	// renders a newer daemon template than the daemons run. It is applied with
  +	// the next spec change, so that driver upgrades do not restart daemons.
  ...
  +	ComputeDomainDaemonSetCliqueStalled = "Stalled"
  ...
  +// +kubebuilder:resource:scope=Cluster,shortName=cdds
  ```
  ```diff
  +	// Static IMEX daemons register in cliques and serve reserved channels.
  +	if Enabled(ComputeDomainDaemonSet) {
  +		for _, required := range []featuregate.Feature{ComputeDomainCliques, ComputeDomainChannelReservations} {
  +			if !Enabled(required) {
  +				return fmt.Errorf("feature gate %s requires %s to also be enabled", ComputeDomainDaemonSet, required)
  ```
  </details>

- **gpu-kubelet-plugin:time-slice 复位改为逐卡执行,“不支持”不再阻断其他卡。** `unprepareDevices` 原来把一批 GPU UUID 一次性交给 `SetTimeSlice`,而且只用 `err == nvml.ERROR_NOT_SUPPORTED` 做等值判断。`nvidia-smi` 返回的 exec 错误从来不会等于这个值，所以不支持 time-slicing 的卡会导致 unprepare 整体失败。现在新增 `nvidiaSMIError()`,把 nvidia-smi 的退出码 3 包装成 `nvml.ERROR_NOT_SUPPORTED`,并改为逐卡循环 + `errors.Is` 判断。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go / nvlib.go</summary>

  ```diff
  -				if err := s.tsManager.SetTimeSlice(gpuUUIDsToReset, tsc); err != nil {
  -					if err == nvml.ERROR_NOT_SUPPORTED {
  +				for _, gpuUUID := range gpuUUIDsToReset {
  +					if err := s.tsManager.SetTimeSlice([]string{gpuUUID}, tsc); err != nil {
  +						if errors.Is(err, nvml.ERROR_NOT_SUPPORTED) {
  +							klog.Warningf("Unprepare: skip resetting time-slice policy for GPU %s: %v", gpuUUID, err)
  +							continue
  ```
  ```diff
  +const nvidiaSMIExitNotSupported = 3
  +func nvidiaSMIError(err error) error {
  +	var exitErr *exec.ExitError
  +	if errors.As(err, &exitErr) && exitErr.ExitCode() == nvidiaSMIExitNotSupported {
  +		return fmt.Errorf("error running nvidia-smi: %w: %w", err, nvml.ERROR_NOT_SUPPORTED)
  ```
  </details>

- **MIG capability 路径可重定向;kubelet plugin 的 Prepare 去掉了常驻 goroutine。** `internal/common/nvcaps.go` 新增 `procDriverPath`,可用环境变量 `ALT_PROC_DRIVER_PATH` 覆盖，并提供 `MigCapsPaths()`;注释说明是为 mock NVML 节点(没有内核模块、runc 拒绝挂 /proc)服务的，属于测试基础设施。compute-domain-kubelet-plugin 的 `PrepareResourceClaims` 去掉了 `sync.WaitGroup` 和后台 `go func(){wg.Wait();cancel()}`,改为在回调里计数 `pending`,归零时 `cancel()`;空 claims 直接返回。修复前，有 claim 一直没完成就超时时，后台 goroutine 会永远卡在 `wg.Wait()` 上。
  <details><summary>代码依据 internal/common/nvcaps.go / cmd/compute-domain-kubelet-plugin/driver.go</summary>

  ```diff
  +	if v := os.Getenv("ALT_PROC_DRIVER_PATH"); v != "" {
  +		procDriverPath = v
  +	}
  ```
  ```diff
  -	go func() {
  -		wg.Wait()
  -		cancel()
  -	}()
  +	pending := len(claims)
  ...
  +				pending--
  +				if pending == 0 {
  +					cancel()
  +				}
  ```
  </details>

### 后续发展方向 [AI]
- **NVIDIA 正在把多节点 NVLink(GB200/GB300 NVL72 类)的 IMEX 隔离，从“按节点独占”转向“按 channel 多租户”。** 以前一个 CD 独占节点、所有 workload 共用 channel 0;现在一个 clique 内最多有 2047 个隔离 channel,多个 CD 可以共享节点。daemon 也从“跟着 workload 创建和销毁”改为常驻，避免作业频繁起停带来的扰动。对我们产品的启示：如果要纳管 NVL72 这类超节点，租户隔离的单位不应该再是“整节点 / 整 clique”,应该是 IMEX channel。调度层需要理解 clique 拓扑(`nvidia.com/gpu.clique` 标签)和 channel 容量。这一点与 HAMi 11-25 期 #3410 的“superpod 感知调度”方向一致：两边都在补“超节点”这一层抽象。证据覆盖:API、gate、imex 包、channelAssigner、proposal 文本;**没有逐行读** claimadmission 和 CDDS controller 的实现。
- **NVIDIA DRA 驱动开始依赖 K8s 1.34+ 的 DRA 新特性(binding conditions、consumable capacity、device taints、device status)。** 这些都是 KEP 级别的 alpha/beta 能力，意味着 NVIDIA 的多节点 GPU 方案和上游 DRA 的演进节奏绑在一起。如果我们要跟进，K8s 基线版本和 feature gate 开关矩阵会成为交付约束。两个新 gate 都是 v0.6 alpha、默认关闭，从 helper 看 v0.6.0 还没发版。
- **`imex.mode` / `isolation` 的弃用路径做得比较温和(v0.5 的值继续可用，只打 warning)**,但 `isolation` 是“被忽略”而不是“被映射”。如果用户曾把 isolation 设成 `channel`(以前直接报错，所以实际不太可能有人这么配),行为会悄悄改变。文档仍要求修改 daemonLifecycle 前先排空并删除现有 CD。

## NVIDIA/k8s-device-plugin: 057b54be -> a817d82f
- 比较: 057b54be3946886765dc2700ce1ab80ce6bcf4ba -> a817d82f | ahead=4 | files=3 | Release: v0.20.2
- compare: https://github.com/NVIDIA/k8s-device-plugin/compare/057b54be3946886765dc2700ce1ab80ce6bcf4ba...a817d82f45389f99869f9040e6980be6a1fcbe35
- 提交:
  - https://github.com/NVIDIA/k8s-device-plugin/commit/2e9cc606f10c8f6f31d02f68cb7506080fb7709c Remove XID 109 from the default allowlist and add XIDs 32 and 69 (#2176)
  - https://github.com/NVIDIA/k8s-device-plugin/commit/9697f8a5e010ab89919e368d071ea014f33f4ed7 Fix persistence daemon socket lookup in operand images (#2175)

### AI 总结重点(源码 diff 为据)
- **默认被视为“应用错误、GPU 仍健康”的 XID 集合变了:去掉 109,加入 32 和 69。** `getDisabledHealthCheckXids()` 里的 `ignoredXids` 现在是 {13, 31, 32, 43, 45, 68, 69}。效果是:**XID 109(Context Switch Timeout)从此会触发 device 不健康**,该卡会从可分配资源里摘除;XID 32(PBDMA Error)和 69(Graphics Engine Class Error)不再摘卡。参考文档链接也换成了新版 XID catalog。
  <details><summary>代码依据 internal/rm/health.go</summary>

  ```diff
  -	// http://docs.nvidia.com/deploy/xid-errors/index.html#topic_4
  +	// https://docs.nvidia.com/deploy/xid-errors/latest/analyzing-xid-catalog.html
   	ignoredXids := []uint64{
  -		13,  // Graphics Engine Exception
  -		31,  // GPU memory page fault
  -		43,  // GPU stopped processing
  -		45,  // Preemptive cleanup, due to previous errors
  -		68,  // Video processor exception
  -		109, // Context Switch Timeout Error
  +		13, // Graphics Engine Exception
  +		31, // GPU memory page fault
  +		32, // PBDMA Error
  +		43, // GPU stopped processing
  +		45, // Preemptive cleanup, due to previous errors
  +		68, // Video processor exception
  +		69, // Graphics Engine Class Error
   	}
  ```
  </details>
- **operand 镜像里把 `/var/run` 软链到 `/run`。** 注释说明:NVML 在 `/var/run` 下找 persistenced socket,而 CDI 可能把它挂到 `/run`。修复前，CDI 注入模式下 NVML 可能找不到 persistence daemon。
  <details><summary>代码依据 deployments/container/Dockerfile</summary>

  ```diff
  +# NVML looks for the persistenced socket under /var/run, while CDI may mount it under /run.
  +RUN rm -r /var/run && ln -s /run /var/run
  ```
  </details>

### 后续发展方向 [AI]
- XID 列表仍然是硬编码，旁边还留着 `FIXME: formalize the full list and document it`,说明 NVIDIA 在按新版 XID catalog 逐个重新分类。对我们产品的启示：如果我们的 GPU 健康检查 / 故障自愈也维护着一份 XID 白名单，应该对齐这次调整(109 视为致命,32/69 视为应用级);升级 device-plugin 后，XID 109 频发的节点会出现可分配 GPU 数下降。证据只覆盖 health.go 的常量表，没有看到 DRA driver 侧(`NVMLDeviceHealthCheck` gate)是否同步调整。

## NVIDIA/nvidia-container-toolkit: d8041cb6 -> d4dbcac4
- 比较: d8041cb623e601ebc085e2198725d2ce8277ab5a -> d4dbcac4 | ahead=5 | files=9 | Release: v1.20.2
- compare: https://github.com/NVIDIA/nvidia-container-toolkit/compare/d8041cb623e601ebc085e2198725d2ce8277ab5a...d4dbcac49f612774116fc176bf8ac5de8cee4321
- 提交(PR #2236):
  - https://github.com/NVIDIA/nvidia-container-toolkit/commit/03730e36ee210a957db69f9aba8f3f79cbc82852 Revert "Add 'void' volume-mount device in CDI spec"
  - https://github.com/NVIDIA/nvidia-container-toolkit/commit/cbe4f6849538e91034b9e94c851cd45569c10a7c Ignore volume mounts if void device requested through envvar
  - (另有 golang 1.27.3→1.27.4 的 devel 镜像 bump,不展开)

### AI 总结重点(源码 diff 为据)
- **防重复注入的手段从“CDI spec 多挂一个 void 设备”改为“运行时以 env 的 void 为准”。** `wrapper.GetCommonEdits()` 不再往 CDI 公共 edits 里加 `/dev/null → /var/run/nvidia-container-devices/void` 的 bind mount,只保留 `NVIDIA_VISIBLE_DEVICES=void`。同时，`CUDA.VisibleDevices()` 在读取 volume-mount 设备列表前，先用新函数 `voidRequestedByEnvVar()` 检查各 visible env 中是否有 `void` 或 `none`,命中就跳过 volume-mount 路径。`visibleDevicesFromMounts()` 里对 `void` 挂载的特判被删除(常量 `volumeMountDeviceVoid` 也一并删除)。效果是：所有已生成的 CDI spec 少了一条 mount,而 `volume-mounts` 设备策略下的防重复注入改由 env 实现。
  <details><summary>代码依据 pkg/nvcdi/wrapper.go / internal/config/image/cuda_image.go</summary>

  ```diff
   	edits.Env = append(edits.Env, image.EnvVarNvidiaVisibleDevices+"=void")
  -	// Configure a void volume mount device to prevent duplicate device
  -	// injection from NVIDIA Container Runtime when the 'volume-mounts'
  -	// device strategy is enabled.
  -	edits.Mounts = append(edits.Mounts, &specs.Mount{
  -		HostPath:      "/dev/null",
  -		ContainerPath: filepath.Join(image.DeviceListAsVolumeMountsRoot, "void"),
  ```
  ```diff
  -	if i.acceptDeviceListAsVolumeMounts {
  +	// An explicit request for the void device means that no devices
  +	// should be injected, including those requested through volume mounts.
  +	// This is relied upon by generated CDI specs, which set
  +	// NVIDIA_VISIBLE_DEVICES=void to avoid duplicate device injection.
  +	if i.acceptDeviceListAsVolumeMounts && !i.voidRequestedByEnvVar() {
  ...
  +func (i CUDA) voidRequestedByEnvVar() bool {
  +	for _, envVar := range i.visibleEnvVars() {
  +		for d := range strings.SplitSeq(i.env[envVar], ",") {
  +			d = strings.TrimSpace(d)
  +			if d == "void" || d == "none" {
  ```
  </details>
- **语义上的细微差别:void 和 none 都会压过 volume-mount 请求。** 单测 "Void envvar overrides mount devices, privileged/unprivileged" 中，env=void 且挂载了 GPU0、GPU1 时，期望结果都是 `nil`。旧用例 "Void mount device, unprivileged, accept unprivileged"(期望 `all`)被删除。
  <details><summary>代码依据 internal/config/image/cuda_image_test.go</summary>

  ```diff
  -			description:        "Void mount device, unprivileged, accept unprivileged",
  -			mountDevices:       makeTestMounts("GPU0", "GPU1", "void"),
  -			envvarDevices:      "all",
  +			description:        "Void envvar overrides mount devices, privileged",
  +			mountDevices:       makeTestMounts("GPU0", "GPU1"),
  +			envvarDevices:      "void",
  +			privileged:         true,
  ...
  -			expectedDevices:    []string{"all"},
  +			expectedDevices:    nil,
  ```
  </details>

### 后续发展方向 [AI]
- CDI 作为唯一注入路径的收敛还在继续：toolkit 选择让生成的 CDI spec 保持精简(不带 runtime 私有约定的挂载),由 legacy runtime 自己识别 env。证据只覆盖本次回滚;revert 的 commit message 没有给出原因，推测与“旧版 runtime 不识别 void 挂载”或 spec 兼容性有关，这一点**未核实**。

## NVIDIA/gpu-operator: d338c6bd -> cf2bb183
- 比较: d338c6bd60db03ef29db86f5ef411b0dca35a85b -> cf2bb183 | ahead=3 | files=5 | Release: v26.7.3
- compare: https://github.com/NVIDIA/gpu-operator/compare/d338c6bd60db03ef29db86f5ef411b0dca35a85b...cf2bb183db43711840607cc3f2e0350507962fc4
- 提交:https://github.com/NVIDIA/gpu-operator/commit/83131c9a6415651baf874839721c2717ebad730b Preserve DRA validator selector label (#2956);另有 operator-framework/api 0.47.1 的依赖 bump(compare 全量核对过，除这两项外无其他 Bump 类内容)

### AI 总结重点(源码 diff 为据)
- **DRA validator DaemonSet 的 pod 模板不再接受用户用 `app.kubernetes.io/name` 覆盖。** 在 `ClusterPolicy.spec.daemonsets.labels` 透传到 pod template 的循环里，原本只排除 `app` 和 `app.kubernetes.io/part-of`,这次把 `app.kubernetes.io/name` 也加入排除。原因是这个 label 正是 DS selector(`app.kubernetes.io/name: nvidia-dra-validator`)。修复前，用户如果设置了同名的 common label,pod 模板的 label 会被覆盖，与 immutable 的 selector 不匹配，DaemonSet 无法创建或更新。新单测覆盖了 5 种保留 label 冲突组合，并断言 common label 仍会出现在 DS 自身的 metadata 上。
  <details><summary>代码依据 manifests/state-dra-validation/0500_daemonset.yaml</summary>

  ```diff
  -        {{- if and (ne $k "app") (ne $k "app.kubernetes.io/part-of") }}
  +        {{- if and (ne $k "app") (ne $k "app.kubernetes.io/part-of") (ne $k "app.kubernetes.io/name") }}
  ```
  </details>

### 后续发展方向 [AI]
- gpu-operator 对 DRA 组件(validator)在持续修边角，说明 DRA 路径已经进入 operator 的常规交付面;本期没有改动 ClusterPolicy CRD(`clusterpolicy_types.go` 未命中)。

## NVIDIA/gpu-driver-container: 6be32fc9 -> fdae62a6
- 比较: 6be32fc94f4599b2cfc35f113a170607980cdd03 -> fdae62a6 | ahead=8 | files=10 | Release: —
- compare: https://github.com/NVIDIA/gpu-driver-container/compare/6be32fc94f4599b2cfc35f113a170607980cdd03...fdae62a6b79a3584267e6361e9fa743d5136b1b8
- 提交:https://github.com/NVIDIA/gpu-driver-container/commit/4ed5cb3353a484a403bcc5305f1ae41d6d600f58 Add the rhel9.9 tag to the release pipeline (#1091);以及 renovate 驱动的 UBI 和 Ubuntu 基础镜像刷新(#1092 / #1095)

### AI 总结重点(源码 diff 为据)
- **OS 矩阵:NGC 发布新增 `rhel9.9` 目标。** `.nvidia-ci.yml` 新增 job `release:ngc-rhel9.9`,继承 `.dist-rhel9`,`OUT_DIST: "rhel9.9"`,排在 `rhel9.8` 之后。`rhel9/Dockerfile` 的 UBI9 基础镜像早已是 `9.9-*`,这次只刷新了 build 号。所以这次是补齐发版 tag,让 RHEL 9.9 节点能拉到带 `rhel9.9` 后缀的驱动镜像。
  <details><summary>代码依据 .nvidia-ci.yml / rhel9/Dockerfile</summary>

  ```diff
  +release:ngc-rhel9.9:
  +  extends:
  +    - .release:ngc
  +    - .dist-rhel9
  +  variables:
  +    OUT_DIST: "rhel9.9"
  ```
  ```diff
  -ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.9-1794466612
  +ARG BASE_IMAGE=registry.access.redhat.com/ubi9/ubi:9.9-1795197514
  ```
  </details>
- 其余是基础镜像日期 tag 的刷新(noble-20261110→20261110.1,jammy-20261110→20261114.1,UBI8/9 build 号),没有功能变化。

## NVIDIA/mig-parted: 9e415433 -> 6cf77a2b
- 比较: 9e4154330f5124ee62bf8f724892f6dcfa1a7145 -> 6cf77a2b | ahead=4 | files=2 | Release: v0.15.2
- compare: https://github.com/NVIDIA/mig-parted/compare/9e4154330f5124ee62bf8f724892f6dcfa1a7145...6cf77a2b52a528d2bac5468b7a33abb7bf45ac68
- 提交:https://github.com/NVIDIA/mig-parted/commit/ec5a86f42ead0b6be2d1f7987f420780b8098ac7 Fail mig-manager startup when the node ConfigMap write fails (#597);另有 distroless/go v4.2.2→v4.2.3 的 bump

### AI 总结重点(源码 diff 为据)
- **mig-manager 写节点 ConfigMap 失败时，由“告警后继续”改为“启动失败”。** `setupMigConfig()` 中 `createNodeConfigMap` 出错时，原来 `log.Warnf` 后照常返回生成的配置路径，现在改为返回 error。效果是：缺少 ConfigMap 的 RBAC 或 API 不可达时，mig-manager Pod 会 CrashLoop 并暴露问题，不再带着不完整的状态静默运行。
  <details><summary>代码依据 cmd/nvidia-mig-manager/main.go</summary>

  ```diff
   	if err := createNodeConfigMap(ctx, clientset, nodeNameFlag, configYAML); err != nil {
  -		log.Warnf("Failed to create node ConfigMap: %v", err)
  +		return "", fmt.Errorf("failed to create node ConfigMap: %w", err)
   	}
  ```
  </details>

## kai-scheduler/KAI-Scheduler: 41a8c429 -> 31139362
- 比较: 41a8c429ec6b97beab30fbf8188838bb261d56e9 -> 31139362 | ahead=3 | files=16 | Release: v0.18.9(0.18 分支 backport;releases 最大 semver 仍为 v0.19.0,不算跨档)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/41a8c429ec6b97beab30fbf8188838bb261d56e9...3113936297208d9ba2cab734964f1ff7b74595ab
- 提交:
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/97640fa644b9b1de766605ddc1d34162f6dc9ee1 fix(scheduler): count a reservation pod per new GPU group in pod slot check (#2714)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/3f7338e9bd2898b86ede7dc5866135ebf90dca79 fix(chart): honor global image pull policy by default (#2440)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/3113936297208d9ba2cab734964f1ff7b74595ab docs(metrics): clarify total_preemption_attempts description (#2487)

### AI 总结重点(源码 diff 为据)
- **GPU 共享场景下的节点 Pod 槽位检查从“是否需要新 GPU group”改为“需要几个”。** 函数 `willCreateNewGpuGroup() bool` 改名为 `newGpuGroupsCount() int`,`containsNewGpuGroup` 也改为 `countNewGpuGroups`。槽位阈值从固定的 `availablePods < 2` 改为 `< 1+newGpuGroups`:binder 为每个新 GPU group 各建一个 reservation pod。没有具体分配方案时，上限取 `GetNumOfGpuDevices()`(至少 1)。修复前，多设备 fraction 请求(例如 2×0.5 GPU)在 Pod 数接近 `maxPods` 的节点上只预留 2 个槽位，过滤能通过，但 binder 建 reservation pod 时会失败。
  <details><summary>代码依据 pkg/scheduler/plugins/gpusharingnodevalidation/gpusharingnodevalidation.go</summary>

  ```diff
  -	needsNewGpuGroup := willCreateNewGpuGroup(task, node, ssn)
  -	if !needsNewGpuGroup {
  +	newGpuGroups := newGpuGroupsCount(task, node, ssn)
  +	if newGpuGroups == 0 {
   		return nil
   	}
  -	if availablePods < 2 {
  +	// The binder creates one reservation pod per new GPU group, on top of the task pod itself.
  +	if availablePods < float64(1+newGpuGroups) {
  ...
  +	upperBound := int(task.GpuRequirement.GetNumOfGpuDevices())
  +	if upperBound < 1 {
  +		upperBound = 1
  +	}
  ```
  </details>
- **chart:各组件的 `image.pullPolicy` 默认值由 `IfNotPresent` 改为空，全局 `global.imagePullPolicy` 终于生效。** 新增 helper `kai-scheduler.imagePullPolicy`,优先级为：组件显式值 → global → `IfNotPresent`。修复前组件默认值非空,`| default .Values.global.imagePullPolicy` 永远不会生效。
  <details><summary>代码依据 deployments/kai-scheduler/templates/_helpers.tpl / values.yaml</summary>

  ```diff
  +{{- define "kai-scheduler.imagePullPolicy" -}}
  +{{- .pullPolicy | default .root.Values.global.imagePullPolicy | default "IfNotPresent" -}}
  +{{- end -}}
  ...
  -        pullPolicy: {{ .Values.binder.image.pullPolicy | default .Values.global.imagePullPolicy }}
  +        pullPolicy: {{ include "kai-scheduler.imagePullPolicy" (dict "root" $ "pullPolicy" .Values.binder.image.pullPolicy) }}
  ```
  ```diff
  -    pullPolicy: IfNotPresent
  +    pullPolicy: ""
  ```
  </details>
- **指标语义的澄清:`total_preemption_attempts` 的含义是“调度器发起的抢占次数(受害者已驱逐、抢占者尚未运行)”,每次抢占只计 1 次，与受害者数量无关。** 只改了 Help 文案和文档，计数逻辑没有变。
  <details><summary>代码依据 pkg/scheduler/metrics/metrics.go</summary>

  ```diff
  -			Help:      "Total preemption attempts in the cluster till now",
  +			Help:      "Total preemptions started by the scheduler, counted once per preemption regardless of the number of victims",
  ```
  </details>

### 后续发展方向 [AI]
- KAI 的 GPU fraction(reservation pod 模式)还在补多设备边界情况，说明“一个 Pod 跨多张卡的分数请求”已有真实用户在用。我们如果做软切分，也要按卡数计算附加 Pod 的开销。证据只覆盖槽位校验，没看到 binder 侧的改动。

<details>
<summary>## 本期无实质改动(2 仓)</summary>

- NVIDIA/dcgm-exporter:无新提交(HEAD 仍是 4e663a52,Release 4.9.0)
- NVIDIA/DCGM:无新提交(HEAD 仍是 9fae2867,master 分支)

</details>

## 扫描锚点(机器可读，勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=cf2bb183db43711840607cc3f2e0350507962fc4 branch=main release=v26.7.3 scanned=2026-11-25 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d4dbcac49f612774116fc176bf8ac5de8cee4321 branch=main release=v1.20.2 scanned=2026-11-25 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=fdae62a6b79a3584267e6361e9fa743d5136b1b8 branch=main release=— scanned=2026-11-25 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=a817d82f45389f99869f9040e6980be6a1fcbe35 branch=main release=v0.20.2 scanned=2026-11-25 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=6b1b335c654357de6f418b4e265b4ef40bc005ab branch=main release=v0.5.1 scanned=2026-11-25 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-25 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=6cf77a2b52a528d2bac5468b7a33abb7bf45ac68 branch=main release=v0.15.2 scanned=2026-11-25 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=3113936297208d9ba2cab734964f1ff7b74595ab branch=main release=v0.18.9 scanned=2026-11-25 -->
