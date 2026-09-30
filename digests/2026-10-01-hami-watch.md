# HAMi diff 雷达 2026-10-01

## 摘要
- HAMi 主仓落地一处 **breaking Helm 重构**(`feat!` #3124):所有厂商的资源名与 NVIDIA device-plugin 调优项从 chart 根级/`devicePlugin.*` 全部迁到 `devices.<vendor>.*` 命名空间,并新增渲染期校验模板,老字段一律拒绝渲染——面向 v2.11 升级。
- 仅影响 Helm values 表面,HAMi 运行时/device plugin 读取的 `device-config.yaml` 格式不变,非运行时行为变更。
- 其余 4 repo(HAMi-core / volcano-vgpu-device-plugin / ascend-device-plugin / HAMi-WebUI)无新提交。

## 当日重要改变
- Project-HAMi/HAMi [弃用/移除][架构方向] 删除 chart 根级 `resourceName`/`mluResourceName`/… 及 `devicePlugin.deviceSplitCount`/`deviceMemoryScaling`/`runtimeClassName` 等字段,统一迁到 `devices.<vendor>.*`;新增 `hami-vgpu.validateDeviceValues` 模板,命中老字段直接 fail `helm install/upgrade`。证据:charts/hami/values.yaml、charts/hami/templates/_helpers.tpl、charts/hami/templates/validate-values.yaml(新增)。https://github.com/Project-HAMi/HAMi/pull/3124

## Project-HAMi/HAMi: 36b9e522 -> eb46ae6b
- 比较: 36b9e5222311bb3e2b2eec4e72ae1becd166e820 -> eb46ae6b | ahead=3 | files=11 | Release: v2.10.0
- 关键提交:eb46ae6b `feat!: move all vendor configs to devices.VENDOR` (#3124) https://github.com/Project-HAMi/HAMi/commit/eb46ae6b4b8c2ee83c5cae566c85c7a0e5bb77b9

### AI 总结重点(源码 diff 为据)
- **厂商资源名全部从 chart 根级下沉到 `devices.<vendor>.*` 命名空间。** `values.yaml` 删掉了一整块平铺的厂商参数(NVIDIA `resourceName/resourceMem/resourceMemPercentage/resourceCores/resourcePriority`、Cambricon `mluResource*`、Hygon `hcuResource*`、Metax `metaxResource*`+`metaxsGPUTopologyAware`、Enflame `enflameResourceName*`、Kunlun `kunlunResource*`、Vastai/Biren `*ResourceName`),这些值改由 `devices.nvidia.resourceCountName` 等结构化路径承载。这是命名空间化的配置重构,消除了 8 个厂商各自平铺在根级的命名混乱。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  -#Nvidia GPU Parameters
  -resourceName: "nvidia.com/gpu"
  -resourceMem: "nvidia.com/gpumem"
  -resourceMemPercentage: "nvidia.com/gpumem-percentage"
  -resourceCores: "nvidia.com/gpucores"
  -resourcePriority: "nvidia.com/priority"
  -#MLU Parameters
  -mluResourceName: "cambricon.com/vmlu"
  ...
  -#Biren Parameters
  -birenResourceName: "birentech.com/gpu"
  ```
  </details>

- **NVIDIA device-plugin 的 7 个调优项从 `devicePlugin.*` 迁到 `devices.nvidia.*`。** 涉及 `deviceSplitCount`(单卡切分数)、`deviceMemoryScaling`(显存超分)、`deviceCoreScaling`(算力超分)、`preConfiguredDeviceMemory`(统一内存 GPU 如 GB10/DGX Spark 的显存预置)、`enableNumaTopology`(NUMA 拓扑上报)、`runtimeClassName`/`createRuntimeClass`。切分/超分正是 HAMi 软虚拟化的核心旋钮,现在归口到 `devices.nvidia`。
  <details><summary>代码依据 charts/hami/templates/scheduler/device-configmap.yaml</summary>

  ```diff
  -      deviceSplitCount: {{ .Values.devicePlugin.deviceSplitCount }}
  -      deviceMemoryScaling: {{ .Values.devicePlugin.deviceMemoryScaling }}
  -      deviceCoreScaling: {{ .Values.devicePlugin.deviceCoreScaling }}
  -      enableNumaTopology: {{ .Values.devicePlugin.enableNumaTopology | default false }}
  +      deviceSplitCount: {{ .Values.devices.nvidia.deviceSplitCount }}
  +      deviceMemoryScaling: {{ .Values.devices.nvidia.deviceMemoryScaling }}
  +      deviceCoreScaling: {{ .Values.devices.nvidia.deviceCoreScaling }}
  +      enableNumaTopology: {{ .Values.devices.nvidia.enableNumaTopology | default false }}
  ```
  </details>

- **新增渲染期硬校验 `hami-vgpu.validateDeviceValues`,把迁移从"软提示"变成"硬门禁"。** 该模板用 `$removedRootFields` 字典枚举所有被删字段→新路径映射,遍历 `.Values` 若命中老字段(即便值是 `0`/`false`/空)即 `append` 到 `$errors`;`devicePlugin.*` 的 7 个字段同样检查。被 include 进 `managedResources` 和 `device-configmap.yaml` 顶部,因此任何残留老配置都会让 `helm install/upgrade` 直接渲染失败并逐条列出替换路径。新增 `charts/hami/templates/validate-values.yaml` 承载这段校验入口。
  <details><summary>代码依据 charts/hami/templates/_helpers.tpl</summary>

  ```diff
  +{{- define "hami-vgpu.validateDeviceValues" -}}
  +{{/* Reject obsolete paths by presence, including explicit zero, false and empty values. */}}
  +{{- $removedRootFields := dict
  +  "resourceName" "devices.nvidia.resourceCountName"
  +  ...
  +  "birenResourceName" "devices.biren.resourceCountName"
  +-}}
  +{{- range $old := keys $removedRootFields | sortAlpha -}}
  +  {{- if hasKey $.Values $old -}}
  +    {{- $errors = append $errors (printf "%s has been removed; use %s instead" $old (index $removedRootFields $old)) -}}
  ```
  </details>

- **运行时格式不变,仅 Helm values 表面重排。** README 新增 "Upgrade to v2.11" 段明确写 "The `device-config.yaml` format read by HAMi and the device plugins is unchanged",并给出字段迁移表 + `helm get values`/ConfigMap 备份步骤。结论:这是打包/升级体验层的 breaking,不动 HAMi-core hook 或调度器的实际切分逻辑。
  <details><summary>代码依据 charts/hami/README.md</summary>

  ```diff
  +## Upgrade to v2.11
  +Device-specific Helm values use `devices.<vendor>`. Move your existing overrides
  +to the paths below before upgrading. The `device-config.yaml` format read by
  +HAMi and the device plugins is unchanged.
  ```
  </details>

### 后续发展方向 [AI]
- **多厂商配置治理收口**:把 8+ 厂商平铺参数统一到 `devices.<vendor>.*` 结构,是 HAMi 往"多加速卡厂商统一纳管"演进时必然的 values schema 规整——新厂商接入只需在 `devices` 下加一个 key,而非往根级再堆一批 `xxxResourceName`。证据只覆盖 Helm chart 模板与 values,未见 HAMi 主仓 Go 侧(device-config.yaml 解析器/CRD)有对应改动,故运行时侧是否也在做同样命名空间化,本期无 diff 佐证。
- **升级门禁前移**:用渲染期校验阻断老配置而非运行时报错,说明维护者在为 v2.11 这类 breaking 版本铺"升级即失败早于部署"的护栏。证据仅为 `validateDeviceValues` 模板本身,未覆盖是否配套 e2e/升级测试(patch 未含 `_test` 文件命中)。

## 本期无实质改动(折叠)
<details><summary>4 个 repo 无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=eb46ae6b4b8c2ee83c5cae566c85c7a0e5bb77b9 branch=master release=v2.10.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-01 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-01 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-01 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=846c0e2d3360cc7240bb61968e4cc7e3cea53443 branch=main release=v1.3.0 scanned=2026-10-01 -->
