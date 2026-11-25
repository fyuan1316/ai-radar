# 昇腾算力栈 diff 雷达 2026-11-26

## 摘要
- **vNPU 软切分新增"在线/离线混部"优先级抢占**:Pod 注解 `huawei.com/vnpu-priority`("0"/"1")从调度器一路传到 vCANN。高优先级 vNPU 在调度侧**不占算力配额、跳过 cores 校验和同卡 policy 一致性约束**,放置改用"高优先级 vNPU 数最少 → 剩余算力最多"的字典序打分;device-plugin 把它在 `npu_info.config` 里写成 `aicore-quota=0`、`scheduling-policy=best-effort`、`vnpu_priority=1`。**显存仍严格校验、不超卖**。需要节点上的 ubs-virt 劫持库升级,未升级时退化为不限算力的 best-effort。
- **npu-dra-plugin 落地 DRA 设备健康上报**(`WatchHealthStatus`,对接 K8s DRA 设备健康 API):通过 DCMI `dcmi_get_device_health` 周期探测(默认 10s,范围 1~25s),健康码 ≥ `unhealthyHealthCodeThreshold`(默认 2)判 Unhealthy;带滞回(连续 2 次判坏、连续 3 次判好)和 `manualIsolation` 手动隔离;故障码只写进 Message,不参与判定。ResourceSlice 设备新增 `cardID` 属性。
- **npu-dra-plugin 软切分配额修复**:改为生成 `/etc/ld.so.preload` 挂进容器,强制加载 vCANN-RT 劫持库 `libvruntime.so`。代码注释明确写了"未加载该库配额会静默失效";默认 ConfigMap 也把原来挂的 `libboundscheck.so` 换成了 `libvruntime.so`。与 vNPU 仓本期把 libboundscheck 静态链进 libvruntime.so 是同一条线。mind-cluster 本期只有测试、文档、CI 和 faultdiag 小修;另外 CI 门禁新增了两个 POC 分支(`poc_master_superpod-defrag` 超节点碎片整理、`poc_master_volcano-refactor` volcano 重构)。其余 8 仓零提交。

## 当日重要改变
- vNPU [新能力] 软切分优先级抢占:新增 Pod 注解常量 `VNPUPriorityAnnotation = "huawei.com/vnpu-priority"`,`XPUDevice.HighPriorityCount` 参与打分;device-plugin `writeVxpuInfo` 新增 `vnpu_priority=` 行;xpu-exporter 新增指标 `xpu_vnpu_priority`。证据 `volcano-xpu-plugin/plugin/vxpu.go`、`plugin.go`、`node.go`、`xpu-device-plugin/pkg/plugin/plugin.go`。 https://gitcode.com/openFuyao/vNPU/commit/63935ae74ad8821ea4ca429cdd5df498f804c115
- vNPU [行为变更] 调度器对 `vnpu-priority` **严格校验**:只接受精确的 "0"/"1",其他值(包括 " 1")在 predicate 阶段直接失败;device-plugin 侧则容错,非法值回退为 0。高优先级 Pod 声明的 `vnpu-cores` 会被告警后忽略,`vnpu-soft-scheduler-policy` 失效。 https://gitcode.com/openFuyao/vNPU/commit/63935ae74ad8821ea4ca429cdd5df498f804c115
- npu-dra-plugin [新能力] 实现 `kubeletplugin.DRAPlugin.WatchHealthStatus`,用 `kubeletplugin.HealthService(driver.healthProber != nil)` 按需对外声明健康服务;新增 flag `--health-probe-interval`、`--health-policy-config`,ConfigMap 新增 key `health.config`;`pkg/dcmi` 通过 dlsym 加载 `dcmi_get_device_health`、`dcmi_get_device_errorcode_v2`、`dcmi_get_device_errorcode_string`。 https://gitcode.com/openFuyao/npu-dra-plugin/commit/dc00ce213e3e78e0cdbf14090d548010609677b1
- npu-dra-plugin [API变更] ResourceSlice 设备属性新增 `cardID`(只有经 DCMI 发现的设备才有;sysfs 回退发现的设备没有,健康状态一律报 Unknown);软切分设备的属性白名单 `getSoftDeviceAttributes` 也同步透传 `cardID`。 https://gitcode.com/openFuyao/npu-dra-plugin/commit/dc00ce213e3e78e0cdbf14090d548010609677b1
- npu-dra-plugin [行为变更] 软切分 CDI edits 新增 bind 挂载 `/etc/ld.so.preload`(内容是 `/opt/enpu/vcann-rt/lib/libvruntime.so`)。注释原文写明"this REPLACES any existing /etc/ld.so.preload in the image"——会覆盖镜像自带的同名文件。 https://gitcode.com/openFuyao/npu-dra-plugin/commit/8347399b8d16b12037433e39ab189af18bfd9dcf
- mind-cluster [架构方向] CI 的 `poc-PR-pipeline_mindcluster.yml` 把新分支 `poc_master_superpod-defrag`、`poc_master_volcano-refactor` 纳入门禁。用 branches API 核实,两分支的描述分别是"volcano 超节点碎片整理POC分支""用于volcano重构的poc分支",当前 HEAD 都还停在 master 的 f393144d(11-11),**暂无独立提交**。 https://gitcode.com/Ascend/mind-cluster/commit/d7b523094cd32a1710e00c4b157cc05becc32237

## vNPU: 4414d35e -> 21a52631
- 比较: 4414d35e61e85fc8eb501b68e70b8ba04b4816e0..21a52631 | tag: v26.9.0 | commits=2 | truncated=false(CHANGELOG 新增 v0.2.0 条目,但还没打 tag)
- 源链接: https://gitcode.com/openFuyao/vNPU/compare/4414d35e61e85fc8eb501b68e70b8ba04b4816e0...21a52631996530ae84da9ca97eb469d9cab436f3 ,MR https://gitcode.com/openFuyao/vNPU/merge_requests/99

### AI 总结重点(源码 diff 为据)
- **优先级注解的解析与校验分两层**。调度侧新增 `getVnpuPriority(pod)`:注解缺省或为空串时取 `VNPUPriorityNormalLevel=0`;值不是精确的 `"0"`/`"1"` 就返回 error,`EvaluateXPUDeviceAllocation` 直接以此失败。另外,只有非高优先级 Pod 才调用 `getSchedulerPolicy`,高优先级 Pod 的 `schedulerPolicy` 固定为空串。device-plugin 侧的 `util.GetVnpuPriority` 则容错,非法值只打 warning 并回退为 0,避免卡住 Allocate。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/vxpu.go</summary>

  ```diff
  -	schedulerPolicy, policyErr := getSchedulerPolicy(pod)
  -	if policyErr != nil {
  -		return false, PodDevices{}, policyErr
  +	vnpuPriority, prioErr := getVnpuPriority(pod)
  +	if prioErr != nil {
  +		return false, PodDevices{}, prioErr
  +	}
  +	schedulerPolicy := ""
  +	if vnpuPriority != util.VNPUPriorityHighLevel {
  +		var policyErr error
  +		schedulerPolicy, policyErr = getSchedulerPolicy(pod)
  ...
  +	if priority != util.VNPUPriorityNormal && priority != util.VNPUPriorityHigh {
  +		return util.VNPUPriorityNormalLevel, fmt.Errorf(
  +			"invalid vnpu priority: %q, must be %q or %q",
  ```
  </details>
- **高优先级 vNPU 不进入算力配额核算**。`IsDeviceQualified` 对高优先级请求跳过两项检查:`Base100-UsedCores < ReqXPUCores` 的算力余量检查,以及 `device.Policy != val.ReqPolicy` 的同卡 policy 一致性检查。`applySoftModeDevice` 与 `updateXPUDeviceUsage` 中,高优先级只递增 `HighPriorityCount`,不累加 `UsedCores`;但显存 `UsedMemory` 和 vid 槽位照常占用。`validateContainerResource` 也对高优先级放开三项限制:`vnpu-number>1` 且 cores 非整卡的组合、`cores>100`、elastic/fixed-share 必须声明 cores。效果是**算力维度允许跨优先级超卖,显存维度不超卖**。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/vxpu.go / plugin.go</summary>

  ```diff
  -	if util.Base100-device.UsedCores < val.ReqXPUCores {
  +	if val.ReqVNPUPriority != util.VNPUPriorityHighLevel && util.Base100-device.UsedCores < val.ReqXPUCores {
  ...
  -	device.UsedCores += val.ReqXPUCores
  +	if val.ReqVNPUPriority == util.VNPUPriorityHighLevel {
  +		device.HighPriorityCount++
  +	} else {
  +		device.UsedCores += val.ReqXPUCores
  +	}
  ```
  </details>
- **高优先级放置使用独立的打分规则,binpack/spread 对它不生效**。节点级用 `computeHighPriorityNodeScore`,卡级用 `highPriorityDeviceScore`,公式都是"剩余算力 − 1000 × 高优先级 vNPU 数"(`highPriorityCountWeight=1000`,而剩余算力最大只有 100),所以等价于先比高优先级 vNPU 数、再比剩余算力的字典序,按降序取。在 `NodePredicateForTask` 和 `AllocateContainerDevices` 两处,spread 分支都加了 `podPriority != High` 的条件,即普通优先级 Pod 的调度行为不变。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/node.go / type.go</summary>

  ```diff
  +	if vnpuPriority == util.VNPUPriorityHighLevel {
  +		return computeHighPriorityNodeScore(devices)
  +	}
  ...
  +	return float64(sumRemainingCores) - float64(highPriorityCountWeight*sumHighPriority)
  ...
  +	highPriorityCountWeight = 1000
  ```
  </details>
- **节点侧下发给 vCANN 的配置固定为"有效值"**。`writeVxpuInfo` 遇到高优先级 vNPU 时,把 `aicore-quota` 强制写成 0、`scheduling-policy` 强制写成 `PolicyBestEffortInt`(测试样例中为 3),并新增一行 `vnpu_priority=%d`。普通 vNPU 也会多出 `vnpu_priority=0` 这一行。源码注释说明了这样写的原因:旧 vCANN 节点读不懂优先级字段,会按"不限算力的 best-effort"确定性运行。整卡(preload/full card)路径不走劫持库,所以优先级不生效。`buildVxpuDevice` 对高优先级把对外暴露的 `VxpuCoreLimit` 置 0。
  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/plugin.go</summary>

  ```diff
  +		aicoreQuota := contDev.Usedcores
  +		policy := contDev.Policy
  +		if contDev.Priority == xpu.PriorityHighInt {
  +			aicoreQuota = 0
  +			policy = xpu.PolicyBestEffortInt
  +		}
  -		info += fmt.Sprintf("aicore-quota=%d\n", contDev.Usedcores)
  +		info += fmt.Sprintf("aicore-quota=%d\n", aicoreQuota)
  ...
  +		info += fmt.Sprintf("vnpu_priority=%d\n", contDev.Priority)
  ```
  </details>
- **Pod 设备注解格式不变**。`ContainerDevice.Priority` 的注释写明 "runtime only and never serialized into the pod device annotation (kept at 7 fields)"。调度器从注解恢复 in-use 设备时,`getInUseXPUDevices` 每个 Pod 重新解析一次优先级,再填回 `device.Priority`。因此本期**不存在**上期 v1 annotation 9→10 字段那种需要按顺序升级的问题。另一处细节:调度器给高优先级 Pod 编码进注解的仍是它声明的 cores 值(注释原文 "encoded UsedCores below still carries the declared value for compatibility with older device-plugins")。如果 device-plugin 是旧版,读不到优先级,就会按这个声明值限额,抢占不生效。
  <details><summary>代码依据 volcano-xpu-plugin/common/device.go</summary>

  ```diff
  +	// Priority is the vnpu priority of the owning pod, runtime only and never
  +	// serialized into the pod device annotation (kept at 7 fields).
  +	Priority int
  ```
  </details>
- **可观测与依赖**。xpu-exporter 新增 `xpu_vnpu_priority`(0 普通 / 1 高),标签沿用 vNPU 粒度的 `vnpuLabel`。子模块 `third_party/ubs-virt` 从 49d01051 升到 35e0b3d3;新增子模块 `third_party/libboundscheck`(v1.1.16)。CI 脚本 `prepare_libboundscheck` 把它打成 `-fPIC` 静态库链进 vcann-rt。脚本注释给出的理由是:业务容器通过 `/etc/ld.so.preload` 预加载 libvruntime.so,不必另装 libboundscheck。
  <details><summary>代码依据 xpu-exporter/collector/npuservice/npu_collector.go / ci/pipeline/script/_common_utils.sh</summary>

  ```diff
  +	xpuVnpuPriorityDesc = prometheus.NewDesc("xpu_vnpu_priority",
  +		"vNPU priority (0: normal, 1: high)", vnpuLabel, nil)
  ...
  +# vcann-rt requires securec and linking it statically keeps libvruntime.so
  +# self-contained at runtime: business containers preload it through
  +# /etc/ld.so.preload without libboundscheck installed.
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾软切分开始做"在线/离线混部"**:调度层把算力从"硬配额"降级为"可超卖、由运行时抢占兜底",显存仍按硬配额管理。这与 GPU 侧"显存隔离 + 算力时间片优先级"的思路一致。对我们的影响:多厂商切分的统一抽象里,应把"优先级/可抢占"做成与"算力配额"正交的维度,不能只建模 cores/memory 两个数值。证据边界:只看到调度器和 device-plugin 的传递链路;真正的抢占和防饿死逻辑在 ubs-virt(vCANN)子模块里,本 diff 只有子模块指针变化,没有读到实现。
- **优先级目前只有两档,而且是 Pod 注解,不是 K8s PriorityClass**:没有与 volcano 队列或 PriorityClass 联动,集群均衡也只按高优先级 vNPU 的个数打分。可能的后续方向:更多档位,或者与 PriorityClass、volcano 的 queue 优先级打通。证据边界:diff 中没有看到对 PriorityClass 的任何引用。

## npu-dra-plugin: f0654355 -> 4f20ad9b
- 比较: f0654355fb65ac3ffca9a41357100a82fde4fc10..4f20ad9b | tag: v26.9.0 | commits=4 | truncated=false
- 源链接: https://gitcode.com/openFuyao/npu-dra-plugin/compare/f0654355fb65ac3ffca9a41357100a82fde4fc10...4f20ad9bd8a6d248315d32f42fbd706c6e241713 ,MR https://gitcode.com/openFuyao/npu-dra-plugin/merge_requests/56 、 https://gitcode.com/openFuyao/npu-dra-plugin/merge_requests/58

### AI 总结重点(源码 diff 为据)
- **`WatchHealthStatus` 从直接返回 `ErrHealthNotSupported` 改为真正实现**。新逻辑:每个周期先调用 `healthProber.Probe(ctx, targets)`,再用 `buildHealthReport` 组装一份全量 `DeviceHealthReport` 发给 kubelet。每台设备的 `HealthCheckTimeout` 取 2 倍探测周期,下限 10s。只要 ctx 已取消,一律返回 nil(上游接口的契约要求)。`kubeletplugin.HealthService(...)` 只在 prober 成功创建时才对外声明健康服务,所以 gpu profile、`--health-probe-interval<=0`、非 linux/cgo 构建这几种情况下,kubelet 根本不会发起 watch。
  <details><summary>代码依据 cmd/ascend-npu-dra-kubeletplugin/driver.go</summary>

  ```diff
   func (d *driver) WatchHealthStatus(ctx context.Context, reports chan<- kubeletplugin.DeviceHealthReport) error {
  -	return kubeletplugin.ErrHealthNotSupported
  +	if ctx.Err() != nil {
  +		return nil
  +	}
  +	if d.healthProbeInterval <= 0 || d.healthProber == nil {
  +		return kubeletplugin.ErrHealthNotSupported
  +	}
  ...
  +		kubeletplugin.HealthService(driver.healthProber != nil),
  ```
  </details>
- **健康判定只看 DCMI 健康码,故障码不参与**。`EvaluateHealth` 的映射规则:`0xFFFFFFFF` 和未知值 → Unknown;`health >= UnhealthyHealthCodeThreshold`(取值 1~3,默认 2)→ Unhealthy;其余 → Healthy,Message 中附带 minor alarm 说明。故障码由 `GetDeviceErrors` 取前 3 条、每条描述截断到 128 字符,只拼进 Message。同一 PR 内 `HealthPolicy` 里的 `FaultCodes`、`UnknownCodeLevel` 已被标为 Deprecated:旧配置仍能解析,但会被忽略,启动时打 warning。
  <details><summary>代码依据 internal/profiles/npu/health_evaluator.go / health_policy.go</summary>

  ```diff
  +	if health == dcmiHealthDeviceAbsent {
  +		return DeviceHealthUnknown, "DCMI reports device does not exist or is not started"
  +	}
  ...
  +	if health >= uint32(threshold) {
  +		return DeviceHealthUnhealthy, message
  +	}
  +	return DeviceHealthHealthy, message
  ...
  +	// Deprecated: fault codes no longer participate in the health decision.
  +	FaultCodes       map[string]FaultLevel `yaml:"faultCodes"`
  ```
  </details>
- **滞回与手动隔离**。`healthTracker.Apply` 的规则:首次观测按原值上报;之后要连续 `UnhealthyThreshold`(默认 2)次异常才切到 Unhealthy,连续 `HealthyThreshold`(默认 3)次正常才恢复;Unknown 原样透传,同时清零连续计数、保留已确认状态。按默认 10s 周期算,约 20s 报坏、30s 报恢复。`probeTarget` 中 `IsManuallyIsolated` 优先级最高:命中的设备直接报 Unhealthy,不查 DCMI。prober 是进程级单例,用 mutex 串行化,源码注释给出的理由是 `pkg/dcmi` 的 C handle 是进程全局变量、非线程安全。
  <details><summary>代码依据 internal/profiles/npu/health_tracker.go / health_probe_linux.go</summary>

  ```diff
  +	if observed == DeviceHealthUnknown {
  +		if entry, ok := t.entries[device]; ok {
  +			entry.bad = 0
  +			entry.good = 0
  +		}
  +		return DeviceHealthUnknown
  +	}
  ...
  +	if p.policy.IsManuallyIsolated(target.DeviceName) {
  +		result.State = DeviceHealthUnhealthy
  +		result.Message = "manually isolated by health policy"
  ```
  </details>
- **失败分级**:有两种情况视为"永久不支持",返回 `ErrHealthUnsupported`,让 kubelet 停止 watch:一是 `libdcmi.so` 不存在(`dcmi.ErrLibraryUnavailable`),二是健康符号未导出(`dcmi.ErrSymbolUnavailable`,对应 wrapper 返回 `dcmiFuncUnloaded=-2`)。`dcmi init` 失败(例如驱动尚未就绪)只把所有设备报为 Unknown,下个周期重试 Init。故障码接口不可用时降级为只报健康码,Message 末尾追加 "error codes unavailable"。
  <details><summary>代码依据 pkg/dcmi/dcmi.go</summary>

  ```diff
  +    dcmi_get_device_health_func = (int (*)(int, int, unsigned int *))
  +        dlsym(dcmiHandle, "dcmi_get_device_health");
  ...
  +	case dcmiFuncUnloaded:
  +		return 0, fmt.Errorf("get device health: %w", ErrSymbolUnavailable)
  ```
  </details>
- **设备寻址**:发现阶段把 DCMI 物理卡号写进 ResourceSlice 设备属性 `cardID`(`DeviceSpec.CardID *int`,sysfs 回退发现的设备不写)。探测时按 `(cardID, deviceID=chipID)` 直接寻址。`healthProbeTargets` 在任何 goroutine 启动前做一次只读快照,并按设备名排序,避免与 `updateDevices` 并发改写属性 map 产生竞争。
  <details><summary>代码依据 internal/profiles/npu/dcmi.go / npu.go</summary>

  ```diff
  +	if spec.CardID != nil {
  +		attributes[cardIDAttr] = resourceapi.DeviceAttribute{IntValue: ptr.To(int64(*spec.CardID))}
  +	}
  ...
  +	if cardID, ok := physDev.Attributes[cardIDAttr]; ok {
  +		attributes[cardIDAttr] = cardID
  +	}
  ```
  </details>
- **软切分配额执行修复:用 `/etc/ld.so.preload` 取代依赖 LD_PRELOAD**。`SoftManager.CreateVNPU` 为每个 claim 在 host 配置目录生成 `ld.so.preload`,内容为 `SoftSharePreloadLibPath=/opt/enpu/vcann-rt/lib/libvruntime.so`;`buildSoftVNPUCDIEdits` 把它只读 bind 到容器的 `/etc/ld.so.preload`。如果 `softShareMounts` 没有提供该库路径(或 hostPath 为空),`hasSoftPreloadMount()` 判为缺失,自动注入默认挂载 `/opt/xpu/lib/libvruntime.so`,保证"预加载文件"和"库挂载"成对出现。源码注释给出的改法理由是:LD_PRELOAD 环境变量会和镜像自带的、或其他设备注入的 LD_PRELOAD 冲突,导致加载静默失败。部署清单 `01-configmap.yaml` 删掉了原来的 `libboundscheck.so` 挂载,改挂 `libvruntime.so`;`npu-monitor` 也更名为 `enpu-monitor`。
  <details><summary>代码依据 internal/profiles/npu/cdi_edits.go / internal/vnpu/soft_manager.go / manifests/deploy/01-configmap.yaml</summary>

  ```diff
  +		// NOTE: this REPLACES any existing /etc/ld.so.preload in the image (it is
  +		// not merged with it); verify the base image does not rely on its own file.
  +		mounts = append(mounts, &cdispec.Mount{
  +			HostPath:      filepath.Join(out.HostConfigDir, vnpupath.SoftSharePreloadFileName),
  +			ContainerPath: vnpupath.SoftSharePreloadContainerTarget,
  ...
  -    - hostPath: /opt/xpu/lib/libboundscheck.so
  -      containerPath: /lib/libboundscheck.so
  +    - hostPath: /opt/xpu/lib/libvruntime.so
  +      containerPath: /opt/enpu/vcann-rt/lib/libvruntime.so
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾 DRA 驱动补上了"设备健康"这块,和 NVIDIA DRA driver 的健康上报对齐**。但当前的 Unhealthy 只进入 kubelet 的健康 API(按上游 KEP-4680 语义,反映在 Pod status 里,这是背景知识、不在本 diff 中),**不会把设备从调度里摘掉**。`FaultLevel` 的注释原文是 "(for example by future DeviceTaint support)",说明下一步大概率会接 DRA DeviceTaint,做到调度侧真正隔离。证据边界:本期没有任何 taint 相关代码。对我们的影响:对外宣传"DRA 健康上报"时,要区分"可观测"和"可隔离"。
- **软切分劫持库的交付方式统一为"宿主机安装 + ld.so.preload 注入 + 静态链接依赖"**(dra-plugin 与 vNPU 两仓同步变化)。风险点:覆盖镜像自带 `/etc/ld.so.preload` 会和某些安全/APM 类基础镜像冲突,需要在兼容性清单里写明。证据只覆盖 DRA 路径;vNPU 仓 device-plugin 路径自己的注入方式,本期没有看到 diff。

## mind-cluster: e845d2e1 -> 50a33a26
- 比较: e845d2e1c5337c0831e54d9bbdaa0bf8231c4f0c..50a33a26 | tag: v26.3.0-beta.2 | commits=22 | truncated=false
- 源链接: https://gitcode.com/Ascend/mind-cluster/compare/e845d2e1c5337c0831e54d9bbdaa0bf8231c4f0c...50a33a268d77a14bb8bb42bd32d24452b2b1e54a
- 目录分布核对(不带 PATHPREFIX 全量 146 文件):docs/zh 120、ascend-faultdiag 7、ascend-faultdiag-online 6、ascend-for-volcano 6、.gitcode/workflows 3、docker/ascend-dynamic-resource-allocation 2(仅 OVERVIEW 文档措辞)、README 1、noded 1(README)。**没有冒出新的 component**,PATHPREFIX 清单无需改动。faultdiag-online 的 6 个文件全部是 `*.pb.go` 补版权头,已过滤。

### AI 总结重点(源码 diff 为据)
- **ascend-for-volcano 只新增测试(6 个 `_test.go`,无实现改动)**。这些测试固定了此前已合入的"静默故障 + pod error 退避"语义:`TimeGateAllows(ToleranceForbidden, 999)` 恒为 false,afterTime ≤ 0 时立即放行;`expirePodErrorLocked` 按 `MaxPodErrorToleranceAfterTime` 淘汰过期的卡级 pod error 记录,并在节点下记录全部过期后删除该节点条目;`getPodFailedTime` 取容器 `Terminated.FinishedAt` 的最大值,其次取 `LastTerminationState`,都没有时回退为 now;`stripAffinitySegments("chip8-node8-ra64-sp")` 返回 `"chip8-node8"`。实现见 11-03 期(`DefaultSilentUnhealthyToleranceAfterTime` 0→600)。
  <details><summary>代码依据 component/ascend-for-volcano/common/util/time_gate_test.go / common/cache/pod_error_test.go</summary>

  ```diff
  +		{"forbidden never allows", ToleranceForbidden, 999, false},
  +		{"zero allows immediately", 0, 0, true},
  +		{"elapsed equals after-time", DefaultSilentUnhealthyToleranceAfterTime, DefaultSilentUnhealthyToleranceAfterTime, true},
  ...
  +	expired := now - util.MaxPodErrorToleranceAfterTime - 1
  +	kept := now - util.MaxPodErrorToleranceAfterTime + 1
  ```
  </details>
- **faultdiag BMC 解析:没有时间戳的行改为丢弃**。`BMCParser` 原来只在设置了 start/end 时间过滤时才解析行时间,否则 `occur_time=""`,事件因此丢失时间(对应提交标题"无 plog 场景该行时间丢失")。现在每行都调用 `_filter_log_time`,解析不出时间就 `continue` 跳过。副作用:原先能入库、只是缺时间的行,现在会被直接丢掉。
  <details><summary>代码依据 component/ascend-faultdiag/src/ascend_fd/pkg/parse/knowledge_graph/parser/bmc_parser.py</summary>

  ```diff
  -            if self.start_time or self.end_time:
  -                occur_time = self._filter_log_time(log_line)
  -            else:
  -                occur_time = ""
  +            occur_time = self._filter_log_time(log_line)
  +            if not occur_time:
  +                continue
  ```
  </details>
- **faultdiag 知识图谱:6 个 BMC 故障码由大写 `0X` 改为小写 `0x`**(`0x8F184C25`~`0x8F184C2A`,提交标题说是电源告警)。key 和 `regex.in` 匹配串一起改。从提交标题推断:BMC 日志里这几个码是以小写输出的,原配置的 `in` 子串匹配命中不了,这几类电源告警之前一直诊断不出来。证据边界:没有核实 BMC 日志的原始格式。
  <details><summary>代码依据 component/ascend-faultdiag/src/ascend_fd/configuration/kg-config.json</summary>

  ```diff
  -        "0X8F184C25": {
  +        "0x8F184C25": {
  ...
  -                "in": ["0X8F184C25", "Asserted"]
  +                "in": ["0x8F184C25", "Asserted"]
  ```
  </details>
- **faultdiag 两套 `safe_read_open`(ascend_fd 和 ascend_fd_tk)在文本模式下默认 `errors="replace"`**。效果:日志中的非法 UTF-8 字节被替换为占位符,不再抛 UnicodeDecodeError、导致整个文件读取失败;调用方显式传入 errors 时不覆盖,二进制模式也不注入该参数。
  <details><summary>代码依据 component/ascend-faultdiag/toolkit_src/ascend_fd_tk/utils/file_tool.py</summary>

  ```diff
  -    file_stream = open(file_real_path, *args, **kwargs)
  +    mode = args[0] if args else "r"
  +    is_binary = "b" in mode
  +    if is_binary:
  +        file_stream = open(file_real_path, *args, **kwargs)
  +    else:
  +        kwargs.setdefault("errors", "replace")  # 文本模式，默认容错
  ```
  </details>
- **CI 改动(不在 component 内,补充记录)**:两条流水线的 `permissions` 从 workflow 级下放到 SCA / malicious-scan 两个 job,并收窄为 `repository: read` + `id-token: write`(提交标题 safe-least_privilege)。新增 `api_scan.yml`。poc 流水线的分支列表新增 `poc_master_superpod-defrag`、`poc_master_volcano-refactor`。
  <details><summary>代码依据 .gitcode/workflows/poc-PR-pipeline_mindcluster.yml</summary>

  ```diff
  -    branches: [ 'resource_migration_poc', 'branch_v26.1.0', 'branch_v26.0.0', 'branch_v7.3.0' ]
  +    branches: [ 'resource_migration_poc', 'branch_v26.1.0', 'branch_v26.0.0', 'poc_master_superpod-defrag', 'poc_master_volcano-refactor', 'branch_v7.3.0' ]
  ```
  </details>

### 后续发展方向 [AI]
- **"超节点碎片整理"和"volcano 重构"已经立项为 POC 分支**。前者关系到 Atlas 950 SuperPoD 这类超节点的整机/整框资源碎片问题(重调度/迁移),后者可能改变 ascend-for-volcano 插件的整体结构。按 task 的已知盲区,feature 分支上的开发不会出现在 master compare 里。建议后续每期加查一次这两个分支的 HEAD 是否离开 f393144d。证据边界:两分支目前都没有独立提交,上述判断只依据分支描述。
- README 把对外口径从 "A5" 统一改成 "Ascend 950"(新闻条目里有"支持 Ascend 950 软切分、A2/A3 动态硬切分"),和上期 vNPU 能力表 `Ascend950 SupportHardCut=false` 的结论一致:950 只支持软切分。

## 本期无实质改动(折叠)
- npu-operator: ddcf0eb7..ddcf0eb7 无新提交(v26.9.0)
- npu-container-toolkit: c720a3b8..c720a3b8 无新提交(v26.9.0)
- npu-driver-installer: bd1b2a9e..bd1b2a9e 无新提交(v26.9.0)
- npu-node-provision: 717ef777..717ef777 无新提交(v26.6.0)
- npu-feature-discovery: 4ba6e58e..4ba6e58e 无新提交(v26.9.0)
- volcano-ext: 0f265f98..0f265f98 无新提交(v1.9.0)
- ub-network-device-plugin: 9cc5dbdd..9cc5dbdd 无新提交(v26.9.0)
- ub-network-bandwidth-operator: d4ee1a47..d4ee1a47 无新提交(无 tag)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=50a33a268d77a14bb8bb42bd32d24452b2b1e54a tag=v26.3.0-beta.2 scanned=2026-11-26 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=vNPU sha=21a52631996530ae84da9ca97eb469d9cab436f3 tag=v26.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=npu-dra-plugin sha=4f20ad9bd8a6d248315d32f42fbd706c6e241713 tag=v26.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=npu-feature-discovery sha=4ba6e58e3e132f61936ae2c619f91d9e75c5ec90 tag=v26.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=9cc5dbdd87c01f90aa7f9ea8038b7a1ed5b2bd2d tag=v26.9.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=ub-network-bandwidth-operator sha=d4ee1a478ec50c0c543b73f01a00944467e8018d tag=— scanned=2026-11-26 -->
