# HAMi diff 雷达 2026-08-08

## 摘要
- HAMi 主仓 13 个实质提交,清一色**分配路径正确性/健壮性修复**:重写多容器 Allocate 的注解擦除(把"每容器各 patch 一次 API"改成"循环内内存擦除、循环后一次性 patch"修 #2380 陈旧注解);堵住 MIG 记账损坏 + MIG 锁文件 fd 泄漏(#2245);修 AMD 空注解误排除全部卡(#2395)。均为 bug 修复,**无 API/CRD 变更、无新能力、无版本跨档**。
- HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI **本期均无新提交**。

## 当日重要改变
- 无(无弃用/移除、无 API/CRD 路径命中、无新增顶层 package、Release 仍 v2.9.0)。仅 docs/develop/roadmap.md 把 AWS Neuron 加进"计划支持"表——方向信号但非代码能力。

## Project-HAMi/HAMi: 87d9795a -> 3616313c
- 比较: https://github.com/Project-HAMi/HAMi/compare/87d9795adc4d73042efe1751351c8d04488270cf...3616313c | ahead=13 | files=22 | Release: v2.9.0

### AI 总结重点(源码 diff 为据)

- **多容器 Allocate 的注解擦除从"每容器 patch API"重构为"内存擦除 + 循环后一次性 patch",修多容器场景陈旧注解(#2380)**。旧路径在每个容器分支里调用 `eraseNextDeviceTypeFromAnnotation(dtype, *current)`——它每次都从 `current.Annotations` 重新 `DecodePodDevices`、擦掉"第一个非空容器"、再 `PatchPodAnnotations`。但擦除后没同步回写内存里的 `current.Annotations`,导致同一次 kubelet Allocate 里第二个容器 decode 到的仍是旧注解 → 分配串位/陈旧。新代码拆成三个纯函数:`decodePodSingleDevice`(循环前 decode 一次)、`popNextContainerDevices`(在内存 slice 上就地擦除,并按"先 init 后普通容器"的顺序解析容器、越界返回明确 error)、`patchErasedAnnotation`(循环**结束后**只 patch 一次,并同步 `pod.Annotations[annoKey]=encoded` 让后续调用看到擦除态)。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go</summary>

  ```diff
  + podSingleDev, err := decodePodSingleDevice(nvidia.NvidiaGPUDevice, current)
  + if err != nil {
  +     PodAllocationFailed(nodename, current, NodeLockNvidia)
  +     return &kubeletdevicepluginv1beta1.AllocateResponse{}, err
  + }
    for idx, req := range reqs.ContainerRequests {
        ...
  -       currentCtr, devreq, err := GetNextDeviceRequest(nvidia.NvidiaGPUDevice, *current)
  +       currentCtr, devreq, err := popNextContainerDevices(current, podSingleDev)
            ...
  -       err = eraseNextDeviceTypeFromAnnotation(nvidia.NvidiaGPUDevice, *current)  // 每容器 patch,已删
    }
  + if err := patchErasedAnnotation(current, nvidia.NvidiaGPUDevice, podSingleDev); err != nil {  // 循环后一次
  +     PodAllocationFailed(nodename, current, NodeLockNvidia)
  +     return &kubeletdevicepluginv1beta1.AllocateResponse{}, err
  + }
  ```
  </details>
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/util.go(popNextContainerDevices + patchErasedAnnotation)</summary>

  ```diff
  + func popNextContainerDevices(pod *corev1.Pod, podSingleDev device.PodSingleDevice) (corev1.Container, device.ContainerDevices, error) {
  +     initContainerCount := len(pod.Spec.InitContainers)
  +     for i, ctrDevs := range podSingleDev {
  +         if len(ctrDevs) > 0 {
  +             podSingleDev[i] = device.ContainerDevices{}  // 内存就地擦除
  +             if i < initContainerCount { return pod.Spec.InitContainers[i], ctrDevs, nil }
  +             regularIdx := i - initContainerCount
  +             if regularIdx >= len(pod.Spec.Containers) {
  +                 return corev1.Container{}, nil, fmt.Errorf("container index %d out of range ...", i, ...)
  +             }
  +             return pod.Spec.Containers[regularIdx], ctrDevs, nil
  +         }
  +     }
  +     return corev1.Container{}, nil, errors.New("no pending device allocation found")
  + }
  + func patchErasedAnnotation(pod *corev1.Pod, dtype string, podSingleDev device.PodSingleDevice) error {
  +     encoded := device.EncodePodSingleDevice(podSingleDev)
  +     annoKey := device.InRequestDevices[dtype]
  +     if err := util.PatchPodAnnotations(pod, map[string]string{annoKey: encoded}); err != nil { return err }
  +     pod.Annotations[annoKey] = encoded  // 同步回写内存,后续容器看到擦除态
  +     return nil
  + }
  ```
  </details>

- **MIG 模式记账损坏 + fd 泄漏双修(#2245)**。`AddResourceUsage` 原来在函数开头就 `n.Used++`,即使后面 MIG 模板匹配失败也已经把已用计数加上去 → 计数损坏。新代码把 `n.Used++` 移到函数末尾成功路径,并在 `migNeedsReset` 分支加 `found` 哨兵:遍历完 MigTemplate 若没命中就 `return errors.New("mig template allocate resource fail")`,不再静默污染。配套 `lock.go` 的 `createMigApplyLock` 把 `os.Create` 返回的 fd 从 `_` 丢弃改为捕获并 `f.Close()`,堵住每次建 MIG 锁泄漏一个文件描述符。
  <details><summary>代码依据 pkg/device/nvidia/device.go(AddResourceUsage)</summary>

  ```diff
  func (dev *NvidiaGPUDevices) AddResourceUsage(pod *corev1.Pod, n *device.DeviceUsage, ctr *device.ContainerDevice) error {
  -   n.Used++                       // 失败也已计数
      if n.Mode == MigMode {
          if dev.migNeedsReset(n) {
  +           found := false
          OuterLoop:
              for tidx, templates := range n.MigTemplate { ...
  +                       found = true
                          break OuterLoop
              }
  +           if !found {
  +               return errors.New("mig template allocate resource fail")
  +           }
          } ...
      }
  +   n.Used++                       // 移到成功路径末尾
      n.Usedcores += ctr.Usedcores
  ```
  </details>
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/lock.go</summary>

  ```diff
  - _, err := os.Create(file)
  + f, err := os.Create(file)
    if err != nil { ...; return err }
  - return nil
  + return f.Close()
  ```
  </details>

- **`Fit` 把解析后的显存请求传给 CustomFilterRule,而非原始(可能为 0)的 Memreq**。此前 `CustomFilterRule` 收到的是 `request` 原值,若请求是百分比/需推导的显存,`request.Memreq` 尚为 0,自定义过滤规则据此判断会失真。现构造 `resolvedReq := request; resolvedReq.Memreq = memreq` 再传入。
  <details><summary>代码依据 pkg/device/nvidia/device.go(Fit)</summary>

  ```diff
  - if !nv.CustomFilterRule(allocated, request, tmpDevs[k.Type], dev) {
  + // CustomFilterRule must see the resolved memory request, not the raw (possibly zero) Memreq field.
  + resolvedReq := request
  + resolvedReq.Memreq = memreq
  + if !nv.CustomFilterRule(allocated, resolvedReq, tmpDevs[k.Type], dev) {
  ```
  </details>

- **AMD 空的 use/nouse-gputype 注解不再误排除全部卡(#2395)**。`checkAMDType` 原来只判 `annos[AMDInUse]` 是否存在,存在即 `strings.Split(inuse, ",")`;当值是空串时 split 得 `[""]`,`strings.Contains(cardType, "")` 恒真 → 空 nouse 注解会把每张卡都判成"禁用"、空 inuse 把每张卡都判成"限定"。现加 `&& strings.TrimSpace(inuse) != ""` 整体空值短路,并对每个逗号分段再 `useType != ""` 过滤。
  <details><summary>代码依据 pkg/device/amd/device.go(checkAMDType)</summary>

  ```diff
  - if inuse, ok := annos[AMDInUse]; ok {
  + if inuse, ok := annos[AMDInUse]; ok && strings.TrimSpace(inuse) != "" {
        useTypes := strings.Split(inuse, ",")
        if !slices.ContainsFunc(useTypes, func(useType string) bool {
  -         return strings.Contains(cardType, strings.ToUpper(strings.TrimSpace(useType)))
  +         useType = strings.TrimSpace(useType)
  +         return useType != "" && strings.Contains(cardType, strings.ToUpper(useType))
        }) { return false }
    }
  - if noUse, ok := annos[AMDNoUse]; ok {
  + if noUse, ok := annos[AMDNoUse]; ok && strings.TrimSpace(noUse) != "" {
  ```
  </details>

- **`ListAndWatch` 不再吞掉 `Send` 错误(#2353)**。原来首帧和健康更新帧的 `s.Send(...)` 返回值被忽略;现首帧失败 `return err`、健康更新帧失败 `return nil` 退出 goroutine,避免向已断开的 kubelet 流空转。
  <details><summary>代码依据 pkg/device-plugin/nvidiadevice/nvinternal/plugin/server.go(ListAndWatch)</summary>

  ```diff
  - s.Send(&...ListAndWatchResponse{Devices: plugin.apiDevices()})
  + err := s.Send(&...ListAndWatchResponse{Devices: plugin.apiDevices()})
  + if err != nil { klog.Errorf("Failed to send ListAndWatch response: %v", err); return err }
    ...
  - s.Send(&...ListAndWatchResponse{Devices: plugin.apiDevices()})
  + if err := s.Send(&...ListAndWatchResponse{...}); err != nil {
  +     klog.Errorf("Failed to send health-update ListAndWatch response: %v", err); return nil
  + }
  ```
  </details>

- **NVML `Init`/`Shutdown` 顺序修正 + 健康检查对老设备的处理**。`getAPIDevices` 原来 `defer nvml.Shutdown()` 写在 `nvml.Init()` **之前**,一旦 Init 失败(panic 前)仍会 defer 执行 Shutdown 而崩溃;现把 defer 移到 Init 成功之后,并抽出可被测试覆盖的 `nvmlInit` 变量。`health.go` 的 `checkHealth` 把两个独立 `if` 改成 `switch`:`ERROR_NOT_SUPPORTED`(设备太旧)只告警**不再**继续落进 `ret != SUCCESS` 分支被误标 unhealthy(#2393)。
  <details><summary>代码依据 register.go + health.go</summary>

  ```diff
  // register.go getAPIDevices
  - defer nvml.Shutdown()
  - if nvret := nvml.Init(); nvret != nvml.SUCCESS { ...; panic(0) }
  + if nvret := nvmlInit(); nvret != nvml.SUCCESS { ...; panic(0) }
  + defer nvml.Shutdown()   // 仅 Init 成功后才 defer
  // health.go checkHealth
  - if ret == nvml.ERROR_NOT_SUPPORTED { klog.Warningf("... too old ...") }
  - if ret != nvml.SUCCESS { unhealthy <- d }
  + switch {
  + case ret == nvml.ERROR_NOT_SUPPORTED: klog.Warningf("... too old ...")
  + case ret != nvml.SUCCESS: unhealthy <- d
  + }
  ```
  </details>

- 另有 `pkg/device/devices.go` 的 shared `CheckType` 跳过空逗号分段(#2435)与上面 AMD 修复同类,但本次 helper 未截到该文件 hunk(仅 3 行改动),不作符号级展开。

### 后续发展方向 [AI]
- HAMi 主仓这一波全是**分配/记账路径的正确性收口**(多容器擦除、MIG 记账、fd、空注解、Send 错误、NVML 生命周期),说明 v2.9.0 后进入稳定化打磨期而非加新能力;证据只覆盖 device-plugin/device 层的 diff,未见调度器 filter/score 或 CRD 侧改动。
- 空注解误排除(AMD #2395)+ 空逗号分段(#2435 CheckType)集中出现,指向一类系统性 bug:**注解 CSV 解析对空串的处理不一致**。可预期后续还会在 NVIDIA/其他厂商的 use/nouse-type 解析里做同类加固——证据只到 AMD 与 CheckType 两处,未逐仓核实其他 device 实现。
- roadmap 新增 AWS Neuron 说明厂商矩阵在往非 NV/非昇腾扩;仅 docs 改动,无对应 `pkg/device/neuron` 代码落地,方向尚未进入实现阶段。

## 本期无实质改动(折叠)
<details><summary>4 个仓库无新提交</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交(Release 仍 hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=3616313cb4d30841a6162421969d7ab9463931aa branch=master release=v2.9.0 scanned=2026-08-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=5496322f2fb3e71bf1eca014fba3c9bc59ab8ffd branch=main release=— scanned=2026-08-08 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=abe6919b389e98d33af1d8dd1c7d4fee6874102c branch=main release=— scanned=2026-08-08 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=771e19f836103727bc84d0bda29ba6a03538e5f2 branch=main release=— scanned=2026-08-08 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=fa9b560dfbe6caba65d5af48151d4ba544c8730f branch=main release=hami-webui-1.2.0 scanned=2026-08-08 -->
