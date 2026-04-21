# 任务:Kubernetes AI 基础设施周报

## 目标
跟踪 Kubernetes 社区里与 AI/ML 工作负载直接相关的 SIG 级别变化:调度、加速器管理、资源分配。这些是所有云原生 AI 产品的"地基",变化会影响上层所有组件的架构决策。

> **与 `tasks/k8s-core.md` 的边界**:本任务只管 **AI-specific** 组件(gpu-operator / NFD / DRA 设备层 / LWS / JobSet / Kueue / scheduler-plugins gang 等)。通用的 K8s 集群能力(kube-scheduler 自身、kubelet、VPA、Cluster Autoscaler、Karpenter、controller-runtime、Gateway API、CSI、Gatekeeper/Kyverno 等)由 `k8s-core` 负责。重叠时默认归本任务,`k8s-core` 只在有通用溢出影响时补一笔。

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

### K8s 核心
- `kubernetes/enhancements` — KEP 跟踪,筛选 AI/GPU/DRA/scheduling 相关
- `kubernetes/kubernetes` — 主仓库只看 CHANGELOG 和 release notes(不看 commit)

### 可观测 & 成本
- `kubernetes-sigs/usage-metrics-collector` — 资源用量采集

每个仓库看过去 7 天:releases + 重要 PR(筛选 merged)。kubernetes/enhancements 只看新增或状态变更的 KEP(grep "kep" + "gpu|accelerator|dra|scheduling|topology|device")。

## 输出

写到 `digests/YYYY-MM-DD-k8s-ai-infra.md`:

```markdown
# K8s AI 基础设施周报 YYYY-MM-DD

## 摘要(3 条以内)

## GPU / 加速器管理
- ...

## 调度 & 资源分配
### Kueue
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
- 每条带链接
