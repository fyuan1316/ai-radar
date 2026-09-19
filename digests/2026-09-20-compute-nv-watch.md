# NVIDIA 算力栈 diff 雷达 2026-09-20

## 摘要
- **dcgm-exporter 4.8.4**:启动配置 schema `version: 1 → 2`,从单 `collection` 演进为多命名 `collections` + `sources`(向 nv-exporter catalog 靠拢)+ 新增 `server.maxConcurrentScrapes` 限制并发抓取;并落地对 NVIDIA DRA 驱动"动态 MIG"设备名的正则解析与 ResourceSlice generation 变更回调,补齐 DRA 场景下 MIG 指标归属。
- **k8s-device-plugin**:`NewDeviceListStrategies` 硬化——空/nil 策略列表直接报错(至少要一个),`AllCDIEnabled` 修正空集合下的假真返回;device-list 配置面收紧。
- **gpu-operator**:GFD/operator RBAC 补 `delete` nodefeatures 权限(可回收陈旧 NodeFeature CR);air-gapped 镜像清单生成器改为同时解析 OLM CSV `relatedImages`;container-toolkit v1.20.1 / dcgm 4.6.1 / dcgm-exporter 4.8.4 镜像跟进。

## 当日重要改变
- dcgm-exporter [API/CRD变更] 启动 YAML 配置版本 v1→v2:`YAMLConfig` 由单 `Collection` 改为 `Collections []CollectionConfig`(带 `name/every/metrics.include/sources`),新增顶层 `Sources`(dcgm)与 `Server.MaxConcurrentScrapes`;保留 `legacyV1`/`legacyYAMLConfigVersion=1` 做向后兼容。证据 internal/pkg/appconfig/yaml_config.go。https://github.com/NVIDIA/dcgm-exporter/compare/16ecae49e4d6174e556e768c87cd4e49d844b909...fafd151148052628061a80450b4ee037a5fa0c3c
- dcgm-exporter [新能力] DRA 动态 MIG 指标归属:新增 `draDynamicMIGNameRegex` 解析 DRA 驱动的 `gpu-<minor>-mig-<profile>-<id>-<placement>` 设备名,并给 ResourceSlice informer 加 pool generation 变更回调。证据 internal/pkg/transformation/dra.go。https://github.com/NVIDIA/dcgm-exporter/issues/714
- k8s-device-plugin [API/CRD变更] `api/config/v1/strategy.go`:`NewDeviceListStrategies` 拒绝空/nil 列表,`AllCDIEnabled` 在无任何 CDI 策略时返回 false(前为空集合下 vacuously true)。https://github.com/NVIDIA/k8s-device-plugin/compare/674f626b4a6bd353e0cb2e01b5ef6f9d75adb4f2...1a7c1f8a9c074efd3ff2063a689195dea461f178

## NVIDIA/dcgm-exporter: 16ecae49 -> fafd1511
- 比较:https://github.com/NVIDIA/dcgm-exporter/compare/16ecae49e4d6174e556e768c87cd4e49d844b909...fafd151148052628061a80450b4ee037a5fa0c3c | 最新 Release: 4.8.4 https://github.com/NVIDIA/dcgm-exporter/releases/tag/4.8.4
- 一次 squash 提交(152 文件),下面结论基于关键 hunk;部分文件 hunk 被截断(未覆盖全量)。

### AI 总结重点(源码 diff 为据)
- **启动配置 schema v1→v2,从"单一采集组"升级为"多命名采集 + 分源 + 服务器段"**:`yamlConfigVersion` 由 1 升到 2 并保留 `legacyYAMLConfigVersion=1`;`YAMLConfig` 删掉单个 `Collection *YAMLCollection`,改为 `Collections []CollectionConfig`(每项含 `name`、`every`、`metrics.include`、可选 `sources`),另加顶层 `Sources *YAMLSources`(内含 `dcgm`)和 `Server *YAMLServer`。注释明确 include 仍是 dcgm-exporter 现有 glob 语义、不是 nv-exporter catalog 的 SignalId——即在保持旧语义下向 nv-exporter 配置形态收敛。
  <details><summary>代码依据 internal/pkg/appconfig/yaml_config.go</summary>

  ```diff
  -const yamlConfigVersion = 1
  +const (
  +	yamlConfigVersion       = 2
  +	legacyYAMLConfigVersion = 1
  +)
   type YAMLConfig struct {
  -	Version    int             `yaml:"version"`
  -	Metrics    *YAMLMetrics    `yaml:"metrics,omitempty"`
  -	Collection *YAMLCollection `yaml:"collection,omitempty"`
  +	Version     int                `yaml:"version"`
  +	Metrics     *YAMLMetrics       `yaml:"metrics,omitempty"`
  +	Collections []CollectionConfig `yaml:"collections,omitempty"`
  +	Sources     *YAMLSources       `yaml:"sources,omitempty"`
  +	Server      *YAMLServer        `yaml:"server,omitempty"`
  +	legacyV1 *yamlV1Config
  +}
  +type YAMLServer struct {
  +	MaxConcurrentScrapes *int `yaml:"maxConcurrentScrapes,omitempty"`
  +}
  ```
  </details>
- **新增抓取并发上限**:`server.maxConcurrentScrapes` 配置项落地(配合新增 `internal/pkg/server/scrape_coordinator*.go`),给 Prometheus 高频/多副本抓取加背压。见上 hunk 的 `YAMLServer.MaxConcurrentScrapes`。
- **导出器自监控指标可开关**:`YAMLMetrics` 增加 `EnableExporterMetrics *bool`,开启 Go runtime/process/HTTP handler 指标。
  <details><summary>代码依据 internal/pkg/appconfig/yaml_config.go</summary>

  ```diff
   type YAMLMetrics struct {
   	File   string            `yaml:"file,omitempty"`
   	Fields []YAMLMetricField `yaml:"fields,omitempty"`
  +	// EnableExporterMetrics enables Go runtime, process, and HTTP handler metrics.
  +	EnableExporterMetrics *bool `yaml:"enableExporterMetrics,omitempty"`
   }
  ```
  </details>
- **DRA 动态 MIG 设备名解析,补齐 DRA 场景的 MIG 指标归属**:`dra.go` 新增 `draDynamicMIGNameRegex = ^gpu-(\d+)-mig-.+-(\d+)-(\d+)$`,对齐 DRA 驱动 `cmd/gpu-kubelet-plugin/mig.go` 的命名(捕获父卡 minor、profileID、placement start);`NewDRAResourceSliceManager` 改为内部 `newDRAResourceSliceManager(onGenerationChange)`,给 ResourceSlice informer 挂 Add/Update/Delete 事件与 pool generation 基线,pool 代次变化时回调刷新——DRA 下 ResourceSlice 变更能触发指标标签重算。
  <details><summary>代码依据 internal/pkg/transformation/dra.go</summary>

  ```diff
  +	// draDynamicMIGNameRegex matches the NVIDIA DRA driver's dynamic MIG schema:
  +	// gpu-<parentMinor>-mig-<profile>-<profileID>-<placementStart>.
  +	draDynamicMIGNameRegex = regexp.MustCompile(`^gpu-(\d+)-mig-.+-(\d+)-(\d+)$`)
  -	m := &DRAResourceSliceManager{factory: factory}
  +	m := &DRAResourceSliceManager{
  +		factory:             factory,
  +		onGenerationChange:  onGenerationChange,
  +		generationBaselines: make(map[string]int64),
  +	}
  +		if _, err := informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
  +			AddFunc:    m.observeResourceSlice,
  +			UpdateFunc: func(_, newObj any) { m.observeResourceSlice(newObj) },
  +			DeleteFunc: m.observeResourceSlice,
  +		}); err != nil {
  ```
  </details>
- **PodMapper 生命周期与 MIG 计算实例标签硬化**:新增保留标签 `GPU_CI_ID`(compute instance,与已有 `GPU_I_ID`/`GPU_I_PROFILE` 并列),使 MIG compute-instance 级指标不被当作 pod 标签污染;`Stop()` 变为带互斥的幂等实现,关闭 grpc 连接并停掉 ResourceSliceManager;gRPC 就绪判断由 `resolver` 改为 `connectivity`;`newDRAResourceSliceManagerFunc` 接入 `c.DRAResourceSliceChangeCallback()`。
  <details><summary>代码依据 internal/pkg/transformation/kubernetes.go</summary>

  ```diff
   	rendererReservedLabels = map[dcgm.Field_Entity_Group]map[string]struct{}{
   		dcgm.FE_GPU: {
  +			"GPU_CI_ID":     {},
   			"GPU_I_ID":      {},
   			"GPU_I_PROFILE": {},
  -		resourceSliceManager, err := newDRAResourceSliceManagerFunc()
  +		resourceSliceManager, err := newDRAResourceSliceManagerFunc(c.DRAResourceSliceChangeCallback())
   	func (p *PodMapper) Stop() {
  +	p.grpcConnMu.Lock()
  +	defer p.grpcConnMu.Unlock()
  +	if p.stopped { return }
  +	p.stopped = true
   	close(p.stopChan)
  ```
  </details>
- **WatchList 支持 compute-instance 字段与采样保留策略**:`WatchList` 新增 `computeInstanceFields`、`fieldsAtMultipleScopes`、`maxKeepAge`、`maxKeepSamples`;构造走内部 `newWatchListWithGroups(...)` 注入默认 `DefaultWatchMaxKeepAge`/`DefaultWatchMaxSamples`——即 DCGM 侧 watch 的样本保留时长/条数变成可配置策略,并支持在多 scope(GPU / MIG CI)同时观测同一字段。
  <details><summary>代码依据 internal/pkg/devicewatchlistmanager/device_watchlist_manager.go</summary>

  ```diff
   type WatchList struct {
  +	computeInstanceFields  []dcgm.Short
  +	fieldsAtMultipleScopes []dcgm.Short
  +	maxKeepAge             float64
  +	maxKeepSamples         int32
   }
  ```
  </details>
- **合规:引入 THIRD_PARTY_NOTICES 生成工具链**:新增 `hack/licenses/{generate,container}.go` 等,为 distroless 镜像按 GOOS/GOARCH 收集依赖法务文件并拼装(伴随 10462 行 `THIRD_PARTY_NOTICES`)。属发布工程,不影响运行时。

### 后续发展方向 [AI]
- 配置面明显朝 nv-exporter 统一 catalog 收敛(`sources.dcgm`、`collections` 命名组),但注释刻意声明 include 仍是旧 glob 语义、非 SignalId——判断是"外壳先兼容、语义后迁移"的过渡态;证据只覆盖 yaml_config.go 的类型定义,未见 v2→运行时的解析/校验路径,catalog 是否真正接管尚不能确认。
- DRA + MIG 的指标归属是本次重心(regex 解析 + ResourceSlice generation 回调 + GPU_CI_ID 标签),方向是让 dcgm-exporter 在 DRA 原生分片路径下与经典 device-plugin 路径达到同等的 pod/MIG 归属精度;证据只覆盖 dra.go/kubernetes.go 的接线,未逐测试用例验证归属正确性。

## NVIDIA/k8s-device-plugin: 674f626b -> 1a7c1f8a
- 比较:https://github.com/NVIDIA/k8s-device-plugin/compare/674f626b4a6bd353e0cb2e01b5ef6f9d75adb4f2...1a7c1f8a9c074efd3ff2063a689195dea461f178 | 最新 Release: v0.20.0

### AI 总结重点(源码 diff 为据)
- **device-list 策略配置硬化,拒绝空配置**:`NewDeviceListStrategies` 新增前置校验——空/nil 列表直接返回错误(要求 envvar/volume-mounts/cdi-annotations/cdi-cri 至少一个);策略表构造抽出 `supportedDeviceListStrategies` 切片统一初始化。同时 `AllCDIEnabled` 先判 `AnyCDIEnabled`,无任何 CDI 策略时返回 false,修掉空集合下"全 CDI 成立"的假真。
  <details><summary>代码依据 api/config/v1/strategy.go</summary>

  ```diff
  +var supportedDeviceListStrategies = []string{
  +	DeviceListStrategyEnvVar, DeviceListStrategyVolumeMounts,
  +	DeviceListStrategyCDIAnnotations, DeviceListStrategyCDICRI,
  +}
   func NewDeviceListStrategies(strategies []string) (DeviceListStrategies, error) {
  +	if len(strategies) == 0 {
  +		return nil, fmt.Errorf("no device list strategy specified; at least one of %v is required", supportedDeviceListStrategies)
  +	}
   func (s DeviceListStrategies) AllCDIEnabled() bool {
  +	if !s.AnyCDIEnabled() {
  +		return false
  +	}
  ```
  </details>
- **GFD RBAC 补 delete**:helm role 给 `nfd.k8s-sigs.io/nodefeatures` 加 `delete` verb,GFD 可回收陈旧 NodeFeature CR(与 gpu-operator 侧同源修复)。
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/templates/role.yml</summary>

  ```diff
  -    verbs: ["get", "list", "watch", "create", "update"]
  +    verbs: ["get", "list", "watch", "create", "update", "delete"]
  ```
  </details>

### 后续发展方向 [AI]
- 属健壮性收口而非能力扩张:把"空策略"从静默默认(旧代码初始化全 false 的 map)变成显式报错,减少 CDI 迁移期误配。证据只覆盖 strategy.go + 单测,未见调用方(命令行 flag 解析)是否已同步要求非空。

## NVIDIA/gpu-operator: 93c0ff56 -> bf73d076
- 比较:https://github.com/NVIDIA/gpu-operator/compare/93c0ff560ca71e761d6c1782d904765bb88de3db...bf73d0763dcb3a76946699d382a179de386a3696 | 最新 Release: v26.7.0

### AI 总结重点(源码 diff 为据)
- **GFD/operator RBAC 补 delete nodefeatures**:`role.yaml`、`assets/gpu-feature-discovery/0200_role.yaml` 与 OLM CSV 均给 nodefeatures 资源加 `delete`,使 GFD 能删除过期 NodeFeature CR。
  <details><summary>代码依据 deployments/gpu-operator/templates/role.yaml</summary>

  ```diff
     - watch
     - create
     - update
  +  - delete
  ```
  </details>
- **air-gapped 镜像清单改为同时解析 OLM bundle**:`generate-image-list.py` 新增 `--csv` 参数解析 CSV `spec.relatedImages`,并加 `_resolve_image_digest`(对镜像 tag 发 registry HEAD 请求取 `Docker-Content-Digest`,产出 tag@digest);`update-csv-images.py` 把 DCGM 从 `RELATED_IMAGE_COMPONENTS`/`ENV_IMAGE_COMPONENTS` 映射中移除(OLM 用 UBI 版 dcgm、Helm 用 Ubuntu 版,CSV 引用需与 values.yaml 解耦),并新增 `APP_VERSION_COMPONENTS={operator,validator}` 在 values.yaml 缺版本时回落到 chart `appVersion`。
  <details><summary>代码依据 .github/scripts/update-csv-images.py</summary>

  ```diff
  +# DCGM is intentionally omitted ... OLM bundle uses a UBI-based DCGM image
  +# while the Helm chart uses Ubuntu ...
   RELATED_IMAGE_COMPONENTS = {
  -    "dcgm-image": "dcgm",
  +APP_VERSION_COMPONENTS = {"operator", "validator"}
  +		if not version and component_path in APP_VERSION_COMPONENTS:
  +			version = (chart.get("appVersion") or "").strip()
  ```
  </details>
- **组件镜像跟进**:`values.yaml`/CSV 里 container-toolkit `v1.20.0→v1.20.1`、dcgm `4.6.0→4.6.1`、dcgm-exporter `4.6.0-4.8.3→4.6.1-4.8.4-distroless`。

### 后续发展方向 [AI]
- 本期无 ClusterPolicy CRD(`api/nvidia/v1/clusterpolicy_types.go`)字段增删,均为发布工程(OLM/air-gapped 镜像清单)与 RBAC 修复;OLM 与 Helm 双打包路径的镜像引用解耦(DCGM UBI vs Ubuntu)是持续趋势。证据只覆盖脚本与 values/CSV,未见 controller 逻辑改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 仅 bump·CI·merge 的 repo</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 未动,Release v1.20.1)
- NVIDIA/gpu-driver-container — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(Release v0.5.0)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/mig-parted — ahead=2,仅 bump/CI/merge,无实质源码(Release v0.15.0)
- kai-scheduler/KAI-Scheduler — 无新提交(Release v0.17.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=bf73d0763dcb3a76946699d382a179de386a3696 branch=main release=v26.7.0 scanned=2026-09-20 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3a6c050d9c0c7b2516ce17e2190fb7e71b741f82 branch=main release=v1.20.1 scanned=2026-09-20 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=2e703a2ef0232fd865863ecd6eb3dfa8e9cc7636 branch=main release=— scanned=2026-09-20 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1a7c1f8a9c074efd3ff2063a689195dea461f178 branch=main release=v0.20.0 scanned=2026-09-20 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=1fc50b37bafb4fc30d92cfb6ca77faecd5c9fb76 branch=main release=v0.5.0 scanned=2026-09-20 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-09-20 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-20 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=b62deb6b8d43c74be46c376ded0d2ebd6b2dfc77 branch=main release=v0.15.0 scanned=2026-09-20 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=90f9eb339926ae028ea3589ac451da4c8ccd05c2 branch=main release=v0.17.2 scanned=2026-09-20 -->
