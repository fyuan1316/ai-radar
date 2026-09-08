# HAMi diff 雷达 2026-09-09

## 摘要
- **Hygon 加速卡从 "DCU" 全面改名 "HCU",且是破坏性重命名**:资源名(`hygon.com/dcunum`→`hcunum`)、调度器 flag、节点/选卡注解、Go 类型全部换名,存量 Hygon 用户的 Pod resources 与调度器启动参数需同步改,否则识别不到设备(#2969)。
- HAMi 主仓另有两处 Helm chart 修复:让 `imagePullSecrets` 覆盖内置 kube-scheduler sidecar 镜像(#2976)、把 livenessProbe 收回 kubeScheduler 容器守卫内(#2977,仅提交标题,本次 patch 节选未覆盖)。
- HAMi-core / volcano-vgpu / ascend-device-plugin / WebUI 四仓本期全 EMPTY,软切分内核与昇腾 vNPU 无演进。

## 当日重要改变
- Project-HAMi/HAMi [弃用/移除·破坏性] Hygon 设备标识 DCU→HCU 全量重命名,默认资源名 `hygon.com/dcunum|dcumem|dcucores` 改为 `hygon.com/hcunum|hcumem|hcucores`,调度器 flag `--dcu-name/-memory/-cores` 改为 `--hcu-*`,选卡注解 `hygon.com/use-dcutype`→`use-hcutype`。证据:pkg/device/hygon/device.go、pkg/scheduler/config/config.go。https://github.com/Project-HAMi/HAMi/pull/2969
- Project-HAMi/HAMi [新能力·文档] 新增 docs/hygon-hcu-support.md,指向新的上游插件仓 https://github.com/HYGON-AI/k8s-hcu-device-plugin(与旧 DCU 插件分家的信号)。

## Project-HAMi/HAMi: 1092ba20 -> 4434305d
- 比较:https://github.com/Project-HAMi/HAMi/compare/1092ba203998fb5acb77aefc149cad715cd67719...4434305db88ab30eec9143df722870f26c2b272b | ahead=3 | Release: v2.10.0

### AI 总结重点(源码 diff 为据)
- **Hygon 设备的对外契约整体从 DCU 迁到 HCU,是用户可见的破坏性改名,不是纯内部重构**。默认资源名从 `hygon.com/dcunum / dcumem / dcucores` 改为 `hygon.com/hcunum / hcumem / hcucores`,调度器命令行 flag 从 `dcu-name / dcu-memory / dcu-cores` 改为 `hcu-name / hcu-memory / hcu-cores`,节点握手/注册注解从 `hami.io/node-handshake-dcu`、`hami.io/node-dcu-register` 改为 `-hcu` 后缀,内部分配注解 `hami.io/dcu-devices-to-allocate`→`hami.io/hcu-devices-to-allocate`。存量用户升级后,原有 Pod 的 `hygon.com/dcunum` 请求与旧 flag 都会失配。
  <details><summary>代码依据 pkg/device/hygon/device.go</summary>

  ```diff
  -type DCUDevices struct {
  +type HCUDevices struct {
   }
   const (
  -	HandshakeAnnos     = "hami.io/node-handshake-dcu"
  -	RegisterAnnos      = "hami.io/node-dcu-register"
  -	HygonDCUDevice     = "DCU"
  +	HandshakeAnnos     = "hami.io/node-handshake-hcu"
  +	RegisterAnnos      = "hami.io/node-hcu-register"
  +	HygonHCUDevice     = "HCU"
   )
  -func InitDCUDevice(config HygonConfig) *DCUDevices {
  +func InitHCUDevice(config HygonConfig) *HCUDevices {
  -		device.InRequestDevices[HygonDCUDevice] = "hami.io/dcu-devices-to-allocate"
  +		device.InRequestDevices[HygonHCUDevice] = "hami.io/hcu-devices-to-allocate"
  -	fs.StringVar(&HygonResourceCount, "dcu-name", "hygon.com/dcunum", "dcu resource count")
  +	fs.StringVar(&HygonResourceCount, "hcu-name", "hygon.com/hcunum", "hcu resource count")
  ```
  </details>
- **调度器设备注册表与内嵌默认 config 同步改名**,`InitDevicesWithConfig` 里 Hygon 分支从 `HygonDCUDevice/InitDCUDevice` 换为 `HygonHCUDevice/InitHCUDevice`,内嵌 YAML 默认 `hygon.resourceCountName` 等三项默认值改为 `hygon.com/hcu*`。说明改名贯穿"设备驱动定义→调度器装配→默认配置"整条链,而非只改常量。
  <details><summary>代码依据 pkg/scheduler/config/config.go</summary>

  ```diff
  -		{hygon.HygonDCUDevice, hygon.HygonDCUCommonWord, func(cfg any) (device.Devices, error) {
  +		{hygon.HygonHCUDevice, hygon.HygonHCUCommonWord, func(cfg any) (device.Devices, error) {
  -			return hygon.InitDCUDevice(hygonConfig), nil
  +			return hygon.InitHCUDevice(hygonConfig), nil
   hygon:
  -  resourceCountName: "hygon.com/dcunum"
  -  resourceMemoryName: "hygon.com/dcumem"
  -  resourceCoreName: "hygon.com/dcucores"
  +  resourceCountName: "hygon.com/hcunum"
  +  resourceMemoryName: "hygon.com/hcumem"
  +  resourceCoreName: "hygon.com/hcucores"
  ```
  </details>
- **Helm chart 修复:extender 的 imagePullSecrets 现在把内置 kube-scheduler sidecar 镜像也纳入拉取凭证计算**。旧版只对 `scheduler.extender.image` 求 pullSecrets;开启 `scheduler.kubeScheduler.enabled` 时,官方 kube-scheduler 镜像若来自私有仓会拉不动。新版按开关把 `kubeScheduler.image` 追加进 image 列表再算 secret。
  <details><summary>代码依据 charts/hami/templates/_helpers.tpl</summary>

  ```diff
   {{- define "hami.scheduler.extender.imagePullSecrets" -}}
  -{{ include "common.images.pullSecrets" (dict "images" (list .Values.scheduler.extender.image) "global" .Values.global) }}
  +{{- $images := list .Values.scheduler.extender.image -}}
  +{{- if .Values.scheduler.kubeScheduler.enabled -}}
  +{{- $images = append $images .Values.scheduler.kubeScheduler.image -}}
  +{{- end -}}
  +{{ include "common.images.pullSecrets" (dict "images" $images "global" .Values.global) }}
   {{- end -}}
  ```
  </details>
- chart 侧 `_helpers.tpl` 的资源忽略列表(`ignoredByScheduler`)也随改名把 `dcuResourceName/Mem/Cores` 换为 `hcuResourceName/Mem/Cores`,与 values 改名对齐,确保这些资源仍被标记为不参与原生调度。
  <details><summary>代码依据 charts/hami/templates/_helpers.tpl</summary>

  ```diff
  -{{/* DCU resources */}}
  -{{- $resources = append $resources (dict "name" .Values.dcuResourceName "ignoredByScheduler" true) -}}
  +{{/* HCU resources */}}
  +{{- $resources = append $resources (dict "name" .Values.hcuResourceName "ignoredByScheduler" true) -}}
  ```
  </details>

### 后续发展方向 [AI]
- **这是 Hygon 官方把产品线从 "DCU" 品牌重命名为 "HCU" 在 HAMi 侧的落地**:新增文档指向独立新仓 `HYGON-AI/k8s-hcu-device-plugin`,而非旧 DCU 插件,暗示上游 device-plugin 也在换名/换仓。证据覆盖 device.go/config.go/chart 三层的标识改名与新文档,**未见任何兼容旧 `hygon.com/dcu*` 资源名的过渡别名**——从 diff 看是硬切换,升级需用户手工改 Pod 与 chart values,存在破坏性风险边界。
- 注意 UUID 选卡注解 key 仍是 `hygon.com/use-gpuuuid`(未改名),只是文档里示例值前缀从 `DCU-` 改成 `HCU-`;说明本轮只动"设备类型/资源名"层,UUID 通道保持稳定。证据只覆盖 examples 与 device.go 注释,未逐行读 device-plugin 侧对 UUID 前缀的解析逻辑。
- HAMi-core 本期仍 EMPTY,DCU→HCU 改名停留在 K8s 调度/资源命名层,**软切分内核(显存/算力 hook)未见随品牌改名产生行为变化**,vGPU/vNPU 隔离能力本轮无演进。

## 本期无实质改动(折叠)
<details><summary>EMPTY 的 repo</summary>

- Project-HAMi/HAMi-core:无新提交(HEAD 仍 f01e9f23,无 release tag)
- Project-HAMi/volcano-vgpu-device-plugin:无新提交(HEAD 仍 cbded47b)
- Project-HAMi/ascend-device-plugin:无新提交(HEAD 仍 4b977f92,release ascend-device-plugin-0.1.0)
- Project-HAMi/HAMi-WebUI:无新提交(HEAD 仍 f6ae9160,release v1.3.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=4434305db88ab30eec9143df722870f26c2b272b branch=master release=v2.10.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-09 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-09 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-09 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=f6ae916068e6a8e026343ec7679fd96643472e7c branch=main release=v1.3.0 scanned=2026-09-09 -->
