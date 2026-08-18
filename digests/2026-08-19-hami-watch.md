# HAMi diff 雷达 2026-08-19

## 摘要
- HAMi **Ascend vNPU 内存请求语义变化**:`update ascend trim` 删掉了非 core(模板/硬切分)路径上的 `trimMemory` 调用,改为一律 `memnum = int(memnums)` 直接用原始请求值;紧接着 #2601 给整个 `GenerateResourceRequests` 补 int32 溢出/负值防护(拒绝把 16Gi 这类误当 Byte 的超 int32 值、负内存、超 int32 核数)。
- ascend-device-plugin **向后兼容 HAMi ≤v2.8.x 配置布局**:`LoadConfig` 现在同时读 v2.9.0 的 `vnpus.configs` 与旧版 `vnpus` 列表,靠 `json.UnmarshalTypeError`(field=vnpus,value=array)识别旧格式并降级 + 打告警,使插件可先于 HAMi 升级(#127)。
- HAMi 健壮性/可观测性小修:调度器在 vendor 上报 0 设备时清除陈旧缓存避免虚报容量(#2550);host GPU 内存/利用率指标补 `node` 标签(#2580)、node 内存占比指标补 `device_type` 标签(#2554)。HAMi-core / volcano-vgpu-device-plugin / HAMi-WebUI 三仓无新提交。

## 当日重要改变(命中信号才列;无则写"无")
- 无严格信号命中(未触及弃用/移除、API/CRD、proposal/design、版本跨档、新增顶层 package)。**但需留意 HAMi Ascend 内存 trim 语义有变**(切分相关行为改动,非信号类但影响分配),详见正文 `pkg/device/ascend/device.go`。

## Project-HAMi/HAMi: 45b3d467 -> e803f758
- 比较: https://github.com/Project-HAMi/HAMi/compare/45b3d46769b44cfc1445728dfcb8e524939afba1...e803f758 | ahead=14 | files=21 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)

- **Ascend 内存请求不再做 template 对齐(trim),非 core 路径改为直用原始值**。旧代码按"是否请求了 core"分叉:请求 core(软切分)→ 直接用 `memnums`;否则 → `trimMemory(memnums)` 把请求向模板档位取整。新代码删除整个分叉,统一 `memnum = int(memnums)`。即无论软切分还是模板/硬切分,内存都按用户原始请求透传,不再被 `trimMemory` 收敛到最近模板档。
  <details><summary>代码依据 pkg/device/ascend/device.go(commit 7a9fbb76 "update ascend trim")</summary>

  ```diff
  -					// If "core" is requested, it explicitly indicates the use of soft-partitioning.
  -					isCoreRequested := false
  -					if ascendResourceCore != "" {
  -						_, isCoreRequested = ctr.Resources.Limits[ascendResourceCore]
  -						if !isCoreRequested {
  -							_, isCoreRequested = ctr.Resources.Requests[ascendResourceCore]
  -						}
  -					}
  -
  -					if isCoreRequested {
  -						// Soft-partitioning: Use the raw value directly.
  -						memnum = int(memnums)
  -					} else {
  -						m, _ := dev.trimMemory(memnums)
  -						memnum = int(m)
  -					}
  +					memnum = int(memnums)
  ```
  </details>

- **`GenerateResourceRequests` 补 int32 收窄/符号防护,非法请求直接拒绝(返回空 ContainerDeviceRequest)**(#2601)。设备数 `n<=0 || n>MaxInt32`、内存 `mem.Sign()<0`、内存 `memnums>MaxInt32`(明确报"单位是 MB 不是 Byte,16Gi 该写 16384")、乘以 `MemoryFactor` 后再越界、核数 `<0 || >MaxInt32` 各自单独校验并 `klog.ErrorS` 后 return。防止把 Byte 量误当 MB、负值、int32 溢出造成错误分配。
  <details><summary>代码依据 pkg/device/ascend/device.go(#2601)</summary>

  ```diff
  +			if n <= 0 || n > math.MaxInt32 {
  +				klog.ErrorS(nil, "ascend device count request is out of range", ...)
  +				return device.ContainerDeviceRequest{}
  +			}
  ...
  +				if mem.Sign() < 0 { ...; return device.ContainerDeviceRequest{} }
  +					if memnums > math.MaxInt32 {
  +						klog.ErrorS(nil, "ascend device memory request is out of range; memory unit is treated as MB not Byte, so a quantity such as 16Gi is invalid, request 16384 for 16GB instead", ...)
  +						return device.ContainerDeviceRequest{}
  +					}
  ```
  </details>

- **调度器缓存一致性:vendor 健康但上报 0 设备时,删除该节点的陈旧设备缓存条目**(#2550)。原逻辑只在 `GetNodeDevices` 出错时 `rmNodeDevices`;新增分支:成功但 `len(nodedevices)==0` 且缓存里仍有该 vendor 条目时,主动 `rmNodeDevices` 后 `continue`,避免调度器继续按已消失的设备派发容量。
  <details><summary>代码依据 pkg/scheduler/scheduler.go(#2550)</summary>

  ```diff
  +			if len(nodedevices) == 0 {
  +				if existingNode, getNodeErr := s.GetNode(val.Name); getNodeErr == nil {
  +					if _, ok := existingNode.Devices[devhandsk]; ok {
  +						klog.InfoS("Vendor reports zero devices, removing stale cache entry", ...)
  +						s.rmNodeDevices(val.Name, devhandsk)
  +					}
  +				}
  +				continue
  +			}
  ```
  </details>

- **host GPU 指标补 `node` 标签**(#2580):`hami_host_gpu_memory_used_bytes` 与 `hami_host_gpu_utilization_ratio`(及 legacy `HostGPUMemoryUsage`/`HostCoreUtilization`)的 label 集从 `[device_index,device_uuid,device_type]` 增加到含 `node`,采集时读 `NodeName` 环境变量,缺失即 return error。多节点场景下 host 级 GPU 指标此前无法按节点区分,现补齐。顺带把与 `util` 包同名的局部变量 `util` 改名 `utilRates` 消除遮蔽。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go(#2580)</summary>

  ```diff
  -		[]string{"device_index", "device_uuid", "device_type"}, nil,
  +		[]string{"node", "device_index", "device_uuid", "device_type"}, nil,
  +	nodeName := os.Getenv(util.NodeNameEnvName)
  +	if nodeName == "" {
  +		return fmt.Errorf("node name environment variable %s is not set", util.NodeNameEnvName)
  +	}
  ```
  </details>

- **node 内存占比指标补 `device_type` 标签**(#2554,承接 #2370):`hami_node_gpu_memory_allocated_ratio` 的 label 从 `[node,device_uuid,device_index]` 增加 `device_type`,发送时多带 `devs.Device.Type`,便于按卡型聚合内存分配率。
  <details><summary>代码依据 cmd/scheduler/metrics.go(#2554)</summary>

  ```diff
  -		[]string{"node", "device_uuid", "device_index"}, nil,
  +		[]string{"node", "device_uuid", "device_index", "device_type"}, nil,
  -		..., nodeID, devs.Device.ID, fmt.Sprint(devs.Device.Index)); err != nil {
  +		..., nodeID, devs.Device.ID, fmt.Sprint(devs.Device.Index), devs.Device.Type); err != nil {
  ```
  </details>

### 后续发展方向 [AI]
- 删除 `trimMemory` 是 Ascend 内存分配从"服务端向模板档位取整"转向"信任上层请求值"的一步:证据(device.go diff)显示非 core 路径不再自动对齐模板,配套 #2601 的严格越界拒绝说明改由校验+报错兜底而非静默 trim。这意味着请求值若不匹配任何 vNPU 模板,后果从"被悄悄下调"变为"由后续模板匹配逻辑决定成败";证据只覆盖 `GenerateResourceRequests` 入口,未见下游模板匹配(`trimMemory` 定义处及调用方)是否还有其它对齐点,不能断言模板对齐已完全移除。
- 本期 HAMi 无切分内核(hook/时分)本身的改动,变化集中在 Ascend 资源请求校验、调度缓存一致性、指标标签三块——均属可观测性与健壮性硬化,方向是"多节点/多卡型可观测 + 输入防呆",非新增虚拟化能力。证据只覆盖上述 5 个 diff,未逐 PR 展开。

## Project-HAMi/ascend-device-plugin: 771e19f8 -> 1cf92f2f
- 比较: https://github.com/Project-HAMi/ascend-device-plugin/compare/771e19f836103727bc84d0bda29ba6a03538e5f2...1cf92f2f | ahead=2 | files=5 | Release: —

### AI 总结重点(源码 diff 为据)
- **`LoadConfig` 双布局兼容:同时读 HAMi v2.9.0 的 `vnpus.configs` 与 ≤v2.8.x 的 `vnpus` 列表**(#127)。先按新 `Config`(vnpus 为含 `hamiVnpuCore`+`configs` 的映射)解析;失败且 `isLegacyVNPUsLayout(err)` 为真(`json.UnmarshalTypeError.Field=="vnpus" && Value=="array"`,即 vnpus 是数组)时,回退用 `legacyConfig`(vnpus 为 `[]VNPUConfig` 列表 + 顶层 `hamiVnpuCore`)重解,并组装回统一 `Config{VNPUs:{HamiVnpuCore, Configs}}`,同时打告警提示升级 HAMi 才能用 `vnpus.hamiVnpuCore` 与 hami-core 软切分。其它解析错误(含 vnpus 内部深层错)保留原错误信息,不误判为旧布局。
  <details><summary>代码依据 internal/vnpu.go(#127)</summary>

  ```diff
  +type legacyConfig struct {
  +	HamiVnpuCore bool         `json:"hamiVnpuCore,omitempty"`
  +	VNPUs        []VNPUConfig `json:"vnpus"`
  +}
  +func isLegacyVNPUsLayout(err error) bool {
  +	var typeErr *json.UnmarshalTypeError
  +	return errors.As(err, &typeErr) && typeErr.Field == "vnpus" && typeErr.Value == "array"
  +}
   func LoadConfig(path string) (*Config, error) {
  ...
  -	if err != nil {
  +	if err == nil {
  +		return &yamlData, nil
  +	}
  +	if !isLegacyVNPUsLayout(err) {
   		return nil, err
   	}
  -	return &yamlData, nil
  +	var legacy legacyConfig
  +	if err := yaml.Unmarshal(data, &legacy); err != nil { return nil, err }
  +	klog.Warningf("%s uses the device config layout of HAMi <= v2.8.x ...", path)
  +	return &Config{VNPUs: VNPUsConfig{HamiVnpuCore: legacy.HamiVnpuCore, Configs: legacy.VNPUs}}, nil
  ```
  </details>
- 文档(`docs/hami.md`/`hami_cn.md`)同步说明:HAMi v2.9.0 把 Ascend 芯片列表从 `vnpus` 挪到 `vnpus.configs`,插件两种都读、回退旧格式会告警,故可先于 HAMi 升级;跨命名空间合并 ConfigMap 时,若 HAMi <v2.9.0 要保留旧 `vnpus` 列表写法(其调度器读不了 `vnpus.configs`)。新增 `internal/vnpu_test.go`(+279)与 `manager_test.go`(+121)覆盖两版布局多芯片解析。

### 后续发展方向 [AI]
- 该改动解绑了 ascend-device-plugin 与 HAMi 的版本升级顺序,是生态成熟度信号(插件可独立于主仓迭代)。证据(vnpu.go diff)明确降级仅针对 `vnpus` 为数组这一种 mismatch,其它错误照旧报错,兼容面是窄而精准的;证据只覆盖 `LoadConfig`,未见 `VNPUConfig` 字段是否在两版间还有差异,不能断言旧布局所有字段都被无损映射。

## 本期无实质改动(折叠)
<details><summary>3 仓无新提交</summary>

- Project-HAMi/HAMi-core(5496322f,无新提交)
- Project-HAMi/volcano-vgpu-device-plugin(4fb76ba1,无新提交)
- Project-HAMi/HAMi-WebUI(fa9b560d,Release hami-webui-1.2.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=e803f7584137e08e134d00c8da9436f04b2bff17 branch=master release=v2.9.0 scanned=2026-08-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-19 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4fb76ba16a1744b161e9e2fbfc0b9ec3a546dd9b branch=main release=— scanned=2026-08-19 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf92f2ff25cebfe6f6752c1d50bbb729fb0683e branch=main release=— scanned=2026-08-19 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-19 -->
