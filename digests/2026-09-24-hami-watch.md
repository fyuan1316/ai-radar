# HAMi diff 雷达 2026-09-24

## 摘要
- HAMi 主仓给 **动态 MIG** 补上了 **CDI 注入路径**(#3070):新增 `cdi/dynamic_mig.go` 与 `DynamicMIGInterface`,device-plugin 在 Allocate 返回前为每个运行时 MIG 实例落地一份独立 CDI 文件,并在启动/回收/回滚三处补齐幂等清理。这是把"临时切出来的 MIG 设备"接进 CDI 生态的关键一步,不再依赖静态 CDI spec。
- AWS Neuron 侧把每设备核数上限从 2 抬到 4,正式支持 **Inferentia1 四 NeuronCore**(#3082),并把 core 配额校验下沉进 scheduler 打分阶段(`neuronCorePeak` + `FitQuota`)。
- HAMi-WebUI 上线**设备切分可视化**(#311):proto 新增 `ContainerDevice`/`MigProfile`/`MigPlacement` 消息,前端 `DeviceSplit.vue` 画出 MIG 槽位占用与"还能塞下哪些 profile"。控制台从"看用量"走向"看物理切分布局"。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增独立文件 `pkg/device-plugin/nvidiadevice/nvinternal/cdi/dynamic_mig.go`(+401)与 `DynamicMIGInterface` 接口,动态 MIG 走 CDI 注入。https://github.com/Project-HAMi/HAMi/pull/3070
- Project-HAMi/HAMi-WebUI [API/CRD变更] `server/api/v1/container.proto`、`card.proto` 新增 `ContainerDevice`/`MigProfile`/`MigPlacement` 消息及 `GPUReply.mig_profiles` 字段。https://github.com/Project-HAMi/HAMi-WebUI/pull/311

## Project-HAMi/HAMi: 6531fdd9 -> c1baf1df
- 比较: 6531fdd9 -> c1baf1df | ahead=4 | files=29 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/6531fdd97682642eccf10caefc13da418b3bba7e...c1baf1df73d61eda7cc1675776f5643c98439ea5

### AI 总结重点(源码 diff 为据)
- **动态 MIG 首次接入 CDI**:新增 `DynamicMIGInterface`(`EnsureDynamicMIGDevice`/`RemoveDynamicMIGDevice`/`ReplaceDynamicMIGDevices`),`cdiHandler` 实现之。每个运行时切出的 MIG 实例被写成一份 `hami-dynamic-mig-<sha256(uuid)>.json` 的独立 CDI spec,与 base GPU spec 隔离(`DynamicMIGClass = "dynamic-mig"`)。此前 HAMi 的 MIG 只有静态 CDI/annotation 路径,动态创建的 GI/CI 无法用 CDI 注入。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/cdi/dynamic_mig.go</summary>

  ```diff
  +// DynamicMIGClass isolates HAMi-owned runtime MIG entries from the base GPU spec.
  +const DynamicMIGClass = "dynamic-mig"
  +const dynamicMIGFilePrefix = "hami-dynamic-mig-"
  +
  +type DynamicMIGInterface interface {
  +	EnsureDynamicMIGDevice(DynamicMIGDevice) (string, error)
  +	RemoveDynamicMIGDevice(string) error
  +	ReplaceDynamicMIGDevices([]DynamicMIGDevice) error
  +}
  +func DynamicMIGName(uuid string) (string, error) {
  +	if uuid == "" || !strings.HasPrefix(uuid, "MIG-") { return "", fmt.Errorf(...) }
  +	sum := sha256.Sum256([]byte(uuid))
  +	return "mig-" + hex.EncodeToString(sum[:]), nil
  +}
  ```
  </details>

- **Allocate 路径在返回前落地 CDI 条目**:`GetContainerDeviceStrArray` 里,每创建一个 MIG(`EnsureDynamicMIGDevice`)就发布对应 CDI;失败直接报错中断分配,不再返回"半个"设备。回滚 defer 里对已创建 MIG 同步 `RemoveDynamicMIGDevice`,删不掉的记进 `pendingCDIRemovals` 待后续清。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go</summary>

  ```diff
  +		if nv.deviceListStrategies.AnyCDIEnabled() {
  +			handler, ok := nv.cdiHandler.(cdi.DynamicMIGInterface)
  +			if !ok { return nil, fmt.Errorf("dynamic MIG CDI handler is unavailable") }
  +			record, err := nv.dynamicMIGRecord(gpuIndex, reservation.GPUUUID, reservation.Profile, ...)
  +			if err != nil { return nil, err }
  +			if _, err := handler.EnsureDynamicMIGDevice(record); err != nil {
  +				return nil, fmt.Errorf("publish CDI entry for MIG device %s: %w", migUUID, err)
  +			}
  +		}
  ```
  </details>

- **回收只删"确实被销毁"的实例,避免误删活条目**:`ReconcileActiveAllocations` 拆出 `ReconcileActiveAllocationsWithDestroyed`,只返回真正 destroy 掉 GI/CI 的 UUID;server 端拿这批 UUID 再二次确认 `byAllocationMigUUID` 里已无该 live 记录才 `RemoveDynamicMIGDevice`。启动时 `recoverDynamicMIGCDI` + `CreateSpecFile` 重建父卡 spec。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/migmgr.go</summary>

  ```diff
  +// ReconcileActiveAllocationsWithDestroyed reports only MIG UUIDs whose GI/CI
  +// pair was actually destroyed, so CDI cleanup cannot remove a live entry.
  +func (m *MigInstanceManager) ReconcileActiveAllocationsWithDestroyed(active ...) ([]string, error) {
  +	destroyed := []string{}
  ...
  +			destroyed = append(destroyed, oldUUID)
  ...
  +	return destroyed, nil
  ```
  </details>

- **CDI spec 生成支持"仅父卡"模式**:`cdiHandler` 加 `dynamicMIGMode`/`SetDynamicMIGMode`,`CreateSpecFile` 在该模式下对 `gpu` class 不再走 full spec,而是按 `DeviceGetCount` 逐个父卡 UUID 生成——把父卡与动态 MIG 子设备的 CDI 生成解耦。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/cdi/cdi.go</summary>

  ```diff
  -		if class == "gpu" {
  +		if class == "gpu" && !cdi.dynamicMIGMode {
  ...
  +		if class == "gpu" && cdi.dynamicMIGMode {
  +			count, ret := cdi.nvmllib.DeviceGetCount()
  +			if count == 0 { return fmt.Errorf("dynamic MIG CDI requires at least one parent GPU") }
  ```
  </details>

- **AWS Neuron:支持 Inferentia1 四核**:`maxCoresPerNeuronDevice` 2→4;删掉 `splitCoreRequest`(不再把核数摊到多设备的旧逻辑);解码历史分配时 `coresPerNeuronDevice` 回退到旧的两核布局(向后兼容)。新增 `ContainerDeviceRequest.TotalCoresreq` 与 `CoreMaskAccounting` 接口,把"位掩码型核占用"和"加法型核占用"两类后端区分开。
  <details><summary>代码依据 pkg/device/awsneuron/device.go + pkg/device/devices.go</summary>

  ```diff
  -	maxCoresPerNeuronDevice = int64(2)
  +	// Inferentia1 exposes four NeuronCores; Inferentia2 and Trainium expose two.
  +	maxCoresPerNeuronDevice = int64(4)
  ...
  -func (dev *AWSNeuronDevices) splitCoreRequest(cores int64) (int32, int32, error) { ... }   // 整段删除
  ...
  +	// TotalCoresreq preserves a NeuronCore request until the candidate node's
  +	// cores-per-device geometry is known. Other backends leave it zero.
  +	TotalCoresreq int64
  +type CoreMaskAccounting interface {
  +	AccumulateCores(used, allocated int32) int32
  +	CountAllocatedCores(allocated int32) int64
  +}
  ```
  </details>

- **NeuronCore 配额下沉到打分阶段**:`scoreNode` 里对 AWS Neuron 设备算实际峰值核数(`neuronCorePeak`,用 `bits.OnesCount32` 数掩码位,init/sidecar 走峰值规则),再 `FitQuota` 校验命名空间配额,超了直接 "AWS NeuronCore quota exceeded" 拒绝该节点。此前 admission 只校验单容器上限,配额判断没进 scheduler 打分。
  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
  +	if cores := neuronCorePeak(task, score.Devices[awsneuron.AWSNeuronDevice]); cores > 0 &&
  +		!s.quotaManager.FitQuota(task.Namespace, 0, 1, cores, awsneuron.AWSNeuronDevice) {
  +		return nodeScoreResult{reason: "AWS NeuronCore quota exceeded"}
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 动态 MIG + CDI 是 HAMi 把 MIG 从"静态划好、静态注入"推向"按需切、CDI 注入、崩溃可恢复"的明确信号:启动 recover、Allocate 发布、回收/回滚三态幂等清理都补齐了,说明目标是让运行时切出的 MIG 在 kubelet 重启/plugin 重启后仍能对齐。证据只覆盖 device-plugin 与 cdi 包的 diff,未见 scheduler 侧如何决定"何时动态切/合" MIG 的 hunk。
- AWS Neuron 的 `CoreMaskAccounting` 抽象+`TotalCoresreq` 延迟解析,暗示后续要支持"同一请求落在不同 cores-per-device 几何的节点"——即异构 Neuron 机型混跑。证据只覆盖 device.go/devices.go/score.go,未见 PatchAnnotations 全量 hunk(截断),掩码编码细节未完全展开。

## Project-HAMi/HAMi-WebUI: b2af8ecc -> 846c0e2d
- 比较: b2af8ecc -> 846c0e2d | ahead=1 | files=43 | Release: v1.3.0
- https://github.com/Project-HAMi/HAMi-WebUI/compare/b2af8ecc94a2330a6f11ab189522f16f328495bd...846c0e2d3360cc7240bb61968e4cc7e3cea53443

### AI 总结重点(源码 diff 为据)
- **proto 新增设备级切分模型**:`container.proto` 加 `repeated ContainerDevice devices = 30`(每个已分配设备一条,含 `allocated_cores`/`allocated_mem`/`allocation_shape`/`mig_start`/`mig_size`),`allocation_shape` 语义扩展到含 `mig`。这让前端能把一次分配精确落到具体设备与 MIG 槽位,而非只给聚合数字。
  <details><summary>代码依据 server/api/v1/container.proto</summary>

  ```diff
  +  // One entry per allocated device, so a page can place the allocation on it.
  +  repeated ContainerDevice devices = 30;
  +message ContainerDevice {
  +  string id = 1;
  +  int32 allocated_cores = 3;
  +  string allocation_shape = 6;   // whole, template, soft (HAMi-core), mig or unknown
  +  optional int32 mig_start = 8;
  +  optional int32 mig_size = 9;
  +}
  ```
  </details>

- **card.proto 暴露 MIG profile 与合法放置点**:`GPUReply` 加 `repeated MigProfile mig_profiles = 16`,新 `MigProfile`(name/memory_mb/slice_count/core%/placements)与 `MigPlacement`(start/size)。控制台由此知道每张卡注册了哪些 MIG 规格、每种能放在 GPU 的哪些槽位。
  <details><summary>代码依据 server/api/v1/card.proto</summary>

  ```diff
  +  repeated MigProfile mig_profiles = 16;
  +message MigProfile {
  +  string name = 1;
  +  int32 slice_count = 3;
  +  int32 core = 5;                  // Compute share of the whole GPU, in percent
  +  repeated MigPlacement placements = 6;
  +}
  +message MigPlacement { int32 start = 1; int32 size = 2; }
  ```
  </details>

- **前端画出切分布局并算"还能塞下什么"**:新增 `DeviceSplit.vue`(+777)与 `device-split.mjs`。`collectHolders` 把每个容器的 `devices` 摊成"持有者",`fitting()` 按已占槽位算每种 profile 还能非重叠放几个;MIG 走槽位网格(`split-mig__grid`),soft/HAMi-core 走共享 meter 条。测试覆盖 A100 8 槽、stranded 槽、重叠/越界放置等。
  <details><summary>代码依据 packages/web/projects/vgpu/components/device-split.mjs</summary>

  ```diff
  +// How many more instances of each profile fit: the most non-overlapping
  +// allowed placements that avoid every used slot.
  +const fitting = (profiles, occupied) => profiles.map((profile) => {
  +  const open = profile.placements
  +    .filter((placement) => covers(placement).every((slot) => !occupied[slot]))
  ```
  </details>

- **服务端解析 HAMi 的 MIG 分配注解**:新增 `server/internal/provider/nvidia/mig.go`,`decodeMigAllocations` 严格校验 `hami.io/vgpu-mig-allocations`(缺字段/重复 slot/运行时字段不齐即整体作废),并有 `LegacyMigUUID` 兼容 v2.10 前把 template/slot 拼进 UUID(如 `GPU-x[1-2]`)的旧格式。
  <details><summary>代码依据 server/internal/provider/nvidia/mig.go</summary>

  ```diff
  +	MigAllocationsAnnotation = "hami.io/vgpu-mig-allocations"
  +func decodeMigAllocations(raw string) (map[slot]migAllocation, error) {
  +		if runtimeFields != 0 && runtimeFields != 3 {
  +			return nil, fmt.Errorf("MIG allocation %d has partial runtime identity", i)
  +// LegacyMigUUID ... recorded by HAMi before v2.10, ... as in GPU-x[1-2].
  ```
  </details>

- **Ascend NPU 详情块条件化**:`card/admin/Detail.vue` 把原 NPU spec 块下移,新增 `device-split-block`;对 `detail.mode === 'hami-core'` 的卡不再显示 template(HAMi-core 按请求量分配,模板不适用)。切分视图对 MIG/soft/template 三种模式做了差异化渲染。
  <details><summary>代码依据 packages/web/projects/vgpu/views/card/admin/Detail.vue</summary>

  ```diff
  +        <!-- HAMi-core allocates what is requested; templates never apply to this card. -->
  +        <template v-if="detail.mode !== 'hami-core'">
  +          <div class="npu-spec-subtitle">{{ $t('card.deviceConfig.templates') }}
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 正从"用量仪表盘"演进为"物理切分布局可视化":proto 把 MIG placement/profile 结构化下发,前端能画槽位占用并推算剩余可放 profile。这与主仓动态 MIG(#3070)方向一致——两端都在把 MIG 的"槽位/几何"做成一等公民。证据覆盖 proto 与前端组件,未见 provider 侧如何真正从 device-plugin 拉到 `mig_profiles` 的填充 hunk(server/internal 相关文件多为测试)。
- `LegacyMigUUID` 的存在说明 v2.10 是 MIG UUID 记录格式的分水岭;后续控制台需长期兼容两种注解格式,暗示 MIG 分配元数据 schema 仍在收敛。证据仅 mig.go 一处,未见调用方如何选择新旧路径。

## 本期无实质改动(折叠)
<details><summary>3 个 repo 无新提交/仅 EMPTY</summary>

- Project-HAMi/HAMi-core:无新提交(锚点未动 410dfbe9)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(锚点未动 6063efe9)
- Project-HAMi/ascend-device-plugin:无新提交(锚点未动 074d93a8)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=c1baf1df73d61eda7cc1675776f5643c98439ea5 branch=master release=v2.10.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=410dfbe999f1fadca3039cd629823c4534fdd90a branch=main release=— scanned=2026-09-24 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-09-24 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=074d93a8e1ca4f357fb1f4946f0566ced93641a6 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-24 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=846c0e2d3360cc7240bb61968e4cc7e3cea53443 branch=main release=v1.3.0 scanned=2026-09-24 -->
