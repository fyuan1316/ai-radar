# 昇腾算力栈 diff 雷达 2026-11-18

> 距上期(2026-11-03)停跑 15 天,mind-cluster 积压 128 个 commit 且 compare 被截断(truncated=true),helper 进入 `__OVERVIEW__`。本期在概览之外,**对 14 个重点提交逐个做单 commit compare(parent...sha)读了真实 hunk**,下文"AI 总结重点"仅基于这些 hunk;其余提交只按标题聚类,未读代码。

## 摘要
- **mind-cluster [DRA 收缩]**:昇腾 DRA 驱动的支持范围收缩到只剩 A5(Ascend 950)。驱动 YAML 删掉了 `ascend910.ext.huawei.com` DeviceClass(之前可用扩展资源名 `huawei.com/Ascend910` 申请 910 整卡),文档里的 A2/A3 也一并去掉。KEP-5004 扩展资源名路径现在只剩 `npu.ext.huawei.com` → `huawei.com/npu`,也只支持 950。另外新增 `deviceResetTimeout` 启动参数校验,范围 [10, 600],超出直接报错。
- **mind-cluster [默认策略转向 + 新能力]**:clusterd 静默故障检测从默认关改为**默认开**(`DefaultSilentFaultEnabled = true`),判定时还会参考 DPU 的硬件故障。上期 volcano 侧已把静默故障退避默认值从 0 改成 600s,两期合起来就是"静默故障治理默认上线"。ascend-docker-runtime 和 ascend-common 新增一整套 RoCE RDMA 注入链路(`ASCEND_RDMA_DEVICES` 环境变量 + 新增 `rdma/` 包),**只走 legacy 模式,CDI 模式下会被忽略**。device-plugin 通过 DCMI 查 NPU 与网卡的亲和关系(仅 A5),DaemonSet 因此**改成 `hostNetwork: true`**。
- **mind-cluster [生态适配]**:npu-exporter 新增 `-containerMode=crio`,走 CRI `ContainerStatus(Verbose)` 拿容器的 NPU 分配,OpenShift 这类 CRI-O 底座可以直接监控了。此外 device-plugin 的故障升级拆成 combined / independent 两种模式;noded 的三个监控插件改为各自配置轮询周期;infer-operator 缩容时优先删未就绪实例。ub-network-device-plugin 只补了测试并修了数据竞争,其余 7 个仓无新提交。

## 当日重要改变
- mind-cluster [弃用/移除] 删除 DRA DeviceClass `ascend910.ext.huawei.com`(扩展资源名 `huawei.com/Ascend910`),DRA 支持代际收缩为仅 Ascend 950(A2/A3 移出)。commit `69b72a0a34b3` https://gitcode.com/Ascend/mind-cluster/commit/69b72a0a34b352eba07d58b0d06e77ecf609e2dd ;文档 `1550cac4a061` https://gitcode.com/Ascend/mind-cluster/commit/1550cac4a061fa73613f6b230ffdc65361d3e744
- mind-cluster [架构方向] clusterd 静默故障检测默认 `enabled: false → true`,DPU 硬件故障单独记录,作业申请了 DPU 时才计入判定窗口。commit `d16ed24c15c9` https://gitcode.com/Ascend/mind-cluster/commit/d16ed24c15c9c6f0dd3a13b960dbfc38a558d7d6
- mind-cluster [新能力] 新增 `component/ascend-common/rdma/` 包(hca.go / discover.go / mount.go),docker-runtime 和 hook 按 `ASCEND_RDMA_DEVICES` 注入 uverbs 字符设备与 RDMA 用户态驱动库(1825 RoCE)。commit `39ba89d9c697` https://gitcode.com/Ascend/mind-cluster/commit/39ba89d9c697b4441ce1737e8b6431e94b024746 / `903f5d77bb6f` https://gitcode.com/Ascend/mind-cluster/commit/903f5d77bb6f13f10b3d19843adae21d40c8cb8c
- mind-cluster [新能力][部署变更] 新增 `devmanager/npu_nic` 包,通过 DCMI `dcmiv2_get_topo_info_by_device_id_and_nic_name` 查 NPU 与网卡的拓扑关系;ascend-device-plugin DaemonSet 改为 `hostNetwork: true`。commit `24f51e2428a7` https://gitcode.com/Ascend/mind-cluster/commit/24f51e2428a70e7fd7226d68c02398b3a761a6d3
- mind-cluster [新能力] npu-exporter 支持 CRI-O(新增 `collector/container/crio.go`、`-containerMode=crio`)。commit `2502e19b0296` https://gitcode.com/Ascend/mind-cluster/commit/2502e19b0296a2cb7ea11d83381c20efa19eabbf
- mind-cluster [版本] 最新 tag v26.2.1(2026-11-02),是 26.2 线的 patch 版,**不算跨档**;最高 semver 仍是上期已见的 v26.3.0-beta.1。helper 按日期排序,所以锚点 tag 显示为 v26.2.1。

## mind-cluster: 0a1f9a1e -> 6fc1d5e1
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/0a1f9a1e27d66474618d960fe0a35edfd06f7733...6fc1d5e1f35e18e683529eaf8efb35b99e3a5af4 | tag: v26.2.1 | commits=128 | truncated=true
- PATHPREFIX 在 task 默认清单之外补了 `component/ascend-dynamic-resource-allocation` 和 `component/ascend-common`:本期 DRA、RDMA、NPU 与网卡亲和三条线的代码都落在这两个目录里。

### 大区间概览(按提交标题聚类,未逐文件读代码)
1. **RoCE / RDMA 网络接入**(本期最大主题):1825 RoCE 驱动设备挂载 1~5 连续 PR、补 RDMA 依赖库挂载、rdma-shared-dev-plugin 修 DCMI 端口初始化、dpu-exporter 增加 RDMA 指标,以及 device-plugin 和 rdma-device-plugin 从驱动取 NPU 与网卡亲和关系。
2. **故障诊断(FD)知识库扩充**:掉卡故障模式库 Part1-3、HCCL 模块故障模式库、CRC 计数错误解析、A5 主节点定位、无 CANN_Plog 时上报全部 CANN_Device 故障,外加大量 UT/ST。
3. **静默故障 / 亚健康调度**:clusterd 静默故障默认开启并纳入 DPU;volcano 侧支持 DPU 亚健康不优先调度、修 chip8-node8-ra64-sp 亚健康失效、修 1520 亚健康异常、单节点配了 ra/sp 时改用非节点间亲和、修 sp-block 判定。
4. **DRA 收缩到 A5**,并补参数校验(见下)。
5. **运维面**:noded 各插件分别配置轮询周期,npu-exporter 支持 CRI-O,infer-operator 缩容策略调整,taskd 在 MindSpore 场景下处理 SIGTERM,docker-runtime 增加默认挂载目录和 src:dst / 通配符校验。

改动热点目录(helper,PATHPREFIX 限定,truncated 后可能不全):clusterd/pkg 16、infer-operator/pkg 12、ascend-device-plugin/pkg 11、ascend-common/devmanager 11、noded/pkg 9、ascend-for-volcano/internal 9、npu-exporter/collector 7、ascend-docker-runtime/cli 6、ascend-common/rdma 6。

### AI 总结重点(源码 diff 为据,仅覆盖下列 14 个单 commit compare)
- **DRA:删除 910 整卡的扩展资源 DeviceClass,KEP-5004 路径只剩 950**。`build/ascend-dra-driver.yaml` 删掉了整个 `ascend910.ext.huawei.com` DeviceClass:它的 CEL 选择 `deviceKind == 'physical-npu'` 且 chipName 以 910 开头,并声明 `extendedResourceName: huawei.com/Ascend910`。`helm_tool.sh` 同步去掉这个 deviceclass 的 helm meta。剩下的 `npu.ext.huawei.com`(`huawei.com/npu`)按文档"只支持 Ascend950 系列"。文档 commit 还把支持代际里的 Atlas A2/A3 删掉;示例 CDI ID 从 `npu.huawei.com/ascend910=0` 改成 `ascend.com/npu=0`,说明 CDI vendor/class 命名同样以 950 为准。对已在 910 上用 `huawei.com/Ascend910` 扩展资源走 DRA 的用户,这是**破坏性变更**,需要改回 ResourceClaimTemplate,或者退回 device-plugin。
  <details><summary>代码依据 component/ascend-dynamic-resource-allocation/build/ascend-dra-driver.yaml</summary>

  ```diff
   apiVersion: resource.k8s.io/v1
   kind: DeviceClass
  -metadata:
  -  name: ascend910.ext.huawei.com
  -spec:
  -  selectors:
  -  - cel:
  -      expression: >-
  -        device.driver == 'npu.huawei.com' &&
  -        device.attributes['npu.huawei.com'].deviceKind == 'physical-npu' &&
  -        (device.attributes['npu.huawei.com'].chipName.startsWith('910') ||
  -         device.attributes['npu.huawei.com'].chipName.startsWith('Ascend910'))
  -  extendedResourceName: huawei.com/Ascend910
  ----
  -apiVersion: resource.k8s.io/v1
  -kind: DeviceClass
   metadata:
     name: npu.ext.huawei.com
  ```
  </details>
- **DRA:`DRAOption.Validate()` 新增 `DeviceResetTimeout` 范围校验**。原来 flag 帮助文本里写了 range [10, 600],但代码并不校验;现在超出 `api.MinDeviceResetTimeout` / `MaxDeviceResetTimeout` 时,驱动启动直接报错退出。
  <details><summary>代码依据 component/ascend-dynamic-resource-allocation/internal/flags/draoption.go</summary>

  ```diff
   func (d *DRAOption) Validate() error {
  +	if d.DeviceResetTimeout < api.MinDeviceResetTimeout ||
  +		d.DeviceResetTimeout > api.MaxDeviceResetTimeout {
  +		return fmt.Errorf("%s must be in range [%d, %d], got %d", api.DeviceResetTimeout,
  +			api.MinDeviceResetTimeout, api.MaxDeviceResetTimeout, d.DeviceResetTimeout)
  +	}
  ```
  </details>
- **clusterd 静默故障检测改为默认开启,三处同时生效**。具体是:ConfigMap 模板改为 `enabled: true`;新常量 `DefaultSilentFaultEnabled = true`;全局 `config` 初始值和 `loadSilentConfig` 反序列化前的预置值都改用这个常量。所以 **ConfigMap 里没写 `enabled` 字段时,结果也是开启**,不再是 Go 零值 false。
  <details><summary>代码依据 clusterd/pkg/application/conf/watch.go + domain/conf/config.go + build/clusterd.yaml</summary>

  ```diff
   silent_fault_policy.conf: |
  -    enabled: false
  +    enabled: true
  ...
  -		var sp conf.SilentFaultPolicy
  +		sp := conf.SilentFaultPolicy{Enabled: conf.DefaultSilentFaultEnabled}
  ...
  -var config GlobalConfig
  +var config = GlobalConfig{
  +	SilentFaultPolicy: SilentFaultPolicy{Enabled: DefaultSilentFaultEnabled},
  +}
  +	// DefaultSilentFaultEnabled default silent fault detection switch, enabled by default
  +	DefaultSilentFaultEnabled = true
  ```
  </details>
- **静默故障判定纳入 DPU 证据,但按作业是否用了 DPU 来决定**。`PendingEvent` 新增 `UseDPU` 字段;`jobUsesDpu` 读节点注解 `DpuResourceNameKey` 里的 RDMA 资源名,只要作业有任意 Pod 申请了这些资源就算用了 DPU。`DpuCenter` 原来"只透传、不挂处理器",现在挂上 `silentfault.FaultRecorderProcessor`,DPU 故障写进单独的 `dpuFaultHardwareLog`。`validatePending` 判"窗口内是否有硬件故障"(有硬件故障就不判静默故障)时,只有 `ev.UseDPU` 为真才查这份 DPU 日志。效果是:没用 DPU 的作业,不会因为节点上的 DPU 故障而被误判为"不是静默故障"。
  <details><summary>代码依据 clusterd/pkg/application/silentfault/validator.go</summary>

  ```diff
  -		if faultHardwareLog.HasFaultIn(ev.FailNode, (ev.Timestamp-hwWindowSeconds)*ms, (ev.Timestamp+hwWindowSeconds)*ms) {
  +		start := (ev.Timestamp - hwWindowSeconds) * ms
  +		end := (ev.Timestamp + hwWindowSeconds) * ms
  +		hasFault := faultHardwareLog.HasFaultIn(ev.FailNode, start, end)
  +		if ev.UseDPU && !hasFault {
  +			hasFault = dpuFaultHardwareLog.HasFaultIn(ev.FailNode, start, end)
  +		}
  +		if hasFault {
  ```
  </details>
- **RoCE RDMA 注入链路(ascend-common → docker-runtime → hook)**。分三层:
  - **请求**:新环境变量 `AscendRdmaDevicesEnv = "ASCEND_RDMA_DEVICES"`,按 sysfs HCA 名选网卡,和 NPU 编号互相独立。`rdma.ParseRDMADevices` 解析时,值为空或 `void` 表示不启用。
  - **设备**:`ResolveRdmaDeviceNode` 在 `infiniband_verbs` 目录下按 `ibdev` 文件确认 uverbs 节点归属,防止同目录的兄弟 HCA 被误注入。runtime 的 `addRDMADevices` 把每个 HCA 的 uverbs 字符设备加入 spec,并为每个设备写精确的 cgroup 规则;共享的 `/dev/infiniband/rdma_cm` 不存在时容忍。
  - **驱动库**:新增 `rdma_devices.conf`,按 vendor/device/class 三元组(`0xcc08 0x8200 0x0102 → rdma_driver`)映射到 `rdma_driver.list`(hrn5 / ibv_extend 一组用户态库)。hook 的 `selectHookMountConfigs` 根据请求的 HCA 动态并入对应的挂载集合;安装脚本 `prepare_rdma_driver_list` 部署这些配置,权限 440。
  - **边界**:`processDevicesAndHooks` 在 CDI 注入模式下遇到 `ASCEND_RDMA_DEVICES` 只打 Warn 并忽略,也就是 **RDMA 注入目前只在 legacy(OCI hook)模式可用**。
  <details><summary>代码依据 ascend-docker-runtime/runtime/process/process.go + rdma.go</summary>

  ```diff
   	if loadConfig().InjectionMode == cdiInjectionMode {
  +		rdmaRequestValue := strings.TrimSpace(parser.GetEnvValue(spec.Process.Env, api.AscendRdmaDevicesEnv))
  +		if rdmaRequestValue != "" && rdmaRequestValue != void {
  +			hwlog.RunLog.Warnf("%s is ignored in CDI mode; use legacy mode to request RDMA devices",
  +				api.AscendRdmaDevicesEnv)
  +		}
  ...
  +func processRDMARequest(spec *specs.Spec) (bool, error) {
  +	hcaNames, err := rdma.ParseRDMADevices(parser.GetEnvValue(spec.Process.Env, api.AscendRdmaDevicesEnv))
  ...
  +	// rdma_cm is shared and may be absent on hosts that do not expose it.
  +	rdmaCMNodePath := "/dev/infiniband/rdma_cm"
  ```
  </details>
  <details><summary>代码依据 ascend-docker-runtime/build/scripts/rdma_devices.conf</summary>

  ```diff
  +# Columns: vendor, device, class_code, and collection name without the .list suffix.
  +0xcc08 0x8200 0x0102 rdma_driver
  +0xcc08 0x8200 *      rdma_driver
  ```
  </details>
- **docker-runtime 的 legacy 路径重构:`addHook` 不再做 vNPU 切分**。`addHook(w, spec, &devices)` 改成 `addHook(spec)`,只注册 prestart hook,不再初始化 NPU/DCMI。`dcmi.CreateVDevice` 动态切分挪到新的 `processNPURequest` 里;显式 `VIRTUAL` 模式仍然跳过切分。这样纯 RDMA 请求(不带 NPU)也能注册 hook,不会被"没有 NPU 设备就提前 return"挡掉。(hunk 截断,未看到 processDevicesLegacy 新版全貌)
  <details><summary>代码依据 ascend-docker-runtime/runtime/process/process.go</summary>

  ```diff
  -func addHook(w dcmi.WorkerInterface, spec *specs.Spec, deviceIdList *[]int) error {
  -	if deviceIdList == nil {
  -		return nil
  -	}
  +// addHook registers the prestart hook without initializing NPU/DCMI.
  +func addHook(spec *specs.Spec) error {
  ...
  -	vdevice, err := dcmi.CreateVDevice(w, spec, *deviceIdList)
  +func processNPURequest(spec *specs.Spec, npuDeviceIDs []int) error {
  +	npuWorker, err := dcmi.GetMatchingNpuWorker()
  +	// Explicit VIRTUAL mode already refers to existing vNPU devices.
  +	if !strings.Contains(getValueByKey(spec.Process.Env, ascendRuntimeOptions), "VIRTUAL") {
  +		vdevice, err := dcmi.CreateVDevice(npuWorker, spec, npuDeviceIDs)
  ```
  </details>
- **NPU 与网卡亲和:从驱动查拓扑,device-plugin 改用 hostNetwork**。DCMI v2 新增 `DcGetTopoInfoByDeviceIDAndNicName`,注释写明"仅 A5 支持";新类型 `TopoType` 对应 `DCMI_TOPO_TYPE_*`,`IsUBAffinity()` 只认 `TopoTypeUB=8`。新包 `devmanager/npu_nic` 遍历 `/sys/class/infiniband/*/net` 列出网卡。device-plugin 的 `main` 启动时调用 `hdm.InitNpuNicMappingRefresh(ctx)`,每 5 分钟(`npuNicPollInterval`,不可配)轮询一次网卡数量,数量变化就刷新映射,驱动查不到时回退到 `loadNpuNicMappingFile`。两份 DaemonSet YAML 都**新增 `hostNetwork: true`**,推测是为了看到宿主机网卡命名空间。(manager_v2.go 只看了函数签名,映射最终怎么发布出去(注解还是文件)未核实)
  <details><summary>代码依据 ascend-device-plugin/build/ascendplugin.yaml + devmanager/dcmi/dcmi_v2.go</summary>

  ```diff
       spec:
  +      hostNetwork: true
  ...
  +// DcGetTopoInfoByDeviceIDAndNicName get the topology type between the device and the nic.
  +// The underlying driver interface is only supported on the A5 generation, callers should check the
  +// device type before calling it, e.g. via npu_nic.Query.
  +func (d *DcV2Manager) DcGetTopoInfoByDeviceIDAndNicName(deviceID int32, nicName string) (common.TopoType,
  ```
  </details>
- **device-plugin 故障升级拆成两种模式**。`FaultFrequency` 新增 `EscalationMode` 字段(json omitempty),有两种取值:
  - `combined`:旧行为,只在持续时长超时或恢复时才计一次频次;
  - `independent`:每次故障发生或恢复都计频次,持续时长超时只触发时长升级。
  
  字段留空时自动推导:配了持续时长就用 combined,否则用 independent。配置成 combined 却没有持续时长配置,或者填了非法值,都会回退并打限频 warn。另外 `LoadFaultCustomization` 改为先在旁边构建 duration 和 frequency 两张新 map,再按固定锁序一次性替换,保证并发处理故障时不会看到两张 map 不一致。
  <details><summary>代码依据 ascend-device-plugin/pkg/common/fault_code.go</summary>

  ```diff
  +	// ModeCombined counts frequency only on duration timeout/recovery (legacy behavior).
  +	ModeCombined = "combined"
  +	// ModeIndependent counts frequency on every fault occur/recover; duration
  +	// timeout only triggers duration upgrade.
  +	ModeIndependent = "independent"
  ...
  +	EscalationMode string `json:"EscalationMode,omitempty"`
  ...
  -	loadFaultFrequencyCustomization(faultCustomization.FaultFrequency)
  +	faultDurationMapLock.Lock()
  +	faultFrequencyMapLock.Lock()
  +	newDurationMap := buildFaultDurationCustomization(faultCustomization.FaultDuration, faultDurationMap)
  ```
  </details>
- **npu-exporter 支持 CRI-O**。新增 `containerModeCrio = "crio"` 分支,只走 CRI(`UseOciBackup=false`、`UseCriBackup=false`)。`getCrioContainerInfo` 优先调 CRI v1 `ContainerStatus{Verbose:true}`,从 `Info["info"]` 的 JSON 里解析 `runtimeSpec` 拿设备;只有返回 `Unimplemented` 时才降级到 v1alpha2。`-containerMode=crio` 和 `-containerd` 不能同时用,会报错并提示改用 `-endpoint`。
  <details><summary>代码依据 npu-exporter/cmd/npu-exporter/container_flags.go + collector/container/crio.go</summary>

  ```diff
  +	case containerModeCrio:
  +		opts.EndpointType = container.EndpointTypeCrio
  +		opts.CriEndpoint = container.DefaultCrioAddr
  +		opts.UseOciBackup = false
  +		opts.UseCriBackup = false
  ...
  +// CRI-O encodes verbose ContainerStatus data as JSON in Info["info"].
  +		resp, err := criv1.NewRuntimeServiceClient(operator.criConn).ContainerStatus(ctx,
  +			&criv1.ContainerStatusRequest{ContainerId: id, Verbose: true})
  +		if status.Code(err) != codes.Unimplemented {
  ```
  </details>
- **noded 的单一 `MonitorPeriod` 拆成三个独立参数**:`IpmiMonitorPeriod`(默认 60s,范围 [60, 600],等于原值)、`DpcMonitorPeriod` 和 `DtfsMonitorPeriod`(默认 5s,范围 [1, 300])。删掉了写死的 `common.CheckPeriod = 5s`;三个 monitor 的循环从 `default: time.Sleep` 忙等改成 `time.Timer` + `select`,收到停止信号时能立即退出,不用等 sleep 结束。
  <details><summary>代码依据 noded/pkg/monitoring/dpcmonitor/dpc_monitor.go</summary>

  ```diff
  +	period := time.Duration(common.ParamOption.DpcMonitorPeriod) * time.Second
  +	timer := time.NewTimer(period)
  ...
  -		default:
  -			time.Sleep(common.CheckPeriod)
  -			newDpcMap, err := getStatusFromFile()
  +		case <-timer.C:
  +			i.checkStatus()
  +			timer.Reset(period)
  ```
  </details>
- **volcano 重调度 `isFailedTask` 新增"从容器快照恢复"的失败判定**:容器没有 `LastTerminationState.Terminated`,但 `RestartCount > 0`,也视为任务失败。这种情况是快照恢复后容器重启,却没留下终止记录,之前会被漏判。
  <details><summary>代码依据 ascend-for-volcano/internal/rescheduling/job.go</summary>

  ```diff
  +		} else if status.LastTerminationState.Terminated == nil && status.RestartCount > 0 {
  +			// container restore from snapshot and task failed
  +			return true
  ```
  </details>
- **infer-operator 扩缩容改为基于实例索引和就绪状态**:
  - 推荐副本数的 `CurrentReplicas` 从 `workload.currentReplicas` 改成 `readyPods(workload.pods)`,和只统计就绪 Pod 的指标口径对齐,避免出现"幽灵基数"导致连续缩容。
  - 扩容时 `SelectIndicesToCreate` 先补索引空洞,再从最大索引往后追加;统计索引时把 terminating 对象也算进去,不会把它们当空洞重复创建。
  - 缩容时 `DeleteExtraWorkLoad` 的删除顺序是:负索引 → 未就绪 → 就绪,每组内按索引降序;没有索引标签或标签非法的实例保留不删。
  <details><summary>代码依据 infer-operator/pkg/controller/podautoscaler/controller.go + workload/deployment_handler.go</summary>

  ```diff
  -		PodAutoscaler: pa, Evaluation: state.evaluation, CurrentReplicas: workload.currentReplicas,
  +		PodAutoscaler: pa, Evaluation: state.evaluation, CurrentReplicas: readyPods(workload.pods),
  ...
  +// Instances with a negative index are deleted first, then unready instances, then ready
  +// instances, each group in descending index order, until the shrink count is reached.
  ```
  </details>
- **device-plugin 修 Pod 缓存的并发读写**:`getAllPodListCache` 等函数原来把 `pods` 切片的创建放在加锁之前,并且对注解 map 只做浅拷贝;现在挪到 `lock.Lock()` 之后,并引入 `maps` 包做深拷贝,修复注解 map 被并发读写的问题。(hunk 截断,只见到锁序调整和 `maps` 引入)
  <details><summary>代码依据 ascend-device-plugin/pkg/kubeclient/kube_cache.go</summary>

  ```diff
  +	"maps"
  ...
  -	pods := make([]v1.Pod, 0, len(podCache))
   	lock.Lock()
   	defer lock.Unlock()
  +	pods := make([]v1.Pod, 0, len(podCache))
  ```
  </details>

源链接(本节逐条对应):
- DRA DeviceClass 删除 https://gitcode.com/Ascend/mind-cluster/commit/69b72a0a34b352eba07d58b0d06e77ecf609e2dd
- DRA 参数校验 https://gitcode.com/Ascend/mind-cluster/commit/6b52d9a5a21ca0ba90b114d0bd019a4c0bf7335b
- 静默故障默认开 + DPU https://gitcode.com/Ascend/mind-cluster/commit/d16ed24c15c9c6f0dd3a13b960dbfc38a558d7d6
- RDMA 第 1 段 https://gitcode.com/Ascend/mind-cluster/commit/39ba89d9c697b4441ce1737e8b6431e94b024746
- RDMA 第 4 段 https://gitcode.com/Ascend/mind-cluster/commit/6b5d1d0d17983dd12b4e28c09b32b983084ed6a4
- RDMA 第 5 段 https://gitcode.com/Ascend/mind-cluster/commit/903f5d77bb6f13f10b3d19843adae21d40c8cb8c
- NPU 与网卡亲和 https://gitcode.com/Ascend/mind-cluster/commit/24f51e2428a70e7fd7226d68c02398b3a761a6d3
- 故障升级双模式 https://gitcode.com/Ascend/mind-cluster/commit/4fdfa9220fd8c65300d73720a56a27e9639ccc04
- npu-exporter CRI-O https://gitcode.com/Ascend/mind-cluster/commit/2502e19b0296a2cb7ea11d83381c20efa19eabbf
- noded 轮询周期 https://gitcode.com/Ascend/mind-cluster/commit/a542ec05d9447ef3e431c989da217d35a7c63ec2
- volcano 快照恢复判定 https://gitcode.com/Ascend/mind-cluster/commit/a27f64ec9a56d824f89f59ed73e0755d07a40a8a
- infer-operator 扩缩容 https://gitcode.com/Ascend/mind-cluster/commit/3b1cac9cc1bed3d0fb2e852f2cbab05068b5c751
- device-plugin 缓存竞争 https://gitcode.com/Ascend/mind-cluster/commit/c03cb950733e13bca6f8a0b3a97551a527c31a5d

### 后续发展方向 [AI]
- **DRA 主线押注 950 代,910(A2/A3)留在 device-plugin**。依据是 DeviceClass 删除 hunk,以及文档里代际收缩到只剩 950。结合上期 npu-dra-plugin(openFuyao)仍在修 full / hard vNPU 的 DRA 语义,昇腾的 DRA 现在有两条线:**mind-cluster 官方 DRA 只做 950**,openFuyao 的 npu-dra-plugin 覆盖面待确认。对我们的启示:如果底座要在 910B 上走 DRA,目前不能依赖 mind-cluster 官方驱动。证据只覆盖 YAML 和文档,驱动代码里是否删了 910 的 DeviceAttributes 分支,未逐文件核实。
- **网络 fabric 进入算力栈**:RDMA 注入、NPU 与网卡亲和、dpu-exporter 增加 RDMA 指标、静默故障纳入 DPU,四条线同期落地,方向是把 RoCE 网卡和 DPU 当作和 NPU 同级的调度、监控、故障对象(对标 NVIDIA 的 GPU + NIC 拓扑亲和 / network-operator)。代价是 device-plugin 要用 hostNetwork(安全基线变宽),而且 RDMA 只支持 legacy 注入、CDI 模式不支持;CDI 化和 RDMA 目前是两条没合起来的路径。证据边界:没看到 volcano 消费 NPU 与网卡映射的调度代码。
- **故障治理从"可选能力"转成"默认行为"**:上期 volcano 静默故障退避默认改 600s,本期 clusterd 静默故障检测默认开、device-plugin 故障升级双模式、FD 故障模式库大扩充。默认开启意味着升级后行为会变(更多卡被判定和扣留),我们做版本升级评估时要把这一项列为默认行为差异。
- **CRI-O 支持是 OpenShift 兼容的前置条件**:npu-exporter 加了 CRI-O 适配(device-plugin 和 docker-runtime 本期没看到同类改动)。对标 OAI 的底座需要关注的是 runtime 侧,CDI 模式能否替代 docker-runtime 的 OCI hook;本期证据只覆盖 exporter。

## ub-network-device-plugin: 021fe219 -> 37a1d669
- 比较: https://gitcode.com/openFuyao/ub-network-device-plugin/compare/021fe219256b1b5618b76c5a4c5f40aaa7ec1a16...37a1d669b4f5ad815110d509c541d321c0c4fab5 | tag: v26.9.0 | commits=2 | truncated=false
### AI 总结重点(源码 diff 为据)
- **对外行为不变,主要是测试和并发修复**。`plugin/health.go` 里内联在 `StartHealthServer` 的 `/healthz` 闭包被抽成 `healthzHandler` / `writeHealthz(w, files)` / `readyzHandler` / `newHealthMux`,依赖的 UB socket 列表(`/var/run/ubse/ubse.sock`、`ubse_ubm.socket`)提成包级变量 `healthSocketFiles`,便于测试注入。`plugin/server.go` 把 `p.stop` / `p.update` / `p.server` 先拷到局部变量再给 goroutine 使用,修复 Stop 时字段被置空引起的数据竞争;`ListAndWatch` 在通道为 nil 时返回 "device plugin is not initialized",不再阻塞在 nil 通道上。其余新增文件都是测试(覆盖率 93.6%)。
  <details><summary>代码依据 plugin/server.go</summary>

  ```diff
  +	stop := p.stop
  +	update := p.update
  +	if stop == nil || update == nil {
  +		return errors.New("device plugin is not initialized")
  +	}
   	for {
   		select {
  -		case <-p.stop:
  +		case <-stop:
  ```
  </details>
- 源: https://gitcode.com/openFuyao/ub-network-device-plugin/commit/2e9826681e16177c6a917656330bc7ab278b1515
### 后续发展方向 [AI]
- 只是工程质量收口(测试和数据竞争),没有新能力信号;UB fabric 的 device plugin 仍停在健康检查和 urma 设备上报这一层。

## 本期无实质改动(折叠)
- npu-operator:无新提交(ddcf0eb7)
- npu-container-toolkit:无新提交(c720a3b8)
- npu-driver-installer:无新提交(bd1b2a9e)
- vNPU:无新提交(529e48a6)
- npu-node-provision:无新提交(717ef777)
- npu-dra-plugin:无新提交(f0654355)
- volcano-ext:无新提交(0f265f98)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=6fc1d5e1f35e18e683529eaf8efb35b99e3a5af4 tag=v26.2.1 scanned=2026-11-18 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.9.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-18 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=37a1d669b4f5ad815110d509c541d321c0c4fab5 tag=v26.9.0 scanned=2026-11-18 -->
