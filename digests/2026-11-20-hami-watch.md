# HAMi diff 雷达 2026-11-20

## 摘要
- 当日没有命中严格信号：没有 API/CRD、proposal、新顶层 package、版本跨档，也没有弃用或移除。HAMi 仍是 v2.11.0,WebUI 仍是 v1.3.0。
- HAMi-core 合入 driver admission 客户端(PR #406)。开启 `LIBVGPU_HOSTPID_BROKER=1` 且 `LIBVGPU_DRIVER_ADMISSION=1` 后,`cuInit`、primary context 的 retain、release、reset 四个 hook 会先向 host PID broker 申请一个 permit,拿到后才调用真实驱动。permit 就是一条 Unix socket 连接，关闭即归还。拿不到 permit 时照常调用驱动，不会失败。作用是削平同一节点大批 Pod 同时启动时的驱动调用峰值。
- HAMi 调度器新增 allocate 超时计数(#3474)。Pod 已绑定节点但卡在 `allocating` 状态，超过 node lock 超时仍未完成的，会计入 `hami_scheduler_allocation_failures_total{phase="allocate",failure_reason="timeout"}`。每次 bind 只计一次，超时之后才到的成功或失败结果不再重复计数。

## 当日重要改变
- 无。严格信号全部未命中。HAMi-core 的 driver admission 是在已有的 `hostpid_broker.c` 上扩展协议命令，没有新增独立 package 或目录，因此不计 [新能力],放在正文展开。

## Project-HAMi/HAMi: 297dfaed -> 7482d491
- 比较: 297dfaedd9a00291b4ad3f40aa367eb9581aa3a4 -> 7482d491 | ahead=3 | files=8 | Release: v2.11.0(未变)
- 比较链接: https://github.com/Project-HAMi/HAMi/compare/297dfaedd9a00291b4ad3f40aa367eb9581aa3a4...7482d49100da2a964f45eed30a1ec3887febd688
- 3 个提交里有 2 个是依赖 bump:controller-runtime(#3486)和 libvgpu 子模块 `1fc9ea5` → `9bc18ca`(#3487)。`9bc18ca` 是昨日 HAMi-core 的 HEAD,还**不含**今天 HAMi-core 合入的 admission 客户端。
- 说明:helper 节选里 `pkg/scheduler/scheduler.go` 的 hunk 被截断，下面 `observeAllocateTimeouts` 和 `WatchAllocateTimeouts` 的 hunk 是用 compare API 补拉的。

### AI 总结重点(源码 diff 为据)
- **新增 failure reason `timeout`**(`pkg/metrics/scheduler.go`)。`SchedulerFailureReason` 枚举在 internal、conflict、device_plugin 之后加了 `FailureReasonTimeout = "timeout"`,复用已有的 `hami_scheduler_allocation_failures_total` 计数器，没有新增指标名。提交: https://github.com/Project-HAMi/HAMi/pull/3474
  <details><summary>代码依据 pkg/metrics/scheduler.go</summary>

  ```diff
   	FailureReasonDevicePlugin    SchedulerFailureReason = "device_plugin"
  +	FailureReasonTimeout         SchedulerFailureReason = "timeout"
   )
  ```
  </details>
- **leader 每 15 秒扫一次卡在 allocate 阶段的 Pod**。
  - `cmd/scheduler/main.go` 启动时新开 goroutine `sher.WatchAllocateTimeouts()`,用 ticker 按 `allocateTimeoutInterval = 15s` 调用 `observeAllocateTimeouts(now)`。scheduler 未 started 时跳过，收到 `stopCh` 时退出。
  - `observeAllocateTimeouts` 只在 leader 上执行。它遍历 podLister 中所有 Pod,用 `waitingForAllocate` 筛出四个条件都满足的 Pod:phase 为 Pending,`NodeName` 非空,`StartTime` 为空，并且 bind-phase 注解为 `allocating`。
  - 对筛出的 Pod,用 `allocationDuration`(按 bind-time 注解计算)判断，严格大于 `nodelockutil.NodeLockTimeout` 才计 `ObserveAllocationFailure("allocate", <deviceType>, timeout)`。恰好等于超时时间的不计，单测 "at the timeout" 用例覆盖了这一点。
  <details><summary>代码依据 pkg/scheduler/scheduler.go(补拉)</summary>

  ```diff
  +func waitingForAllocate(pod *corev1.Pod) bool {
  +	return pod.Status.Phase == corev1.PodPending &&
  +		pod.Spec.NodeName != "" &&
  +		pod.Status.StartTime == nil &&
  +		pod.Annotations[util.DeviceBindPhase] == util.DeviceBindAllocating
  +}
  ...
  +func (s *Scheduler) observeAllocateTimeouts(now time.Time) {
  +	if !s.leaderManager.IsLeader() {
  +		return
  +	}
  +	pods, err := s.podLister.List(labels.NewSelector())
  ...
  +		d, ok := allocationDuration(pod, now)
  +		if !ok || d <= nodelockutil.NodeLockTimeout.Seconds() {
  +			continue
  +		}
  +		if s.markAllocateTimeout(pod) {
  +			s.GetAllocationMetrics().ObserveAllocationFailure("allocate", s.podAllocationType(pod), metrics.FailureReasonTimeout)
  +		}
  ...
  +var allocateTimeoutInterval = 15 * time.Second
  ```
  </details>
- **每次 bind 只计一次，超时之后才到的结果不再计入成功或 device_plugin 失败**。
  - `Scheduler` 新增 `timedOutPods map[UID]string`,记录已经计过超时的那次 bind 的 bind-time,由 `timeoutLock` 保护。
  - `markAllocateTimeout` 先看同一个 bind-time 是否已记过，再从 lister 重新取一次 Pod,复核 UID、仍处于等待状态、bind-time 未变。三项都满足才记录。
  - `observeAllocateResult` 有三处改动:
    - 新旧 Pod 的 UID 不同(同名重建)时，清掉旧 Pod 的超时记录后直接返回。
    - 新 Pod 的 bind-phase 仍是 `allocating` 时也直接返回。原来只判断旧 Pod 是否为 `allocating`。
    - 如果 `clearAllocateTimeout` 返回 true,说明这次 bind 已经计过超时，只打 Info 日志，不再计成功或失败。
  - `onDelPod` 也会调用 `clearAllocateTimeout`,防止 map 泄漏。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
   func (s *Scheduler) observeAllocateResult(oldPod, newPod *corev1.Pod) {
  -	if oldPod.Annotations[util.DeviceBindPhase] != util.DeviceBindAllocating {
  +	if oldPod.UID != newPod.UID {
  +		s.clearAllocateTimeout(oldPod)
  +		return
  +	}
  +	if oldPod.Annotations[util.DeviceBindPhase] != util.DeviceBindAllocating ||
  +		newPod.Annotations[util.DeviceBindPhase] == util.DeviceBindAllocating {
   		return
   	}
  ...
  +	if s.clearAllocateTimeout(newPod) {
  +		klog.InfoS("Allocate result after timeout was not counted", ...)
  +		return
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 调度器的分配观测正在补全 allocate 阶段：原来只能看到 device plugin 明确返回的成功或失败，现在 device plugin 一直不回写的「静默卡住」也有了独立的 failure_reason。超时阈值直接复用 `NodeLockTimeout`,说明它被当作 node lock 被长时间占用的告警信号，可以与 `lock` reason 一起看。证据只覆盖 scheduler 和 metrics 两个包，没有看到超时后自动释放 node lock 或重调度的处置逻辑。目前只计数，不做处置。
- libvgpu 子模块落后 HAMi-core 主线一天，主仓镜像要等下一次 bump 才会带上 driver admission 客户端。broker 服务端已经在 HAMi `hostpid/protocol.go` 中定义了命令 2、3、4 和 `statusUnavailable`,来自 HAMi#3373,本期区间外，只核对了常量。

## Project-HAMi/HAMi-core: 9bc18ca8 -> 6ef40c6e
- 比较: 9bc18ca8f31e7f4ad92b53deb0d3fa58e5c6009f -> 6ef40c6e | ahead=20 | files=11 | Release: —
- 比较链接: https://github.com/Project-HAMi/HAMi-core/compare/9bc18ca8f31e7f4ad92b53deb0d3fa58e5c6009f...6ef40c6e481b22057f6ac8fe0fbe54344ff34a6e
- 主体是 PR #406「hold a broker permit around driver init and primary context calls」: https://github.com/Project-HAMi/HAMi-core/pull/406 。另有 #413,仅改测试：在运行时 dlsym 查找 `vgpu_hostpid_found`: https://github.com/Project-HAMi/HAMi-core/pull/413
- 说明:`hostpid_broker.c` 和 `context.c` 的 hunk 在 helper 节选中被截断，下面相应部分是用 compare API 补拉的。

### AI 总结重点(源码 diff 为据)
- **broker 协议 v1 新增三个 admission 命令，协议版本号不变**(`src/hostpid_broker.c`)。
  - 原有的 `GET_PID=1` 之外，新增 `ACQUIRE_DRIVER_INIT=2`、`ACQUIRE_DRIVER_RETAIN=3`、`ACQUIRE_DRIVER_RELEASE=4`,以及状态码 `HOSTPID_STATUS_UNAVAILABLE=2`。`HOSTPID_PROTOCOL_VERSION` 仍是 1,请求 8 字节、响应 12 字节的帧格式不变。
  - 新增排队等待上限 `HOSTPID_ADMISSION_WAIT_MS`,默认 600000,即 10 分钟。注释说明这个上限是为了兜住不应答的 broker,不是为了限制队列长度。
  <details><summary>代码依据 src/hostpid_broker.c</summary>

  ```diff
   #define HOSTPID_COMMAND_GET_PID 1
  +#define HOSTPID_COMMAND_ACQUIRE_DRIVER_INIT 2
  +#define HOSTPID_COMMAND_ACQUIRE_DRIVER_RETAIN 3
  +#define HOSTPID_COMMAND_ACQUIRE_DRIVER_RELEASE 4
   #define HOSTPID_STATUS_OK 0
  +#define HOSTPID_STATUS_UNAVAILABLE 2
  ...
  +#ifndef HOSTPID_ADMISSION_WAIT_MS
  +#define HOSTPID_ADMISSION_WAIT_MS 600000
  +#endif
  ```
  </details>
- **permit 等于一个打开的 socket fd,关闭即归还**。
  - 新增 `acquire_driver_admission` 函数。connect 和写请求沿用 500ms 截止时间，超时后把 errno 从 ETIMEDOUT 改写为 EAGAIN,含义是 broker 忙。读响应则改用 `HOSTPID_ADMISSION_WAIT_MS` 作截止时间，只有这一步超时才报 ETIMEDOUT,含义是 broker 收下了请求但一直没有应答。
  - 响应 status 为 UNAVAILABLE 时映射为 EAGAIN。成功时 `*lease_fd = fd`,由调用方持有。
  - 所有已打开的 lease 都挂在全局链表 `admission_leases` 上，受 `admission_leases_lock` 保护。`pthread_atfork` 的 prepare 和 parent 回调负责加锁、解锁,child 回调关闭子进程继承的那份 fd 拷贝。这样父进程释放 permit 时,broker 能真正收到 EOF。
  - `_trusted` 变体先调用 `hostpid_broker_validate_trust`,再用 `verify_peer_uid(fd, 0)` 校验对端是 root。
  <details><summary>代码依据 src/hostpid_broker.c(补拉)</summary>

  ```diff
  +    if (connect_before_deadline(fd, &address, address_length, &deadline) != 0 ||
  +        (verify_peer && verify_peer_uid(fd, 0) != 0) ||
  +        write_before_deadline(fd, request, sizeof(request), &deadline) != 0) {
  +        // A full accept queue or a slow write means a busy broker. Only a
  +        // broker that never answers the request reports ETIMEDOUT.
  +        if (errno == ETIMEDOUT) {
  +            errno = EAGAIN;
  +        }
  +        result = -1;
  +    } else if (deadline_after_ms(&wait_deadline,
  +                                 HOSTPID_ADMISSION_WAIT_MS) != 0 ||
  +               read_before_deadline(fd, response, sizeof(response),
  +                                    &wait_deadline) != 0) {
  ...
  +        errno = status == HOSTPID_STATUS_UNAVAILABLE ? EAGAIN : EPROTO;
  ...
  +    *lease_fd = fd;
  ```
  </details>
- **双开关门控，按 best effort 降级**(`src/libvgpu.c`)。
  - `driver_admission_enabled()` 要求 `LIBVGPU_HOSTPID_BROKER` 和 `LIBVGPU_DRIVER_ADMISSION` 都等于 `"1"`。
  - `driver_admission_acquire` 拿不到 permit 时返回 -1,调用方照常调用驱动，只在第一次 miss 时打一条 WARN。
  - 遇到 ETIMEDOUT 后置位 `admission_timed_out`,本进程此后不再申请 permit;fork 出的子进程在 `childReinitPostInit` 中复位。
  - 线程局部标志 `in_hostpid_init` 的定义被上移。宿主 PID 探测期间不申请 permit,避免持有节点级 fallback 锁时还要排队等 broker。
  <details><summary>代码依据 src/libvgpu.c</summary>

  ```diff
  +int driver_admission_enabled(void) {
  +    return hostpid_broker_enabled(getenv("LIBVGPU_HOSTPID_BROKER")) &&
  +           hostpid_broker_enabled(getenv("LIBVGPU_DRIVER_ADMISSION"));
  +}
  ...
  +    if (!driver_admission_enabled() || in_hostpid_init ||
  +        __atomic_load_n(&admission_timed_out, __ATOMIC_RELAXED)) {
  +        return -1;
  +    }
  +    // Admission only smooths bursts, so a missing permit never fails the call.
  ...
  +        if (saved_errno == ETIMEDOUT) {
  +            __atomic_store_n(&admission_timed_out, 1, __ATOMIC_RELAXED);
  +        }
  ```
  </details>
- **四个 hook 只在会真正触发驱动重操作时才申请 permit,并且先拿 permit 再加锁**(`src/libvgpu.c`、`src/cuda/context.c`)。
  - `cuInit`:成功一次后置 `cuinit_succeeded`,之后的调用不再申请。
  - `cuDevicePrimaryCtxRetain`:仅当 `cuDevicePrimaryCtxGetState` 显示 context 未激活时才申请 RETAIN permit。
  - `cuDevicePrimaryCtxRelease_v2`:新增按设备的引用计数 `primary_context_retains[dev]`,仅当计数 ≤1、即这是最后一次 release 时才申请 RELEASE permit。
  - `cuDevicePrimaryCtxReset_v2`:仅当 context 处于激活状态时申请 RELEASE permit。`cudaDeviceReset` 走的是这个 hook,不经过 release。
  - 四处都是先申请 permit,再调用 `lock_primary_context` 拿 legacy 锁和设备锁，注释说明这是为了避免持锁排队。真实驱动调用返回后立即 `driver_admission_release`。
  - 原来手写的 unlock 改为 `pthread_cleanup_push/pop`,线程在驱动调用中被 cancel 时也能归还 permit 并释放锁。新测试 `test_driver_admission_cancel.c`(+496)专门覆盖这一场景。
  <details><summary>代码依据 src/cuda/context.c(补拉)</summary>

  ```diff
  -    pthread_mutex_t *legacy = legacy_context_lock();
  -    pthread_mutex_t *guard = primary_context_lock(dev);
  +    if (driver_admission_enabled() && !primary_context_active(dev)) {
  +        lease_fd = driver_admission_acquire(HOSTPID_DRIVER_ADMISSION_RETAIN);
  +    }
  +    pthread_cleanup_push(driver_admission_cleanup, &lease_fd);
  +    lock_primary_context(dev, &locks);
  +    pthread_cleanup_push(unlock_primary_context, &locks);
  ...
  -    CUresult res = CUDA_OVERRIDE_CALL(cuda_library_entry,cuDevicePrimaryCtxRetain,pctx,dev);
  +    res = CUDA_OVERRIDE_CALL(cuda_library_entry,cuDevicePrimaryCtxRetain,pctx,dev);
  +    driver_admission_release(&lease_fd);
  ...
   CUresult cuDevicePrimaryCtxRelease_v2( CUdevice dev ){
  +    if (primary_context_release_is_final(dev)) {
  +        lease_fd = driver_admission_acquire(HOSTPID_DRIVER_ADMISSION_RELEASE);
  +    }
  ...
   CUresult cuDevicePrimaryCtxReset_v2(CUdevice dev) {
  +    if (driver_admission_enabled() && primary_context_active(dev)) {
  +        lease_fd = driver_admission_acquire(HOSTPID_DRIVER_ADMISSION_RELEASE);
  +    }
  ```
  </details>
  <details><summary>代码依据 src/libvgpu.c(cuInit)</summary>

  ```diff
  -    CUresult res = CUDA_OVERRIDE_CALL(cuda_library_entry,cuInit,Flags);
  +    int lease_fd = -1;
  +    if (!__atomic_load_n(&cuinit_succeeded, __ATOMIC_ACQUIRE)) {
  +        lease_fd = driver_admission_acquire(HOSTPID_DRIVER_ADMISSION_INIT);
  +    }
  +    CUresult res;
  +    pthread_cleanup_push(driver_admission_cleanup, &lease_fd);
  +    res = CUDA_OVERRIDE_CALL(cuda_library_entry,cuInit,Flags);
  +    pthread_cleanup_pop(1);
  ...
  +    __atomic_store_n(&cuinit_succeeded, 1, __ATOMIC_RELEASE);
  ```
  </details>

### 后续发展方向 [AI]
- host PID broker 的定位在扩大：原来只是给显存记账提供宿主 PID,现在开始做节点级的驱动调用准入控制。HAMi-core 不再只在进程内切显存和算力，开始与节点上的 root 守护进程(device plugin 中的 broker)协同做跨容器的并发治理。这条路线属于 HAMi 软切分(hook),与 DRA 原生路径无关。证据只覆盖客户端 hunk,未逐行读 broker 服务端的 permit 上限和排队实现(HAMi#3373)。
- 设计上明确是削峰而不是隔离：拿不到 permit 就放行，超时一次后整个进程都不再申请，引用计数在并发下允许误判(注释写明 "Admission is best effort")。可以推断它要解决的是大批 Pod 同时冷启动时 `cuInit` 和 context 创建的驱动锁争用，不提供任何配额保证。默认关闭，需要两个环境变量同时开启。PR 描述提到 Helm 侧由 `driverAdmissionPermits` 控制注入，本期 diff 中未见相应 chart 改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos</summary>

- `Project-HAMi/volcano-vgpu-device-plugin`:无新提交(仍 e5b0164c / volcano-vgpu-device-plugin-1.13.0)
- `Project-HAMi/ascend-device-plugin`:无新提交(仍 9325759b / ascend-device-plugin-0.2.2)
- `Project-HAMi/HAMi-WebUI`:无新提交(仍 19a0f955 / v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=7482d49100da2a964f45eed30a1ec3887febd688 branch=master release=v2.11.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6ef40c6e481b22057f6ac8fe0fbe54344ff34a6e branch=main release=— scanned=2026-11-20 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=e5b0164caef64359ea10a7430a15008fa6be2ecb branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-20 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=19a0f955a652ba7f7e4af5a9315686829e884328 branch=main release=v1.3.0 scanned=2026-11-20 -->
