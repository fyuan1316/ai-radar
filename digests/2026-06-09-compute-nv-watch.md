# NVIDIA 算力栈 diff 雷达 2026-06-09

## 摘要
- KAI-Scheduler 落两笔实质改动:一是把 kai-config 这个 Config CR 从 Helm pre-upgrade hook(每次升级都 delete+recreate)改为由 post-upgrade Job 用 kubectl 幂等 apply,解决升级churn/丢用户改动;二是把节点打分 `OrderedNodesByTask` 从「每节点一 goroutine + 共享 mutex」重写为 ants 协程池分块打分,降锁竞争、提大规模集群调度吞吐。
- 其余 8 仓(gpu-operator / container-toolkit / driver-container / k8s-device-plugin / dra-driver / dcgm-exporter / DCGM / mig-parted)本期仅 bump/CI 或无新提交,无实质代码改动。
- 无 ClusterPolicy/CRD 字段增删,无 time-slicing→DRA 迁移信号。

## 当日重要改变
- kai-scheduler/KAI-Scheduler [架构方向] kai-config Config CR 退出 Helm hook 生命周期,改用独立 post-upgrade Job(+ServiceAccount/ClusterRole)out-of-band apply,避免 helm upgrade 重建 CR。证据:`deployments/kai-scheduler/templates/kai-config.yaml`(-243/+12)、新增 `_helpers.tpl` 与 `hooks/post/kai-config-deployer/{job,rbac,configmap}.yaml`。https://github.com/kai-scheduler/KAI-Scheduler/pull/1550
- kai-scheduler/KAI-Scheduler [新能力] 调度打分并行化:引入 `github.com/panjf2000/ants/v2` 协程池,Session 新增 `nodeScoringPool`/`scoringPoolWorkerCount` 字段,节点分块 worker-local 打分后合并,去除全局 mutex。证据:`pkg/scheduler/framework/session.go`(+83/-22)。https://github.com/kai-scheduler/KAI-Scheduler/pull/1548

## kai-scheduler/KAI-Scheduler: 3ef912ec -> 8fbaf953
- 比较: ahead=2 | files=20 | Release: v0.14.5

### AI 总结重点(源码 diff 为据)
- **kai-config CR 脱离 Helm hook,改 Job 幂等下发(#1550)**:旧 `kai-config.yaml` 直接把 `kind: Config` 渲染成带 `helm.sh/hook: pre-install,pre-upgrade` 注解的资源——Helm 把它当 hook 资源管理,每次 upgrade 会 delete+recreate,既制造 churn 又会抹掉运维对 CR 的带外改动。新做法把整段 Config 渲染逻辑抽到命名模板 `kai-scheduler.kai-config`(`_helpers.tpl`),由一个 `post-install,post-upgrade` 的 Job(`kai-config-deployer`)在 release 之外用 `kubectl` apply;Job 还会先 `kubectl annotate config kai-config helm.sh/hook- helm.sh/hook-weight-` 清掉旧版本残留的 hook 注解(否则 Helm 仍会接管删除)。配套新增 ServiceAccount + ClusterRole(`kai.scheduler/configs` 的 get/list/create/update/patch)+ ClusterRoleBinding。
  <details><summary>代码依据 deployments/kai-scheduler/templates/kai-config.yaml + hooks/post/kai-config-deployer/job.yaml</summary>

  ```diff
  # kai-config.yaml:整段 CR 渲染被移除(-243),仅留壳
  -apiVersion: kai.scheduler/v1
  -kind: Config
  -metadata:
  -  name: kai-config
  -  annotations:
  -    "helm.sh/hook": pre-install,pre-upgrade
  -    "helm.sh/hook-weight": "3"
  -spec:
  -  ...
  ```
  ```yaml
  # 新增 hooks/post/kai-config-deployer/job.yaml(post-install,post-upgrade Job)
  +        command: [/bin/bash, -c]
  +        args:
  +        - |
  +          # Strip leftover Helm hook annotations from previous chart versions (#1536)
  +          kubectl annotate config kai-config helm.sh/hook- helm.sh/hook-weight- 2>/dev/null || true
  ```
  </details>
- **节点打分并行化:per-node goroutine → ants 协程池分块(#1548)**:`OrderedNodesByTask` 旧实现对每个 node 起一个 goroutine,各自调 `NodeOrderFn` 后用 `mutex` 写共享 `nodeScores` map——节点多时既是 goroutine 爆炸又是锁热点。新实现按 `scoringPoolWorkerCount` 把节点切成 chunk,经 `ssn.nodeScoringPool.Submit` 提交到 ants 池,每 worker 写自己的 `workerLocalScores[idx]`(无锁),最后串行合并;Submit 失败时降级为顺序执行。Session 结构体新增 `nodeScoringPool *ants.Pool`、`scoringPoolWorkerCount int` 两字段。
  <details><summary>代码依据 pkg/scheduler/framework/session.go</summary>

  ```diff
  +	"github.com/panjf2000/ants/v2"
  ...
  -	k8sResourceStateCache sync.Map
  +	k8sResourceStateCache  sync.Map
  +	nodeScoringPool        *ants.Pool
  +	scoringPoolWorkerCount int
  ...
  -	for _, node := range nodes {
  -		go func(node *node_info.NodeInfo) {
  -			score, err := ssn.NodeOrderFn(task, node)
  -			mutex.Lock()
  -			nodeScores[score] = append(nodeScores[score], node)
  -			mutex.Unlock()
  +	numWorkersToUseInParallel := max(min(ssn.scoringPoolWorkerCount, len(nodes)), 1)
  +	workerLocalScores := make([]map[float64][]*node_info.NodeInfo, numWorkersToUseInParallel)
  +	... ssn.nodeScoringPool.Submit(func() { scoreChunk(idx) })
  ```
  </details>

### 后续发展方向 [AI]
- 配置面在向「声明式 CR 由 operator/Job 统一 reconcile、Helm 只负责静态资源」收敛——kai-config 已不再受 Helm 生命周期摆布,后续运维带外改 CR 不会被 upgrade 覆盖。证据只覆盖 chart 模板与 Job/RBAC,未见 operator 侧对该 CR 的 reconcile 逻辑改动。
- 调度性能优化指向大规模节点场景(协程池分块打分),但本 diff 未见 `scoringPoolWorkerCount` 的配置入口/默认值出处,无法判断是否可由用户调参——证据只覆盖 session.go 的池使用,未见池初始化与配置注入点。

## 本期无实质改动(折叠)
<details><summary>8 仓 EMPTY(仅 bump/CI 或无新提交)</summary>

- NVIDIA/gpu-operator(ahead=2,仅 bump/CI)
- NVIDIA/nvidia-container-toolkit(无新提交)
- NVIDIA/gpu-driver-container(ahead=2,仅 bump/CI)
- NVIDIA/k8s-device-plugin(无新提交)
- kubernetes-sigs/dra-driver-nvidia-gpu(无新提交)
- NVIDIA/dcgm-exporter(无新提交)
- NVIDIA/DCGM(无新提交)
- NVIDIA/mig-parted(ahead=2,仅 bump/CI)
</details>

## 扫描锚点(机器可读,勿手改——下次跑据此定 base)
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=1ab8a08a932c72475de7cdc28410b91fac23c7d1 branch=main release=v26.3.2 scanned=2026-06-09 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=e0bcfd493755f5c11ae18c56c5a1f172d061af5c branch=main release=v1.19.1 scanned=2026-06-09 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=a929c768f93d5e7dfa888a959e11cc8af28d327b branch=main release=— scanned=2026-06-09 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=db1ea9481054448d97ae43bd082147e7d6ba5501 branch=main release=v0.19.2 scanned=2026-06-09 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=f51778e2e66c6bf9364d8ae319cdd5ad609ec4a3 branch=main release=v0.4.0 scanned=2026-06-09 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=d5e5f510a1b6b393f39a43293ccd9dc985defc79 branch=main release=4.5.3-4.8.2 scanned=2026-06-09 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=0869351a7d89ff24e68c93b92a50d981cea15580 branch=master release=— scanned=2026-06-09 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=9221140671899b3c0dd281cd849927c0ba02120f branch=main release=v0.14.2 scanned=2026-06-09 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=8fbaf953f84c633ef73a2c86b584e6e990b52d14 branch=main release=v0.14.5 scanned=2026-06-09 -->
