# 昇腾算力栈 diff 雷达 2026-08-05

## 摘要
- 昨日 npu-operator 落地 vNPU+DRA+Volcano 三合一大架构后,今日全栈回到**收尾/纠错节奏**:唯一实质代码改动是 vNPU 仓一处**硬模式(整卡静态模板)vNPU 设备计数 bug 修复**——把 `device.UsedCpu` 的累加从错用 `template.AiCore` 改回 `template.AiCPU`,修正 AI CPU 配额记账。
- npu-dra-plugin **删除两份 soft-vnpu 设计文档**(中英各 446 行,`doc/soft-vnpu*.md`),提交标题即「DRA插件废弃文档清理」——是文档级动作而非代码,但结合上下文是**昇腾软切分主线正从 DRA 插件内置实现向 operator/vNPU 仓收敛**的信号面(该文档描述的 vCANN-RT 内置 SoftVNPUManager 路径被标记为废弃)。
- 其余 7 个跟踪仓(含 mind-cluster 全部 `component/*` 子目录、npu-operator、npu-driver-installer、npu-container-toolkit 等)在跟踪范围内**无代码改动**;mind-cluster 区间仅 1 条 docs 提交(更新 v26.1.0 软件包获取链接),不落 `component/` 路径。

## 当日重要改变
- **vNPU [缺陷修复]** `applyHardModeDevice()`(硬模式/整卡静态模板切分)修正 AI CPU 记账:此前 `device.UsedCpu += template.AiCore` 错用了 AI Core 数量去累加已用 AI CPU,改为 `device.UsedCpu += template.AiCPU`。证据:`volcano-xpu-plugin/plugin/vxpu.go`。https://gitcode.com/openFuyao/vNPU/merge_requests/87
- **npu-dra-plugin [弃用/移除]** 删除 `doc/soft-vnpu.md` / `doc/soft-vnpu-zh.md`(各 446 行,描述 DRA 插件内 vCANN-RT + SoftVNPUManager 的软切分实现),提交「!31 DRA插件废弃文档清理」。仅文档、无代码;但坐实软切分实现主线在收敛。证据:两份 `doc/soft-vnpu*.md` removed。https://gitcode.com/openFuyao/npu-dra-plugin/merge_requests/31

## vNPU: 5366f8e4 -> 109f4d14
- 比较: 5366f8e44a2f114584ed0f0099a25cf487aa63b7..109f4d14 | tag: v0.1.0 | commits=2(实为单个 !87)| truncated=false
- 源:https://gitcode.com/openFuyao/vNPU/merge_requests/87

### AI 总结重点(源码 diff 为据)
- **硬模式 vNPU 设备分配时,AI CPU 已用量的累加口径修正**。`applyHardModeDevice(device, template)` 在给容器分配一个静态模板(hard mode = 整卡按固定模板切分,非弹性软切)vNPU 时,会同时递增设备两类资源计数:`device.UsedCores += template.AiCore`(AI Core,未改)与 `device.UsedCpu += ...`(AI CPU)。此前 AI CPU 那行错误地也加了 `template.AiCore`,导致**用 AI Core 的规格数去记 AI CPU 的已用量**——两者是模板里独立的两项配额(`AiCore` vs `AiCPU`),数值通常不等,会造成设备剩余 AI CPU 记账偏差,进而在后续 `checkHardModeDevice` 判定能否再放一个模板时算错余量(多分或少分)。修复即把该行改用 `template.AiCPU`,使 UsedCores/UsedCpu 各自对应正确的模板字段。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/vxpu.go</summary>

  ```diff
   func applyHardModeDevice(device *common.XPUDevice, template *TemplateInfo) *common.ContainerDevice {
   	device.UsedCores += template.AiCore
  -	device.UsedCpu += template.AiCore
  +	device.UsedCpu += template.AiCPU
   	vid := device.AllocateVid()
   	return &common.ContainerDevice{
   		Index:    device.PhysicID,
  ```
  </details>

### 后续发展方向 [AI]
- 这是**记账正确性修复**而非能力变化:硬模式(静态模板切分)与软模式(弹性 share)是 vNPU 两条切分路径,本次只触及硬模式的 CPU 计数。证据仅到 `applyHardModeDevice` 单行改动,**未见 checkHardModeDevice / 软模式路径是否有同类 AiCore/AiCPU 混用**——若软模式或其它 template 应用点存在同款拼写级错误,值得一并核查(本次 diff 未覆盖)。
- vNPU 仓仍在 `v0.1.0`、以此类细粒度 bug fix 推进,说明该仓处于**早期稳定化阶段**;昇腾软切分的架构表达已上移到 npu-operator 的 `VNPUSpec`(昨日),vNPU 仓这里更像被 operator 下发/调用的**执行侧插件**(Volcano xpu-plugin)。

## npu-dra-plugin: b6d9bffb -> dff4fa7d
- 比较: b6d9bffb26ce91cef9e7ceb70736f7eddbfa6a58..dff4fa7d | tag: v26.6.0 | commits=2(实为单个 !31)| truncated=false
- 源:https://gitcode.com/openFuyao/npu-dra-plugin/merge_requests/31

### AI 总结重点(源码 diff 为据)
- **删除 DRA 插件内 soft-vnpu 特性设计文档(中英双份,各 446 行)**,提交标题定性为「废弃文档清理」。被删文档完整描述了一套**在 DRA kubeletplugin 内实现软虚拟化**的架构:`SoftVNPUManager`(`internal/vnpu/soft_manager.go`,vNPU 生命周期)、NPU `Profile`(设备枚举 + CDI edits 生成)、`DeviceState`(`cmd/ascend-npu-dra-kubeletplugin/state.go`,选择 VNPU manager)、`GpuConfig`/`SoftSharingConfig`(配额与软分区策略),运行时挂 `vCANN-RT`,配置落 `/etc/enpu/`、shm 落 `/dev/shm`,并给 `VNPUManager` 接口加 `DeviceUpdater() chan SoftDeviceUpdate`(动态发布 `AllocationMode`:unbound/fixed/elastic/best-effort)。这套设计现被标记废弃移除——是纯文档删除,**不能据此断言对应代码已删**,但方向上与昨日 operator 把 vNPU/DRA 收进单一 CR 编排一致,软切分实现权正从 DRA 插件自带向上收敛。
  <details><summary>代码依据 doc/soft-vnpu.md(removed,节选原文所述结构)</summary>

  ```diff
  -| `SoftVNPUManager`   | `internal/vnpu/soft_manager.go`             | vNPU lifecycle management (create/delete) |
  -| `DeviceState`       | `cmd/ascend-npu-dra-kubeletplugin/state.go` | Device state tracking, VNPU manager selection |
  -| `SoftSharingConfig` | `api/sharing.go`                            | Soft partitioning strategy configuration structure |
  -type VNPUManager interface {
  -    CreateVNPU(params CreateVNPUParams) (*CreateVNPUOutcome, error)
  -    DeleteVNPU(deleteRef string) error
  -    DeviceUpdater() chan SoftDeviceUpdate  // New: dynamic state updates
  -}
  ```
  </details>

### 后续发展方向 [AI]
- **只删文档、未见同批删代码**:本次 diff 仅命中两份 `doc/soft-vnpu*.md`,信号文件里无 `internal/vnpu/*` 或 `api/sharing.go` 的删除。所以更可能是**文档陈旧/迁移**而非特性下线——需下期盯 `internal/vnpu/`、`cmd/ascend-npu-dra-kubeletplugin/` 是否跟进删除或重构来确认。证据边界:仅文档层。
- 值得对标的是文档里那个 **`AllocationMode`(unbound/fixed/elastic/best-effort)+ `DeviceUpdater` 动态发布设备属性**的模型——把软切 vNPU 的分配模式作为可动态更新的设备属性上报,是 DRA 场景下做弹性共享的清晰抽象,即便文档被删,这套语义对我们产品的 GPU/NPU DRA 弹性共享设计仍有参考价值。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- mind-cluster:区间 2 提交,实质仅 1 条 docs(更新软件包获取链接至 v26.1.0),不落跟踪的 `component/*` 子目录,组件代码无改动。
- npu-operator:无新提交(昨日 !109 大合并后未再动)。
- npu-container-toolkit:无新提交。
- npu-driver-installer:无新提交。
- npu-node-provision:无新提交。
- volcano-ext:无新提交。
- ub-network-device-plugin:无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=98f216bcd21d72a38b73dc1ea1053aa07e41af5f tag=v26.1.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=vNPU sha=109f4d14f9d14f4a425f41462d99b6791c850d8a tag=v0.1.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=npu-dra-plugin sha=dff4fa7de9c90bd2be9203adfa5f2d3a1c7a06a6 tag=v26.6.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-05 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-05 -->
</content>
</invoke>
