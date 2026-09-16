# HAMi diff 雷达 2026-09-17

## 摘要
- **HAMi 主仓这期是一次调度器安全加固潮**:5 个提交里 3 个是 extender 安全修复——把 `/filter`、`/bind` 从集群端口挪到独立 loopback 端口(新 `--extender-bind=127.0.0.1:9444`)、绑定前校验 Pod 身份(UID/节点必须与 live 对象一致)、webhook 拒绝携带调度器专属分配注解创建的 Pod。核心威胁模型统一表述为"`/filter`、`/bind` 不认证调用方,请求体里的 Pod 是输入不是证据"。
- **昇腾 hami-core 软切分算力口径落地**:主仓新增 `hamiCorePercentBudget`,把 device-plugin 上报的 `Devcore` 归一到 0–100 百分比预算(>100 视为有意超卖);WebUI(#310)同步长出读取 HAMi `device-config` ConfigMap 的能力,新增 `devicecatalog` / `provider/ascend` 两个 package 与 `device_config.proto`,前端能展示 vNPU 的 whole/template/soft 分配形态。昇腾 vNPU 软切分正从内核/调度器打通到控制台。
- **HAMi-core 修多卡+无上下文线程的记账健壮性**:给共享区访问器补设备 id 越界防护(修一个由未初始化 device id 触发的 OOB SIGSEGV),异步 free 改按分配时记录的设备归还显存(修跨设备误记账导致的伪 OOM)。

## 当日重要改变
- HAMi [架构方向/安全] 调度器 extender 拆端口 + 零信任请求体:`/filter`、`/bind` 独立绑到 loopback `9444`,绑定前 `verifyBindTarget`/`authoritativePod` 校验 UID 与目标节点。cmd/scheduler/main.go、pkg/scheduler/scheduler.go https://github.com/Project-HAMi/HAMi/pull/3039 https://github.com/Project-HAMi/HAMi/pull/3040
- HAMi [弃用防护] webhook 拒绝创建即携带调度器专属分配注解的 Pod(否则 device-plugin 会按 Pod 自填的 GPU/显存发卡,绕过调度器记账)。pkg/scheduler/webhook.go https://github.com/Project-HAMi/HAMi/pull/3042
- HAMi [新能力] 昇腾 hami-core 百分比算力预算:`Devcore` 归一到 100 基准,>100 为超卖预算。pkg/device/ascend/device.go https://github.com/Project-HAMi/HAMi/pull/2952
- HAMi-WebUI [API/CRD变更][新能力] 新增 `device_config.proto`(`DeviceConfig` 服务 + `AscendModel`/`AscendTemplate` 消息)与 `devicecatalog`、`provider/ascend` 两个 package,读取 HAMi device-config ConfigMap。server/api/v1/device_config.proto https://github.com/Project-HAMi/HAMi-WebUI/pull/310
- HAMi-core [新能力] 新增 `test_device_id_guard.c` 回归测试 + 全共享区访问器越界防护,堵一个字段观测到的 OOB SIGSEGV。src/multiprocess/multiprocess_memory_limit.c https://github.com/Project-HAMi/HAMi-core/commits/main

## Project-HAMi/HAMi: a7e3ffd6 -> 9e111e9d
- 比较: https://github.com/Project-HAMi/HAMi/compare/a7e3ffd66891d0fddfc5e331572cab3375c6bf3e...9e111e9d | ahead=5 | files=23 | 最新 Release: v2.10.0

### AI 总结重点(源码 diff 为据)
- **extender 的 `/filter`、`/bind` 从共享 HTTP 端口拆到独立 loopback 端口**。`cmd/scheduler/main.go` 新增 `--extender-bind`(默认 `127.0.0.1:9444`),`--http_bind` 的语义收窄为只服务 `/webhook`、`/refit`、探针;非 loopback 时打印告警"anyone able to reach it can drop a pod's device reservation or have its annotations patched"。原来 filter/bind/refit/webhook 全挤在一个端口靠 NetworkPolicy 限流,现在按信任边界物理隔离。
  <details><summary>代码依据 cmd/scheduler/main.go</summary>

  ```diff
  -	rootCmd.Flags().StringVar(&config.HTTPBind, "http_bind", "127.0.0.1:8080", "http server bind address")
  +	rootCmd.Flags().StringVar(&config.HTTPBind, "http_bind", "127.0.0.1:8080", "http server bind address, serving /webhook, /refit and the probes")
  +	rootCmd.Flags().StringVar(&config.ExtenderBind, "extender-bind", "127.0.0.1:9444", "bind address for the scheduler extender's /filter and /bind, called by the kube-scheduler container in this pod. Point it at a routable address only when kube-scheduler runs outside this pod.")
  ...
  +	if !isLoopbackAddr(config.ExtenderBind) {
  +		klog.Warningf("--extender-bind=%s is not a loopback address: /filter and /bind authenticate no caller, "+
  +			"so anyone able to reach it can drop a pod's device reservation or have its annotations patched", config.ExtenderBind)
  +	}
  ```
  </details>

- **绑定/过滤前先核对 Pod 身份,不再信任请求体**。`pkg/scheduler/scheduler.go` 新增 `verifyBindTarget`:UID 缺失即拒(不放行以防省字段绕过)、live UID 不匹配即拒、已分配节点即拒、并要求 bind 的节点等于 filter 阶段选中的节点;配套 `authoritativePod` 用 podLister/apiserver 取 live 对象与请求声明比对。威胁模型写明"a caller is free to pair a running pod's identity with a spec of its own"。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +func (s *Scheduler) verifyBindTarget(args extenderv1.ExtenderBindingArgs, current *corev1.Pod) error {
  +	if args.PodUID == "" {
  +		return fmt.Errorf("bind request for pod %s/%s carries no UID", args.PodNamespace, args.PodName)
  +	}
  +	if current.UID != args.PodUID {
  +		return fmt.Errorf("pod %s/%s has UID %s, bind request carries UID %s", ...)
  +	}
  +	if current.Spec.NodeName != "" {
  +		return fmt.Errorf("pod %s/%s is already assigned to node %s", ...)
  +	}
  +	if pi, ok := s.podManager.GetPod(current); ok && pi.NodeID != "" && pi.NodeID != args.Node {
  +		return fmt.Errorf("pod %s/%s was scheduled to node %s, bind request names node %s", ...)
  +	}
  ```
  </details>

- **`PodManager.TakeAndDeletePod` 释放缓存分配时,除 UID 外还校验 name/namespace**,防止"用 A 的 UID 配 B 的 name"释放掉仍在用的预留。
  <details><summary>代码依据 pkg/device/pods.go</summary>

  ```diff
  -	if ok {
  -		delete(m.pods, pod.UID)
  +	if !ok {
  +		return nil, false
  +	}
  +	if pi.Pod != nil && (pi.Name != pod.Name || pi.Namespace != pod.Namespace) {
  +		klog.InfoS("Refusing to delete cached pod, the request names a different pod than the UID holds", ...)
  +		return nil, false
  +	}
  +	delete(m.pods, pod.UID)
  ```
  </details>

- **webhook 在"放行到其它调度器"分支之前,先拒绝携带调度器专属注解创建的 Pod**。`schedulerOwnedAnnotation` 覆盖 `AssignedNodeAnnotations`、`BindTimeAnnotations`、`DeviceBindPhase` 及各设备的 `InRequestDevices`/`SupportDevices`;这些注解 device-plugin 会直接据以发卡,自填即绕开调度器记账。
  <details><summary>代码依据 pkg/scheduler/webhook.go</summary>

  ```diff
  +	if annotation, found := schedulerOwnedAnnotation(pod); found {
  +		klog.Warningf(template+" - Denying admission as pod presets %s", ...)
  +		return admission.Denied(fmt.Sprintf("annotation %s is written by the scheduler and cannot be set when creating a pod", annotation))
  +	}
  ```
  </details>

- **昇腾 hami-core 的 `Devcore` 归一为 0–100 百分比预算**。`GetNodeDevices` 在 `nodeSupportsHamiCore` 为真时,把上报值(未启用 hami-core 的插件会报硬件 AICore 数 8/20/24/30)经 `hamiCorePercentBudget` 改写:≤100 一律拉到 100(一个库存单位),>100 视为有意超卖;并新增 `hamiCoreExclusiveOccupant` 防止把已被单 Pod 独占整卡的设备当作可超卖。关联 ascend-device-plugin#132。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  +	normalizeHamiCore := dev.nodeSupportsHamiCore(&n)
  	for idx := range nodeDevices {
  		nodeDevices[idx].DeviceVendor = dev.config.CommonWord
  +		if !normalizeHamiCore { continue }
  +		advertised := nodeDevices[idx].Devcore
  +		budget := hamiCorePercentBudget(advertised)
  +		if budget == advertised { continue }
  +		nodeDevices[idx].Devcore = budget
  	}
  ...
  +func hamiCorePercentBudget(advertisedTotalcore int32) int32 {
  +	if advertisedTotalcore > hamiCorePercentBase { return advertisedTotalcore }
  +	return hamiCorePercentBase
  +}
  ```
  </details>

- **score 阶段 init/sidecar 行的落位修正**:`allocateAppContainers` 的行索引从 `appIndex` 改为 `numInitContainers+appIndex`,`scoreNode` 直接把 init 分配 seed 进 `score.Devices` 行,让 app 阶段的 Fit 看到并发 sidecar 占用、行下标与 Pod spec 对齐(旧代码事后再 prepend init 行,索引会错位)。
  <details><summary>代码依据 pkg/scheduler/score.go</summary>

  ```diff
  -			if len(score.Devices[typ]) == appIndex {
  +			if len(score.Devices[typ]) == numInitContainers+appIndex {
  ...
  -	var initAllocs device.PodDevices
  +		for devType, initConList := range allocs {
  +			score.Devices[devType] = append(device.PodSingleDevice{}, initConList...)
  +		}
  ```
  </details>

- **release 工作流加固**(非 vGPU 能力):`auto-release.yaml` 把 dispatch 输入经环境变量而非表达式插值传入、`checkout` 加 `persist-credentials: false`、版本比对直接读文件避免管道吞掉退出码。
  <details><summary>代码依据 .github/workflows/auto-release.yaml</summary>

  ```diff
  +      env:
  +        INPUT_TAG: ${{ github.event.inputs.tag }}
  +      run: |
  +        if [ -n "$INPUT_TAG" ] ; then echo "RUN_TAG=$INPUT_TAG" >> $GITHUB_ENV
  -        RecordVersion=` cat VERSION  | tr -d ' ' | tr -d '\n' `
  +        RecordVersion=` tr -d ' \n' < VERSION `
  ```
  </details>

### 后续发展方向 [AI]
- 调度器安全模型正从"靠 NetworkPolicy 挡端口"转向"零信任请求体 + 物理端口隔离":extender 认定 `/filter`、`/bind` 无调用方认证,故把它们锁在 pod 内 loopback,并在业务逻辑层核验身份。证据覆盖 extender 绑定/身份/注解三条路径,未见对 `/refit`(仍靠 TokenReview)与 `/webhook` 做同类改造。
- 昇腾 vNPU 软切分(hami-core 模式)在打通"插件上报口径 → 调度器百分比预算 → 超卖控制"的闭环,`hamiCorePercentBudget` 与 `hamiCoreExclusiveOccupant` 共同界定了超卖边界。证据只覆盖 ascend 设备路径的 `GetNodeDevices` 归一化,未见 NVIDIA 路径同步改动,也未见对应 device-plugin(#132)侧代码(该仓本期 EMPTY)。

## Project-HAMi/HAMi-core: 2c5c03d8 -> a5231c7f
- 比较: https://github.com/Project-HAMi/HAMi-core/compare/2c5c03d804d89428033e8b6f274d4f2122e1c9e9...a5231c7f | ahead=6 | files=5 | Release: —

### AI 总结重点(源码 diff 为据)
- **给共享区所有设备访问器补 device id 越界防护,堵 OOB SIGSEGV**。`multiprocess_memory_limit.c` 里 `get_gpu_memory_monitor`/`get_gpu_memory_usage`/`add_gpu_device_memory_usage`/`rm_gpu_device_memory_usage` 新增 `dev < 0 || dev >= CUDA_DEVICE_MAX_COUNT` 检查并返回安全值;更关键的是给一批只 `LOG_ERROR` 却仍继续索引数组的函数(`get_current_device_sm_limit` 等)补上了缺失的 `return`——之前日志打完照样越界读写 `limit[dev]`。触发源是无当前上下文线程上 `cuCtxGetDevice` 不写出参、栈垃圾当索引(测试里固化了字段观测值 `1716861768`)。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
  size_t get_gpu_memory_usage(const int dev) {
  +    if (dev < 0 || dev >= CUDA_DEVICE_MAX_COUNT) {
  +        LOG_ERROR("Illegal device id: %d", dev);
  +        return 0;
  +    }
  ...
  int get_current_device_sm_limit(int dev) {
      if (dev < 0 || dev >= CUDA_DEVICE_MAX_COUNT) {
          LOG_ERROR("Illegal device id: %d", dev);
  +        return -1;
      }
      return region_info.shared_region->sm_limit[dev];
  ```
  </details>

- **`cuda_to_nvml_map` 也补越界防护**,超范围返回 `CUDA_DEVICE_MAX_COUNT`(而非索引 `cuda_to_nvml_map_array[cudadev]`)。
  <details><summary>代码依据 src/multiprocess/multiprocess_utilization_watcher.c</summary>

  ```diff
  unsigned int cuda_to_nvml_map(unsigned int cudadev){
  +    if (cudadev >= CUDA_DEVICE_MAX_COUNT) {
  +        LOG_ERROR("Illegal cuda device id: %u", cudadev);
  +        return CUDA_DEVICE_MAX_COUNT;
  +    }
      return cuda_to_nvml_map_array[cudadev];
  ```
  </details>

- **无当前上下文线程上的分配/OOM 检查改为安全降级**。`allocator.c` 的 `oom_check_impl` 在 `cuCtxGetDevice` 失败时跳过限额执行(`return 0`);`add_chunk` 在无上下文时"不跟踪直接转发给驱动"(小于 `IPCSIZE` 走 `cuMemAlloc_v2`,否则 `cuMemoryAllocate(..., NULL)`),避免用未定义 id 索引 per-device 状态。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
  -    if (dev==-1)
  -        cuCtxGetDevice(&d);
  -    else
  +    if (dev == -1) {
  +        if (cuCtxGetDevice(&d) != CUDA_SUCCESS) {
  +            LOG_WARN("oom_check: no current context, skipping enforcement");
  +            return 0;
  +        }
  +    } else {
          d=dev;
  +    }
  ```
  </details>

- **异步 free 按分配时记录的设备归还显存**。`remove_chunk_async` 改用 `val->entry->dev`(分配时记录、在 `LIST_REMOVE` 释放条目前捕获),不再在 free 时调 `cuCtxGetDevice`——释放线程可能无上下文或当前设备不同,旧写法会漏记/误记账并最终表现为伪 OOM。
  <details><summary>代码依据 src/allocator/allocator.c</summary>

  ```diff
  +    CUdevice t_dev;
  ...
  +            t_dev = val->entry->dev;
              CUDA_OVERRIDE_CALL(cuda_library_entry,cuMemFreeAsync,dptr,hStream);
              LIST_REMOVE(a_list,val);
              a_list->limit-=t_size;
  -            CUdevice dev;
  -            cuCtxGetDevice(&dev);
  -            rm_gpu_device_memory_usage(getpid(),dev,t_size,2);
  +            rm_gpu_device_memory_usage(getpid(), t_dev, t_size, 2);
  ```
  </details>

### 后续发展方向 [AI]
- HAMi-core 的软隔离内核正在补"多卡 + 非 CUDA-主线程"两类边角场景的记账正确性:越界防护(防崩)+ 按分配设备归还(防伪 OOM),方向是让 CUDA hook 在异步流/worker 线程等无上下文场景下不再崩、不再错记。证据覆盖 memory_limit / allocator / utilization_watcher 三文件,`refactor` 提交显式把"无上下文异步分配守卫"推迟到后续 PR,说明这块尚未收口。

## Project-HAMi/HAMi-WebUI: 5fd62d49 -> 96aa960a
- 比较: https://github.com/Project-HAMi/HAMi-WebUI/compare/5fd62d49bc379abeef9b6afed69eba7deed0be26...96aa960a | ahead=1 | files=81 | 最新 Release: v1.3.0

### AI 总结重点(源码 diff 为据)
- **新增 `DeviceConfig` gRPC/HTTP 服务读取 HAMi 设备配置**。`device_config.proto` 定义 `GET /v1/device-config`,`DeviceConfigReply` 带 `state`(disabled/loading/loaded/missing/forbidden/invalid/error)、`issues` 与 `AscendModel` 列表;`AscendModel` 含 `resource_name`/`memory_allocatable`/`ai_core`/`ai_cpu`/`templates`/`super_pod`(两 NPU 成模块,请求 1 变 2、其它奇数拒绝),`AscendTemplate` 含 `compute_share`(模板 AICore 相对模型的百分比)。
  <details><summary>代码依据 server/api/v1/device_config.proto</summary>

  ```diff
  +service DeviceConfig {
  +  rpc GetDeviceConfig (GetDeviceConfigReq) returns (DeviceConfigReply) {
  +    option (google.api.http) = { get: "/v1/device-config" };
  +message AscendModel {
  +  string resource_name = 3;
  +  int32 ai_core = 8;
  +  repeated AscendTemplate templates = 10;
  +  bool super_pod = 11;   // request for 1 becomes 2; other odd counts rejected
  ```
  </details>

- **新增 `devicecatalog` + `data/device_catalog.go`,以 informer 监听 device-config ConfigMap**。`deviceCatalog` 用 field selector 只 watch 目标 ConfigMap,`recordList` 记录 forbidden/空列表(这些不会触达 handler),`NewDeviceCatalog` 首次读带 10s 等待让启动时解码的 Pod 能看到配置;未启用或缺 ns/name 时退化为 `Static{State: StateDisabled}`。
  <details><summary>代码依据 server/internal/data/device_catalog.go</summary>

  ```diff
  +func newDeviceCatalog(client kubernetes.Interface, config *conf.DeviceConfig, ...) devicecatalog.Source {
  +	if !config.GetEnabled() || ref.Namespace == "" || ref.Name == "" {
  +		return devicecatalog.Static{Current: &devicecatalog.Snapshot{State: devicecatalog.StateDisabled, Ref: ref}}
  +	}
  +	selector := fields.OneTermEqualSelector("metadata.name", ref.Name).String()
  ```
  </details>

- **新增 `provider/ascend/allocation.go`,把昇腾 vNPU 分配解读为形态**。`ResolveMode` 依据 `huawei.com/vnpu-mode`、节点 `hami-vnpu-core` 注解与策略推出 soft/template/unknown(歧义对应 ascend-device-plugin#134);形态常量 `whole`/`template`/`soft`/`unknown` 及一组 `Reason*`(catalog 不可用、模型/模板/算力未配置、模式歧义)供前端解释为何算力份额未知。
  <details><summary>代码依据 server/internal/provider/ascend/allocation.go</summary>

  ```diff
  +func ResolveMode(podMode, nodeHamiCore, policy string) (mode, reason string) {
  +	switch {
  +	case podMode == VNPUModeHamiCore:        return ModeSoft, ""
  +	case podMode != "", nodeHamiCore == "false": return ModeTemplate, ""
  +	case nodeHamiCore == "true" && policy == PolicyNode: return ModeSoft, ""
  +	case nodeHamiCore == "true": return ModeUnknown, ReasonModeAmbiguous
  ```
  </details>

- **card/container/scheduling 三个 proto 补 `vendor` 与配置对齐字段**。`GPUReply` 加 `unconfigured`(已注册但不在 device-config 里)+`vendor`;`ContainerReply` 加 `allocation_shape`/`template`/`allocated_cores_reason`/`vendor`;`SchedulingResource` 加 `vendor`——控制台开始按厂商与"是否在设备配置中"区分展示。
  <details><summary>代码依据 server/api/v1/card.proto</summary>

  ```diff
  message GPUReply {
  +  bool unconfigured = 14;  // Registered but absent from HAMi's device configuration.
  +  string vendor = 15;      // Provider, such as NVIDIA or Ascend.
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 从"只认 NVIDIA vGPU"向"多厂商 + 昇腾 vNPU 感知"扩:通过读 HAMi device-config ConfigMap 把后端的分配语义(whole/template/soft、super_pod 双卡成组、模板算力份额)搬到控制台,并用 `unconfigured`/`vendor` 区分未纳管设备。证据覆盖 proto/provider/catalog 三层与前端 `NpuAllocationOption.vue`、`DeviceConfigAlert.vue`,与 [HAMi-WebUI provider 模板](../) 的 provider+注解发现路数一致;昇腾之外的其它厂商(寒武纪等)本期未见同类 provider。
- 三仓这期共同指向"昇腾 vNPU 软切分产品化":主仓定超卖预算口径、内核补记账健壮性、WebUI 补可视化,三者分别引用 ascend-device-plugin #132/#134——而该插件仓本期 EMPTY,说明配套插件改动或已先行合入(锚点前)或仍在 PR,未落到本期扫描窗口。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓</summary>

- Project-HAMi/volcano-vgpu-device-plugin:无新提交(base=HEAD cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(base=HEAD 4b977f92),但被主仓 #2952 与 WebUI #310 引用为 #132/#134,配套改动未落本期窗口
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=9e111e9dde51a1194dbb6c2c842200e3c819f664 branch=master release=v2.10.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=a5231c7f4524e5d98f5200fde47f97b06356fcbe branch=main release=— scanned=2026-09-17 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-17 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=96aa960a04764ec9057561c1b69e53b8423e49e2 branch=main release=v1.3.0 scanned=2026-09-17 -->
</content>
</invoke>
