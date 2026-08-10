# NVIDIA 算力栈 diff 雷达 2026-08-11

## 摘要
- 9 仓 3 仓有新提交,均属修复/维护:gpu-operator 给 vgpu-device-manager DaemonSet 补 GPU 污点容忍;KAI-Scheduler 让 DRA/NRT 特性探测在 API discovery 失败时 fail-fast(不再静默禁用);gpu-driver-container 只是 RHEL UBI 基础镜像 digest 刷新。
- 无 API/CRD 字段增删、无 device-plugin/mig 侧能力变化;其余 6 仓无新提交。
- 唯一触及算力语义面的是 KAI 那条——它改的是 DRA 可用性判定路径的错误处理,方向仍指向 DRA/NRT 原生调度的健壮性收口,非新能力。

## 当日重要改变
- 无(gpu-operator 补容忍属部署正确性修复;KAI fail-fast 属启动健壮性修复,均未命中 API/CRD/proposal 路径)

## NVIDIA/gpu-operator: cfabcc9a -> 599e2836
- 比较: cfabcc9a8c4cc071a7120d320d0d8db79984a166 -> 599e2836 | ahead=2 | files=2 | Release: v26.3.3
- 提交: Fix: add missing toleration to vgpu-device-manager DaemonSet manifest

### AI 总结重点(源码 diff 为据)
- **vgpu-device-manager DaemonSet 补上 `nvidia.com/gpu:NoSchedule` 容忍**:此前该 manifest 只有 `nodeSelector`(`nvidia.com/gpu.deploy.vgpu-device-manager: "true"`)与 `priorityClassName`,没有对 GPU 节点常见污点 `nvidia.com/gpu`(operator 自身会打)的容忍,导致在打了该污点的节点上 vGPU device manager Pod 无法落地。本次显式加入 `Exists`/`NoSchedule` 容忍,使其能调度到被污点隔离的 GPU 节点。

  <details><summary>代码依据 assets/state-vgpu-device-manager/0600_daemonset.yaml</summary>

  ```diff
         nodeSelector:
           nvidia.com/gpu.deploy.vgpu-device-manager: "true"
         priorityClassName: system-node-critical
  +      tolerations:
  +        - key: nvidia.com/gpu
  +          operator: Exists
  +          effect: NoSchedule
         serviceAccountName: nvidia-vgpu-device-manager
  ```
  </details>

- **配套单测锁定"DaemonSet spec 为空时不覆盖已有容忍"**:`TestApplyCommonDaemonSetConfig` 新增用例,当传入的 `DaemonsetsSpec{}` 为空时,manifest 里已声明的 `nvidia.com/gpu` 容忍必须原样保留——防止 operator 的 common 变换逻辑在用户未覆写 tolerations 时把清单里硬编码的容忍抹掉。

  <details><summary>代码依据 controllers/transforms_test.go</summary>

  ```diff
  +		{
  +			description: "existing tolerations preserved when daemonsets spec is empty",
  +			ds: NewDaemonset().WithTolerations([]corev1.Toleration{
  +				{Key: "nvidia.com/gpu", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
  +			}),
  +			dsSpec: gpuv1.DaemonsetsSpec{},
  +			expectedDs: NewDaemonset().WithTolerations([]corev1.Toleration{
  +				{Key: "nvidia.com/gpu", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule},
  +			}),
  +		},
  ```
  </details>

### 后续发展方向 [AI]
- 纯部署正确性补丁:vGPU(时分/MIG 之外的 vGPU 授权路径)组件的落地能力与其余 GPU operand 对齐,证据只覆盖 vgpu-device-manager 这一个 DaemonSet 的清单 + common 变换单测,**未触及 ClusterPolicy CRD 字段、vGPU 授权/许可逻辑本身**。ClusterPolicy schema 本期未变(API 探测命中为 0)。

## kai-scheduler/KAI-Scheduler: 46a09dd1 -> 2f782392
- 比较: 46a09dd1ec1f4e934168b3e1b7ae289e20bd9157 -> 2f782392 | ahead=1 | files=11 | Release: v0.17.0
- 提交: fix(scheduler): fail fast when feature gate discovery fails (#2050) https://github.com/kai-scheduler/KAI-Scheduler/pull/2050

### AI 总结重点(源码 diff 为据)
- **DRA/NRT 特性探测从"静默吞错返 false"改为"返回 error"**:`IsDynamicResourcesEnabled` 与 `IsNodeResourceTopologyEnabled` 签名由 `... bool` 改为 `... (bool, error)`,不再在 `ServerGroups()`/`ServerVersion()` 失败时打日志并 `return false`,而是把错误 `%w` 包裹上抛。含义变化:此前 API server 启动瞬间短暂不可达会被误判为"集群不支持 DRA/NodeResourceTopology",并对整个进程生命周期锁死禁用;现在探测失败直接暴露为错误。

  <details><summary>代码依据 pkg/common/feature_gates/feature_gates.go</summary>

  ```diff
  -func IsNodeResourceTopologyEnabled(discoveryClient discovery.DiscoveryInterface) bool {
  -	logger := log.Log.WithName("feature-gates")
  +func IsNodeResourceTopologyEnabled(discoveryClient discovery.DiscoveryInterface) (bool, error) {
   	serverGroups, err := discoveryClient.ServerGroups()
   	if err != nil {
  -		logger.Error(err, "Failed to get server groups")
  -		return false
  +		return false, fmt.Errorf("failed to get server groups: %w", err)
   	}
   	for _, group := range serverGroups.Groups {
   		if group.Name == nodeResourceTopologyGroup {
  -			return true
  +			return true, nil
   		}
   	}
  -	return false
  +	return false, nil
   }
  ```
  </details>

- **`SetDRAFeatureGate` / `SetNodeResourceTopologyFeatureGate` 与 `cache.New` 全链路改为传播 error**:`SetXxxFeatureGate` 从 `void` 改为返回 `error`;`SchedulerCache` 的 `New`/`newSchedulerCache` 由返回 `Cache` 改为 `(Cache, error)`,内部原先"transform 失败/clusterInfo 失败就打日志 `return nil`"的静默降级,全部改为 `return nil, fmt.Errorf(...)`。调度器 cache 初始化不再有"半残返回 nil"的隐患。

  <details><summary>代码依据 pkg/scheduler/cache/cache.go</summary>

  ```diff
  -func New(schedulerCacheParams *SchedulerCacheParams) Cache {
  +func New(schedulerCacheParams *SchedulerCacheParams) (Cache, error) {
   	return newSchedulerCache(schedulerCacheParams)
   }
  ...
  -	featuregates.SetDRAFeatureGate(schedulerCacheParams.DiscoveryClient)
  -	featuregates.SetNodeResourceTopologyFeatureGate(schedulerCacheParams.DiscoveryClient)
  +	if err := featuregates.SetDRAFeatureGate(schedulerCacheParams.DiscoveryClient); err != nil {
  +		return nil, fmt.Errorf("failed to determine dynamic resource allocation availability: %w", err)
  +	}
  +	if err := featuregates.SetNodeResourceTopologyFeatureGate(schedulerCacheParams.DiscoveryClient); err != nil {
  +		return nil, fmt.Errorf("failed to determine node resource topology availability: %w", err)
  +	}
  ```
  </details>

- **scheduler 与 binder 两个入口都改为启动即 fail-fast**:`scheduler.go` 的 `NewScheduler` 先 `schedcache.New(...)` 拿 error 再构造 Scheduler;`cmd/binder/app/app.go` 在 `SetDRAFeatureGate` 失败时 `return nil, err` 让 binder 启动失败。changelog 一句话点明意图:"fail fast when Kubernetes API discovery fails at startup, instead of silently disabling DRA and NRT for the lifetime of the process"。

  <details><summary>代码依据 cmd/binder/app/app.go</summary>

  ```diff
  -	featuregates.SetDRAFeatureGate(kubeClient.Discovery())
  +	if err := featuregates.SetDRAFeatureGate(kubeClient.Discovery()); err != nil {
  +		setupLog.Error(err, "unable to determine dynamic resource allocation availability")
  +		return nil, err
  +	}
  ```
  </details>

### 后续发展方向 [AI]
- 方向是把 DRA/NodeResourceTopology 这类"靠 API discovery 动态判定的原生特性开关"做成硬约束:探测不到就崩,而不是带着一个错误的"DRA=off"状态跑一整个进程周期。这对 DRA 路径的可靠性是正向收口——KAI 越来越把 DRA/NRT 当作一等调度输入,容不得启动竞态导致的静默降级。证据只覆盖 feature_gates + cache/scheduler/binder 的错误传播链与其单测(erroringDiscovery 桩),**未触及 DRA 分配算法、device-plugin、GPU 共享语义,也未新增/删除 CRD 字段**(API 探测命中为 0)。

## 本期无实质改动(折叠)
<details>

- NVIDIA/gpu-driver-container — 仅 RHEL UBI 基础镜像 digest 刷新(`rhel9` ubi9 `9.8-1785906690→9.8-1786339177`、`rhel10` ubi10 `10.2-1785778137→10.2-1786324782`),无 OS 矩阵/预编译逻辑变化,不作正文
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=599e28368646116dc56a8018a068fbac6334cce1 branch=main release=v26.3.3 scanned=2026-08-11 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a996390117806acd2a73fd0e5b3e6a17755f3ae4 branch=main release=v1.20.0-rc.1 scanned=2026-08-11 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=1aedf993074e945dd73b1f9b0d3b3303d160db31 branch=main release=— scanned=2026-08-11 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=04fc23c27961f42346bcba90e7d00fc2ed818fa0 branch=main release=v0.19.3 scanned=2026-08-11 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=95932046683719c43b6a0dd9613c2e5aad5d6703 branch=main release=v0.4.1 scanned=2026-08-11 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-08-11 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-08-11 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f35ad98cc3718a432fd5d1e49d20dbc28fcaedcd branch=main release=v0.14.4 scanned=2026-08-11 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=2f782392ffd43efeccc7fb463cb6371c1144ee17 branch=main release=v0.17.0 scanned=2026-08-11 -->
</content>
</invoke>
