# HAMi diff 雷达 2026-09-15

## 摘要
- **HAMi 主仓把"环境变量注入"做成可细粒度关停的策略面**:新增 pod 级 `hami.io/overwrite-env` 与 container 级 `hami.io/overwrite-env-containers`(三态 Unset/On/Off),让用户按容器决定是否注入 `NVIDIA_VISIBLE_DEVICES=none`;同批把 NVIDIA/Ascend 的 admission mutation 改成幂等(配合 webhook `reinvocationPolicy: IfNeeded`),并把 MIG manager 的 NVML 会话生命周期收敛到 plugin Start/Stop 成对 Init/Shutdown。
- **HAMi-core 修了一个跨进程显存配额 TOCTOU 竞态**:从"先 oom_check 再 alloc"改为"持锁 reserve → alloc → 失败回滚 release",堵住两进程同时通过配额检查后双双分配把 limit 冲破的洞;并重写 `dlsym` 拦截入口(新增汇编 `dlsym_entry.S`)保住 RTLD_NEXT caller。
- **HAMi-core 补齐开源治理**:首次加入 Apache-2.0 LICENSE/NOTICE、SECURITY.md、OpenSSF `security-insights.yml`、CodeQL——其中安全声明明确把 HAMi-core 定位为"可信集群上的协作式配额,不是硬隔离边界",对我们判断其安全能力边界是关键一句。

## 当日重要改变
- HAMi [新能力] pod/容器级 overwrite-env 开关,新增 `pkg/util/overwrite_env.go` + 注解 `hami.io/overwrite-env` / `hami.io/overwrite-env-containers` https://github.com/Project-HAMi/HAMi/pull/2966
- HAMi [新能力] MIG profile 偏好注解 `nvidia.com/mig-profile-preference`,新增 `pkg/device/nvidia/mig_preference.go` https://github.com/Project-HAMi/HAMi/pull/3014
- HAMi [行为变更] NVIDIA/Ascend admission mutation 幂等化(webhook 可被重复调用不再重复追加 env) https://github.com/Project-HAMi/HAMi/pull/2936
- HAMi-core [新能力/安全] reserve-before-alloc 关闭跨进程显存配额 TOCTOU 竞态 https://github.com/Project-HAMi/HAMi-core/commit/fdbe6a860c14e014e1cb5f5178e3f58368da069d
- HAMi-core [架构方向] 首次加 Apache-2.0 LICENSE + OpenSSF security-insights,自述"协作式配额、非硬隔离" https://github.com/Project-HAMi/HAMi-core/blob/main/security-insights.yml

## Project-HAMi/HAMi: 88b118e5 -> 6c17a8f9
- 比较: 88b118e565a9effaa27f81669da291c5508fc5e4 -> 6c17a8f9 | ahead=6 | files=38 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **新增三态 OverwriteEnv 决策层,把"是否注入 `*_VISIBLE_DEVICES=none`"从全局 config 下放到 pod/容器注解**。新文件 `pkg/util/overwrite_env.go` 定义 `OverwriteEnvMode{Unset,On,Off}`:pod 级注解 `hami.io/overwrite-env` 是单个 bool 串,容器级 `hami.io/overwrite-env-containers` 是 `容器名→bool串` 的 JSON;`Unset` 回退全局 `dev.config.OverwriteEnv`、`On` 强制注入、`Off` 保留既有 env 不动。NVIDIA 后端在 `MutateAdmission` 里按 `util.OverwriteEnvDecision(p, ctr)` 选择注入与否。

  <details><summary>代码依据 pkg/util/overwrite_env.go / pkg/device/nvidia/device.go</summary>

  ```diff
  +const (
  +	OverwriteEnvAnnotationKey           = "hami.io/overwrite-env"
  +	OverwriteEnvContainersAnnotationKey = "hami.io/overwrite-env-containers"
  +)
  +const (
  +	OverwriteEnvUnset OverwriteEnvMode = iota // no annotation — fall back to global config
  +	OverwriteEnvOn                            // force inject the clearing env var
  +	OverwriteEnvOff                           // do not touch existing env var
  +)
  -	if !hasResource && dev.config.OverwriteEnv {
  -		ctr.Env = append(ctr.Env, corev1.EnvVar{Name: "NVIDIA_VISIBLE_DEVICES", Value: "none"})
  +	if !hasResource {
  +		inject := false
  +		switch util.OverwriteEnvDecision(p, ctr) {
  +		case util.OverwriteEnvOn:  inject = true
  +		case util.OverwriteEnvOff: inject = false
  +		default:                   inject = dev.config.OverwriteEnv
  +		}
  +		if inject && !hasEnvVarWithValue(ctr.Env, "NVIDIA_VISIBLE_DEVICES", "none") {
  +			ctr.Env = append(ctr.Env, corev1.EnvVar{Name: "NVIDIA_VISIBLE_DEVICES", Value: "none"})
  +		}
  +	}
  ```
  </details>

- **admission mutation 改为幂等,以配合 webhook `reinvocationPolicy: IfNeeded` 的重复调用**。新增 `hasEnvVarWithValue`(从后往前找同名 env、以最后一条为准),`TaskPriority`、`CoreLimitSwitch`、`NVIDIA_VISIBLE_DEVICES` 三处注入前都先查重,避免 webhook 二次触发时把同名 env 追加两遍。

  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +// hasEnvVarWithValue matches the last entry with the given name, because
  +// kubelet lets the last same-name env entry win.
  +func hasEnvVarWithValue(env []corev1.EnvVar, name, value string) bool {
  +	for _, e := range slices.Backward(env) {
  +		if e.Name != name { continue }
  +		return e.ValueFrom == nil && e.Value == value
  +	}
  +	return false
  +}
  ```
  </details>

- **Ascend 后端为容器级 OverwriteEnv JSON 加了一个进程内 LRU 缓存**,原因是 webhook 对每颗芯片各调一次 `MutateAdmission`(典型节点 7 颗),不缓存则同一段 JSON 会被解码 7 次;key 是 JSON 原文而非 pod 身份,故 TTL 取 `MaxInt64`(仅因 API 要求),容量 256,连解码失败(nil)也缓存以保证同一非法值只告警一次。

  <details><summary>代码依据 pkg/device/ascend/overwrite_env_cache.go(新增)</summary>

  ```diff
  +var overwriteEnvEntriesCache = cache.NewLRUExpireCache(256)
  +const overwriteEnvCacheTTL = time.Duration(math.MaxInt64)
  +func cachedContainerOverwriteEnv(rawJSON, ctrName string) (mode util.OverwriteEnvMode, listed bool) {
  +	v, ok := overwriteEnvEntriesCache.Get(rawJSON)
  +	if !ok {
  +		entries, err := util.DecodeContainerOverwriteEnvJSON(rawJSON)
  +		if err != nil { overwriteEnvEntriesCache.Add(rawJSON, map[string]util.OverwriteEnvMode(nil), overwriteEnvCacheTTL); return util.OverwriteEnvUnset, false }
  +		overwriteEnvEntriesCache.Add(rawJSON, entries, overwriteEnvCacheTTL); v = entries
  +	}
  ```
  </details>

- **新增 MIG profile 偏好注解 `nvidia.com/mig-profile-preference`,允许 pod 声明优先选用某 MIG 切片而非默认按显存排序**。新文件 `pkg/device/nvidia/mig_preference.go`:解析逗号分隔、去空去重且保序的偏好列表,匹配时既比全名(如 `3g.20gb`)也比切片前缀 key(`.` 前的 `3g`),`migProfileCandidates` 按偏好把命中项提前、其余仍按显存序排在后。`MutateAdmission` 里新增 `validateMigProfilePreference(p)` 校验。

  <details><summary>代码依据 pkg/device/nvidia/mig_preference.go(新增)</summary>

  ```diff
  +const MigProfilePreference = "nvidia.com/mig-profile-preference"
  +func migProfileMatchesPreference(profile, entry string) bool {
  +	return profile == entry || migProfileSliceKey(profile) == entry
  +}
  +func migProfileCandidates(profiles []device.MigProfile, preferred []string) []device.MigProfile {
  +	ordered := migProfilesByMemory(profiles)
  +	if len(preferred) == 0 { return ordered }
  +	// preferred 命中项按列出顺序提前,其余按显存序保留
  ```
  </details>

- **MIG manager 的 NVML 会话从"构造即 Init"改为"随 plugin Start/Stop 成对 Init/Shutdown",并加会话准入门 `beginOperation` 在释放 NVML 前 drain 在途操作**。`MigInstanceManager` 新增 `sessionMu`、`operations WaitGroup`、`nvmllib`(注入的 `nvml.Interface`,便于测试)、`initialized`、`closing chan`;`Init` 幂等且可失败后重试,`Shutdown` 拒新活+排空+精确释放一次;原先的自由函数 `collectInUseGPUs`/`kubernetesAllocatedMigGPUs`/`gpuUUIDToIndex`/`nvmlBusyGPUs` 全部改挂到 `*MigInstanceManager` 上并走 `beginOperation` 取句柄,不再各自裸调 `nvml.Init()`。plugin 侧 `Start` 加 `lifecycleMu`、`runCtx/cancelRun`、`workers WaitGroup`、`grpc.WaitForHandlers(true)`,重复 Start 直接报 "already started"。

  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/migmgr.go / mig_startup.go</summary>

  ```diff
   type MigInstanceManager struct {
  +	sessionMu   sync.Mutex
  +	operations  sync.WaitGroup
  +	nvmllib     nvml.Interface
  +	initialized bool
  +	closing     chan struct{}
   	mu ...
   }
  +func (m *MigInstanceManager) beginOperation() (func(), error) {
  +	m.sessionMu.Lock(); defer m.sessionMu.Unlock()
  +	if !m.initialized || m.closing != nil { return nil, fmt.Errorf("MIG manager NVML session is not running") }
  +	m.operations.Add(1); return m.operations.Done, nil
  +}
  -func gpuUUIDToIndex(gpuUUID string) (int, bool) {
  -	if nvret := nvml.Init(); nvret != nvml.SUCCESS { return 0, false }
  +func (m *MigInstanceManager) gpuUUIDToIndex(gpuUUID string) (int, bool) {
  +	done, err := m.beginOperation(); if err != nil { return 0, false }
  +	defer done(); dev, ret := m.nvmllib.DeviceGetHandleByUUID(gpuUUID)
  ```
  </details>

### 后续发展方向 [AI]
- OverwriteEnv 三态 + MIG-preference 都走**注解驱动的按 pod/容器策略**,HAMi 正把过去只能全局配的 device-plugin 行为逐项下放成工作负载级开关;后续大概率还有更多 `hami.io/*` 注解把注入/隔离策略细化到容器粒度。证据只覆盖 overwrite-env 与 mig-preference 两处注解,未见统一的注解 schema 或 CRD 化迹象。
- MIG manager 把 `nvml.Interface` 改为注入、会话生命周期化,是**为可测试性 + 多次 Start/Stop 不泄漏 NVML 会话**铺路(本批新增 3 个 lifecycle 测试文件);指向 MIG 动态重分片(dynamic-mig-migration)路径要在 plugin 反复重启下保持稳定。证据覆盖 migmgr/mig_startup/server 的重构与测试,未逐 PR 展开动态迁移的调度侧逻辑。

## Project-HAMi/HAMi-core: f01e9f23 -> fdbe6a86
- 比较: f01e9f23fc6ab251d2a7fee8987279f16b08afc8 -> fdbe6a86 | ahead=41 | files=30 | Release: —

### AI 总结重点(源码 diff 为据)

- **跨进程显存配额从"检查后分配"改为"持锁预留-分配-回滚",堵住 TOCTOU 竞态**。`allocator.c` 把 `oom_check` 拆出 `oom_check_impl(dev, addon, already_locked)`(带"调用者已持 `lock_shrreg`、不可重入"标志),并新增 `reserve_device_memory`:持锁内 `oom_check_impl(...,1)` 通过后立刻 `add_gpu_device_memory_usage` 记账再解锁,失败返回 `CUDA_ERROR_OUT_OF_MEMORY`;配 `release_device_memory` 回滚。`memory.c` 里 `cuMemAllocManaged`/`cuMemAllocPitch_v2`/`cuMemCreate` 全部改成先 reserve 再调真实 CUDA,分配失败或 `add_chunk_only` 失败时 `cuMemFree_v2`+release 回滚;pitch 路径还按驱动实际返回的 `*pPitch*Height` 校正记账(多退少补)。此前两个进程可同时通过 `oom_check` 再各自分配,把 limit 冲破。

  <details><summary>代码依据 src/allocator/allocator.c / src/cuda/memory.c</summary>

  ```diff
  +int reserve_device_memory(CUdevice dev, size_t size) {
  +    lock_shrreg();
  +    if (oom_check_impl(dev, size, 1)) { unlock_shrreg(); return CUDA_ERROR_OUT_OF_MEMORY; }
  +    add_gpu_device_memory_usage(getpid(), dev, size, 2);
  +    unlock_shrreg();
  +    return 0;
  +}
  // memory.c cuMemAllocManaged:
  -    if (oom_check(dev,bytesize)){ return CUDA_ERROR_OUT_OF_MEMORY; }
  +    if (reserve_device_memory(dev, bytesize) != 0) { return CUDA_ERROR_OUT_OF_MEMORY; }
       CUresult res = CUDA_OVERRIDE_CALL(... cuMemAllocManaged ...);
  -    if (res == CUDA_SUCCESS) { add_chunk_only(*dptr, bytesize, dev); }
  +    if (res == CUDA_SUCCESS) {
  +        if (add_chunk_only(*dptr, bytesize, dev) != 0) { CUDA_OVERRIDE_CALL(... cuMemFree_v2, *dptr); release_device_memory(dev, bytesize); return CUDA_ERROR_OUT_OF_MEMORY; }
  +    } else { release_device_memory(dev, bytesize); }
  ```
  </details>

- **重写 `dlsym` 拦截入口,用汇编 shim 保住 `RTLD_NEXT` 的原始 caller**。新增 `src/dlsym_entry.S`(x86_64 用 `endbr64`、aarch64 用 BTI `c`),对 `handle==RTLD_NEXT`(即 `-1`)先调 `libvgpu_get_real_dlsym` 解析真实 `dlsym`,再**尾跳**回去以保留调用方栈帧;其余走 `libvgpu_dlsym_dispatch`。`libvgpu.c` 把原单函数拆为 `initialize_dlsym`(用 `dlvsym` 按 GLIBC 版本表精确取 `dlsym`,并 lazy `dlopen` vgpulib)、hidden 的 `libvgpu_get_real_dlsym`/`libvgpu_dlsym_dispatch`,非 x86/arm 架构保留纯 C fallback。此前 `real_dlsym(RTLD_NEXT, ...)` 会把 caller 错认成 libvgpu 自身。

  <details><summary>代码依据 src/dlsym_entry.S(新增) / src/libvgpu.c</summary>

  ```diff
  +dlsym:
  +    cmpq $-1, %rdi
  +    jne .Ldispatch_x86_64
  +    call libvgpu_get_real_dlsym
  +    ...
  +    jmp *%rax            /* tail-jump keeps original return address */
  +__attribute__((visibility("hidden")))
  +fp_dlsym libvgpu_get_real_dlsym(void) { initialize_dlsym(); return real_dlsym; }
  ```
  </details>

- **NVML 打桩:查不到条目时返回"缺失"而非解引用 NULL 调穿**。`nvml_entry.c` 改动量小(+5),配合 `libnvml_hook.h` 调整,避免对未 hook 的 NVML entry 直接 call 空指针崩溃;另 `multiprocess_utilization_watcher.c` 把 total cuda cores 计算改 `int64_t` 防溢出。

  <details><summary>代码依据 提交标题 + 信号文件(hunk 未入节选,依据受限)</summary>

  ```
  fix(nvml): report a missing entry instead of calling through NULL
  fix: compute total cuda cores in int64_t
  5  modified src/nvml/nvml_entry.c
  3  modified src/multiprocess/multiprocess_utilization_watcher.c
  ```
  (注:这两条 hunk 未进「关键 patch 节选」,仅据提交标题+文件改动量,符号级细节受限)
  </details>

- **首次补齐开源治理与安全声明**:新增 Apache-2.0 `LICENSE`/`NOTICE`、`SECURITY.md`、OpenSSF `security-insights.yml`、CodeQL C/C++ 工作流、dependabot、CUDA base image 按 digest 钉版。其中 `security-insights.yml` 明确 in-scope 只保"工作负载读到他租户的 GPU 显存/设备/命名空间",而"卸掉 LD_PRELOAD/静态链接 CUDA/对自身 ptrace 绕过自己的配额"均 out-of-scope,并自述:"HAMi-core 是可信集群上的**协作式配额机制,不是硬隔离边界**"。

  <details><summary>代码依据 security-insights.yml(新增)</summary>

  ```yaml
  vulnerability-reporting:
    in-scope:
      - A workload reaching another tenant's GPU memory, device or namespace
    out-of-scope:
      - A workload exceeding its own GPU quota by unsetting LD_PRELOAD
      - A workload exceeding its own GPU quota via a statically linked CUDA runtime
      - A workload exceeding its own GPU quota via ptrace on its own process
    comment: |
      HAMi-core is a cooperative quota mechanism on a trusted cluster, not a
      hard isolation boundary. The out-of-scope cases are triaged as bugs.
  ```
  </details>

### 后续发展方向 [AI]
- 这批 41 提交里功能实质集中在**显存记账的并发正确性**(reserve/release + TOCTOU 回归测试 `test_concurrent_oom_race.c`/`test_shared_region_concurrency.c`)与 **dlsym 拦截健壮性**,方向是把软切分内核从"能跑"推到"并发下配额不被冲破";新增两个并发回归测试 + CTest 超时/GPU-less skip 说明后续会把并发配额正确性纳入 CI 常态。证据覆盖 allocator/memory/dlsym 的 hunk,未见新增 hook 类型或新的隔离维度(如带宽/SM 配额)。
- security-insights 的自述给出了明确的**安全边界口径**:HAMi-core 不承诺对抗恶意租户绕过自身配额,只承诺"不越界读他人"。对我们的产品定位有直接参考——若要对标企业级硬多租户隔离,HAMi-core 这层软 hook 需外挂更强的隔离(cgroup/驱动级/机密计算),不能单靠它。证据为治理文件文本,非代码路径。

## 本期无实质改动(折叠)
<details><summary>3 个 repo 无新提交</summary>

- Project-HAMi/volcano-vgpu-device-plugin(cbded47b,无新提交)
- Project-HAMi/ascend-device-plugin(4b977f92,无新提交)
- Project-HAMi/HAMi-WebUI(5fd62d49,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=6c17a8f9fe5a186b1ca763884a40fa6b40b6307d branch=master release=v2.10.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=fdbe6a860c14e014e1cb5f5178e3f58368da069d branch=main release=— scanned=2026-09-15 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-15 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-15 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=5fd62d49bc379abeef9b6afed69eba7deed0be26 branch=main release=v1.3.0 scanned=2026-09-15 -->
