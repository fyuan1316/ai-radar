# NVIDIA 算力栈 diff 雷达 2026-11-20

## 摘要
- **KAI-Scheduler 不再把 DRA adminAccess GPU claim 计成 GPU 占用**。像 DCGM exporter、DRA validator 这类监控 DaemonSet 会在每个节点挂 admin access 的 GPU claim。过去它们会把单卡节点"占满",以后真实负载可以正常放上去。同时新增 `HasDRAGPUClaim`/`RequiresGPUNode()`,这类 Pod 仍被限制在 GPU 节点上。binder 也开始 watch 不带 KAI schedulerName 的 reservation pod,这类 pod 被外部删掉时会同步 GPU group。
- **k8s-device-plugin 的 socket 名加了随机 session ID**:从 `nvidia-gpu.sock` 改成 `nvidia-gpu-<8位hex>.sock`。`Serve()` 启动时不再无条件删掉同名 socket,只删没有监听者(ECONNREFUSED)的旧 socket,用来支持新旧插件进程交接(takeover)。
- **gpu-operator 新增 ISV 自认证套件的 kustomize 部署**(`deployments/gpu-operator-certification/`)。它以一次性 Job 跑 TS1000~TS1008,覆盖默认配置、time-slicing、DCGM、驱动升级、MIG single/mixed、GPUDirect RDMA/DMA-BUF、GDRCopy。nvidia-container-toolkit 只是把 CI Action 钉到 commit SHA。

## 当日重要改变
- **kai-scheduler/KAI-Scheduler [API/CRD变更·内部结构]**:helper 命中了 `pkg/scheduler/api/{pod_info,node_info}`。核实下来这是调度器内部缓存结构,不是 CRD:`PodInfo` 新增 `HasDRAGPUClaim` 字段,`IsRequireAnyKindOfGPU()` 拆成 `requiresGPUCapacity()`(私有,判断是否消耗 GPU 容量)和 `RequiresGPUNode()`(判断是否必须落在 GPU 节点)。DRA 共享设备去重 `allocatedGPUDeviceKeys` 跳过 `AdminAccess=true` 的分配结果。依赖 `github.com/kai-scheduler/api` 从 v0.2.1 升到 v0.2.2,用户可见的 CRD 仓有 patch 级变化,但不在本 diff 内。 https://github.com/kai-scheduler/KAI-Scheduler/commit/b19036d26de6 https://github.com/kai-scheduler/KAI-Scheduler/issues/2236
- **NVIDIA/gpu-operator [新能力]**:新增子目录 `deployments/gpu-operator-certification/`(README + RBAC/Job 清单 + kustomization),对应二进制 `gpu-operator-certification` 已经随 operator 镜像发布。 https://github.com/NVIDIA/gpu-operator/pull/3112

---

## kai-scheduler/KAI-Scheduler: f348ba24 -> 17f87cd1
- 比较: f348ba244ce9ac5cbd0858e71beb8f3ef6353279 -> 17f87cd1 | ahead=5 | files=31 | Release: v0.16.18(旧分支 backport;releases 里最大 semver 仍是 v0.19.0,不算跨档)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/f348ba244ce9ac5cbd0858e71beb8f3ef6353279...17f87cd114655a001631ccabf695b9a0be057ca2

### AI 总结重点(源码 diff 为据)
- **DRA adminAccess claim 不再占 GPU 容量,但仍要求 GPU 节点**(#2237)。`PodInfo` 新增 `HasDRAGPUClaim`:只要 Pod 引用了任何 GPU ResourceClaim(含 admin access)就置 true,`Clone()` 也会带上。原来的 `IsRequireAnyKindOfGPU()` 拆成两个:
  - `requiresGPUCapacity()`:整卡、DRA GPU 数、显存或 MIG 请求;`IsCPUOnlyRequest()` 改用它。
  - `RequiresGPUNode()`:`requiresGPUCapacity() || HasDRAGPUClaim`。
  
  predicates 插件在 restrict-node-scheduling 模式下改用 `RequiresGPUNode()` 判断 GPU 节点标签,所以监控类 Pod 仍不会被放到 CPU 节点。
  <details><summary>代码依据 pkg/scheduler/api/pod_info/pod_info.go</summary>

  ```diff
  +	// HasDRAGPUClaim marks a pod that references a GPU ResourceClaim, admin access claims included.
  +	HasDRAGPUClaim bool
  ...
   func (pi *PodInfo) IsCPUOnlyRequest() bool {
  -	return !pi.IsRequireAnyKindOfGPU()
  +	return !pi.requiresGPUCapacity()
   }
  -func (pi *PodInfo) IsRequireAnyKindOfGPU() bool {
  +// RequiresGPUNode is true for GPU requests and for pods holding a GPU claim that requests no GPU,
  +// such as an admin access claim, whose device can still only be on a GPU node.
  +func (pi *PodInfo) RequiresGPUNode() bool {
  +	return pi.requiresGPUCapacity() || pi.HasDRAGPUClaim
  +}
  +func (pi *PodInfo) requiresGPUCapacity() bool {
  ...
  +	pi.HasDRAGPUClaim = slices.ContainsFunc(draPodClaims, resources.IsGpuResourceClaim)
  ```
  </details>
  <details><summary>代码依据 pkg/scheduler/plugins/predicates/predicates.go</summary>

  ```diff
  -		if task.IsRequireAnyKindOfGPU() {
  +		if task.RequiresGPUNode() {
  ```
  </details>
- **节点侧 DRA 共享设备去重跳过 admin access 结果**。`allocatedGPUDeviceKeys` 收集"已经计过的共享 GPU 设备 key"时,新增 `ptr.Deref(result.AdminAccess, false)` 判断。这样监控 Pod 通过 admin access 持有的设备 key 不会进去重集合,真实消费者也就不会被误判成"已计数"而漏算。新测试覆盖的场景:1 卡节点挂 validator 和两个 dcgm-exporter 的 admin claim(其中两个是 `AllocationMode=All`)后,`UsedVector[GPU]=0`、空闲 GPU 为 1,1 卡训练 Pod 可以放下;再加一个真实消费者,`UsedVector[GPU]=1`。admin claim 的 `ResReqVector[GPU]=0` 这一点,测试里有断言,但实现应该在 `resources` 包或 `kai-scheduler/api` v0.2.2 里,本 diff 没覆盖到。
  <details><summary>代码依据 pkg/scheduler/api/node_info/dra_shared_device_info.go</summary>

  ```diff
  -			if !resources.IsGPUDeviceClass(result.Driver) {
  +			if !resources.IsGPUDeviceClass(result.Driver) || ptr.Deref(result.AdminAccess, false) {
   				continue
   			}
  ```
  </details>
- **`FeasibleNodesForJob` 语义随之变化**:原来写的是"job 里有任一 task 不需要任何 GPU 就返回全部节点",现在改为 `task.IsCPUOnlyRequest()`。所以只持有 admin claim 的 task 会被当作 CPU-only,返回全部节点,节点限制交给 predicates 的 `RequiresGPUNode()` 去兜。
  <details><summary>代码依据 pkg/scheduler/actions/common/feasible_nodes.go</summary>

  ```diff
  -		if !task.IsRequireAnyKindOfGPU() {
  +		if task.IsCPUOnlyRequest() {
   			return allNodes
  ```
  </details>
- **binder 开始关注 reservation pod**(#2628)。`isRelevantPod` 原来只放行 `SchedulerName == KAI` 的 Pod,但 GPU reservation pod 创建时不带 KAI scheduler name,外部删掉它时 binder 收不到事件,GPU group 也就不会同步。现在新增接口方法 `IsReservationPod`:在 reservation namespace 下、并且带 `GPUGroup` label 的 Pod 都算相关。这是 KAI 分数 GPU(reservation pod 模式)的一致性修复。
  <details><summary>代码依据 pkg/binder/controllers/pod_controller.go / resource_reservation.go</summary>

  ```diff
  -	if isPod {
  -		return pod.Spec.SchedulerName == r.SchedulerName
  +	if !isPod {
  +		return false
  +	}
  +	if pod.Spec.SchedulerName == r.SchedulerName {
  +		return true
   	}
  -	return false
  +	// Reservation pods are created without the KAI scheduler name.
  +	return r.ResourceReservation.IsReservationPod(pod)
  ...
  +func (rsc *service) IsReservationPod(pod *v1.Pod) bool {
  +	_, hasGpuGroup := pod.Labels[constants.GPUGroup]
  +	return hasGpuGroup && pod.Namespace == rsc.namespace
  +}
  ```
  </details>
- **node-scale-adjuster 的 scaling pod 改名,避免冲突**(#2439)。`scalingPodName` 从 `<ns>-<name>` 改成 `scaling.<ns>.<name>`。namespace 不能含点,所以不同 ns/name 组合不会再撞名(比如 `a-b`/`c` 和 `a`/`b-c`)。`IsScalingPodExistsForUnschedulablePod` 改为返回 `(bool, error)`:先按新名查,查不到再按 `legacyScalingPodName` 查,兼容升级前已经建好的 pod;查到之后还要核对 `SharedGpuPodName/Namespace` label 确认归属。出错时 `createNewScalingPods` 记日志并跳过,不再把错误当成"不存在"。
  <details><summary>代码依据 pkg/nodescaleadjuster/scaler/{scaling_pod,scaler}.go</summary>

  ```diff
   func scalingPodName(unschedulablePodNamespace string, unschedulablePodName string) string {
  +	return fmt.Sprintf("scaling.%s.%s", unschedulablePodNamespace, unschedulablePodName)
  +}
  +func legacyScalingPodName(unschedulablePodNamespace string, unschedulablePodName string) string {
   	return fmt.Sprintf("%s-%s", unschedulablePodNamespace, unschedulablePodName)
  ...
  -	return err == nil
  +	if errors.IsNotFound(err) {
  +		key.Name = legacyScalingPodName(unschedulablePod.Namespace, unschedulablePod.Name)
  +		err = s.client.Get(context.TODO(), key, pod)
  +	}
  ...
  +	return pod.Labels[consts.SharedGpuPodName] == unschedulablePod.Name &&
  +		pod.Labels[consts.SharedGpuPodNamespace] == unschedulablePod.Namespace, nil
  ```
  </details>
- 其余:topology 插件删掉 `sortTreeFromRoot`,直接把已经算好的 `tasksResources` 传给 `sortTree`,不再重复累加(#2576,纯重构)。queue/podgroup controller 的 ClusterRole 补了 `events` create/patch,让 leader election 能写事件(#2697)。

### 后续发展方向 [AI]
- **KAI 在把 DRA 的语义细节逐个补进自己的 GPU 记账**:上期是 terminating pod 占着的 DRA 设备,这期是 adminAccess。"要不要 GPU 节点"和"消耗多少 GPU"被拆成两个判断,这是 DRA 监控/运维类 claim(DCGM exporter 走 DRA adminAccess)进入生产后必须有的区分。证据只覆盖 scheduler/binder 的 hunk;未见 kai-scheduler/api v0.2.2 的具体改动。
- 分数 GPU 仍走 reservation pod 模式,本期修的是它和 binder 之间的事件一致性,没有看到向 DRA 原生共享迁移的代码。

---

## NVIDIA/k8s-device-plugin: 69439afc -> a36490f8
- 比较: 69439afcc740f6ea85a9f7f5a449c93e395deb73 -> a36490f8 | ahead=4 | files=15 | Release: v0.20.2
- compare: https://github.com/NVIDIA/k8s-device-plugin/compare/69439afcc740f6ea85a9f7f5a449c93e395deb73...a36490f8f08e832cf6c27ef28e5eeb12be60812d

### AI 总结重点(源码 diff 为据)
- **socket 路径带上 session ID**(#2078)。`plugin.New()` 每次启动用 `crypto/rand` 生成 4 字节随机数(hex 后 8 位)作为 `options.sessionID`,同一批启动的各 resource 插件共用。`getPluginSocketPath(resource, sessionID)` 生成的路径从 `/var/lib/kubelet/device-plugins/nvidia-<name>.sock` 变成 `nvidia-<name>-<sessionID>.sock`,启动日志会打 `Creating plugins for session <id>`。
  <details><summary>代码依据 internal/plugin/server.go / factory.go</summary>

  ```diff
  +	// Random bytes of session ID which is hex-encoded in socket names
  +	sessionIDBytes = 4
  ...
  -		socket: getPluginSocketPath(resourceManager.Resource()),
  +		socket: getPluginSocketPath(resourceManager.Resource(), o.sessionID),
  ...
  -func getPluginSocketPath(resource spec.ResourceName) string {
  +func getPluginSocketPath(resource spec.ResourceName, sessionID string) string {
  +	return filepath.Join(pluginapi.DevicePluginPath, getPluginName(resource)+"-"+sessionID) + ".sock"
  ```
  </details>
- **启动时的 socket 清理从"无条件删"改成"只删死 socket"**。`Serve()` 原来是 `os.Remove(plugin.socket)`,现在调 `removeStaleSockets()`:glob 匹配 `nvidia-<name>-????????.sock`,逐个 `net.DialTimeout("unix", s, 1s)` 探测,只有返回 `ECONNREFUSED`(没有监听者,比如上次崩溃留下的)才删。还活着的旧进程的 socket 会被保留。效果是新插件 Pod 可以在旧 Pod 仍在服务时注册新 socket,kubelet 切到新 endpoint 之前设备不会掉成 0(takeover 场景)。
  <details><summary>代码依据 internal/plugin/server.go</summary>

  ```diff
  +	pattern := filepath.Join(dir, pluginName+"-"+strings.Repeat("?", 2*sessionIDBytes)+".sock")
  ...
  +func isStaleSocket(socket string) bool {
  +	conn, err := net.DialTimeout("unix", socket, time.Second)
  +	if err == nil {
  +		conn.Close()
  +		return false
  +	}
  +	return errors.Is(err, syscall.ECONNREFUSED)
  +}
  ...
   func (plugin *nvidiaDevicePlugin) Serve() error {
  -	os.Remove(plugin.socket)
  +	plugin.removeStaleSockets()
  ```
  </details>
- 另一个提交 #2174 把各 workflow 的 Action 钉到 commit SHA,属于供应链加固,不影响运行时。

### 后续发展方向 [AI]
- **经典 device plugin 在补滚动升级/零中断能力**。socket 名唯一化加上"只清死 socket",是做 maxSurge 式 DaemonSet 升级的前置条件。说明 time-slicing/MPS 这条老路径虽然有 DRA 在替代,短期仍在持续投入运维质量。证据只覆盖 server.go/factory.go;未见 Helm chart 侧的 updateStrategy 改动。
- 兼容性提示:如果外部工具硬编码了 `nvidia-gpu.sock` 路径(探活脚本、自研 sidecar),升级到含这个提交的版本后会找不到 socket。

---

## NVIDIA/gpu-operator: 9e39c654 -> 304898f7
- 比较: 9e39c6544380a8aa486951b13adcd567066b3a59 -> 304898f7 | ahead=2 | files=3 | Release: v26.7.3
- compare: https://github.com/NVIDIA/gpu-operator/compare/9e39c6544380a8aa486951b13adcd567066b3a59...304898f717631a3e6da35526385cc44262d60125

### AI 总结重点(源码 diff 为据)
- **新增 ISV 自认证的 kustomize 部署入口**(#3112)。`kubectl apply -k deployments/gpu-operator-certification/` 会建一个 `backoffLimit: 0` 的一次性 Job:镜像 `ghcr.io/nvidia/gpu-operator:main-latest`,命令 `gpu-operator-certification`,容忍 `nvidia.com/gpu` 污点。配置全部来自 `configMapGenerator` 生成的 `gpu-operator-certification-config`(关掉 hash 后缀,方便 `delete -k`),结果写到 ConfigMap `gpu-operator-certification-results`,另有 JSON/HTML 报告。
  <details><summary>代码依据 deployments/gpu-operator-certification/kustomization.yaml</summary>

  ```diff
  +      #   TS1000 - Default Settings (operands, allocatable, GFD labels, DCGM metrics, workload)
  +      #   TS1001 - GPU Sharing via Timeslicing
  +      #   TS1002 - DCGM Standalone
  +      #   TS1003 - Driver Update
  +      #   TS1004 - MIG mode (single strategy)  — skipped if no MIG-capable GPUs detected
  +      #   TS1005 - MIG mode (mixed strategy)   — skipped if no MIG-capable GPUs detected
  +      #   TS1006 - GPUDirectRDMA               — skipped if fewer than 2 GPU nodes with RDMA hardware
  +      #   TS1007 - GPUDirectRDMA with DMA-BUF  — skipped if fewer than 2 GPU nodes with RDMA hardware
  +      #   TS1008 - GDRCopy                     — skipped if no operator-managed driver pods
  +      - TEST_SETS=all
  +      - TEST_TIMEOUT=15m
  ```
  </details>
- **认证 Job 的 RBAC 范围能看出它会碰哪些对象**:可以 `patch` clusterpolicies 和 nvidiadrivers(TS1003 驱动升级、TS1004/5 切 MIG 都通过改 CR 实现),可以 `patch` nodes,在 namespace 内能建删 pods/deployments、exec 进 Pod;另外可选读取 KubeVirt/HCO 用来识别虚拟化,读取 OpenShift `clusterversions`/`machines` 用来识别平台,并 `use` privileged SCC 跑 hostNetwork 的 RDMA 测试。
  <details><summary>代码依据 deployments/gpu-operator-certification/gpu-operator-certification.yaml</summary>

  ```diff
  +  - apiGroups: ["nvidia.com"]
  +    resources: ["clusterpolicies"]
  +    verbs: ["get", "list", "patch"]
  +  - apiGroups: ["nvidia.com"]
  +    resources: ["nvidiadrivers"]
  +    verbs: ["list", "patch"]
  +  # KubeVirt (optional, for virtualization detection)
  ...
  +  # OpenShift: RDMA test pods are privileged and use host networking.
  +  - apiGroups: ["security.openshift.io"]
  +    resources: ["securitycontextconstraints"]
  +    resourceNames: ["privileged"]
  +    verbs: ["use"]
  ```
  </details>
- ClusterPolicy(`api/nvidia/v1/clusterpolicy_types.go`)本期没有变化。

### 后续发展方向 [AI]
- **NVIDIA 在把"GPU Operator 兼容性"做成可交给 ISV 自助跑的认证流程**。测试集同时覆盖 vanilla K8s、OpenShift 和 KubeVirt,共享方式只测了 time-slicing 和 MIG,还没有 DRA 测试集。证据只覆盖部署清单和 README;认证二进制的源码在之前的提交里,本期没读。
- 对我们的启示:平台方如果要宣称"支持 NVIDIA GPU Operator",以后很可能被要求交这份 results.json/report.html。可以提前在自家发行版上跑一遍 TS1000~TS1008,把 SCC/PSA、RDMA 节点的前置条件补齐。

---

## 本期无实质改动(折叠)
<details><summary>6 个仓库</summary>

- NVIDIA/nvidia-container-toolkit:07b6bee0 -> d8041cb6,ahead=2,只有 #2228 把各 workflow 的 Action 从 tag 钉到 commit SHA,没有代码改动(v1.20.2)。 https://github.com/NVIDIA/nvidia-container-toolkit/pull/2228
- NVIDIA/gpu-driver-container:无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(v0.5.1)
- NVIDIA/dcgm-exporter:无新提交(4.9.0)
- NVIDIA/DCGM:无新提交
- NVIDIA/mig-parted:无新提交(v0.15.2)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=3ac6796228bda663fef350bda0f768d1bc5b35da branch=main release=— scanned=2026-11-20 -->
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=304898f717631a3e6da35526385cc44262d60125 branch=main release=v26.7.3 scanned=2026-11-20 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d8041cb623e601ebc085e2198725d2ce8277ab5a branch=main release=v1.20.2 scanned=2026-11-20 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-20 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=17f87cd114655a001631ccabf695b9a0be057ca2 branch=main release=v0.16.18 scanned=2026-11-20 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-20 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=a36490f8f08e832cf6c27ef28e5eeb12be60812d branch=main release=v0.20.2 scanned=2026-11-20 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=e775fdb63e593a121b40fc1cc4c9a9c89955e635 branch=main release=v0.5.1 scanned=2026-11-20 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=ea1cf1d0bab07cd430c1568667c9c6f69a06ca14 branch=main release=v0.15.2 scanned=2026-11-20 -->
