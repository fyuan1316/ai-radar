# 昇腾算力栈 diff 雷达 2026-08-20

## 摘要
- **推理服务"跨 PodGroup 任务间亲和"重构为共享包并扩展到 A3 SuperPod**:ascend-for-volcano 把原先只在 chip8node8sp 里的 inferServiceID 亲和逻辑(两级优先队列:优先落到已承载同一 service 的 super pod)抽成 `internal/npu/base/inferservice` 共享包,A3(ascend910a3/superpod)新增同能力;infer-operator 侧自动把 `inferserviceid=InferService.UID` 注入到 `-sp` 结尾的超节点策略作业上。多机推理实例被软亲和到同一超节点。
- **npu-exporter 打通"一卡多 Pod(软切分)"监控**:`containerMap` 从 `map[int32]DevicesInfo` 改成 `map[int32][]DevicesInfo`——一张物理芯片可对应多个容器;多 Pod 时 namespace/pod_name/container_name 标签显示占位符而非误挂到某一个 Pod,并新增经容器运行时 socket(containerd Tasks.ListPids / isula Inspect)取容器 PID 把进程级指标关联到正确容器。
- **npu-dra-plugin 一批 vNPU DFX 硬化**:重启后从 checkpoint 恢复软 vNPU 占用(`RestoreVNPU`,不再重复发放在用 ID)、设备发现失败不再回退"模拟设备"而是拒绝上报、软切分份数上限 100→63、shm 文件仅在物理卡全部实例归还后才删。

## 当日重要改变
- mind-cluster [新能力/架构方向] 推理服务任务间亲和抽为共享包 `component/ascend-for-volcano/internal/npu/base/inferservice/infer_service.go`(281 行新增),A3 超节点 `ascend910a3/superpod/infer_service.go` 接入;infer-operator `inferservice_controller.go` 自动注入 `inferserviceid` 标签。 https://gitcode.com/Ascend/mind-cluster/compare/ec460dc60d38bd07f71563ca3edef0b63762d44d...5fcb7b99c3f3662fa33a9acd62e4c2465863c895
- mind-cluster [新能力] npu-exporter 支持一卡对应多 Pod 的监控标签与进程归属(软切分场景),证据 `npu-exporter/collector/metrics/collector_for_npu.go`、`common_utils.go`、新增 `collector/container/v1/tasks.go`。链接同上。
- mind-cluster [架构方向] 适配 Volcano 1.15:删除 `v1.7.0.yaml`、改 `v1.15.0.yaml`,plugin/node.go 去掉反射兼容旧/新 Capacity 字段的 `getNPUNodeCapacity`,直接读 `Capacity.ScalarResources`。上游调度器版本抬档。链接同上。
- npu-dra-plugin [新能力/弃用] 插件重启后恢复软 vNPU 占用(新增 `VNPUManager.RestoreVNPU`),同时**移除设备发现的模拟回退**(删 `simulateDevices`,发现失败改为拒绝上报 ResourceSlice)。 https://gitcode.com/openFuyao/npu-dra-plugin/compare/90c70b32b9b368efc2cc26bda1209e4f275a804c...b33edd6dc28f0dc96f908ee7de414af931bb8fe1
- mind-cluster [弃用/移除](超出本 task 8 个 PATHPREFIX 范围,仅记录)`component/sriov-cni` 与 `component/sriov-network-device-plugin` 两个组件整体删除,SR-IOV DP 功能迁到 k8s-shared-rdma、sriov-cni 迁到 host-device(commit「sriovdp功能迁移到k8s-shared-rdma组件」)。

## mind-cluster: ec460dc6 -> 5fcb7b99
- 比较: ec460dc6..5fcb7b99 | tag: v26.1.0 | commits=20 | truncated=true(文件列表可能不全,已直接读取 compare patch 补齐关键 hunk)
- https://gitcode.com/Ascend/mind-cluster/compare/ec460dc60d38bd07f71563ca3edef0b63762d44d...5fcb7b99c3f3662fa33a9acd62e4c2465863c895

### AI 总结重点(源码 diff 为据)
- **推理服务任务间亲和逻辑抽成共享 `inferservice` 包 + 两级优先队列**:新建 `base/inferservice/infer_service.go`,定义 `GroupSameSP=1 / GroupOtherSP=2` 与 `PQ` 优先队列——同一 `inferserviceid` 已占用的 super pod 优先(group 小者先),同组内空闲节点多者先。原 `chip8node8sp/infer_service.go` 从 211 行砍到 33 行,`isInferServiceJobCheck`/选点全部委托给共享包;`chip8node8sp/type.go` 删掉本地 `inferServiceIDLabelKey`、`inferServicePQ` 等重复定义。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/base/inferservice/infer_service.go(新增)</summary>

  ```diff
  +const (
  +	IDLabelKey = "inferserviceid"
  +	GroupSameSP  = 1  // 已承载同一 infer service 的 super pod
  +	GroupOtherSP = 2  // 未承载的 super pod
  +)
  +// Less: 先按 group(小者优先),同组内空闲节点多者优先
  +func (pq PQ) Less(i, j int) bool {
  +	a, b := pq[i], pq[j]
  +	if a.Group != b.Group { ... }
  ```
  </details>
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/policy/chip8node8sp/infer_service.go(-211/+33)</summary>

  ```diff
  -	id, ok := tp.Label[inferServiceIDLabelKey]
  -	if !ok || id == "" { return false }
  -	tp.inferServiceID = id
  +	if id := inferservice.GetInferServiceID(tp.Label); id != "" {
  +		tp.inferServiceID = id
  +		return true
  +	}
  -func (tp *chip8node8sp) getInferServiceScheduledSPs() map[int32]*inferServiceSPInfo { ...本地实现整段删除... }
  ```
  </details>
- **A3(ascend910a3/superpod)新增推理服务亲和**:新建 `superpod/infer_service.go`,`module910SuperPod` 新增 `isInferServiceJob`/`inferServiceID` 字段,`selectNodesForInferService` 直接调用共享包 `inferservice.SelectNodesForInferService(InferServiceReq{...})`。对应 commit「新增A3支持通过inferserviceid标签配置任务间亲和性」——把原只在 8p-8-sp 的能力推广到 A3 超节点。
  <details><summary>代码依据 component/ascend-for-volcano/internal/npu/ascend910/ascend910a3/superpod/infer_service.go(新增)</summary>

  ```diff
  +func (tp *module910SuperPod) selectNodesForInferService(task *api.TaskInfo,
  +	nodes []*api.NodeInfo) (map[string][]plugin.SuperNode, error) {
  +	return inferservice.SelectNodesForInferService(inferservice.InferServiceReq{
  +		Jobs: tp.ScheduleEnv.Jobs, JobName: tp.Name, InferServiceID: tp.inferServiceID,
  +		SpBlock: tp.spBlock, ReqNPUNum: tp.ReqNPUNum, ... })
  ```
  </details>
- **infer-operator 自动注入 inferserviceid 标签 + 从 Pod 模板回落调度策略**:`newInstanceSet` 里,当注解缺 `SchedulePolicyAnnoKey` 时从 role 的 Pod 模板补齐;当策略以 `-sp` 结尾(`isTargetSuperPodJob` 判 `SuperPodPolicySuffix`)时,把 `inferserviceid=is.UID`(InferService UID,唯一且长度合规)注入 InstanceSet 标签。新增常量 `InferServiceIDLabelKey="inferserviceid"`——**故意不加 LabelKeyPrefix**,与 ascend-for-volcano 端保持同名,免去跨组件翻译;`AddInferServiceIDToPodTemplate` 再把标签复制到 Pod 模板,使关闭 gang 调度、无 PodGroup 时调度器也能从 Pod 读到。
  <details><summary>代码依据 component/infer-operator/pkg/controller/v1/inferservice_controller.go / common/constant.go</summary>

  ```diff
  +	if isTargetSuperPodJob(annotations) {
  +		if _, exist := labels[common.InferServiceIDLabelKey]; !exist &&
  +			!hasInferServiceIDInPodTemplate(role.InstanceSpec) {
  +			labels[common.InferServiceIDLabelKey] = string(is.UID)
  +		}
  +	}
  +	InferServiceIDLabelKey = "inferserviceid"  // 不加前缀,与 volcano 端对齐
  ```
  </details>
- **super-pod 策略常量集中到 ascend-common/api**:`consts.go` 新增 `Chip8Node8Sp`、`Chip8Node8Ra64Sp`、`Chip2Node16Sp`、`Chip2Node8Sp` 与 `SuperPodPolicySuffix="-sp"`;`ascend-operator/pkg/utils/superpod.go` 对应删掉本地的 `Chip2Node16Sp`/`Chip2Node8Sp`。策略常量从各组件下沉到公共 api,配合 infer-operator 的 `-sp` 后缀判断。
  <details><summary>代码依据 component/ascend-common/api/consts.go</summary>

  ```diff
  +	Chip8Node8Sp = "chip8-node8-sp"
  +	Chip8Node8Ra64Sp = "chip8-node8-ra64-sp"
  +	Chip2Node16Sp = "chip2-node16-sp"
  +	Chip2Node8Sp = "chip2-node8-sp"
  +	SuperPodPolicySuffix = "-sp"
  ```
  </details>
- **npu-exporter:一张卡从"对应一个容器"改成"对应多个容器"**:`geenContainerInfo`(单个)→ `geenContainerInfos`(切片),`containerMap` 类型 `map[int32]DevicesInfo` → `map[int32][]DevicesInfo`;新增 `getContainerLabels`——0 Pod 三标签留空、1 Pod 正常显示、>1 Pod 用 `NotDisplayedForMultiPod` 占位。避免软切分下把共享一卡的指标误挂到某一个 Pod。
  <details><summary>代码依据 component/npu-exporter/collector/metrics/common_utils.go</summary>

  ```diff
  +func getContainerLabels(containerInfos []container.DevicesInfo) (containerName, namespaceValue, podNameValue string) {
  +	switch {
  +	case len(containerInfos) == 1: return getContainerInfoWithDefault(getContainerNameArray(containerInfos[0]))
  +	case len(containerInfos) > 1:  return colcommon.NotDisplayedForMultiPod, ...  // 多 Pod 占位
  +	default: return "", "", "" }
  -func geenContainerInfo(... map[int32]container.DevicesInfo) container.DevicesInfo {
  +func geenContainerInfos(... map[int32][]container.DevicesInfo) []container.DevicesInfo {
  ```
  </details>
- **进程级指标改为经容器运行时 socket 定位所属容器**:`RuntimeOperator` 接口新增 `GetContainerPIDs`——containerd 走 `Tasks.ListPids` RPC(新增 `collector/container/v1/tasks.go` 手写 protobuf 客户端)、isula 走 Inspect 取 `State.Pid`,**因容器模式下宿主 /proc 未挂载**;`parser.go` 的 `DevicesInfo` 新增 `PIDs map[int32]struct{}` 集合供 O(1) 判属。让软切分下多个 Pod 共享一卡时,芯片上的进程 PID 能被正确归到各自容器。
  <details><summary>代码依据 component/npu-exporter/collector/container/runtime_ops.go / parser.go</summary>

  ```diff
  +	GetContainerPIDs(ctx context.Context, id string) ([]uint32, error)
  +func (operator *RuntimeOperatorTool) getContainerdContainerPIDs(ctx, id) ([]uint32, error) {
  +	resp, err := v1.NewTasksClient(operator.conn).ListPids(..., &v1.ListPidsRequest{ContainerId: id})
  +	// parser.go: DevicesInfo 新增 PIDs map[int32]struct{}(集合,O(1) 判属)
  ```
  </details>
- **适配 Volcano 1.15,去掉版本兼容反射**:删 `build/volcano-v1.7.0.yaml`、改 `volcano-v1.15.0.yaml`;`plugin/node.go` 删除用反射按字段名(oldCapacity/newCapacity)兼容不同 volcano 版本 Capacity 的 `getNPUNodeCapacity`,直接 `npuNode.Capacity.ScalarResources`;`klog` → `klog/v2`;`superPod` 本地类型统一为 `type superPod = plugin.SuperPod`(去重)。
  <details><summary>代码依据 component/ascend-for-volcano/plugin/node.go</summary>

  ```diff
  -	capability := getNPUNodeCapacity(npuNode)
  +	capability := npuNode.Capacity.ScalarResources
  -// getNPUNodeCapacity get npu node Capacity by diff volcano version(反射整段删除)
  ```
  </details>

### 后续发展方向 [AI]
- 推理侧方向明确是**多机推理实例的超节点级 locality**:同一 InferService 的多个 PodGroup 被软亲和到已承载它的 super pod,且能力从 8p-8-sp 单策略泛化为共享包 + A3 接入,预期后续其余 SuperPod 策略(chip8node8ra64sp / a3x16 等)也会挂接同一 `inferservice` 包。证据覆盖共享包 + A3 接入 + operator 标签注入;未见亲和权重/打分具体数值(在 `SelectNodesForInferService` 内部,本次 hunk 截断未全展开)。
- 监控侧的"一卡多 Pod"改造是**软切分(vCANN/vNPU 软共享)监控可观测性补齐**的关键一步——此前一卡一容器的假设在软切分下会误挂指标。方向是把 exporter 从"整卡粒度"推进到"共享实例粒度",但本期只解决了标签归属与进程定位,未见按 vNPU 实例拆分算力/显存指标。证据仅覆盖 containerMap 结构与 PID 关联,未覆盖 vNPU 级指标采集。

## npu-dra-plugin: 90c70b32 -> b33edd6d
- 比较: 90c70b32..b33edd6d | tag: v26.6.0 | commits=5 | truncated=false
- https://gitcode.com/openFuyao/npu-dra-plugin/compare/90c70b32b9b368efc2cc26bda1209e4f275a804c...b33edd6dc28f0dc96f908ee7de414af931bb8fe1

### AI 总结重点(源码 diff 为据)
- **插件重启后从 checkpoint 恢复软 vNPU 占用**:`DeviceState.RecoverState` 从"no-op"改为:读 checkpoint,遍历 `PreparedClaims`,对前缀为 `soft:`(`SoftDeleteRefPrefix`)的 deleteRef 调 `softMgr.RestoreVNPU` 重新登记为已占用——保证重启后空闲 ID 池**不会把仍被运行中 Pod 使用的 vNPU ID 再发出去**。接口 `VNPUManager` 新增 `RestoreVNPU`;hard 管理器实现为 no-op(生命周期归 Ascend Docker Runtime,重启不需簿记)。
  <details><summary>代码依据 cmd/ascend-npu-dra-kubeletplugin/state.go / internal/profiles/vnpu_manager.go</summary>

  ```diff
  -// RecoverState ... Currently a no-op.
  +	for claimUID, devices := range checkpoint.V1.PreparedClaims {
  +		for _, d := range devices {
  +			if d == nil || !strings.HasPrefix(d.VNPUDeviceID, vnpu.SoftDeleteRefPrefix) { continue }
  +			if err := softMgr.RestoreVNPU(d.VNPUDeviceID); err != nil { ...; continue }
  +			restored++
  +	// interface: RestoreVNPU(deleteRef string) error
  ```
  </details>
- **设备发现移除"模拟设备"回退,失败即拒绝上报**:`Profile.EnumerateDevices` 原先发现失败会 `simulateDevices()` 造假设备兜底,现改为直接 `Errorf("refusing to publish devices")` 并返回;`simulateDevices` 整函数删除。`discoverWithDCMI` 把错误细分为「DCMI API call failed」与「no NPU」两类,`discoverPhysicalDevices` 双路(DCMI + /dev/davinci* 扫描)都失败时给出可诊断的合并错误。杜绝生产环境把假设备发布进 DRA ResourceSlice。
  <details><summary>代码依据 internal/profiles/npu/npu.go</summary>

  ```diff
  -		klog.Warningf("physical device discovery failed, falling back to simulation: %v", err)
  -		physicalDevices, err = profile.simulateDevices()
  +		klog.Errorf("NPU device discovery failed on node %s, refusing to publish devices: %v", ...)
  +		return resourceslice.DriverResources{}, fmt.Errorf("physical device discovery failed: %w", err)
  -func (p Profile) simulateDevices() ([]resourceapi.Device, error) { ...整段删除... }
  ```
  </details>
- **软切分份数上限 100→63**:`--share-count` 每物理 NPU 软共享实例数从「1-100」收紧到「1-63」(CLI Usage 与新增范围校验,commit「新增share-count范围校验(1-63)」),贴近硬件真实可切分上限。
  <details><summary>代码依据 cmd/ascend-npu-dra-kubeletplugin/main.go</summary>

  ```diff
  -			Usage: "Number of soft-share vNPU instances per physical NPU (1-100).",
  +			Usage: "Number of soft-share vNPU instances per physical NPU (1-63).",
  ```
  </details>
- **shm 文件仅在整卡全部实例归还后才删**:`SoftManager.DeleteVNPU` 里 `returnVNPUID` 改为返回 `fullyReturned`,仅当一张物理 NPU 的**所有** vNPU 实例都归还时才 `os.Remove` 共享内存文件(shm 由该卡所有 vNPU 实例共用),避免提前删导致其他在用实例失效。
  <details><summary>代码依据 internal/vnpu/soft_manager.go</summary>

  ```diff
  -	m.returnVNPUID(config.PhysicalNPUID, config.VirtualNPUID)
  +	fullyReturned := m.returnVNPUID(config.PhysicalNPUID, config.VirtualNPUID)
  +	if fullyReturned {  // shm 由整卡所有 vNPU 实例共用,全部归还才可删
  +		os.Remove(filepath.Join(m.shmDir, config.ShmID)) ... }
  ```
  </details>
- **调度策略经 channel 下发到 ResourceSlice + 配置加载硬化**:`SoftDeviceUpdate.VnpuMode` 字段改名 `SchedulingPolicy`(fixed-share/elastic/best-effort),`propagateInitialPolicies` 把设备初始策略注入软管理器以便 `returnVNPUID` 归零时恢复;`main.go` 的 profile 配置加载从"静默忽略 `yaml.Unmarshal` 错误"改为 `loadProfileConfig`(缺文件 OK、损坏即报错),并把误引的 `testify/assert/yaml` 换成正牌 `gopkg.in/yaml.v3`。
  <details><summary>代码依据 internal/profiles/vnpu_manager.go / cmd/.../main.go</summary>

  ```diff
  -	VnpuMode   string
  +	// SchedulingPolicy: fixed-share / elastic / best-effort
  +	SchedulingPolicy string
  -	"github.com/stretchr/testify/assert/yaml"
  +	"gopkg.in/yaml.v3"
  +func loadProfileConfig(path string) (npu.ProfileConfig, error) { ... 缺文件不报错、损坏报错 ... }
  ```
  </details>

### 后续发展方向 [AI]
- 这批是明确的 **DRA 软 vNPU 生产可靠性(DFX)硬化**:重启态恢复 + 拒绝模拟设备 + shm 生命周期正确性,指向 npu-dra-plugin 正从"能跑"走向"可运维上生产"。`RestoreVNPU` 依赖 checkpoint 里持久化的 `soft:`/`hard:` deleteRef,说明 checkpoint 已是软/硬 vNPU 的权威状态源。证据覆盖恢复/发现/清理三处;未见 checkpoint 结构本身的版本兼容处理(V1.PreparedClaims 直接读)。
- `SchedulingPolicy` 进入 ResourceSlice attribute 且有 fixed-share/elastic/best-effort 三档,方向是**软切分的算力 QoS 策略化**(弹性/尽力而为/固定配额),后续可结合 vCANN-rt 观察各策略在运行时的隔离强度差异。证据仅覆盖字段更名与初始策略注入,未见各策略的实际算力分配实现。

## 本期无实质改动(折叠)
- **vNPU**:本期 2 个提交(`!85 fix: add xpu-device-plugin and xpu-exporter module UT` 等)全是新增/补充单元测试(信号文件皆 `*_test.go`),无功能代码改动,不展开。
- npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / volcano-ext / ub-network-device-plugin —— 均无新提交。
- mind-cluster 内 `component/ascend-faultdiag`(A5 芯片故障诊断适配,大量 host_a5.py)与 `component/sriov-cni`、`component/sriov-network-device-plugin`(整体删除)均在本 task 8 个 PATHPREFIX 之外,不做代码研判,仅在"当日重要改变"记录删除信号。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=5fcb7b99c3f3662fa33a9acd62e4c2465863c895 tag=v26.1.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=npu-operator sha=5c41aa83e7e810159f5a7be3c5327c3a350a54bd tag=v26.6.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=vNPU sha=44bef0ba5e48c2700c6afb9f581bca1a25c59012 tag=v0.1.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=npu-dra-plugin sha=b33edd6dc28f0dc96f908ee7de414af931bb8fe1 tag=v26.6.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-20 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-20 -->
