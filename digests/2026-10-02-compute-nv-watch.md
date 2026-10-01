# NVIDIA 算力栈 diff 雷达 2026-10-02

## 摘要
- KAI-Scheduler 继续推进 NvFractions 分数共享:新增 `gpu-memory.limit` / `gpu-fraction.limit` 两个 limit 短写注解,把原本塞在一个文件里的 nvfractions 插件拆成 mutation.go + validation.go,并新增 request/limit 一致性校验——分数共享从"只能设请求"走向"请求+上限"的双阈值模型。
- L2 修了个硬 bug:k8s-device-plugin 把 `cuDeviceTotalMem` 换成 `cuDeviceTotalMem_v2`,修复 >4 GiB 显存设备被旧 API 截断在 UINT_MAX 的错误上报(几乎所有现代卡都受影响)。
- L1 两处工程化改动:gpu-operator 的 must-gather 开始采集 DRA 资源(DeviceClass/ResourceSlice)与 GPUCluster,是 DRA 路径落地成熟度的侧写;container-toolkit 修 Docker `daemon.json` 中 `runtimes:null` 等空字段的类型断言 panic + 去重重复可见设备。
- 无 API/CRD 字段增删,无弃用/移除信号。DRA 主仓(dra-driver-nvidia-gpu)、dcgm/DCGM/mig-parted/gpu-driver-container 本日全部无新提交。

## 当日重要改变
- KAI-Scheduler [新能力] NvFractions 模式新增 `gpu-memory.limit` 与 `gpu-fraction.limit` limit 短写注解支持,分数 GPU 从单一请求值扩展到"请求+上限"双阈值 https://github.com/kai-scheduler/KAI-Scheduler/pull/2238
- k8s-device-plugin [修复/正确性] 显存上报改用 `cuDeviceTotalMem_v2`,修复 >4 GiB 卡被 pre-CUDA-3.2 旧 API 截断到 UINT_MAX 的错误容量 https://github.com/NVIDIA/k8s-device-plugin/commit/3b2b89ecd543ec84f6681aa97569467b1af058a1

## kai-scheduler/KAI-Scheduler: a6941e62 -> 5982e4bf
- 比较: a6941e624a0956117d89abe50880ad36f65b2f66 -> 5982e4bf | ahead=4 | files=12 | Release: v0.18.2
- https://github.com/kai-scheduler/KAI-Scheduler/compare/a6941e624a0956117d89abe50880ad36f65b2f66...5982e4bf5559120d1fb5650ebec7fe400e85bc95

### AI 总结重点(源码 diff 为据)
- **NvFractions 插件按职责拆分:nvfractions.go 从 ~169 行瘦身到 ~16 行,只保留 struct/New/Name,Mutate 逻辑移到新 mutation.go、Validate 移到新 validation.go**。这是为下面的 limit 能力腾结构,原来 Mutate/Validate/adjustFractionalMemoryAnnotations 全挤在一个文件。
  <details><summary>代码依据 pkg/admission/webhook/v1alpha2/nvfractions/nvfractions.go</summary>

  ```diff
  -// NvFractions is the admission plugin for the NvFractions GPU-sharing mode. It
  -// validates fractional GPU requests ... and normalizes legacy memory annotations ...
  +// NvFractions translates legacy GPU memory requests and validates fractional
  +// requests and binder-owned device annotations.
   type NvFractions struct {
   	binderServiceAccountUsername string
   }
  -func (p *NvFractions) Validate(ctx context.Context, oldPod, pod *v1.Pod) error { ... }
  -func (p *NvFractions) Mutate(pod *v1.Pod) error { ... }
  -func adjustFractionalMemoryAnnotations(pod *v1.Pod, containerName string) error { ... }
  ```
  </details>

- **Mutate 从"只翻译 legacy gpu-memory"扩展为翻译三类 legacy 注解:memory、memory.limit、gpu-fraction.limit**(新 mutation.go)。新增 `translateLegacyMemoryLimit` / `translateLegacyGpuFractionLimit`,各自把旧注解写到按容器计算的 NvFractions limit 目标注解,且目标若已存在值不同则报冲突(幂等+防冲突)。
  <details><summary>代码依据 pkg/admission/webhook/v1alpha2/nvfractions/mutation.go</summary>

  ```diff
  +func (p *NvFractions) Mutate(pod *v1.Pod) error {
  +	...
  +	err = translateLegacyMemory(pod, containerRef.Container.Name)
  +	err = translateLegacyMemoryLimit(pod, containerRef.Container.Name)
  +	err = translateLegacyGpuFractionLimit(pod, containerRef.Container.Name)
  +}
  +func translateLegacyMemory(pod *v1.Pod, containerName string) error {
  +	target := resources.CalcGpuFractionAnnotationForContainer(containerName)
  +	if _, exists := pod.Annotations[target]; !exists {
  +		pod.Annotations[target] = value
  +	} else if pod.Annotations[target] != value {
  +		return fmt.Errorf("gpu-memory annotation conflicts with %s annotation", target)
  +	}
  +}
  ```
  </details>

- **新增 limit 短写注解的语义校验(gpu_sharing_validation.go +70):limit 必须与对应 request 共存、且 limit 要严格大于 request**。`validateFractionLimitShorthand` 要求 `gpu-fraction.limit` 必须同时有 `gpu-fraction`,limit ∈ (0,1) 且 > fraction;`validateMemoryLimitShorthand` 要求 `gpu-memory.limit` 必须同时有 `gpu-memory`。同时放宽了原来"limit 不能与 legacy 注解共存"的硬约束:legacy gpu-memory request 现在可与翻译出来的 memory.limit 短写并存。
  <details><summary>代码依据 pkg/common/resources/gpu_sharing_validation.go</summary>

  ```diff
  +	if err := validateShorthandLimits(pod); err != nil {
  +		return err
  +	}
   	legacyMemoryStr, hasLegacyMemory := pod.Annotations[constants.GpuMemory]
  -	// NvFractions limit cannot coexist with legacy fraction annotations;
  -	if req.Limit != nil && (hasLegacyFraction || hasLegacyMemory) {
  +	// A legacy gpu-memory request may accompany a translated shorthand limit.
  +	_, hasMemoryLimitShorthand := pod.Annotations[constants.GpuMemoryLimit]
  +	if req.Limit != nil && (hasLegacyFraction || (hasLegacyMemory && !hasMemoryLimitShorthand)) {
  +func validateFractionLimitShorthand(pod *v1.Pod) error {
  +	if limit <= fraction {
  +		return fmt.Errorf("%s value (%s) must be greater than %s value (%s)", ...)
  ```
  </details>

- **底层 gpu-fractioning OCI chart 依赖从 v0.1.3 连跳到 v0.1.6**(Chart.lock),与上面 webhook 层的 limit 能力配套下沉到 fractioning 运行时组件。
  <details><summary>代码依据 deployments/kai-scheduler/Chart.lock</summary>

  ```diff
  -  version: v0.1.3
  +  version: v0.1.6
  ```
  </details>

### 后续发展方向 [AI]
- NvFractions 正在把分数共享做成"请求+上限"的可超售模型(request 是保底、limit 是弹性上限),语义上向 K8s requests/limits 对齐。证据只覆盖 admission webhook 的注解翻译与校验层(mutation/validation),运行时如何按 limit 真正施加显存/算力上限在 gpu-fractioning v0.1.6 组件里,本 diff 未见。
- device 注解的授权仍收敛在 binder service account(validation.go 的 `authorizeDeviceAnnotationChange`),说明"谁能改可见设备"是安全边界;未见对普通用户开放该注解的迹象。

## NVIDIA/k8s-device-plugin: a6ddd025 -> 3b2b89ec
- 比较: a6ddd0252a5b84f24dbff8e2f3e253e5dfb67fc7 -> 3b2b89ec | ahead=2 | files=1 | Release: v0.20.1
- https://github.com/NVIDIA/k8s-device-plugin/compare/a6ddd0252a5b84f24dbff8e2f3e253e5dfb67fc7...3b2b89ecd543ec84f6681aa97569467b1af058a1

### AI 总结重点(源码 diff 为据)
- **显存查询从 `cuDeviceTotalMem` 切到 `cuDeviceTotalMem_v2`,修复 >4 GiB 显存被错误截断**。libcuda 导出的未版本化符号是 pre-CUDA-3.2 的旧 API,写入 `unsigned int` 并在 UINT_MAX(4 GiB)饱和;改为显式声明并调用 `_v2` 版本写 `size_t`,现代大显存卡才能报对真实容量。这是影响几乎所有在用 GPU 的容量上报正确性 bug。
  <details><summary>代码依据 internal/cuda/cuda.go</summary>

  ```diff
  -CUresult CUDAAPI cuDeviceTotalMem(size_t *bytes, CUdevice dev);
  +// cuda.h defines cuDeviceTotalMem as cuDeviceTotalMem_v2. The unversioned symbol
  +// ... saturates at UINT_MAX, so it must not be used on devices with more than 4 GiB
  +CUresult CUDAAPI cuDeviceTotalMem_v2(size_t *bytes, CUdevice dev);
   func cuDeviceTotalMem(bytes *uint64, dev Device) Result {
  -	_ret := C.cuDeviceTotalMem(cBytes, cDev)
  +	_ret := C.cuDeviceTotalMem_v2(cBytes, cDev)
  ```
  </details>

### 后续发展方向 [AI]
- 该调用用于 device-plugin 内部按显存量做切分/上报判断(如 MPS/time-slicing 的容量基准),修复后相关共享模式的显存计费基准才准确。证据仅覆盖 cuda.go 这一个 CGo 封装函数,未见上层消费点改动。

## NVIDIA/gpu-operator: 75210df1 -> 8587e97f
- 比较: 75210df15b7322f999a43448221612a0b83f5f3b -> 8587e97f | ahead=3 | files=2 | Release: v26.7.1
- https://github.com/NVIDIA/gpu-operator/compare/75210df15b7322f999a43448221612a0b83f5f3b...8587e97f9df8e0ae12937548619543f74f19612f

### AI 总结重点(源码 diff 为据)
- **must-gather 诊断脚本开始采集 DRA 相关资源与 GPUCluster**:新增抓取 `gpuclusters.nvidia.com`、集群范围的 `deviceclasses.resource.k8s.io`,以及按 driver(`gpu.nvidia.com` 与 `compute-domain.nvidia.com` 两个)分别导出 `resourceslices`。说明 DRA driver(含 IMEX compute-domain)已是官方支持排障范畴的一等公民。
  <details><summary>代码依据 hack/must-gather.sh</summary>

  ```diff
  +GPU_CLUSTER_NAME=$($K get gpuclusters.nvidia.com -oname --ignore-not-found)
  +DEVICE_CLASSES=$($K get deviceclasses.resource.k8s.io -oname --ignore-not-found)
  +NVIDIA_DRA_DRIVERS="gpu.nvidia.com compute-domain.nvidia.com"
  +for driver in ${NVIDIA_DRA_DRIVERS}; do
  +    $K get resourceslices.resource.k8s.io --field-selector "spec.driver=${driver}" -oyaml ...
  ```
  </details>

- **operator ClusterRole 为 `events.k8s.io` 的 events 资源补 `patch` 动词**,让 operator 能更新(而不仅创建)事件,属权限修复。
  <details><summary>代码依据 deployments/gpu-operator/templates/clusterrole.yaml</summary>

  ```diff
     - delete
  +  - patch
   - apiGroups:
     - events.k8s.io
  ```
  </details>

### 后续发展方向 [AI]
- 排障工具把 DRA 资源(DeviceClass/ResourceSlice/compute-domain)纳入默认采集,是 gpu-operator 把 DRA 当成生产路径而非实验特性的间接信号。证据仅为 must-gather 脚本,ClusterPolicy CRD(`clusterpolicy_types.go`)本日未动,DRA 编排主逻辑未见改动。

## NVIDIA/nvidia-container-toolkit: 84e2c2c1 -> faef9c9e
- 比较: 84e2c2c182bfa0b2edab4fdca27e5197faba0ca7 -> faef9c9e | ahead=5 | files=4 | Release: v1.20.1
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/84e2c2c182bfa0b2edab4fdca27e5197faba0ca7...faef9c9e6770a59001c9e5f7a9c7adbde9f79685

### AI 总结重点(源码 diff 为据)
- **Docker `daemon.json` 配置读写全面改用安全类型断言(`v, ok := x.(T)`),修复 `runtimes:null` / `default-runtime:null` 等空字段导致的 panic**。原来 `config["runtimes"].(map[string]any)` 在值为 null 时会 panic;AddRuntime/RemoveRuntime/UpdateDefaultRuntime/GetRuntimeConfig 四处全部改为带 ok 的断言,空字段安全跳过。
  <details><summary>代码依据 pkg/config/engine/docker/docker.go</summary>

  ```diff
  -	if _, exists := config["runtimes"]; exists {
  -		runtimes = config["runtimes"].(map[string]any)
  +	if rt, ok := config["runtimes"].(map[string]any); ok {
  +		runtimes = rt
   	}
  ```
  </details>

- **可见设备去重:`NVIDIA_VISIBLE_DEVICES` 里重复的设备 ID 只返回一次**。newDevices 构建 lookup 时对已存在的 id 跳过,避免同一 GPU 因重复列举(或跨 swarm resource 环境变量)被多次暴露。
  <details><summary>代码依据 internal/config/image/devices.go</summary>

  ```diff
   	for id := range strings.SplitSeq(commaSeparated, ",") {
  +		if _, exists := lookup[id]; exists {
  +			continue
  +		}
   		lookup[id] = i
  ```
  </details>

### 后续发展方向 [AI]
- 两处都是健壮性修复(null 容忍、去重),无行为语义或配置面扩展。证据覆盖 docker 配置引擎与 image 设备解析,未见 CDI/runtime hook 主路径改动。

## 本期无实质改动(折叠)
<details><summary>5 仓本日无新提交</summary>

- NVIDIA/gpu-driver-container — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(release v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(release 4.8.4)
- NVIDIA/DCGM — 无新提交(branch master)
- NVIDIA/mig-parted — 无新提交(release v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=8587e97f9df8e0ae12937548619543f74f19612f branch=main release=v26.7.1 scanned=2026-10-02 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=faef9c9e6770a59001c9e5f7a9c7adbde9f79685 branch=main release=v1.20.1 scanned=2026-10-02 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=73b03d850b0d2468a75341e5054315aee49f966d branch=main release=— scanned=2026-10-02 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=3b2b89ecd543ec84f6681aa97569467b1af058a1 branch=main release=v0.20.1 scanned=2026-10-02 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=495bf4c59b9423080aa1fe2163955f44a495012c branch=main release=v0.5.0 scanned=2026-10-02 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-02 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-02 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=a668e5c92da14856769edcb0fec27946abf8920c branch=main release=v0.15.1 scanned=2026-10-02 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=5982e4bf5559120d1fb5650ebec7fe400e85bc95 branch=main release=v0.18.2 scanned=2026-10-02 -->
