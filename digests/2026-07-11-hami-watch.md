# HAMi diff 雷达 2026-07-11

## 摘要
- **HAMi 主仓把 DRA 从 helm chart 里整体拆出**(remove dra from charts #2038):删掉 `hami-dra` 子 chart 依赖、`dra.enabled` 开关与 configmap 的 DRA 分支——软切分(scheduler-extender)重新成为主 chart 的唯一默认路径,DRA 走独立仓部署。
- **昇腾 vNPU 软切分能力两处同时推进**:主仓给 910C 补 `vir05_1c_16g`/`vir10_3c_32g` 两个 vNPU 模板并加 SuperPod 门控(#2005);`ascend-device-plugin` 首次落地独立 helm chart + `hamiVnpuCore` 软切分开关。
- **HAMi-core 打通 Blackwell 利用率采集**:`nvmlDeviceGetProcessUtilization` 在 Blackwell 返回 NOT_SUPPORTED 时回退到 `nvmlDeviceGetProcessesUtilizationInfo`(driver 580+),否则时分利用率统计在新卡上直接失灵。

## 当日重要改变
- Project-HAMi/HAMi [架构方向] `remove dra from charts` 从主 chart 移除 hami-dra 子 chart 依赖、`dra.enabled` value 与 device-configmap 的 DRA 分支 —— charts/hami/Chart.yaml, charts/hami/values.yaml https://github.com/Project-HAMi/HAMi/pull/2038
- Project-HAMi/HAMi [新能力] 昇腾 910C 新增 `vir05_1c_16g`/`vir10_3c_32g` vNPU 模板(16G/32G 档),device-configmap 落 `superPod: true` —— charts/hami/templates/scheduler/device-configmap.yaml https://github.com/Project-HAMi/HAMi/pull/2005
- Project-HAMi/HAMi [弃用/移除] `hami_container_device_memory_bytes` 主指标砍掉 `context_size`/`module_size`/`buffer_size`/`offset` 四个标签,细分口径挪到 legacy 指标,v2.10.0 弃用 —— cmd/vGPUmonitor/metrics.go https://github.com/Project-HAMi/HAMi/compare/2487a240...1dc4fb71
- Project-HAMi/HAMi [项目治理] 文档把项目状态从 CNCF Sandbox 改为 Incubating —— https://github.com/Project-HAMi/HAMi/pull/2032
- Project-HAMi/HAMi-core [新能力] 新增 Blackwell 利用率回退路径 + `nvml_processes_utilization_subset.h`(driver 580+ 结构体子集) —— src/multiprocess/multiprocess_utilization_watcher.c https://github.com/Project-HAMi/HAMi-core/compare/8f3a89c6...06e69807
- Project-HAMi/ascend-device-plugin [新能力] 首次提供独立 helm chart 与 `hamiVnpuCore` 软切分开关,可脱离 HAMi 主 chart 单独部署昇腾 vNPU —— charts/ascend-device-plugin/ https://github.com/Project-HAMi/ascend-device-plugin/compare/6f1113ff...fce6ed64

## Project-HAMi/HAMi: 2487a240 -> 1dc4fb71
- 比较: 2487a240edb78705c2cbf35829f95f67793817ed -> 1dc4fb71 | ahead=12 | files=48 | Release: v2.9.0
- 比较链接:https://github.com/Project-HAMi/HAMi/compare/2487a240...1dc4fb71

### AI 总结重点(源码 diff 为据)
- **DRA 从主 chart 彻底解绑**:`remove dra from charts` 删掉 `charts/hami/Chart.yaml` 里对 `hami-dra` 子 chart 的 dependency、`values.yaml` 的整个 `dra`/`hami-dra` 配置段(含 `k8s-dra-driver` 镜像),并去掉 `device-configmap.yaml` 顶部 `{{- if not .Values.dra.enabled -}}` 守卫。等于 v2.9.0 后 HAMi 主 chart 不再内置/可选装 DRA,scheduler-extender 软切分回归唯一默认路径。
  <details><summary>代码依据 charts/hami/Chart.yaml + values.yaml</summary>

  ```diff
  # Chart.yaml
  -dependencies:
  -  - name: hami-dra
  -    version: "0.2.0"
  -    repository: "https://project-hami.github.io/HAMi-DRA/"
  -    condition: dra.enabled

  # values.yaml
  -# If this option is enabled, the DRA will be installed and the scheduler extender will not be installed.
  -dra:
  -  enabled: false
  -hami-dra:
  -  ...
  -      image:
  -        repository: ghcr.io/project-hami/k8s-dra-driver

  # device-configmap.yaml
  -{{- if not .Values.dra.enabled -}}
   apiVersion: v1
   kind: ConfigMap
  ```
  </details>
- **昇腾 910C vNPU 模板扩档 + SuperPod 门控**:device-configmap 给 910C 加了 `superPod: true` 和两档 vNPU 模板(`vir05_1c_16g` 16384MB/5 aiCore/1 aiCPU、`vir10_3c_32g` 32768MB/10 aiCore/3 aiCPU);同时 `MutateAdmission` 里"1 卡向上取整到 2(最小分配单元)"的逻辑从对所有 910C 生效收窄为**仅 `SuperPod` 时**生效——非 SuperPod 的 910C 不再被强行凑成 2 NPU。
  <details><summary>代码依据 pkg/device/ascend/device.go + device-configmap.yaml</summary>

  ```diff
  # device.go MutateAdmission
  -	if dev.config.CommonWord == Ascend910CType {
  +	if dev.config.CommonWord == Ascend910CType && dev.config.SuperPod {
   		if reqNum == 1 {
   			// round up ... to 2.

  # device-configmap.yaml
  +        superPod: true
  +        templates:
  +          - name: vir05_1c_16g
  +            memory: 16384
  +            aiCore: 5
  +          - name: vir10_3c_32g
  +            memory: 32768
  +            aiCore: 10
  ```
  </details>
- **硬切分 vNPU 上禁用 `-core` 资源 + hami-core 节点门控前移**:`MutateAdmission` 新增:当 pod 不是 hami-core 模式却申请了 `ResourceCoreName`(算力核)时直接报错,因为硬切分由模板固定算力;`Fit` 里"pod 要 hami-core 但节点不支持"的过滤判断从"仅当 Memreq 落在单卡区间内"提前到函数开头无条件执行,避免整卡/无显存请求绕过节点模式门(#2029)。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  +	// -core only applies to hami-core (soft split); on hard split the template
  +	// fixes compute, so reject it here.
  +	if !isHAMiCore && dev.config.ResourceCoreName != "" {
  +		...
  +		if ok && coreQ.Value() > 0 {
  +			return false, fmt.Errorf("%s is only supported in hami-core (soft split) mode", ...)
  +		}
  +	}
  ...
  +	if isHAMiCore && !nodeSupportHamiCore {
  +		reason[common.ModeNotFit]++
  +		return false, nil, common.GenReason(reason, len(devices))
  +	}
   	if request.Memreq > 0 && request.Memreq < totalMemPerCard && request.Nums > 0 {
  -		if !nodeSupportHamiCore && isHAMiCore { ... }
  ```
  </details>
- **NVIDIA 设备健康检查纳入 register 注解变化**:`NvidiaGPUDevices` 新增 `ReportedRegisterAnnos` map,`CheckHealth` 在 GPU 数未变但节点 `RegisterAnnos` 注解变化时也返回 changed=true,触发缓存刷新(#2022)——解决 device-plugin 重注册后 scheduler 侧信息陈旧问题。
  <details><summary>代码依据 pkg/device/nvidia/device.go</summary>

  ```diff
   type NvidiaGPUDevices struct {
  +	ReportedRegisterAnnos map[string]string // key: nodeName, value: last observed register annotation
  ...
  +	if reportedRegisterAnno != registerAnno {
  +		dev.ReportedRegisterAnnos[n.Name] = registerAnno
  +		return handshakeHealthy, true
  +	}
  ```
  </details>
- **vGPU 监控指标口径收窄**:`hami_container_device_memory_bytes` 主指标的 desc 与 label 集从含 `context_size`/`module_size`/`buffer_size`/`offset` 简化为仅基础 label,细分口径改由 legacy 指标承载,原注释明确这些 label 将在 v2.10.0 弃用、改用 `hami_vgpu_memory_context_bytes` 等新指标。集成方仪表盘需提前迁移。
  <details><summary>代码依据 cmd/vGPUmonitor/metrics.go</summary>

  ```diff
   	ctrDeviceMemorydesc = prometheus.NewDesc(
   		"hami_container_device_memory_bytes",
  -		`... The label "context_size", "module_size", "buffer_size" and "offset" will be deprecated in v2.10.0 ...`,
  -		[]string{..., "context_size", "module_size", "buffer_size", "offset"}, nil,
  +		`Container device memory usage in bytes`,
  +		[]string{"namespace", "pod", "container", "vdevice_index", "device_uuid"}, nil,
   	)
  ```
  </details>

### 后续发展方向 [AI]
- DRA 与软切分的关系已明确分叉:HAMi 把 DRA 完全移出主 chart(独立 HAMi-DRA 仓/子 chart 部署),主线交付继续押注 hook+scheduler-extender 的软切分。对我们产品的启示:若对标 OAI 走 DRA 原生路径,别指望从 HAMi 主 chart 直接复用,两条路径在 HAMi 侧是显式互斥部署。证据只覆盖 charts 目录改动,未见 DRA 仓自身是否同步演进。
- 昇腾软切分(hami-core 类)正在从"仅主仓配置"走向"device-plugin 侧独立能力封装":910C 模板扩档 + `SuperPod` 门控 + 硬/软切分的 `-core` 资源互斥校验,说明 HAMi 在把昇腾 vNPU 的软/硬两种切分语义在准入层做硬隔离。证据覆盖 device.go 准入/Fit 与 configmap,未逐 PR 展开 scheduler 实际打分改动。

## Project-HAMi/HAMi-core: 8f3a89c6 -> 06e69807
- 比较: 8f3a89c67b037d8fdfe6c4cd4d8c4f0cd6504811 -> 06e69807 | ahead=9 | files=12 | Release: —
- 比较链接:https://github.com/Project-HAMi/HAMi-core/compare/8f3a89c6...06e69807

### AI 总结重点(源码 diff 为据)
- **异步显存池分配纳入软隔离记账**:`cuMemAllocFromPoolAsync` 从原来的直通(`CUDA_OVERRIDE_CALL` 透传)改为走 `allocate_from_pool_async_raw`;`add_chunk_async` 拆出 `account_async_chunk`,按 `CU_MEMPOOL_ATTR_RESERVED_MEM_HIGH` 高水位把异步池分配计入 `device_allocasync->limit`——即异步内存池分配现在也受 HAMi-core 的显存上限约束,堵住了一条软切分显存绕过口子。
  <details><summary>代码依据 src/allocator/allocator.c + src/cuda/memory.c</summary>

  ```diff
  # memory.c
   CUresult cuMemAllocFromPoolAsync(...) {
  -    return CUDA_OVERRIDE_CALL(cuda_library_entry,cuMemAllocFromPoolAsync,...);
  +    return allocate_from_pool_async_raw(dptr, bytesize, pool, hStream);
   }

  # allocator.c
  +static int account_async_chunk(allocated_list_entry *e, size_t size, CUmemoryPool pool) {
  +    CUresult res = CUDA_OVERRIDE_CALL(..., cuMemPoolGetAttribute, pool, CU_MEMPOOL_ATTR_RESERVED_MEM_HIGH, &poollimit);
  +    if (poollimit != 0) {
  +        if (poollimit > device_allocasync->limit) {
  +            add_gpu_device_memory_usage(getpid(), e->entry->dev, allocsize, 2);
  +            device_allocasync->limit = device_allocasync->limit + allocsize;
  ```
  </details>
- **未跟踪异步指针不再泄漏**:`remove_chunk_async` 对不在 libvgpu 跟踪链表里的指针,从"直接返回 -1"(会以 unrecognized error code 暴露给应用,且真实显存泄漏)改为真正调 `cuMemFreeAsync` 释放;`add_chunk_async` 的 OOM 返回码也从 `-1` 规范为 `CUDA_ERROR_OUT_OF_MEMORY`。软隔离场景下的错误码/内存正确性双修。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
   int remove_chunk_async(...) {
  -    if (a_list->length == 0) { return -1; }
  ...
  -    return -1;
  +    /* Not tracked by libvgpu: free it for real instead of returning -1, which
  +     * leaked and surfaced as an "unrecognized error code". */
  +    return CUDA_OVERRIDE_CALL(cuda_library_entry, cuMemFreeAsync, dptr, hStream);
  ...
  -    if (oom_check(dev,size)) return -1;
  +    if (oom_check(dev, size)) return CUDA_ERROR_OUT_OF_MEMORY;
  ```
  </details>
- **Blackwell 利用率采集回退**:新增 `get_process_utilization_samples`,当 `nvmlDeviceGetProcessUtilization` 返回 `NVML_ERROR_NOT_SUPPORTED`(Blackwell 上不再支持)时回退到 `nvmlDeviceGetProcessesUtilizationInfo`,并把新 API 的 `nvmlProcessUtilizationInfo_v1` 样本回填成旧结构;为兼容老 CUDA nvml.h 头,新增 `nvml_processes_utilization_subset.h` 自带该结构体子集。这是 HAMi-core 时分利用率统计在新卡上继续工作的前置条件。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c + nvml_entry.c</summary>

  ```diff
  +static nvmlReturn_t get_process_utilization_samples(...) {
  +  nvmlReturn_t res = nvmlDeviceGetProcessUtilization(device, out, &processes_num, last_seen);
  +  if (res == NVML_SUCCESS) { *out_count = processes_num; return NVML_SUCCESS; }
  +  if (res != NVML_ERROR_NOT_SUPPORTED) { return res; }
  +  ...
  +  res = nvmlDeviceGetProcessesUtilizationInfo(device, (nvmlProcessesUtilizationInfo_t *)&info);
  ...
  -      nvmlReturn_t res2 = nvmlDeviceGetProcessUtilization(device, processes_sample, &processes_num, microsec);
  +      nvmlReturn_t res2 = get_process_utilization_samples(device, microsec, processes_sample, &processes_num);
  ```
  </details>
- 治理侧 `CONTRIBUTING.md` 补齐与主仓同款 6 条 Contribution Gates(硬件验证、禁大规模 AI 生成 PR、禁 AI co-author trailer 等),与上期 07-08 主仓所记为同一套规则,不再展开。

### 后续发展方向 [AI]
- HAMi-core 这批全是软隔离"正确性/覆盖面"收口:异步池记账把最后一类未受控的显存分配纳管,Blackwell 回退保证新卡上时分统计不失灵。方向是把软切分从"够用"推向"新硬件+异步 API 全覆盖"。证据覆盖 allocator/memory/utilization watcher 三处 hunk,`add_chunk_async` 后半段 hunk 被截断,未见完整错误路径。
- Blackwell(driver 580+)适配已进入 hook 内核层,意味着 HAMi 软切分对最新 NVIDIA 代次的支持不再只停留在 device-plugin。对我们产品:若要在 Blackwell 上做同类利用率隔离,需同步跟进 `nvmlDeviceGetProcessesUtilizationInfo` 这条新 API 路径。

## Project-HAMi/ascend-device-plugin: 6f1113ff -> fce6ed64
- 比较: 6f1113ff2f380da887c8b777635ab158e1d2c2db -> fce6ed64 | ahead=7 | files=13 | Release: —
- 比较链接:https://github.com/Project-HAMi/ascend-device-plugin/compare/6f1113ff...fce6ed64

### AI 总结重点(源码 diff 为据)
- **首次落地独立 helm chart**:新增 `charts/ascend-device-plugin/` 全套(daemonset/rbac/configmap/runtimeclass/values),可脱离 HAMi 主 chart 单独部署昇腾 device-plugin;README 明确"若 HAMi 主 chart 已管理该 DaemonSet/ConfigMap/RBAC/RuntimeClass,勿同时部署本 chart",并支持 `config.existingDeviceConfigMapName` 复用主 chart 的 `hami-scheduler-device`。这是昇腾 vNPU 交付从"绑在 HAMi 主 chart"走向"可独立发布"的信号。
  <details><summary>代码依据 charts/ascend-device-plugin/README.md</summary>

  ```diff
  +If the HAMi chart already manages the Ascend device plugin DaemonSet, related ConfigMaps, RBAC, or RuntimeClass, do not deploy this standalone chart at the same time.
  +...
  +  --set config.create=false \
  +  --set config.existingDeviceConfigMapName=hami-scheduler-device
  ```
  </details>
- **`hamiVnpuCore` 软切分开关贯穿 chart**:values 里 `hamiVnpuCore.enabled` 注入生成的 device-config `vnpus.hamiVnpuCore`,可全局或按节点(`nodeConfig` 里 `hami-vnpu-core: true` + `vDeviceCount`)开启;daemonset 挂载 `/usr/local/hami-vnpu-core` 与 `/usr/local/hami-shared-region`——即昇腾 NPU 的 hami-core 式软切分(共享区+vnpu-core)现在有了标准部署形态,而非仅硬切分模板。
  <details><summary>代码依据 charts/ascend-device-plugin/values.yaml + templates/daemonset.yaml</summary>

  ```diff
  # values.yaml
  +hamiVnpuCore:
  +  enabled: false
  +deviceConfig: |-
  +  vnpus:
  +    hamiVnpuCore: {{ .Values.hamiVnpuCore.enabled }}

  # daemonset.yaml
  +            - name: hami-shared-region
  +              mountPath: /usr/local/hami-shared-region
  +            - name: hami-vnpu-core
  +              mountPath: /usr/local/hami-vnpu-core
  ```
  </details>
- 另有工程性修正:`fix: stop staging the removed limiter binary onto the host`(不再把已删除的 `limiter` 二进制铺到宿主机)与 `libvnpu` 子模块 bump 到 embedded-manager(PR#11),偏构建/打包,未涉及 vNPU 语义。

### 后续发展方向 [AI]
- 昇腾侧的看点是 `hamiVnpuCore` 软切分从主仓配置项走向"device-plugin 自带、可独立部署+按节点开关"的封装,和主仓 910C 模板扩档+SuperPod 门控是同一波昇腾 vNPU 能力建设的两端。对我们产品(对标 OAI 多加速器):HAMi 正把昇腾 vNPU 的软/硬切分做成与 NVIDIA hami-core 对称的能力矩阵,值得作为国产卡软虚拟化对标基线。证据覆盖 chart 全量新增文件,未见 device-plugin Go 侧(internal/)对 `hamiVnpuCore` 的运行时实现改动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=1dc4fb716e7c93689b32946b97234e0ae1973f1f branch=master release=v2.9.0 scanned=2026-07-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-11 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-11 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=fce6ed645c14ae8eac21582acff59edba5d8933a branch=main release=— scanned=2026-07-11 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-11 -->
