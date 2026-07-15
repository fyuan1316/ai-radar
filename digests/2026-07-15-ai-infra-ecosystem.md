# AI 推理 & MLOps 生态周报 2026-07-15

> 覆盖窗口:2026-07-08 ~ 07-15。数据源见 `tasks/ai-infra-ecosystem.md`。
> 提示:任务清单中 4 个源仓库已改名——`substratusai/lingo`→`kubeai-project/kubeai`、`kubeflow/training-operator`→`kubeflow/trainer`、`kubeflow/model-registry`→`kubeflow/hub`、`meta-llama/llama-stack`→`ogx-ai/ogx`,本期按新路径抓取。

## 摘要(5 条以内)

1. **vLLM v0.25.0** 大版本:Model Runner V2 成为所有稠密模型默认执行路径、彻底删除 PagedAttention;Rust 前端补齐 HTTPS/mTLS 与 DP supervisor——推理引擎正在把"企业级服务面"内建化。紧接着的 v0.25.1 修了一个会输出乱码(`!!!!!`)的 NVFP4 融合 bug,生产升级要直接跳到 .1。
2. **OGX(原 llama-stack)v1.2.0** 引入**租户隔离作为独立于 ABAC 的硬分区键**,并新增 Containers API(/v1alpha)、Skills API——Meta 的应用栈在往"多租户平台"方向走,和我们做的事高度重叠。
3. **Kubeflow Hub(原 model-registry)** 把模型注册表升级成**带性能指标 + 安全评估的模型目录**:冷启动/硬件配置 artifact、`security-evaluations.ndjson` 加载器、Artifacts 端点新增 `security-metrics` 枚举。模型生命周期治理的上游范式在变。
4. **Ollama v0.32.0** 把默认入口从"跑模型"改成"启动一个 Agent"(`glm-5.2:cloud`),Codex 集成改名 ChatGPT——边缘/桌面推理工具全面转向 agent 工作流 + 云端模型。
5. **Kubeflow Trainer** 落地 runtime snapshot 机制(KEP-2599)、reconciler 尊重 `managedBy` 字段;**TensorRT-LLM** BREAKING 删掉遗留 TensorRT 后端(全面 PyTorch 化)。

---

## 推理引擎动态

### vLLM
v0.25.0 是本周最重的一发(558 commits / 232 contributors),对做服务平台的人有几处关键信号:

- **Model Runner V2 成为所有稠密模型默认路径**,并同步删除遗留 PagedAttention(#47361)。V1/MRv2 已是唯一标准执行栈,自研平台如果还 pin 老路径需要尽快迁移。
  https://github.com/vllm-project/vllm/releases/tag/v0.25.0
- **Rust 前端补齐企业级服务面**:HTTP/gRPC 的静态 HTTPS 与 mTLS(#45890)、DP supervisor(#47076)、profiler 控制路由(#46306)。以前要靠 sidecar/网关兜的 TLS,引擎在自己做。
- **PD 分离(prefill/decode disaggregation)二级实现**(#42285)+ Mooncake connector 支持 GDN(Qwen3.5)/ MLA(DeepSeek-V4-Flash)(#46807);KV offloading 分层指标打通(#45959)。大规模服务的 KV 分层/分离在成为一等公民。
- **统一 Streaming Parser Engine**(#46610):tool-call/reasoning 解析框架统一,内建 Kimi k2.5/k2.6/k2.7、DeepSeek V4 parser——多模型 function-calling 兼容层收敛。
- **异构词表通用投机解码 TLI**(#38174):draft/target 模型词表不同也能投机解码,给"小模型草稿 + 大模型验证"的成本优化打开空间。
- **v0.25.1 补丁**:修复混合 dtype 的 allreduce+RMSNorm+量化融合会污染隐藏状态、输出重复 `!!!!!` 乱码(#48330),以及无系统 FFmpeg 时 TorchCodec 阻塞启动(#47888)。**生产升级直接用 v0.25.1**。
  https://github.com/vllm-project/vllm/releases/tag/v0.25.1

### SGLang
v0.5.15 / v0.5.15.post1,主线是 Blackwell 生产化与投机解码:

- **GLM-5.2 NVFP4 生产调优**:8x B300 上 500+ tok/s/user、4x GB300 上 450(bs=1),配 cookbook。竞品在把"某旗舰模型 + 某代卡"的最优组合做成开箱即用。
- **Spec V2 默认开启**:CUDA-graphable DSA draft-extend、去掉 D2H/H2D 同步,端到端 +11% TPS;IndexShare MTP 长上下文 draft-step 成本降至 1/1.9。
- **原生 Web 搜索(Exa)**:内建 `web_search`(#29342)——推理引擎开始内建 agent 工具。
- **MLA 模型 Decode Context Parallelism**(DeepSeek V3 / Kimi K2 系列)(#14194)。
  https://github.com/sgl-project/sglang/releases/tag/v0.5.15

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:**BREAKING——移除遗留 TensorRT 后端的 Python 模块与测试(#15918)**,栈全面 PyTorch 化;KV cache manager v2 运行时集成(commit_min_snapshot,#16185);disagg 增加 gated C++ NIXL 的在途取消与安全清理(#15238);新增"Scaffolding 上通过 trace-replay 做 agent serving 评估"(#14397)。测试矩阵已在跑 DGX-Spark / GB300 / B300。
- **TGI**:本周无提交,主分支最后一次提交停在 2026-03-21。HuggingFace 官方推理栈事实上已进入维护/停滞状态,选型上不建议再作为新平台基座。
- **Ollama v0.32.0**:默认命令 `ollama` 从"跑模型"变成"**启动交互式 Agent**"(默认 `glm-5.2:cloud`,可 chat/code/搜网/委派任务);Codex 集成改名 ChatGPT;对老 agent 模型(CodeLlama、Qwen2.5-coder、Llama 3.x 等)启动前弹弃用告警。信号:边缘/桌面工具在向 agent + 云端模型转型。
  https://github.com/ollama/ollama/releases/tag/v0.32.0

## 模型服务 & 编排

### KServe 上游
- v0.18.1 为纯补丁发布:cherry-pick 一个 Helm chart 修复(#5811)+ release 准备(#5819),无功能变化。
  https://github.com/kserve/kserve/releases/tag/v0.18.1

### Ray
Serve / Core 侧稳定性与容错为主,几处对平台有参考价值:

- **GCS 内嵌 RocksDB 存储后端做容错(REP-64,#63657)**:GCS 元数据可持久化到 RocksDB,是 Ray 控制面高可用的关键补强,对标我们自研控制面的容错设计值得看。
- **Ray Data 向 actor-only 架构演进**:废弃底层 scheduling API(#64632),hash shuffle v2、file listing work-stealing 等。
- **Serve**:HAProxy 稳定性系列(所有 serve 测试跑 HAProxy、去掉白名单)、控制器 O(1) 版本过滤副本计数;Serve LLM 升级到 vLLM 0.24.0(#64483)并补自定义 vLLM 模型指南。
- **安全**:修复 `/logs` 端点的本地文件包含 LFI(#64701)、模板 zip 解压路径穿越加固(#64669)——自建平台若借鉴 Ray 模板机制需注意同类问题。
- 治理:新增 `AGENTS.md` 贡献策略并把 `.claude/CLAUDE.md` 路由过去(#64419)。

### KubeAI(原 substratusai/lingo)
本周无更新,主分支最后一次提交为 2026-06-29(支持以 OCI 镜像加载模型,#661)。

## 训练 & 微调

- **Kubeflow Trainer(原 training-operator)**:v2 持续成型——
  - **runtime snapshot 机制落地(KEP-2599,#3580)**:运行时快照,利于 TrainJob 的可复现与调度决策。
  - reconciler 尊重 `managedBy` 字段(#3681),多控制器共管场景更干净;initializer 校验使用正确的 volume name(#3714)。
  - **BREAKING:CRD 移到 Helm chart template 目录(#3655)**;`enableHTTP2` 挪进 Configuration 对象(#3339);放宽 TrainJob command/args 长度限制(#3689)。
  https://github.com/kubeflow/trainer/commits/master
- **LLaMA-Factory(现 hiyouga/LlamaFactory)**:v1 重构——用 `apply_chat_template` 替换自研模板系统(#10598),对齐 transformers 生态;更新 license 检查与 transformers 版本(#10632)。

## 模型生命周期(MLflow / Registry / Feast)

### Kubeflow Hub(原 model-registry,现并入 monorepo)
v0.3.12 仍是 Alpha,但方向明确:**从"模型注册表"升级为"带性能 + 安全元数据的模型目录"**——

- 目录卡片/详情用**性能指标**(冷启动 artifact、硬件配置)做过滤与展示,支持从冷启动 artifact 解析硬件配置(#2852、#2837);
- **安全评估**:新增 `security-evaluations.ndjson` 加载器(#2779),Artifacts 端点新增 `security-metrics` 枚举(#2814);
- catalog 新增 `orderBy=RECOMMENDED`、废弃旧 recommendations 参数(#2819);TLS config 设置 ALPN/NextProtos(#2851)。
- **启示**:上游把"模型选型"从功能维度扩展到**性能 + 安全评估维度**,这正是企业模型治理的差异化点,我们的模型目录/注册表应对齐 perf/security 元数据 schema。
  https://github.com/kubeflow/hub/releases/tag/v0.3.12

### MLflow
主线是 GenAI 可观测/评估与企业接入:

- **第三方 scorer 纳入 telemetry**:Guardrails、Phoenix、TruLens(#24437)——MLflow 在做"评估中台",聚合外部 guardrail/eval。
- **RBAC 网关认证 OpenAI 协议编码 agent(#24294)**、FastAPI auth 前解析 workspace 上下文(#24368):把 coding agent 纳入企业 RBAC。
- 大量 tracing 稳健性修复:Postgres `start_trace()`/`log_spans()` 死锁(#24338)、深层嵌套 trace 的 `RecursionError`(#24362)、异步 trace 导出丢 workspace 上下文(#24275)。GenAI 追踪在向生产级打磨。
- Helm chart 加 OCI source 注解对接 GHCR(#24317)。

### Feast
- **新增 ScyllaDB 在线存储并带向量搜索(#6508)**:feature store 与向量检索继续融合,在线特征 + 向量同库的方案在变多。
- MySQL registry proto 列改用 LONGBLOB(#6566);补 dark mode。

## LLM 评估 & 安全

- **OGX(原 meta-llama/llama-stack)v1.2.0 / v1.2.1**——本周企业化信号最强的一个:
  - **多租户:租户隔离作为独立于 ABAC 的硬分区键(#6126)**。这是平台级隔离的正确姿势(不靠权限策略、靠数据分区),直接对标我们的多租户设计。
  - **Containers API 上线(/v1alpha,#5913)**、Skills API(#6087)、Files API 对齐 OpenAI 规范(#6127);
  - 安全:MarkItDown / MarkItDown 处理器加 ZIP 解压限制(#6100、#6127),CI 引入 Trivy 扫描(#6074);
  - vector_io 传播搜索错误而非静默返回空(#6093),Qdrant/Milvus/Elasticsearch 改为 eager 集合初始化(#6144)。
  https://github.com/ogx-ai/ogx/releases/tag/v1.2.0
- **garak**:修复反向翻译输出用 `list.pop()` 导致重组顺序错乱(#1959)、`analyze_log` 除零防护(#1941);BedrockGenerator 支持 `suppressed_params`(#1842)。红队工具在补 Bedrock 覆盖。
- **lm-evaluation-harness**:新增葡语 ASSIN2 RTE/STS(#3812)、12 种低资源印度语系 MCQ 基准 IndicParam(#3826);修 xnli/xcopa 等数据集命名空间路径(#3870)。评测语种覆盖扩张,基座变化不大。

## 值得跟进

- [ ] **vLLM Rust 前端 mTLS + DP supervisor**:引擎自带 TLS/多副本管理后,我们平台里"网关代管 TLS/负载"的分层要重估边界。(#45890、#47076)
- [ ] **OGX 租户隔离硬分区键(#6126)**:对照我们多租户实现,评估是否需要引入"独立于 ABAC 的分区键"这一层。
- [ ] **Kubeflow Hub 的 perf + security-metrics 目录 schema**:模型目录对齐性能/安全评估元数据,做企业模型治理差异化。(#2779、#2814、#2852)
- [ ] **Kubeflow Trainer runtime snapshot(KEP-2599)**:跟进快照语义,评估对我们训练调度/复现的借鉴。(#3580)
- [ ] **PD 分离 + KV 分层(vLLM #42285 / SGLang / TensorRT-LLM KVCMv2)**:三大引擎同时推 prefill/decode 分离与 KV 分层,是大规模推理成本优化的共同方向,值得立项跟踪。
- [ ] **TGI 停滞**:主分支 4 个月无实质更新,选型/文档中若把 TGI 作为推荐基座需下调。
