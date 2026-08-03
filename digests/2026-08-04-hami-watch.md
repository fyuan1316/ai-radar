# HAMi diff 雷达 2026-08-04

## 摘要
- **AMD vGPU 从"仅整卡/显存"升级到"核(CU)软切分"**(HAMi #2290):AMD 设备结构新增 `resourceCoreName` 维度、准入校验核占比 1–100%,设备类型标识从固定常量 `"AMDGPU"` 改为真实产品名(如 `AMD Instinct MI300X VF`),`hami.io/amd-devices-to-allocate` 注册/分配注解格式随之变化——AMD 正被拉齐到 NVIDIA/昇腾同款"显存+算力"双维软切模型。
- **昇腾 vNPU 引入"模式随节点"语义**(HAMi #2035 + ascend-device-plugin 联动):无 `huawei.com/vnpu-mode` 注解的 Pod 从"只能走模板路径、在 hami-core-only 节点永久 Pending"改为 mode-agnostic——有效模式由节点 `IsHamiVnpuCore()` 决定,hami-core 节点走软切、模板节点走 `ASCEND_VNPU_SPECS`,打通两类节点混排调度。
- **HAMi-core 把 postInit 串行化从"无名信号量"换成"POSIX 记录锁"**:进程被 SIGKILL 后内核自动释放锁,修掉持锁者猝死导致后续进程永久跳过 host PID 检测的软隔离初始化死锁;同时主仓修正共享内存 `ownerPid` 类型(uint32→uint64)对齐 C ABI,消除 hook 缓存布局"靠巧合对齐"的隐患。

## 当日重要改变
- Project-HAMi/HAMi [新能力] AMD vGPU 增加核(CU)软切分维度 `resourceCoreName` + 准入校验 1–100%,设备类型改用真实产品名。证据 `pkg/device/amd/device.go`、`cmd/scheduler/metrics.go`、`docs/develop/amd-vgpu.md`;PR https://github.com/Project-HAMi/HAMi/pull/2290
- Project-HAMi/HAMi + ascend-device-plugin [架构方向] 昇腾 vNPU "模式随节点"(mode-agnostic Pod),跨仓联动。证据 `pkg/device/ascend/device.go`(HAMi #2035)、`internal/server/allocate.go`(ascend);PR https://github.com/Project-HAMi/HAMi/pull/2035
- Project-HAMi/HAMi-core [新能力] postInit 串行化改用进程死亡安全的 POSIX 记录锁 + 死主恢复回归测试。证据 `src/multiprocess/multiprocess_memory_limit.c`、`test/test_postinit_owner_death.c`;比较 https://github.com/Project-HAMi/HAMi-core/compare/52f33fc7...5496322f

## Project-HAMi/HAMi: 65f59ae4 -> 0345bd87
- 比较 / 最新 Release:65f59ae495ce9b52fd15406c310d14295bb675c8 -> 0345bd87 | ahead=14 | files=42 | Release: v2.9.0
- 比较链接:https://github.com/Project-HAMi/HAMi/compare/65f59ae4...0345bd87

### AI 总结重点(源码 diff 为据)
- **AMD 设备从"整卡/显存"扩到"核(CU)软切分",且身份标识重构**。`AMDDevices` 结构新增 `resourceCoreName` 字段;常量 `AMDDevice`/`AMDCommonWord` 由 `"AMDGPU"` 收窄为 `"AMD"`,新增互斥锁常量 `NodeLockAMD = "hami.io/mutex.lock"`、注册注解 `RegisterAnnos = "hami.io/node-amd-register"`,并把 AMD 纳入 `InRequestDevices`(键 `hami.io/amd-devices-to-allocate`)——这是让 AMD 走 HAMi 通用"待分配→已分配"注解协议的关键;`MutateAdmission` 新增对 `resourceCoreName` 的整数百分比校验(1–100,否则拒绝)。原 `MutateAdmission` 逻辑还把 `if !ok` 误写成"未请求整卡才继续",此次改为 `if ok` 时才校验核占比。

  <details><summary>代码依据 pkg/device/amd/device.go</summary>

  ```diff
   type AMDDevices struct {
   	resourceCountName  string
   	resourceMemoryName string
  +	resourceCoreName   string
   }

   const (
  -	AMDDevice          = "AMDGPU"
  -	AMDCommonWord      = "AMDGPU"
  +	AMDDevice          = "AMD"
  +	AMDCommonWord      = "AMD"
  	AMDDeviceSelection = "amd.com/gpu-index"
  +	AMDInUse           = "amd.com/use-gputype"
  +	AMDNoUse           = "amd.com/nouse-gputype"
  	...
  -	Mi300xMemory       = 192000
  +	NodeLockAMD        = "hami.io/mutex.lock"
  +	RegisterAnnos      = "hami.io/node-amd-register"
   )

   func InitAMDGPUDevice(config AMDConfig) *AMDDevices {
  -	_, ok := device.SupportDevices[AMDDevice]
  +	_, ok := device.InRequestDevices[AMDDevice]
   	if !ok {
  +		device.InRequestDevices[AMDDevice] = "hami.io/amd-devices-to-allocate"
   		device.SupportDevices[AMDDevice] = "hami.io/amd-devices-allocated"
   	}

   func (dev *AMDDevices) MutateAdmission(...) (bool, error) {
   	_, ok := ctr.Resources.Limits[corev1.ResourceName(dev.resourceCountName)]
  -	if !ok {
  +	if ok {
  +		core, coreRequested := ctr.Resources.Limits[corev1.ResourceName(dev.resourceCoreName)]
  +		if coreRequested {
  +			corePercentage, coreIsInteger := core.AsInt64()
  +			if !coreIsInteger || corePercentage < 1 || corePercentage > 100 {
  +				return false, fmt.Errorf("%s must be an integer percentage between 1 and 100", dev.resourceCoreName)
  ```
  </details>

- **AMD 设备类型标识由固定常量改为真实产品名**,直接改变节点注册与分配注解的载荷。`hami.io/node-amd-register` 里 `type` 从 `"AMDGPU"` 变为 `"AMD Instinct MI300X VF"`,`hami.io/amd-devices-{to-allocate,allocated}` 里的 type 字段同步从 `AMDGPU` 常量变为 `<type>` 产品名。对已部署集群,这是 AMD 侧的注解协议不兼容变更(旧格式硬编码 `AMDGPU`)。

  <details><summary>代码依据 docs/develop/amd-vgpu.md</summary>

  ```diff
  -    "type": "AMDGPU",
  +    "type": "AMD Instinct MI300X VF",
  ...
  -hami.io/amd-devices-to-allocate: <UUID>,AMDGPU,<memMiB>,<cuCount>:;
  -hami.io/amd-devices-allocated:   <UUID>,AMDGPU,<memMiB>,<cuCount>:;
  +hami.io/amd-devices-to-allocate: <UUID>,<type>,<memMiB>,<cuCount>:;
  +hami.io/amd-devices-allocated:   <UUID>,<type>,<memMiB>,<cuCount>:;
  -The type field uses the existing `AMDGPU` constant (see `pkg/device/amd/device.go`).
  +The type field uses device product name.
  ```
  </details>

- **调度器 AMD 核指标归一化**:AMD 的物理 CU 计数在 Prometheus 指标里换算成百分比,与 HAMi 通用 core-ratio 口径一致。新增 `normalizeAMDCoreMetrics(deviceType, total, allocated)`——凡设备类型前缀为 `AMD` 且 total>0,limit 恒为 100、allocated 按 `ceil(allocated/total*100)` 折算;其它设备保持原值。`nodevGPUCoreLimitDesc`/`nodeGPUCoreAllocatedDesc` 从直接吐 `Totalcore`/`Usedcores` 改为吐归一化值。

  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  +const normalizedCoreLimit = 100
  +func normalizeAMDCoreMetrics(deviceType string, total, allocated int32) (float64, float64) {
  +	if !strings.HasPrefix(strings.ToUpper(deviceType), "AMD") || total <= 0 {
  +		return float64(total), float64(allocated)
  +	}
  +	return normalizedCoreLimit, math.Ceil(float64(allocated) / float64(total) * normalizedCoreLimit)
  +}
   ...
  +	coreLimit, coreAllocated := normalizeAMDCoreMetrics(devs.Device.Type, devs.Device.Totalcore, devs.Device.Usedcores)
  -		float64(devs.Device.Totalcore),
  +		coreLimit,
  -		float64(devs.Device.Usedcores),
  +		coreAllocated,
  ```
  </details>

- **节点锁(nodelock)向"锁属主感知 + 幂等"演进**,支撑并发调度与失败回收(#2197/#2255/#2293)。`SetNodeLock` 重试谓词从"任何错误都重试"改为 `!IsNodeLockContention(err)`(争抢即失败不空转);且当节点已被本 Pod(`lockOwner` 后缀匹配)持有时直接返回成功,即幂等重入,不再误报争抢。`ReleaseNodeLock` 在 patch 前重新校验当前锁属主,只有确实是本 Pod 的锁才清除,并用 `released` 标志确保日志只在真正释放时打印——避免并发下误删他人锁 / 虚假"已释放"日志。

  <details><summary>代码依据 pkg/util/nodelock/nodelock.go</summary>

  ```diff
   func SetNodeLock(...) error {
  +	lockOwner := NodeLockSep + GeneratePodNamespaceName(pods, NodeLockSep)
   	err = retry.OnError(DefaultStrategy, func(err error) bool {
  -		// Retry on any error
  -		return true
  +		return !IsNodeLockContention(err)
   	}, func() error {
   		...
  +		lockStr, ok := node.Annotations[NodeLockKey]
  +		if ok && strings.Contains(lockStr, NodeLockSep) && strings.HasSuffix(lockStr, lockOwner) {
  +			return nil   // 本 Pod 已持锁,幂等成功
  +		}
  +		if ok {
  +			return fmt.Errorf("node %s is locked: %w", nodeName, ErrNodeLockContention)
  +		}
   ...
   func ReleaseNodeLock(...) error {
  +	released := false
   		...
  +		currentLock, ok := node.Annotations[NodeLockKey]
  +		if !ok { return nil }
  +		if skipNodeLockOwnerCheck || !strings.Contains(currentLock, NodeLockSep) {
  +			if currentLock != lockStr { return nil }
  +		} else if !strings.HasSuffix(currentLock, lockOwner) {
  +			return nil   // 锁已易主,不误删
  +		}
   		...
  +		released = true
  -	klog.InfoS("Node lock released", ...)
  +	if released { klog.InfoS("Node lock released", ...) }
  ```
  </details>

- **多设备类型混排时 Fit 记账修正(#2238)**:NVIDIA 与昇腾的 `Fit` 里,`tmpDevs` 已是按类型分桶的 `map[string]ContainerDevices`,但 `NumaNotFit` / `AllocatedCardsInsufficientRequest` 的计数仍用整表长度 `len(tmpDevs)`(=设备类型数),改为按当前类型 `len(tmpDevs[k.Type])`。前:一个 Pod 同时请求多类设备时,某类分配不足的失败原因计数被按"类型数"而非"该类型实际候选数"记账,拒因统计失真;后:每类各记各的。

  <details><summary>代码依据 pkg/device/nvidia/device.go(昇腾同型)</summary>

  ```diff
   		if numa && prevnuma != dev.Numa {
   			if k.Nums != originReq {
  -				reason[common.NumaNotFit] += len(tmpDevs)
  +				reason[common.NumaNotFit] += len(tmpDevs[k.Type])
   ...
  -	if len(tmpDevs) > 0 {
  -		reason[common.AllocatedCardsInsufficientRequest] = len(tmpDevs)
  +	if len(tmpDevs[k.Type]) > 0 {
  +		reason[common.AllocatedCardsInsufficientRequest] = len(tmpDevs[k.Type])
  ```
  </details>

- **昇腾 Fit 删除遗留 vNPU 内存闸门 + 回填运行时用量**,配合 mode-agnostic 落地(#2035)。原 `Fit` 里有一段"若 node 预留给 hami-core 但 Pod 是 legacy vNPU(memreq<整卡显存)则过滤"的硬闸门,连同 `totalMemPerCard` 计算一并删除——不再因 Pod 未声明模式就把它挡在 hami-core 节点外。`PatchAnnotations` 补写 `info.Memory`/`info.Core`,让分配结果带上实际显存/核用量。

  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
   				_, temp := dev.trimMemory(int64(val.Usedmem))
   				info.Temp = temp
  +				info.Memory = int64(val.Usedmem)
  +				info.Core = val.Usedcores
   ...
  -	var totalMemPerCard int32 = 0
  -	if len(devices) > 0 {
  -		totalMemPerCard = devices[0].Totalmem
  -	}
   	if isHAMiCore && !nodeSupportHamiCore {
   		reason[common.ModeNotFit]++
   		return false, nil, common.GenReason(reason, len(devices))
   	}
  -	if request.Memreq > 0 && request.Memreq < totalMemPerCard && request.Nums > 0 {
  -		if nodeSupportHamiCore && !isHAMiCore {
  -			reason[common.ModeNotFit]++
  -			return false, nil, common.GenReason(reason, len(devices))
  -		}
  -	}
  ```
  </details>

- **HAMi-core 共享内存布局对齐 C ABI(#2194)**:vGPUmonitor 侧 `sharedRegionT.ownerPid` 从 `uint32` 改为 `uint64`,匹配 libvgpu 的 `_Atomic size_t owner_pid`(64 位 Linux 上 8 字节)。原来后续字段仅"靠 Go 8 字节对齐填充恰好吸收了缺失的 4 字节"而巧合对齐,现真正对齐;新增 `MinSize()` 返回 `CastSpec` 内存安全所需的最小字节数,给 loadCache use-after-unmap 修复兜底。

  <details><summary>代码依据 pkg/monitor/nvidia/v1/spec.go</summary>

  ```diff
  -	ownerPid        uint32
  -	sem             semT
  +	// ownerPid mirrors libvgpu's `_Atomic size_t owner_pid`, 8 bytes on 64-bit Linux ...
  +	ownerPid uint64
  +	sem      semT
   ...
  +func MinSize() int {
  +	return int(unsafe.Sizeof(sharedRegionT{}))
  +}
  ```
  </details>

### 后续发展方向 [AI]
- **AMD 正被抬到与 NVIDIA/昇腾平级的一等软切后端**:证据覆盖 device.go(核维度+注解协议+互斥锁)、metrics.go(核指标归一化)、amd-vgpu.md(产品名标识 + 多卡验证 TODO),但 doc 明说"MI300X VF 测试节点只有 1 张卡,多卡 `HSA_CU_MASK` 与可见设备重排序的映射尚未验证"——即 AMD 核切分当前仅单卡可信,多卡共享 CU 掩码是下一步硬骨头。未见 AMD 走 DRA 原生路径,仍是 hami-core 时分/掩码软切。
- **昇腾"模式随节点"是把软切(hami-core)与模板(vNPU template)两类节点做混合调度的关键一步**:证据落在 HAMi Fit 删闸门 + ascend allocate.go 的 `effectiveHamiCore` 判定,方向是让用户不写 `vnpu-mode` 注解也能被正确路由,降低两生态交汇处的使用门槛。证据只覆盖"注解缺失→随节点"这一条判定,未见跨节点模式冲突(如同一 Pod 多容器落在异构模式节点)的处理,不宜外推为完整的混合调度器。
- **软隔离内核在补进程生命周期健壮性**:HAMi-core 记录锁 + 主仓 ownerPid 布局对齐,共同指向"持锁进程猝死 / 缓存布局错位导致软隔离初始化失效"这类边角。证据是 postInit 单点 + 一个死主回归测试,反映能力已进入"抗崩溃/抗重放"打磨期,非新增隔离维度。

## Project-HAMi/HAMi-core: 52f33fc7 -> 5496322f
- 比较 / 最新 Release:52f33fc7fa1fbb3f08148ab076d0e7447bec7f2a -> 5496322f | ahead=7 | files=6 | Release: —
- 比较链接:https://github.com/Project-HAMi/HAMi-core/compare/52f33fc7...5496322f

### AI 总结重点(源码 diff 为据)
- **postInit 串行化从无名信号量改为 POSIX 记录锁(fcntl),解决持锁者猝死不可恢复**。注释点破根因:`sem_postinit` 保留在 `shared_region_t` 里只为不破坏布局,但无名信号量在持有者死亡后无法恢复;改用内核在进程退出(含 SIGKILL)时自动释放的 record lock。锁字节固定在 `POSITINIT_FILE_LOCK_OFFSET = 0x40000000`,`_Static_assert` 保证它落在 `shared_region_t` 之外,未来布局变更仍指向同一字节。新增带抖动的重试退避(`postinit_file_lock_backoff`,LCG 生成 jitter)与线程本地守卫 `postinit_lock_held` / `atomic_flag postinit_local_lock`(POSIX 记录锁按进程而非线程,需进程内自旋守卫)。

  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -// Longer timeout for postinit since set_task_pid() ...
  -#ifndef SEM_WAIT_TIME_POSTINIT
  -#define SEM_WAIT_TIME_POSTINIT 30
  -#endif
  +#define POSTINIT_FILE_LOCK_OFFSET ((off_t)UINT64_C(0x40000000))
  +#define POSTINIT_FILE_LOCK_INITIAL_RETRY_US 10000U
  +#define POSTINIT_FILE_LOCK_MAX_RETRY_US 1000000U
  +_Static_assert(POSTINIT_FILE_LOCK_OFFSET > (off_t)sizeof(shared_region_t),
  +               "postinit file lock must remain outside the shared region");
  +static atomic_flag postinit_local_lock = ATOMIC_FLAG_INIT;
  +static _Thread_local int postinit_lock_held;
  +static int postinit_file_lock(short lock_type) {
  +    struct flock lock = { .l_type = lock_type, .l_whence = SEEK_SET,
  +        .l_start = POSTINIT_FILE_LOCK_OFFSET, .l_len = 1 };
  ```
  </details>

- **libvgpu.c 里 postInit 失败语义变更**:锁失败原因从"超时→跳过 host PID 检测"改述为"postinit lock failed",NVML 返回码从 `NVML_ERROR_TIMEOUT` 改为 `NVML_ERROR_UNKNOWN`——因为记录锁语义下失败不再是"超时",而是不确定的锁错误。`lock_postinit()` 注释同步由 "Returns 1 on success, 0 on timeout" 改为 "0 on lock error"。

  <details><summary>代码依据 src/libvgpu.c + multiprocess_memory_limit.h</summary>

  ```diff
  -    // Timeout - another process likely crashed holding the lock
  -    LOG_WARN("Skipped host PID detection due to lock timeout");
  -    res = NVML_ERROR_TIMEOUT;
  +    LOG_WARN("Skipped host PID detection because the postinit lock failed");
  +    res = NVML_ERROR_UNKNOWN;
   ...
  -    sem_t sem_postinit;  // For serializing postInit() host PID detection
  +    sem_t sem_postinit;  // Retained for shared-region layout compatibility
  -int lock_postinit();  // Returns 1 on success, 0 on timeout
  +int lock_postinit();  // Returns 1 on success, 0 on lock error
  ```
  </details>

- **新增无 GPU 依赖的死主回归测试**:`test/test_postinit_owner_death.c`(406 行)用多进程杀掉初始持锁者与首个等待者,断言第二等待者在任一属主存活期间保持阻塞、在每次 SIGKILL 后迅速获锁;并含线程测试验证进程本地守卫。CMake 为该测试单独用生产 `multiprocess_memory_limit.c` 编链(`--gc-sections` 丢弃 GPU 相关符号,只链 `-lrt -lpthread`,不依赖 CUDA/NVML),纳入 `enable_testing()` + 20s 超时的 ctest。头文件另新增 `CONTAINER_VGPU_MOUNT`/`POD_UID`/`CONTAINER_NAME` 等 env 常量定义(本期 hunk 未见其使用点,hunk 截断)。

  <details><summary>代码依据 test/CMakeLists.txt</summary>

  ```diff
  +    if (TEST_TARGET_NAME STREQUAL "test_postinit_owner_death")
  +        add_executable(${TEST_TARGET_NAME} ${TEST_SCRIPT}
  +            .../src/multiprocess/multiprocess_memory_limit.c .../src/log_utils.c)
  +        set_target_properties(... LINK_FLAGS "-Wl,--no-export-dynamic,--gc-sections")
  +    elseif (TEST_SCRIPT MATCHES ".*cu")
  +add_test(NAME postinit_owner_death COMMAND test_postinit_owner_death)
  +set_tests_properties(postinit_owner_death PROPERTIES TIMEOUT 20)
  ```
  </details>

### 后续发展方向 [AI]
- **软隔离内核在补"多进程共享一份 cudevshr 缓存时的崩溃安全"**:证据是把唯一的进程间同步原语(postInit 锁)换成内核托管的记录锁,并明确"共享一份 cache 的进程必须都走此协议,仅用信号量的旧二进制不参与"——指向 HAMi-core 与主仓 vGPUmonitor 需版本对齐,否则新旧混跑锁协议不兼容。证据只覆盖 postInit 一处锁;`lock_shrreg`/`unlock_shrreg` 等其它共享区锁本期未动,不宜断言全面转向 record lock。
- 头文件新增 `POD_UID`/`CONTAINER_NAME`/`CONTAINER_VGPU_MOUNT` 常量暗示后续可能把 Pod/容器身份纳入共享区缓存路径或隔离粒度,但本期无使用点(hunk 截断),仅作方向标记,不下结论。

## Project-HAMi/ascend-device-plugin: ffadaa96 -> 5d5bad2d
- 比较 / 最新 Release:ffadaa96270de157fbe461be321f7b17c79a16de -> 5d5bad2d | ahead=4 | files=3 | Release: —
- 比较链接:https://github.com/Project-HAMi/ascend-device-plugin/compare/ffadaa96...5d5bad2d

### AI 总结重点(源码 diff 为据)
- **无 vnpu-mode 注解的 Pod 改为"有效模式随节点"**,与 HAMi 主仓 #2035 联动。`buildContainerAllocateResponse` 原来只有当注解显式 `== VNPUModeHamiCore` 才走软切分挂载(libvnpu / hami-vnpu-core mounts + preload),否则一律模板路径。现引入 `effectiveHamiCore = 注解==hami-core || (注解为空 && ps.mgr.IsHamiVnpuCore())`:注解缺失时由节点能力决定——hami-core 节点走软切,模板节点走 `ASCEND_VNPU_SPECS`。这修掉 doc 记载的"annotation-less Pod 在 hami-core-only 集群永久 Pending"。

  <details><summary>代码依据 internal/server/allocate.go</summary>

  ```diff
   	vnpuMode := pod.Annotations[VNPUModeAnnotation]
  -	klog.V(4).Infof("Pod %s vnpu mode: %s", pod.Name, vnpuMode)
  -	if vnpuMode == VNPUModeHamiCore {
  +	effectiveHamiCore := vnpuMode == VNPUModeHamiCore || (vnpuMode == "" && ps.mgr.IsHamiVnpuCore())
  +	klog.V(4).Infof("Pod %s vnpu mode: %q, effectiveHamiCore: %v", pod.Name, vnpuMode, effectiveHamiCore)
  +	if effectiveHamiCore {
  		// 1. Handle volume mount injection ...
  ```
  </details>

- **文档把模式选择规则改写为显式两分支**(mode-follows-node),并新增两个单测锁定行为:`NoAnnotation_NodeHamiCore_FollowsNode`(节点 hami-core → 期望注入 hami-vnpu-core 挂载 + `NPU_MEM_QUOTA`/`NPU_PRIORITY`/`NPU_GLOBAL_SHM_PATH` 环境)与 `NoAnnotation_NodeTemplate_FollowsNode`(节点模板 → 只吐 `ASCEND_VNPU_SPECS=vir08`)。测试用 `FakeManager.IsHamiVnpuCoreFunc` 注入节点能力,直接验证"同一无注解 Pod 在两类节点上得到不同响应"。

  <details><summary>代码依据 internal/server/util_test.go</summary>

  ```diff
  +		{ name: "NoAnnotation_NodeHamiCore_FollowsNode",
  +			mgr: &FakeManager{ IsHamiVnpuCoreFunc: func() bool { return true }, ... },
  +			pod: &v1.Pod{ObjectMeta: metav1.ObjectMeta{Annotations: map[string]string{}}},
  +			want: envs{ "NPU_GLOBAL_SHM_PATH": "/hami-shared-region/3_global_registry", ... },
  +			mounts: { "/usr/local/hami-vnpu-core/ld.so.preload" -> "/etc/ld.so.preload", ... } },
  +		{ name: "NoAnnotation_NodeTemplate_FollowsNode",
  +			mgr: &FakeManager{ IsHamiVnpuCoreFunc: func() bool { return false }, ... },
  +			want: envs{ "ASCEND_VNPU_SPECS": "vir08" } },
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾软切分接入路径在"零配置可用"上打磨**:证据是 allocate.go 把模式判定的兜底从"显式注解"下沉到"节点能力探测(IsHamiVnpuCore)",方向是让用户不感知 hami-core vs 模板差异、由平台按节点路由。证据只覆盖单容器 allocate 响应构造,未见调度器侧(HAMi 主仓)如何保证无注解 Pod 被同时投递到两类节点后打分一致——这条链的调度端仅由 HAMi #2035 删闸门体现,端到端一致性未在本期 diff 内闭环。

## 本期无实质改动(折叠)
<details><summary>2 仓无实质改动</summary>

- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HAMi × Volcano 集成路径本期静默)
- Project-HAMi/HAMi-WebUI:无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=0345bd878f8966e8c22b151608a84c92634c0c20 branch=master release=v2.9.0 scanned=2026-08-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-04 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-08-04 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=5d5bad2d544a9725e064d68a4de28b6271628adb branch=main release=— scanned=2026-08-04 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-04 -->
