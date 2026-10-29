# HAMi diff 雷达 2026-10-30

## 摘要
- **HAMi 主仓两处实质能力**:①调度器 extender 开始计入"软 nodeAffinity"打分(新 flag `--node-affinity-score-weight`,复用 kube-scheduler 的 component-helpers 解析,默认 0 关闭);②vGPUmonitor 新增 `hami_host_gpu_unknown_process_count` 指标——数出该卡上 NVML 活跃进程里"匹配不到 HAMi 所分配容器"的个数,是未纳管 GPU 占用的可观测信号(env `HAMI_MONITOR_UNKNOWN_PROCESSES=true` 开关)。
- **volcano-vgpu-device-plugin 一次 perf + 一次工程化基线**:monitor 的 5s 反馈环从"每 tick List 一次 Pod"改为节点级 informer 缓存读(新增 `pkg/nodepodinformer`),削 API server 压力;同期落 OpenSSF 安全基线(SECURITY.md / SECURITY-INSIGHTS.yml / CodeQL / scorecard / dependency-review)+ nvml-mock 无真卡测试路径。
- **弃用信号**:HAMi CHANGELOG 预告 v2.11 弃用两个旧指标(v2.12 移除);helm 校验器把一批已删字段统一纳入"present 即 fail"守卫(`devices.ascend.enpu`、`scheduler.patch.image`、`dcuResource*` 等)。HAMi-core 软切分内核本期**空日**(连续多日无改动)。

## 当日重要改变
- **HAMi** [新能力] 调度打分纳入 preferred nodeAffinity:新 flag `NodeAffinityScoreWeight`,按匹配权重占比归一化加分;0 为默认(关闭)。证据 `pkg/scheduler/config/config.go` / `pkg/scheduler/policy/node_policy.go`。https://github.com/Project-HAMi/HAMi/pull/3298
- **HAMi** [新能力] vGPUmonitor 新增"未知 GPU 进程数"指标 `hami_host_gpu_unknown_process_count`(label node/device_uuid),env 开关,失败则 collect success 置 0。证据 `pkg/monitor/nvidia/unknown_processes.go`、`cmd/vGPUmonitor/metrics.go`。https://github.com/Project-HAMi/HAMi/pull/3305
- **HAMi** [弃用/移除] CHANGELOG 预告 `hami_container_device_memory_bytes`、`hami_resource_quota_used` 的 `limit` label 于 v2.11 弃用、v2.12 移除;helm 校验器新增一批 removed-field 守卫。证据 `CHANGELOG.md`、`charts/hami/templates/_helpers.tpl`。https://github.com/Project-HAMi/HAMi/pull/3324
- **HAMi** [新能力] remote-gpu(Lupine)session stub 支持 imagePullSecrets,私有镜像仓拉取 session server。证据 `pkg/device/remotegpu/session.go`。https://github.com/Project-HAMi/HAMi/pull/3329
- **volcano-vgpu-device-plugin** [架构方向] monitor 反馈环改节点级 Pod informer(不再每 tick List API);`clientset` 由 `*kubernetes.Clientset` 松绑为 `kubernetes.Interface`。证据 `pkg/nodepodinformer/informer.go`、`pkg/monitor/nvidia/cudevshr.go`。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commits/main

## Project-HAMi/HAMi: 07c89a3f -> a1a1b7e7
- 比较: 07c89a3f8cbda064a0e7641c354ac0770ac2a431 -> a1a1b7e7 | ahead=6 | files=34 | Release: v2.10.0
### AI 总结重点(源码 diff 为据)
- **调度器 extender 开始为 preferred(软)nodeAffinity 加分,此前只有 required 由 kube-scheduler 前置过滤、extender 不理会 preferred**。新增 `PreferredNodeAffinity{terms, totalWeight}`,`NewPreferredNodeAffinity` 逐条解析 pod 的 `preferredDuringSchedulingIgnoredDuringExecution`,跳过 weight=0/空/解析失败的 term(聚合报错但不丢可用 term),直接复用 kube-scheduler 的 `component-helpers/.../nodeaffinity` 做 matcher;`totalWeight` 作归一化分母。
  <details><summary>代码依据 pkg/scheduler/policy/node_policy.go</summary>

  ```diff
  +type PreferredNodeAffinity struct {
  +	terms       *nodeaffinity.PreferredSchedulingTerms
  +	totalWeight int64
  +}
  +func NewPreferredNodeAffinity(terms []corev1.PreferredSchedulingTerm) (*PreferredNodeAffinity, error) {
  +	for i, term := range terms {
  +		if term.Weight == 0 || isEmptyNodeSelectorTerm(&term.Preference) { continue }
  +		if _, err := nodeaffinity.NewPreferredSchedulingTerms([]corev1.PreferredSchedulingTerm{term}); err != nil {
  +			errs = append(errs, fmt.Errorf("preferred term %d: %w", i, err)); continue }
  +		usable = append(usable, term); total += int64(term.Weight)
  +	}
  ```
  </details>
- **新 flag `--node-affinity-score-weight`(`config.NodeAffinityScoreWeight float32`,默认 0=关闭)挂进打分;`scoreNode` 签名新增 `pref` 参数,匹配时用 nodeLister 取实时节点标签再 `AddNodeAffinityScore`**。并加 `ValidateNodeAffinityScoreWeight` 拒绝负数/NaN/Inf(负权会把"优选加分"反转成惩罚)。
  <details><summary>代码依据 pkg/scheduler/config/config.go + score.go</summary>

  ```diff
  +	// NodeAffinityScoreWeight ... 0 (the default) disables the bonus.
  +	NodeAffinityScoreWeight float32
  +func ValidateNodeAffinityScoreWeight(weight float32) error {
  +	w := float64(weight)
  +	if math.IsNaN(w) || math.IsInf(w, 0) || w < 0 {
  +		return fmt.Errorf("--node-affinity-score-weight must be a finite number >= 0, got %v", weight) }
  +	return nil }
  ```
  ```diff
  -func (s *Scheduler) scoreNode(..., userNodePolicy string, weights util.DeviceScoringWeights) nodeScoreResult {
  +func (s *Scheduler) scoreNode(..., userNodePolicy string, pref *policy.PreferredNodeAffinity, weights util.DeviceScoringWeights) nodeScoreResult {
  +	if pref != nil { score.Node = s.currentNode(nodeID, node.Node) }
  +	score.AddNodeAffinityScore(pref, userNodePolicy, config.NodeAffinityScoreWeight)
  ```
  </details>
- **新增 vGPUmonitor 指标 `hami_host_gpu_unknown_process_count`:数出该卡 NVML compute/graphics 活跃 PID 里匹配不到"HAMi 已分配该卡的容器"的个数**。新文件 `unknown_processes.go` 读 `/proc/<pid>/cgroup`+`stat`(用 starttime 夹读检测 PID 复用),用 `podCgroupUID`/`containerCgroupID` 正则把 PID 归到 pod。注释明确:**不是**共享显存槽计数、**不是**断言这些 PID 在 K8s 之外。env `HAMI_MONITOR_UNKNOWN_PROCESSES=true` 才采,失败则 `hami_vgpumonitor_collect_success=0`。
  <details><summary>代码依据 pkg/monitor/nvidia/unknown_processes.go + cmd/vGPUmonitor/metrics.go</summary>

  ```diff
  +// UnknownProcessCount counts distinct live NVML compute/graphics PIDs that
  +// cannot be matched to a container allocated this GPU by HAMi.
  +type UnknownProcessCount struct { UUID string; Count int }
  ```
  ```diff
  +	unknownProcessCountDesc = prometheus.NewDesc(
  +		"hami_host_gpu_unknown_process_count",
  +		"Distinct live NVML compute/graphics processes not matched to a container allocated this GPU by HAMi; omitted when the inventory fails",
  +		[]string{"node", "device_uuid"}, nil)
  +	if os.Getenv("HAMI_MONITOR_UNKNOWN_PROCESSES") == "true" {
  +		counts, err := cc.ClusterManager.containerLister.UnknownProcessCounts()
  +		if err != nil { ...; success = 0 }
  ```
  </details>
- **remote-gpu(Lupine)session stub 支持 imagePullSecrets**:新常量 `sessionPullSecretsAnno = "hami.io/lupine-session-image-pull-secrets"` 记录 scheduler 所配的 pull-secret 清单;`ReconcileSessionStubs` 在 endpoint 或 pull 凭据变化时**重建**(而非 edit,因这些字段不可改于运行中的 pod);`sessionPullSecretsMatch` 用注解区分"scheduler 配的"与"ServiceAccount admission 注入的"避免误判。
  <details><summary>代码依据 pkg/device/remotegpu/session.go</summary>

  ```diff
  +	sessionPullSecretsAnno = "hami.io/lupine-session-image-pull-secrets"
  -	if keep && stubEndpoint(stub) == endpoint {
  +	if keep && stubEndpoint(stub) == endpoint && sessionPullSecretsMatch(stub, RemoteGPUSessionImagePullSecrets) {
  -func sessionStub(namespace, node, endpoint, image string) (*corev1.Pod, error) {
  +func sessionStub(namespace, node, endpoint, image string, pullSecrets []string) (*corev1.Pod, error) {
  ```
  </details>
- **helm 校验器重构 + 扩展弃用字段守卫**:`validateDeviceValues`→`validateValues`,`removedRootFields`→`removedFields` 并支持嵌套路径(`devicePlugin.deviceSplitCount`、`scheduler.patch.image`→`imageNew`、`dcuResource*`、`devices.ascend.enpu`→`hamiVnpuMode` 等),present 即 fail;删掉了旧的单独 `enpu` fail 块和 `deviceSplitCount` 校验(并入统一表)。另 CHANGELOG 预告两个指标弃用(v2.11 弃用/v2.12 移除)。
  <details><summary>代码依据 charts/hami/templates/_helpers.tpl + CHANGELOG.md</summary>

  ```diff
  -{{- define "hami-vgpu.validateDeviceValues" -}}
  +{{- define "hami-vgpu.validateValues" -}}
  -{{- $removedRootFields := dict
  +{{- $removedFields := dict
  +  "dcuResourceName" "devices.hygon.resourceCountName"
  +  "devicePlugin.deviceSplitCount" "devices.nvidia.deviceSplitCount"
  +  "devices.ascend.enpu" "devices.ascend.hamiVnpuMode (template, hami-core, or enpu)"
  +  "scheduler.patch.image" "scheduler.patch.imageNew"
  ```
  ```diff
  +**Deprecations**
  +- `hami_container_device_memory_bytes` is deprecated in v2.11.0 and removed in v2.12.0, use `hami_vgpu_memory_used_bytes`
  +- The `limit` label of `hami_resource_quota_used` and `QuotaUsed` is deprecated in v2.11.0 and removed in v2.12.0, use `hami_resource_quota_limit`
  ```
  </details>
### 后续发展方向 [AI]
- HAMi 的 **scheduler extender 正在向 kube-scheduler 原生打分语义靠拢**:这次把 preferred nodeAffinity 用 component-helpers 原班代码接入,意味着后续"节点亲和/反亲和/拓扑"这类原本只在 K8s 默认调度器里的软约束,可能逐步进 HAMi 打分链,让 vGPU 调度决策与原生调度一致。证据只覆盖 preferred nodeAffinity 一项,未见 podAffinity/topologySpreadConstraints。
- `unknown_process_count` 指标指向 **"卡上有多少占用是 HAMi 管不到的"这类纳管缺口可观测化**——对多租户隔离审计有用(能发现绕过 HAMi 的裸进程),但当前只是计数+env 开关,未见据此做驱逐/告警动作,也未扩展到 NVIDIA 以外厂商。证据仅 nvidia 包。
- CHANGELOG 的指标弃用 + helm 字段守卫扩展,延续近日观察到的 **chart/指标口径工程化收敛**(昨日 `global.imageSource`),方向是配置面可复现、破坏性变更显式 fail;对升级 v2.11→v2.12 的用户需盯 `hami_container_device_memory_bytes` 等指标改名。证据为 CHANGELOG 文本与 helpers.tpl,未逐指标核实消费侧是否已切换。

## Project-HAMi/volcano-vgpu-device-plugin: 5283c861 -> bb24c715
- 比较: 5283c861b7f4bd4169d86daf4d03d34ac056d5fb -> bb24c715 | ahead=31 | files=32 | Release: —
### AI 总结重点(源码 diff 为据)
- **monitor 的 5s 反馈环不再每 tick 向 API server List Pod,改为节点级 informer 缓存读**。新增 `pkg/nodepodinformer`(按 `spec.nodeName` FieldSelector 的节点作用域 Pod informer);`ContainerLister` 加 `listNodePods func()` 注入点,`Update()` 改走 `ListNodePods()`(有注入走 informer 缓存,无则回退节点级 API List 保兼容);`clientset` 类型由 `*kubernetes.Clientset` 松绑为 `kubernetes.Interface`,`isValidPod` 入参由 `*corev1.PodList` 改 `[]*corev1.Pod`(便于 mock/测试)。
  <details><summary>代码依据 pkg/monitor/nvidia/cudevshr.go</summary>

  ```diff
  -	clientset     *kubernetes.Clientset
  +	clientset     kubernetes.Interface
  +	listNodePods func() ([]*corev1.Pod, error)
  +func (l *ContainerLister) UseNodePodList(list func() ([]*corev1.Pod, error)) { l.listNodePods = list }
  +func (l *ContainerLister) ListNodePods() ([]*corev1.Pod, error) {
  +	if l.listNodePods != nil { return l.listNodePods() }
  -func (l *ContainerLister) Update() error {
  -	listOptions := metav1.ListOptions{}
  -	pods, err := l.clientset.CoreV1().Pods("").List(...)
  +func (l *ContainerLister) Update() error {
  +	pods, err := l.ListNodePods()
  -func isValidPod(name string, pods *corev1.PodList) bool {
  +func isValidPod(name string, pods []*corev1.Pod) bool {
  ```
  </details>
- **落 OpenSSF 安全基线(供应链成熟度信号)**:新增 `SECURITY.md`、`SECURITY-INSIGHTS.yml`(2.1.0 schema)、`CONTRIBUTING.md`,及 `.github/workflows` 下 CodeQL、scorecard、dependency-review、unit-test、dependabot;文档明确 release 镜像用 cosign keyless 签名、依赖 critical/high 必须发版前修。属 CI/治理工程化,非 vGPU 内核能力。
  <details><summary>代码依据 SECURITY-INSIGHTS.yml / codeql.yml(新增)</summary>

  ```diff
  +header:
  +  schema-version: 2.1.0
  +project:
  +  name: volcano-vgpu-device-plugin
  +  repositories:
  +    - name: HAMi-core
  +      comment: In-container CUDA interception library (libvgpu) ... compiled into every release image
  ```
  </details>
- **nvml-mock 无真卡测试路径(仅 Helm)**:`nvmlMock.enabled=true` 时 chart 注入 `NVIDIA_DRIVER_ROOT`/`DEVICE_DISCOVERY_STRATEGY=nvml`/`DP_DISABLE_HEALTHCHECKS=all` 并挂 mock driver root、禁用 monitor 容器;与 `cdi.enabled` 互斥。用于 kind 上验证调度/注册,不验证容器内隔离。属开发/CI 工效。
  <details><summary>代码依据 README.md(新增 nvml-mock 章节)</summary>

  ```diff
  +### Testing without real GPUs (nvml-mock)
  +> **Note:** `nvmlMock.enabled` and `cdi.enabled` are mutually exclusive.
  +When `nvmlMock.enabled=true`, the chart injects the `NVIDIA_DRIVER_ROOT`,
  +`DEVICE_DISCOVERY_STRATEGY=nvml`, and `DP_DISABLE_HEALTHCHECKS=all` ... disables the monitor container.
  ```
  </details>
- **(非 API 变更澄清)** `api/config/v1/replicas_test.go` 命中 API 路径但只是删测试用例:`NewResourceName` 因资源名迁到 `volcano.sh/` 前缀已不再校验名字格式,故去掉 `$invalid$` 这类期望报错的用例。是对既有放宽行为的测试对齐,非 schema 改动。
  <details><summary>代码依据 api/config/v1/replicas_test.go</summary>

  ```diff
  -		{ input: `{"name": "$invalid$", "replicas": 2, "rename": "valid-shared"}`, err: true },
  +		// Invalid resource name cases were removed: NewResourceName no longer
  +		// validates the name format since resources moved to volcano.sh/.
  ```
  </details>
### 后续发展方向 [AI]
- 这批几乎全是 **工程化/供应链成熟度**(OpenSSF 基线、CodeQL、cosign、node-scoped informer 减 API 压力),说明 volcano-vgpu 集成路径在往"生产可审计、可大规模部署"收;与 vGPU 软切分算法本身无关。证据覆盖 informer/安全文件,未见切分/隔离逻辑改动。
- informer 化后 monitor 的 Pod 发现与 HAMi 主仓一致走缓存,后续两仓 monitor 代码可能进一步统一;但本期 `HAMi-core`(真正的 CUDA hook 切分内核)仍空日,**软隔离能力边界本期无变化**。证据:HAMi-core 无新提交。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交(软切分内核连续空日,隔离能力边界未动)
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=a1a1b7e7b23028cf18de8fd0a6b4e92ab5468877 branch=master release=v2.10.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6736b0589049390ec945bd40dfb4769f9f043def branch=main release=— scanned=2026-10-30 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=bb24c7155c7ab65d4061aa7a6b4b6513525eb06a branch=main release=— scanned=2026-10-30 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ab41bec367ca95ac52ed1bcb8667c33e689f8f37 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-30 -->
</content>
</invoke>
