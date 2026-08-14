# AI 推理 & MLOps 生态周报 2026-08-14

> 窗口:2026-08-07 ~ 2026-08-14。只筛对"做云原生 AI 基础设施产品"有借鉴/威胁的变化;版本 bump、CVE 依赖升、CI 噪音已跳过。

## 摘要(5 条以内)

1. **HuggingFace TGI 已归档**(archived,最后 push 2026-03-21)——自研推理引擎赛道进一步收敛到 vLLM / SGLang / TensorRT-LLM 三强,产品选型不必再把 TGI 列为上游。https://github.com/huggingface/text-generation-inference
2. **KServe `LLMInferenceService`(llmisvc)本周高速迭代**:KEDA 真·缩容到 0(idleReplicaCount=0)、加权 InferencePool、rolloutStrategy 滚动更新、OCI 镜像拉模型——上游正把"LLM 专用 serving"能力补齐,和我们产品是正面对标点。https://github.com/kserve/kserve/pull/5996
3. **vLLM v0.27.0**:Model Runner V2 扩到 embedding/分类/pooling 等非生成负载,DP+EP 大规模部署引入(简化版)容错框架,Rust 前端长出 gRPC 控制面——vLLM 从"推理内核"向"可运维的服务平台"进化。https://github.com/vllm-project/vllm/releases/tag/v0.27.0
4. **Ray 2.57.0**:Ray Serve LLM 实验性 KV-cache 感知路由;Ray Core 内置 RocksDB 后端做 GCS 容错,**不再强依赖外部 Redis**——降低 Ray 生产部署的运维门槛。https://github.com/ray-project/ray/releases/tag/ray-2.57.0
5. **Kubeflow Trainer v2.3.0** 引入 `OptimizationJob` CRD(KEP-3562,超参/优化作业)+ runtime snapshot(KEP-2599),并带 **breaking change**(CRD 挪进 Helm chart、移除 Runtime Finalizers);从 v2.0/2.1/2.2 升级必须先过 v2.3。https://github.com/kubeflow/trainer/releases/tag/v2.3.0

## 推理引擎动态

### vLLM(v0.27.0,2026-08-10)
面向平台化的几条对我们最有价值:
- **Model Runner V2 覆盖非生成负载**:encoder-only attention、embedding/分类 sequence pooling、BGE-M3 pooling、CPU 上跑多模态——同一个 runtime 同时服务生成 + 向量/重排,利好"一套推理平台多种任务"的产品叙事。
- **大规模服务容错**:为 DP+EP 外部负载均衡部署引入(简化版)fault tolerance 框架 + 弹性 EP 扩缩容异步准备;P/D 分离支持 hybrid MLA+SSM 模型、异构 block size。
- **KV 分层 offload 体系化**:通用 P2P 二级缓存、按请求 tier 过滤、可插拔淘汰策略、文件系统 offload——对做"KV 缓存复用/分级存储"的平台能力有直接参考。
- **Rust 前端 gRPC 控制面**:健康上报、abort、server/model 发现、KV event 源发现,`vllm-bench` 并入 `vllm` CLI。
- 环境破坏性升级:PyTorch 2.13 / Triton 3.7.1;新硬件 sm_107(Rubin)、ROCm gfx1250。v0.27.1 为紧随的修复版。
- 对我们的启示:vLLM 正在把"多机容错、弹性 EP、KV 分层"这些原本要平台层自己补的能力内建进引擎,产品差异化要往调度/多租户/生命周期上走,而非重复造推理内核。

### SGLang(v0.5.17,2026-08-08)
- **Rust 前端初步落地**(网络入口→分词的前半段从 Python 迁到多线程 Rust,#29799),和 vLLM 的 Rust 化同步——推理引擎前端普遍在去 Python 化降开销。
- **Session-reference-aware Unified Radix Cache**(`--enable-session-radix-cache`,#29173):请求带 `session_id`,淘汰时知道哪些前缀被活跃会话引用——**专为 agentic / RL rollout 场景**做的 KV 缓存治理,值得关注。
- **引擎快速恢复**:weight-cache 守护进程按 GPU 缓存权重,大模型重启从 3-6 分钟级降下来(#27139)——对"故障快恢复 / 弹性调度"是好卖点。
- Kimi K3(2.8T MoE)/ MiniMax-H3 day-0;DWDP MoE prefill 并行策略(4×B200 gpt-oss-120b 相比 DEP4 1.92x)。https://github.com/sgl-project/sglang/releases/tag/v0.5.17

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc24**(2026-08-12):Kimi K3 + KDA、Whisper/MiniCPM-V 进 PyTorch backend、OpenAI API **per-request priority**、`generation_config="auto"`。注意 release note 里"Known Issues"很长(torch.compile+CUDA graph、KVCacheManagerV2 teardown 等),仍是 rc,生产采用需谨慎。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc24
- **TGI:已归档,无重大更新**。HuggingFace 停止自维护 TGI,推理栈重心转向 vLLM 等上游。选型/竞品分析里可将其从"活跃上游"移除。https://github.com/huggingface/text-generation-inference
- **Ollama**(v0.32.7→v0.32.11,一周 5 版):Meta MSL 的 Muse Glimmer(30B 多模态 agent 模型)全平台支持、Nemotron 3.5 架构、**DeepSeek Harness / Muse Code 集成**——边缘/桌面侧持续绑定新开源模型与 agent harness。https://github.com/ollama/ollama/releases/tag/v0.32.11

## 模型服务 & 编排

### KServe 上游(无 release,但本周 commit 密集,重点看)
`llmisvc`(LLMInferenceService)是本周最值得盯的方向,几乎全部围绕"LLM 专用 serving"补能力:
- **KEDA 真·缩容到 0**:`idleReplicaCount=0` 允许 KEDA scale-to-zero(#5996)。
- **加权 InferencePool** e2e(#5886)——对齐 Gateway API Inference Extension 的流量切分。
- **rolloutStrategy**:控制 llmisvc 滚动更新行为(#5916);渲染出的 config 模板做校验(#5918)。
- **OCI 镜像拉模型**:`oci+fetch://` KServe 侧 OCI image pull(Step 3, #5739)——模型分发走 OCI registry 的路线在推进。
- InferenceService 侧:canary 流量按 readiness 门控避免瞬时 503(#5984);agent AWS SDK v1→v2(#5438)。
- 对我们的启示:上游把"缩容到 0 + InferencePool 流量治理 + OCI 模型分发 + 滚动策略"作为 LLM serving 标配在补,这几项应逐条对照我们产品的能力矩阵。https://github.com/kserve/kserve/pull/5886

### Ray(2.57.0,2026-08-11)
- **Ray Serve LLM:实验性 KV-cache 感知请求路由**(先分词、按 prefill/decode token 负载路由,追踪副本 KV 状态;完整支持 2.58),对标 vLLM/SGLang 的前缀感知路由。
- **Ray Core:内置 RocksDB GCS 容错后端**(`RAY_gcs_storage=rocksdb`),GCS 容错**不再需要外部 Redis**——生产部署少一个依赖,是运维正向信号;另加拓扑感知调度公共 API。
- **Ray Serve HAProxy ingress 拆成 `ray-haproxy` PyPI 包**并支持 gRPC(流式/metrics/自定义 request id)。
- Ray Data:DataSourceV2 默认开启、任务化 Hash Shuffle V2(去掉 aggregator actor 池,中间态可 spill)。https://github.com/ray-project/ray/releases/tag/ray-2.57.0

### KubeAI(原 substratusai/lingo)
无重大更新(仓库最后 push 2026-07-31,窗口内无提交)。https://github.com/kubeai-project/kubeai

## 训练 & 微调

- **Kubeflow Trainer v2.3.0**(2026-08-07):
  - 新 `OptimizationJob` CRD(KEP-3562)——把超参优化/优化作业纳入 Trainer;runtime snapshot 机制(KEP-2599)解耦 runtime 生命周期与 TrainJob;MPI launcher 依赖 worker readiness;Flux 集成。
  - **Breaking**:移除 Runtime Finalizers、CRD 移入 Helm chart template——**从 v2.0/2.1/2.2 升级必须先升到 v2.3 再往后**,有迁移指南。做训练平台集成的要留意升级路径。https://github.com/kubeflow/trainer/releases/tag/v2.3.0
- **LLaMA-Factory**(hiyouga,活跃):`[v1] FSDPTurbo EP/EFSDP` MoE 训练插件、KTransformers MoE LoRA SFT 加固、FA3 支持、NPU 镜像升到 CANN 9.1 + PyTorch 2.10。国内社区在补 MoE 训练 + 昇腾栈。https://github.com/hiyouga/LLaMA-Factory/pull/10676

## 模型生命周期(MLflow / Registry / Feast)

- **Kubeflow model-registry → AI Hub 化**:本周提交集中在 **catalog**——git-backed skill catalog 同步(SKC-105/106/107)、MCP server 详情页 + logo endpoint、agent catalog 加载日志。Registry 正从"模型登记"扩成"模型 + Agent + MCP + Skill 目录"。做模型生命周期/agent 治理的产品要跟这条线。https://github.com/kubeflow/model-registry/pull/3055
- **MLflow**(活跃,无 release):TS SDK 加 SpanLink、`MLFLOW_TRACKING_AUTH=kubernetes` 命名空间鉴权支持;OpenInference prompt-cache token 计数映射;防对象存储 artifact 删除误删同级路径(#25024)。tracing / 评估数据集打通继续加强。https://github.com/mlflow/mlflow/pull/24243
- **Feast**:通过 operator 暴露 OIDC JWKS 可调参数(#6690)、SQL registry 加 `schema_mode` 与 registry create 命令(#6704)、修 apply 静默忽略 ttl 更新——企业级鉴权 + 注册中心 schema 管理在补。https://github.com/feast-dev/feast/pull/6690

## LLM 评估 & 安全

- **lm-evaluation-harness**:本周几乎全是 **datasets>=4 兼容修复**——大量任务从"已移除的 dataset 脚本"迁到 parquet/命名空间路径(SCROLLS、arithmetic、PROST、MMLU-SR、mathqa 等)。如果你的评测流水线 pin 了老 datasets,升级要留意这批数据加载变更。https://github.com/EleutherAI/lm-evaluation-harness/pull/3976
- **garak**(NVIDIA):新增 Ollama auth + 自定义 client kwargs、向 Ollama 转发生成参数(#2025、#1993);修 MarkdownExfilContent detector 与若干不可达分支。红队工具在补本地/Ollama 后端的接入。https://github.com/NVIDIA/garak/pull/2025
- **llama-stack(已改名 ogx-ai/ogx,v1.3.0,2026-08-07)**:大量新增远程 inference provider(Meta AI、Mistral、DeepSeek)、Neo4j vector provider;**多租户能力**博客;启动时未配置鉴权会告警;把不可信的 web_search/file_search 工具输出做定界再回喂模型(#6337,防注入)。安全 + 多租户是其本版主线。https://github.com/meta-llama/llama-stack/releases/tag/v1.3.0

## 值得跟进

- [ ] **KServe llmisvc 能力矩阵对标**:KEDA scale-to-zero、加权 InferencePool、rolloutStrategy、OCI 模型拉取——逐条比对我们产品,补差距或明确差异化。
- [ ] **OCI registry 分发模型**成上游共识(KServe `oci+fetch://`):评估我们模型分发是否切/兼容 OCI 路线。
- [ ] **Ray GCS 去 Redis 依赖(RocksDB)**:若产品内嵌 Ray,可简化部署拓扑,验证 `RAY_gcs_storage=rocksdb` 稳定性。
- [ ] **Kubeflow Trainer v2.3 breaking 升级链**:集成方需规划 v2.2→v2.3→更高版本的迁移顺序。
- [ ] **model-registry 的 Agent/MCP/Skill catalog 化**:若我们要做 agent/工具治理,这是可对齐或差异化的上游锚点。
- [ ] **TGI 归档**:更新竞品/上游清单,推理引擎收敛为 vLLM / SGLang / TensorRT-LLM。
- [ ] **KV 缓存治理成引擎标配**(vLLM 分层 offload、SGLang session-radix、Ray KV-aware 路由):平台层不必自造,聚焦调度与多租户隔离。
