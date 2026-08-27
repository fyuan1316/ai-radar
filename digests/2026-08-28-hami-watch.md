# HAMi diff 雷达 2026-08-28

## 摘要
- **HAMi 主仓一波"越界请求硬拒绝"横扫全厂商**:nvidia/metax/cambricon/biren/awsneuron/enflame/kunlun/amd 的 device count(0/负/溢出)与 core 百分比(必须 0–100)校验统一收紧,`core>100` 从旧的"clamp 到 100 继续调度"改为**直接拒绝该设备/该请求**——软切分的资源边界从"容忍并纠偏"转向"严格失败",行为语义变了。
- **调度器新增两个状态可观测指标** `hami_scheduler_is_leader` / `hami_scheduler_cache_synced`(#2758),配套把 `synced` 字段从 mutex 保护改为 `atomic.Bool` 无锁读;运维可直接对 leader 丢失/缓存失步告警,不再靠捞日志。
- **HAMi-core 内核清理**:删除废弃的 `/tmp/vgpulock/lock` 全局文件锁(`try_lock_unified_lock`/`try_unlock_unified_lock`),显存多进程协调已不依赖它;PID 发现/合并逻辑补齐单测。

## 当日重要改变
- Project-HAMi/HAMi [新能力/可观测性] scheduler 暴露 `hami_scheduler_is_leader`、`hami_scheduler_cache_synced` 两个 gauge,`synced` 改 atomic 无锁读。证据 cmd/scheduler/metrics.go、pkg/scheduler/scheduler.go https://github.com/Project-HAMi/HAMi/pull/2758
- Project-HAMi/HAMi [行为变更] 全厂商 core/count 越界请求由"clamp 纠偏"改为"拒绝"。证据 pkg/device/nvidia/device.go、pkg/device/metax/device.go https://github.com/Project-HAMi/HAMi/pull/2740 https://github.com/Project-HAMi/HAMi/pull/2784
- Project-HAMi/HAMi [Bug/正确性] nvidia device-plugin 按物理 UUID 配对 per-device 显存限制,修显存限额挂错 GPU。证据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go https://github.com/Project-HAMi/HAMi/pull/2814
- Project-HAMi/HAMi-core [架构清理] 移除废弃 unified_lock 全局文件锁。证据 src/utils.c https://github.com/Project-HAMi/HAMi-core/commit/de6ce39dc36246d4161e931ae2fd93929e676e55

## Project-HAMi/HAMi: b1fd3583 -> 8ca23d00
- 比较 b1fd35838082f7a7e83486d0203ee55df8afe739 -> 8ca23d00 | ahead=22 | files=78 | Release: v2.10.0
- 比较页 https://github.com/Project-HAMi/HAMi/compare/b1fd35838082f7a7e83486d0203ee55df8afe739...8ca23d003f7a45650c4a49945a57166d4080f974

### AI 总结重点(源码 diff 为据)
- **`core>100` 语义从"截断到 100 继续"改为"拒绝该设备"**。nvidia/metax 的 `Fit()` 里旧逻辑把 `Coresreq` clamp 到 100 后继续尝试分配,新逻辑对 `>100 || <0` 直接 `reason[CardInsufficientCore]++; continue`(nvidia)或直接返回失败(metax)。这意味着请求超额算力不再被"悄悄降配"运行,而是调度失败——对用户是更可预期的资源契约,但也可能让原先勉强跑起来的 pod 变成 Pending。

  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -		if k.Coresreq > 100 {
  -			klog.ErrorS(nil, "core limit can't exceed 100", "pod", klog.KObj(pod), "device", dev.ID)
  -			k.Coresreq = 100
  -			//return false, tmpDevs
  +		if k.Coresreq > 100 || k.Coresreq < 0 {
  +			klog.ErrorS(nil, "core limit out of range (must be 0-100)", "pod", klog.KObj(pod), "device", dev.ID, "coresreq", k.Coresreq)
  +			reason[common.CardInsufficientCore]++
  +			continue
  		}
  ```
  </details>

- **入口层新增 count/core 范围校验,越界直接吐空请求**。各厂商 `GenerateResourceRequests` 里 device 数量 `n<=0 || n>MaxInt32`、core `<0 || >100` 均返回空 `ContainerDeviceRequest{}`;nvidia 的 `MutateAdmission` 还新增 `validateCores()` 在准入阶段就拦。防止负数/溢出的 count 进到调度器。

  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +func (dev *NvidiaGPUDevices) validateCores(ctr *corev1.Container) error {
  +	...
  +	if ok {
  +		cores, valid := qty.AsInt64()
  +		if !valid || cores < 0 || cores > 100 {
  +			return fmt.Errorf("invalid %s value %s in container %s: must be an integer between 0 and 100", ...)
  +		}
  +	}
  +	return nil
  +}
  ```
  </details>

- **scheduler 状态指标 + synced 无锁化**。新增 `collectSchedulerStateMetrics` 每次 scrape 发 `hami_scheduler_is_leader`、`hami_scheduler_cache_synced`(0/1 gauge);`Scheduler.synced` 由 `bool`(锁保护)改 `atomic.Bool`,新增 `IsSynced()` 无锁读,可安全从 Prometheus Collect 回调调用而不抢调度写锁。

  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	synced bool
  +	synced atomic.Bool
  ...
  +func (s *Scheduler) IsSynced() bool {
  +	return s.synced.Load()
  +}
  ```
  </details>

- **NVIDIA device-plugin 按 UUID 配对 per-device 限制**。`alignContainerDevicesWithAllocatedIDs` 从"按位置(annotation 顺序)配对"改为"按物理设备 UUID 匹配",修复了 kubelet 上报顺序与 annotation 顺序不一致时、把某 GPU 的 CUDA 显存限额挂到另一张卡的 bug(#2814)。未匹配上的条目才回退到旧的顺序配对。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  -	aligned := append(device.ContainerDevices(nil), devreq...)
  +	aligned := make(device.ContainerDevices, len(deviceIDs))
  +	matched := make([]bool, len(deviceIDs))
  +	used := make([]bool, len(devreq))
  +	for i, id := range deviceIDs {
  +		phys := physicalDeviceID(id)
  +		for j := range devreq {
  +			if !used[j] && physicalDeviceID(devreq[j].UUID) == phys {
  +				aligned[i] = devreq[j]; aligned[i].UUID = phys
  +				matched[i] = true; used[j] = true; break
  ```
  </details>

- **NUMA refit 的 TLS 客户端改为按需构建 + 硬失败**。`numaRefitHTTPClient` 从全局单例变量改为函数,每次 refit 重建 client,以便**轮转的 CA bundle 无需重启 device-plugin 即可生效**;`numaRefitTLSConfig` 从"读证书失败仅打日志"改为返回 error。同时修正候选池:不再把 `allowedUUIDs` 收窄到 `MustIncludeDeviceIDs`(那会让候选池小于请求设备数),改用 kubelet 的 `AvailableDeviceIDs` 全集。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/numa_refit_client.go</summary>

  ```diff
  -func numaRefitTLSConfig() *tls.Config {
  +func numaRefitTLSConfig() (*tls.Config, error) {
  ...
  -var numaRefitHTTPClient = &http.Client{...}
  +func numaRefitHTTPClient() (*http.Client, error) { ... }
  ...
  -	allowedUUIDs := allowedPhysicalDeviceIDs(req.AvailableDeviceIDs)
  -	if len(req.MustIncludeDeviceIDs) > 0 {
  -		allowedUUIDs = allowedPhysicalDeviceIDs(req.MustIncludeDeviceIDs)
  -	}
  +	allowedUUIDs := allowedPhysicalDeviceIDs(req.AvailableDeviceIDs)
  ```
  </details>

- **未识别的 GPU 调度 policy 不再被采纳**。`GetGPUSchedulerPolicyByPod` 新增 `IsValidGPUSchedulerPolicy` 校验:pod annotation 里不认识的 policy(非 binpack/spread/numa/mutex/topology)被忽略并告警,保留配置默认 policy。避免打错字的 annotation 静默改变调度行为(#2769)。

  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -			userGPUPolicy = value
  +			if IsValidGPUSchedulerPolicy(value) {
  +				userGPUPolicy = value
  +			} else {
  +				klog.Warningf("ignoring unrecognized %s=%q ... using configured policy %q", ...)
  +			}
  ```
  </details>

- **terminating pod 的 informer 重放不再丢占用**。`onAddPod`/`onUpdatePod` 对"处于 terminating 但缓存里没有"的 pod(scheduler 重启后 informer 初始 sync 会把它重放成 add)不再直接 return 丢弃,而是 fall through / 转 `onAddPod` 记账其设备占用,避免重启窗口内超卖(#2812)。

  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -		klog.V(5).InfoS("Pod is terminating but holding locks, preserving cache", ...)
  -		s.podManager.UpdatePod(pod)
  -		return
  +		if _, cached := s.podManager.GetPod(pod); cached {
  +			s.podManager.UpdatePod(pod); return
  +		}
  +		// 未缓存则 fall through,记账占用
  ```
  </details>

- **Cambricon 恢复 model-aware 调度**。`GetNodeDevices` 从节点 `Model` label 读 MLU 型号写入 `DeviceInfo.Type`(之前硬编码 `CambriconMLUDevice`),`checkType` 支持按具体型号做 use/nouse 约束匹配(#2780)。让"指定 MLU 型号"的调度约束重新生效。

  <details><summary>代码依据 pkg/device/cambricon/device.go</summary>

  ```diff
  +	mluType := strings.TrimSpace(n.Labels[MLUModelLabel])
  +	if !strings.Contains(strings.ToUpper(mluType), CambriconMLUDevice) { mluType = CambriconMLUDevice }
  ...
  -			Type:         CambriconMLUDevice,
  +			Type:         mluType,
  ```
  </details>

- **Metax 删除 customFilterRule,放开多容器分布**。移除了"强制一个 pod 的所有设备落在同一张卡"的 `customFilterRule`,让多容器 pod 能在多张独占 GPU 上铺开(#2837)。软切分之外的整卡分配策略放松。

  <details><summary>代码依据 pkg/device/metax/device.go</summary>

  ```diff
  -func (dev *MetaxDevices) customFilterRule(...) bool { ... 强制同卡 ... }
  ...
  -		if !mat.customFilterRule(allocated, request, tmpDevs[k.Type], dev) {
  -			reason[common.CardNotFoundCustomFilterRule]++; continue
  -		}
  ```
  </details>

- 其余(未逐一贴 hunk):`GetDevicePluginOptions` 的 `GetPreferredAllocationAvailable` 从硬编码 `true` 改读 `enableGetPreferredAllocation` 配置(#2845);MIG 路径 `FailRequestsGreaterThanOne` 改为指针 nil 检查防空;vGPUmonitor 在不支持利用率的 GPU 上优雅跳过指标而非报错(#2808);dashboard 指标改名 `hami_node_gpu_memory_allocated_ratio` 并对齐 0–1 标度(#2840);新增 hami-scheduler 的 PodDisruptionBudget(#2773);升级 go 1.27(#2851)。大量 `*_test.go` 新增/改动(cambricon/nvidia/metax/scheduler 等),测试覆盖显著补齐。

### 后续发展方向 [AI]
- **资源契约从"宽容纠偏"转向"严格拒绝"是本期主线**,横跨 8+ 厂商设备。证据覆盖 nvidia/metax/cambricon 的 Fit 与 GenerateResourceRequests;未见对已有集群的迁移开关(即无 feature-gate 兜底),存量依赖"超额 core 被 clamp 仍能跑"的 workload 升级后可能转 Pending,值得盯 release note 是否补说明。
- **可观测性在向"可告警"补齐**:leader/cache_synced 指标 + synced 无锁化,配合上期已见的 leader election,方向是把 scheduler HA 状态做成一等可监控信号。证据只覆盖 metrics.go/scheduler.go 两处,未见对应 Grafana/告警规则是否同步进 chart。
- **多加速器厂商适配持续横向铺开且趋于"对齐同一套校验/调度骨架"**(count/core 校验、model-aware、mutex policy 在各厂商 device.go 里同构化)。证据是各厂商 device.go 的改动高度雷同;未逐 PR 展开确认是否有统一抽象层重构计划。

## Project-HAMi/HAMi-core: b216ba1b -> de6ce39d
- 比较 b216ba1be1b8e21488d1c7370ed3357b3049aad1 -> de6ce39d | ahead=3 | files=5 | Release: —
- 比较页 https://github.com/Project-HAMi/HAMi-core/compare/b216ba1be1b8e21488d1c7370ed3357b3049aad1...de6ce39dc36246d4161e931ae2fd93929e676e55

### AI 总结重点(源码 diff 为据)
- **移除废弃的 unified_lock 全局文件锁**。从 `utils.c` 删掉 `try_lock_unified_lock`/`try_unlock_unified_lock` 及 `/tmp/vgpulock/lock` 的 `flock(LOCK_EX)` 逻辑。说明 HAMi-core 的多进程显存/算力协调已不再依赖这把跨进程文件锁(此前多进程限额走 `multiprocess_memory_limit.c` 的共享内存区),死代码清理降低隔离内核的锁竞争面。

  <details><summary>代码依据 src/utils.c</summary>

  ```diff
  -const char* unified_lock="/tmp/vgpulock/lock";
  -static int lock_fd = -1;
  -int try_lock_unified_lock() { ... flock(lock_fd, LOCK_EX) ... }
  -int try_unlock_unified_lock() { ... flock(lock_fd, LOCK_UN) ... }
  ```
  </details>

- **PID 发现/合并逻辑对外声明化 + 补单测**。`nvmlProcessInfo_t1` 结构体定义从 `nvml_override.h` 迁到 `utils.h`,并在头文件公开 `mergepid`/`getextrapid` 声明;新增 `test/test_pid_discovery.c` 专测 `getextrapid` 的下溢处理(prev>current 应返回 0,防无符号下溢)与 `mergepid` 去重合并。这是给"设备上进程列表合并"这条 NVML 拦截路径加防回归网。

  <details><summary>代码依据 src/include/utils.h + test/test_pid_discovery.c</summary>

  ```diff
  -int try_lock_unified_lock();
  -int try_unlock_unified_lock();
  +typedef struct nvmlProcessInfo_st1 { unsigned int pid; unsigned long long usedGpuMemory; } nvmlProcessInfo_t1;
  +int mergepid(unsigned int *prev, unsigned int *current, nvmlProcessInfo_t1 *sub, nvmlProcessInfo_t1 *merged);
  +int getextrapid(unsigned int prev, unsigned int current, nvmlProcessInfo_t1 *pre_pids_on_device, nvmlProcessInfo_t1 *pids_on_device);
  ```
  ```c
  +void test_getextrapid_underflow() {
  +    ... int extra = getextrapid(3, 1, pre, cur);
  +    ASSERT_EQ(extra, 0); // underflow should be handled and return 0
  ```
  </details>

### 后续发展方向 [AI]
- 内核层本期是**清理 + 测试硬化**,无新 hook 类型或隔离能力扩展。证据仅覆盖 utils.c/头文件/测试;`nvml_override.h`、`libcuda_hook` 的拦截面本期未动,未见新增 NVML/CUDA 拦截入口。
- unified_lock 的移除暗示多进程协调已收敛到共享内存区实现,后续可留意 `multiprocess_memory_limit.c` 是否成为唯一同步点(潜在争用热点)。此判断仅基于本次删除的锁不再被引用,未读共享内存区当前实现。

## 本期无实质改动(折叠)
<details><summary>EMPTY(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=8ca23d003f7a45650c4a49945a57166d4080f974 branch=master release=v2.10.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=de6ce39dc36246d4161e931ae2fd93929e676e55 branch=main release=— scanned=2026-08-28 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-28 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-08-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-28 -->
