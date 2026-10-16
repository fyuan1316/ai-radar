# HAMi diff 雷达 2026-10-17

## 摘要
- 主仓 `HAMi` 5 提交(4 实质),当日最实质代码改动是设备插件健康检查:XID 故障事件现在把**同一物理 GPU 下的全部 vGPU 副本 / MIG 切片**一并标记 unhealthy(此前只标一个),并把 MIG gi/ci 匹配改成逐实例独立判断——直接影响软切分/MIG 场景下的故障隔离正确性。
- 其余为 `--disable-core-limit` flag 真正生效(core-limit 关闭语义收敛为 OR)、AMD vGPU 的 chart 文档补全、CI workflow 注入加固与 build 镜像(CUDA 13.3→13.4.2、buildkit v0.31→v0.34)升级。
- 其余 4 仓(HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI)本期无新提交。Release 仍 v2.10.0,无版本跨档。

## 当日重要改变
- 无命中正式信号(无弃用/移除、无 `*_types.go`/`config/crd`/`apis/` 改动、无 `docs/proposals`、无版本跨档、无新顶层 package)。最值得记的是 `HAMi` 健康检查的 XID 故障隔离修正,见下方 AI 总结重点(属正确性修复,非 API/CRD 信号)。

## Project-HAMi/HAMi: b385c823 -> 0af48d62
- 比较: https://github.com/Project-HAMi/HAMi/compare/b385c82333ed98c7c036d2e29d5d1d312f5be5b5...0af48d62 | ahead=5 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **XID 故障现在作用于父 GPU 下所有设备,而非单个(#3265)**:`checkHealth` 里 `parentToDeviceMap` 从 `map[string]*Device` 改为 `map[string][]*Device`,注册时由覆盖写(`map[uuid]=d`)改为追加(`append(...)`)。由于一张物理卡上的多个 vGPU 副本与 MIG 切片共享同一父 UUID,旧实现每个父 UUID 只留最后一个设备,XID 临界错误只会把一个设备打成 unhealthy、其余副本/切片仍被当健康继续调度;新实现遍历 `affected` 把全部打成 unhealthy。同时 MIG 的 gi/ci 匹配从"要求 gi 与 ci 同时非 0xFFFFFFFF 才比对"改为"两个实例 ID 各自独立比对"(`0xFFFFFFFF` 表示事件未限定到该层级)。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/rm/health.go</summary>

  ```diff
  - parentToDeviceMap := make(map[string]*Device)
  + // Replicas and MIG slices share a parent UUID, so each parent maps to all of its devices.
  + parentToDeviceMap := make(map[string][]*Device)
  ...
  -   parentToDeviceMap[uuid] = d
  +   parentToDeviceMap[uuid] = append(parentToDeviceMap[uuid], d)
  ...
  -   d, exists := parentToDeviceMap[eventUUID]
  +   affected, exists := parentToDeviceMap[eventUUID]
  ...
  -   if d.IsMigDevice() && e.GpuInstanceId != 0xFFFFFFFF && e.ComputeInstanceId != 0xFFFFFFFF {
  -     gi := deviceIDToGiMap[d.ID]
  -     ci := deviceIDToCiMap[d.ID]
  -     if gi != e.GpuInstanceId || ci != e.ComputeInstanceId {
  -       continue
  +   for _, d := range affected {
  +     if d.IsMigDevice() {
  +       gi := deviceIDToGiMap[d.ID]
  +       ci := deviceIDToCiMap[d.ID]
  +       if (e.GpuInstanceId != 0xFFFFFFFF && gi != e.GpuInstanceId) ||
  +         (e.ComputeInstanceId != 0xFFFFFFFF && ci != e.ComputeInstanceId) {
  +         continue
  +       }
  ```
  </details>

- **`--disable-core-limit` flag 被真正遵循,关闭语义收敛为 OR(#3252)**:chart 值注释明确 `devicePlugin.disablecorelimit` 现在与 `device-config.yaml` 里的 `nvidia.disableCoreLimit` **合并**——任一为 true 即关闭 HAMi-core 的算力(utilization)限制,且文件侧为 true 时命令行/chart 的 `"false"` 不再能覆盖它。即软切分的"算力限流开关"从单源判定变为双源 OR 判定。证据边界:patch 只覆盖到 chart 注释与新增的 `core_limit_config_test.go`(89 行新测试),未抓到 `plugin/` 下实际合并逻辑的 hunk,OR 语义由注释与测试文件名推断。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
  +  # -- Set to `"true"` to disable HAMi-core utilization limits. This value is
  +  # merged with `nvidia.disableCoreLimit` in `device-config.yaml`; either one
  +  # being true disables limits, while `"false"` does not override a true file value.
     disablecorelimit: "false"
  ```
  </details>

- **AMD Instinct vGPU 的 chart 配置项补全文档(#3260)**:`devices.amd` 一节用 helm-docs 风格补齐全部字段语义——`resourceMemoryPercentageName`(按百分比 0-100 申请显存,与固定 MiB 并存时固定值优先)、`runtimeClassName`(准入 webhook 给未声明的 AMD GPU Pod 注入,chart 不负责创建该 RuntimeClass)、`defaultGPUNum`(只申请显存/核未申请卡数时补的默认卡数,<1 视作 1)、`customresources`(需显式列出 count/memory/core 资源名,百分比资源名自动加)。配合 README 把设备后端清单显式列为 14 类并新增 Biren GPU 与 Lupine 远程 NVIDIA GPU,对应 v2.10.0/Unreleased 的 AMD MI300X 与 remote-gpu 方向。
  <details><summary>代码依据 charts/hami/values.yaml + README.md</summary>

  ```diff
  +    # -- RuntimeClass the admission webhook adds to AMD GPU Pods that do not already specify one. The chart does not create it; empty leaves the Pod unchanged.
       runtimeClassName: ""
  +    # -- Default GPU count added by the admission webhook when memory, memory percentage, or cores are requested without a GPU count. Values below 1 are treated as 1.
       defaultGPUNum: 1
  + Device backends in this repository: NVIDIA GPU (including MIG), AMD GPU, ... Biren GPU, VastAI, AWS Neuron, and remote NVIDIA GPUs served by Lupine.
  ```
  </details>

- **CI 供应链/注入加固 + build 镜像升级(#3237)**:release workflow 把 `inputs.*`/`github.event.inputs.*` 从表达式内联(`image_ref=${{ inputs.ref }}`)改为经 `env:` 注入后用 shell 变量引用(`image_ref="$IN_REF"`),杜绝输入内容拼进命令造成的 workflow 注入;构建基镜像 NVIDIA CUDA `13.3.0-cudnn-devel-ubi8`→`13.4.2`、buildkit `v0.31.2`→`v0.34.0`。另 `.golangci.yaml` 精简(移除 dupl/errcheck/gocritic/gocyclo/nestif/gofumpt 等大量自定义配置)。均为工程/安全侧,不触及切分或调度核心逻辑。
  <details><summary>代码依据 .github/workflows/call-release-image-hamicore.yaml</summary>

  ```diff
  +        env:
  +          IN_REF: ${{ inputs.ref }}
  -              image_ref=${{ inputs.ref }}
  +              image_ref="$IN_REF"
  -          driver-opts: image=moby/buildkit:v0.31.2@sha256:...
  +          driver-opts: image=moby/buildkit:v0.34.0@sha256:...
  -              NVIDIA_IMAGE=nvidia/cuda:13.3.0-cudnn-devel-ubi8@...
  +              NVIDIA_IMAGE=nvidia/cuda:13.4.2-cudnn-devel-ubi8@...
  ```
  </details>

### 后续发展方向 [AI]
- 健康检查正在往**副本/MIG 粒度的故障爆炸半径正确传播**收口:XID 事件打穿到同父 UUID 的全部设备,说明 HAMi 在把"软切分出来的多个逻辑设备共享同一故障域"这件事显式建模进设备插件。证据只覆盖 `rm/health.go` 的 nvml 事件路径,未见调度器侧对 unhealthy 设备的重调度/驱逐联动,也未见 Ascend/其他后端是否同步该语义。
- 算力限流开关转双源 OR + chart 文档体系化(helm-docs 生成、AMD 字段补全),指向**配置来源多元化后的语义去歧义**而非新切分能力;AMD MI300X 与 Lupine remote-gpu 的后端扩张只在本期 README/CHANGELOG 层面可见,核心切分/调度代码的 hunk 本期未出现,不能据此判断远程 GPU 路径的隔离机制。

## 本期无实质改动(折叠)
<details><summary>4 仓无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交(锚点未动)
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=0af48d6234dfec4d8fbb8ab76c25af7e2c114ffe branch=master release=v2.10.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a55248ecc6e2530602875054e2d334645d08f35b branch=main release=— scanned=2026-10-17 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-17 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf890f96118f38a85f71d31da2e74ca95aeb1a0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=09f0b75b0773c2caf835933936f0301f7efc248c branch=main release=v1.3.0 scanned=2026-10-17 -->
