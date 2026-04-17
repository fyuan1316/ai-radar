# 专题:infer-operator 与 InferNex 的关系

跟进自 2026-04-17 OpenFuyao 周报"值得跟进"第一条。

## 一句话结论

**不是替代关系,是不同抽象层的并行品**。infer-operator 是昇腾 mind-cluster 内的「推理工作负载 K8s 编排层」(operator + CRD),InferNex 是 OpenFuyao 的「推理服务系统层」(Helm + GIE + vLLM)。前者归华为昇腾事业部,后者归 OpenFuyao 社区,**两支队伍各自在做推理抽象**,短期会重叠、长期有整合可能。

## 对比表

| 维度 | infer-operator(mind-cluster) | InferNex(openFuyao) |
|------|-----------------------------|---------------------|
| **抽象层** | K8s 工作负载层(operator pattern) | 推理运行时层(Helm chart 集合) |
| **对外核心抽象** | InferServiceSet → InferService → InstanceSet 三层 CRD(`mindcluster.huawei.com/v1`) | **无自定义 CRD**,复用 K8s GIE 的 `InferencePool` / `InferenceObjective` + label(`openfuyao.com/pdRole`) |
| **落到 K8s 原语** | 渲染为 Deployment / StatefulSet(+ 可用户自定义) | 直接 Deployment(Helm 渲染) |
| **推理引擎** | RFC 不绑定具体引擎,只做编排 | 强绑定 **vLLM / vLLM-Ascend** |
| **多角色协同** | 通过 CRD 层次 + Volcano gang schedule | 通过 Helm values + label + pd-orchestrator |
| **弹性** | RFC 里"未来计划"之一 | 已有 `pd-orchestrator`(内含 elastic-scaler + resource-scaling-group + tidal) |
| **路由** | 不管 | hermes-router(基于 GIE) |
| **KVCache** | 不管 | cache-indexer + Mooncake transfer |
| **可观测** | 不管 | eagle-eye(hardware-monitor + diagnosis) |
| **部署形态** | K8s Operator(operator.yaml / 规划 Helm) | Helm chart(Quick Start 走 `helm install`) |
| **治理归属** | 华为昇腾 / mind-cluster 社区 | OpenFuyao 社区 |
| **RFC 是否提 KServe** | **未提** | Roadmap 里明说 26-X 要对接 KServe |
| **仓库语言** | Go(operator) | Python(proxy-server)+ Helm(主要) |

## 关键证据(原文节选)

### infer-operator(`Ascend/mind-cluster` `docs/rfc/26.0.0/features-inference-workload.md`)

> 推理工作负载特性是 MindCluster 针对大模型推理服务在昇腾硬件集群上提供的 K8S 工作负载能力,支持推理服务的单机、多机、PD分离等场景的任务管理能力。本特性新增组件 Infer Operator,其是一个 Kubernetes Operator,用于部署和管理多角色合作的推理任务。它定义了三种自定义资源(CRD):InferServiceSet、InferService 和 InstanceSet。

替代的是自家旧方案,不是外部方案:

> MindCluster 此前通过 ascend-operator 提供的 ascend job CRD 部署推理任务,单 acjob 映射一个推理实例的方式只能解决部分场景下的协同问题,无法很好的支持越来越复杂的场景。

层次结构:

```
InferServiceSet
    └─── InferService (1..N)
            └─── InstanceSet (1..N)
                    ├─── Service (0..N)
                    └─── Workload (Deployment/StatefulSet)
                            └─── Pod (1..N)
```

设计目标:简化多角色推理服务部署、水平扩缩、统一状态监控、**gang 调度**、兼容 K8s 生态。Volcano PodGroup 作为 gang schedule 载体。

全文 grep 未匹配 KServe / InferNex / vLLM —— **RFC 设计时没有把这两个作为参照物**。

### InferNex(`openFuyao/InferNex` README + Chart.yaml)

> 提供 openFuyao AI 推理服务化框架的端到端一键式集成部署……基于主流 LLM 推理技术栈及 K8s 官方项目 GIE(Gateway API Inference Extension)构建。

对外抽象复用上游 CRD,不自建:

- `inferencepools.inference.networking.x-k8s.io`(GIE)
- `inferenceobjectives.inference.networking.x-k8s.io`(GIE)
- `resourcescalinggroup.autoscaling.openfuyao.com/v1alpha1`(pd-orchestrator 子 chart 带,非 InferNex 本仓)

Roadmap **明确把 KServe 当对接对象**:

> [26-X] 规划 KServe 对接适配,便于统一管理 predictive、LLM 等不同类型推理 Serving 及 InferNex、llm-d 等算力栈流量。

组件清单:inference-backend(vLLM/vLLM-Ascend)、pd-orchestrator(弹性)、hermes-router(路由)、cache-indexer(KVCache 元数据)、eagle-eye(可观测)、inference-gateway(Istio)、Mooncake(KVCache transfer)。

## 关系分析

### 为什么不是替代?

1. **抽象层不一样**。infer-operator 站在"一个推理任务在 K8s 里怎么表达"这一层,产出的是 CRD 和 workload;InferNex 站在"一个推理服务的完整运行时怎么拼起来"这一层,产出的是一套 Helm 打包好的运行时组件。前者是"盒子",后者是"盒子里的东西"。
2. **技术栈不一样**。infer-operator 是 Go + operator pattern;InferNex 是 Helm + GIE + Python 胶水 + vLLM。把两边互换要几乎重写。
3. **不对对方存在感知**。infer-operator RFC 全文没提 InferNex;InferNex README 也没提 mind-cluster 或 infer-operator。说明**两支队伍在各自的路线里推进**。

### 为什么会看起来像替代?

1. 都声称解决"多角色协同"(PD 分离、AF 部署)。infer-operator 用三层 CRD 解,InferNex 用 Helm + label 解。**对用户来说表面功能重合**。
2. 都是华为牵头。外部用户看不清华为内部两支团队的边界,容易以为在内部竞争。

### 最有可能的整合路径(我判断)

infer-operator RFC 第 2 节说"三层 CRD **支持替换为 K8S 原生工作负载,如 Deployment、StatefulSet 等,同时支持用户扩展自定义的 CRD 类型**"——这句话给出了一个接口点。未来可行路径:

- **InferNex 把 inference-backend 的 Deployment 交给 infer-operator 的 InstanceSet 管**,自己聚焦路由 / KVCache / 弹性 / 可观测
- 或者 **infer-operator 的 InferService CRD 里允许引用 GIE InferencePool**,让上层统一,下层 mind-cluster 管

但这需要两边团队对齐,目前没有公开信号说已经在对齐。

## 对我们产品的启示

**核心启示:"推理负载的 K8s 抽象"至少有三条路,选型要想清楚**。

| 路线 | 代表 | 特点 | 风险 |
|------|------|------|------|
| A. KServe InferenceService CRD | OAI / 我们的现状 | 通用多框架,上游成熟 | 对 LLM 复杂场景(PD 分离、多角色)表达力不够 |
| B. GIE InferencePool | InferNex / llm-d | 路由优先、数据面抽象 | 还是 alpha,CRD 多,心智负担大 |
| C. 自建 operator 抽象 | infer-operator / KubeAI | 表达力强,可定制 | 跟 KServe 生态割裂 |

**具体建议**:

1. **主干路线不变**:继续用 KServe InferenceService 作为服务级抽象(跟 OAI 对齐)
2. **数据面引入 GIE**:参考 InferNex 用 GIE InferencePool 做 LLM 路由层,这跟 llm-d 方向一致,是产业共识
3. **昇腾场景要有兜底**:如果我们产品要支持昇腾集群,需要看清楚客户是用 mind-cluster(会看到 infer-operator)还是用 OpenFuyao(会看到 InferNex)——**两者不能完全混用**
4. **警惕"用 CRD 解决一切"的诱惑**:infer-operator 三层 CRD 看起来体面,但运维成本不低;InferNex 用 Helm + label 反而更轻量

**不要做的事**:

- 不要自建类似 infer-operator 的 CRD。华为昇腾栈内部都还没跑通,我们下场只会被动
- 不要直接抄 InferNex 的 vLLM 绑定。我们客户引擎诉求比单一 vLLM 广

## 下一步值得跟踪

- [ ] InferNex 26-X 里程碑兑现 KServe 对接后,看它具体怎么把 KServe InferenceService 映射到 GIE InferencePool —— 这是可复用模式
- [ ] mind-cluster 后续版本的 infer-operator 是否把"引用 GIE InferencePool"加入 CRD —— 这是两边整合的标志
- [ ] 观察昇腾生态在 KubeCon / 开源中国 这类场合是否明确两条路线的分工(或合并)
- [ ] InferNex `pd-orchestrator` 的 `resourcescalinggroup` CRD 细节(在 pd-orchestrator 子 chart,未来单独读一次)

## 附:抓取信息

- infer-operator RFC 原文:<https://gitcode.com/Ascend/mind-cluster/blob/master/docs/rfc/26.0.0/features-inference-workload.md>(441 行,commit 窗口锚点 `4db91ae`,截止 2026-04-17 HEAD `145426ad`)
- InferNex repo:<https://gitcode.com/openFuyao/InferNex>(README 126 行,主 chart `charts/infernex`,chart version 0.0.0-latest,示例 0.20.0)
- InferNex 用户手册:<https://gitcode.com/openFuyao/sig-ai-inference/blob/main/docs/zh/ai_inference_infernex/user_guide/ai_inference_infernex.md>
- 两边均通过 `git clone --depth 1` 成功抓取(WebFetch 对 GitCode raw 返回 JS 壳,实测不可用)
