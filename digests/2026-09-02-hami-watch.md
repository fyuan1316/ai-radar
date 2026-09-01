# HAMi diff 雷达 2026-09-02

## 摘要
- **软隔离内核修了两处真 bug**:HAMi-core 把 `exit_handler`/`lock_shrreg` 的进程身份从缓存的 `region_info.pid` 改成实时 `getpid()`,堵住"clone 子进程退出误清父进程共享内存槽位/误放父进程锁"的竞态;同时补齐 NVML v2 hook 的参数元数(`nvmlDeviceGetFanSpeed_v2` 漏了 fan 索引、`nvmlDeviceGetRetiredPages_v2` 漏了 timestamps 数组,之前多传的实参会以寄存器残值形态漏进驱动)。
- **HAMi 主仓一轮健壮性 + 可观测性硬化**:device-plugin 把 NVML 失败从 `panic(0)` 改成"跳过坏卡/返回错误"、vGPUmonitor 新增主机 GPU 温度/功耗/ECC 错误三类指标并把 listen 失败/serve 退出上报给容器、NUMA refit 改用 phase-aware 计账修 init 容器双计数、device-plugin 支持 `--nvidia-driver-root=auto` 从 GPU Operator 契约自动解析。
- **WebUI Chart 2 单镜像方向落锤**:`chart-2-single-image.md` 提案 status=accepted——一个 Go 进程 in-process 服务 Vue 静态资源 + API,单镜像单容器(3000 浏览器口 / 8000 内部指标口),Chart 1.x 嵌套 values 直接 fail-closed 拒绝;这是上一期(8-31 概览)预测的 Go 统一入口的正式定稿。

## 当日重要改变
- **Project-HAMi/HAMi-WebUI [架构方向]** Chart 2 单镜像运行时提案定为 accepted,`refactor(chart)!` 破坏性合并一个应用容器,`legacyBackendPort` 兼容口定于 Chart 2 移除。证据:`docs/proposals/chart-2-single-image.md`(新增)。https://github.com/Project-HAMi/HAMi-WebUI/pull/229
- **Project-HAMi/HAMi-WebUI [API/CRD变更]** proto 三个 Reply 消息新增 `optional bool ..._known` 字段,把"算力用量=0"与"算力用量未知"在 API 层区分开。证据:`server/api/v1/{node,card,container}.proto`。https://github.com/Project-HAMi/HAMi-WebUI/pull/260
- **Project-HAMi/HAMi [新能力]** vGPUmonitor 暴露主机 GPU 温度/功耗/ECC 错误三类 Prometheus 指标。证据:`cmd/vGPUmonitor/metrics.go`。https://github.com/Project-HAMi/HAMi/pull/2732
- **Project-HAMi/volcano-vgpu-device-plugin [新能力]** 新增 `CUDA_DISABLE_CONTROL_DP` 环境变量,置位即跳过 `/etc/ld.so.preload` 注入——等于给 Volcano 路径一个"按需关掉 HAMi-core CUDA hook"的逃生阀。证据:`pkg/plugin/server.go`。https://github.com/Project-HAMi/volcano-vgpu-device-plugin/commit/cbded47b8d4cabb4ac6b228e52049949a1bae271

## Project-HAMi/HAMi-core: de6ce39d -> f01e9f23
- 比较 / 最新 Release:https://github.com/Project-HAMi/HAMi-core/compare/de6ce39d...f01e9f23 (无 Release)

### AI 总结重点(源码 diff 为据)
- **`exit_handler()` 的进程身份从缓存 pid 改为实时 `getpid()`,并对"继承来的退出钩子"直接短路返回**。之前 `int32_t my_pid = region_info.pid;` 用的是共享区里缓存的 pid;经 `clone(SIGCHLD)`(不走 glibc 的 pthread_atfork 复位)创建的子进程,继承了父进程 atexit 注册的 `exit_handler`,子进程 `exit(0)` 时会拿着父进程的 pid 去清槽位、`sem_post` 一把父进程仍持有的锁。改后先取自身 pid,若缓存 pid 非 0 且 ≠ 自身则判定为"继承的钩子"并跳过清理。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -    int32_t my_pid = region_info.pid;
  +    /*
  +     * Identity is the calling process, not the cached parent pid.  After
  +     * clone()/fork paths that skip pthread_atfork, region_info.pid still
  +     * belongs to the parent; using it here would drop the parent's slot
  +     * and sem_post a lock the parent still holds.
  +     */
  +    int32_t my_pid = getpid();
  +    if (region_info.pid != 0 && region_info.pid != my_pid) {
  +        LOG_DEBUG("Skip inherited exit cleanup; cached pid %d != self %d",
  +                  region_info.pid, my_pid);
  +        return;
  +    }
  ```
  </details>
- **`lock_shrreg()` 抢锁成功后把 `owner_pid` 写成实时 `getpid()`,`child_reinit_flag()` 在检测到子进程时同步刷新 `region_info.pid`**。配合上一条,确保锁归属和共享区身份始终是当前真实进程,而不是父进程遗留值。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  -            region->owner_pid = region_info.pid;
  +            region->owner_pid = (size_t)getpid();
  ...
   void child_reinit_flag() {
       region_info.init_status = PTHREAD_ONCE_INIT;
  +    region_info.pid = getpid();
       postinit_lock_held = 0;
  ```
  </details>
- **NVML v2 pass-through wrapper 补齐被吞掉的实参**。`nvmlDeviceGetFanSpeed_v2` 原来只声明 `(device, *speed)`,漏了 v2 相对 v1 多出的 `unsigned int fan` 风扇索引;`nvmlDeviceGetRetiredPages_v2` 漏了 `timestamps` 数组。由于 wrapper 经 `driver_sym_t` 无原型函数指针转发、且本翻译单元看不到 NVIDIA 的 nvml.h,v1 arity 声明能无警告编译链接,漏掉的那个实参就以"对应参数寄存器里恰好是什么"的形态漏进真实驱动。改后按 v2 真实签名声明并转发。
  <details><summary>代码依据 src/nvml/nvml_entry.c</summary>

  ```diff
  -nvmlReturn_t nvmlDeviceGetFanSpeed_v2(nvmlDevice_t device,
  +nvmlReturn_t nvmlDeviceGetFanSpeed_v2(nvmlDevice_t device, unsigned int fan,
                                         unsigned int *speed) {
     return NVML_OVERRIDE_CALL(nvml_library_entry, nvmlDeviceGetFanSpeed_v2, device,
  -                         speed);
  +                         fan, speed);
  ...
  -                                          unsigned long long *addresses) {
  +                                          unsigned long long *addresses,
  +                                          unsigned long long *timestamps) {
     return NVML_OVERRIDE_CALL(nvml_library_entry, nvmlDeviceGetRetiredPages_v2,
  -                         device, cause, pageCount, addresses);
  +                         device, cause, pageCount, addresses, timestamps);
  ```
  </details>
- **新增两支 GPU-free 回归测试**:`test_fork_child_exit_cleanup.c`(+286)复现 clone 子进程退出后父进程仍须持锁/保槽;`test_nvml_v2_signatures.c`(+168)装一张自带 entry 表、按真实 NVML 原型调 wrapper 校验 arity,且强制 `LIBCUDA_LOG_LEVEL=4`——低于此级 `NVML_OVERRIDE_CALL` 的 LOG_DEBUG 分支不触发、不会踩脏参数寄存器,v1-arity 的 wrapper 反而会"碰巧"把漏参传对,测试宁可拒跑也不报假 pass。说明这层 hook 的正确性验证正在从"跑得起来"往"无 GPU 可确定性回归"补。

### 后续发展方向 [AI]
- 软隔离内核的工作重心从"显存/算力限额算法"转向**多进程/fork 语义的鲁棒性**:clone-without-atfork 的场景(sidecar、某些运行时的进程模型)正被逐个堵。证据只覆盖 exit/lock/child_reinit 三处 pid 身份,未见对信号处理路径或 `region->owner_pid` 死锁 TODO(代码里仍留 "irregular exit here will hang pending locks")的处理。
- NVML v2 签名修正意味着 hook 层要跟 NVIDIA 驱动的版本化 API 对齐,后续可能有更多 `_v2/_v3` wrapper 的 arity 审计;证据仅两个函数,未见系统性扫描机制。

## Project-HAMi/HAMi: ebcd8ae0 -> e6932f52 (v2.10.0)
- 比较 / 最新 Release:https://github.com/Project-HAMi/HAMi/compare/ebcd8ae0...e6932f52 (Release v2.10.0,未跨档)

### AI 总结重点(源码 diff 为据)
- **device-plugin 注册路径去 `panic`,坏卡跳过而非崩进程**。`getAPIDevices()` 签名从 `*[]*device.DeviceInfo` 改为 `(*[]*device.DeviceInfo, error)`:NVML `Init` 失败改为返回 error;`DeviceGetHandleByUUID`/`GetIndex`/`GetMemoryInfo`/`GetName` 失败从 `panic(0)` 改为记日志 `continue` 跳过该卡;`RegisterInAnnotation` 把 error 上抛。单卡故障不再拖垮整个 device-plugin 进程。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/register.go</summary>

  ```diff
  -func (plugin *NvidiaDevicePlugin) getAPIDevices() *[]*device.DeviceInfo {
  +func (plugin *NvidiaDevicePlugin) getAPIDevices() (*[]*device.DeviceInfo, error) {
   	if nvret := nvmlInit(); nvret != nvml.SUCCESS {
  -		panic(0)
  +		return nil, fmt.Errorf("nvml init failed: %v", nvret)
   	}
  ...
   		ndev, ret := nvml.DeviceGetHandleByUUID(UUID)
   		if ret != nvml.SUCCESS {
  -			panic(0)
  +			klog.Errorf("skipping device uuid=%s: nvml DeviceGetHandleByUUID failed: %v", UUID, ret)
  +			continue
   		}
  ```
  </details>
- **vGPUmonitor 新增主机级 GPU 温度/功耗/ECC 指标,并把 per-device label 解析抽成一次**。新增 `hami_host_gpu_temperature_celsius`、`hami_host_gpu_power_usage_watts`、`hami_host_gpu_ecc_errors_total`(后者带 `error_type` label)三个 Desc;引入 `gpuDeviceIdentity` 结构 + `resolveGPUDeviceIdentity`,每卡每次抓取只解析一次 node/uuid/name,取代各 collector 各自调 `GetUUID()/GetName()` 重复读环境变量。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go</summary>

  ```diff
  +	hostGPUTemperaturedesc = prometheus.NewDesc(
  +		"hami_host_gpu_temperature_celsius", ...
  +		[]string{"node", "device_index", "device_uuid", "device_type"}, nil)
  +	hostGPUPowerUsagedesc = prometheus.NewDesc(
  +		"hami_host_gpu_power_usage_watts", ... )
  +	hostGPUEccErrorsdesc = prometheus.NewDesc(
  +		"hami_host_gpu_ecc_errors_total",
  +		[]string{"node", "device_index", "device_uuid", "device_type", "error_type"}, nil)
  +
  +type gpuDeviceIdentity struct { nodeName; uuid; deviceName string }
  +func (cc ClusterManagerCollector) resolveGPUDeviceIdentity(hdev nvml.Device) (gpuDeviceIdentity, error) { ... }
  ```
  </details>
- **vGPUmonitor 指标服务器把 listen/serve 失败上报给容器,不再静默**。`initMetrics` 先 `net.Listen` 抢端口(绑定失败=启动期不可自愈的配置错,提前返回);`server.Serve` 在 goroutine 里的致命错误经 `serveErr` channel 上抛;`start()` 把 signal(正常退出)与 error(异常)区分,返回 `runErr` 让 main 非零退出;rootCmd 设 `SilenceUsage: true` 避免运行期错误时打印整页 flag help。之前 listen 失败只 `klog.Errorf` 然后容器仍显示 Completed。
  <details><summary>代码依据 cmd/vGPUmonitor/main.go</summary>

  ```diff
  +	listener, err := net.Listen("tcp", metricsBindAddress)
  +	if err != nil {
  +		return fmt.Errorf("failed to listen on %s: %w", metricsBindAddress, err)
  +	}
  ...
  -	go func() { if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed { klog.Errorf(...) } }()
  -	<-ctx.Done()
  +	serveErr := make(chan error, 1)
  +	go func() { if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) { serveErr <- err } }()
  +	select {
  +	case err := <-serveErr: return fmt.Errorf("metrics server on %s stopped: %w", metricsBindAddress, err)
  +	case <-ctx.Done():
  ```
  </details>
- **device-plugin 支持 `--nvidia-driver-root=auto`,从 GPU Operator 契约自动解析驱动根**。新增 `resolveNvidiaDriverRoot`:当配置为字面量 `"auto"` 时读 `/run/nvidia/validations/driver-ready`,契约不存在则判定为非 GPU Operator 部署、回落到宿主根 `/`;存在则从中读出 driverRoot/devRoot。让同一份 device-plugin 部署既能跑在 GPU Operator 管理的驱动容器里、也能跑在宿主机装驱动的节点上,无需人工区分。
  <details><summary>代码依据 cmd/device-plugin/nvidia/main.go</summary>

  ```diff
  +const ( autoNvidiaDriverRoot = "auto"; hostNvidiaDriverRoot = "/" )
  +var gpuOperatorDriverReadyFile = "/run/nvidia/validations/driver-ready"
  +func resolveNvidiaDriverRoot(config *spec.Config) error {
  +	if config.Flags.NvidiaDriverRoot == nil || *config.Flags.NvidiaDriverRoot != autoNvidiaDriverRoot { return nil }
  +	driverRoot, devRoot, err := readGPUOperatorDriverRoots(gpuOperatorDriverReadyFile)
  +	if err != nil {
  +		if !os.IsNotExist(err) { return err }
  +		driverRoot = hostNvidiaDriverRoot; devRoot = hostNvidiaDriverRoot
  +	}
  ```
  </details>
- **NUMA refit 改用 phase-aware 计账,修 init 容器双计数**。原 `releaseContainerUsage`(简单减掉自身预留)被 `preparePhaseAwareRefitUsage` + `effectivePodDeviceUsage`/`effectiveUsageOnCandidate` 取代:对非 sidecar 的 init 容器按 `max(init, app)` 而非 `init+app` 计,且按 UUID 过滤后逐候选卡评估,避免对每个候选都复制/collapse 整个 pod 分配。
  <details><summary>代码依据 pkg/scheduler/numa_refit_handler.go</summary>

  ```diff
  -	// release it so capacity checks do not double count the pod against itself.
  -	releaseContainerUsage(nodeUsage, current)
  +	// Prepare each allowed candidate so adding the moved container produces the same
  +	// effective usage as normal scheduling (for example max(init, app), not init+app...).
  +	preparePhaseAwareRefitUsage(nodeUsage, pod, pi.Devices, allocated, req.DeviceType, req.ContainerIndex, current[0].Usedmem, current[0].Usedcores, allowed, pi.InitContainerResourceReleased)
  ...
  -		effective := device.CollapseInitContainerUsage(pod, rawDevices)
  -		if pi.InitContainerResourceReleased { effective = device.SteadyStateDeviceUsage(pod, rawDevices) }
  +		effective := effectivePodDeviceUsage(pod, rawDevices, pi.InitContainerResourceReleased)
  ```
  </details>
- **其余零散**:新增 MIG E2E(`hack/e2e-mig-smoke-test.sh`、`e2e-mig-test.sh`、`call-e2e-mig.yaml` 走 `nvidia.com/vgpu-mode: mig` 注解拉起 MIG 冒烟);ascend 910C 模块配对分配加 SuperPod 门槛(#2853)、admission 防空 `ResourceMemoryName` 注入(#2889);scheduler 设备不足经 `GenReason` 上报(#2881);chart 暴露 scheduler `kube-qps/kube-burst/kube-timeout`(#2905)、把 IMEX channel 透传进 NVIDIA plugin(#2892)。均以测试/配置为主,未改软切分核心语义。

### 后续发展方向 [AI]
- 主仓这一轮是**生产健壮性收口**:去 panic、启动期 fail-fast、指标服务器可观测化、驱动根自适应——都指向"HAMi 要在 GPU Operator 与裸机混合环境里稳定托管"。证据覆盖 device-plugin/vGPUmonitor 启动与注册路径,未见对调度打分/显存切分算法的改动。
- MIG 路径正在补 E2E(冒烟 + 完整矩阵分离),说明 MIG 模式(硬切分)与 vGPU 软切分并行维护;证据只到 e2e 脚本与 workflow,未见 MIG 分配逻辑本身的 diff。

## Project-HAMi/volcano-vgpu-device-plugin: 32162c65 -> cbded47b
- 比较 / 最新 Release:https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/32162c65...cbded47b (无 Release)

### AI 总结重点(源码 diff 为据)
- **新增 `CUDA_DISABLE_CONTROL_DP` 环境变量,置位即跳过 `/etc/ld.so.preload` 注入**。`Allocate` 里原本只有在容器已自带 preload(`found`)时才不追加 HAMi 的 `ld.so.preload` 挂载;新增分支:未找到但 `CUDA_DISABLE_CONTROL_DP` 非空时强制 `found=true`,从而不注入 preload——等于关掉 HAMi-core 的 CUDA hook(显存/算力限额),让 Volcano 路径能按 workload 粒度退回"不软切分、直通物理卡"。
  <details><summary>代码依据 pkg/plugin/server.go</summary>

  ```diff
   				}
  +
  +				if !found && os.Getenv("CUDA_DISABLE_CONTROL_DP") != "" {
  +					found = true
  +				}
  +
   				if !found {
   					response.Mounts = append(response.Mounts, &pluginapi.Mount{ContainerPath: "/etc/ld.so.preload",
   						HostPath: hostHookPath + "/ld.so.preload",
  ```
  </details>

### 后续发展方向 [AI]
- Volcano 集成路径开始提供"软切分逃生阀":同一 device-plugin 既能软隔离、也能通过环境变量整卡直通,契合 HAMi-core 里 `CUDA_DISABLE_CONTROL` 语义。证据仅这一处 env 分支,未见对应的调度侧(Volcano predicate)是否感知该模式的改动——直通后配额记账是否一致存疑。

## Project-HAMi/HAMi-WebUI: 01333fb2 -> f6ae9160 (v1.3.0)
- 比较 / 最新 Release:https://github.com/Project-HAMi/HAMi-WebUI/compare/01333fb2...f6ae9160 (Release v1.3.0,未跨档)

### AI 总结重点(源码 diff 为据)
- **Chart 2 单镜像运行时提案定稿(status: accepted)**。新增 `docs/proposals/chart-2-single-image.md`:Go 应用进程 in-process 服务已构建的 Vue 静态资源 + 调 API handler,生产镜像只需一个 `projecthami/hami-webui`、一个容器(Node.js 仅留构建/测试);两个 HTTP 监听——3000 是浏览器 SPA + `/api/vgpu/v1/*` 入口,8000 是内部 readiness/metrics/诊断口(非鉴权边界、非公开 API);主 Service 只暴露 3000。明确不改 RBAC/NetworkPolicy/外部认证/iframe 策略。
  <details><summary>代码依据 docs/proposals/chart-2-single-image.md</summary>

  ```diff
  +# Chart 2 Single-Image Runtime
  +status: accepted
  +Chart 2 deploys one `projecthami/hami-webui` image and one container. The process
  +keeps two HTTP listeners with different exposure:
  +- port `3000` is the supported browser entry for the SPA and `/api/vgpu/v1/*`;
  +- port `8000` is the internal readiness, metrics, and diagnostics listener...
  +The primary Service exposes only port `3000`.
  ```
  </details>
- **破坏性 chart 契约:Chart 1.x 嵌套 values 被 fail-closed 拒绝**。提案记:Chart 1.x 的嵌套 image/resource/env/probe/proxy/gRPC/legacyBackendPort 值不再被静默忽略而是直接 reject,运维必须新建 Chart 2 values 文件并 `--reset-values` 升级;回滚只支持 `helm rollback` 回 Chart 1.3。`web-entry-and-embedding.md` 同步从 proposed→accepted,把 Chart 1.x Gateway 降级为"历史兼容桥",`legacyBackendPort` 兼容口定于 Chart 2.0.0 移除。
  <details><summary>代码依据 docs/proposals/web-entry-and-embedding.md</summary>

  ```diff
  -status: proposed
  +status: accepted
  -A single Go application image is deferred to Chart version 2.0.0...
  +Chart 2 completes the transition with one Go application image and one
  +container, as recorded in [`chart-2-single-image.md`](chart-2-single-image.md).
  ```
  </details>
- **proto 层给算力用量补"已知/未知"标志位**。`node.proto` 的 `DeviceSummaryReply`/`NodeReply`、`card.proto` 的 `GPUReply`、`container.proto` 的 `ContainerReply` 各新增 `optional bool ..._known` 字段(`core_used_known`/`allocated_cores_known`),在 API 层把"算力占用真为 0"与"底层遥测缺失导致未知"区分开——配合本期一串 `fix(metrics): preserve missing/unknown ...` 提交,解决前端把"没数据"错渲成"0 占用"。
  <details><summary>代码依据 server/api/v1/node.proto</summary>

  ```diff
   message DeviceSummaryReply {
     int32 node_count = 8;
  +  optional bool core_used_known = 9;
   }
   message NodeReply {
     string creation_timestamp = 21;
  +  optional bool core_used_known = 22;
   }
  ```
  </details>
- **大规模死代码清除**:删掉 `views/dashboard/index.vue`(-9596 行)、无用 mock fixture、不可达的 legacy 前端 island / view shell / chart option builder / 共享 utils(#239–#243),`utils/index.js` 从 555 行删到几乎空。配合 Chart 2 单镜像,前端在往"只留可达路径 + Go 统一托管"收敛。
  <details><summary>代码依据 packages/web/src/utils/index.js</summary>

  ```diff
  -import { isFunction } from 'lodash';
  -import { ElMessage } from 'element-plus';
  -export function parseTime(time, cFormat) { ... }
  -export function formatTime(time, option) { ... }
  (整文件从 366+ 行工具函数删到仅剩 3 行)
  ```
  </details>
- **其余**:`fix: secure external Prometheus authentication`(#236)+ `require explicit Prometheus setup`(#231)让 chart 在 Prometheus 未配置时 fail-closed 报可操作错误而非瞎猜后端;一串 `fix(metrics)`(#256–#268)校正 vendor 遥测查询、XID 命名、风扇遥测能力探测、物理算力容量稳定化、workload 分配排名去重;`fix(ascend): decode variant allocation contracts`(#237)解析昇腾变体分配契约。

### 后续发展方向 [AI]
- WebUI 的部署形态在 Chart 2 正式收敛为**单 Go 镜像 / 单容器 / 只读单集群视图**,认证/多集群/iframe 策略明确划到范围外——与上一期结论一致:企业多集群纳管与鉴权要由外层平台承接。证据到提案与 proto/chart 骨架,未逐一验证 Go 进程的路由与静态资源服务实现。
- 8-30 起的 metrics 口径整改在本期基本收口:从"改 PromQL"上升到"在 proto 契约里显式建模 known/unknown",数据正确性问题被固化进 API schema。证据覆盖三个 proto 文件的字段新增,各 PromQL 前后差异未逐条展开。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=e6932f52b16d3358ef9ac47cd63b73bdbda04714 branch=master release=v2.10.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-02 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-02 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-02 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-02 -->
</content>
