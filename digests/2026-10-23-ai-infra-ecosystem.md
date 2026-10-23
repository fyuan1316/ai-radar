# AI 推理 & MLOps 生态周报 2026-10-23

窗口:2026-10-16 ~ 2026-10-23(过去 7 天)。版本 bump / dependabot / CI / 纯文档修复已过滤。
说明:本期与 10-21 期窗口重叠 5 天,vLLM v0.32.0、SGLang v0.5.22、Ray 2.58.1 等上期已详述的版本不再重复,**只写这两天的增量信号**。

## 摘要(5 条以内)

1. **"决策端点/判别模型"从推理引擎扩散到桌面侧**:Ollama v0.40.9 上架 `d3` 决策模型族(2B/4B/9B/27B),官方明说"brings vLLM Semantic Router's decision models"——给文本/结构化状态/图像做分类、是非判断、带概率的打分。接上期 vLLM `systemone`、llama-stack 各 provider 补 SystemOne,一个跨端的"判别原语"生态正在成形,推理网关层值得预留接入位。 https://github.com/ollama/ollama/releases/tag/v0.40.9
2. **TensorRT-LLM v1.4.0rc1 把 KV cache V2 设为默认(破坏性)并整合 Mooncake**:默认启用 KV cache manager V2 + Python KV transceiver(#17495),Mooncake connector 接入 V2(#19171)、host 层渐进式填充(#19650),并暴露原生 KV 事件流与路由负载(#19440)、trtllm-serve 支持运行时 sleep/wakeup。KV 分层/外置存储正从实验走向默认路径。 https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc1
3. **国产加速卡继续渗透上游训练/微调**:LLaMA-Factory 合入壁仞 Biren Supa 加速卡支持(#10844),叠加上期 SGLang 的 AMD 一等公民化——多厂商纳管不再只是 GPU/NPU,异构加速卡适配是我们产品要持续跟的清单。 https://github.com/hiyouga/LLaMA-Factory/pull/10844
4. **Kubeflow Hub(原 model-registry)继续 catalog 化,补齐 Agent/评估治理拼图**:v0.3.18 新增 `evaluation-metrics` catalog artifact 类型(#3332)、MCP 运行时元数据带 storage(#3238)、alpha catalog API 加 RFC 8594 弃用头(#3221);配合 MLflow v3.17.2 在 `genai.evaluate` 落 dataset/scorer/agent 血缘——"模型+Agent+评估"的注册与血缘在上游同步推进。 https://github.com/kubeflow/hub/releases/tag/v0.3.18
5. **KServe `llmisvc` 本周为收尾性加固**:tokenizer Deployment 继承 imagePullSecrets(#6425)、informer 缓存按命名空间收窄(#6270)、storage initializer 的 IRSA 传播(#6396)、cgroup v2 CPU limit 识别(#6347)——企业级多租/私仓/IAM 细节在补,主线功能上期已覆盖。 https://github.com/kserve/kserve/pull/6425

---

## 推理引擎动态

### vLLM
- 本周无新 release(仍为上期 v0.32.0)。主线进入 v0.32 后的常规迭代,无对我们产品清单有增量影响的大改动,略。
- 参考上期:systemone 决策端点 + hf 通用 parser + 低精度 KV cache 默认化。 https://github.com/vllm-project/vllm/releases/tag/v0.32.0

### SGLang
- 本周无新 release(仍为上期 v0.5.22)。无重大更新。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.4.0rc1**(接 rc0):https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.4.0rc1
  - **破坏性默认切换**:默认走 KV cache manager V2 + Python KV cache transceiver(#17495);移除未用 LlmRequest 字段(#19967);C++ `ArrayView` 换成 `std::span`(#20205)。升级需验证分离式服务(已知问题:默认 Python KV transceiver 在 A100 上流式请求取消后可能报 KV 传输错误)。
  - **KV 分层/外置存储**:Mooncake connector 接入 KV cache V2(#19171);host 层渐进式填充(#19650);新增 transfer backend 的 KV cache lending API(#19722);暴露原生 KV 事件流与路由负载(#19440)、可配置 V2 pool 再平衡参数(#19077)。
  - **服务能力**:trtllm-serve/LLM 支持运行时 sleep/wakeup(含 MiniMax-H3,#19016/#19604);发布 serving 配置 schema(#19906);OpenAI server 的 serving-extension registry(上期 rc0 引入)继续。
  - **模型/精度**:DeepSeek-V4.1-Flash(#19727)、NVFP4 GLM-5.3-Flash(#20127);DSpark 带置信度策略的推测校验(#19707);Rubin/Blackwell CuTe DSL MoE 与 MLA 大量优化。
  - **启示**:KV V2 默认化 + Mooncake + KV 事件流/路由负载暴露,是"外置 KV 存储 + 调度器可感知 KV 状态"的厂商落地,和 vLLM CPU-KV、SGLang HiSparse、KServe ModelExpress 同一赛道,可横向对标我们分离式推理的 KV 管理设计。
- **TGI**:仍 archived,0 提交,不再跟踪。
- **Ollama v0.40.6→v0.40.9**:https://github.com/ollama/ollama/releases/tag/v0.40.9
  - **d3 决策模型**(v0.40.9):把 vLLM Semantic Router 的决策模型搬到 Ollama,`ollama run d3 ... --ask "..."` 对文本/结构化状态/图像做分类/是非/概率打分,2B~27B 四档。**这是本期最值得注意的跨端信号**(见摘要 1)。
  - **Phonon 语音/TTS**(v0.40.9):Apple Silicon 上生成语音,支持 OpenAI 兼容 `/v1/audio/speech` 流式端点——多模态 I/O 向边缘侧铺。
  - **Flint 编码模型**(v0.40.8 上架、v0.40.9 扩到 Linux/Windows):Recursive 的 40B MoE(~2.5B active)、262K 上下文、Apache 2.0,主打仓库级编码 agent(SWE-bench Verified 74.2%)。
  - 修复:流式 OpenAI Responses / Anthropic Messages 现会上报生成失败而非静默截断;`ollama launch` 正确传云模型上下文长度/能力给编码工具。

---

## 模型服务 & 编排

### KServe 上游(无 release,main 收尾加固)
`llmisvc` 主线功能上期已详述,本期多为企业级细节(对标 OAI 的"可运维性"维度):
- tokenizer Deployment 继承 imagePullSecrets(私仓拉镜像,https://github.com/kserve/kserve/pull/6425);controller CPU limit 提到 500m(#6444)。
- Deployment/Service informer 缓存按命名空间收窄(大规模下内存/watch 压力,#6270)。
- storage initializer 的 IRSA 传播(AWS IAM 角色,#6396);`cpu_count()` 识别 cgroup v2 CPU limit(容器内线程数更准,#6347)。
- **启示**:这些是"上了规模才会踩的坑"——私仓凭据传递、informer 缓存作用域、IRSA/cgroup 感知,直接对应我们产品在多租户大集群下的稳定性清单,值得逐条对照自查。

### Ray
- 本周无新功能 release(仍为上期 ray-2.58.1 / 2.57.1 补丁)。无重大更新。

### KubeAI(原 substratusai/lingo)
- 收尾性:支持 K8s 1.37 并对齐 client 库(#772);完善 SECURITY.md(#773);RBAC 模板与 SeaweedFS/S3 配置修复。上期 v0.24.0 网关重构后本周无新功能。

---

## 训练 & 微调

- **Kubeflow Trainer**:Volcano PodGroup 在 TrainJob 终态/挂起时清理(#4059,接上期 KEP-3015 workload-aware 调度);initializer 只下载 S3 prefix 下的对象(#4116);OptimizationJob 随机搜索种子收敛到采样器区间(#4248)。gang 调度资源回收与超参搜索在补齐。 https://github.com/kubeflow/trainer/pull/4059
- **LLaMA-Factory**:合入壁仞 Biren Supa 加速卡支持(#10844);采用 HyperParallel 统一模型装配(#10877)。国产加速卡适配(见摘要 3)。 https://github.com/hiyouga/LLaMA-Factory/pull/10844

---

## 模型生命周期(MLflow / Registry / Feast)

- **Kubeflow Hub v0.3.18**(原 kubeflow/model-registry):https://github.com/kubeflow/hub/releases/tag/v0.3.18
  - catalog 新增 `evaluation-metrics` artifact 类型(#3332)——registry 开始承载评估结果,呼应 MLflow 的评估血缘方向。
  - MCP runtimeMetadata 带 storage(catalog server + BFF,#3238);alpha catalog API 加 RFC 8594 弃用头(#3221)。
  - 运维:catalog 滚动升级初始化死锁修复(#3308);缺失的 HuggingFace token 会被明确上报(#3321);minio 换 SeaweedFS(#3270,与 KubeAI 同向)。
- **MLflow v3.17.2**(patch):`mlflow.genai.evaluate` 记录 dataset/scorer/agent 血缘(#26543);修 `MlflowSparkStudy` executor 重采样、Optuna trial 提前标记完成的 bug。GenAI/Agent 评估治理继续小步推进。 https://github.com/mlflow/mlflow/releases/tag/v3.17.2
- **Feast**:PushSource 的上游 FeatureView 血缘(#6853);Ray engine 不再吞掉物化错误(#7026);DuckDB offline store 惰性扫描 Lance 源(perf)。 https://github.com/feast-dev/feast/pull/6853

---

## LLM 评估 & 安全

- **garak v0.17.1**:https://github.com/NVIDIA/garak/releases/tag/v0.17.1
  - 新增 `hit@k` 攻击成功率指标(每 probe/detector 对,输出到 report.jsonl 的 digest,#2090);Python 3.14 支持(#2297)。
  - 一批 detector **判定精度**修复:FileDetector 不再把未检查文件判 pass(#2080)、RefusalOnlyAdversarial 不再多计跳过的多轮尝试(#2111)、safe-token 抑制作用域收窄(#2182/#2270)——降低红队结果的假阴/误判,评测可信度提升。
- **llama-stack v1.4.1**:SQL/KV store 支持 PostgreSQL 连接 URI(#6755);移除未用 nltk 依赖。仅小幅增强。 https://github.com/meta-llama/llama-stack/releases/tag/v1.4.1
- **lm-evaluation-harness**:窗口内 0 实质提交,无重大更新。

---

## 值得跟进
- [ ] **试 Ollama `d3` + vLLM Semantic Router 决策模型**:确认"判别/决策原语"的 API 形态(输入:文本/结构化状态/图像;输出:分类/是非/概率),评估在我们推理网关/路由层做统一抽象的可行性。 https://github.com/ollama/ollama/releases/tag/v0.40.9
- [ ] **读 TensorRT-LLM KV cache V2 + Mooncake 整合(#19171/#19650/#19440)**:对照我们分离式推理的 KV 外置存储与"调度器感知 KV 状态"设计,看 KV 事件流/路由负载暴露这套接口值不值得对齐。
- [ ] **对照 KServe `llmisvc` 本期加固清单自查**:imagePullSecrets 传递(#6425)、informer 缓存作用域(#6270)、IRSA 传播(#6396)、cgroup v2 CPU 识别(#6347)是否在我们产品里都处理了。
- [ ] **关注国产加速卡上游适配节奏**:LLaMA-Factory 壁仞 Biren Supa(#10844)——评估我们多厂商纳管对这类新卡的接入成本。
- [ ] **跟 registry 的评估化**:Kubeflow Hub `evaluation-metrics` artifact(#3332)+ MLflow 评估血缘(#26543),判断"模型注册中心承载评估结果"是否要进我们模型生命周期能力。
