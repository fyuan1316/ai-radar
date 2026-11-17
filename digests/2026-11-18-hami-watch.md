# HAMi diff 雷达 2026-11-18

> 距上一篇(2026-11-03)间隔 15 天。HAMi 主仓(81 commit)和 HAMi-core(147 commit)积压太多,helper 判为 `__OVERVIEW__`,这两个只写概览;volcano-vgpu-device-plugin 和 HAMi-WebUI 按深度模式读 hunk;ascend-device-plugin 无新提交。

## 摘要
1. HAMi 主仓从 v2.10.0 跨档到 v2.11.0。区间内新增 Tecorigin(太初)GPU 设备包 `pkg/device/tecorigin`,以及独立的远程 GPU 监控组件 `cmd/remoteGPUmonitor` 和 `pkg/monitor/remotegpu`。调度器把大量工作放在 NUMA refit 和分配指标(bind、device plugin 分配结果、耗时直方图)上,另加了离线配置校验。(大区间概览,未逐文件读代码)
2. HAMi-core 147 个提交几乎都在补 CUDA Graph/stream capture 场景的显存记账:graph 内存按 shared pool 计费、capture 与 per-thread stream(`_ptsz/_ptds`)接口补齐、适配 CUDA 13.4 generic graph node、host pid 检测改为首次用 GPU 时才做。`allocator.c` 净增 1662 行,软隔离的能力边界从「普通 cuMalloc」扩到「Graph 与 VMM 路径」。(大区间概览,未逐文件读代码)
3. volcano-vgpu-device-plugin 升到 1.13.0。Tegra 设备发现策略被标为 deprecated,运行时会告警说 Tegra 不支持 vGPU 和显存记账。daemonset 去掉了 `critical-pod` 注解和 `volcano.sh/gpu-memory` 容忍。另外 MIG UUID 查找失败从 `panic(0)` 改成返回 error。HAMi-WebUI 新增 `Overview.GetInventory`(`/api/v1/overview/inventory`)和 `About`(`/v1/about`)两个 API,一次读出「物理卡清单 + coverage 完整性」,并导出 `hami_webui_device_*` 物理卡指标。

## 当日重要改变
- HAMi [版本跨档] 最新 Release 从 v2.10.0 升到 v2.11.0(minor 跨档)。主要特性:整卡分配不再挂载 HAMi-core、Flexible-MIG CDI、NUMA refit、Ascend 950、全面支持 AMD。https://github.com/Project-HAMi/HAMi/releases/tag/v2.11.0
- HAMi [新能力] 新增顶层设备包 `pkg/device/tecorigin/device.go`(+717 行),示例在 `examples/tecorigin/default_use.yaml`,对应 feat: add support for Tecorigin GPU。https://github.com/Project-HAMi/HAMi/pull/3369
- HAMi [新能力] 新增独立二进制 `cmd/remoteGPUmonitor/main.go`(+171),配套 `pkg/monitor/remotegpu/collector.go`、chart 模板 `templates/device-plugin/remotemonitor.yaml` 和对应 role。https://github.com/Project-HAMi/HAMi/pull/3334
- HAMi [新能力] 调度器新增离线配置校验 `cmd/scheduler/validate.go`(+85)和 `scheduler_options.go`;另有 feat(scheduler): reject unrecognized scheduler-policy annotations,未识别的策略注解从「静默忽略」改为「拒绝」(仅据提交标题,未读 hunk)。https://github.com/Project-HAMi/HAMi/pull/3422 https://github.com/Project-HAMi/HAMi/pull/3365
- HAMi [弃用/移除] docs: remove Ascend950DT SKU reference from the repo(只删文档里的 SKU 引用,950DT 整卡调度配置仍在 #3316);build: drop the dead proto target(只动构建)。https://github.com/Project-HAMi/HAMi/pull/3372 https://github.com/Project-HAMi/HAMi/pull/3450
- volcano-vgpu-device-plugin [弃用/移除] Tegra 设备发现策略被标为 deprecated:flag 的 Usage 改了说明,选 `tegra` 分支时打 Warning。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/1ae6851e53a2cecac88c3fc48bf59a90679a905c
- volcano-vgpu-device-plugin [弃用/移除] daemonset 删除 `scheduler.alpha.kubernetes.io/critical-pod` 注解(helm 和 static 两套)和 `volcano.sh/gpu-memory` NoSchedule 容忍。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/261
- volcano-vgpu-device-plugin [版本跨档] 静态清单镜像从 v1.12.0 升到 v1.13.0,Release 为 volcano-vgpu-device-plugin-1.13.0。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/releases/tag/volcano-vgpu-device-plugin-1.13.0
- volcano-vgpu-device-plugin [API/CRD变更] 命中 `api/config/v1/config.go`,但实际只删 TODO、修注释错字,没有字段变化,属于误报。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/236
- HAMi-WebUI [API/CRD变更] 新增 proto 服务 `observability.v1.Overview/GetInventory` 和 `api.v1.About/GetAbout`,新增 `Coverage/FieldState` 通用类型;前端 node/card API 改走 inventory。https://github.com/Project-HAMi/HAMi-WebUI/pull/347 https://github.com/Project-HAMi/HAMi-WebUI/pull/348

## Project-HAMi/HAMi: 2b8f4e29 -> fc2bcd0d
- 比较: https://github.com/Project-HAMi/HAMi/compare/2b8f4e29c48bca376d4f6123d7c6ae7627aef579...fc2bcd0d24da4e409a792de02deaf57a143565ac | ahead=81 | files=139 | Release: v2.11.0

**大区间概览,未逐文件读代码**(依据:实质提交标题聚类、改动热点目录、新增文件清单、release note)

### 方向主题
1. **调度可观测性与正确性**(热点 `pkg/scheduler` 19、`cmd/scheduler` 7)
   - 指标:新增 NUMA refit 结果计数(#3364)、成功 bind 计数(#3411)、device plugin 分配结果计数(#3418)、分配耗时直方图(#3463)、last sync success 时间戳(#3389)。
   - 一致性:移除 pod 分配时持有 allocLock(#3350);设备 cordon 注解变化时刷新节点缓存(#3332);NUMA refit 取 live pod 以保住 resourceVersion(#3328),refit 后更新 standby 副本(#3379);失去 leader 时清理调度状态并关掉指标(#3416);跟随被 Filter 移到别的节点的 pod(#3470)。
   - 配置治理:离线配置校验(#3422);拒绝未识别的 scheduler-policy 注解(#3365)。
2. **多厂商设备纳管扩面**(热点 `pkg/device` 24)
   - 新厂商:Tecorigin 太初(#3369,新包)。
   - 新型号:Iluvatar MR-V100A/MR-V50A(#3368)、Ascend950DT 9582 整卡调度(#3316)。
   - 配额与拓扑:Hygon 整卡显存 ResourceQuota 强制(#3374)和 DCU/HCU resourcePrefix 升级兼容(#3375);AMD 拓扑调度按 quota 可行组合选卡(#3361);NVIDIA 拓扑调度按 NUMA 域切分候选卡(#3326/#3327);AWS Neuron UUID 包含/排除(#3434)、部分占用设备(#3432)、init 容器 core mask 保持(#3440);Cambricon ReleaseNodeLock 守卫(#3424)。
3. **Remote GPU(远程 CUDA)产品化**:新增 remoteGPUmonitor 独立组件(#3334)、session relay 失败或过期后对账(#3371)、reservation 刷新失败时阻塞分配(#3399)、filter patch 失败时释放预留(#3425/#3433)。v2.11.0 release note 里的「Run vLLM on remote GPUs served by Lupine」与此衔接。
4. **device plugin / monitor 健壮性**:hostpid broker 限制并发 CUDA driver 调用数(#3373);nil DeviceSplitCount 守卫(#3359);vgpu-monitor 发现 MIG 实例(#3349);MIG allowlist 补实际 NVML 名称(#3352);拒绝非正数的 `HAMI_RESYNC_INTERVAL`(#3441)。
5. **构建与依赖**:Go 1.27.4(#3437);HAMi-core 构建镜像升到 CUDA 13.5.0(#3451);dependabot 每天检查 libvgpu(#3458)。

### 改动热点目录
`pkg/device`(24)、`pkg/scheduler`(19)、`pkg/device-plugin`(17)、`charts/hami`(15)、`.github/workflows`(11)、`cmd/scheduler`(7)、`pkg/monitor`(5)、`cmd/vGPUmonitor`(4)、`cmd/remoteGPUmonitor`(2)

### 后续发展方向 [AI]
- **调度器正在补「可运营」能力**。区间里约 1/4 的提交是分配链路指标和缓存一致性修复(leader 切换、cordon、NUMA refit 与 resourceVersion),加上离线校验和拒绝未知注解,方向是把 HAMi scheduler extender 从「能调度」推到「能排障、能 SLO 化」。证据边界:只看了标题和目录,没读 `pkg/scheduler` 的 hunk,无法确认指标名和 label 设计。
- **Remote GPU 正在从实验走向独立部署单元**,依据是新增独立二进制、chart 模板和 RBAC,并补齐预留失败的回滚路径。这是 HAMi 软切分之外的第三条路径(前两条是本地 hook 切分和 MIG),与 DRA 原生路径无关。证据边界:没读 `collector.go` 和 `main.go`,不清楚远程会话的计量口径。
- **厂商扩面仍走 `pkg/device/<vendor>` 插件化模板**(本期是太初)。HAMi 的多厂商广度在继续拉开,但只新增了 device 包和示例,未见 HAMi-core 对应的 hook,应是厂商侧自带切分或只做整卡调度。证据边界:没读 `tecorigin/device.go`,未核实是否支持显存/算力切分。

## Project-HAMi/HAMi-core: 6736b058 -> 1fc9ea59
- 比较: https://github.com/Project-HAMi/HAMi-core/compare/6736b0589049390ec945bd40dfb4769f9f043def...1fc9ea59cf1f94e16a7ddf6f445e129d282e1d03 | ahead=147 | files=41 | Release: —

**大区间概览,未逐文件读代码**(依据:提交标题和文件增量统计;compare API 只返回前 100 个 commit)

### 方向主题
1. **CUDA Graph 显存记账(主线)**
   - 计费口径:graph 内存计到所属 graph,直到 graph 被销毁;exec 存活期间保持计费;从没运行过的 graph 也要释放;按 shared graph pool 计费,不按单个 graph 计(#396);图执行需求在 CUDA 提交之前预留;超限的 graph mem alloc 节点直接拒绝。
   - 新 ABI:适配 CUDA 13.4 generic graph node,两套 generic node ABI 都要走准入。
   - 涉及文件:`src/allocator/allocator.c`(+1662/-5)、`src/cuda/graph.c`(+187)、`allocator.h`(+52)。
2. **Stream capture 与 per-thread 默认流接口补齐**
   - capture 期间内部查询不改变 capture 行为;capture 身份保留到原生 capture 终止;per-thread capture 按 context 隔离。
   - per-thread 的 kernel、memory、copy 提交 hook 补齐;不可用的 extended per-thread launch 直接拒绝;保留原始 capture ABI 入口。
   - 涉及文件:`src/cuda/hook.c`(+267)、`src/include/libcuda_hook.h`(+149,hook 表扩充)、`src/cuda/stream.c`。
3. **VMM 路径记账**:显存要等 handle 释放并且 unmap 后才不再计数;记账失败时回滚 VMM 映射;`cuMemMap` 期间持有临时 handle 引用。涉及 `src/cuda/memory.c`(+360)。
4. **Host pid 检测改为懒执行**:推迟到首次使用 GPU 时;覆盖 `cuCtxCreate_v2/v3` 和 green context。涉及 `src/cuda/context.c`(+116)、`src/libvgpu.c`(+90)。
5. **多进程与总量上报**:fork 出的子进程释放继承来的 shrreg;`cuDeviceTotalMem` 上限钳到真实设备总量。

### 改动热点目录
`src/cuda`(6 文件)、`src/include`(3)、`src/allocator`(2),另有约 15 个新增 `test/test_graph_*`、`test_lazy_hostpid`、`test_vmm_release_mapped` 等回归用例。

### 后续发展方向 [AI]
- **软隔离的补洞对象从「普通分配 API」转到「CUDA Graph、capture、VMM」**。这些是 vLLM/TensorRT-LLM 的 CUDA Graph 推理,以及 PyTorch expandable segments(VMM)的实际显存路径。以前这些路径能绕过 HAMi-core 的显存配额(超用或漏记),本期 147 个提交几乎都在封堵。对用 HAMi 做 LLM 推理切分的场景,这是隔离可信度的关键改进。证据边界:只看了提交标题和文件增量,没读 `allocator.c` 的 hunk,不清楚「graph pool 计费」和「quota pressure 时才回收 backing」的具体算法,也未见算力(SM)切分侧的同步改动。
- 适配 CUDA 13.4 generic graph node、主仓构建镜像升到 CUDA 13.5,说明 HAMi-core 在跟进 CUDA 新 ABI 的节奏,每次 CUDA minor 升级都可能出现新的绕过面。

## Project-HAMi/volcano-vgpu-device-plugin: 9d852775 -> e5b0164c
- 比较: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/9d8527759939f3a2d2aca68647549dd22b9fa9a1...e5b0164caef64359ea10a7430a15008fa6be2ecb | ahead=33 | files=64 | Release: volcano-vgpu-device-plugin-1.13.0

### AI 总结重点(源码 diff 为据)
- **Tegra 设备发现策略被弃用(只告警,未删除)**:`--device-discovery-strategy` 的 Usage 文案给 `tegra` 加上 `(deprecated)`;`getResourceManagers()` 在 `case "tegra"` 里先 `klog.Warning`,明确「Tegra SoC 不支持 vGPU 虚拟化和显存记账」,然后仍照常返回 `NewTegraResourceManagers`。也就是说行为不变,只是把能力边界写明。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/1ae6851e53a2cecac88c3fc48bf59a90679a905c
  <details><summary>代码依据 pkg/plugin/factory.go / cmd/vgpu/main.go</summary>

  ```diff
  -			Usage:   "the strategy to use to discover devices: 'auto', 'nvml', or 'tegra'",
  +			Usage:   "the strategy to use to discover devices: 'auto', 'nvml', or 'tegra' (deprecated)",
  ...
   	case "tegra":
  +		klog.Warning("Tegra device discovery strategy is deprecated; vGPU virtualization and memory accounting are not supported on Tegra SoC architectures")
   		return rm.NewTegraResourceManagers(o.config)
  ```
  </details>
- **`WatchAndRegister` 可以被停止**:之前它是无限循环,用 `time.Sleep(2s/5s/30s)`,plugin Stop 之后这个 goroutine 还在继续写节点注解(goroutine 泄漏,旧实例和新实例并发注册)。现在签名改成 `WatchAndRegister(stop <-chan interface{})`,所有 sleep 换成 `sleepUnlessStopped`,stop 关闭就 return。后续一个提交又修了竞态:timer 和 stop 同时就绪时,二次 select 让关闭的 stop 优先生效。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/500acf5fe97b0c9605dadf763a298f415fff2156 https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/6ad03b7b72409fa239c6e2af400725ee7fc39470
  <details><summary>代码依据 pkg/plugin/server.go</summary>

  ```diff
  -		go plugin.WatchAndRegister()
  +		go plugin.WatchAndRegister(plugin.stop)
  ...
  -func (plugin *nvidiaDevicePlugin) WatchAndRegister() {
  +func (plugin *nvidiaDevicePlugin) WatchAndRegister(stop <-chan interface{}) {
  ...
  -		err := RegisterInAnnotation(devices)
  -		if err != nil {
  -			klog.Errorf("register error, %v", err)
  -			time.Sleep(time.Second * 5)
  -		} else {
  -			time.Sleep(time.Second * 30)
  +		wait := time.Second * 30
  +		if err := RegisterInAnnotation(devices); err != nil {
  +			klog.Errorf("register error, %v", err)
  +			wait = time.Second * 5
  +		}
  +		if !sleepUnlessStopped(stop, wait) {
  +			return
  ...
   	case <-timer.C:
  -		return true
  +		// Both channels can be ready; a closed stop must still win.
  +		select {
  +		case <-stop:
  +			return false
  +		default:
  +			return true
  +		}
  ```
  </details>
- **MIG UUID 查找失败不再让进程崩溃**:`GetIndexAndTypeFromUUID` 的返回值从 `(string, int)` 改为 `(string, int, error)`,NVML `DeviceGetHandleByUUID` 和 `GetName` 失败时不再 `panic(0)`,改为返回 error。`Allocate` 拿到 `GetContainerDeviceStrArray` 的 error 后会调 `util.PodAllocationFailed` 把 pod 标为分配失败,然后返回空响应。之前一张 UUID 异常的卡会把整个 device plugin 进程拖垮;现在只影响当前 pod。(hunk 截断,未覆盖全部)https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/232
  <details><summary>代码依据 pkg/util/util.go / pkg/plugin/server.go</summary>

  ```diff
  -func GetIndexAndTypeFromUUID(uuid string) (string, int) {
  +func GetIndexAndTypeFromUUID(uuid string) (string, int, error) {
   	ndev, ret := config.Nvml().DeviceGetHandleByUUID(originuuid)
   	if ret != nvml.SUCCESS {
   		klog.Error("nvml get handlebyuuid error ret=", ret)
  -		panic(0)
  +		return "", -1, fmt.Errorf("nvml get handle by uuid %s error ret: %s", originuuid, nvml.ErrorString(ret))
  ...
  -			response, err := plugin.getAllocateResponse(plugin.GetContainerDeviceStrArray(devreq))
  +			deviceStrArray, err := plugin.GetContainerDeviceStrArray(devreq)
  +			if err != nil {
  +				klog.Errorln("failed to get container device string array", err.Error())
  +				util.PodAllocationFailed(nodeName, current)
  +				return &pluginapi.AllocateResponse{}, err
  +			}
  ```
  </details>
- **部署面去掉过时的「关键 pod」机制和一条硬编码容忍**:helm `daemonset.yaml` 和 `static/volcano-vgpu-device-plugin.yml` 都删掉 `scheduler.alpha.kubernetes.io/critical-pod: ""`(K8s 早已弃用,只保留 `priorityClassName: system-node-critical`)。同时删掉默认容忍 `volcano.sh/gpu-memory: NoSchedule`。镜像 tag 默认取 `.Chart.AppVersion`,不再写死 `v1.12.0`。`nodeConfig.configs` 默认从示例节点 `aio-node67` 改为 `[]`,ConfigMap 卷只在 `enabled && configs` 都成立时挂载。**升级注意**:给 GPU 节点打了 `volcano.sh/gpu-memory` taint 的集群,daemonset 升级后会调度不上去,需要在 values 里自己补回容忍。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/261
  <details><summary>代码依据 deployments/static/volcano-vgpu-device-plugin.yml / helm values.yaml / daemonset.yaml</summary>

  ```diff
  -      annotations:
  -        scheduler.alpha.kubernetes.io/critical-pod: ""
  ...
  -      - key: volcano.sh/gpu-memory
  -        operator: Exists
  -        effect: NoSchedule
  ...
  -      - image: docker.io/projecthami/volcano-vgpu-device-plugin:v1.12.0
  +      - image: docker.io/projecthami/volcano-vgpu-device-plugin:v1.13.0
  ...
  -        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
  +        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default (hasPrefix "v" .Chart.AppVersion | ternary .Chart.AppVersion (printf "v%s" .Chart.AppVersion)) }}"
  ...
  -      {{- if .Values.nodeConfig.enabled }}
  +      {{- if and .Values.nodeConfig.enabled .Values.nodeConfig.configs }}
  ```
  </details>
- **配置序列化从 `gopkg.in/yaml.v2` 换成 `sigs.k8s.io/yaml`**:`NvidiaConfig` 每个字段都补了 `json:"..."` tag,名字和 yaml tag 保持一致。`sigs.k8s.io/yaml` 先转 JSON 再按 json tag 解析,补 tag 是为了保证现有 ConfigMap 的键名兼容。`DeviceInfo` 删掉 protobuf tag 和 `XXX_*` 遗留字段。`lm.Outputer.Output` 接口新增 `context.Context` 参数。属于技术债清理,无功能变化。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/pull/235
  <details><summary>代码依据 pkg/config/config.go / pkg/util/types.go</summary>

  ```diff
  -	DeviceSplitCount             uint                   `yaml:"deviceSplitCount"`
  +	DeviceSplitCount             uint                   `json:"deviceSplitCount" yaml:"deviceSplitCount"`
  ...
  -	Id                   string            `protobuf:"bytes,1,opt,name=id,proto3" json:"id,omitempty"`
  +	Id          string            `json:"id,omitempty"`
  -	XXX_NoUnkeyedLiteral struct{}          `json:"-"`
  ```
  </details>

### 后续发展方向 [AI]
- 这个仓库正在从「fork 自 NVIDIA k8s-device-plugin 的魔改版」向「HAMi 自维护组件」收口:删掉 NVIDIA 上游的 TODO 和注释代码、去掉 protobuf 遗留、Tegra 明确降级为不支持 vGPU、补 MIG 和 Tegra 的单测。能力面没有新增,稳定性(goroutine 退出、panic 改 error)和部署卫生是主线。证据边界:server.go 和 util.go 的 hunk 截断,未覆盖 apiDevices 等后半段。
- Tegra 现在只是告警,按惯例下一步会移除 `NewTegraResourceManagers` 分支。证据只覆盖告警,未见移除计划。

## Project-HAMi/HAMi-WebUI: 3d863e8d -> 01b0ba23
- 比较: https://github.com/Project-HAMi/HAMi-WebUI/compare/3d863e8d182ecd21f8fc8e5dea27199e8323ea55...01b0ba234db547f3bcc0b9f916ba8664f0716ea0 | ahead=38 | files=244 | Release: v1.3.0

### AI 总结重点(源码 diff 为据)
- **新增「物理卡清单」统一读模型 API,并显式区分「0 张卡」和「数据不完整」**:新服务 `observability.v1.Overview.GetInventory`(`GET /api/v1/overview/inventory`)一次返回 `nodes`、`devices`,外加 `node_coverage`、`device_coverage`。`Coverage` 带 `observed`、`optional total` 和 `complete`;注释约定只有完整来源确认了总数才填 `total`。`InventoryDevice` 的 `utilization_ratio`、`memory_usage_ratio` 都是 optional,「缺值不等于 0」。前端 `readCoverageCount` 只在 `complete` 为真或 `observed>0` 时给出 count,否则返回 undefined,不会把采集不全显示成「集群 0 卡」。https://github.com/Project-HAMi/HAMi-WebUI/pull/347
  <details><summary>代码依据 server/api/observability/v1/overview.proto / common.proto / overview-inventory.mjs</summary>

  ```diff
  +service Overview {
  +  rpc GetInventory (InventoryRequest) returns (InventoryReply) {
  +    option (google.api.http) = { get: "/api/v1/overview/inventory" };
  +  }
  +}
  +message Coverage {
  +  // Distinct entities matching the filters, before pagination.
  +  int32 observed = 2;
  +  // Omitted unless a complete source confirms a comparable total.
  +  optional int32 total = 3;
  +  bool complete = 4;
  ...
  +message InventoryDevice {
  +  // The canonical provider registration on this node identifies one physical device.
  +  string node = 1;
  +  string provider = 2;
  +  string device_id = 3;
  ...
  +  // Latest known device observations in [0, 1]. An absent value is not zero.
  +  optional double utilization_ratio = 6;
  ...
  +// An empty observed subset is not evidence that the cluster is empty. Preserve
  +// known zero only when the inventory source confirms a complete collection.
  +export const readCoverageCount = (coverage) => {
  ...
  +    count: coverage.complete || coverage.observed > 0 ? coverage.observed : undefined,
  ```
  </details>
- **导出物理卡维度的 Prometheus 指标(`hami_webui_device_*`)**:新文件 `resource_metrics.go` 注册 `resourceMetricCollector`,label 集合为 `node,node_uid,provider,vendor,model,device_id,device_kind,parent_device_id,device_uuid`。指标分两组:容量(`device_slots_capacity`、`device_compute_capacity_ratio`、`device_memory_capacity_bytes`)和已分配(`device_slots_allocated`、`device_compute_allocated_ratio`、`device_memory_allocated_bytes`、`device_compute_unknown_occupancies`),外加源原生的 `device_utilization_ratio`。HELP 文案明确写了「slots 不是物理卡数」「证据不完整时省略,不报 0」。WebUI 从只读的控制台变成了一个指标来源,可以接入外部监控和计费。(hunk 截断,未覆盖全部)https://github.com/Project-HAMi/HAMi-WebUI/commit/2aff52f9
  <details><summary>代码依据 server/internal/exporter/resource_metrics.go</summary>

  ```diff
  +var resourceDeviceLabels = []string{"node", "node_uid", "provider", "vendor", "model", "device_id", "device_kind", "parent_device_id", "device_uuid"}
  ...
  +		"device_slots_capacity":              "Known device allocation slot capacity; not a physical device count.",
  +		"device_slots_allocated":             "Known observed effective HAMi Pod occupancy in slots; empty incomplete inventory is omitted, not zero.",
  +		"device_compute_unknown_occupancies": "Observed HAMi occupancies with unknown compute shares; an incomplete zero is omitted and does not prove allocator coverage.",
  +	} {
  +		c.descriptors[name] = prometheus.NewDesc("hami_webui_"+name, help, resourceDeviceLabels, nil)
  ```
  </details>
- **新增 About API,用来对齐 HAMi 版本兼容性**:`api.v1.About.GetAbout`(`GET /v1/about`)返回 WebUI 构建信息、`HamiVersions`(`supported` 列出本 WebUI 支持的 HAMi minor 版本,`support` 取 supported/unsupported/development 三种)、各节点 kubelet 版本、Prometheus 状态和 K8s 版本。HAMi 版本来自 `hami_build_info` 指标;组件 Pod 按 chart 的 `app.kubernetes.io/component` label 识别。WebUI 开始显式声明「我支持哪几个 HAMi minor」,本期主仓刚升到 v2.11,版本错配会在界面上显示出来。https://github.com/Project-HAMi/HAMi-WebUI/commit/7dc422bf
  <details><summary>代码依据 server/api/v1/about.proto</summary>

  ```diff
  +service About {
  +  rpc GetAbout (GetAboutReq) returns (AboutReply) {
  +    option (google.api.http) = {
  +      get: "/v1/about"
  ...
  +// State is ok, missing (no hami_build_info series) or unavailable (Prometheus query failed).
  +message HamiVersions {
  +  string state = 1;
  +  // HAMi minor versions this WebUI release supports, such as 2.10.
  +  repeated string supported = 2;
  ...
  +  // Support is supported, unsupported or development (not a release tag).
  +  string support = 4;
  ```
  </details>
- **寒武纪资源名不再写死 mlu370**:常量 `CambriconDeviceCoreAnnos`/`MemAnnos`(`cambricon.com/mlu370.smlu.vcore|vmemory`)换成前缀 `cambricon.com/` 加后缀 `.smlu.vcore`/`.smlu.vmemory`。新增 `smluCapacity()`,遍历 node capacity 按 base 名配对 vcore 和 vmemory,半注册的名字跳过,多组不一致时报错。PromQL 的 `type="mlu370.smlu.vcore"` 改为正则 `type=~".+[.]smlu[.]vcore"`。之前开了 `--enable-device-type` 或用 370 以外型号(比如 590)的节点,在 WebUI 里看不到卡,现在能看到。https://github.com/Project-HAMi/HAMi-WebUI/pull/343
  <details><summary>代码依据 server/internal/provider/mlu/device.go / provider.go / exporter.go</summary>

  ```diff
  -	CambriconDeviceCoreAnnos   = "cambricon.com/mlu370.smlu.vcore"
  -	CambriconDeviceMemAnnos    = "cambricon.com/mlu370.smlu.vmemory"
  +	CambriconResourcePrefix    = "cambricon.com/"
  +	CambriconCoreResource      = ".smlu.vcore"
  +	CambriconMemResource       = ".smlu.vmemory"
  ...
  +// smluCapacity pairs vcore with vmemory per resource name, which --enable-device-type changes.
  +func smluCapacity(node *corev1.Node) (smluResources, error) {
  ...
  -...type=\"mlu370.smlu.vcore\"})"
  +...type=~\".+[.]smlu[.]vcore\"})"
  ```
  </details>
- **NVIDIA 物理卡显存查询排除 MIG 实例**:DCGM 会把 MIG 实例的读数挂在父卡 UUID 下。之前 `deviceMemUsed`/`deviceMemTotal` 只按 `UUID` 过滤,会把 MIG 实例读数算进整卡;现在统一加 `dcgmWholeGPUMatchers = GPU_I_ID="",GPU_CI_ID=""`,只取整卡读数。https://github.com/Project-HAMi/HAMi-WebUI/commit/28d99fc4
  <details><summary>代码依据 server/internal/exporter/exporter.go / dcgm_samples.go</summary>

  ```diff
  +const dcgmWholeGPUMatchers = `GPU_I_ID="",GPU_CI_ID=""`
  ...
  -		query = fmt.Sprintf("avg(DCGM_FI_DEV_FB_USED{UUID=\"%s\"})", deviceUUID)
  +		query = fmt.Sprintf("avg(DCGM_FI_DEV_FB_USED{UUID=%q,%s})", deviceUUID, dcgmWholeGPUMatchers)
  ```
  </details>
- **海光 HCU/DCU 接入物理遥测**:`telemetryPlan` 的 provider 列表从 `{Nvidia, Ascend}` 扩到再加 `HygonHCUDevice`、`HygonGPUDevice`,按 node 分批查询。原来 Ascend 专用的 `ascendReading` 抽象成通用的 `nodeMetricLabels.reading`,通过 label schema 适配不同厂商(Ascend 用 `vdie_id`,Hygon 用 `device_id`/`minor_number`)。Hygon 用新增的 `DeviceIdentity.HygonBoardSerial()`(去掉 `HCU-`/`DCU-` 前缀,拒绝 `N/A`;DCU 拒绝纯数字的旧版节点内 index)和 exporter 做 join,并跳过 `vhcu_minor_number` 非空的虚拟卡读数。https://github.com/Project-HAMi/HAMi-WebUI/commit/10b39063
  <details><summary>代码依据 server/internal/exporter/resource_telemetry.go / node_observations.go / resourceview/identity.go</summary>

  ```diff
  -	for _, provider := range []string{biz.NvidiaGPUDevice, biz.AscendGPUDevice} {
  +	for _, provider := range []string{biz.NvidiaGPUDevice, biz.AscendGPUDevice, biz.HygonHCUDevice, biz.HygonGPUDevice} {
  ...
  +	ascendLabels = nodeMetricLabels{"vdie_id", "id", "pcie_bus_info", "model_name", ascendUtilization}
  +	hygonLabels  = nodeMetricLabels{deviceID: "device_id", index: "minor_number", pci: "pcieBus_number", model: "name"}
  ...
  +		if id.Provider == biz.HygonHCUDevice && labels["vhcu_minor_number"] != "" {
  +			continue
  +		}
  ...
  +func (id DeviceIdentity) HygonBoardSerial() (string, bool) {
  ```
  </details>

### 后续发展方向 [AI]
- **WebUI 的数据模型从「按 HAMi 注册注解拼出 vGPU 列表」转到「物理卡清单 + 分配事实 + 遥测三方 join,并带 coverage」**。新增的 `resourceview/`、`podfacts/`、`providerfacts/` 三个服务端包(本次只读了 identity.go 的 hunk,其余按文件名判断)和 proto 里的 `FieldState`(known/unknown/stale/conflict/not_applicable)说明,团队把「数据可信度」做成了一等字段。这和上期的解码失败指标、panic 兜底是同一条线,都是让多厂商异构集群的数字可信、可审计。证据边界:`pod_fact_allocations.go`、`informer_continuity.go` 未读 hunk。
- **WebUI 正在变成 HAMi 的指标出口和兼容性中心**(`hami_webui_device_*` 指标加 About 的 supported minor)。如果再出现按 namespace/租户的聚合 label,就是在往计量计费走;本期 label 集合里只有 node、device、model,没有租户维度。
- **多厂商纳管仍按 provider 模板推进**(见 [[hami-webui-provider-pattern]]):本期没有新增 `provider/<vendor>/` 目录,改动集中在已有厂商(寒武纪、海光、沐曦、昇腾)的数字正确性上;新增的 vendor logo(太初 tecorigin、壁仞 biren、昆仑芯 kunlunxin、瀚博 vastai 等)只是 UI 素材,不代表已纳管。

### 对我们产品的启示
- HAMi-core 修 Graph/VMM 绕过,说明「hook 式软隔离 + CUDA Graph 推理」长期存在超用风险。如果我们集成或对标 HAMi 做 LLM 推理切分,验收用例应加上 CUDA Graph 和 expandable segments 场景,并要求 HAMi-core 版本不低于本区间 HEAD 1fc9ea59。
- WebUI 的 coverage 设计(不完整不报 0、slots 不等于卡数)值得在我们的 GPU 看板和计量 API 里借鉴,可以避免多厂商 exporter 缺数时出现「0 利用率」误判。
- volcano-vgpu 升级到 1.13 会去掉 `volcano.sh/gpu-memory` 容忍,用了这个 taint 的环境要在 values 里补回。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos</summary>

- `Project-HAMi/ascend-device-plugin`:无新提交(仍 9325759b / ascend-device-plugin-0.2.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=fc2bcd0d24da4e409a792de02deaf57a143565ac branch=master release=v2.11.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=1fc9ea59cf1f94e16a7ddf6f445e129d282e1d03 branch=main release=— scanned=2026-11-18 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=e5b0164caef64359ea10a7430a15008fa6be2ecb branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=01b0ba234db547f3bcc0b9f916ba8664f0716ea0 branch=main release=v1.3.0 scanned=2026-11-18 -->
