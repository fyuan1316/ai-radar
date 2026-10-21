# HAMi diff 雷达 2026-10-22

## 摘要
- **HAMi 主仓给 whole-GPU 监控补齐 MIG 实例级利用率**(PR #3270):NVML 无法在 MIG GPU-instance 粒度报利用率,新增嵌入式 DCGM 采集器(`pkg/monitor/nvidia/wholegpu_dcgm.go`),懒启动 host engine、读 `DCGM_FI_PROF_GR_ENGINE_UTIL_RATIO`;`DeviceSmUtil` 对 MIG 句柄改走 DCGM。配套新增只读诊断命令 `vGPUmonitor dry-run whole-gpu` 与 Dockerfile 里的 DCGM 4.5.0 运行时安装层。这是软切分之外、对"整卡+MIG"场景的可观测性补强。
- **HAMi-core 修软切分 SM 限流的两处公平性/联动缺陷**:(1) 限流补充步长从 `sm_num²×…` 改为"初始桶大小的固定比例"(issue #348),让大卡/桶翻倍场景下步长不再失真;(2) `rate_limiter` 现在即便利用率开关关闭也用 CAS 发布 `recent_kernel=2`,否则 vGPUmonitor 永远无法把开关再打开(issue #350)。两处都直接影响时分复用的算力配比正确性。
- **HAMi [弃用/移除] `hami_container_device_memory_bytes` 指标进入弃用窗口**(PR #3273):v2.11.0 弃用、v2.12.0 移除,改用 `hami_vgpu_memory_used_bytes`。接 HAMi vGPU metrics 的下游面板需提前迁移。

## 当日重要改变
- Project-HAMi/HAMi [新能力] whole-GPU 监控新增 MIG 实例级利用率采集:`DeviceSmUtil` 对 `IsMigDeviceHandle()` 为真的设备不再走 NVML `GetUtilizationRates`,改用嵌入式 DCGM(`DCGM_FI_PROF_GR_ENGINE_UTIL_RATIO`,FE_GPU_I 粒度),并新增 `wholegpu_dcgm.go` 懒启动 host engine、`wholegpu_dryrun.go` 只读诊断。证据:pkg/monitor/nvidia/wholegpu.go、pkg/monitor/nvidia/wholegpu_dcgm.go、cmd/vGPUmonitor/wholegpu_dryrun.go、docker/Dockerfile,PR https://github.com/Project-HAMi/HAMi/pull/3270
- Project-HAMi/HAMi [弃用/移除] 指标 `hami_container_device_memory_bytes` v2.11.0 弃用、v2.12.0 移除,下游改用 `hami_vgpu_memory_used_bytes`。证据:skill/hami-vgpu-metrics-summary/SKILL.md,PR https://github.com/Project-HAMi/HAMi/pull/3273

## Project-HAMi/HAMi: 228a3313 -> a80a7ae6
- 比较 https://github.com/Project-HAMi/HAMi/compare/228a331334aca19395e54e5f44980755212a266c...a80a7ae65d20a2df8f74cdd4ddf35ae1e883177a | ahead=6 | files=24 | 最新 Release v2.10.0

### AI 总结重点(源码 diff 为据)
- **MIG 设备利用率改由 DCGM 采集,NVML 仅管整卡**:`wholeGPUUsage` 结构体新增 `dcgm *dcgmWholeGPUCollector` 字段;`DeviceSmUtil(idx)` 原来无条件 `handle.GetUtilizationRates()`,现先判 `handle.IsMigDeviceHandle()`,为 MIG 则取 `GetGpuInstanceId()` + 父卡 UUID,交给 `u.dcgm.GpuInstanceSmUtil(parentUUID, giID, uuid)`;`u.dcgm == nil` 时返回 0(无 DCGM 时优雅退化,不再误报整卡利用率)。
  <details><summary>代码依据 pkg/monitor/nvidia/wholegpu.go</summary>

  ```diff
   type wholeGPUUsage struct {
   	nvmllib nvml.Interface
  +	dcgm    *dcgmWholeGPUCollector
   	uuids   []string
   }
  ...
  +	isMig, ret := handle.IsMigDeviceHandle()
  +	if errors.Is(ret, nvml.SUCCESS) && isMig {
  +		if u.dcgm == nil {
  +			return 0
  +		}
  +		giID, ret := handle.GetGpuInstanceId()
  +		...
  +		parentUUID, ret := parentHandle.GetUUID()
  +		...
  +		return u.dcgm.GpuInstanceSmUtil(parentUUID, uint(giID), u.uuids[idx])
  +	}
   	rates, ret := handle.GetUtilizationRates()
  ```
  </details>
- **新增嵌入式 DCGM 采集器,避免外挂 nv-hostengine / dcgm-exporter sidecar**:`dcgmWholeGPUCollector` 在首个 MIG 容器真正取利用率时才懒启动内嵌 host engine(`initialized`/`initErr` + mutex),字段采样周期 `dcgmFieldUpdateInterval = 30s`,`dcgmInitRetryInterval = 30s` 限制失败重试频率以免"永远返 0";利用率字段只取 `DCGM_FI_PROF_GR_ENGINE_UTIL_RATIO`(注释说明 `DCGM_FI_DEV_GPU_UTIL` 仅整卡粒度,不适配 MIG)。接口 `dcgmLatestValuesQuerier` / `dcgmHierarchyQuerier` 做了可注入 fake 的抽象,便于无 libdcgm 单测。
  <details><summary>代码依据 pkg/monitor/nvidia/wholegpu_dcgm.go</summary>

  ```diff
  +const dcgmFieldUpdateInterval = 30 * time.Second
  +const dcgmInitRetryInterval = 30 * time.Second
  +var migProfUtilFields = []dcgm.Short{dcgm.DCGM_FI_PROF_GR_ENGINE_UTIL_RATIO}
  +type dcgmWholeGPUCollector struct {
  +	mu          sync.Mutex
  +	initialized bool
  +	initErr     error
  ```
  </details>
- **新增只读诊断子命令 `vGPUmonitor dry-run whole-gpu`**:列出调度到 `NODE_NAME` 的 Pod、读其 NVIDIA 分配注解与节点设备注册表、采样 NVML,但**不启动监控、不碰 libvgpu cache 文件、不下发反馈控制**;支持 `--namespace/--pod/--container` 精确过滤。定位是上线前/排障时的无副作用巡检入口。
  <details><summary>代码依据 cmd/vGPUmonitor/wholegpu_dryrun.go</summary>

  ```diff
  +	command := &cobra.Command{
  +		Use:   "whole-gpu",
  +		Short: "Inspect whole-GPU allocations and sample NVML metrics without starting the monitor",
  +		Long: "Lists Pods scheduled on NODE_NAME and reads their NVIDIA allocation annotations and node device registry. " +
  +			"It only sends Kubernetes GET/LIST requests and reads NVML; it does not start the monitor, access libvgpu cache files, or apply feedback controls.",
  +	command.Flags().StringVar(&options.Namespace, "namespace", "", "Only inspect Pods in this namespace")
  ```
  </details>
- **镜像引入 DCGM 运行时层(libdcgm.so.4 + 分析模块)**:Dockerfile 新增 `FROM debian:bookworm-slim AS dcgm` 阶段,按架构(amd64→x86_64 / arm64→sbsa)拉 `datacenter-gpu-manager-4-core` 与 `-proprietary`(提供 `libdcgmmoduleprofiling.so.4`,MIG 的 `DCGM_FI_PROF_GR_ENGINE_UTIL_RATIO` 必需)4.5.0 deb,校验 SHA256 后 `COPY --from=dcgm` 进运行镜像并 `ldconfig`;基础镜像从 cuda:13.4.2 升到 13.4.3。即 MIG 监控依赖 DCGM 分析模块在镜像内就绪。
  <details><summary>代码依据 docker/Dockerfile</summary>

  ```diff
  +FROM debian:bookworm-slim AS dcgm
  +ARG DCGM_DEB=v4.5.0-1
  ...
  -FROM nvidia/cuda:13.4.2-base-ubuntu22.04@sha256:5d8ec7...
  +FROM nvidia/cuda:13.4.3-base-ubuntu22.04@sha256:7416c5...
  +COPY --from=dcgm /out/ /
  +RUN ldconfig
  ```
  </details>
- **`hami_container_device_memory_bytes` 指标标记弃用/移除时间表**:SKILL.md 文档把该指标标注"v2.11.0 弃用、v2.12.0 移除,改用 `hami_vgpu_memory_used_bytes`"。属对外指标契约收敛信号(仅文档层,未见代码里加 deprecation 告警)。
  <details><summary>代码依据 skill/hami-vgpu-metrics-summary/SKILL.md</summary>

  ```diff
  -- `hami_container_device_memory_bytes` — container device memory usage
  +- `hami_container_device_memory_bytes` — container device memory usage (deprecated in v2.11.0, removed in v2.12.0; use `hami_vgpu_memory_used_bytes` instead)
  ```
  </details>
- **chart 为 lupine(RemoteGPU)服务器开放 `securityContext`**:`charts/hami/values.yaml` 新增 `securityContext: {}` 并注明:当宿主 NVIDIA container toolkit 设了 `accept-nvidia-visible-devices-envvar-when-unprivileged=false` 时需 `privileged: true`,否则 `NVIDIA_VISIBLE_DEVICES` 被忽略、服务器看不到 GPU。补齐昨天 RemoteGPU 节点选择能力后的部署可配性。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  +      # -- Container securityContext of the lupine server. Set `privileged: true` on hosts where the
  +      # NVIDIA container toolkit has accept-nvidia-visible-devices-envvar-when-unprivileged=false,
  +      # otherwise NVIDIA_VISIBLE_DEVICES is ignored and the server sees no GPU.
  +      securityContext: {}
  ```
  </details>

### 后续发展方向 [AI]
- MIG 监控落地后,HAMi 的"整卡/MIG/hami-core 时分/MPS/remote"五种 operatingmode 在 vGPUmonitor 侧的利用率口径趋于统一(证据:wholegpu.go 的 MIG 分支 + device.go 把 `WholeGPUUsedCores=100` 注释为设备插件与监控共用的 whole-GPU 标记)。证据只覆盖监控读取路径,未见调度/分配侧对 MIG 的新处理。
- DCGM 以嵌入式 host engine 内置进监控镜像(非 sidecar),是明显的"少一个外部依赖"取向;但引入了对 NVIDIA `-proprietary` 分析模块 deb 的镜像内分发(含 SHA256 校验与可留空跳过)。证据只覆盖 Dockerfile 与采集器初始化,未见对非 MIG 整卡是否也走 DCGM 的改动(当前整卡仍走 NVML)。

## Project-HAMi/HAMi-core: 3f6134c1 -> fe985a14
- 比较 https://github.com/Project-HAMi/HAMi-core/compare/3f6134c14946b46459a0808e0366e97541ed102a...fe985a147eecfb0b08b2d02a3483d967a6965818 | ahead=8 | files=6 | 最新 Release —

### AI 总结重点(源码 diff 为据)
- **SM 限流补充步长改为"初始桶大小的固定比例"(issue #348)**:`delta()` 原公式 `increment = sm_num² × max_thread_per_sm × utilization_diff / 2560`,会随 SM 数量平方增长、且桶被翻倍(超大 kernel)时步长也放大;新公式 `increment = g_base_cuda_cores[device_id] × utilization_diff / 1024`,对 20/80/188 SM 卡给出同一比例的步长,在 80 SM 卡上与旧公式等值。新增全局 `g_base_cuda_cores[]` 在 `setspec()` 里记录初始桶大小(`g_total_cuda_cores` 后续可能被翻倍,故另存基准)。这是时分算力配比在不同规格卡/超大 kernel 下保持一致的修正。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c</summary>

  ```diff
  -  int64_t increment =
  -      (int64_t)g_sm_num[device_id] * (int64_t)g_sm_num[device_id] *
  -      (int64_t)g_max_thread_per_sm[device_id] * (int64_t)utilization_diff / 2560;
  +  /* A fixed fraction of the initial bucket, so the step does not grow with the
  +   * SM count or when the bucket is doubled. Equal to the former sm_num^2 form
  +   * on an 80 SM device. */
  +  int64_t increment = g_base_cuda_cores[device_id] * (int64_t)utilization_diff / 1024;
  ...
  +        g_base_cuda_cores[dev] = g_total_cuda_cores[dev];
  ```
  </details>
- **利用率开关关闭时也发布 `recent_kernel`,否则无法被重新打开(issue #350)**:`rate_limiter()` 原逻辑在 `cached_util_switch == 0` 时直接 `return`,再 `set_recent_kernel(2)`;现调整为**先用 CAS 循环把 `recent_kernel` 置 2**(并发的 -1 不被覆盖),**再**判开关是否关闭。另在等待 token(`before_cuda_cores < 0`)期间也持续 `cas_recent_kernel(rk, 2)` 刷新,避免 vGPUmonitor 在等待中把 `recent_kernel` 衰减到 0。新增 `cas_recent_kernel(expected, desired)`(基于 `atomic_compare_exchange_strong`)并导出到头文件。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c + multiprocess_memory_limit.c</summary>

  ```diff
  -  if (cached_util_switch == 0) {
  -      return;
  +  for (;;) {
  +      int rk = get_recent_kernel();
  +      if (rk < 0) { sleep(1); continue; }
  +      if (rk == 2 || cas_recent_kernel(rk, 2)) break;
   }
  -  while (get_recent_kernel()<0) { sleep(1); }
  -  set_recent_kernel(2);
  +  if (cached_util_switch == 0) {
  +      return;
  +  }
  ...
  +int cas_recent_kernel(int expected, int desired) {
  +    return atomic_compare_exchange_strong(&region_info.shared_region->recent_kernel,
  +                                          &expected, desired);
  +}
  ```
  </details>
- **补了两个无需 GPU 的回归测试**:`test_sm_limiter_step.c`(验证 20/80/188 SM 卡步长同比例、80 SM 与旧公式等值、桶翻倍后步长不变)与 `test_rate_limiter_recent_kernel.c`(验证开关关闭仍置 `recent_kernel=2`、负值期间等待),均通过 `#include` 被测 .c 源文件以触达其 static 状态、桩掉 driver 与共享内存。说明这两处行为被固化为 CI 不回退项。
  <details><summary>代码依据 test/CMakeLists.txt</summary>

  ```diff
  +# rate_limiter must publish recent_kernel even with the utilization switch
  +# off, or vGPUmonitor can never switch it back on (issue #350).
  +add_test(NAME rate_limiter_recent_kernel COMMAND test_rate_limiter_recent_kernel)
  ...
  +# The SM limiter refill step must be the same fraction of the bucket on every
  +# device (issue #348).
  +add_test(NAME sm_limiter_step COMMAND test_sm_limiter_step)
  ```
  </details>
- *(证据边界)* 本期另有 commit "fix: parse CUDA_DEVICE_MEMORY_LIMIT suffixes and refuse malformed values",但 helper 捕获的 `multiprocess_memory_limit.c` hunk 仅含 `cas_recent_kernel`(+5),未见显存限额后缀解析的 diff,故不做符号级研判——如需核实看比较链接。

### 后续发展方向 [AI]
- HAMi-core 本期全是软隔离核心(SM 时分限流 + recent_kernel 联动)的正确性收敛,而非新能力:步长与设备规格解耦、限流与 vGPUmonitor 开关的双向联动闭合。方向是把"大卡/超大 kernel/开关切换"等边界场景的算力配比做稳。证据只覆盖 utilization_watcher 与 recent_kernel 读写路径,未见显存隔离(memory_limit)侧的功能性改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=a80a7ae65d20a2df8f74cdd4ddf35ae1e883177a branch=master release=v2.10.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=fe985a147eecfb0b08b2d02a3483d967a6965818 branch=main release=— scanned=2026-10-22 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-22 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=cfb45bc037af17bf50834ecf885e720684ec8cea branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-22 -->
