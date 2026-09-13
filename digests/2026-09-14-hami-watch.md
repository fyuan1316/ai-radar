# HAMi diff 雷达 2026-09-14

## 摘要
- HAMi-WebUI 迈出关键一步:从"看已分配 GPU"扩到"看调度决策"——新增**统一工作负载列表**(把已分配容器与 pending/waiting 的 GPU pod 合并展示)+ **调度诊断抽屉**,后端能把 PodScheduled 失败原因解析成结构化 reason code,并区分是 HAMi 软切分自身原因(显存/核/时分片耗尽)还是 K8s 原生原因(CPU/亲和/PVC/污点)。
- 新增 3 个 proto 服务/类型文件(Scheduling.GetSchedulingPod、Workload.ListWorkloads、SchedulingPod/Event 类型),ContainerReply 追加 4 个字段(pending/scheduling/request/container_kind);新增 RBAC `events: list` 权限。
- 软切分内核 HAMi-core、主调度仓 HAMi、volcano-vgpu-device-plugin、ascend-device-plugin 四仓本期均无新提交。

## 当日重要改变
- HAMi-WebUI [新能力][API/CRD变更] 新增"调度诊断"能力:后端把 GPU pod 按 waiting/gated/bound/unknown/terminating/finished 分档,并把调度失败原因解析成 HAMi 专属 code(如 CardInsufficientMemory/CardTimeSlicingExhausted)vs K8s 原生 code,标注来源 hami/kubernetes/mixed。证据:`server/internal/data/scheduling_pod.go`、`server/api/v1/scheduling.proto`。 https://github.com/Project-HAMi/HAMi-WebUI/commit/5fd62d49bc379abeef9b6afed69eba7deed0be26
- HAMi-WebUI [API/CRD变更] 新增 Workload.ListWorkloads(POST /v1/workloads)与 Scheduling.GetSchedulingPod(GET /v1/scheduling/pod)两个 gRPC/HTTP 服务;ContainerReply 增字段 pending(22)/scheduling(23)/request(24)/container_kind(25)。 https://github.com/Project-HAMi/HAMi-WebUI/pull/303

## Project-HAMi/HAMi-WebUI: 715c1a2b -> 5fd62d49
- 比较: 715c1a2ba38adafa4553f37b6d36b7ab64492163 -> 5fd62d49 | ahead=4 | files=68 | Release: v1.3.0
- 比较链接: https://github.com/Project-HAMi/HAMi-WebUI/compare/715c1a2ba38adafa4553f37b6d36b7ab64492163...5fd62d49bc379abeef9b6afed69eba7deed0be26

### AI 总结重点(源码 diff 为据)

- **新增统一工作负载列表 `ListWorkloads`,把"已分配容器"与"未分配但请求了 GPU 的 pod"合并成一张表**。以前列表只来自 `GetAllContainers`(已分配),现在再拉 `ListSchedulingPods` 后 `mergeWorkloads` 合并,pending 行标 `pending=true`;回复里带 `status_counts`(all/pending/waiting/success/abnormal)做分档计数。语义:pending 的 GPU pod 第一次进入控制台视野,不再"排不上就消失"。
  <details><summary>代码依据 server/internal/service/workload.go</summary>

  ```go
  // ListWorkloads joins allocations and GPU requests from the Pod cache. It never reads Events.
  func (s *WorkloadService) ListWorkloads(ctx context.Context, req *pb.ListWorkloadsRequest) (*pb.WorkloadsReply, error) {
      allocated, err := s.containers.GetAllContainers(ctx, ...)
      // Read Pods after allocations so a newer pending snapshot wins.
      pods, err := s.scheduling.ListSchedulingPods(ctx)
      items := mergeWorkloads(allocated.Items, pods)
  ```
  </details>
  <details><summary>代码依据 server/api/v1/workload.proto</summary>

  ```diff
  +message WorkloadsReply {
  +  repeated ContainerReply items = 1;
  +  int32 total = 2;
  +  // Rows per status (all, pending, waiting, success, abnormal), ignoring the status filter.
  +  map<string, int32> status_counts = 3;
  +}
  ```
  </details>

- **调度阶段机(`schedulingStage`)把 GPU pod 分为 terminating/finished/unknown/gated/waiting 五态**。terminating 看 DeletionTimestamp;非 Pending phase 归 unknown;有 SchedulingGates 归 gated;否则 waiting。`ListSchedulingPods` 只收 已绑定/waiting/gated/unknown 的行,已终结(finished)的跳过(与分配列表一致,终态无分配)。
  <details><summary>代码依据 server/internal/data/scheduling_pod.go</summary>

  ```go
  func schedulingStage(pod *corev1.Pod) string {
      if pod.DeletionTimestamp != nil { return "terminating" }
      if pod.Status.Phase == corev1.PodSucceeded || pod.Status.Phase == corev1.PodFailed { return "finished" }
      if pod.Status.Phase != "" && pod.Status.Phase != corev1.PodPending { return "unknown" }
      if len(pod.Spec.SchedulingGates) > 0 { return "gated" }
      return "waiting"
  }
  ```
  </details>

- **核心新增:调度失败原因分类器 `schedulingReasons`**,把 PodScheduled condition 的自由文本 message 解析成结构化 reason code,并区分来源。HAMi 专属码 16 个(`CardInsufficientMemory`/`CardInsufficientCore`/`CardComputeUnitsExhausted`/`CardTimeSlicingExhausted`/`NodeInsufficientDevice`/`CardTypeMismatch`/`CardUuidMismatch`/`CardNotHealth`/`CardCordoned`/`CardMigTopologyInfeasible`/`ResourceQuotaNotFit`/`ModeNotFit` 等),K8s 原生码走关键短语匹配(`untolerated taint`→UntoleratedTaint、node affinity/selector→NodeAffinity、PVC not found→PVCNotFound、`insufficient cpu/memory`→InsufficientCPU/InsufficientHostMemory)。两类都命中→`reason_source=mixed`,单类→hami/kubernetes,都不中→unknown。这是把"软切分调度为什么没排上"从日志考古变成可读诊断的关键。
  <details><summary>代码依据 server/internal/data/scheduling_pod.go</summary>

  ```go
  var hamiSchedulingReasons = []string{
      "CardInsufficientMemory", "CardInsufficientCore", "CardComputeUnitsExhausted", "CardTimeSlicingExhausted",
      "NodeInsufficientDevice", "AllocatedCardsInsufficientRequest", "CardTypeMismatch", "CardUuidMismatch",
      "CardNotHealth", "CardCordoned", "ExclusiveDeviceAllocateConflict", "NumaNotFit",
      "CardMigTopologyInfeasible", "ResourceQuotaNotFit", "CardNotFoundCustomFilterRule", "ModeNotFit",
  }
  func schedulingReasons(message string, resourceNames map[corev1.ResourceName]struct{}) ([]string, string) {
      ...
      if hami && kube { return result, "mixed" }
      if hami { return result, "hami" }
      if kube { return result, "kubernetes" }
      return []string{"UnknownSchedulingReason"}, "unknown"
  }
  ```
  </details>

- **GPU pod 通过自定义 informer index `schedulingGPUIndex` 发现**,判定条件是"带 HAMi 已分配注解 或 容器 requests/limits 里有配置的 GPU 资源名"。默认资源名为 `nvidia.com/gpu`、`gpucores`、`gpumem`、`gpumem-percentage`,可经新配置项 `Scheduling.resource_names` 覆盖(上限 64,必须是带 `/` 的合法扩展资源名)。资源值还会按类型标准化输出(gpucores→core/%、gpumem→memory/MiB)。
  <details><summary>代码依据 server/internal/data/scheduling_pod.go + server/internal/conf/conf.proto</summary>

  ```go
  var defaultSchedulingResources = []string{
      "nvidia.com/gpu", "nvidia.com/gpucores", "nvidia.com/gpumem", "nvidia.com/gpumem-percentage",
  }
  func (r *podRepo) schedulingCandidate(pod *corev1.Pod) bool {
      if pod.Annotations[util.AssignedNodeAnnotations] != "" { return true }
      // ... 遍历 Containers/InitContainers 的 requests/limits 匹配 schedulingResourceNames
  }
  ```
  ```diff
  +// Exact resource names; empty uses the NVIDIA HAMi defaults.
  +message Scheduling {
  +  repeated string resource_names = 1;
  +}
  ```
  </details>

- **详情接口 `GetSchedulingPod` 会读取 K8s Events**(`scheduling_events.go`),为此 Helm role 新增 `events: list` 权限;并做了 pod 身份三重校验(namespace+name+uid 齐全、UID 不匹配报 POD_RECREATED、非 GPU pod 报 GPU_POD_NOT_FOUND),读事件前后各校验一次防 pod 在慢读期间被重建。
  <details><summary>代码依据 charts/hami-webui/templates/role.yaml + scheduling_pod.go</summary>

  ```diff
  +  - apiGroups: [ "" ]
  +    resources: [ "events" ]
  +    verbs: [ "list" ]
  ```
  ```go
  func (r *podRepo) checkedSchedulingPod(namespace, name, uid string) (*corev1.Pod, error) {
      if string(pod.UID) != uid {
          return nil, kratoserrors.Conflict("POD_RECREATED", "A different Pod now uses this name")
      }
      if !r.schedulingCandidate(pod) {
          return nil, kratoserrors.NotFound("GPU_POD_NOT_FOUND", ...)
      }
  ```
  </details>

- **前端路由从深层路径拍平为顶层短路径**:`/admin/vgpu/monitor/overview`→`/overview`、`/admin/vgpu/task/admin`→`/workloads`、`/admin/vgpu/card/admin`→`/accelerators`;删掉 TopBar、新增 SegmentedControl 组件(208 行)与 1086 行 SchedulingDrawer.vue。配合浏览器端 e2e(web-entry.browser.test.mjs)改测新路径。属可用性/信息架构重构。
  <details><summary>代码依据 test/web-entry/web-entry.browser.test.mjs</summary>

  ```diff
  -const deepRoute = `${basePath}admin/vgpu/monitor/overview`
  +const deepRoute = `${basePath}overview`
  -      url.pathname.endsWith('/admin/vgpu/card/admin') &&
  +      url.pathname.endsWith('/accelerators') &&
  ```
  </details>

### 后续发展方向 [AI]
- WebUI 的产品定位正从"GPU 用量监控"上移到"**调度可观测性/自助诊断**":把 HAMi 软切分特有的失败模式(显存不足、核数不足、时分片耗尽、MIG 拓扑不可行、卡型/UUID 不匹配)显式编码成 reason code,是在给"我的 vGPU pod 为什么排不上"提供第一方答案。证据覆盖 reason 分类器 + 阶段机 + 统一列表三处 hunk;未见调度器侧(HAMi 主仓)是否会把这些 code 直接写进 condition——目前 WebUI 靠正则从自由文本 message 反解,若主仓将来结构化输出 reason,这套解析可被替换。
- 资源名可配(`Scheduling.resource_names`)是为纳管非 NVIDIA 加速卡(昇腾/寒武纪/沐曦等)预留的钩子,但默认值与所有 reason code 仍以 `nvidia.com/*` 为中心;证据只覆盖配置项与默认值,未见针对其他厂商资源名的 reason code 适配。
- 读 K8s Events 走 list(非 watch)且详情接口显式"never reads Events"的列表路径分离,说明事件读取被限定在按需详情场景以控访问面;证据为 role.yaml 与 workload.go 注释,未逐行读 scheduling_events.go 的分页/截断实现。

### 对我们产品的启示
- 我们对标 OAI 若做多租户 GPU 平台,"pending pod 为什么排不上"是高频支持工单。HAMi 这套把软切分失败原因结构化 + 区分平台原因(HAMi)vs K8s 原生原因的做法,值得在我们调度诊断里对齐——尤其是把厂商特有失败码与 K8s 通用码分层展示。

## 本期无实质改动(折叠)
<details><summary>四仓 EMPTY,无新提交</summary>

- Project-HAMi/HAMi (master): 无新提交,Release v2.10.0
- Project-HAMi/HAMi-core (main): 无新提交
- Project-HAMi/volcano-vgpu-device-plugin (main): 无新提交
- Project-HAMi/ascend-device-plugin (main): 无新提交,Release ascend-device-plugin-0.1.0
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=Project-HAMi/HAMi sha=88b118e565a9effaa27f81669da291c5508fc5e4 branch=master release=v2.10.0 scanned=2026-09-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-core sha=f01e9f23fc6ab251d2a7fee8987279f16b08afc8 branch=main release=— scanned=2026-09-14 -->
<!-- ANCHOR repo=Project-HAMi/volcano-vgpu-device-plugin sha=cbded47b8d4cabb4ac6b228e52049949a1bae271 branch=main release=— scanned=2026-09-14 -->
<!-- ANCHOR repo=Project-HAMi/ascend-device-plugin sha=4b977f92853a9e797f7d219204e575524e740ee0 branch=main release=ascend-device-plugin-0.1.0 scanned=2026-09-14 -->
<!-- ANCHOR repo=Project-HAMi/HAMi-WebUI sha=5fd62d49bc379abeef9b6afed69eba7deed0be26 branch=main release=v1.3.0 scanned=2026-09-14 -->
