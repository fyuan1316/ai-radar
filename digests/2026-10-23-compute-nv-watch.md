# NVIDIA 算力栈 diff 雷达 2026-10-23

## 摘要
- **gpu-operator 把"自认证测试套件"搬进主仓**:新增 `internal/certification/` 顶层包(+2000 行),以代码方式对 ClusterPolicy 的 rdma/mig/gpu_sharing/gdrcopy/image-updates 等能力做端到端认证,跑前抓集群快照、改 CR、跑完回滚。企业级一致性验证productization 信号。
- **container-toolkit** 两个稳健性修复:CDI spec 写盘时先 close 临时 fd 再重开(防描述符泄漏);能力校验 panic 信息改报"配置允许集"而非请求交集。
- **KAI-Scheduler** 修 Ray in-tree autoscaling 的 gang 最小值:开启自动扩缩时用 `minReplicas`(含 0/未设)而非 desired replicas 作为 worker gang 下限,打通 Ray scale-from-zero。

## 当日重要改变
- NVIDIA/gpu-operator [新能力/架构方向] 新增顶层包 `internal/certification/`,把 GPU Operator 自认证测试从外部搬进主仓;含环境快照采集、NVIDIADriver CR 动态读写、测试后原始配置回滚、HTML 报告生成。证据见下 gpu-operator 节。 https://github.com/NVIDIA/gpu-operator/compare/932f9068433d031244b986ed253e14263aa22e8e...e136269e743140a5e9669a8fd9d525aff422f99c
- kai-scheduler/KAI-Scheduler [行为变更] Ray 自动扩缩场景的 worker gang 最小值语义变了:`calcJobNumOfPodsAndSubGroups` 现按 `enableInTreeAutoscaling` 判定,开启时即便 `minReplicas=0/未设` 也取之作下限(原逻辑仅 `minReplicas>0` 才用)。证据见下 KAI 节。 https://github.com/kai-scheduler/KAI-Scheduler/pull/2272

## NVIDIA/gpu-operator: 932f9068 -> e136269e
- 比较: 932f9068433d031244b986ed253e14263aa22e8e -> e136269e | ahead=7 | files=143 | Release: v26.7.2
- https://github.com/NVIDIA/gpu-operator/compare/932f9068433d031244b986ed253e14263aa22e8e...e136269e743140a5e9669a8fd9d525aff422f99c

### AI 总结重点(源码 diff 为据)
- **新增自认证(certification)子系统,是本次最大改动**:新建 `internal/certification/` 包树,核心是 `Runner.Run()` 执行一组 TestSet,跑前先 `Build()` 一个 `EnvironmentSnapshot`(集群/算子/策略/驱动/节点全量状态),再 `CaptureOriginalSettings()` 存下当前 ClusterPolicy 与 NVIDIADriver CR,跑完按 TestSet 回滚。相当于把过去散落在外的 GPU Operator 一致性验证做成了算子仓内置的代码化测试框架。
  <details><summary>代码依据 internal/certification/runner.go</summary>

  ```diff
  +func (r *Runner) Run(ctx context.Context) *SuiteResult {
  +	// Capture environment snapshot before running tests
  +	suite.Environment, _ = environment.NewSnapshotBuilder(r.clients, r.config.Namespace).Build(ctx)
  +	// Capture original settings for restoration after each TestSet.
  +	// Retry on transient errors — without this, all restoration is silently
  +	// disabled and tests mutate the cluster with no rollback.
  +	originalSettings, err := CaptureOriginalSettings(ctx, r.clients, timeout)
  +	if err != nil {
  +		log.Println("Aborting — running tests without rollback protection risks leaving the cluster in a modified state.")
  +		return suite
  +	}
  +	testSets := r.selectTestSets()
  +	for _, ts := range testSets { ... }
  ```
  </details>
- **认证框架直接动态读写 NVIDIADriver CR(`nvidia.com/v1alpha1`)**:新增 `Clients.ListNVIDIADrivers` 与 `ModifyNVIDIADriver`(走 `dynamic.Resource(nvidiaDriverGVR).Patch` 打 JSONPatch),以及 `HasDriverPods` 判断驱动是否由算子托管。说明认证用例会主动改驱动配置再验证重建,而非只读探测。
  <details><summary>代码依据 internal/certification/k8s/driver.go</summary>

  ```diff
  +var nvidiaDriverGVR = schema.GroupVersionResource{
  +	Group: "nvidia.com", Version: "v1alpha1", Resource: "nvidiadrivers"}
  +func (c *Clients) ModifyNVIDIADriver(ctx context.Context, name string, patchJSON []byte) error {
  +	_, err := c.dynamic.Resource(nvidiaDriverGVR).Patch(
  +		ctx, name, types.JSONPatchType, patchJSON, metav1.PatchOptions{})
  +}
  +// HasDriverPods ... Returns false when the driver is disabled or the host has a pre-installed driver.
  ```
  </details>
- **环境快照建模了驱动的容器化关键维度**:`DriverInfo` 结构体显式记录 `UsePrecompiled`、`UseOpenKernelModules`、`Repository`、`Image`、`DriverVersion`,`ClusterInfo` 记录 GPU 节点数/PCI 节点/K8s 版本/PodSecurityAdmission。这正是 NVIDIA 关心的"驱动预编译/开源内核模块矩阵"信号被结构化进认证输出。
  <details><summary>代码依据 internal/certification/environment/types.go</summary>

  ```diff
  +type DriverInfo struct {
  +	DriverVersion        string `json:"driverVersion,omitempty"`
  +	UsePrecompiled       bool   `json:"usePrecompiled"`
  +	UseOpenKernelModules bool   `json:"useOpenKernelModules"`
  +	...
  +}
  ```
  </details>
- **认证覆盖的能力面**:新增 `testsuite/clusterpolicy/` 下 rdma、mig、gpu_sharing、gdrcopy、image_updates 等用例文件,`testsuite/baseline/` 下 gfd_labels、pytorch_workload 等基线,并有 `reporting/html.go` 的 `GenerateHTMLReport` 产出带 NVIDIA 配色的 HTML 报告。覆盖面=GPU Operator 的主要企业能力集。
  <details><summary>代码依据(信号文件清单,新增)</summary>

  ```
  internal/certification/testsuite/clusterpolicy/rdma.go         (+382)
  internal/certification/testsuite/clusterpolicy/mig.go          (+333)
  internal/certification/testsuite/clusterpolicy/gpu_sharing.go  (+234)
  internal/certification/testsuite/clusterpolicy/gdrcopy.go      (+209)
  internal/certification/testsuite/clusterpolicy/image_updates.go(+189)
  internal/certification/reporting/html.go                       (+264)
  ```
  </details>
- 其余 3 个 commit 本次未落入 top-8 patch 节选(无 hunk 依据,仅记录不展开结论):`fix: fail the node pool when its additional driver configs do not render`、`fix[device-plugin] add DEVICE_LIST_STRATEGY env var guardrail`、`return errors from loadPodSpec instead of panicking (#3108)`。前两条关系到多驱动配置渲染失败处理与 device-plugin 的 DEVICE_LIST_STRATEGY 校验,下期若有后续改动再追。

### 后续发展方向 [AI]
- 这是一个明确的**企业级一致性/认证能力 productization 信号**:NVIDIA 把"你的 GPU Operator 部署是否合规可用"做成算子内置、可自动跑并产出报告的代码框架。对我们产品的启示——对标 OAI,我们也需要一套可被客户/伙伴自助运行的 GPU 栈一致性验证(带快照+回滚+HTML 报告),而不是靠人工 checklist。
- 证据只覆盖框架骨架(runner/clients/types/reporting)与用例文件存在性,**未逐个读 clusterpolicy 用例的断言逻辑**,无法判断每项能力的具体判定标准;THIRD_PARTY_NOTICES 新增 gorilla/websocket、moby/spdystream、k8s.io/streaming 依赖,提示框架用到了 pod exec/attach 流式通道(认证需进容器跑负载)。

## NVIDIA/nvidia-container-toolkit: 44f1c6ef -> d2454dea
- 比较: 44f1c6ef98c9f82ee53c6018086a40b436260f9e -> d2454dea | ahead=4 | files=3 | Release: v1.20.1
- https://github.com/NVIDIA/nvidia-container-toolkit/compare/44f1c6ef98c9f82ee53c6018086a40b436260f9e...d2454dea06a2e851f321d396ba1ef650dc19d350

### AI 总结重点(源码 diff 为据)
- **CDI spec 写盘修复描述符泄漏**:`(*spec).WriteTo` 里把 `tmpFile.Close()` 从"写内容之后、rename 之前"移到了"创建临时文件之后、`os.OpenRoot(tmpDir)` 打开目录之前"。即先关掉临时文件句柄再通过 root 目录重开,避免写入出错路径上临时文件描述符未释放。
  <details><summary>代码依据 pkg/nvcdi/spec/spec.go</summary>

  ```diff
  +	if err := tmpFile.Close(); err != nil {
  +		return 0, fmt.Errorf("failed to close temporary file: %w", err)
  +	}
  	tmpDir, tmpFileName := filepath.Split(tmpFile.Name())
  	tmpDirRoot, err := os.OpenRoot(tmpDir)
  ...
  -	if err := tmpFile.Close(); err != nil {
  -		return 0, fmt.Errorf("failed to close temporary file: %w", err)
  -	}
  	savedFile, err := tmpDirRoot.Open(tmpFileName)
  ```
  </details>
- **能力校验的 panic 信息改报"配置允许集"**:`getDriverCapabilities` 发现请求了不支持的 driver capability 时,panic 文案的 allowed 字段从 `capabilities`(请求∩支持的交集)改为 `supportedDriverCapabilities`(真正的配置允许集),让用户看到能申请哪些,而不是被回显自己请求里恰好命中的那部分。
  <details><summary>代码依据 cmd/nvidia-container-runtime-hook/container_config.go</summary>

  ```diff
  -	log.Panicln(fmt.Errorf("unsupported capabilities found in '%v' (allowed '%v')", envCapabilities, capabilities))
  +	log.Panicln(fmt.Errorf("unsupported capabilities found in '%v' (allowed '%v')", envCapabilities, supportedDriverCapabilities))
  ```
  </details>

### 后续发展方向 [AI]
- 两条都是稳健性/可观测性修复,非能力面变化;CDI 写盘路径收敛说明 toolkit 持续把 CDI(而非 legacy hook)当作一等公民在打磨。证据仅覆盖这两个文件,未见运行时注入逻辑改动。

## kai-scheduler/KAI-Scheduler: 4b90eacd -> 96eb3764
- 比较: 4b90eacd8f8f7bc1155fd078f55b895408a84234 -> 96eb3764 | ahead=1 | files=4 | Release: v0.16.13
- https://github.com/kai-scheduler/KAI-Scheduler/compare/4b90eacd8f8f7bc1155fd078f55b895408a84234...96eb3764caadc87dfb1508af848970868dfbb8b4

### AI 总结重点(源码 diff 为据)
- **Ray in-tree autoscaling 的 gang 最小值语义修正**:`calcJobNumOfPodsAndSubGroups` 新增读取 `spec.enableInTreeAutoscaling`。原逻辑 worker gang 下限默认 = desired replicas,仅当 `minReplicas>0` 才改用 minReplicas;新逻辑改为 `autoscaling || groupMinReplicas>0` 时都用 `minReplicas`(含 0 或未设)。效果:开启自动扩缩的 Ray 集群,worker gang 最小值可为 0,gang 调度不再强制拉起全部 desired 副本,打通 Ray scale-from-zero。
  <details><summary>代码依据 pkg/podgrouper/podgrouper/plugins/ray/ray_grouper.go</summary>

  ```diff
  +	autoscaling, _, err := unstructured.NestedBool(topOwner.Object, "spec", "enableInTreeAutoscaling")
  +	if err != nil {
  +		return 0, nil, err
  +	}
  	workerGroupMinReplicas := int32(groupDesiredReplicas * numOfHosts)
  -	if groupMinReplicas > 0 {
  -		// if minReplicas is set, use it to calculate the min number for workload scheduling
  +	if autoscaling || groupMinReplicas > 0 {
  +		// Autoscaling uses minReplicas for the subgroup minimum, even when
  +		// it is zero or omitted, regardless of the desired replica count.
  		workerGroupMinReplicas = int32(groupMinReplicas * numOfHosts)
  	}
  ```
  </details>

### 后续发展方向 [AI]
- KAI 在精修与 Ray 的 gang 调度契合度,方向是"弹性工作负载 + gang 调度"的正确共存(autoscaling 下允许最小 0 副本)。对我们产品启示:若自家调度器对接 Ray/KubeRay,gang 最小值必须区分"静态副本"与"autoscaling minReplicas"两种语义,否则会把弹性作业锁死在 desired 规模。证据仅覆盖 ray_grouper 一处,未见对其它 framework(PyTorch/MPI)的类似处理。

## 本期无实质改动(折叠)
<details><summary>以下 6 个 repo 本期 EMPTY(仅保锚点)</summary>

- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交(Release v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(Release v0.5.1)
- NVIDIA/dcgm-exporter — 无新提交(Release 4.8.4)
- NVIDIA/DCGM — 无新提交(branch master)
- NVIDIA/mig-parted — 无新提交(Release v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=e136269e743140a5e9669a8fd9d525aff422f99c branch=main release=v26.7.2 scanned=2026-10-23 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=d2454dea06a2e851f321d396ba1ef650dc19d350 branch=main release=v1.20.1 scanned=2026-10-23 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d6d82abedb448b8f67992f1b59c86f163df24772 branch=main release=— scanned=2026-10-23 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=1053da35d5a67fdbc3f0ea0877b7178026048769 branch=main release=v0.20.1 scanned=2026-10-23 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=63e98d305bb66cb9f2a07a0669661329d320ee3f branch=main release=v0.5.1 scanned=2026-10-23 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-23 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=9fae2867e6e5264fa0fca22a07dc898d591baa21 branch=master release=— scanned=2026-10-23 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=26d51f55bab4f0fdd8da56bacaa34513d8fe0c86 branch=main release=v0.15.1 scanned=2026-10-23 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=96eb3764caadc87dfb1508af848970868dfbb8b4 branch=main release=v0.16.13 scanned=2026-10-23 -->
