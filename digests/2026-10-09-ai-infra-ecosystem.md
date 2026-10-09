# AI 推理 & MLOps 生态周报 2026-10-09

> 窗口:2026-10-02 ~ 2026-10-09。只记对"做云原生 AI 基础设施产品"有借鉴/威胁的变化,版本 bump、CI、dependabot 噪音已过滤。

## 摘要(5 条以内)

1. **KServe 把 P/D 分离服务收敛成单对象**:新增 `DisaggregatedSet` 后端(基于 LeaderWorkerSet),把 prefill/decode 两个工作负载当成一个对象同步滚动,并设为 P/D 服务默认——解决两角色独立滚动导致的容量比漂移。对标我们自家的分离式推理编排,这是必须跟的架构动作。https://github.com/kserve/kserve/pull/6330
2. **Ray Serve LLM / Ray Data LLM 正式 GA/Stable**(ray-2.59.0),且 Serve 本地集群默认开启 token 认证、dashboard 对 runtime_env 做凭据脱敏——Ray 在"企业级推理服务层"的成熟度和安全姿态明显上台阶。https://github.com/ray-project/ray/releases/tag/ray-2.59.0
3. **vLLM v0.31.0 落地"快速重启"栈**:新 `vllm preload` 权重缓存守护进程让后量化权重跨引擎重启常驻 GPU 显存,外加实验性 CRIU 引擎快照(`vllm snapshot`)——对我们做模型热更新/故障自愈的停机时间是直接利好。https://github.com/vllm-project/vllm/releases/tag/v0.31.0
4. **Feast 把 MCP server 升级为一等组件**,并新增 Chronon 在线/离线存储集成、Lance 非 JVM 读写路径——Feature Store 正在往"给 Agent/LLM 当上下文源"方向长。https://github.com/feast-dev/feast/pull/6855
5. **安全合规多点推进**:KServe KernelCache 默认要求验证过的 artifact 才复用缓存 + 证书 artifact 安全默认开 + 修 SSRF 存储校验;MLflow 3.17 给共享资源做细粒度 RBAC(runs/traces/versions 级 + 通配授权 + 显式 DENY)。企业级多租户方向都在补课。https://github.com/kserve/kserve/pull/6323

## 推理引擎动态

### vLLM
v0.31.0(10-05,717 commits/307 贡献者)对我们有用的几条:
- **快速重启栈**:`vllm preload` 权重缓存守护进程跨重启常驻后量化权重(#56680,含 DP/MTP/`/health`/就绪等待);实验性 `vllm snapshot create/restore` 用 CRIU 恢复已初始化的 TP1 引擎(#51360)。模型滚更/崩溃恢复的冷启动时间可大幅压缩。
- **调度控制**:`--max-num-active-seqs` 独立于 `max_num_seqs` 限制 RUNNING 准入(#56758);等待队列重排,已持有 KV block 的请求优先调度(#58947);修 KV connector + MTP 在 KV 压力下的死锁(#57104)。
- **安全**:逐请求 `mm_processor_kwargs`/`media_io_kwargs` 默认拒绝,需 `--trust-request-mm-kwargs` 才放行(#58830);prefix-cache key 按来源打标签,LoRA 名与 `cache_salt` 不再冲突、LoRA 路径纳入 block hash(#51899/#59335)。多租户共享 KV 缓存的隔离更严。
- **破坏性变更**(升级要看):逐请求多模态 kwargs 默认门控、`tokenizer_mode="slow"` 移除、在线量化 `quantization="fp8"` 改 `fp8_per_tensor`、`--enforce-eager` 现在也禁 JIT warmup。
来源:https://github.com/vllm-project/vllm/releases/tag/v0.31.0

### SGLang
v0.5.21(10-02,779 PR/227 贡献者),三个产品向信号:
- **PD 实例可在线切换 prefill/decode 角色,无需重启**(#28403)——和上面 KServe DisaggregatedSet 是同一问题的两端解法,运维弹性方向。
- **前缀缓存默认走 Rust 核**(#39627),吞吐/延迟基线抬高。
- **新 Decisions API `/v1/decisions`**(把 LLM/VLM 当低延迟分类器/打分器)+ **Score API `/v1/score`**(一次请求打分所有候选)。推理服务不止"生成",正在标准化"判别/排序"端点,值得在我们网关层预留。
来源:https://github.com/sgl-project/sglang/releases/tag/v0.5.21

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:本周仅 rc 迭代(最新 v1.3.0rc29,09-29,窗口外),无 GA,无重大增量。
- **TGI**(huggingface/text-generation-inference):已 archived(最后 push 2026-03-21),窗口内恒 0 提交,属正常停维护,不再跟踪。
- **Ollama**:v0.40.x(10-07~10-08)。亮点是 Apple Silicon 上默认用 MLX 运行时跑受支持架构(含 gemma4/qwen3.x、嵌入模型、decision 模型)。主要是桌面/边缘侧,对我们服务端编排影响有限,但"decision/embedding 模型下沉到边缘"趋势可留意。https://github.com/ollama/ollama/releases/tag/v0.40.0

## 模型服务 & 编排

### KServe 上游
本周 KServe 是全周最该看的仓,两条主线:
- **分离式推理编排**:`DisaggregatedSet` 后端(#6330)。P/D 服务此前是两个独立 Deployment/LWS,更新时两角色各滚各的,prefill/decode 容量比会漂移、可能出现新 prefill 没有对应新 decode。新后端用一个基于 LeaderWorkerSet 的 `DisaggregatedSet`(`<name>-kserve-pd`,含 decode/prefill 两 role)统一管理同步滚动,并**设为 P/D 默认**(feature gate `disaggregatedSet` 默认关,需显式开 + 装 CRD;可按服务 `enable-disaggregated-set: "false"` opt-out)。附带 `DisaggregatedSetUsed` 条件和迁移告警。对我们:这是上游把"分离式推理的滚动一致性"做进控制器,直接对标我们产品的 P/D 编排能力。
  - 另:`llmisvc` 新增可选 P/D backend(#6330 即此);storage-initializer 现可透传 HF 鉴权环境变量(#6308),私有/门控模型拉取更顺。
- **供应链/工件安全**:KernelCache 复用前要求已验证 artifact(#6323)、证书 artifact 安全默认开启(#6324)、artifact 安全请求跨仓共享 registry 设置(#6329),以及一个来自 fork 的安全合并 + 修 SSRF 存储校验挡住的 agent watcher 测试(#6366)。企业级安全合规在补。
来源:https://github.com/kserve/kserve/pull/6330

### Ray
ray-2.59.0(10-02)是本周另一重磅:
- **Ray Data LLM & Ray Serve LLM 升 GA/Stable**(#65194),并同步升到 vLLM 0.27.0(#65351)。Ray 作为"分布式推理/数据"底座的 LLM API 正式稳定,是我们选型时的强竞品/可集成项。
- **Ray Serve 企业特性**:每 deployment `BackpressureConfig`(拒绝请求时返回 429 + 可选 `Retry-After`,把"主动卸载"和"坏了"区分开,对接 LB/SLO)(#65193);声明式 `TracingConfig`(#63273);gang 调度 deployment 支持 `min_replicas=0` 真缩容到零(#65575)。
- **安全默认收紧**:本地集群默认开 token 认证(`ray.init()` 自动在 `~/.ray/auth_token` 生成,`RAY_AUTH_MODE=disabled` 退出)(#64755);dashboard 浏览器端点脱敏 `runtime_env` 凭据(#65226);`read_hudi` 加反序列化防 RCE(#65780)。
- Ray Data:外部磁盘 shuffle(shuffle_v2)GA 化,ORC 原生读等。
来源:https://github.com/ray-project/ray/releases/tag/ray-2.59.0

### KubeAI(原 substratusai/lingo)
v0.24.0(10-07)重新活跃,有几条值得看:
- **新增 SGLang 与 llama.cpp 推理引擎**(#727),引擎覆盖面扩大。
- **控制器 watch scope 可配**(#692),多租户/命名空间隔离部署友好。
- **可选运行时 AI 清单(k8s-aibom subchart,默认关)**(#739)——给推理栈做 AIBOM(AI 物料清单),合规/可追溯方向的新苗头。
- 修:路由排除 terminating pod(#747);支持 `oci://` 模型经 llmman serve 拉取(#728)。
来源:https://github.com/kubeai-project/kubeai/releases/tag/v0.24.0

## 训练 & 微调

- **Kubeflow Trainer**(原 training-operator):本周多为稳健性修复。注意一条 **BREAKING**:`helm uninstall` 时保留 CRD(#4122),避免误删 CRD 连带删作业;另修 TrainJob 省略 `spec.trainer` 时也注入分布式环境变量(#4082)、MPI/Flux plugin 的 nil 解引用 panic(#4157/#4159)。无新能力,偏打磨。https://github.com/kubeflow/trainer/commit
- **LLaMA-Factory**(hiyouga/LlamaFactory):窗口内无实质提交,最近 release 仍是 v0.9.5(05-30)。无重大更新。

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
v3.17.0(10-07),企业向三件事:
- **共享资源细粒度权限(RBAC)**:可控制 runs/traces/versions 等子资源类型访问,支持通配授权和显式 DENY(#26157)。多租户托管 MLflow 的关键能力。
- **大 trace 数据集分析提速**:可选的按日 rollup 汇总 + 原始查询回退,降 SQL 分析开销(#25991)。注意:SQL 后端需协调式 schema 升级(停写 + 备份,`mlflow db upgrade`,不支持混版滚更)。
- 另:AI Gateway 加 OpenAI 兼容模型发现(#25940)、可用 `MLFLOW_ENABLE_AI_GATEWAY` 禁用;自定义 scorer 代码限制在 job executor 内执行(#26225,安全)。
来源:https://github.com/mlflow/mlflow/releases/tag/v3.17.0

### 模型注册(kubeflow/hub,原 model-registry)
延续 catalog 化主题:catalog 新增 **evaluation-metrics artifact 类型**(#3332)——注册表开始承载"评测指标"作为一等工件;修 catalog 滚更初始化死锁(#3308)、报告缺失的 HF token(#3321)、校验归档解压(#3322)。方向:模型注册 + 评测结果 + HF 门控接入的整合。https://github.com/kubeflow/hub/pull/3332

### Feast
本周提交密集,产品向信号:
- **MCP server 升为一等组件**(#6855,独立 MCP server)——Feature Store 直接给 Agent/LLM 当上下文/工具源,是"特征即上下文"的明确落子。
- **Chronon 在线/离线存储集成**(#6188)+ Chronon operator 校验修复(#6947)。
- **Lance 数据源非 JVM 读/写路径**(#6943/#6945)、LanceFormat 表格式带版本/tag 固定(pinning)。
- Milvus 在线库支持 partition key(#6xxx)、一致性级别配置;REST 权限 API 拒绝未知资源/动作类型、删权限后刷新 SQL registry 缓存(安全/正确性)。
来源:https://github.com/feast-dev/feast/pull/6855

## LLM 评估 & 安全

- **NVIDIA garak**:本周密集修复红队工具链的正确性/隔离性——`Buff._derive_new_attempt` 深拷贝可变状态避免攻击样本串台(#2156/#2198)、ApiKey safe-token 抑制只作用于匹配凭据(#2270/#2182)、尊重 generator 的 `parallel_capable`(#2274)、WebSocketGenerator 复用事件循环(#2269)。无新攻击面,偏稳定性。https://github.com/NVIDIA/garak/pull/2270
- **lm-evaluation-harness**:窗口内无提交,最近 release 仍 v0.4.13(08-31)。无重大更新。
- **llama-stack**(release 发在 meta-llama/llama-stack,代码在 ogx-ai/ogx):**v1.5.0**(10-09,108 commits)。对我们有用的:
  - **新增 Text-Embeddings-Inference(TEI)推理 provider**(#6657),并把 llama-cpp-server 的模型按 models.dev 分类向 vLLM 对齐(#6619);新增 DeepSeek/Fireworks 的 `/v1/messages` 原生透传、Anthropic 路径支持 reasoning 模型 thinking(#6663)。
  - **新增 Exa / Serply 两个 web search provider**(#6643/#6636)、responses 支持 `file_search` 混合检索(#6576)、支持 MCP 2.x 客户端 SDK(#6684)。
  - 存储层:PostgreSQL 连接 URI(#6690)、S3 对象可选 key 前缀(#6639)。
  - **BREAKING**:`apis:` 显式列表现在是权威(空也算)、FastAPI 底线抬到 0.137.2 并移除遗留路由收集。
  来源:https://github.com/meta-llama/llama-stack/releases/tag/v1.5.0

## 值得跟进

- [ ] **KServe DisaggregatedSet** vs 我们自家 P/D 编排:上游用 LeaderWorkerSet 做"同步滚动"的思路,评估能否直接复用 LWS 或对齐其 condition/迁移语义。https://github.com/kserve/kserve/pull/6330
- [ ] **Ray Serve LLM GA**:作为推理服务层的竞品/可集成底座重新评估,尤其 BackpressureConfig(429/Retry-After)和 min_replicas=0 缩容到零,对标我们网关的卸载/弹性策略。https://github.com/ray-project/ray/pull/65193
- [ ] **推理网关的"判别端点"**:SGLang Decisions/Score API 把分类/打分标准化为服务端点,考虑在我们网关层预留 `/v1/score` 类能力。https://github.com/sgl-project/sglang/pull/41208
- [ ] **AIBOM 苗头**:KubeAI 的 k8s-aibom subchart,跟踪"AI 物料清单"是否会成为合规硬需求。https://github.com/kubeai-project/kubeai/pull/739
- [ ] **Feast × MCP**:Feature Store 作为 Agent 上下文源,评估与我们模型服务/RAG 链路的接入点。https://github.com/feast-dev/feast/pull/6855
- [ ] **vLLM 快速重启**:`vllm preload` / `vllm snapshot` 能否接入我们的模型滚更与故障自愈,压缩冷启动。https://github.com/vllm-project/vllm/pull/56680
