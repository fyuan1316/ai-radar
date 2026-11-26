# NVIDIA 算力栈 diff 雷达 2026-11-27

## 摘要
- **gpu-operator 修掉了一个会让 sandbox 节点被错标成 container 工作负载的竞态。** `ClusterPolicy.spec.sandboxWorkloads.defaultWorkload` 过去是在 `ClusterPolicyController.init()` 里写进包级变量 `defaultGPUWorkloadConfig`,node-labeling 控制器再去读这个全局量;现在改成纯函数 `getDefaultWorkloadConfig(&cp.Spec.SandboxWorkloads)` 按调用现场从 CR 算。全局变量被删除,`vfio-pci` / `vgpu-manager` / `vgpu-devices` 三个 validator 的 `DEFAULT_GPU_WORKLOAD_CONFIG` 环境变量也改为现算。
- **驱动容器的 startup probe 从"`nvidia-smi` 成功即就绪"收紧到"控制设备节点必须存在"。** probe 脚本新增 `mkdir -p /dev/char` 硬失败,并在 `nvidia-smi` 成功之后再逐个校验 `/dev/nvidiactl`、`/dev/nvidia-uvm`、`/dev/nvidia-uvm-tools` 是字符设备,缺一个就判驱动未就绪。注释写明动机:`nvidia-smi` 成功也可能留下缺失的控制设备。
- **k8s-device-plugin 把 `NVIDIA_VISIBLE_DEVICES` 提到 chart values。** 新增 `devicePlugin.nvidiaVisibleDevices` 与 `mps.nvidiaVisibleDevices`(默认 `all`,schema 限定 string|null)。PR 自述动机是 MIG 发现权限问题(k8s-device-plugin#1683、nvidia-container-toolkit#1740)的现行 workaround 需要改这个环境变量,过去只能靠 kustomize/post-renderer。KAI 侧则是两个稳定性修复(BindRequest 状态写失败重试、snapshot 端点与插件注册的并发安全),外加依赖 `kai-scheduler/api` 升到 v0.3.0 带来的 GPU 共享注解校验放宽。

## 当日重要改变
- `NVIDIA/k8s-device-plugin` **[新能力·chart 配置面]** 新增两个 chart values(`devicePlugin.nvidiaVisibleDevices`、`mps.nvidiaVisibleDevices`),把原先模板里硬编码的 `NVIDIA_VISIBLE_DEVICES: all` 变成可配置项,并在 `values.schema.json` 里限定类型为 string|null(bool/number/list 被 schema 拒绝)。注意升级陷阱:`null` 和空串都渲染成 `all`,所以 `helm upgrade --reuse-values` 下要清除旧覆盖必须显式写 `all`,写 `null` 时 Helm 会保留旧值。 https://github.com/NVIDIA/k8s-device-plugin/pull/1935
- `kai-scheduler/KAI-Scheduler` **[API/CRD变更·注解契约]** 依赖的 `github.com/kai-scheduler/api` 从 v0.2.2 升到 v0.3.0,其中 `ValidateGPUFractionRequest` 的准入校验从"NvFractions limit 不能与 `gpu-fraction` 或 `gpu-memory` 同时出现"拆成两条带例外的规则:设置了 `gpu-memory.portion.limit` 时允许 `gpu-fraction` + NvFractions limit 共存(binder 在 bind 时从前者推导后者)。这不是 CRD schema 改动,是 Pod 注解层的用户可见 API。 https://github.com/kai-scheduler/KAI-Scheduler/commit/8d110364 / https://github.com/kai-scheduler/api/pull/28
- `[弃用/移除]` 本期命中的只有 gpu-operator 删除包级变量 `defaultGPUWorkloadConfig`(内部符号,非 CRD 字段/flag,不构成对外弃用)。
- `[版本跨档]` 未命中:9 仓 Release 与上期全同。KAI releases 列表最大 semver 仍是 v0.19.0(2026-11-11),helper 报的 v0.18.9 是 0.18 分支 backport。
- `[架构方向]` 未命中:无 `docs/proposals` / `/design/` 改动,无新增顶层 package。本期也没有改动 `api/nvidia/v1/clusterpolicy_types.go`,无 ClusterPolicy 字段增删。

## NVIDIA/gpu-operator: f6acfb9e -> 877c9860
- 比较: f6acfb9ee0ab4a041ff1a035ebb851d306583327 -> 877c9860 | ahead=4 | files=26 | Release: v26.7.3
- compare: https://github.com/NVIDIA/gpu-operator/compare/f6acfb9ee0ab4a041ff1a035ebb851d306583327...877c98604aa7e9d88bf5b805307172acdf73548e
- 提交(已用 compare API 核对全量标题,无被 `Bump ` 前缀过滤掉的实质提交):
  - https://github.com/NVIDIA/gpu-operator/commit/98d4eef3 Use ClusterPolicy defaultWorkload when labeling sandbox nodes(PR https://github.com/NVIDIA/gpu-operator/pull/3159)
  - https://github.com/NVIDIA/gpu-operator/commit/45deccb0 [fix]: Validate device nodes in driver startup probe(PR https://github.com/NVIDIA/gpu-operator/pull/3285)

### AI 总结重点(源码 diff 为据)
- **`defaultWorkload` 从"进程级全局状态"变成"按 CR 现算"。** 包级 `var defaultGPUWorkloadConfig = gpuWorkloadConfigContainer` 被删除,新增 `getDefaultWorkloadConfig(sandboxWorkloads *gpuv1.SandboxWorkloadsSpec) string`:sandbox 启用且 `DefaultWorkload` 合法时返回该值,否则返回 `container`。`getWorkloadConfig` 的签名也从 `(labels, sandboxEnabled)` 变为 `(labels, sandboxEnabled, defaultWorkloadConfig string)`,默认值由调用方传入。行为差异:修复前 `init()` 只在 sandbox 启用时才会把全局量改写成 CR 里的 `defaultWorkload`,node-labeling 控制器若在此之前(或与之并发)跑,读到的仍是 `container`,于是没有 `nvidia.com/gpu.workload.config` 标签的 sandbox 节点会被按 container 工作负载打上 state 标签;修复后每次标注都从 `cp.Spec.SandboxWorkloads` 现读,不存在时序窗口。
  <details><summary>代码依据 controllers/state_manager.go</summary>

  ```diff
   var (
  -	defaultGPUWorkloadConfig = gpuWorkloadConfigContainer
  -	podSecurityModes         = []string{"enforce", "audit", "warn"}
  +	podSecurityModes = []string{"enforce", "audit", "warn"}
   )
  +func getDefaultWorkloadConfig(sandboxWorkloads *gpuv1.SandboxWorkloadsSpec) string {
  +	if sandboxWorkloads.IsEnabled() && isValidWorkloadConfig(sandboxWorkloads.DefaultWorkload) {
  +		return sandboxWorkloads.DefaultWorkload
  +	}
  +	return gpuWorkloadConfigContainer
  +}
  -func getWorkloadConfig(labels map[string]string, sandboxEnabled bool) (string, error) {
  +func getWorkloadConfig(labels map[string]string, sandboxEnabled bool, defaultWorkloadConfig string) (string, error) {
  ```
  </details>
  <details><summary>代码依据 controllers/state_manager.go(init 不再写全局量)</summary>

  ```diff
  -	if clusterPolicy.Spec.SandboxWorkloads.IsEnabled() {
  -		n.sandboxEnabled = true
  -		defaultWorkload := clusterPolicy.Spec.SandboxWorkloads.DefaultWorkload
  -		if isValidWorkloadConfig(defaultWorkload) {
  -			n.logger.Info("Default GPU workload is overridden in ClusterPolicy", "DefaultWorkload", defaultWorkload)
  -			defaultGPUWorkloadConfig = defaultWorkload
  -		}
  -	} else {
  -		n.sandboxEnabled = false
  +	n.sandboxEnabled = clusterPolicy.Spec.SandboxWorkloads.IsEnabled()
  +	if n.sandboxEnabled && isValidWorkloadConfig(clusterPolicy.Spec.SandboxWorkloads.DefaultWorkload) {
  +		n.logger.Info("Default GPU workload is overridden in ClusterPolicy", "DefaultWorkload", clusterPolicy.Spec.SandboxWorkloads.DefaultWorkload)
   	}
  ```
  </details>
- **节点标签变更探测改为直接比较原始标签,不再比较"解析后的 workload config"。** `getNodeLabelUpdateReasons` 和 `addWatchNewGPUNode` 里的 `gpuWorkloadConfigChanged` 从 `getWorkloadConfig(oldLabels, true) != getWorkloadConfig(newLabels, true)` 改成 `oldLabels[gpuWorkloadConfigLabelKey] != newLabels[gpuWorkloadConfigLabelKey]`。差异:旧写法会把"标签被删除"和"标签值非法"都折叠成同一个默认值,因而漏判变更(两边都解析成默认值时判为未变);新写法逐字比较标签,新增用例 "GPU workload config label added"(old 为空 map、new 带 `vm-passthrough`)断言 `gpuWorkloadConfigChanged` 为真。副作用是去掉了对全局默认值的依赖,正是上一条竞态修复的前置。
  <details><summary>代码依据 controllers/nodelabeling_controller.go</summary>

  ```diff
  -	oldGPUWorkloadConfig, _ := getWorkloadConfig(oldLabels, true)
  -	newGPUWorkloadConfig, _ := getWorkloadConfig(newLabels, true)
  -
   	reasons := nodeLabelUpdateReasons{
  -		gpuWorkloadConfigChanged:     oldGPUWorkloadConfig != newGPUWorkloadConfig,
  +		gpuWorkloadConfigChanged:     oldLabels[gpuWorkloadConfigLabelKey] != newLabels[gpuWorkloadConfigLabelKey],
  ```
  </details>
  <details><summary>代码依据 controllers/nodelabeling_controller.go(sandbox 关闭时不再查 workload config)</summary>

  ```diff
  -	if cp != nil {
  +	workloadConfig := gpuWorkloadConfigContainer
  +	if sandboxEnabled {
   		sandboxMode = cp.Spec.SandboxWorkloads.Mode
  +		defaultWorkloadConfig := getDefaultWorkloadConfig(&cp.Spec.SandboxWorkloads)
  +		workloadConfig, err = getWorkloadConfig(labels, sandboxEnabled, defaultWorkloadConfig)
   	}
  -	config, err := getWorkloadConfig(labels, sandboxEnabled)
  ```
  </details>
- **driver startup probe 增加两道设备节点闸门。** `assets/state-driver/0400_configmap.yaml` 与 `manifests/state-driver/0400_configmap.yaml` 的 `startup-probe.sh` 同步改:(1) `mkdir -p /dev/char` 失败即 `exit 1`(该目录是 CDI 符号链接的落点);(2) `nvidia-smi` 成功**之后**再遍历 `/dev/nvidiactl`、`/dev/nvidia-uvm`、`/dev/nvidia-uvm-tools`,任一不是字符设备(`[ ! -c ]`)就报 `NVIDIA driver is not ready: missing character device` 并失败。行为差异:修复前 `nvidia-smi` 返回 0 即视为驱动就绪,控制设备缺失的半就绪状态会放过去,下游 operand(toolkit / device-plugin / validator)随后才失败;现在驱动容器自身不会进入 ready。新增的 `internal/state/driver_startup_probe_test.go` 从 YAML 里切出脚本在 tmpdir 内执行,覆盖 "missing control device"、"missing UVM device"、"regular file"(普通文件冒充设备也要判失败)等 9 个场景。
  <details><summary>代码依据 assets/state-driver/0400_configmap.yaml、manifests/state-driver/0400_configmap.yaml</summary>

  ```diff
  +    if ! mkdir -p /dev/char; then
  +      echo "Failed to create /dev/char"
  +      exit 1
  +    fi
  +
       if ! nvidia-smi; then
         echo "nvidia-smi failed"
         exit 1
       fi

  +    # A successful nvidia-smi can leave required control devices missing.
  +    for device_node in /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
  +      if [ ! -c "$device_node" ]; then
  +        echo "NVIDIA driver is not ready: missing character device $device_node"
  +        exit 1
  +      fi
  +    done
  ```
  </details>

### 后续发展方向 [AI]
- sandbox 工作负载(KubeVirt / Kata 直通)这条线在被逐步去全局状态化:本期把 `defaultWorkload` 的读取从进程级变量改成按 CR 现算,`gpuWorkloadConfigChanged` 也不再经过解析层。按这个方向,下一步可预期的是 `n.sandboxEnabled` 这类挂在 `ClusterPolicyController` 上的缓存字段继续内联。证据只覆盖 `state_manager.go` / `nodelabeling_controller.go` / `clusterpolicy_controller.go` 三个文件的本次 diff,未见 ClusterPolicy CRD 字段层面的配套改动。
- 驱动就绪判定正在从"工具命令成功"转向"设备节点存在性"。本次校验的是 `nvidiactl` / `nvidia-uvm` / `nvidia-uvm-tools` 三个控制设备,尚未覆盖 per-GPU 的 `/dev/nvidia{N}` 和 `/dev/char` 下的符号链接完整性;probe 测试已经把脚本做成可单测的形状,说明后续加闸门的成本已降低。证据只覆盖 configmap 里的 probe 脚本,未看 operator 侧 readiness 判定链路。

## NVIDIA/k8s-device-plugin: a46c3947 -> c22b0c89
- 比较: a46c39473c5d6c4807bd91ccef86a6998fdaf58a -> c22b0c89 | ahead=2 | files=7 | Release: v0.20.2
- compare: https://github.com/NVIDIA/k8s-device-plugin/compare/a46c39473c5d6c4807bd91ccef86a6998fdaf58a...c22b0c894ebfdb779b6285ee980377032f28de3c
- 提交(已用 compare API 核对全量标题):
  - https://github.com/NVIDIA/k8s-device-plugin/commit/2471245c Allow setting NVIDIA_VISIBLE_DEVICES through the helm chart(PR https://github.com/NVIDIA/k8s-device-plugin/pull/1935)

### AI 总结重点(源码 diff 为据)
- **device-plugin 容器和 MPS control daemon 容器的 `NVIDIA_VISIBLE_DEVICES` 从硬编码 `all` 变为 chart 可配。** 两个 DaemonSet 模板的 env 值从字面量 `all` 改为 `{{ .Values.<component>.nvidiaVisibleDevices | default "all" | quote }}`;`values.yaml` 为 `devicePlugin` 和 `mps` 各加一个 `nvidiaVisibleDevices: "all"`;`values.schema.json` 在两处把类型限定为 `["string","null"]`。模板里走 `default`,所以 `null` 与空串都落回 `all`,而 bool/number/list 会被 schema 直接拒(新测试 `TestDaemonsetNvidiaVisibleDevices` 用 `expectSchemaRejection` 覆盖 `true` / `1` / `["0","1"]` 三种)。按 PR 自述,这是为 MIG 发现的权限问题(`MIG_STRATEGY=single` 下 `error getting parent memory info: Insufficient Permissions`,k8s-device-plugin#1683;非特权 `MIG_STRATEGY=mixed` 缺 `nvidia-cap1`/`nvidia-cap2` cgroup 访问,nvidia-container-toolkit#1740)的现行 workaround 提供官方入口,此前运维只能靠 kustomization 或 helm post-renderer 改这个 env。
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/templates/daemonset-device-plugin.yml、daemonset-mps-control-daemon.yml</summary>

  ```diff
             - name: NVIDIA_VISIBLE_DEVICES
  -            value: all
  +            value: {{ .Values.devicePlugin.nvidiaVisibleDevices | default "all" | quote }}
  ```
  ```diff
             - name: NVIDIA_VISIBLE_DEVICES
  -            value: all
  +            value: {{ .Values.mps.nvidiaVisibleDevices | default "all" | quote }}
  ```
  </details>
  <details><summary>代码依据 deployments/helm/nvidia-device-plugin/values.yaml</summary>

  ```diff
  +  # nvidiaVisibleDevices sets NVIDIA_VISIBLE_DEVICES on the device plugin
  +  # container. A null or empty value falls back to "all", so set "all" to
  +  # clear an override on upgrades that use --reuse-values.
  +  # @schema type:[string, null]
  +  nvidiaVisibleDevices: "all"
  ```
  </details>
- **`--reuse-values` 升级语义被单独测试锁住。** `TestReuseValuesUpgradeWithNullValue` 的 null 路径清单里加入 `devicePlugin.nvidiaVisibleDevices` 和 `mps.nvidiaVisibleDevices`,另有新测试 `TestReuseValuesUpgradeNvidiaVisibleDevices` 覆盖三种升级路径:从不含该 value 的旧 chart 升级(渲染 `all`)、覆盖值被保留(`void`)、用 `all` 显式清除覆盖。这与 README 新增小节的说法一致——写 `null` 时 Helm 会沿用旧值,想清除必须写 `all`。
  <details><summary>代码依据 tests/helm/helm_upgrade_test.go</summary>

  ```diff
   		{nullValuePath: "devicePlugin.enabled"},
  +		{nullValuePath: "devicePlugin.nvidiaVisibleDevices"},
   		{nullValuePath: "mps.enableHostPID"},
  +		{nullValuePath: "mps.nvidiaVisibleDevices"},
  +	testCases := []struct {
  +		installChartWithoutValue  bool
  +		expectedVisibleDevicesEnv []v1.EnvVar
  +	}{
  +		{description: "upgrade from a chart without the value", installChartWithoutValue: true,
  +			expectedVisibleDevicesEnv: []v1.EnvVar{{Name: "NVIDIA_VISIBLE_DEVICES", Value: "all"}}},
  +		{description: "override is kept", installValue: ptr("void"),
  +			expectedVisibleDevicesEnv: []v1.EnvVar{{Name: "NVIDIA_VISIBLE_DEVICES", Value: "void"}}},
  +		{description: "override is cleared with all", installValue: ptr("void"), upgradeValue: ptr("all"),
  +			expectedVisibleDevicesEnv: []v1.EnvVar{{Name: "NVIDIA_VISIBLE_DEVICES", Value: "all"}}},
  ```
  </details>
  (hunk 截断,两个测试文件各只看到前 80 行,未覆盖断言主体全部分支)

### 后续发展方向 [AI]
- 经典 device-plugin 这条线本期没有能力演进,只是把"MIG 发现需要更宽的设备可见性"这个长期 workaround 固化进 chart。这反过来说明 MIG mixed 模式在非特权部署下的权限模型仍未从根上解决(两个 issue 都是靠放宽 `NVIDIA_VISIBLE_DEVICES` 绕过),而 DRA 路径下设备可见性由 ResourceClaim 决定、不走这个 env。证据只覆盖本次 chart diff 和两个被引用 issue 的标题/描述,未展开 toolkit 侧 cgroup 注入代码。

## kai-scheduler/KAI-Scheduler: 8e0d52c2 -> 523b3329
- 比较: 8e0d52c26a117f3f4212a80a15cc82a10b1c1ea1 -> 523b3329 | ahead=4 | files=13 | Release: v0.18.9(0.18 分支 backport;releases 最大 semver 仍为 v0.19.0,不算跨档)
- compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/8e0d52c26a117f3f4212a80a15cc82a10b1c1ea1...523b33294d2fbec6467a12f79a32c72a323d78f2
- 提交(已用 compare API 核对全量标题;helper 的实质提交过滤吞掉了下面第 3 条 `chore(deps)`,但它带来对外注解语义变化,故补入):
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/1a90ac9b fix(binder): retry failed BindRequest status writes (#2418)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/523b3329 fix(scheduler): serve consistent snapshots and stop plugin server races (#2789)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/8d110364 chore(deps): bump kai-scheduler/api to v0.3.0 (#2777)
  - https://github.com/kai-scheduler/KAI-Scheduler/commit/4ab1c3cc chore(deps): bump amannn/action-semantic-pull-request(纯 CI)

### AI 总结重点(源码 diff 为据)
- **BindRequest 状态写入失败不再被静默吞掉,且脏判定从"只看 Phase"扩展到整个 Status。** `UpdateStatus` 里的提前返回条件从 `originalBindRequest.Status.Phase == bindRequest.Status.Phase` 改为 `reflect.DeepEqual(originalBindRequest.Status, bindRequest.Status)`,因此 Phase 不变但失败计数/原因变化时也会落盘;`patch` 失败处原来只记日志后继续,现在 `return ctrl.Result{}, patchErr` 把错误交回 controller-runtime 触发重试。配套 changelog 描述为 "Persist consecutive BindRequest failure counts and reasons and retry failed status writes"。行为差异:绑定反复失败时,连续失败次数与原因此前可能因 Phase 未变而丢失,`BackoffLimit` 的计数基础不可靠。
  <details><summary>代码依据 pkg/binder/controllers/bindrequest_controller.go</summary>

  ```diff
  -	if originalBindRequest.Status.Phase == bindRequest.Status.Phase {
  +	if reflect.DeepEqual(originalBindRequest.Status, bindRequest.Status) {
   		return result, nil
   	}
   		logger.Error(patchErr, "Failed to patch status for BindRequest",
   			"Namespace", bindRequest.Namespace, "Name", bindRequest.Name)
  +		return ctrl.Result{}, patchErr
  ```
  </details>
  <details><summary>代码依据 .changes/unreleased/fixed-20261013-204811.yaml</summary>

  ```diff
  +kind: Fixed
  +body: |-
  +  Persist consecutive BindRequest failure counts and reasons and retry failed status writes
  +custom:
  +  Author: "NVGreg"
  +  Issue: "2418"
  ```
  </details>
- **`/get-snapshot` 改为"先全量 List 再开始写响应",lister 出错直接返 500 而不是写出半截 JSON。** 新增 `listRawObjects() (jsonFieldWriter, error)`,在 HTTP 响应头写出之前把 pods/nodes/queues/podGroups/bindRequests/resourceClaims/resourceSlices/deviceClasses/topologies/nodeResourceTopologies 等 17 类对象一次性 List 完;`listedSliceField` 的签名从 `(fieldName, list, errorMessage string)` 改为 `(fieldName, list, listErr *error)`,出错时把错误写进共享的 `*error` 并跳过后续 lister,不再像旧 `writeListedSlice` 那样"记日志 + 用空切片 `[]T{}` 顶替"。行为差异:以前某个 kind List 失败,快照里那个字段会是空数组,使用者无法区分"真的没有对象"和"取数失败";现在整个请求以 500 失败。注释给出的第二个动机是让各 kind 的 List 背靠背发生,而不是夹在 encode 之间,从而降低快照内部不一致。
  <details><summary>代码依据 pkg/scheduler/plugins/snapshot/snapshot.go</summary>

  ```diff
   func (sp *snapshotPlugin) serveSnapshot(writer http.ResponseWriter, request *http.Request) {
  +	rawObjects, err := sp.listRawObjects()
  +	if err != nil {
  +		log.InfraLogger.Errorf("Error listing snapshot objects: %v", err)
  +		http.Error(writer, err.Error(), http.StatusInternalServerError)
  +		return
  +	}
   	writer.Header().Set("Content-Disposition", "attachment; filename=snapshot.zip")
  -func listedSliceField[T any](fieldName string, list func() ([]T, error), errorMessage string) jsonFieldWriter {
  -	return func(object *jsonObjectWriter) error {
  -		return writeListedSlice(object, fieldName, list, errorMessage)
  +func listedSliceField[T any](fieldName string, list func() ([]T, error), listErr *error) jsonFieldWriter {
  +	if *listErr != nil {
  +		return nil
   	}
  +	values, err := list()
  +	if err != nil {
  +		*listErr = fmt.Errorf("listing %s: %w", fieldName, err)
  +	}
  +	return sliceField(fieldName, values)
   }
  -func writeListedSlice[T any](object *jsonObjectWriter, fieldName string, list func() ([]T, error), errorMessage string) error {
  -	values, err := list()
  -	if err != nil {
  -		log.InfraLogger.Errorf("%s: %v", errorMessage, err)
  -		values = []T{}
  -	}
  -	return writeSliceField(object, fieldName, values)
  -}
  ```
  </details>
- **插件 HTTP 服务端的注册表加了读写锁,端口绑定失败不再无声。** `PluginServer` 新增 `mu sync.RWMutex`:`registerPlugin` 写锁保护 `registeredPlugins` 赋值(注释写明"每个 session 都会重新注册 handler,而此时服务端正在处理请求"),`handlePlugin` 用读锁只在查表时持有、serve 之前释放(注释:慢 handler 不能挡住下一个 session 的注册)。同时 `cmd/scheduler/app/server.go` 把 `_ = http.ListenAndServe(...)` 改为 `glog.Errorf("Plugin Http Server failed %s", http.ListenAndServe(...))`。changelog 自述影响面是"插件端点不再让调度器崩溃或提供不完整快照"——即此前每轮 session 重新注册 map 与并发读取构成 Go map 并发读写,可直接 fatal。
  <details><summary>代码依据 pkg/scheduler/framework/server.go</summary>

  ```diff
   type PluginServer struct {
  +	mu                sync.RWMutex
   	registeredPlugins map[string]func(http.ResponseWriter, *http.Request)
  +	// Handlers are re-registered on every session while the server is handling requests.
  +	ps.mu.Lock()
  +	defer ps.mu.Unlock()
   	ps.registeredPlugins[path] = handler
  +	// Unlock before serving: a slow handler must not block the next session's registration.
  +	ps.mu.RLock()
   	handler, ok := ps.registeredPlugins[path]
  +	ps.mu.RUnlock()
  ```
  </details>
  <details><summary>代码依据 cmd/scheduler/app/server.go</summary>

  ```diff
  -		_ = http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", so.PluginServerPort), mux)
  +		glog.Errorf("Plugin Http Server failed %s", http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", so.PluginServerPort), mux))
  ```
  </details>
- **discovery 快照在 `ServerGroupsAndResources` 报错时保留部分结果。** 原来出错后执行 `discoverySnapshot.Resources = nil` 丢弃一切,现在删掉这行,只记 V(2) 警告,注释说明该 API 会在返回错误的同时给出部分结果。
  <details><summary>代码依据 pkg/scheduler/plugins/snapshot/snapshot.go</summary>

  ```diff
   	_, discoverySnapshot.Resources, err = discoveryClient.ServerGroupsAndResources()
   	if err != nil {
  +		// ServerGroupsAndResources returns partial results along with the error, so they're kept.
   		log.InfraLogger.V(2).Warnf("Failed to snapshot server resources: %v", err)
  -		discoverySnapshot.Resources = nil
   	}
  ```
  </details>
- **GPU 共享注解的准入校验放宽一档(来自 `kai-scheduler/api` v0.2.2→v0.3.0)。** 本仓只改了 `pkg/admission/webhook/v1alpha2/gpusharing/gpu_sharing_test.go` 里的期望错误串,真实逻辑在依赖模块的 `utilities/resources/gpu_sharing_validation.go`:原来一条规则"NvFractions limit 不能与 `gpu-fraction` 或 `gpu-memory` 同时出现",现在拆成两条并各带例外——`gpu-fraction` 与 NvFractions limit 共存时,只要通过 `ExtractGpuMemoryPortionLimitAnnotation` 取到 `gpu-memory.portion.limit` 即放行(注释:binder 在 bind 时从该注解推导 NvFractions limit);`gpu-memory` 与 NvFractions limit 共存时,只要设置了 `constants.GpuMemoryLimit` 简写注解即放行。对使用方的影响:同时写 `gpu-fraction` 请求和内存占比上限的 Pod 不再被 webhook 拒。
  <details><summary>代码依据 kai-scheduler/api utilities/resources/gpu_sharing_validation.go(v0.2.2...v0.3.0)</summary>

  ```diff
  -	if req.Limit != nil && (hasLegacyFraction || (hasLegacyMemory && !hasMemoryLimitShorthand)) {
  -		return fmt.Errorf("cannot combine %s limit annotation with %s or %s annotation",
  -			constants.NvFractionsAnnotationPrefix, constants.GpuFraction, constants.GpuMemory)
  +	// A legacy gpu-fraction request may accompany the NvFractions limit the binder
  +	// derives from gpu-memory.portion.limit at bind time.
  +	_, _, hasPortionLimit := ExtractGpuMemoryPortionLimitAnnotation(pod)
  +	if req.Limit != nil && hasLegacyFraction && !hasPortionLimit {
  +		return fmt.Errorf("cannot combine %s limit annotation with %s annotation unless a %s annotation is set",
  +			constants.NvFractionsAnnotationPrefix, constants.GpuFraction,
  +			strings.TrimPrefix(constants.GpuMemoryPortionLimitSuffix, "."))
  +	}
  +	if req.Limit != nil && hasLegacyMemory && !hasMemoryLimitShorthand {
  +		return fmt.Errorf("cannot combine %s limit annotation with %s annotation unless the %s annotation is set",
  +			constants.NvFractionsAnnotationPrefix, constants.GpuMemory, constants.GpuMemoryLimit)
   	}
  ```
  </details>
  <details><summary>代码依据 pkg/admission/webhook/v1alpha2/gpusharing/gpu_sharing_test.go(本仓侧)</summary>

  ```diff
  -			error: fmt.Errorf("cannot combine %s limit annotation with %s or %s annotation",
  -				constants.NvFractionsAnnotationPrefix, constants.GpuFraction, constants.GpuMemory),
  +			error: fmt.Errorf("cannot combine %s limit annotation with %s annotation unless a %s annotation is set",
  +				constants.NvFractionsAnnotationPrefix, constants.GpuFraction,
  +				strings.TrimPrefix(constants.GpuMemoryPortionLimitSuffix, ".")),
  ```
  </details>

### 后续发展方向 [AI]
- GPU 共享注解体系正在从"互斥的历史注解"向"request/limit 两段式 + binder 侧推导"收拢:`gpu-memory.portion.limit` 可以替 `gpu-fraction` 提供 NvFractions limit,说明 NvFractions 是内部统一表示,而 `gpu-fraction`/`gpu-memory` 退化为前端写法。证据只覆盖 `gpu_sharing_validation.go` 这一处 14 行 diff 和本仓测试期望串,未见 binder 侧推导代码本身。
- 调度器的可观测面(`/get-snapshot` 等插件端点)在往"可作为故障诊断契约"的方向硬化:本期把"部分失败静默填空数组"改成 500、把注册表并发问题修掉、把端口绑定失败打日志。对我们产品的启示是:若自研调度器也暴露类似快照端点,需要同样区分"空集"与"取数失败",否则线上排障会被误导。证据只覆盖 snapshot 插件与 `framework/server.go`,未展开其他插件端点。
- 本期 KAI 三项都是稳定性/一致性修复,没有新调度能力,也没有 DRA 相关改动——上期(11-26)的 `gpuResourceWithoutDeviceSource` 之后 DRA 迁移这条线本日静默。

<details>
<summary>## 本期无实质改动(6 仓)</summary>

- NVIDIA/nvidia-container-toolkit:无新提交(HEAD 仍是 8abf9478,Release v1.20.2)
- NVIDIA/gpu-driver-container:无新提交(HEAD 仍是 24e26a1a)
- kubernetes-sigs/dra-driver-nvidia-gpu:无新提交(HEAD 仍是 5da6f625,Release v0.5.1)
- NVIDIA/dcgm-exporter:无新提交(HEAD 仍是 4e663a52,Release 4.9.0)
- NVIDIA/DCGM:无新提交(HEAD 仍是 9fae2867,master 分支)
- NVIDIA/mig-parted:无新提交(HEAD 仍是 6cf77a2b,Release v0.15.2)

</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=877c98604aa7e9d88bf5b805307172acdf73548e branch=main release=v26.7.3 scanned=2026-11-27 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=8abf947869fd1f97019c267e9f02397c3ce4dc97 branch=main release=v1.20.2 scanned=2026-11-27 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=24e26a1ab32df265a298e95a4ec9116789d0b140 branch=main release=— scanned=2026-11-27 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=c22b0c894ebfdb779b6285ee980377032f28de3c branch=main release=v0.20.2 scanned=2026-11-27 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5da6f62540fe3f807ba7023cc5b0690451072b3d branch=main release=v0.5.1 scanned=2026-11-27 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=4e663a526c4624ad0e18ad816f09b7be2c5348a7 branch=main release=4.9.0 scanned=2026-11-27 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-11-27 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=6cf77a2b52a528d2bac5468b7a33abb7bf45ac68 branch=main release=v0.15.2 scanned=2026-11-27 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=523b33294d2fbec6467a12f79a32c72a323d78f2 branch=main release=v0.18.9 scanned=2026-11-27 -->
