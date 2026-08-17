# 昇腾算力栈 diff 雷达 2026-08-18

## 摘要
- **mind-cluster**:clusterd 落地 **RankTable v2(rank_list)**,为 A5 超节点/UB fabric 引入按设备多层网络拓扑(LevelList)+ scale-out 网络类型(RoCE>UBoE>UBG)优选;同时把 HCCL ConfigMap 分片从"每 1000 设备一片"改为"按序列化字节数(800KB)分片";npu-exporter 新增 A5(910A5)与 UBx/Atlas35xxP 主板的 PCIe 指标采集。
- **npu-operator**:一个 fix 打通 `volcano.flavor` 在 **vnpu ↔ mindcluster 之间热切换**——引入 componentResourceRef 冲突规避,避免切换时误删对方仍在管的共享资源;CRD 里 `enableHardVNPU` 标记 **Deprecated**(hard-vNPU 改由 DRA profile/节点标签决定),VolcanoAdmissionSpec 新增 `initImageSpec` 字段。
- 其余 7 仓(npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期无新提交。

## 当日重要改变
- **npu-operator [API/CRD变更]** `enableHardVNPU` 字段被标注 Deprecated(hard-vNPU 由 DRA profile 配置或节点标签选择);VolcanoAdmissionSpec 新增 `initImageSpec`。证据:api/v1/npuclusterpolicy_types.go、config/crd/bases/npu.openfuyao.com_npuclusterpolicies.yaml。https://gitcode.com/openFuyao/npu-operator/commit/5c41aa83e7e810159f5a7be3c5327c3a350a54bd
- **npu-operator [架构方向]** 支持 volcano flavor 在 vnpu 与 mindcluster 间切换:reconcile 时跳过"仍被其它已管组件占用"的资源引用,避免切换误删。证据:internal/controller/components.go 新增 `activeManagedResourceRefs()`。https://gitcode.com/openFuyao/npu-operator/commit/5c41aa83e7e810159f5a7be3c5327c3a350a54bd
- **mind-cluster [新能力]** clusterd 新增 RankTable v2 / rank_list 生成(A5 超节点 UB fabric 多层网络拓扑)。证据:新增 component/clusterd/pkg/domain/pod/ranktable_v2.go、component/clusterd/pkg/common/constant/ranktable_v2.go。https://gitcode.com/Ascend/mind-cluster/commit/0035c85eb1fc47667187aad4ef1dbfc1c5328cf0
- **mind-cluster [架构方向]** HCCL ConfigMap 分片策略从"设备数/1000"改为"序列化字节数 800KB"。证据:component/clusterd/pkg/domain/job/job_util.go。https://gitcode.com/Ascend/mind-cluster/commit/0035c85eb1fc47667187aad4ef1dbfc1c5328cf0

## mind-cluster: 6fe79f06 -> 0035c85e
- 比较:6fe79f06..0035c85e | tag: v26.1.0 | commits=12 | truncated=false
- 比较页:https://gitcode.com/Ascend/mind-cluster/compare/6fe79f061b6383290148f1119e98e97142b2f3cf...0035c85eb1fc47667187aad4ef1dbfc1c5328cf0

### AI 总结重点(源码 diff 为据)
- **RankTable 数据结构升级为 v2**:`constant.RankTable` 追加 `Version`、`RankList []Rank`、`RankCount` 三个 omitempty 字段;新增 `Rank` 结构(RankID/LocalID/DeviceID + `LevelList []api.LevelElement`),`Device` 追加 `LevelList []api.RankLevel`(camelCase `levelList`,由 device-plugin 写入 pod annotation)。即 v1 的 `server_list` 之外并行输出 `rank_list`,承载每卡多层网络地址。

  <details><summary>代码依据 component/clusterd/pkg/common/constant/type.go</summary>

  ```diff
   type RankTable struct {
   	ServerList  []ServerHccl `json:"server_list"`
   	ServerCount string       `json:"server_count"`
   	Total       int          `json:"total"`
  +	Version     string       `json:"version,omitempty"`
  +	RankList    []Rank       `json:"rank_list,omitempty"`
  +	RankCount   int          `json:"rank_count,omitempty"`
  +}
  +
  +type Rank struct {
  +	RankID    int                `json:"rank_id"`
  +	LocalID   int                `json:"local_id"`
  +	DeviceID  int                `json:"device_id"`
  +	LevelList []api.LevelElement `json:"level_list,omitempty"`
  +	Device    Device             `json:"-"`
   }
  ...
   type Device struct {
  +	// LevelList is the raw per-device multi-layer network data parsed from the pod device
  +	// annotation (camelCase "levelList", written by device-plugin) ... feeds v2 rank_list
  +	LevelList []api.RankLevel `json:"levelList,omitempty"`
   }
  ```
  </details>

- **v2 rank_list 只对 NPU 类任务生成,按 scale-out 网络类型优选**:`UpdateCmAndCache` 在 `ResourceType == api.NPULowerCase` 时读取 podGroup 的 `scaleout-type` 标签(转大写)调用 `ConstructRankListV2`;新增 constant/ranktable_v2.go 定义 RoCE/UBoE/UBG 三种 PortAddrType 到 NetInfo(PortAddrType/ScaleOutType/RankAddrType,IP or EID)的映射,`GetNetInfoByDefault` 默认优先级 RoCE>UBoE>UBG,`GetNetInfoByCustom` 按用户标签选(非法值报错)。level2 只保留 UBoE/UBG、level3 只保留 RoCE(`shouldInclude`)。

  <details><summary>代码依据 component/clusterd/pkg/domain/job/job_util.go + constant/ranktable_v2.go</summary>

  ```diff
  +	if jobInfo.ResourceType == api.NPULowerCase {
  +		customScaleOutType := strings.ToUpper(strings.TrimSpace(podGroup.Labels[constant.ScaleOutTypeLabel]))
  +		pod.ConstructRankListV2(&jobInfo.JobRankTable, podsInJob, jobInfo.Replicas, customScaleOutType)
  +	}
  ```

  ```go
  var defaultPriorityScaleOutType = []string{PortAddrTypeRoCE, PortAddrTypeUBoE, PortAddrTypeUBG}
  var portTypeMappings = map[string]NetInfo{
  	PortAddrTypeRoCE: {PortAddrTypeRoCE, ScaleOutTypeRoCE, RankAddrTypeIP},
  	PortAddrTypeUBoE: {PortAddrTypeUBoE, ScaleOutTypeUBoE, RankAddrTypeIP},
  	PortAddrTypeUBG:  {PortAddrTypeUBG, ScaleOutTypeUBoE, RankAddrTypeEID},
  }
  ```
  </details>

- **HCCL ConfigMap 分片:从"设备数固定切"改为"按字节大小切"**:删除 `safeDeviceSize=1000` 常量,新增 `maxHcclSliceSize = 800*1024`;`TotalCmNum` 不再用 `(Replicas-1)/1000+1` 预估,而是先 `getHcclSlice` 出实际分片数再回填(`len(hccls)`,兜底 1)。新增 `getHcclSliceBySize`/`computeRankEnd`/`marshalHcclPart`:按 ServerList 子区间且 RankList 对齐地序列化每个 ≤800KB 的子表。

  <details><summary>代码依据 component/clusterd/pkg/domain/job/job_util.go</summary>

  ```diff
  -	safeDeviceSize   = 1000
  +	maxHcclSliceSize = 800 * 1024
  ...
  -	jobInfo.TotalCmNum = (jobInfo.Replicas-1)/safeDeviceSize + 1
  +	jobInfo.TotalCmNum = 1
  ...
  -	jobInfo.JobRankTable.Total = jobInfo.TotalCmNum
   	hccls := getHcclSlice(jobInfo.JobRankTable)
  +	jobInfo.TotalCmNum = len(hccls)
  +	if jobInfo.TotalCmNum == 0 { jobInfo.TotalCmNum = 1 }
  +	jobInfo.JobRankTable.Total = jobInfo.TotalCmNum
  ...
  +func computeRankEnd(table constant.RankTable, serverBegin, serverEnd, rankBegin int) int { ... }
  +func marshalHcclPart(table constant.RankTable, serverBegin, serverEnd, rankBegin int) (string, error) { ... }
  ```
  </details>

- **util 新增有序区间版二分**:`BinarySearchMaxFit(length, maxSize, sizeOfPrefix)` 返回最大 k 使前缀序列化 ≤maxSize,是原 map 版 `binarySearchMaxFit` 的有序泛化,服务上面的字节分片。

  <details><summary>代码依据 component/clusterd/pkg/common/util/util.go</summary>

  ```diff
  +func BinarySearchMaxFit(length, maxSize int, sizeOfPrefix func(k int) int) int {
  +	low, high := 1, length
  +	for low <= high {
  +		mid := (low + high) / 2
  +		if sizeOfPrefix(mid) <= maxSize { low = mid + 1 } else { high = mid - 1 }
  +	}
  +	return high
  +}
  ```
  </details>

- **npu-exporter:PCIe 采集扩到 A5 与 UBx/Atlas35xxP**:`supportedPcieDevices` 加入 `Ascend910A5`;新增 `supportedPcieA5MainBoards`(Atlas3501P/3502P/3504P/Ubx 主板 ID)。`IsSupported` 对 A5 额外校验 `GetMainBoardId()` 是否在白名单,否则记 unsupported。原先仅 910A2/910B 支持。

  <details><summary>代码依据 component/npu-exporter/collector/metrics/collector_for_pcie.go</summary>

  ```diff
   	supportedPcieDevices = map[string]bool{
  -		api.Ascend910B: true,
  +		api.Ascend910B:  true,
  +		api.Ascend910A5: true,
  +	}
  +	supportedPcieA5MainBoards = map[uint32]bool{
  +		api.Atlas3501PMainBoardID: true, api.Atlas3502PMainBoardID: true,
  +		api.Atlas3504PMainBoardID: true, api.UbxMainBoardID: true,
   	}
  +	if devType == api.Ascend910A5 {
  +		if !supportedPcieA5MainBoards[n.Dmgr.GetMainBoardId()] { ...return false }
  +	}
  ```
  </details>

- **infer-operator:清理多余 Service 时按命名空间过滤(修跨 ns 同名异常)**:`deleteExtraService` 新增 `namespace` 形参,List 时加 `client.InNamespace(namespace)`;对应"多服务场景下同名 ns 相关异常"修复,避免跨命名空间误删同标签 Service。

  <details><summary>代码依据 component/infer-operator/pkg/controller/workload/statefulset_handler.go</summary>

  ```diff
  -	return s.deleteExtraService(ctx, selectLabels, indexLimit)
  +	return s.deleteExtraService(ctx, selectLabels, indexer.Namespace, indexLimit)
  ...
  -	if err = s.client.List(ctx, serviceList, client.MatchingLabelsSelector{Selector: selector}); err != nil {
  +	if err = s.client.List(ctx, serviceList,
  +		client.MatchingLabelsSelector{Selector: selector}, client.InNamespace(namespace)); err != nil {
  ```
  </details>

### 后续发展方向 [AI]
- RankTable v2 + LevelList + scale-out 网络优选,是昇腾往 **A5 超节点/UB(UnifiedBus)大规模组网**铺路:rank 编排开始区分 RoCE/UBoE/UBG 与 IP/EID 寻址,HCCL 拓扑不再只按 server 平铺而是带多层网络级别。证据只覆盖 clusterd 的 v2 生成与常量映射,未见 device-plugin 侧 `levelList` 写入的具体格式与 ConstructRankListV2 的完整体(hunk 截断)。
- HCCL 分片改字节驱动,说明目标规模已大到单 ConfigMap(1MB etcd 上限)装不下整表,需按 800KB 切多片——这是万卡级 rank table 的工程约束信号。证据止于分片函数签名,未见跨 ConfigMap 的消费端(训练框架/agent)如何拼回。

## npu-operator: bae95f0b -> 5c41aa83
- 比较:bae95f0b..5c41aa83 | tag: v26.6.0 | commits=2 | truncated=false
- 比较页:https://gitcode.com/openFuyao/npu-operator/compare/bae95f0b9eaa2c5727b951694c45e6206a755d63...5c41aa83e7e810159f5a7be3c5327c3a350a54bd
- PR:!114 fix: support vnpu and mindcluster volcano switching

### AI 总结重点(源码 diff 为据)
- **支持 volcano flavor 在 vnpu↔mindcluster 热切换,不误删共享资源**:reconcile 时先算出所有"仍被已管组件占用"的资源引用 `activeManagedResourceRefs()`;对某个非托管(isManaged=false)组件的资源,若其 ref 命中该集合则 `continue` 跳过(不删)。配套 `resolveComponentPaths` 里两种 flavor 的组件路径都补齐了对方 vccontroller/vcscheduler/vnpu 三件套,使切换后新旧组件可共存过渡。

  <details><summary>代码依据 internal/controller/components.go</summary>

  ```diff
  +	activeResourceRefs, err := r.activeManagedResourceRefs()
  +	if err != nil { return currentState, err }
   	for _, resource := range resources {
  +		if !isManaged && activeResourceRefs[resource.ref(r.namespace)] { continue }
   		state, err := resource.clone().reconcile(ctx, r, isManaged)
  ...
  +func (r *NPUClusterPolicyReconciler) activeManagedResourceRefs() (map[componentResourceRef]bool, error) {
  +	for i := range r.components {
  +		if !isComponentManaged[component.name](r) { continue }
  +		... refs[resource.ref(r.namespace)] = true
  ```
  </details>

- **`enableHardVNPU` 标记 Deprecated**:CRD 描述改为"hard-vNPU mode is selected by DRA profile config or node labels",即 hard-vNPU 的开关权从 CR 顶层布尔迁移到 DRA profile / 节点标签(延续上期"hard-vNPU 去全局开关"路线)。

  <details><summary>代码依据 config/crd/bases/npu.openfuyao.com_npuclusterpolicies.yaml</summary>

  ```diff
                     enableHardVNPU:
  -                    description: Whether hard-vNPU is enabled
  +                    description: 'Deprecated: hard-vNPU mode is selected by DRA profile
  +                      config or node labels.'
  ```
  </details>

- **VolcanoAdmissionSpec 新增 initImageSpec;vNPU flavor 下 init 容器用 busybox**:api 追加 `InitImage ImageSpec`;getter `volcanoAdmissionInitImageConfig` 在 flavor=vnpu 且用户未覆盖时,用环境变量 `NPU_OPERATOR_BUSYBOX_IMAGE_*`(默认 `hub.oepkgs.net/openfuyao/busybox:1.36.1`,PullPolicy=Always)渲染 init 镜像。

  <details><summary>代码依据 api/v1/npuclusterpolicy_types.go + internal/controller/resources_getters.go</summary>

  ```diff
   	Image ImageSpec `json:"imageSpec,omitempty"`
  +	// Init image configuration
  +	InitImage ImageSpec `json:"initImageSpec,omitempty"`
  ...
  +	return &v1.ImageSpec{
  +		Repository:      stringEnvOrDefault(operatorBusyboxImageRepositoryEnvName, defaultBusyboxImageRepository),
  +		Tag:             stringEnvOrDefault(operatorBusyboxImageTagEnvName, defaultBusyboxImageTag),
  +		ImagePullPolicy: stringEnvOrDefault(operatorBusyboxImagePullPolicyEnvName, defaultBusyboxImagePullPolicy),
  +	}
  ```
  </details>

- **镜像覆盖改为显式开关,切 flavor 时用 assets 默认**:values.yaml 去掉 vnpu 系列镜像硬编码 `tag: latest`,新增 `imageOverrideEnabled`/`initImageOverrideEnabled`(默认 false);模板据此决定是否渲染 imageSpec/initImageSpec——CR 只存用户显式覆盖,切换 flavor 时不被旧 tag 污染。

  <details><summary>代码依据 charts/npu-operator/values.yaml + templates/npuclusterpolicy.yaml</summary>

  ```diff
     vnpuVccontroller:
       repository: cr.openfuyao.cn/openfuyao/vnpu/vc-controller-manager
  -    tag: latest
  ...
   vccontroller:
  +  imageOverrideEnabled: false
  +  initImageOverrideEnabled: false
  ```
  </details>

### 后续发展方向 [AI]
- 这次是把 vNPU 与 mindcluster 两套 volcano 栈做成**可在同一 operator 内切换/共存**的产品化收口:资源引用去冲突 + 镜像覆盖显式化 + init 镜像分 flavor,是为"同一集群从 mindcluster 调度平滑迁到 vNPU 软切分"减少停机。证据覆盖切换的删除保护与镜像渲染,未见切换过程中调度器/webhook 的滚动顺序与数据面中断窗口(需看 deployment 滚动策略,本 diff 未含)。
- `enableHardVNPU` 弃用坐实 hard-vNPU 归 DRA:昇腾虚拟化正把静态切分能力往 **DRA profile/节点标签**下沉,CR 顶层开关退场。对我们产品的启示:对标时 vNPU 的"硬切分"配置面要按 DRA ResourceSlice/DeviceClass 建模,而非 operator CR 布尔位。

## 本期无实质改动(折叠)
- npu-container-toolkit:无新提交(锚点 c1be1ea2 未动)。
- npu-driver-installer:无新提交(锚点 bd1b2a9e 未动)。
- vNPU:无新提交(锚点 f5869cd1 未动)。
- npu-node-provision:无新提交(锚点 717ef777 未动)。
- npu-dra-plugin:无新提交(锚点 90c70b32 未动)。
- volcano-ext:无新提交(锚点 c9be5c4c 未动)。
- ub-network-device-plugin:无新提交(锚点 263d6387 未动)。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=0035c85eb1fc47667187aad4ef1dbfc1c5328cf0 tag=v26.1.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=npu-dra-plugin sha=90c70b32b9b368efc2cc26bda1209e4f275a804c tag=v26.6.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-18 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-18 -->
