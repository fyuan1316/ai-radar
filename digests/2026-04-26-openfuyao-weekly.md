# OpenFuyao 周报 2026-04-26

窗口:2026-04-19 → 2026-04-26(过去 7 天)

抓取说明:GitCode 组织页可打开但未返回可解析 repo 列表;本机网络无法 `git clone --depth 1` 验证 GitCode 仓库提交。官网和 CSDN 官方博客可访问。按本 task 空周规则,若无新功能/官方动态,本周只归档,不推飞书。

## 摘要

- 本周未发现 OpenFuyao 官方新公告、新版本或高置信 repo release。官网首页仍强调 AI 推理套件、分布式 KVCache、智能路由、NPU Operator、NUMA 亲和、超大规模集群调度等能力: [openFuyao 官网](https://www.openfuyao.cn/zh/)。
- CSDN 官方博客最近可见文章停留在 2026-03-28 的 KubeCon Europe 2026 / 管理面安装,未见 2026-04-19 → 2026-04-26 新文章: [openFuyao CSDN](https://blog.csdn.net/openFuyao)。
- 因“新功能 / 能力”和“官方动态”均无本周新增内容,本周按规则跳过飞书推送。

## 新功能 / 能力

本周无可确认新增。

背景材料:
- [openFuyao 官网](https://www.openfuyao.cn/zh/) 仍把 AI 推理场景加速作为核心货架能力,描述包括分布式 KVCache、智能路由与缓存命中策略优化、降低 TTFT、突破 N/S 和 E/W 全局显存瓶颈。
  - 启示:OpenFuyao 的推理路线与 vLLM/llm-d/KServe 的“KV cache + routing + PD disaggregation”方向同频,但更强调昇腾/异构硬件与全局显存瓶颈。我们可借鉴的是 KV-aware routing 思路,不是特定 NPU 实现。
- [openFuyao 官网](https://www.openfuyao.cn/zh/) 继续展示 NPU Operator、KAE Operator、节点特征发现、NPU 软切分、异构硬件资源池化。
  - 启示:这部分主要是昇腾/鲲鹏生态专用能力。我们如果做通用平台,应抽象成“accelerator operator 插槽 + device discovery + resource slicing”,避免绑定单一硬件术语。

## AI 推理栈(InferNex / hermes-router / ...)

本周未能通过 GitCode clone/commit log 验证 InferNex、hermes-router、Elastic Scaler、Eagle Eye 的新增变更。

可确认背景:
- [openFuyao 官网](https://www.openfuyao.cn/zh/) 明确写出 AI 推理场景加速支持分布式 KVCache、智能路由与缓存命中策略优化。
- [CSDN 官方博客 2026-03-28 KubeCon Europe 文章列表项](https://blog.csdn.net/openFuyao) 显示 InferNex 曾作为 KubeCon Europe 2026 展示主题。

对标:
- 与 KServe/llm-d/vLLM 相同:都在围绕 KV cache、路由、PD 分离、TTFT 优化。
- 分叉点:OpenFuyao 更强调异构算力集群和昇腾生态,而 KServe/llm-d 更强调 Kubernetes 原生 CRD 和多厂商 runtime。

## 昇腾资源管理(NPU Operator / MindCluster / DRA)

本周无可确认新增。

可确认背景:
- [openFuyao 官网](https://www.openfuyao.cn/zh/) 把 NPU Operator、KAE Operator、节点特征发现、NPU 软切分列为多样化算力使能能力。

启示:
- NPU Operator 的产品价值在“驱动/固件/device plugin/资源切分/监控”的闭环,这与 NVIDIA GPU Operator 的产品形态相似。我们要做多硬件支持时,应形成统一 accelerator operator contract,把安装、升级、健康检查、资源上报做成同一种用户体验。

## 调度 & 集群(volcano-ext / 超大规模 / 在离线混部)

本周无可确认新增。

可确认背景:
- [openFuyao 官网](https://www.openfuyao.cn/zh/) 宣称容器编排引擎优化可支持单机场景 1000+ Pod,NUMA 智能调度在金融支付场景应用性能提升 20%,在离线混部提升 CPU/内存利用率,超大规模集群调度支持 1 万节点以上。

启示:
- 这些能力偏集群底座,与 OAI/KServe 的模型平台不是同一层。对我们产品最有借鉴意义的是“AI workload 与底层调度优化联动”的指标表达方式:不要只展示模型 QPS,也要展示节点利用率、NUMA 命中、混部干扰、调度耗时。

## 官方动态

本周无可确认新增。

可见来源:
- [openFuyao CSDN 博客](https://blog.csdn.net/openFuyao) 最近可见文章为 2026-03-28 的 KubeCon Europe 2026 和管理面安装文章。
- [openFuyao 官网](https://www.openfuyao.cn/zh/) 首页“活动/新闻”区域当前显示暂无内容。

## 跟我们产品的对比

- OpenFuyao 强项:异构算力、昇腾/NPU、KVCache-aware routing、超大规模/NUMA/混部等底座优化。
- OAI/KServe 强项:Kubernetes 原生模型服务、MaaS、Llama Stack、Model Registry、Feature Store、MLflow、Kubeflow Trainer、Kueue/LWS 等 MLOps 工作流闭环。
- 我们应优先借鉴:KV-aware routing 指标体系、accelerator operator contract、底层资源调度与上层模型 SLA 的映射。
- 暂不应直接跟随:只对昇腾 NPU 有意义的实现细节,例如特定驱动/固件/UB 网络配置。

## 值得跟进

- [ ] 下次在有网络的环境里 `git clone --depth 100 https://gitcode.com/openFuyao/InferNex.git` 和 hermes-router/npu-operator/npu-dra-plugin,补提交级扫描。
- [ ] 找到 OpenFuyao v26.03 / v26.06 release notes 的稳定 URL,建立版本节奏表。
- [ ] 对比 OpenFuyao KVCache 智能路由、vLLM KV connector、SGLang PD staging、llm-d scheduler,整理共性能力。

## 原始材料

- [openFuyao 官网](https://www.openfuyao.cn/zh/)
- [openFuyao CSDN 官方博客](https://blog.csdn.net/openFuyao)
- [GitCode openFuyao 组织页](https://gitcode.com/openFuyao)
- 未完成:GitCode clone/commit log 扫描失败,本周未能验证 repo 级变更。
