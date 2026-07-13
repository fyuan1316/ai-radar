# NVIDIA 算力栈 diff 雷达 2026-07-14

## 摘要
- KAI-Scheduler 一次性落地两块能力:**PodGroup 新增 `preemptionDelay` 字段**(API/CRD 变更,抢占前必须挂起的最短时间,锚定 max(创建时间, 上次被驱逐时间)),以及 **Karta 通用 pod grouper fallback 插件**(默认开启,给没有原生 plugin 的 workload GVK 兜底做 gang 分组)——两者都是把 run:ai 的调度语义继续搬进开源调度器。
- NVIDIA driver 容器化栈出现一条贯穿 gpu-operator↔mig-parted 的**新部署标签 `nvidia.com/gpu.deploy.client`**:MIG 静态重配时会把第三方(非 operator 自管)GPU 客户端 pod 一并暂停/恢复,补上此前 MIG apply 只管自家组件的盲区。
- gpu-driver-container 新增 **arm64(sbsa)预编译数据中心驱动容器**(Ubuntu 24.04),是 driver 预编译矩阵向 ARM 服务器扩张的实锤。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [API/CRD变更] `PodGroupSpec` 新增 `preemptionDelay *metav1.Duration` 字段并同步进 CRD,新增 `PreemptionDelayNotElapsed` 不可调度原因;抢占/回收/整合动作在延迟窗口内被抑制。 https://github.com/kai-scheduler/KAI-Scheduler/pull/1886 https://github.com/kai-scheduler/KAI-Scheduler/pull/1890
- kai-scheduler/KAI-Scheduler [新能力] 新增 `pkg/podgrouper/podgrouper/plugins/karta` 包 + `GenericKartaFallback` 配置项(默认 true),为无原生 plugin 的 workload 提供 Karta 驱动的 gang 分组兜底。 https://github.com/kai-scheduler/KAI-Scheduler/pull/1877
- NVIDIA/mig-parted + NVIDIA/gpu-operator [新能力] 新增部署标签 `nvidia.com/gpu.deploy.client`,MIG 重配流程会暂停/等待/恢复第三方 GPU 客户端 pod。 https://github.com/NVIDIA/mig-parted/compare/b52cf9c9...4f279a9f https://github.com/NVIDIA/gpu-operator/compare/be25c4f2...17c08086
- NVIDIA/gpu-driver-container [新能力] 预编译数据中心驱动容器扩到 arm64(sbsa CUDA repo、跳过 i386/fbc1/secure-boot 签名),Ubuntu 24.04。 https://github.com/NVIDIA/gpu-driver-container/compare/65b0904e...1ea5e0fc

## kai-scheduler/KAI-Scheduler: b63badc9 -> 20d04b76
- 比较 / Release: https://github.com/kai-scheduler/KAI-Scheduler/compare/b63badc9...20d04b76 | ahead=6 | Release v0.16.4
### AI 总结重点(源码 diff 为据)
- **抢占延迟(preemption delay)成为 PodGroup 一等公民**:`v2alpha2.PodGroupSpec` 加了 `PreemptionDelay *metav1.Duration`(protobuf 字段 9),语义是"该 PodGroup 挂起满这段时间后才允许触发对**别人**的驱逐(preempt/reclaim/consolidation),不影响它占用空闲容量、也不影响它自身被驱逐"。计时锚点取 `max(创建时间, 上次被驱逐时间)`,由 `PodGroupInfo.LastEvictionTimestamp` 承载,从 PodGroup annotation `LastEvictionTimeStamp` 解析(RFC3339)。判定逻辑落在新方法 `PreemptionDelayEnd()` / `IsWithinPreemptionDelay(now)`。
  <details><summary>代码依据 pkg/apis/scheduling/v2alpha2/podgroup_types.go + pkg/scheduler/api/podgroup_info/job_info.go</summary>

  ```diff
  +	// PreemptionDelay is the minimal time the PodGroup must be pending, counted from
  +	// max(creation time, last eviction time), before it may trigger eviction of other
  +	// workloads (preempt, reclaim and consolidation actions). It does not affect plain
  +	// allocation into free capacity, nor the PodGroup's own evictability.
  +	PreemptionDelay *metav1.Duration `json:"preemptionDelay,omitempty" protobuf:"bytes,9,opt,name=preemptionDelay"`
  ```
  ```diff
  +func (pgi *PodGroupInfo) PreemptionDelayEnd() *time.Time {
  +	if pgi.PodGroup == nil || pgi.PodGroup.Spec.PreemptionDelay == nil ||
  +		pgi.PodGroup.Spec.PreemptionDelay.Duration <= 0 {
  +		return nil
  +	}
  +	anchor := pgi.CreationTimestamp.Time
  +	if pgi.LastEvictionTimestamp != nil && pgi.LastEvictionTimestamp.After(anchor) {
  +		anchor = *pgi.LastEvictionTimestamp
  +	}
  +	end := anchor.Add(pgi.PodGroup.Spec.PreemptionDelay.Duration)
  +	return &end
  +}
  ```
  </details>
- **配置面用两种入口**:CRD `scheduling.run.ai_podgroups.yaml` 加了 `preemptionDelay`(string 类型),同时 #1890 把用户侧 API 从 spec 字段"下沉"为 **pod annotation**(commit "move preemption-delay API to a pod annotation"),spec 字段作为内部承载保留——即对用户暴露 annotation、内部编译进 PodGroupSpec。新增不可调度原因常量 `PreemptionDelayNotElapsed`。
  <details><summary>代码依据 deployments/kai-scheduler/crds/scheduling.run.ai_podgroups.yaml + podgroup_types.go</summary>

  ```diff
  +              preemptionDelay:
  +                description: |-
  +                  PreemptionDelay is the minimal time the PodGroup must be pending, counted from
  +                  max(creation time, last eviction time) ...
  +                type: string
  ```
  ```diff
  +	// PreemptionDelayNotElapsed means the pod group is within its preemption delay window
  +	// and may not yet trigger eviction of other workloads.
  +	PreemptionDelayNotElapsed UnschedulableReason = "PreemptionDelayNotElapsed"
  ```
  </details>
- **Karta 通用分组 fallback 插件**:新增 `pkg/podgrouper/podgrouper/plugins/karta`(grouper.go/hub.go/component_matching.go 等),`KartaGrouper` 读取 run.ai Karta CRD 的 `GangSchedulingInstructions`,分 v2(`PodGroupComponentsMapping`)与 alpha 两条路径生成 PodGroup 元数据;无 Karta 指令时回退 defaultGrouper。开关 `GenericKartaFallback *bool` 加进 `pod_grouper.Args`,`SetDefaultsWhereNeeded` 默认置 true,并写进 `kai.scheduler_configs.yaml` CRD。意味着任意没有原生 grouper plugin 的 GVK 都能被 Karta 兜底做 gang。
  <details><summary>代码依据 pkg/apis/kai/v1/pod_grouper/pod_grouper.go + plugins/karta/grouper.go</summary>

  ```diff
  +	// GenericKartaFallback specifies whether to enable Karta-backed generic pod grouping fallback for workload GVKs without native plugins. Default is true.
  +	GenericKartaFallback *bool `json:"genericKartaFallback,omitempty"`
  ...
  +	pg.Args.GenericKartaFallback = common.SetDefault(pg.Args.GenericKartaFallback, ptr.To(true))
  ```
  ```diff
  +func (g *KartaGrouper) GetPodGroupMetadata(topOwner *unstructured.Unstructured, pod *v1.Pod, ...) (*podgroup.Metadata, error) {
  +	gangScheduling := g.getGangSchedulingInstructions()
  +	if gangScheduling == nil {
  +		return g.defaultGrouper.GetPodGroupMetadata(topOwner, pod)
  +	}
  +	if gangScheduling.PodGroup != nil {
  +		return g.getPodGroupMetadataV2(ctx, topOwner, pod, gangScheduling.PodGroup)
  +	}
  +	return g.getPodGroupMetadataAlpha(ctx, topOwner, pod)
  +}
  ```
  </details>
### 后续发展方向 [AI]
- preemptionDelay 是给"抖动型/短命抢占者"上闸:防止一个刚起来的高优 job 立刻掀翻一批 running workload,再被自己也很快让位,造成集群反复驱逐。锚点含"上次被驱逐时间"说明设计上要处理被驱逐→重排→再抢占的循环。证据只覆盖 API 字段与判定函数(job_info.go),**未见 preempt/reclaim action 里实际消费 `IsWithinPreemptionDelay` 的调用点**(该 hunk 不在节选内),抑制的具体触发路径待下期确认。
- Karta fallback 默认开启,是 KAI 把 run:ai 私有的 Karta gang 语义作为"通用兜底"推给全体 workload 的信号——开源调度器正从"针对已知 CRD 的 grouper 矩阵"转向"未知 GVK 也能 gang"。证据覆盖插件入口与开关默认值,未展开 `hub.go` 的 Karta 结构匹配细节。

## NVIDIA/mig-parted: b52cf9c9 -> 4f279a9f
- 比较 / Release: https://github.com/NVIDIA/mig-parted/compare/b52cf9c9...4f279a9f | ahead=2 | Release v0.14.3
### AI 总结重点(源码 diff 为据)
- **MIG 重配时新增"第三方 GPU 客户端 pod"的暂停/恢复闭环**:`reconfigure.go` 加了标签常量 `gpuClientDeployLabel = "nvidia.com/gpu.deploy.client"` 和字段 `gpuClientDeployed`,与已有的 device-plugin/gfd/dcgm/nvsm 部署标签并列。`shutdownKubernetesGPUClients()` / `restartKubernetesGPUClients()` / `setState()` 在该标签非空时把它一并设为 paused/true;`waitForPodsToBeDeleted()` 新增等待带 `nvidia.com/gpu.deploy.client` nodeSelector 的 daemonset pod 退出。即 MIG 静态切分 apply 前,能把用户自带、贴了该标签的 GPU 消费 pod 也优雅赶下节点,避免切分时 GPU 被占用。
  <details><summary>代码依据 pkg/mig/reconfigure/reconfigure.go</summary>

  ```diff
  +	gpuClientDeployLabel           = "nvidia.com/gpu.deploy.client"
  ...
  +	if len(r.gpuClientDeployed) > 0 {
  +		labels[gpuClientDeployLabel] = r.maybeSetPaused(r.gpuClientDeployed)
  +	}
  ...
  +	log.Infof("Waiting for any daemon set pods with nodeSelector key %s to shutdown", gpuClientDeployLabel)
  +	if err := r.waitForPodsWithNodeSelector(gpuClientDeployLabel, timeout); err != nil {
  +		return fmt.Errorf("third-party gpu client pods did not shutdown: %w", err)
  +	}
  ```
  </details>
### 后续发展方向 [AI]
- 这条标签是 mig-parted 与 gpu-operator 协同的产物(gpu-operator 同期提交标题即 "add new deploy label to manage third-party gpu client pods"),把 MIG 重配的"停机面"从 NVIDIA 自管组件扩到用户工作负载,是 operator 想在生产集群里更安全地做 MIG 动态切换的前置动作。证据覆盖 reconfigure 全流程标签注入,未见 gpu-operator 侧 `state_manager.go` 具体如何下发该标签(该 patch 不在节选内)。

## NVIDIA/gpu-driver-container: 65b0904e -> 1ea5e0fc
- 比较 / Release: https://github.com/NVIDIA/gpu-driver-container/compare/65b0904e...1ea5e0fc | ahead=2 | Release —
### AI 总结重点(源码 diff 为据)
- **预编译数据中心驱动容器支持 arm64**:Ubuntu 24.04 precompiled Dockerfile 与安装脚本按 `$TARGETARCH` 分叉——arm64 走 CUDA `sbsa` repo(非 x86_64)、不再 `dpkg --add-architecture i386`;`nvidia-driver` 安装脚本在 arm64 上跳过 `libnvidia-fbc1`(FrameBuffer Capture)与 `linux-signatures-nvidia`(secure boot 签名,arm 无此包)。CI 侧新增 `build-kernel-matrix.sh` 按 platform 生成内核矩阵,并把 kernel 版本发现改成用 `regctl manifest inspect --platform` 判断镜像是否已存在。
  <details><summary>代码依据 ubuntu24.04/precompiled/Dockerfile + nvidia-driver</summary>

  ```diff
  +# Fetch GPG keys for CUDA repo (architecture-specific)
  +RUN CUDA_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "sbsa" || echo "x86_64") && \
  ...
  +    # libnvidia-fbc1 (FrameBuffer Capture) is not available for arm64
  +    if [ "$TARGETARCH" = "amd64" ]; then
  +        apt-get install -y --no-install-recommends libnvidia-fbc1-${DRIVER_BRANCH}-server
  +    fi
  +    # linux-signatures-nvidia (secure boot signatures) is not available for arm64
  +    if [ "$TARGETARCH" = "amd64" ]; then
  +        apt-get install --no-install-recommends -y linux-signatures-nvidia-${KERNEL_VERSION}
  +    fi
  ```
  </details>
### 后续发展方向 [AI]
- 明确指向 GH200/Grace-Hopper 这类 ARM 服务器上的免编译驱动分发:预编译容器此前是 x86 专属,现在把 kernel 矩阵、镜像 manifest 探测、包裁剪都做了 arch 感知。代价是 arm64 上缺 FBC 与 secure-boot 签名两项能力(前者影响远程渲染/编码,后者影响 UEFI secure boot 场景)。证据覆盖 Ubuntu 24.04 一条线,未见其它发行版(22.04/26.04)同步 arm 化。

## NVIDIA/gpu-operator: be25c4f2 -> 17c08086
- 比较 / Release: https://github.com/NVIDIA/gpu-operator/compare/be25c4f2...17c08086 | ahead=8 | Release v26.3.3
### AI 总结重点(源码 diff 为据)
- **operator 侧引入第三方 GPU 客户端部署标签**(见 mig-parted 节的 `nvidia.com/gpu.deploy.client`):本期 operator 唯一实质提交 "add new deploy label to manage third-party gpu client pods" 触及 `controllers/state_manager.go`(仅 3 行,patch 未进节选),与 mig-parted 的标签常量配套,证据完整侧在 mig-parted。
- **内置 NFD 子 chart 升级到 v0.19.0**(附带面):`deployments/gpu-operator/charts/node-feature-discovery` 大改,新增 `values.schema.json`、四类组件(master/worker/topology-updater/gc)的 **NetworkPolicy** 模板,并收紧 RBAC——worker clusterrole 把 `nodes/proxy` 换成 `nodes/configz`、给 pods 加 `list/watch`、新增对 `customresourcedefinitions` 的读权限。属 NFD 上游打包更新(NFD 本体归 k8s-ai-infra 视角),此处只记 operator 捆绑版本的边界变化。
  <details><summary>代码依据 charts/node-feature-discovery/templates/clusterrole.yaml</summary>

  ```diff
  -    - nodes/proxy
  +    - nodes/configz
  ...
  +- apiGroups:
  +  - apiextensions.k8s.io
  +  resources:
  +  - customresourcedefinitions
  +  verbs:
  +  - get
  +  - list
  +  - watch
  ```
  </details>
### 后续发展方向 [AI]
- operator 的实质动作是把 MIG 重配的安全停机面延伸到用户 workload(与 mig-parted 同步),这是本期跨仓主线。NFD 0.19 的 NetworkPolicy 化是安全加固方向,但属子 chart 透传,不代表 operator 自身控制面变化。证据仅覆盖 chart 模板与 RBAC,operator 如何消费新标签需看 state_manager.go 全量(未在节选)。

## 本期无实质改动(折叠)
<details><summary>EMPTY / 无新提交仓(5 仓)</summary>

- NVIDIA/nvidia-container-toolkit — 无新提交(HEAD 3db41dec 未动,Release v1.20.0-rc.1)
- NVIDIA/k8s-device-plugin — 有 1 提交但仅 bump/CI/merge(HEAD 前移到 7a3ea104,Release v0.19.3)
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(HEAD 9001f17e 未动,Release v0.4.1)
- NVIDIA/dcgm-exporter — 无新提交(HEAD d5e5f510 未动,Release 4.5.3-4.8.2)
- NVIDIA/DCGM(master)— 无新提交(HEAD 72fa3fea 未动)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=17c0808606923914106359966de575233be60d51 branch=main release=v26.3.3 scanned=2026-07-14 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3db41dec03bf1179b4f7259f6a7037f7f158d39b branch=main release=v1.20.0-rc.1 scanned=2026-07-14 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=1ea5e0fca809020c7388ba1058d19ad3788e6aaf branch=main release=— scanned=2026-07-14 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=7a3ea10445ff0f7a90add0675ff6ce53e3eab0b0 branch=main release=v0.19.3 scanned=2026-07-14 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=9001f17e513115a9366987bf5fd9f7850ac52368 branch=main release=v0.4.1 scanned=2026-07-14 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-07-14 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=4f279a9fa3e985172e78909e99d471b803627001 branch=main release=v0.14.3 scanned=2026-07-14 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=20d04b768ddc3a2c30658f75b9a9c6cc0caa64b2 branch=main release=v0.16.4 scanned=2026-07-14 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=72fa3feaa67d716a75323a8f47c34ff3ee73f824 branch=master release=— scanned=2026-07-14 -->
</content>
</invoke>
