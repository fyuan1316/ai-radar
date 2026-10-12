# NVIDIA 算力栈 diff 雷达 2026-10-13

## 摘要
- **gpu-operator 命中 [API/CRD变更]**:NVIDIADriver CRD 的 `default` 与 `driverType` 两字段从 required 降级为 optional(struct tag 加 `omitempty`+`+kubebuilder:validation:Optional`,CRD `required` 列表删掉这两项)。这让精简版 NVIDIADriver CR 可省掉这两字段,配 kubebuilder 默认值(`default=false`、`driverType=gpu`)生效——降低手写 CR 门槛,但对已有自动化无破坏。
- **nvidia-container-toolkit** 单条 fix 价值高:重写 `SignalContainerd`,改在 `connect()` 之前经 `net.Dialer.Control` 开 `SO_PASSCRED` 再取 peer PID,修"服务端在 accept 即写数据、而凭据尚未开启→读到 pid 0→`kill(0)` 误杀自身进程组"的真实隐患(配 200 次回归测试)。影响所有用 container-toolkit 向 containerd 发 SIGHUP 重载配置的安装路径。
- **KAI-Scheduler** 单条 fix:BindRequest 生命周期从"按节点是否删除分类"改为"按是否失败分类"(`FailedBindRequestsForShard` 取代 `BindRequestsForDeletedNodes`),scheduler 只删失败的 BindRequest,binder 跳过终态并用乐观锁(resourceVersion 前置条件)patch status,防同名 BindRequest 被替换后把旧绑定结果写到新对象上。
- 其余:mig-parted 仅 Go 1.27.1→1.27.2 版本 bump(无能力变更);driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM 五仓无新提交。

## 当日重要改变
- **NVIDIA/gpu-operator [API/CRD变更]** NVIDIADriver 的 `default`/`driverType` 由必填改为可选(CRD required 列表移除 + struct omitempty)。证据 `api/nvidia/v1alpha1/nvidiadriver_types.go`、`config/crd/bases/nvidia.com_nvidiadrivers.yaml`。https://github.com/NVIDIA/gpu-operator/commit/032e544fd7704da883fae340f9d024aadfe362c9

## NVIDIA/gpu-operator: 9eddbaa4 -> 032e544f
- 比较: 9eddbaa4292c3ceb56295f40bc70ea5755237004 -> 032e544f | ahead=4 | files=5 | Release: v26.7.1
- https://github.com/NVIDIA/gpu-operator/compare/9eddbaa4292c3ceb56295f40bc70ea5755237004...032e544fd7704da883fae340f9d024aadfe362c9

### AI 总结重点(源码 diff 为据)
- **NVIDIADriverSpec 的 `Default` 与 `DriverType` 两字段从必填降为可选**。Go struct tag 由 `json:"default"`/`json:"driverType"` 改成带 `omitempty` 并新增 `+kubebuilder:validation:Optional` 标注;三份生成 CRD(`config/crd/bases`、`deployments/.../crds`、`bundle/manifests`)的 `required` 列表同步删除 `- default`、`- driverType`,仅保留 `- image`。两字段原有的 kubebuilder 默认值(`Default=false`、`DriverType=gpu`)与 `driverType` 不可变校验(`self == oldSelf`)保留不动,因此省略字段时按默认值填充,语义不变、仅放宽提交要求。
  <details><summary>代码依据 api/nvidia/v1alpha1/nvidiadriver_types.go + CRD yaml</summary>

  ```diff
  -	Default bool `json:"default"`
  +	// +kubebuilder:validation:Optional
  +	Default bool `json:"default,omitempty"`

  -	DriverType DriverType `json:"driverType"`
  +	// +kubebuilder:validation:Optional
  +	DriverType DriverType `json:"driverType,omitempty"`
  ```
  ```diff
   # config/crd/bases/nvidia.com_nvidiadrivers.yaml (三份生成产物同改)
               required:
  -            - default
  -            - driverType
               - image
  ```
  </details>

### 后续发展方向 [AI]
- 这是一次**易用性导向的 CRD 放宽**:让最小化 NVIDIADriver CR(只写 image)即可创建,降低手写/GitOps 模板门槛,属 API 收尾打磨而非能力扩展。证据只覆盖 NVIDIADriver 这一 CRD 的两字段 required 属性与 struct tag,未见 ClusterPolicy 侧字段变化,也未见 driver 预编译矩阵/time-slicing/DRA 相关改动;本仓其余改动仅 distroless/cc 基镜 v4.1.5→v4.1.6,无能力含义。

## NVIDIA/nvidia-container-toolkit: a672e378 -> 023f3590
- 比较: a672e378ef91bea7dfe92c0ed274847fa1cb9236 -> 023f3590 | ahead=2 | files=2 | Release: v1.20.1
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/a672e378ef91bea7dfe92c0ed274847fa1cb9236...023f35906ee23384b48dc3db3f2d1fb75d29f6b0

### AI 总结重点(源码 diff 为据)
- **`SignalContainerd` 的 PID 解析从"连后设选项"改为"连前经 Dialer.Control 设 `SO_PASSCRED`"**,修读到 containerd pid 为 0 的竞态。旧逻辑:`net.Dial` 建连后才 `SetsockoptInt(SO_PASSCRED)`,再 `WriteMsgUnix`/`ReadMsgUnix`+`ParseUnixCredentials` 取对端 PID;但内核只对"选项开启后入队"的数据附带凭据,而 containerd 服务端在 accept 即写数据,早入队的数据凭据为 pid 0,`kill(0, SIGHUP)` 会被解释为向调用方自身进程组发信号。新逻辑抽出 `getContainerdPid(socket)`,用 `net.Dialer{Control: ...}` 在 connect 前对 fd 设 `SO_PASSCRED`,保证首字节即带正确凭据,再 `syscall.Kill(pid, SIGHUP)`。错误包装从 `%v` 升级为 `%w`。
  <details><summary>代码依据 cmd/nvidia-ctk-installer/container/runtime/containerd/containerd_linux.go</summary>

  ```diff
   	retriable := func() error {
  -		conn, err := net.Dial("unix", socket)
  -		...SetsockoptInt(fd, SOL_SOCKET, SO_PASSCRED, 1) // 连后才设
  -		...WriteMsgUnix / ReadMsgUnix / ParseUnixCredentials
  -		err = syscall.Kill(int(ucred.Pid), syscall.SIGHUP)
  +		pid, err := getContainerdPid(socket)
  +		if err != nil { return fmt.Errorf("failed to get containerd pid: %w", err) }
  +		err = syscall.Kill(pid, syscall.SIGHUP)
   	}
  +func getContainerdPid(socket string) (int, error) {
  +	dialer := net.Dialer{ Control: func(network, address string, c syscall.RawConn) error {
  +		// connect() 前开 SO_PASSCRED,避免早入队数据带 pid 0
  +		c.Control(func(fd uintptr){ syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_PASSCRED, 1) })
  +	}}
  +	conn, err := dialer.Dial("unix", socket) …
  ```
  </details>
- **新增回归测试 `containerd_linux_test.go`**:起一个 accept 即写数据的 mock unix server,`TestGetContainerdPid` 断言返回 `os.Getpid()`,`TestGetContainerdPidNeverZero` 连做 200 次确认永不返回 pid 0。

### 后续发展方向 [AI]
- 纯正确性/健壮性修复,方向是**容器运行时集成的边界条件加固**(toolkit 安装器向 containerd 发 SIGHUP 重载配置这一步),不涉能力/配置面。证据覆盖 SignalContainerd 整函数与新测试,未见 CDI/runtime hook 生成逻辑改动。

## kai-scheduler/KAI-Scheduler: 173748a0 -> a2731327
- 比较: 173748a0b254531a5054374580e34ec8b9d839c8 -> a2731327 | ahead=1 | files=12 | Release: v0.18.5
- https://github.com/kai-scheduler/KAI-Scheduler/compare/173748a0b254531a5054374580e34ec8b9d839c8...a2731327f29de318c01321b3bdce5b9914b5dd0d

### AI 总结重点(源码 diff 为据)
- **BindRequest 快照的分类维度从"节点是否被删"改为"是否失败"**。`ClusterInfo.BindRequestsForDeletedNodes` 字段更名 `FailedBindRequestsForShard`;`snapshotBindRequests` 删掉 `nodes` 入参与 `nodePoolSelector` 依赖,不再按 `SelectedNode` 是否在快照内归类,改为 `bri.IsFailed()` 判定:失败的进 `failedBindRequestsForShard`,其余进正常 `result` map。配套 `data_lister` 的 `ListBindRequests` 从 `labels.Everything()` 收窄为 `k.partitionSelector`(按分片过滤)。
  <details><summary>代码依据 pkg/scheduler/cache/cluster_info/cluster_info.go + pkg/scheduler/api/cluster_info.go</summary>

  ```diff
  -	BindRequestsForDeletedNodes []*bindrequest_info.BindRequestInfo
  +	FailedBindRequestsForShard []*bindrequest_info.BindRequestInfo
  ```
  ```diff
  -func (c *ClusterInfo) snapshotBindRequests(nodes map[string]*node_info.NodeInfo) (...) {
  +func (c *ClusterInfo) snapshotBindRequests() (...) {
   	for _, bindRequest := range bindRequests {
  -		if _, found := nodes[bindRequest.Spec.SelectedNode]; !found {
  -			if c.nodePoolSelector.Matches(labels.Set(bindRequest.Labels)) { ...requestsForDeletedNodes }
  -			continue
  -		}
  -		result[...] = bindrequest_info.NewBindRequestInfo(bindRequest)
  +		bri := bindrequest_info.NewBindRequestInfo(bindRequest)
  +		if bri.IsFailed() { failedBindRequestsForShard = append(...) } else { result[...] = bri }
   	}
  ```
  ```diff
  -	return k.bindRequestLister.List(labels.Everything())
  +	return k.bindRequestLister.List(k.partitionSelector)
  ```
  </details>
- **binder reconcile 只处理"可操作"的 BindRequest,status patch 加乐观锁**。`Reconcile` 把"删除中/已成功则跳过"的两段判断合成 `isActionableBindRequest(bindRequest)`;事件 handler 的 Create/Update 过滤也走该判据(`isActionableBindRequest`/`shouldEnqueueBindRequestUpdate`);`UpdateStatus` 的 `client.MergeFrom` 升级为 `MergeFromWithOptions(..., MergeFromWithOptimisticLock{})`,冲突/NotFound 时不报错,记录"BindRequest 在 reconcile 途中被替换/删除,丢弃本次结果"——若此时 Phase 已是 Succeeded 还额外打一条"基于旧 BindRequest 完成了绑定,属 bug"的错误日志。另:controller 注册从 `For(...)` 改 `Named(...)`+`Watches(...)`,PodReconciler 去掉 `Owns(ConfigMap)` 与 Create/Generic 事件处理。
  <details><summary>代码依据 pkg/binder/controllers/bindrequest_controller.go</summary>

  ```diff
  -	if bindRequest.DeletionTimestamp != nil { return result, nil }
  -	if bindRequest.Status.Phase == schedulingv1alpha2.BindRequestPhaseSucceeded { return result, nil }
  +	if !isActionableBindRequest(bindRequest) { return result, nil }
  -	patchErr := r.Client.Status().Patch(ctx, bindRequest, client.MergeFrom(originalBindRequest))
  +	patchErr := r.Client.Status().Patch(ctx, bindRequest,
  +		client.MergeFromWithOptions(originalBindRequest, client.MergeFromWithOptimisticLock{}))
  +	if patchErr != nil {
  +		if kerrors.IsConflict(patchErr) || kerrors.IsNotFound(patchErr) { // 被替换/删除 → 丢弃结果
  ```
  </details>
- **失败的 BindRequest 在 backoff 未耗尽时仍视为"GPU 组有活跃绑定",保留资源预留**。`hasActiveBindRequestsForGpuGroup` 对 Failed 的请求不再一律 continue:若 `BackoffLimit` 为 nil 或 `FailedAttempts >= BackoffLimit`(重试额度用尽)才返回 false,否则继续当作活跃占用——避免 binder 还在重试时预留被提前释放。
  <details><summary>代码依据 pkg/binder/binding/resourcereservation/resource_reservation.go</summary>

  ```diff
   	if br.Status.Phase == schedulingv1alpha2.BindRequestPhaseFailed {
  +		if br.Spec.BackoffLimit == nil || br.Status.FailedAttempts >= *br.Spec.BackoffLimit {
  +			return false, nil
  +		}
   		continue
   	}
  ```
  </details>

### 后续发展方向 [AI]
- 延续昨日主线:**BindRequest 绑定生命周期在多分片(shard/partition)+ 替换重建场景下的正确性收敛**。昨天修的是快照跨命名空间/拓扑子组,今天把"谁负责删 BindRequest、binder 如何安全 patch 已被替换的对象、重试期间预留是否保留"三处竞态钉死——乐观锁 + 按失败而非按节点分类 + backoff 感知的预留保持,指向 scheduler/binder 职责切分更清晰(scheduler 只收割失败件、binder 只认当前 resourceVersion)。证据覆盖 cluster_info 快照、binder 两个 controller、resource_reservation 四处,未见对调度算法(bin-packing/抢占/gang)本身的改动;`pkg/scheduler/api/cluster_info.go` 命中的是内部 API 包字段改名,非对外 CRD 变更,不计 [API/CRD变更]。

## 本期无实质改动(折叠)
<details><summary>6 仓无新提交 / 仅版本 bump</summary>

- NVIDIA/mig-parted — 仅 Go 1.27.1→1.27.2 版本 bump(两份 Dockerfile),无能力变更(Release v0.15.1)
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交(Release v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(Release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.8.4)
- NVIDIA/DCGM — 无新提交(master)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=032e544fd7704da883fae340f9d024aadfe362c9 branch=main release=v26.7.1 scanned=2026-10-13 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=023f35906ee23384b48dc3db3f2d1fb75d29f6b0 branch=main release=v1.20.1 scanned=2026-10-13 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9287a5418573da037ba0d287e059812aa4740e45 branch=main release=— scanned=2026-10-13 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=bd98fbd6b676c655d235857574bdca29ab562dbc branch=main release=v0.20.1 scanned=2026-10-13 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=fb8b9674749c15b35f3bc7535c2e796c86463397 branch=main release=v0.5.0 scanned=2026-10-13 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-13 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-13 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=71640b442b4e33748f6472f5ad0f68ac6551d875 branch=main release=v0.15.1 scanned=2026-10-13 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=a2731327f29de318c01321b3bdce5b9914b5dd0d branch=main release=v0.18.5 scanned=2026-10-13 -->
