# HAMi diff 雷达 2026-10-05

## 摘要
- HAMi 主仓把 device-config 的默认值全部收敛到 `values.yaml`:多个厂商(enflame/kunlun/vastai/biren)的 `customresources` 默认改成 `[]`,标准资源名改由命名字段自动派生——对有自定义 customresources 的用户是**行为变更**,升级需清理重复条目(#3152)。
- remote-gpu(Lupine 远程 GPU)修复:多容器 Pod 的后续容器现在强制复用前序容器已占的同一 Lupine server,不再跨 server 分配(#3164)。
- device-plugin ClusterRole 收掉 pods 的 create/update、nodes/status 的 update/list 等未用 RBAC 动词,最小权限收紧(#3157);webhook 补 `admission.k8s.io/v1` 版本(#3158)。

## 当日重要改变
- Project-HAMi/HAMi [弃用/移除] enflame/kunlun/vastai/biren 四家 `customresources` 默认值从显式资源列表改为 `[]`,标准资源名改为从 `resource*Name` 字段自动注入;升级时需从自定义 values 里删掉重复的标准资源条目,否则语义变化 charts/hami/README.md https://github.com/Project-HAMi/HAMi/pull/3152
- Project-HAMi/HAMi [弃用/移除] device-plugin ClusterRole 删除 pods 的 create/update、nodes/status 的 update/list RBAC 动词 charts/hami/templates/device-plugin/monitorrole.yaml https://github.com/Project-HAMi/HAMi/pull/3157

## Project-HAMi/HAMi: dc0ff8ea -> 43a8cffb
- 比较: dc0ff8ea68acff7115da80d1a9f5c5b9477f2ecd -> 43a8cffb | ahead=4 | files=9 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)

- **device-config 的全部默认值从模板硬编码迁移到 `values.yaml`**。`device-configmap.yaml` 以前把 NVIDIA 的 `defaultMemory: 0`、`defaultCores: 0`、`defaultGPUNum: 1`、`memoryFactor: 1`、整段 `migProfileAllowlist`(A30/A100/H100/H200/B200 的 MIG profile 表)以及 metax/enflame/mthreads 的资源名直接写死在模板里;现在全部改成 `{{ .Values.devices.<vendor>.* }}` 引用,MIG allowlist 改为 `{{ toYaml .Values.devices.nvidia.migProfileAllowlist | indent 8 }}`。即 values.yaml 成为默认值的唯一来源,用户覆写只改 `devices.<vendor>` 即可。
  <details><summary>代码依据 charts/hami/templates/scheduler/device-configmap.yaml</summary>

  ```diff
  -      defaultMemory: 0
  -      defaultCores: 0
  -      defaultGPUNum: 1
  -      preConfiguredDeviceMemory: {{ .Values.devices.nvidia.preConfiguredDeviceMemory | default 0 }}
  -      memoryFactor: 1
  +      defaultMemory: {{ .Values.devices.nvidia.defaultMemory }}
  +      defaultCores: {{ .Values.devices.nvidia.defaultCores }}
  +      defaultGPUNum: {{ .Values.devices.nvidia.defaultGPUNum }}
  +      preConfiguredDeviceMemory: {{ .Values.devices.nvidia.preConfiguredDeviceMemory }}
  +      memoryFactor: {{ .Values.devices.nvidia.memoryFactor }}
  ...
         migProfileAllowlist:
  -      - models: [ "A30" ]
  -        profiles: [ "1g.6gb", "2g.12gb", "4g.24gb" ]
  -      - models: [ "A100-SXM4-40GB", ... ]
  ...
  +{{ toYaml .Values.devices.nvidia.migProfileAllowlist | indent 8 }}
  ```
  </details>

- **enflame/kunlun/vastai/biren 的 `customresources` 默认值由显式列表改为 `[]`,标准资源名改为从命名字段派生**。以前 `_helpers.tpl` 直接 `range .Values.devices.<vendor>.customresources` 把整份列表注册给 scheduler extender;现在先用 `resource*Name` 字段拼出 `$standardResources`,再 `concat $standardResources (customresources | default list) | uniq`。配合 values.yaml 把这几家 `customresources` 清成 `[]`。含义:标准资源(如 `enflame.com/drs-gcu`、`kunlunxin.com/xpu`)不再靠用户在 customresources 里列,而是自动注入;customresources 退化为"额外资源"追加位。
  <details><summary>代码依据 charts/hami/templates/_helpers.tpl</summary>

  ```diff
   {{/* Enflame resources */}}
   {{- if .Values.devices.enflame.enabled -}}
  -{{- range .Values.devices.enflame.customresources -}}
  +{{- $standardResources := list .Values.devices.enflame.resourceNameDRSGCU .Values.devices.enflame.resourceNameGCUMemory .Values.devices.enflame.resourceNameGCUCore .Values.devices.enflame.resourceNameGCU -}}
  +{{- range (concat $standardResources (.Values.devices.enflame.customresources | default (list)) | uniq) -}}
   {{- $resources = append $resources (dict "name" . "ignoredByScheduler" true) -}}
  ```
  </details>
  <details><summary>代码依据 charts/hami/README.md(升级指引,确认为行为变更)</summary>

  ```diff
  +For Enflame, Kunlun, Vastai, and Biren, standard extender resources are now
  +added from the named device resource fields. Their `customresources` lists
  +contain only additional resources and default to `[]`. Remove any copied
  +standard-resource entries from these lists and keep the extra resources you
  +need. Standard resources are included even when `customresources` is empty.
  ```
  </details>

- **mthreads `memoryPerCard` 兼容标量/列表**:新增 README 字段说明,模板用 `kindIs "slice"` / `kindIs "invalid"` 判断,把旧的标量覆写值自动包成单元素 list,保持与运行时 list 字段兼容。同时为 metax 新增 `resourceCountName`、hygon 新增 `memoryFactor`、amd/awsneuron 补齐 `resourceCountName`/`resourceMemoryName`/`resourceCoreName` 等命名字段(配合上一条的字段派生)。
  <details><summary>代码依据 charts/hami/values.yaml</summary>

  ```diff
   devices:
     metax:
  +    resourceCountName: "metax-tech.com/gpu"
     hygon:
  +    memoryFactor: 1
     amd:
  +    resourceCountName: "amd.com/gpu"
  +    resourceMemoryName: "amd.com/gpumem"
  +    resourceCoreName: "amd.com/gpucores"
  ```
  </details>

- **remote-gpu(Lupine 远程 GPU)多容器 Pod 分配锁定同一 server**。`Fit()` 签名的最后一个参数从 `_ *device.PodDevices`(忽略)改为具名 `allocated`,并新增 `committedAllocation()`:从本 Pod 已分配记录里取出前序容器占用的 server 与卡集合;若 `prior != ""` 则把候选 `servers` 收窄为 `[]string{prior}`。`tryFit()` 新增 `committed map[string]struct{}` 参数,使本 Pod 自己已占的卡不被计为冲突。原因注释:HAMi 当前只给每个 client 容器注入一个 `LUPINE_SERVER` 端点,后续容器必须落在同一端点服务的卡上。
  <details><summary>代码依据 pkg/device/remotegpu/device.go</summary>

  ```diff
  -func (dev *RemoteGPUDevices) Fit(..., _ *device.NodeInfo, _ *device.PodDevices) (...) {
  +func (dev *RemoteGPUDevices) Fit(..., _ *device.NodeInfo, allocated *device.PodDevices) (...) {
  ...
  +	prior, committed := committedAllocation(allocated)
  +	if prior != "" {
  +		servers = []string{prior}
  +	}
  -	fit, tmpDevs, reason := dev.tryFit(byServer, servers, request, pod)
  +	fit, tmpDevs, reason := dev.tryFit(byServer, servers, request, pod, committed)
  ...
  +func committedAllocation(allocated *device.PodDevices) (string, map[string]struct{}) {
  +	for _, ctrList := range (*allocated)[RemoteGPUCommonWord] {
  +		for _, d := range ctrList {
  +			if s := serverOf(d.UUID); s != "" { ... committed[d.UUID] = struct{}{} }
  ```
  </details>

- **device-plugin ClusterRole 最小权限收紧**:`monitorrole.yaml` 删除 pods 的 `create`/`update`、nodes/status 的 `update`/`list` 动词,仅保留 get/watch/list/patch 等读与补丁权限。
  <details><summary>代码依据 charts/hami/templates/device-plugin/monitorrole.yaml</summary>

  ```diff
       verbs:
         - get
  -      - create
         - watch
         - list
  -      - update
         - patch
  ...
       verbs:
         - get
  -      - update
  -      - list
         - patch
  ```
  </details>

- **admission webhook 补 v1 版本**:`webhook.yaml` 的 `admissionReviewVersions` 在 `v1beta1` 之上追加 `v1`(配合 commit "add admission.k8s.io/v1"),使 webhook 兼容新版 admission API,向后兼容旧的 v1beta1。
  <details><summary>代码依据 charts/hami/templates/scheduler/webhook.yaml</summary>

  ```diff
     - admissionReviewVersions:
  +    - v1
       - v1beta1
  ```
  </details>

### 后续发展方向 [AI]
- **厂商接入统一化在往"声明式命名字段 + 自动派生"收敛**:device-config 默认值集中到 values.yaml、customresources 从"手列全集"退化为"额外追加",证据见 `_helpers.tpl` 的 `$standardResources + concat|uniq` 模式与 README 升级指引。方向是降低多厂商(已覆盖 metax/hygon/amd/awsneuron/enflame/kunlun/vastai/biren/mthreads)接入与覆写的心智成本。证据只覆盖 helm chart 模板层,未见调度器/device 代码里对应的解析改动。
- **remote-gpu(Lupine)分块虚拟化正在补多容器语义**:本次锁定"一 Pod 一 server",注释明说受限于"每容器仅注入一个 LUPINE_SERVER 端点"。证据只覆盖 `Fit/tryFit` 的 server 收窄逻辑,未见端点注入侧(多端点支持)的改动;若后续放开多端点,此约束可能回退。

## 本期无实质改动(折叠)
<details><summary>EMPTY repos</summary>

- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交
- Project-HAMi/HAMi-WebUI — ahead=3,仅 bump/CI/merge,无实质改动
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=43a8cffbb81394affece98bedaed8ae27f60db41 branch=master release=v2.10.0 scanned=2026-10-05 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=ec5d85a3d709e5ed138a1668ebfefd366c05ca1e branch=main release=— scanned=2026-10-05 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=6063efe9806ee7bd2fd966fc65f155c65c95696b branch=main release=— scanned=2026-10-05 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=6f6ee0240641e9f03e6e46356910a1579b3cf276 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-10-05 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=4263a44d2a8f4a6a1c48a82494db3df74ffdcda2 branch=main release=v1.3.0 scanned=2026-10-05 -->
</content>
</invoke>
