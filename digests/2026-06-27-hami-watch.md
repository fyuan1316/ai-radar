# HAMi diff 雷达 2026-06-27

## 摘要
- **ascend-device-plugin 落地 vNPU 可观测闭环**:新增独立 `internal/monitor/` 包(DCMI 进程级显存采集 + 容器级 Prometheus exporter),通过读 hami-vnpu-core 共享内存把"软切分到每容器的 vNPU 用量"暴露成指标,并自带 ServiceMonitor/PrometheusRule。这是 HAMi×昇腾交汇点本期最实质的能力推进(PR #87)。
- **HAMi 主仓本期无 API/CRD 改动**,只有调度器内部重构(删 `cachedstatus` 字段)、一处 metrics 数据竞争修复(`InspectAllNodesUsage` 改为深拷贝快照)和配额负值钳零;其余 11 个提交是文档勘误/roadmap 勾选(MIG、AMD、Biren166M 标记为已支持)。
- HAMi-core、volcano-vgpu-device-plugin 本期 EMPTY。

## 当日重要改变
- **Project-HAMi/ascend-device-plugin** `[新能力]` 新增顶层 package `internal/monitor/`(container.go/collector.go/registry.go/dsmi.go/metrics.go,共 ~560 行),把昇腾 vNPU 的主机级+容器级用量做成 Prometheus 指标。证据:`internal/monitor/collector.go`、`internal/server/allocate.go`。https://github.com/Project-HAMi/ascend-device-plugin/commit/7ca13d87862d1adeaa93c9d63d1652e0b8f79b6b

## Project-HAMi/ascend-device-plugin: 799eaa34 -> b7508b9f
- 比较:`799eaa34 -> b7508b9f` | ahead=4 | files=12 | Release: —
- https://github.com/Project-HAMi/ascend-device-plugin/compare/799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b...b7508b9f5030f89a98b872f6ee92d595f2102b89

### AI 总结重点(源码 diff 为据)
- **新增 `vNPUCollector`(internal/monitor/collector.go),把昇腾软切分用量做成两层 Prometheus 指标**:主机级 `hami_host_gpu_memory_used_bytes` / `hami_host_gpu_utilization_ratio`(标签 device_index/uuid/type),容器级 `hami_vgpu_memory_used_bytes` / `hami_vgpu_memory_limit_bytes` / `hami_container_device_utilization_ratio`(标签 namespace/pod/container/vdevice_index/uuid)。即"每容器 vNPU 用量/限额/利用率"首次可观测。
  <details><summary>代码依据 internal/monitor/collector.go</summary>

  ```diff
  +	ctrvGPUdesc = prometheus.NewDesc(
  +		"hami_vgpu_memory_used_bytes",
  +		"vGPU device memory usage in bytes",
  +		[]string{"namespace", "pod", "container", "vdevice_index", "device_uuid"}, nil,
  +	)
  +	ctrvGPUlimitdesc = prometheus.NewDesc(
  +		"hami_vgpu_memory_limit_bytes", ... )
  ```
  </details>
- **容器级数据来自共享内存,而非 DCMI**:`registry.go` 定义 `ShmemReader`,用 `syscall.Mmap` 只读映射每容器 shmem 文件,按 `#[repr(C)]` 偏移量(MemUsed=8、procs 数组起始 1080、每 slot 80 字节、HBM 8 设备)解析。注释明示该布局"matching Rust struct in crates/limiter/src/shmem/mod.rs",即直接对齐 HAMi-core 限流器的内存布局——读数路径与软隔离内核强耦合。
  <details><summary>代码依据 internal/monitor/registry.go</summary>

  ```diff
  +// LocalContainerShmem layout matching Rust #[repr(C)] struct in crates/limiter/src/shmem/mod.rs.
  +const (
  +	localShmMemUsedOffset       = 8
  +	procSlotSize      = 80
  +	procSlotHBMOffset = 8 // [AtomicU64; NPU_DEVICE_MAX=8]
  +	localShmProcsOffset = 1080 // 56 + 32*32
  +)
  +func (r *ShmemReader) ReadMemoryByDevice() [hbmDevices]uint64 { ... }
  ```
  </details>
- **主机级数据走 DCMI(dsmi.go)**:封装 `dcmi.DcManager`,`collectHostDeviceStats` 遍历 logicID 取 `DcGetMemoryInfo`(总量-可用=已用)与 `DcGetDeviceUtilizationRate(AICore)`,单例 `sync.Once` 初始化。
  <details><summary>代码依据 internal/monitor/dsmi.go</summary>

  ```diff
  +		if memInfo, err := mgr.DcGetMemoryInfo(cardID, deviceID); err == nil {
  +			memTotal = memInfo.MemorySize
  +			memUsed = memInfo.MemorySize - memInfo.MemoryAvailable
  +		}
  +		if rate, err := mgr.DcGetDeviceUtilizationRate(cardID, deviceID, common.AICore); err == nil {
  ```
  </details>
- **allocate.go 为每容器创建独立 local shmem 目录并挂进容器**:仿 NVIDIA vgpu 的 `containers/{podUID}_{ctrName}` 布局,在 `hostHookPath`(默认 `/usr/local/hami-vnpu-core`,可由 `HOOK_PATH` 覆盖)下建目录,挂到容器内 `/hami-vnpu-shmem`,并注入 `NPU_LOCAL_SHM_PATH` 环境变量。为此 `popNextContainerDevices` 改签名,新增返回容器名(init 容器在前、常规容器在后)。
  <details><summary>代码依据 internal/server/allocate.go</summary>

  ```diff
  +		containerShmemDir := fmt.Sprintf("%s/containers/%s_%s", hostHookPath, pod.UID, ctrName)
  +		resp.Mounts = append(resp.Mounts, &v1beta1.Mount{
  +			HostPath: containerShmemDir, ContainerPath: "/hami-vnpu-shmem", ReadOnly: false })
  +		resp.Envs["NPU_LOCAL_SHM_PATH"] = "/hami-vnpu-shmem/vnpu_local_shmem"
  -func (ps *PluginServer) popNextContainerDevices(podSingleDev device.PodSingleDevice) (device.ContainerDevices, error) {
  +func (ps *PluginServer) popNextContainerDevices(pod *v1.Pod, podSingleDev device.PodSingleDevice) (device.ContainerDevices, string, error) {
  ```
  </details>
- **配套交付 ServiceMonitor + PrometheusRule(ascend-vnpu-monitor-integration.yaml)**:把 `hami_host_gpu_*` / `hami_vgpu_*` 经 recording rule 改名成 `kantaloupe_gpu_*` / `kantaloupe_workload_*`,注释直说"Kantaloupe discovers ServiceMonitors labeled release=prometheus"——指向商业控制台 Kantaloupe 的仪表盘兼容层。
  <details><summary>代码依据 ascend-vnpu-monitor-integration.yaml</summary>

  ```diff
  +        - record: kantaloupe_workload_gpumem_used
  +          expr: |
  +            label_replace(hami_vgpu_memory_used_bytes / 1024 / 1024, "UUID", "$1", "device_uuid", "(.*)")
  ```
  </details>
- 配套:Dockerfile 弃用 `longsleep/golang-backports` PPA,改装官方 Go toolchain(`GO_VERSION=1.24.6`,理由是 PPA 依赖 Launchpad、CI 在 arm64 仿真腿上易 flake)。

### 后续发展方向 [AI]
- HAMi 的昇腾路线正在补齐"软切分 → 可观测"的最后一段:此前 vNPU 只有调度/分配,本期把"每容器 HBM 用量+利用率"打通到 Prometheus,且指标命名直接向商业控制台 Kantaloupe 对齐(recording rule 改名为 `kantaloupe_*`)。说明 HAMi 把"软切分调度 + per-container 设备指标"这条护城河从 NVIDIA 复制到昇腾,且可观测层被设计成商业版的接入点。
- 证据边界:仅看了 diff。指标读数路径(shmem 偏移量)硬编码对齐 HAMi-core Rust 限流器布局,但本期 HAMi-core 仓 EMPTY,无法确认两侧版本是否已同步发版;`kantaloupe_*` recording rule 暗示商业控制台依赖,但未见控制台侧代码佐证。

## Project-HAMi/HAMi: 5f06e0ab -> 6d2d19a5
- 比较:`5f06e0ab -> 6d2d19a5` | ahead=15 | files=15 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/5f06e0abbb5ab27ec86ac0fe144e8cab1125a477...6d2d19a5dc0d76fe88bceb3c280a94af597f9091

### AI 总结重点(源码 diff 为据)
- **调度器删除 `cachedstatus` 字段,统一只保留 `overviewstatus`**:`Scheduler` 结构体移除 `cachedstatus map[string]*NodeUsage`,`register()` 改为从 `getNodesUsage` 取第二返回值 `overallnodeMap` 赋给 `s.overviewstatus`(getNodesUsage 签名也从 3 返回值扩到 4),`cleanupNodeUsage` 不再清 cachedstatus。即"filter 缓存"与"overview 缓存"两套状态合并为一套。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	//Node status returned by filter
  -	cachedstatus map[string]*NodeUsage
   	//Node Overview
   	overviewstatus map[string]*NodeUsage
  ...
  -	_, _, err = s.getNodesUsage(&nodeNames, nil)
  +	_, overallnodeMap, _, err := s.getNodesUsage(&nodeNames, nil)
  +	s.overviewstatus = *overallnodeMap
  ```
  </details>
- **`InspectAllNodesUsage`(metrics monitor 调用)修数据竞争**:从直接返回 `&s.overviewstatus` 改为在 `RLock` 下逐节点 `DeepCopy()` 出快照返回,避免 metrics 采集与调度写入并发读同一 map。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -	return &s.overviewstatus
  +	s.lock.RLock()
  +	defer s.lock.RUnlock()
  +	snapshot := make(map[string]*NodeUsage, len(s.overviewstatus))
  +	for nodeID, usage := range s.overviewstatus {
  +		snapshot[nodeID] = usage.DeepCopy()
  +	}
  +	return &snapshot
  ```
  </details>
- **配额回收钳零(pkg/device/quota.go)**:`RmUsage` 在 `qInfo.Used -= val` 后,若结果 <0 则钳回 0,防止负数累积污染配额跟踪。同时 `PodManager.GetPod` 把 `Lock` 降为 `RLock`(读路径降锁)。
  <details><summary>代码依据 pkg/device/quota.go</summary>

  ```diff
   			qInfo.Used -= val
  +			if qInfo.Used < 0 {
  +				qInfo.Used = 0
  +			}
  ```
  </details>
- 文档侧(非代码能力):roadmap.md 把 MIG、AMD GPU 从未支持勾为已支持([x]),Biren 从 "Model 110 / In progress" 改为 "Biren166M / 显存+算力隔离 ✅";protocol.md 把调度决策注解键改名(`hami.io/devices-to-allocate` → `hami.io/{device-type}-devices-to-allocate`,`device-node` → `vgpu-node`,`device-schedule-time` → `vgpu-time`)。注:仅文档,未在本期代码 diff 中见到对应实现改动。

### 后续发展方向 [AI]
- 主仓本期是稳定性收尾(并发降锁、数据竞争、配额钳零)而非新能力,`cachedstatus`/`overviewstatus` 双缓存合一会简化后续 metrics/overview 路径。protocol.md 注解键改名若属实(待代码侧确认)是协议层调整,可能影响依赖旧 `hami.io/device-node` 注解的外部集成。
- 证据边界:仅看了 diff;protocol.md 注解键改名未在本期任何 .go 文件 diff 中找到对应实现,无法判断是文档先行还是历史已改、本期仅补文档。

## 本期无实质改动(折叠)
<details><summary>HAMi-core / volcano-vgpu-device-plugin 无新提交;HAMi-WebUI 仅 CI/构建+测试修复(下列)</summary>

- Project-HAMi/HAMi-core: 0831874b -> 0831874b | 无新提交
- Project-HAMi/volcano-vgpu-device-plugin: 6561f1c1 -> 6561f1c1 | 无新提交
- Project-HAMi/HAMi-WebUI: 30c3ce14 -> 8f42445d | ahead=12,但实质均为 CI/构建治理:新增 PR Go/Frontend 检查工作流、CI 增发镜像到 GHCR(含 :latest)、Helm chart 发布现额外推 OCI 到 ghcr.io/{owner}/charts;代码仅两处 bugfix——`server/internal/provider/util/util.go` 修 MLU 解码 `Sprintf("%s_%s", str, instance, nodeName)` 多传一参,以及 BFF 单测/ESLint(Vue 3.3 宏)修复。无 API/CRD 改动。Release: hami-webui-1.2.0
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=6d2d19a5dc0d76fe88bceb3c280a94af597f9091 branch=master release=v2.9.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0831874bce5af56cefca7093dfb2f9f95d1970aa branch=main release=— scanned=2026-06-27 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-27 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=b7508b9f5030f89a98b872f6ee92d595f2102b89 branch=main release=— scanned=2026-06-27 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=8f42445d325736655d467842cb762b75f2612d25 branch=main release=hami-webui-1.2.0 scanned=2026-06-27 -->
