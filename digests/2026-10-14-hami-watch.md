# HAMi diff 雷达 2026-10-14

## 摘要
- **HAMi 主仓落地"文件化 limit 下发"(limitDelivery)**:device plugin 除环境变量外,把 HAMi-core 的显存/算力 limit 额外写进容器内只读文件 `/overrideEnv`,解决 SSH / `su -` / cron 等登录会话不继承环境变量、导致软切分静默失效的问题——软隔离的生效面从"仅容器主进程环境"扩到"容器内所有登录会话"。配套新增 Pod 注解 `hami.io/limit-delivery` 与节点级 `limitDelivery` 配置(file/env)。
- **HAMi-core 补齐 CUDA 12.x/13.x 的 hook 符号版本解析**:按 `cudaTypedefs.h` 边界在 `g_func_map` 显式 pin `cuCtxCreate` 的 `_v2/_v3/_v4`、`cuMemAdvise`/`cuMemPrefetchAsync` 的 bare/`_v2`,修 `find_symbols_in_table()` 只探 `_v3/_v2/bare`、够不到 `_v4` 而返回错签名的 bug——拦截层正式覆盖 CUDA 13。
- 全仓设备计量 `int32→int64` 去范围检查 + AMD 补齐"只报显存/核数不报卡数时的默认整卡数/显存/核数"与 device cordon,向 nvidia 默认行为对齐。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增 `pkg/device-plugin/.../plugin/limits.go`(+199)、Pod 注解 `hami.io/limit-delivery`、`NvidiaConfig.LimitDelivery` 配置,把 HAMi-core limit 从"仅环境变量"扩成可写只读文件 `/overrideEnv`;证据 `limits.go` / `pkg/device/nvidia/device.go`。 https://github.com/Project-HAMi/HAMi/pull/3226 https://github.com/Project-HAMi/HAMi/pull/3220
- Project-HAMi/HAMi-core [新能力] hook 符号映射表 `g_func_map` 新增 `cuCtxCreate`/`cuMemAdvise`/`cuMemPrefetchAsync` 的版本区间条目,拦截层补齐 CUDA 13;证据 `src/include/multi_func_hook.h` / `src/libvgpu.c`。 https://github.com/Project-HAMi/HAMi-core/pull/320
- Project-HAMi/HAMi [架构方向] 设备计量结构体(`DeviceUsage`/`DeviceInfo`/`MigProfile`/`MigTemplate` 等)字段整体 `int32→int64`,删除 enflame 等处的 `MaxInt32` 溢出守卫;证据 `pkg/device/devices.go`。 https://github.com/Project-HAMi/HAMi/pull/3233

## Project-HAMi/HAMi: c5ca416f -> 3cd048cf
- 比较: https://github.com/Project-HAMi/HAMi/compare/c5ca416f05a75ad54986b7cf2f05e633ab3f92b7...3cd048cf603c2441fdfc0768389b55589929cf66 | ahead=13 | 最新 Release v2.10.0(未跨档)

### AI 总结重点(源码 diff 为据)
- **limit 下发从"纯环境变量"改为可选"文件化下发"到 `/overrideEnv`**。新增 `limits.go` 定义:HAMi-core 读 limit 的容器内硬编码路径 `overrideEnvContainerPath = "/overrideEnv"`(编译进 HAMi-core、不走环境,故登录会话不继承),文件格式版本键 `HAMI_LIMITS_FORMAT=1`,文件权限 `0o644`(允许非 root 容器用户读),共享计费文件名固定为 `usage.cache`。动机写在注释里:SSH / `su -` / sudo / cron 登录会话拿不到环境变量,导致软切分失效。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/limits.go</summary>

  ```diff
  +	// overrideEnvContainerPath is where HAMi-core reads the limits file
  +	// (ENV_OVERRIDE_FILE). The path is compiled into HAMi-core and never passed
  +	// through the environment, which a login session (SSH, su -, sudo, cron)
  +	// does not inherit.
  +	overrideEnvContainerPath = "/overrideEnv"
  +	limitsFormatKey     = "HAMI_LIMITS_FORMAT"
  +	limitsFormatVersion = "1"
  +	limitsFileMode = 0o644
  +	// sharedCacheName is HAMi-core's shared accounting file ...
  +	sharedCacheName = "usage.cache"
  ```
  </details>

- **新增 Pod 注解 `hami.io/limit-delivery` 与节点配置 `LimitDelivery`(file/env),可覆盖设备默认**。`device.go` 新增 `LimitDeliveryAnnotation = "hami.io/limit-delivery"`、类型 `LimitDelivery` 及常量 `LimitDeliveryFile="file"`(额外写只读文件)/`LimitDeliveryEnv="env"`(仅环境变量),并在 `NodeDefaultConfig` 加 `LimitDelivery *LimitDelivery` 字段。即:限额投递通道可按 Pod / 按节点选择。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +	// LimitDeliveryAnnotation lets a pod choose how its containers' limits reach
  +	// HAMi-core, "file" or "env", overriding the device configuration.
  +	LimitDeliveryAnnotation = "hami.io/limit-delivery"
  ...
  +type LimitDelivery string
  +const (
  +	LimitDeliveryFile LimitDelivery = "file"  // also writes limits to read-only /overrideEnv
  +	LimitDeliveryEnv  LimitDelivery = "env"   // env vars only
  +)
  ...
  +	// LimitDelivery is how containers get their limits: file (default) or env.
  +	LimitDelivery *LimitDelivery `yaml:"limitDelivery" json:"limitdelivery"`
  ```
  </details>

- **设备计量全面 `int32→int64`,并删除原有溢出守卫**。`DeviceUsage`/`DeviceInfo`/`MigTemplate`/`MigTemplateUsage`/`MigProfile`/`MigInUse` 的 Used/Count/Mem/Core/Index 等字段改 int64;`WholeGPUUsedCores`、`MemoryFactor` 同改 int64。enflame 处因此删掉 `n > math.MaxInt32` 的"请求过大"报错(改为直接用 int64 并在换算 1024 前加 `math.MaxInt64/1024` 溢出判断)。前→后:请求/显存数值不再被 int32 上限截断,大显存/大计数设备不再触发范围检查失败。
  <details><summary>代码依据 pkg/device/devices.go + pkg/device/enflame/device.go</summary>

  ```diff
   type DeviceUsage struct {
  -	Used      int32
  -	Totalmem  int32
  -	Usedcores int32
  +	Used      int64
  +	Totalmem  int64
  +	Usedcores int64
  ...
  -			if n > math.MaxInt32 {
  -				return ..., &device.ErrInvalidDeviceRequest{... Reason: "drs request %d is too large"}
  -			}
  +	if maxMemGB > math.MaxInt64/1024 {
  +		return ..., fmt.Errorf("drs profile memory %d GiB overflows int64 ...")
  +	}
  ```
  </details>

- **AMD device 补齐"只报显存/核数不报卡数"时的默认卡数/显存/核数,并尊重 device cordon**。`AMDConfig` 新增 `DefaultGPUNum`/`DefaultMemory`/`DefaultCores`(init 时 `max(.,1)` / `max(.,0)` / `min(max(.,0),100)` 归一);`MutateAdmission` 把原先"显存/百分比/核数各自单独判断是否补 1 张卡"的分支合并为:只要请求了三者任一而没给卡数,就补 `defaultGPUNum` 张(request-only count 时保留原值)。前→后:AMD 与 nvidia 一样支持"只写显存/核数自动配整卡数"。
  <details><summary>代码依据 pkg/device/amd/device.go</summary>

  ```diff
  +	defaultGPUNum                int64
  +	defaultMemory                int64
  +	defaultCores                 int64
  ...
  +		defaultGPUNum: max(config.DefaultGPUNum, 1),
  +		defaultCores:  min(max(config.DefaultCores, 0), 100),
  ...
  +		for _, name := range []string{dev.resourceMemoryName, dev.resourceMemoryPercentageName, dev.resourceCoreName} {
  +			... asked = asked || inLimits || inRequests
  +		}
  +		if asked {
  +			count := *resource.NewQuantity(dev.defaultGPUNum, resource.DecimalSI)
  +			ctr.Resources.Limits[corev1.ResourceName(dev.resourceCountName)] = count
  ```
  </details>

- **scheduler 重启后用 post-init 用量重放,修 init 容器用量释放时序**。`onAddPod` 现持 `allocLock` 调用 `onAddPodLocked`;新增 `releaseCompletedInitContainersLocked`,在 informer 初次同步重放已跑完 init 容器的 Pod 时,立刻释放 init 用量,而非等下一个 Pod 事件触发。前→后:scheduler 重启后账本不再因漏释放 init 容器用量而虚高。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +	// Unrelated Pods must not wait for allocation or NUMA refit operations.
  +	s.allocLock.Lock()
  +	defer s.allocLock.Unlock()
  +	s.onAddPodLocked(pod, assignedNodeName)
  +}
  +func (s *Scheduler) onAddPodLocked(pod *corev1.Pod, assignedNodeName string) {
  ...
  +	// Initial informer sync can replay a pod after its init containers have
  +	// already finished. Restore the same usage and release flag as an update ...
  +	s.releaseCompletedInitContainersLocked(pod, nil, rawDevices)
  ```
  </details>

- 另有 `CheckHealth` 新增 `device.RemoveObsoleteHandshake(devType, n)` 清理过期握手;以及 `#3113` 停止为 auto driver root 挂载宿主机根目录(安全收敛)、`#3223` 未显式设 `--node-lock-timeout` 时保留 `HAMI_NODELOCK_EXPIRE`、`#3227` 移除 requesting annotations。(hunk 截断,未覆盖全部)
- 注:本期 `charts/hami/values.yaml`(+269/-272)、`README.md`(+166/-160)大改动基本是 **helm-docs 注释迁移**(把参数说明从 README 表格搬进 values.yaml 的 `# --` 内联注释,并补 OpenShift/SELinux 字段文档),非能力变更,不单列。

### 后续发展方向 [AI]
- limit 下发文件化是 HAMi-core 侧的配套前置:`limits.go` 注释里 `HAMI_LIMITS_FORMAT=1`、`ENV_OVERRIDE_FILE` 暗示 HAMi-core 将来会有读这份文件的 reader(当前 patch 只见 HAMi 侧写入,未见 HAMi-core 侧读取实现)。方向:软切分 limit 从"进程环境注入"转向"容器内文件契约",让隔离覆盖登录/子进程全场景。证据只覆盖 HAMi 写入端 + 注解/配置定义,未见 HAMi-core 读取端。
- AMD 默认行为对齐 nvidia 延续"多厂商软切分能力拉平"主线(此前 metax/enflame/biren 等陆续补齐),device cordon 也在向全厂商铺开。证据只覆盖 amd/device.go,未逐一核对其他厂商本期是否同步。

## Project-HAMi/HAMi-core: 5ab7da10 -> a55248ec
- 比较: https://github.com/Project-HAMi/HAMi-core/compare/5ab7da10f72c72b7c158bb2d81f5148ec0af6392...a55248ecc6e2530602875054e2d334645d08f35b | ahead=7 | Release —

### AI 总结重点(源码 diff 为据)
- **hook 符号映射表 `g_func_map` 显式 pin CUDA 版本区间,修 `_v4` 够不到 / 错配签名的 bug**。新增 `cuCtxCreate` 三段(`<11.04` → `_v2`、`11.04–12.049` → `_v3`、`≥12.05` → `_v4`),`cuMemAdvise`/`cuMemPrefetchAsync` 两段(`<12.02` bare、`≥12.02` → `_v2`)。注释点明根因:`find_symbols_in_table()` 只探 `_v3/_v2/bare`,够不到 `_v4`,对其它 base name 也会答出错误签名。前→后:拦截层在 CUDA 12.x/13.x 下返回与 cuda.h 一致的符号拼写。
  <details><summary>代码依据 src/include/multi_func_hook.h</summary>

  ```diff
  +    // Boundaries follow cudaTypedefs.h: cuCtxCreate is _v2 below 11.4, _v3
  +    // from 11.4 and _v4 from 12.5; ... find_symbols_in_table() only probes
  +    // _v3, _v2 and the bare spelling, so it cannot reach _v4 ...
  +    {"cuCtxCreate", 10000, 11039, "cuCtxCreate_v2"},
  +    {"cuCtxCreate", 11040, 12049, "cuCtxCreate_v3"},
  +    {"cuCtxCreate", 12050, 99999, "cuCtxCreate_v4"},
  +    {"cuMemAdvise", 10000, 12019, "cuMemAdvise"},
  +    {"cuMemAdvise", 12020, 99999, "cuMemAdvise_v2"},
  +    {"cuMemPrefetchAsync", 10000, 12019, "cuMemPrefetchAsync"},
  +    {"cuMemPrefetchAsync", 12020, 99999, "cuMemPrefetchAsync_v2"}
  ```
  </details>

- **`_cuGetProcAddress_v2` 命中符号后不再裸返 `CUDA_SUCCESS`,改透传给驱动以回填 `symbolStatus`**。调用方会读 `*symbolStatus`,旧代码命中 hook 后直接 return 让其未初始化;新代码用一个丢弃用的 `optr` 调真实 `cuGetProcAddress_v2` 把 status 填回。
  <details><summary>代码依据 src/cuda/hook.c</summary>

  ```diff
  -        return CUDA_SUCCESS;
  +        /* The caller reads *symbolStatus after a successful return ... */
  +        void *optr;
  +        return CUDA_OVERRIDE_CALL(cuda_library_entry, cuGetProcAddress_v2, symbol,
  +                                  &optr, cudaVersion, flags, symbolStatus);
  ```
  </details>

- **`libvgpu.c` 把 `cuMemAdvise`/`cuMemPrefetchAsync` 的 `DLSYM_HOOK_FUNC` 用 `#if CUDA_VERSION < 13000` 守起来**,与 `memory.c` 仅在 <13.0 编译该实现保持一致(CUDA 13 起这两个 bare 符号不再 hook,只 hook `_v2`)。另加测试 `test/test_cuda_version_map.c`(+164)固化上述解析顺序。
  <details><summary>代码依据 src/libvgpu.c</summary>

  ```diff
  +    /* memory.c compiles this one only below 13.0; match it. */
  +#if CUDA_VERSION < 13000
      DLSYM_HOOK_FUNC(cuMemAdvise);
  +#endif
      DLSYM_HOOK_FUNC(cuMemAdvise_v2);
  ```
  </details>

### 后续发展方向 [AI]
- HAMi-core 拦截层正在系统性对齐 CUDA 13 的符号版本演进(`_v4` 入表、bare 符号按 13.0 分界),是整条软切分链条支持最新 CUDA 的底座。方向:hook 表从"手工探 2-3 个后缀"转向"按 cudaTypedefs.h 边界精确 pin + 测试锁定"。证据只覆盖 cuCtxCreate/cuMemAdvise/cuMemPrefetchAsync 三族,未见其它被 `find_symbols_in_table` 错配的符号是否也待补。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=3cd048cf603c2441fdfc0768389b55589929cf66 branch=master release=v2.10.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a55248ecc6e2530602875054e2d334645d08f35b branch=main release=— scanned=2026-10-14 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=5283c861b7f4bd4169d86daf4d03d34ac056d5fb branch=main release=— scanned=2026-10-14 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=1cf890f96118f38a85f71d31da2e74ca95aeb1a0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=09f0b75b0773c2caf835933936f0301f7efc248c branch=main release=v1.3.0 scanned=2026-10-14 -->
