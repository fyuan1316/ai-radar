# HAMi diff 雷达 2026-11-03

## 摘要
- **HAMi 昇腾路径接入昇腾 950DT 新卡,但仅支持整卡分配,明确不走 vNPU 软切分**:`ascend-device-plugin` 新增一整套 DCMI v2 接入层(cgo dlopen `libdcmi.so`),新资源 `huawei.com/Ascend950DT` 的 `templates: []` 为空,allocate 侧直接拒绝任何 vNPU 模式/模板。信号 `[新能力]`。
- **WebUI 修了寒武纪 MLU 显存 4 倍高估(1024→256 MiB/单位)+ 给 Pod informer 加 panic 兜底**:一条坏注解过去会让整个 WebUI 进程崩重启,现在按设备类型计数解码失败并续跑。
- `volcano-vgpu-device-plugin` 本期 7 个 PR 全是健康上报健壮性(流重连不丢健康态、stop 时不再阻塞发送)+ 构建/文档清理,无能力/API 变化。`HAMi`、`HAMi-core` 两主仓无新提交。

## 当日重要改变
- `ascend-device-plugin` [新能力] 新增昇腾 950DT 整卡支持:独立 DCMI v2 接入层(`internal/manager/dcmiv2_950dt.go`、`dcmiv2_linux.go`、`dcmiv2_stub.go`)+ 新资源 `huawei.com/Ascend950DT`,**整卡独占、无 vNPU 模板**。主 PR https://github.com/Project-HAMi/ascend-device-plugin/pull/149 ;Release 升 ascend-device-plugin-0.2.2 https://github.com/Project-HAMi/ascend-device-plugin/releases/tag/ascend-device-plugin-0.2.2
- `HAMi-WebUI` [修复] 寒武纪 MLU 节点显存按 1024 MiB/单位统计实际应为 256,导致上报显存 4 倍偏高,本期改正;同时修 Pod 事件处理 panic 会拖垮进程。PR https://github.com/Project-HAMi/HAMi-WebUI/pull/340

## Project-HAMi/ascend-device-plugin: fff306db -> 9325759b
- 比较: https://github.com/Project-HAMi/ascend-device-plugin/compare/fff306dbb379c1e0e0a7935e3608db6a8b98cf7c...9325759b9d297302908e91e17d81a2676ffd7a6f | ahead=10 | Release: ascend-device-plugin-0.2.2

### AI 总结重点(源码 diff 为据)
- **新增 DCMI v2 读接口层,只做整卡发现与健康,刻意不含虚拟设备操作**。`dcmiV2API` 接口枚举的全是只读能力(`deviceList`/`chipInfo`/`deviceHealth`/`deviceDDIE`/`hbmInfo` 等),注释明说 950DT 不用 DCMI 虚拟设备操作。底层 `dcmiv2_linux.go` 用 cgo `dlopen` 动态加载 `libdcmi.so` 的 `dcmiv2_*` 符号,并本地 `#define DCMI_V2_DDIE_VALUE 2` 兼容仓内旧头文件(旧头只声明 NDIE/VDIE)。这是"接新卡"的驱动适配层,不是新的软切分能力。
  <details><summary>代码依据 internal/manager/dcmiv2_950dt.go / dcmiv2_linux.go</summary>

  ```diff
  +// dcmiV2API is intentionally limited to read-only APIs needed for whole-card
  +// discovery and health. 950DT does not use DCMI virtual-device operations.
  +type dcmiV2API interface {
  +	init() error
  +	allDeviceCount() (int32, error)
  +	deviceList() ([]int32, error)
  +	chipInfo(int32) (common.ChipInfo, error)
  +	deviceHealth(int32) (uint32, error)
  +	deviceDDIE(int32) ([ascend950DTDieIDCount]uint32, error)
  +	...
  +}
  +const (
  +	ascend950DTName     = "Ascend950DT"
  +	ascend950DTResource = "huawei.com/Ascend950DT"
  +)
  ```
  ```diff
  +//go:build linux && cgo
  +#define DCMI_V2_DDIE_VALUE 2   // 旧头只有 NDIE/VDIE,本地补 DDIE=2 以兼容构建
  +static int dcmi_v2_load(const char *path) {
  +    dcmi_v2_handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL);
  +    LOAD_DCMI_V2(dcmiv2_init, dcmiv2_init_func);
  +    ...
  ```
  </details>
- **950DT 走"AutoInit 失败再降级到 DCMI v2"的探测路径,且强制整卡**。`NewAscendManager` 在原 `devmanager.AutoInit` 失败时 fallback 到 `newAscend950DTManager()`;`LoadNodeConfig` 对 950DT 把 `VDeviceCount` 限死在 {0,1}(每张物理卡一个整卡设备),`LoadConfig` 对 950DT 取 `v2Mgr.chipInfo` 而非 `mgr.GetValidChipInfo()`。
  <details><summary>代码依据 internal/manager/manager.go</summary>

  ```diff
   func NewAscendManager() (*AscendManager, error) {
   	mgr, err := devmanager.AutoInit("", 30)
   	if err != nil {
  -		return nil, fmt.Errorf("failed to auto-init device manager: %w", err)
  +		v2Mgr, v2Err := newAscend950DTManager()
  +		if v2Err != nil {
  +			return nil, fmt.Errorf("failed to auto-init device manager: %v; Ascend950DT DCMI v2 detection failed: %w", err, v2Err)
  +		}
  +		return &AscendManager{v2Mgr: v2Mgr, devs: []*Device{}}, nil
   	}
  +	// LoadNodeConfig:
  +	if am.v2Mgr != nil {
  +		if n.VDeviceCount < 0 || n.VDeviceCount > 1 {
  +			return fmt.Errorf("Ascend950DT supports one whole-card device per physical card; ... vDeviceCount=%d", n.VDeviceCount)
  +		}
  +	}
  ```
  </details>
- **allocate 侧硬拒绝 950DT 上的任何 vNPU 请求**。新增 `fullCardOnlyManager` 接口 + `managerIsFullCardOnly()`;`buildContainerAllocateResponse` 对整卡卡型,若 pod 的 `huawei.com/vnpu-mode` 非空且不等于新常量 `VNPUModeTemplate="template"`、或带了 vNPU 模板 spec,直接报错返回。
  <details><summary>代码依据 internal/server/server.go / allocate.go</summary>

  ```diff
  +	VNPUModeTemplate = "template"
  +type fullCardOnlyManager interface { IsFullCardOnly() bool }
  +func managerIsFullCardOnly(mgr manager.Manager) bool { ... }
  ```
  ```diff
  +	if managerIsFullCardOnly(ps.mgr) {
  +		if requestedMode != "" && !strings.EqualFold(requestedMode, VNPUModeTemplate) {
  +			return nil, fmt.Errorf("Ascend950DT supports whole-card allocation only; pod vnpu mode %q is not supported", vnpuMode)
  +		}
  +		if ascendVNPUSpec != "" {
  +			return nil, fmt.Errorf("Ascend950DT supports whole-card allocation only; vNPU template %q is not supported", ascendVNPUSpec)
  +		}
  +	}
  ```
  </details>
- **设备目录新增 950DT 条目,显存 96GiB、32 AiCore、模板为空**。`charts/.../values.yaml` 与 `ascend-device-configmap.yaml` 同步加 `Ascend950DT`:`memoryAllocatable/Capacity: 98304`、`aiCore: 32`、`templates: []`(空模板=无切分规格,印证整卡)。
  <details><summary>代码依据 charts/ascend-device-plugin/values.yaml</summary>

  ```diff
  +    - chipName: Ascend950DT
  +      commonWord: Ascend950DT
  +      resourceName: huawei.com/Ascend950DT
  +      memoryAllocatable: 98304
  +      memoryCapacity: 98304
  +      aiCore: 32
  +      templates: []
  ```
  </details>
- **发现失败时保留已知设备为 unhealthy,不直接清空**。950DT discovery 报错时把 `am.devs` 拷贝一份、置 `Health=false` 上报,避免抖动把整卡从可调度列表里抹掉。
  <details><summary>代码依据 internal/manager/manager.go(Preserve unhealthy 提交)</summary>

  ```diff
  +	klog.Errorf("Ascend950DT discovery failed; marking known devices unhealthy: %v", err)
  +	for _, dev := range am.devs {
  +		unhealthy := *dev
  +		unhealthy.Health = false
  +		devices = append(devices, &unhealthy)
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- HAMi 对昇腾的覆盖正从"910 系列 vNPU 模板软切分"横向扩到"950DT 新卡整卡纳管"。证据集中在 950DT 全走整卡、`templates: []`、allocate 拒绝一切 vNPU 模式——说明本期目标是**先把新硬件纳进调度/健康闭环,软切分(vNPU/hami-core)暂不在 950DT 上开放**。证据只覆盖本次 diff 引入的整卡路径,未见后续是否会给 950DT 补 DCMI v2 的虚拟设备切分接口。
- DCMI v2 用 `dlopen` + 本地 `#define` 兼容旧头,是典型"驱动 ABI 还在演进、先运行时软加载规避头文件缺失"的过渡写法;后续 950DT 驱动头稳定后这层本地补丁有收敛空间。证据仅为 `dcmiv2_linux.go` 的 cgo 片段,未见驱动侧 roadmap。

## Project-HAMi/volcano-vgpu-device-plugin: 0512eba1 -> 9d852775
- 比较: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/0512eba10b312391b9660df876685ff26dedd4ac...9d8527759939f3a2d2aca68647549dd22b9fa9a1 | ahead=7 | Release: —

### AI 总结重点(源码 diff 为据)
- **把设备健康态从 ListAndWatch 流里解耦出来,独立 goroutine 持有,流重连不再丢健康**。新增 `pkg/plugin/health.go`:`watchHealth` 常驻 goroutine 收 unhealthy 事件,用"关闭并重建 `healthChanged` channel"的广播模式唤醒所有 watcher;`deviceSnapshot` 在同一把 `healthMu` 下拷贝健康态与取通知 channel,避免序列化竞态。插件结构体里 `entryLimitWarned bool` 换成 `entryLimitWarning sync.Once`,应对 ListAndWatch 流在重连期重叠。
  <details><summary>代码依据 pkg/plugin/health.go / server.go</summary>

  ```diff
  +func (plugin *nvidiaDevicePlugin) watchHealth(stop <-chan interface{}, health <-chan *rm.Device, done chan<- struct{}) {
  +	for {
  +		select {
  +		case <-stop: return
  +		case d := <-health:
  +			plugin.healthMu.Lock()
  +			if d.Health != pluginapi.Unhealthy {
  +				d.Health = pluginapi.Unhealthy
  +				close(plugin.healthChanged)
  +				plugin.healthChanged = make(chan struct{})
  +			}
  +			plugin.healthMu.Unlock()
  +	}
  +}
  ```
  ```diff
  -	entryLimitWarned bool
  +	entryLimitWarning sync.Once
  ```
  </details>
- **健康检查发送 unhealthy 事件时不再无脑阻塞,改为 select stop/unhealthy,shutdown 可退出跑 NVML 清理**。`pkg/rm/health.go` 里所有 `unhealthy <- d` 裸发送换成 `reportUnhealthy(stop, unhealthy, d)`,返回 false(stop 关闭)即 `return nil` 退出,让 defer 的 NVML 清理得以执行。
  <details><summary>代码依据 pkg/rm/health.go</summary>

  ```diff
  -			unhealthy <- d
  +			if !reportUnhealthy(stop, unhealthy, d) {
  +				return nil
  +			}
  +// reportUnhealthy waits for a reader or shutdown. A false result tells the
  +// health check to exit so its deferred NVML cleanup can run.
  +func reportUnhealthy(stop <-chan interface{}, unhealthy chan<- *Device, device *Device) bool {
  +	select { ...
  ```
  </details>
- **节点/容器设备注解解码加错误校验:坏条目跳过但仍计数,防止非法请求匹配到更小的分配**。`DecodeNodeDevices`/`DecodeContainerDevices` 原来用 `strconv.ParseInt(...) ,_` 吞错,现在检查 err(数值溢出 `ErrRange` 容忍、其余跳过);容器解码里坏条目 `deviceCount++` 仍计数,注释明说"a malformed entry still counts, so the pod cannot match a smaller request"。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -			count, _ := strconv.ParseInt(items[1], 10, 32)
  -			devmem, _ := strconv.ParseInt(items[2], 10, 32)
  -			health, _ := strconv.ParseBool(items[4])
  +			count, err := strconv.ParseInt(items[1], 10, 32)
  +			if err != nil && !errors.Is(err, strconv.ErrRange) { continue }
  +			devmem, err := strconv.ParseInt(items[2], 10, 32)
  +			if err != nil && !errors.Is(err, strconv.ErrRange) { continue }
  +			health, err := strconv.ParseBool(items[4])
  +			if err != nil { continue }
  ```
  </details>
- 构建/文档清理(无能力影响):删 `Makefile.def` 与死 target `gen_bin`、`VERSION` 默认 `1.0.0`→`dev`、补 `.PHONY`(#224);删 `devices.go` 里未用的 `GetPluginDevices`;README 重写(#225)把两种共享模式讲清:`hami-core`(软隔离,任意 GPU)vs `mig`(动态 MIG,硬隔离,Ampere+),并标 client-go 0.37 / 验证到 K8s 1.36。

### 后续发展方向 [AI]
- 本期是清一色的 device-plugin 健壮性收口(健康态持久化、优雅停机、注解解码防御),无新调度/切分能力。证据覆盖 health/util/server 三处 diff,未见对 Volcano 调度侧协议或 vGPU 切分算法的改动。方向上看是在为"流重连/异常注解"等生产故障场景补稳定性,属成熟化而非能力扩张。

## Project-HAMi/HAMi-WebUI: 4f5875cf -> 3d863e8d
- 比较: https://github.com/Project-HAMi/HAMi-WebUI/compare/4f5875cf561bd831cef7dde2177117f1d39687f9...3d863e8d182ecd21f8fc8e5dea27199e8323ea55 | ahead=3 | Release: v1.3.0

### AI 总结重点(源码 diff 为据)
- **寒武纪 MLU 显存换算系数从 1024 改为 256,修正 4 倍高估**。`mlu/device.go` 把 `CambriconMemUnit=1024` 换成 `CambriconMemoryFactor=256`(注释:一个 vmemory 单位对应 256 MiB,与 HAMi 统计口径一致),`provider.go` 的 `Devmem` 计算同步改用 256。同时 `SupportDevices[CambriconMLUDevice]` 从环境变量 `DsmluProfile` 改成按注解 `hami.io/cambricon-mlu-devices-allocated` 识别。
  <details><summary>代码依据 server/internal/provider/mlu/device.go / provider.go</summary>

  ```diff
  -	CambriconMemUnit           = 1024
  +	// CambriconMemoryFactor is the MiB in one vmemory unit of node capacity, as HAMi counts it.
  +	CambriconMemoryFactor = 256
  -	util.SupportDevices[CambriconMLUDevice] = DsmluProfile
  +	util.SupportDevices[CambriconMLUDevice] = "hami.io/cambricon-mlu-devices-allocated"
  ```
  ```diff
  -		Devmem:  int32(memoryTotal * CambriconMemUnit * 100 / cards),
  +		Devmem:  int32(memoryTotal * CambriconMemoryFactor * 100 / cards),
  ```
  </details>
- **给 Pod informer 事件处理加 panic 兜底 + 按设备类型统计解码失败,单条坏注解不再拖垮进程**。`pod.go` 新增 `recoverEvent`(注释:client-go 会 re-panic handler 的 panic,否则一个坏对象就重启进程),`onAddPod`/`onDeletedPod` 加 `defer r.recoverEvent(...)`;`DecodePodDevices` 从"一错即 return"改为返回 `failures` 列表,逐设备类型累加新 Prometheus 指标 `hami_webui_allocation_decode_errors_total{device_type}`。
  <details><summary>代码依据 server/internal/data/pod.go</summary>

  ```diff
  +var allocationDecodeErrors = prometheus.NewCounterVec(prometheus.CounterOpts{
  +	Name: "hami_webui_allocation_decode_errors_total",
  +	Help: "Failed attempts to decode a Pod allocation annotation, by device type.",
  +}, []string{"device_type"})
  +func (r *podRepo) recoverEvent(event string, obj interface{}) {
  +	if p := recover(); p != nil { ... r.log.Errorf("pod %s handler panicked ...", ...) }
  +}
   func (r *podRepo) onAddPod(obj interface{}) {
  +	defer r.recoverEvent("add", obj)
  -	podDev, err := util.DecodePodDevices(pod, r.log)
  -	if err != nil { ...; return }
  +	podDev, failures := util.DecodePodDevices(pod, r.log)
  +	for _, failure := range failures {
  +		allocationDecodeErrors.WithLabelValues(failure.DeviceType).Inc()
  +	}
  ```
  </details>
- **解码路径重构为带错误返回的分段解析,去掉静默吞错**。`util.go` 把 `DecodeContainerDevices` 拆成 `parseDeviceSegment` + `parseNonNegativeInt32`,内存/算力字段解析失败返回明确 error(而非旧的 `,_` 丢弃);删掉独立的 `DecodeDCUContainerDevices` 与常量 `DsmluProfileAndInstance`(收敛)。
  <details><summary>代码依据 server/internal/provider/util/util.go</summary>

  ```diff
  +func parseDeviceSegment(val string) (deviceSegment, error) {
  +	fields := strings.Split(val, ",")
  +	if len(fields) < 4 { return deviceSegment{}, fmt.Errorf("allocation %q has fewer than 4 fields", val) }
  +	mem, err := parseNonNegativeInt32(fields[2])
  +	if err != nil { return deviceSegment{}, fmt.Errorf("allocation %q memory: %w", val, err) }
  +	...
  +}
  -	DsmluProfileAndInstance = "CAMBRICON_DSMLU_PROFILE_INSTANCE"
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 的多厂商纳管(Cambricon/Hygon/Metax/MLU)正在从"能显示"走向"显示对且不崩":本期全是计量修正(MLU 显存 4x)与观测性/健壮性(panic 恢复 + 解码失败指标)。证据覆盖 mlu/util/pod 三处,新 `hami_webui_allocation_decode_errors_total` 指标说明开始把"注解解码质量"当可观测信号暴露。未见新增厂商 provider(见 [[hami-webui-provider-pattern]] 的接卡模板,本期未触发)。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos</summary>

- `Project-HAMi/HAMi`:无新提交(仍 2b8f4e29 / v2.10.0)
- `Project-HAMi/HAMi-core`:无新提交(仍 6736b058)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=2b8f4e29c48bca376d4f6123d7c6ae7627aef579 branch=master release=v2.10.0 scanned=2026-11-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6736b0589049390ec945bd40dfb4769f9f043def branch=main release=— scanned=2026-11-03 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=9d8527759939f3a2d2aca68647549dd22b9fa9a1 branch=main release=— scanned=2026-11-03 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-03 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=3d863e8d182ecd21f8fc8e5dea27199e8323ea55 branch=main release=v1.3.0 scanned=2026-11-03 -->
