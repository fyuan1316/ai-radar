# 昇腾算力栈 diff 雷达 2026-07-10

## 摘要
- **mind-cluster 把 SR-IOV 网络栈整体开源合入**:新增 `component/sriov-cni` 与 `component/sriov-network-device-plugin` 两个顶层组件(纯 added,合计数千行,含 CNI/资源池/deviceSelector/工厂/mocks 全套),这是昇腾多机训练 fabric 侧首次在 mind-cluster 主仓落地 SR-IOV VF 直通网络能力(此前只有算力设备,网络走外部)。属 `[新能力][架构方向]`。
- **两处"适配新代际/新版本"改动**:①调度侧适配 Volcano 1.12——`ascend-for-volcano` 显式把 `NotReady` 节点排除出可调度列表(1.12 起 volcano 不再帮忙剔除);②设备解析适配新代际——`device_parser.go`/npu-exporter `parser.go` 的占卡解析除 `Ascend910-0` 外新增识别小写 `npu-0,npu-1` 格式。
- **vNPU 新增按 dieID / NPU 型号过滤设备的调度能力**(!72):Pod 注解 `huawei.com/vnpu-use-npu-dieID`、`huawei.com/vnpu-use-npu-type` 可把 vNPU 精确绑到指定物理 die 或指定芯片型号(如 310P3/910B),`IsDeviceQualified` 加两道过滤门。属 `[新能力]`。
- 其余 6 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)全无新提交。mind-cluster tag 停在 v26.1.0.beta.2。

## 当日重要改变
- mind-cluster [新能力][架构方向] SR-IOV 网络栈开源合入:新增 `component/sriov-cni`(CNI 主逻辑 sriov.go 516 行 + config/utils)与 `component/sriov-network-device-plugin`(资源池 server.go/manager.go/deviceSelectors + 全套 mocks),昇腾多机训练网络 fabric 走 VF 直通首次进主仓。证据文件 component/sriov-cni/pkg/sriov/sriov.go、component/sriov-network-device-plugin/pkg/resources/server.go。https://gitcode.com/Ascend/mind-cluster/compare/c836864aa50044c463790eb8b2f9e4d7fa7c321f...f1816ec35614ca5e56a18acfdc680f78cecc480d
- mind-cluster [修复] ascend-for-volcano 适配 Volcano 1.12:`getNeedInitNodeList` 由无条件 `append(ssn.NodeList...)` 改为逐节点 `util.IsNodeReady` 过滤,把 real-NotReady 节点排除出可调度节点(1.12 不再自动剔除)。证据文件 component/ascend-for-volcano/plugin/node.go。同上 compare 链接
- mind-cluster [新能力] 设备占卡解析适配新代际小写命名:`parseDeviceIDs`/`ascendStyle` 除 `Ascend` 前缀外新增匹配 `api.NPULowerCase`(`npu`),支持 `npu-0,npu-1` 设备名。证据文件 component/ascend-common/common-utils/parser/device_parser.go、component/npu-exporter/collector/container/parser.go。同上 compare 链接
- mind-cluster [修复] device-plugin 故障等级判定 SubHealth 优先于 NotHandle,并补全故障事件字段:`GetFaultTypeByCode` switch 中 SubHealthFault 分支上移到 NotHandleFault 之前;a950 超平面故障恢复/发生事件补 `LogicID`+`Assertion`。证据文件 component/ascend-device-plugin/pkg/common/fault_code.go。同上 compare 链接
- vNPU [新能力] 按 dieID / NPU 型号过滤 vNPU 调度:新增注解 `huawei.com/vnpu-use-npu-dieID`、`huawei.com/vnpu-use-npu-type`,`IsDeviceQualified` 加 dieID 与 Type 两道不匹配即淘汰逻辑。证据文件 volcano-xpu-plugin/plugin/vxpu.go、util/type.go、util/task.go。https://gitcode.com/openFuyao/vNPU/compare/8c58a454b89831edc3b1f51a22b24852c5e5f24f...464c7358071a6cc48f463c10fedf6b2d4519a5f3

## mind-cluster: c836864a -> f1816ec3
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/c836864aa50044c463790eb8b2f9e4d7fa7c321f...f1816ec35614ca5e56a18acfdc680f78cecc480d | tag: v26.1.0.beta.2 | commits=18 | truncated=true(files=300)

> helper 标 `__OVERVIEW__`(truncated=true)。但本区间信号文件多为 added 新组件与小改动,已单独拉取真实 patch 写符号级;因 truncated 文件清单可能不全,sriov 相关新增文件以已见的为准。

### AI 总结重点(源码 diff 为据)

- **新增两个顶层组件 `component/sriov-cni` 与 `component/sriov-network-device-plugin`(SR-IOV 网络栈开源合入)**。sriov-network-device-plugin 侧含资源发现/资源池 `pkg/resources/server.go`(385 行)、`cmd/sriovdp/manager.go`(270 行)、`deviceSelectors.go`、工厂 `pkg/factory/factory.go`、netDevice/auxNetDevice provider 及全套 mocks;sriov-cni 侧含 `pkg/sriov/sriov.go`(516 行)、`cnicommands/cni.go`、`config/config.go`、netlink 操作。对昇腾栈意义:此前 mind-cluster 只覆盖 NPU 算力设备,网络 fabric(多机训练 RDMA/参数面)依赖外部 CNI;现把 SR-IOV VF 直通的 device-plugin+CNI 一并收进主仓,形成"算力设备 + 网络设备"统一供给。
  <details><summary>代码依据 新增文件清单(node/aux provider + 资源池 + CNI)</summary>

  ```
  + component/sriov-network-device-plugin/pkg/resources/server.go        (385, added)
  + component/sriov-network-device-plugin/cmd/sriovdp/manager.go         (270, added)
  + component/sriov-network-device-plugin/pkg/resources/deviceSelectors.go
  + component/sriov-network-device-plugin/pkg/factory/factory.go         (230, added)
  + component/sriov-network-device-plugin/pkg/netdevice/netDeviceProvider.go
  + component/sriov-cni/pkg/sriov/sriov.go                               (516, added)
  + component/sriov-cni/pkg/cnicommands/cni.go                           (332, added)
  + component/sriov-cni/pkg/config/config.go                            (204, added)
  ```
  </details>

- **ascend-for-volcano 调度前显式剔除 NotReady 节点(适配 Volcano 1.12)**。`getNeedInitNodeList` 原来把 `ssn.NodeList` 全量并入待初始化节点;新逻辑逐个 `util.IsNodeReady(node.Node)` 判断,real-notready 节点打 warning 并 `continue` 跳过。对应提交标题"[volcano]适配1.12版本未将NotReady节点排除出可调度节点"——即 Volcano 1.12 改了行为不再自动过滤,昇腾插件需自己兜底,否则会把宕机节点当可调度。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/node.go</summary>

  ```diff
  -	return append(nodeList, ssn.NodeList...)
  +	for _, node := range ssn.NodeList {
  +		if !util.IsNodeReady(node.Node) {
  +			klog.V(util.LogWarningLev).Infof("node <%s> is real notready", node.Name)
  +			continue
  +		}
  +		nodeList = append(nodeList, node)
  +	}
  +	return nodeList
  ```
  </details>

- **占卡设备解析新增小写 `npu-` 命名识别(适配新代际)**。`parseDeviceIDs` 与 npu-exporter 的 `ascendStyle` 判定原本只认包含 `Ascend` 的设备字符串(`Ascend910-0`);现在追加 `|| strings.Contains(devices, api.NPULowerCase)`,即也把 `npu-0,npu-1` 走 `parseAscendStyle` 解析。对应"npu容器占用卡逻辑解析适配新代际"——新代 NPU 在容器环境变量里上报的设备名改用小写 `npu-` 前缀。
  <details><summary>代码依据 device_parser.go + npu-exporter parser.go</summary>

  ```diff
  -	// Handle Ascend style: Ascend910-0,Ascend910-1
  -	if strings.Contains(devices, ascend) {
  +	// Handle Ascend style: Ascend910-0,Ascend910-1 or npu-0,npu-1
  +	if strings.Contains(devices, ascend) || strings.Contains(devices, api.NPULowerCase) {
  		return parseAscendStyle(devices, containerID)
  	}
  ```
  </details>

- **故障类型判定把 SubHealth 优先级提到 NotHandle 之上,并补全故障事件字段**。`GetFaultTypeByCode` 的 switch 中,`SubHealthFaultCodes` 分支上移到 `NotHandleFaultCodes` 之前——原顺序会让同时命中"亚健康"和"不处理"的码先返回 NotHandle,现优先判亚健康(subHealth > NotHandle)。另 `a950HyperPlaneNewOverallFaultModify` 在构造 UB 分离恢复(`FaultRecover`)/亚健康发生(`FaultOccur`)事件时补 `LogicID` 与 `Assertion` 字段,修"日志打印故障事件不全"。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
  -	case Int64Tool.SameElement(faultTypeCode.NotHandleFaultCodes, faultCodes):
  -		return NotHandleFault
  	case Int64Tool.SameElement(faultTypeCode.SubHealthFaultCodes, faultCodes):
  		return SubHealthFault
  +	case Int64Tool.SameElement(faultTypeCode.NotHandleFaultCodes, faultCodes):
  +		return NotHandleFault
  ...
  		tmpFaultInfo := common.DevFaultInfo{
  			EventID:         UBSubHealFaultCode,
  +			LogicID:         device.LogicID,
  +			Assertion:       common.FaultOccur,
  			AlarmRaisedTime: curTime,
  		}
  ```
  </details>

- **其余为噪声**:ascend-docker-runtime 仅 README 大小写重命名(`.MD`→`.md`)、pre-commit 新增 gitleaks 敏感信息检测、多篇文档规范化,无逻辑变化。

### 后续发展方向 [AI]
- **昇腾栈从"算力设备供给"扩到"网络设备供给"**:SR-IOV CNI + device-plugin 进主仓,意味着 mind-cluster 想统一管理多机训练的 RDMA/参数面网络 VF,而非只做 NPU 算力。这与 ub-network-device-plugin(UB 超低时延 fabric)是两条网络路线——SR-IOV 走标准 VF 直通、UB 走华为私有超节点互联;需后续观察二者是否收敛。证据仅覆盖新增文件清单与 sriov.go/server.go 存在,未逐行读 VF 分配/隔离实现(truncated 且新增量大)。
- **调度与解析层持续跟上游/新硬件代际**:同期出现"适配 Volcano 1.12 节点就绪语义"与"适配新代际 npu- 小写设备名",说明昇腾插件同时承受上游调度框架升级与新一代 NPU 硬件命名两个方向的兼容压力,属产品化维护而非新特性。证据覆盖 node.go 节点过滤与两处 parser 前缀判断,未见 1.12 其他行为差异是否还有配套改动。
- **故障管理向精细化收口**:SubHealth 优先级、LogicID/Assertion 补全都指向"亚健康/UB 分离"这类超节点(a950 超平面)故障的上报精度提升,配合 UB fabric 方向,超节点级健康度是持续投入点。证据仅 fault_code.go 一处顺序调整与字段补全。

## vNPU: 8c58a454 -> 464c7358
- 比较: https://gitcode.com/openFuyao/vNPU/compare/8c58a454b89831edc3b1f51a22b24852c5e5f24f...464c7358071a6cc48f463c10fedf6b2d4519a5f3 | tag: v0.1.0 | commits=2 | truncated=false

### AI 总结重点(源码 diff 为据)

- **新增两个 Pod 注解,支持把 vNPU 精确绑定到指定 dieID 或指定 NPU 型号**。`util/type.go` 加 `VNPUUseDieIDAnnotation = "huawei.com/vnpu-use-npu-dieID"` 与 `VNPUUseNPUTypeAnnotation = "huawei.com/vnpu-use-npu-type"`;`parseContainerRequests` 从 `pod.Annotations` 读出这两个值写入每个容器的 `ContainerResource.ReqXPUDieID`/`ReqUseNPUType`。dieID 对应物理卡 die 唯一标识(取自 node 注解 `huawei.com/node-vnpu-register` 第 2 字段),NPU 型号形如 `NPU-ASCEND-310P3`(第 5 字段)。
  <details><summary>代码依据 volcano-xpu-plugin/util/type.go + task.go + plugin/vxpu.go</summary>

  ```diff
  +	VNPUUseDieIDAnnotation   = "huawei.com/vnpu-use-npu-dieID"
  +	VNPUUseNPUTypeAnnotation = "huawei.com/vnpu-use-npu-type"
  ```
  ```diff
   type TaskResource struct {
  +	ReqXPUDieID         string
  +	ReqUseNPUType       string
   }
  ```
  ```diff
  +	useDieID := pod.Annotations[util.VNPUUseDieIDAnnotation]
  +	useNPUType := pod.Annotations[util.VNPUUseNPUTypeAnnotation]
  ...
  +	cr.ReqXPUDieID = useDieID
  +	cr.ReqUseNPUType = useNPUType
  ```
  </details>

- **`IsDeviceQualified` 增加两道过滤门:请求 dieID/型号非空且与设备不匹配即淘汰**。在原有 policy/内存校验之外,若 `ReqXPUDieID != ""` 且设备 `DieID` 不等则返回 `false`;若 `ReqUseNPUType != ""` 且设备 `Type` 不等则返回 `false`。空值语义为"匹配任意"(测试用例 `dieID empty matches any` 验证)。这让用户能把 vNPU 精确落到某张物理卡或某种芯片型号——比如异构节点上强制只用 310P3 而非 910B。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/vxpu.go</summary>

  ```diff
  +	if len(val.ReqXPUDieID) != 0 && device.DieID != val.ReqXPUDieID {
  +		klog.V(util.LogDebugLevel).Infof(`... dieID not the same ...`)
  +		return false, 0
  +	}
  +	if len(val.ReqUseNPUType) != 0 && device.Type != val.ReqUseNPUType {
  +		klog.V(util.LogDebugLevel).Infof(`... npu type not the same ...`)
  +		return false, 0
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- **vNPU 调度从"按算力/内存配额"细化到"按物理拓扑/型号亲和"**:dieID 级绑定意味着可做 die 亲和(同 die 上多 vNPU 共享/隔离)与异构节点型号选择,是软切分从"能切"走向"切得可控/可复现"的一步。证据覆盖注解定义、请求解析、IsDeviceQualified 两道过滤及配套 test,未见 dieID 是否进一步参与 binpack/spread 设备级打分(仅做硬过滤,不匹配即淘汰)。
- **与 mind-cluster/npu-dra-plugin 软切分路线的关系待观察**:此处 vNPU(volcano-xpu-plugin)走 Volcano 注解路径做 dieID 过滤,而 DRA 路线用 ResourceSlice 属性;拓扑/型号选择在 DRA 侧通常由 device selector/CEL 表达,昇腾两条路线的选卡语义可能重复建设。证据仅本仓注解与过滤逻辑,未跨仓比对 DRA 侧是否已有等价能力。

## 本期无实质改动(折叠)
<details><summary>7 个 openFuyao 仓无新提交</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(98f8fa5e,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=f1816ec35614ca5e56a18acfdc680f78cecc480d tag=v26.1.0.beta.2 scanned=2026-07-10 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=v26.6.0 scanned=2026-07-10 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-10 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=v26.6.0 scanned=2026-07-10 -->
<!-- ANCHOR repo=vNPU sha=464c7358071a6cc48f463c10fedf6b2d4519a5f3 tag=v0.1.0 scanned=2026-07-10 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-10 -->
<!-- ANCHOR repo=npu-dra-plugin sha=98f8fa5e34726e82f6dee560e0d510750845ff49 tag=v26.6.0 scanned=2026-07-10 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-10 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-10 -->
</content>
</invoke>
