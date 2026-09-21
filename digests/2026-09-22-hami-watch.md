# HAMi diff 雷达 2026-09-22

## 摘要
- HAMi 主仓这期几乎全是 **lupine 远程 GPU(GPU over network / 显卡池化)** 的成体系落地:客户端节点(无卡、无 device-plugin、无 Allocate)靠 init 容器 + `LD_PRELOAD` 注入 HAMi-core 就地做显存/算力软隔离;调度器新增读 lupine server `/metrics` 感知带外占用防重复投放;运行态多了 session-stub 中继 Pod 让用户 port-forward 到中继而非 server。方向清晰:HAMi 正把软切分能力从"本地卡"延伸到"网络远端卡"。
- 一条安全向修复:webhook 把 scheduler-owned 注解的校验从"仅 create"扩到"update",堵住"有 pod update 权限即可后改注解骗取未计量显存/算力"的提权口子(#3074)。
- volcano-vgpu-device-plugin 侧:device ConfigMap 查找加 `--device-config-namespace` 可配置命名空间 + 非 NotFound 错误不再被回退吞掉;daemonset 的 `HOOK_PATH` 从 `/tmp/vgpu` 改到 `/usr/local/vgpu`,并为驱动 580 利用率 bump 了 libvgpu。

## 当日重要改变
- Project-HAMi/HAMi [新能力/架构方向] lupine 远程 GPU 成体系补齐:客户端注入 HAMi-core + 调度器带外占用感知 + session-stub 中继,软切分从本地卡扩到网络远端卡。证据 `pkg/device/remotegpu/{device.go,session.go,metrics.go}`、`server.go` https://github.com/Project-HAMi/HAMi/pull/3013
- Project-HAMi/HAMi [安全] webhook 新增 update 路径校验,scheduler-owned 注解被非 HAMi 组件改写即拒(SubjectAccessReview + schedulerName 双检)。证据 `pkg/scheduler/webhook.go` https://github.com/Project-HAMi/HAMi/pull/3074
- Project-HAMi/HAMi [新能力] MIG ↔ hami-core 动态切换:`DisableIdleGPUs` 关闭空闲卡 MIG 以便注册 hami-core,占用卡仍在 MIG 则拒绝降级。证据 `pkg/device-plugin/.../migmgr.go` https://github.com/Project-HAMi/HAMi/pull/3043
- Project-HAMi/volcano-vgpu-device-plugin [配置/部署变更] `LoadConfigFromCM` 加命名空间参数 + `--device-config-namespace` flag;`HOOK_PATH` `/tmp/vgpu`→`/usr/local/vgpu`。证据 `pkg/util/util.go`、`deployments/helm/.../daemonset.yaml` https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/cbded47b8d4cabb4ac6b228e52049949a1bae271...806072e6

## Project-HAMi/HAMi: 60197354 -> 379547bb
- 比较: https://github.com/Project-HAMi/HAMi/compare/60197354e5fa0bb042b0ee62862fa68a621ecb77...379547bb382783fc79e39f8f2f1b644bba6ed715 | ahead=6 | files=38 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **lupine 客户端节点就地做 HAMi-core 软隔离**:`MutateAdmission` 签名从 `(ctr, _ *Pod)` 改为接收真实 `pod`,新增 `armMemoryLimit(ctr, pod)`。客户端节点自己不拥有 GPU、不跑 device-plugin、永远收不到 Allocate 回调,所以把 HAMi-core(`libvgpu.so.*`)通过 init 容器灌进 `/hami-remote-gpu` 卷,并设 `LD_PRELOAD` + `CUDA_DEVICE_MEMORY_LIMIT` + `CUDA_DEVICE_MEMORY_SHARED_CACHE`,让显存上限在请求发到网络前就被 HAMi-core 拦住。这把"软切分只在本地卡生效"的边界打破了。
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
  + libVolumeName = "hami-remote-gpu-lib"
  + libMountPath  = "/hami-remote-gpu"
  + libSourceGlob = "/k8s-vgpu/lib/nvidia/libvgpu.so.*"
  + ldPreloadEnv   = "LD_PRELOAD"
  + memoryLimitEnv = "CUDA_DEVICE_MEMORY_LIMIT"
  + sharedCacheEnv = "CUDA_DEVICE_MEMORY_SHARED_CACHE"
  ...
  -func (dev *RemoteGPUDevices) MutateAdmission(ctr *corev1.Container, _ *corev1.Pod) (bool, error) {
  +func (dev *RemoteGPUDevices) MutateAdmission(ctr *corev1.Container, pod *corev1.Pod) (bool, error) {
  +	needsLib, err := armMemoryLimit(ctr, pod)
  ...
  +	if needsLib {
  +		addLibDelivery(pod)   // 最后做:append InitContainers 可能搬动底层数组
  +	}
  ```
  </details>

- **调度器新增按节点 label 决定 operating mode**:`resolveOperatingMode(configured, node)`,只要节点带 `remotegpu.LupineServerLabel` 就强制 `nvidia.RemoteMode`(把卡当网络服务对外供);config 写了 remote 但节点没 label 则回退 `HamiCoreMode`。目的:让"是否属于 lupine 车队"只有节点 label 一个真值来源,避免 config 与 label 漂移导致节点"半入队"——既对外供卡又把同一批卡 advertise 给本机 kubelet。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  +func resolveOperatingMode(configured string, node *corev1.Node) string {
  +	if node != nil {
  +		if _, ok := node.Labels[remotegpu.LupineServerLabel]; ok {
  +			return nvidia.RemoteMode
  +		}
  +	}
  +	if configured == nvidia.RemoteMode {
  +		klog.InfoS("ignoring the configured remote operating mode, this node carries no lupine server label", ...)
  +		return nvidia.HamiCoreMode
  +	}
  +	return configured
  +}
  ```
  </details>

- **调度器读 lupine server `/metrics` 感知带外占用**:新增 `pkg/device/remotegpu/metrics.go`,`httpBusyDevices` GET `http://<endpoint>/metrics`,解析 `lupine_client_device_memory_used_bytes` 行取 `device_uuid`,得出"哪些卡当前有 client"。调度器自身账本只覆盖它投放的 pod,而交互式 session / 手工配的 client 也会占卡,不查就会把已占卡再投给新 pod 造成两负载挤一卡;超时 `metricsTimeout=2s` 防单台 server 卡住全车队调度。
  <details><summary>代码依据 pkg/device/remotegpu/metrics.go</summary>

  ```diff
  +	clientMemoryMetric = "lupine_client_device_memory_used_bytes"
  +	deviceUUIDLabel = "device_uuid"
  +	metricsTimeout = 2 * time.Second
  +func httpBusyDevices(ctx context.Context, endpoint string) (map[string]struct{}, error) {
  +	url := fmt.Sprintf("http://%s/metrics", endpoint)
  ```
  </details>

- **新增 session-stub 中继 Pod 机制**:`pkg/device/remotegpu/session.go` 的 `ReconcileSessionStubs` 在每台 lupine server 节点上维持一个中继 pod(label `hami.io/lupine-session`、env `LUPINE_ENDPOINT`)。用户手工访问车队时 port-forward 到 stub 而非 server,于是转发权限可授在"只做中继的 pod"上而不必开放 server 所在命名空间;stub 生命周期跟随 server,随用随有、无需临时创建。仅 leader 调用以免双调度器互相创建/删除打架。
  <details><summary>代码依据 pkg/device/remotegpu/session.go(新增)</summary>

  ```diff
  +	sessionStubLabel = "hami.io/lupine-session"
  +	sessionStubPrefix = "lupine-session-"
  +	sessionEndpointEnv = "LUPINE_ENDPOINT"
  +func (dev *RemoteGPUDevices) ReconcileSessionStubs(ctx context.Context) {
  +	if RemoteGPUSessionImage == "" { return }
  ...
  +	// Only the leader should call this.
  ```
  </details>

- **MIG ↔ hami-core 动态降级(#3043)**:`migmgr.go` 新增 `DisableIdleGPUs(deviceCount, inUse)`——把空闲卡的 MIG 关掉好让节点注册成 hami-core;若某卡在用且仍处 MIG,直接报错、不注册 hami-core,避免"硬件还在分区却对外宣称软切分可用"。配套三个错误助手 `errMigModeNeedsReset`/`errMigModePending`/`errMigModeActivation`,当 NVML 返回 `ERROR_RESET_REQUIRED` 时给出 `nvidia-smi --gpu-reset` 或重启 VM 的运维指引。server.go 侧 `migMgr` 改为始终构造(不再仅 mig 模式才建)。
  <details><summary>代码依据 pkg/device-plugin/.../migmgr.go</summary>

  ```diff
  +func (m *MigInstanceManager) DisableIdleGPUs(deviceCount int, inUse map[int]struct{}) ([]int, error) {
  +		if _, busy := inUse[gpuIndex]; busy {
  +			if enabled { return disabled, fmt.Errorf("gpu %d is in use; cannot disable MIG", gpuIndex) }
  +		}
  +		if err := m.ensureMigModeDisabled(gpuIndex); err != nil { ... }
  ```
  </details>

- **webhook 补 update 路径注解校验(#3074,安全)**:`Handle` 对 `admissionv1.Update` 分流到新 `handleUpdate`;若 scheduler-owned 注解被改(`changedSchedulerOwnedAnnotation`),要求调用者同时满足"能写 node(SubjectAccessReview `canWriteNodes`)"且"pod.Spec.SchedulerName == config.SchedulerName",否则拒绝。原来只在 create 拦、update 敞开,任何持 pod update 权限者可事后补写注解,device-plugin 据此发未被调度器计量的显存/算力。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  +	if req.Operation == admissionv1.Update {
  +		return h.handleUpdate(ctx, req, pod)
  +	}
  ...
  +	if !canWriteNodes(ctx, req.UserInfo) {
  +		return denySchedulerOwnedAnnotation(pod, req.UserInfo.Username, annotation)
  +	}
  +	if len(config.SchedulerName) > 0 && pod.Spec.SchedulerName != config.SchedulerName {
  +		return denySchedulerOwnedAnnotation(pod, req.UserInfo.Username, annotation)
  +	}
  ```
  </details>

- **调度器有界基数 outcome 指标(#3088)**:新增 `pkg/metrics/scheduler.go` 的 `SchedulerOutcomeMetrics`,三条 CounterVec(`hami_scheduler_allocations_total` / `hami_scheduler_allocation_failures_total` / `hami_scheduler_bind_rollbacks_total`),标签固定为 `phase/device_type/failure_reason`,失败原因用受控枚举 `SchedulerFailureReason`(no_fit/lookup/identity/lock/annotation_patch/bind/internal…)防标签爆炸。scheduler.go 用 `allocationMetricsOnce` 懒初始化。
  <details><summary>代码依据 pkg/metrics/scheduler.go(新增)</summary>

  ```diff
  +var schedulerOutcomeLabels = []string{"phase", "device_type", "failure_reason"}
  +func NewSchedulerOutcomeMetrics() *SchedulerOutcomeMetrics {
  +	allocations:        newSchedulerCounter("hami_scheduler_allocations_total", ...),
  +	allocationFailures: newSchedulerCounter("hami_scheduler_allocation_failures_total", ...),
  +	bindRollbacks:      newSchedulerCounter("hami_scheduler_bind_rollbacks_total", ...),
  ```
  </details>

> 另有 #3075「device-plugin 拒绝超出容器请求的分配」、#3092「auto driverroot 挂载保持不变」,helper patch 截断未覆盖到判定性 hunk,此处按标题记录不展开(hunk 截断,未覆盖全部)。

### 后续发展方向 [AI]
- **HAMi 的下一主战场是"远程 GPU / 显卡池化(lupine)"**:device.go+session.go+metrics.go+server.go 四处证据一致指向"把 GPU 从节点本地资源变成网络服务",且软隔离(HAMi-core)已能随客户端 pod 下发、调度器已能感知带外占用。这与 Dynamo/llm-d 的推理分离、以及 remote-GPU 类项目(如各家 GPU 池化)是同一赛道——对标 OAI 值得关注 HAMi 是否会把 lupine 做成"跨节点共享大卡"的开源基座。证据只覆盖调度器/device-plugin/webhook 侧 diff,未见 lupine server 端(独立进程/镜像)实现,也未见 CRD 化配置(本期无 API/CRD 路径命中,配置走全局变量 `RemoteGPULibImage`/`RemoteGPUSessionImage` + charts values)。
- **软切分与 MIG 从"二选一"走向"同节点动态互切"**:`DisableIdleGPUs` + `resolveOperatingMode` 让一个节点可按负载在 MIG 硬分区与 hami-core 软切分间切换。证据只覆盖 disable 方向(MIG→hami-core)与 label 判定,未见反向(hami-core→MIG)自动化 hunk。

## Project-HAMi/volcano-vgpu-device-plugin: cbded47b -> 806072e6
- 比较: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/cbded47b8d4cabb4ac6b228e52049949a1bae271...806072e6eb8594f1989913085ad4b87bc5d61af5 | ahead=12 | files=13 | Release: —

### AI 总结重点(源码 diff 为据)
- **device ConfigMap 查找命名空间可配 + 错误不再被回退吞掉**:`LoadConfigFromCM(cmName)` 改签名为 `LoadConfigFromCM(namespace, cmName)`,`deviceConfigNamespaces` 把配置命名空间排在 legacy `kube-system`/`volcano-system` 前;`loadConfigFromCM` 只在 `IsNotFound` 时才试下一个命名空间,Forbidden/传输错误直接返回不被 legacy 回退掩盖;整体加 30s 超时。配套 `cmd/vgpu/main.go` 新增 `--device-config-namespace` flag(env `DEVICE_CONFIG_NAMESPACE`)。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -func LoadConfigFromCM(cmName string) (*config.Config, error) {
  -	cm, err := client.GetClient().CoreV1().ConfigMaps("kube-system").Get(...)
  -	if err != nil {
  -		cm, err = client.GetClient().CoreV1().ConfigMaps("volcano-system").Get(...)
  +func LoadConfigFromCM(namespace, cmName string) (*config.Config, error) {
  +	return loadConfigFromCM(ctx, client.GetClient(), deviceConfigNamespaces(namespace), cmName)
  +func loadConfigFromCM(ctx, cs, namespaces, cmName) (*config.Config, error) {
  +		if !apierrors.IsNotFound(err) { return nil, err }   // 非 NotFound 不回退
  ```
  </details>

- **daemonset:HOOK_PATH 迁移 + runtimeClassName + lib 卷**:`HOOK_PATH` 从 `/tmp/vgpu` 改到 `/usr/local/vgpu`,并新增 `lib` 卷挂到同路径(vgpu-monitor 也据此指向 plugin 的 HOOK_PATH);新增 `runtimeClassName` 支持与 `DEVICE_CONFIG_NAMESPACE` env 透传。这是部署侧的实际行为变化,升级需留意 hook 路径变更。
  <details><summary>代码依据 deployments/helm/.../daemonset.yaml</summary>

  ```diff
  +      {{- if .Values.runtimeClassName }}
  +      runtimeClassName: {{ .Values.runtimeClassName }}
  +        - name: DEVICE_CONFIG_NAMESPACE
  +          value: {{ .Values.namespace | quote }}
  -          value: "/tmp/vgpu"          # HOOK_PATH
  +          value: "/usr/local/vgpu"
  +        - name: lib
  +          mountPath: /usr/local/vgpu
  ```
  </details>

- **驱动 580 利用率修复**:`libvgpu` 子模块 bump(commit `fix: update HAMi-core for driver 580 utilization`),对应 NVIDIA driver 580 下利用率读取的 HAMi-core 侧修正(2 行子模块指针变更,未展开子模块 hunk)。另有一批 `.github` issue/PR 模板与 AI 披露、最小化诊断数据采集的 docs,属社区治理非能力变化。

### 后续发展方向 [AI]
- Volcano 集成路径本期偏"运维健壮性"(命名空间可配、错误不吞、超时、hook 路径规整)而非新调度能力;driver 580 适配说明 HAMi-core 仍在跟进新驱动的利用率统计。证据只覆盖 util.go 与 helm 模板,未见调度打分逻辑改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi-core:无新提交
- Project-HAMi/ascend-device-plugin:无新提交
- Project-HAMi/HAMi-WebUI:无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=379547bb382783fc79e39f8f2f1b644bba6ed715 branch=master release=v2.10.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a5231c7f4524e5d98f5200fde47f97b06356fcbe branch=main release=— scanned=2026-09-22 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=806072e6eb8594f1989913085ad4b87bc5d61af5 branch=main release=— scanned=2026-09-22 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=074d93a8e1ca4f357fb1f4946f0566ced93641a6 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-22 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=b2af8ecc94a2330a6f11ab189522f16f328495bd branch=main release=v1.3.0 scanned=2026-09-22 -->
</content>
</invoke>
