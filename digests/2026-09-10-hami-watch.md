# HAMi diff 雷达 2026-09-10

## 摘要
- **HAMi 主仓落地 OpenShift/SELinux 一等支持**:新增 SCC(SecurityContextConstraints)三件套 chart + device-plugin SELinux relabel initContainer + `platform.openshift`/`selinux` values 开关,把软切分从"kube-system 高权限裸跑"推向企业级受限平台(#2208)。
- **昇腾 vNPU 准入逻辑修 bug**:`OverwriteEnv` 不再无脑给非本资源名的容器塞空 `ASCEND_VISIBLE_DEVICES`,新增跨全部 vNPU 资源名判定 + env last-wins 检测,避免误屏蔽昇腾设备(#2953)。
- HAMi-core / volcano-vgpu / ascend-device-plugin / HAMi-WebUI 四仓本期全 EMPTY,软切分内核无演进。

## 当日重要改变
- Project-HAMi/HAMi [新能力] 新增独立 OpenShift SCC chart 子集(openshift-scc / -clusterrole / -rolebinding)与 SELinux relabel 能力,首次让 HAMi 在受限 SCC 平台上原生部署。证据:charts/hami/templates/device-plugin/openshift-scc*.yaml(added)。https://github.com/Project-HAMi/HAMi/pull/2208
- Project-HAMi/HAMi [架构方向] scheduler HTTP 端口从硬编码 443/80 改为可配 `httpTargetPort`(默认 9443,非特权端口),配合 OpenShift 受限 SCC 以非 root 运行 extender。证据:charts/hami/templates/scheduler/deployment.yaml。https://github.com/Project-HAMi/HAMi/pull/2208

## Project-HAMi/HAMi: 4434305d -> b5ec6b14
- 比较 4434305d → b5ec6b14 | ahead=6 | files=16 | Release: v2.10.0
- https://github.com/Project-HAMi/HAMi/compare/4434305db88ab30eec9143df722870f26c2b272b...b5ec6b143a322e33a7ace339dff840cccb2e55ac

### AI 总结重点(源码 diff 为据)

- **OpenShift 平台开关落地为 chart 层三资源 + 两个总开关 values**:新增 `platform.openshift`(布尔总闸)与 `openshift.securityContextConstraints.{create,name}`;`create=true` 时 chart 自建名为 `hami-device-plugin` 的 SCC 及其 `system:openshift:scc:<name>` use ClusterRole,并只把该 SCC 绑给 device-plugin/mock-device-plugin 的 ServiceAccount(scheduler/admission 走平台 restricted SCC)。内置 `privileged` SCC 场景强制 `create=false`,否则 openshift-scc.yaml 里 `fail` 阻断渲染。
  <details><summary>代码依据 charts/hami/values.yaml + openshift-scc.yaml</summary>

  ```diff
  +platform:
  +  openshift: false
  +openshift:
  +  securityContextConstraints:
  +    create: true
  +    name: "hami-device-plugin"
  ```
  ```diff
  +{{- if and .Values.platform.openshift .Values.openshift.securityContextConstraints.create (eq .Values.openshift.securityContextConstraints.name "privileged") }}
  +{{- fail "openshift.securityContextConstraints.create must be false when ... privileged because OpenShift provides this SCC" }}
  +apiVersion: security.openshift.io/v1
  +kind: SecurityContextConstraints
  +allowPrivilegedContainer: true
  +allowedCapabilities:
  +  - SYS_ADMIN
  +requiredDropCapabilities:
  +  - ALL
  ```
  </details>

- **device-plugin DaemonSet 新增 SELinux relabel initContainer**:`selinux.enabled` 开启后,以 `privileged/runAsUser:0` 起一个 `selinux-relabel` initContainer,对共享 vGPU 宿主目录(`/host/hami/vgpu`、`/host/hami/containers`、`/host/hami/tmp/vgpulock`)做 `chcon -t <type> -l <level>` 打标 + `chmod 0777/1777`;type/level 由 `selinux.type`(默认 `container_file_t`)、`selinux.level`(默认 `s0`)注入。NOTES.txt 明确警告卸载不会还原宿主标签/权限。
  <details><summary>代码依据 charts/hami/templates/device-plugin/daemonsetnvidia.yaml</summary>

  ```diff
  -      {{- if .Values.devicePlugin.gpuOperatorToolkitReady.enabled }}
  +      {{- if or .Values.selinux.enabled .Values.devicePlugin.gpuOperatorToolkitReady.enabled }}
         initContainers:
  +        {{- if .Values.selinux.enabled }}
  +        - name: selinux-relabel
  +          securityContext: { privileged: true, runAsUser: 0 }
  +          args:
  +            - chcon -R -t "${SELINUX_TYPE}" -l "${SELINUX_LEVEL}" \
  +                /host/hami/vgpu /host/hami/containers /host/hami/tmp/vgpulock
  ```
  </details>

- **scheduler extender 服务端口去硬编码 + OpenShift 下非 root 加固**:`--http_bind` 与 containerPort 从写死 `443`(webhook 开)/`80`(关)改为 `{{ .Values.scheduler.service.httpTargetPort | default 9443 }}`;`service.httpTargetPort` 默认值同步从 443 改 9443。`platform.openshift` 时给 extender 容器加 `runAsNonRoot/drop ALL/seccomp RuntimeDefault` securityContext。
  <details><summary>代码依据 charts/hami/templates/scheduler/deployment.yaml + values.yaml</summary>

  ```diff
  -            - --http_bind=0.0.0.0:443
  +            - --http_bind=0.0.0.0:{{ .Values.scheduler.service.httpTargetPort | default 9443 }}
  +          {{- if .Values.platform.openshift }}
  +          securityContext:
  +            runAsNonRoot: true
  +            capabilities: { drop: ["ALL"] }
  +            seccompProfile: { type: RuntimeDefault }
  -    httpTargetPort: 443
  +    httpTargetPort: 9443
  ```
  </details>

- **昇腾 vNPU 准入不再误清空 `ASCEND_VISIBLE_DEVICES`**:`Devices` 结构新增 `allAscendResourceNames []corev1.ResourceName`(在 `InitDevices` 里聚合全部 vNPU 配置的 ResourceName)。`MutateAdmission` 里 `OverwriteEnv` 追加空 `ASCEND_VISIBLE_DEVICES` 的条件从"只要容器没请求本 config 的 ResourceName"收窄为"**且**容器没请求任一昇腾资源(`containerRequestsAnyAscendResource`)**且** env 里 last-wins 的 `ASCEND_VISIBLE_DEVICES` 不已是空(`lastEnvValueEquals`)"。修掉了多资源名/已显式设值场景下把昇腾卡全屏蔽的问题。
  <details><summary>代码依据 pkg/device/ascend/device.go</summary>

  ```diff
  +	allAscendResourceNames []corev1.ResourceName
  +func (dev *Devices) containerRequestsAnyAscendResource(ctr *corev1.Container) bool { ... }
  +func lastEnvValueEquals(env []corev1.EnvVar, name, value string) bool {
  +	// kubelet dedupes same-name env, last wins, so iterate backward
  +	for _, e := range slices.Backward(env) { ... }
  +}
   func (dev *Devices) MutateAdmission(ctr *corev1.Container, p *corev1.Pod) (bool, error) {
  -		if dev.config.OverwriteEnv {
  +		if dev.config.OverwriteEnv && !dev.containerRequestsAnyAscendResource(ctr) &&
  +			!lastEnvValueEquals(ctr.Env, "ASCEND_VISIBLE_DEVICES", "") {
  ```
  </details>

- **nvidiaDriverRoot 渲染健壮化 + GPU Operator taint 默认容忍**:device-plugin/monitor 注入 `NVIDIA_DRIVER_ROOT` 的条件从 `typeIs "string"` 改为 `and (kindIs "string" ...) 非空`(空串不再注入),monitor 侧新增同源 driver-root 挂载(为 fake-gpu-operator 校验对齐);`devicePlugin.tolerations` 默认值从 `[]` 改为容忍 `nvidia.com/gpu:NoSchedule`。
  <details><summary>代码依据 charts/hami/templates/device-plugin/daemonsetnvidia.yaml + values.yaml</summary>

  ```diff
  -            {{- if typeIs "string" .Values.devicePlugin.nvidiaDriverRoot }}
  +            {{- if and (kindIs "string" .Values.devicePlugin.nvidiaDriverRoot) .Values.devicePlugin.nvidiaDriverRoot }}
  -  tolerations: []
  +  tolerations:
  +    - key: nvidia.com/gpu
  +      operator: Exists
  +      effect: NoSchedule
  ```
  </details>

### 后续发展方向 [AI]
- **HAMi 正把"能在 OpenShift 受限平台上跑"作为明确工程目标**:本轮全部落在 chart/RBAC/SCC/SELinux 与端口非特权化,而非调度或切分内核——说明当前阶段的短板是"部署合规性"而非"能力本身"。对我们对标 OAI 有直接意义:HAMi 开始补齐企业级平台适配这一块过去的弱项。证据只覆盖 chart 层(SCC 三件套 + SELinux initContainer + 9443 端口),**未见 scheduler/device-plugin Go 代码为 OpenShift 做行为分支**,即软切分运行时逻辑不变,纯部署面加固。
- 昇腾 vNPU 侧修复揭示其"多资源名共存 + env 覆盖"语义仍在打磨,`allAscendResourceNames` 聚合是为支持一个节点多种 vNPU 资源名并存的准入判定。证据只覆盖 `MutateAdmission` 入口这一段 hunk,未逐行看 `lastEnvValueEquals` 之后的完整分支(patch 截断),昇腾切分模板/内核未动。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 f01e9f23,无 release tag)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 f6ae9160,release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=b5ec6b143a322e33a7ace339dff840cccb2e55ac branch=master release=v2.10.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-10 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-10 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-10 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-10 -->
