# HAMi diff 雷达 2026-10-23

## 摘要
- **Ascend vNPU 记账模型转向**:`ascend-device-plugin` 把软切显存从"容器级 HBM 总账(各卡配额求和)"改成"逐卡独立配额"——多卡必须配额相同、不等则拒绝,`NPU_MEMORY_LIMIT_MB` 由累加改为单卡值;SHM 路径与首卡解绑(core 自己按 `.device-<physicalID>` 追加)。这是本家国产卡软切语义的一次实质变更。
- **HAMi-core 修软隔离的进程归属正确性**:`set_task_pid()` 重写为"多探针共识 + 退避"的 host PID 发现,防止容器误取他进程的 host PID(误取会污染共享区显存记账与进程清理);同时移除独立 `shrreg-tool` 工具。
- **HAMi 主仓给 MIG 分配加校验**:新增 `validateMigAllocation`,拿节点已注册的 profile 兜底,防止伪造分配注解拿到未经调度确认的 MIG 切片。

## 当日重要改变
- Project-HAMi/ascend-device-plugin [架构方向][新能力] vNPU 软切记账从"聚合总账"改"逐卡独立配额",并新增逐卡 Prometheus 监控域。证据 `internal/server/hami.go` / `internal/monitor/*`。https://github.com/Project-HAMi/ascend-device-plugin/pull/147
- Project-HAMi/HAMi-core [弃用/移除] 删除独立 `shrreg-tool` 调试工具(`src/multiprocess/shrreg_tool.c`,-86 行)。https://github.com/Project-HAMi/HAMi-core/pull/366

## Project-HAMi/ascend-device-plugin: cfb45bc0 -> ab41bec3
- 比较 https://github.com/Project-HAMi/ascend-device-plugin/compare/cfb45bc037af17bf50834ecf885e720684ec8cea...ab41bec367ca95ac52ed1bcb8667c33e689f8f37 | Release ascend-device-plugin-0.2.0(与上期同,非跨档)
### AI 总结重点(源码 diff 为据)
- **多卡显存配额从"求和"改为"逐卡独立、且必须相等"**。`hamiCoreQuota` 原来把每张卡的 memory `+=` 累加成一个容器级总账(还带 int64/u64 溢出检查),现在改为:若各卡配额不等直接报错拒绝,memory 取单卡值写入 `NPU_MEMORY_LIMIT_MB`。注释也从"core 只有一个容器级 HBM 总账,所以聚合"改成"core 把标量 memory/compute 独立作用到每张选中卡"。语义上这是把"整容器一个 HBM 上限"变成"每卡各自一个上限"。

  <details><summary>代码依据 internal/server/hami.go</summary>

  ```diff
  -// HAMi annotates memory per selected card. The core has one container-wide HBM
  -// ledger, so aggregate those reservations. Its single compute setting applies
  -// to every selected device and cannot represent heterogeneous compute quotas.
  +// The core applies its scalar memory and compute settings independently to
  +// every selected card, so heterogeneous per-card quotas cannot be represented.
   func (ps *PluginServer) hamiCoreQuota(...) (int64, int32, error) {
  -		if memory > math.MaxInt64-memoryLimit {
  -			return 0, 0, fmt.Errorf("combined HAMi memory quota overflows int64")
  -		}
  -		memoryLimit += memory
  -		if uint64(memoryLimit) > math.MaxUint64/(1024*1024) {
  -			return 0, 0, fmt.Errorf("combined HAMi memory quota overflows runtime byte count")
  +		if uint64(memory) > math.MaxUint64/(1024*1024) {
  +			return 0, 0, fmt.Errorf("HAMi memory quota for %s overflows runtime byte count", allocation.UUID)
  +		}
  +		if memoryLimit != 0 && memoryLimit != memory {
  +			return 0, 0, fmt.Errorf("HAMi core requires the same memory quota on every device: got %d and %d MiB", memoryLimit, memory)
   		}
  +		memoryLimit = memory
  ```
  </details>

- **全局 SHM 路径与"首卡物理 ID"解绑**。原来 `NPU_GLOBAL_SHM_PATH` 把 `devices[0]` 的 PhyID 拼进路径(`/hami-shared-region/<phyID>_global_registry`),导致路径随所选卡顺序而变;现在固定为中性基址 `/hami-shared-region/global_registry`,由 core 运行时自己追加 `.device-<physicalID>`。这解决了"同一组卡但分配顺序不同 → 落到不同 SHM 域"的问题。

  <details><summary>代码依据 internal/server/hami.go</summary>

  ```diff
  -	physicalID := ps.mgr.GetDeviceByUUID(devices[0].UUID).PhyID
  -	resp.Envs["NPU_GLOBAL_SHM_PATH"] = fmt.Sprintf("/hami-shared-region/%d_global_registry", physicalID)
  +	// The core appends the physical device ID; overlapping allocations must use
  +	// the same base regardless of their selected device order.
  +	resp.Envs["NPU_GLOBAL_SHM_PATH"] = "/hami-shared-region/global_registry"
  ```
  </details>

- **监控从"数组序号索引"改"物理卡身份索引",并引入逐卡 SHM 域**。`DeviceStat` 新增 `PhysicalID` 字段;`ContainerEntry` 废弃 `Stats PodStats` / `DeviceMemory [hbmDevices]uint64` / `DeviceUUIDs []string`,改为 `Devices []ContainerDeviceStats`(含 Index/UUID/MemoryUsed/MemoryLimit)。`ListContainers()` 现在要求传入 `[]DeviceStat` 以把容器目录里的用量按物理卡 ID 关联到 UUID。指标语义同步改写:`hami_vgpu_memory_used_bytes` 从"每容器 vNPU 已用显存"改为"该容器在该 NPU 上由 hook 记账的显存",`vdevice_index` 对逐卡域变为宿主物理设备 ID。

  <details><summary>代码依据 internal/monitor/container.go + dsmi.go</summary>

  ```diff
  -	Stats         PodStats
  -	DeviceMemory  [hbmDevices]uint64
  -	DeviceUUIDs   []string
  +	Devices       []ContainerDeviceStats
  +}
  +type ContainerDeviceStats struct {
  +	Index       int
  +	UUID        string
  +	MemoryUsed  uint64
  +	MemoryLimit uint64
   }
  -func (l *ContainerLister) ListContainers() ([]ContainerEntry, error) {
  +func (l *ContainerLister) ListContainers(devices []DeviceStat) ([]ContainerEntry, error) {
  --- dsmi.go ---
   type DeviceStat struct {
   	Index       int
  +	PhysicalID  int
  ```
  </details>

- **910 HBM 读数改走专用 DCMI 接口**。主机侧显存从旧的 `DcGetMemoryInfo`(DDR 口径)改为优先用 `FuncDcmiGetDeviceHbmInfo`(并校验 `Usage<=MemorySize`),失败再回退旧接口;产品型号为空时用 `DcGetChipInfo().Name` 兜底。host 指标也加了 `MemoryTotal>0` 才导出的闸门。

  <details><summary>代码依据 internal/monitor/dsmi.go</summary>

  ```diff
  -		if memInfo, err := mgr.DcGetMemoryInfo(cardID, deviceID); err == nil {
  +		// Ascend 910 reports HBM through FuncDcmiGetDeviceHbmInfo, not the DDR interface.
  +		if hbm, err := dcmi.FuncDcmiGetDeviceHbmInfo(cardID, deviceID); err == nil && hbm != nil && hbm.MemorySize > 0 && hbm.Usage <= hbm.MemorySize {
  +			memTotal = hbm.MemorySize
  +			memUsed = hbm.Usage
  +		} else if memInfo, err := mgr.DcGetMemoryInfo(cardID, deviceID); err == nil && memInfo != nil && memInfo.MemorySize > 0 && memInfo.MemoryAvailable <= memInfo.MemorySize {
  ```
  </details>

- 配套:锁定的 hami-vnpu-core 运行库从 `b19ef02` 升到 `9f7be4c`(文档明示"旧库不提供本次逐卡独立记账语义"),文档大段改写示例(4 卡每卡 20GiB/50%,强调 `-memory` 填单卡值而非求和)。
### 后续发展方向 [AI]
- 记账模型的主线是"从容器级聚合 → 物理卡级独立",且刻意不支持异构配额(各卡必须相等),与 NVIDIA 侧"一卡一份 vGPU"的对齐更紧。证据覆盖 plugin 侧的 env 注入与监控重构;**未覆盖** `9f7be4c` 运行库内部如何按 `.device-<physicalID>` 建域(core 仓本期未在扫描范围),逐卡隔离的真实强度需看 core 侧实现。
- 监控从序号索引转向 UUID/物理 ID 身份索引,是把 vNPU 可观测性对齐"物理卡"这一稳定实体;配合逐卡域,后续大概率会把 per-card 利用率/配额也做成独立时序。证据只在 exporter 标签与 `DeviceStat` 结构,未见上层 dashboard 变更。

## Project-HAMi/HAMi-core: fe985a14 -> 0ee2a428
- 比较 https://github.com/Project-HAMi/HAMi-core/compare/fe985a147eecfb0b08b2d02a3483d967a6965818...0ee2a4284d7e5c76aab7596cdfba16066da0ff9f | Release —
### AI 总结重点(源码 diff 为据)
- **`set_task_pid()` 从"一次性读 NVML 进程表"重写为"多探针共识 + 退避"的 host PID 发现**。容器内进程读不到自己的 host PID,靠 NVML 设备进程列表反查;旧实现直接 merge 一次进程列表就取值,存在竞态:别的进程恰好此刻出现在设备上就会被误认成自己。新实现引入 `find_own_hostpid()` / `own_pid_candidates()`(对比 before/during/after 三次快照求候选)/ `hostpid_retry_seed()`(用时钟纳秒给退避播种),并要求**连续两次探针匹配同一 PID** 才认定,附带严格的 host namespace 检查与失败计数。这是软隔离里"进程→host PID"归属正确性的基线修复,误取会污染共享区显存记账与清理。(hunk 截断,未覆盖 utils.c 全部新逻辑)

  <details><summary>代码依据 src/utils.c + src/include/utils.h</summary>

  ```diff
  --- utils.c: 旧实现(单次 merge 即取) ---
  -nvmlReturn_t set_task_pid() {
  -    ...
  -        mergepid(&running_processes,&merged_num,...,pids_on_device);
  -        break;
  --- 新实现:多探针 + 阈值 ---
  +#define HOSTPID_DETECT_MAX_ATTEMPTS 8
  +static int pid_listed(const nvmlProcessInfo_t1 *list, unsigned int count, unsigned int pid) { ... }
  --- utils.h: 新增内部 API ---
  +unsigned int own_pid_candidates(const nvmlProcessInfo_t1 *before, ..., *during, ..., *after, ...);
  +unsigned int hostpid_retry_seed(const struct timespec *ts, unsigned int pid);
  +int find_own_hostpid(hostpid_probe_fn probe, void *ctx, int max_attempts, unsigned int *hostpid, uint64_t *used);
  ```
  </details>

- **共享区加锁重构 + 诊断快照不再阻塞初始化**。抽出 `set_shrreg_lock_owner()` 统一记录 owner_pid;新增 `try_lock_shrreg()`(`sem_trywait` 非阻塞)。`print_all()` 重写为:仅 debug 级(`g_log_level>=4`)执行,用 try-lock 拿不到锁就跳过(避免别人持锁时拖慢初始化),拿到后拷贝最多 16 个进程槽的快照再打印。

  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  +static void set_shrreg_lock_owner(shared_region_t *region) {
  +    region->owner_pid = (size_t)getpid();
  +    __sync_synchronize();
  +    SEQ_POINT_MARK(SEQ_UPDATE_OWNER_OK);
  +}
  +static int try_lock_shrreg(void) {
  +    if (sem_trywait(&region->sem) != 0) { return -1; }
  +    set_shrreg_lock_owner(region);
  +    return 0;
  +}
  ...
  +    if (g_log_level < 4 || region_info.shared_region == NULL) { return; }
  +    if (try_lock_shrreg() != 0) {
  +        LOG_DEBUG("Shared-region snapshot skipped: lock unavailable (errno=%d)", errno);
  +        return;
  +    }
  ```
  </details>

- **移除独立 `shrreg-tool` 工具**(`src/multiprocess/shrreg_tool.c`,-86 行)。该工具原提供 `--create_new/--suspend/--print/--resume/--version` 的命令行调试入口;其能力被新的 debug 级快照日志(见上)取代。

  <details><summary>代码依据 src/multiprocess/shrreg_tool.c(整文件删除)</summary>

  ```diff
  -void create_new() { ... ensure_initialized(); }
  -void print_shared_region(){ ensure_initialized(); print_all(); }
  -void send_stop_signal(){ ... suspend_all(); ... }
  -int main(int argc, char* argv[]) { ... "--create_new" ... "--suspend" ... "--print" ... }
  ```
  </details>
### 后续发展方向 [AI]
- 本期主线是软隔离内核的**正确性与可诊断性加固**,不是新切分能力:host PID 竞态是时分/显存记账准确性的根因之一,修它说明项目在把"记账正确"而非"更多切分维度"当当前重点。证据覆盖 utils.c/memory_limit.c 的锁与探针逻辑;**未覆盖** `nvmlDeviceGetComputeRunningProcesses` 在 MIG/多卡下的行为差异,多卡场景的 host PID 发现仍待观察。
- 把临时调试工具(shrreg-tool)并进"按需 debug 日志",是运维界面收敛信号,降低生产镜像里额外二进制的攻击面。

## Project-HAMi/HAMi: a80a7ae6 -> 33b7220f
- 比较 https://github.com/Project-HAMi/HAMi/compare/a80a7ae65d20a2df8f74cdd4ddf35ae1e883177a...33b7220f629ac21c12dde18667c39e32de8077f0 | Release v2.10.0(无变化)
### AI 总结重点(源码 diff 为据)
- **MIG 分配新增独立校验 `validateMigAllocation`,防止伪造分配注解绕过调度**。原先 `validateContainerAllocation` 在 MIG 模式直接 `return nil`(注释说"MIG 切片按 profile 容量计费,无从与请求比对");现在改为由新方法校验:插件维护 `registeredMig map[string]registeredMigCard`(记录每张 MIG 卡注册时的 memory 与可提供 profiles),Allocate 时解析分配注解,要求所取 profile **在本插件注册过的 profiles 里、且容量够容器的 memory 请求**;对应 issue #3077——分配注解本身不能证明调度器选了该 profile。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go + server.go</summary>

  ```diff
  --- util.go ---
  -// A MIG slice is charged its profile's capacity rather than the raw request, so there is nothing to
  -// compare it against here.
  +// A MIG slice is charged its profile's capacity rather than the raw request, so it is checked by
  +// validateMigAllocation instead.
  +func (plugin *NvidiaDevicePlugin) validateMigAllocation(pod *corev1.Pod, ctr *corev1.Container) error {
  +	allocations, err := nvidia.DecodeMigAllocations(pod.Annotations[nvidia.MigAllocationsAnnotation])
  +	...
  +		profile, found, known := plugin.registeredMigProfile(allocation.GPUUUID, allocation.Profile)
  --- server.go: 挂进 Allocate ---
  +			if plugin.operatingMode == "mig" {
  +				if err := plugin.validateMigAllocation(current, &currentCtr); err != nil {
  +					PodAllocationFailed(nodename, current, NodeLockNvidia)
  +					return &kubeletdevicepluginv1beta1.AllocateResponse{}, err
  +				}
  +			}
  ```
  </details>

- 其余为工程质量,非产品能力:新增 CI benchmark 对比门禁(`hack/bench-compare.sh` + `bench-policy.tsv`,用 benchstat 比对 PR base/head,仅对 `B/op`/`allocs/op` 设阈值、不卡时延);dependabot 把 k8s.io/* 归组;hygon 默认 core 微调(`pkg/device/hygon/device.go` 仅 2 行 + libvgpu 子模块 bump)。
### 后续发展方向 [AI]
- MIG 路径在补"分配可信"短板:HAMi 对 NVIDIA 的硬件分区(MIG)支持正从"接受调度结果"转向"插件侧二次校验注册 profile",与软切分(hook/时分)是两条正交路线,别混为一谈。证据只在 device-plugin 的校验逻辑,未见调度器侧对 MIG profile 下发的改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=33b7220f629ac21c12dde18667c39e32de8077f0 branch=master release=v2.10.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0ee2a4284d7e5c76aab7596cdfba16066da0ff9f branch=main release=— scanned=2026-10-23 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-23 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=ab41bec367ca95ac52ed1bcb8667c33e689f8f37 branch=main release=ascend-device-plugin-0.2.0 scanned=2026-10-23 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-23 -->
