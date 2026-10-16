# AI 推理 & MLOps 生态周报 2026-10-16

> 窗口:2026-10-09 ~ 2026-10-16。面向云原生 AI 基础设施产品(对标 OpenShift AI)。版本 bump / dependabot / CI 噪音已过滤,只保留对平台能力有参考或威胁的信号。

## 摘要(5 条以内)

1. **KServe 重心全面转向 `llmisvc` + P/D 分离分角色弹性**:DisaggregatedSet 各 role 现可用 KEDA 独立自动扩缩([#6383](https://github.com/kserve/kserve/pull/6383)),并开始服务 vLLM-Omni 多模态端点、整合 llm-d / GIE / LMCache。这是对标我们 LLM serving 最直接的能力参照。
2. **"Anthropic `/v1/messages` 原生透传"本周在 KServe/Ray/KubeAI/llama-stack 四处同时出现**,正成为推理网关的事实标配——网关层 API 兼容面需把 Anthropic Messages 纳入一等公民。
3. **三大推理引擎(vLLM/SGLang/TRT-LLM)共同主线仍是 P/D 分离 + KV 分层/传输**(NIXL、Mooncake、HiCache、KV lending API)与**路由负载信号外暴露**;TRT-LLM 发 [v1.4.0rc0](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc0),含稀疏 KV cache 与 Runtime Sleep/Wakeup(空闲释显存)。
4. **Kubeflow Trainer v2 坐实 DRA + Workload Aware Scheduling 两条上游标准**([#4027](https://github.com/kubeflow/trainer/pull/4027)、[#3219](https://github.com/kubeflow/trainer/pull/3219)),指向摆脱 device-plugin 整数计数模型的下一代异构加速器调度。
5. **MLflow [v3.17.0](https://github.com/mlflow/mlflow/releases/tag/v3.17.0) 把子资源级 RBAC + 评估血缘做进来**,模型生命周期治理从"注册"转向"GenAI 评估/tracing 的企业化"。

## 推理引擎动态

### vLLM
本周无正式 release,持续 main 迭代,主线在分布式服务化与 KV 分层:
- 弹性 EP 扩缩新增 **External LB Mode**(外部负载均衡器驱动专家并行弹性扩缩),直接关系多副本自动扩缩编排。[commit](https://github.com/vllm-project/vllm/commit/dd9e07a25febb05f1a44f2ef9e6c56803ee1a9b6)
- KV Offload:暴露 OffloadingManager lock/unlock,把 KV 分层控制面从 scheduler 线程剥离;新增 PROMOTION_LATENCY 直方图。[commit](https://github.com/vllm-project/vllm/commit/c5f8adc0b1944b9142a31d85cfbc6a61973d0b3a)
- NIXL KV Connector 将 MLA KV 注册为单一 region;Mooncake 每 peer 只发一次 KV layout。[commit](https://github.com/vllm-project/vllm/commit/7020600b1db32f239611b037f07e0dc5268e5b4f)
- 清理遗留 executor 残留的 Ray driver-node GPU pin,减少无谓占卡。[commit](https://github.com/vllm-project/vllm/commit/4a89316efaf329d690ae6c5e2d7fd9cb078be44c)
- 热门 RFC(建议跟读):[Q4 2026 路线图](https://github.com/vllm-project/vllm/issues/61024)、[BYOG 可复现评测](https://github.com/vllm-project/vllm/issues/61698)、[CPU 性能仿真 CI](https://github.com/vllm-project/vllm/issues/61406)(无卡做性能回归,对降低多硬件 CI 成本有直接借鉴)。

### SGLang
本周无正式 release,重点在 sgl-router(与我们网关层最相关)与 HiCache 分层:
- sgl-router 提供原生 [gRPC ChatComplete 服务](https://github.com/sgl-project/sglang/commit/a2981ab8ea603990ab379a73d671d48a02e4c32c);新增 [`--dp-rank-policy round_robin`](https://github.com/sgl-project/sglang/commit/08f15e76bb466cfc6dfaa80bff439f4bf1940ca5) DP 感知路由。
- rust-server 应用 x-override-* 请求头 + 健康检查带元数据头(多租户/网关透传);/metrics 暴露 scheduler 指标。[commit](https://github.com/sgl-project/sglang/commit/0b1a73599a23aa2d9a6ff5487c32ea1f31c85748)
- HiCache 新增 page_unified host KV layout + 统一 L3 key;docker 新增 AWS EFA 变体(云上多机 RDMA)。[commit](https://github.com/sgl-project/sglang/commit/9ea5472833296e97724f12df716936576d34ddbb)
- 初步接入 T-HEAD SAIL 平台(国产/新硬件后端纳管方向)。[PR #43826](https://github.com/sgl-project/sglang/pull/43826)

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM [v1.4.0rc0](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc0)(2026-10-14)**:新增**稀疏 KV cache** + tier-aware locking + 卸载(为 DeepSeek V4 准备);**Mooncake store pool + V2 scheduler 抢占**;OpenAI server 加按模型的 serving-extension 注册表;**Runtime Sleep/Wakeup 通用化**(空闲释显存,利于多租户共卡,[commit](https://github.com/NVIDIA/TensorRT-LLM/commit/8d09d171348330aebc7e50c83120863b71d1d011));新增跨实例 [KV cache lending API](https://github.com/NVIDIA/TensorRT-LLM/commit/5f2e6cdc8b6e53ca3de57e3d9047af9afe1c961b)。**破坏性变更**:移除 KVCacheManagerV2 Python 后端;rc 版本已知问题多(多 GPU 流式 hang 等),勿上生产。
- **TGI**:已 archived(last push 2026-03-21),窗口内 0 提交,属正常停止维护。生态已转向 vLLM/SGLang/TRT-LLM,建议产品层面不再把 TGI 作为可选后端。
- **Ollama**([v0.40.5](https://github.com/ollama/ollama/releases/tag/v0.40.5)/[v0.40.4](https://github.com/ollama/ollama/releases/tag/v0.40.4)):主线是本地+云 passthrough 的开发者体验与 **Decision 模型**(判别式 yes/no/分类/打分小模型,`ollama run --ask`)。与企业级多租户不是一个战场,但 Decision 模型品类可留意作为 LLM 网关前置的轻量路由/审计决策层。

## 模型服务 & 编排

### KServe 上游
无窗口内 release(v0.21.0 于 2026-09-25),但 commit 极活跃,聚焦 `llmisvc`:
- **DisaggregatedSet(P/D 分离)各 role 用 KEDA 独立自动扩缩**([#6383](https://github.com/kserve/kserve/pull/6383));配套修复 0 副本 scale-up 卡死([#6390](https://github.com/kserve/kserve/pull/6390))、maxSurge:0 滚动卡死([#6378](https://github.com/kserve/kserve/pull/6378));弃用 WVA 向 KEDA 收敛([#6263](https://github.com/kserve/kserve/pull/6263))。
- llmisvc 开始服务 **vLLM-Omni 的 TTS/TTI 多模态端点**([#6285](https://github.com/kserve/kserve/pull/6285))。
- 上游整合:llm-d-router v0.11.0([#6258](https://github.com/kserve/kserve/pull/6258))、Gateway API Inference Extension v1.6.2([#6348](https://github.com/kserve/kserve/pull/6348))、LMCache 0.5.5([#6381](https://github.com/kserve/kserve/pull/6381))。
- 企业能力:**机密模型解密不再全量载入内存**([#6219](https://github.com/kserve/kserve/pull/6219));LocalModelCache 的 OCI 导入支持 imagePullSecrets(私有 registry,[#6213](https://github.com/kserve/kserve/pull/6213));按 ISVC 粒度配置 logger agent worker([#6372](https://github.com/kserve/kserve/pull/6372));KernelCache E2E 测试线落地(加速冷启动,[#6401](https://github.com/kserve/kserve/pull/6401))。

### Ray
无窗口内 release(ray-2.59.0 于 2026-10-02),serve/llm 实质变更:
- KVAwareRouter 支持 **Anthropic `/v1/messages`**([#66827](https://github.com/ray-project/ray/pull/66827))。
- Serve 原地更新引入 `max_surge_percent`,支持 start-before-stop 滚动(零停机,[#66267](https://github.com/ray-project/ray/pull/66267));HAProxy ingress 改走 request router 统一路由层([#66592](https://github.com/ray-project/ray/pull/66592))。
- vLLM 引擎推导的 per-worker GPU 配置下发到副本 actor(GPU 调度细化,[#63881](https://github.com/ray-project/ray/pull/63881))。

### KubeAI(原 substratusai/lingo,已复活)
**此前记录的"2026-07-31 后沉寂"已过期**——本周明显复活:
- **[v0.24.0](https://github.com/kubeai-project/kubeai/releases/tag/v0.24.0)**(2026-10-07)。
- **API 面重构 [#753](https://github.com/kubeai-project/kubeai/pull/753)**:新增 `POST /v1/messages`(Anthropic Messages 原生透传到 vLLM 等,复用 model lookup / scale-from-zero / LB / 重试);rerank、systemone 迁到独立路径,旧 `/openai/v1/*` 保留并打 Deprecation 头。定位仍是轻量 OpenAI/Anthropic 兼容网关 + scale-from-zero,与 KServe 重型 llmisvc 形成差异点。

## 训练 & 微调

### Kubeflow Trainer v2(原 training-operator)
无窗口内 release(v2.3.0 于 2026-08-07),但合入两个架构级调度能力:
- **KEP-2782:TrainJob 支持 DRA(Dynamic Resource Allocation)**([#4027](https://github.com/kubeflow/trainer/pull/4027))——用结构化参数申请 GPU/加速器,替代 device-plugin 整数计数模型。企业级异构调度主线,若对标 OAI 应评估是否跟进。
- **KEP-3015:Workload Aware Scheduling**([#3219](https://github.com/kubeflow/trainer/pull/3219))——向调度器暴露整体工作负载语义,是 gang/拓扑感知调度的上游基础。
- 可观测性成体系:Prometheus monitoring overlay([#4102](https://github.com/kubeflow/trainer/pull/4102))、serviceMonitor→prometheus 对齐 JobSet。
- 与排队系统协同待打磨:reconciler 覆盖外部 JobSet suspend([#4212](https://github.com/kubeflow/trainer/issues/4212),影响 Kueue 协同);删除 TrainingRuntime 致 TrainJob 卡 Terminating([#4203](https://github.com/kubeflow/trainer/issues/4203))。

### LLaMA-Factory
无重大更新。窗口内 main 仅合入 1 个文档提交(NPU Docker 安全说明,[#10883](https://github.com/hiyouga/LlamaFactory/pull/10883))。特性工作均在未合入的开放 PR 中,无云原生基础设施相关架构变化。

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
- **[v3.17.0](https://github.com/mlflow/mlflow/releases/tag/v3.17.0)** + 补丁 [v3.17.1](https://github.com/mlflow/mlflow/releases/tag/v3.17.1):
  - **子资源级 RBAC**:对 runs/traces/versions 等做细粒度访问控制,支持通配符授权与显式 DENY(多租户治理直接相关)。
  - 大 trace 分析加速(每日 rollup),但**需协调式 schema 升级**(停写 + `mlflow db upgrade`,不支持混版滚动升级)——运维硬约束。
  - AI Gateway 可由 `MLFLOW_ENABLE_AI_GATEWAY` 关闭;OTLP ingestion 指标暴露给 Prometheus。
- 本周新进 main:引入 **Skill Registry**([#26736](https://github.com/mlflow/mlflow/commit/fb519dbbc82746675ff8ab9c2b5386c17a73fe46));实验性 **docker job executor**(容器化隔离跑自定义 scorer,[#26430](https://github.com/mlflow/mlflow/commit/36a1db06116fdd988739154cf99b069664975791));记录**评估血缘**(dataset/scorer/agent lineage,[#26543](https://github.com/mlflow/mlflow/commit/6485ea856b1debd19be6d8c72f30e1177dc1a6a0));Assistant 多租户加固。启示:主线是 GenAI 评估/tracing 的企业化,而非传统模型注册。

### Kubeflow Model Registry(已并入 kubeflow/hub)
无实质功能更新,几乎全是 dependabot 噪音。catalog 化仅收尾:Model Catalog 响应统一包进 `data` 信封([#3351](https://github.com/kubeflow/hub/commit/09fc03499c281cfd05ed625aeb83b2152b71b9d6))、filterQuery 引号修复([#3329](https://github.com/kubeflow/hub/commit/a44782a6470c654f0957399d6913d9390de30000))。本周无新的 HuggingFace gated/private 接入进展。

### Feast
- **[v0.67.0](https://github.com/feast-dev/feast/releases/tag/v0.67.0)**(2026-10-13):大量 bug fix + 安全修复(注册表写入先鉴权、REST permission API 拒绝未知资源、UI CORS 限制可信来源)。
- 接入现代 lakehouse/向量生态:**Apache Polaris**(Iceberg REST catalog,[#7006](https://github.com/feast-dev/feast/commit/386759c1787b1a16a2e1ad7783db00e709cf4b26))、**Trino 计算引擎**([#6898](https://github.com/feast-dev/feast/commit/11a47b42d66e82f31f3a46d73340bae797d39548))、**Lance 数据源**(面向 ML/向量的列式格式,[#6945](https://github.com/feast-dev/feast/commit/f754323687f7054f6f27f280a54610905828b842));Operator 加 dualStack server([#6887](https://github.com/feast-dev/feast/commit/725a1470ea7e464a0188d21e249d89ff6fc665aa))。Lance/向量方向与 RAG 特征服务相关。

## LLM 评估 & 安全

### lm-evaluation-harness
无重大更新(最新 v0.4.13 于 8/31,窗口内 0 commit)。[repo](https://github.com/EleutherAI/lm-evaluation-harness)

### garak(LLM 红队)
无窗口内 release,但一批 detector/probe 修复直接影响红队评测准确性:多轮越狱重复计数误报修正([#2111](https://github.com/NVIDIA/garak/pull/2111))、FileDetector 漏报修正([#2080](https://github.com/NVIDIA/garak/pull/2080))、拒答检测判定收紧([#2067](https://github.com/NVIDIA/garak/pull/2067));Python 3.14 支持([#2297](https://github.com/NVIDIA/garak/pull/2297))。热点 issue 揭示多语言盲区([#2307](https://github.com/NVIDIA/garak/issues/2307))。启示:"红队评分可信度"是 guardrail 评测产品的核心风险点,集成安全扫描需关注检测器版本与多语言一致性。

### llama-stack(内部已改名 ogx-ai/ogx)
- **[v1.5.0](https://github.com/meta-llama/llama-stack/releases/tag/v1.5.0)**(2026-10-09):
  - **Breaking**:`apis:` 显式列表现为权威配置(即使为空),升级需审查 API 启用清单([#6562](https://github.com/ogx-ai/ogx/pull/6562))。
  - 多 provider 统一推理面:新增 Text-Embeddings-Inference provider;DeepSeek/Fireworks 加原生 `/v1/messages` 直通;支持 **MCP 2.x 客户端 SDK**。
  - 企业级存储:PostgreSQL 连接 URI 支持;S3 对象可存于可选 key 前缀下(多租户存储隔离);上传流式写 S3 而非内存缓冲([#6765](https://github.com/ogx-ai/ogx/pull/6765))。启示:主线与 OAI 的 model serving + 工具编排高度重叠,MCP 2.x 与 S3 流式上传可直接对标。

## 值得跟进

- [ ] **把 Anthropic `/v1/messages` 纳入网关一等公民**:本周 KServe/Ray/KubeAI/llama-stack 同步支持,已是事实标配,我们网关层 API 兼容面需补齐。
- [ ] **评估 DRA(Dynamic Resource Allocation)跟进路线**:Kubeflow Trainer v2 已坐实 DRA + Workload Aware Scheduling,这是摆脱 device-plugin 整数计数的下一代异构调度方向,直接对标企业级 GPU 调度。
- [ ] **对标 KServe `llmisvc` 的 P/D 分离分角色 KEDA 弹性 + 机密模型 + OCI 模型缓存**:这是本周离我们产品最近的能力缺口参照。
- [ ] **跟踪三引擎的 KV event / routing load 外暴露接口**(NIXL/Mooncake/HiCache/KV lending):云原生推理平台调度层要对接的接口,建议网关/调度器设计对齐。
- [ ] **借鉴 vLLM 的 CPU 性能仿真 CI 与 BYOG 可复现评测 RFC**:对降低多硬件 CI 成本有直接价值。
