# HAMi diff 雷达 2026-09-16

## 摘要
- **HAMi 主仓落地全新独立后端 `pkg/device/remotegpu`(lupine remote-gpu):把"远端节点上的物理 GPU 经网络服务给无卡节点的 Pod"做成一等调度后端**——这是 HAMi 首次把"GPU 池化/解耦(disaggregation)"从 vGPU 时分切分扩展到跨节点网络挂载,方向意义大于当日代码量(PR #3004)。
- HAMi-core 修复利用率采集的 NVML/CUDA 索引错配(issue #318):`nvmlDeviceGetHandleByIndex` 传错索引,当 `CUDA_VISIBLE_DEVICES` 非恒等映射时统计到错卡,补 GPU-free 回归测试(PR #330)。
- volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI 三仓无实质改动。

## 当日重要改变
- **Project-HAMi/HAMi [新能力]** 新增顶层子包 `pkg/device/remotegpu/`(pool.go/device.go/inspect.go/config.go),注册新设备类型 `RemoteGPU`,支持把 lupine 服务的远端 GPU 调度给 GPU-less 客户端 Pod。https://github.com/Project-HAMi/HAMi/pull/3004
- **Project-HAMi/HAMi [架构方向]** nvidia 后端新增 `RemoteMode = "remote"` 常量并在 `GetNodeDevices` 主动过滤掉本节点"对外出租"的卡,避免同一物理 GPU 被本地调度器与 remote 池双重分配。https://github.com/Project-HAMi/HAMi/commit/a7e3ffd66891d0fddfc5e331572cab3375c6bf3e
- **Project-HAMi/HAMi-core [Bug 修复]** 利用率 watcher 索引错配修复(NVML index vs CUDA index),影响多卡+非恒等 `CUDA_VISIBLE_DEVICES` 下的显存/算力记账准确性。https://github.com/Project-HAMi/HAMi-core/issues/318

## Project-HAMi/HAMi: 6c17a8f9 -> a7e3ffd6
- 比较: 6c17a8f9 -> a7e3ffd6 | ahead=7(5 条 dep bump 已滤)| files=26 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **新增 remote-gpu 后端:GPU 与运行 Pod 的节点解耦,靠标签 `hami.io/lupine-server`(值=lupine 监听端口,空则用 `DefaultLupinePort=14833`)发现"出租节点",无卡客户端节点经 `LUPINE_SERVER` 环境变量访问远端卡。**关键在于它复用 stock NVIDIA device plugin 已发布的 `hami.io/node-nvidia-register` 注解读取卡信息——**出租节点无需任何 HAMi 侧的节点组件**,纯调度器侧逻辑。
  <details><summary>代码依据 pkg/device/remotegpu/pool.go / device.go</summary>

  ```diff
  +	// LupineServerLabel marks a GPU node as serving its GPUs through lupine.
  +	LupineServerLabel = "hami.io/lupine-server"
  +	// nvidiaRegisterAnnos is where the stock HAMi NVIDIA device plugin already
  +	// publishes a node's GPUs. A lupine node runs that plugin unchanged, so the
  +	// pool needs no node-side component of its own.
  +	nvidiaRegisterAnnos = "hami.io/node-nvidia-register"
  +	// DefaultLupinePort is lupine's listen port ...
  +	DefaultLupinePort = 14833
  +	lupineServerEnv     = "LUPINE_SERVER"
  ```
  </details>

- **调度握手用一组新注解走 downward API 把"放到哪台 lupine server"注入客户端容器**:`hami.io/remote-gpu-devices-to-allocate` / `-allocated` / `hami.io/lupine-endpoint`。注释点明动因:客户端节点没有 device plugin,无法在 Allocate 时注入,只能靠调度器决策 + downward API 传递。
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
  +	RemoteGPUDevice     = "RemoteGPU"
  +	HandshakeAnnos = "hami.io/node-handshake-remote-gpu"
  +	InRequestAnnos = "hami.io/remote-gpu-devices-to-allocate"
  +	AllocatedAnnos = "hami.io/remote-gpu-devices-allocated"
  +	// LupineServerAnno carries the scheduler's placement decision to the
  +	// client container through the downward API. There is no device plugin on
  +	// a GPU-less client node to inject it at Allocate time.
  +	LupineServerAnno = "hami.io/lupine-endpoint"
  ```
  </details>

- **nvidia 后端加防重分配保护**:新增 `RemoteMode = "remote"`,`GetNodeDevices` 遍历节点注册的卡时跳过 mode 为 remote 的设备;若过滤后为空,返回 `nil, nil`(零设备而非 error)——注释解释这是为了让 `Scheduler.register` 能正确 prune 掉已切换为"出租"节点的陈旧缓存(error 会跳过 prune,导致节点仍在广告本地卡)。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +	// RemoteMode marks a GPU this node serves over the network through lupine
  +	// rather than to pods of its own. The remote-gpu backend hands such a card
  +	// out cluster wide, so this backend must leave it alone.
  +	RemoteMode = "remote"
  ...
  +	for _, nodedevice := range nodedevices {
  +		if nodedevice == nil || nodedevice.Mode == RemoteMode {
  +			continue
  +		}
  +		local = append(local, nodedevice)
  +	}
  +	if len(local) == 0 {
  +		return nil, nil  // 零设备而非 error,让 register 正确 prune 陈旧缓存
  +	}
  ```
  </details>

- **remote 池是集群级共享而非节点级**:pool 被"发"给每个客户端节点,因此指标若按常规 node 维度输出会把同一张卡在每个节点重复报一次、且挂在不拥有它的节点下。metrics 因此新增 `collectRemoteGPUMetrics`,按 **server 维度**输出 `hami_remote_gpu_memory_limit_bytes` / `hami_remote_gpu_allocated` / `hami_remote_gpu_overview`,并在 `collectNodeMetrics` 里显式 `continue` 跳过 RemoteGPU 类型。整卡出租,分配是布尔量(整卡或 0)。
  <details><summary>代码依据 cmd/scheduler/metrics.go</summary>

  ```diff
  +			if devs.Device.Type == remotegpu.RemoteGPUCommonWord {
  +				// reporting it here would list each card once per node ...
  +				continue
  +			}
  ...
  +func (cc ClusterManagerCollector) collectRemoteGPUMetrics(ch chan<- prometheus.Metric) {
  +	labels := []string{"server", "endpoint", "device_uuid", "device_index", "device_type"}
  +	// "hami_remote_gpu_memory_limit_bytes" / "hami_remote_gpu_allocated" / "hami_remote_gpu_overview"
  ```
  </details>

- **删除仓库自带的 legacy Grafana dashboard**(`dashboards/hami-vgpu-dashboard.json` 901 行 + README + test,PR #3031)。信号弱(可用性/维护成本收敛),但与 remote-gpu 新增独立指标同期,暗示指标暴露面正在重整。
  <details><summary>代码依据 dashboards/hami-vgpu-dashboard.json(removed)</summary>

  ```diff
  -{ "annotations": ... "description": "GPU virtualization metrics exported by HAMi ...",
  -  ... 整个 901 行 dashboard JSON 删除
  ```
  </details>

### 后续发展方向 [AI]
- HAMi 的能力版图正从"单机 vGPU 软切分(hook/时分)"向 **"跨节点 GPU 池化/网络挂载(disaggregation)"** 扩张。证据是 remotegpu 为**独立后端**、整卡出租(`allocated` 是布尔、无 devmem 分数记账)、且刻意零节点组件复用现有注解——这条路线目前是**整卡粒度**,尚未见与 HAMi-core 的显存/算力软切分在远端卡上组合(即"远端卡再切分")。证据只覆盖 HAMi 主仓调度侧 diff,未见 lupine server 本体实现(不在本仓),也未见 CRD/API 变更(探测无 API/CRD 路径命中)。
- 对我们产品的启示:remote-gpu 走的是**注解 + downward API 的调度器侧纯软方案**,不依赖 DRA,也不需在客户端节点部署 device plugin——是低侵入接入"远端 GPU/GPU-over-fabric"的一种参考路径,但当前只做整卡、无网络传输/隔离层(那部分在 lupine),企业级多租户下的 QoS/隔离仍是空白。区别于 DRA 原生路径:这仍是 HAMi 自有注解协议栈,非 K8s 原生资源模型。

## Project-HAMi/HAMi-core: fdbe6a86 -> 2c5c03d8
- 比较: fdbe6a86 -> 2c5c03d8 | ahead=2 | files=3 | Release: —

### AI 总结重点(源码 diff 为据)
- **修复利用率采集把 CUDA 索引当 NVML 索引用的 bug**:`get_used_gpu_utilization` 循环里 `nvmlDeviceGetHandleByIndex(cudadev, ...)` 应传其映射到的真实 NVML 索引 `devi`。二者仅在 `CUDA_VISIBLE_DEVICES` 为恒等映射时才相等,否则多卡场景下统计到错卡的利用率/显存(issue #318)。同时新增 GPU-free 回归测试 `test_utilization_nvml_index.c`(桩掉 NVML 与共享区,断言 watcher 请求的是 NVML index),并在 CMake/CTest 里以 `--gc-sections`+`--no-export-dynamic` 剥离 watcher 线程对 libcuda 的依赖,使之无需驱动/GPU 即可跑。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c</summary>

  ```diff
  -      CHECK_NVML_API(nvmlDeviceGetHandleByIndex(cudadev, &device));
  +      CHECK_NVML_API(nvmlDeviceGetHandleByIndex(devi, &device));
  ```
  </details>
  <details><summary>代码依据 test/CMakeLists.txt(新增 GPU-free 回归测试)</summary>

  ```diff
  +    elseif (TEST_TARGET_NAME STREQUAL "test_utilization_nvml_index")
  +        # ... needs no NVIDIA driver and no GPU at runtime.
  +        add_executable(${TEST_TARGET_NAME} ${TEST_SCRIPT}
  +            .../multiprocess_utilization_watcher.c .../log_utils.c)
  +add_test(NAME utilization_nvml_index COMMAND test_utilization_nvml_index)
  ```
  </details>

### 后续发展方向 [AI]
- 延续上期观察到的"把软切分内核的正确性纳入 CI 常态"趋势:本次同样是**记账正确性修复 + 配套 GPU-free 回归测试**,索引错配属于多卡记账的隐蔽 bug。方向是逐个消除 hook 层"统计口径"缺陷(上期是并发/TOCTOU,本期是索引映射)。证据仅覆盖 utilization watcher 一处 hunk,未见对显存分配路径或新隔离维度的改动。

## 本期无实质改动(折叠)
<details><summary>3 个 repo 无新提交</summary>

- Project-HAMi/volcano-vgpu-device-plugin(cbded47b,无新提交)
- Project-HAMi/ascend-device-plugin(4b977f92,无新提交)
- Project-HAMi/HAMi-WebUI(5fd62d49,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=a7e3ffd66891d0fddfc5e331572cab3375c6bf3e branch=master release=v2.10.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=2c5c03d804d89428033e8b6f274d4f2122e1c9e9 branch=main release=— scanned=2026-09-16 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-16 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=5fd62d49bc379abeef9b6afed69eba7deed0be26 branch=main release=v1.3.0 scanned=2026-09-16 -->
