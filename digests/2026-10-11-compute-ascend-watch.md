# 昇腾算力栈 diff 雷达 2026-10-11

## 摘要
- 头条在 **npu-operator**:一条 `!121 feat: update the component to adapt A5 machine`(区间 c806e3c8..ddcf0eb7,2 commit,未截断)把 operator 的治理边界从"驱动/device-plugin/调度生命周期"**扩张为完整的 MindCluster 组件编排器**——NPUClusterPolicy CRD 新增 `inferOperator`(推理控制器)、`rdmaDevicePlugin`(RDMA 共享设备插件)、NodeD `containerSnapshot`(断点续训 checkpoint/restore)、Exporter `serviceMonitor`(Prometheus Operator 集成)四块;并新增一套**从组件自身 command/args 自动推导健康探针**的控制器代码。属 `[API/CRD变更]+[新能力]+[架构方向]` 三重信号。
- **npu-container-toolkit** 一条真改动:ascend-docker-runtime 的 .run 安装包下载源从华为 OBS 门户迁到 **GitCode 开放 release**,`ARG VERSION 26.0.0→26.1.1`——供应链取数开放化。
- **mind-cluster** 本期 component/ 内全是文档/构建版本串重构(README 版本占位符 v6.0.0→v\<version\>、Go 文档版本 1.21→1.26、agreement.txt v6.0.0→v26.2.0)+ 一条 x/net CVE 依赖升级,无组件代码信号;openFuyao 其余 6 仓零新提交。
- 非空日,按约定推飞书。

## 当日重要改变

### npu-operator · operator 扩为 MindCluster 全组件编排器:新增推理控制器/RDMA/快照/监控四块 [API/CRD变更][新能力][架构方向]
对应 `!121 feat: update the component to adapt A5 machine`。虽挂"适配 A5"名义,diff 实质是 operator 管理面大幅扩张。

**(1) NPUClusterPolicy 新增两个被管组件 + 一个可复用工作负载规范。** `api/v1/npuclusterpolicy_types.go` 的 `NPUClusterPolicySpec` 新增 `InferOperator`(MindCluster 推理控制器)、`RDMADevicePlugin`(k8s-rdma-shared-dp,多机训练 fabric);新建 `api/v1/component_types.go` 定义可复用的 `ComponentWorkloadSpec`(Managed/Image/Env/Command/VolumeSpec/Resources/Placement 内联),两组件各内联它 + 独立 `LogRotate` + `Config map[string]string` 覆盖。两者默认 `managed=false` 不部署。配套把 infer-operator 的三个 CRD(InferServiceSet/InferService/InstanceSet,`mindcluster.huawei.com` 组)作为 asset 加入。

<details><summary>代码依据 api/v1/npuclusterpolicy_types.go + component_types.go</summary>

```go
 type NPUClusterPolicySpec struct {
 	DevicePlugin DevicePluginSpec `json:"devicePlugin"`
 	NodeD NodeDSpec `json:"nodeD"`
+	// MindCluster inference controller. Disabled unless explicitly managed.
+	InferOperator InferOperatorSpec `json:"inferOperator,omitempty"`
+	// MindCluster RDMA shared device plugin. Disabled unless explicitly managed.
+	RDMADevicePlugin RDMADevicePluginSpec `json:"rdmaDevicePlugin,omitempty"`
 	Exporter ExporterSpec `json:"exporter"`

// component_types.go(新文件)
+type ComponentWorkloadSpec struct {
+	Managed bool `json:"managed,omitempty"`              // +default=false
+	Image ImageSpec `json:"imageSpec,omitempty"`
+	Env []corev1.EnvVar `json:"env,omitempty"`
+	Command CommandSpec `json:"commandSpec,omitempty"`
+	VolumeSpec VolumesSpec `json:"volumeSpec,omitempty"`
+	Resources ResourceRequirements `json:"resources,omitempty"`
+	PlacementSpec `json:",inline"`
+}
+type InferOperatorSpec struct { ComponentWorkloadSpec `json:",inline"`; LogRotate LogRotate; Config map[string]string }
+type RDMADevicePluginSpec struct { ... }  // +XValidation: RDMA log compression unsupported
```
</details>

**(2) NodeD 断点续训(容器 checkpoint/restore)开关。** `NodeDSpec` 新增 `ContainerSnapshot ContainerSnapshotSpec{Enabled bool}`——打开后给 NodeD 加 host PID 访问、runtime 挂载与 PATH,启用容器快照前置条件,需 snapshot-capable NodeD 镜像与主机工具。这是昇腾断点续训链路在 operator 侧的落点。

<details><summary>代码依据 api/v1/npuclusterpolicy_types.go / component_types.go</summary>

```go
 type NodeDSpec struct {
+	// Configure NodeD for container checkpoint and restore.
+	ContainerSnapshot ContainerSnapshotSpec `json:"containerSnapshot,omitempty"`
 	Managed bool `json:"managed,omitempty"`  // +default=true

+type ContainerSnapshotSpec struct {
+	// Add host PID access, runtime mounts and PATH required by snapshot support.
+	Enabled bool `json:"enabled,omitempty"`  // +default=false
+}
```
</details>

**(3) Exporter 接 Prometheus Operator。** `ExporterSpec` 新增 `ServiceMonitor ServiceMonitorSpec`,可选的 ServiceMonitor 集成,默认关。昇腾监控从裸 exporter 走向 Prometheus Operator 生态对接。

<details><summary>代码依据 api/v1/npuclusterpolicy_types.go</summary>

```go
 type ExporterSpec struct {
+	// Optional Prometheus Operator integration; disabled by default.
+	ServiceMonitor ServiceMonitorSpec `json:"serviceMonitor,omitempty"`
 	Managed bool `json:"managed,omitempty"`  // +default=true
```
</details>

**(4) 自动推导健康探针(新能力,无需硬编码每组件 flag)。** 新建 `resources_health_probe_shell.go`(有界 shell 词法器 `splitHealthProbeShell`:只解析字面简单命令、**不执行 shell**、显式拒绝扩展/重定向/管道/条件/通配)+ `resources_health_probe_flags.go`(`newHealthProbeFlags`/`resolveHealthProbe`:用 Go flag 语义解析组件 command/args,识别 `--enable-healthz`/`--healthz-address`/`--tls-cert-file`),据此为被管组件合成 corev1.Probe,默认健康端口 infer-operator 11254、rdma 11257。即 operator 从组件自身启动参数反推出探针,而非为每个组件写死探测配置。

<details><summary>代码依据 resources_component_workload.go / resources_health_probe_flags.go</summary>

```go
// resources_component_workload.go
const ( inferOperatorDefaultHealthPort = 11254; rdmaDevicePluginDefaultHealthPort = 11257 )

// resources_health_probe_flags.go
func resolveHealthProbe(profile healthProbeProfile, command, args []string) (*corev1.Probe, string, error) {
	argv, supported := healthProbeCommandArgs(profile.binary, command, args)
	if !supported { return nil, "command is not a supported literal invocation", nil }
	flags, values := newHealthProbeFlags(profile)
	...
	if !values.enabled || values.version { return nil, "", nil }  // 仅当组件开了 healthz 才注入探针
```
</details>

**(5) Volcano 插件版本识别加固。** `resources_volcano_config.go`(新文件)把 `volcanoPluginVersion` 从天真的 `strings.Split(tag,"-")` 取末段,改为正则校验 `^v?[0-9]+\.[0-9]+\.([0-9]+|RC[0-9]+)$` 的候选提取,恰好一个才认、否则返空;`ObtainVolcanoVersion` 现对无法识别的 image tag **显式报错** `errUnrecognizedVolcanoPluginVersion` 而非静默用脏值;`volcanoPluginNamePattern` 正则匹配 `volcano-npu_*` 插件名条目且保留 YAML 缩进/引号/注释;删掉旧的 `os.Getenv("OPERATOR_NODE_NAME")` + 查 Node 的路径,`volcanoUnifiedPluginVersion` 常量定为 `26.1.1`。

<details><summary>代码依据 resources_volcano_config.go / resources_basic_hooks.go</summary>

```go
 func volcanoPluginVersion(tag string) string {
-	part := strings.Split(tag, "-")
-	if len(part) == 0 { return "" }
-	return part[len(part)-1]
+	parts := strings.FieldsFunc(tag, func(c rune) bool { return c=='-' || c=='_' })
+	// 只收匹配 v?N.N.(N|RCn) 的候选,恰好一个才认
+	if len(candidates) != 1 { return "" }
+	return candidates[0]
 }
// ObtainVolcanoVersion:
+	if tag != "" && version == "" {
+		return "", fmt.Errorf("%w: %q", errUnrecognizedVolcanoPluginVersion, tag)
+	}
```
</details>

源:https://gitcode.com/openFuyao/npu-operator/commit/ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 · PR https://gitcode.com/openFuyao/npu-operator/merge_requests/121

### npu-container-toolkit · runtime 安装包下载源迁到 GitCode 开放 release
`!17 update: 更新文件 ascend-docker-runtime.dockerfile`:构建镜像时拉取 Ascend-docker-runtime .run 包的 URL 从华为 OBS 门户改为 GitCode 开放 release,`ARG VERSION` 26.0.0→26.1.1。供应链取数从闭源门户转向开放代码仓,利于镜像可复现构建。

<details><summary>代码依据 build/ascend-docker-runtime.dockerfile</summary>

```dockerfile
-ARG VERSION=26.0.0
+ARG VERSION=26.1.1
-url="https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/MindX/MindX%20${VERSION}/Ascend-docker-runtime_${VERSION}_linux-${arch}.run"
+url="https://gitcode.com/Ascend/mind-cluster/releases/download/v${VERSION}/Ascend-docker-runtime_${VERSION}_linux-${arch}.run"
```
</details>

源:https://gitcode.com/openFuyao/npu-container-toolkit/commit/c720a3b8d142b188cc3baca1ae08ffce98a7f27e

## 本期无实质改动 / 仅文档(折叠)
<details><summary>展开</summary>

- **mind-cluster**(区间 eed2442f..aac1c915,10 commit):component/ 内全是文档与构建版本串重构——多仓 README 把硬编码版本号 `v6.0.0`/`volcano-npu_v26.1.0.so` 改为 `v<version>`/`v{version}` 占位符并加"数字版本号"说明;ascend-for-volcano README Go 版本要求文档从 ≥1.21 改 ≥1.26;npu-exporter agreement.txt 版本串 v6.0.0→v26.2.0;各组件 build.sh/build_ch.sh 构建脚本适配。另有一条 `升级 golang.org/x/net 至 v0.60.0 修复 x/net 系列 CVE`——纯依赖升级(go.mod/go.sum,被信号过滤器滤出),安全收尾、无组件逻辑改动。
- openFuyao 其余 6 仓(npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)无新提交,HEAD 与 10-10 锚点逐仓一致。

</details>

## 对我们产品的启示
- **npu-operator 正在变成"MindCluster 发行版的单一控制面"**:一个 NPUClusterPolicy 从只管驱动/device-plugin/调度,扩到同时编排推理控制器(infer-operator)、RDMA fabric 设备插件、断点续训快照、Prometheus 监控。这和 NVIDIA GPU Operator 用一个 ClusterPolicy 收编全栈是同一打法。我们若做 NPU operator,要预判用户期待"一个 CR 管住训练+推理+网络+监控",而非每组件各一套 CRD。
- "从组件 command/args 反推健康探针"的 `ComponentWorkloadSpec` + bounded-shell-lexer 是个可借鉴的通用化手法:operator 不为每个被管组件写死探针/端口,而是解析其启动参数自动合成——新增组件时 operator 侧零改动。代价是要维护一个安全的命令解析器(拒绝 shell 扩展)。
- 断点续训(container checkpoint/restore)首次以 `containerSnapshot` 开关出现在 operator API,证据只到"加 host PID/挂载/PATH 前置条件 + 需 snapshot-capable NodeD 镜像",未见快照存取/恢复编排的具体实现(那部分在 NodeD/clusterd,本期无增量)——下期盯 NodeD 侧快照落地。
- npu-container-toolkit 把安装包源迁到 GitCode 开放 release,配合 mind-cluster README 去掉"切 master 分支"等措辞,是昇腾把构建链路开放化、降低外部复现门槛的一致动作。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=aac1c915825f04dd5ebc5073dbcb7d666f7c1aa6 tag=v26.1.1 scanned=2026-10-11 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-11 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=5dd79f3952dcb2a01c455feb953fe8d5b5b07af9 tag=1.0.2 scanned=2026-10-11 -->
