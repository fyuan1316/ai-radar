# HAMi diff 雷达 2026-10-31

## 摘要
- **ascend-device-plugin 当日主线:孤儿 vNPU 清理从 manager 内联方法重构为独立 `internal/cleanup` 包**——引入 node-local 分配快照 + "宽限期 10min × 连续确认 3 次"门限 + candidate/protected/**unknown** 三态,核心安全不变量是"快照不完整绝不当成空分配",把 kubelet 重启/checkpoint 过期/pod 启动中等竞态下的误销毁堵死。Release 跟进 0.2.0 → **0.2.1**。
- **volcano-vgpu-device-plugin:`getOldestPod` 从"按谓词时间猜最老 pod"改为"分配不可区分时返回 error 拒绝猜测"**——device-plugin `Allocate()` 重建"kubelet 正在为哪个 pod 分配"时,遇到排序键全相同但申请设备不同的 pod 不再瞎选,避免错配显存/卡。
- HAMi 主仓仅 docs 搬迁(Chart/README 详文挪到 website 仓),无能力/API 改动;HAMi-core、HAMi-WebUI 无新提交。

## 当日重要改变
- **ascend-device-plugin** `[新能力]` `[架构方向]` 新增顶层 package `internal/cleanup`(snapshot_kubernetes.go/reconciler.go/types.go/confirmation.go 共 ~1080 行),把 idle vNPU 回收从 `AscendManager.CleanupIdleVNPUs()` 迁出为可测的平台侧 reconciler。证据见下。 https://github.com/Project-HAMi/ascend-device-plugin/compare/ab41bec3...fff306db
- **ascend-device-plugin** `[弃用/移除]` Manager 接口删 `CleanupIdleVNPUs() error`,换成 `ListVirtualDevices`/`DestroyVirtualDevice`/`IsDeviceInUse` 三个只读+销毁原语(内部 Go 接口,非 CRD)。 https://github.com/Project-HAMi/ascend-device-plugin/commit/fff306dbb379c1e0e0a7935e3608db6a8b98cf7c

## Project-HAMi/ascend-device-plugin: ab41bec3 -> fff306db
- 比较: ab41bec367ca95ac52ed1bcb8667c33e689f8f37 -> fff306db | ahead=23 | files=29 | Release: ascend-device-plugin-0.2.1
- 比较链接: https://github.com/Project-HAMi/ascend-device-plugin/compare/ab41bec3...fff306db

### AI 总结重点(源码 diff 为据)
- **idle vNPU 回收彻底换架构**:`Manager` 接口删掉一把梭的 `CleanupIdleVNPUs() error`,改暴露三个细粒度能力 `ListVirtualDevices(logicID)`/`DestroyVirtualDevice(logicID, vdevID)`/`IsDeviceInUse(logicID)`,销毁决策移到新 `internal/cleanup` 包。清理策略因此不再绑死 CANN/Ascend 运行时,可脱离真卡单测。
  <details><summary>代码依据 internal/manager/manager.go</summary>

  ```diff
  - CleanupIdleVNPUs() error
  + ListVirtualDevices(logicID int32) ([]VirtualDevice, error)
  + DestroyVirtualDevice(logicID int32, vdevID uint32) error
    IsHamiVnpuCore() bool
  + IsDeviceInUse(logicID int32) (bool, error)
  ```
  </details>
- **新增只读硬件视图 `VirtualDevice`**:reconciler 只拿做"安全清理决策"所需字段(LogicID/VDevID/CardID/TemplateName/IsContainerUsed/Ignored),刻意不依赖驱动查询结构体。`ListVirtualDevices` 里 `IsContainerUsed` 直接来自驱动 `QueryInfo`,`Ignored` 来自 cleanup 过滤(UUID/卡过滤命中则跳过清理)。
  <details><summary>代码依据 internal/manager/manager.go</summary>

  ```diff
  +type VirtualDevice struct {
  +	LogicID         int32
  +	VDevID          int32
  +	CardID          int32
  +	DeviceID        int32
  +	TemplateName    string
  +	IsContainerUsed int32
  +	Ignored         bool
  +}
  ```
  </details>
- **"不完整快照 ≠ 空分配"被定为硬不变量**:`PodAllocationSnapshot` 与硬件 manager 刻意解耦,返回"完整 node-local 视图"或"不完整/unknown",注释明确不完整结果绝不能被当作空分配来清卡;claim 三态 candidate/protected/**unknown** 固化这一点。同一 `IdleVNPUReconciler` 接口同时服务启动期与周期清理,防 kubelet 重启路径绕过安全检查。
  <details><summary>代码依据 internal/cleanup/types.go (added)</summary>

  ```diff
  +// PodAllocationSnapshot is deliberately separate from the hardware manager.
  +// It returns a complete node-local view or an incomplete/unknown result; an
  +// incomplete result must never be interpreted as an empty allocation.
  +type PodAllocationSnapshot interface {
  +	Snapshot(ctx context.Context) (AllocationSnapshot, error)
  +}
  +const (
  +	ClaimCandidate ClaimState = "candidate"
  +	ClaimProtected ClaimState = "protected"
  +	ClaimUnknown   ClaimState = "unknown"
  +)
  ```
  </details>
- **回收门限 = 连续确认次数 + 宽限期双闸,且防重启"偷跑"**:`confirmationTracker.observe` 要求某张卡 `count >= confirmations`(默认 3)且 `now - graceSince >= grace`(默认 10min)才判可回收;`graceSince` 取 `firstSeen` 与 `candidateSince` 的较晚者,注释点明"绝不让重启后从旧快照恢复的 candidateSince 缩短本进程宽限期",`firstSeen` 仅初始化一次作为安全下界。
  <details><summary>代码依据 internal/cleanup/confirmation.go (added)</summary>

  ```diff
  +	graceSince := state.firstSeen
  +	if state.candidateSince.After(graceSince) {
  +		graceSince = state.candidateSince
  +	}
  +	return state.count >= confirmations && now.Sub(graceSince) >= grace
  ```
  </details>
- **k8s 侧快照由 informer + kubelet checkpoint 双源构成**:`KubernetesPodSnapshot` 持 `podLister`(informer)和 `checkpointPath`(默认 `/var/lib/kubelet/device-plugins/kubelet_internal_checkpoint`),并带 `staleCheckpoint` 过期跟踪(默认宽限 10min、确认 3 次),处理"失败 pod / 过期 checkpoint"场景。
  <details><summary>代码依据 internal/cleanup/snapshot_kubernetes.go (added)</summary>

  ```diff
  +const (
  +	defaultStaleCheckpointGrace         = 10 * time.Minute
  +	defaultStaleCheckpointConfirmations = 3
  +)
  +type checkpointStaleState struct {
  +	firstAbsent time.Time
  +	count       int
  +}
  ```
  </details>
- **npu-smi 调用全面加超时,防挂死拖垮注册回路**:`runNpuSmi` 统一走 `exec.CommandContext` + `cmd.WaitDelay=1s`,默认 `npuSmiTimeout=30s`,启动期 `multi-die-policy` 探测用更短的 `multiDiePolicyTimeout=10s`。注释说明该调用在 `watchAndRegister` 循环里随 chip 等待 device-share 时触发,npu-smi 挂死会连带阻塞 kubelet 设备更新与 HAMi 节点注册。并配 `keep serving when one chip refuses device-share`:新增 `shareTarget` 结构,单 chip 拒绝 device-share 不再整体失败。
  <details><summary>代码依据 internal/server/device_share.go</summary>

  ```diff
  +var npuSmiTimeout = 30 * time.Second
  +var multiDiePolicyTimeout = 10 * time.Second
  -	cmd := exec.Command(bin, args...)
  +	timeout := npuSmiTimeout
  +	ctx, cancel := context.WithTimeout(context.Background(), timeout)
  +	cmd := exec.CommandContext(ctx, bin, args...)
  +	cmd.WaitDelay = time.Second
  +	if ctx.Err() == context.DeadlineExceeded {
  +		return out, fmt.Errorf("npu-smi %s: timed out after %s", strings.Join(args, " "), timeout)
  ```
  </details>
- **构建/供应链硬化(非能力)**:Dockerfile 新增 data-only arm64 stage 从 pin 死的公共镜像 `ghcr.io/dynamia-ai/enpu-runtime:1.0.0-cann9.1.0-r1@sha256:9c50…` 取 ENPU 运行时,拆 `runtime`/`runtime-local`/`runtime-base` 多阶段,go mod 下载层与源码分离缓存,wget 加重试;CI 改原生 amd64/arm64 matrix 构建、checkout 升 v7、新增 `verify-chart-version-bump.sh` 闸门(默认镜像变了但 chart 版本没 bump 则 fail CI)。

### 后续发展方向 [AI]
- 昇腾 vNPU 的"自动回收"正从"能跑"走向"敢在生产自动跑":三态 claim + 双闸确认 + "不完整快照不清卡" + 重启防偷跑,整套都是在给"自动销毁 vNPU"这个高危动作加保险。方向是让 ascend-device-plugin 在节点抖动/kubelet 重启场景下也能安全自愈孤儿 vNPU,而不需要人工介入。证据覆盖 cleanup 包的接口/门限/快照三块与 manager 接口改造;未见 reconciler.go 的完整 `Reconcile()` 主循环 hunk(被截断),也未见周期触发的调用点(cmd/main.go 仅 19 行改动,未展开),"启动期 vs 周期"两条触发路径的实际接线待后续 PR 展开确认。
- npu-smi 超时 + 单 chip 容错是把"注册回路"当关键路径在加固,指向多卡节点上"一张卡坏/驱动卡住不拖垮整节点注册"的可用性目标。证据仅 device_share.go 的超时与 shareTarget,未见 watchAndRegister 全量循环。

## Project-HAMi/volcano-vgpu-device-plugin: bb24c715 -> 77206460
- 比较: bb24c7155c7ab65d4061aa7a6b4b6513525eb06a -> 77206460 | ahead=17 | files=28 | Release: —
- 比较链接: https://github.com/Project-HAMi/volcano-vgpu-device-plugin/compare/bb24c715...77206460

### AI 总结重点(源码 diff 为据)
- **`getOldestPod` 由"猜"改为"拒绝猜"**:签名从 `(...) *v1.Pod` 改为 `(...) (*v1.Pod, error)`。旧逻辑把所有匹配 pod 收进 `filteredPods` 再按谓词时间选最老的 `oldest`;新逻辑遍历时用 `podOrderLess` 定序,一旦出现"排序键不分先后(`!podOrderLess` 双向成立)但 `AssignedIDsToAllocateAnnotations` 不同"的 pod,记为 `ambiguous` 并最终报错——device-plugin 在 `Allocate()` 里重建"kubelet 正给哪个 pod 分配"时,kubelet 不传 pod 身份,无法区分就当错误而非瞎选。另新增跳过 `DeviceBindPhase == success/failed` 的 pod。
  <details><summary>代码依据 pkg/util/util.go</summary>

  ```diff
  -func getOldestPod(pods []v1.Pod, nodename string, gpuAmount int) *v1.Pod {
  +// ... pods that tie on every ordering key and ask for different
  +// devices cannot be told apart; that is an error, not a guess.
  +func getOldestPod(pods []v1.Pod, nodename string, gpuAmount int) (*v1.Pod, error) {
  +		if phase := pod.Annotations[DeviceBindPhase]; phase == DeviceBindSuccess || phase == DeviceBindFailed {
  +			continue
  +		}
  +		switch {
  +		case oldest == nil, podOrderLess(pod, oldest):
  +			oldest, ambiguous = pod, nil
  +		case !podOrderLess(oldest, pod) &&
  +			pod.Annotations[AssignedIDsToAllocateAnnotations] != oldest.Annotations[AssignedIDsToAllocateAnnotations]:
  +			ambiguous = pod
  +		}
  ```
  </details>
- **`Allocate()` 的 node lock 释放失败不再静默**:`GetPendingPod` 返错或无 pending pod 时释放 node lock,旧代码直接丢弃 `ReleaseNodeLock` 返回值,新代码失败时 `klog.Errorf` 记录;`grpc.DialContext` 弃用改 `NewClient`,引入 `connectivity` 包。
  <details><summary>代码依据 pkg/plugin/server.go</summary>

  ```diff
  -		nodelock.ReleaseNodeLock(nodeName, util.VGPUDeviceName)
  +		if lerr := nodelock.ReleaseNodeLock(nodeName, util.VGPUDeviceName); lerr != nil {
  +			klog.Errorf("release node lock failed: %v", lerr)
  +		}
  ```
  </details>
- **设备名解码修正有符号/无符号歧义**:`pkg/rm/helper.go` 把 `uint8Slice`(`[]uint8`)整体改名 `int8Slice`(`[]int8`),append 时 `byte(c)` 转换。对应 NVML 返回的 C `char` 在不同架构上符号性不同,原 `uint8` 假设在 ARM 等平台会读错设备名。
  <details><summary>代码依据 pkg/rm/helper.go</summary>

  ```diff
  -type uint8Slice []uint8
  -func (s uint8Slice) String() string {
  +type int8Slice []int8
  +func (s int8Slice) String() string {
  -		b = append(b, c)
  +		b = append(b, byte(c))
  ```
  </details>
- **构建供应链硬化(非能力)**:`Dockerfile.ubuntu20.04` 把 `ubuntu:25.10` 换 `ubuntu:26.04@sha256:6a06…` digest pin,Go `1.26.9→1.26.10` 且下载后 `sha256sum -c` 校验(新增 amd64/arm64 两个 GO_SHA256),`nvidia-mig-parted` 从 `@latest` 钉到 `@v0.15.1`,CUDA 基镜像也加 digest。另加 golangci-lint CI job、pod/node 解码器 fuzz 测试、`DecodeNodeDevices` 的 int32 越界防护(commit `fix(util): bound int32 conversion`)。

### 后续发展方向 [AI]
- 这批几乎全是 device-plugin `Allocate` 回路的鲁棒性/正确性收口(拒绝歧义分配、锁释放可观测、跨架构设备名、越界防护)+ 供应链 pin 死,属"把软切分数据面做稳",非新切分能力。证据覆盖 util.go/server.go/helper.go/Dockerfile;int32 越界与 fuzz 仅见 commit 标题与文件名、未展开 hunk,具体边界条件待看 util_test.go。

## 本期无实质改动(折叠)
<details><summary>EMPTY / docs-only repo</summary>

- **Project-HAMi/HAMi**(master, def0bf82):仅 `docs: move Chart content to website (#3296)`——`charts/hami/README.md` 手写部分删掉 v2.11 字段迁移大表、改为指向 website 文档链接,README.md/cn/ja 精简为概览+导航,CLAUDE.md 新增"详文归 website 仓"治理条款,新增 `AGENTS.md`(内容仅一行 `CLAUDE.md`)。**无代码/能力/API 改动**,不计重要改变。 https://github.com/Project-HAMi/HAMi/pull/3296
- **Project-HAMi/HAMi-core**(main, 6736b058):无新提交。
- **Project-HAMi/HAMi-WebUI**(main, 4f5875cf):无新提交。
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=def0bf82074ca7aff940800c18d5d3402eef5cff branch=master release=v2.10.0 scanned=2026-10-31 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=6736b0589049390ec945bd40dfb4769f9f043def branch=main release=— scanned=2026-10-31 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=77206460af6fa83cd0655b780a6df3ddb8578413 branch=main release=— scanned=2026-10-31 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=fff306dbb379c1e0e0a7935e3608db6a8b98cf7c branch=main release=ascend-device-plugin-0.2.1 scanned=2026-10-31 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4f5875cf561bd831cef7dde2177117f1d39687f9 branch=main release=v1.3.0 scanned=2026-10-31 -->
