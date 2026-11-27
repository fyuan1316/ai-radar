# HAMi diff 雷达 2026-11-28

## 摘要

- **RemoteGPU(Lupine 远程 GPU)路线发生一次架构级转向:从"每节点一个 chart 托管的 Lupine server DaemonSet + 整卡独占"改成"调度器为每个 client Pod 在 GPU 节点上拉起一个专属 server Pod + 按显存共享同一张卡"**。chart 里的 `devices.remotegpu.server.enabled` 被直接删除(不再由 chart 部署 server),`daemonsetlupine.yaml` 改名为 `daemonsetremotemonitor.yaml` 只留监控;HAMi-core 的显存限流从注入 client 容器挪到注入 server Pod(`armMemoryLimit` 整函数删除,改由 `serverPod()` 写 `CUDA_DEVICE_MEMORY_LIMIT_<i>`),**隔离点从"用户可以 unset 的工作负载容器"移到"用户拿不到的 server 容器"**(#3467 #3468)。
- **配额侧补上企业多租户里一个真实缺口:带 `spec.scopes` / `spec.scopeSelector` 的 ResourceQuota 此前被 HAMi 当成命名空间总量,等于对 BestEffort/PriorityClass/Terminating 这类作用域配额完全不生效**。新增 `pkg/device/quota_scope.go`(363 行)按 kube-apiserver 的 pod quota evaluator 复刻作用域匹配,`FitPodQuota` 从 `FitQuota(ns,...)` 换成 `FitQuotaForPod(pod,...)`(#3549)。
- **可观测性两头同时推进**:HAMi 侧 OpenTelemetry 从调度器延伸到 NVIDIA device plugin 的 `Allocate`(`startAllocateSpan` 从 Pod 注解里的 traceparent 续上 Filter 的 span),chart 新增顶层 `tracing.otlpEndpoint`/`tracing.extraEnvs`(#3544 #3545);HAMi-WebUI 则**冻结 `/api/v1` 读契约**(新增 `server/api/v1/resources.proto`、`observability/v1/telemetry.proto`)、给 Prometheus 客户端加熔断+响应体字节上限+并发闸,并彻底卸掉 element-plus/bootstrap 等旧前端栈只留 TDesign(#372~#380)。

## 当日重要改变

- **Project-HAMi/HAMi [架构方向][新能力]** 新增 `pkg/device/remotegpu/server.go`(318 行):`serverPod()` 为每个 client Pod 构造专属 Lupine server Pod(`NodeName` 直接指定、`hostNetwork`、名字含 `fnv32(node|endpoint|devices|allocation)` 哈希),Bind 前调 `StartServer`、bind 失败调 `StopServer`,`ReconcileServers` 在 leader 的 register 周期里对账。证据:`pkg/device/remotegpu/server.go`、`pkg/scheduler/scheduler.go` — https://github.com/Project-HAMi/HAMi/pull/3468
- **Project-HAMi/HAMi [弃用/移除]** chart value `devices.remotegpu.server.enabled` 删除,`charts/hami/templates/device-plugin/daemonsetlupine.yaml` 重命名为 `daemonsetremotemonitor.yaml` 且渲染条件从 `.server.enabled` 换成 `.monitor.enabled`,节点亲和从 `hami.io/lupine-server In [""]` 放宽为 `Exists`。**升级时在 values 里写 `devices.remotegpu.server.enabled` 会直接变成未知键**。证据:`charts/hami/values.yaml`、`charts/hami/templates/device-plugin/daemonsetremotemonitor.yaml` — https://github.com/Project-HAMi/HAMi/pull/3468
- **Project-HAMi/HAMi [新能力]** 新增顶层文件 `pkg/device/quota_scope.go` 与 `QuotaManager.scoped` / `podUsages` 两个状态表,支持作用域 ResourceQuota 的设备配额;`Scheduler.onUpdatePod` 新增 `quotaManager.RefreshPodScopes(newPod)`(`activeDeadlineSeconds` 可在运行期变化)。证据:`pkg/device/quota_scope.go`、`pkg/device/quota.go`、`pkg/scheduler/scheduler.go` — https://github.com/Project-HAMi/HAMi/pull/3549
- **Project-HAMi/HAMi [新能力]** device plugin 接入 tracing:新增 `pkg/device-plugin/nvidiadevice/nvinternal/plugin/tracing.go`,`cmd/device-plugin/nvidia/main.go` 调 `tracing.Setup(ctx, "hami-device-plugin")`,`Allocate` 包一层 `allocate` span 并在成功时写 `tracing.DeviceUUIDsKey`;chart 新增顶层 `tracing` 段。证据:`pkg/device-plugin/nvidiadevice/nvinternal/plugin/tracing.go`、`charts/hami/values.yaml` — https://github.com/Project-HAMi/HAMi/pull/3544 和 https://github.com/Project-HAMi/HAMi/pull/3545
- **Project-HAMi/HAMi [架构方向]** RemoteGPU 配置契约扩容:`RemoteGPUConfig` 新增 `Server ServerConfig` 字段(image/tolerations/securityContext/resources/env/liveness/readiness),并给 `ServerConfig` 写了 `UnmarshalYAML` 以按 Kubernetes 的 JSON 名解析,`device-configmap.yaml` 渲染出整个 `server:` 子树。证据:`pkg/device/remotegpu/config.go`、`charts/hami/templates/scheduler/device-configmap.yaml` — https://github.com/Project-HAMi/HAMi/pull/3468
- **Project-HAMi/HAMi-core [弃用/移除]** 删除 `CUDA_REDIRECT` 环境变量与 `vgpulib` 的 `dlopen`(含默认路径 `/usr/local/vgpu/libvgpu.so`):该句柄 load 后从未被使用,属死代码,但对外是一个消失的环境变量入口。证据:`src/libvgpu.c` — https://github.com/Project-HAMi/HAMi-core/pull/440
- **Project-HAMi/HAMi-WebUI [API/CRD变更]** 新增 `server/api/v1/resources.proto`(11 个 `/api/v1/*` 只读 RPC)与 `server/api/observability/v1/telemetry.proto`(`GET /api/v1/telemetry/trends`),同时删除前端旧 API 模块 `packages/web/projects/vgpu/api/resources.js` / `deviceConfig.js`,新增 `packages/web/src/api/client.mjs` + `client.d.mts` 作为唯一类型化客户端;新增 16 个 `test/contracts/http-goldens/*.json` 把响应体冻成 golden。证据:`server/api/v1/resources.proto`、`server/api/observability/v1/telemetry.proto`、`packages/web/src/api/client.d.mts` — https://github.com/Project-HAMi/HAMi-WebUI/pull/375
- **Project-HAMi/HAMi-WebUI [弃用/移除]** 前端单栈收口:`package.json` 删除 `element-plus`、`@element-plus/icons-vue`、`bootstrap`、`@tabler/core`、`@tabler/icons-vue`、`sortablejs`、`tom-select`、`vuedraggable`、`vue-clipboard3`、`vue-count-to`、`animate.css`、`core-js`、`generate-avatar`,`tdesign-vue-next` 由 `^1.18.5` 钉成 `1.18.5`;同步删除 `src/plugins/element.js`、`styles/element-*`、`components/Message`、`components/Confirm`、`assets/custom-theme/*`。证据:`packages/web/package.json` — https://github.com/Project-HAMi/HAMi-WebUI/pull/376

## Project-HAMi/HAMi: 3d600ea7 -> 5eba23f5

- 比较: 3d600ea70324d4a4d60c59806ce0a78ab9810a7d -> 5eba23f5 | ahead=7 | files=64 | Release: v2.11.0
- 比较链接:https://github.com/Project-HAMi/HAMi/compare/3d600ea70324d4a4d60c59806ce0a78ab9810a7d...5eba23f5680deb0703c1bcbb5cea2d365ac90631

### AI 总结重点(源码 diff 为据)

- **RemoteGPU 的"服务端"从节点级共享变成 Pod 级专属**:新增 `serverPod()` 直接用 `NodeName` 把 server Pod 钉在持卡节点上(不走调度,因为卡已被调度器记账)、`hostNetwork: true`(client 拨节点 InternalIP)、`AutomountServiceAccountToken: false`,并用 `NVIDIA_VISIBLE_DEVICES` 只暴露该 Pod 的卡;Pod 名 = `lupine-<clientUID>-<fnv32(node|endpoint|serverDevices|allocation)>`,**所以重新放置会生成新名字而不是复用上一次放置的 server**。
  <details><summary>代码依据 pkg/device/remotegpu/server.go</summary>

  ```diff
  +	env := []corev1.EnvVar{
  +		{Name: "NVIDIA_VISIBLE_DEVICES", Value: strings.Join(cards, ",")},
  +		{Name: "NVIDIA_DRIVER_CAPABILITIES", Value: "compute,utility"},
  +		// Clients name cards by the server's CUDA ordinals, which the
  +		// scheduler counted in PCI bus order.
  +		{Name: "CUDA_DEVICE_ORDER", Value: "PCI_BUS_ID"},
  +		{Name: "LUPINE_PORT", Value: rawPort},
  +	}
  +	spec := corev1.PodSpec{
  +		// Assigned rather than scheduled: the cards are on this node, and the
  +		// scheduler has already accounted for them.
  +		NodeName: node,
  +		// Clients dial the node's InternalIP.
  +		HostNetwork:                  true,
  +		DNSPolicy:                    corev1.DNSClusterFirstWithHostNet,
  +		RestartPolicy:                corev1.RestartPolicyAlways,
  +		AutomountServiceAccountToken: new(false),
  +	h := fnv.New32a()
  +	fmt.Fprintf(h, "%s|%s|%s|%s", node, endpoint, clientPod.Annotations[ServerDevicesAnno], clientPod.Annotations[AllocatedAnnos])
  +			Name:      fmt.Sprintf("%s%s-%08x", serverPrefix, clientPod.UID, h.Sum32()),
  ```
  </details>

- **软隔离的执行点从 client 容器迁到 server 容器**:原来 `MutateAdmission` 用 `armMemoryLimit()` 给 client 容器注入 `LD_PRELOAD=<libvgpu>` + `CUDA_DEVICE_MEMORY_LIMIT` + `CUDA_DEVICE_MEMORY_SHARED_CACHE`(整个函数本期删除);现在 init container 把 HAMi-core 拷进 **server Pod**,并按卡序号写 `CUDA_DEVICE_MEMORY_LIMIT_<i>=<mem>m`,注释写明理由是"the workload cannot take the library out"。`configuredEnv()` 还会把用户配的任何 `CUDA_DEVICE_MEMORY_LIMIT*` 过滤掉,防止用 chart 的 `server.env` 绕开限额。
  <details><summary>代码依据 pkg/device/remotegpu/server.go / pkg/device/remotegpu/device.go</summary>

  ```diff
  +	// A card the pod shares by memory is limited to its share. The server
  +	// enforces it, where the workload cannot take the library out.
  +	if RemoteGPULibImage != "" {
  +		for i, uuid := range cards {
  +			if s, ok := shares[deviceID(node, uuid)]; ok && !s.whole && s.mem > 0 {
  +				limits = append(limits, corev1.EnvVar{Name: fmt.Sprintf("CUDA_DEVICE_MEMORY_LIMIT_%d", i), Value: fmt.Sprintf("%dm", s.mem)})
  +			}
  +		}
  +	}
  +func configuredEnv(configured, set []corev1.EnvVar) []corev1.EnvVar {
  +	for _, e := range configured {
  +		if strings.HasPrefix(e.Name, "CUDA_DEVICE_MEMORY_LIMIT") || slices.ContainsFunc(set, ...) {
  +			continue
  -// armMemoryLimit puts HAMi-core in front of the client's CUDA calls, so the
  -// memory the pod asked for is the memory it can take.
  -func armMemoryLimit(ctr *corev1.Container, pod *corev1.Pod) (bool, error) {
  -	preload := libMountPath + "/libvgpu.so"
  -	if existing := envOf(ctr, ldPreloadEnv); existing != nil {
  ```
  </details>

- **远程卡从"整卡独占"变成"可按显存共享",且复用了本地 vGPU 的那套判据**:`pool` 的 `inUse`/`held` 从 `map[string]struct{}`(卡 → 占用)升级为 `map[string]map[string]share`(卡 → podKey → 占了多少),新增 `share{users,mem,whole,host}`;新增 `shareable(request)` 规定"只有同时给了 `Memreq>0` 且配了 HAMi-core 镜像才允许共享,否则整卡拿走";`cardState.check()` 复用 `CardTimeSlicingExhausted`(按 `d.Count`,即 device plugin 的 `deviceSplitCount` 限制同卡 Pod 数)与 `CardInsufficientMemory` 两个拒绝原因;`pick()` 的排序把"本 Pod 已用的卡"排最前、再按剩余显存从小到大(best-fit,先填满一张再开下一张)。
  <details><summary>代码依据 pkg/device/remotegpu/device.go / pkg/device/remotegpu/pool.go</summary>

  ```diff
  +func shareable(request device.ContainerDeviceRequest) bool {
  +	return request.Memreq > 0 && RemoteGPULibImage != ""
  +}
  +	case !shareable(request):
  +		// A whole card: nobody else may be on it.
  +		if c.others.users > 0 {
  +			return common.ExclusiveDeviceAllocateConflict, true
  +		}
  +	case c.others.whole:
  +		return common.ExclusiveDeviceAllocateConflict, true
  +	case int64(c.others.users+c.own.users) >= c.d.Count:
  +		return common.CardTimeSlicingExhausted, c.others.users > 0
  +	case c.d.Totalmem-c.usedMem() < request.Memreq:
  +		return common.CardInsufficientMemory, c.others.users > 0
  -	inUse        map[string]struct{}  // device ID held by a live pod
  -	held         map[string]booking   // device ID booked since the last refresh
  +	inUse        map[string]map[string]share   // device ID -> pod key -> what a live pod holds
  +	held         map[string]map[string]booking // device ID -> pod key -> booked since the last refresh
  ```
  </details>

- **多容器同 Pod 的卡可见性真正做了隔离**:新增注解前缀 `remote-gpu-visible-devices.hami.io/<container>`,`PatchAnnotations` 按 NVML index 给 Pod 的卡排序后写每容器的**序号**列表,`MutateAdmission` 用 downward API 把它映射成容器内的 `CUDA_VISIBLE_DEVICES`;`ServerDevicesAnno`(`hami.io/lupine-server-devices`)记录 server 侧的 UUID 顺序。注释明确说用序号而不是 UUID 是因为 chart 钉的 Lupine 版本忽略 GPU UUID(上游 lupinemachines/lupine#1135 已修)。
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
  +	// VisibleDevicesAnnoPrefix, followed by a container name, lists the
  +	// indices of the cards the scheduler gave that container on its pod's
  +	// Lupine server. It reaches the client as CUDA_VISIBLE_DEVICES, so
  +	// containers of one pod do not see each other's cards in CUDA.
  +	VisibleDevicesAnnoPrefix = "remote-gpu-visible-devices.hami.io/"
  +	for _, wire := range [][2]string{{lupineServerEnv, LupineServerAnno}, {visibleDevicesEnv, VisibleDevicesAnnoPrefix + ctr.Name}} {
  +		setEnv(ctr, corev1.EnvVar{
  +			Name: env,
  +			ValueFrom: &corev1.EnvVarSource{
  +				FieldRef: &corev1.ObjectFieldSelector{FieldPath: fmt.Sprintf("metadata.annotations['%s']", anno)},
  +	ordinal := make(map[string]int, len(cards))
  +		if name := containerName(pod, i); name != "" && len(ctrDevs) > 0 {
  +			(*annoinput)[VisibleDevicesAnnoPrefix+name] = strings.Join(visible, ",")
  ```
  </details>

- **端口从"节点一个固定端口"变成"每 Pod 一个端口"并进了调度器的可冲突资源集**:`pool` 新增 `taken map[string]bool` / `heldEndpoints map[string]heldEndpoint`,`PatchAnnotations` 改调 `assignEndpoint(server, podKey)` 而不是只读 `endpoint(server)`;`DefaultPort`(14833)语义降级为"节点自己的端口 / 外部托管 server 的端口",每个 client Pod 的 server 在其之上找第一个空闲 host port。
  <details><summary>代码依据 pkg/device/remotegpu/pool.go / pkg/device/remotegpu/device.go / charts/hami/values.yaml</summary>

  ```diff
  +	// taken holds the endpoints a placed client pod or a Lupine server pod
  +	// holds, and heldEndpoints the ones booked since the last refresh, by pod
  +	// key. Together they keep two server pods off one port.
  +	taken         map[string]bool
  +	heldEndpoints map[string]heldEndpoint
  -		if ep, ok := dev.pool.endpoint(serverOf(id)); ok {
  +		if ep, ok := dev.pool.assignEndpoint(serverOf(cards[0]), podKey(pod)); ok {
  +			(*annoinput)[ServerDevicesAnno] = strings.Join(physical, ",")
  -    # -- Port (1-65535) used by the scheduler and the server DaemonSet's container and host ports.
  +    # -- A server node's own port (1-65535), used when its `hami.io/lupine-server` label has no
  +    # valid port. Each client Pod's lupine server listens on the first free host port above it.
  ```
  </details>

- **Bind 时序被改成"先起 server、再 bind、bind 失败就删 server",并且 booking 过期会拒绝 bind**:`ValidateReservedServer` 新增 `dev.pool.booked(podKey(pod))` 检查(booking 超过 `heldTTL` 没 bind 说明卡可能已给别人,宁可让 Pod 重新 Fit);`Scheduler.register` 的 leader 周期里新增 `dev.ReconcileServers(ctx)`。chart RBAC 的 `pods: [create, delete]` 条件从 `and .enabled .sessionImage` 放宽成只要 `.enabled`。
  <details><summary>代码依据 pkg/scheduler/scheduler.go / pkg/device/remotegpu/device.go / charts/hami/templates/scheduler/role.yaml</summary>

  ```diff
  +	// The pod's Lupine server starts while the pod does.
  +	if remoteReserved {
  +		if err = remote.StartServer(context.Background(), current); err != nil {
  +			return fail(err)
   	if err = s.kubeClient.CoreV1().Pods(args.PodNamespace).Bind(...); err != nil {
  +		if remoteReserved {
  +			remote.StopServer(context.Background(), current)
  +		}
  +	if !dev.pool.booked(podKey(pod)) {
  +		return fmt.Errorf("the RemoteGPU booking for this pod has expired before Bind")
  +	}
  -{{- if and .Values.devices.remotegpu.enabled .Values.devices.remotegpu.sessionImage }}
  +{{- if .Values.devices.remotegpu.enabled }}
   - apiGroups: [""]
     resources: ["pods"]
     verbs: ["create", "delete"]
  ```
  </details>

- **远程 GPU 监控从"server Pod 里的 sidecar"改成"server 节点上的 DaemonSet",并开始区分"HAMi 记账的用量"与"无主用量"**:`Collector` 的 `URL string` 换成 `Host string` + 新增 `Cards func() (map[string]Card, error)`(从节点注册注解 `nvidia.RegisterAnnos` 反解每张卡的 NVML index 与显存),按 Pod 分组逐个 server 抓 `/metrics`;新增 5 个指标 `hami_host_gpu_memory_total_bytes`、`hami_remote_gpu_clients`、`hami_remote_gpu_unattributed_memory_used_bytes`、`hami_remote_gpu_unattributed_utilization_ratio`、`hami_remote_gpu_server_connections`;调度器侧 `cmd/scheduler/metrics.go` 新增 `hami_remote_gpu_server_up` 与 `hami_remote_gpu_server_last_scrape_success_timestamp_seconds`,`hami_remote_gpu_allocated` 的 `usedmem` 从"整卡或 0"改成 `pd.Usedmem`。
  <details><summary>代码依据 pkg/monitor/remotegpu/collector.go / cmd/scheduler/metrics.go / cmd/remoteGPUmonitor/main.go</summary>

  ```diff
  +var unattributedMemory = prometheus.NewDesc("hami_remote_gpu_unattributed_memory_used_bytes", "GPU memory used by Lupine clients that match no HAMi allocation", deviceLabels, nil)
  +var connections = prometheus.NewDesc("hami_remote_gpu_server_connections", "Lupine clients connected to the server", []string{"node"}, nil)
   type Collector struct {
  -	Node, URL string
  -	Client    *http.Client
  +	Node, Host string
  +	Cards func() (map[string]Card, error)
  +	remoteGPUServerUpDesc = prometheus.NewDesc(
  +		"hami_remote_gpu_server_up",
  +		"1 if the scheduler's last read of a lupine server's /metrics succeeded with NVML up, 0 otherwise; reported once the server has answered",
  -		allocated, usedmem := 0.0, int64(0)
  +		allocated, usedmem := 0.0, pd.Usedmem
  -	source := flag.String("lupine-metrics-url", "http://127.0.0.1:14833/metrics", "Lupine metrics endpoint")
  +	host := flag.String("lupine-host", "127.0.0.1", "Address the node's Lupine servers are reached at")
  ```
  </details>

- **调度器读 server `/metrics` 的解析从"哪些卡忙"升级为"每张卡上有哪些 client",并新增 NVML 不可用的硬失败**:`httpBusyDevices` 返回值 `map[string]struct{}` → `map[string][]string`(卡 UUID → client_id 列表);新增哨兵 `lupine_monitor_nvml_up`,值不为 1 时直接返回 `errNVMLDown`——理由是 server 读不到 GPU 时会报"零 client",那不能被当成"卡空闲"。
  <details><summary>代码依据 pkg/device/remotegpu/metrics.go</summary>

  ```diff
  +	// nvmlUpMetric is 0 when the server cannot read its GPUs. It then reports
  +	// no clients at all, which says nothing about whether the cards are free.
  +	nvmlUpMetric = "lupine_monitor_nvml_up"
  +var errNVMLDown = errors.New("lupine server cannot read its GPUs through NVML")
  -func httpBusyDevices(ctx context.Context, endpoint string) (map[string]struct{}, error) {
  +func httpBusyDevices(ctx context.Context, endpoint string) (map[string][]string, error) {
  +		if value, ok := strings.CutPrefix(line, nvmlUpMetric+" "); ok && strings.TrimSpace(value) != "1" {
  +			return nil, errNVMLDown
  +		}
  -			busy[uuid] = struct{}{}
  +			busy[uuid] = append(busy[uuid], labelValue(line, clientIDLabel))
  ```
  </details>

- **作用域 ResourceQuota 的设备配额:匹配逻辑按 kube-apiserver 复刻,且"后加的配额能补算已有 Pod"**。`podScopes` 收 4 个维度(priorityClass / terminating / bestEffort / crossNamespace),`isTerminatingPod` 判 `ActiveDeadlineSeconds != nil && >= 0`,`isBestEffortPod` 优先信 `Status.QOSClass` 否则回退扫容器(含 pod-level resources),`usesCrossNamespacePodAffinity` 扫 (anti)affinity 的 `Namespaces`/`NamespaceSelector`;`PriorityClass` 作用域走 `labels.NewRequirement` 四种算子,**非法算子/值记 `invalid` 并视为匹配不到任何 Pod**(不是放行)。`QuotaManager` 为此多存 `podUsages`,`addQuotaLocked` 对 `isScopedQuota(quota)` 分流到 `addScopedQuotaLocked`,与无作用域配额完全分表。
  <details><summary>代码依据 pkg/device/quota_scope.go / pkg/device/quota.go</summary>

  ```diff
  +func isTerminatingPod(pod *corev1.Pod) bool {
  +	return pod.Spec.ActiveDeadlineSeconds != nil && *pod.Spec.ActiveDeadlineSeconds >= 0
  +}
  +	case corev1.ResourceQuotaScopePriorityClass:
  +		if m.invalid {
  +			return false
  +		}
  +		// As in kube-apiserver, a pod without a class has no PriorityClass key.
  +	// podUsages holds each pod's usage, so a scoped quota added later can
  +	// count the pods it matches: namespace -> pod -> usage.
  +	podUsages map[string]map[string]*podUsage
  -	return GetLocalCache().FitQuota(pod.Namespace, mem, core, devType)
  +	return GetLocalCache().FitQuotaForPod(pod, mem, core, devType)
  +	return q.fitQuotaLocked(pod.Namespace, ...) &&
  +		q.fitScopedLocked(pod, ...)
  ```
  </details>

- **KUBECONFIG 多文件(`a:b:c`)此前直接 fallback 到 in-cluster**:`loadKubeConfig` 原来用 `clientcmd.BuildConfigFromFlags("", os.Getenv("KUBECONFIG"))`,单路径语义,冒号分隔的多文件会解析失败后静默走 in-cluster;改为 `NewDefaultClientConfigLoadingRules().Load()` 做合并,并且两条路都失败时用 `%w; %w` 同时保留两个原因(不再丢掉 kubeconfig 的真实报错)。
  <details><summary>代码依据 pkg/util/client/client.go</summary>

  ```diff
  -	kubeConfigPath := os.Getenv("KUBECONFIG")
  -	if kubeConfigPath == "" {
  -		kubeConfigPath = filepath.Join(os.Getenv("HOME"), ".kube", "config")
  -	config, err := buildConfigFromFlags("", kubeConfigPath)
  +func LoadFileConfig() (*rest.Config, error) {
  +	rules := clientcmd.NewDefaultClientConfigLoadingRules()
  +	config, err := rules.Load()
  +	return clientcmd.NewNonInteractiveClientConfig(*config, "", &clientcmd.ConfigOverrides{}, rules).ClientConfig()
  +		inCluster, fallbackErr := inClusterConfig()
  +		if fallbackErr != nil {
  +			return nil, fmt.Errorf("kubeconfig: %w; in-cluster config: %w", err, fallbackErr)
  ```
  </details>

- **device plugin 侧 tracing 接的是"跨进程续链",不是新开一条**:`startAllocateSpan` 用 `tracing.Extract(ctx, pod.Annotations)` 从 Pod 注解(调度器 webhook 写入的 `hami.io/traceparent`)恢复上下文,因此 `allocate` span 挂在 Filter span 下;chart 的 `tracing.otlpEndpoint` 同时注给 scheduler 与 NVIDIA device plugin,`devicePlugin.extraEnvs` 对同名变量优先。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/tracing.go / charts/hami/values.yaml</summary>

  ```diff
  +// startAllocateSpan starts the span of one Allocate call for pod, a child of
  +// the Filter span whose context Filter wrote to the pod.
  +func startAllocateSpan(ctx context.Context, pod *corev1.Pod, node string) (context.Context, trace.Span) {
  +	return tracing.Tracer().Start(tracing.Extract(ctx, pod.Annotations), "allocate",
  +			tracing.DeviceTypeKey.String(nvidia.NvidiaGPUDevice),
  +tracing:
  +  # -- OTLP gRPC endpoint for the scheduler and the NVIDIA device plugin, as an HTTP(S) URL
  +  otlpEndpoint: ""
  +  # -- Additional `OTEL_*` environment variables for the scheduler and the NVIDIA device plugin.
  +  extraEnvs: []
  ```
  </details>

- 另:`libvgpu` 子模块从 `1b9824e` bump 到 `7e686fe`(#3546),即昨天那批 CUDA Graph 限流 + `libvgpu.map` 符号导出修复已进主仓构建。

### 后续发展方向 [AI]

- **RemoteGPU 正在从"远程整卡租借"长成"远程 vGPU":共享判据(`shareable` 要求 `Memreq>0` + HAMi-core 镜像)、同卡 Pod 数上限复用 `d.Count`(即 `deviceSplitCount`)、best-fit 填卡顺序,与本地 hami-core 路径的语义已经对齐;缺的只有算力维度**——`grant()` 在共享分支里只写 `Usedmem`,整卡分支才写 `Usedcores`,证据覆盖到 diff 里没有任何远程侧 `SM_LIMIT` 的下发路径。
- **隔离边界从"工作负载容器"上移到"平台托管的 server Pod",意味着 RemoteGPU 路径的软隔离强度反而高于本地 hami-core 路径**:本地路径里 `LD_PRELOAD` 和 `CUDA_DEVICE_MEMORY_LIMIT` 注在用户容器,用户可以覆盖;现在远程路径的限额注在用户无权编辑的 server Pod,且 `configuredEnv()` 主动过滤 `CUDA_DEVICE_MEMORY_LIMIT*`。证据只覆盖 server 侧 env 构造与过滤,未见对 `server.env` 做准入校验的 webhook。
- **"无主用量"这组新指标是在为"远程卡上存在 HAMi 不知道的 client"做长期准备**:`hami_remote_gpu_unattributed_memory_used_bytes` / `_utilization_ratio` + `lupine_monitor_nvml_up` 的硬失败表明设计上承认 server 可能被 HAMi 之外的会话使用。接下来最自然的一步是把这组数据接回 Fit 的拒绝原因或准入拦截,但 diff 里 `pick()` 目前只消费 `others.foreign` 这一个布尔,未见按无主用量做数值扣减。
- **调度器已经在扮演"工作负载 controller"**(`StartServer`/`StopServer`/`ReconcileServers` 直接 create/delete Pod,靠 label `hami.io/lupine-client` 对账,注释明确说 ownerReference 跨命名空间用不了)。这条路线会把 scheduler 的 RBAC 和故障语义继续放大(本期 `pods: create/delete` 已从"仅开 sessionImage 时"放宽到"开 remotegpu 就有");diff 里没有任何独立 controller/operator 的雏形,也没有 leader 之外的 reconcile 入口。
- 配额侧:`quota_scope.go` 复刻的是 kube-apiserver 的 pod 作用域语义,`VolumeAttributesClass` 等其他作用域显式返回"永不匹配"。证据只覆盖 scopes/scopeSelector 的匹配与计数,未见把 HAMi 的设备资源注册给 apiserver 原生 quota(仍是 scheduler 侧自管一套账)。

## Project-HAMi/HAMi-core: 7e686fe2 -> d4647013

- 比较: 7e686fe2b46d206fb6fcb11d24d65df8f6f72151 -> d4647013 | ahead=4 | files=11 | Release: —
- 比较链接:https://github.com/Project-HAMi/HAMi-core/compare/7e686fe2b46d206fb6fcb11d24d65df8f6f72151...d4647013f3c0c451274a0dec7ad0af8646ad604c

### AI 总结重点(源码 diff 为据)

- **`cuMemAllocAsync` 的配额记在了错误的设备上(多卡进程下会错配额)**:`add_chunk_async` 原来无条件 `cuCtxGetDevice(&dev)` 取"当前上下文的设备",但 `cuMemAllocAsync` 实际是从 **stream 所属设备的当前内存池** 分配。新增 `async_stream_device()` 三级回退解析 stream 的设备:legacy/per-thread/NULL stream 走 `cuCtxGetDevice`;有 `cuStreamGetDevice` 直接用;否则用 `cuStreamGetCtx_v2`(green stream 返回其设备的 primary context)或 `cuStreamGetCtx` 拿到 owner ctx,与当前 ctx 不同则 `cuCtxPushCurrent_v2` 临时切换再取设备、`cuCtxPopCurrent_v2` 还原;都不支持则返回 `CUDA_ERROR_NOT_SUPPORTED`。解析失败现在**直接返回错误而不是继续按错设备记账**。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
  +/** Resolve the device whose current pool cuMemAllocAsync will use. */
  +static CUresult async_stream_device(CUstream stream, CUdevice *dev) {
  +    if (stream == NULL || stream == CU_STREAM_LEGACY || stream == CU_STREAM_PER_THREAD)
  +        return cuCtxGetDevice(dev);
  +    if (CUDA_FIND_ENTRY(cuda_library_entry, cuStreamGetDevice) != NULL)
  +        return CUDA_OVERRIDE_CALL(cuda_library_entry, cuStreamGetDevice, stream, dev);
  +    res = CUDA_OVERRIDE_CALL(cuda_library_entry, cuCtxPushCurrent_v2, owner);
  +    res = cuCtxGetDevice(dev);
  +    CUresult pop = CUDA_OVERRIDE_CALL(cuda_library_entry, cuCtxPopCurrent_v2, &popped);
   int add_chunk_async(CUdeviceptr *address, size_t size, CUstream hStream) {
  -    CUresult res = CUDA_SUCCESS;
       CUdevice dev;
  -    cuCtxGetDevice(&dev);
  +    CUresult res = async_stream_device(hStream, &dev);
  +    if (res != CUDA_SUCCESS) return res;
  -    /* cuMemAllocAsync draws from the device's default pool. */
  +    /* cuMemAllocAsync draws from the stream device's current pool. */
  ```
  </details>

- **为此新增两个可选 hook 槽位 `cuStreamGetCtx_v2` / `cuStreamGetDevice`,并走"老驱动缺符号允许留空"的白名单**:`hook.c` 的 `load_cuda_libraries` 把 `OVERRIDE_cuStreamGetCtx_v2` 加入"找不到就跳过不报错"的分支(与 `cuGraphAddNode_v2/v3`、`cuGraphExecUpdate_v2` 同列),一致性检查脚本的 `OPTIONAL_DLSYM_SYMBOLS` / `OPTIONAL_WRAPPER_SYMBOLS` 同步放行两个新符号。
  <details><summary>代码依据 src/cuda/hook.c / src/include/libcuda_hook.h / hack/check_cuda_hook_consistency.py</summary>

  ```diff
       {.name = "cuStreamGetCtx"},
  +    {.name = "cuStreamGetCtx_v2"},
  +    {.name = "cuStreamGetDevice"},
  -                if (i == OVERRIDE_cuGraphAddNode_v2 || i == OVERRIDE_cuGraphAddNode_v3 ||
  +                if (i == OVERRIDE_cuStreamGetCtx_v2 ||
  +                    i == OVERRIDE_cuGraphAddNode_v2 || i == OVERRIDE_cuGraphAddNode_v3 ||
  -OPTIONAL_DLSYM_SYMBOLS = {..., "cuStreamGetCtx", "cuGetExportTable", ...}
  +OPTIONAL_DLSYM_SYMBOLS = {..., "cuStreamGetCtx", "cuStreamGetCtx_v2", "cuStreamGetDevice", "cuGetExportTable", ...}
  ```
  </details>

- **删掉 `CUDA_REDIRECT` 与 `vgpulib` 全局句柄**:`initialize_dlsym` 原来会 `dlopen(getenv("CUDA_REDIRECT") ?: "/usr/local/vgpu/libvgpu.so")` 并把句柄存进全局 `void *vgpulib`,但该句柄在代码里从未被 `dlsym` 使用——等于每个被 LD_PRELOAD 的进程白加载一个 so。对外的影响是 `CUDA_REDIRECT` 这个历史环境变量入口消失。
  <details><summary>代码依据 src/libvgpu.c</summary>

  ```diff
  -void *vgpulib;
  -    if (vgpulib == NULL) {
  -        char *path_search = getenv("CUDA_REDIRECT");
  -        if (path_search != NULL && strlen(path_search) > 0) {
  -            vgpulib = dlopen(path_search, RTLD_LAZY);
  -        } else {
  -            vgpulib = dlopen("/usr/local/vgpu/libvgpu.so", RTLD_LAZY);
  -        }
  -    }
  ```
  </details>

### 后续发展方向 [AI]

- **本期两处改动都是"hook 覆盖面的精确化",而不是新增隔离维度**:`async_stream_device` 把 stream→device 的解析补全到 green context / 老驱动两个边角,说明 stream-ordered 内存分配(`cuMemAllocAsync`,vLLM / PyTorch caching allocator 的常用路径)正被当成一等公民对待;上一期的 CUDA Graph 限流也是同一方向。证据只覆盖 `add_chunk_async` 这一条分配路径,未见 `cuMemAllocFromPoolAsync` / 显式 pool(`cuMemPoolCreate`)路径的同类修正。
- **"可选 hook 白名单"正在变长**(本期 +2,上期 +4),意味着 HAMi-core 开始正式承担"同一份 so 跨多代驱动"的兼容负担;配套的 `hack/check_cuda_hook_consistency.py` 已是 CI 级门禁。diff 里没有按驱动版本分支的能力探测框架,仍是"符号存在即用"。

## Project-HAMi/HAMi-WebUI: 43298757 -> 5cc511a1

- 比较: 43298757f33c5e36e39eb1d0e79a84f6c695daa9 -> 5cc511a1 | ahead=17 | files=198 | Release: v1.3.0
- 比较链接:https://github.com/Project-HAMi/HAMi-WebUI/compare/43298757f33c5e36e39eb1d0e79a84f6c695daa9...5cc511a14701da0dd267a49e966367b4d1bddaa0

### AI 总结重点(源码 diff 为据)

- **`/api/v1` 被正式定义成"冻结的只读契约"**:新增 `server/api/v1/resources.proto` 把 11 个读接口收进一个 `Resources` service(`/api/v1/nodes`、`/nodes/{uid}`、`/nodes/{uid}/containers`、`/devices`、`/device`、`/containers`、`/containers/{pod_uid}/{container}`、`/scheduling/pods/{namespace}/{name}`、`/device-config`、`/about`),并新增 16 个 `test/contracts/http-goldens/*.json` 把响应体(含 404 形态 `api-v1-node-not-found.json`)钉成 golden。前端侧 `packages/web/src/api/client.mjs` + `client.d.mts`(537 行类型声明)成为唯一客户端,旧的 `projects/vgpu/api/resources.js`、`deviceConfig.js` 删除、`node.js` 清空 56 行。
  <details><summary>代码依据 server/api/v1/resources.proto / packages/web/package.json 周边</summary>

  ```diff
  +service Resources {
  +  rpc ListNodes (ListNodesRequest) returns (NodesReply) {
  +    option (google.api.http) = { get: "/api/v1/nodes" };
  +  rpc GetNode (GetResourceNodeRequest) returns (NodeReply) {
  +    option (google.api.http) = { get: "/api/v1/nodes/{uid}" };
  +  rpc GetSchedulingPod (GetResourceSchedulingPodRequest) returns (SchedulingPodReply) {
  +    option (google.api.http) = { get: "/api/v1/scheduling/pods/{namespace}/{name}" };
  ```
  </details>

- **新增"命名趋势"接口,刻意不开放任意 PromQL**:`observability/v1/telemetry.proto` 定义 `GET /api/v1/telemetry/trends`,入参只有 `scope`(cluster/node/device/container)+ 实体标识 + `start/end/step`;服务端 `server/internal/telemetry/historical.go`(763 行)用 `buildTrendSpecs` 把 scope 映射到固定的 4 条物理指标(`compute_allocation_percent`、`memory_allocation_percent`、`compute_utilization_percent`、`memory_utilization_percent`)或 2 条容器指标,注释写明"serves bounded, named PromQL trends without exposing arbitrary PromQL to callers"。护栏是硬编码常量:`step ∈ [30s, 6h]`、窗口 ≤ 31 天、点数 ≤ 360(自动步长 ≤ 120 点)、缓存 TTL 15s / 256 条 / 8MiB、并发 fetch ≤ 2。
  <details><summary>代码依据 server/api/observability/v1/telemetry.proto / server/internal/telemetry/historical.go</summary>

  ```diff
  +service Telemetry {
  +  rpc GetTrends (TrendsRequest) returns (TrendsReply) {
  +    option (google.api.http) = { get: "/api/v1/telemetry/trends" };
  +  // Optional Go duration string (e.g. "60s", "5m"). Allowed range is [30s, 6h].
  +  string step = 10;
  +	minTrendStep   = 30 * time.Second
  +	maxTrendStep   = 6 * time.Hour
  +	maxTrendWindow = 31 * 24 * time.Hour
  +	maxTrendPoints = 360
  +	defaultMaxCacheBytes        = 8 << 20
  +	defaultMaxConcurrentFetches = 2
  +// HistoricalObservationReader serves bounded, named PromQL trends from historical
  +// Prometheus metrics without exposing arbitrary PromQL to callers.
  ```
  </details>

- **趋势查询的 PromQL 里内置了"多源互证"逻辑**:`buildPhysicalTrendSpecs` 对每个指标先做 `agreed()`(同一 `(device_id,node,provider)` 上 `min == max`,即多个 exporter 口径一致才采信)与 `singleSource()`(该组只有一个 `source` 标签)过滤,再用 `pairedPercent()` 要求分子分母成对出现才算百分比;算力口径额外要求 `compute_unknown_occupancies == 0` 且 `configured="true"`。容器口径则用 `hami_container_vgpu_allocated > 0` 作为资格门,并用 `count(...) == count(...)` 保证"样本覆盖了全部已分配设备"才出点。
  <details><summary>代码依据 server/internal/telemetry/historical.go</summary>

  ```diff
  +	agreed := func(series string) string {
  +		return fmt.Sprintf("(min by (%s) (%s) == max by (%s) (%s))", groupLabels, series, groupLabels, series)
  +	}
  +	singleSource := func(series string) string {
  +		sources := fmt.Sprintf("group by (%s, source) (%s)", groupLabels, series)
  +		return fmt.Sprintf("(count by (%s) (%s) == 1)", groupLabels, sources)
  +	computeElig := fmt.Sprintf("(%s == 0) and ignoring (configured, mode, resource, device_no, driver_version) %s and %s (%s == 0)",
  +		unknownOcc, configured, deviceMatch, agreed(unknownOcc))
  ```
  </details>

- **Prometheus 客户端加了熔断 + 响应体字节上限 + 并发闸,并把"查询用的 client"与"连接/靶点用的 client"拆开**:新增 `ErrResponseTooLarge` / `ErrCircuitOpen`,默认 `maxConcurrentQueries=4`、`maxQueryResponseBytes=8MiB`、`circuitFailureThreshold=3`、`cooldown=15s`(closed/open/half-open 三态);`responseLimitRoundTripper` 既查 `Content-Length` 也用 `limitedReadCloser` 兜住分块响应;字节限制只套在 `queryClient` 上,`Conn()` 与流式 `WalkActiveTargets` 仍用未包装的 client。
  <details><summary>代码依据 server/internal/data/prom/client.go</summary>

  ```diff
  +	ErrResponseTooLarge = errors.New("prometheus query response exceeded size limit")
  +	ErrCircuitOpen = errors.New("prometheus circuit breaker is open")
  +	defaultMaxConcurrentQueries    = 4
  +	defaultMaxQueryResponseBytes   int64 = 8 << 20
  +	defaultCircuitFailureThreshold = 3
  +	defaultCircuitCooldown         = 15 * time.Second
  +	if t.limit > 0 {
  +		if resp.ContentLength > t.limit {
  +			_ = resp.Body.Close()
  +			return nil, ErrResponseTooLarge
  +	// Keep the unwrapped client for Conn() and streaming WalkActiveTargets, and apply
  +	// the query response size limit only to PromQL query calls through queryClient.
  ```
  </details>

- **exporter 的遥测批查询改成"按失败原因自适应二分"**:`telemetryBatch` 从"一批固定 ids + filter"重构为 `groups []telemetryKeyGroup`(延迟到 `buildBatchSpec` 才拼 selector),批内新增 20000 series 上限 `telemetryMaxBatchSeries` 与 3s 的 `telemetryBatchTimeout`;`batchSplitReason` 只对 `ErrResponseTooLarge` / `errTelemetrySeriesLimit` / `DeadlineExceeded` 三类原因拆批,**对 `ErrCircuitOpen` 和父 ctx 取消明确不拆**(拆了只会加剧上游压力),且批规模降到 `telemetryFallbackIDsPerQuery=16` 就不再拆。
  <details><summary>代码依据 server/internal/exporter/resource_telemetry.go</summary>

  ```diff
  -const telemetryIDsPerQuery = 64
  +	telemetryIDsPerQuery         = 64
  +	telemetryFallbackIDsPerQuery = 16
  +	telemetryMaxBatchSeries      = 20_000
  +	telemetryBatchTimeout        = 3 * time.Second
  +			seriesCount++
  +			if seriesCount > telemetryMaxBatchSeries {
  +				return nil, fmt.Errorf("%w: %w", errTelemetryQuery, errTelemetrySeriesLimit)
  +	if err == nil || len(groups) <= telemetryFallbackIDsPerQuery || parentCtx.Err() != nil || errors.Is(err, prom.ErrCircuitOpen) {
  +		return 0, false
  ```
  </details>

- **WebUI 开始上报自身的健康度(self-observability),并给指标描述符加了 golden**:新增 `server/internal/exporter/self_observability.go` 暴露 `hami_webui_prom_queries_total{outcome=ok|error|circuit_open|response_too_large|canceled}`、`hami_webui_prom_circuit_breaker_opens_total`、`hami_webui_prom_circuit_breaker_open`、`hami_webui_telemetry_batch_splits_total{reason=response_too_large|series_limit|timeout}`、`hami_webui_telemetry_observations{state=...}`;新增 `test/contracts/metrics-goldens/descriptors.json`(564 行)把所有指标描述符冻住,配 `metrics_golden_test.go`。
  <details><summary>代码依据 server/internal/exporter/self_observability.go</summary>

  ```diff
  +	promQueryOutcomes = []string{"ok", "error", "circuit_open", "response_too_large", "canceled"}
  +	batchSplitReasons = [...]string{
  +		splitReasonOverflow:    "response_too_large",
  +		splitReasonSeriesLimit: "series_limit",
  +		splitReasonTimeout:     "timeout",
  +		promQueries: prometheus.NewDesc("hami_webui_prom_queries_total", ...),
  +		breakerOpen: prometheus.NewDesc("hami_webui_prom_circuit_breaker_open", ...),
  +		batchSplits: prometheus.NewDesc("hami_webui_telemetry_batch_splits_total", ...),
  ```
  </details>

- **前端完成单栈化并按路由重排目录**:`package.json` 一次性移除 element-plus / @element-plus/icons-vue / bootstrap / @tabler/core / @tabler/icons-vue / sortablejs / tom-select / vuedraggable / vue-clipboard3 / vue-count-to / animate.css / core-js / generate-avatar,`tdesign-vue-next` 由 `^1.18.5` 钉成 `1.18.5`;视图目录 `views/monitor/overview` → `views/overview`、`views/node/admin` → `views/nodes`、`views/card` → `views/accelerators`(21 个文件 renamed),新增 `src/hooks/useTelemetryTrends.mjs` 让各视图统一消费 trends 接口。
  <details><summary>代码依据 packages/web/package.json</summary>

  ```diff
  -    "@element-plus/icons-vue": "^2.1.0",
  -    "@tabler/core": "1.0.0-beta20",
  -    "bootstrap": "5.3.1",
  -    "element-plus": "^2.4.1",
  -    "sortablejs": "^1.15.2",
  -    "tom-select": "2.2.2",
  -    "tdesign-vue-next": "^1.18.5",
  +    "tdesign-vue-next": "1.18.5",
  -    "vuedraggable": "^4.1.0"
  ```
  </details>

### 后续发展方向 [AI]

- **WebUI 正在从"Grafana 风格的面板拼装器"转成"有契约的产品级后端"**:proto 冻结 + HTTP golden + 指标描述符 golden + 类型化 JS 客户端,四件套一起落,意味着后续厂商接入(昨天的 Inventory/Allocation/Telemetry Dialect)要通过固定契约出数,而不是各视图自己拼 PromQL。证据覆盖到 `/api/v1` 的 11 个读接口 + trends,未见任何写接口(配置下发/配额编辑)进入契约。
- **"不开放任意 PromQL"是一条明确的产品决策**:`HistoricalObservationReader` 的命名趋势 + 硬上限 + 熔断 + 自适应拆批,整体是在把 Prometheus 当成一个**不可信的、会被打爆的下游**来治理。对自家产品的启示是:如果我们也把 vGPU 可观测性直连 Prometheus 开放给用户,`step/窗口/点数/响应体字节/并发` 这五个闸和"多源互证(`agreed`/`singleSource`)"的口径仲裁都得自己补——HAMi-WebUI 这一版给出了可直接对标的参数量级(30s~6h / ≤31d / ≤360 点 / 8MiB / 并发 2)。
- 证据边界:本期 198 文件里约一半是测试与 golden,我只读了 proto、`historical.go`、`prom/client.go`、`resource_telemetry.go`、`self_observability.go`、`package.json` 的 hunk,未逐一展开 21 个 renamed Vue 视图与 `web-entry.browser.test.mjs`(629 行改动)。

## 本期无实质改动(折叠)

- `Project-HAMi/volcano-vgpu-device-plugin`:无新提交(仍在 `4781e41d`,Release `volcano-vgpu-device-plugin-1.13.0`)
- `Project-HAMi/ascend-device-plugin`:无新提交(仍在 `9325759b`,Release `ascend-device-plugin-0.2.2`)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)

<!-- ANCHOR repo=Project-HAMi/HAMi sha=5eba23f5680deb0703c1bcbb5cea2d365ac90631 branch=master release=v2.11.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=d4647013f3c0c451274a0dec7ad0af8646ad604c branch=main release=— scanned=2026-11-28 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=4781e41df9edac3c30e882a5183409601643c644 branch=main release=volcano-vgpu-device-plugin-1.13.0 scanned=2026-11-28 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=9325759b9d297302908e91e17d81a2676ffd7a6f branch=main release=ascend-device-plugin-0.2.2 scanned=2026-11-28 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=5cc511a14701da0dd267a49e966367b4d1bddaa0 branch=main release=v1.3.0 scanned=2026-11-28 -->
