# HAMi diff 雷达 2026-11-26

## 摘要
- HAMi 主仓新增 **MPS v3 后端**(新 operatingmode `mps-v3`,#3443)。它不走 HAMi-core 的 CUDA hook,而是对接宿主机上由运维托管的 **NVIDIA r620 驱动 MPS v3 守护进程**:每个容器对应一个 MPS namespace,同一组 GPU 共用一个 MPS server。算力支持两种模式:按百分比限制(`namespace-cap` / `server-timeslice`),或通过 `hami.io/mps-sm-count` 申请**真实的静态 SM 分区**(`sm-partition create --chunks`)。显存上限由 NVIDIA Container Toolkit ≥1.20.1 的 CDI `createRuntime apply-cuda-memory-limits` hook 落地。启用门槛很高:驱动主版本必须是 620、只能用 CDI 设备列表策略、UUID 设备 ID、memory/core scaling=1、cgroup v2、节点不能处于 MIG。调度器 `Fit` 新增 `mpsV3Fits`,同一张物理卡上禁止混用"静态 SM"和"百分比"两种申请方式,并保证同一 GPU 只属于一个 GPU 组合。这是 HAMi 在"hook 软切分""MIG"之外的**第三条 NVIDIA 切分路径**:由驱动执行隔离,而不是靠用户态拦截。
- HAMi 主仓新增独立包 `pkg/tracing`(OpenTelemetry,#3529)。它定义了 Pod 注解 `hami.io/traceparent`,用来把 webhook、scheduler、device plugin 三段 span 串成一条 trace;导出只支持 OTLP gRPC,采样器跟随 `OTEL_TRACES_SAMPLER`。本期**只有包本身,还没有任何组件调用 `tracing.Setup`**(compare 里没有 cmd/ 或调用点改动),属于先铺基础设施。
- HAMi-core 修复了"进程退出后显存仍被计入"的问题(#433,对应 issue #432)。`exit_handler` 不再把 slot 的 PID 置 0,只把 status 标成 0。通过 nvml/cuMemGetInfo 上报显存时,会跳过"整个进程已消失"的 slot,并就地回收这些 slot。`proc_alive` 改为优先用 pidfd 判断进程存活,不支持时回退到 /proc,并修正了"主线程已退出但其他线程仍在运行"被误判为死亡的问题。主仓 libvgpu 子模块已同步到这次修复(#3532)。volcano-vgpu、ascend-device-plugin、WebUI 三个仓零提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力][架构方向] 新增顶层独立包 `pkg/tracing`(tracing.go / sampler.go / annotation.go)。新的 Pod 注解契约是 `hami.io/traceparent`,本期尚未接入任何组件。https://github.com/Project-HAMi/HAMi/pull/3529
- Project-HAMi/HAMi [新能力] MPS v3 后端:新增子目录 `pkg/device-plugin/nvidiadevice/nvinternal/cudainfo/`(cgo 调 `cuDeviceGetAttribute` 读取 SM 几何信息),以及 `plugin/mpsv3.go`(1404 行)、`pkg/device/nvidia/mpsv3.go`、`cdi/memory_limits.go`。用户面新增 4 个 Pod 注解(`hami.io/mps-compute-mode` / `mps-sm-count` / `mps-sm-shareable` / `mps-sm-max-chunks`),节点配置新增 `mpsv3` 对象,chart 新增 `devicePlugin.mpsV3.{enabled,root,binary}`。https://github.com/Project-HAMi/HAMi/pull/3443
- 其余信号核对:`[API/CRD变更]` 两仓 helper 均为"无 API/CRD 路径命中";`[弃用/移除]` 无;`[版本跨档]` HAMi 仍为 v2.11.0,其余仓 release 未变。
- 规则外提示:`mps-v3` 节点的设备注册注解改用 `json.Marshal` 编码,不再走原来的 `device.MarshalNodeDevices`,这样才能把 `CustomInfo`(SM 几何、compute 模式)带给调度器。只读旧格式的外部消费者(如自研面板直接解析 `hami.io/node-nvidia-register`)碰到 mps-v3 节点时需要适配。

## Project-HAMi/HAMi: 1e825e6b -> 7a18e230
- 比较: 1e825e6bd0d9634cd805622bedd9ed8aa6551614 -> 7a18e230 | ahead=4 | files=30 | Release: v2.11.0(未变)
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/1e825e6bd0d9634cd805622bedd9ed8aa6551614...7a18e230656ac91db561a0c314d08176b8db61d7
- 实质提交:
  - `feat(device plugin): support mps v3 backend` — https://github.com/Project-HAMi/HAMi/pull/3443 (de999b41)
  - `feat(tracing): add OpenTelemetry tracing package` — https://github.com/Project-HAMi/HAMi/pull/3529 (6f79d3fd)
- helper 过滤掉的 2 个 `build(deps)` 提交已用 compare API 核对:benchmark 镜像 vllm-openai 升级(#3533),以及 libvgpu 子模块 `4314e0a`→`d8b6c45`(#3532)。后者正是下文 HAMi-core #433 的合并点,与 HAMi-core 本期锚点一致。两项都不涉及默认版本跨档。
- helper 节选中 `mpsv3.go`(两处)、`device.go`、`server.go`、`tracing.go`、`sampler.go` 都被截断。已用 compare API 补拉完整 patch,并补看了节选里缺失的 `values.yaml`、`daemonsetnvidia.yaml`、`register.go`、`pods.go`、`scheduler.go`/`score.go`、`common.go`、`annotation.go`。下文结论覆盖补拉的 hunk。`plugin/mpsv3.go` 中 `reconcileMPSV3`、`release`、`recover` 的清理与恢复细节只读了函数签名和错误串,没有逐行审。

### AI 总结重点(源码 diff 为据)
- **新 operatingmode `mps-v3`,设备插件变成 r620 MPS 控制面的客户端**。`startMPSV3` 启动时依次校验以下前置条件,任一不满足就拒绝启动:`HAMI_MPS_V3_ENABLED`、全部使用 CDI 策略、scaling=1、UUID 设备 ID、已发布 CDI spec 含 `apply-cuda-memory-limits` hook、驱动主版本 `== 620`。随后用 `cudainfo.Geometry()` 读取每张卡的 SM 数和 chunk 粒度:Ampere 为 2,Hopper 及以上的独立卡为 8。若节点需要切换 MIG 状态,直接报错,不会自动 disable。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/mpsv3.go / server.go / cudainfo/info_linux.go</summary>

  ```diff
  +	if !plugin.deviceListStrategies.AnyCDIEnabled() || !plugin.deviceListStrategies.AllCDIEnabled() {
  +		return fmt.Errorf("mps-v3 requires exclusively CDI device-list strategies")
  +	}
  +	if plugin.schedulerConfig.DeviceMemoryScaling == nil || *plugin.schedulerConfig.DeviceMemoryScaling != 1 || plugin.schedulerConfig.DeviceCoreScaling == nil || *plugin.schedulerConfig.DeviceCoreScaling != 1 {
  +		return fmt.Errorf("mps-v3 requires memory and core scaling of 1")
  +	}
  ...
  +	if err != nil || version != 620 {
  +		return fmt.Errorf("mps-v3 requires NVIDIA driver branch r620, got %q", driver)
  +	}
  ```
  ```diff
  +	if plugin.operatingMode == nvidia.MpsV3Mode {
  +		return fmt.Errorf("mps-v3 requires MIG disabled with no pending MIG transition; drain and configure the node before enabling this backend")
  +	}
  ```
  ```diff
  +		chunk := int64(0)
  +		if major >= 8 {
  +			chunk = 2
  +			if major >= 9 && integrated == 0 {
  +				chunk = 8
  +			}
  +		}
  +		result[id] = nvidia.MPSV3Geometry{SMs: int64(sms), Chunk: chunk}
  ```
  </details>
- **分配流程:每个容器对应一个 MPS namespace,同一 GPU 组合对应一个 server,先持久化意图再建资源**。`mpsV3Manager.ensure` 的顺序是:先把 allocation 写入 `allocations.json`,用于崩溃后回滚;再 `server create --allowed-devices=<GPU组合>`(仅在 server 尚不存在时),然后 `namespace create`、`namespace set --active-thread-percentage`。静态 SM 模式下,还会对每张卡执行 `sm-partition create --chunks/--include-remainder/--shareable[/--max-chunks]`,并把分区绑定到 namespace。在静态 SM 或 server-timeslice 模式下,namespace 的 thread 百分比固定为 100,算力限制改由 SM 分区或 server 的 `--timeslice-pct` 承担。同一张卡上若混用静态 SM 与百分比申请,或 GPU 组合不一致,都会判为冲突。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/mpsv3.go(ensure)</summary>

  ```diff
  +			case a.ComputeMode != other.ComputeMode || (a.SMCount > 0) != (other.SMCount > 0):
  +				conflict.error = fmt.Errorf("cannot mix static SM and percentage sharing on GPU %s", gpu)
  ...
  +	// Persist intent before creating allocation resources. Rollback derives all resource
  +	// names from this record, including partitions created just before a crash.
  +	m.generation++
  +	m.allocations[a.Namespace] = a
  +	if err := m.save(); err != nil {
  ...
  +	if a.ComputeMode == nvidia.MPSV3ServerTimeslice {
  +		if _, err = m.run(ctx, "server", "set", a.Server, "--timeslice-pct="+strconv.FormatInt(a.Percent, 10)); err != nil {
  ...
  +			args := []string{"sm-partition", "create", m.partitionName(a, gpu), "--server=" + a.Server,
  +				"--device=" + gpu, "--chunks=" + strconv.FormatInt(chunks, 10),
  +				"--include-remainder=" + strconv.FormatBool(remainder), "--shareable=" + strconv.FormatBool(a.SMPolicy.Shareable)}
  ```
  </details>
- **显存限制交给 NVIDIA 工具链,不再走 libvgpu**。每个 allocation 生成一个独立的 CDI spec(`Kind: hami.io/mps-v3`),内容包括:注入 `NVIDIA_GPU_MEMORY_LIMIT`/`REQUEST`,以及 `CUDA_MPS_PIPE_DIRECTORY=/run/hami-mps`,并把宿主机上该 namespace 的 pipe 目录以只读方式 bind 进容器。启动时 `ValidateMemoryLimitsHooks` 会读取**实际发布**的 GPU CDI spec,确认每张卡都有 `createRuntime` 阶段的 `apply-cuda-memory-limits` hook。admission 阶段 `ValidateMPSV3Environment` 拒绝容器自行设置 `NVIDIA_GPU_MEMORY_*` 或 `CUDA_MPS_*` 环境变量,防止用户绕过限额。
  <details><summary>代码依据 plugin/mpsv3.go(allocationEnvs/cdiSpec)/ cdi/memory_limits.go / pkg/device/nvidia/mpsv3.go</summary>

  ```diff
  +	env := map[string]string{"NVIDIA_GPU_MEMORY_REQUEST": strconv.FormatInt(a.Memory, 10), "NVIDIA_GPU_MEMORY_LIMIT": strconv.FormatInt(a.Memory, 10), "CUDA_MPS_PIPE_DIRECTORY": mpsV3ContainerPipe}
  ...
  +		Version: "0.6.0", Kind: "hami.io/mps-v3",
  +				HostPath: filepath.Join(m.root, "pipe", a.Server, a.Namespace), ContainerPath: mpsV3ContainerPipe,
  +				Options: []string{"bind", "ro"},
  ```
  ```diff
  +				if hook.Path != "" && hook.HookName == "createRuntime" && slices.Contains(hook.Args, "apply-cuda-memory-limits") && slices.Contains(hook.Args, id) {
  ...
  +			return fmt.Errorf("GPU %s has no published createRuntime apply-cuda-memory-limits hook (requires Toolkit >=1.20.1 and UUID device IDs)", id)
  ```
  ```diff
  +		if strings.HasPrefix(env.Name, "NVIDIA_GPU_MEMORY_") || strings.HasPrefix(env.Name, "CUDA_MPS_") {
  +			return fmt.Errorf("container %q sets reserved MPS environment variable %s", ctr.Name, env.Name)
  ```
  </details>
- **调度侧:`Fit` 引入 `mpsV3Fits`,SM 申请按向上取整的百分比计费**。不带 MPS 注解的 Pod 仍可落到非 mps-v3 卡上;一旦带了 `hami.io/mps-compute-mode` 或 SM 请求,就只能落到 mps-v3 卡,而且 Pod 的模式必须与节点注册的 `mpsV3ComputeStrategy` 一致。静态 SM 请求必须能被 chunk 整除,或恰好等于"整卡剩余尾数";每张卡最多只能有一个带 remainder 的分区。计费百分比为 `ceil(sms*100/总SM)`,用于复用原有的 core 配额与容量记账。新增失败原因 `CardMPSV3Incompatible`。另外,`checkType` 把原来的 `strings.Contains(mode, d.Mode)` 改成按逗号分词的精确匹配(`MatchesOperatingMode`)。若沿用子串匹配,请求 `mps-v3` 会误命中 `mps` 卡。
  <details><summary>代码依据 pkg/device/nvidia/mpsv3.go / device.go / pkg/scheduler/score.go</summary>

  ```diff
  +	if dev.Mode != MpsV3Mode {
  +		_, optedIn := pod.Annotations[MPSV3ComputeModeAnnotation]
  +		return cores, sms == 0 && !optedIn
  +	}
  +	nodeStrategy, ok := dev.CustomInfo[MPSV3ComputeModeKey].(string)
  +	if !ok || strategy != nodeStrategy {
  +		return 0, false
  +	}
  ...
  +	remainder := sms % g.Chunk
  +	if remainder != 0 && remainder != g.SMs%g.Chunk {
  +		return 0, false, fmt.Errorf("SM count %d cannot be represented in %d-SM chunks", sms, g.Chunk)
  +	}
  ...
  +	return (sms*100 + g.SMs - 1) / g.SMs, nil
  ```
  ```diff
  -	if ok && !strings.Contains(mode, d.Mode) {
  +	if ok && !MatchesOperatingMode(mode, d.Mode) {
  ...
  +		coresreq, mpsFits := mpsV3Fits(pod, dev, originReq, selected, k.Coresreq, allocated)
  +		if !mpsFits {
  +			reason[common.CardMPSV3Incompatible]++
  +			continue
  +		}
  ```
  </details>
- **`PodInfo` 新增 `RawDevices`,用于保留每个容器各自的分配**。调度器的 `onAddPodLocked` 和 `Filter` 改为调用 `AddPodWithRawDevices`,`mpsV3PodGPUSet` 由此读取已有 Pod 的 GPU 组合,判断新 Pod 是否与它重叠。原有的 `Devices` 保存的是 init 容器折叠后的用量,看不出每个容器的 GPU 组合。
  <details><summary>代码依据 pkg/device/pods.go / pkg/scheduler/scheduler.go</summary>

  ```diff
  +	RawDevices                    PodDevices
  ...
  -	if s.podManager.AddPod(pod, assignedNodeName, effectiveDevices) {
  +	if s.podManager.AddPodWithRawDevices(pod, assignedNodeName, effectiveDevices, rawDevices) {
  ```
  </details>
- **mps-v3 节点的注册注解改为 JSON 编码,并带上 `CustomInfo`;缺少 compute 元数据的卡会被判为不健康**。`RegisterInAnnotation` 在 mps-v3 模式下改用 `json.Marshal(*devices)`。调度器 `GetNodeDevices` 若发现 mps-v3 卡缺少合法的 `mpsV3ComputeStrategy`,就把该卡置为 `Health=false`。
  <details><summary>代码依据 plugin/register.go / pkg/device/nvidia/device.go</summary>

  ```diff
  -	encodeddevices := device.MarshalNodeDevices(*devices)
  +	var encodeddevices string
  +	if plugin.operatingMode == nvidia.MpsV3Mode {
  +		data, err := json.Marshal(*devices)
  ```
  ```diff
  +		if d.Mode == MpsV3Mode {
  +			mode, _ := d.CustomInfo[MPSV3ComputeModeKey].(string)
  +			if mode != MPSV3NamespaceCap && mode != MPSV3ServerTimeslice {
  +				d.Health = false
  ```
  </details>
- **chart 侧默认关闭 mps-v3,并在模板渲染阶段拦截错误配置**。新增 `devicePlugin.mpsV3.enabled=false`,默认 `root: /var/run/hami/mps-v3`(以 hostPath DirectoryOrCreate 方式挂载,插件 Pod 重启后状态仍保留)。若 `deviceListStrategy` 不是纯 `cdi-cri`/`cdi-annotations`,或 root 不是一个专用的绝对路径,helm 直接 `fail`。
  <details><summary>代码依据 charts/hami/templates/device-plugin/daemonsetnvidia.yaml / values.yaml</summary>

  ```diff
  +{{- if .Values.devicePlugin.mpsV3.enabled }}
  +{{- if not (regexMatch "^cdi-(cri|annotations)(,cdi-(cri|annotations))*$" .Values.devicePlugin.deviceListStrategy) }}
  +{{- fail "devicePlugin.mpsV3 requires exclusively cdi-cri or cdi-annotations deviceListStrategy" }}
  ```
  ```diff
  +  # Requires exclusively CDI strategies, Toolkit >=1.20.1, NVIDIA driver branch r620, and cgroup v2.
  +  mpsV3:
  +    enabled: false
  +    root: /var/run/hami/mps-v3
  +    binary: nvidia-cuda-mps-control
  ```
  </details>
- **新增 `pkg/tracing`:跨组件 trace 通过 Pod 注解传递上下文**。`Setup` 只有在设置了 `OTEL_EXPORTER_OTLP[_TRACES]_ENDPOINT` 且未设置 `OTEL_SDK_DISABLED=true` 时才启用,否则返回空操作的 shutdown。endpoint 必须是 http(s) URL;协议非 grpc 时只记一条错误日志,仍然用 gRPC 导出。`Inject`/`Extract` 用 W3C traceparent 读写 `hami.io/traceparent` 注解。采样器外层套了 `ParentBased(linksBasedSampler)`,保证一条 trace 整体保留或整体丢弃。本期 compare 中没有 cmd/ 或 webhook/scheduler 调用点改动,包尚未接入。
  <details><summary>代码依据 pkg/tracing/annotation.go / tracing.go / sampler.go</summary>

  ```diff
  +// TraceparentAnnotation holds the W3C traceparent that links the spans of one
  +// pod placement across the webhook, the scheduler and the device plugin.
  +const TraceparentAnnotation = "hami.io/traceparent"
  ```
  ```diff
  +	if endpoint == "" || sdkDisabled() {
  +		return func(context.Context) error { return nil }, nil
  +	}
  ...
  +	exporter, err := otlptracegrpc.New(ctx)
  ```
  ```diff
  +	return sdktrace.ParentBased(linksBasedSampler{root: root})
  ```
  </details>

### 后续发展方向 [AI]
- **NVIDIA 切分正在分成三条路径**:HAMi-core hook(软隔离)、MIG(硬件分区)、mps-v3(驱动 MPS v3 + SM partition + toolkit 显存 hook)。mps-v3 的隔离由驱动执行,不依赖 LD_PRELOAD 拦截,这补上了 hook 方案"可被绕过、显存只是软限制"的短板。代价是强绑定特定驱动分支和 toolkit 版本:`version != 620` 是硬编码判断,r620 之后的驱动分支在本期代码下会直接拒绝启动。可以预期后续会有放宽驱动版本判断的提交。这条路径与 DRA 原生路径无关:仍然是 device plugin + extender + 注解协议,本期 diff 中没有任何 DRA 代码。
- **调度器开始依赖节点上报的"设备几何"做决策**(SM 数、chunk、GPU 组合放在 `CustomInfo`,注册注解随之改为 JSON)。这是从"显存/百分比两个标量"走向"带拓扑约束的结构化设备描述"。证据只覆盖 mps-v3 一种模式;未见 hami-core/mig 模式迁移到 JSON 注册。
- **可观测性从指标扩展到分布式追踪**:注解中已经预留了 webhook→scheduler→device plugin 的 trace 传递契约。从注解注释和包设计推断,下一步应该是在各组件 main 里接入 `Setup` 并在 Filter/Bind/Allocate 中打 span。本期只看到包本身,没有看到任何调用点。

## Project-HAMi/HAMi-core: 4314e0a7 -> d8b6c459
- 比较: 4314e0a7750eb53dbe865c86abe88b59143390cc -> d8b6c459 | ahead=8 | files=4 | Release: —
- 比较链接: https://github.com/Project-HAMi/HAMi-core/compare/4314e0a7750eb53dbe865c86abe88b59143390cc...d8b6c459bc6bed03a02aebfeb62d460f62e6fc53
- 合并 PR: https://github.com/Project-HAMi/HAMi-core/pull/433(修复 https://github.com/Project-HAMi/HAMi-core/issues/432),7 个提交加 1 个 merge。
- helper 节选中 `multiprocess_memory_limit.c` 与 `process_utils.h` 被截断,已用 compare API 补拉 `src/` 下的完整 patch。

### AI 总结重点(源码 diff 为据)
- **`exit_handler` 不再把 slot 的 PID 置 0,只把 `status` 置 0**。原因是 atexit 执行时驱动还没有销毁 context,显存仍被占用,而 teardown 阶段的 free 还需要通过 PID 找到这个 slot。这类 slot 改为由读取方和 `clear_proc_slot_nolock` 在 `proc_alive()` 确认"整个进程已消失"后再清理。PID=0 的分支仍然保留,用于兼容旧版本 libvgpu 写下的 slot。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -            // Atomically set PID to 0 - this marks the slot as available
  -            atomic_store_explicit(&region->procs[slot].pid, 0, memory_order_release);
  -            // Also set status to 0 (inactive)
  +            LOG_DEBUG("Marking process slot %d as exiting (PID %d)", slot, my_pid);
               atomic_store_explicit(&region->procs[slot].status, 0, memory_order_release);
  ```
  </details>
- **上报路径会跳过已退出进程的 slot 并就地回收;OOM 判定路径的计数不变**。原来的 `get_gpu_memory_usage` 拆成 `sum_gpu_memory_usage(dev, skip_exited, &exited_seen)`。上报路径 `get_current_device_memory_usage`(nvmlDeviceGetMemoryInfo / cuMemGetInfo)传入 `skip_exited=1`,发现死 slot 时调用 `reap_exited_proc_slots`。回收只用 `try_lock`,拿不到锁就放弃;对死 slot 原位清零,只截掉表尾,**不移动存活的 slot**,因为 slot 的属主不加锁就会写入。限额检查仍走 `get_gpu_memory_usage(dev)`,即 `skip_exited=0`,保持保守计数。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -    result = get_gpu_memory_usage(dev);
  +    result = sum_gpu_memory_usage(dev, 1, &exited_seen);
  +    if (exited_seen) {
  +        reap_exited_proc_slots();
  +    }
  ...
  +    return sum_gpu_memory_usage(dev, 0, NULL);
  ...
  +        if (pid != 0 && proc_slot_exited(pid)) {
  +            LOG_INFO("Reap exited slot %d (pid %d)", i, pid);
  +            clear_proc_slot_atomic(slot);
  +            // An owner killed mid-update left the count odd.
  +            atomic_store_explicit(&slot->seqlock, 0, memory_order_release);
  ```
  </details>
- **seqlock 读取不再因"写入方中途被杀"而无限自旋**。原来的逻辑是:seqlock 停在奇数时一直重试。现在每重试 100 次检查一次 slot 的 PID 是否已退出,若已退出则跳过该 slot,并记一条 WARN 日志。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  +                        if (proc_slot_exited(atomic_load_explicit(&slot->pid, memory_order_acquire))) {
  +                            writer_dead = 1;
  +                            break;
  +                        }
  ```
  </details>
- **`proc_alive` 改为优先使用 pidfd,并修正多线程进程被误判为死亡的问题**。原来用 fscanf 读 `/proc/<pid>/stat`,状态为 Z 就判为死亡。新逻辑分两层:先用 `pidfd_open`+`poll`,只有"leader 已退出且没有其他线程"时 pidfd 才可读。内核低于 5.3 或被 seccomp 拒绝时,回退到 `kill(pid,0)` 加 /proc,而且只有 `Z` 状态且 `num_threads<=1` 才算死亡,读不到 /proc 时返回 UNKNOWN 而不是 NONALIVE。另外,为 UBI8 的旧内核头文件补了 `SYS_pidfd_open 434` 的定义。
  <details><summary>代码依据 src/include/process_utils.h</summary>

  ```diff
  -    if ((fp = fopen(filename, "r")) == NULL) {
  -        return PROC_STATE_NONALIVE;
  ...
  -    } else if (state == 'Z' || state == 'X' || state == 'x') {
  -        res = PROC_STATE_NONALIVE;
  +    if (state == 'Z' || state == 'X' || state == 'x') {
  +        return threads <= 1 ? PROC_STATE_NONALIVE : PROC_STATE_ALIVE;
  +    }
  ...
  +    pfd.fd = syscall(SYS_pidfd_open, pid, 0);
  ```
  </details>
- **SIGUSR1/SIGUSR2 的挂起/恢复改为 CAS,并且不会覆盖退出标记**。`sig_swap_stub` 和 `sig_restore_stub` 原来直接 set 状态,现在只做 `1→2` 和 `2→1` 的 CAS 转换。`wait_status_self` 遇到状态 0(已执行 exit_handler)时直接放行,避免进程退出期间收到挂起信号后卡在 `ENSURE_RUNNING`。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
   void sig_swap_stub(int signo){
  -    set_current_gpu_status(2);
  +    swap_current_gpu_status(1, 2);
   }
  ...
  -        return (cur == status) ? 1 : 0;
  +        // 0 is exit_handler's mark; CUDA calls after it must not block.
  +        return (cur == status || cur == 0) ? 1 : 0;
  ```
  </details>

### 后续发展方向 [AI]
- HAMi-core 最近几期持续在加固**共享内存 slot 表的生命周期**:进程 fork、属主死亡、退出后的残留计数。这次把"进程是否还活着"的判断从读 /proc 状态字符升级到 pidfd,说明软隔离方案在长驻进程和多线程推理服务(如 vLLM worker)下的显存记账一直是痛点。证据只覆盖 #433 的 diff。代码注释明确写了这套判断"假设写入方与本进程在同一 PID namespace",跨 namespace 的情况没有看到处理。

## 本期无实质改动(折叠)
- Project-HAMi/volcano-vgpu-device-plugin:327cd25b,无新提交
- Project-HAMi/ascend-device-plugin:9325759b,无新提交
- Project-HAMi/HAMi-WebUI:19a0f955,无新提交

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=7a18e230656ac91db561a0c314d08176b8db61d7 branch=master release=v2.11.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=d8b6c459bc6bed03a02aebfeb62d460f62e6fc53 branch=main release=— scanned=2026-11-26 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=327cd25b4a6e8b1c408db9e522428b5e31216cf2 branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-26 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-26 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-26 -->
