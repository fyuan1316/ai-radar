# 任务:Kubernetes AI 基础设施周报

## 目标
跟踪 Kubernetes 社区里与 AI/ML 工作负载直接相关的 SIG 级别变化:调度、加速器管理、资源分配。这些是所有云原生 AI 产品的"地基",变化会影响上层所有组件的架构决策。

> **与 `tasks/k8s-core.md` 的边界**:本任务只管 **AI-specific** 组件(gpu-operator / NFD / DRA 设备层 / LWS / JobSet / Kueue / scheduler-plugins gang 等),**外加 kube-scheduler 的 AI 方向原生演进**(Workload Aware Scheduling / gang / Workload API / PodGroup,详见下面"上游原生调度"节)。通用的 K8s 集群能力(kube-scheduler 的非 AI 通用改动、kubelet、VPA、Cluster Autoscaler、Karpenter、controller-runtime、Gateway API、CSI、Gatekeeper/Kyverno 等)由 `k8s-core` 负责。重叠时默认归本任务,`k8s-core` 只在有通用溢出影响时补一笔。

## 数据源(GitHub API)

### GPU / 加速器管理
- `NVIDIA/gpu-operator` — NVIDIA GPU Operator
- `NVIDIA/k8s-device-plugin` — NVIDIA device plugin
- `kubernetes-sigs/node-feature-discovery` — NFD,硬件特征发现

### 调度 & 资源分配
- `kubernetes-sigs/kueue` — 作业队列/配额/公平调度(AI 集群必备)
- `kubernetes-sigs/dra-evolution` — Dynamic Resource Allocation 演进(GPU 共享/分片的未来)
- `kubernetes-sigs/scheduler-plugins` — 调度器插件(gang scheduling 等)
- `kubernetes-sigs/lws` — LeaderWorkerSet(多节点推理/训练的原生 K8s 方案,OAI 已在用)
- `kubernetes-sigs/jobset` — JobSet(大规模训练作业编排)
- `volcano-sh/volcano` — 批调度事实标准,gang scheduling;昇腾整个调度栈(ascend-for-volcano / volcano-ext / HAMi vgpu plugin)压在它上面,主仓 release/API 变化直接波及三个 watch task 下游(`compute-nv-watch` 边界说明里"volcano 归 k8s-ai-infra"指的就是这里)
- `volcano-sh/kthena` — Volcano 社区的 AI 推理调度/路由项目,2026-07 GA v1.0;与 InferNex/KServe 推理路由同赛道,openFuyao 大概率会跟
- `koordinator-sh/koordinator` — P2 低频:阿里系在离线混部 + QoS 感知调度,只看 release,不扫 PR
- `ai-dynamo/grove` — P2 观察:NVIDIA Dynamo 生态多角色 AI workload 编排(PodClique/gang),与 LWS DisaggregatedSet 是竞争路线;alpha 阶段,每月扫一眼 release 即可

### 上游原生调度(SIG Scheduling / WAS 主线)
> kube-scheduler 正在原生收编 AI 调度能力,这条线是"生态调度器(Volcano/Kueue/KAI)长期会被上游挤压到什么位置"的核心研判依据。时间线锚点:v1.35 引入 Workload Aware Scheduling(WAS)+ KEP-4671 Workload API gang scheduling(alpha)→ v1.36 补 PodGroup API + 原子成组调度周期 → v1.37 两个 feature gate 合并为 `GenericWorkload` 冲 beta。
- `kubernetes/kubernetes` — 除 CHANGELOG/release notes 外,**加扫 sig/scheduling label 的 merged PR**(`https://api.github.com/search/issues?q=repo:kubernetes/kubernetes+is:pr+is:merged+label:sig/scheduling+merged:>=<SINCE>`),只挑 WAS / gang / Workload / PodGroup / preemption / TAS 相关,过滤 test/ci 噪声
- `kubernetes/enhancements` — KEP 筛选词在原有 `gpu|accelerator|dra|scheduling|topology|device` 基础上**加 `gang|workload|podgroup|preemption`**;重点盯 KEP-4671(gang/Workload)、KEP-5710(workload-aware preemption)、KEP-5732(TAS)、KEP-5729(workload-level ResourceClaim)的状态变更

### K8s 核心
- `kubernetes/kubernetes` — CHANGELOG 和 release notes(通用视角;sig/scheduling PR 扫描见上节)

### 可观测 & 成本
- `kubernetes-sigs/usage-metrics-collector` — 资源用量采集

每个仓库看过去 7 天:releases + 重要 PR(筛选 merged)。kubernetes/enhancements 只看新增或状态变更的 KEP(grep "kep" + "gpu|accelerator|dra|scheduling|topology|device|gang|workload|podgroup|preemption")。P2 仓(koordinator / grove)只看 release,无 release 则跳过不凑字。

## 输出

写到 `digests/YYYY-MM-DD-k8s-ai-infra.md`:

```markdown
# K8s AI 基础设施周报 YYYY-MM-DD

## 摘要(3 条以内)

## GPU / 加速器管理
- ...

## 调度 & 资源分配
### 上游原生调度(WAS / gang / Workload API)
### Kueue
### Volcano / Kthena
### DRA
### LWS / JobSet

## KEP 动向
- 新增/推进中的 AI 相关 KEP

## 值得跟进
- [ ] ...
```

## 推送飞书

**格式和推送流程:见 [oai-weekly 推送规范](./oai-weekly.md#推送飞书)**(前置先 `git push`、简讯纯文本不得含 markdown 语法、链接用裸 URL;DIGEST_FILE 改成 `digests/$(date +%Y-%m-%d)-k8s-ai-infra.md`)。

## 质量要求
- KEP 是最有价值的信号:一个新 KEP 可能决定我们 6 个月后的架构选型
- 关注"什么能力进了哪个 K8s 版本的 alpha/beta/GA"
- DRA 是重中之重,它将取代 device-plugin 模式,影响所有加速器方案
- **WAS 原生化 vs 生态调度器是常设研判题**:每期上游原生调度节要回答"这次 WAS/gang 进展,挤压还是利好 Volcano / Kueue / KAI 的哪块地盘"(参照:Kueue 已把 DRA/Workload 路径当默认在追,Volcano 的 gang 独占性在被稀释)
- 每条带链接
