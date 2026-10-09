# HAMi diff 雷达 2026-10-10

## 摘要
- **ENPU 三后端改造补齐插件侧**:`ascend-device-plugin` 跟进 10-09 HAMi scheduler 侧改动,把 vNPU 配置从两个布尔(`hamiVnpuCore`/`enpu`)换成单字符串 `hamiVnpuMode`(template/hami-core/enpu),删除 `enpu.enabled` chart 值与 `vnpus.enpu` 配置字段,启动即校验拒绝旧字段——昨天预判的"按后端分流"从 scheduler 一路落到 plugin 与 chart。
- **NVIDIA device-plugin 节点配置从"精确节点名"升级为"标签选择器"**:HAMi 主仓 `NodeConfig` 新增 `nodelabelselector` 与通配 `*` 兜底项,`selectNodeConfigs` 三级优先级匹配,一条规则即可覆盖一组节点,不必逐节点列名。
- **一个显存误服务的安全修复**:`GetPendingPod` 删掉"按 pod 自身 hami.io 注解找 pending pod"的兜底路径,只认 node lock 指名的 pod,避免把一个 pod 的设备分配给另一个(issue #3076)。

## 当日重要改变
- Project-HAMi/ascend-device-plugin [弃用/移除+配置契约变更] vNPU 模式布尔开关 `hamiVnpuCore`/`enpu` 废弃,收敛为字符串 `hamiVnpuMode`;`enpu.enabled` chart 值与 `values.schema.json` 中的 `enpu.enabled` 必填项删除,配置里残留 `vnpus.enpu` 直接报错拒绝。证据见下。 https://github.com/Project-HAMi/ascend-device-plugin/commit/1cf890f96118f38a85f71d31da2e74ca95aeb1a0
- Project-HAMi/HAMi [新能力] device-plugin nodeconfig 支持 `nodelabelselector` 标签选择与 `*` 通配兜底,`EnableGetPreferredAllocation` 字段由 `bool` 改指针 `*bool`(后项不再能清掉前项的 true)。 https://github.com/Project-HAMi/HAMi/pull/3173
- Project-HAMi/HAMi [弃用/移除] `GetPendingPod` 移除注解兜底匹配路径,无 node lock 时直接报错,堵住跨 pod 设备误分配。 https://github.com/Project-HAMi/HAMi/pull/3126

## Project-HAMi/HAMi: 7b7d0381 -> c40de0fa
- 比较: 7b7d038150813eafe421dff3a2d93d7bf6f1f7bf -> c40de0fa | ahead=10 | files=28 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/7b7d038150813eafe421dff3a2d93d7bf6f1f7bf...c40de0fa87f38ebe585b47d5675c6fd1d2b62ff2

### AI 总结重点(源码 diff 为据)
- **NVIDIA device-plugin 节点配置匹配从"精确节点名"扩展为"标签选择器 + 通配兜底"的三级优先级**。原来只有 `os.Getenv(NodeName) == val.Name` 精确命中单条;现在匿名内嵌 struct 升为具名 `NodeConfig` 类型,新增 `NodeLabelSelector *metav1.LabelSelector`、常量 `NodeConfigFallbackName = "*"`,`selectNodeConfigs` 返回"命名本节点的全部条目,否则 nodelabelselector 匹配的全部条目,否则名为 `*` 的条目",层内按列表顺序后者覆盖前者。`EnableGetPreferredAllocation` 从 `bool` 改为 `*bool`,只有显式设置的条目才改它,避免后一条把前一条的 `true` 清成零值。(#3173)
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +const NodeConfigFallbackName = "*"
  +
  +type NodeConfig struct {
  +	NodeDefaultConfig `json:",inline"`
  +	Name string `json:"name"`
  +	NodeLabelSelector            *metav1.LabelSelector `json:"nodelabelselector,omitempty"`
  +	OperatingMode                string                `json:"operatingmode"`
  +	Migstrategy                  string                `json:"migstrategy"`
  +	FilterDevice                 *FilterDevice         `json:"filterdevices"`
  +	EnableGetPreferredAllocation *bool                 `json:"enablegetpreferredallocation"`
  +}
  -	Nodeconfig []struct {
  -		Name                         string        `json:"name"`
  -		EnableGetPreferredAllocation bool          `json:"enablegetpreferredallocation"`
  -	} `json:"nodeconfig"`
  +	Nodeconfig []NodeConfig `json:"nodeconfig"`
  ```
  </details>
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  -	for _, val := range deviceConfigs.Nodeconfig {
  -		if os.Getenv(util.NodeNameEnvName) == val.Name {
  +	for _, val := range selectNodeConfigs(deviceConfigs.Nodeconfig, os.Getenv(util.NodeNameEnvName), nodeLabels) {
  +		// Only an entry that sets the field changes it, so a later selector cannot clear an earlier true.
  +		if val.EnableGetPreferredAllocation != nil {
  +			enableGetPreferredAllocation = *val.EnableGetPreferredAllocation
  +		}
  ```
  </details>
- **`GetPendingPod` 删掉"按 pod 注解反查 pending pod"兜底,只信 node lock**。原来 `GetAllocatePodByNode` 返回空时会 List 本节点所有 pending pod,靠 `BindTimeAnnotations`/`DeviceBindPhase`/`AssignedNodeAnnotations` 注解猜哪个 pod 在分配;新代码直接去掉整段 List+匹配逻辑,空即报错。注释点明动机:写这些注解不需要额外 rbac,lock 缺失时"最近的带注解 pod"并非正在分配的 pod,老路径会把一个 pod 的设备服务给另一个(issue #3076)。(#3126)
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
   func GetPendingPod(ctx context.Context, node string) (*corev1.Pod, error) {
   	pod, err := GetAllocatePodByNode(ctx, node)
  -	if pod != nil {
  -		return pod, nil
  -	}
  -	// filter pods for this node.
  -	podlist, err := client.GetClient().CoreV1().Pods("").List(ctx, podListOptions)
  -	for _, p := range podlist.Items {
  -		if _, ok := p.Annotations[BindTimeAnnotations]; !ok { continue }
  -		...
  -	}
  -	return nil, fmt.Errorf("no binding pod found on node %s", node)
  +	if pod == nil {
  +		return nil, fmt.Errorf("no node lock naming a pending pod on node %s", node)
  +	}
  +	return pod, nil
   }
  ```
  </details>
- **NVIDIA 显存百分比校验收紧:拒绝小数,且 limits 与 requests 都查**。原 `validateMemoryPercentage` 只读一处(`resourceValue` 走 int),现在遍历 `Limits`+`Requests` 两张表,用新 `validPercentage` 以 `qty.AsInt64()` 判定——`AsInt64` 对 `50.5` 这类小数返回 `ok=false` 即判非法;`defaultExclusiveCoreIfNeeded` 的"100% 即独占"判断也同步改成 `AsInt64` 解析。(#2789)
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  -	if pct, ok := resourceValue(ctr, corev1.ResourceName(dev.config.ResourceMemoryPercentageName)); ok {
  -		if pct < 0 || pct > 100 { return fmt.Errorf(...) }
  +	name := corev1.ResourceName(dev.config.ResourceMemoryPercentageName)
  +	for _, list := range []corev1.ResourceList{ctr.Resources.Limits, ctr.Resources.Requests} {
  +		if qty, ok := list[name]; ok && !validPercentage(qty) {
  +			return fmt.Errorf("invalid %s value %s ... must be an integer between 0 and 100", name, qty.String(), ctr.Name)
  +		}
  +	}
  +func validPercentage(qty resource.Quantity) bool {
  +	pct, ok := qty.AsInt64()
  +	return ok && pct >= 0 && pct <= 100
  +}
  ```
  </details>
- **海光 HCU 在 admission 期做范围校验,limits/requests 同查**。`MutateAdmission` 原来只判断 `hcunum` 是否存在就返回;现在对 `hcunum`/`hcumem`(≤MaxInt32)与 `hcucores`(≤100)在 limits 和 requests 两表逐项校验,非整数或越界即在准入期拒绝,而非留到 `GenerateResourceRequests` 才报错。(#3012)
  <details><summary>代码依据 pkg/device/hygon/device.go</summary>

  ```diff
  -	_, ok := ctr.Resources.Limits[corev1.ResourceName(HygonResourceCount)]
  -	return ok, nil
  +	for _, list := range []corev1.ResourceList{ctr.Resources.Limits, ctr.Resources.Requests} {
  +		for name, max := range map[string]int64{HygonResourceCount: math.MaxInt32, HygonResourceMemory: math.MaxInt32, HygonResourceCores: 100} {
  +			if qty, found := list[corev1.ResourceName(name)]; found {
  +				if v, valid := qty.AsInt64(); !valid || v < 0 || v > max {
  +					return false, fmt.Errorf("invalid %s value %s ... between 0 and %d", name, qty.String(), ctr.Name, max)
  ```
  </details>
- **remotegpu 保证"库拷贝 init 容器"排到最前**。新增 `moveLibDeliveryFirst`/`requestsRemoteGPU`:webhook 逐容器 mutate,init 容器可能已追加 libvgpu 拷贝,`MutateAdmission` 在命中 app 容器时 `defer moveLibDeliveryFirst`,把生成的 `cp .../libvgpu.so` init 容器挪到 `InitContainers[0]`,确保库先于其它 init 落地;只对真正申请 remote GPU(count+memory>0)的 pod 生效,避免误动用户同名容器。(#3201)
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
  +	if pod != nil {
  +		for i := range pod.Spec.Containers {
  +			if ctr == &pod.Spec.Containers[i] { defer moveLibDeliveryFirst(pod); break }
  +		}
  +	}
  +func moveLibDeliveryFirst(pod *corev1.Pod) {
  +	if !requestsRemoteGPU(pod) { return }
  +	for i := range pod.Spec.InitContainers {
  +		lib := pod.Spec.InitContainers[i]
  +		if lib.Name == libVolumeName && ... lib.Command[2] == "cp "+libSourceGlob+" "+libMountPath+"/libvgpu.so" {
  +			if i > 0 { copy(pod.Spec.InitContainers[1:i+1], pod.Spec.InitContainers[:i]); pod.Spec.InitContainers[0] = lib }
  ```
  </details>
- **vGPUmonitor 暴露采集失败并加健康探针**(#3162,证据只见 chart README,metrics.go hunk 未入节选):chart 新增 `devicePlugin.monitor.probes.enabled`(liveness/readiness 探针,可关闭以进容器调试)与 `devicePlugin.monitor.metricsBindAddress`(`/metrics` 监听地址,容器端口/Service target/探针跟随它,拒绝 loopback 地址)。
  <details><summary>代码依据 charts/hami/README.md</summary>

  ```diff
  +| `devicePlugin.monitor.probes.enabled` | Run the monitor liveness and readiness probes; disable to debug inside the container | `true` |
  +| `devicePlugin.monitor.metricsBindAddress` | Address the monitor serves `/metrics` on; ... loopback addresses are rejected | `":9394"` |
  ```
  </details>
- 另:`feat(amd): check the namespace ResourceQuota in Fit`(#3180,AMD 调度在 Fit 阶段查命名空间配额,device_test.go 为主,生产 hunk 未入节选);删除 `docs/audit-report-v290.md`、`docs/hygon-hcu-support.md`(转移到 website);新增 helm-docs workflow 生成 chart 文档(#3189)。

### 后续发展方向 [AI]
- **多厂商准入校验正在统一到"limits+requests 双表 + AsInt64 整数判定"范式**:本期 NVIDIA(显存百分比)、海光(num/mem/cores)两处独立改动用的是同一套写法——遍历两张 ResourceList、`AsInt64` 拒小数/越界、准入期即拒。证据覆盖 nvidia/hygon 两个 device.go,未见是否已有共享 helper(仍是各插件各写一遍),但范式趋同明显,下一步可能抽成 `pkg/device` 公共函数(昨天 allocation.go 的 `ValidateContainerAllocation` 已是这方向的起点)。
- **device-plugin 节点配置从"节点级枚举"转向"声明式选择器"**:`nodelabelselector`+`*` 兜底让一份 config 可按标签批量覆盖异构节点池,是大规模集群运维友好度的信号。证据只覆盖 NVIDIA 插件的 config 解析(device.go/server.go),未见其它厂商插件是否共用同一 `NodeConfig` 结构。

## Project-HAMi/HAMi-core: ec5d85a3 -> 5ab7da10
- 比较: ec5d85a3d709e5ed138a1668ebfefd366c05ca1e -> 5ab7da10 | ahead=17 | files=13 | Release: —
- https://github.com/Project-HAMi/HAMi-core/compare/ec5d85a3d709e5ed138a1668ebfefd366c05ca1e...5ab7da10f72c72b7c158bb2d81f5148ec0af6392

### AI 总结重点(源码 diff 为据)
- **override 环境变量在初始化前加载,修登录会话无限额问题**。`initialized()` 开头新增 `load_env_from_file(ENV_OVERRIDE_FILE)`,注释点明:从 SSH / su - / sudo / cron 启动的进程没有限额变量,须在 `try_create_shrreg()` 建共享区之前读 `/overrideEnv`(issue #356)。意味着 HAMi-core 的显存/算力限额不再只依赖容器注入的 env,多了一条 override 文件兜底路径。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
   void initialized() {
  +    /* A process started from SSH, su -, sudo or cron has no limit variables.
  +       Load the override file first, so try_create_shrreg() below sees them. */
  +    load_env_from_file(ENV_OVERRIDE_FILE);
   	pthread_mutex_init(&_kernel_mutex, NULL);
  ```
  </details>
- **`load_env_from_file` 解析加固:坏行跳过而非 break 停止**。原逻辑遇到第一个不含 `=` 的行就 `break`,导致该行之后的配置(如 cache path)全部丢失;新逻辑按行号遍历,`\r\n` 都剥除,空行 continue,无 `=` 或 `=` 开头的行记 `LOG_ERROR` 后 continue;文件打不开时区分 `ENOENT`(INFO,用环境变量)与其它错误(WARN)。override 文件容错性显著提升。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -        if (strstr(tmp, "=") == NULL)
  -            break;
  +        /* Skip a bad line instead of stopping, so the lines after it, such as the cache path, are still loaded. */
  +        char *eq = strchr(tmp, '=');
  +        if (eq == NULL || eq == tmp) {
  +            LOG_ERROR("%s:%d is not KEY=VALUE, line skipped", filename, lineno);
  +            continue;
  +        }
  +        *eq = '\0';
  +        setenv(tmp, eq + 1, 1);
  ```
  </details>
- 另:`CMakeLists.txt` 用 `REGEX REPLACE "[^A-Za-z0-9_]"` 把分支名里所有非标识符字符(dependabot 带点号的版本分支)清成 `_`,因分支名会进 C 标识符;`security-insights.yml` 显式声明 GitHub secret scanning 与 CodeQL(SAST)工具;checkout/buildx/cpplint 等 CI action 版本 bump;新增 `test_override_env.c`、`test_cuda_memory_compat.c` 回归测试。

### 后续发展方向 [AI]
- **软隔离内核在补"非容器注入场景"的限额生效路径**:override 文件先加载 + 解析加固,说明 HAMi-core 想覆盖 SSH/debug/cron 进到容器内直接跑 GPU 进程的场景(这些进程绕开了容器 env 注入)。证据只覆盖 env 加载时序与解析,未见 override 文件由谁写入、与 device-plugin 侧如何约定格式。

## Project-HAMi/ascend-device-plugin: 6f6ee024 -> 1cf890f9
- 比较: 6f6ee0240641e9f03e6e46356910a1579b3cf276 -> 1cf890f9 | ahead=2 | files=22 | Release: ascend-device-plugin-0.1.0
- https://github.com/Project-HAMi/ascend-device-plugin/compare/6f6ee0240641e9f03e6e46356910a1579b3cf276...1cf890f96118f38a85f71d31da2e74ca95aeb1a0

### AI 总结重点(源码 diff 为据)
- **vNPU 模式配置从双布尔收敛为单字符串,对齐 10-09 的 HAMi scheduler 侧改动**。`VNPUsConfig` 删除 `HamiVnpuCore bool`+`Enpu bool`,新增 `HamiVnpuMode string`(`HamiVnpuCore` 保留但标 Deprecated,仅 `HamiVnpuMode` 空时兜底);新增常量 `VNPUModeTemplate/HamiCore/ENPU` 与 `resolveVNPUMode`、`Mode()`——`hamicore`/`hamiCore` 归一到 `hami-core`,非法值报错。`manager.go` 的 `IsHamiVnpuCore`/`IsEnpu` 不再读布尔字段,改走 `vnpuMode()`(node 覆盖 global)。
  <details><summary>代码依据 internal/vnpu.go</summary>

  ```diff
  -	HamiVnpuCore bool   `json:"hamiVnpuCore,omitempty"`
  -	Enpu         bool   `json:"enpu,omitempty"`
  +	HamiVnpuMode string `json:"hamiVnpuMode,omitempty"`
   	EnpuPolicy   string `json:"enpuPolicy,omitempty"`
  +	// Deprecated: used only when HamiVnpuMode is empty.
  +	HamiVnpuCore bool `json:"hamiVnpuCore,omitempty"`
  +const ( VNPUModeTemplate = "template"; VNPUModeHamiCore = "hami-core"; VNPUModeENPU = "enpu" )
  +func (v VNPUsConfig) Mode() (string, error) {
  +	fallback := VNPUModeTemplate
  +	if v.HamiVnpuCore { fallback = VNPUModeHamiCore }
  +	return resolveVNPUMode(v.HamiVnpuMode, fallback)
  +}
  ```
  </details>
- **启动即校验,显式拒绝残留的 `vnpus.enpu` 旧字段**。`LoadConfig` 在 Unmarshal 成功后先调 `VNPUs.Mode()` 验模式合法,再用 `map[string]json.RawMessage` 探测 `vnpus.enpu` 是否存在,存在即报错 "vnpus.enpu has been removed; use vnpus.hamiVnpuMode: enpu"——有意不误伤其它厂商字段。
  <details><summary>代码依据 internal/vnpu.go</summary>

  ```diff
  +		if _, err := yamlData.VNPUs.Mode(); err != nil {
  +			return nil, fmt.Errorf("vnpus: %w", err)
  +		}
  +		if _, exists := fields.VNPUs["enpu"]; exists {
  +			return nil, fmt.Errorf("vnpus.enpu has been removed; use vnpus.hamiVnpuMode: enpu")
  +		}
  ```
  </details>
- **Chart 契约同步:删 `enpu.enabled`/`hamiVnpuCore.enabled` 开关,新增 `hamiVnpuMode` 值 + `_helpers.tpl` 归一模板**。`values.yaml` 顶层加 `hamiVnpuMode: ""`,`hamiVnpuCore.enabled` 标 Deprecated,`enpu.enabled` 整项删除;`deviceConfig` 模板从 `hamiVnpuCore: {{...}}` + `enpu: {{...}}` 改为单行 `hamiVnpuMode: {{ include "ascend-device-plugin.vnpuMode" . | quote }}`;`values.schema.json` 的 enpu.required 去掉 `enabled`、新增顶层 `hamiVnpuMode` string。新模板 `vnpuMode` 对 `enpu.enabled`/非布尔 `hamiVnpuCore.enabled` 直接 `fail`。
  <details><summary>代码依据 charts/ascend-device-plugin/templates/_helpers.tpl + values.yaml</summary>

  ```diff
  +{{- define "ascend-device-plugin.vnpuMode" -}}
  +{{- if hasKey .Values.enpu "enabled" -}}{{- fail "enpu.enabled has been removed; use hamiVnpuMode: enpu" -}}{{- end -}}
  +{{- if eq $mode "" -}}{{- $mode = ternary "hami-core" "template" .Values.hamiVnpuCore.enabled -}}
  +{{- else if eq $mode "hamicore" -}}{{- $mode = "hami-core" -}}{{- end -}}
  -    hamiVnpuCore: {{ .Values.hamiVnpuCore.enabled }}
  -    enpu: {{ .Values.enpu.enabled }}
  +    hamiVnpuMode: {{ include "ascend-device-plugin.vnpuMode" . | quote }}
  ```
  </details>
- **语义修正:ENPU 与 hami-vnpu-core 从"同集群可同启、Pod 注解选后端"改为"按节点分后端"**。README 明确:每个节点选一个后端,Pod 的 `huawei.com/vnpu-mode` 注解必须匹配节点能力(此前文案是"同一 installation 可同时启用,Pod 注解选后端")。节点级 `nodeConfig` 从 `hami-vnpu-core: true` 布尔改为 `hamiVnpuMode: hami-core`,省略模式继承全局。
  <details><summary>代码依据 charts/ascend-device-plugin/README.md</summary>

  ```diff
  -ENPU and hami-vnpu-core can be enabled in the same installation. The pod's
  -`huawei.com/vnpu-mode` annotation selects the backend.
  +ENPU and hami-vnpu-core can run on different nodes in the same installation.
  +Each node selects one backend; the Pod annotation must match its capability.
  -      hami-vnpu-core: true
  +      hamiVnpuMode: hami-core
  ```
  </details>

### 后续发展方向 [AI]
- **"单字符串后端选择"成为 HAMi×昇腾 vNPU 的稳定配置契约**:scheduler(10-09)与 plugin+chart(今日)两侧用的是同一 `hamiVnpuMode` 字段名和同一归一/校验规则(hamiCore→hami-core、拒非法、拒旧字段),这是把"布尔开关叠加"的早期设计一次性清账。证据覆盖 vnpu.go 配置解析、manager.go 调用点与 chart 模板,未见运行时(enpu-manager/libvruntime)如何按 mode 实际切换,也未见 scheduler 与 plugin 版本不匹配时的降级行为(README 仅建议"先部署 scheduler 再写新字段")。
- **强约束"一节点一后端 + Pod 注解须匹配节点能力"**:语义从"Pod 注解自由选后端"收紧为"节点先定后端、Pod 必须对齐",ENPU-only 节点拒绝无注解 Pod。证据只覆盖 README 与 manager.go 的 node 优先逻辑,未见调度器侧对"Pod 注解与节点能力不匹配"的具体拒绝/回退路径(属 HAMi 主仓,本期该路径无新 diff)。

## Project-HAMi/HAMi-WebUI: 54d4bdf0 -> 09f0b75b
- 比较: 54d4bdf02cb1a6d733c418809eb81d82d72c8d9e -> 09f0b75b | ahead=4 | files=32 | Release: v1.3.0
- https://github.com/Project-HAMi/HAMi-WebUI/compare/54d4bdf02cb1a6d733c418809eb81d82d72c8d9e...09f0b75b0773c2caf835933936f0301f7efc248c

### AI 总结重点(源码 diff 为据)
- 本期 4 个 commit 全是前端可用性修复,无后端/纳管能力变化。新增 `metrics/time-axis.mjs`(170 行):趋势图时间轴按时区生效,`buildTimeAxisLabels` 按跨天/跨年/跨时区自适应 tick 粒度(秒/分/时/日/月/年),tooltip 显示 `UTC±HH:MM`,DST 重复小时用 elapsed-time 步进保留两个偏移(#329)。其余:date range picker 打开日历时保留已输入草稿(走 `patches/tdesign-vue-next@1.18.5.patch`,#334)、列表搜索与空结果文案澄清(#328)、loading 占位对齐页面布局(新增 `LoadingValue.vue`,#330)。
  <details><summary>代码依据 packages/web/projects/vgpu/metrics/time-axis.mjs(新增)</summary>

  ```diff
  +export const buildTimeAxisLabels = (timestamps, interval = 60_000) => {
  +  const spansDays = new Set(dates.map((date) => timeParse(date, 'YYYY-MM-DD'))).size > 1;
  +  const spansOffsets = new Set(dates.map((date) => date.getTimezoneOffset())).size > 1;
  +      if (interval >= 86_400_000 || (spansDays && midnight)) {
  +        return timeParse(date, spansYears ? 'YYYY-MM-DD' : 'MM-DD');
  +      return spansOffsets ? `${clock}\nUTC${utcOffset(date)}` : clock;
  ```
  </details>

### 后续发展方向 [AI]
- 控制台处于"打磨存量视图"阶段(时间轴/日期选择/搜索/loading),未见新纳管对象或新厂商视图。证据只覆盖 4 个 fix commit 的前端 diff,无后端 API 变更,商业化/能力信号本期为零。

## 本期无实质改动(折叠)
<details><summary>1 仓 EMPTY</summary>

- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=c40de0fa87f38ebe585b47d5675c6fd1d2b62ff2 branch=master release=v2.10.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5ab7da10f72c72b7c158bb2d81f5148ec0af6392 branch=main release=— scanned=2026-10-10 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-10 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf890f96118f38a85f71d31da2e74ca95aeb1a0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-10 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=09f0b75b0773c2caf835933936f0301f7efc248c branch=main release=v1.3.0 scanned=2026-10-10 -->
</content>
</invoke>
