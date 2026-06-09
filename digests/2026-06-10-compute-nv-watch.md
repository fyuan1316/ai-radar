# NVIDIA 算力栈 diff 雷达 2026-06-10

## 摘要
- KAI-Scheduler 是本期主角:新增 **opt-in 的 `deviceaccess` 准入插件**,通过新 CRD 字段 `admission.blockNvidiaVisibleDevices` 拦截 Pod 自行覆盖 `NVIDIA_VISIBLE_DEVICES`(防止越过 device-plugin 直接抢卡);同时把 **GPU 显存请求按设备显存折算成整卡配额计入队列容量**(此前显存请求不占 queue capacity 会超卖);并落地 GPU 资源隔离设计文档,且首次出现 **KAI × HAMi-core 集成**的文档与 e2e。
- nvidia-container-toolkit 把驱动库目录从单路径重构为**多路径**(`GetDriverLibDirectory`→`GetDriverLibDirectories`,`NVIDIA_CTK_LIBCUDA_DIR` 改为 ListSeparator 拼接多目录),修驱动库分散在多个目录时定位失败。dra-driver 给 MPS 控制守护进程 Deployment 加了 imagePullSecret/pullPolicy(私有仓/离线场景)。
- 其余 5 仓(gpu-operator / k8s-device-plugin / dcgm-exporter / DCGM / mig-parted)仅 bump/CI 或无新提交。gpu-driver-container 仅给镜像加 OCI 溯源 LABEL(GIT_COMMIT),无能力变化。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [API/CRD变更][新能力] 新增 `admission.blockNvidiaVisibleDevices` 配置项 + 全新 `deviceaccess` 准入 webhook 插件,opt-in 拦截 Pod 覆盖 `NVIDIA_VISIBLE_DEVICES`(避免与 NVIDIA device-plugin 的设备分配冲突)。证据:`pkg/apis/kai/v1/admission/admission.go`(+6)、`deployments/kai-scheduler/crds/kai.scheduler_configs.yaml`(+5)、新增 `pkg/admission/webhook/v1alpha2/deviceaccess/device_access.go`(+161)。https://github.com/kai-scheduler/KAI-Scheduler/pull/1672
- kai-scheduler/KAI-Scheduler [架构方向] GPU 显存请求计入队列容量:新增 `GpuMemoryAsGpuFraction()` 把显存请求按 per-device 显存折算成整卡 fraction,`IsMemoryRequest`→`IsGpuMemoryRequest` 全栈改名;此前显存请求不计入 proportion 配额会导致超卖。证据:`pkg/scheduler/api/resource_info/gpu_resource_requirment.go`(+10)、`pkg/scheduler/api/podgroup_info/allocation_info.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1668
- kai-scheduler/KAI-Scheduler [架构方向][新能力] 落地 GPU 资源隔离设计文档,并首次出现 KAI × HAMi-core 集成路径(GPU 共享文档 + e2e)。证据:新增 `docs/developer/designs/gpu-resource-isolation/resource-isolation.md`、`pkg/common/resources/mig.go`、`docs/gpu-sharing/hami/README.md`、`test/e2e/suites/integrations/third_party/hamicore/`。https://github.com/kai-scheduler/KAI-Scheduler/pull/60

## NVIDIA/nvidia-container-toolkit: e0bcfd49 -> 538606ca
- 比较: e0bcfd49 -> 538606ca | ahead=4 | files=5 | Release: v1.19.1

### AI 总结重点(源码 diff 为据)
- **驱动库目录从单路径改为多路径定位(#1820)**:`root.Driver` 的缓存字段 `driverLibDirectory string` 改为 `driverLibDirectories []string`,公开方法 `GetDriverLibDirectory() (string,error)` 改名为 `GetDriverLibDirectories() ([]string,error)`。`DriverLibraryLocator` 的搜索路径由 `[]string{单目录}` 改为 `slices.Clone(多目录)`,relative additionalDirs 会对每个根目录分别拼接。这修的是驱动库(如 `libcuda.so` 与 `libnvidia-ml.so`)分散在不同目录(例:`/usr/lib64` 与 `/usr/lib/x86_64-linux-gnu`)时只认一个目录导致定位失败的问题——新增的测试用例 "locates two driver library directories" 即覆盖此场景。
  <details><summary>代码依据 internal/lookup/root/root.go</summary>

  ```diff
  -	// driverLibDirectory caches the path to parent of the driver libraries
  -	driverLibDirectory string
  +	// driverLibDirectories caches the paths to parent of the driver libraries
  +	driverLibDirectories []string
  ...
  -func (r *Driver) GetDriverLibDirectory() (string, error) {
  -	if r.driverLibDirectory == "" { ... return r.driverLibDirectory, nil }
  +func (r *Driver) GetDriverLibDirectories() ([]string, error) {
  +	if len(r.driverLibDirectories) == 0 { ... return r.driverLibDirectories, nil }
  ...
  -	searchPaths := []string{libcudasoParentDirPath}
  +	searchPaths := slices.Clone(libcudasoParentDirPaths)
  ```
  </details>
- **下游消费方同步多路径(#1820)**:CDI 注入侧 `NVIDIA_CTK_LIBCUDA_DIR` 环境变量从单目录改为用 `filepath.ListSeparator`(`:`)拼接所有目录;XOrg 搜索路径构造 `buildXOrgSearchPaths(libRoot string)` 拆成 `buildXOrgSearchPaths(roots ...string)` 遍历多根目录调用 `buildXOrgSearchPathsAtRoot`。即多驱动库目录会一路传到容器内的 CDI 设备发现与图形库发现。
  <details><summary>代码依据 pkg/nvcdi/driver-nvml.go + internal/discover/graphics.go</summary>

  ```diff
  -	driverLibDirectory, err := l.driver.GetDriverLibDirectory()
  +	driverLibDirectories, err := l.driver.GetDriverLibDirectories()
  -		Value: driverLibDirectory,
  +		Value: strings.Join(driverLibDirectories, string(filepath.ListSeparator)),
  ...
  -func buildXOrgSearchPaths(libRoot string) []string {
  +func buildXOrgSearchPaths(roots ...string) []string {
  +	for _, root := range roots { paths = append(paths, buildXOrgSearchPathsAtRoot(root)...) }
  ```
  </details>

### 后续发展方向 [AI]
- 容器内 GPU 可见性的根(库定位)在向"多目录/多发行版布局"健壮化收敛,利于在驱动库布局非标准(如混合手装/容器化驱动)的节点上稳定注入。证据只覆盖 root.go/graphics.go/driver-nvml.go 三个消费点的签名改动,未见对 CDI spec 生成端到端行为或具体 OS 矩阵的验证。

## kubernetes-sigs/dra-driver-nvidia-gpu: f51778e2 -> c4ee8970
- 比较: f51778e2 -> c4ee8970 | ahead=2 | files=5 | Release: v0.4.0

### AI 总结重点(源码 diff 为据)
- **MPS 控制守护进程支持 imagePullSecret / pullPolicy(#1175)**:kubelet-plugin 新增两个 CLI flag `--image-pull-secrets`(逗号分隔,env `IMAGE_PULL_SECRETS`)、`--image-pull-policy`(env `IMAGE_PULL_POLICY`),解析后存入 `Config.imagePullSecretNames []string` / `imagePullPolicy`,经 `MpsControlDaemonTemplateData` 注入到动态创建的 MPS 控制守护进程 Deployment 模板(`imagePullSecrets` 列表 + 容器 `imagePullPolicy`)。Helm chart 把 `.Values.imagePullSecrets` 与 `.Values.image.pullPolicy` 透传成上述 env。这让 DRA 原生 MPS 共享路径能从私有/镜像仓拉取 MPS daemon 镜像(离线/企业仓场景)。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/main.go + templates/mps-control-daemon.tmpl.yaml</summary>

  ```diff
  +		&cli.StringFlag{ Name: "image-pull-secrets", EnvVars: []string{"IMAGE_PULL_SECRETS"}, Destination: &flags.imagePullSecrets },
  +		&cli.StringFlag{ Name: "image-pull-policy",  EnvVars: []string{"IMAGE_PULL_POLICY"},  Destination: &flags.imagePullPolicy },
  ...
  +			imagePullSecretNames: strings.Fields(strings.ReplaceAll(strings.TrimSpace(flags.imagePullSecrets), ",", " ")),
  +			imagePullPolicy:      strings.TrimSpace(flags.imagePullPolicy),
  ```
  ```diff
  # templates/mps-control-daemon.tmpl.yaml
  +      {{- if .MpsImagePullSecretNames }}
  +      imagePullSecrets:
  +      {{- range .MpsImagePullSecretNames }}
  +      - name: {{ . }}
  +      {{- end }}{{- end }}
  +        {{- if .MpsImagePullPolicy }}
  +        imagePullPolicy: {{ .MpsImagePullPolicy }}{{- end }}
  ```
  </details>
- **MPS Deployment 渲染抽成独立函数(#1175)**:把原内联在 `MpsControlDaemon.Start` 里的 "ParseFiles→Execute→Unmarshal→FromUnstructured" 一段抽到 `renderMpsControlDaemonDeployment(templatePath, templateData) (*appsv1.Deployment, error)`,Start 直接拿 typed `*appsv1.Deployment`。纯重构,但配套新增了校验 imagePullSecrets/pullPolicy 正确渲染的单测 `TestRenderMpsControlDaemonDeploymentImagePullSettings`。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/sharing.go</summary>

  ```diff
  -	tmpl, err := template.ParseFiles(m.manager.templatePath)
  -	... yaml.Unmarshal ... runtime.DefaultUnstructuredConverter.FromUnstructured(...)
  +	deployment, err := renderMpsControlDaemonDeployment(m.manager.templatePath, templateData)
  +	if err != nil { return err }
  ```
  </details>

### 后续发展方向 [AI]
- DRA 原生共享(MPS)在补企业落地缺口(私有仓拉取),与下方 KAI 的共享/隔离方向呼应:NVIDIA 系正同时从"调度准入"(KAI)和"kubelet-plugin 运行时"(dra-driver)两端补 GPU 共享的生产化细节。证据只覆盖 MPS 控制守护进程的镜像拉取参数,未见对 time-slicing 或 MIG 共享路径的同类改动。

## kai-scheduler/KAI-Scheduler: 8fbaf953 -> c87cdb20
- 比较: 8fbaf953 -> c87cdb20 | ahead=5 | files=43 | Release: v0.14.5

### AI 总结重点(源码 diff 为据)
- **新增 opt-in `deviceaccess` 准入插件 + CRD 字段 `blockNvidiaVisibleDevices`(#1672)**:`Admission` 配置结构体新增 `BlockNvidiaVisibleDevices *bool`(默认 false,`SetDefaultsWhereNeeded` 补默认),CRD `kai.scheduler_configs.yaml` 同步加该 boolean 字段。新增独立包 `pkg/admission/webhook/v1alpha2/deviceaccess`(device_access.go +161),开启后拦截 Pod 把 `NVIDIA_VISIBLE_DEVICES` 覆盖为 `all`/具体 index 等值——因为这会绕过 NVIDIA device-plugin 的设备隔离直接拿到全部卡。e2e 用例确认默认放行、开启后拒绝 `1`/`1,2`/`all`。
  <details><summary>代码依据 pkg/apis/kai/v1/admission/admission.go + crds/kai.scheduler_configs.yaml</summary>

  ```diff
  +	// BlockNvidiaVisibleDevices prevents pods from overriding the NVIDIA_VISIBLE_DEVICES
  +	// environment variable, which would conflict with NVIDIA's device plugin.
  +	// +kubebuilder:validation:Optional
  +	BlockNvidiaVisibleDevices *bool `json:"blockNvidiaVisibleDevices,omitempty"`
  ...
  +	b.BlockNvidiaVisibleDevices = common.SetDefault(b.BlockNvidiaVisibleDevices, ptr.To(false))
  ```
  ```diff
  # crds/kai.scheduler_configs.yaml
  +                  blockNvidiaVisibleDevices:
  +                    description: |- ... conflict with NVIDIA's device plugin.
  +                    type: boolean
  ```
  </details>
- **GPU 显存请求计入队列容量(#1668)**:新增 `GpuResourceRequirement.GpuMemoryAsGpuFraction(gpuDeviceMemory)`,把显存请求按 `count * (gpuMemory/gpuDeviceMemory)` 折算成等效整卡 fraction(非显存请求或基数≤0 返回 0)。`allocation_info.go` 用它替换原来内联的折算逻辑,并把判定从 `IsMemoryRequest()` 改为 `IsGpuMemoryRequest()`(`pod_info.go` 起全栈改名,语义更精确:专指 GPU 显存请求)。效果是显存维度的共享请求现在会真实占用 proportion 队列配额,堵住"显存请求不计配额导致队列超卖"的口子。
  <details><summary>代码依据 gpu_resource_requirment.go + podgroup_info/allocation_info.go</summary>

  ```diff
  +func (g *GpuResourceRequirement) GpuMemoryAsGpuFraction(gpuDeviceMemory int64) float64 {
  +	if g.gpuMemory <= 0 || gpuDeviceMemory <= 0 { return 0 }
  +	return float64(g.count) * (float64(g.gpuMemory) / float64(gpuDeviceMemory))
  +}
  ...
  -			if task.IsMemoryRequest() && minNodeGPUMemory > 0 {
  -				additionalGpuFraction := float64(...GetNumOfGpuDevices()) * (float64(...GpuMemory()) / float64(minNodeGPUMemory))
  -				result.Set(gpuIdx, result.Get(gpuIdx)+additionalGpuFraction)
  +			if task.IsGpuMemoryRequest() && minNodeGPUMemory > 0 {
  +				result.Set(gpuIdx, result.Get(gpuIdx)+task.GpuRequirement.GpuMemoryAsGpuFraction(minNodeGPUMemory))
  ```
  </details>
- **GPU 资源隔离设计文档 + HAMi-core 集成(#60)**:新增设计文档 `docs/developer/designs/gpu-resource-isolation/resource-isolation.md` 与 `pkg/common/resources/mig.go`(MIG 资源辅助),并新增 `docs/gpu-sharing/hami/README.md` 与 `test/e2e/suites/integrations/third_party/hamicore/`(hamicore_test.go +264)。说明 KAI 正把 HAMi-core 作为第三方 GPU 软隔离后端纳入其共享体系并以 e2e 验证集成。
  <details><summary>代码依据 信号文件清单(本提交仅文档+测试,无核心调度逻辑改动)</summary>

  ```text
  added  docs/developer/designs/gpu-resource-isolation/resource-isolation.md (+104)
  added  pkg/common/resources/mig.go (+16)
  added  docs/gpu-sharing/hami/README.md (+116)
  added  test/e2e/suites/integrations/third_party/hamicore/hamicore_test.go (+264)
  ```
  </details>

### 后续发展方向 [AI]
- KAI 的 GPU 共享正从"自家 fraction/显存语义"扩展到"准入层把关 + 第三方隔离后端(HAMi-core)集成":一边用 `deviceaccess` 防 Pod 越过 device-plugin 抢卡,一边把 HAMi-core 当作软隔离实现引进。证据覆盖 admission CRD/插件、显存配额折算、隔离设计文档与 hamicore e2e;但 #60 本期只落了设计文档+测试骨架与 `mig.go` 辅助,核心隔离执行逻辑尚未在本 diff 出现,未见 deviceaccess 与 HAMi-core 运行时如何串联。
- 显存请求计入队列容量是配额正确性修正,直接影响多租户超卖行为;证据只覆盖 proportion/allocation 折算与改名,未见对既有以"仅按整卡计配额"假设运行的集群的迁移/兼容说明。

## 本期无实质改动(折叠)
<details><summary>5 仓 EMPTY + 1 仓仅溯源 LABEL</summary>

- NVIDIA/gpu-operator(无新提交)
- NVIDIA/k8s-device-plugin(ahead=2,仅 bump/CI/merge)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(无新提交)
- NVIDIA/gpu-driver-container(ahead=4,#255 仅给各 OS Dockerfile 加 `ARG GIT_COMMIT` 与 OCI 镜像 LABEL `vcs-ref`/display-name 等溯源元数据,无构建逻辑/能力变化)https://github.com/NVIDIA/gpu-driver-container/pull/255
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=1ab8a08a932c72475de7cdc28410b91fac23c7d1 branch=main release=v26.3.2 scanned=2026-06-10 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=538606ca9f4949f7b46f60e5e612143de1f17079 branch=main release=v1.19.1 scanned=2026-06-10 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=0dbfbb9cfab989f59f1960ac4554fc54dc61c529 branch=main release=— scanned=2026-06-10 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=febb5056c83e8c35a6e96842be11ba3cd5dd8c5d branch=main release=v0.19.2 scanned=2026-06-10 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c4ee89702d334ce52d95450d09e7bc6bca3da519 branch=main release=v0.4.0 scanned=2026-06-10 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-10 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-10 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9221140671899b3c0dd281cd849927c0ba02120f branch=main release=v0.14.2 scanned=2026-06-10 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=c87cdb20d241b80f3d36b7b0c3c4c2508862fcd3 branch=main release=v0.14.5 scanned=2026-06-10 -->
