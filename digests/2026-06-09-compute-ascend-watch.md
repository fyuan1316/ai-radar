# 昇腾算力栈 diff 雷达 2026-06-09

## 摘要
- **mind-cluster**:ascend-device-plugin 把超节点类型字段 `superPodType` 及相关拓扑映射键从 `int8/uint8` 全量拓宽到 `int32/uint32`(对齐 dcmi 驱动接口头文件),DevManager 接口签名随之改变——为 A5 超节点(SuperPod)类型/规模突破 127 上限做准备;另适配 volcano v1.12.0、调整一个故障码恢复策略。
- **vNPU**:删除"aicore 算力必须是 5 的倍数"的切分约束(常量 `coresSplitMinSize=5` 连带删除),vGPU/vNPU 算力切分粒度从"步长 5"放开到任意整核数(上限仍为 100)。
- 其余 7 仓(npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)无新提交。

## 当日重要改变
- mind-cluster [架构方向/接口变更] 超节点类型字段 `superPodType` int8→int32 全栈拓宽,DevManager 的 `Set/GetSuperPodType` 接口签名同步变更,与 dcmi 驱动头文件对齐,放开超节点类型枚举上限。证据:component/ascend-device-plugin/pkg/device/ascendcommon.go、pkg/server/npu_base_v2.go;commit 2c141d42 https://gitcode.com/Ascend/mind-cluster/commit/2c141d42ca7b
- vNPU [弃用/移除→新能力] 删除 aicore 切分"必须 5 的倍数"约束与常量 `coresSplitMinSize`,切分粒度放开到任意整核。证据:volcano-xpu-plugin/plugin/vxpu.go、plugin/type.go;commit f35c7f7b https://gitcode.com/openFuyao/vNPU/commit/f35c7f7bea69
- mind-cluster [版本适配] 新增 volcano v1.12.0 原始部署 yaml(ascend-for-volcano 适配新版 volcano)。证据:component/ascend-for-volcano/build/volcano-v1.12.0.yaml(新增);commit c9f1b9fb https://gitcode.com/Ascend/mind-cluster/commit/c9f1b9fab4e4

## mind-cluster: a93469f8 -> 3c628f48
- 比较:a93469f8...3c628f48 | tag: v26.0.1 | commits=8 | truncated=false
- 比较链接:https://gitcode.com/Ascend/mind-cluster/compare/a93469f8f1ff26cb74366013f960c842aac3f6b6...3c628f4879d563d3f6405e492ec088fa0dab096e

### AI 总结重点(源码 diff 为据)
- **超节点类型 `superPodType` 从 8 位整型全量拓宽到 32 位**,贯穿 device-plugin 的数据结构、接口与拓扑映射。前:类型枚举值上限 127(int8)/255(uint8);后:扩到 int32/uint32。这意味着超节点(SuperPod)类型/型号枚举要超出原 8 位上限——配合 A5 超节点形态,枚举空间需要更大。改动同时改了 `DevManager` 接口的 `SetSuperPodType/GetSuperPodType` 签名(int8→int32),属对外接口契约变更。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  type AscendTools struct {
  	// superPodType for A5
  -	superPodType int8
  +	superPodType int32
  
  type DevManager interface {
  	// SetSuperPodType for A5
  -	SetSuperPodType(int8)
  +	SetSuperPodType(int32)
  	// GetSuperPodType for A5
  -	GetSuperPodType() int8
  +	GetSuperPodType() int32
  ```
  </details>
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/npu_base_v2.go</summary>

  ```diff
  -var hcclTopoFilePathMap = map[int8]string{
  +var hcclTopoFilePathMap = map[int32]string{
  
  type ProductBase struct {
  -	superPodType   uint8
  +	superPodType   uint32
  
  func (p *ProductBase) getTopoPath() (string, error) {
  -	path, exist := hcclTopoFilePathMap[int8(p.superPodType)]
  +	path, exist := hcclTopoFilePathMap[int32(p.superPodType)]
  ```
  </details>

- **超节点信息上报结构 `SuperPodInfo` 的 `Reserve` 字段与转换全部由 int8 改 int32**(manager.go),HCCL 拓扑文件路径映射(rack_topology.go 的 `topoFilePathMap`、`superPodType` 全局变量)同步拓宽,`PluginServer.getProductTypeKey` 返回值也从 int8 改 int32。即整条"卡型/超节点型号 → HCCL 拓扑文件"的查表链路统一升到 32 位。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/manager.go</summary>

  ```diff
  		SuperPodType: common.SuperPodTypeAbnormal,
  -		Reserve:      make([]int8, 0),
  +		Reserve:      make([]int32, 0),
  ...
  -		SuperPodType: int8(superPodInfo.SuperPodType),
  +		SuperPodType: int32(superPodInfo.SuperPodType),
  		for i := 0; i < len(superPodInfo.Reserve); i++ {
  -			result.Reserve = append(result.Reserve, int8(superPodInfo.Reserve[i]))
  +			result.Reserve = append(result.Reserve, int32(superPodInfo.Reserve[i]))
  ```
  </details>
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/plugin_v2.go</summary>

  ```diff
  -func (ps *PluginServer) getProductTypeKey(cardType string, allNPUInfo common.NpuAllInfo) int8 {
  +func (ps *PluginServer) getProductTypeKey(cardType string, allNPUInfo common.NpuAllInfo) int32 {
  ...
  -		return int8(superPodInfo.SuperPodType)
  +		return int32(superPodInfo.SuperPodType)
  ```
  </details>

- **故障码 `81B38004` 恢复策略级别调整**:从一组恢复码移到另一组(对应 commit "81B38004故障码恢复策略级别修改")。faultCode.json 里 `81B38004` 从前一个列表删除、追加到 `SeparateNPUCodes` 之前的列表(分离/隔离 NPU 前的那一组),即该故障的处置等级被改写。

  <details><summary>代码依据 component/ascend-device-plugin/build/faultCode.json</summary>

  ```diff
  -    "81618009","81718009","81078008","81B38004","81358005","813D8005",...
  +    "81618009","81718009","81078008","81358005","813D8005",...
  ...
  -    "8C4DA000","814D800A","81AE4E00","80F38000"
  +    "8C4DA000","814D800A","81AE4E00","80F38000","81B38004"
  ```
  </details>

- **新增 volcano v1.12.0 部署 yaml**(ascend-for-volcano/build/volcano-v1.12.0.yaml,9906 行新增),适配上游 volcano 1.12.0;补丁体未在节选内展开(为整份 yaml 部署清单)。

### 后续发展方向 [AI]
- int8→int32 的全栈拓宽是为**超节点(SuperPod)类型枚举突破 8 位上限**铺路——证据覆盖 device-plugin 的数据结构/接口/拓扑查表三层,但未见 dcmi 驱动侧头文件本体(diff 只在 mind-cluster 仓内),故"驱动头文件已先行扩位"是据 commit 标题推断、未直接看到驱动 diff。
- DevManager 接口签名变更属破坏性改动,下游若有自研 DevManager 实现需同步;证据仅覆盖接口定义与本仓实现,未覆盖外部消费方。

## vNPU: 1c407018 -> 8eb5e3c8
- 比较:1c407018...8eb5e3c8 | tag: v0.1.0 | commits=2 | truncated=false
- 比较链接:https://gitcode.com/openFuyao/vNPU/compare/1c407018907f5a41b9ffba929aa98453ca7798d3...8eb5e3c8e3f1a29f4f2e4c246fb3c00538b132af

### AI 总结重点(源码 diff 为据)
- **删除 aicore 算力切分"必须是 5 的倍数"的校验**:`EvaluateXPUDeviceAllocation` 里把 `ReqXPUCores > scoreWeight || ReqXPUCores%coresSplitMinSize != 0` 的拒绝条件改为只判 `ReqXPUCores > scoreWeight`,并删掉常量 `coresSplitMinSize = 5`。前:申请的 aicore 核数必须 ≤100 且为 5 的整数倍,否则报 invalid limit;后:只要 ≤100(scoreWeight)即可,任意整核数都放行。即 vNPU 算力切分粒度从"步长 5"细化到"步长 1"。

  <details><summary>代码依据 volcano-xpu-plugin/plugin/vxpu.go</summary>

  ```diff
  -		if containerResource.ReqXPUCores > scoreWeight || containerResource.ReqXPUCores%coresSplitMinSize != 0 {
  +		if containerResource.ReqXPUCores > scoreWeight {
  			errMsg := fmt.Sprintf("Container %s invalid %s limit: %d",
  				c.Name, sp.VxpuCore, containerResource.ReqXPUCores)
  ```
  </details>
  <details><summary>代码依据 volcano-xpu-plugin/plugin/type.go</summary>

  ```diff
  const (
  	scoreWeight              = 100
  	defaultSchedulingTaskNum = -1
  -	coresSplitMinSize        = 5
  )
  ```
  </details>

### 后续发展方向 [AI]
- 放开 5 倍数限制后,vNPU 可按单核粒度切分 aicore,资源利用率/装箱密度更高;但证据只覆盖调度插件的入口校验(EvaluateXPUDeviceAllocation),**未见底层 vCANN/驱动是否真支持任意核数切分**——若驱动仍按 5 对齐,这里只是放宽了上层校验,需结合 vCANN 侧确认。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=3c628f4879d563d3f6405e492ec088fa0dab096e tag=v26.0.1 scanned=2026-06-09 -->
<!-- ANCHOR repo=npu-operator sha=83270337c25487948cbf56685561e273730f9bbf tag=1.2.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=vNPU sha=8eb5e3c8e3f1a29f4f2e4c246fb3c00538b132af tag=v0.1.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=npu-dra-plugin sha=7731787412babb25bc775efd57240e0239a58db9 tag=1.0.1 scanned=2026-06-09 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=c7e00375aff3e56f84243abc48c6e348dcb0728b tag=1.0.1 scanned=2026-06-09 -->
</content>
</invoke>
