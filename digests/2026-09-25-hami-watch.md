# HAMi diff 雷达 2026-09-25

## 摘要
- **HAMi 主仓把「非法设备请求」从 fail-open 改成 fail-closed(#2994)**:`Devices.GenerateResourceRequests` 接口签名全线加了 `error` 返回值,请求值非法时不再静默返回空 request(会被当作"这个 Pod 不要 GPU"照常调度),而是让调度器直接拒 Pod。涉及 nvidia/ascend/cambricon/mthreads/iluvatar/hygon/enflame 全部后端。
- **HAMi-core 修了两个会影响软隔离正确性的老 bug**:①oom_check/显存统计用 CUDA 下标去读 NVML 下标的 `used[]`,在 `CUDA_VISIBLE_DEVICES` 重排时统计错卡(读回自己刚记的账都对不上);②`cuMemGetInfo_v2(NULL, &total)`(libnvoptix/OptiX 初始化会这么调)以前解引用 NULL 直接 segfault。另外新增按语法解析 `CUDA_DEVICE_MEMORY_LIMIT` 后缀(K/M/G、Ki/KiB、小数)、拒绝畸形值。
- 其余 3 仓(volcano-vgpu / ascend-device-plugin / HAMi-WebUI)本期无新提交。

## 当日重要改变
- **Project-HAMi/HAMi [API/CRD变更]** 公有接口 `device.Devices.GenerateResourceRequests` 签名从 `(ContainerDeviceRequest)` 改为 `(ContainerDeviceRequest, error)`,并新增导出错误类型 `device.ErrInvalidDeviceRequest`;所有 vendor 后端与调度入口 `Resourcereqs` 随之改。(注:未命中 `*_types.go`/`config/crd` 字面路径,是 Go 接口契约层的破坏性变更) 证据 pkg/device/devices.go https://github.com/Project-HAMi/HAMi/pull/2994
- **Project-HAMi/HAMi [调度语义]** 调度准入由 fail-open 转 fail-closed:非法请求(负数/超 int32/非整数如 1Ei、显存单位写错、算力越界)以前落到"设备数为 0"被当普通 CPU Pod 放行,现在报错拒绝。证据 pkg/device/nvidia/device.go https://github.com/Project-HAMi/HAMi/commit/a2dd191b2e7fb1f289833e9b4fcef16289ec89b3
- **Project-HAMi/HAMi-core [正确性]** 显存记账在 `CUDA_VISIBLE_DEVICES` 重排下读错卡的 bug 修复(limit[] 是 CUDA 索引、used[] 是 NVML 索引),影响软隔离显存上限的准确性。证据 src/allocator/allocator.c https://github.com/Project-HAMi/HAMi-core/issues/319

## Project-HAMi/HAMi: c1baf1df -> a2dd191b
- 比较: https://github.com/Project-HAMi/HAMi/compare/c1baf1df73d61eda7cc1675776f5643c98439ea5...a2dd191b2e7fb1f289833e9b4fcef16289ec89b3 | ahead=1 | files=48 | Release: v2.10.0
- PR: https://github.com/Project-HAMi/HAMi/pull/2994

### AI 总结重点(源码 diff 为据)
- **`Devices` 接口新增 `error` 返回,语义三态化**:`GenerateResourceRequests` 现返回 `(request, err)`。约定为——`Nums=0 且 err=nil` 表示"该容器不要这个 vendor 的设备";`err != nil`(`*ErrInvalidDeviceRequest`)表示"要,但请求非法,调用方必须 fail-closed"。显式写 count=0 归入前者(否则会误拒所有把 GPU 数模板渲染成 0 的普通 CPU Pod)。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
  -	GenerateResourceRequests(ctr *corev1.Container) ContainerDeviceRequest
  +	// A zero Nums with a nil error means the container does not
  +	// request this vendor's devices. A non-nil error means it does, but the
  +	// request is invalid and the caller must fail closed instead of silently
  +	// treating the pod as device-less.
  +	GenerateResourceRequests(ctr *corev1.Container) (ContainerDeviceRequest, error)
  +type ErrInvalidDeviceRequest struct {
  +	Container string
  +	Device    string
  +	Reason    string
  +}
  ```
  </details>
- **调度入口 `Resourcereqs` 改为可失败,遇非法请求即中止收集并上抛**:以前逐容器丢弃非法项、最终返回一份"看起来无设备"的清单,Pod 就被无隔离放行;现在任一容器非法就 `return nil, reqErr`,由调度器拒 Pod。
  <details><summary>代码依据 pkg/device/devices.go</summary>

  ```diff
  -func Resourcereqs(pod *corev1.Pod) (counts PodDeviceRequests) {
  +func Resourcereqs(pod *corev1.Pod) (counts PodDeviceRequests, err error) {
   		for idx, val := range devices {
  -			request := val.GenerateResourceRequests(&pod.Spec.Containers[i])
  +			request, reqErr := val.GenerateResourceRequests(&pod.Spec.Containers[i])
  +			if reqErr != nil {
  +				return nil, reqErr
  +			}
  ```
  </details>
- **各后端补齐"整数解析失败"的兜底为报错而非静默放行**:nvidia/ascend/cambricon/hygon 等在 `v.AsInt64()` 失败(如 `1Ei`、`1e19` 这类 apiserver 接受但超 int64 的量)时,以前 fall-through 到函数末尾返回空 request(fail-open),现在返回 `ErrInvalidDeviceRequest`。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
  +		// A quantity the apiserver accepts as an integer can still be too
  +		// large for int64 (1Ei, 1e19). Falling through would report the
  +		// container as device-less, which is the fail-open this change
  +		// exists to remove.
  +		klog.ErrorS(nil, "nvidia device count request is not a plain integer", "container", ctr.Name, "request", v.String())
  +		return device.ContainerDeviceRequest{}, &device.ErrInvalidDeviceRequest{Container: ctr.Name, Device: "nvidia", Reason: fmt.Sprintf("device count %s is not a plain integer", v.String())}
  ```
  </details>
- **mthreads 后端修正多卡算力(core)分摊逻辑**:以前无条件 `Coresreq: corenum / int32(n)`;现在识别到 MutateAdmission 在 count>1 时把 core 限额改写成 `count*16`(coresPerMthreadsGPU),故在 `n>1` 时先校验能整除再除回单卡值,且显式不照抄 iluvatar 的 `>100 && n>1` 门(mthreads 的 2~6 卡总额是 32~96,≤100,套那道门会漏除、单卡上报 16 倍)。
  <details><summary>代码依据 pkg/device/mthreads/device.go</summary>

  ```diff
  -			if n <= 0 || n > math.MaxInt32 {
  -				return device.ContainerDeviceRequest{}
  +			if n == 0 {
  +				return device.ContainerDeviceRequest{}, nil
  +			}
  +			if n < 0 || n > math.MaxInt32 { ... }
  -				if !ok || corenums < 0 || corenums > 100 {
  +				if !ok || corenums < 0 { ... }
  +				if n > 1 {
  +					if corenums%n != 0 { return ...ErrInvalidDeviceRequest... }
  +					corenums /= n
  +				}
  +				if corenums > 100 { return ...ErrInvalidDeviceRequest... }
  -				Coresreq:         corenum / int32(n),
  +				Coresreq:         corenum,
  ```
  </details>
- **iluvatar 后端把多卡 core 校验门收紧为 `>100 && n>1`,并在除后复检**:注释点明单卡请求写 >100 本就非法(MutateAdmission 只在多卡时写 `count*100`),除回后可能仍 >100 需再判一次。

### 后续发展方向 [AI]
- 这次是把"软切分准入"的默认失效模式从 fail-open 扭到 fail-closed,方向是**让非法/歧义的 vGPU 请求确定性被拒,而不是悄悄退化成裸跑无隔离**——对企业级多租户是正向信号(避免越权占卡、避免无 limit 逃逸)。证据覆盖 7 个 vendor 后端 + 调度入口签名,未见对 device-plugin 侧/webhook MutateAdmission 的对应改动(本 PR 只动 scheduler 侧读取,webhook_test.go 有改但 hunk 未纳入截选)。
- 各 vendor 后端 core/mem 分摊校验开始各自精细化(mthreads 与 iluvatar 的 `count*16` vs `count*100` 差异被显式区分),提示 HAMi 正在把"多卡算力百分比语义"逐厂商对齐;证据只覆盖 mthreads/iluvatar 两家的 hunk,其余厂商本期只改了签名与兜底。

## Project-HAMi/HAMi-core: 410dfbe9 -> ec5d85a3
- 比较: https://github.com/Project-HAMi/HAMi-core/compare/410dfbe999f1fadca3039cd629823c4534fdd90a...ec5d85a3d709e5ed138a1668ebfefd366c05ca1e | ahead=7 | files=10 | Release: —

### AI 总结重点(源码 diff 为据)
- **新增语法化的显存限额解析 `parse_limit_value()`**:`CUDA_DEVICE_MEMORY_LIMIT` 现按"数字[.小数][单位]"文法解析,单位 K/M/G 一律 1024 基、允许 Ki/KiB/KB 拼写;SM(算力)限额走百分比分支(可带 `%`、不带单位);无法识别一律返 0(即"无限额")而非瞎猜。同时导出 `get_limit_from_env`。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  +static int parse_limit_value(const char *value, int is_sm, size_t *out) {
  +    ...
  +    if (!isdigit((unsigned char)*p)) return 0;   // strtoull 会吞前导负号,先要求数字
  +    digits = strtoull(p, &end, 10);
  +    switch (*end) {
  +        case 'k': case 'K': scalar = UINT64_C(1) << 10; break;
  +        case 'm': case 'M': scalar = UINT64_C(1) << 20; break;
  +        case 'g': case 'G': scalar = UINT64_C(1) << 30; break;
  +        default: return 0;
  +    }
  +    if (digits > (uint64_t)SIZE_MAX / scalar) return 0;   // 溢出保护
  ```
  </details>
- **oom_check / 显存统计的 CUDA↔NVML 索引错配修复**:`limit[]` 按 CUDA 序、`used[]` 按 NVML 序,以前直接用同一个 `dev` 下标读两者,在 `CUDA_VISIBLE_DEVICES` 重排时读到别的卡的用量。现在读 usage 前统一过 `cuda_to_nvml_map()`。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
  -    size_t _usage = get_gpu_memory_usage(d);
  +    /* limit[] is CUDA indexed, used[] is NVML indexed. */
  +    size_t _usage = get_gpu_memory_usage(cuda_to_nvml_map(d));
  -    size_t t = get_current_device_memory_usage(0);
  +    size_t t = get_current_device_memory_usage(cuda_to_nvml_map(0));
  ```
  </details>
- **`cuMemGetInfo_v2` 容忍 free/total 为 NULL,并修正 limit 取值下标**:libnvoptix 在 OptiX 初始化会以 `free=NULL` 调用,驱动接受、但 hook 旧代码直接 `*free=...` segfault(issue #333)。改为读进本地变量、按调用方给的非 NULL 指针回写;同时 `get_current_device_memory_limit(cuda_to_nvml_map(dev))` 修回 `(dev)`(limit 本就是 CUDA 索引)。
  <details><summary>代码依据 src/cuda/memory.c</summary>

  ```diff
  -    size_t limit = get_current_device_memory_limit(cuda_to_nvml_map(dev));
  +    size_t limit = get_current_device_memory_limit(dev);
  +    /* libnvoptix calls this with free=NULL ... read into locals and write
  +       back only what the caller asked for. */
  -        CUDA_OVERRIDE_CALL(cuda_library_entry,cuMemGetInfo_v2, free, total);
  -        *free = *total - usage;
  +        CUresult res = CUDA_OVERRIDE_CALL(cuda_library_entry, cuMemGetInfo_v2, &drv_free, &drv_total);
  +        if (free != NULL)  { *free = out_free; }
  +        if (total != NULL) { *total = out_total; }
  ```
  </details>
- **配套新增 3 个 GPU-free 回归测试**:`test_limit_env_parsing`(限额文法)、`test_memory_index_map`(#319 索引错配)、`test_meminfo_null_out`(#333 NULL 解引用),均 link 生产源码、桩掉驱动、不需 GPU;`security-insights.yml` 补 governance/review-policy 元数据,分发点由 `pkg:docker/...` 改成 `https://hub.docker.com/...`(供应链元数据,非代码)。

### 后续发展方向 [AI]
- HAMi-core 本轮全是**软隔离正确性/健壮性收敛**,而非新增 hook 能力:两处 CUDA↔NVML 索引错配说明多卡+`CUDA_VISIBLE_DEVICES` 重排是当前软限额的实测薄弱面;NULL 容忍针对 OptiX/光追类负载(libnvoptix)——提示 HAMi 正把兼容面从纯 CUDA compute 往 OptiX 扩。证据仅覆盖 memory/allocator/nvml 三处 hunk,未见对算力(SM)时分逻辑的改动。
- 引入无 GPU 回归测试基建(桩驱动 + `--gc-sections` 裁剪)是可持续信号:意味着 HAMi-core 这类需真卡的内核开始能在 CI 里对关键路径做确定性回归,后续显存/限额类 bug 的回归成本会降。

## 本期无实质改动(折叠)
<details><summary>3 仓无新提交</summary>

- Project-HAMi/volcano-vgpu-device-plugin(6063efe9,无新提交)
- Project-HAMi/ascend-device-plugin(074d93a8,Release ascend-device-plugin-0.1.0,无新提交)
- Project-HAMi/HAMi-WebUI(846c0e2d,Release v1.3.0,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=a2dd191b2e7fb1f289833e9b4fcef16289ec89b3 branch=master release=v2.10.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-09-25 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-09-25 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=074d93a8e1ca4f357fb1f4946f0566ced93641a6 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-25 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=846c0e2d3360cc7240bb61968e4cc7e3cea53443 branch=main release=v1.3.0 scanned=2026-09-25 -->
