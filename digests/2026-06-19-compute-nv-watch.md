# NVIDIA 算力栈 diff 雷达 2026-06-19

## 摘要
- 全栈 9 仓今日仅 KAI-Scheduler 1 仓有实质提交,且为单条 bugfix:修 NUMA placement exporter operand 的**非幂等 reconcile**——之前用 `append()` 往 Env/VolumeMounts/Volumes 追加,每轮调和都会重复堆叠;改为直接字面量赋值,二次调和不再重复挂卷。
- 同 PR 在 helm `_helpers.tpl` 把 numaPlacementExporter 的运维旋钮(service.enabled/image/resources/affinity/nodeSelector/tolerations + `pollInterval`/`driftResyncInterval`)铺进 KAIConfig spec 模板,延续昨日 NUMA 调度本体落地后的配置面收尾。
- 无 API/CRD 字段增删,无版本跨档;其余 8 仓(gpu-operator / container-toolkit / driver-container / device-plugin / dra-driver / dcgm-exporter / DCGM / mig-parted)无新提交。

## 当日重要改变
- 无(KAI 改动为 bugfix + 配置面铺设,未命中弃用/API-CRD/架构/跨档/新能力信号)。

## kai-scheduler/KAI-Scheduler: 5ccedbad -> 1eab11c8
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/5ccedbad0e37d849e0760853adbc2d0a03b44fb5...1eab11c8 | ahead=1 | files=3 | Release: v0.15.2
- PR: https://github.com/kai-scheduler/KAI-Scheduler/pull/1722

### AI 总结重点(源码 diff 为据)
- `daemonSetForKAIConfig`(`pkg/operator/operands/numa_placement_exporter/resources.go`)修复非幂等装配:NODE_NAME 环境变量、podresources/sysfs 两个 VolumeMount 与对应 Volume,原来都用 `append(...)` 往容器/Pod 已有列表里追加。该 operand 的 DesiredState 在二次调和时是从集群里已存在的对象重新构建的,append 会把同样的卷/挂载/env 再叠一遍 → 最终 DaemonSet 上重复挂载。改成直接 `[]v1.EnvVar{{...}}` / `[]v1.VolumeMount{...}` / `[]v1.Volume{...}` 字面量赋值(覆盖而非追加),保证幂等。新增的单测断言二次 DesiredState 后 Volumes/VolumeMounts 各为 2、Env 为 1。
  <details><summary>代码依据 pkg/operator/operands/numa_placement_exporter/resources.go</summary>

  ```diff
  -	container.Env = append(container.Env, v1.EnvVar{
  +	container.Env = []v1.EnvVar{{
  		Name:      "NODE_NAME",
  		ValueFrom: &v1.EnvVarSource{FieldRef: &v1.ObjectFieldSelector{FieldPath: "spec.nodeName"}},
  -	})
  +	}}
  	// The kubelet podresources socket and its parent directory are root-owned; read as root.
  	container.SecurityContext = &v1.SecurityContext{ RunAsUser: ptr.To(int64(0)), RunAsNonRoot: ptr.To(false) }
  -	container.VolumeMounts = append(container.VolumeMounts,
  -		v1.VolumeMount{Name: "podresources", MountPath: podResourcesDir, ReadOnly: true},
  -		v1.VolumeMount{Name: "sysfs", MountPath: sysfsMountPath, ReadOnly: true},
  -	)
  +	container.VolumeMounts = []v1.VolumeMount{
  +		{Name: "podresources", MountPath: podResourcesDir, ReadOnly: true},
  +		{Name: "sysfs", MountPath: sysfsMountPath, ReadOnly: true},
  +	}
  ```
  </details>
- helm 模板 `deployments/kai-scheduler/templates/_helpers.tpl` 在 KAIConfig spec 渲染里新增 `numaPlacementExporter` 整块:service.enabled、image(name/repository/tag/pullPolicy)、resources、affinity、nodeSelector、tolerations,以及两个采集行为旋钮 `pollInterval`、`driftResyncInterval`。说明 NUMA exporter 从"代码里写死"升级为可经 values 调参的标准 operand。
  <details><summary>代码依据 deployments/kai-scheduler/templates/_helpers.tpl</summary>

  ```diff
  +  numaPlacementExporter:
  +    service:
  +      enabled: {{ .Values.numaPlacementExporter.enabled }}
  +      image:
  +        name: {{ .Values.numaPlacementExporter.image.name }}
  +        ...
  +    {{- if .Values.numaPlacementExporter.pollInterval }}
  +    pollInterval: {{ .Values.numaPlacementExporter.pollInterval | quote }}
  +    {{- end }}
  +    {{- if .Values.numaPlacementExporter.driftResyncInterval }}
  +    driftResyncInterval: {{ .Values.numaPlacementExporter.driftResyncInterval | quote }}
  +    {{- end }}
  ```
  </details>

### 后续发展方向 [AI]
- NUMA placement exporter 这条线在持续硬化:昨日(2026-06-18 digest)是 NPE 从静态 yaml 升级为 operator tri-state 按需部署 + numa 插件本体落地,今日补幂等修复与 values 调参面。方向是把 NUMA 拓扑感知调度做成生产可运维的标准组件(可调采集周期 `pollInterval` 与漂移重同步 `driftResyncInterval`)。证据只覆盖 operand 装配与 helm 模板,未见 NUMA 调度决策算法本身今日变化。

## 本期无实质改动(折叠)
<details><summary>8 仓无新提交 / 仅 bump-CI-merge</summary>

- NVIDIA/gpu-operator — 无新提交
- NVIDIA/nvidia-container-toolkit — 无新提交
- NVIDIA/gpu-driver-container — 无新提交
- NVIDIA/k8s-device-plugin — 无新提交
- kubernetes-sigs/dra-driver-nvidia-gpu — 无新提交
- NVIDIA/dcgm-exporter — 无新提交
- NVIDIA/DCGM — 无新提交
- NVIDIA/mig-parted — 无新提交
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=9b198ba801ee9f1754dea0d74d85384659bea1c9 branch=main release=v26.3.2 scanned=2026-06-19 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=6d1a53dbd83f7b95eff3645afedf2335466014f2 branch=main release=v1.19.1 scanned=2026-06-19 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=d5f839873900dc0f985eae0ff4d975c9aacff0b4 branch=main release=— scanned=2026-06-19 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=25e493580ca8d18413c7ec6a912d3bd2af2b135a branch=main release=v0.19.2 scanned=2026-06-19 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=ed0d0e5593dad7f0f7594ce08fd3239e52fb15ba branch=main release=v0.4.1-rc.1 scanned=2026-06-19 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-19 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=d646460fe8ac5f3b67daf4f27385fe7701187d23 branch=master release=— scanned=2026-06-19 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=d8348422bc7338fba3e112fa3f733e7eecaf51da branch=main release=v0.14.2 scanned=2026-06-19 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=1eab11c812b328de8f761bcf285dfbb4ea5a3b12 branch=main release=v0.15.2 scanned=2026-06-19 -->
