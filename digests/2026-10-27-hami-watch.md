# HAMi diff 雷达 2026-10-27

## 摘要
- **HAMi-core 软算力时间片限流器核心修复**:计费口径从"按 grid 数"改为"按线程数(grids×blocks)",并全链路改 int64 + 溢出饱和 + 退避步长随当前令牌桶缩放。修的是大 GEMM(块少但块内线程多/长跑)几乎不消耗令牌桶、导致 SM 限流形同虚设的 bug——直接影响软切分算力隔离的可信度。
- **HAMi 主仓给 remote GPU(lupine 远程显卡池)补调度闭环**:远程显卡无服务器注册时 Fit 根本不触发、pod 永久卡在 unschedulable 队列;新增按 fleet revision 盖注解主动 requeue + 10min TTL 兜底。
- **HAMi 弃用 `hami_resource_quota_used` 的 `limit` label**(v2.11.0 弃用 / v2.12.0 移除),引导迁移到 `hami_resource_quota_limit`。其余 3 仓(volcano-vgpu / ascend-device-plugin / WebUI)本期无新提交。

## 当日重要改变
- **Project-HAMi/HAMi** `[弃用/移除]` `hami_resource_quota_used` 指标的 `limit` label 标记弃用,v2.11.0 弃用、v2.12.0 移除,迁移到 `hami_resource_quota_limit`。证据 `cmd/scheduler/metrics.go`(连 legacy `QuotaUsed` 一并改)。 https://github.com/Project-HAMi/HAMi/pull/3299
- **Project-HAMi/HAMi-core** `[能力修复]` 软算力限流器 charge/退避口径重写(按线程数计费 + int64 防溢出 + 步长随桶缩放),修复大 kernel 下 SM 限流不生效。证据 `src/multiprocess/multiprocess_utilization_watcher.c`、`src/cuda/memory.c`。 https://github.com/Project-HAMi/HAMi-core/pull/376
- **Project-HAMi/HAMi** `[调度行为]` remote GPU 在远程 fleet 为空/变更时不再把 pod 永久晾在 unschedulable 队列,改为盖注解主动 requeue。证据 `pkg/scheduler/scheduler.go`、`pkg/device/remotegpu/{pool,device}.go`。 https://github.com/Project-HAMi/HAMi/pull/3274

## Project-HAMi/HAMi: f4079c08 -> 363a4f5b
- 比较: f4079c08 -> 363a4f5b | ahead=3 | files=25 | Release: v2.10.0 | https://github.com/Project-HAMi/HAMi/compare/f4079c08e9380acc3012b8af0caa7d040819a7e2...363a4f5b2cf83c0de5cef4b67f0ff0117724c6e4

### AI 总结重点(源码 diff 为据)
- **remote GPU(lupine)调度补了一条"等 fleet 变更再重排"的闭环**。HAMi scheduler 是 kube-scheduler 的 extender,远程显卡这类资源:若集群里当前没有任何 lupine 服务器注册,就没有节点报告该卡、Fit 根本不会跑,kube-scheduler 把 pod 丢进 unschedulable 队列后,因为 extender 不产生任何事件,pod 要等到下一次队列 flush(分钟级)才可能被重看。新增 `RetryAnno = "hami.io/remote-gpu-retry"`:fleet 变化时给等待中的 pod 打这个注解(值为 fleet revision),任何 pod 更新都会立刻触发 requeue;另加 `waitingTTL = 10 * time.Minute` 兜底丢弃"等不到 fleet 变更"的僵尸 pod(如等待期间被删的)。
  <details><summary>代码依据 pkg/device/remotegpu/pool.go</summary>

  ```diff
  +	// RetryAnno is stamped on a pod that Fit turned away once the fleet
  +	// changes. ... the pod would sit in the unschedulable queue until the
  +	// next flush, minutes away. Any update to the pod requeues it at once.
  +	RetryAnno = "hami.io/remote-gpu-retry"
  +	// waitingTTL drops a refused pod that never got a fleet change to retry on.
  +	waitingTTL = 10 * time.Minute
  +
  +type waiter struct {
  +	uid             types.UID
  +	namespace, name string
  +	at              time.Time
  +}
  +// apiNudgePods ... returns the pods it could not patch, so they are kept
  +func apiNudgePods(pods []waiter, rev uint64) []waiter {
  +	payload := []byte(`{"metadata":{"annotations":{"` + RetryAnno + `":"` + strconv.FormatUint(rev, 10) + `"}}}`)
  +	for _, w := range pods {
  +		_, err := c.CoreV1().Pods(w.namespace).Patch(ctx, w.name, types.MergePatchType, payload, metav1.PatchOptions{})
  +		if err != nil && !apierrors.IsNotFound(err) { ... failed = append(failed, w) }
  ```
  </details>
- **Filter 失败路径接上了 WaitForFleet**。`scheduler.go` 在进入打分前先抓一次 `FleetRevision()`,当所有节点都不满足打分(`len(NodeList)==0`)且该 pod 确实请求了 remote GPU 资源(新 helper `requestsDevice(...)` 判断容器请求里是否含 `RemoteGPUCommonWord`)时,调 `rgpu.WaitForFleet(pod, fleetRev)` 把 pod 登记进等待集。`device.go` 侧 `WaitForFleet`/`FleetRevision` 只是把调用转发给 `pool.wait`/`pool.revision`。即:判断用的是"是否请求了远程 GPU",而非"是否有节点",这正好覆盖了"零服务器注册"这种 Fit 跑不到的盲区。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +func requestsDevice(requests device.PodDeviceRequests, deviceType string) bool {
  +	for _, container := range requests {
  +		if _, ok := container[deviceType]; ok { return true } }
  +	return false }
   ...
  +	var fleetRev uint64
  +	rgpu, hasRGPU := device.GetDevices()[remotegpu.RemoteGPUDevice].(*remotegpu.RemoteGPUDevices)
  +	if hasRGPU { fleetRev = rgpu.FleetRevision() }
   	if len((*nodeScores).NodeList) == 0 {
  +		if hasRGPU && requestsDevice(resourceReqs, remotegpu.RemoteGPUCommonWord) {
  +			rgpu.WaitForFleet(pod, fleetRev) }
  ```
  </details>
- **弃用信号(见"当日重要改变")**:`collectQuotaMetrics` 里 `hami_resource_quota_used` 及其 legacy 别名 `QuotaUsed` 的 help 文本被加上弃用说明,`limit` label 将在 v2.12.0 移除。
  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  -		"resourcequota usage for a certain device",
  +		"resourcequota usage for a certain device (DEPRECATED: the limit label is deprecated in v2.11.0, removed in v2.12.0; use hami_resource_quota_limit instead)",
   		[]string{"namespace", "quota_name", "limit"}, nil,
  ```
  </details>
- 其余为构建噪声:Go 1.27.3、NVIDIA CUDA 13.4.3、buildkit v0.34.1、helm v3.22.1 等 bump,并把 `GOLANG_IMAGE`/`NVIDIA_IMAGE` 从 workflow 内联改为统一从 `version.mk` 读(单一事实源),dcgm base image 固定到 digest。无能力含义,不展开。

### 后续发展方向 [AI]
- remote GPU(网络化/池化显卡,代号 lupine)正在从"能分配"走向"调度鲁棒性":本次补的是空 fleet → 有 fleet 的唤醒路径。证据只覆盖 scheduler/pool 的 requeue 机制,未见 fleet revision 如何递增、lupine server 注册/心跳协议(那部分在 `pool.go` 截断 hunk 之外),该方向待后续增量确认。
- 指标层在为 v2.12.0 做 label 清理(quota 系列),对接我们监控面板的话要提前把 `limit` label 的用法迁走。

## Project-HAMi/HAMi-core: cdb52607 -> 6736b058
- 比较: cdb52607 -> 6736b058 | ahead=38 | files=51 | Release: — | https://github.com/Project-HAMi/HAMi-core/compare/cdb5260760f16221c027ffeedb747c38a2f4deb5...6736b0589049390ec945bd40dfb4769f9f043def

### AI 总结重点(源码 diff 为据)
- **时间片算力限流器计费口径修正:从 grid 数 → 线程数(grids×blocks)**。`rate_limiter` 原来只按 grid 数扣令牌,对"块少但每块线程多、单块长跑"的 kernel(典型大 GEMM)几乎不扣费,令牌桶永远不空 → SM 限流名义存在但对这类负载完全不生效。改为 `kernel_size = grids * blocks`。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c</summary>

  ```diff
   void rate_limiter(int grids, int blocks) {
  -  int64_t kernel_size = grids;
  +  /* Charge by thread count: grid count alone barely charges kernels with few,
  +   * long-running blocks (large GEMMs), so the bucket never runs dry. */
  +  int64_t kernel_size = (int64_t)grids * blocks;
  ```
  </details>
- **乘法全链路改 int64 + 饱和,防溢出**。`rate_limiter` 签名 `(int,int)` → `(int64_t,int64_t)`;`memory.c` 三个 launch 入口(`cuLaunchKernel`/`cuLaunchKernelEx`/`cuLaunchCooperativeKernel`)在计算 `gridDim*...` 与 `blockDim*...` 时前置 `(int64_t)` 强转;`rate_limiter` 内 `grids*blocks` 加溢出判断,超 `INT64_MAX` 则饱和,避免扣费回绕成负/小值又把限流架空。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c / src/cuda/memory.c</summary>

  ```diff
  -  int64_t kernel_size = grids * blocks;
  +  int64_t kernel_size = (blocks != 0 && grids > INT64_MAX / blocks)
  +                            ? INT64_MAX
  +                            : grids * blocks;
  -extern void rate_limiter(int grids, int blocks);
  +extern void rate_limiter(int64_t grids, int64_t blocks);
  -        rate_limiter(gridDimX * gridDimY * gridDimZ, blockDimX * blockDimY * blockDimZ);
  +        rate_limiter((int64_t)gridDimX * gridDimY * gridDimZ, (int64_t)blockDimX * blockDimY * blockDimZ);
  ```
  </details>
- **退避步长改随"当前令牌桶"缩放,删掉固定基准 `g_base_cuda_cores`**。`delta()`(计算每轮令牌增减步长)原来用初始化时固定的 `g_base_cuda_cores` 当分母;但令牌桶 `g_total_cuda_cores` 会在遇到大 kernel 时被翻倍,固定步长就拉不回已抬高的 share,限流器"卡在不节流"状态。改用当前 `g_total_cuda_cores`,并彻底移除 `g_base_cuda_cores` 数组及其在 `setspec()` 的初始化。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c</summary>

  ```diff
  -static int64_t g_base_cuda_cores[CUDA_DEVICE_MAX_COUNT] = {0};
   static int64_t delta(int up_limit, int user_current, int64_t share, int device_id) {
  -  int64_t increment = g_base_cuda_cores[device_id] * (int64_t)utilization_diff / 1024;
  +  /* Scale the step with the current bucket: once it has been doubled for big
  +   * kernels, a step sized for the initial bucket cannot pull share back down. */
  +  int64_t increment = g_total_cuda_cores[device_id] * (int64_t)utilization_diff / 1024;
   ...
  -        g_base_cuda_cores[dev] = g_total_cuda_cores[dev];
  ```
  </details>
- **显存统计删除 `initial_offset` 固定偏移 + 删除 `active_oom_killer`**。`get_gpu_memory_usage` 不再往用量里加 `initial_offset`(该全局及其累加被整体删除);同时删掉 `active_oom_killer()`(遍历进程 `kill(pid,9)`)及开关 `enable_active_oom_killer`——即放弃"用量超限就强杀容器内所有进程"的旧 OOM 路径。显存隔离回到"按统计上报/拦截"而非"主动杀进程"。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -int enable_active_oom_killer;
  -size_t initial_offset=0;
  -int active_oom_killer() {
  -    for (i=0;i<region_info.shared_region->proc_num;i++) { kill(region_info.shared_region->procs[i].pid,9); }
  -    return 0; }
   size_t get_gpu_memory_usage(const int dev) {
  -    total+=initial_offset;
       return total;
  ```
  </details>
- **分配器删掉旧 region/bitmap 分配路径**。`allocator.h`/`allocator.c` 移除 `region`/`region_list`/`r_list`、`CUmemGenericAllocationHandle` 追踪、`round_up`、`view_vgpu_allocator`、`get_listsize`、`BITSIZE/IPCSIZE/OVERSIZE/ALIGN` 等一整套基于 region 的旧实现,只留 `device_overallocated`/`device_allocasync` 两条 allocated_list。属历史包袱清理,显存记账逻辑收敛。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
  -size_t BITSIZE = 512;   size_t IPCSIZE = 2097152;   size_t OVERSIZE = 134217728;
  -region_list *r_list;
  -size_t round_up(size_t size, size_t unit) { ... }
  -CUresult view_vgpu_allocator() { ... }
  -CUresult get_listsize(allocated_list *al, size_t *size) { ... }
  ```
  </details>
- 另有大量 NVML 包装(`nvml_entry.c`)注释掉的死代码、README(中/英/日)重写配置参考与构建说明、CMake 最低版本提到 3.18、CUDA 支持 12.x/13.x——文档与清理,不含能力变化。

### 后续发展方向 [AI]
- HAMi-core 这轮是对"软算力时间片隔离"内核的一次可信度修复:之前对大矩阵乘类负载 SM 限流可能失效,修完后限流对大 kernel 才真正落地——对标我们产品的软切分算力 QoS,这类计费口径/溢出是隔离保真度的关键,值得回归一次大 GEMM 下的限流有效性。证据覆盖 charge/delta/溢出三处 hunk,未覆盖 `change_token`/令牌桶翻倍的完整时序。
- 显存侧放弃 `active_oom_killer`(强杀)旧路径,方向是"统计拦截 + 分配器收敛",不再有进程级 kill 兜底;若我们依赖过超限强杀行为需注意此变化。证据为删除 hunk,未见是否有替代 OOM 处理路径。

## 本期无实质改动(折叠)
<details><summary>3 仓无新提交(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin — 相对上期锚点无新提交
- Project-HAMi/ascend-device-plugin — 相对上期锚点无新提交
- Project-HAMi/HAMi-WebUI — 相对上期锚点无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=363a4f5b2cf83c0de5cef4b67f0ff0117724c6e4 branch=master release=v2.10.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6736b0589049390ec945bd40dfb4769f9f043def branch=main release=— scanned=2026-10-27 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-27 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ab41bec367ca95ac52ed1bcb8667c33e689f8f37 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-27 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-27 -->
