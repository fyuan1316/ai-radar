# HAMi diff 雷达 2026-08-22

## 摘要
- **HAMi 主仓跨档 v2.9.0 → v2.10.0**:核心带一处调度器显存/算力记账修正——给 `ContainerDevice` 加 `Slots` 字段,把"一个 Pod 多容器共享同一张卡"的并发实例数正确累加到 `Device.Used`,修掉了折叠(collapse)统计时把多容器算成 1 份的欠计。
- **HAMi-core 一批 33 提交的软隔离内核加固**:NVML/CUDA 显存查询全面 clamp(usage>limit 时夹取而非报错/下溢)、共享内存 proc slot 访问加边界+PID 校验防悬垂、OOM 清理补齐 shrreg 锁;并把 `cuLaunchCooperativeKernel` 纳入 `rate_limiter`——补上协作式内核此前绕过算力限流的口子。
- volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI 本期无实质改动。

## 当日重要改变
- **Project-HAMi/HAMi [版本跨档]** v2.9.0 → v2.10.0(minor 跨档),随 PR #2759 同步 HAMi-core 子模块。https://github.com/Project-HAMi/HAMi/releases/tag/v2.10.0
- **Project-HAMi/HAMi [调度记账修正]** 折叠 Pod 设备用量时按容器并发数累加 `Slots`,避免共享卡的多副本占用被欠计。证据 `pkg/device/devices.go` / `pkg/scheduler/scheduler.go`,PR #2623。https://github.com/Project-HAMi/HAMi/pull/2623
- **Project-HAMi/HAMi-core [新能力/隔离补口]** `cuLaunchCooperativeKernel` 接入 `rate_limiter`,协作式内核不再绕过算力时分限流。证据 `src/cuda/memory.c`。https://github.com/Project-HAMi/HAMi-core/compare/5496322f...b216ba1b

## Project-HAMi/HAMi: f06e7e3c -> 4707fb02
- 比较: f06e7e3c -> 4707fb02 | ahead=3 | files=16 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/f06e7e3cac2e7fc9594ebb50c803000b95455663...4707fb02

### AI 总结重点(源码 diff 为据)
- **`ContainerDevice` 新增 `Slots int32` 字段,承载"这条折叠后的记录代表设备上几个并发任务"**。语义约定:0(未折叠的 raw 记录)按 1 计。这是把"共享同一张卡的多容器占用份数"显式建模进设备记账结构体。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
   type ContainerDevice struct {
  -	Idx        int
  -	Usedmem    int32
  -	Usedcores  int32
  +	Idx       int
  +	Usedmem   int32
  +	Usedcores int32
  +	// Slots is the number of concurrent tasks this collapsed entry represents on the device.
  +	// Usage reconstruction adds it to DeviceUsage.Used; 0 (raw, uncollapsed entries) counts as 1.
  +	Slots      int32
   	CustomInfo map[string]any
   }
  ```
  </details>
- **折叠逻辑区分 init 容器与 app 容器的 slot 计法**:`CollapseInitContainerUsage` 里 init 容器顺序执行 → 峰值并发恒为 `cur.slots = 1`;app 容器并发执行 → 每出现一次 `cur.slots++`;最终 `effSlots := max(initU.slots, appU.slots, 1)`。同一处 `usage` 结构体加了 `slots int32`。这修正了此前折叠只保留 mem/cores 峰值、丢掉并发份数的行为。
  <details><summary>代码依据 pkg/device/initContainer.go</summary>

  ```diff
   type usage struct {
   	mem   int32
   	cores int32
  +	slots int32
   }
  ...
  +					// Init containers run sequentially: peak concurrency is one slot per device.
  +					cur.slots = 1
  ...
  +					// App containers run concurrently: each occurrence is an additional slot.
  +					cur.slots++
  ...
  +			// Raw entries carry no slot count; clamp to at least one.
  +			effSlots := max(initU.slots, appU.slots, 1)
   			containerDevs = append(containerDevs, ContainerDevice{
  +				Slots:     effSlots,
  ```
  </details>
- **调度器 `getNodesUsage` 把设备占用计数从"每匹配一次 +1"改为"加上该记录的 Slots(至少 1)"**,即 `d.Device.Used++` → `d.Device.Used += max(udevice.Slots, 1)`。这是本次修正真正落到调度决策的一步:节点可用卡位统计现在反映多容器并发实占,避免共享卡被超卖。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
   						if d.Device.ID == deviceID {
   							matched = true
  -							d.Device.Used++
  +							// Raw entries carry no slot count; clamp to at least one.
  +							slots := max(udevice.Slots, 1)
  +							d.Device.Used += slots
  							d.Device.Usedmem += udevice.Usedmem
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 正在把"单卡多容器共享"这条路径的记账做准**:v2.10.0 的核心不是新能力而是修正——之前折叠 Pod 用量会把同卡多 app 容器的并发份数压成 1,导致 `Device.Used` 欠计、共享卡有被超卖风险;现在按 slot 累加。方向是让 vGPU 共享调度在"一个 Pod 塞多个用卡容器"的高密场景下计数可信。证据仅覆盖 `devices.go`/`initContainer.go`/`scheduler.go` 三处 slot 传递链;代码注释里的 TODO 指向 PR #2584(sidecar 改按 app-sum 记账)尚未合入,说明 sidecar 与 slot 分类的交互还是敞口,未见其实现。

## Project-HAMi/HAMi-core: 5496322f -> b216ba1b
- 比较: 5496322f -> b216ba1b | ahead=33 | files=13 | Release: —
- https://github.com/Project-HAMi/HAMi-core/compare/5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd...b216ba1b

### AI 总结重点(源码 diff 为据)
- **NVML 显存查询 `_nvmlDeviceGetMemoryInfo` 重写为"物理容量 + 限额双重夹取"**:先按 version 取真实物理 total,`actual_limit = min(limit, physical_total)`,再 `clamped = min(usage, actual_limit)`,`free` 用 `actual_limit - clamped`(且防负)。同时把非法 version 从"落空返回"改为显式 `NVML_ERROR_INVALID_ARGUMENT`。前行为在 usage>limit 或 limit>物理容量时会产生下溢/虚高;现在恒为自洽的一致视图。
  <details><summary>代码依据 src/nvml/hook.c</summary>

  ```diff
  -             ((nvmlMemory_t*)memory)->free = (limit-usage);
  -             ((nvmlMemory_t*)memory)->total = limit;
  -             ((nvmlMemory_t*)memory)->used = usage;
  +        size_t actual_limit = (limit > physical_total) ? physical_total : limit;
  +        size_t clamped = (usage > actual_limit) ? actual_limit : usage;
  +        if (usage > actual_limit) {
  +            LOG_WARN("NVML meminfo: usage %lu exceeds limit %lu, clamping", usage, actual_limit);
  +        }
  +            ((nvmlMemory_t*)memory)->free = (actual_limit > clamped) ? (actual_limit - clamped) : 0;
  +            ((nvmlMemory_t*)memory)->total = actual_limit;
  +            ((nvmlMemory_t*)memory)->used = clamped;
  ```
  </details>
- **`cuMemGetInfo_v2` 同源修正**:原来 `limit < usage` 直接返回 `CUDA_ERROR_INVALID_VALUE`(让上层看到查询失败),现在改为 clamp usage 后照常返回一致的 free/total。软隔离下的显存视图从"可能报错"变为"始终给出被限额约束的自洽值"。
  <details><summary>代码依据 src/cuda/memory.c</summary>

  ```diff
  -    } else if (limit < usage) {
  -        LOG_WARN("limit < usage; usage=%ld, limit=%ld", usage, limit);
  -        return CUDA_ERROR_INVALID_VALUE;
  -    } else {
  +    } else {
  +        size_t clamped = (usage > limit) ? limit : usage;
  +        if (usage > limit) {
  +            LOG_WARN("CUDA meminfo: usage %lu exceeds limit %lu, clamping", usage, limit);
  +        }
  +        *free = (actual_limit > clamped) ? (actual_limit - clamped) : 0;
  ```
  </details>
- **`cuLaunchCooperativeKernel` 接入 `rate_limiter`**:此前协作式内核启动只走 `pre_launch_kernel()`,绕过了算力时分限流;现在按 grid×block 线程数调用 `rate_limiter`,与普通 `cuLaunchKernel` 对齐。这是软算力隔离覆盖面的实质补口——协作组内核不再是限流盲区。
  <details><summary>代码依据 src/cuda/memory.c</summary>

  ```diff
   CUresult cuLaunchCooperativeKernel ( ... ) {
       ENSURE_RUNNING();
       ensure_post_init();
       pre_launch_kernel();
  +    if (pidfound==1){
  +        rate_limiter(gridDimX * gridDimY * gridDimZ,
  +                   blockDimX * blockDimY * blockDimZ);
  +    }
  ```
  </details>
- **共享内存 proc slot 访问加固**:新增 `get_current_proc_slot()` 取代 `set_current_gpu_status` 里的裸缓存路径——校验 `my_slot` 仍落在 `procs[0..proc_num)` 有效区间、地址按 slot 大小对齐、且 `slot->pid == getpid()` 才复用;否则线性扫描且**不回写 my_slot**(避免其他线程仍在用旧缓存时踩踏)。这修的是 proc slot 压缩(compaction)后 my_slot 悬垂导致误写他人状态。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  +static shrreg_proc_slot_t* get_current_proc_slot(void) {
  +    uintptr_t procs_end = procs_start + (sizeof(region->procs[0]) * (size_t)proc_num);
  +    if (slot != NULL && slot_addr >= procs_start && slot_addr < procs_end &&
  +        ((slot_addr - procs_start) % sizeof(region->procs[0]) == 0) &&
  +        atomic_load_explicit(&slot->pid, memory_order_acquire) == current_pid) {
  +        return slot;
  +    }
  +    for (int i = 0; i < proc_num; i++) {
  +        if (slot_pid == current_pid) {
  +            // Do not rewrite my_slot here: other threads may still be using the stale cache.
  +            return &region->procs[i];
  ```
  </details>
- **OOM 清理补齐共享区锁 + NVML/CUDA 初始化仅在成功时 postInit**:`oom_check` 里 `clear_proc_slot_nolock(1)` 现被 `lock_shrreg()/unlock_shrreg()` 包裹(原来无锁清理跨进程 slot);`nvmlInit`/`nvmlInit_v2`/`nvmlInitWithFlags` 改为仅当底层 `res == NVML_SUCCESS` 才 `pthread_once(nvml_postInit)`,避免真实 nvml 初始化失败时仍跑虚拟映射后处理。
  <details><summary>代码依据 src/allocator/allocator.c + src/nvml/hook.c</summary>

  ```diff
  -        if (clear_proc_slot_nolock(1) > 0)
  +        lock_shrreg();
  +        int cleared = clear_proc_slot_nolock(1);
  +        unlock_shrreg();
  +        if (cleared > 0)
  ...
  -    pthread_once(&init_virtual_map_post_flag,(void (*)(void))nvml_postInit);
  +    if (res == NVML_SUCCESS) {
  +        pthread_once(&init_virtual_map_post_flag,(void (*)(void))nvml_postInit);
  +    }
  ```
  </details>
- **移除 dlsym 递归检测机制**:删掉 `dlmap`/`check_dlmap`/`init_dlsym`/`dlsym_lock` 整套,`RTLD_NEXT` 分支直接 `return real_dlsym(RTLD_NEXT, symbol)`。原机制把第二次 `RTLD_NEXT` dlsym 误判为递归并返回 NULL,现停止此启发式(配合 commit "stop treating a second RTLD_NEXT dlsym as recursion")。属简化+纠错,减少 hook 拦截的边角失败。
  <details><summary>代码依据 src/libvgpu.c</summary>

  ```diff
  -    if (handle == RTLD_NEXT) {
  -        void *h = real_dlsym(RTLD_NEXT,symbol);
  -        pthread_mutex_lock(&dlsym_lock);
  -        if (check_dlmap(tid,h)){
  -            LOG_WARN("recursive dlsym : %s\n",symbol);
  -            h = NULL;
  -        }
  -        return h;
  +    if (handle == RTLD_NEXT) {
  +        return real_dlsym(RTLD_NEXT, symbol);
  ```
  </details>
- 另有一批边界/下溢加固(未逐条贴):`cuMemAllocPitch_v2` 对 `ElementSizeBytes==0||WidthInBytes==0` 返回 pitch=0 防除零;`cuPointerGetAttributes` 失败早返回、不再强行把 `IS_MANAGED` 置 0(保留托管内存状态);`utils.c` 修 `getextrapid` 无符号下溢与 `parse_cuda_visible_env` 全局缓冲越界;`get_limit_from_env` 用 `strlen` 守 `env_name[12]` 读取。新增 issue #1662 的 init 竞争基准 `bench_init_contention.c`(纯测量,不改行为)。

### 后续发展方向 [AI]
- **HAMi-core 这轮是"软隔离内核可信化"批次,而非新增隔离维度**:主线是把显存视图(NVML/CUDA 双通道)在 usage>limit / limit>物理容量等异常下从"报错或下溢"统一收敛为"clamp 到自洽值",并堵住共享内存 proc slot 悬垂、OOM 无锁清理、nvml 失败仍 postInit 等并发/健壮性漏洞。方向是让容器内 `nvidia-smi`/框架看到的显存数字在高并发、进程频繁进出场景下始终一致可信——这是软切分产品化的地基。唯一算力侧的能力扩展是 `cuLaunchCooperativeKernel` 纳入限流(补口而非新特性)。证据覆盖 nvml/cuda/multiprocess/allocator/libvgpu 五处 hunk;未见新增 hook 类型或新隔离资源维度,`bench_init_contention` 表明团队开始量化 init 锁竞争,后续或有初始化路径的锁优化(本期未见优化本身,仅测量工具)。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=4707fb02c91c545bc7343ce26dba4c32919f9a3e branch=master release=v2.10.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=b216ba1be1b8e21488d1c7370ed3357b3049aad1 branch=main release=— scanned=2026-08-22 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-22 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-22 -->
