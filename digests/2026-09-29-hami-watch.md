# HAMi diff 雷达 2026-09-29

## 摘要
- **ascend-device-plugin 落地全新 ENPU 软虚拟化运行时**(9 提交/新增 ~20 文件):HAMi 给昇腾 NPU 补上了类 HAMi-core 的用户态软切分路径——通过 `libvruntime.so` + `ld.so.preload` 注入,按 DIE 做持久虚拟槽位分配,支持 core 配额 + 显存 request/limit + 可选 mem-swap,并经 DCMI 暴露 per-容器指标。运行时源自 openEuler `ubs-virt`。这是本 task 边界内"两生态交汇点"的实质进展。
- **HAMi 主仓把 libvgpu 缓存目录 GC 从 monitor 迁到 Device Plugin**(#3049):新增 `vgpucache` + `nodepodinformer` 两个包,删目录前用 node-scoped informer + API-server live-Pod 二次确认;monitor 侧 `Update()` 不再删文件,只刷映射。缓存路径/宽限期改由 `HAMI_VGPU_CACHE_ROOT`/`HAMI_VGPU_CACHE_GRACE_PERIOD` 控制。
- **scheduler 两处优化**:pprof 从集群侧 HTTP 路由挪到独立 loopback 监听(`--profiling-bind-address`,安全收敛,#3117);打分快照从"全量节点"收窄为"仅候选节点"(#3024,规模性能)。

## 当日重要改变
- ascend-device-plugin [新能力] 引入 ENPU 昇腾软虚拟化运行时(runtime 分配 + 持久槽位 + mem-swap + DCMI 指标),新增 `internal/server/enpu*.go`、`internal/monitor/enpu*.go`、`scripts/build-enpu-runtime.sh`。https://github.com/Project-HAMi/ascend-device-plugin/commits/main
- ascend-device-plugin [架构方向] 新增顶层目录 `enpu-runtime-assets/`(含 Mulan PSL v2 授权),打包"经校验的官方发布运行时资产"。https://github.com/Project-HAMi/ascend-device-plugin/blob/main/scripts/build-enpu-runtime.sh
- HAMi [架构方向] 新增 `pkg/device-plugin/nvidiadevice/nvinternal/vgpucache` 与 `nodepodinformer` 两个顶层子包,缓存 GC 责任从 vGPUMonitor 转移到 Device Plugin。https://github.com/Project-HAMi/HAMi/pull/3049

## Project-HAMi/ascend-device-plugin: 074d93a8 -> 6f6ee024
- 比较: 074d93a8e1ca4f357fb1f4946f0566ced93641a6 -> 6f6ee024 | ahead=9 | files=56 | Release: ascend-device-plugin-0.1.0
- https://github.com/Project-HAMi/ascend-device-plugin/compare/074d93a8e1ca4f357fb1f4946f0566ced93641a6...6f6ee024

### AI 总结重点(源码 diff 为据)
- **ENPU 是昇腾侧的用户态软切分运行时,靠 `ld.so.preload` 注入 `libvruntime.so` 实现,与 HAMi-core 对 NVIDIA 的 CUDA hook 是同一套思路**。`enpu.go` 定义了注入用的容器内固定路径:运行时库 `/usr/local/enpu/vcann-rt/lib/libvruntime.so`、preload 文件 `/etc/ld.so.preload`、配置 `/etc/enpu/vcann-rt/npu_info.config`、监控工具 `enpu-monitor`。即容器启动时预加载虚拟运行时接管 NPU 调用,而非依赖硬件 MIG/vNPU 静态切分。

  <details><summary>代码依据 internal/server/enpu.go</summary>

  ```diff
  +	defaultENPURuntimePath           = "/usr/local/enpu/vcann-rt/lib/libvruntime.so"
  +	defaultENPUMonitorPath           = "/usr/local/enpu/vcann-rt/tools/enpu-monitor"
  +	defaultENPUPreloadPath           = "/usr/local/enpu/vcann-rt/ld.so.preload"
  +	enpuConfigContainerPath          = "/etc/enpu/vcann-rt/npu_info.config"
  +	enpuRuntimeContainerPath         = "/usr/local/enpu/vcann-rt/lib/libvruntime.so"
  +	enpuPreloadContainerPath         = "/etc/ld.so.preload"
  ```
  </details>

- **切分维度是"核配额 + 显存 request/limit",经 Pod annotation 声明,并支持三种 vnpu-mode 标识**。`enpu_config.go` 的 `listENPUAllocations` 只认 `huawei.com/vnpu-mode` ∈ {`enpu`,`ubs-virt`,`vcann-rt`} 的 Pod;`enpu.go` 定义策略/显存注解 `huawei.com/enpu-policy`、`huawei.com/enpu-memory-request`、`huawei.com/enpu-memory-limit`。`enpuAllocation` 结构体带 `CoreQuota/MemoryRequest/MemoryLimit float64`,即软切分粒度落到核与显存两轴。

  <details><summary>代码依据 internal/monitor/enpu_config.go</summary>

  ```diff
  +type enpuAllocation struct {
  +	Namespace, PodName, PodUID, ContainerName, ContainerID, DeviceUUID, Policy string
  +	PhysicalID, VirtualID                                                      int
  +	CoreQuota, MemoryRequest, MemoryLimit                                      float64
  +}
  +		switch strings.ToLower(strings.TrimSpace(pod.Annotations["huawei.com/vnpu-mode"])) {
  +		case "enpu", "ubs-virt", "vcann-rt":
  ```
  </details>

- **虚拟槽位按选定 DIE 持久化预留,跨插件进程用 flock 串行化,并靠 live-Pod 集合回收僵尸槽位**(commit "reserve persistent virtual slots on the selected DIE")。`reserveENPUConfig` 打开 `.allocation.lock` 加 `LOCK_EX`,读现有槽位后,对 `active[slot.uid]==false` 且非本次请求的槽位执行 `os.Remove` 回收;若 live-Pod 查询失败则保守保留(不误删)。这是把"分配状态"落到磁盘 + 文件锁的确定性方案,规避了多进程竞争。

  <details><summary>代码依据 internal/server/enpu_slots.go</summary>

  ```diff
  +func reserveENPUConfig(root, uid, container string, physical int32, contents func(int) string, livePods func() (map[string]bool, error)) (string, error) {
  +	lock, err := os.OpenFile(filepath.Join(root, ".allocation.lock"), os.O_CREATE|os.O_RDWR, 0600)
  +	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
  +	if len(slots) > 0 && livePods != nil {
  +		active, err = livePods()
  +		if err != nil {
  +			klog.Warningf("Retaining ENPU slots: cannot verify allocation cleanup: %v", err)
  +			active = nil
  +	if active != nil && !active[slot.uid] && slot.uid != uid {
  +			if err := os.Remove(slot.path); err != nil {
  ```
  </details>

- **可选对接外部 `enpu-manager` HTTP 服务做 DIE 分配与配额下发**(commit "add runtime allocation and optional mem-swap manager support")。`enpu_manager_client.go` 的 `allocateENPUManager` 读 `ENPU_MANAGER_URL`,为空时返回 nil 走本地路径;非空时把 HAMi 选中的 DIE 连同 core/HBM 配额 POST 给 manager,由其回填 `phy_id/vnpu_id/shm_id/aicore_quota/hbm_quota/hbm_limit`。即架构上留了"本地自管"与"外部 manager 托管"两条路。

  <details><summary>代码依据 internal/server/enpu_manager_client.go</summary>

  ```diff
  +type enpuManagerAllocation struct {
  +	PhyID         int32  `json:"phy_id"`
  +	VnpuID        int    `json:"vnpu_id"`
  +	ShmID         string `json:"shm_id"`
  +	AICoreQuota   int32  `json:"aicore_quota"`
  +	HBMRequest    int64  `json:"hbm_quota"`
  +	HBMLimit      int64  `json:"hbm_limit"`
  +func allocateENPUManager(...) (*enpuManagerAllocation, error) {
  +	endpoint := enpuManagerEndpoint()
  +	if endpoint == "" {
  +		return nil, nil
  ```
  </details>

- **监控经 DCMI 直读物理 DIE 的 HBM 占用与 AICore 利用率,再用 `/host/proc` cgroup 反查把进程归属到容器**(commit "expose metrics through the Ascend monitor")。`enpu_dcmi.go` 的 `readENPUDeviceStats` 遍历 logic ID 取 `DcGetDeviceHbmInfo`(显存)+`DcGetDeviceUtilizationRate(AICore)`(算力);`enpu_process.go` 的 `enpuProcessContainer` 解析 `/host/proc/<pid>/cgroup`,只认 `cri-containerd/containerd/docker/crio` scope 的 64 位十六进制容器 ID,含冲突/畸形即报错(fail-closed)。指标粒度到 DIE + 容器。

  <details><summary>代码依据 internal/monitor/enpu_dcmi.go / enpu_process.go</summary>

  ```diff
  +	if info, err := hbm(card, device); err == nil && info != nil && info.MemorySize > 0 && info.Usage <= info.MemorySize {
  +		value := float64(info.Usage) * common.UnitMB
  +		sample.MemoryUsed = &value
  +	if utilization, err := mgr.DcGetDeviceUtilizationRate(card, device, common.AICore); err == nil && utilization >= 0 && utilization <= 100 {
  +	enpuRuntimeScopePattern = regexp.MustCompile(`^(?:cri-containerd|containerd|docker|crio)-([[:xdigit:]]{64})\.scope$`)
  ```
  </details>

- **运行时资产由 `scripts/build-enpu-runtime.sh` 从 openEuler `ubs-virt` 官方 tag 可复现构建**,钉死 commit 与 CANN 版本。脚本 clone `https://gitcode.com/openeuler/ubs-virt.git` tag `1.0.0`(commit `46b6d55a...`),用官方 builder 镜像 `swr.cn-north-4.myhuaweicloud.com/ubscore/ubs-virt:oe2403-v1` + CANN `9.1.0` 构建,并校验 tag→commit 一致性。即 ENPU 底座是 openEuler 生态的 ubs-virt,HAMi 只做打包与 K8s 集成。

  <details><summary>代码依据 scripts/build-enpu-runtime.sh</summary>

  ```diff
  +release=1.0.0
  +commit=46b6d55a892429008b1e02f96b0a0f81d1176db8
  +repository=https://gitcode.com/openeuler/ubs-virt.git
  +builder=swr.cn-north-4.myhuaweicloud.com/ubscore/ubs-virt:oe2403-v1
  +cann_version=9.1.0
  +actual_commit=$(git -C "$source_dir" rev-parse "refs/tags/$release^{commit}")
  +[[ "$actual_commit" == "$commit" ]] || fail "Tag $release resolves to $actual_commit; expected $commit"
  ```
  </details>

### 后续发展方向 [AI]
- **昇腾软切分正被抬到与 NVIDIA 软切分对等的地位**:core+显存两轴配额、preload 注入、shm、mem-swap、DCMI 指标一应俱全,能力面已接近 HAMi-core。对我们产品意味着:HAMi 全家桶开始具备"一套调度器 + 两套用户态运行时(CUDA hook / vcann-rt)覆盖 N/A 双栈"的形态,昇腾不再只能靠硬件静态 vNPU。证据覆盖到运行时注入路径、槽位分配、指标采集;**未见调度器侧(HAMi 主仓)如何感知 ENPU 资源与打分**,也未见 mem-swap 的具体换页策略实现(仅见 manager client 中的 request/limit 字段)。
- **"外部 enpu-manager 托管"这条路可能预示商业化/闭源组件分层**:`ENPU_MANAGER_URL` 为空即回退本地自管,说明官方 manager 是可选增强件;结合 builder 镜像/资产走华为 SWR + openEuler,判断该运行时底座与企业版分发强绑定。证据仅到 HTTP 契约字段,未见 manager 服务端代码,不清楚其是否开源。

## Project-HAMi/HAMi: b309f72d -> 5d2c4e06
- 比较: b309f72d59de6dc8fd70342f029fdfacb6206259 -> 5d2c4e06 | ahead=3 | files=34 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/b309f72d59de6dc8fd70342f029fdfacb6206259...5d2c4e06

### AI 总结重点(源码 diff 为据)
- **libvgpu per-容器缓存目录的 GC 责任从 vGPUMonitor 迁到 Device Plugin,删目录前强制 API-server live-Pod 二次确认**(#3049)。新增 `vgpucache.Manager`,注释明确"owns preparation and garbage collection of the libvgpu per-container cache directories";其 `Config` 带 `ScanInterval/GracePeriod`,并接受 `listNodePods`(informer 快照)与 `listLiveNodePods`(权威确认)两个函数。这解决了此前 monitor 侧误删活跃容器缓存的竞态。

  <details><summary>代码依据 pkg/device-plugin/.../vgpucache/manager.go</summary>

  ```diff
  +// Package vgpucache owns preparation and garbage collection of the libvgpu
  +// per-container cache directories used by the NVIDIA device plugin.
  +func New(config Config, listNodePods, listLiveNodePods func() ([]*corev1.Pod, error)) (*Manager, error) {
  +	root := filepath.Clean(config.Root)
  +	if !filepath.IsAbs(root) || root == string(filepath.Separator) {
  +		return nil, fmt.Errorf("vGPU cache root must be an absolute non-root path: %q", config.Root)
  ```
  </details>

- **monitor 侧不再拥有删除权,`Update()` 改为"只刷映射不删文件"**,并新增缓存根目录不存在时的整体解除映射兜底。`cudevshr.go` 注释新增"refreshes cache mappings ... without deleting files owned by the device plugin";`Update()` 在 `os.IsNotExist` 时调 `l.unmapAll()` 后返回,而非尝试清理。职责边界由此清晰:Device Plugin 写与删,monitor 只读映射做指标。

  <details><summary>代码依据 pkg/monitor/nvidia/cudevshr.go</summary>

  ```diff
  +// Update refreshes cache mappings under the lister lock without deleting files owned by the
  +// device plugin.
   func (l *ContainerLister) Update() error {
  -
   	entries, err := os.ReadDir(l.containerPath)
   	if err != nil {
  +		if os.IsNotExist(err) {
  +			l.unmapAll()
  +		}
   		return err
  ```
  </details>

- **缓存路径与 GC 宽限期外置为环境变量/Helm 值**。`cmd/device-plugin/nvidia/main.go` 新增常量:根 `defaultVGPUCacheRoot = "/usr/local/vgpu/containers"`、扫描间隔 5s、宽限期 5m,及环境变量名 `HAMI_VGPU_CACHE_ROOT`、`HAMI_VGPU_CACHE_GRACE_PERIOD`;monitor 与 device-plugin 共享同一 `HAMI_VGPU_CACHE_ROOT`。Helm 侧新增 `devicePlugin.vgpuCache.gracePeriod` 与 `devicePlugin.monitor.resyncInterval`,并注明 `"0s"` 只去掉宽限期而非关闭 GC(仍需 live-Pod 确认)。

  <details><summary>代码依据 cmd/device-plugin/nvidia/main.go</summary>

  ```diff
  +	defaultVGPUCacheRoot         = "/usr/local/vgpu/containers"
  +	defaultVGPUCacheScanInterval = 5 * time.Second
  +	defaultVGPUCacheGracePeriod  = 5 * time.Minute
  +	vgpuCacheRootEnvName         = "HAMI_VGPU_CACHE_ROOT"
  +	vgpuCacheGracePeriodEnvName  = "HAMI_VGPU_CACHE_GRACE_PERIOD"
  ```
  </details>

- **scheduler pprof 从集群侧 HTTP 路由剥离到独立 loopback 监听,默认不再对集群暴露**(#3117)。`cmd/scheduler/main.go` 删除注入到 extender/cluster router 的 `injectProfilingRoute`,改为独立 `profilingMux()` + `--profiling-bind-address`(默认 `127.0.0.1:6060`);非 loopback 绑定会打安全告警(pprof 无鉴权)。README 明确旧集群端点现返回 404,运维需改用 port-forward。属安全收敛。

  <details><summary>代码依据 cmd/scheduler/main.go</summary>

  ```diff
  -// injectProfilingRoute injects pprof routes into the router.
  -func injectProfilingRoute(router *httprouter.Router) {
  +// profilingMux keeps diagnostic handlers off the cluster and extender routers.
  +func profilingMux() *http.ServeMux {
  +	mux := http.NewServeMux()
  +	mux.HandleFunc("GET /debug/pprof/", pprof.Index)
  +func listenProfiling(enabled bool, address string) (net.Listener, error) {
  +	if !isLoopbackAddr(address) {
  +		klog.Warningf("--profiling-bind-address=%s is not a loopback address: pprof authenticates no caller ...")
  ```
  </details>

- **调度打分快照从"全量注册节点"收窄为"仅候选节点",并省掉 `PodInfos` 的空切片预分配**(#3024,规模性能)。`getNodesUsage` 现按 `nodes` 参数分支:`nil` 时才 `ListNodes()` 建全量(供 metrics overview),否则只 `s.GetNodes(*nodes)` 建候选;`register()` 改传 `nil`。`buildNodeUsage` 把 `PodInfos: make([]*device.PodInfo, 0)` 改为留 nil,注释指出该函数"runs once per device per node on every Filter call",大集群下省掉全量深拷贝。

  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +	// Snapshot only the nodes the caller asked about. Filter and the NUMA
  +	// refit handler pass a candidate list ... building and deep-copying the
  +	// rest of the registered-node cache is wasted work.
  +	if nodes == nil {
  +		allNodes, err := s.ListNodes()
  ...
  +	} else {
  +		candidateNodes := s.GetNodes(*nodes)
  -					PodInfos:     make([]*device.PodInfo, 0),
  +					// PodInfos is left nil: every consumer ranges over it or appends to it
  ```
  </details>

### 后续发展方向 [AI]
- **vGPU 缓存的生命周期正被彻底收拢到 Device Plugin 单一 owner + API 权威确认**,反映 HAMi 在软隔离路径上补齐"资源泄漏/误删"这类生产可靠性短板;informer 走 node-scoped field-selector(`spec.nodeName=`)也显示在往单节点低开销方向调。证据覆盖 GC/informer/env 三处;**未见 GC 在大量僵尸目录下的批处理/退避实际表现**(manager.go hunk 截断,只见 `maxDeleteAttempts=5` 与 generation 机制)。
- **scheduler 明显在为"大规模节点池"优化热路径**:候选节点快照 + 免深拷贝直指 Filter 每次调用的开销。方向是承接更大集群/更高调度 QPS,而非新增调度语义。证据仅到 `getNodesUsage`/`buildNodeUsage` 两函数,未见对端到端调度延迟的基准数据(`score_bench_test.go` 有改动但 hunk 未取)。

## 本期无实质改动(折叠)
<details><summary>3 个 repo 无实质改动</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=5d2c4e063c2a6a9bb0e5cb109af27263f51b28c6 branch=master release=v2.10.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-09-29 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-09-29 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-29 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=846c0e2d3360cc7240bb61968e4cc7e3cea53443 branch=main release=v1.3.0 scanned=2026-09-29 -->
</content>
</invoke>
