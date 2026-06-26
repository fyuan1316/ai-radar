# 昇腾算力栈 diff 雷达 2026-06-27

## 摘要
- **infer-operator 给 gang 调度的 PodGroup 补上 `MinResources`**:从只声明 `MinMember`(副本数)升级为同时声明聚合资源量,Volcano 据此做"资源足额才整组准入",对接昇腾推理负载的真实门控。
- **ascend-for-volcano 删掉调度插件里手工维护 `Idle` 的那段代码**,改回完全交给 Volcano 框架记账——修"抢占时 pod 反复拉起抖动 + vNPU 动态算力切分冒烟用例失败"(此前手工增减 + 钳位造成与框架双重记账)。
- ascend-device-plugin:把 Atlas950/9501D(A5)从"带 UBoE 口"的主板集合里剔除(A5 无 UBoE 口),faultCode 全量大写归一 + rdma dpu ub port 故障级别下调。其余 8 个 openFuyao 仓全 EMPTY。

## 当日重要改变
- mind-cluster `[新能力]` infer-operator 的 PodGroup 创建路径新增 `MinResources` 维度,gang 调度从"够数"升级到"够量"。证据 `component/infer-operator/pkg/controller/workload/workload_reconciler.go`、新增 `pkg/common/utils/resource.go`。https://gitcode.com/Ascend/mind-cluster/commit/37905df6593785dad11df642a639c28d8406a5ed
- mind-cluster `[架构方向]` ascend-for-volcano 撤掉调度插件对 `vcNode.Idle` 的手工增减/钳位,回归框架单点记账以消除抢占抖动。证据 `component/ascend-for-volcano/plugin/task.go`。

## mind-cluster: 88b0fddd -> 37905df6
- 比较 / 最新 Release:`88b0fddd..37905df6` | tag: v26.0.1 | commits=22 | truncated=false
- 比较页:https://gitcode.com/Ascend/mind-cluster/compare/88b0fddd758e171dfa61c4ebecc3109621ca0bd0...37905df6593785dad11df642a639c28d8406a5ed

### AI 总结重点(源码 diff 为据)

- **infer-operator:PodGroup 现在带聚合资源量,gang 准入从 MinMember 升级到 MinMember+MinResources**。`newPodGroupSpec` 签名由 `(workloadReplicas int32)` 改为 `(minMember int32, minResources *corev1.ResourceList)`,返回的 `PodGroupSpec` 多填 `MinResources` 字段;`Reconcile` 在拿到 replicas 后多调一次 `workloadHandler.GetMinResources(...)` 把结果传进去。意味着 Volcano 不再只看"凑齐 N 个 pod",而是要求集群同时具备整组的累计资源请求才整组放行。

  <details><summary>代码依据 component/infer-operator/pkg/controller/workload/workload_reconciler.go</summary>

  ```diff
  +		minResources, err := workloadHandler.GetMinResources(instanceSet.Spec.InstanceSpec)
  +		if err != nil {
  +			hwlog.RunLog.Errorf("Failed to get min resources: %v", err)
  +			return err
  +		}
  -		podGroupSpec := newPodGroupSpec(workloadReplicas)
  +		podGroupSpec := newPodGroupSpec(workloadReplicas, minResources)
  	...
  -func newPodGroupSpec(workloadReplicas int32) v1beta1.PodGroupSpec {
  +func newPodGroupSpec(minMember int32, minResources *corev1.ResourceList) v1beta1.PodGroupSpec {
  	return v1beta1.PodGroupSpec{
  -		MinMember: workloadReplicas,
  +		MinMember:    minMember,
  +		MinResources: minResources,
  	}
  }
  ```
  </details>

- **新增资源累加工具 `CalcMinResources` / `AddResourceList`(pkg/common/utils/resource.go,新文件)**:按 pod 模板把每个容器的 `Requests` 求和,缺 `Requests` 的资源回退用 `Limits`(遵循 K8s 约定),再乘以副本数;`replicas<=0` 或无任何资源请求时返回 `nil`,让调用方把 `MinResources` 留空。`WorkLoadHandler` 接口同步新增 `GetMinResources(spec) (*corev1.ResourceList, error)`,Deployment/StatefulSet 两个 handler 各自实现(解析自己的 pod 模板 + 副本数)。

  <details><summary>代码依据 component/infer-operator/pkg/common/utils/resource.go(新增)</summary>

  ```diff
  +func CalcMinResources(replicas int32, podSpec v1.PodSpec) *v1.ResourceList {
  +	if replicas <= 0 {
  +		return nil
  +	}
  +	singlePodRes := v1.ResourceList{}
  +	for _, container := range podSpec.Containers {
  +		AddResourceList(singlePodRes, container.Resources.Requests, container.Resources.Limits)
  +	}
  +	if len(singlePodRes) == 0 {
  +		return nil
  +	}
  +	minResources := v1.ResourceList{}
  +	for name, quantity := range singlePodRes {
  +		total := quantity
  +		for i := int32(1); i < replicas; i++ { total.Add(quantity) }
  +		minResources[name] = total
  +	}
  +	return &minResources
  +}
  ```
  </details>

- **ascend-for-volcano:删除调度插件对 `vcNode.Idle` 的手工增减 + 钳位**。`updateChipCountAfterAllocate` 原本会 `Idle[npuResName] -= chips*NPUHexKilo` 并钳到 0,`updateChipCountAfterDeallocate` 原本 `+= chips*NPUHexKilo` 并钳到 Allocatable——这两段全删,函数退化为只保证 `Idle` map 非 nil。配合提交标题"解决抢占时 pod 反复拉起抖动 + vNPU 动态算力切分冒烟用例失败",判断是此前手工记账与 Volcano 框架自身的 Idle 记账重复扣减/回补,抢占场景下数值来回跳导致 pod 反复被调度/驱逐;删手工记账让框架单点维护 Idle。

  <details><summary>代码依据 component/ascend-for-volcano/plugin/task.go</summary>

  ```diff
   	if vcNode.Idle == nil {
   		vcNode.Idle = make(map[v1.ResourceName]float64)
   	}
  -	vcNode.Idle[npuResName] -= float64(len(chipIDs)) * util.NPUHexKilo
  -	if vcNode.Idle[npuResName] < 0 {
  -		klog...Infof("...Idle[%s] went negative ... clamping to 0", ...)
  -		vcNode.Idle[npuResName] = 0
  -	}
   	...
  -	vcNode.Idle[npuResName] += float64(len(chipIDs)) * util.NPUHexKilo
  -	allocatable := vcNode.Allocate[npuResName]
  -	if vcNode.Idle[npuResName] > allocatable {
  -		klog...Infof("...Idle[%s] exceeded Allocatable ... clamping to Allocatable", ...)
  -		vcNode.Idle[npuResName] = allocatable
  -	}
  ```
  </details>

- **ascend-device-plugin:把 A5(Atlas950/9501D)从"带 UBoE 口"的主板白名单剔除**。`withUBOEDevicesMainBoardID` 集合去掉 `Atlas950MainBoardID`、`Atlas9501DMainBoardID`,仅留 `Atlas850MainBoardID`(及其 2/3)。结合提交"A5 Pod 没有 UBoE 口,不支持 UBoE 参数面查询"——A5 形态硬件无 UBoE 口,从集合移除后 device-plugin 不再对 A5 触发 UBoE 参数面查询,避免无效/报错的查询。

  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/ascendcommon.go</summary>

  ```diff
  -	withUBOEDevicesMainBoardID = sets.NewInt(api.Atlas950MainBoardID, api.Atlas9501DMainBoardID,
  -		api.Atlas850MainBoardID, api.Atlas850MainBoardID2, api.Atlas850MainBoardID3)
  +	withUBOEDevicesMainBoardID = sets.NewInt(api.Atlas850MainBoardID, api.Atlas850MainBoardID2, api.Atlas850MainBoardID3)
  ```
  </details>

- **ascend-device-plugin:faultCode.json 故障码全量大写归一**。`AutoStopNPUCodes` / `PreSeparateNPUCodes` 等列表里所有 `8f18xxxx`/`8f19Axxx` 小写十六进制码统一改为大写(如 `8f180200`→`8F180200`),纯格式归一,不改集合成员。另有提交"修改 rdma dpu ub port 故障级别由 separateDPU 到 SubHeathFault"(故障级别下调,本文件 hunk 截断未覆盖该段,以提交标题为据)。

  <details><summary>代码依据 component/ascend-device-plugin/build/faultCode.json(节选)</summary>

  ```diff
  -    "8f180200","8f180201","8f180202",...,"8f19800C"
  +    "8F180200","8F180201","8F180202",...,"8F19800C"
  ```
  </details>

### 后续发展方向 [AI]
- infer-operator 的 gang 调度正在向"资源足额准入"靠拢:`MinResources` 一旦下发,Volcano 会在集群聚合资源不足时挂起整组而非拉起部分 pod,这对昇腾大规模推理实例(多副本占满 NPU)的"全有或全无"语义是必要前提。证据只覆盖 Deployment/StatefulSet 两个 handler + 资源累加工具;接口注释提到 LeaderWorkerSet 的 leader/worker 双模板待各自实现,未见 LWS handler 的 MinResources 代码。
- ascend-for-volcano 这次是"减法修复":把记账责任收敛回框架,趋势是减少插件侧对 `Idle`/`Allocate` 的旁路改写以消除与框架的状态竞争。证据只覆盖 task.go 两函数的 Idle 段,未见是否还有其他旁路记账点。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos(仅锚点,无实质改动)</summary>

- npu-operator(tag 1.2.0,无新提交)
- npu-container-toolkit(tag 1.2.0,无新提交)
- npu-driver-installer(tag 1.2.0,无新提交)
- vNPU(tag v0.1.0,无新提交)
- npu-node-provision(tag 1.2.0,无新提交)
- npu-dra-plugin(tag 1.0.1,无新提交)
- volcano-ext(tag v1.9.0,无新提交)
- ub-network-device-plugin(tag 1.0.1,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=37905df6593785dad11df642a639c28d8406a5ed tag=v26.0.1 scanned=2026-06-27 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=1.2.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=1.2.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=1.2.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=vNPU sha=ed90d497b78be919aa5c571daf7b8914bc89c7fe tag=v0.1.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=1.2.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b28f10a1e98ec0c2af8be45928e08e689d4a7fb4 tag=1.0.1 scanned=2026-06-27 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-06-27 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=1.0.1 scanned=2026-06-27 -->
</content>
</invoke>
