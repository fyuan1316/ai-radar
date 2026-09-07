# NVIDIA 算力栈 diff 雷达 2026-09-08

## 摘要
- 仅 **KAI-Scheduler** 活跃(2 实质提交,均非核心代码):新增了"优先级驱动的 in-quota 回收"(priority-based in-quota reclaim)**设计文档**,把昨日已落地的 `InQuotaQueuePriorityStrategy` 代码正式补上架构说明,并明确该能力定位为 **v0.18 alpha**、按调度 shard 显式 opt-in;另一提交是 e2e CI 修 Prometheus chart 版本钉扎。
- NVIDIA 供应商栈其余 8 仓(gpu-operator / container-toolkit / driver-container / k8s-device-plugin / dra-driver-nvidia-gpu / dcgm-exporter / DCGM / mig-parted)全 EMPTY,ClusterPolicy CRD、DRA、time-slicing/MPS 配置面本区间零演进。

## 当日重要改变
- KAI-Scheduler [架构方向] 新增设计文档 `docs/developer/designs/priority-based-in-quota-reclaim.md`,为昨日落地的 `InQuotaQueuePriorityStrategy` 补齐设计依据:明确定位 v0.18 alpha、每 shard opt-in,并给出跨层级队列优先级比较(复用 LCA `getLeveledQueues`)、防回收环(reclaim loop)论证、队列排序函数改动三块设计细节。证据 docs/developer/designs/priority-based-in-quota-reclaim.md。https://github.com/kai-scheduler/KAI-Scheduler/pull/2092

## kai-scheduler/KAI-Scheduler: 61e935cb -> 57a0ca0d
- 比较: https://github.com/kai-scheduler/KAI-Scheduler/compare/61e935cb233887894d548412cbed87da59a7542c...57a0ca0d | ahead=2 | files=3 | Release: v0.17.1

### AI 总结重点(源码 diff 为据)
- **补齐 priority-based in-quota reclaim 的设计文档,并首次给出发布节奏**:新增 97 行设计文档,开篇即声明 "This feature will be implemented as alpha for v0.18"。这与 09-07 已合入的实现代码(`InQuotaQueuePriorityStrategy` + `queuePriorityInQuotaReclaim` flag)形成"代码先行、设计文档回补"的顺序。文档把该能力的核心权衡讲清:此前配额是绝对的("Quota Protection Guarantee",in-quota 资源永不可被回收),该特性首次允许"客户自己决定优先级是否比配额更重要",从而放宽了对低优先级队列的配额保护——因此强制 opt-in(per scheduling shard)。
  <details><summary>代码依据 docs/developer/designs/priority-based-in-quota-reclaim.md</summary>

  ```diff
  +# Priority-Based In-Quota Reclaim
  +
  +This feature will be implemented as alpha for v0.18.
  +...
  +- `MaintainFairShareStrategy` — reclaimable if the victim queue is currently allocated above its allocatable fair share.
  +- `GuaranteeDeservedQuotaStrategy` — reclaimable if the reclaimer stays within its own deserved quota **and** the victim queue is currently above its deserved quota.
  +Both require the victim queue to be over-quota in some sense. In-quota (`Allocated <= Deserved`) allocations are never reclaimable — this is documented as the "Quota Protection Guarantee".
  +...
  +This allows the customer to decide if priority is more important to the cluster fairness state rather then quota, which until now, was absolute.
  ```
  </details>
- **回收触发条件三段式,且论证了"不会产生回收环"**:文档把新回收路径的准入条件固化为 `reclaimerQueue.Priority > victimQueue.Priority` AND reclaimer 回收后仍在自身 Deserved 配额内 AND victim task 可抢占;并论证因 reclaimer 回收后必然处于 in-quota、且 reclaimee 恒来自更低优先级队列,故三条现有策略均无法把资源"反向回收"回去,不会形成 loop。
  <details><summary>代码依据 docs/developer/designs/priority-based-in-quota-reclaim.md</summary>

  ```diff
  +reclaimerQueue.Priority > victimQueue.Priority
  +AND
  +reclaimer's queue stays within its own Deserved quota after taking the resource
  +AND
  +victim task is preemptible (already enforced upstream by both actions)
  +...
  +## 4. No Reclaim Loops
  +A reclaim of a `InQuotaQueuePriorityStrategy` will happen only for a reclaimer that fits into the quota of the higher priority queue...
  ```
  </details>
- **跨层级队列的优先级比较复用现有 LCA 逻辑**:多层 hierarchy 下比较哪两个队列的优先级——复用 `Reclaimable.getLeveledQueues`(`reclaimable.go`),沿两队列祖先路径找到最低公共祖先(LCA)后,比较 LCA 下一层的两个分支队列优先级。属复用现有抽象、非新增机制。
  <details><summary>代码依据 docs/developer/designs/priority-based-in-quota-reclaim.md</summary>

  ```diff
  +## 5. Hierarchy Scoping
  +...we will reuse the current logic of finding the lowest common ancestor, then compare the priority of the two branches one level below it...
  +The existing reclaim path already needs to compare a reclaimer and a reclaimee that may live in different branches, and already solves this via `Reclaimable.getLeveledQueues` (`reclaimable.go`)
  ```
  </details>
- **CI:e2e 集群钉扎 kube-prometheus-stack 到 90.0.0 并关闭控制面组件的 ServiceMonitor**:`setup-e2e-cluster.sh` 与 GitHub Action 同步加 `--version 90.0.0`,并把 kubeApiServer/kubelet/kubeControllerManager/coreDns/kubeEtcd/kubeScheduler/kubeProxy 全部 `enabled=false`(kind 集群无对应可抓端点,避免 ServiceMonitor 报错)。纯测试基建,无产品语义。
  <details><summary>代码依据 hack/setup-e2e-cluster.sh</summary>

  ```diff
  +    --version 90.0.0 \
       --set "alertmanager.enabled=false" \
  +    --set "kubeApiServer.enabled=false" \
  +    --set "kubelet.enabled=false" \
  +    --set "kubeScheduler.enabled=false" \
  ```
  </details>

### 后续发展方向 [AI]
- KAI 把"优先级压过配额保护"从代码正式抬到设计文档并锚定 v0.18 alpha,说明该能力不是一次性 hack 而是有节奏推进的产品特性——多租户强 SLA 场景(高优队列可抢占低优队列 in-quota 资源)是其目标。证据边界:文档明确 opt-in/alpha,本区间未见默认开启计划,也未见把 `queuePriorityInQuotaReclaim` 开关暴露到 CRD/API 层的 `*_types.go` 改动(与 09-07 观察一致,配置入口是全局 vs 队列级仍未在代码中定型)。
- 设计文档中"队列排序函数改动"一节(第 6 节,hunk 已截断)预告了 `proportion` 插件排序会新增"两队列均 in-quota 时优先级先于 starvation"的分支——这与 09-07 已见的 `prioritizeBasedOnPriorityIfBothQueuesInQuota` 实现对应,可视为设计与实现闭环。

## 本期无实质改动(折叠)
<details><summary>EMPTY 仓(仅锚点,无新提交/仅 bump·CI·merge)</summary>

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
<!-- ANCHOR repo=NVIDIA/gpu-operator sha=08c40bc479192e3d5a82b7fd41d7e85a7197741f branch=main release=v26.7.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=NVIDIA/nvidia-container-toolkit sha=752e1e571bdfda0a5e0e3f5804c4c556796ab0eb branch=main release=v1.20.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=NVIDIA/gpu-driver-container sha=9ac64592151369a93da35b831322f193c03b13f5 branch=main release=— scanned=2026-09-08 -->
<!-- ANCHOR repo=NVIDIA/k8s-device-plugin sha=4edf2b66ec53db87c36e035f82e5629b676893e3 branch=main release=v0.20.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=kubernetes-sigs/dra-driver-nvidia-gpu sha=8ad4e66f1367b852c36e1f405d50055b7b3bbe66 branch=main release=v0.5.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=NVIDIA/dcgm-exporter sha=181290c399d46a9b905e083d0204348be63cb436 branch=main release=4.6.0-4.8.3 scanned=2026-09-08 -->
<!-- ANCHOR repo=NVIDIA/DCGM sha=64df9f894541e426e416131a9820cae97aa4dd81 branch=master release=— scanned=2026-09-08 -->
<!-- ANCHOR repo=NVIDIA/mig-parted sha=2098686586250d28c472aaa821643a069f8464ec branch=main release=v0.15.0 scanned=2026-09-08 -->
<!-- ANCHOR repo=kai-scheduler/KAI-Scheduler sha=57a0ca0d52d227aa964a8a2b05db0605280c469c branch=main release=v0.17.1 scanned=2026-09-08 -->
</content>
</invoke>
