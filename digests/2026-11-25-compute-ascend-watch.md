# 昇腾算力栈 diff 雷达 2026-11-25

## 摘要
- **vNPU 纳管 A5(Ascend950)**:xpu-device-plugin 抽出 `DeviceManagerInterface`,启动时先试 DCMI V2(`dcmi.DcV2Manager`),失败再回退 V1;A5 查 die id 时 VDIE 会返回 -8255,此时改用 DDIE 重查。新增芯片能力表 `chipCapabilityTable`,其中 `Ascend950` 的 `SupportHardCut=false`(不支持 HDK 硬切分)。节点新增 annotation `huawei.com/node-vnpu-register-v2`(12 字段,带 logicID/supportHardCut/memType),旧 v1 annotation 从 9 字段扩到 10 字段(末尾加 logicID)。volcano-xpu-plugin 对应改动:`mode=hard` 的 Pod 遇到含不支持硬切分卡的节点,直接判 Unschedulable;device-plugin 侧,hard 模式节点上有这类芯片时,自动降级为 soft。
- **升级顺序有坑(推断)**:新 device-plugin 写出的 v1 annotation 是 10 字段,旧版 volcano-xpu-plugin 的 `DecodeNodeDevices` 要求字段数**严格等于** `XPUDeviceLen=9`,不符就整节点解码为空。所以要先升级调度插件,再升级 device-plugin,否则节点上的 vNPU 会从调度视图里消失。
- **mind-cluster infer-operator 把副本数/枚举校验前移到 CRD**(kubebuilder 声明式校验):`InferServiceSet.replicas` 加 `minimum: 1`,`InstanceSet.replicas` 加 `minimum: 0`,`scalingPolicy.type` 限定为 ""/HPA,`schedulingStrategy.type` 限定为 ""/Parallel/Priority。controller 里对应的手写校验同时删除。其余 openFuyao 9 仓零提交,mind-cluster tag 仍为 v26.3.0-beta.2。

## 当日重要改变
- vNPU [新能力] 新增 `xpu-device-plugin/pkg/plugin/xpu/device_manager.go`(DCMI V1/V2 双实现)和 `chip_capability.go`(Ascend950 不支持硬切分),完成 A5 纳管。节点注册协议新增 `huawei.com/node-vnpu-register-v2`,v1 annotation 从 9 字段扩到 10 字段。 https://gitcode.com/openFuyao/vNPU/commit/404f8b4e7fedde661cc0a7122cca679a40ea259f
- vNPU [行为变更] volcano-xpu-plugin `NodePredicateForTask` 对 hard 模式 Pod 新增前置判断 `IsNodeSupportHardCut`,不满足即 Unschedulable;device-plugin `parseNodeModeFromConfigMap` 在 hard 模式下遇到不支持硬切分的芯片,把 `config.NodeMode` 强制改为 soft。 https://gitcode.com/openFuyao/vNPU/commit/404f8b4e7fedde661cc0a7122cca679a40ea259f
- mind-cluster [API/CRD变更] infer-operator 三个 `*_types.go` 加 kubebuilder `Minimum`/`Enum` 校验,`build/infer-operator.yaml` 的 CRD schema 同步更新。 https://gitcode.com/Ascend/mind-cluster/commit/f2c871a621d457ebf70ab21ea243e81a16f0b5ea

## mind-cluster: 4b230db0 -> e845d2e1
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/4b230db07136b3e2a3feff044843cb9c83457305...e845d2e1c5337c0831e54d9bbdaa0bf8231c4f0c | tag: v26.3.0-beta.2 | commits=4(2 个实质提交 + 2 个 merge) | truncated=false
- 改动分布(不限 path,全量核对):`component/infer-operator` 9、`tests/st` 2。没有新 component 冒出来,PATHPREFIX 清单无遗漏。`[Presmoke]` 那条提交只改了 `tests/st` 的冒烟部署脚本,不在本 task 范围内。

### AI 总结重点(源码 diff 为据)
- **infer-operator CRD 声明式校验**:`InferServiceSetSpec.Replicas` 加 `+kubebuilder:validation:Minimum=1`,`InstanceSetSpec.Replicas` 加 `Minimum=0`,`ScalingPolicy.Type` 加 `Enum="";HPA`,`SchedulingStrategy.Type` 加 `Enum="";Parallel;Priority`。改动前后的行为差异:
  - 以前 `replicas<1`(ISS)或 `replicas<0`(InstanceSet)的对象可以创建成功,要等 reconcile 时 `validate()` 打 Warning Event 或报错。现在 apiserver 准入阶段直接拒绝。
  - 以前 `type` 写任意字符串都能入库,现在不在枚举内的值会被拒。**存量对象如果带了枚举外的值,下次 update 会失败**(推断:CRD schema 收紧对存量对象的常规影响,diff 里没有迁移逻辑)。
  - `MaxInferServiceReplicas` 上限仍由 controller 在 reconcile 时校验,没有写进 CRD 的 `maximum`;`Replicas==nil` 时默认设为 1 的逻辑也保留。
  https://gitcode.com/Ascend/mind-cluster/commit/f2c871a621d457ebf70ab21ea243e81a16f0b5ea
  <details><summary>代码依据 component/infer-operator/pkg/api/v1/*_types.go + controller</summary>

  ```diff
   type ScalingPolicy struct {
  +	// +kubebuilder:validation:Enum="";HPA
   	Type string               `json:"type,omitempty"`
  @@ InstanceSetSpec
  +	// +kubebuilder:validation:Minimum=0
   	Replicas           *int32               `json:"replicas,omitempty"`
  @@ InferServiceSetSpec
  +	// +kubebuilder:validation:Minimum=1
   	Replicas             *int32           `json:"replicas,omitempty"`
  @@ SchedulingStrategy
  +	// +kubebuilder:validation:Enum="";Parallel;Priority
   	Type string `json:"type,omitempty"`
  @@ inferserviceset_controller.go validate()
  -	if *iss.Spec.Replicas > common.MaxInferServiceReplicas || *iss.Spec.Replicas < 1 {
  +	if *iss.Spec.Replicas > common.MaxInferServiceReplicas {
  @@ instanceset_controller.go validate()
  -	if *replicas < 0 {
  -		errorMsg := fmt.Sprintf("jobSpec is not valid: replicas can not be negative num, but but got %d",
  ```
  </details>

### 后续发展方向 [AI]
- infer-operator 的 API 在逐步向标准 operator 的做法收敛:校验从 reconcile 前移到 CRD schema。这里的 `SchedulingStrategy`(Parallel/Priority)和 `ScalingPolicy`(目前只有 HPA)两个枚举,是它推理编排能力面的边界,后续出现新枚举值就是新能力信号。证据只覆盖本次 schema 收紧,没看到新枚举值,也没看到 webhook。

## vNPU: 529e48a6 -> 4414d35e
- 比较: https://gitcode.com/openFuyao/vNPU/compare/529e48a62557698ce7a0b4a8c6df5f095d626572...4414d35e61e85fc8eb501b68e70b8ba04b4816e0 | tag: v26.9.0 | commits=2(`feat: support A5` + merge !97) | truncated=false
- 取数说明:helper 节选里 `npu.go`、`util.go`、`device_manager.go`、`volcano-xpu-plugin/plugin/util.go` 都被截断,`plugin.go`、`register.go`、`types.go`、`Dockerfile` 没进入节选。下面引用的这几处是从 compare JSON 直接补拉的。

### AI 总结重点(源码 diff 为据)

#### 1. 设备访问层抽象 + DCMI V2 优先、V1 回退
`npu.go` 里的全局 `dm` 从 `*dcmi.DcManager` 改为接口 `DeviceManagerInterface`(12 个方法,全部以 logicID 为主键)。`Init()` 先调 `initV2()`(`dcmi.DcV2Manager`),失败再调 `initV1()`。以前很多调用要先 `DcGetCardIDDeviceID` 换出 (cardID, deviceID),现在统一按 logicID 调用:`Devices`/`CheckHealth`/`GetDeviceInfo`/`GetXPUUsage` 都改了,`GetCardIDs()` 实际返回的也是 logicID 列表。`V2DeviceManager.GetDieID` 遇到 VDIE 不支持(-8255)时用 DDIE 重试;`Devices()` 里如果仍拿不到,就用 logicID 字符串充当 device id。
<details><summary>代码依据 xpu-device-plugin/pkg/plugin/xpu/npu.go / device_manager.go</summary>

```diff
-	dm *dcmi.DcManager = &dcmi.DcManager{}
+	dm     DeviceManagerInterface
+	dcmiV1 = &dcmi.DcManager{}
@@ func Init() error {
-	return dm.DcInit()
+	// prefer the DCMI V2 interface; drivers without the V2 entry symbols
+	// (old generation chips) fail the V2 init and fall back to V1
+	if err := initV2(); err != nil {
+		log.Infof("V2 DCMI init failed: %v, falling back to V1", err)
+		return initV1()
+	}
@@ device_manager.go
+func (v *V2DeviceManager) GetDieID(logicID int32) (string, error) {
+	dieID, err := v.dm.DcGetDieID(logicID, dcmi.VDIE)
+	...
+	// A5 generation chips (Ascend950) report DDIE as their die id type and
+	// answer -8255 for VDIE; retry with DDIE before giving up
+		return v.dm.DcGetDieID(logicID, dcmi.DDIE)
+func (v *V2DeviceManager) GetMemoryInfo(logicID int32) (*common.MemoryInfo, error) {
+	return nil, fmt.Errorf("DCMI V2 does not support GetMemoryInfo (DDR), use GetHbmInfo instead")
```
</details>

- **风险点(推断)**:`V2DeviceManager.GetMemoryInfo` 恒返回错误,而 `GetDeviceInfo` 对非 HBM 芯片走 `GetMemoryInfo`,出错就 `log.Fatalf`。能力表里 `Ascend310P` 是 `MemoryTypeDDR`。如果 310P 节点上的驱动导出了 V2 符号、`initV2()` 成功,device-plugin 启动时会直接退出。diff 里没有"DDR 芯片强制走 V1"的分支。

#### 2. 芯片能力表与硬切分能力位
新增 `chip_capability.go`:`chipCapabilityTable` 记录 310P(DDR,可硬切)、910/910B(HBM,可硬切)、**950(HBM,不可硬切)**。`isHbmChip` 改为查表,查不到再回退到"名称含 910"的老规则。`GetDeviceInfo` 把 `LogicID`/`SupportHardCut`/`MemoryType` 填进 `types.DeviceInfo`,proto 字段号对应 10/11/12。
<details><summary>代码依据 xpu-device-plugin/pkg/plugin/xpu/chip_capability.go / types/types.go</summary>

```diff
+	"Ascend950": {
+		ChipName:       "Ascend950",
+		SupportHardCut: false,
+		MemoryType:     MemoryTypeHBM,
+	},
@@ type DeviceInfo struct {
+	LogicID        int32  `protobuf:"varint,10,opt,name=logic_id,json=logicid,proto3" json:"logicid,omitempty"`
+	SupportHardCut bool   `protobuf:"varint,11,opt,name=support_hard_cut,json=supporthardcut,proto3" json:"supporthardcut,omitempty"`
+	MemoryType     string `protobuf:"bytes,12,opt,name=memory_type,json=memorytype,proto3" json:"memorytype,omitempty"`
```
</details>

#### 3. 节点注册协议:v1 扩字段 + 新 v2 annotation
`EncodeNodeDevices`(v1)末尾追加 logicID,从 9 字段变成 10 字段(`deviceLength` 9→10)。新增 `EncodeNodeDevicesV2`,格式为 `index,logicID,id,count,mem,type,health,numa,mode,core,supportHardCut,memType`。`registerInAnnotation` 在保留 v1 的同时写入 `huawei.com/node-vnpu-register-v2`。device-plugin 自己的 `DecodeNodeDevices` 兼容 9 字段的老格式(此时 logicID 回落为 index)。
volcano-xpu-plugin 的 `DecodeNodeDevices` 由严格 `len(items) != XPUDeviceLen` 改为 `switch`:接受 9、10、12(`XPUDeviceLenV2`)三种长度;`GetXPUDevicesFromNode` 在 v1 解码为空时回退读 v2。
<details><summary>代码依据 xpu-device-plugin/pkg/plugin/register.go / util/util.go / volcano-xpu-plugin/plugin/util.go</summary>

```diff
@@ register.go registerInAnnotation()
+	encodedDevicesV2 := util.EncodeNodeDevicesV2(devices)
+	if encodedDevicesV2 != "" {
+		annotations[xpu.NodeVXPURegisterV2] = encodedDevicesV2
+	}
@@ util.go
-	deviceLength = 9
+	deviceLength = 10
@@ volcano-xpu-plugin/plugin/util.go DecodeNodeDevices
-			if len(items) != util.XPUDeviceLen {
+		switch len(items) {
+		case util.XPUDeviceLenV2:
+			if device := decodeV2Device(items, nodeId); device != nil {
+		case util.XPUDeviceLen, util.XPUDeviceLen + 1:
+			// the current device-plugin appends a logicID field to the v1
+			// format (9 -> 10 fields); parse it as v1 and ignore the extra
+			// field so mixed clusters keep working
```
</details>

- **升级顺序(推断)**:base 版 volcano-xpu-plugin 只要遇到一个设备不是 9 字段,就 `return map[int]*common.XPUDevice{}`。所以"新 device-plugin + 旧调度插件"组合下,整个节点的 vNPU 都会解码为空。代码注释里的 "mixed clusters keep working" 只对**新调度插件 + 新旧 device-plugin 混部**成立。

#### 4. 硬切分能力闸门(调度侧 + 节点侧)
- 调度侧:`NodePredicateForTask` 把 `podMode` 的解析提到设备评估之前。`hard` 模式下如果 `IsNodeSupportHardCut(node)` 为 false,直接返回 `Unschedulable`。`IsNodeSupportHardCut` 只看 v2 annotation,**任意一张卡** `supportHardCut=false` 整节点就判为不支持;没有 v2 annotation 的节点默认判为支持。
- 节点侧:`parseNodeModeFromConfigMap` 在 hard 模式下遇到含不可硬切芯片的节点(读的是 v1 annotation 的 Type,经 `IsHardCutUnsupportedType` 判定),把 `config.NodeMode` 改为 soft。`enableDeviceShareMode` 以前无条件执行,现在只在 soft 模式执行;遇到不可硬切芯片时还会跳过 `npu-smi ... device-share` 和 `vnpu-cfg-recover`。
<details><summary>代码依据 volcano-xpu-plugin/plugin/plugin.go / xpu-device-plugin/pkg/plugin/util/node.go</summary>

```diff
+	if podMode == util.HardMode && !IsNodeSupportHardCut(node) {
+		klog.V(util.LogWarningLevel).Infof("node %s does not support hard cut, rejecting pod %s",
+			node.Name, task.Name)
+		return api.Unschedulable, fmt.Errorf("node %s does not support hard cut mode", node.Name)
+	}
@@ node.go
-	enableDeviceShareMode()
+	if IsSoftMode() {
+		enableDeviceShareMode()
+	}
+	if config.NodeMode == hardMode && isHardCutUnsupportedNode() {
+		log.Warningf("node %s has a chip which does not support hard cut, falling back to soft mode",
+		config.NodeMode = softMode
```
</details>

#### 5. vxpu 信息文件、进程统计与镜像
- `writeVxpuInfo`:在 `IsDcmiV2ByMode()`(实现只判断 `NodeMode=="soft" && dm!=nil`,**并没有真正检查是不是 V2**)为真时,`physical-npu-id` 改为写 `GetLogicIDForDevice(Index)`,超过 `MaxNpuID=15` 就报错(注释写的是 "for 950PR")。但 `logicIDFromPhysicID` 默认是恒等函数,diff 里也没有任何地方调用 `SetLogicIDLookup`,所以本期实际写出的仍是物理 ID,只是多了一道 ≤15 的上限检查(证据边界:只看 diff)。
- `getUidToProcessMap` 调 `GetXPUUsage` 的参数从 `v.Index` 改为 `v.LogicID`,修正了物理 ID 和逻辑 ID 不一致时查错卡的问题;测试专门覆盖了 `LogicID=0, Index=7`。`getContainerID` 只返回 Running 容器的 ID;cgroup 找不到时降为 Warning 并返回空,不再继续往下读。
- 镜像:`npu-device-plugin.Dockerfile` 在 aarch64 构建时下载并安装 UMDK(`umdk-urma-26.06.0`,提供 `liburma.so.0`),注释说明不装的话 dcmi 加载会失败,"仅 unified bus 场景必需"。submodule `third_party/mind-cluster` 的 tag 从 v7.2.RC1.SPC1 升到 v26.1.0,`DcV2Manager` 应该就来自这里。
<details><summary>代码依据 xpu-device-plugin/pkg/plugin/plugin.go / service_impl.go / Dockerfile / .gitmodules</summary>

```diff
-		info := fmt.Sprintf("physical-npu-id=%d\n", contDev.Index)
+		npuID := contDev.Index
+		if xpu.IsDcmiV2ByMode() {
+			npuID = xpu.GetLogicIDForDevice(contDev.Index)
+			if npuID > xpu.MaxNpuID {
@@ service_impl.go getUidToProcessMap
-		deviceUsageInfo, processMap, err := xpu.GetXPUUsage(v.Index, int32(period))
+		deviceUsageInfo, processMap, err := xpu.GetXPUUsage(v.LogicID, int32(period))
@@ getContainerID
-		if status.Name == containerName {
+		if status.Name == containerName && status.State.Running != nil {
@@ Dockerfile
+ARG UMDK_URL="https://mirrors.huaweicloud.com/ascend/archive/deb/unifiedbus/common/umdk-urma-26.06.0-B025.glibc217.arrch64.deb.tar.gz"
@@ .gitmodules
-	tag = v7.2.RC1.SPC1
+	tag = v26.1.0
```
</details>

### 后续发展方向 [AI]
- **A5 代际的 vNPU 只能做软切分**:能力表把 950 标成 `SupportHardCut=false`,调度和节点两侧都加了闸门。这说明 A5 上的 vNPU 切分要依赖 vCANN 软隔离(soft 模式),不再走 HDK 硬切分。对我们的影响:多厂商切分能力矩阵需要按芯片代际声明"可硬切/仅软切",不能按厂商一刀切。证据只覆盖能力表和闸门逻辑,没看到 950 的软切分配额实现改动。
- **从 cardID/deviceID 二元寻址迁移到以 logicID 为主键的 DCMI V2**:`DeviceManagerInterface` 的抽象,加上 v2 annotation 里的 logicID/memType,是为了一套代码同时管 910 系(V1)和 950(V2)。`SetLogicIDLookup` 目前只是预留钩子、没接线,后续应该会补上物理 ID→逻辑 ID 的映射。证据边界:只看到钩子定义,没看到调用。
- **UB(unified bus)依赖进入 device-plugin 镜像**:和 ub-network-device-plugin / ub-network-bandwidth-operator 是同一条 fabric 主线,A5 超节点的 UB 互联开始下沉到单卡管理组件。证据只有 Dockerfile 注释和 UMDK 包,没看到 device-plugin 调用 urma 的代码。

## 本期无实质改动(折叠)
- npu-operator: ddcf0eb7..ddcf0eb7 无新提交(v26.9.0)
- npu-container-toolkit: c720a3b8..c720a3b8 无新提交(v26.9.0)
- npu-driver-installer: bd1b2a9e..bd1b2a9e 无新提交(v26.9.0)
- npu-node-provision: 717ef777..717ef777 无新提交(v26.6.0)
- npu-dra-plugin: f0654355..f0654355 无新提交(v26.9.0)
- npu-feature-discovery: 4ba6e58e..4ba6e58e 无新提交(v26.9.0)
- volcano-ext: 0f265f98..0f265f98 无新提交(v1.9.0)
- ub-network-device-plugin: 9cc5dbdd..9cc5dbdd 无新提交(v26.9.0)
- ub-network-bandwidth-operator: d4ee1a47..d4ee1a47 无新提交(无 tag)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=e845d2e1c5337c0831e54d9bbdaa0bf8231c4f0c tag=v26.3.0-beta.2 scanned=2026-11-25 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=vNPU sha=4414d35e61e85fc8eb501b68e70b8ba04b4816e0 tag=v26.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=npu-feature-discovery sha=4ba6e58e3e132f61936ae2c619f91d9e75c5ec90 tag=v26.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=9cc5dbdd87c01f90aa7f9ea8038b7a1ed5b2bd2d tag=v26.9.0 scanned=2026-11-25 -->
<!-- ANCHOR repo=ub-network-bandwidth-operator sha=d4ee1a478ec50c0c543b73f01a00944467e8018d tag=— scanned=2026-11-25 -->
