# 昇腾算力栈 diff 雷达 2026-06-10

## 摘要(≤3 条)
- **mind-cluster 整栈删除 DPU 支持**:device-plugin / clusterd / ascend-for-volcano 三组件成片删除 DPU 发现、健康上报、ConfigMap 同步代码(commit "【Device-plugin】【Volcano】【clusterd】删除DPU相关代码"),`UpdateNodeDeviceInfo`/`writeDeviceInfoCm` 去掉 `dpuInfo` 入参、NpuDevice 去掉 `DpuHealth` 字段、RoCE 地址兜底从"读 DPU info"改为直接返回空表——A5(910A5)组网从 DPU 路径收敛到 NIC-mapping/RoCE 直连。
- **适配 Volcano v1.12.0**:`build.sh` 默认版本 v1.7.0→v1.12.0、DEFAULT_VER v6.0.0→v26.1.0,新增 `replace_node_predicate`(predicate 签名改为返回 `[]*api.Status`)、`replace_node_score`、`replace_klog_version`(klog→klog/v2)三个上游补丁函数;删除旧的 `build_1.10plus.sh`。
- **npu-exporter:A5 纳入新利用率接口**,`collectUtilV2` 改名 `collectUtilCommon` 并改调 `GetDeviceUtilizationRateCommon`(1s 利用率接口),去掉 PreCollect 里 v2/v1 探测重试逻辑,910A5 直接走新 API。openFuyao 8 仓本期均无新提交。

## 当日重要改变
- mind-cluster [弃用/移除] DPU 全栈下线:device-plugin 删 `pkg/server/dpu.go`、`pkg/device/dpucontrol/{dpu_device_find,types}.go`、`pkg/common/proto_v2.go`,clusterd 删 `pkg/domain/dpu/dpu_util.go`,ascend-for-volcano 删 `internal/rescheduling/dpu.go`、`internal/npu/policy/chip8node8ra64sp/dpu.go`。证据见下。 https://gitcode.com/Ascend/mind-cluster/compare/3c628f48...3c7cf49f
- mind-cluster [架构方向] 调度组件适配 Volcano v1.12.0(`component/ascend-for-volcano/build/build.sh` + 新增 `volcano-v1.12.0.yaml`),predicate 接口签名随上游变更。 https://gitcode.com/Ascend/mind-cluster/compare/3c628f48...3c7cf49f
- mind-cluster [新能力] npu-exporter 把 Ascend910A5 接入 `dcmi_get_device_multi_utilization_rate` 系新利用率接口(`GetDeviceUtilizationRateCommon`)。 https://gitcode.com/Ascend/mind-cluster/compare/3c628f48...3c7cf49f

## mind-cluster: 3c628f48 -> 3c7cf49f
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/3c628f48...3c7cf49f | tag: v26.0.1 | commits=16 | truncated=false
- 限定 PATHPREFIX:component/{ascend-device-plugin,ascend-docker-runtime,ascend-for-volcano,ascend-operator,npu-exporter,noded,clusterd,infer-operator}

### AI 总结重点(源码 diff 为据)
- **DPU 发现/上报链路整体移除**。`AscendTools` 结构体删掉 `lastDpuInfo` 字段,`DevManager` 接口删掉 `SetDpu(string, []common.DpuCMData, map[string][]string)` 方法;`UpdateNodeDeviceInfo`、`writeDeviceInfoCm`、`updateLastInfo` 三个函数签名统一去掉 `dpuInfo common.DpuInfo` 参数,设备信息变更比对里 `DeepEqualDpuInfo(...)` 项被删除。即设备状态 ConfigMap 不再携带 DPU 维度。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  -	lastDpuInfo               common.DpuInfo
  ...
  -	SetDpu(string, []common.DpuCMData, map[string][]string)
  ...
  -func (tool *AscendTools) UpdateNodeDeviceInfo(devStatusSet common.DevStatusSet, dpuInfo common.DpuInfo,
  +func (tool *AscendTools) UpdateNodeDeviceInfo(devStatusSet common.DevStatusSet,
  		updateDeviceInfoFunc func(map[string]string, map[string]string, common.DevStatusSet) error) error {
  ...
  		dataSame := compareDeviceList(deviceList, newDeviceList) &&
  			... &&
  -			reasonCache.Equals(tool.lastUpgradeFaultReason) &&
  -			common.DeepEqualDpuInfo(dpuInfo, tool.lastDpuInfo)
  +			reasonCache.Equals(tool.lastUpgradeFaultReason)
  ```
  </details>

- **NPU 设备健康去掉 DPU 子健康维度**。`assembleNpuDeviceStruct` 不再设 `DpuHealth: v1beta1.Healthy`;`getDevStatesDevSet`/`groupDevsByStatus` 删除 `totalDpuUHDevices` 聚合及 `DevStatusSet.DpuUnHealthyDevice` 字段填充;删除 `getDpuFaults`,910A5 不再因 `DpuSubHealthy` 注入 DPU 故障事件(`DpuSubHealthCode`)。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  -		DpuHealth:     v1beta1.Healthy,
  ...
  -		if tool.dmgr.GetDevType() == api.Ascend910A5 && device.DpuHealth == api.DpuSubHealthy {
  -			devicesFaults = append(devicesFaults, tool.getDpuFaults(device.DeviceName)...)
  -		}
  ...
  -		if device.DpuHealth == v1beta1.Unhealthy {
  -			totalDpuUHDevices.Insert(device.DeviceName)
  -		}
  ```
  </details>

- **A5 rank table RoCE 地址不再用 DPU 兜底**。`getLevelList` 取 `productInfo.maxNpuCount` 并透传给 `getRankAddrList`/`getROCEAddrList`(新增 `maxNpuNum` 参数),`npuId` 计算从写死的 `dev.PhyID % common.NpuNum` 改为 `% int32(maxNpuNum)`;NIC-mapping 缺失时旧逻辑走 `getROCEAddrListLegacy`(读 DPU 对应信息),现直接返回空 `[]api.RankAddrItem{}`,`getROCEAddrListLegacy` 整体删除。这是 DPU 移除在组网地址表上的落点。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager_v2.go</summary>

  ```diff
  -		rankAddrList := hdm.getRankAddrList(level, dev)
  +		rankAddrList := hdm.getRankAddrList(level, dev, maxNpuCount)
  ...
  -	npuId := int(dev.PhyID % common.NpuNum)
  +	npuId := int(dev.PhyID % int32(maxNpuNum))
  	nicNames, err := getNpuToNicNames(npuId)
  	if err != nil {
  -		... using legacy dpu info", npuId, err)
  -		return hdm.getROCEAddrListLegacy(dev)
  +		... returning empty addr list", npuId, err)
  +		return []api.RankAddrItem{}
  	}
  ```
  </details>

- **Volcano v1.12.0 适配补丁**。`ascend-for-volcano/build/build.sh` 默认 `BASE_VER` v1.7.0→v1.12.0、`DEFAULT_VER` v6.0.0→v26.1.0;新增三个对上游源码打补丁的函数:`replace_klog_version`(全量 `k8s.io/klog`→`k8s.io/klog/v2`)、`replace_node_predicate`(把 `NodePredicate(... api.NodeInfo) error` 改为返回 `([]*api.Status, error)`,匹配 v1.12 调度框架)、`replace_node_score`(按版本改 allocate.go 候选节点打分分支)。旧专用脚本 `build_1.10plus.sh`、`volcano-v1.12.0.yaml` 内 admission 模板段被删。

  <details><summary>代码依据 component/ascend-for-volcano/build/build.sh</summary>

  ```diff
  -    BASE_VER=v1.7.0
  +    BASE_VER=v1.12.0
  ...
  -DEFAULT_VER='v6.0.0'
  +DEFAULT_VER='v26.1.0'
  ...
  +function replace_node_predicate() {
  +    REPLACE_FILE=".../ascend-volcano-plugin/npu.go"
  +    sed -i "s/api.NodeInfo) error {/api.NodeInfo) (\[\]\*api.Status, error) {/g" "$REPLACE_FILE"
  +    sed -i "s/return predicateErr/return \[\]\*api.Status{}, predicateErr/g" "$REPLACE_FILE"
  +}
  ```
  </details>

- **npu-exporter:910A5 接入新利用率接口 + 简化探测**。`BaseInfoCollector.PreCollect` 原先对 chip 做 3 次重试探测 v2/v1 API 再决定回调;现 A2/A3/A5(`Ascend910B`/`Ascend910A3`/`Ascend910A5`)统一直接用 `collectUtilCommon`,其余走 `collectUtilV1`。`collectUtilV2`(调 `GetDeviceUtilizationRateV2`)改名 `collectUtilCommon` 并改调 `GetDeviceUtilizationRateCommon`(对应"1s 利用率接口")。

  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_npu.go</summary>

  ```diff
  -	if n.Dmgr.GetDevType() != common.Ascend910B && n.Dmgr.GetDevType() != common.Ascend910A3 {
  +	if n.Dmgr.GetDevType() != common.Ascend910B &&
  +		n.Dmgr.GetDevType() != common.Ascend910A3 &&
  +		n.Dmgr.GetDevType() != common.Ascend910A5 {
  		... use v1 api ...
  		return
  	}
  -	... 3 次重试探测 v2/v1 的整段逻辑删除 ...
  +	c.realGetDeviceUtilizationRateInfoFunc = collectUtilCommon
  ...
  -func collectUtilV2(logicID int32, dmgr devmanager.DeviceInterface, chip *chipCache) {
  -	multiUtilInfo, err := dmgr.GetDeviceUtilizationRateV2(logicID)
  +func collectUtilCommon(logicID int32, dmgr devmanager.DeviceInterface, chip *chipCache) {
  +	multiUtilInfo, err := dmgr.GetDeviceUtilizationRateCommon(logicID)
  ```
  </details>

### 后续发展方向 [AI]
- DPU 路径下线是本期最强信号:910A5 的多机组网从"NPU↔DPU 配对查表"彻底转向 NIC-mapping/RoCE 直连(NIC-mapping 缺失即返回空表,不再有 DPU 兜底)。证据覆盖 device-plugin 的设备健康/rank table 与 clusterd 的 ConfigMap 解析、ascend-for-volcano 的重调度策略三处删除;未见替代的 NIC-mapping 配置下发链路改动(本区间无新增对应文件),仅见兜底被砍。
- 调度侧绑定 Volcano v1.12.0:predicate 返回值带 `[]*api.Status`、klog v2,说明昇腾插件跟随 Volcano 调度框架接口升级;证据仅在 build 脚本的 sed 补丁层,未见插件 Go 源码本身入仓(仍以"打补丁到上游 volcano 源码树"方式构建)。
- npu-exporter 去掉运行时 API 探测、按芯片型号静态分流,降低采集启动开销并把 A5 纳入秒级利用率;证据只覆盖 BaseInfoCollector 分流逻辑,未见 `GetDeviceUtilizationRateCommon` 在 devmanager 层的实现 diff(可能在 ascend-common 子模块,本区间未命中)。

## 本期无实质改动(折叠)
<details><summary>openFuyao 8 仓本期无新提交</summary>

- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:均 `无新提交`。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=3c7cf49f6035d42355c3a6e803cc1b0509d6b8fd tag=v26.0.1 scanned=2026-06-10 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=vNPU sha=8eb5e3c8e3f1a29f4f2e4c246fb3c00538b132af tag=v0.1.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-10 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-10 -->
