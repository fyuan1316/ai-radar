# 昇腾算力栈 diff 雷达 2026-07-08

## 摘要
- **软切分(device-share/soft-share)成为今日跨仓主线**:mind-cluster 的 ascend-device-plugin 修复"软切分请求 aicore 数 == 节点 NPU 卡数时误走整机调度导致挂卡错误"(Allocate 增 `IsSupportSoftShareDevice()` 强制走 volcano annotation 路径),并新增 `checkSoftShareDevParam` 启动校验(软切分开启但 volcanoType=false 直接拒绝);vNPU 则在节点初始化时**自动 `npu-smi set device-share` 开启物理卡共享模式**,并把 `disablePresetVirtualDevice` 的 `panic` 改为日志降级。
- mind-cluster 另有两处:`getPodFromKubelet` 默认值从 `true` **回退为 `false`**(昨日刚上的 kubelet 直读默认被关);ascend-for-volcano 进程级恢复新增"外部平台删 Pod"模式(`ProcessRecoverStrategy` annotation → 跳过自删,交外部平台重建),修 A3 节点 not ready 无法重调度。
- vNPU 调度侧收敛:节点锁重试 3→30 次、`AllocateXPUForTask` 改为返回 error 并把失败经 `event.Err` 上抛给 volcano、`GetPendingPod` 删掉"列全节点 Pod 挑最早 bind"的兜底路径改为仅认节点锁身份。
- 其余 7 个 openFuyao 仓(npu-operator / npu-container-toolkit / npu-driver-installer / npu-node-provision / npu-dra-plugin / volcano-ext / ub-network-device-plugin)全无新提交。

## 当日重要改变
- mind-cluster [新能力] ascend-device-plugin 软切分修复:`Allocate` 的 `usePodAnnotation` 判定增 `common.IsSupportSoftShareDevice()` 分支,使"分配设备数 == 全卡数"的软切分场景也走 `useVolcano` 注解分配路径而非整机直挂,根治挂卡错误;配套 main.go 新增 `checkSoftShareDevParam` 启动校验。证据文件 component/ascend-device-plugin/pkg/server/plugin.go、main.go。https://gitcode.com/Ascend/mind-cluster/compare/d46e4038f24e1e473ecd9ba3c851fc18192ba33a...47c436e3d52121a4c1f67c36e5138fbf688d06bb
- mind-cluster [弃用/移除] ascend-device-plugin `getPodFromKubelet` flag 默认值 `true`→`false`,昨日(07-07)刚落地的"device-plugin 默认从 kubelet 直读 Pod"被回退为默认走 apiserver。证据文件 component/ascend-device-plugin/main.go。同上 compare 链接
- mind-cluster [新能力] ascend-for-volcano 进程级恢复新增"外部平台接管"模式:新增 annotation key `ProcessRecoverStrategy`(`ProcessRecoverExternalModeKey`)与方法 `isDealFaultByExternal()`,命中则重调度阶段跳过删 Pod、交外部平台处理,修 A3 节点 not ready 无法重调度。证据文件 component/ascend-for-volcano/internal/rescheduling/job.go、common/util/constants.go。同上 compare 链接
- vNPU [新能力] 节点初始化自动开启物理卡 device-share:新增 `enableDeviceShareMode()`,遍历 `xpu.GetCardIDs()` 对每卡 `npu-smi set -t device-share -d 1`(喂 "Y\n")并 `device-share-cfg-recover` 持久化;同时 `disablePresetVirtualDevice` 失败从 `panic` 改为 `log.Errorf`+return。证据文件 xpu-device-plugin/pkg/plugin/util/node.go、xpu/npu.go。https://gitcode.com/openFuyao/vNPU/compare/75efcb9f42057ad1549fdccc4edb64ba8f8657be...8c58a454b89831edc3b1f51a22b24852c5e5f24f
- vNPU [架构方向] 调度分配失败开始上抛:`AllocateXPUForTask` 由 void 改为返回 error,`volcano_vxpu.go` 的 AllocateFunc 捕获后置 `event.Err`,分配失败不再被静默吞掉;`GetPendingPod` 删除"列节点全 Pod 挑最早 bind"兜底、仅认节点锁身份。证据文件 volcano-xpu-plugin/plugin/task.go、volcano_vxpu.go、xpu-device-plugin/pkg/plugin/util/util.go。同上 vNPU compare 链接

## mind-cluster: d46e4038 -> 47c436e3
- 比较: https://gitcode.com/Ascend/mind-cluster/compare/d46e4038f24e1e473ecd9ba3c851fc18192ba33a...47c436e3d52121a4c1f67c36e5138fbf688d06bb | tag: v26.0.1 | commits=20 | truncated=false

### AI 总结重点(源码 diff 为据)

- **软切分场景修复挂卡错误:`Allocate` 强制走 volcano 注解分配路径**。原判定"仅当分配设备数 ≠ 全卡数 或 未预置 vDevice 时"才用 `useVolcano`;当软切分请求的 aicore 数恰好等于节点 NPU 卡数时,会走整机(whole-machine)直挂路径,导致挂卡错误。新增 `common.IsSupportSoftShareDevice()` 为第三个触发条件,使软切分场景无论设备数是否相等都走 `usePodAnnotation=true` → `ps.useVolcano(...)` 的注解分配。
  <details><summary>代码依据 component/ascend-device-plugin/pkg/server/plugin.go</summary>

  ```diff
  -		if (len(allocateDevices) != len(allNPUInfo.AllDevs) || !common.ParamOption.PresetVDevice) &&
  -			common.ParamOption.UseVolcanoType {
  +		if (len(allocateDevices) != len(allNPUInfo.AllDevs) || !common.ParamOption.PresetVDevice ||
  +			common.IsSupportSoftShareDevice()) && common.ParamOption.UseVolcanoType {
  			usePodAnnotation = true
  			allocateDevices, npuInfoConfigDir, err = ps.useVolcano(rqt.DevicesIDs)
  ```
  </details>

- **启动参数校验合并为 `checkSoftShareDevParam`,补软切分与 volcanoType 互斥约束**。原 checkParam 列表里 `checkShareDevCount` 与 `checkSoftShareDevConfigDir` 两独立项合并为一个 `checkSoftShareDevParam`,内部先跑原两项,再补新约束:`shareDevCount == MaxShareDevCount && softShareDevConfigDir != "" && volcanoType == false` 时报错"soft share device is enabled, but volcanoType must be true"——即软切分必须配合 volcano 调度。
  <details><summary>代码依据 component/ascend-device-plugin/main.go</summary>

  ```diff
  -		checkShareDevCount,
  -		checkSoftShareDevConfigDir,
  +		checkSoftShareDevParam,
  ...
  +func checkSoftShareDevParam() bool {
  +	if !checkShareDevCount() || !checkSoftShareDevConfigDir() {
  +		return false
  +	}
  +	if *shareDevCount == common.MaxShareDevCount && *softShareDevConfigDir != "" && *volcanoType == false {
  +		hwlog.RunLog.Error("soft share device is enabled, but volcanoType must be true")
  +		return false
  +	}
  +	return true
  +}
  ```
  </details>

- **`getPodFromKubelet` 默认值回退 `true`→`false`**。昨日(07-07 digest 记录)刚把"device-plugin 抽 `PodManager` 接口 + kubelet 直读"落地,今日直接把默认开关关掉:默认仍走 apiserver 读 Pod,kubelet 直读需显式开启。接口骨架保留、默认策略回退——kubelet 直读实现尚未达到默认启用的成熟度。
  <details><summary>代码依据 component/ascend-device-plugin/main.go</summary>

  ```diff
  -	getPodFromKubelet = flag.Bool("getPodFromKubelet", true,
  +	getPodFromKubelet = flag.Bool("getPodFromKubelet", false,
  		"Whether to get pod information from kubelet instead of apiserver")
  ```
  </details>

- **ascend-for-volcano 进程级恢复新增"外部平台接管删 Pod"模式**。原 `isFaultJobCanRestarted` 里对"软件故障/PreSeparateNPU 故障"统一走"由 platform 重启、跳过删 Pod";重构后:非故障 Job 直接 `return false`(带告警日志),故障 Job 若命中新方法 `isDealFaultByExternal()`(即 Job 带 annotation `ProcessRecoverStrategy` = `util.ProcessRecoverExternalModeKey`)则跳过自身删 Pod、交外部平台处理,日志文案由 "by platform" 改为 "by external"。对应修"进程级恢复场景 A3 节点 not ready 无法重调度"。
  <details><summary>代码依据 component/ascend-for-volcano/internal/rescheduling/job.go + common/util/constants.go</summary>

  ```diff
   func (fJob *FaultJob) isFaultJobCanRestarted(reScheduler *ReScheduler) bool {
   	if !fJob.IsFaultJob {
  +		klog.V(util.LogWarningLev).Infof("fJob %s is not fault job, can not be restarted", fJob.JobName)
  +		return false
  +	}
  +	if fJob.isDealFaultByExternal() {
   		klog.V(util.LogWarningLev).Infof("fJob %s has software fault or PreSeparateNPU fault, "+
  -			"need restarted by platform skip delete pod", fJob.JobName)
  +			"need restarted by external skip delete pod", fJob.JobName)
   		return false
   	}
  +// isDealFaultByExternal indicate the fault which should be deal
  +func (fJob *FaultJob) isDealFaultByExternal() bool {
  +	if _, ok := fJob.Annotations[util.ProcessRecoverExternalModeKey]; ok { ... return true }
  +	return false
  +}
  ```
  ```diff
  +	// ProcessRecoverExternalModeKey indicate the pod which is deleted by external platform in the process recover
  +	ProcessRecoverExternalModeKey = "ProcessRecoverStrategy"
  ```
  </details>

- **ascend-docker-runtime 日志目录轮转跳过"容器快照 restore 目录"**。`ChangeRuntimeLogMode` 遍历 `runLogDir` 改日志文件权限时,新增:遇到名为 `restore`(`snapshotRestore` 常量)的目录直接 `filepath.SkipDir`;并把 `counter++`/超 `maxFileNum` 判断移到 err 检查之后。配合本区间文档侧"容器快照资料"改动,指向容器快照(snapshot/restore)特性——快照 restore 目录不参与运行日志计数与权限变更。
  <details><summary>代码依据 component/ascend-docker-runtime/mindxcheckutils/mindxcheckutils.go</summary>

  ```diff
  +	snapshotRestore               = "restore"
  ...
  -		counter += 1
  -		if counter > maxFileNum {
  -			return fmt.Errorf("the counter file is over maxFileNum")
  -		}
   		if err != nil { ... return err }
  +		if fileInfo.IsDir() && fileInfo.Name() == snapshotRestore {
  +			return filepath.SkipDir
  +		}
  +		counter += 1
  +		if counter > maxFileNum { return fmt.Errorf("the counter file is over maxFileNum") }
  ```
  </details>

- **提交标题另含一条 device-plugin 掉卡故障检测方式修改**(`【k8s_rdma_shared_dev_plugin】修改掉卡故障检测方式`),但本次 patch 节选未覆盖对应 hunk,仅据标题记录不作符号级研判。

### 后续发展方向 [AI]
- **软切分(soft-share)正走向"可用默认能力"**:本次同时补上 Allocate 分配路径修复 + 启动参数互斥校验(软切分必须配 volcano),说明软切分已进入产品化打磨(修边界 bug、加防呆),而非实验特性。证据只覆盖 plugin.go 判定分支与 main.go 校验,`IsSupportSoftShareDevice()` 的具体判定条件、`useVolcano` 对软切分设备的注解写法 hunk 未在节选内。
- **kubelet 直读 Pod 暂缓默认化**:接口抽象保留但默认关闭,推断 kubelet `/pods` 直读在真实集群遇到问题(缓存一致性/权限/兼容性),回退保守默认;后续应关注 `getPodFromKubelet=true` 路径是否补测试/修 bug 后再次默认开启。证据仅默认值一行,未见回退原因的代码线索。
- **进程级恢复引入"外部平台协同"契约**:`ProcessRecoverStrategy` annotation 让上层平台接管故障 Pod 生命周期(调度器只负责不误删),指向断点续训/进程级恢复由外部 operator 编排的分工。证据只覆盖调度器侧"跳过删 Pod"判定,未见外部平台侧如何设置该 annotation、如何重建 Pod。

## vNPU: 75efcb9f -> 8c58a454
- 比较: https://gitcode.com/openFuyao/vNPU/compare/75efcb9f42057ad1549fdccc4edb64ba8f8657be...8c58a454b89831edc3b1f51a22b24852c5e5f24f | tag: v0.1.0 | commits=4 | truncated=false

### AI 总结重点(源码 diff 为据)

- **节点初始化自动开启物理卡 device-share 共享模式**。`SetNodeConfig` 新增调用 `enableDeviceShareMode()`:先 `xpu.GetCardIDs()`(新增,包 `dm.DcGetCardList()`)取本节点全部 NPU 卡 ID,逐卡 `npu-smi set -t device-share -i <cardID> -d 1`(stdin 喂 "Y\n" 自动确认),末尾再 `npu-smi set -t device-share-cfg-recover -d 1` 做重启持久化。单卡失败 `continue` 不阻断其余卡。这让 vNPU 软切分的底层"device-share"硬件模式在节点起来时自动就绪,无需手工 npu-smi。
  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/util/node.go + xpu/npu.go</summary>

  ```diff
   func SetNodeConfig() {
  +	enableDeviceShareMode()
   	if !IsSoftMode() { disablePresetVirtualDevice() }
  ...
  +func enableDeviceShareMode() {
  +	cardIDs, err := xpu.GetCardIDs()
  +	if err != nil { log.Errorf(...); return }
  +	for _, cardID := range cardIDs {
  +		cmd := exec.Command("npu-smi", "set", "-t", "device-share",
  +			"-i", strconv.FormatInt(int64(cardID), 10), "-d", "1")
  +		cmd.Stdin = strings.NewReader("Y\n")
  +		if output, err := cmd.CombinedOutput(); err != nil { log.Errorf(...); continue }
  +	}
  +	// device-share-cfg-recover 持久化
  +}
  +func GetCardIDs() ([]int32, error) {
  +	_, cardIDs, err := dm.DcGetCardList()
  +	return cardIDs, err
  +}
  ```
  </details>

- **`disablePresetVirtualDevice` 从 `panic` 降级为日志返回**。原逻辑 `npu-smi set vnpu-cfg-recover -d 0` 失败直接 `panic`,会拖垮整个进程;改为 `log.Errorf(... output)` + return,单点失败不再致命。
  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/util/node.go</summary>

  ```diff
   	output, err := cmd.Output()
   	if err != nil {
  -		panic("failed to disable virtual device:" + err.Error())
  +		log.Errorf("failed to disable virtual device: %v, output: %s", err, string(output))
  +		return
   	}
  ```
  </details>

- **调度分配失败改为向 volcano 上抛,节点锁重试 3→30**。`AllocateXPUForTask` 由 `void` 改为返回 `error`:各前置校验(task/ssn nil、node 不存在)返回具体 error,加锁逻辑抽为 `acquireNodeLock`、分配抽为 `allocateDevices`;`volcano_vxpu.go` 的 AllocateFunc 捕获返回值并置 `event.Err = err`,使分配失败真正反馈给 volcano 调度器(原先 void 被静默吞)。锁重试常量 `reducedLockRetries=3` → `maxLockRetries=30`(500ms 间隔),缓解高并发抢锁失败。
  <details><summary>代码依据 volcano-xpu-plugin/plugin/task.go + volcano_vxpu.go</summary>

  ```diff
  -	reducedLockRetries = 3
  -	lockRetryInterval  = 500 * time.Millisecond
  +	maxLockRetries    = 30
  +	lockRetryInterval = 500 * time.Millisecond
  ...
  -func (sh *ScheduleHandler) AllocateXPUForTask(task *api.TaskInfo, ssn *framework.Session) {
  +func (sh *ScheduleHandler) AllocateXPUForTask(task *api.TaskInfo, ssn *framework.Session) error {
  ...
  +	if err := sh.acquireNodeLock(nodeName, task.Pod); err != nil { return err }
  +	return sh.allocateDevices(sJob, task, node, nodeName)
  ```
  ```diff
  -			xp.Scheduler.AllocateXPUForTask(event.Task, ssn)
  +			if err := xp.Scheduler.AllocateXPUForTask(event.Task, ssn); err != nil {
  +				event.Err = err
  +			}
  ```
  </details>

- **`GetPendingPod` 删除"列节点全 Pod 挑最早 bind"兜底,仅认节点锁身份**。原实现 lock-first + 兜底:锁没命中就 `ListPods(fieldSelector spec.nodeName)` 遍历、按 `DeviceBindTime` 挑最早 `DeviceBindAllocating` 的 Pod;新实现只用 `lock.GetLockPodIdentity` 拿到 ns/name 直接 Get,拿不到锁身份即返回 error("node lock has no pod identity")。移除 `math`/`fields` 依赖与 `PodAnnotationMaxLength`/`BaseDec`/`BitSize` 常量。配套 nodelock.go 新增 `LockState` 结构 + `GetLockState`/`IsHeld`。device-plugin Allocate 的错误文案也从"user pod doesn't specify volcano scheduler"改为"no pending pod found via node lock"。
  <details><summary>代码依据 xpu-device-plugin/pkg/plugin/util/util.go + plugin.go + nodelock/nodelock.go</summary>

  ```diff
  -// GetPendingPod finds the pending pod on a specific node, lock-first with bind-time fallback
  +// GetPendingPod finds the pending pod on a specific node via node lock annotation.
  +// Only the node lock is used to identify the pod; there is no fallback path.
   func GetPendingPod(nodename string) (*v1.Pod, error) {
   	ns, name, err := lock.GetLockPodIdentity(nodename, types.VXPULockName)
  -	if err == nil && ns != "" && name != "" { ...bind-time 遍历兜底... }
  +	if err != nil { return nil, fmt.Errorf("get lock pod identity failed: %v", err) }
  +	if ns == "" || name == "" { return nil, fmt.Errorf("node lock has no pod identity on node %s", nodename) }
  ```
  ```diff
  +func GetLockState(nodeName string, lockName string) (*LockState, error) { ... }
  +func (s *LockState) IsHeld() bool { return s != nil && s.PodName != "" }
  ```
  </details>

### 后续发展方向 [AI]
- **vNPU 与 mind-cluster 在"device-share/软切分"上同频演进**:同日 mind-cluster 修软切分调度挂卡、vNPU 自动开 device-share 硬件模式,两侧都把"物理卡共享"从手工配置推向自动/默认。vNPU 走 `npu-smi device-share` + 节点锁独占 Pod 分配的路线,与 mind-cluster 的 softShareDevConfigDir+volcano 注解路线是两套实现,值得持续比对哪套成主线。证据覆盖 vNPU 节点侧 npu-smi 调用与 mind-cluster 分配判定,未见两者是否共享 CRD/注解协议。
- **调度可靠性收敛为"节点锁唯一真相源"**:GetPendingPod 删兜底、分配失败上抛、锁重试拉到 30 次,方向是让"哪个 Pod 在本节点分配设备"完全由节点锁 annotation 决定,消除"列 Pod 猜最早 bind"的不确定性。证据覆盖 util.go/task.go,未见 LockState/GetLockState 的调用方(疑为后续用于锁状态可观测或抢占判断,当前仅定义未见消费)。
- **稳定性打磨(去 panic)**:disablePresetVirtualDevice 去 panic 是把 v0.1.0 早期"失败即崩"改为容错,配合自动 device-share,指向 vNPU 正从 demo 级向可长稳运行的节点组件过渡。证据仅一处 panic→log,未见其余 panic 是否一并清理。

## 本期无实质改动(折叠)
<details><summary>7 个 openFuyao 仓无新提交</summary>

- npu-operator(335bc283,无新提交)
- npu-container-toolkit(d54256e0,无新提交)
- npu-driver-installer(9f400f3c,无新提交)
- npu-node-provision(717ef777,无新提交)
- npu-dra-plugin(dbffd794,无新提交)
- volcano-ext(c9be5c4c,无新提交)
- ub-network-device-plugin(263d6387,无新提交)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=mind-cluster sha=47c436e3d52121a4c1f67c36e5138fbf688d06bb tag=v26.0.1 scanned=2026-07-08 -->
<!-- ANCHOR repo=npu-operator sha=335bc283068ac89cf190d7e8c1d7d87d2b300cbb tag=v26.6.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=npu-container-toolkit sha=d54256e0c9568943f289a6146a5441755e17f0a8 tag=v26.6.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=npu-driver-installer sha=9f400f3c1a514f003d684f003da08176fd4ba156 tag=v26.6.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=vNPU sha=8c58a454b89831edc3b1f51a22b24852c5e5f24f tag=v0.1.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=npu-node-provision sha=717ef77727376637011fc6bd2bbeb9e24b98c530 tag=v26.6.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=npu-dra-plugin sha=dbffd7942b003f1bd4880861c167aa7a0410c9ca tag=v26.6.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=volcano-ext sha=c9be5c4c934597d99a0a80c9b26a3e919bbf8877 tag=v1.9.0 scanned=2026-07-08 -->
<!-- ANCHOR repo=ub-network-device-plugin sha=263d6387fef13dbf534d0063803d810ef723a43a tag=v26.6.0 scanned=2026-07-08 -->
