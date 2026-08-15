# 昇腾算力栈 diff 雷达 2026-08-16

## 摘要
- **npu-operator 新增"组件节点冲突检测"闸门**:reconcile 前先跑 `detectComponentConflicts`,一旦 mindcluster-device-plugin / vnpu-device-plugin / dra-kubelet-plugin / vcannrt-installer 这几路在同一批节点上都被 managed 且 nodeSelector 重叠,就置 `ComponentConflict` 条件并**直接 return、不部署**——防止两套 device-plugin/DRA 路径抢同一张 NPU。
- **hard-vNPU 的开关模型改动**:CRD 字段 `EnableHardVNPU` 标记 Deprecated,`--enable-hard-vnpu` 命令行注入和 values 里的 `enableHardVNPU` 一并删除,hard-vNPU 改由"DRA profile config / 节点标签"选择——从一个全局布尔位转向按 profile/节点粒度。
- 另有两处状态机 bug 修复(updateStatus 吞掉 getInstance 错误、getInstance 错误链 `%v→%w` 断了 IsNotFound)+ volcano 容器 **de-root(runAsUser/Group 0→9000)** 安全加固。
- mind-cluster 本期 4 个提交仅落在文档与 FD SDK,**未触及所跟踪的 component/ 子目录**;其余 7 个 openFuyao 仓无新提交。

## 当日重要改变
- npu-operator [新能力] 新增 `internal/controller/component_conflict.go`(188 行),reconcile 主流程加冲突闸门,重叠节点即停部署并报 `ComponentConflict`。 https://gitcode.com/openFuyao/npu-operator/commit/bae95f0b9eaa2c5727b951694c45e6206a755d63
- npu-operator [API/CRD变更][弃用/移除] `api/v1/npuclusterpolicy_types.go` 字段 `EnableHardVNPU` 标 Deprecated,配套删除 `--enable-hard-vnpu` 注入与 values 项。 https://gitcode.com/openFuyao/npu-operator/compare/7cddacb58841f285c6f719e2d7a5cb235be32cdb...bae95f0b9eaa2c5727b951694c45e6206a755d63
- npu-operator [架构方向] node event filter 放宽:Create/Delete 从"仅带 NPU 标签节点"改为全量触发、Update 改为"任意标签变化即触发",以喂养新冲突检测所依赖的节点选择器信号。 https://gitcode.com/openFuyao/npu-operator/commit/bae95f0b9eaa2c5727b951694c45e6206a755d63

## npu-operator: 7cddacb5 -> bae95f0b
- 比较: 7cddacb5..bae95f0b | tag: v26.6.0 | commits=10 | truncated=false
- 源:https://gitcode.com/openFuyao/npu-operator/compare/7cddacb58841f285c6f719e2d7a5cb235be32cdb...bae95f0b9eaa2c5727b951694c45e6206a755d63

### AI 总结重点(源码 diff 为据)

- **新增组件冲突检测,作为 reconcile 的前置闸门**。`detectComponentConflicts` 把 5 个部署单元(mindcluster-device-plugin / vnpu-device-plugin / dra-kubelet-plugin / vnpu-client-update / dra-vcannrt-installer)各自的 `managed` 布尔 + 从 PlacementSpec 提取的 `nodeSelector` 装进 `conflictWorkload` map,再按 4 条 `conflictRule`(device-plugin↔vnpu-device-plugin、device-plugin↔dra-kubelet-plugin、vnpu-device-plugin↔dra-kubelet-plugin、vnpu-client-update↔dra-vcannrt-installer)逐对检查。两边都 managed 且 `findOverlappingNodes` 返回非空时记为冲突。Reconcile 在 `reconcileComponents` 之前调用它,一旦有冲突就 `setConditionsError(componentConflictReason, ...)` 并 `return`,**不再往下部署**。这是把"两套设备暴露路径(传统 device-plugin vs DRA vs vNPU)不能同时管同一节点"的约束从运行期踩坑前移到 reconcile 期硬拦。
  <details><summary>代码依据 internal/controller/component_conflict.go + npuclusterpolicy_controller.go(均新增/改)</summary>

  ```diff
  +	rules := []conflictRule{
  +		{left: "mindcluster-device-plugin", right: "vnpu-device-plugin"},
  +		{left: "mindcluster-device-plugin", right: "dra-kubelet-plugin"},
  +		{left: "vnpu-device-plugin", right: "dra-kubelet-plugin"},
  +		{left: "vnpu-client-update", right: "dra-vcannrt-installer"},
  +	}
  +	for _, rule := range rules {
  +		left := workloads[rule.left]; right := workloads[rule.right]
  +		if !left.managed || !right.managed { continue }
  +		nodes, err := findOverlappingNodes(ctx, r.Client, left.selector, right.selector)
  +		...
  +		conflicts = append(conflicts, componentConflict{Left: left.name, Right: right.name, Nodes: nodes})
  +	}
  // 主流程:
  +	conflicts, err := r.detectComponentConflicts(ctx)
  +	if len(conflicts) > 0 {
  +		ignoreError(r.setConditionsError(ctx, componentConflictReason, formatComponentConflicts(conflicts)))
  +		return ctrl.Result{}, nil
  +	}
  ```
  </details>

- **重叠判定的实现细节**:`findOverlappingNodes` 先用 `selectorsDefinitelyDisjoint`(两边有同 key 但不同 value 即判定必然不相交)做快速排除;两边都空 selector 视为"全部节点重叠"(返回哨兵 `<all nodes>`);否则用 `selectorsForDynamicCheck` 取**较大**的 selector 去 `client.List(MatchingLabels)` 拉节点、再用另一组 selector 在内存里 `labels.Set.Matches` 二次过滤,得到真正同时命中两组标签的节点名列表(排序后返回)。是"标签集合真交集",不是纯静态推断。
  <details><summary>代码依据 internal/controller/component_conflict.go</summary>

  ```diff
  +	if selectorsDefinitelyDisjoint(a, b) { return nil, nil }
  +	if len(a) == 0 && len(b) == 0 { return []string{allNodesSelectorName}, nil }
  +	listSelector, filterSelector := selectorsForDynamicCheck(a, b)
  +	if err := c.List(ctx, nodes, client.MatchingLabels(listSelector)); err != nil { ... }
  +	filter := labels.SelectorFromSet(filterSelector)
  +	for _, node := range nodes.Items {
  +		if filter.Matches(labels.Set(node.Labels)) { overlapped = append(overlapped, node.Name) }
  +	}
  ```
  </details>

- **hard-vNPU 从"全局开关"降级为"profile/标签驱动"**。`api/v1/npuclusterpolicy_types.go` 里 `EnableHardVNPU` 字段保留但注释改为 `Deprecated: hard-vNPU mode is selected by DRA profile config or node labels.`;`resources_getters.go` 删掉了"若 `spec.DRA.EnableHardVNPU` 则 append `--enable-hard-vnpu`"这段参数注入;`charts/npu-operator/values.yaml` 也删了 `enableHardVNPU: false`。即 hard-vNPU 不再由一个 CRD 布尔位统一开关,而交给 DRA 的 profile 配置或节点标签细粒度决定。
  <details><summary>代码依据 api/v1/npuclusterpolicy_types.go + resources_getters.go</summary>

  ```diff
  -	// Whether hard-vNPU is enabled
  +	// Deprecated: hard-vNPU mode is selected by DRA profile config or node labels.
  	EnableHardVNPU bool `json:"enableHardVNPU,omitempty"`
  // resources_getters.go:
  -	if spec.DRA.EnableHardVNPU {
  -		args = append(args, "--enable-hard-vnpu")
  -	}
  ```
  </details>

- **node event filter 全面放宽**,配合冲突检测。`nodeEventFilter` 的 CreateFunc/DeleteFunc 由 `hasNPUDeviceLabels(...)` 改为直接 `return true`,UpdateFunc 由"仅 NPU-present 标签发生翻转"改为 `!reflect.DeepEqual(objectLabels(old), objectLabels(new))`(任意标签变化都触发)。代价是 reconcile 频率上升,收益是节点 selector 相关标签一变就能重算冲突——原过滤器只盯 NPU 标签,会漏掉影响 nodeSelector 命中的普通标签变更。
  <details><summary>代码依据 internal/controller/npuclusterpolicy_controller.go</summary>

  ```diff
  	CreateFunc: func(e event.CreateEvent) bool {
  -		return hasNPUDeviceLabels(e.Object.GetLabels())
  +		return true
  	},
  	UpdateFunc: func(e event.UpdateEvent) bool {
  -		return hasNPUPresentLabel(e.ObjectNew.GetLabels()) != hasNPUDeviceLabels(e.ObjectNew.GetLabels())
  +		return !reflect.DeepEqual(objectLabels(e.ObjectOld), objectLabels(e.ObjectNew))
  	},
  ```
  </details>

- **两处状态机 bug 修复**。①`updateStatus` 的 RetryOnConflict 回调里,`getInstance` 失败时原来 `return nil`——把重取实例的错误吞掉,导致基于**过期 instance** 继续写状态;改为 `return err` 让冲突重试/错误正常上抛。②`getInstance` 的错误包装 `%v→%w`,保留错误链,使上层 `apierrors.IsNotFound` 能正确识别(否则 NotFound 被字符串化后判不出来)。
  <details><summary>代码依据 internal/controller/status.go + npuclusterpolicy_controller.go</summary>

  ```diff
  // status.go updateStatus:
  		if err := r.getInstance(ctx, r.instance.Name); err != nil {
  -			return nil
  +			return err
  		}
  // controller getInstance:
  -		err = fmt.Errorf("Failed to get ClusterPolicy object: %v", err)
  +		err = fmt.Errorf("Failed to get ClusterPolicy object: %w", err)
  ```
  </details>

- **dra-deviceclasses / dra-soft-vnpu 改为"无独立状态"组件**,并有一处安全加固。`components.go` 删除 `draDeviceClassesStatus`/`draSoftVNPUStatus` 两个状态常量,`componentStatusName` 把这两个组件并入"返回空串"的分支(与 namespace/CRD 同类,只 apply、不报 per-component 就绪条件);同时删了随之而来的 8 个 `outputs/manual-validation/*.yaml` 手测夹具。`values.yaml` 把 volcano 的 `runAsUser/runAsGroup` 从 **0 改为 9000**(de-root),并把 draVCANNRTInstaller 镜像从 docker.io/library 占位改指向 `cr.openfuyao.cn/openfuyao/vnpu:acl-client-update`、删除尚无正式镜像的 draWebhook 块。
  <details><summary>代码依据 internal/controller/components.go + charts/npu-operator/values.yaml</summary>

  ```diff
  // components.go:
  -	draDeviceClassesStatus      = componentPathPrefix + "/dra-deviceclasses"
  -	draSoftVNPUStatus           = componentPathPrefix + "/dra-soft-vnpu"
  	case vnpuNamespaceComponent, volcanoVNPUCRDsComponent, volcanoVNPUNamespaceComponent,
  +		draDeviceClassesComponent, draSoftVNPUComponent:
  		return ""
  // values.yaml volcano:
  -	runAsUser: 0
  -	runAsGroup: 0
  +	runAsUser: 9000
  +	runAsGroup: 9000
  ```
  </details>

### 后续发展方向 [AI]
- 冲突闸门 + hard-vNPU 去全局开关,合看是 npu-operator 在把"设备暴露路径的互斥性"做成一等公民:传统 device-plugin、vNPU device-plugin、DRA kubelet-plugin 三条路被显式建模为不可在同节点共管。**对我们产品的启示**:自家 operator 若同样支持多套 GPU/NPU 暴露路径(device-plugin 与 DRA 并行迁移期),这种 reconcile 前置的 nodeSelector 交集检测值得抄——比运行期设备争用报错友好。证据仅覆盖 4 条硬编码 `conflictRule` + `component_conflict.go` 的实现,**未见**冲突后是否有自动修复/建议,只是置条件停部署。
- hard-vNPU 转向 profile/标签驱动,说明 DRA 侧正把 vNPU 切分模式的选择下沉到 DeviceClass/ResourceClaim 或节点标签;但**本次 diff 只看到 operator 侧删了开关注入,未见** DRA driver 侧如何消费 profile/label 做 hard 切分(那部分在 npu-dra-plugin/vNPU 仓,本期均无提交)。趋势判断需下期这两仓有动时再确认。
- de-root(runAsUser 9000)是纯安全加固、不改功能语义,但方向明确:昇腾组件在往非 root 容器靠,对企业级合规(PSP/PSA restricted)是加分项。

## 本期无实质改动(折叠)
- mind-cluster:本期 4 提交仅"README与CONTRIBUTE文档标准化"+"[FD][Fix] Fix Attribute error if calling sdk",按 component/ 前缀过滤后信号文件为空,未触及所跟踪的算力栈子目录,故不写正文(锚点照常推进)。
- npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=6fe79f061b6383290148f1119e98e97142b2f3cf tag=v26.1.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=npu-operator sha=bae95f0b9eaa2c5727b951694c45e6206a755d63 tag=v26.6.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=npu-dra-plugin sha=90c70b32b9b368efc2cc26bda1209e4f275a804c tag=v26.6.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-16 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-16 -->
</content>
</invoke>
