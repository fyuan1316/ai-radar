# 昇腾算力栈 diff 雷达 2026-08-26

## 摘要
- **mind-cluster 全栈接入 DPU/智能网卡**:从 dpu-exporter(1825 指标采集)→ dpu-dp(把 RDMA 资源名写进节点 annotation、故障上报新增 `AffectedNPU` 字段)→ clusterD(聚合 `cluster-info-dpu-<index>` 分片 CM,单 CM 限 800KB)→ ascend-for-volcano(DPU 隔离级故障映射到所用 NPU,触发断点续训重调度)一条链全部落地代码。这是昇腾把"训练 fabric(RDMA/DPU)故障"纳入 NPU 故障重调度体系的新能力。
- **mind-cluster 节点标签/注解统一到 `huawei.com/npu.*` 命名空间**:device-plugin 新增 Labeler 模式(labelers.go),所有 chip.name/chip.memory/server.type/accelerator/topology 标签走"新键+旧键 dual-write";ascend-for-volcano 侧废弃 `accelerator`/`servertype`/`baseDeviceInfos` 等裸键,改经 `GetAnnotationValue` 按优先级读新旧键。是一次面向节点契约的破坏性重命名(带兼容期双写)。
- **npu-dra-plugin 上报 NPU 拓扑亲和属性**:DRA driver 经 `npu-smi` 发现 HCCS 环网/SIO/PCIe root 拓扑,写入 ResourceSlice 设备属性;软切分(vNPU)设备也继承这些拓扑属性,供 DRA 调度器做拓扑约束。README 首次系统化文档软切分(vCANN-RT 劫持库 + `DRAConsumableCapacity` 特性门控,单卡最多 63 vNPU)。
- 其余 6 个 openFuyao NPU 栈仓相对上期锚点无新提交,仅保锚点续链。

## 当日重要改变
- mind-cluster [新能力] DPU/智能网卡全栈接入 + DPU 故障触发 NPU 断点续训重调度。证据 `component/clusterd/pkg/domain/dpu/dpu_util.go`(新增)、`component/ascend-for-volcano/common/k8s/cmmgr.go`、`component/ascend-for-volcano/internal/rescheduling/task.go`、`component/ascend-for-volcano/common/util/type.go`。https://gitcode.com/Ascend/mind-cluster/compare/b0f79f5ac2436f3f19cbd4d71732475ce8065d6c...d0eaf52edaa03fdd29bd4d9cdf0f1d0bf4e080e5
- mind-cluster [弃用/移除] 节点标签/注解统一命名空间 `huawei.com/npu.*`,旧裸键(accelerator/servertype/baseDeviceInfos)标记 Deprecated 并双写。证据 `component/ascend-device-plugin/pkg/server/labelers.go`(新增)、`component/ascend-for-volcano/common/util/type.go`、`common/util/util.go`。同上 compare 链接。
- npu-dra-plugin [新能力] NPU 拓扑亲和(HCCS 环 / SIO / PCIe root)属性上报,软切分设备继承拓扑;`DeviceSpec.NumaNode` 由 `int` 改为 `*int` 可空。证据 `Ascend-npu-dra-plugin/internal/profiles/npu/dcmi.go`、`npu.go`。https://gitcode.com/openFuyao/npu-dra-plugin/compare/b33edd6dc28f0dc96f908ee7de414af931bb8fe1...c92ce682564c24f6a6ae535ab904f24cf26db18

## mind-cluster: b0f79f5a -> d0eaf52e
- 比较: b0f79f5a..d0eaf52e | tag: v26.1.0 | commits=36 | truncated=false
- 源链接:https://gitcode.com/Ascend/mind-cluster/compare/b0f79f5ac2436f3f19cbd4d71732475ce8065d6c...d0eaf52edaa03fdd29bd4d9cdf0f1d0bf4e080e5

### AI 总结重点(源码 diff 为据)
- **DPU 信息经 ConfigMap 全链路聚合,并做 800KB 分片**:新增 `component/clusterd/pkg/domain/dpu/dpu_util.go`,`ParseDpuInfoCM` 从 dpu-dp 写的 `dpuinfo-<node>` CM 里反序列化 `DpuInfoCfg`;`GetSafeData` 按 `maxCmDataSize=800*1024` 把全量 DPU 信息切成多个 chunk,规避 K8s 单 CM ~1MB 上限。clusterD 因此能横向聚合大规模集群的 DPU 状态。

  <details><summary>代码依据 component/clusterd/pkg/domain/dpu/dpu_util.go</summary>

  ```diff
  +const (
  +	// maxCmDataSize is the max data size for a single ConfigMap (~1MB limit, using 800KB for safety margin)
  +	maxCmDataSize = 800 * 1024
  +)
  +func GetSafeData(dpuInfos map[string]*constant.DpuInfo) []string {
  +	return util.SplitMapToSafeChunks(dpuInfos, maxCmDataSize,
  +		func(m map[string]*constant.DpuInfo) string {
  +			return util.ObjToString(getReportDpuInfo(m))
  +		})
  +}
  ```
  </details>

- **ascend-for-volcano CM informer 扩容纳管 DPU**:`common/k8s/cmmgr.go` 把 `initDeviceAndNodeDCmInformer` 重命名为 `initDeviceNodeDAndDPUCmInformer`,`updateConfigMap` 新增 `CheckConfigMapIsDpuInfo` 分支(增删改 dpu-dp 的 `dpuinfo-<node>` CM),`updateConfigMapCluster` 新增 `dealClusterDpuInfo`——从 clusterD 聚合的 `cluster-info-dpu-` 前缀 CM 反解 `map[string]DpuInfoWithNode` 刷进本地缓存。即调度器实时感知 DPU 拓扑与故障。

  <details><summary>代码依据 component/ascend-for-volcano/common/k8s/cmmgr.go</summary>

  ```diff
  -	cmManager.initDeviceAndNodeDCmInformer(k8sClient, stopCh)
  +	cmManager.initDeviceNodeDAndDPUCmInformer(k8sClient, stopCh)
  ...
  +	if CheckConfigMapIsDpuInfo(cm) {
  +		if operator == util.AddOperator || operator == util.UpdateOperator {
  +			cmMgr.createOrUpdateDpuInfo(cm)
  +		} else if operator == util.DeleteOperator { ... }
  +	}
  ...
  +	cmMgr.dealClusterDpuInfo(cm, operator)   // in updateConfigMapCluster
  ```
  </details>

- **DPU 隔离级故障映射到 NPU → 触发断点续训**:`internal/rescheduling/task.go` 新增 `IsDpuSeparateFault`(故障级别非 `NotHandleFault`/`SubHealthFault` 即判隔离级)与 `taskUsesFaultDpuAffectedNpu`——把任务占用的 NPU 卡号(`getNpuIDFromCardName` 解析 `xxx-<id>`)与故障 DPU 的 `AffectedNPU` 列表求交;命中即认为该任务受 DPU 故障影响,进入重调度/断点续训。这解释了 dpu-dp 侧为何要在故障上报里加 `AffectedNPU` 字段。

  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/task.go</summary>

  ```diff
  +func IsDpuSeparateFault(dpu k8s.DPUItem) bool {
  +	for _, fault := range dpu.FaultList {
  +		switch fault.FaultLevel {
  +		case NotHandleFault, SubHealthFault:
  +			continue
  +		default:
  +			return true
  +		}
  +	}
  +	return false
  +}
  +func (fTask *FaultTask) taskUsesFaultDpuAffectedNpu(fNode *FaultNode) bool {
  +	for _, fDpu := range fNode.FaultDpuList {
  +		if !IsDpuSeparateFault(fDpu) { continue }
  +		for _, taskNpu := range fTask.UseCardName {
  +			taskNpuID, err := getNpuIDFromCardName(taskNpu) ...
  +			for _, affectedNpu := range fDpu.AffectedNPU {
  +				if affectedNpu == taskNpuID { return true }
  ```
  </details>

- **RDMA 任务识别 + DPU 常量集中定义**:`common/util/util.go` 新增 `IsRdmaTask`——用节点 annotation `huawei.com/dpu.resource.name`(dpu-dp 写入)里声明的资源名集合,匹配任务 `Resreq.ScalarResources`,判断是否为 RDMA 作业。`common/util/type.go` 集中新增 DPU 键:`DpuResourceNameKey`、`DpuInfoAnnoKey=huawei.com/dpu.infos`、CM 前缀 `dpuinfo-`/`cluster-info-dpu-`、故障级别 `NotHandleFault`/`SubHealthFault`。

  <details><summary>代码依据 component/ascend-for-volcano/common/util/{util,type}.go</summary>

  ```diff
  +func IsRdmaTask(nT *api.TaskInfo, nodeAnnotation map[string]string) bool {
  +	rdmaResName, ok := nodeAnnotation[DpuResourceNameKey]
  +	if !ok || rdmaResName == "" { return false }
  +	... for k := range nT.Resreq.ScalarResources { if rdmaResSet[string(k)] { return true } }
  +}
  +	// DpuResourceNameKey node annotation key for DPU resource name, written by dpu-dp
  +	DpuResourceNameKey = "huawei.com/dpu.resource.name"
  ```
  </details>

- **节点标签体系重构为 Labeler 模式 + 新旧双写**:device-plugin 新增 `pkg/server/labelers.go`(391 行),把每类标签抽成实现 `label.NodeLabeler` 的小结构(chipName/chipMemory/serverType/driverVersion/accelerator/topology),统一经 `writeValue(labels, value, newKey, deprecatedKey)` 同时写新键与旧键。`manager.go` 把 `acceleratorLabelMap` 的取值从 `api.Accelerator910Label` 迁到 `label.Accelerator910Label`,`HwDevManager` 新增 `labelGroup`/`annotationGroup` 字段并在 `initMarkerGroups()` 一次性初始化(不再每次 `updateNode` 重建);新增 `jitterDuration=1000` 配合 `math/rand` 给注解更新加抖动。`common/util/type.go` 删除旧裸键 `Accelerator`/`AcceleratorType`/`ServerType`/`BaseDeviceInfoKey`,启用 `huawei.com/npu.server.type`、`huawei.com/npu.base-device-infos`、`huawei.com/npu.chip.name`、`huawei.com/npu.chip.memory`、`huawei.com/topotree.serverid`、`huawei.com/npu.chip.product-type`。

  <details><summary>代码依据 ascend-device-plugin/pkg/server/{labelers,manager}.go + for-volcano/common/util/type.go</summary>

  ```diff
  +func (l *chipNameLabeler) Write(labels map[string]string, ctx *label.NodeContext) error {
  +	...
  +	writeValue(labels, sanitizeLabelValue(chipInfo.Name), label.NPUChipNameLabel, label.NPUChipNameLabelDeprecated)
  +}
  ...
  -	api.Ascend910:   api.Accelerator910Label,
  +	api.Ascend910:   label.Accelerator910Label,
  ...
  -	// Accelerator for custom tag.
  -	Accelerator = "accelerator"
  +	// NPUServerTypeLabel unified server type label key
  +	NPUServerTypeLabel = "huawei.com/npu.server.type"
  ```
  </details>

- **注解读取改为优先级键回退**:`common/util/util.go` 的 `GetNodeDevListFromAnno` 不再直读 `BaseDeviceInfoKey`,改用新增的 `GetAnnotationValue(annotations, NPUBaseDevInfosAnnotation, BaseDeviceInfoKeyDeprecated)`——按新键→旧键顺序取值。同批新增 `GetLabelValue`/`GetNodeLabel` 通用回退读取器,是上面 dual-write 迁移的消费侧配套。

  <details><summary>代码依据 component/ascend-for-volcano/common/util/util.go</summary>

  ```diff
  -	baseDevInfo, ok := nodeInfo.Node.Annotations[BaseDeviceInfoKey]
  +	baseInfo, ok := GetAnnotationValue(nodeInfo.Node.Annotations, NPUBaseDevInfosAnnotation, BaseDeviceInfoKeyDeprecated)
  +func GetAnnotationValue(annotations map[string]string, keys ...string) (string, bool) {
  +	for _, key := range keys {
  +		if val, ok := annotations[key]; ok && val != "" { return strings.Trim(val, " "), true }
  +	}
  ```
  </details>

- **仅提交标题、无 patch 依据的项(不下结论,仅记录)**:`feat(cdi)` 一组(unified mount Build entrypoint / MountConfig / legacy list-mode reader / glob+symlink helpers)、`container-manager 支持 A5 热复位`、`coordinator 新增容器协调服务 protobuf`。这些文件未落入本次 component/ 信号集的 patch 节选,方向待下期看到 hunk 再研判。

### 后续发展方向 [AI]
- 昇腾这次把"网络域故障(DPU/RDMA)"接进了原本只管"NPU 卡故障"的重调度状态机:`AffectedNPU` 建立了 DPU→NPU 的影响传播边,隔离级 DPU 故障会把其影响的 NPU 上的训练任务一并重调度/断点续训。证据覆盖到 volcano 侧的判定与 clusterD 聚合,**未见** dpu-dp 侧如何生成 `AffectedNPU`(拓扑映射算法在 dpu-dp 组件,本区间信号集未含其 patch)。
- 节点标签/注解统一到 `huawei.com/npu.*` 命名空间且带 Deprecated 双写,是明确的契约治理动作;**证据只覆盖写侧(labelers.go)+ 读侧回退(GetAnnotationValue)**,未见双写的退场时间表——依赖旧裸键(如自研调度器直接读 `accelerator`/`servertype`)的集成方需在此兼容期内切到新键。
- 对我们产品的启示:若我们要对标"训练 fabric 故障自愈",DPU/智能网卡故障→受影响加速卡→任务重调度这条链是可直接借鉴的数据面设计(故障 CM 上报 + AffectedNPU 影响集 + 调度器求交)。另外节点标签命名空间化(`vendor/npu.*`)+双写迁移是低风险的契约演进范式,值得在我们自有 device-plugin 标签体系里预置。

## npu-dra-plugin: b33edd6d -> c92ce768
- 比较: b33edd6d..c92ce768 | tag: v26.6.0 | commits=4 | truncated=false
- 源链接:https://gitcode.com/openFuyao/npu-dra-plugin/compare/b33edd6dc28f0dc96f908ee7de414af931bb8fe1...c92ce682564c24f6a6ae535ab904f24cf26db18

### AI 总结重点(源码 diff 为据)
- **DRA driver 新增 npu-smi 拓扑发现**:`internal/profiles/npu/dcmi.go` 在 `discoverWithDCMI` 里 DCMI 发现设备后,追加调 `getNpuSmiTopologyGroups`+`applyTopologyGroups`,通过 `runNpuSmiCommand`(exec `/usr/local/bin/npu-smi`,3 次重试、3s 超时、200ms 退避)拿 HCCS 环网/SIO 拓扑分组并回填到设备。`DeviceSpec` 新增 `PCIeRoot`/`TopoHccsRingID *int`/`TopoSioID *int`,并把 `NumaNode` 由 `int` 改为 `*int`(可区分"未知 NUMA"与 node 0)。

  <details><summary>代码依据 Ascend-npu-dra-plugin/internal/profiles/npu/dcmi.go</summary>

  ```diff
  +	pcieRootAttr       = "resource.kubernetes.io/pcieRoot"
  +	topoHccsRingIDAttr = "topoHccsRingID"
  +	topoSioIDAttr      = "topoSioID"
  +	npuSmiPath         = "/usr/local/bin/npu-smi"
  +var runNpuSmiCommand = func(ctx context.Context, args ...string) ([]byte, error) {
  +	return exec.CommandContext(ctx, npuSmiPath, args...).Output()
  +}
  -	NumaNode    int
  +	NumaNode       *int
  +	PCIeRoot       string
  +	TopoHccsRingID *int
  +	TopoSioID      *int
  ...
  +	topoGroups, topoErr := getNpuSmiTopologyGroups(topologyCtx)
  +	if topoErr != nil { klog.Warningf("npu topology discovery unavailable: %v", topoErr)
  +	} else { applyTopologyGroups(topologyCtx, devices, topoGroups) }
  ```
  </details>

- **软切分(vNPU)设备继承物理卡拓扑**:`internal/profiles/npu/npu.go` 的 `getSoftDeviceAttributes` 在生成软切分设备属性时,把物理设备的 `pcieRoot`/`topoHccsRingID`/`topoSioID` 一并透传给 vNPU 设备(此前仅透传 pciBusID/numaNode)。意味着软切分场景下 DRA 调度器也能对 vNPU 做 HCCS 环网/PCIe 亲和约束,不再退化为拓扑无关。

  <details><summary>代码依据 Ascend-npu-dra-plugin/internal/profiles/npu/npu.go</summary>

  ```diff
   		if busID, ok := physDev.Attributes["resource.kubernetes.io/pciBusID"]; ok {
   			attributes["resource.kubernetes.io/pciBusID"] = busID
   		}
  +		if pcieRoot, ok := physDev.Attributes[pcieRootAttr]; ok { attributes[pcieRootAttr] = pcieRoot }
  +		if ringID, ok := physDev.Attributes[topoHccsRingIDAttr]; ok { attributes[topoHccsRingIDAttr] = ringID }
  +		if sioID, ok := physDev.Attributes[topoSioIDAttr]; ok { attributes[topoSioIDAttr] = sioID }
  ```
  </details>

- **README 首次系统化文档三种分配模式**(文档,但揭示能力矩阵):整卡独占 / 硬切分(910B,固定模板按 `aiCore`+`aiCPU` 匹配,需 `runtimeClassName: ascend`)/ 软切分(基于 vCANN-RT 运行时劫持库,按 `memCapacity`+`coreCapacity` 配额,支持 elastic/fixed-share/best-effort 三策略,单物理 NPU 最多 63 vNPU)。环境要求 K8s v1.34+ 且需启 `DynamicResourceAllocation`+`DRAConsumableCapacity` 门控。约束:910C 需单 die 模式方可切分。

  <details><summary>代码依据 README-zh.md</summary>

  ```diff
  +  - **软切分**：基于vCANN-RT运行时劫持库实现软件虚拟化，按`memCapacity`+`coreCapacity`灵活配额共享物理NPU，支持弹性（elastic）、固定份额（fixed-share）、尽力而为（best-effort）三种调度策略。
  +- Kubernetes v1.34及以上（需启用`DynamicResourceAllocation`及`DRAConsumableCapacity`特性门控，推荐v1.34.3）。
  +3. 软切分依赖vCANN-RT劫持库（可通过Helm的`vcannrtInstaller`自动安装），每个物理NPU最多支持63个vNPU实例。
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 DRA 路径正在补齐"拓扑感知"这块短板:先前 ResourceSlice 只有 pciBusID/numaNode,现在补上 HCCS 环网 ID/SIO/PCIe root,配合 CEL 就能表达"同 HCCS 环内成组分配"的训练亲和。`NumaNode` 改指针也是在为"拓扑属性可缺省"做准备。**证据覆盖属性发现与透传两侧**,未见调度器/DeviceClass 侧如何用这些新属性写 CEL(需看使用样例或 webhook)。
- 软切分(vCANN-RT + `DRAConsumableCapacity`)从代码走向文档化,说明这条"对标 HAMi vGPU 的软隔离"路线已趋稳定;结合 hami-watch 里 HAMi 也在做昇腾 vNPU,昇腾官方 DRA 软切分与 HAMi 软切分构成同生态两条并行路线,值得持续对比隔离强度与调度策略差异。
- 对我们产品的启示:DRA 设备属性里内置厂商拓扑(HCCS 环)是"原生调度器 + 拓扑亲和"的关键落点;若我们自研 DRA driver 覆盖 NPU,应同样把互联拓扑(而非仅 NUMA)作为一等设备属性上报,否则大模型训练的通信域亲和无从表达。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo(仅保锚点)</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=d0eaf52edaa03fdd29bd4d9cdf0f1d0bf4e080e5 tag=v26.1.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=vNPU sha=9d8a271694a5b157c7f6dfca07a683cadb7c55e6 tag=v0.1.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=npu-dra-plugin sha=c92ce682564c24f6a6ae535ab904f24cf26db18 tag=v26.6.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-26 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-26 -->
</content>
</invoke>
