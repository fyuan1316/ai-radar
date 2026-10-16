# 昇腾算力栈 diff 雷达 2026-10-17

## 摘要
- **重大能力:mind-cluster 的 DRA 驱动新增"动态 vNPU(硬切分)"调度能力**(commit `feat(dra): 增加基础的动态 vNPU（硬切分）调度能力`)。此前 `ascend-dynamic-resource-allocation` 只能把整卡/预创建的静态 vNPU 以独占方式发布给 DRA;本期引入新模式:一个 ResourceClaim 可按 AI-core 容量 + DCMI 模板向物理 NPU 申请一块切片,驱动在 Prepare 阶段**实时调 DCMI 创建 vNPU**、校验、checkpoint,Unprepare 时销毁。走的是 K8s 1.34+ DRA 的**可消费容量(consumable capacity)+ ShareID 共享设备**模型(`AllowMultipleAllocations=true`),一张物理卡可被多 claim 按算力份额共享。
- 该特性**默认关闭**:新 flag `-presetVirtualDevice` 默认 `true`(保持原整卡+静态 vNPU 独占语义),置 `false` 才启用动态硬切分;部署清单已显式钉 `-presetVirtualDevice=true`。仅 910(A2/A3)支持,950(A5)显式返回空容量("A5 软共享不属于动态硬切分")。
- 命中 `[新能力]`(新 component 路径 `ascend-dynamic-resource-allocation` 的动态 vNPU 子系统)+ `[架构方向]`(转向 DRA 可消费容量/共享设备模型)+ `[版本跨档]`(tag v26.1.1 → v26.2.0 minor 跨档)。**覆盖盲点**:该 component 不在本 task 的 PATHPREFIX 清单里,信号文件仅因 commit 标题被捕获,详见文末"扫描说明"。
- 其余 8 仓(openFuyao 全部)本期无新提交,全 EMPTY。

## 当日重要改变
- mind-cluster `[新能力]` DRA 驱动新增动态 vNPU 硬切分:claim 级实时创建/销毁 vNPU,证据 `component/ascend-dynamic-resource-allocation/internal/device/dynamic_vnpu_manager.go`(新增)+ `internal/plugin/state.go` Prepare 重写 https://gitcode.com/Ascend/mind-cluster/commit/98ac9ada4e
- mind-cluster `[架构方向]` 驱动从"仅发布设备属性"转为"发布可消费容量 + AllowMultipleAllocations",引入 DeviceClass `dynamic-vnpu.huawei.com`,证据 `internal/driver/driver.go` `buildDriverResources` + `build/ascend-dra-driver.yaml`
- mind-cluster `[版本跨档]` tag v26.1.1 → v26.2.0(minor)

## mind-cluster: 28399af5 -> 07e3f3cc
- 比较:28399af5..07e3f3cc | tag: v26.2.0 | commits=12 | truncated=false
- https://gitcode.com/Ascend/mind-cluster/compare/28399af5e4b11af64be2a49406da1ffde8e99863...07e3f3ccb778a76db838fc18344d77e8e1c47d0e

### AI 总结重点(源码 diff 为据)

- **新增 `DynamicVNPUManager`:在 claim Prepare 时实时创建硬切分 vNPU 并做硬件级校验,Unprepare 时销毁**。`Create(phyID, template, requestedAICore)` 先把 phyID 解析为 logicID、调 `dmgr.CreateVirtualDevice`(VDevID/VfgID 传 `InvalidID`、只给 `TemplateName`),再回查 DCMI inventory 确认**实际分到的 AI-core 数 == 请求数**、且该 vNPU 未被占用,不符即报错并由调用方清理。`Destroy` 先查 inventory 再 `DestroyVirtualDevice`。这把"切分"从过去的"管理员预创建静态 vNPU"推进到"调度时按需切分",语义对标 HAMi vGPU 的动态切分,但走的是 DCMI 硬切分(非软 hook)。
  <details><summary>代码依据 component/ascend-dynamic-resource-allocation/internal/device/dynamic_vnpu_manager.go(新增)</summary>

  ```diff
  +func (m *DynamicVNPUManager) Create(phyID int32, template string, requestedAICore int64) (*DynamicVNPU, error) {
  +	logicID, err := m.dmgr.GetLogicIDFromPhysicID(phyID)
  +	out, err := m.dmgr.CreateVirtualDevice(logicID, devcommon.CgoCreateVDevRes{
  +		VDevID: devcommon.InvalidID, VfgID: devcommon.InvalidID, TemplateName: template,
  +	})
  +	...
  +	for _, current := range info.VDevInfo {
  +		if current.VDevID != out.VDevID { continue }
  +		if vnpuInUse(current.QueryInfo) {
  +			return created, fmt.Errorf("created vNPU %d is already in use", out.VDevID) }
  +		if float64(current.QueryInfo.Computing.Aic) != float64(requestedAICore) {
  +			return created, fmt.Errorf("vNPU %d hardware ... AI cores=%v; requested ... %d", ...) }
  +		return created, nil
  +	}
  ```
  </details>

- **新 flag `-presetVirtualDevice`(默认 true)作为新旧模式开关;动态硬切分默认关闭、部署清单显式钉 true**。`presetVirtualDevice=true` 保持"发布整卡 + 预创建 vNPU 独占"语义;`false` 才启用动态硬切分。`build/ascend-dra-driver.yaml` 的启动命令追加了 `-presetVirtualDevice=true`,说明该能力本期是"落地代码但默认不开"。
  <details><summary>代码依据 internal/flags/draoption.go + build/ascend-dra-driver.yaml</summary>

  ```diff
  +	flag.BoolVar(&d.PresetVirtualDevice, "presetVirtualDevice", true,
  +		"Publish whole cards and pre-created vNPUs exclusively; false enables dynamic hard slicing")
  ...
  -        command: ["/bin/bash", "-c", "exec ascend-dra -logLevel=0 --enable-healthz --healthz-address=11258"]
  +        command: ["/bin/bash", "-c", "exec ascend-dra ... --healthz-address=11258 -presetVirtualDevice=true"]
  ```
  </details>

- **驱动从"只发设备属性"升级为"发布可消费容量 + 允许多重分配",接入 DRA consumable-capacity/共享设备模型**。`buildDriverResources` 在非 preset 模式下给物理设备挂 `Capacity`(key=`aiCoreNum`)、置 `AllowMultipleAllocations=true`、打 `deviceKind=dynamic-vnpu` 属性。`generation_910.DeviceCapacity` 仅对未切分、AICore>0 的物理卡发布 `aiCoreNum` 容量;950 显式返回 nil。配套新增 DeviceClass `dynamic-vnpu.huawei.com`(CEL 选 `deviceKind=='dynamic-vnpu'`)。这是一张物理卡被多个 claim 按算力份额共享的关键——与 K8s 1.34 DRA 的 partitionable/consumable capacity 对齐。
  <details><summary>代码依据 internal/driver/driver.go + internal/device/generation_910.go + build/ascend-dra-driver.yaml</summary>

  ```diff
  +		if !d.draConfig.DraOption.PresetVirtualDevice {
  +			capacity = d.generation.DeviceCapacity(*dev) }
  +		if len(capacity) > 0 {
  +			published.AllowMultipleAllocations = ptr.To(true)
  +			published.Attributes["deviceKind"] = resourceapi.DeviceAttribute{
  +				StringValue: ptr.To(consts.DynamicVNPUDeviceKind) } }
  +// DeviceCapacity (910): map{ aiCoreNum: NewQuantity(dev.AICore, DecimalSI) }  // 仅物理卡 & AICore>0
  +kind: DeviceClass  metadata: name: dynamic-vnpu.huawei.com  // CEL: deviceKind == 'dynamic-vnpu'
  ```
  </details>

- **`ShareID` 贯通 PreparedDevice → kubeletplugin.Device;claim 请求的模板从 ResourceClaim 的 Opaque config 解析**。`PreparedDevice` 新增 `DynamicVNPU/CDIDeviceName/ShareID/LogicID/PhyID/VDevID/TemplateName` 字段并序列化进 checkpoint;`validateDynamicAllocation` 要求动态分配必须带非空 `ShareID` 与正整数 `aiCoreNum` 消费容量;`dynamicVNPUTemplate` 从 `claim.Status.Allocation.Devices.Config` 的 Opaque(driver=npu.huawei.com)解出 `{"template":...}`,冲突/空即报错。
  <details><summary>代码依据 internal/plugin/state.go</summary>

  ```diff
  +	if result.ShareID == nil || *result.ShareID == "" {
  +		return 0, 0, fmt.Errorf("request %s has no share ID for dynamic vNPU allocation", result.Request) }
  +	requestedAICore, exact := capacity.AsInt64()
  +	if !hasAICoreCapacity || !exact || requestedAICore <= 0 { ... }
  +	phyID, err := parsePhysicalNPUName(result.Device)
  ```
  </details>

- **Prepare/Unprepare 重写为"硬件操作 + 失败全回滚",并以 `ValidateMode` 取代启动期 `LoadCheckpoint`,拒绝新旧模式混用**。Prepare 任一步失败(创建硬件/写 CDI/CDI 计数不符/checkpoint)都走 `rollbackPrepare`:删 CDI spec + 销毁已建 vNPU + `errors.Join` 保留原始错误。Unprepare 顺序改为先销毁硬件→删 CDI→落 checkpoint。启动期 `ValidateMode(preset)` 遍历 checkpoint,若已有设备的 `DynamicVNPU` 标志与当前 `presetVirtualDevice` 不符即拒启,防止重启后两种切分模式混用导致悬挂 vNPU。
  <details><summary>代码依据 internal/plugin/state.go + internal/plugin/plugin.go + internal/driver/driver.go</summary>

  ```diff
  +	if err := d.ascendDraPlugin.ValidateMode(d.draConfig.DraOption.PresetVirtualDevice); err != nil {
  +		return fmt.Errorf("validate vNPU mode: %w", err) }
  -	if err := adp.state.LoadCheckpoint(); err != nil { ... }
  +func isPreparedDeviceModeCompatible(preset bool, p *PreparedDevice) bool { return preset != p.DynamicVNPU }
  +func (s *DeviceState) rollbackPrepare(claimUID string, preparedDevices PreparedDevices, prepareErr error) error {
  +	... return errors.Join(prepareErr, cdiErr, cleanupErr) }
  ```
  </details>

- **ascend-common 放宽 vNPU 模板校验:删掉编译期 `IsValidTemplateName(DevType,...)` 白名单,改为只拒空/含 NUL,DCMI 为权威**。原 `CreateVirtualDevice`/`GetVirtualDeviceInfo` 会用硬编码白名单校验模板名,现因动态模板来自 ResourceClaim(非编译期清单),改为信任 DCMI。同时去掉静态 vNPU 的 `aiCore` 属性(`attrKeyAICore`),改走容量模型;新增 `setResources` 从 DCMI `CgoComputingResource` 读 AICore/AICpu/MemorySize(带溢出防护),`NpuDevice` 加 `AICpu/MemorySize` 字段。
  <details><summary>代码依据 component/ascend-common/devmanager/devmanager.go + generation_common.go + types.go</summary>

  ```diff
  -	if !common.IsValidTemplateName(d.DevType, vDevInfo.TemplateName) {
  +	if vDevInfo.TemplateName == "" || strings.ContainsRune(vDevInfo.TemplateName, 0) {
  		return common.CgoCreateVDevOut{}, fmt.Errorf("input invalid template name: %s", vDevInfo.TemplateName) }
  // GetVirtualDeviceInfo 删除整段 IsValidTemplateName 循环校验
  -	attrKeyAICore = "aiCore"   // 静态 vNPU 的 AI 核属性被移除,改走 DeviceCapacity
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 DRA 路径正从"管理员预切分 + 整卡/静态 vNPU 独占"迈向"调度时按算力份额动态硬切分 + 单卡多 claim 共享",这是本 task 开跑以来昇腾侧第一个**能力级**(非健壮性/文档)跃进,直接对标 HAMi vGPU 的动态切分,但实现路线是 DCMI 硬切分 + K8s 原生 DRA consumable-capacity,而非 HAMi 的 CUDA/CANN 软 hook。证据覆盖:创建/销毁/校验/容量发布/模式开关/回滚全链路均有 hunk;**未覆盖**调度器侧(Volcano/kube-scheduler 如何对 `aiCoreNum` 容量做 bin-packing)与 vCANN 层如何感知硬切分。
- 该能力默认关闭且仅 910(A2/A3),950(A5)明确"软共享另算",说明短期内昇腾把"硬切分(910)"与"软共享(950/A5)"按代差分成两条技术路线;A5 的软共享能力本期无代码,是后续观察点。
- 模板白名单下放给 DCMI 后,模板合法性不再由 K8s 侧编译期保证,运维需关注 ResourceClaim 里 `template` 字段的输入面(目前仅靠 DCMI 创建后回查 AI-core 数兜底)。证据只到驱动层校验,未见是否有 admission 层对 template/容量组合做准入。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(保锚点)</summary>

- npu-operator:无新提交
- npu-container-toolkit:无新提交
- npu-driver-installer:无新提交
- vNPU:无新提交
- npu-node-provision:无新提交
- npu-dra-plugin:无新提交
- volcano-ext:无新提交
- ub-network-device-plugin:无新提交
</details>

## 扫描说明(覆盖盲点,下次改进)
- 本期 DRA 动态 vNPU 全部落在 `component/ascend-dynamic-resource-allocation/` 与 `component/ascend-common/`,**两者均不在本 task 执行步骤的 PATHPREFIX 清单**(清单只列 ascend-device-plugin/docker-runtime/for-volcano/operator/npu-exporter/noded/clusterd/infer-operator)。helper 的"信号文件/patch 节选"因此只报出 README,是靠 commit 标题 `feat(dra)` 才回溯到真实代码。**下次应把 `component/ascend-dynamic-resource-allocation` 和 `component/ascend-common` 补进 PATHPREFIX**,否则 DRA 主线会被 PATHPREFIX 过滤静默漏掉。
- 文档类提交(noded/clusterd README 模板化、MindIO TFT README)本期占改动量大头,属标准化非能力演进,不单列。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=07e3f3ccb778a76db838fc18344d77e8e1c47d0e tag=v26.2.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.6.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.6.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=vNPU sha=60eb00c70ff741cbb4a3d06779b9995c441a67e6 tag=v0.1.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=npu-dra-plugin sha=a091c78614ecd0c00412b15aa8a0d2ecd717ba39 tag=v26.6.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-10-17 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=021fe219256b1b5618b76c5a4c5f40aaa7ec1a16 tag=1.0.2 scanned=2026-10-17 -->
