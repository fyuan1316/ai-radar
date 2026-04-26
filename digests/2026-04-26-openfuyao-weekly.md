# OpenFuyao / 华为系周报 2026-04-26

窗口:2026-04-19 → 2026-04-26

## 摘要

- 本周公开渠道没有看到 OpenFuyao 新版本公告或重大官网动态,[openFuyao 官网](https://www.openfuyao.cn/zh/) 仍把 AI 推理套件、分布式 KVCache、智能路由、NPU Operator、NUMA 亲和、超大规模集群调度作为核心能力。
- 华为系云原生 AI 栈的主线仍是 **昇腾/NPU 资源管理 + KVCache-aware routing + 超大规模集群调度**。启示:它与 OAI/KServe 的交集在推理路由和 workload 编排,分叉点在硬件生态强绑定。
- 对我们产品最有借鉴意义的是通用抽象:accelerator operator contract、KV-aware routing、NUMA/混部指标、底层调度和模型 SLA 的映射;昇腾专用驱动/UB 网络/vNPU 细节暂时不应直接照搬。

## 新功能 / 能力

- [openFuyao 官网](https://www.openfuyao.cn/zh/) 继续强调 AI 推理场景加速,包括分布式 KVCache、智能路由与缓存命中策略优化、降低 TTFT、突破 N/S 和 E/W 全局显存瓶颈。
  - 启示:OpenFuyao 与 vLLM/llm-d/KServe/SGLang 的共同方向是 KV cache 和路由层。我们应把 KV cache 从 runtime 内部细节上升为平台资源,做命中率、迁移量、跨节点传输和 SLA 指标。
- [openFuyao 官网](https://www.openfuyao.cn/zh/) 继续展示 NPU Operator、KAE Operator、节点特征发现、NPU 软切分和异构硬件资源池化。
  - 启示:面向国产/异构硬件,平台要抽象“设备发现、驱动安装、资源切分、健康上报、升级回滚”的统一 contract,而不是为每个硬件写一套孤立流程。

## AI 推理栈(InferNex / hermes-router / KVCache)

- OpenFuyao 推理路线强调 **KVCache-aware routing + 分布式缓存 + TTFT 优化**。
  - 与 OAI/KServe 相同:都在从“部署 runtime”走向“调度/路由/cache/autoscaling”的组合控制面。
  - 分叉点:OpenFuyao 更围绕昇腾/异构算力和全局显存瓶颈,OAI/KServe 更围绕 Kubernetes 原生 CRD、多 runtime 和企业 MLOps 工作流。
- 启示:我们可以优先借鉴 hermes-router 这类 KV-aware routing 思路,把它与 vLLM KV connector、SGLang PD staging、KServe llm-d scheduler 做同一张能力矩阵。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

- OpenFuyao 的资源管理叙事集中在 NPU Operator、节点特征发现、NPU 软切分、多样化算力池化。
  - 启示:这条线对应 NVIDIA GPU Operator 在昇腾生态里的位置。我们产品需要统一 accelerator operator 入口,让 GPU/NPU/其他加速器都能被安装、诊断、升级和审计。
- 对 DRA 的产品判断:OpenFuyao 的 npu-dra-plugin 方向与 Kubernetes DRA 大趋势一致,但当前公开周报层面更适合作为“跟踪项”。
  - 启示:我们的资源模型要预留 ResourceClaim/ClaimTemplate,为未来 GPU/NPU 统一资源声明做准备。

## 调度 & 集群(volcano-ext / NUMA / 混部)

- [openFuyao 官网](https://www.openfuyao.cn/zh/) 宣称容器编排引擎优化支持单机场景 1000+ Pod、NUMA 智能调度、在离线混部、超大规模集群调度。
  - 启示:这部分不是模型平台的 UI 能力,而是底层资源效率能力。我们要对标时应关注指标:节点利用率、NUMA 命中率、混部干扰、调度耗时、模型 TTFT/TPOT 的变化。

## 官方动态

- [openFuyao CSDN 官方博客](https://blog.csdn.net/openFuyao) 最近可见重点仍是 KubeCon Europe 2026 展示和管理面安装类内容。
  - 启示:OpenFuyao 的外部传播当前更偏生态展示和安装引导,技术深水区仍需要从 GitCode/Gitee 仓库和文档站持续跟踪。

## 跟我们产品的对比

- OpenFuyao 强项:昇腾/NPU、异构算力、KVCache-aware routing、NUMA/混部/超大规模集群底座。
- OAI/KServe 强项:Kubernetes 原生模型服务、MaaS、Llama Stack、Model Registry、Feature Store、MLflow、Kubeflow Trainer、Kueue/LWS 工作流闭环。
- 我们应补:KV cache/路由能力矩阵、统一 accelerator operator contract、底层资源效率指标到模型 SLA 的映射。
- 我们应谨慎:昇腾专用实现细节不宜直接产品化,除非客户场景明确要求。

## 值得跟进

- [ ] 跟踪 OpenFuyao v26.06 发布节奏,整理 InferNex/hermes-router/npu-operator/npu-dra-plugin 的版本关系。
- [ ] 做一张 KV-aware routing 对比表:OpenFuyao hermes-router、vLLM KV connector、SGLang PD staging、KServe llm-d scheduler。
- [ ] 设计 accelerator operator contract:安装、升级、健康、资源切分、监控、回滚。

## 原始材料

- [openFuyao 官网](https://www.openfuyao.cn/zh/)
- [openFuyao CSDN 官方博客](https://blog.csdn.net/openFuyao)
- [GitCode openFuyao 组织页](https://gitcode.com/openFuyao)
