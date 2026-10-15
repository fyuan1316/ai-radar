# HAMi diff 雷达 2026-10-16

## 摘要
- HAMi 主仓三条实质提交,核心是 **remote mode(Lupine 网络远程 GPU)能力大改**(#3247):新增客户端库自动注入(init 容器 + emptyDir,免定制镜像),并把"运行模式"的唯一真相从节点 label 反转为 per-node ConfigMap(`hami-core`/`mig`/`remote`),再由插件把 label 当"发现产物"同步。这是 HAMi 里区别于 hook 软切分、也区别于 DRA 的**第三条路径(远程/解耦 GPU)**。
- 健康检查纠错(#3255):enflame/iluvatar/mthreads 等厂商此前 `CheckHealth` 恒真(`return true,true`),现改为按节点 allocatable 显存/算力是否 >0 判活,掉零即从调度缓存摘除——此前这些卡**永远不会被标记不健康**。
- Chart 加固(#3238):`kubeVersion` 下限从 `>=1.18` 抬到 `>=1.23`(放弃 1.18–1.22),PSP 模板在 K8s ≥1.25 直接 `fail`(policy/v1beta1 已移除),certgen/mock 镜像全部 pin 到 digest。其余 3 仓无新提交。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 远程 GPU 新增客户端库自动注入:新文件 `pkg/device/remotegpu/client.go`,用 init 容器把 Lupine 客户端库 + `libnghttp2.so.14` 拷进工作负载,免定制镜像;Pod 注解 `hami.io/remote-gpu-client-injection: "disabled"` 可退出。https://github.com/Project-HAMi/HAMi/pull/3247
- Project-HAMi/HAMi [弃用/移除] Chart 放弃 K8s 1.18–1.22(`kubeVersion >=1.23`),PSP 在 ≥1.25 集群构造即 `fail`。https://github.com/Project-HAMi/HAMi/pull/3238

## Project-HAMi/HAMi: 6d9ab479 -> b385c823
- 比较: 6d9ab479cd090b25270c295eac92ecb554300c8f -> b385c823 | ahead=6 | files=46 | Release: v2.10.0(未跨档)
- 比较页: https://github.com/Project-HAMi/HAMi/compare/6d9ab479cd090b25270c295eac92ecb554300c8f...b385c82333ed98c7c036d2e29d5d1d312f5be5b5
- 实质提交 3 条(另 3 条为 deps bump):#3247 远程模式增强、#3255 健康检查纠错、#3238 Chart 加固。

### AI 总结重点(源码 diff 为据)

- **[新能力] 远程 GPU 客户端库自动注入**:新增 `pkg/device/remotegpu/client.go`。定义注入卷名 `hami-lupine-client`、挂载点 `/opt/lupine/lib` 与退出注解 `ClientInjectionAnnotation = "hami.io/remote-gpu-client-injection"`;`clientDeliveryContainer()` 构造一个 init 容器,跑 shell 脚本把 `RemoteGPUClientImage` 里的客户端库 `cp` 到 emptyDir,并从 Debian/Ubuntu multiarch 及 `/usr/lib64` 等目录捞 `libnghttp2.so.14`(找不到即失败并报诊断);`armClientLibraries()` 在改 Pod 前做冲突校验——保留卷/init 容器名被工作负载占用即报错,绝不静默复用用户资源。效果:远程 GPU 工作负载可直接用上游 `nvidia/cuda`、`vllm/vllm-openai` 镜像,HAMi 自动补注入库 + 环境变量,无需定制镜像或本地 NVIDIA driver(设 `NVIDIA_VISIBLE_DEVICES=void` 避免挂本地 driver)。
  <details><summary>代码依据 pkg/device/remotegpu/client.go</summary>

  ```diff
  +const (
  +	clientVolumeName = "hami-lupine-client"
  +	clientMountPath  = "/opt/lupine/lib"
  +	// ClientInjectionAnnotation opts out when a workload delivers its own libraries.
  +	ClientInjectionAnnotation = "hami.io/remote-gpu-client-injection"
  +)
  +func clientInjectionEnabled(pod *corev1.Pod) bool {
  +	return pod != nil && RemoteGPUClientImage != "" && pod.Annotations[ClientInjectionAnnotation] != "disabled"
  +}
  +func armClientLibraries(ctr *corev1.Container, pod *corev1.Pod) error {
  +	if !clientInjectionEnabled(pod) { return nil }
  +	for _, v := range pod.Spec.Volumes {
  +		if v.Name == clientVolumeName && !reflect.DeepEqual(v.VolumeSource, corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}) {
  +			return fmt.Errorf("reserved remote GPU volume %q conflicts with workload", clientVolumeName)
  ```
  </details>

- **[架构方向] 运行模式真相源反转:label → ConfigMap**。原 `resolveOperatingMode(configured, node)` 以节点上的 `hami.io/lupine-server` label **决定**模式(有 label 即 RemoteMode,忽略配置文件);现 `resolveOperatingMode(configured)` 只认 per-node ConfigMap 的 `operatingmode`(`hami-core`/`mig`/`remote`,空值回退 `HamiCoreMode`),新增的 `syncLupineServerLabel()` 反过来**把模式镜像成 label**(remote 且未打标则 `PatchNodeLabels` 补空值标,非 remote 却带标则清除)。即 label 从"配置输入"降级为"调度器发现用的产物",消除了 label 与配置文件两处来源漂移导致"节点半在 fleet"的问题。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  -func resolveOperatingMode(configured string, node *corev1.Node) string {
  -	if node != nil {
  -		if _, ok := node.Labels[remotegpu.LupineServerLabel]; ok { return nvidia.RemoteMode }
  -	}
  -	if configured == nvidia.RemoteMode { ... return nvidia.HamiCoreMode }
  -	return configured
  -}
  +func resolveOperatingMode(configured string) string {
  +	if configured == "" { return nvidia.HamiCoreMode }
  +	return configured
  +}
  +func syncLupineServerLabel(mode string, node *corev1.Node) error {
  +	_, labelled := node.Labels[remotegpu.LupineServerLabel]
  +	if mode == nvidia.RemoteMode {
  +		if labelled { return nil }
  +		return util.PatchNodeLabels(node, map[string]string{remotegpu.LupineServerLabel: ""})
  +	}
  ```
  </details>

- 配套新增 `util.PatchNodeLabels` / `PatchNodeLabelsWithContext` / `RemoveNodeLabels`(merge patch,空串是刻意的 label 值而非省略),供上面的模式→label 同步落地。示例 `default_use.yaml`/`vllm_deployment.yaml` 改用上游镜像、`tensor-parallel-size=2`、真实 CUDA 核验证(`35+7==42`)替代 `nvidia-smi`;`charts/hami/values.yaml` 把 `remotegpu` 配置说明从"按 label 声明"改写为"按 `operatingmode: remote` 声明",新增 `clientImage`(默认 `ghcr.io/lupinemachines/lupine-client:cuda-13.3.1-ubuntu24.04`)。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
     remotegpu:
  -    # Label each lupine node with hami.io/lupine-server, optionally setting the label value to the port.
  +    # Mark lupine nodes with operatingmode: remote in devicePlugin.nodeConfiguration
  +    # (peer to hami-core / mig). The device plugin applies hami.io/lupine-server;
  +    # -- Client image used to deliver Lupine libraries and libnghttp2 for the CUDA/vLLM examples; empty disables delivery.
  +    clientImage: "ghcr.io/lupinemachines/lupine-client:cuda-13.3.1-ubuntu24.04"
  ```
  </details>

- **[纠错] 多厂商健康检查从"恒真"改为按 allocatable 判活**(#3255)。新增 `device.AllocatableHealth(devType, nodeName, allocatable, cardCount, anno)`:allocatable ≤0 时 `ForgetRegisteredDevices` 并返回不健康,否则按 `cardCount+anno` 指纹判断是否需重读设备。enflame/iluvatar/mthreads 的 `CheckHealth` 从直接 `return true, true` 改为读节点 `Status.Allocatable` 的显存/算力(DRS/软切分厂商按 mem/core 发布,而非 card-count 资源),任一 >0 才算在线。此前这些厂商节点**永远健康**,插件停发资源也不会被调度器摘除。
  <details><summary>代码依据 pkg/device/devices.go · pkg/device/iluvatar/device.go</summary>

  ```diff
  +// AllocatableHealth reports whether a node should stay in the scheduler cache.
  +func AllocatableHealth(devType, nodeName string, allocatable, cardCount int64, anno string) (bool, bool) {
  +	if allocatable <= 0 { ForgetRegisteredDevices(devType, nodeName); return false, false }
  +	observed := strconv.FormatInt(cardCount, 10) + "\n" + anno
  +	return true, registerAnnoChanged(devType, nodeName, observed)
  +}
  ...
  -func (dev *IluvatarDevices) CheckHealth(devType string, n *corev1.Node) (bool, bool) {
  -	return device.CheckHealth(devType, dev.GetResourceNames().ResourceCountName, n, n.Annotations[dev.nodeRegisterAnno])
  +	memQty := n.Status.Allocatable[corev1.ResourceName(dev.config.ResourceMemoryName)]
  +	coreQty := n.Status.Allocatable[corev1.ResourceName(dev.config.ResourceCoreName)]
  +	if mem > 0 || core > 0 { signal = 1 }
  +	return device.AllocatableHealth(devType, n.Name, signal, iluvatarAnnotationDevices(anno), anno)
  ```
  </details>

- **[弃用/移除] Chart 支持矩阵收窄 + PSP 守卫**(#3238)。`Chart.yaml` 的 `kubeVersion` 从 `>= 1.18.0-0` 抬到 `>= 1.23.0-0`;PSP 模板新增 `semverCompare ">=1.25-0"` 即 `fail`(policy/v1beta1 的 PodSecurityPolicy 在 K8s 1.25 已删除);certgen(v1.5.2 / v1.1.1)、mock-device-plugin(1.0.1)镜像全部改 `tag@sha256:...` 按 digest 固定。
  <details><summary>代码依据 charts/hami/Chart.yaml · templates/scheduler/job-patch/psp.yaml</summary>

  ```diff
  -kubeVersion: ">= 1.18.0-0"
  +kubeVersion: ">= 1.23.0-0"
  ...
   {{- if .Values.podSecurityPolicy.enabled }}
  +{{- if semverCompare ">=1.25-0" .Capabilities.KubeVersion.Version }}
  +{{- fail "podSecurityPolicy.enabled needs the policy/v1beta1 PodSecurityPolicy API, which Kubernetes removed in 1.25; leave it disabled on this cluster" }}
  +{{- end }}
   apiVersion: policy/v1beta1
  ```
  </details>

### 后续发展方向 [AI]
- **远程/解耦 GPU(Lupine)正从"能跑"走向"产品化易用"**:本期把"要不要定制镜像、模式从哪声明、label 谁维护"三块粗糙边界都收口——客户端库自动注入 + 模式单点声明(ConfigMap)+ label 自动同步。这条路径既非 HAMi-core 的 CUDA hook 软切分、也非 K8s DRA,而是网络远程 GPU(一个 Pod 独占整台 server),是 HAMi 的第三类供给形态,值得单独跟踪它与 hook 软切分在配额/显存强制上的复用(远程路径仍靠 HAMi-core 注入做 memory enforcement)。证据只覆盖 device-plugin 侧的 server.go/client.go/util.go 与 chart,未见调度器 pool 侧如何按新 label 发现 server 的改动。
- **健康检查正按"厂商资源模型"重构**:恒真 `CheckHealth` 被逐厂商替换为 allocatable 判活,说明 HAMi 在统一"card-count 型"与"mem/core 型(DRS/软切分)"两类设备的存活语义。证据覆盖 enflame/iluvatar/mthreads/nvidia/cambricon 的 device.go 与新 `AllocatableHealth` helper,未逐一确认是否所有厂商都已切换(hygon/kunlun 等本次是否同步需看全量 diff)。
- 软隔离内核层(HAMi-core)本期无提交,CUDA hook 显存/算力切分能力边界无变化。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos(仅保锚点)</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=b385c82333ed98c7c036d2e29d5d1d312f5be5b5 branch=master release=v2.10.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a55248ecc6e2530602875054e2d334645d08f35b branch=main release=— scanned=2026-10-16 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-16 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf890f96118f38a85f71d31da2e74ca95aeb1a0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-16 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=09f0b75b0773c2caf835933936f0301f7efc248c branch=main release=v1.3.0 scanned=2026-10-16 -->
