# HAMi diff 雷达 2026-09-13

## 摘要
- 主仓 HAMi、HAMi-core、volcano-vgpu、ascend-device-plugin 四仓全 EMPTY,软切分内核与调度侧本日无实质改动;唯一活跃仓是 **HAMi-WebUI**(16 个实质 PR,base f6ae9160 -> 715c1a2b,ahead=16)。
- WebUI 两处能力级新增:① proto `ContainerReply` 新增 `ContainerStatusDetail`(21 号字段),控制台首次能直接呈现容器/Pod 真实生命周期状态(不再从 GPU 遥测反推健康);② 新增 **Hygon HCU** provider,与 legacy DCU 并存,把海光新一代加速卡纳入 WebUI 库存/监控。
- 其余为工作负载状态语义收敛(把 error/not_ready/failed 归并为"异常"一档)、侧边栏/语言切换的可访问性重构、按 Pod+容器双维标识工作负载。

## 当日重要改变
- HAMi-WebUI [新能力] 新增 Hygon HCU provider(`hygon.HCU`),从 `hami.io/node-hcu-register` 注册注解发现设备,与 legacy DCU(`node-dcu-register`)并行,身份用稳定 `HCU-<serial>` 而非节点本地 minor。证据 `server/internal/provider/hygon/hcu.go`、`device.go`。 https://github.com/Project-HAMi/HAMi-WebUI/pull/302
- HAMi-WebUI [API/CRD变更] `container.proto` `ContainerReply` 新增 `ContainerStatusDetail status_detail = 21`(16 个容器/Pod 生命周期字段),并明确 `status` 过滤器语义:`abnormal` 一次匹配 error/not_ready/failed。证据 `server/api/v1/container.proto`。 https://github.com/Project-HAMi/HAMi-WebUI/pull/298

## Project-HAMi/HAMi-WebUI: f6ae9160 -> 715c1a2b
- 比较: f6ae9160 -> 715c1a2b | ahead=16 | files=99 | Release: v1.3.0
- 全量 diff: https://github.com/Project-HAMi/HAMi-WebUI/compare/f6ae916068e6a8e026343ec7679fd96643472e7c...715c1a2b

### AI 总结重点(源码 diff 为据)

- **新增 Hygon HCU provider,与 legacy DCU 并存,不复用 DCU 身份逻辑。** `hygon/device.go` 在 `init()` 注册 `HCU` 设备的 `InRequestDevices`/`SupportDevices`(`hami.io/hcu-devices-to-allocate` / `-allocated`),新增常量 `HygonHCUDevice="HCU"`、`HCURegisterAnnos="hami.io/node-hcu-register"`。新文件 `hcu.go` 定义 `HCU` 结构体:`FetchDevices` 从节点 `node-hcu-register` 注解解码设备,并对每个设备做 `strings.CutPrefix(device.ID, "HCU-")` 剥前缀得到物理 serial 存入 `device.ID`、原始全 ID 存 `AliasId`(供分配 join);剥不出前缀的(注册时 serial 读取失败仍写 `HCU-`)直接 drop 并 warn。默认 labelSelector 空时回退 `hcu=on`。
  <details><summary>代码依据 server/internal/provider/hygon/hcu.go + device.go</summary>

  ```diff
  + // device.go
  + HygonHCUDevice     = "HCU"
  + HCURegisterAnnos   = "hami.io/node-hcu-register"
  + func init() {
  +   util.InRequestDevices[HygonHCUDevice] = "hami.io/hcu-devices-to-allocate"
  +   util.SupportDevices[HygonHCUDevice]   = "hami.io/hcu-devices-allocated"
  + }
  + // hcu.go
  + func (h *HCU) FetchDevices(node *corev1.Node) ([]*util.DeviceInfo, error) {
  +   encoded, ok := node.Annotations[HCURegisterAnnos]
  +   ...
  +   serial, ok := strings.CutPrefix(device.ID, "HCU-")
  +   if !ok || serial == "" { h.log.Warnf("skip HCU device ..."); continue }
  +   device.AliasId = device.ID
  +   device.ID = serial
  + }
  ```
  </details>

- **控制台状态从"遥测反推健康"改为读 K8s 容器真实状态。** 新增后端 `data/container_status.go`:`classifyContainerStatus(pod, observed)` 用 `pod.Status.Phase/Reason/Message`、`PodReady` condition、`observed.State.{Running,Terminated,Waiting}` 与 `LastTerminationState` 组装 `biz.ContainerStatusDetail`;`isContainerWaitingError` 用固定白名单(CrashLoopBackOff/ImagePullBackOff/... 12 项)判定哪些 Waiting reason 算 error,陌生 reason 保持 waiting 可见;`containerWillRestart` 按 RestartPolicy+exitCode 判断是否待重启。proto 侧 `ContainerReply` 新增 `status_detail=21`,类型 `ContainerStatusDetail` 含 container_state/ready/restart_count/exit_code/pod_phase/pod_ready/last_termination_* 等 16 字段(optional 区分 false/0 与"不可用")。
  <details><summary>代码依据 server/internal/data/container_status.go + server/api/v1/container.proto</summary>

  ```diff
  + func isContainerWaitingError(reason string) bool {
  +   switch reason {
  +   case "CrashLoopBackOff","ImagePullBackOff","ErrImagePull","InvalidImageName",
  +        "ErrImageNeverPull","ImageInspectError","CreateContainerConfigError",
  +        "CreateContainerError","RunContainerError","PreCreateHookError",
  +        "PreStartHookError","PostStartHookError": return true
  +   default: return false } }
  + // container.proto
  + message ContainerReply { ... + ContainerStatusDetail status_detail = 21; }
  + message ContainerStatusDetail {
  +   string container_state = 1; string reason = 2; optional bool ready = 4;
  +   int32 restart_count = 5; optional int32 exit_code = 6; string pod_phase = 7;
  +   bool restart_pending = 11; optional int32 last_exit_code = 13; ... }
  ```
  </details>

- **工作负载状态语义收敛为 5 档,error/not_ready/failed 统一归并"异常"。** 新增前端 `workload-status.mjs`:`STATUS_LABEL_KEYS` 把 8 个原始 code(waiting/success/not_ready/error/closed/failed/terminating/unknown)映射到 5 个展示标签,其中 not_ready/error/failed 都指向 `statusAbnormal`;过滤器 `getWorkloadStatusOptions` 只暴露 waiting/success/abnormal 三档。`getSummary` 用一套优先级(当前状态优先于历史 termination/readiness 证据)+ `REASON_SUMMARY_KEYS` 把镜像拉取/配置/启动类错误折叠成单句结论,不再向用户直接暴露 registry/Pod 原始报文。
  <details><summary>代码依据 packages/web/projects/vgpu/views/task/admin/workload-status.mjs</summary>

  ```diff
  + const STATUS_LABEL_KEYS = Object.freeze({
  +   waiting:'statusStarting', success:'statusRunning',
  +   not_ready:'statusAbnormal', error:'statusAbnormal', failed:'statusAbnormal',
  +   closed:'statusCompleted', terminating:'statusTerminating', unknown:'statusUnknown' });
  + // 当前状态优先于陈旧证据
  + if (code === 'success') {
  +   if (detail.podReady === 'False') return summary('podNotReady');
  +   if (hasPastFailure) return summary(detail.lastTerminationReason==='OOMKilled'?'recoveredOom':'recoveredFailure');
  + }
  ```
  </details>

- **工作负载改为 Pod+容器双维标识,新增 `WorkloadRankingName.vue` 并改造表格/排行渲染。** `task/admin/index.vue` 把原来的单 `formatWorkloadName`/`TextPlus` 拆成 `workloadPodName`(appName)+`workloadContainerName`(name),用 `EllipsisText`(middle 截断)分别渲染并以 `/` 分隔;无 appName 时退化为 `容器名 / Pod UID`。新增 `WorkloadRankingName.vue` 在排行榜复用同一身份逻辑,并带 RouterLink 深链到 detail。
  <details><summary>代码依据 packages/web/projects/vgpu/views/task/admin/index.vue + WorkloadRankingName.vue</summary>

  ```diff
  - import TextPlus from '@/components/TextPlus.vue';
  + import EllipsisText from '@/components/EllipsisText.vue';
  + const workloadPodName = appName || '--';
  + const workloadContainerName = name || '--';
  +   {workloadPodName !== workloadContainerName && (<>
  +     <span class="workload-pod-name"><EllipsisText text={workloadPodName} mode="middle" tooltip="always" /></span>
  +     <span class="workload-identity-separator">/</span></>)}
  ```
  </details>

- **侧边栏与语言切换做可访问性重写(纯前端)。** `Sidebar/index.vue` 从 `t-menu`/`t-submenu` 结构改为扁平 `router-link`(带 `aria-current`、`role`、collapsed 时 t-tooltip),`menu.scss` 净删 197 行改 flex 布局;`LangSelect/index.vue` 侧边栏态改为 segmented 双按钮(zh/EN,带 `aria-pressed`/`aria-label`),collapsed 态改单按钮 toggle。属交互/无障碍改造,不涉及切分或调度语义。

### 后续发展方向 [AI]
- WebUI 正沿"多厂商加速卡统一纳管 + 真实工作负载可观测"两条线走:HCU provider 的加入方式(新 provider 结构体 + init 注册 InRequest/Support 设备映射 + 从厂商 device-plugin 的 `node-*-register` 注解发现设备)已成为 HAMi-WebUI 接新硬件的固定模板,后续再接其它国产卡大概率复刻此形状。证据只覆盖 hygon 目录与 provider/util 的设备注册,未见对调度/分配路径(主仓 HAMi)的对应改动——本日主仓 EMPTY。
- `ContainerStatusDetail` 把 K8s 原生容器状态引入 WebUI 数据面,意味着控制台健康判断正从"GPU 遥测有没有数"解耦为"容器/Pod 真实生命周期",这会降低对 exporter 覆盖度的依赖。证据仅到 proto 定义 + data 层 classify 函数,未见 service 层如何 join 遥测与该 detail(service/container_status.go 本次新增但未纳入 patch 节选,hunk 未覆盖)。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓</summary>

- Project-HAMi/HAMi — 无新提交(仍在 88b118e5 / v2.10.0)
- Project-HAMi/HAMi-core — 无新提交
- Project-HAMi/volcano-vgpu-device-plugin — 无新提交
- Project-HAMi/ascend-device-plugin — 无新提交(仍在 4b977f92 / ascend-device-plugin-0.1.0)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=88b118e565a9effaa27f81669da291c5508fc5e4 branch=master release=v2.10.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-13 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-13 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-13 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=715c1a2ba38adafa4553f37b6d36b7ab64492163 branch=main release=v1.3.0 scanned=2026-09-13 -->
