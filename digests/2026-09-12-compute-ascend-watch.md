# 昇腾算力栈 diff 雷达 2026-09-12

## 摘要(3 条内)
- mind-cluster 本期主线是**把 vNPU 模板/核数常量从 ascend-device-plugin 本地下沉到共享库 `ascend-common/devmanager/common`**:device-plugin 内 `constants.go` 删掉本地 86 行 `Core*`/`Vir*` 常量定义、改引 `npuCommon.Core1/Minus...`,`device.go` 的 `GetTemplateName2DeviceTypeMap()` 直接委托给 `common.GetTemplateName2DeviceTypeMap()`;配合区间内 "[ascend dynamic resource allocation] 支持静态 vNPU 设备发布与分配" 提交,是让 device-plugin 与 DRA 路径共用**同一份 vNPU 模板真源**的地基改造(证据只覆盖 device-plugin 侧的常量收敛,DRA 侧发布/分配逻辑未在本次信号文件出现)。
- 一处 controller bug 修复:`ascendjob_controller` 的 TTL 重排队原来用 `req.NamespacedName.String()` 当 key 去查 `ttlRequeues`,与写入时的 job key 不一致,导致 TTL 到期重排队可能查不到而失效;新增 `getAndCleanRequeueAfter` 改用 `common.KeyFunc(ascendjob)` 取正确 key。
- 一处调度默认值调整:ascend-for-volcano 打包的 `volcano-v1.15.0.yaml` 里 `super-pod-size` 默认从 **48 提到 128**,超节点(super-pod)拓扑亲和调度的单组规模翻倍以上。其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期均无新提交。

## 当日重要改变(命中信号才列)
- mind-cluster [新能力] vNPU 模板/核数常量下沉到共享库 `ascend-common/devmanager/common`,`GetTemplateName2DeviceTypeMap` 委托给 common,为"静态 vNPU 设备发布与分配"让 device-plugin 与 DRA 共用一份模板真源。证据:`component/ascend-device-plugin/pkg/common/constants.go`、`component/ascend-device-plugin/pkg/common/device.go`。https://gitcode.com/Ascend/mind-cluster/compare/72e2192ffdf90a6c3a33606e99c651b38fbf73cd...6166ecd736ec6771e5bb1e378943c2ccdd831df3
- mind-cluster [架构方向] Volcano 调度配置 `super-pod-size` 默认 48→128,超节点拓扑亲和单组规模翻倍。证据:`component/ascend-for-volcano/build/volcano-v1.15.0.yaml`。https://gitcode.com/Ascend/mind-cluster/compare/72e2192ffdf90a6c3a33606e99c651b38fbf73cd...6166ecd736ec6771e5bb1e378943c2ccdd831df3
- mind-cluster [修复] ascend-operator TTL 重排队用错 job key 导致 TTL 失效,改用 `common.KeyFunc`。证据:`component/ascend-operator/pkg/controllers/v1/ascendjob_controller.go`。https://gitcode.com/Ascend/mind-cluster/compare/72e2192ffdf90a6c3a33606e99c651b38fbf73cd...6166ecd736ec6771e5bb1e378943c2ccdd831df3

## mind-cluster: 72e2192f -> 6166ecd7
- 比较 / 最新 Release:72e2192f..6166ecd7 | tag: v26.2.0.beta.1 | commits=14 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/72e2192ffdf90a6c3a33606e99c651b38fbf73cd...6166ecd736ec6771e5bb1e378943c2ccdd831df3
### AI 总结重点(源码 diff 为据)
- **vNPU 模板/核数常量下沉到共享库,消除 device-plugin 与 DRA 的两份定义**:`constants.go` 新增 `import npuCommon "ascend-common/devmanager/common"`,把 `Ascend310Pc1`/`Ascend910vir2...vir16`/`Ascend910vir5Cpu1Gb8` 等所有虚拟规格常量的拼接从本地字面量 `api.Ascend910 + "-" + Core2` 改为 `api.Ascend910 + npuCommon.Minus + npuCommon.Core2`(即分隔符 `"-"` 和 `Core1/Core2/.../Core12Cpu3Gb32` 核数枚举全部改引共享库),同一文件另删掉 86 行本地常量块(`@@ -242,86 +243,6 @@` 起,原 "AiCoreResourceName" 段)。`device.go` 的 `GetTemplateName2DeviceTypeMap()` 从本地手写 18 项 `Vir16→Core16...` map 改为一行 `return common.GetTemplateName2DeviceTypeMap()`。行为等价但真源唯一化——配合区间内 "支持静态 vNPU 设备发布与分配" 提交,这是让 device-plugin 与新的 DRA 静态 vNPU 发布路径共用同一模板定义的前置重构。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/device.go</summary>

  ```diff
  -	return map[string]string{
  -		Vir16:        Core16,
  -		Vir08:        Core8,
  -		...
  -		Vir12C3G32:   Core12Cpu3Gb32,
  -	}
  +	return common.GetTemplateName2DeviceTypeMap()
  ```
  </details>
  <details><summary>代码依据 component/ascend-device-plugin/pkg/common/constants.go</summary>

  ```diff
  +	npuCommon "ascend-common/devmanager/common"
  ...
  -	Ascend910vir2 = api.Ascend910 + "-" + Core2
  +	Ascend910vir2 = api.Ascend910 + npuCommon.Minus + npuCommon.Core2
  ```
  </details>
- **设备名分隔符全面切到共享常量 `npuCommon.Minus`(替换本地 `common.MiddelLine`)**:device-plugin 的设备名解析/切分路径 `plugin.go`(`checkAllocateRequest`、`convertLogicIDToPhyID`、`checkAnnotationAllocateValid`、`getAICoreFromPodAnnotation`)、`device.go`(`GetDeviceID`)、`labelers.go`(`serverTypeLabeler.Write` 拼 cardType)、`ascend910.go`(`getPatchLabel`)、`ascendcommon.go`(`CheckDeviceTypeLabel`)全部把 `common.MiddelLine` 换成 `npuCommon.Minus`。纯常量来源统一,分隔符值不变(仍是 `"-"`),行为不变;意义是与上一条模板下沉配套,把"设备名格式"这套约定收敛到共享库一处。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/plugin.go</summary>

  ```diff
  -			if common.IsSupportSoftShareDevice() && strings.Count(deviceName, common.MiddelLine) > 1 {
  -				deviceNameSlice := strings.Split(deviceName, common.MiddelLine)
  -				deviceName = deviceNameSlice[0] + common.MiddelLine + deviceNameSlice[1]
  +			if common.IsSupportSoftShareDevice() && strings.Count(deviceName, npuCommon.Minus) > 1 {
  +				deviceNameSlice := strings.Split(deviceName, npuCommon.Minus)
  +				deviceName = deviceNameSlice[0] + npuCommon.Minus + deviceNameSlice[1]
  ```
  </details>
- **ascend-operator TTL 重排队 job key 修复**:`Reconcile` 尾部原来内联用 `req.NamespacedName.String()` 去 `ttlRequeues.LoadAndDelete`,现抽出 `getAndCleanRequeueAfter(ascendjob, req)`,先用 `common.KeyFunc(ascendjob)` 算出与写入侧一致的 `jobKey` 再查表。行为差异:此前若 TTL 写入用的是 KeyFunc 生成的 key、而读取用 NamespacedName 字符串,两者不一致会导致 TTL 到期的 AscendJob **查不到重排队时长而不触发延迟清理**;修复后 key 一致,TTL requeue 正常生效。
  <details><summary>代码依据 component/ascend-operator/pkg/controllers/v1/ascendjob_controller.go</summary>

  ```diff
  -	if value, ok := r.ttlRequeues.LoadAndDelete(req.NamespacedName.String()); ok {
  +	if requeueAfter := r.getAndCleanRequeueAfter(ascendjob, req); requeueAfter > 0 {
  +		return ctrl.Result{RequeueAfter: requeueAfter}, nil
  +	}
  +	return ctrl.Result{}, nil
  +}
  +func (r *ASJobReconciler) getAndCleanRequeueAfter(ascendjob *mindxdlv1.AscendJob, req ctrl.Request) time.Duration {
  +	jobKey, err := common.KeyFunc(ascendjob)
  +	...
  +	if value, ok := r.ttlRequeues.LoadAndDelete(jobKey); ok {
  ```
  </details>
- **Volcano 超节点规模默认值 super-pod-size 48→128**:ascend-for-volcano 打包的 `volcano-v1.15.0.yaml` 里 `init-params` 的 `super-pod-size` 从 `"48"` 改为 `"128"`,`reserve-nodes` 仍为 2。意味着昇腾 Volcano 调度的超节点(super-pod)拓扑亲和单组默认规模从 48 卡/节点级提到 128,匹配更大规模训练集群的超节点组网。
  <details><summary>代码依据 component/ascend-for-volcano/build/volcano-v1.15.0.yaml</summary>

  ```diff
  -    "useClusterInfoManager":"true","self-maintain-available-card":"true","super-pod-size": "48", "reserve-nodes": "2",
  +    "useClusterInfoManager":"true","self-maintain-available-card":"true","super-pod-size": "128", "reserve-nodes": "2",
  ```
  </details>
### 后续发展方向 [AI]
- 昇腾在为**静态 vNPU 设备发布与分配**做地基:先把 vNPU 模板(`Vir*`→`Core*`)与设备名格式常量收敛进 `ascend-common/devmanager/common`,让 device-plugin 与 DRA 两条路径共用一份定义,避免两处漂移——这通常是把某能力从 device-plugin 私有搬到可被 DRA/其他组件复用的前奏。证据只覆盖 device-plugin 侧的常量下沉与委托,尚未见 DRA 侧(`npu-dra-plugin`/mind-cluster 的 dra 组件)对应的发布/分配代码 hunk,静态 vNPU 的实际分配逻辑待后续 diff 确认。
- 调度侧 super-pod-size 翻倍到 128 指向更大超节点组网的支撑;证据仅一处配置默认值,未见 for-volcano 插件内相关算法改动。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:本期无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=6166ecd736ec6771e5bb1e378943c2ccdd831df3 tag=v26.2.0.beta.1 scanned=2026-09-12 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=vNPU sha=d88907ed4061c5d63babbb79b453a368b55f14d6 tag=v0.1.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=npu-dra-plugin sha=5d7339c517d971eaeb0b915bd19ed3d90db3c44c tag=v26.6.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-09-12 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-09-12 -->
