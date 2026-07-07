# NVIDIA 算力栈 diff 雷达 2026-07-08

## 摘要
- **忙碌一天,5 仓有实质提交**。硬件方向信号最强:gpu-driver-container 为 **NVLink5+(GB200 NVL72 级 NVSwitch)** 加了 fabric manager 启动分支——用 InfiniBand VPD 里的 `SW_MNG` 探测 NVLink5 交换机、拉起 `nvidia-fabricmanager-start.sh` + `nvlsm`,并在 driver branch≥580 时切到重命名后的 `nvidia-fabricmanager` 包与 `nvidia-imex`/`libnvsdm`。
- nvidia-container-toolkit 把 cudacompat hook 从"只比 CUDA 版本"升级为**driver-branch 感知**(用 ELF header 里的 `Driver[]` 分支列表 + `Masterminds/semver` 比对 compat 与 host 驱动版本),并给 CDI hook 引入 `OCIHookType` 抽象(目前是脚手架,所有 hook 仍落在 createContainer)。
- KAI-Scheduler 延续 reclaim 求解器打磨:新增**场景指纹去重**(sha256(preemptor+victim UIDs) 一 job 一 cache,免重复模拟)、修**失败模拟的 feasible-node 回滚**,并给上周新入的 **NUMA 感知调度 `numa` 插件补了整套 e2e 套件**(接 NodeResourceTopology),与 07-06 记的 `PredictedNUMAZones` CRD 字段是同一条线。gpu-operator 收窄 OpenShift 支持到 ≥4.18 并改 driver 容器的 sysfs 挂载根。DCGM 一次性合入 4.6.0(概览)。

## 当日重要改变
- NVIDIA/gpu-driver-container [新能力/硬件] rhel 预编译驱动容器新增 NVLink5+ 系统支持:`_assert_nvlink5_system` 用 `/sys/class/infiniband/*/device/vpd` 里的 `SW_MNG` 标记探测 NVLink5 交换机,命中则等 `mlx5_core`/`ib_umad` 模块就绪后用 `nvidia-fabricmanager-start.sh`(带 `nvlsm` 配置)启 fabric manager;Dockerfile 对 driver branch≥580 改装 `nvidia-fabricmanager`(旧名 `nvidia-fabric-manager`)+`nvidia-imex`+`libnvsdm`,≥550 装 `infiniband-diags`+`nvlsm`。证据 `rhel9/precompiled/nvidia-driver`、`rhel9/precompiled/Dockerfile`。https://github.com/NVIDIA/gpu-driver-container/compare/102ce377e0478c58cb3927c28cfda685c6bd3425...cac25f48747d5f4384782a7008c6de55bb00c093
- NVIDIA/nvidia-container-toolkit [新能力] cudacompat hook 改为 driver-branch 感知:`UseCompat` 现按 ELF header 的 `Driver[]` 判断 host 驱动分支是否受支持、再比 compat 与 host 驱动版本,driver 版本缺失才退回 CUDA 版本比较。证据 `cmd/nvidia-cdi-hook/cudacompat/cuda-elf-header.go`、`cudacompat.go`。https://github.com/NVIDIA/nvidia-container-toolkit/compare/69c285d7fd8f23e2a45bf64efe71e1bdaa61c1de...8807d7c763603a06aca4055decc86be47a1d4c55
- NVIDIA/gpu-operator [支持矩阵/弃用] OLM bundle 最低支持 OpenShift 从 v4.16 抬到 v4.18(`com.redhat.openshift.versions: v4.16-v4.22`→`v4.18-v4.22`),4.16/4.17 集群不再受支持。证据 `bundle/metadata/annotations.yaml`。https://github.com/NVIDIA/gpu-operator/compare/7b38b13887ac4054d2f958d9e178d25f6b72ef8a...35d35715dd3f2441ddf8323e7f01a2f006116824
- kai-scheduler/KAI-Scheduler [新能力] NUMA 感知调度 `numa` 插件补齐 e2e 套件(接 NodeResourceTopology,覆盖 single-numa-node/restricted/best-effort 三种 Topology-Manager 策略),与 07-06 入的 `PredictedNUMAZones` CRD 字段合流,NUMA 对齐能力从"字段+插件"走到"有回归护栏"。证据 `test/e2e/suites/numa/*`、`test/e2e/modules/resources/rd/numa/numa.go`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1843

## NVIDIA/gpu-operator: 7b38b138 -> 35d35715
- 比较: 7b38b13887ac4054d2f958d9e178d25f6b72ef8a -> 35d35715 | ahead=4 | files=20 | Release: v26.3.3
- Compare: https://github.com/NVIDIA/gpu-operator/compare/7b38b13887ac4054d2f958d9e178d25f6b72ef8a...35d35715dd3f2441ddf8323e7f01a2f006116824

### AI 总结重点(源码 diff 为据)
- **driver 容器的 sysfs 挂载从窄路径 `/sys/devices/system/memory/auto_online_blocks` 收拢到父目录 `/sys/devices/system`**,volume 也从 `sysfs-memory-online` 更名 `host-sys-devices-system` 并显式加 `type: Directory`。这是"内存热插拔"(Memory Hotplug)支持的稳定化:挂父目录而非叶子文件,可在不同内核/OS 上稳定命中,并让 driver 容器能读到 `/sys/devices/system` 下更多子树(不止 `memory/auto_online_blocks`)。manifests 与 assets 两份 daemonset 同步改。
  <details><summary>代码依据 manifests/state-driver/0500_daemonset.yaml</summary>

  ```diff
  -          - name: sysfs-memory-online
  -            mountPath: /sys/devices/system/memory/auto_online_blocks
  +          - name: host-sys-devices-system
  +            mountPath: /sys/devices/system
  ...
  -        - name: sysfs-memory-online
  +        - name: host-sys-devices-system
           hostPath:
  -            path: /sys/devices/system/memory/auto_online_blocks
  +            path: /sys/devices/system
  +            type: Directory
  ```
  </details>
- **OLM bundle 把最低支持的 OpenShift 版本从 4.16 抬到 4.18**(顺带同 PR 里 [OLM] bump minimum supported openshift version 提交)。对存量 OCP 4.16/4.17 用户是一次支持面收窄,升级 v26.3.x operator 前需先抬集群版本。
  <details><summary>代码依据 bundle/metadata/annotations.yaml</summary>

  ```diff
  -  com.redhat.openshift.versions: v4.16-v4.22
  +  com.redhat.openshift.versions: v4.18-v4.22
  ```
  </details>

### 后续发展方向 [AI]
- 内存热插拔挂载改父目录,是 driver 容器往"更贴主机 sysfs 拓扑"靠——配合近期 CPU/内存热插拔场景(vGPU/裸金属动态扩容)。证据只覆盖挂载路径与卷定义,未见 driver 启动脚本里对新增 sysfs 子树的具体消费逻辑,不能断言已启用某项新热插拔行为。
- 未命中 `clusterpolicy_types.go` 等 CRD 信号文件,本期 ClusterPolicy API 面无增删。

## NVIDIA/nvidia-container-toolkit: 69c285d7 -> 8807d7c7
- 比较: 69c285d7fd8f23e2a45bf64efe71e1bdaa61c1de -> 8807d7c7 | ahead=7 | files=23 | Release: v1.19.1
- Compare: https://github.com/NVIDIA/nvidia-container-toolkit/compare/69c285d7fd8f23e2a45bf64efe71e1bdaa61c1de...8807d7c763603a06aca4055decc86be47a1d4c55

### AI 总结重点(源码 diff 为据)
- **`compatElfHeader.UseCompat` 签名从单参 `hostCUDAVersion string` 扩为三参 `(compatDriverVersion, hostDriverVersion, hostCUDAVersion *semver.Version)`,判定逻辑改为 driver-branch 优先**。新逻辑:host/compat 驱动版本都有时,先用 `slices.Contains(h.Driver, hostDriverVersion.Major())` 校验 host 驱动分支在 ELF header 声明的受支持分支列表里,再要求 `compatDriverVersion > hostDriverVersion` 才用容器内 compat 库;驱动版本缺失才退回原来的 CUDA 版本比较。这让"CUDA 次版本兼容"(CUDA Minor Version Compat)从粗粒度的 CUDA 版本比对,精确到驱动分支级匹配。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/cudacompat/cuda-elf-header.go</summary>

  ```diff
  -func (h *compatElfHeader) UseCompat(hostCUDAVersion string) bool {
  -	return h.CUDAVersion.UseCompat(hostCUDAVersion)
  +func (h *compatElfHeader) UseCompat(compatDriverVersion *semver.Version, hostDriverVersion *semver.Version, hostCUDAVersion *semver.Version) bool {
  +	if compatDriverVersion == nil || hostDriverVersion == nil {
  +		if hostCUDAVersion != nil { return h.CUDAVersion.UseCompat(hostCUDAVersion) }
  +		return false
  +	}
  +	if !slices.Contains(h.Driver, int(hostDriverVersion.Major())) { return false }
  +	return compatDriverVersion.Compare(hostDriverVersion) > 0
  }
  ```
  </details>
- **版本解析库从 `golang.org/x/mod/semver`+`strconv` 换成 `Masterminds/semver/v3`**,`useCompatLibraries` 改为先把 compat/host driver/host CUDA 三个版本串统一 `semver.NewVersion` 解析(解析失败仅告警不 fail),再无条件先查 ELF header——即"总是优先读 libcuda.so 的 ELF header",读不到再走 host CUDA 版本或主版本回退。去掉了旧的 `extractMajorVersion`/`normalizeVersion` 手工解析,能正确处理带前导零的版本串(commit: account for leading zeros)。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/cudacompat/cudacompat.go</summary>

  ```diff
  -	if hostCUDAVersion != "" {
  -		cudaCompatHeader, _ := GetCUDACompatElfHeaderFromReader(libcudaCompatFile)
  -		if cudaCompatHeader != nil { return cudaCompatHeader.UseCompat(hostCUDAVersion), nil }
  -		return false, nil
  -	}
  -	driverMajor, err := extractMajorVersion(hostDriverVersion)
  +	compatDriverSemver, err := semver.NewVersion(compatDriverVersion)
  +	hostDriverSemver, err := semver.NewVersion(hostDriverVersion)
  +	hostCUDASemver, err := semver.NewVersion(hostCUDAVersion)
  +	cudaCompatHeader, err := GetCUDACompatElfHeaderFromReader(libcudaCompatFile)
  +	if cudaCompatHeader != nil {
  +		return cudaCompatHeader.UseCompat(compatDriverSemver, hostDriverSemver, hostCUDASemver), nil
  +	}
  ```
  </details>
- **CDI hook 引入 `OCIHookType` 抽象,`cdiHookCreator.Create` 的 `Lifecycle` 从硬编码 `cdi.CreateContainerHook` 改为 `string(c.getOCIHookType(name))`**。新增三个常量(CreateRuntime/CreateContainer/StartContainer)映射到 OCI 生命周期阶段。注意:目前 `getOCIHookType` 的 switch 两个分支都返回 `OCIHookTypeCreateContainer`(即行为暂无变化),是为"未来允许按 hook 指定运行阶段"铺的脚手架——commit 标题 [CDI Hooks] add ability to specify OCI hook type。
  <details><summary>代码依据 internal/discover/hooks.go</summary>

  ```diff
  +type OCIHookType string
  +const (
  +	OCIHookTypeCreateRuntime = OCIHookType(cdi.CreateRuntimeHook)
  +	OCIHookTypeCreateContainer = OCIHookType(cdi.CreateContainerHook)
  +	OCIHookTypeStartContainer = OCIHookType(cdi.StartContainerHook)
  +)
  ...
  -		Lifecycle: cdi.CreateContainerHook,
  +		Lifecycle: string(c.getOCIHookType(name)),
  +func (c cdiHookCreator) getOCIHookType(name HookName) OCIHookType {
  +	switch name {
  +	case CreateSymlinksHook, ChmodHook, ...: return OCIHookTypeCreateContainer
  +	default: return OCIHookTypeCreateContainer
  +	}
  +}
  ```
  </details>

### 后续发展方向 [AI]
- **cudacompat 正从"CUDA 版本对比"迁向"驱动分支+驱动版本对比"**,更贴 NVIDIA 前向兼容的真实约束(同一 driver 分支内 minor 兼容)。配套 e2e 用 CUDA 13.0.3 容器(driver 580.126.20)测跨主机驱动 580.105.08 的 compat 选择。证据覆盖判定与解析路径,`GetCUDACompatElfHeaderFromReader` 对 ELF `Driver[]` 的填充来源本期未读 hunk。
- **`OCIHookType` 是明确的未来能力挂钩点**:当前两分支同值说明尚未有 hook 真正落到 createRuntime/startContainer 阶段;下期若见 `getOCIHookType` 的 case 分化,即某类 hook(如 ldcache/symlink)要挪到不同 OCI 阶段。证据仅这段脚手架,不能断言已有行为变化。

## NVIDIA/gpu-driver-container: 102ce377 -> cac25f48
- 比较: 102ce377e0478c58cb3927c28cfda685c6bd3425 -> cac25f48 | ahead=2 | files=4 | Release: —
- Compare: https://github.com/NVIDIA/gpu-driver-container/compare/102ce377e0478c58cb3927c28cfda685c6bd3425...cac25f48747d5f4384782a7008c6de55bb00c093

### AI 总结重点(源码 diff 为据)
- **新增 NVLink5+ 系统探测与 fabric manager 启动分支**。`_assert_nvlink5_system` 遍历 `/sys/class/infiniband/*/device/vpd`,VPD 里含 `SW_MNG` 即判为 NVLink5+ 交换机系统(GB200 NVL72 级 NVSwitch);`_load_driver` 里把它排在旧的 `_assert_nvswitch_system` 之前,命中则先 `_ensure_nvlink5_prerequisites` 死等 `mlx5_core`+`ib_umad` 内核模块加载,再用 `nvidia-fabricmanager-start.sh --mode start` 同时拉起 fabric manager 与 **nvlsm**(NVLink Subnet Manager);未命中才退回 NVLink4 及以下的 `nv-fabricmanager -c ...`。
  <details><summary>代码依据 rhel9/precompiled/nvidia-driver</summary>

  ```diff
  +_assert_nvlink5_system() (
  +    for dir in /sys/class/infiniband/*/device; do
  +        if [ -f "$dir/vpd" ] && grep -q "SW_MNG" "$dir/vpd"; then
  +            echo "Detected NVLink5+ system"; return 0
  +        fi
  +    done
  +    return 1 )
  ...
  -    if _assert_nvswitch_system; then
  +    if _assert_nvlink5_system; then
  +        _ensure_nvlink5_prerequisites || return 1
  +        /usr/bin/nvidia-fabricmanager-start.sh --mode start \
  +            --fm-config-file $fm_config_file --nvlsm-config-file $nvlsm_config_file ...
  +    elif _assert_nvswitch_system; then
           nv-fabricmanager -c /usr/share/nvidia/nvswitch/fabricmanager.cfg
       fi
  ```
  </details>
- **Dockerfile 按 driver branch 分档装包**:branch≥580 装 `nvidia-fabricmanager-${VER}`(注意包名从旧的 `nvidia-fabric-manager` 去连字符)+`libnvidia-nscq`,并装 `nvidia-imex`(IMEX,多节点 NVLink 内存导出)+`libnvsdm`;570≤branch<580 走带 branch 后缀的旧包名;branch≥550 额外装 `infiniband-diags`+`nvlsm`。这坐实 NVLink5+ 路线依赖 IB 侧管理栈(nvlsm 复用 InfiniBand subnet manager 机制)。
  <details><summary>代码依据 rhel9/precompiled/Dockerfile</summary>

  ```diff
  +            if [ "$DRIVER_BRANCH" -ge "580" ]; then \
  +            dnf install -y nvidia-fabricmanager-${DRIVER_VERSION} libnvidia-nscq-${DRIVER_VERSION}; \
  +            else \
               dnf install -y nvidia-fabric-manager-${DRIVER_VERSION} libnvidia-nscq-${DRIVER_BRANCH}-${DRIVER_VERSION} ; \
  +            fi \
  +            if [ "$DRIVER_BRANCH" -ge "580" ]; then \
  +            dnf install -y nvidia-imex-${DRIVER_VERSION} libnvdsm-${DRIVER_VERSION}; \
  +            elif [ "$DRIVER_BRANCH" -ge "570" ]; then \
  +            dnf install -y nvidia-imex-${DRIVER_BRANCH}-${DRIVER_VERSION} libnvsdm-${DRIVER_BRANCH}-${DRIVER_VERSION} ; \
  +            fi \
  +            if [ "$DRIVER_BRANCH" -ge "550" ]; then dnf install install -y infiniband-diags nvlsm ; fi \
  ```
  </details>

### 后续发展方向 [AI]
- **驱动容器正在把 GB200/NVL72 级机架(NVLink5 + NVSwitch + IMEX)的 day-0 编排纳入镜像自身**:从"探测 → 等 IB 模块 → 起 nvlsm + fabric manager"整条链都进了 `nvidia-driver` 启动脚本,意味着这类超节点的 fabric 拉起不再依赖外部编排。证据覆盖 rhel9/rhel10 两份预编译脚本与 Dockerfile,未见对应的非预编译(通用 tarball)路径是否同步,也未见 `nvidia-fabricmanager-start.sh` 脚本本体(不在本仓 diff)。
- Dockerfile 里 `dnf install install`(重复 install)疑似笔误但不影响判断方向;IMEX 装包上线提示后续会有多节点 NVLink 内存共享(GPU 跨节点直连)相关的 device-plugin/operator 侧配套,值得下期盯 gpu-operator 是否加 IMEX daemon 编排。

## kai-scheduler/KAI-Scheduler: 8fab211a -> 9fad9300
- 比较: 8fab211af6e482be7f4b0a75dbf59571909c496a -> 9fad9300 | ahead=4 | files=37 | Release: v0.16.3
- Compare: https://github.com/kai-scheduler/KAI-Scheduler/compare/8fab211af6e482be7f4b0a75dbf59571909c496a...9fad93007f7d41e86e104f85656d106ff4354d50

### AI 总结重点(源码 diff 为据)
- **新增 reclaim 场景指纹去重(#1838)**:`scenario_fingerprint.go` 用 sha256 对 4 段做规范化哈希——preemptor UID + pending / recorded-victim / potential-victim 三组 task UID(每组先 `slices.Sort` 再拼,故不同顺序/批次的等价 victim 集映射到同一指纹)。solver 在 portfolio 每吐出一个候选、模拟之前立刻算指纹,命中缓存则跳过模拟,记为新指标状态 `duplicate`(`scenario_search_scenarios_total` 的 state 从 emitted/simulated/validator_rejected 扩了 `duplicate`)。缓存一 job solve 一份、不跨 session,只缓存"模拟过且失败"的场景。
  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/scenario_fingerprint.go</summary>

  ```diff
  +func fingerprintScenario(sn *scenario.ByNodeScenario) scenarioFingerprint {
  +	digest := sha256.New()
  +	if preemptor := sn.GetPreemptor(); preemptor != nil { writeString(digest, string(preemptor.UID)) }
  +	for _, tasks := range [][]*pod_info.PodInfo{ sn.PendingTasks(), sn.RecordedVictimsTasks(), sn.PotentialVictimsTasks() } {
  +		writeString(digest, fingerprintSectionSeparator); writeTaskUIDs(digest, tasks)
  +	}
  +	var fingerprint scenarioFingerprint; digest.Sum(fingerprint[:0]); return fingerprint
  +}
  ```
  </details>
- **修失败模拟的 feasible-node 回滚(#1841)**:`byPodSolver.solve` 在 `result != nil && !result.solved` 时补 `feasibleNodesRollback(newFeasibleNodes)`——因 feasibleNodes map 在整个 probe 的多个场景间共享,validator-rejected/error 结果也必须回滚,否则残留节点污染后续场景。同时 `tryScenarioWithEvictedVictims`/`runSimulation` 去掉 error 返回值(签名从 `(bool, *simulationVictims, error)` 收成 `(bool, *simulationVictims)`),删掉 `handleSolveError` 分支——错误路径统一并进"未解出"。这是上面去重缓存正确性的前置:去重靠"相同指纹在 session 内模拟确定性",而确定性要求每次失败都把 feasible-node 集还原到"仅由 recorded victims 派生"。
  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/by_pod_solver.go</summary>

  ```diff
  +		if !result.solved {
  +			s.feasibleNodesRollback(newFeasibleNodes)
  +		}
  		return result
  ...
  -	successfulSimulation, solutionVictims, err := s.tryScenarioWithEvictedVictims(...)
  -	if err != nil { return handleSolveError(pendingJob, nextTaskToFindAllocation, err, statement) }
  +	successfulSimulation, solutionVictims := s.tryScenarioWithEvictedVictims(...)
  ```
  </details>
- **NUMA 感知调度 `numa` 插件补齐 e2e 套件(#1843)**。新增 `test/e2e/suites/numa/*`(reclaim/modes/preempt/qos/operand 五组 spec)+ `rd/numa/numa.go`(只读发现集群 NRT,按 Topology-Manager 策略 none/best-effort/restricted/single-numa-node 建 Guaranteed pod)+ feature_flags/numa.go(通过 patch `SchedulingShard.Spec.Plugins["numa"]` 开关插件)。测试用 fake-gpu-operator 的新 `numa` 拓扑字段(每 pool 声明 zones/topologyManagerPolicy/distances)与 status-exporter 发布 NodeResourceTopology+podResources。这坐实 07-06 记录的 `PredictedNUMAZones` CRD 字段背后确有一个成形的 NUMA 对齐调度插件。
  <details><summary>代码依据 test/e2e/modules/configurations/feature_flags/numa.go + hack/fake-gpu-operator-values.yaml</summary>

  ```diff
  +func EnableNUMA(ctx, testCtx, arguments map[string]string) error {
  +	return setNUMA(ctx, testCtx, ptr.To(true), arguments) }
  +		shard.Spec.Plugins[numaPluginName] = kaiv1.PluginConfig{ Enabled: enabled, Arguments: arguments }
  ...
  +      numa:
  +        zones: 2
  +        topologyManagerPolicy: restricted
  +statusExporter:
  +  nodeResourceTopology:
  +    enabled: true
  ```
  </details>
- **operator informer 缓存收窄到 KAI 命名空间(#1845)**:`cmd/operator/app/app.go` 把 Pod/Lease/EndpointSlice 三类 informer 的 cache scope 限到 KAI 所在 ns(降 watch 量与内存)。snapshot-tool 侧加 `disableWatchListClientForFakeReplay`——关掉 client-go 1.35 默认开的 WatchListClient 门控,绕开 NRT 生成客户端(基于旧 client-go v0.22)在 fake clientset 下 watch-list reflector 卡死、导致回放的 NRT 不同步的问题。
  <details><summary>代码依据 cmd/snapshot-tool/main.go</summary>

  ```diff
  +func disableWatchListClientForFakeReplay() {
  +	featureGates, ok := clientfeatures.FeatureGates().(interface{ Set(clientfeatures.Feature, bool) error })
  +	if !ok { return }
  +	if err := featureGates.Set(clientfeatures.WatchListClient, false); err != nil { utilruntime.HandleError(err) }
  +}
  ```
  </details>

### 后续发展方向 [AI]
- **NUMA 对齐调度是当前主线之一**:字段(PredictedNUMAZones,07-06)→ 插件 e2e 护栏(本期)已闭环,fake-gpu-operator 现能模拟多 NUMA-zone GPU 节点并发布 NRT/podResources,说明其 NUMA 放置要与 kubelet Topology Manager 策略对齐(single-numa-node/restricted 才强制、best-effort/none 放行)。证据覆盖 e2e 与 fake-operator 配置,`numa` 插件本体的对齐算法(如何消费 NRT zone 里的 free GPU、`reconstructAvailable`/`ignoreList` 参数语义)本期未读 hunk。
- **reclaim 求解器仍在"降模拟次数"路线上收敛**:上期是去 map 分配,本期是场景级去重 + 失败回滚保确定性,`reclaim-generator-portfolio-design.md` 把去重缓存从 "Future Enhancements" 提为已实现节。方向是大规模抢占场景下把"portfolio 多 generator 重复吐等价 victim 集"的浪费掐掉。证据仅 solver/fingerprint 子树,generator 侧如何触发重复本期未展开。

## dra-driver / DCGM(低信号)
- **kubernetes-sigs/dra-driver-nvidia-gpu**:8807(884f41fd→2607fc64,ahead=6)本期实质提交仅 1 条纯文档(`site/content/contribute/docs.md`,讲 Hugo `driver_version`/`driver_release_tag` 版本参数用法),其余为 bump/CI/merge。**无代码/CRD/DRA 行为变化**,不做符号级展开。Compare: https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/compare/884f41fdd20204ae2f194ba9a94cce4b4200110b...2607fc64e99547f604f201b66cefc06eab45090e
- **NVIDIA/DCGM**(master):单次 squash 提交 `DCGM 4.6.0`(#306),files=300 被 API 截断,走概览模式未逐 hunk。改动热点集中在 `dcgmlib/src`(51)、`modules/mndiag`(39,多节点诊断)、`modules/nvswitch`(9)、`modules/diag`(8),提示 4.6.0 主要在底层库与多节点/NVSwitch 诊断上加料——与上面 NVLink5+ 硬件线呼应,但无 release body,breaking 判断待后续单独看 tag。Compare: https://github.com/NVIDIA/DCGM/compare/d646460fe8ac5f3b67daf4f27385fe7701187d23...72fa3feaa67d716a75323a8f47c34ff3ee73f824

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓</summary>

- NVIDIA/k8s-device-plugin — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=35d35715dd3f2441ddf8323e7f01a2f006116824 branch=main release=v26.3.3 scanned=2026-07-08 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=8807d7c763603a06aca4055decc86be47a1d4c55 branch=main release=v1.19.1 scanned=2026-07-08 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=cac25f48747d5f4384782a7008c6de55bb00c093 branch=main release=— scanned=2026-07-08 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=10fd1c08afa74932e0f949e540eca9d9953d9cec branch=main release=v0.19.3 scanned=2026-07-08 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=2607fc64e99547f604f201b66cefc06eab45090e branch=main release=v0.4.1 scanned=2026-07-08 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-08 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=944764a9e9685d82279eb2d1ee216b7b2451e213 branch=main release=v0.14.3 scanned=2026-07-08 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=9fad93007f7d41e86e104f85656d106ff4354d50 branch=main release=v0.16.3 scanned=2026-07-08 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-08 -->
