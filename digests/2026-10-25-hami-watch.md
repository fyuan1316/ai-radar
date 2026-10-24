# HAMi diff 雷达 2026-10-25

## 摘要
- HAMi-core(#374):CUDA 主上下文显存基线的测量从「broker init 时急切测量(固定 device 0 + 占节点锁)」改为「应用首次 retain 时惰性测量(按实际 retain 的设备 + 本地 mutex)」,init 不再自建上下文、不再争节点锁。这是软隔离内核显存记账路径的一处行为级重构。
- HAMi(#3294):vGPUmonitor 的 per-container vGPU/MIG 指标采集跳过 Succeeded/Failed 终态 Pod,修掉已释放设备仍被上报的脏指标。
- 其余 3 仓(volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI)自 2026-10-24 锚点以来无新提交;Release 均持平。

## 当日重要改变
- 无(两处改动均未命中弃用/API-CRD/proposal/版本跨档/新 package 信号;属常规增量,详见各仓正文)

## Project-HAMi/HAMi-core: 0ee2a428 -> cdb52607
- 比较: 0ee2a428 -> cdb52607 | ahead=1 | files=8 | Release: —
- 提交: size the primary context at the first retain (#374) https://github.com/Project-HAMi/HAMi-core/pull/374

### AI 总结重点(源码 diff 为据)
- `set_task_pid_from_broker()` 被剥掉了「急切测量主上下文」整段逻辑:旧版在 broker 查到 hostpid 后,会取节点锁 → `cuDevicePrimaryCtxRetain(&pctx, 0)` 在 **device 0** 上强制建一个主上下文 → `get_used_gpu_memory_by_pid` 量显存 → 写 `context_size` → 释放上下文 + 解锁;新版这段全部删除,init 阶段**不再自建任何 CUDA 上下文、也不再碰节点锁**,只保留 set_host_pid / nvmlInit / map_cuda_visible_devices 后直接返回。
  <details><summary>代码依据 src/utils.c</summary>

  ```diff
  -// The broker names this process's host PID without NVML discovery. Context
  -// sizing shares the node lock so its retain cannot disturb a fallback probe.
  +static pthread_mutex_t lazy_sizing_lock = PTHREAD_MUTEX_INITIALIZER;
  +static pid_t lazy_sizing_hostpid;
  +
  +// The broker names this process's host PID without NVML discovery. The
  +// context is sized later, from the first primary context the application
  +// retains, so init creates no context of its own.
   nvmlReturn_t set_task_pid_from_broker(void) {
       pid_t hostpid = 0;
  -    unsigned long long used = 0;
  -    CUcontext pctx;
  -    nvmlReturn_t res;
  -    struct timespec deadline;
   ...
  -    if (hostpid_fallback_lock_deadline_after_ms(...) != 0 ||
  -        hostpid_fallback_lock_acquire_shared_until(&deadline) != 0) {
  -        LOG_WARN("Skipped primary context sizing because the node lock failed...");
  -        return NVML_SUCCESS;
  -    }
  -    if (cuDevicePrimaryCtxRetain(&pctx, 0) != CUDA_SUCCESS) { ... }
  -    res = get_used_gpu_memory_by_pid(hostpid, &used);
  -    if (res == NVML_SUCCESS) { context_size = used; } ...
  ```
  </details>
- 测量改由新函数 `size_primary_context_lazily(int cudadev)` 承担,挂在 `cuDevicePrimaryCtxRetain` 的 hook 里:仅当 retain 成功**且 `context_size == 0`** 时触发一次,按应用**实际 retain 的那个 dev** 测量,而非固定 device 0。
  <details><summary>代码依据 src/cuda/context.c</summary>

  ```diff
   CUresult cuDevicePrimaryCtxRetain(CUcontext *pctx, CUdevice dev){
       CUresult res = CUDA_OVERRIDE_CALL(cuda_library_entry,cuDevicePrimaryCtxRetain,pctx,dev);
  +    if (res == CUDA_SUCCESS && context_size == 0) {
  +        size_primary_context_lazily(dev);
  +    }
       if (ctx_activate[dev] == 0) {
           add_gpu_device_memory_usage(getpid(),dev,context_size,0);
       }
  ```
  </details>
- `get_used_gpu_memory_by_pid` 签名加了 `int cudadev` 形参,内部由硬编码 `cuda_to_nvml_map(0)` 改成 `cuda_to_nvml_map(cudadev)` —— 显存查询目标跟随应用用的设备,不再默认落在物理 0 号卡上。
  <details><summary>代码依据 src/utils.c</summary>

  ```diff
  -static nvmlReturn_t get_used_gpu_memory_by_pid(pid_t hostpid,
  +static nvmlReturn_t get_used_gpu_memory_by_pid(pid_t hostpid, int cudadev,
                                                 unsigned long long *used) {
  -    res = nvmlDeviceGetHandleByIndex(cuda_to_nvml_map(0), &device);
  +    res = nvmlDeviceGetHandleByIndex(cuda_to_nvml_map(cudadev), &device);
  ```
  </details>
- fork 后在 `childReinitPostInit()` 里新增 `reset_lazy_context_sizing()`,让子进程重新武装一次惰性测量(配合 `context_size==0` 的触发条件),头文件 libvgpu.h 导出 `size_primary_context_lazily` / `reset_lazy_context_sizing` 两个新符号。
  <details><summary>代码依据 src/libvgpu.c + src/include/libvgpu.h</summary>

  ```diff
   void childReinitPostInit() {
       hostpid_fallback_lock_after_fork();
  +    reset_lazy_context_sizing();
       ...
  +void size_primary_context_lazily(int cudadev);
  +void reset_lazy_context_sizing(void);
  ```
  </details>
- 测试侧同步改口径:并发/映射测试断言「broker init creates no context」「broker init leaves the context unsized」「sizing takes no node lock」,并新增「应用首次 retain 后由 `size_primary_context_lazily(0)` 完成测量、`queried_index` 指向 retain 设备的物理 GPU」。原来基于节点锁(`hostpid_fallback_lock_*`)协调测量的 fake 全部删除。

### 后续发展方向 [AI]
- 方向是把「主上下文显存基线」的测量从 init 期前移到真正用卡时,且做到**设备感知**:避免 HAMi-core 在应用还没用 GPU 时就替它在 0 号卡建上下文(白占显存/可能选错卡),也去掉了测量与 fallback 探测争节点锁的耦合(改用进程内 `lazy_sizing_lock`)。证据只覆盖 utils.c/context.c 的测量与 retain hook 路径,**未见** vGPU 显存上限的实际拦截/扣减逻辑(add_gpu_device_memory_usage 之后的限额执行)有改动——这次只动"基线怎么量",没动"量完怎么限"。

## Project-HAMi/HAMi: 33b7220f -> f4079c08
- 比较: 33b7220f -> f4079c08 | ahead=1 | files=3 | Release: v2.10.0
- 提交: fix(vGPUmonitor): skip terminated pods in per-container metrics (#3294) https://github.com/Project-HAMi/HAMi/pull/3294

### AI 总结重点(源码 diff 为据)
- `ClusterManagerCollector.collectPodAndContainerInfo` 与 `collectPodAndContainerMigInfo`(cmd/vGPUmonitor/metrics.go)两个采集循环各加了一处早退:遇到终态 Pod(Succeeded/Failed)直接 `continue`,不再为其上报 per-container vGPU 指标与 MIG 分配指标。判定走新引入的 `util.IsPodInTerminatedState(pod)`,注释点明终态 Pod "no longer hold their devices"。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go</summary>

  ```diff
       for _, pod := range pods {
  +        // Skip terminated pods (Succeeded or Failed): they no longer hold their devices.
  +        if util.IsPodInTerminatedState(pod) {
  +            klog.V(5).Infof("Skipping terminated pod %s/%s", pod.Namespace, pod.Name)
  +            continue
  +        }
           podContainers, found := containerMap[string(pod.UID)]
  ```
  (collectPodAndContainerMigInfo 处同形插入,位于 DecodeMigAllocations 之前)
  </details>
- 其余两文件为对应单测:`TestCollectPodAndContainerInfoSkipsTerminatedPods` / `TestCollectPodAndContainerMigInfoSkipsTerminatedPods`,分别用 PodSucceeded/PodFailed 两相验证「Running 时有指标、转终态后采集条数归零」。

### 后续发展方向 [AI]
- 纯指标正确性修复:Pod 跑完/失败释放设备后,Prometheus 侧不再残留它的 per-container vGPU/MIG 占用,避免监控面板把已释放显存算成仍在用。证据仅覆盖 vGPUmonitor 指标采集,**未触及**调度/分配(scheduler、device-plugin allocate)逻辑,不影响实际配额。

## 本期无实质改动(折叠)
<details><summary>3 仓本期无实质改动(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin:5283c861 -> 5283c861,无新提交
- Project-HAMi/ascend-device-plugin:ab41bec3 -> ab41bec3,无新提交,Release ascend-device-plugin-0.2.0
- Project-HAMi/HAMi-WebUI:4f5875cf -> 4f5875cf,无新提交,Release v1.3.0
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=f4079c08e9380acc3012b8af0caa7d040819a7e2 branch=master release=v2.10.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=cdb5260760f16221c027ffeedb747c38a2f4deb5 branch=main release=— scanned=2026-10-25 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-25 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ab41bec367ca95ac52ed1bcb8667c33e689f8f37 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-25 -->
