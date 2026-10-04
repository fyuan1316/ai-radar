# NVIDIA 算力栈 diff 雷达 2026-10-05

## 摘要
- KAI-Scheduler 把 API 类型整体外移到独立 Go 模块 `github.com/kai-scheduler/api`(v0.1.4),CRD 类型从"随调度器仓发布"转为"可被第三方单独 import"的版本化契约——打包/集成架构信号。
- KAI 调度器 solver 优化:单任务作业跳过二分探测(`searchMaxSolvableK`),`n>1` 才做 maxK 搜索,减少一次重复全量 probe。
- 其余 8 仓(gpu-operator / container-toolkit / driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)本日无新提交。

## 当日重要改变
- KAI-Scheduler [架构方向] API 类型从 in-tree `pkg/apis/...` 外移到独立模块 `github.com/kai-scheduler/api`,go.mod 新增该依赖 v0.1.4,299 文件改 import 路径。 https://github.com/kai-scheduler/KAI-Scheduler/commit/dfbe76e7397af52bdc82fb90b0b494eca0f517d6

## kai-scheduler/KAI-Scheduler: 5982e4bf -> dfbe76e7
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/5982e4bf5559120d1fb5650ebec7fe400e85bc95...dfbe76e7397af52bdc82fb90b0b494eca0f517d6 | ahead=2 | 最新 Release v0.18.2
- 说明:ahead 仅 2 commit,但其中 `refactor(api)` 是全仓机械改 import,触及 300+ 文件(被 API 截断到 300),故 helper 走了 OVERVIEW;下面两条均已单独取 commit patch 做符号级研判。

### AI 总结重点(源码 diff 为据)
- **API 类型外移为独立版本化模块**:`refactor(api)` 把所有 CRD 类型的 import 从 in-tree `github.com/kai-scheduler/KAI-scheduler/pkg/apis/{kai/v1alpha1,scheduling/v1alpha2,v2,v2alpha2}` 改为外部模块 `github.com/kai-scheduler/api/{...}`,go.mod 新增 `github.com/kai-scheduler/api v0.1.4`。本次 300 个文件里 299 modified + 1 added,无逻辑改动,纯打包边界调整——CRD 类型成为可被外部项目单独消费的发布物。
  <details><summary>代码依据 go.mod + cmd/admission/app/app.go</summary>

  ```diff
  # go.mod
  + github.com/kai-scheduler/api v0.1.4
  ```
  ```diff
  # cmd/admission/app/app.go
  - kaiv1alpha1 "github.com/kai-scheduler/KAI-scheduler/pkg/apis/kai/v1alpha1"
  - schedulingv1alpha2 "github.com/kai-scheduler/KAI-scheduler/pkg/apis/scheduling/v1alpha2"
  - schedulingv2 "github.com/kai-scheduler/KAI-scheduler/pkg/apis/scheduling/v2"
  - schedulingv2alpha2 "github.com/kai-scheduler/KAI-scheduler/pkg/apis/scheduling/v2alpha2"
  + kaiv1alpha1 "github.com/kai-scheduler/api/kai/v1alpha1"
  + schedulingv1alpha2 "github.com/kai-scheduler/api/scheduling/v1alpha2"
  + schedulingv2 "github.com/kai-scheduler/api/scheduling/v2"
  + schedulingv2alpha2 "github.com/kai-scheduler/api/scheduling/v2alpha2"
  ```
  </details>
- **solver 单任务跳过二分探测**:`perf(scheduler): avoid duplicate full job solver probe`。`solvePendingJobWithGenerator` 现在只在 `n>1`(待分配任务 >1)时才跑 `searchMaxSolvableK`,之后无条件对完整 n 做一次 `probeAtK`;`searchMaxSolvableK` 的边界从 `n==0` 收紧到 `n<=1` 直接返回 0,内层二分循环改为 `for k < n` 且命中 `k>=n` 时返回 `lo` 而非 `n`。效果:k 搜索区间从 `[0,n]` 收窄为 `[0,n)`,把"k 已到 n 还要再探一次"的重复全量 probe 去掉(测试断言从 4 次 probe 降到 3 次)。
  <details><summary>代码依据 pkg/scheduler/actions/common/solvers/job_solver.go</summary>

  ```diff
  -	maxSolvedK, searchResult := s.searchMaxSolvableK(...)
  -	if maxSolvedK == 0 { ... return searchResult }
  +	if n > 1 {
  +		maxSolvedK, searchResult := s.searchMaxSolvableK(...)
  +		if maxSolvedK == 0 { ... return searchResult }
  +	}
   	result := s.probeAtK(ssn, state, pendingJob, tasksToAllocate, n, ...)

  -// searchMaxSolvableK returns the largest k in [0, n] for which a probe at k succeeds.
  +// searchMaxSolvableK returns the largest k in [0, n) for which a probe at k succeeds.
  ...
  -	if n == 0 { return 0, nil }
  +	if n <= 1 { return 0, nil }
  ...
  -	for {
  +	for k < n {
   		...
  -		if k == n { return n, lastUnsolvedResult }
   		k *= 2
  -		if k > n { k = n }
  +		if k >= n { return lo, lastUnsolvedResult }
  ```
  </details>

### 后续发展方向 [AI]
- API 外移意味着 KAI 想把自己的调度 CRD(queue / podgroup / scheduling.kai v2 等)做成独立可依赖的契约层,降低外部 operator/集成方对整仓的耦合——这是把 KAI 当"平台底座"而非"单体调度器"推的信号。证据只覆盖 import 路径与 go.mod,未见 `github.com/kai-scheduler/api` 仓内是否对字段做了 v2/v2alpha2 的 schema 变更(需单独扫该 api 仓才能确认)。
- solver 这条是纯性能/正确性收敛(去掉单任务场景的冗余全量 probe),不改调度语义;配合 release note 里 `gpu-memory.limit`/`gpu-fraction.limit` 与 nvFraction 的多条 fix,方向仍是把 GPU 分数化(fractioning)路径做扎实。证据只覆盖 job_solver.go 的 k-search,未展开 fractioning 相关 PR 的 hunk。

## 本期无实质改动(折叠)
<details><summary>8 仓无新提交</summary>

- NVIDIA/gpu-operator(Release v26.7.1)
- NVIDIA/nvidia-container-toolkit(Release v1.20.1)
- NVIDIA/gpu-driver-container
- NVIDIA/k8s-device-plugin(Release v0.20.1)
- kubernetes-sigs/dra-driver-nvidia-gpu(Release v0.5.0)
- NVIDIA/dcgm-exporter(Release 4.8.4)
- NVIDIA/DCGM
- NVIDIA/mig-parted(Release v0.15.1)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=3e1873a25ef46219f9b2db6f19a0b90818729586 branch=main release=v26.7.1 scanned=2026-10-05 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=a672e378ef91bea7dfe92c0ed274847fa1cb9236 branch=main release=v1.20.1 scanned=2026-10-05 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=46f292d300b2affd6202d45a1422e41bfedd8fd0 branch=main release=— scanned=2026-10-05 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=d7265fdcf89f571e70b5eb6724ba78a3398bc03e branch=main release=v0.20.1 scanned=2026-10-05 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=c6784feadfcb65aeddbd40ca86add9b0856288d8 branch=main release=v0.5.0 scanned=2026-10-05 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=fafd151148052628061a80450b4ee037a5fa0c3c branch=main release=4.8.4 scanned=2026-10-05 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-10-05 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9a831d5d84770d6d976c6499572425eddc88ee7a branch=main release=v0.15.1 scanned=2026-10-05 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=dfbe76e7397af52bdc82fb90b0b494eca0f517d6 branch=main release=v0.18.2 scanned=2026-10-05 -->
