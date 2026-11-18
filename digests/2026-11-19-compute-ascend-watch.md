# 昇腾算力栈 diff 雷达 2026-11-19

> 正常日增量:mind-cluster 30 个 commit(15 个实质),truncated=false,深度模式。PATHPREFIX 在 task 默认清单外补了 `component/ascend-dynamic-resource-allocation component/ascend-common`(见历史反馈);另对区间做了一次无 prefix 的全量 compare,补读了 PATHPREFIX 外的 `k8s-rdma-shared-dev-plugin` / `ub-host-device-cni` 两处 hunk(下文已标注)。openFuyao 8 仓全部无新提交。

## 摘要
- **mind-cluster [新能力] 软切分(soft share)接入节点侧 enpu-manager**:ascend-common 新增 `enpumanager` 包，是 Unix socket `/run/enpu/enpu-manager.sock` 上的 HTTP 客户端，接口包括 `POST /api/v1/allocate`、`GET/DELETE /api/v1/allocations`、`/metrics`。device-plugin 在节点存在该 socket 时改由 manager 创建软切分分配（AI Core 配额 1~100%、HBM 配额、调度策略），每 30s 回收孤儿分配。npu-exporter 新增 `enpu` 指标组（默认 OFF），暴露 vNPU 级的利用率、HBM 用量和配额，共 16 个指标族。昇腾软切分从此有了独立的管理守护进程和 vNPU 级可观测。
- **mind-cluster [默认行为变化 + 配置键改名] volcano 亲和性降级退避改为全局默认开启**:原来作业必须打 `huawei.com/scheduler.downgrade: "true"` 才启用，现在删掉了这个开关注解。改为全局窗口，默认 120s，对所有实现了降级 hook 的策略生效，本期新增 A5 的 chip8node8sp / chip8node8ra64sp 和多级调度 multilevelscheduling。作业级注解改为 `huawei.com/scheduler.downgrade.timeout`(-1 关闭,[1,86400] 秒,越界取边界值)。全局配置键也从 `scheduler-downgrade-timeout` 改成同名的 `huawei.com/scheduler.downgrade.timeout`。原来"降级与 Pod 级重调度、进程级恢复互斥"的校验也删掉了。
- **mind-cluster [链路闭环] RDMA 设备改由 ascend-docker-runtime 注入**(PATHPREFIX 外补读):rdma-shared-dev-plugin 检测到 `ASCEND_DOCKER_RUNTIME=True` 时，不再直接返回 DeviceSpec，而是把 HCA 名写进 `ASCEND_RDMA_DEVICES` 环境变量，由上期新增的 runtime RDMA 注入链路负责挂载。同时删除 462 行"按 NPU 关联分配 DPU"的逻辑(`allocateByNpu`、`GetPreferredAllocation`)。另有 FD 掉卡故障模式库 Part4~10(kg-config.json 改动 5786 行，未逐条读),仅属知识库扩充。

## 当日重要改变
- mind-cluster [新能力] 新增 `component/ascend-common/enpumanager/`(client.go)、`ascend-device-plugin/pkg/enpuconfig/`、`npu-exporter/collector/prometheushttp/`。device-plugin 的软切分分配交给节点上的 enpu-manager,exporter 侧新增 vNPU 利用率指标。commit `25b77b0f54ca` https://gitcode.com/Ascend/mind-cluster/commit/25b77b0f54ca4b160a2d4b1271de566fb3c88b68 / `dea383756611` https://gitcode.com/Ascend/mind-cluster/commit/dea383756611b0cacb4cae0f402bfc6d3bac8059 / `cde7c47d77fb` https://gitcode.com/Ascend/mind-cluster/commit/cde7c47d77fb1cda72ac24140113605ac7d12b71
- mind-cluster [弃用/移除][默认行为变化] 删除作业注解 `huawei.com/scheduler.downgrade`(及 `isSchedulerDowngradeEnabled`、`validDowngradeCompatibility`),全局配置键 `scheduler-downgrade-timeout` 改名为 `huawei.com/scheduler.downgrade.timeout`,降级退避由按作业 opt-in 改为全局默认开启(120s)。commit `d590d43fab18` https://gitcode.com/Ascend/mind-cluster/commit/d590d43fab18438bb9ad5b190d563cd306b1b809
- mind-cluster [弃用/移除] k8s-rdma-shared-dev-plugin 删除 `ub_device/npu_allocate.go`(按 NPU 关联分配 DPU、写 device-status 注解),UB excl 模式下 `GetPreferredAllocationAvailable` 不再开启;配合 ascend-docker-runtime 时改用 `ASCEND_RDMA_DEVICES` 环境变量注入。commit `5381f5f421b6` https://gitcode.com/Ascend/mind-cluster/commit/5381f5f421b615d02e498a87dd6ea757b3d8872c
- mind-cluster [版本] 最新 tag 仍为 v26.2.1,无跨档。

## mind-cluster: 6fc1d5e1 -> 171c2fda
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/6fc1d5e1f35e18e683529eaf8efb35b99e3a5af4...171c2fda6b763f88cccd683520139b318bbdd9d0 | tag: v26.2.1 | commits=30 | truncated=false

### AI 总结重点(源码 diff 为据)
- **软切分分配从 device-plugin 本地生成配置，改为交给 enpu-manager 守护进程**。`enpumanager.Client` 通过 Unix socket 访问 `http://localhost/api/v1/...`:请求体上限 4095 字节，响应上限 1 MiB,metrics 上限 8 MiB;`allocation_id` 必须匹配 UUID 正则。`AllocateRequest` 包含 `aicore_quota` / `hbm_quota` / `sched_policy` / `phy_id` / `pod_uid` / `container_name` 六个字段。
  <details><summary>代码依据 component/ascend-common/enpumanager/client.go</summary>

  ```diff
  +	// SocketPath is the default node-local manager socket.
  +	SocketPath = "/run/enpu/enpu-manager.sock"
  +	// maxRequestBytes bounds the complete serialized resource request.
  +	maxRequestBytes = 4095
  ...
  +	AICoreQuota   int    `json:"aicore_quota"`
  +	HBMQuota      int    `json:"hbm_quota"`
  +	SchedPolicy   int    `json:"sched_policy"`
  +	PhysicalID    int    `json:"phy_id"`
  +	PodUID        string `json:"pod_uid"`
  +	ContainerName string `json:"container_name,omitempty"`
  ...
  +	if err := c.request(ctx, http.MethodPost, "/api/v1/allocate", payload, &response); err != nil {
  ...
  +	if err := c.request(ctx, http.MethodDelete, "/api/v1/allocations/"+allocationID, nil, &response); err != nil {
  ```
  </details>
- **device-plugin 的模式选择和准入校验**。在 `doWithVolcanoSchedule` 里，只有同时满足"节点支持软切分"(`IsSupportSoftShareDevice`)和"作业是软切分作业"(`IsSoftShareDevJob`)时才探测 manager socket。一旦观测到 socket,就粘滞进入 manager 模式(`seen` atomic):manager 重启期间也不会回退，安装或卸载 manager 都要重启 device-plugin。`GetConfigDir` 的校验规则如下:
  - AI Core 配额必须在 [1,100];
  - 策略为 1(fixed share)时 HBM 配额必须 >0;
  - Pod 内只允许一个容器申请该 NPU 资源;
  - 返回的 `config_path` 必须落在白名单 `/etc/enpu/vcann-rt/allocations` 下(`CleanConfigPath` 防路径穿越);
  - `shm_id` 必须等于设备 die ID。
  
  已有分配会按 Pod UID 复用，但配额或卡号不一致时直接报错。
  <details><summary>代码依据 ascend-device-plugin/pkg/server/plugin.go + soft_share_config.go + enpuconfig/allocation.go</summary>

  ```diff
  -	npuInfoConfigDir := ps.getNPUInfoConfigDirFromPod(oldestPod, allocateDevices)
  -	if npuInfoConfigDir != "" {
  +	managerEnabled := false
  +	if common.IsSupportSoftShareDevice() && common.IsSoftShareDevJob(oldestPod) {
  +		managerEnabled, err = ps.softShareManager.requireManager()
  ...
  +	if managerEnabled {
  +		npuInfoConfigDir, err = ps.getManagerNPUInfoConfigDir(oldestPod, allocateDevices)
  ...
  +	if err != nil || coreQuota < minSoftShareCoreQuota || coreQuota > maxSoftShareCoreQuota {
  +		return "", fmt.Errorf("invalid soft share AI Core quota")
  ...
  +	if hbmQuota < 0 || (policy == fixedSharePolicy && hbmQuota == 0) {
  ...
  +const ConfigRoot = "/etc/enpu/vcann-rt/allocations"
  ...
  +	if existing.PhysicalID != input.PhysicalID || existing.AICoreQuota != input.AICoreQuota ||
  +		existing.HBMQuota != input.HBMQuota || existing.HBMLimit != input.HBMQuota ||
  +		existing.SchedPolicy != input.SchedPolicy {
  +		return nil, fmt.Errorf("existing enpu-manager allocation does not match Pod %s request", input.PodUID)
  ```
  </details>
- **孤儿分配回收**。`HwDevManager.Serve` 在支持软切分的节点上启动 `reconcilePeriodically`,每 30s 一次(`managerReconcileInterval`):对比 manager 的分配列表和 informer 里活跃 Pod 的 UID,release 掉已不存在的 Pod 的分配。Pod 缓存未同步时拒绝回收，避免误删。每次新建分配前还会尽力做一轮回收。manager 连接失败会经 `managerOperationError` 让进程以退出码 1 退出、由 kubelet 拉起。
  <details><summary>代码依据 ascend-device-plugin/pkg/server/enpu_reconcile.go + manager.go</summary>

  ```diff
  +const managerReconcileInterval = 30 * time.Second
  ...
  +	if kubeClient == nil || kubeClient.PodInformer == nil || !kubeClient.PodInformer.HasSynced() {
  +		return fmt.Errorf("Pod cache is not synchronized")
  +	}
  ...
  +		if err := m.client.Release(ctx, allocation.AllocationID); err != nil {
  ...
  +	if common.IsSupportSoftShareDevice() && hdm.softShareManager != nil {
  +			go hdm.softShareManager.reconcilePeriodically(workerCtx, kubeClient)
  ```
  </details>
- **npu-exporter 新增 `enpu` 指标组，默认 OFF,采集间隔 60s**。实现是一个通用的 `prometheushttp.Collector`:从 manager 的 `/metrics` 拉 Prometheus 文本，按固定的 16 族契约逐样本校验(百分比 0~100、非负、0/1)后发布，同时输出到 Prometheus 和 Telegraf。指标分两层:
  - 物理卡层:`enpu_npu_{utilization,aicore,aicpu,ctrlcpu,cube,vector}_utilization_percent`(label `phy_id`);
  - vNPU 层:`enpu_allocation_info`、`enpu_vnpu_utilization_percent`、`enpu_vnpu_aicore_utilization_percent`、`enpu_vnpu_aicore_quota_percent`、`enpu_vnpu_core_limit_enabled`、`enpu_vnpu_hbm_{request,limit,used}_bytes`,label 为 `allocation_id/phy_id/vnpu_id/pod_uid/container_name`;
  - 另有两层各自的 `*_metric_valid`。
  
  注意 Help 文案写的是 vNPU 利用率为 **"Estimated"**(估算值)。
  <details><summary>代码依据 npu-exporter/plugins/collector_for_enpu.go + build/pluginConfiguration.json</summary>

  ```diff
  +  {"metricsGroup": "enpu", "state": "OFF", "intervalSeconds": 60},
  ...
  +	physicalUtil := []string{"utilization_percent", "aicore_utilization_percent", "aicpu_utilization_percent",
  +		"ctrlcpu_utilization_percent", "cube_utilization_percent", "vector_utilization_percent"}
  ...
  +	allocation := []string{"allocation_id", "phy_id", "vnpu_id", "pod_uid", "container_name"}
  ...
  +		prometheushttp.GaugeSpec{Name: "enpu_vnpu_utilization_percent", Help: "Estimated vNPU utilization percentage.",
  ...
  +		prometheushttp.GaugeSpec{Name: "enpu_vnpu_hbm_used_bytes", Help: "Source container HBM usage on the configured device in bytes.",
  ```
  </details>
- **volcano 降级退避从按作业 opt-in 变为全局默认开启，配置键同时改名**。原来的布尔注解 `huawei.com/scheduler.downgrade` 被删除，改为 `SchedulerJob.downgradeWindow(global)`:作业注解 `huawei.com/scheduler.downgrade.timeout` 优先;没有注解时用全局值，全局缺省为 `DefaultSchedulerDowngradeTimeout = 120`。只有 -1 表示关闭，越界取边界值，无法解析时回落到 120。按 hunk 推断：升级后，**没有任何配置的作业**在 120s 内调度不上就会开始逐级放宽亲和约束;旧注解 `scheduler.downgrade: "true"` 和旧全局键 `scheduler-downgrade-timeout` 都会被静默忽略，旧全局键配的值失效、回落为 120。三个 volcano 部署 YAML 已同步改键。
  <details><summary>代码依据 ascend-for-volcano/common/util/constants.go + plugin/job.go + plugin/factory.go + build/volcano-v1.12.0.yaml</summary>

  ```diff
  -	SchedulerDowngradeAnnoKey = "huawei.com/scheduler.downgrade"
  +	// annotation in seconds: -1 disables the downgrade, [1, 86400] is the
  +	SchedulerDowngradeTimeoutAnnoKey = "huawei.com/scheduler.downgrade.timeout"
  ...
  -func (sJob SchedulerJob) isSchedulerDowngradeEnabled() bool {
  -	return sJob.Annotation[util.SchedulerDowngradeAnnoKey] == "true"
  -}
  +func (sJob SchedulerJob) downgradeWindow(globalWindow int) int {
  +	raw, ok := sJob.Annotation[util.SchedulerDowngradeTimeoutAnnoKey]
  +	if !ok {
  +		return globalWindow
  +	}
  ...
  -	timeoutStr, ok := conf[schedulerDowngradeTimeoutKey]
  +	timeoutStr, ok := conf[util.SchedulerDowngradeTimeoutAnnoKey]
  ...
  -    "forceEnqueue": "true", "prefer-previous-node": "true", "scheduler-downgrade-timeout": "120"}
  +    "forceEnqueue": "true", "prefer-previous-node": "true", "huawei.com/scheduler.downgrade.timeout": "120"}
  ```
  </details>
- **降级与 Pod 级重调度不再互斥，改用驱逐守卫区分重调度级别**。删除 `validDowngradeCompatibility`,即不再拒绝"降级 + `SinglePodTag` / `ProcessRecoverEnable`"的组合。新增 `roundTaskCount.evicting`(统计正在终止、且已经放置过的 task),以及 `downgrade.MarkPodEviction` / `ClearPodEviction` / `PodEvictionProtected`。规则是:
  - 部分 task 被驱逐，视为 Pod 级重调度，保留已经放宽的约束;
  - 整体被驱逐，视为 Job 级重调度，重置约束并重新计时;
  - `StampSession` 额外为每个作业记录本 session 的有效窗口。
  <details><summary>代码依据 ascend-for-volcano/plugin/factory.go + common/downgrade/downgrade.go</summary>

  ```diff
  -	downgrade  bool
  +	downgradeWindow int
  ...
  +		allWaiting := count.pending == count.scoped && count.evicting == 0
  ...
  -		if downgrade.IsEffective(jobID) && round.allWaiting {
  +		reconcileEvictionGuard(jobID, round)
  +		if downgrade.IsEffective(jobID) && round.allWaiting && !downgrade.PodEvictionProtected(jobID) {
  ...
  -	if sJob.Label[util.SinglePodTag] == util.EnableFunc {
  -		return &api.ValidateResult{Pass: false, Reason: util.InvalidArgumentReason,
  -			Message: "job enables scheduler downgrade and pod rescheduling at the same time, " +
  ```
  </details>
- **A5 与多级调度的降级规则**。各策略的规则不同:
  - `chip8node8ra64sp`(800I A5 机架超节点):先把 ra-block 每个窗口减半，直到 1 节点;再把 sp-block 减半，全程保持 `spBlock % raBlock == 0`。
  - `multilevelscheduling`:从最细的 level1 开始，每个窗口把一级的 reqNode 减半;一旦破坏层级整除关系，该级直接降为 1。
  
  A3 superpod 新增 `superPodsLayoutMatchesSpBlock` 检查：缓存的逻辑超节点布局与当前有效 sp-block 不一致时，Pod 级重调度报错等待，Job 级重调度清缓存重建。同时把 `selectNodeFromOriginVSuperPod` 原来吞掉的 error 改为向上返回(`return selectNodes, nil` → `err`)。
  <details><summary>代码依据 chip8node8ra64sp/downgrade.go + multilevelscheduling/downgrade.go + ascend910a3/superpod/frame.go</summary>

  ```diff
  +	if windows <= raSteps {
  +		raBlockNodeNum >>= uint(windows)
  +	} else {
  +		raBlockNodeNum = nodeNum1
  +		spBlockNodeNum = tp.halvedSpBlockNodeNum(windows - raSteps)
  +	}
  ...
  +		for blocks[key] > 1 && windows > 0 {
  +			blocks[key] >>= 1
  +			if !mh.divisibleBlocks(blocks) {
  +				blocks[key] = 1
  +			}
  ...
  	notReadySuperPod, err := tp.selectNodeFromOriginVSuperPod(fJob, sMap, selectNodes, totalNodes, vSuperPodID)
  	if err != nil {
  -		return selectNodes, nil
  +		return selectNodes, err
  	}
  +	if !tp.superPodsLayoutMatchesSpBlock(fJob) {
  +		return tp.handleLayoutMismatch(fJob)
  +	}
  ```
  </details>
- **(PATHPREFIX 外补读)rdma-shared-dev-plugin:RDMA 设备挂载交给 ascend-docker-runtime,同时删掉按 NPU 分配 DPU 的逻辑**。`main` 读取环境变量 `ASCEND_DOCKER_RUNTIME=="True"`,结果记入 `common.UseAscendDocker`。在 UB excl 模式的 `allocateExclContainer` 里:
  - 该开关为 false 时，按原方式返回 `resp.Devices`;
  - 为 true 时，只把 HCA 名（如 `hrn5_0`)逗号拼接写入 `resp.Envs[ASCEND_RDMA_DEVICES]`。
  
  这正好对接上期 ascend-docker-runtime 新增的 RDMA 注入。整个 `npu_allocate.go` 被删除(kubelet `/pods` 查询、`pendingNpuPods` 按 predicate-time 排序、`markPodAllocated` 写 DPU 注解);`GetPreferredAllocationAvailable` 关闭;`Allocate` 由写锁降为读锁;k8sClient 不再传给 UB server。
  <details><summary>代码依据 k8s-rdma-shared-dev-plugin/pkg/resources/ub_device/server.go + cmd/k8s-rdma-shared-dp/main.go</summary>

  ```diff
  +	common.UseAscendDocker = os.Getenv(api.AscendDockerRuntimeEnv) == "True"
  ...
  -		PreStartRequired:                false,
  -		GetPreferredAllocationAvailable: rs.exclMode,
  +		PreStartRequired: false,
  ...
  -		if err := rs.allocateByNpu(ctx, allRequestedDeviceIDs(reqs)); err != nil {
  -			return nil, err
  -		}
  ...
  +	if !rs.useAscendDocker {
  +		hwlog.RunLog.Info("device-plugin will use origin mount way")
  +		resp.Devices = append(resp.Devices, deviceSpecs...)
  +		return
  +	}
  +	setAscendRdmaDevicesEnv(resp, hcaNames)
  ...
  +	resp.Envs[api.AscendRdmaDevicesEnv] = strings.Join(hcaNames, ",")
  ```
  </details>
- **(PATHPREFIX 外补读)ub-host-device-cni:网卡移入容器后改名为 runtime 指定的名字**。之前沿用宿主机网卡名，现在 `moveLinkIn` 改用 `args.IfName`。重放路由时跳过内核自动派生的路由(`RTPROT_KERNEL`,以及目标为链路本地地址的路由),避免重复添加报错;删除 `nad-cni-inherit-config.yaml`。
  <details><summary>代码依据 component/ub-host-device-cni/cmd/main.go</summary>

  ```diff
  -	contDev, err := moveLinkIn(hostDev, containerNs, hostDev.Attrs().Name)
  +	contDev, err := moveLinkIn(hostDev, containerNs, args.IfName)
  ...
  +func isKernelDerivedRoute(r netlink.Route) bool {
  +	if r.Protocol == unix.RTPROT_KERNEL {
  +		return true
  +	}
  ```
  </details>
- FD 掉卡故障模式库 Part4~10:改动集中在 `ascend-faultdiag/.../kg-config.json`(5786 行)和 `bmc_parser.py`,属于知识库条目扩充，未逐条读 hunk,不下符号级结论。

### 后续发展方向 [AI]
- **昇腾软切分走向"节点守护进程 + 标准接口"的形态**。依据是 enpu-manager 的 socket HTTP API、按 Pod UID 幂等复用分配、孤儿回收、vNPU 级 metrics 四段 hunk。形态和 HAMi 的 hook 软隔离类似，但它是厂商原生实现，配置下发到 `/etc/enpu/vcann-rt/allocations`(vcann-rt 运行时)。对我们的启示：如果底座同时支持 HAMi vNPU 和昇腾原生软切分，两者的配额语义（AI Core %、HBM)和指标名需要统一映射;`enpu_vnpu_*` 指标标明是估算值，不宜直接用于计费。证据边界:enpu-manager 本体不在本仓，未见其隔离实现;`IsSoftShareDevJob` 的注解键在本期 hunk 之外，未核实。
- **调度从"严格亲和、失败排队"转向"默认可退化的亲和"**。降级退避默认开启、覆盖 A5 和多级拓扑，并兼容 Pod 级重调度。方向是牺牲一部分拓扑最优，换取排队时延。升级时这是**默认行为差异 + 配置键不兼容**:旧注解和旧全局键会被静默忽略，需要列进升级检查清单。对我们的启示：自家调度器的拓扑亲和可参考"窗口逐级减半 + 可观测时间戳注解(`scheduler.downgrade.timestamp`)"的设计。
- **网络 fabric 设备挂载收敛到 ascend-docker-runtime**。上期 runtime 新增 RDMA 注入，本期 rdma-shared-dev-plugin 改为只写环境变量并删除 NPU 关联分配，挂载入口统一到 runtime(仍是 legacy 注入路径),device-plugin 退化为只做资源计数。代价是"DPU 按 NPU 就近分配"的能力消失或另作他处实现，本期 diff 里没看到替代实现，CDI 路径也仍未覆盖 RDMA。

## 本期无实质改动(折叠)
- npu-operator:无新提交(ddcf0eb7)
- npu-container-toolkit:无新提交(c720a3b8)
- npu-driver-installer:无新提交(bd1b2a9e;本次 tags 接口返回空，锚点 tag 字段为空，不影响 sha 链)
- vNPU:无新提交(529e48a6)
- npu-node-provision:无新提交(717ef777)
- npu-dra-plugin:无新提交(f0654355)
- volcano-ext:无新提交(0f265f98)
- ub-network-device-plugin:无新提交(37a1d669)

## 扫描锚点(机器可读，勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=171c2fda6b763f88cccd683520139b318bbdd9d0 tag=v26.2.1 scanned=2026-11-19 -->
<!-- ANCHOR repo=npu-operator sha=ddcf0eb7819df1c7c5dfe49270b1bb43754d87d0 tag=v26.9.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c720a3b8d142b188cc3baca1ae08ffce98a7f27e tag=v26.9.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag= scanned=2026-11-19 -->
<!-- ANCHOR repo=vNPU sha=529e48a62557698ce7a0b4a8c6df5f095d626572 tag=v26.9.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=npu-dra-plugin sha=f0654355fb65ac3ffca9a41357100a82fde4fc10 tag=v26.9.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=volcano-ext sha=0f265f98234d9bed0d1192b7f16a4763894dca77 tag=v1.9.0 scanned=2026-11-19 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=37a1d669b4f5ad815110d509c541d321c0c4fab5 tag=v26.9.0 scanned=2026-11-19 -->
