# NVIDIA 算力栈 diff 雷达 2026-10-10

## 摘要
- **dra-driver-nvidia-gpu 把 VFIO 直通从"硬依赖 IOMMU、否则插件启动即失败"改成"节点级优雅降级"**:新增 `deviceLib.vfioEnabled` 字段在启动时探测一次 IOMMU,所有 VFIO 代码路径从 `PassthroughSupport` 单门改为 `PassthroughSupport && IsVfioEnabled()`;无 IOMMU 的节点继续正常服务 GPU、只是不再广告 VFIO 设备。紧接昨日(10-09)`enableAPIDevice` 默认翻转,VFIO 路径连续两天在加固(PR#1419)。
- **k8s-device-plugin 用生成的 `values.schema.json`(draft-07)替代手写模板校验**,顺带删掉 `validation.yml` 里 `nvidiaDriverCapabilities` 必须为字符串的 fail 逻辑、新增 `nvidiaDevRoot` 配置项、修 `_helpers.tpl` 数字 image.tag 被当 float64 打印成科学计数法的 bug(PR#2084)。属 chart 工程化,非 device-plugin 运行时能力变化。
- 其余 7 仓(gpu-operator / container-toolkit / gpu-driver-container / dcgm-exporter / DCGM / mig-parted / KAI-Scheduler)本期无实质改动。

## 当日重要改变
- **dra-driver-nvidia-gpu** `[架构方向]` VFIO 可用性判定从"全局 feature gate"下沉为"节点本地能力探测",混合集群(部分节点无 IOMMU)不再因个别节点拖垮整个 kubelet plugin。证据:`cmd/gpu-kubelet-plugin/nvlib.go`、`device_state.go`、`vfio-device.go`;https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/pull/1419
- **k8s-device-plugin** `[API/CRD变更]` 新增 Helm 值契约 `values.schema.json` 并删除运行时模板校验分支;新增 `nvidiaDevRoot` 值。证据:`deployments/helm/nvidia-device-plugin/values.schema.json`、`values.yaml`、`templates/validation.yml`;https://github.com/NVIDIA/k8s-device-plugin/pull/2084

## kubernetes-sigs/dra-driver-nvidia-gpu: b92f77b8 -> fb8b9674
- 比较: b92f77b8 -> fb8b9674 | ahead=8 | files=6 | Release: v0.5.0
- 比较链接: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/b92f77b8704f087299f59abebad944b94561ff0f...fb8b9674749c15b35f3bc7535c2e796c86463397

### AI 总结重点(源码 diff 为据)
- **IOMMU 探测从"用到才查、查不到就报错"改为"启动时查一次、存成节点能力位"**。`newDeviceLib` 在 `PassthroughSupport` 开启时调用 `checkIommuEnabled(hostRoot)`,结果存入新字段 `deviceLib.vfioEnabled`,并通过新方法 `IsVfioEnabled()` 暴露。探测失败(读 iommu_groups 出错)仍硬失败,但 iommu_groups 为空/不存在只是 `vfioEnabled=false`、不报错。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/nvlib.go</summary>

  ```diff
   type deviceLib struct {
  +	// vfioEnabled records node-local IOMMU capability.
  +	vfioEnabled       bool
   }

   func newDeviceLib(driver *root.Driver, hostRoot string) (*deviceLib, error) {
  +	vfioEnabled := false
  +	if featuregates.Enabled(featuregates.PassthroughSupport) {
  +		var err error
  +		vfioEnabled, err = checkIommuEnabled(hostRoot)
  +		if err != nil {
  +			return nil, fmt.Errorf("error checking if IOMMU is enabled: %w", err)
  +		}
  +	}
  +func (d *deviceLib) IsVfioEnabled() bool {
  +	return d.vfioEnabled
  +}
  ```
  </details>
- **所有 VFIO 代码路径的门禁从单条件 `PassthroughSupport` 收紧为双条件 `PassthroughSupport && IsVfioEnabled()`**:设备枚举(`enumerateAllPossibleDevices`/`GetPerGpuAllocatableDevices`)、Prepare/Unprepare、回滚、sibling 发现等全部加上节点能力位。效果是无 IOMMU 节点"只服务普通 GPU、不枚举 VFIO 设备"而非启动失败。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  -	if featuregates.Enabled(featuregates.PassthroughSupport) {
  -		vfioPciManager, err = NewVfioPciManager(driver.Root, hostDriverRoot, nvdevlib, true)
  -		if err != nil {
  -			return nil, fmt.Errorf("unable to create vfio pci manager: %w", err)
  -		}
  +	if featuregates.Enabled(featuregates.PassthroughSupport) && nvdevlib.IsVfioEnabled() {
  +		vfioPciManager = NewVfioPciManager(driver.Root, hostDriverRoot, nvdevlib, true)
   	}
   ...
  -	if !device.Gpu.vfioEnabled {
  +	if !featuregates.Enabled(featuregates.PassthroughSupport) || !s.nvdevlib.IsVfioEnabled() || !device.Gpu.vfioEnabled {
   		return nil
  ```
  </details>
- **`NewVfioPciManager` 签名去掉 error 返回值**。旧实现在构造函数内 `checkIommuEnabled`,IOMMU 关闭时返回 `"IOMMU is not enabled in the kernel"` 错误(进而导致插件启动失败);现在 IOMMU 探测已上移到 `newDeviceLib`,构造函数变成纯赋值、不再可能失败。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/vfio-device.go</summary>

  ```diff
  -func NewVfioPciManager(...) (*VfioPciManager, error) {
  -	iommuEnabled, err := checkIommuEnabled(nvlib.hostRoot)
  -	if err != nil {
  -		return nil, fmt.Errorf("error checking if IOMMU is enabled: %w", err)
  -	}
  -	if !iommuEnabled {
  -		return nil, fmt.Errorf("IOMMU is not enabled in the kernel")
  -	}
  +func NewVfioPciManager(...) *VfioPciManager {
   	vm := &VfioPciManager{ ... }
  -	return vm, nil
  +	return vm
   }
  ```
  </details>
- **文档同步改口径**:从"IOMMU 关闭 + PassthroughSupport 开启则插件无法启动"改为"无 IOMMU 时插件继续服务普通 GPU、仅不广告 VFIO 设备"。
  <details><summary>代码依据 site/content/docs/guides/gpu-allocation/kubevirt-vfio-gpu-passthrough.md</summary>

  ```diff
  -- **IOMMU enabled** on GPU nodes. VFIO passthrough requires IOMMU; the GPU kubelet plugin fails to start with `PassthroughSupport` enabled if IOMMU is off.
  +- **IOMMU enabled** on GPU nodes intended for VFIO passthrough. Without IOMMU, the GPU kubelet plugin continues serving normal GPU devices but does not advertise VFIO devices.
  ```
  </details>

### 后续发展方向 [AI]
- VFIO/直通路径(DRA 原生,非 HAMi 软切分)正在为"异构混合集群"做鲁棒性收尾:连续两天(10-09 `enableAPIDevice` 默认翻转 → 10-10 IOMMU 优雅降级)都在打磨直通可用性,方向是让 KubeVirt + DRA 的 GPU 直通能在部分节点无 IOMMU 的现实集群里安全开全局 feature gate。证据覆盖 kubelet-plugin 的能力探测与门禁改造,未见 scheduler/CRD 侧字段变化(本期无 `api/` 路径命中),即判定仍停留在节点本地能力位、尚未上升到 ResourceSlice 对 VFIO 可用性的声明。

## NVIDIA/k8s-device-plugin: d5dce58a -> bd98fbd6
- 比较: d5dce58a -> bd98fbd6 | ahead=2 | files=12 | Release: v0.20.1
- 比较链接: https://github.com/NVIDIA/k8s-device-plugin/compare/d5dce58aff4ddf572dc52666f949b37d6be2846c...bd98fbd6b676c655d235857574bdca29ab562dbc

### AI 总结重点(源码 diff 为据)
- **Helm 值校验从"手写模板 fail 逻辑"迁移到"生成的 JSON Schema(draft-07)"**。新增 434 行 `values.schema.json`,由 `helm-values-schema-json` 工具从 `values.yaml` 的 `# @schema` 注解生成;CI 新增 `check-helm-values-schema`(校验 schema 未过期)+ `lint-helm`。原来放在 `validation.yml` 里的 `nvidiaDriverCapabilities` 必须为字符串的 fail 分支被删除,改由 schema 的类型约束兜底。
  <details><summary>代码依据 templates/validation.yml(删除)+ Makefile(新增)</summary>

  ```diff
  - {{- if not (or (kindIs "invalid" .Values.nvidiaDriverCapabilities) (typeIs "string" .Values.nvidiaDriverCapabilities)) }}
  - {{- $error = printf "%s\nValue 'nvidiaDriverCapabilities' must be a string, got %s: %v" ... }}
  - {{- fail $error }}
  - {{- end }}
  ```
  ```diff
  +helm-values-schema: bin/helm-values-schema-json
  +	cd $(HELM_CHART_DIR) && .../helm-values-schema-json --draft 7 --indent 2 --values values.yaml --output values.schema.json
  +check-helm-values-schema: helm-values-schema
  +	@git diff --exit-code -- $(HELM_CHART_DIR)/values.schema.json || { echo "ERROR: values.schema.json is stale..."; exit 1; }
  ```
  </details>
- **新增 `nvidiaDevRoot` 配置项**(与既有 `nvidiaDriverRoot` 并列,均默认 null),延续 container-toolkit 侧 driver-root / dev-root 分离的设计,让设备节点路径可独立于驱动库路径配置。
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/values.yaml</summary>

  ```diff
  +# @schema type:[string, null]
   nvidiaDriverRoot: null
  +# @schema type:[string, null]
  +nvidiaDevRoot: null
  ```
  </details>
- **修 `_helpers.tpl` 的 image.tag 数字处理 bug**:旧代码用 `default`,会把数字 0 当未设、且 values 文件里的数字是 float64,`20260101` 会被打印成 `2.0260101e+07`;新代码按 kind 分支处理字符串/数字 tag 并 `int64|toString`。
  <details><summary>代码依据 templates/_helpers.tpl</summary>

  ```diff
  -{{- $tag := printf "v%s" .Chart.AppVersion }}
  -{{- .Values.image.repository -}}:{{- .Values.image.tag | default $tag -}}
  +{{- $imageTag := printf "v%s" .Chart.AppVersion }}
  +{{- if kindIs "string" .Values.image.tag }}
  +{{- if .Values.image.tag }}{{- $imageTag = .Values.image.tag }}{{- end }}
  +{{- else if not (kindIs "invalid" .Values.image.tag) }}
  +{{- $imageTag = .Values.image.tag | int64 | toString }}
  +{{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- 这期纯 chart 工程化(schema 契约 + CI gate + 两处 bugfix),无 device-plugin 运行时(time-slicing/MPS/CDI)逻辑变化,证据仅覆盖 `deployments/helm` 与 `Makefile`,`cmd/`/`internal/` 无实质改动。唯一能力面信号是 `nvidiaDevRoot` 配置项浮现——指向把设备根路径作为独立可配项,服务于非标准驱动布局(如容器化驱动/只读 rootfs)的部署场景。

## 本期无实质改动(折叠)
<details><summary>7 仓 EMPTY</summary>

- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
- kai-scheduler/KAI-Scheduler — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=57378e9c2bcc707fb5f30e78cbfa745d361bb14b branch=main release=v26.7.1 scanned=2026-10-10 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-10 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9287a5418573da037ba0d287e059812aa4740e45 branch=main release=— scanned=2026-10-10 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=bd98fbd6b676c655d235857574bdca29ab562dbc branch=main release=v0.20.1 scanned=2026-10-10 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=fb8b9674749c15b35f3bc7535c2e796c86463397 branch=main release=v0.5.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-10 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-10 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=87f9e3c6be56020a346e9d25379734291cfc9cca branch=main release=v0.15.1 scanned=2026-10-10 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=469ad7efa3a601f01f6f213458e040f7c03f6b24 branch=main release=v0.18.3 scanned=2026-10-10 -->
