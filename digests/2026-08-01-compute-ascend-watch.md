# 昇腾算力栈 diff 雷达 2026-08-01

## 摘要
- **npu-dra-plugin 一次性落地 vNPU 软/硬切分完整栈**(PR !28/!29):昇腾接 K8s DRA 的分片方案从"编译期 hardIds/softIds 列表"改成"按节点按卡的 CardConfig(physicalId/vnpuMode/schedulingPolicy)",新增 full/soft/hard 三态、内置 310P3/910B4 vNPU 模板、集成 vCANN-RT 劫持库(独立 installer DaemonSet + 自愈守护),并补齐 Helm chart。这是本 task 跟踪以来昇腾 DRA 分片最大的一次功能推进。
- 另有 **vNPU(xpu-device-plugin)** 一条防御式修复:`log.InitLogging` 返回值以前被丢弃,现改为失败即 `os.Exit(1)`。
- mind-cluster 及其余 6 个 openFuyao 仓相对上期锚点零新提交。**本日有实质代码改动,推飞书。**

## 当日重要改变

### npu-dra-plugin — 昇腾 DRA vNPU 软/硬切分成栈([架构方向] / [新能力])
区间 `98f8fa5e..77ab67d1`,commits=6,truncated=false。锚点 repo=`npu-dra-plugin`。

**1. 分片配置模型重构:列表 → 按节点按卡的 CardConfig(`internal/profiles/npu/npu.go`)**
旧模型是全局两张整数列表 `HardIds []int` / `SoftIds []int`,一个节点只能"前 4 张软、后 4 张硬"式静态切。新模型删掉这两个字段,`ProfileConfig` 改成 `Nodes map[string][]CardConfig`,每卡独立声明:
```go
type CardConfig struct {
	PhysicalID       int    `yaml:"physicalId"`
	VnpuMode         string `yaml:"vnpuMode"`         // full / soft / hard
	SchedulingPolicy string `yaml:"schedulingPolicy"`
}
type ProfileConfig struct {
	SoftShareMounts []SoftShareMount        `yaml:"softShareMounts"`
	Nodes           map[string][]CardConfig `yaml:"nodes"`
}
```
同时 `Profile` 结构新增 `chipCaps VnpuTemplates` / `nodeMode` / `nodeSchedulingPolicy`,vNPU 模式变成运行时按卡决议而非启动参数。配套地 `state.go` 删掉了旧的全局开关 `enableHardVNPU bool`。**启示**:这跟 nv-watch 侧 DRA consumable-shares 是同一方向——分片粒度从"节点级策略"下沉到"设备级属性",调度器按 device.Attributes 里的 `vnpuMode` 决策。我们若做统一 XPU 分片抽象,配置模型要按这种 per-device 属性设计,不要再用整机列表。

**2. 新增 full/soft/hard 三态 + 内置 vNPU 模板(新增 `vnpu_template.go` 152 行)**
以前只有 soft/hard 两个 mode 常量,现补 `FullVNPUMode = "full"`(整卡),并内置芯片规格模板库 `DefaultVnpuTemplates()`,把华为 vir 系列切分规格写进代码:
```go
{ChipName: "310P3", TotalAiCore: 8, ...
 Templates: {vir01(1core/3G), vir02, vir02_1c, vir04, vir04_3c}}
{ChipName: "910B4", TotalAiCore: 20, ...
 Templates: {vir05_1c_8g, vir10_3c_16g, vir10_4c_16g_m, vir10_3c_16g_nm}}
```
另有 `defaultChipModel = "Ascend-910C"`、`davinciDevPattern` 正则等常量落定,`ParseVnpuTemplates` 支持从 ConfigMap 覆盖内置模板。**启示**:昇腾把"哪些切分规格合法"编码进 plugin,而非依赖 device-plugin 上报。对比 HAMi 侧近期"vNPU 模板改名纠偏",两条栈都在收敛模板命名,值得盯模板 schema 是否会趋同。

**3. 硬 vNPU 走 Ascend Docker Runtime 委托创建,plugin 只注入 env(新增 `hard_vnpu.go` 125 行 + `cdi_edits.go` 145 行)**
关键设计:硬切分时 plugin **不直接调 DCMI**、也**不注入物理 davinci 设备节点**,而是通过 CDI 注入 `ASCEND_VNPU_SPECS=<template>` 等 env,由 Ascend Docker Runtime 用 DCMI 真正创建 vNPU 设备(`/dev/davinci<vid>`)再挂进容器,实现硬件级隔离:
```go
// buildVNPUCDIEdits: out.Env carries ASCEND_VNPU_SPECS=<template> for the Ascend Docker Runtime.
// For hard vNPU, the Plugin must NOT inject the physical davinci device node.
```
触发条件在 `shouldCreateHardVNPU`:device 的 `vnpuMode` 属性 == "hard" 且用户请求了 `aiCore` capacity(读 `result.ConsumedCapacity["aiCore"]`)。整卡场景 `buildWholeCardCDIEdits` 则注入 `/dev/davinci<phyID>` + `davinci_manager`/`devmm_svm`/`hisi_hdc`。**启示**:职责切分清晰——DRA plugin 只做"决策 + CDI env",实际硬件虚拟化下沉给 runtime。这跟 NV 的 CDI + nvidia-container-runtime 模型同构,是我们做多厂商 runtime 抽象的对标点。

**4. 集成 vCANN-RT 软切分劫持库(新增 `build/vcannrt/` + `vcannrt-installer` DaemonSet)**
软切分靠用户态劫持库 `libvruntime.so` + `ld.so.preload` 实现。新增独立 installer DaemonSet(特权容器)跑自愈脚本 `acl-client-update.sh`:把 `enpu-monitor`/`libvruntime.so`/`ld.so.preload`/`systemd-detect-virt` 装到宿主 `/opt/xpu/{lib,bin}`,每 5s md5 比对、被删/被改即 `install -m 555` 还原,并维护 `xpu-monitor→enpu-monitor` 软链。脚本注释指向 openeuler `ubs-virt-enpu/vcann-rt`。**启示**:软切分是"LD_PRELOAD 劫持 ACL 调用"路线(类 HAMi 的 libvgpu.so),隔离性弱于硬切分但无需 runtime 配合。这条自愈 installer 模式(独立 DaemonSet 守护宿主库文件)可复用到我们自己的注入库分发。

**5. DCMI 发现逻辑瘦身(`internal/profiles/npu/dcmi.go`)**
`DeviceSpec` 去掉 `TopologyGroup`、新增 `ProductType`;`discoverWithDCMI` 删除 `getNpuSmiTopoGroups` 拓扑组发现(整段拿掉,不再上报 topology-group);新增 `getChipSeriesFromPCIDeviceID(busID)` 从 PCI 设备号推芯片系列;`getPhyIDAndVdieID` 里合成 vdieID 的内联代码抽成 `makeVdieID(phyID)`,并把日志改成明说"synthetic vdieID ... not real hardware UUID"。**注意**:拓扑组上报被移除意味着这一版暂不做 NPU 间拓扑亲和调度(可能挪去 volcano-ext,但该仓本期零提交,待观察)。

**6. Helm 化与部署清单收敛(charts/ + manifests/deploy/)**
新增完整 `charts/npu-dra-driver`(values.yaml/daemonset/deviceclass/vcannrt-installer 模板),旧 `manifests/deploy/03-daemonset.yaml` 把内嵌 ConfigMap/RBAC 拆出、命名从 `ascend-npu-dra-kubeletplugin`/`ascend-dra` 收敛为 `npu-dra-plugin`/`npu-dra-driver`,镜像从 `dra-npu:dev` 改 `npu-dra-plugin:latest`,新增 `--share-count=16`、`--npu-profile-config` 参数。另 `state.go` 的 `RecoverState` 现为 no-op(注释:capacity compensation removed),重启后不再做容量补偿,配 `SetPublishFunc` 走标准 resourceslice 发布。

### vNPU(xpu-device-plugin)— InitLogging 错误不再吞([健壮性])
区间 `49ad0e7c..5366f8e4`,PR !84。`cmd/main.go` 里 `log.InitLogging(logFileName)` 以前忽略返回值,现改为失败即写 stderr 并 `os.Exit(1)`——日志初始化失败时进程不再"看似启动但无日志"地静默跑。小改动但对排障有意义。

## 本期无实质改动(折叠)
- **mind-cluster**:相对锚点 `68cce2d6` 无新提交(`__EMPTY__`)。
- **npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / volcano-ext / ub-network-device-plugin**:均无新提交(`__EMPTY__`)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=68cce2d667052820b17381aa9ad6751e3c459df1 tag=v26.1.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=npu-operator sha=53299373d36e46a82415a093cde55e7df240d7f7 tag=v26.6.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=vNPU sha=5366f8e44a2f114584ed0f0099a25cf487aa63b7 tag=v0.1.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=npu-dra-plugin sha=77ab67d12eec260d2eb208409e80c0b62cc1ec70 tag=v26.6.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-01 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-01 -->
</content>
</invoke>
