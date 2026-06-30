# HAMi diff 雷达 2026-07-01

## 摘要
- **昇腾 vNPU 软切分修正核心注册口径**:ascend-device-plugin 在 hami-vnpu-core(软切分)模式下把上报给 HAMi 的 `Devcore` 从硬件真实 AICore 数改为固定 100(百分比语义),与"core 请求按百分比"的软隔离模型对齐——这是直接落在本 task 边界内的 vNPU 能力修正。
- **主仓为昇腾插件铺集成路径**:HAMi 主仓把 nvidia device-plugin 的分配成功/失败回调(`PodAllocationFailed`/`PodAllocationTrySuccess`)导出,供 ascend-device-plugin 复用,两生态共用同一套节点锁/注解释放逻辑。
- **HAMi-core 一批 C 健壮性硬化**:fd 泄漏、`sprintf`→`snprintf`、malloc 判空、getenv 缓存——无新能力,但 hook 内核稳定性边界在收紧。

## 当日重要改变
- **Project-HAMi/ascend-device-plugin** [新能力/边界修正] hami-vnpu-core 软切分模式下设备核数上报口径改为百分比满值 100,纠正之前直接报硬件 AICore 数导致的调度语义错配。证据 `internal/server/register.go` / `internal/server/server.go`(新增常量 `HamiVnpuCoreMaxPercent=100`)https://github.com/Project-HAMi/ascend-device-plugin/commit/9f91d3013b3576b162cf0e942fb93b821576f97d
- **Project-HAMi/HAMi** [架构方向/集成] 导出 nvidia device-plugin 的 Pod 分配回调给昇腾插件复用(#1989),两生态交汇点从"各写一套"走向"共享主仓基建"。证据 `pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go` https://github.com/Project-HAMi/HAMi/pull/1989

## Project-HAMi/HAMi: 03eed2e9 -> 55846c8a
- 比较: 03eed2e96b5f6fbc486b8869f5d3006bebf3d0cc -> 55846c8a | ahead=2 | files=4 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/03eed2e96b5f6fbc486b8869f5d3006bebf3d0cc...55846c8a

### AI 总结重点(源码 diff 为据)
- **新增两个导出包装函数 `PodAllocationTrySuccess` / `PodAllocationFailed`**,只是对原私有变量函数 `podAllocationTrySuccess` / `podAllocationFailed` 的薄封装,目的是把这套"分配成功/失败 → 更新 Pod 注解 + 释放节点锁"的逻辑暴露给包外(昇腾 device-plugin)调用。同时 `server.go` 的 `Allocate` 内部全部调用点从私有名切到导出名。意义:昇腾 vNPU 插件不再自行实现节点锁/注解释放,而是直接复用主仓 nvidia 路径的同一套机制,是两生态在 device-plugin 层的基建归一。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go</summary>

  ```diff
  +func PodAllocationTrySuccess(nodeName string, devName string, lockName string, pod *corev1.Pod) {
  +	podAllocationTrySuccess(nodeName, devName, lockName, pod)
  +}
  +
   func PodAllocationSuccess(nodeName string, pod *corev1.Pod, lockName string) {
  ...
  +func PodAllocationFailed(nodeName string, pod *corev1.Pod, lockName string) {
  +	podAllocationFailed(nodeName, pod, lockName)
  +}
  ```
  </details>
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go(调用点切换)</summary>

  ```diff
  -					podAllocationFailed(nodename, current, NodeLockNvidia)
  +					PodAllocationFailed(nodename, current, NodeLockNvidia)
  ...
  -	podAllocationTrySuccess(nodename, nvidia.NvidiaGPUDevice, NodeLockNvidia, current)
  +	PodAllocationTrySuccess(nodename, nvidia.NvidiaGPUDevice, NodeLockNvidia, current)
  ```
  </details>
- 另一条提交是 CONTRIBUTING.md 加 issue/PR 两周不响应即关闭的生命周期策略(治理流程,非代码能力)。

### 后续发展方向 [AI]
- nvidia 与 ascend 两条 device-plugin 路径在主仓层面开始共享分配生命周期基建,后续昇腾插件大概率会进一步 import 主仓而非各自维护。证据只覆盖了"导出回调函数"这一步,未见昇腾侧已实际 import(本期 ascend 仓 diff 里仍是自有 register 逻辑)。

## Project-HAMi/HAMi-core: 0831874b -> 8f3a89c6
- 比较: 0831874bce5af56cefca7093dfb2f9f95d1970aa -> 8f3a89c6 | ahead=18 | files=6 | Release: —
- https://github.com/Project-HAMi/HAMi-core/compare/0831874bce5af56cefca7093dfb2f9f95d1970aa...8f3a89c6

### AI 总结重点(源码 diff 为据)
- **`load_env_from_file` 修文件描述符泄漏 + 重写读取循环**:原来用 `while(!feof(f))` 反模式(典型多读一行)且函数返回前从不 `fclose`,改为 `while(fgets(...)!=NULL)` 正确驱动循环、缓存 `strlen` 到 `tmplen` 避免每次循环重算、并在返回前补 `fclose(f)`。这是 hook 进程加载 vGPU 限额环境变量(显存/算力配额)的入口,泄漏会随反复加载累积 fd。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -    int cursor=0;
  -    while (!feof(f)){
  -        fgets(tmp,10000,f);
  -        if (strstr(tmp,"=")==NULL)
  +    int cursor = 0;
  +    size_t tmplen = 0;
  +    while (fgets(tmp, sizeof(tmp), f) != NULL) {
  +        if (strstr(tmp, "=") == NULL)
             break;
  -        if (tmp[strlen(tmp)-1]=='\n')
  -            tmp[strlen(tmp)-1]='\0';
  -        for (cursor=0;cursor<strlen(tmp);cursor++){
  +        tmplen = strlen(tmp);
  +        if (tmp[tmplen - 1] == '\n')
  +            tmp[--tmplen] = '\0';
  +        for (cursor = 0; cursor < (int)tmplen; cursor++) {
   ...
  +    fclose(f);
       return 0;
  ```
  </details>
- **`try_create_shrreg` 缓存 `getenv(CUDA_TASK_PRIORITY_ENV)`**:原来连续两次 `getenv` 同一 key(判空一次、取值一次),改为存到 `_priority_env` 单次取。这是共享内存区初始化时读取任务优先级(跨 Pod 算力协商用)的逻辑。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -        if (getenv(CUDA_TASK_PRIORITY_ENV)!=NULL)
  -            region->priority = atoi(getenv(CUDA_TASK_PRIORITY_ENV));
  +        char *_priority_env = getenv(CUDA_TASK_PRIORITY_ENV);
  +        if (_priority_env != NULL)
  +            region->priority = atoi(_priority_env);
  ```
  </details>
- **`allocator_init` 给 malloc 加判空**:`device_overallocated` / `device_allocasync` 两个分配链表头分配失败时 `LOG_ERROR` 后 `exit(EXIT_FAILURE)`,而非原来无检查直接 `LIST_INIT` 解空指针。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
       device_overallocated = malloc(sizeof(allocated_list));
  +    if (!device_overallocated) {
  +        LOG_ERROR("allocator_init: malloc failed");
  +        exit(EXIT_FAILURE);
  +    }
       LIST_INIT(device_overallocated);
  -    device_allocasync=malloc(sizeof(allocated_list));
  +    device_allocasync = malloc(sizeof(allocated_list));
  +    if (!device_allocasync) { ... exit(EXIT_FAILURE); }
  ```
  </details>
- **`proc_alive` 用 `snprintf` 替 `sprintf`**:拼 `/proc/%d/stat` 路径时给定缓冲区上界,消除潜在栈溢出。该函数用于死进程配额回收(判进程是否存活)。
  <details><summary>代码依据 src/include/process_utils.h</summary>

  ```diff
  -    sprintf(filename, "/proc/%d/stat", pid);
  +    snprintf(filename, sizeof(filename), "/proc/%d/stat", pid);
  ```
  </details>
- 测试侧:`limit_tensorflow2.py` 删过时的 `tf.enable_eager_execution()`,`limit_pytorch.py` 给 `.cuda(args.device)` 传设备号;CONTRIBUTING.md 改 master→main 并加生命周期策略(均非内核能力)。

### 后续发展方向 [AI]
- 本期 HAMi-core 全是防御性硬化(fd/缓冲区/空指针/getenv),没有新 hook 类型或新隔离能力,延续上期 DCMI 进程追踪重构后的"稳定化收尾"节奏。证据只覆盖这 6 个文件的 hunk,未见新增 package 或新拦截符号,故判断本期非能力扩张而是质量加固。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓</summary>

- Project-HAMi/volcano-vgpu-device-plugin:无新提交(6561f1c1)
- Project-HAMi/HAMi-WebUI:无新提交(8f42445d,Release hami-webui-1.2.0)
</details>

## ascend-device-plugin 深度(归在本 task 边界内,单列)

## Project-HAMi/ascend-device-plugin: 92ef2136 -> 9f91d301
- 比较: 92ef21365bd0a4f0d0a8bb076862d139e99f21f9 -> 9f91d301 | ahead=7 | files=4 | Release: —
- https://github.com/Project-HAMi/ascend-device-plugin/compare/92ef21365bd0a4f0d0a8bb076862d139e99f21f9...9f91d301

### AI 总结重点(源码 diff 为据)
- **`registerHAMi` 在软切分模式下改报固定核数 100**:新增判断 `if ps.mgr.IsHamiVnpuCore()` 时把上报给 HAMi 的 `Devcore` 从硬件真实 `dev.AICore`(如 310P 的 8)替换为新常量 `HamiVnpuCoreMaxPercent=100`。语义对齐:hami-vnpu-core 软切分下 core 请求按百分比计,设备总可分配核单位必须是 100% 而非物理核数,否则 HAMi 调度器按 8 核切分会把百分比请求算错。
  <details><summary>代码依据 internal/server/register.go</summary>

  ```diff
  +		devcore := dev.AICore
  +		if ps.mgr.IsHamiVnpuCore() {
  +			devcore = HamiVnpuCoreMaxPercent
  +		}
   		device := &device.DeviceInfo{
   			...
  -			Devcore: dev.AICore,
  +			Devcore: devcore,
  ```
  </details>
  <details><summary>代码依据 internal/server/server.go(新增常量)</summary>

  ```diff
  +	// HamiVnpuCoreMaxPercent is the total allocatable core units per device in
  +	// soft-slice (hami-vnpu-core) mode, where core requests are percentages.
  +	HamiVnpuCoreMaxPercent = 100
  ```
  </details>
- **`dial` 重写 gRPC 连接建立**:target 加 `passthrough:///` 前缀(绕过 grpc 新版默认 DNS 解析,直连 unix socket),并把原来"一次 `WaitForStateChange` 到 Ready 否则超时"的简化逻辑换成显式状态轮询循环——遇到 `TransientFailure`/`Shutdown` 立即关闭返错,Ready 才返回,否则阻塞到 deadline。修了 `grpc.NewClient` 非阻塞语义下连接错误被吞(原 `c, _ :=` 丢弃 err)的问题。
  <details><summary>代码依据 internal/server/register.go</summary>

  ```diff
  -	c, _ := grpc.NewClient(unixSocketPath,
  +	target := "passthrough:///" + unixSocketPath
  +	c, err := grpc.NewClient(target, ...)
  +	if err != nil {
  +		return nil, fmt.Errorf("grpc.NewClient(%s): %w", target, err)
  +	}
  +	c.Connect()
  +	for {
  +		state := c.GetState()
  +		if state == connectivity.Ready { return c, nil }
  +		if state == connectivity.TransientFailure || state == connectivity.Shutdown {
  +			c.Close()
  +			return nil, fmt.Errorf("connection to %s failed (state: %s)", unixSocketPath, state)
  +		}
  +		if !c.WaitForStateChange(ctx, state) { ... timed out ... }
  +	}
  ```
  </details>
- **DaemonSet yaml 日志目录 hostPath 改 `DirectoryOrCreate`**:`/var/log/mindx-dl/devicePlugin` 的 type 从 `Directory`(不存在则 Pod 起不来)改为 `DirectoryOrCreate`,配合提交 "create ascend device plugin log path",降低裸节点部署门槛。
  <details><summary>代码依据 ascend-device-plugin.yaml</summary>

  ```diff
           - name: log-path
             hostPath:
               path: /var/log/mindx-dl/devicePlugin
  -            type: Directory
  +            type: DirectoryOrCreate
  ```
  </details>

### 后续发展方向 [AI]
- 软切分(hami-vnpu-core)模式正从"能跑"走向"算对":本期补齐百分比核数上报口径,是把昇腾 vNPU 软隔离真正接入 HAMi 调度语义的关键一环。证据覆盖 register/server/yaml,未见 IsHamiVnpuCore 的判定来源(在 manager 包,本期未改),软切分的显存口径是否也需类似归一(本期只动了 core)未见证据。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=55846c8afd245ad38baf38dd2b35920db9cf66de branch=master release=v2.9.0 scanned=2026-07-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=8f3a89c67b037d8fdfe6c4cd4d8c4f0cd6504811 branch=main release=— scanned=2026-07-01 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-01 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9f91d3013b3576b162cf0e942fb93b821576f97d branch=main release=— scanned=2026-07-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=8f42445d325736655d467842cb762b75f2612d25 branch=main release=hami-webui-1.2.0 scanned=2026-07-01 -->
