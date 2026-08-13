# 昇腾算力栈 diff 雷达 2026-08-14

## 摘要
- **mind-cluster 一次落三件"对标 NV"的能力**:①ascend-docker-runtime 引入 **CDI 注入模式**(legacy/cdi 双轨,走 CNCF container-device-interface 标准库),②新增 **CRI-O 容器引擎**支持(此前仅 docker/containerd/isula),③ascend-device-plugin 向 kubelet **上报 NPU 的 NUMA 拓扑**(`Device.Topology.Nodes`),打通 TopologyManager 的 NPU↔CPU/内存 NUMA 对齐。
- 另有一处性能修:故障刷新从"每次都查 DCMI 错误码"改为**仅在出现 FaultRecover 时才懒查**,减少 DCMI 压力。
- 其余 8 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)本期无新提交。

## 当日重要改变
- mind-cluster [架构方向] ascend-docker-runtime 从"自研 hook 挂载"转向 **CNCF CDI 标准注入**,新增 `config.go`/`inject.go`/CDI spec builder/mount 子包 + 安装开关 `--injection-mode=cdi|legacy`,默认 legacy。 https://gitcode.com/Ascend/mind-cluster/commit/229cbeea4f73c26ce209333a923f8ab3fc3e5a56
- mind-cluster [新能力] ascend-device-plugin 新增 `numa_utils.go`(NumaNodeManager 读 sysfs)并在 ListAndWatch 回包里填 `v1beta1.Device.Topology`,使 NPU 具备 NUMA-aware 调度基础。 https://gitcode.com/Ascend/mind-cluster/commit/229cbeea4f73c26ce209333a923f8ab3fc3e5a56
- mind-cluster [新能力] ascend-docker-runtime 新增 `crio_process.go`(CriOProcess 改写 CRI-O drop-in TOML)+ 把 crio.sock 加入 dpMountConfigs,容器引擎覆盖面扩到 cri-o。 https://gitcode.com/Ascend/mind-cluster/commit/229cbeea4f73c26ce209333a923f8ab3fc3e5a56

## mind-cluster: 4351a8e7 -> 229cbeea
- 比较: 4351a8e7..229cbeea | tag: v26.1.0 | commits=24 | truncated=false
- 源:https://gitcode.com/Ascend/mind-cluster/compare/4351a8e7aab50b1ff0a4b7e0ca8f1430f1d27391...229cbeea4f73c26ce209333a923f8ab3fc3e5a56

### AI 总结重点(源码 diff 为据)

- **ascend-device-plugin 首次向 kubelet 上报 NPU 的 NUMA 拓扑**。新增 `PluginServer.convertNpuDeviceToPluginDevice()`,替换掉原先所有 `&v1beta1.Device{ID, Health}` 直接构造;它按 `PhyID` 查 `device.GetNumaNodesByPhyID()`,非空则填 `Device.Topology.Nodes = []*NUMANode{ID}`。这让 kubelet TopologyManager 能把 NPU 与 CPU/内存做同 NUMA 对齐(此前 NPU 无拓扑信息、无法参与 NUMA 亲和)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/plugin.go</summary>

  ```diff
  -   resp.Devices = append(resp.Devices, &v1beta1.Device{ID: newDeviceName, Health: device.Health})
  +   resp.Devices = append(resp.Devices, ps.convertNpuDeviceToPluginDevice(device, newDeviceName))
  ...
  +func (ps *PluginServer) convertNpuDeviceToPluginDevice(devOri common.NpuDevice, newDeviceName string) *v1beta1.Device {
  +	dev := &v1beta1.Device{ID: newDeviceName, Health: devOri.Health}
  +	numaNodes := device.GetNumaNodesByPhyID(devOri.PhyID)
  +	if len(numaNodes) == 0 { return dev }
  +	dev.Topology = &v1beta1.TopologyInfo{Nodes: make([]*v1beta1.NUMANode, 0, len(numaNodes))}
  +	for _, nodeId := range numaNodes {
  +		dev.Topology.Nodes = append(dev.Topology.Nodes, &v1beta1.NUMANode{ID: nodeId})
  +	}
  +	return dev
  +}
  ```
  </details>

- **NUMA 发现落在新包 `numa_utils.go`**:`NumaNodeManager` 缓存 `phyIDToNumaNodes map[int32][]int64` 与 `cpuListToNumaNode`,通过 `filepath.Glob("/sys/devices/system/node/node*")` 扫 sysfs 建映射,并有 `validateSysfsPath` 限定 `/sys/` 前缀防路径穿越。属于新增独立能力单元(带并发锁保护的进程内缓存)。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/device/numa_utils.go(新增,208 行)</summary>

  ```diff
  +type NumaNodeManager struct {
  +	dmgr                devmanager.DeviceInterface
  +	cpuListToNumaNode   map[string]int64
  +	phyIDToNumaNodes    map[int32][]int64
  +	...Mu sync.RWMutex
  +}
  +func GetNumaNodesByPhyID(phyID int32) []int64 { return numaMgr.getNumaNodesByPhyID(phyID) }
  +func (n *NumaNodeManager) buildCpuListToNumaNodeMap() error {
  +	nodePaths, err := filepath.Glob("/sys/devices/system/node/node*")
  ```
  </details>

- **ascend-docker-runtime 引入 CDI 注入模式,与旧 legacy 挂载并存**。新增 `config.go` 定义 `Config{InjectionMode}`,取值 `legacy`(默认)或 `cdi`,从 `RunTimeDConfigPath/config.json` 读、`sync.Once` 缓存,读不到/校验失败一律回落 legacy;`inject.go` 的 `InjectEdits()` 直接调用 CNCF `tags.cncf.io/container-device-interface` 库把 CDI Spec 的 ContainerEdits(spec 级 + 每设备级)应用到 OCI spec。这是从自研 hook 向业界 CDI 标准收敛的方向性改动。
  <details><summary>代码依据 runtime/process/config.go + inject.go(均新增)</summary>

  ```diff
  +const ( defaultInjectionMode = "legacy"; cdiInjectionMode = "cdi" )
  +func loadConfig() *Config { configOnce.Do(func(){ config = loadConfigFromFile() }); return config }
  +// InjectEdits applies a CDI Spec's container edits to an in-memory OCI spec.
  +func InjectEdits(spec *specs.Spec, cdidSpec *cdispec.Spec) error {
  +	if err := (&cdi.ContainerEdits{ContainerEdits: &cdidSpec.ContainerEdits}).Apply(spec); err != nil { return err }
  +	for _, dev := range cdidSpec.Devices { ... .Apply(spec) }
  +}
  ```
  </details>

- 安装脚本 `run_main.sh` 相应加 `--injection-mode=<mode>` 参数,install/upgrade 时把 `{"injectionMode":...}` 写到 `config.json`(mode 640),uninstall 时删除;upgrade 未显式传参时**从旧 install.info 继承**,避免被空值覆盖。
  <details><summary>代码依据 build/scripts/run_main.sh</summary>

  ```diff
  +  --injection-mode=<mode>       Injection mode for NPU devices, cdi or legacy (default: legacy)
  +    if [[ -n "${INJECTION_MODE}" ]]; then
  +        echo "{\"injectionMode\": \"${INJECTION_MODE}\"}" > ${ASCEND_RUNTIME_CONFIG_DIR}/config.json
  +    # upgrade 时无参则从 install.info 继承
  +        INJECTION_MODE=$(grep "^injection-mode=" .../ascend_docker_runtime_install.info | cut -d"=" -f2-)
  ```
  </details>

- **新增 CRI-O 容器引擎支持**。新增 `install/process/crio_process.go` 的 `CriOProcess()`,按 `[crio.runtime.runtimes]` 路径改写 CRI-O drop-in TOML(`crioRuntimePath()` 组装 TOML key 路径);runtime 侧 `process.go` 把 `crioSockHostPath=/var/run/crio/crio.sock` 加进 `dpMountConfigs`,容器内可见 crio.sock。此前引擎仅 docker/containerd/isula。
  <details><summary>代码依据 runtime/process/process.go</summary>

  ```diff
  +	crioSockHostPath        = "/var/run/crio/crio.sock"
  +	crioSockContainerPath   = "/var/run/crio/crio.sock"
  ...
  var dpMountConfigs = []dpMountConfig{
  	{dockerSockHostPath, ...}, {containerdHostPath, ...},
  +	{crioSockHostPath, crioSockContainerPath, true},
  }
  ```
  </details>

- **故障刷新减少无谓 DCMI 查询**(提交"减少故障刷新时不必要的 DCMI 查询")。`getCurDeviceFaultCode` 去掉 `devFaultInfo` 入参、改成传函数引用;`SetNewFaultAndCacheOnceRecoverFault` 由"外部先算好 curFaultCodesMap 再传入"改为"接受回调 `getCurFaultCodes`,仅当某条 chipFaultInfo 的 `Assertion==FaultRecover` 时才真正调用一次 DCMI 的 `GetDeviceAllErrorCode`"。即把每设备无条件的 DCMI 查询改成"只有发生故障恢复时"才懒加载,降低正常态下的 DCMI 调用量。
  <details><summary>代码依据 common/fault_code.go + device/ascendcommon.go</summary>

  ```diff
  -func SetNewFaultAndCacheOnceRecoverFault(..., curFaultCodesMap sets.Int64) {
  +func SetNewFaultAndCacheOnceRecoverFault(..., getCurFaultCodes func(logicID int32) sets.Int64) {
  +	curFaultCodesMap := sets.Int64{}
  +	for _, faultInfo := range chipFaultInfos {
  +		if faultInfo.Assertion == common.FaultRecover && getCurFaultCodes != nil {
  +			curFaultCodesMap = getCurFaultCodes(logicID); break
  +		}
  +	}
  -func (tool *AscendTools) getCurDeviceFaultCode(logicID int32, devFaultInfo []npuCommon.DevFaultInfo) sets.Int64 {
  -	if len(devFaultInfo) == 0 { return sets.Int64{} }
  +func (tool *AscendTools) getCurDeviceFaultCode(logicID int32) sets.Int64 {
  +	if tool == nil || tool.dmgr == nil { return sets.Int64{} }
  ```
  </details>

- 次要重构:抽出 `writeTomlConfigToFile()` 供 containerd/CRI-O 共用,并把 `file.Close()`/`file.Sync()` 的错误经命名返回值捕获(此前 `defer file.Close()` 静默吞掉 flush 失败,磁盘满/NFS/配额场景下会漏报)。process.go 里 vnpu 分支 `addHook` 现把 `*deviceIdList = []int{int(vdevice.VdeviceID)}`,并把 `io/ioutil` 迁到 `io`。

### 后续发展方向 [AI]
- CDI + CRI-O 两条线合看,ascend-docker-runtime 正把"注入路径"和"引擎适配"都往云原生标准靠(CDI 是 NV/Intel 共用的设备注入标准,cri-o 是 OpenShift 默认引擎)——**对标 OAI 场景意义明确**:若产品底座跑 OpenShift/CRI-O,昇腾运行时现已可原生接入。证据只覆盖 runtime 侧 config/inject/crio 三处新增文件与安装脚本,**未见** CDI spec builder 具体如何枚举 DevType 生成设备节点(该文件本次未进 top patch,只在提交标题"CDI spec builder with validation and per-claim file generation"出现)。
- NUMA 上报只是"device-plugin 填了 Topology 字段",能否真正 NUMA-aware 还依赖 kubelet TopologyManager 策略(single-numa-node 等)与调度侧配合;**证据仅覆盖 plugin.go 回包 + numa_utils.go sysfs 发现**,未见 for-volcano 侧是否消费该拓扑。
- 故障刷新改懒查是纯性能/DCMI 负载优化,不改外部语义,无 API/CRD 变更。

## 本期无实质改动(折叠)
- npu-operator / npu-container-toolkit / npu-driver-installer / vNPU / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin:均无新提交。

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=229cbeea4f73c26ce209333a923f8ab3fc3e5a56 tag=v26.1.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=npu-operator sha=7cddacb58841f285c6f719e2d7a5cb235be32cdb tag=v26.6.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=npu-container-toolkit sha=c1be1ea245fe171704b3b21582beb4af8f9028ef tag=v26.6.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=npu-driver-installer sha=bd1b2a9eb1a1017b1d1528f420b38ed6c3020fb3 tag=v26.6.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=vNPU sha=f5869cd17c57b8392b97fc76a7879a1a9a1eb81f tag=v0.1.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=npu-dra-plugin sha=90c70b32b9b368efc2cc26bda1209e4f275a804c tag=v26.6.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-08-14 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-08-14 -->
