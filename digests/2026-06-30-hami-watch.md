# HAMi diff 雷达 2026-06-30

## 摘要
- **ascend-device-plugin 仅一行 submodule 指针 bump,但背后 vNPU 软隔离内核(hami-vnpu-core)做了 6 commit / 16 文件的实质重构**:从"hook 软件记账显存"升级到 **DCMI 硬件级进程显存追踪**(独立线程每 5s 读 `dcmi_get_device_resource_info` 校准真实用量),并补齐 per-process/per-device 显存槽与死进程配额回收。
- 共享内存层从 POSIX 命名段(`shm_open`)改为 **文件背靠 mmap**,并把 `shmem.rs` 拆成 `shmem/{mod,setup,futex}` 模块;hook 单例改为 **fork 感知工厂 + stub 容错**(TBE 编译子进程无 shmem 时退化为 no-op,不再 panic)。
- 其余 4 仓(HAMi / HAMi-core / volcano-vgpu-device-plugin / HAMi-WebUI)本日无新提交,全 EMPTY。

## 当日重要改变
- **Project-HAMi/ascend-device-plugin [新能力][架构方向]** `libvnpu` 子模块从 `32b3bd82` bump 到 `f795831b`,vNPU 内核新增 DCMI 硬件显存追踪线程、per-process 显存槽(`ProcessSlot`)、fork 感知 limiter 工厂与死进程回收。证据:主仓提交 https://github.com/Project-HAMi/ascend-device-plugin/commit/92ef21365bd0a4f0d0a8bb076862d139e99f21f9 ;内核区间 https://github.com/Project-HAMi/hami-vnpu-core/compare/32b3bd821e0c513185e8b8657adb4feec9af825b...f795831b9c47d9a9a5d00deabc34d33ed3ceade5

## Project-HAMi/ascend-device-plugin: b7508b9f -> 92ef2136
- 比较 / 最新 Release:`b7508b9f -> 92ef2136`(ahead=2,files=1)| Release: —
- 主仓 diff 只有一行:`libvnpu` submodule 指针 `32b3bd82 → f795831b`。**真实代码改动在子模块 `Project-HAMi/hami-vnpu-core`(= 该仓 `libvnpu` 路径,即 vNPU 软切分内核本身),本节展开其 6 commit / 16 文件 diff——此为 submodule 延伸分析,超出 helper 确定性取数范围。**子模块区间命中 PR #3 / #8 / #10。

<details><summary>代码依据 ascend-device-plugin/libvnpu(主仓唯一改动)</summary>

```diff
-Subproject commit 32b3bd821e0c513185e8b8657adb4feec9af825b
+Subproject commit f795831b9c47d9a9a5d00deabc34d33ed3ceade5
```
</details>

### AI 总结重点(源码 diff 为据)

- **新增 DCMI 硬件级进程显存追踪,独立线程与调度环解耦**。`manager.rs` 新增 `unsafe extern "C"` 绑定 `dcmi_init` / `dcmi_get_card_list` / `dcmi_get_device_resource_info`,`build.rs` 新增链接 `libdcmi`;`ContainerManager::run` 起一条专用线程每 `DCMI_UPDATE_INTERVAL_SECS = 5` 秒调 `discover_and_update`,把硬件读到的 `DcmiProcMemInfo{proc_id, proc_mem_usage}` 按 `host_pid` 匹配写回 `slot.hbm_used[dev]`。此前显存用量纯靠 hook 侧 `post_alloc_hbm/post_free_hbm` 软记账,现在引入硬件 ground truth 校准。
  <details><summary>代码依据 crates/limiter/src/manager.rs + build.rs</summary>

  ```diff
  +const MAX_DCMI_PROCS: usize = 64;
  +const DCMI_UPDATE_INTERVAL_SECS: u64 = 5;
  +unsafe extern "C" {
  +    fn dcmi_init() -> i32;
  +    fn dcmi_get_card_list(card_num: *mut i32, card_list: *mut i32, list_len: i32) -> i32;
  +    fn dcmi_get_device_resource_info(card_id: i32, device_id: i32,
  +        proc_info: *mut DcmiProcMemInfo, proc_num: *mut i32) -> i32;
  +}
  +fn discover_and_update(local: &LocalContainerShmem) {
  +    ... dcmi_get_device_resource_info(...) ...
  +    if let Some(&mem) = dcmimap.get(&host_pid) {
  +        slot.hbm_used[dev].store(mem, Ordering::Release);
  +    }
  +}
  +    pub fn run(&mut self) {
  +        thread::spawn(move || { loop {
  +            thread::sleep(Duration::from_secs(DCMI_UPDATE_INTERVAL_SECS));
  +            discover_and_update(local_shmem);
  +        }});
  // build.rs
  +    println!("cargo:rustc-link-lib=dcmi");
  ```
  </details>

- **新增 per-process / per-device 显存槽 `ProcessSlot`,host PID 从 `/proc/self/status` 的 `NSpid` 解析**。`LocalContainerShmem` 新增 `procs: [ProcessSlot; MAX_PROCESSES=64]`;`ProcessSlot` 记 `{pid(容器 PID), host_pid(宿主 PID), hbm_used[NPU_DEVICE_MAX=8], is_active}`。Worker 启动时 `register_proc_slot` 调 `read_host_pid` 读 `NSpid` 第二字段(宿主侧 PID),这样 DCMI 上报的宿主 PID 才能与容器内进程对上。显存追踪粒度从"整容器一个计数器"细化到"每进程 × 每卡"。
  <details><summary>代码依据 crates/limiter/src/shmem/mod.rs + worker.rs</summary>

  ```diff
  +pub const MAX_PROCESSES: usize = 64;
  +pub const NPU_DEVICE_MAX: usize = 8;
  +pub struct ProcessSlot {
  +    pub pid: AtomicI32,          // container PID, 0 = free
  +    pub host_pid: AtomicI32,     // host PID from /proc/self/status NSpid
  +    pub hbm_used: [AtomicU64; NPU_DEVICE_MAX],
  +    pub is_active: AtomicU32,
  +}
  // worker.rs
  +fn read_host_pid(container_pid: i32) -> i32 {
  +    for line in status.lines() {
  +        if line.starts_with("NSpid:") { // "NSpid:\t10\t33538" — 末字段是宿主 PID
  ```
  </details>

- **共享内存从 POSIX 命名段(`shm_open`)改为文件背靠 mmap,并加 `fstat` 大小校验防 SIGBUS**。整文件 `shmem.rs`(230 行,`shm_open(O_CREAT)`)删除,改 `shmem/setup.rs` 用 `open(path, O_CREAT|O_RDWR)+mmap` 走真实文件路径;新增 `try_open_shmem` 非 panic 版本,先 `fstat` 确认文件已被 manager `ftruncate` 到足够大小,否则返回 `None`(避免映射半初始化文件后访问触发 SIGBUS)。
  <details><summary>代码依据 crates/limiter/src/shmem/setup.rs(替代已删除的 shmem.rs)</summary>

  ```diff
  -            let fd = libc::shm_open(c_name.as_ptr(), libc::O_CREAT | libc::O_RDWR, 0o666);
  +pub fn try_open_shmem<T>(path: &str) -> Option<&'static T> {
  +    let fd = open(c_path.as_ptr(), O_RDWR);
  +    if fd < 0 { return None; }
  +    let mut st: libc::stat = mem::zeroed();
  +    if fstat(fd, &mut st) < 0 || (st.st_size as usize) < mem::size_of::<T>() {
  +        close(fd); return None;   // 防止映射过小文件后 SIGBUS
  +    }
  ```
  </details>

- **hook 从全局 `lazy_static` 单例改为 PID 感知工厂 `npu_limiter()`,fork 后为子进程重建 client,shmem 不可用时退化 `stub()`**。原 `hook.rs` 里 `lazy_static! NPU_LIMITER: SchedulerClient` 全局单例,所有拦截点直接 `NPU_LIMITER.xxx()`;改为 `lib.rs` 的 `npu_limiter()`,缓存 `(pid, client)`,检测到当前 PID 与缓存不符(fork 子进程)即重建;`SchedulerClient::new` 用 `catch_unwind` 包裹,失败回退 `SchedulerClient::stub()`(no-op,禁用所有限额——针对 TBE 编译子进程无 shmem 场景)。
  <details><summary>代码依据 crates/hook/src/lib.rs(新增)+ hook.rs</summary>

  ```diff
  +/// PID-aware factory: detects fork and creates a fresh SchedulerClient for the child.
  +static LIMITER: Mutex<Option<(i32, SchedulerClient)>> = Mutex::new(None);
  +pub fn npu_limiter() -> SchedulerClient {
  +    let pid = std::process::id() as i32;
  +    if let Some((old_pid, ref client)) = *guard { if old_pid == pid { return client.clone(); } }
  +    let client = std::panic::catch_unwind(AssertUnwindSafe(SchedulerClient::new))
  +        .unwrap_or_else(|e| { ...; SchedulerClient::stub() });
  // hook.rs: 调用点从单例改工厂
  -    NPU_LIMITER.wait_for_token(stm);
  +    npu_limiter().wait_for_token(stm);
  ```
  </details>

- **死进程显存配额回收 + worker/proc 槽抢占**。`proc_alive` 读 `/proc/{pid}/stat` 第三字段判僵尸态(`Z`/`X`/`x`);`register_worker_slot` 改两遍扫描——先复用本 PID 旧槽,再 CAS 抢占已死进程的槽;`recalculate_usage` 遍历所有 proc slot,CAS 清零死进程 PID、回收其泄漏的 `hbm_used` 并校正全局 `memory_used`;`check_memory_quota` 在判配额前先调一次 `recalculate_usage`;新增 `Drop for SchedulerClientInner` 在析构时释放 proc 槽。解决进程崩溃后配额泄漏导致后续分配被误拒的问题。
  <details><summary>代码依据 crates/limiter/src/worker.rs</summary>

  ```diff
  +fn proc_alive(pid: i32) -> bool {
  +    // Format: pid (comm) state ... → Z/X/x 视为已死
  +    return ch != 'Z' && ch != 'X' && ch != 'x';
  +pub fn recalculate_usage_for_device(&self, device: usize) -> u64 {
  +    if !proc_alive(pid) {
  +        if slot.pid.compare_exchange(pid, 0, ...).is_ok() {
  +            let leaked = slot.hbm_used[device].swap(0, Ordering::Release);
  +            cleaned += leaked;
  +    shmem.memory_used.fetch_sub(cleaned, Ordering::Release);
  +impl Drop for SchedulerClientInner {
  +    fn drop(&mut self) { slot.pid.store(0, ...); slot.is_active.store(0, ...); }
  ```
  </details>

- **算力优先级写入全局 scoreboard,为跨 pod 算力协商铺垫**。`GlobalManagerSlot` 新增 `priority: AtomicU64` 字段;`ContainerManager::new` 把 `comp_priority` 写到 `global.slots[idx].priority`,注释明示 "so other pods can calculate compute share";`LocalContainerShmem` 同步新增 `compute_priority`。另新增 `config.rs` 集中 `NPU_GLOBAL_SHM_PATH/NPU_LOCAL_SHM_PATH/NPU_PRIORITY/NPU_MEM_QUOTA` 环境变量为 `ManagerConfig::from_env`,替代散落各处的 `std::env::var`。
  <details><summary>代码依据 crates/limiter/src/shmem/mod.rs + manager.rs</summary>

  ```diff
  +pub struct GlobalManagerSlot { ... pub priority: AtomicU64, }
  // manager.rs
  +        // Write our priority to the global slot so other pods can calculate compute share
  +        global.slots[idx].priority.store(comp_priority as u64, Ordering::Release);
  +        local.compute_priority.store(comp_priority as u64, Ordering::Relaxed);
  ```
  </details>

### 后续发展方向 [AI]
- **显存隔离正从"软件记账"转向"硬件校准 + 软件记账双轨"**:DCMI 线程提供硬件真实值、hook 记账提供实时增量,`recalculate_usage` 负责对账。证据覆盖 manager.rs 的 DCMI 线程与 worker.rs 的 recalculate;未见两者冲突时以谁为准的最终仲裁逻辑(DCMI 直接 `store` 覆盖 slot,hook 用 `fetch_add/sub`,存在覆盖竞争,diff 未给同步策略)。
- **算力切分在为跨 pod / 多卡场景做准备**:`priority` 进全局 scoreboard、`hbm_used[NPU_DEVICE_MAX=8]` 按卡分桶、`device_id` 经 `rtGetDevice` 取得。证据只覆盖数据结构与写入点;`get_compute_share` 当前仍直接返回原始 `device_util`(无按优先级切分),说明跨 pod 算力分配是占位铺垫、尚未落地实际分配算法。
- **稳健性是本轮主线**:fork 感知、stub 容错、SIGBUS 防护、死进程回收、僵尸槽抢占,集中指向"多进程/异常退出下不崩、不泄漏配额"。证据覆盖 hook/worker/setup;未见对应测试改动(本区间无 `_test.rs` 文件),回归验证靠运行时。
- 边界说明:以上均为 `hami-vnpu-core` 子模块 diff,仅 Ascend vNPU 路径生效,与 HAMi 主仓 GPU(HAMi-core CUDA hook)软切分是两套代码;本日 HAMi-core 无提交,不能外推到 GPU 侧。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/HAMi — 无新提交(锚点 03eed2e9,Release v2.9.0)
- Project-HAMi/HAMi-core — 无新提交(锚点 0831874b)
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交(锚点 6561f1c1)
- Project-HAMi/HAMi-WebUI — 无新提交(锚点 8f42445d,Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=03eed2e96b5f6fbc486b8869f5d3006bebf3d0cc branch=master release=v2.9.0 scanned=2026-06-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=0831874bce5af56cefca7093dfb2f9f95d1970aa branch=main release=— scanned=2026-06-30 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-06-30 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=92ef21365bd0a4f0d0a8bb076862d139e99f21f9 branch=main release=— scanned=2026-06-30 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=8f42445d325736655d467842cb762b75f2612d25 branch=main release=hami-webui-1.2.0 scanned=2026-06-30 -->
