# HAMi diff 雷达 2026-07-18

## 摘要
- HAMi 主仓给调度器 Bind 阶段加了 **PodGroup(gang)感知的 NodeLock 重试**:PodGroup 成员抢不到节点锁时不再 fail-fast,而是在 `NodeLockRetryTimeout` 内轮询重试,避免同组 Pod 因锁竞争互相拖死。
- 修掉一个稳定性坑:更新 leader label 的瞬时 API 报错以前会 `klog.Fatalf` 直接把 scheduler 进程干崩,现在改成记日志 + return。
- AMD vGPU 设计文档大改(#2067):单位 MB→MiB、cores 语义从 MB→百分比/CU 数,CU 掩码环境变量 `ROC_GLOBAL_CU_MASK`→`HSA_CU_MASK`,并规划 CDNA(非 WGP)先行、RDNA(WGP)后续需成对对齐——协议层信号,代码尚未落地但方向明确。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 调度器 Bind 新增 gang-scheduling 感知的节点锁重试逻辑(`acquireNodeLocks`/`lockAllDevices`/`releaseAllDevices` + `NodeLockRetryTimeout` 配置 + `ErrNodeLockContention` 哨兵错误),识别 `scheduling.x-k8s.io/pod-group` 标签。证据:pkg/scheduler/scheduler.go、pkg/util/nodelock/nodelock.go https://github.com/Project-HAMi/HAMi/pull/2066
- Project-HAMi/HAMi [架构方向] AMD vGPU 分配协议重构(设计文档):device-plugin 由 cuCount 推算非重叠 CU range,注入 `ROCR_VISIBLE_DEVICES`/`HSA_CU_MASK`/`HIP_DEVICE_MEMORY_LIMIT`,弃用旧的 `amd.com/cu-mask` JSON 注解,新增 `hami.io/amd-devices-to-allocate`。证据:docs/develop/amd-vgpu.md https://github.com/Project-HAMi/HAMi/pull/2067

## Project-HAMi/HAMi: 03be4d85 -> 125c8c62
- 比较: 03be4d85fdab0a3d532a610b5f420c5375551aeb -> 125c8c62 | ahead=6 | files=16 | Release: v2.9.0
- https://github.com/Project-HAMi/HAMi/compare/03be4d85fdab0a3d532a610b5f420c5375551aeb...125c8c62

### AI 总结重点(源码 diff 为据)

- **Bind 阶段引入 PodGroup 感知的节点锁重试,取代无差别 fail-fast**。新增 `acquireNodeLocks`:非 PodGroup 成员或 `NodeLockRetryTimeout<=0` 时走原有一次性 `lockAllDevices`;PodGroup 成员则在 deadline 内每 100ms 重试,失败先 `releaseAllDevices` 回滚已拿到的设备锁,只有 `IsNodeLockContention` 类错误才重试,其他错误直接返回。语义:同一 gang 的多个 Pod 并发落到同一节点时,不再因为一个成员先占锁就把其余成员判失败,降低整组调度失败率。判定 gang 成员看 `scheduling.x-k8s.io/pod-group` 标签(scheduler-plugins Coscheduling 约定)。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  +func (s *Scheduler) acquireNodeLocks(node *corev1.Node, pod *corev1.Pod) error {
  +	if !util.IsPodGroupMember(pod) || config.NodeLockRetryTimeout <= 0 {
  +		return s.lockAllDevices(node, pod)
  +	}
  +	deadline := time.Now().Add(config.NodeLockRetryTimeout)
  +	for {
  +		err := s.lockAllDevices(node, pod)
  +		if err == nil {
  +			return nil
  +		}
  +		s.releaseAllDevices(node, pod)
  +		if !nodelockutil.IsNodeLockContention(err) {
  +			return err
  +		}
  +		if time.Now().After(deadline) {
  +			return fmt.Errorf("timed out after %v waiting for node %s to be unlocked: %w",
  +				config.NodeLockRetryTimeout, node.Name, nodelockutil.ErrNodeLockContention)
  +		}
  +		select {
  +		case <-s.stopCh:
  +			return fmt.Errorf("scheduler shutting down while waiting for node lock: %w", nodelockutil.ErrNodeLockContention)
  +		case <-time.After(100 * time.Millisecond):
  +		}
  +	}
  +}
  ```
  </details>

- **锁竞争从"模糊错误字符串"升级为可判定的哨兵错误**。`nodelock.LockNode` 在锁被占用时以前只返回普通 `fmt.Errorf`,现在 `%w` 包裹新导出的 `ErrNodeLockContention`,并给出 `IsNodeLockContention(err)` 判定函数——这正是上面重试逻辑区分"该重试的锁竞争"vs"该直接失败的其他错误"的依据。
  <details><summary>代码依据 pkg/util/nodelock/nodelock.go</summary>

  ```diff
  +// ErrNodeLockContention indicates the node lock is currently held by another
  +// valid pod. Callers may retry this error when the caller is a PodGroup member.
  +var ErrNodeLockContention = errors.New("node lock contention")
  +
  +func IsNodeLockContention(err error) bool {
  +	return errors.Is(err, ErrNodeLockContention)
  +}
  ...
  -	return fmt.Errorf("node %s has been locked within %v", nodeName, NodeLockTimeout)
  +	return fmt.Errorf("node %s has been locked within %v: %w", nodeName, NodeLockTimeout, ErrNodeLockContention)
  ```
  </details>

- **新增 gang 成员判定与配置项**。`util.IsPodGroupMember` 靠 `PodGroupLabel = "scheduling.x-k8s.io/pod-group"` 是否非空判断;`config.NodeLockRetryTimeout` 为 0 时禁用重试(保持旧的 fail-fast 行为),即该能力默认 opt-in、不改变现网默认语义。
  <details><summary>代码依据 pkg/util/util.go + pkg/util/types.go + pkg/scheduler/config/config.go</summary>

  ```diff
  +func IsPodGroupMember(pod *corev1.Pod) bool {
  +	if pod == nil {
  +		return false
  +	}
  +	return pod.Labels[PodGroupLabel] != ""
  +}
  +	// PodGroupLabel is the label used by scheduler-plugins Coscheduling to mark
  +	PodGroupLabel = "scheduling.x-k8s.io/pod-group"
  +	// NodeLockRetryTimeout is how long Bind retries LockNode when contended by
  +	// another PodGroup member. Zero disables retry (fail-fast).
  +	NodeLockRetryTimeout time.Duration
  ```
  </details>

- **leader label 更新失败不再拖垮进程**。`updateSchedulerLabel` 里两处 `klog.Fatalf`(list scheduler pods 失败 / patch leader label 失败)改成 `klog.ErrorS` + `return`。前:leader 选举期间一次瞬时 API error 直接 exit 整个 scheduler;后:降级为日志,进程存活。属可用性硬化。
  <details><summary>代码依据 pkg/scheduler/scheduler.go</summary>

  ```diff
  -		klog.Fatalf("Failed to list hami scheduler pods from lister: namespace %s selector %s",
  -			os.Getenv("POD_NAMESPACE"), schedulerSelector.String(),
  -		)
  +		klog.ErrorS(err, "Failed to list hami scheduler pods from lister",
  +			"namespace", os.Getenv("POD_NAMESPACE"), "selector", schedulerSelector.String(),
  +		)
  +		return
  ```
  </details>

- **AMD vGPU 分配协议被重写(目前落在设计文档,代码未随此 PR 落地)**。要点:①单位纠正 MB→MiB,`gpucores` 语义从 MB 改为 CU 百分比;②CU 掩码环境变量从 `ROC_GLOBAL_CU_MASK` 换成 ROCm 官方的 `HSA_CU_MASK`;③协议从"scheduler 写 `amd.com/cu-mask` JSON 注解"改成"device-plugin 在 Allocate 时读 `hami.io/amd-devices-allocated`、把每设备 cuCount 转成非重叠 CU range,注入 `ROCR_VISIBLE_DEVICES`/`HSA_CU_MASK`/`HIP_DEVICE_MEMORY_LIMIT`";④新增 `hami.io/amd-devices-to-allocate` 注解;⑤铺开范围:先 CDNA(非 WGP,CU 可任意选)、后 RDNA(WGP,掩码须成对对齐否则 `HSA_CU_MASK` 非法)。
  <details><summary>代码依据 docs/develop/amd-vgpu.md</summary>

  ```diff
  -Masking (`ROC_GLOBAL_CU_MASK`) assigns an arbitrary and fine-grained per-pod CU partitioning ...
  +Masking (`HSA_CU_MASK`) assigns fine-grained, hardware-valid per-pod CU partitioning ...
  -hami.io/amd-devices-allocated: <UUID>,AMDGPU,<memMB>,<cuCount>:;
  +hami.io/amd-devices-to-allocate: <UUID>,AMDGPU,<memMiB>,<cuCount>:;
  +hami.io/amd-devices-allocated:   <UUID>,AMDGPU,<memMiB>,<cuCount>:;
  +During `Allocate`, the device-plugin reads `hami.io/amd-devices-allocated` ...
  +converts each device's `cuCount` into a non-overlapping CU range ...
  ```
  </details>

- **CI 修复:chart 版本号符合 SemVer**。`charts/Makefile` 里 `chart_version` 从简单 `tr -d 'v'` 改为 `sed` 去前缀 + 把纯数字预发布后缀 `2.9.0-0749842`(git short SHA,含前导零)重写为 `2.9.0-g0749842`——SemVer 禁止数字预发布标识含前导零,helm 会拒。加 `g` 前缀(git-describe 风格)让标识变字母数字。纯 CI/发布链修复,不影响运行时。
  <details><summary>代码依据 charts/Makefile</summary>

  ```diff
  -	chart_version=`echo $(VERSION) | tr -d 'v'`; \
  +	chart_version=`echo $(VERSION) | sed 's/^[vV]//' | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$$/\1-g\2/'`; \
  ```
  </details>

### 后续发展方向 [AI]
- **gang/coscheduling 是 HAMi 调度器当前的主攻方向**。此前(见 07-17 digest)已加 PodGroup 相关重试雏形,今天把它做成 Bind 阶段完整的"锁竞争→重试→回滚→超时"闭环,并对齐 scheduler-plugins 的 `scheduling.x-k8s.io/pod-group` 标签约定。趋势:HAMi 正把自己从"单 Pod 抢占式设备锁"演进到"能安全承接 gang 调度器(Volcano/Coscheduling)整组下发"。证据只覆盖 scheduler/nodelock/util 三处 hunk 与配置项,未见 e2e 或 webhook 侧对 PodGroup 的进一步处理。
- **AMD vGPU 从"能跑"走向"协议标准化 + 硬件正确性"**。文档明确对齐 ROCm 官方 `HSA_CU_MASK`、区分 CDNA/RDNA 的 WGP 成对约束,并把 CU range 计算下沉到 device-plugin。趋势指向 AMD 路径逐步与 NVIDIA/Ascend 拉平(统一 `hami.io/*-devices-allocated` 注解族)。证据只覆盖 docs/develop/amd-vgpu.md 的文档 hunk,本 PR 未见对应 `pkg/device/amd` 的代码实现,属"先定协议后落码",需下期跟踪代码是否跟上。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=125c8c627e20fc85b82e1728a684ae5757741a5b branch=master release=v2.9.0 scanned=2026-07-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=06e698079335cffd0009f3c119bd95b012600ae5 branch=main release=— scanned=2026-07-18 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6561f1c10e98589002939768194f332e44edddaf branch=main release=— scanned=2026-07-18 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=f062939e14354a96fb8bfabd3c103d9d8f6de6c2 branch=main release=— scanned=2026-07-18 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=c59f77693238dc2f08b83c42c9e410bca04e81ed branch=main release=hami-webui-1.2.0 scanned=2026-07-18 -->
