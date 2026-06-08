# HAMi diff 雷达 2026-06-09

## 摘要
- HAMi-core 修了**fork 子进程软隔离失效**:`pthread_atfork` 注册 child handler 在 fork 后重置 once-flag,并在 cuLaunchKernel* 入口补 `ensure_post_init()`,确保 fork 出来的 CUDA worker 进程也能装上利用率监控/限速器(PR #199)。这是软切分(时分限速)在多进程场景的实质正确性修复。
- HAMi 主仓修调度器 `Bind` 失败路径的 vGPU 配额泄漏:取 Pod/取 Node 失败时新增 `cleanupStalePodAllocation`,回收 podManager 缓存与 quotaManager 用量(#1927)。
- 另 3 仓(volcano-vgpu / ascend-device-plugin / WebUI)本日无新提交。

## 当日重要改变
- Project-HAMi/HAMi-core [新能力/软隔离修复] 软切分限速器现支持 fork 子进程:fork 后重置 postInit once-flag 并在 kernel launch 入口惰性补初始化。PR #199 https://github.com/Project-HAMi/HAMi-core/pull/199 头提交 https://github.com/Project-HAMi/HAMi-core/commit/02a9ac22a438824b411e13ad4144fc152a1ec63b
- Project-HAMi/HAMi [资源泄漏修复] 调度器 Bind 失败不再泄漏 vGPU 配额。提交 #1927 https://github.com/Project-HAMi/HAMi/commit/900e3a336f92b752a0fbce3fc3bea9d5f46127af

## Project-HAMi/HAMi-core: 4bbd97ad -> 02a9ac22
- 比较: https://github.com/Project-HAMi/HAMi-core/compare/4bbd97ad48a5ca82149fe89787d2df7ac855e465...02a9ac22a438824b411e13ad4144fc152a1ec63b | ahead=3 | Release: —
### AI 总结重点(源码 diff 为据)
- **fork 安全:新增 `childReinitPostInit()` 经 `pthread_atfork` 注册为 child handler**。原来 `preInit`/`postInit` 各用一个 `pthread_once` flag 保证全进程只跑一次;但 fork 出的子进程会**继承父进程已置位的 once-flag 和 `pidfound`**,于是子进程跳过 `postInit`(其中 `init_utilization_watcher()`、task pid 注册等),导致子进程里**利用率统计/限速器没装上**——软切分对 fork worker 失效。现在 fork 后子进程把 `post_cuinit_flag` 重置为 `PTHREAD_ONCE_INIT`、`pidfound=0`,使其重新执行 postInit。
  <details><summary>代码依据 src/libvgpu.c</summary>

  ```diff
   void preInit(){
       load_cuda_libraries();
       ENSURE_INITIALIZED();
  +    pthread_atfork(NULL, NULL, childReinitPostInit);
   }
  +void childReinitPostInit() {
  +    LOG_DEBUG("Reset postInit state after fork");
  +    post_cuinit_flag = PTHREAD_ONCE_INIT;
  +    pidfound = 0;
  +}
  +void ensure_post_init() {
  +    pthread_once(&post_cuinit_flag, (void(*) (void))postInit);
  +}
   CUresult cuInit(unsigned int Flags){
  -    pthread_once(&post_cuinit_flag, (void(*) (void))postInit);
  +    ensure_post_init();
  ```
  </details>
- **kernel launch 入口惰性补初始化**:`cuLaunchKernel` / `cuLaunchKernelEx` / `cuLaunchCooperativeKernel` 三个 launch hook 都加了 `ensure_post_init()`。语义是:即便子进程**不显式调 `cuInit`**(fork 后直接复用父进程 CUDA context 发 kernel),也会在首个 launch 前惰性触发 postInit,补齐限速器与利用率上报。这把"软隔离何时生效"从"必须经 cuInit"放宽到"launch 前一定生效"。
  <details><summary>代码依据 src/cuda/memory.c</summary>

  ```diff
   CUresult cuLaunchKernel ( ... ){
       ENSURE_RUNNING();
  +    ensure_post_init();
       pre_launch_kernel();
   CUresult cuLaunchKernelEx(...) {
       ENSURE_RUNNING();
  +    ensure_post_init();
   CUresult cuLaunchCooperativeKernel ( ... ){
       ENSURE_RUNNING();
  +    ensure_post_init();
  ```
  </details>
- **利用率初始化循环 bug 修复**:`init_gpu_device_utilization()` 删掉了内层一个 `break`,使其遍历**全部 proc 槽位**而非命中第一个就退出——配合 PR 标题 "Fix SM utilization reporting for forked CUDA worker processes",说明多 worker 场景下原来只清/初始化了第一个进程槽。
  <details><summary>代码依据 src/multiprocess/multiprocess_memory_limit.c</summary>

  ```diff
               atomic_store_explicit(&region_info.shared_region->procs[i].monitorused[dev], 0, memory_order_relaxed);
  -            break;
           }
  ```
  </details>
- 附带:`libvgpu.h` 导出 `ensure_post_init()`、修头文件 guard 名(`__LIBVGPU_GLIBC_H__` → `SRC_INCLUDE_LIBVGPU_H_`)、补 EOF 换行,纯卫生项。
### 后续发展方向 [AI]
- HAMi-core 在补**多进程 CUDA 应用**(Python multiprocessing / fork-based 训练与推理 worker)的软切分覆盖度——这类负载此前是软隔离的盲区,显存限额尚由共享内存 region 兜底,但**算力限速(rate_limiter)和利用率上报**之前对 fork 子进程是漏的。证据只覆盖 fork→postInit 重置与 launch 入口补初始化,未见对 `pre_cuinit_flag`(preInit)是否需要 fork 重置的处理,也未见显存限额路径的对应改动。

## Project-HAMi/HAMi: 5b7b91f7 -> 900e3a33
- 比较: https://github.com/Project-HAMi/HAMi/compare/5b7b91f728c3e983f750fc991e546e24460b6d83...900e3a33 | ahead=1 | Release: v2.9.0
### AI 总结重点(源码 diff 为据)
- **调度器 Bind 失败路径回收 vGPU 配额**:新增 `cleanupStalePodAllocation(pod)`,内部 `TakeAndDeletePod` + 仅当设备数>0 时 `quotaManager.RmUsage`。`Bind` 在两处失败点接入:(1) 从 cache 取 Pod 失败时,用 args 拼一个仅含 UID/Name/Namespace 的临时 Pod 触发清理;(2) 取 Node 失败时,用已取到的 `current` Pod 清理。改前这两条早退路径直接返回 error,**不回收已记账的 vGPU 占用**,造成 podManager 缓存与 quotaManager 用量泄漏(幽灵占用持续挤占配额)。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +func (s *Scheduler) cleanupStalePodAllocation(pod *corev1.Pod) {
  +	if pi, ok := s.podManager.TakeAndDeletePod(pod); ok && len(pi.Devices) > 0 {
  +		s.quotaManager.RmUsage(pod, pi.Devices)
  +	}
  +}
   func (s *Scheduler) Bind(...) {
       current, err := s.podLister.Pods(args.PodNamespace).Get(args.PodName)
       if err != nil {
  +        s.cleanupStalePodAllocation(&corev1.Pod{ObjectMeta: metav1.ObjectMeta{
  +            UID: args.PodUID, Name: args.PodName, Namespace: args.PodNamespace}})
           return &extenderv1.ExtenderBindingResult{Error: err.Error()}, err
       }
       ... // 取 node 失败分支
  +        s.cleanupStalePodAllocation(current)
  ```
  </details>
- 配套新增两个表驱动测试 `Test_Bind_DelPodOnGetPodFailure` / `Test_Bind_DelPodOnGetNodeFailure`,断言失败后 `ListPodsUID()` 由 1 变 0,锁定回收语义。
### 后续发展方向 [AI]
- 主仓本期是配额账本一致性的稳健性补强(失败即回滚记账),非新能力。证据只覆盖 Bind 两条早退分支;未见对 filter/score 阶段或其它失败点是否同样存在悬挂占用的处理。

## 本期无实质改动(折叠)
<details><summary>3 个 repo 本日无新提交(HEAD 未变,仅保锚点)</summary>

- Project-HAMi/volcano-vgpu-device-plugin —— 7aba1850,未动
- Project-HAMi/ascend-device-plugin —— 799eaa34,未动
- Project-HAMi/HAMi-WebUI —— 30c3ce14,未动(Release hami-webui-1.2.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=900e3a336f92b752a0fbce3fc3bea9d5f46127af branch=master release=v2.9.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=02a9ac22a438824b411e13ad4144fc152a1ec63b branch=main release=— scanned=2026-06-09 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=7aba185031fd2f6169885b9c94cfbe1dfc5b788f branch=main release=— scanned=2026-06-09 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=799eaa34cb7ab0dc3c6bc0f502946bf9eafa4e4b branch=main release=— scanned=2026-06-09 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=30c3ce142b2ed9962972ffeabc56aa04890a062d branch=main release=hami-webui-1.2.0 scanned=2026-06-09 -->
