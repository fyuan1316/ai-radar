# NVIDIA 算力栈 diff 雷达 2026-07-18

## 摘要
- **DRA driver 迎来三件大事**:①新增 `pkg/fabricmanager` 包,为 VFIO GPU 直通接入 NVIDIA Fabric Manager,能按 NVSwitch/NVLink5 fabric 分区(partition1/2/4/8)发布设备属性并在 DRA 分配时激活分区——GB200/NVL 机柜级整机直通的关键拼图;②新增 `pkg/imex` 支持 **host-managed IMEX 模式**,让集群管理员自己托管 nvidia-imex 守护进程,driver 不再为每个 ComputeDomain 建 DaemonSet;③把 GPU 的 NUMA 属性从厂商私有 `numa` 改名对齐 KEP-6072 标准 `resource.kubernetes.io/numaNode`(**破坏性改名**)。
- mig-parted v0.14.4:把 systemd 钩子里启动 driver/k8s 服务一律改成 `--no-block`,彻底消除与 `nvidia-gpu-reset.target` 的启动死锁。
- KAI-Scheduler 仅一条测试提交(reclaim 基准跑全调度周期),无生产代码变更。

## 当日重要改变
- dra-driver-nvidia-gpu [新能力] 新增 `pkg/fabricmanager` 整包(client/manager/fabric),受 `FabricManagerPartitioning` feature gate 控制,为 VFIO 直通设备按 fabric 分区发布 `partition1/2/4/8` 属性 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/64a8903b5729bb0468201a2a99039a055bc248ab...e254b82a98621f81483554746cab1983860a6490
- dra-driver-nvidia-gpu [新能力] 新增 `pkg/imex` + `HostManagedIMEXDaemon` feature gate,支持 `imex.mode=hostManaged`;此模式下 ComputeDomain 不再创建 DaemonSet/node label,仅注入 IMEX channel 设备 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/64a8903b5729bb0468201a2a99039a055bc248ab...e254b82a98621f81483554746cab1983860a6490
- dra-driver-nvidia-gpu [弃用/移除] 删除 GPU 设备上的私有 `numa` 整型属性,改为 KEP-6072 标准 `resource.kubernetes.io/numaNode`;selector 依赖旧属性名的会失效 https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/64a8903b5729bb0468201a2a99039a055bc248ab...e254b82a98621f81483554746cab1983860a6490

## kubernetes-sigs/dra-driver-nvidia-gpu: 64a8903b -> e254b82a
- 比较 / 最新 Release:ahead=15 / files=69 / Release v0.4.1 — https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/64a8903b5729bb0468201a2a99039a055bc248ab...e254b82a98621f81483554746cab1983860a6490

### AI 总结重点(源码 diff 为据)
- **Fabric Manager 分区能力落地(整包新增)**:新增 `pkg/fabricmanager`,定义了对 `libnvidia-fabricmanager.so` 的 Go 投影 `Client` 接口(`Init` / `GetSupportedFabricPartitions` / `ActivateFabricPartition` / `DeactivateFabricPartition`),`Partition` 结构携带每个分区的 GPU 成员(PhysicalID/UUID/NvLink 速率)。`DeviceState` 里新增 `fmManager` 字段与 `newFabricManager()`,仅当 `FabricManagerPartitioning` gate 开启、非 mock NVML、且检测到 NVSwitch/NVLink5 fabric 时才打开 FM 连接;检测逻辑靠读 `/proc/driver/nvidia-nvswitch/devices` 与 IB VPD 里的 `SW_MNG` 标记。
  <details><summary>代码依据 pkg/fabricmanager/client.go / cmd/gpu-kubelet-plugin/device_state.go</summary>

  ```diff
  +// Client is a Go projection of the NVIDIA Fabric Manager C SDK
  +type Client interface {
  +	Init() error
  +	GetSupportedFabricPartitions() ([]Partition, error)
  +	ActivateFabricPartition(partitionID int) error
  +	DeactivateFabricPartition(partitionID int) error
  +}
  +
  +func newFabricManager(nvdevlib *deviceLib, containerDriverRoot root) (*fabricmanager.Manager, error) {
  +	if !featuregates.Enabled(featuregates.FabricManagerPartitioning) {
  +		return nil, nil
  +	}
  +	hasFabric, err := fabricmanager.HasFabricManagerFabric(nvdevlib.hostRoot)
  +	...
  +	return fabricmanager.OpenFabricManager(libPath)
  +}
  ```
  </details>
- **VFIO 直通设备发布 fabric 分区属性**:`VfioDeviceInfo.GetDevice()` 在 `FabricManagerPartitioning` 开启时调用 `addFabricManagerAttributes()`,把该 GPU 所属的各尺寸分区(partition1/2/4/8)的 partitionId 作为设备属性发布——调度器/用户可据此把整机柜 GPU 按 fabric 分区申领做直通。`GpuInfo` 新增 `gpuModuleID` 与 `partitionsBySize map[int]int` 承载该信息。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/deviceinfo.go</summary>

  ```diff
  +	// partitionsBySize maps an FM partition size (number of GPUs) to the
  +	// partitionId of the partition of that size that includes this GPU.
  +	partitionsBySize map[int]int
  ...
  +	if featuregates.Enabled(featuregates.FabricManagerPartitioning) {
  +		d.addFabricManagerAttributes(device.Attributes)
  +	}
  ```
  </details>
- **host-managed IMEX 模式(新增 `pkg/imex`)**:定义 `Mode`(`driverManaged` 默认 / `hostManaged`)与 `Isolation`(`domain` 默认 / `channel` 未实现)。选 `hostManaged` 需开 `HostManagedIMEXDaemon` gate;此模式下 `ComputeDomainManager` 直接**不构造** `daemonSetManager` 与 `nodeManager`(而非构造后闲置),意即 driver 不再为每个 ComputeDomain 建 IMEX DaemonSet、不再打 node label,只负责通告/注入 IMEX channel 设备;并新增基于 unix socket 的 host IMEX 守护进程就绪探测。
  <details><summary>代码依据 pkg/imex/imex.go / cmd/compute-domain-controller/computedomain.go</summary>

  ```diff
  +	ModeDriverManaged Mode = "driverManaged"  // 默认:driver 建每-ComputeDomain 的 imex DaemonSet
  +	ModeHostManaged   Mode = "hostManaged"    // admin 自管 host imex,需 HostManagedIMEXDaemon gate
  ...
  -	m.daemonSetManager = NewMultiNamespaceDaemonSetManager(config, m.Get, m.List, m.UpdateStatus)
  +	if !config.imexConfig.EffectiveHostManaged() {
  +		m.daemonSetManager = NewMultiNamespaceDaemonSetManager(config, m.Get, m.List, m.UpdateStatus)
  +		m.nodeManager = NewNodeManager(config, m.Get)
  +	}
  ```
  </details>
- **NUMA 属性对齐 KEP-6072(破坏性改名)**:删除 VFIO 设备上的私有 `numa`(IntValue)属性,统一改用标准 QualifiedName `resource.kubernetes.io/numaNode`,由新的 `addNumaNodeAttribute()` 统一发布,并在 NVML 拿不到时**回退读 PCI sysfs**(`/sys/.../numa_node`)发现 NUMA。任何按旧 `numa` 属性写 selector 的 ResourceClaim 会失配。
  <details><summary>代码依据 cmd/gpu-kubelet-plugin/deviceinfo.go</summary>

  ```diff
  +const standardNumaNodeAttribute resourceapi.QualifiedName = "resource.kubernetes.io/numaNode"
  ...
  -			"numa": {
  -				IntValue: ptr.To(int64(d.numaNode)),
  -			},
  ...
  +	addNumaNodeAttribute(device.Attributes, &d.numaNode)
  ```
  </details>

### 后续发展方向 [AI]
- FM 分区 + VFIO 直通两条线合流,指向**整机柜(NVL72/GB200)级 NVSwitch fabric 感知的 DRA 直通**:未来 GPU 不再是单卡颗粒,而是按 fabric partition 成组申领。证据只覆盖属性发布与 FM client 骨架(Activate/Deactivate 接口已定义),未见调度器侧如何消费 partition 属性做成组分配的逻辑。
- host-managed IMEX 是把 IMEX 生命周期"交还给平台"的解耦信号,利于与既有 fabric 运维体系集成;证据覆盖 controller 侧的分支裁剪与就绪探测,未见 kubelet-plugin 侧 channel 注入的完整路径。
- NUMA 标准化对齐上游 KEP-6072,是 DRA 设备属性从"厂商私有"向"K8s 标准命名"收敛的又一步——对我们产品的启示:若已在用 `numa` 私有属性写拓扑对齐策略,需跟进改 `resource.kubernetes.io/numaNode`,否则升级后拓扑对齐静默失效。

## NVIDIA/mig-parted: 90668a23 -> 567b9373
- 比较 / 最新 Release:ahead=4 / files=5 / Release v0.14.4 — https://github.com/NVIDIA/mig-parted/compare/90668a237485113fdb77cadd825957ffbf3a3c1c...567b93739cda8a9d2bad51286171daab25d107f5

### AI 总结重点(源码 diff 为据)
- **systemd 钩子启动服务一律 `--no-block`**:上一版 `start_driver_services()` 靠 `systemctl is-system-running` 判断,仅在系统未 `running/degraded` 时才加 `--no-block`;新版**无条件**传 `--no-block` 并删掉状态探测。原因是这些服务 `After=nvidia-gpu-reset.target` 而本钩子 `Before=` 该 target,同步启动会与 target 互等造成死锁——不只发生在开机,装包/首次启动都会。同时 `start_k8s_services()` 也从阻塞启动改成 `--no-block`,防止 k8s 服务链间接排在该 target 之后。
  <details><summary>代码依据 deployments/systemd/hooks.sh</summary>

  ```diff
  -	local start_args=""
  -	state="$(systemctl is-system-running 2>/dev/null)"
  -	if [ "${state}" != "running" ] && [ "${state}" != "degraded" ]; then
  -		start_args="--no-block"
  -	fi
  -	nvidia-mig-manager::service::start_systemd_services driver_services "${start_args}"
  +	nvidia-mig-manager::service::start_systemd_services driver_services "--no-block"
  ...
  -	nvidia-mig-manager::service::start_systemd_services k8s_services
  +	nvidia-mig-manager::service::start_systemd_services k8s_services "--no-block"
  ```
  </details>

### 后续发展方向 [AI]
- 纯运维健壮性修复(死锁规避),无功能/API 变化。代价是运行时 reconfigure 不再同步等待服务起来报错——失败改由被启动单元自身上报。证据仅覆盖 hooks.sh,未见对 MIG 切分配置面的改动。

## KAI-Scheduler: 900fe5fe -> 64f3e37d
- 比较 / 最新 Release:ahead=1 / files=2 / Release v0.16.4 — https://github.com/kai-scheduler/KAI-Scheduler/compare/900fe5fef9f6d99797a8e868a1119841dcba6e27...64f3e37d336f0751e31ffe39fc6c4076beb7b60e

### AI 总结重点(源码 diff 为据)
- **仅测试代码**:把 reclaim 基准从只跑 `reclaim.New().Execute()` 改成跑**完整调度周期** `allocate→consolidation→reclaim→preempt→stalegangeviction`,以基准量化 fit-error 在整周期中的保留开销;新增 `TestManySingleGPUJobsSchedulingCycleActions` 断言周期动作顺序。无生产代码变更。
  <details><summary>代码依据 pkg/scheduler/actions/integration_tests/reclaim/reclaim_many_single_gpu_topology_test.go</summary>

  ```diff
  +	expected := []string{"allocate", "consolidation", "reclaim", "preempt", "stalegangeviction"}
  +	if !reflect.DeepEqual(actionNames, expected) {
  +		t.Fatalf("scheduling cycle actions = %v, want %v", actionNames, expected)
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 无方向信号,仅基准/测试维护。可留意其调度周期固定动作序列 `allocate→consolidation→reclaim→preempt→stalegangeviction`(此序列由测试断言固化),反映 KAI 的抢占/回收编排。

## 本期无实质改动(折叠)
- NVIDIA/gpu-operator(ahead=6,仅 bump/CI/merge;Release v26.3.3)
- NVIDIA/nvidia-container-toolkit(无新提交;Release v1.20.0-rc.1)
- NVIDIA/gpu-driver-container(无新提交)
- NVIDIA/k8s-device-plugin(无新提交;Release v0.19.3)
- NVIDIA/dcgm-exporter(无新提交;Release 4.6.0-4.8.3)
- NVIDIA/DCGM(无新提交)

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=c9a0f60c164b2d3197eb31428010b335818c1589 branch=main release=v26.3.3 scanned=2026-07-18 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3db41dec03bf1179b4f7259f6a7037f7f158d39b branch=main release=v1.20.0-rc.1 scanned=2026-07-18 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=b7d88d64c402759134ad0ed7475ec9bc4fb4fe60 branch=main release=— scanned=2026-07-18 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=248164727d5d8bac7024a8e12a13e69246cf0969 branch=main release=v0.19.3 scanned=2026-07-18 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=e254b82a98621f81483554746cab1983860a6490 branch=main release=v0.4.1 scanned=2026-07-18 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-07-18 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-18 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=567b93739cda8a9d2bad51286171daab25d107f5 branch=main release=v0.14.4 scanned=2026-07-18 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=64f3e37d336f0751e31ffe39fc6c4076beb7b60e branch=main release=v0.16.4 scanned=2026-07-18 -->
