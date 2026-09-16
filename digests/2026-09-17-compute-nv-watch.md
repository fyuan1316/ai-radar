# NVIDIA 算力栈 diff 雷达 2026-09-17

## 摘要
- **KAI-Scheduler 落地 NvFractions 分数 GPU 请求的新注解协议与统一校验**:新增 `nvidia.com/nv-fractions-*` 前缀的按容器"显存 request/limit"注解形态,连同 legacy `gpu-fraction`/`gpu-memory` 收敛到一套 `ValidateGPUFractionRequest`,admission 从旧 `gpurequesthandler` 切走——GPU 软共享的请求面正从"整卡分数"向"按容器显存额度(可 request<limit 超卖)"演进。
- **gpu-operator 打通 operand DaemonSet 的 pod 级 securityContext**:Helm 新增 `daemonsets.podSecurityContext`,渲染进 ClusterPolicy,专为 SELinux(spc_t/s0)等场景,当前全局生效、未支持按 operand 覆盖。
- container-toolkit 的 `apply-cuda-memory-limits` CDI hook 由"加载 OCI spec 失败即报错阻断"改为"warn 后放行",避免非 GPU/畸形容器被显存限额 hook 卡住启动;gpu-driver-container 给多架构发布加了"发布后清单与构建产物一致性校验"。

## 当日重要改变
- kai-scheduler [新能力/请求协议] 新增 NvFractions 注解族(`pkg/common/resources/gpu_sharing_nvfractions.go`),支持按容器名的 GPU 显存 request/limit(limit 缺省从 request/limit 互推),优先级高于 legacy `gpu-fraction`/`gpu-memory`;PR #2040 https://github.com/kai-scheduler/KAI-Scheduler/pull/2040
- kai-scheduler [调度正确性] 修复:请求 0 GPU 的 Pod 不再被授予 GPU-sharing 节点打分,避免无卡负载抢占共享卡节点;PR #2154 https://github.com/kai-scheduler/KAI-Scheduler/pull/2154
- gpu-operator [配置面/安全] Helm `daemonsets.podSecurityContext` 渲染进 ClusterPolicy,对所有 operand DaemonSet 统一注入 pod 级 SELinux 等安全上下文;PR #2703 https://github.com/NVIDIA/gpu-operator/pull/2703
- nvidia-container-toolkit [健壮性] `apply-cuda-memory-limits` hook 加载 OCI spec 失败时改为记录 warning 并 `return nil`(原先返回 error),显存限额 hook 不再阻断容器启动;PR #2103 https://github.com/NVIDIA/nvidia-container-toolkit/pull/2103
- gpu-driver-container [供应链完整性] 多架构 driver 镜像发布由 `skopeo copy --all` 推送并新增 `verify-manifest-match.sh`,推后对比本地/远端清单摘要,防止丢架构或摘要漂移;PR #873 https://github.com/NVIDIA/gpu-driver-container/pull/873

## kai-scheduler/KAI-Scheduler: d942b921 -> e22f6543
- 比较 https://github.com/kai-scheduler/KAI-Scheduler/compare/d942b921b8025257207bc0a687e23cc1a6fcc1c5...e22f6543c96a1c3aeabd29c38176c3ada9a21120 | ahead=4 | files=46 | Release: v0.17.2
### AI 总结重点(源码 diff 为据)
- **新增 NvFractions 请求协议**:`gpu_sharing.go` 定义 `FractionType`(`nv-fractions`/`portion`/`memory`)与 `PodGPUFractionRequest`(Portion/Memory/Limit/NumDevices),`RequestsGPUFraction` 由只认 `gpu-fraction`/`gpu-memory` 扩展为额外识别任何 `NvFractionsAnnotationPrefix` 前缀且以 request/limit 后缀结尾的注解——limit-only Pod 也被判定为分数请求(其 request 由 limit 缺省而来)。这是把 GPU 软共享请求从"整卡分数(portion)"扩展到"按容器显存额度",且允许 request 与 limit 分离(超卖语义)。
  <details><summary>代码依据 pkg/common/resources/gpu_sharing.go</summary>

  ```diff
  +type FractionType string
  +const (
  +	BytesInMiB int64 = 1024 * 1024
  +	FractionTypeNvFractions FractionType = "nv-fractions"
  +	FractionTypePortion     FractionType = "portion"
  +	FractionTypeMemory      FractionType = "memory"
  +)
  +type PodGPUFractionRequest struct {
  +	Portion float64        // 仅无 NvFractions 注解时非零
  +	Memory *resource.Quantity  // NvFractions 或 gpu-memory 生效时设定
  +	Limit  *resource.Quantity  // NvFractions limit 注解存在时设定
  +	NumDevices int64
  +	FractionType FractionType
  +}
   func RequestsGPUFraction(pod *v1.Pod) bool {
  -	return foundFraction || foundGPUMemory
  +	if foundFraction || foundGPUMemory { return true }
  +	for annotationKey := range pod.Annotations {
  +		if strings.HasPrefix(annotationKey, constants.NvFractionsAnnotationPrefix) {
  +			if strings.HasSuffix(..., NvFractionsMemoryRequestSuffix) ||
  +			   strings.HasSuffix(..., NvFractionsMemoryLimitSuffix) { return true }
  +		}
  +	}
  ```
  </details>
- **统一校验入口**:新增 `gpu_sharing_validation.go` 的 `ValidateGPUFractionRequest`——configmap 无关、被 admission 复用;校验规则含"不能同时请求分数与整卡"、"NvFractions limit 不能与 legacy 注解共存(prefer 语义只作用于 request)"、"gpu-fraction 与 gpu-memory 互斥"、"gpu-memory 与 NvFractions request 并存时显存值须一致"。admission webhook 的 `GPUSharing.Validate` 由旧 `gpurequesthandler.ValidateGpuRequests` 切到该函数。
  <details><summary>代码依据 pkg/admission/webhook/v1alpha2/gpusharing/gpu_sharing.go</summary>

  ```diff
  -	return gpurequesthandler.ValidateGpuRequests(pod)
  +	return resources.ValidateGPUFractionRequest(pod)
   ...
  +// adjustFractionalMemoryAnnotations 把旧的分数显存注解转换成 NvFractions 格式
  +func adjustFractionalMemoryAnnotations(pod *v1.Pod, containerRef *...PodContainerRef) error {
  +	if gpuMemoryRequestMiB, foundGPUMemory := pod.Annotations[constants.GpuMemory]; foundGPUMemory {
  +		memoryQuantity := resources.GpuMemoryAnnotationToNvFractionsMemoryRequest(...)
  +		pod.Annotations[resources.CalcGpuFractionAnnotationForContainer(containerRef.Container.Name)] = memoryQuantity.String()
  +	}
  +}
  ```
  </details>
- **调度打分修正**:`gpusharingorder` 插件不再给"请求 0 GPU"的 Pod 授予 GPU-sharing 节点分数(新增 `RequestsGPU` = `RequestsGPUFraction || RequestsWholeGPU` 作为闸门),避免纯 CPU 负载被吸引到共享卡节点、挤占分数卡容量。
  <details><summary>代码依据 pkg/common/resources/gpu_sharing.go</summary>

  ```diff
  +func RequestsGPU(pod *v1.Pod) bool {
  +	return RequestsGPUFraction(pod) || RequestsWholeGPU(pod)
  +}
  ```
  </details>
- **运维硬化(非能力)**:`values.yaml` 给 operator / crdupgrader / kaiConfigDeployer / topologyMigration / postCleanup 等容器补齐 requests/limits;example 与 hack 清单统一 `automountServiceAccountToken: false`。
### 后续发展方向 [AI]
- NvFractions 目前落在 common/resources 与 admission 校验/变换层,是"请求协议 + 校验 + 向后兼容转换"的地基(PR 标题即 "foundation"),证据覆盖注解解析/校验/mutate,**未见** binder 实际按 NvFractions 分配显存与 scheduler 侧容量核算的落地——下阶段值得盯 binder plugins/gpusharing 是否消费 `PodGPUFractionRequest.Limit` 做超卖记账。
- request/limit 分离已在类型层建模(`Limit *resource.Quantity`),显存超卖是明确方向;但本期只有校验拒绝非法组合,未见运行时 enforcement 证据。

## NVIDIA/gpu-operator: aff3c2d5 -> 8fe3fd61
- 比较 https://github.com/NVIDIA/gpu-operator/compare/aff3c2d5898a4ebea9bb6826078e6e4782658b4c...8fe3fd61821ba51f6ddd2e7668388360c9655e2f | ahead=20 | files=100 | Release: v26.7.0
### AI 总结重点(源码 diff 为据)
- **operand DaemonSet 支持 pod 级 securityContext**:Helm values 新增 `daemonsets.podSecurityContext`,clusterpolicy 模板条件渲染到 `spec.daemonsets.podSecurityContext`。注释明确用途为 SELinux(`type: spc_t` / `level: s0`),且"Per-operand overrides are not supported yet"——目前是对全部 operand DaemonSet 统一生效。
  <details><summary>代码依据 deployments/gpu-operator/templates/clusterpolicy.yaml + values.yaml</summary>

  ```diff
  # clusterpolicy.yaml
  +    {{- if .Values.daemonsets.podSecurityContext }}
  +    podSecurityContext: {{ toYaml .Values.daemonsets.podSecurityContext | nindent 6 }}
  +    {{- end }}
  # values.yaml
  +  # podSecurityContext:
  +  #   seLinuxOptions:
  +  #     type: spc_t
  +  #     level: s0
  +  # Note: This must be rendered into ClusterPolicy by the Helm template.
  +  # Per-operand overrides are not supported yet.
  ```
  </details>
- 其余为工程化:新增 `internal/conditions/gpucluster` 单测(GPUCluster 状态 conditions,306 行)、`tools/tools.go` 引入 `goimports`、CONTRIBUTING 补开发环境与评审流程说明,以及一批 dependabot bump(controller-runtime 0.24.1→0.25.1、ginkgo、urfave/cli、prometheus-operator apis)。ClusterPolicy `*_types.go` 本期无字段增删。
### 后续发展方向 [AI]
- podSecurityContext 走 Helm→ClusterPolicy 而非直接改 CRD 字段,说明这是既有 ClusterPolicy schema 已容纳的能力,补的是 chart 暴露面;"Per-operand overrides are not supported yet" 的注释预告后续可能下沉到单 operand 粒度。证据仅覆盖 chart 模板与 values,未见 controller 侧对该字段的消费改动。

## NVIDIA/nvidia-container-toolkit: 3c435c90 -> 3a6c050d
- 比较 https://github.com/NVIDIA/nvidia-container-toolkit/compare/3c435c9048e19b09fcc924f25e4630b8f3a2b7b8...3a6c050d9c0c7b2516ce17e2190fb7e71b741f82 | ahead=6 | files=3 | Release: v1.20.0
### AI 总结重点(源码 diff 为据)
- **`apply-cuda-memory-limits` hook 失败不再阻断容器**:`command.run` 在 `fs.Load()` 加载 OCI spec 失败时,由 `return fmt.Errorf(...)` 改为 `logger.Warningf(...)` + `return nil`,即显存限额 hook 遇到无法解析的 spec 时静默跳过而非让容器创建失败。
  <details><summary>代码依据 cmd/nvidia-cdi-hook/apply-cuda-memory-limits/apply-cuda-memory-limits.go</summary>

  ```diff
   _, err = fs.Load()
   if err != nil {
  -	return fmt.Errorf("failed to load OCI container spec: %w", err)
  +	m.logger.Warningf("skipping apply-cuda-memory-limits; failed to load OCI container spec: %v", err)
  +	return nil
   }
  ```
  </details>
- 另有 distroless base `v4.1.3→v4.1.4` bump 与 CI 镜像扫描流程改造(pulse-cli 直连 registry、去掉 DinD save/load),非运行时能力。
### 后续发展方向 [AI]
- 该 hook 是 CDI 路径下按 `GPUMemoryRequestEnvName` 环境变量施加 CUDA 显存上限的机制;本次改动把它从"硬失败"降级为"尽力而为",提高了在混合/非标准容器规格下的兼容性,代价是限额可能被静默跳过。证据仅覆盖 spec 加载分支,未改限额计算逻辑本身。

## NVIDIA/gpu-driver-container: 3036164c -> 01299896
- 比较 https://github.com/NVIDIA/gpu-driver-container/compare/3036164c3323ca68c87c1c98b369a447f978a745...01299896864deb3cd47399c24050cb0957b9171c | ahead=4 | files=4 | Release: —
### AI 总结重点(源码 diff 为据)
- **多架构发布加"发布后清单一致性校验"**:precompiled 发布由 `skopeo copy --all`(原缺 `--all`,arm 多架构会丢)推送,随后 `skopeo inspect --raw` 分别取本地 oci-archive 与远端 docker:// 清单,交给新增 `verify-manifest-match.sh` 归一化(按 os/arch/variant/digest 排序、剔除 attestation 的 unknown 平台)后逐位比对,不一致即 exit 1。
  <details><summary>代码依据 .github/workflows/precompiled.yaml + .github/scripts/verify-manifest-match.sh</summary>

  ```diff
  # precompiled.yaml
  -  skopeo copy --authfile ... "oci-archive:${image_path}" docker://.../driver:...
  +  skopeo copy --all --authfile ... "oci-archive:${image_path}" "docker://${IMAGE}"
  +  skopeo inspect --raw "oci-archive:${image_path}" > ./local-manifest.json
  +  skopeo inspect --raw --authfile ... "docker://${IMAGE}" > ./remote-manifest.json
  +  .github/scripts/verify-manifest-match.sh ./local-manifest.json ./remote-manifest.json
  ```
  </details>
- 配套新增 `test-verify-manifest-match.sh` 固件测试(多架构 index、丢架构、只剩 attestation、arm variant v7/v8 等用例)。属发布链供应链完整性硬化,非驱动/运行时逻辑。
### 后续发展方向 [AI]
- 反映 arm64 预编译 driver 发布的可靠性问题(丢架构/清单漂移)已被以 CI 断言方式固化;证据全在 CI/脚本,未触及 driver 容器内核编译或 OS 矩阵。

## 本期无实质改动(折叠)
<details><summary>展开</summary>

- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交(仍 v0.5.0)
- NVIDIA/dcgm-exporter — 无新提交(4.6.0-4.8.3)
- NVIDIA/DCGM — 无新提交(master)
- NVIDIA/k8s-device-plugin — 仅 CI 扫描 job 修复(`.nvidia-ci.yml`:pulse-cli 直连 registry、去 DinD),无产品代码改动
- NVIDIA/mig-parted — 仅 CI 扫描 job 修复(`.nvidia-ci.yml`,同上),无 MIG 逻辑改动
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=8fe3fd61821ba51f6ddd2e7668388360c9655e2f branch=main release=v26.7.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=3a6c050d9c0c7b2516ce17e2190fb7e71b741f82 branch=main release=v1.20.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=01299896864deb3cd47399c24050cb0957b9171c branch=main release=— scanned=2026-09-17 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=6256903afd0952f7b694d4e194fe88dd084adb87 branch=main release=v0.20.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=5baf08f63bd266129dbdd27b28e77bb0ad91fd28 branch=main release=v0.5.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=16ecae49e4d6174e556e768c87cd4e49d844b909 branch=main release=4.6.0-4.8.3 scanned=2026-09-17 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-17 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=f9613a3bb99dd2b9c01b41a1ebaf11ef17fdbc03 branch=main release=v0.15.0 scanned=2026-09-17 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=e22f6543c96a1c3aeabd29c38176c3ada9a21120 branch=main release=v0.17.2 scanned=2026-09-17 -->
