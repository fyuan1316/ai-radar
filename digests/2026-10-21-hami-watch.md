# HAMi diff 雷达 2026-10-21

## 摘要
- **HAMi-core 新增"宿主 PID broker + 节点级 fallback 锁"子系统**(新增 `src/hostpid_broker.c`/`hostpid_fallback_lock.c` 共 ~1000 行):新版 NVIDIA 驱动把进程 PID 按调用方命名空间上报(非宿主 PID),导致显存记账对不上账;新机制让 libvgpu 通过 Unix socket 向可信 broker 直接问宿主 PID、或退回带死进程自愈的 flock 串行 NVML 探测。这是软隔离核心在 PID 命名空间场景下的正确性修复 + 新能力。
- **ascend-device-plugin 落地 hami-core 的 spatial 算力调度**(PR #145):新增 `vnpus.hamiCorePolicy`(spatial/dynamic/fixed/overdraft,默认 spatial)配置字段与 `huawei.com/npu-sched-policy` 注解,把调度配额改经 `NPU_MEMORY_LIMIT_MB`/`NPU_COMPUTE_LIMIT`/`NPU_SCHED_POLICY` 传给运行库,**旧 `NPU_MEM_QUOTA`/`NPU_PRIORITY` 被新库拒收**——配套依赖锁定版 hami-vnpu-core `b19ef02`,属破坏性运行时契约变更。这是昨天主仓 `deviceSplitCount` 改名之后昇腾 vNPU 软切分的消费端实现。
- **HAMi 主仓 RemoteGPU 增加按节点标签选 Lupine 服务器**(PR #3195):新注解 `hami.io/remote-server` 让远端 GPU Pod 精确匹配某标签的服务器池,并在 bind 阶段二次校验;另给远端客户端注入 `nvidia-smi`(PR #3278)、新增脱敏诊断包采集脚本(PR #3149)。

## 当日重要改变
- Project-HAMi/HAMi-core [新能力] 新增独立 host PID broker + fallback lock 两个顶层源文件,解决新版 NVIDIA 驱动按命名空间上报 PID 导致的显存记账错位;broker 走 `/tmp/vgpulock/hostpid/broker.sock` 直问宿主 PID,失败退回节点级 flock 串行探测。证据:src/hostpid_broker.c、src/hostpid_fallback_lock.c、src/libvgpu.c、src/utils.c,PR https://github.com/Project-HAMi/HAMi-core/pull/354
- Project-HAMi/ascend-device-plugin [新能力][API/CRD变更][弃用/移除] 新增 `vnpus.hamiCorePolicy` 配置字段 + `huawei.com/npu-sched-policy` 注解,hami-core 默认走 spatial(CANN Cube/Vector 协作式核预算);Allocate 改注入 `NPU_MEMORY_LIMIT_MB`/`NPU_COMPUTE_LIMIT`/`NPU_SCHED_POLICY`,旧 `NPU_MEM_QUOTA`/`NPU_PRIORITY` 被新库拒收,需配锁定版 hami-vnpu-core b19ef02。证据:internal/vnpu.go、internal/server/hami.go、internal/server/allocate.go,提交 https://github.com/Project-HAMi/ascend-device-plugin/commit/9be910ab1f1e (PR https://github.com/Project-HAMi/ascend-device-plugin/pull/145)
- Project-HAMi/HAMi [新能力] RemoteGPU 新增 `hami.io/remote-server` 注解,按单个精确节点标签把 Pod 限定到特定 Lupine 服务器池,并在 Bind 阶段二次校验选择器仍匹配。证据:pkg/device/remotegpu/device.go、pkg/device/remotegpu/pool.go、pkg/scheduler/scheduler.go,PR https://github.com/Project-HAMi/HAMi/pull/3195

## Project-HAMi/HAMi-core: a55248ec -> 3f6134c1
- 比较 https://github.com/Project-HAMi/HAMi-core/compare/a55248ecc6e2530602875054e2d334645d08f35b...3f6134c14946b46459a0808e0366e97541ed102a | ahead=39 | files=18 | 最新 Release —

### AI 总结重点(源码 diff 为据)
- **新增显存记账的"宿主 PID broker"客户端**(PR #354 中 commit 79d9baf):新文件 `src/hostpid_broker.c`(+480)实现一个自定义二进制协议(magic `HPID`、协议版本 1、命令 `GET_PID`、请求 8 字节/响应 12 字节),通过 Unix socket `/tmp/vgpulock/hostpid/broker.sock` 向一个可信服务端直接取本进程的宿主 PID,**完全绕开 NVML discovery**。`hostpid_broker_query_trusted` 要求固定 socket 路径、root 属主、只读的直属目录、且对端 UID 0(Linux 下用 SO_PEERCRED 校验),不满足就不发请求。
  <details><summary>代码依据 src/include/hostpid_broker.h</summary>

  ```diff
  +#define HOSTPID_BROKER_SOCKET_PATH "/tmp/vgpulock/hostpid/broker.sock"
  +int hostpid_broker_enabled(const char *value);
  +/* Requires the fixed socket path, root ownership, a read-only immediate
  + * directory and a connected server with UID 0. No request is sent unless
  + * those checks pass. Peer credentials are currently supported only on Linux. */
  +int hostpid_broker_query_trusted(const char *socket_path, pid_t *host_pid);
  ```
  </details>
- **GPU 初始化路由改造:broker 优先,fallback 锁兜底**(commit 7ac764a「use broker during gpu init」):`postInit()` 原来只有"进程死亡安全的共享文件锁 → set_task_pid()"一条路径;现按环境变量 `LIBVGPU_HOSTPID_BROKER=1` 分叉——开启则先 `set_task_pid_from_broker()`,仅当返回 `NVML_ERROR_UNKNOWN` 才取节点级 fallback 锁再退回 NVML 探测(NVML 无法修复缺失的共享槽位,所以只重试查询失败);未开启则保持旧共享文件锁路径。
  <details><summary>代码依据 src/libvgpu.c postInit()</summary>

  ```diff
  -    // Use the process-death-safe shared file lock to serialize host PID detection
  -    int lock_acquired = lock_postinit();
  -    nvmlReturn_t res = NVML_SUCCESS;
  -    if (lock_acquired) {
  -        res = set_task_pid();
  -        unlock_postinit();
  +    int broker_enabled = hostpid_broker_enabled(getenv("LIBVGPU_HOSTPID_BROKER"));
  +    nvmlReturn_t res;
  +    if (broker_enabled) {
  +        res = set_task_pid_from_broker();
  +        if (res == NVML_ERROR_UNKNOWN) {
  +            // Always take the node-wide fallback lock before the cache lock.
  +            if (hostpid_fallback_lock_acquire_until(&deadline) == 0) {
  +                int lock_acquired = lock_postinit();
  +                if (lock_acquired) { res = set_task_pid(); unlock_postinit(); }
  ```
  </details>
- **显存查询优先用宿主 PID、回退 getpid()**(utils.c 新增 `get_used_gpu_memory_by_pid`):新版驱动把 `nvmlDeviceGetComputeRunningProcesses` 里的 `pid` 上报为调用方自己命名空间的 PID 而非宿主 PID,故遍历时先匹配传入的 `hostpid`,匹配不到再用本进程 `getpid()` 兜底,都没有才 `NVML_ERROR_NOT_FOUND`。这是显存记账在 PID 命名空间下对不上账的直接修复(fix(utils)/fix(watcher) 两 commit)。
  <details><summary>代码依据 src/utils.c</summary>

  ```diff
  +        // Newer drivers report the caller's own-namespace PID instead of the
  +        // host PID, so prefer the host PID and fall back to getpid().
  +        for (i = 0; i < count; i++) {
  +            if (processes[i].pid == (unsigned int)hostpid) { match = &processes[i]; break; }
  +            if (self == NULL && processes[i].pid == (unsigned int)getpid()) self = &processes[i];
  +        }
  +        if (match == NULL) match = self;
  ```
  </details>
- **新增节点级 fallback 锁,带死进程自愈 + 文件系统/属主信任校验**(commit 465f823):新文件 `src/hostpid_fallback_lock.c`(+584),锁路径 `/tmp/vgpulock/hostpid`,默认超时 30s,基于 `CLOCK_MONOTONIC` 算 deadline + `flock`;并有一条 commit「stop dropping zfs and overlayfs from the allowed filesystems」放宽了锁对象允许的文件系统类型(容器常见 overlayfs 场景)。头文件注释明确:一进程一锁、同进程重入返回 EDEADLK、不支持并发调用与线程取消,锁目录须在只读挂载、root 属主。
  <details><summary>代码依据 src/include/hostpid_fallback_lock.h</summary>

  ```diff
  +#define HOSTPID_FALLBACK_LOCK_PATH "/tmp/vgpulock/hostpid"
  +#define HOSTPID_FALLBACK_LOCK_TIMEOUT_MS 30000U
  +/* ... The lock directory must sit on a read-only mount, owned by root with
  + * root-owned ancestors, on a supported filesystem. */
  +int hostpid_fallback_lock_acquire_until(const struct timespec *deadline);
  +/* Broker context sizing may overlap other sizing calls, but never an
  + * exclusive NVML PID-discovery window. */
  +int hostpid_fallback_lock_acquire_shared_until(const struct timespec *deadline);
  ```
  </details>

### 后续发展方向 [AI]
- HAMi-core 正在把"宿主 PID 识别"从"纯 NVML 探测 + 共享文件锁"演进为"外部 broker 直供 + NVML 兜底"的双轨架构,根因是新版 NVIDIA 驱动改了 PID 命名空间上报语义。对我们产品的启示:**容器内 GPU 显存软隔离依赖宿主 PID 正确解析,驱动升级会打破旧假设**;若自研软切分同样靠 NVML running-processes 记账,需验证新驱动下的 PID 来源,并考虑 broker 这类带信任边界(root 属主/只读挂载/SO_PEERCRED)的旁路。证据覆盖 broker 协议头、postInit 路由、utils 匹配逻辑与 fallback 锁头文件;broker **服务端**实现未在本仓 diff 出现(客户端注释称"a connected server with UID 0"),其部署形态与 vGPU operator/device-plugin 的集成方式未见,属证据空白。
- broker 默认关闭(需 `LIBVGPU_HOSTPID_BROKER=1` 显式开),说明仍是实验/渐进引入阶段,未成默认路径;fallback 锁放宽 overlayfs/zfs 暗示目标运行环境是标准容器 rootfs。未见该能力与上层 device-plugin 的联动,无法判断是否已进入发布路径。

## Project-HAMi/ascend-device-plugin: 74d8d109 -> cfb45bc0
- 比较 https://github.com/Project-HAMi/ascend-device-plugin/compare/74d8d109c40cb70ba0d2881af3b807aef9984fc6...cfb45bc037af17bf50834ecf885e720684ec8cea | ahead=3 | files=23 | 最新 Release ascend-device-plugin-0.2.0

### AI 总结重点(源码 diff 为据)
- **新增 hami-core 算力调度策略字段 `hamiCorePolicy`**(internal/vnpu.go):`VNPUsConfig` 与 `NodeConfig` 两个结构体都加了 `HamiCorePolicy string` 字段;新函数 `ResolveHamiCorePolicy` 校验取值只能是 `spatial/dynamic/fixed/overdraft`(空值默认 `spatial`),并在 `LoadConfig`/`LoadNodeConfig` 两处做校验。这是昨天主仓把 `vnpuDeviceSplitCount` 改名为 `deviceSplitCount` 之后,昇腾插件侧消费新 vNPU 配置模型并扩展算力策略的落地。
  <details><summary>代码依据 internal/vnpu.go</summary>

  ```diff
   type VNPUsConfig struct {
  -	HamiVnpuMode string `json:"hamiVnpuMode,omitempty"`
  -	EnpuPolicy   string `json:"enpuPolicy,omitempty"`
  +	HamiVnpuMode   string `json:"hamiVnpuMode,omitempty"`
  +	EnpuPolicy     string `json:"enpuPolicy,omitempty"`
  +	HamiCorePolicy string `json:"hamiCorePolicy,omitempty" yaml:"hamiCorePolicy,omitempty"`
   	DeviceSplitCount int `json:"deviceSplitCount"`
  +// ResolveHamiCorePolicy validates the runtime policy and defaults to spatial.
  +func ResolveHamiCorePolicy(value string) (string, error) {
  +	switch normalized := strings.ToLower(strings.TrimSpace(value)); normalized {
  +	case "": return "spatial", nil
  +	case "dynamic", "fixed", "overdraft", "spatial": return normalized, nil
  +	default: return "", fmt.Errorf("hamiCorePolicy must be dynamic, fixed, overdraft, or spatial, got %q", value)
  ```
  </details>
- **破坏性运行时契约变更:Allocate 换一套配额环境变量**(internal/server/allocate.go,−74 行):旧逻辑在 `effectiveHamiCore` 分支里硬编码注入一堆 mount(npu-smi/driver/ld.so.preload/hami-shared-region)并设 `NPU_MEM_QUOTA`/`NPU_PRIORITY` 两个 env;本次整段删除,改由新路径注入 `NPU_MEMORY_LIMIT_MB`/`NPU_COMPUTE_LIMIT`/`NPU_SCHED_POLICY`。README 明确新库会**拒收** `NPU_MEM_QUOTA`/`NPU_PRIORITY`/`NPU_FIXED_SHARE_RATIO`,必须配锁定版 hami-vnpu-core `b19ef02`,且替换节点库前要停掉 hami-core 业务。
  <details><summary>代码依据 internal/server/allocate.go(删除旧 env 注入)</summary>

  ```diff
  -		// Set NPU_MEM_QUOTA
  -		if len(memories) > 0 && memories[0] != nil {
  -			resp.Envs["NPU_MEM_QUOTA"] = strconv.FormatInt(*memories[0], 10)
  -		// Set NPU_PRIORITY
  -		if len(cores) > 0 && cores[0] != nil {
  -			resp.Envs["NPU_PRIORITY"] = strconv.FormatInt(int64(*cores[0]), 10)
  ```
  </details>
  <details><summary>代码依据 charts/ascend-device-plugin/README.md(新变量 + 弃用说明)</summary>

  ```text
  The plugin injects `NPU_MEMORY_LIMIT_MB`, `NPU_COMPUTE_LIMIT`, and
  `NPU_SCHED_POLICY`. ...
  Deploy this plugin together with its pinned hami-vnpu-core `b19ef02` assets;
  older libraries do not understand these variables, and the new library rejects
  `NPU_MEM_QUOTA` / `NPU_PRIORITY`.
  ```
  </details>
- **spatial 为默认策略 + 多卡显存配额聚合语义**(新文件 internal/server/hami.go +138):新增 `hamiCorePolicy(pod)` 解析(Pod 注解 `huawei.com/npu-sched-policy` > 节点 `hamiCorePolicy` > 全局 `vnpus.hamiCorePolicy` > 默认 spatial);`hamiCoreQuota` 把 HAMi 按卡下发的显存配额**相加为容器级单一 HBM 记账上限**(并做 int64/u64 溢出检查),注释点明"单一 compute 设置作用于所有选中设备,无法表达异构算力配额"——即多卡要求每卡算力配额一致。spatial 的语义是 CANN Cube/Vector 核的协作式预算(各自向上取整,如 20C/40V 的 31% → 7/13),非独占硬件分区。
  <details><summary>代码依据 internal/server/hami.go</summary>

  ```diff
  +const HamiCorePolicyAnnotation = "huawei.com/npu-sched-policy"
  +// HAMi annotates memory per selected card. The core has one container-wide HBM
  +// ledger, so aggregate those reservations. Its single compute setting applies
  +// to every selected device and cannot represent heterogeneous compute quotas.
  +func (ps *PluginServer) hamiCoreQuota(devices device.ContainerDevices, lookup map[string]RuntimeInfo) (int64, int32, error) {
  +		memoryLimit += memory
  +		if uint64(memoryLimit) > math.MaxUint64/(1024*1024) { ... overflows runtime byte count }
  ```
  </details>
- **核文件安装改为原子 rename、目录与 Allocate 对齐**(internal/server/util.go):`copyFile` 从"直接 `os.Create` 目标文件写入"改为"先写临时文件 `.tmp-*` → Chmod → Sync → Close → `os.Rename`",避免替换时截断正在被 mmap 的库;`prepareHostResources` 的安装目录从写死的 `/usr/local/hami-vnpu-core` 改为 `hostHookPath`(与 Allocate 用同一目录,且强制绝对路径)。
  <details><summary>代码依据 internal/server/util.go</summary>

  ```diff
  -// A standard file copy implementation that preserves the original file permissions
  +// Install by rename so an existing mapped library is never truncated in place.
  -	dstFile, err := os.Create(dst)
  +	staged, err := os.CreateTemp(filepath.Dir(dst), "."+filepath.Base(dst)+".tmp-*")
  +	return os.Rename(staged.Name(), dst)
  -	targetDir := "/usr/local/hami-vnpu-core"
  +	targetDir := hostHookPath
  +	if !filepath.IsAbs(targetDir) { return fmt.Errorf("HOOK_PATH must be absolute, got %q", targetDir) }
  ```
  </details>

### 后续发展方向 [AI]
- 昇腾 vNPU 软切分(hami-core 后端)正从"单一显存/优先级"进化到"四档算力策略(spatial/dynamic/fixed/overdraft)+ 容器级 HBM 聚合记账",且默认切到 spatial(协作式 CANN 核预算)。对我们产品的启示:**对标昇腾 vNPU 纳管时,算力隔离已非简单时分,而是区分空间/时间两类机制**,配置契约(`vnpus.hamiCorePolicy` + `huawei.com/npu-sched-policy` 三级覆盖)与运行时 env(`NPU_*_LIMIT`)需整套跟踪;且本次是**破坏性升级**——插件与 hami-vnpu-core 库版本强绑定(b19ef02),升级需停机换库,这对企业级灰度/回滚是硬约束。证据覆盖 vnpu.go 字段/校验、allocate.go 的 env 删改、hami.go 配额聚合、util.go 原子安装;spatial 在 CANN 侧如何映射到 Cube/Vector 核的**运行库实现**不在本仓(在 hami-vnpu-core b19ef02 二进制),未见源码。
- `hamiCorePolicy` 四策略语义(spatial=空间协作预算、dynamic=相对时分可借用、fixed=运行/休眠比、overdraft=空闲有界借用)已在 docs/hami.md 定义,但 diff 里只见插件侧的"选择与传参",策略的实际执行在运行库;无法从本次 diff 判断各策略的隔离强度与 QoS 保证,需单独验证。

## Project-HAMi/HAMi: 84c75baf -> 228a3313
- 比较 https://github.com/Project-HAMi/HAMi/compare/84c75baf89b2bec4fd11660126ad2660b9d957f2...228a331334aca19395e54e5f44980755212a266c | ahead=6 | files=25 | 最新 Release v2.10.0

### AI 总结重点(源码 diff 为据)
- **RemoteGPU 新增按节点标签精选 Lupine 服务器**(PR #3195):新注解 `hami.io/remote-server`(常量 `LupineServerSelectorAnno`)让远端 GPU Pod 只落到带某个精确节点标签(如 `gpu-pool=inference`)的 Lupine 服务器;它选的是**远端服务器**而非客户端节点。`pool` 结构体新增 `serverLabels map[string]labels.Set`(刷新时与 endpoints 同快照),`Fit()` 先解析 selector 再用 `matchingServers(selector, ...)` 过滤候选,无匹配返回新错误 `errNoMatchingLupineServer`。
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
  +	// LupineServerSelectorAnno optionally limits a RemoteGPU pod to Lupine
  +	// servers with one exact Node-label match, for example "gpu-pool=inference".
  +	LupineServerSelectorAnno = "hami.io/remote-server"
  +	errNoMatchingLupineServer = errors.New("no Lupine server matches " + LupineServerSelectorAnno)
  +	selector, err := lupineServerSelector(pod)
  +	servers = dev.pool.matchingServers(selector, servers)
  +	if selector != nil && len(servers) == 0 {
  +		return false, map[string]device.ContainerDevices{}, errNoMatchingLupineServer.Error()
  ```
  </details>
- **Bind 阶段二次校验选择器仍匹配**(pkg/scheduler/scheduler.go):Filter 做出预留后,池刷新/服务器标签变更可能让 selector 不再匹配;`Bind()` 新增在 fail 可用之后调用 `remote.ValidateReservedServer(current, pi.Devices)`,不匹配则 `fail(err)` 释放短时预留。`verifyBindTarget` 也补了"带 selector 的 RemoteGPU pod 若无调度预留则拒绝 bind"。
  <details><summary>代码依据 pkg/scheduler/scheduler.go Bind()</summary>

  ```diff
  +	// A RemoteGPU selector can stop matching after Filter has made a
  +	// reservation (for example, following a pool refresh after a server label change).
  +	if pi, reserved := s.podManager.GetPod(current); reserved {
  +		if remote, ok := device.GetDevices()[remotegpu.RemoteGPUCommonWord].(*remotegpu.RemoteGPUDevices); ok {
  +			if err := remote.ValidateReservedServer(current, pi.Devices); err != nil {
  +				return fail(err)
  ```
  </details>
- **远端客户端注入 `nvidia-smi` 包装器**(PR #3278,client.go):给无本地驱动的远端 GPU 客户端挂载一个 `/usr/bin/nvidia-smi` wrapper——它设 `LD_LIBRARY_PATH=/opt/lupine/lib` 后 exec 真正的 nvidia-smi,使之加载 Lupine 的 NVML shim,而不污染 workload 自身的库搜索路径;交付脚本新增 `install_nvidia_smi`,客户端镜像缺 nvidia-smi 则交付失败。
  <details><summary>代码依据 pkg/device/remotegpu/client.go</summary>

  ```diff
  +const clientSMIWrapper = "#!/bin/sh\nLD_LIBRARY_PATH=" + clientMountPath + "${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH} exec " + clientMountPath + "/" + clientSMIBinaryName + " \"$@\"\n"
  +install_nvidia_smi() {
  +    ... cp -L "$smi" "$target/nvidia-smi"; chmod 755 ...
  +	mounts = append(mounts, corev1.VolumeMount{Name: clientVolumeName, MountPath: clientSMIMountPath, SubPath: clientSMIWrapperName, ReadOnly: true})
  ```
  </details>
- **新增脱敏诊断包采集脚本**(PR #3149):新文件 `hack/hami-support-bundle.sh`(+620)+ 测试(+441),按 namespace/node/pod/cluster-wide 采集 HAMi 组件日志,带大小上限(单采集器 4MiB、整包 64MiB)、脱敏模式(`--redact-pattern`)、`--dry-run`。纯运维工具,不改运行时能力;是商业化/可运维性信号。
  <details><summary>代码依据 hack/hami-support-bundle.sh</summary>

  ```bash
  Usage: hami-support-bundle.sh --kubeconfig FILE --context NAME --namespace NAME
    [--workload-namespace NAME] [--node NAME | --pod NAME | --cluster-wide]
    [--since DURATION] [--tail-lines N] [--output-dir DIR] [--redact-pattern TEXT] [--dry-run]
  ```
  </details>
- **多设备 helm-docs 注释 + chart values 文档收尾**(PR #3259/#3277):charts/hami/values.yaml 与 README 大量补充 metax/hygon/cambricon/awsneuron/kunlun/enflame 各家资源名字段的 helm-docs 注释(资源名语义、取值范围、与 vendor 插件匹配要求)。纯文档,无代码行为变化。

### 后续发展方向 [AI]
- RemoteGPU(跨节点用他机 GPU,基于 Lupine)在快速补企业级可运维能力:标签亲和选服务器池 + bind 时一致性二次校验 + 客户端 nvidia-smi 可观测。对我们产品的启示:HAMi 的"远程 GPU 池化"路线正在成形(客户端无驱动、库注入、按池调度),是与"本机软切分"并行的另一条资源利用率路径,值得评估其与我们池化方案的差异。证据覆盖 device.go/pool.go/scheduler.go 的 selector 与 bind 校验、client.go 的 smi 注入;Lupine 服务端协议与性能开销不在本仓,未见。
- 诊断包脚本 + 全家族 values 文档收尾,指向 v2.10.x 在补产品化/可支持性短板(非新调度能力)。证据只覆盖脚本与 values 注释,无运行时代码改动。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- Project-HAMi/volcano-vgpu-device-plugin:无新提交(锚点未动)
- Project-HAMi/HAMi-WebUI:无新提交(锚点未动,Release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=228a331334aca19395e54e5f44980755212a266c branch=master release=v2.10.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=3f6134c14946b46459a0808e0366e97541ed102a branch=main release=— scanned=2026-10-21 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-21 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=cfb45bc037af17bf50834ecf885e720684ec8cea branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-21 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-21 -->
</content>
</invoke>
