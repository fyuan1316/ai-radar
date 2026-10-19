# HAMi diff 雷达 2026-10-20

## 摘要
- HAMi 主仓把 Ascend vNPU 的切分配置字段 `vnpuDeviceSplitCount` 重命名为 `deviceSplitCount`,并把它从「仅 hami-core 模式」扩展到 hami-core + ENPU 两种模式(ENPU 上限封顶 100),同步改了共享 device ConfigMap 的 schema——这是 HAMi×昇腾 vNPU 的配置接口变更,需配套升级 ascend-device-plugin。
- 另删除了 `docs/develop/dynamic-mig-lifecycle.md` 动态 MIG 生命周期设计文档(纯文档整理,无代码/能力变化)。
- HAMi-core、volcano-vgpu-device-plugin、ascend-device-plugin、HAMi-WebUI 四仓本日无新提交。

## 当日重要改变
- Project-HAMi/HAMi [弃用/移除] 移除昇腾 vNPU 配置字段 `vnpuDeviceSplitCount`,改为 `deviceSplitCount`,并扩到 ENPU 模式(封顶 100);改到共享 device ConfigMap schema 与 VNPUs 结构体,属破坏性配置变更,须配套 ascend-device-plugin #144。证据:pkg/device/ascend/vnpu.go、charts/hami/templates/scheduler/device-configmap.yaml,提交 https://github.com/Project-HAMi/HAMi/commit/6f05462cef20df5fdee4b68040a13616b0a1fa82 (PR https://github.com/Project-HAMi/HAMi/pull/3267)

## Project-HAMi/HAMi: 0af48d62 -> 84c75baf
- 比较 https://github.com/Project-HAMi/HAMi/compare/0af48d6234dfec4d8fbb8ab76c25af7e2c114ffe...84c75baf89b2bec4fd11660126ad2660b9d957f2 | 最新 Release v2.10.0 | ahead=2 | files=12

### AI 总结重点(源码 diff 为据)
- **昇腾 vNPU 切分字段改名 + 适用范围扩大**:`VNPUs` 结构体的 yaml 标签 `vnpuDeviceSplitCount` 改为 `deviceSplitCount`(pkg/device/ascend/vnpu.go)。这个字段经「共享 device ConfigMap」透传给 ascend-device-plugin 消费,语义从"每张物理昇腾 NPU 的虚拟设备槽位数,仅 hami-core 模式"变为"hami-core 和 ENPU 两种模式都用",且新增约束「ENPU 模式封顶 100,template 模式仍走自己的模板计算」。旧字段直接删除、非别名共存,属破坏性 schema 变更;配套依赖 ascend-device-plugin 侧支持 `vnpus.deviceSplitCount`(其 PR #144)。
  <details><summary>代码依据 pkg/device/ascend/vnpu.go</summary>

  ```diff
   type VNPUs struct {
   	Configs          []VNPUConfig `yaml:"configs"`

   	// Consumed by the Ascend device plugin from the shared device ConfigMap.
  -	VNPUDeviceSplitCount int `yaml:"vnpuDeviceSplitCount,omitempty"`
  +	DeviceSplitCount int `yaml:"deviceSplitCount,omitempty"`
  ```
  </details>
  <details><summary>代码依据 charts/hami/templates/scheduler/device-configmap.yaml</summary>

  ```diff
       vnpus:
  -      vnpuDeviceSplitCount: {{ .Values.devices.ascend.vnpuDeviceSplitCount | int64 }}
  +      deviceSplitCount: {{ .Values.devices.ascend.deviceSplitCount | int64 }}
         hamiVnpuMode: {{ include "hami-vgpu.ascendVnpuMode" . | quote }}
         enpuPolicy: {{ .Values.devices.ascend.enpuPolicy | default "elastic" | quote }}
  ```
  </details>
  <details><summary>代码依据 charts/hami/values.yaml(语义/范围说明变化)</summary>

  ```diff
  -    # -- Positive integer virtual-device slots per physical Ascend NPU in hami-core mode. Requires an ascend-device-plugin version supporting vnpus.vnpuDeviceSplitCount (introduced in [#144]...). A positive node vDeviceCount takes precedence; template and ENPU modes keep their own capacity.
  -    vnpuDeviceSplitCount: 10
  +    # -- Positive integer virtual-device slots per physical Ascend NPU in hami-core and ENPU modes. Requires an ascend-device-plugin version supporting vnpus.deviceSplitCount (introduced in [#144]...). A positive node vDeviceCount takes precedence; ENPU is capped at 100. Template mode keeps its template calculation.
  +    deviceSplitCount: 10
  ```
  </details>
- **Helm 侧校验同步改名**:`hami-vgpu.validateDeviceValues` 的校验逻辑把读取/报错信息从 `vnpuDeviceSplitCount` 切到 `deviceSplitCount`,仍要求正整数。
  <details><summary>代码依据 charts/hami/templates/_helpers.tpl</summary>

  ```diff
  -{{- $count := .Values.devices.ascend.vnpuDeviceSplitCount -}}
  +{{- $count := .Values.devices.ascend.deviceSplitCount -}}
  ...
  -  {{- fail "devices.ascend.vnpuDeviceSplitCount must be a positive integer" -}}
  +  {{- fail "devices.ascend.deviceSplitCount must be a positive integer" -}}
  ```
  </details>
- **删除动态 MIG 生命周期设计文档**(PR #3258):移除 `docs/develop/dynamic-mig-lifecycle.md`(50 行)及 README 里的链接,保留 README 中 "dynamic MIG" 调度模式一句话描述。纯文档整理,未改任何 MIG 相关代码;无法从本次 diff 判断功能是否变动。
  <details><summary>代码依据 README.md</summary>

  ```diff
  -- **dynamic MIG**: create, cache, reuse, and reclaim NVIDIA MIG instances dynamically for supported cards and modes. See the [Dynamic MIG instance lifecycle](docs/develop/dynamic-mig-lifecycle.md).
  +- **dynamic MIG**: create, cache, reuse, and reclaim NVIDIA MIG instances dynamically for supported cards and modes.
  ```
  </details>

### 后续发展方向 [AI]
- 配置字段去掉 `vnpu` 前缀、统一为 `deviceSplitCount`,且一个字段同时服务 hami-core 与 ENPU 两种 vNPU 模式,说明 HAMi 在收敛昇腾侧的切分配置模型——朝"一套 split count 配多种软切分后端"走。对我们产品的启示:若对标昇腾 vNPU 纳管,配置项命名/语义正在变,需跟踪 ascend-device-plugin #144 的消费端实现确认 ConfigMap 契约。证据只覆盖 HAMi 主仓的字段/模板改名与 values 注释,未见 ascend-device-plugin 侧的实际解析代码(该仓本日锚点未动),ENPU 封顶 100 的执行逻辑也未在本次 diff 出现。
- 动态 MIG 文档被移出仓库(可能迁往官网站点),本次 diff 无 MIG 代码变更,不能据此判断动态 MIG 能力有增减;后续若 MIG 相关代码再动需单独确认。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- Project-HAMi/HAMi-core:无新提交(锚点未动)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(锚点未动)
- Project-HAMi/ascend-device-plugin:无新提交(锚点未动,Release ascend-device-plugin-0.2.0)
- Project-HAMi/HAMi-WebUI:无新提交(锚点未动,Release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=84c75baf89b2bec4fd11660126ad2660b9d957f2 branch=master release=v2.10.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a55248ecc6e2530602875054e2d334645d08f35b branch=main release=— scanned=2026-10-20 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-20 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=74d8d109c40cb70ba0d2881af3b807aef9984fc6 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-20 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-20 -->
