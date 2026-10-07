# AI 推理 & MLOps 生态周报 2026-10-07

> 窗口:2026-09-30 ~ 2026-10-07。只筛对"做云原生 AI 基础设施产品(对标 OpenShift AI)"有用的变化,版本 bump / dependabot / CI 噪音已剔除。

## 摘要(5 条以内)

1. **KServe 把"KV cache 卸载"写进 llmisvc API**,并把 KernelCache 的制品供应链安全(验签后才复用、registry 凭据集成)默认打开——这是上游在补企业级推理的两块短板,值得我们对照自家 InferenceService。
2. **vLLM v0.31.0 发布**:ModelRunner V2 + GPU NGram 投机解码落地,Rust 前端继续替换 Python 解析链路,新增"按缓存层级统计 prompt token"指标与 NIXL KV connector 加固——核心引擎在往"可观测 + 分布式 KV"方向走。
3. **SGLang v0.5.21** 把重心压在生产级路由(sgl-router 重试/退避/超时边界)和 rust-processor 模块化拆分(tokenizer/render/parser),外加 gRPC 暴露 follower 元数据与 node-local KV 源——PD 分离 + 多节点编排能力在成型。
4. **Ray 2.59.0** 默认开启 token 鉴权(C++/Java driver、gRPC facade),serve[llm] 路由更健壮(ingress 失败回退可用副本、KVAwareRouter 支持 LoRA)。
5. **Kubeflow Trainer 新增 OptimizationJob 控制器(KEP-3562)**,把超参优化做成一等 Job;MLflow / Feast / llama-stack 则集体往 GenAI Agent + RAG 向量检索补能力。

## 推理引擎动态

### vLLM
- **v0.31.0 发布**:https://github.com/vllm-project/vllm/releases/tag/v0.31.0
- **ModelRunner V2(MRV2)成为主线**:GPU 版 NGram 投机解码落地(https://github.com/vllm-project/vllm/pull/40704),并修了一批 MRV2 下 Mamba 状态/投机 token 的正确性问题。
- **Rust 前端持续替换 Python**:移除 PyO3 tool-parser 桥(https://github.com/vllm-project/vllm/pull/59744)、把 MiniMax M3 tool parser 迁到解析引擎、工具模板支持 defer_loading。对我们意味着 vLLM 的 OpenAI 兼容网关层正在"去 Python 化"提吞吐。
- **可观测**:按缓存层级(cache tier)暴露 cached prompt token 指标(https://github.com/vllm-project/vllm/pull/56318)、per-session profiling 控制。做容量/计费的可以关注。
- **分布式 KV**:一批 NIXL KV connector 修复(本地失效 peer 元数据恢复、按 region 复制标志等),配合 v0.31 的 NIXL 1.5.0。
- 量化后端继续扩张(UltraQuant 4-bit KV cache、在线 MXFP8→FP8 重量化 API)。

### SGLang
- **v0.5.21 发布**:https://github.com/sgl-project/sglang/releases/tag/v0.5.21
- **sgl-router 生产化**:一组"重试 1/5~5/5"提交把路由做成可重试/可退避、按超时界定 time-to-headers、跳过已失败 worker、拒绝 0 超时配置(https://github.com/sgl-project/sglang/pull/42632)。这正是企业级推理网关该有的鲁棒性,可直接对标我们的流量入口。
- **rust-processor 拆分**:切成 tokenizer / render / parser 三块并按 cargo feature 门控(https://github.com/sgl-project/sglang/pull/42662)——与 vLLM Rust 前端同向。
- **PD 分离 / 多节点**:gRPC 暴露 follower 元数据与 node-local KV 源(https://github.com/sgl-project/sglang/pull/39659);HiCache 按存储池管理 buffer-mode 备份;新增 per-rank DP attention 不均衡指标。
- 另有大量 diffusion(图像/视频生成)模型接入,与我们 LLM 基础设施关系不大,略。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:窗口内无 release,但有两处产品向信号——每请求返回投机解码接受率(https://github.com/NVIDIA/TensorRT-LLM/pull/19311)、模型启动阶段计时指标(https://github.com/NVIDIA/TensorRT-LLM/pull/18060)、C++ 流式 KV 事件支持多模态载荷;KVCacheManagerV2 支持 beam search。可观测与 KV 管理在补齐。
- **TGI**:仓库仍为 archived(最后 push 2026-03-21),无更新,属已停维护。
- **Ollama**:MLX 后端持续建设(System One、decision models、GPU idle 后降延迟)、新增多模态 embeddings(https://github.com/ollama/ollama/pull/18820)、代理 cloud usage/balance API。边缘/桌面向,参考意义有限。

## 模型服务 & 编排

### KServe 上游
本周 KServe 实质更新最值得看:
- **llmisvc 新增 KVCacheOffloading(v1alpha1 API + 转换)**:https://github.com/kserve/kserve/pull/6006 —— 把 KV 卸载作为声明式 API 暴露,和 vLLM/SGLang 的 KV 下沉能力对接,是我们该跟进的 API 面。
- **llmisvc 资源 reconcile/finalize 钩子** 与 **只处理基于 model 的路由匹配(opt-in)**:https://github.com/kserve/kserve/pull/6303 、https://github.com/kserve/kserve/pull/6306 —— 为不同发行版定制预留扩展点。
- **KernelCache 制品供应链安全**:默认启用证书制品安全(https://github.com/kserve/kserve/pull/6324)、复用缓存前要求验签制品(https://github.com/kserve/kserve/pull/6323)、集成 registry 凭据/支持非安全 OCI registry。对标我们企业级"模型/内核缓存可信来源"诉求。
- **InferenceGraph 加发行版特定逻辑钩子**(https://github.com/kserve/kserve/pull/6304);storage-initializer 透传 HF auth 环境变量(https://github.com/kserve/kserve/pull/6308)。

### Ray
- **Ray 2.59.0 发布**:https://github.com/ray-project/ray/releases/tag/ray-2.59.0
- **安全默认收紧**:C++/Java driver 自起本地集群时启用 token 鉴权、gRPC facade 强制 API token(https://github.com/ray-project/ray/pull/66675)。多租户场景值得借鉴。
- **serve[llm] 路由健壮性**:ingress router 失败时回退到可用副本(https://github.com/ray-project/ray/pull/66339)、KVAwareRouter 支持 LoRA(https://github.com/ray-project/ray/pull/66200)、移除 P/D tokenize-once 补丁;新增推送式副本健康检查。
- Ray Data 做了大规模 DSv2 重构(格式/调度 API),离线批处理相关。

## 训练 & 微调
- **Kubeflow Trainer 新增 OptimizationJob 控制器(KEP-3562)**:https://github.com/kubeflow/trainer/pull/3828 —— 把超参优化做成一等公民 Job,是 Trainer v2 向"训练+调优统一编排"扩张的信号,直接关系我们训练平台的能力清单。
- 其余为健壮性修复:Flux 插件 nil NumProcPerNode 不再 panic、spec.trainer 省略时注入分布式环境变量、插件阶段执行顺序确定化、Volcano priorityClassName 校验覆盖所有 ReplicatedJob。
- **LLaMA-Factory**:窗口内无提交(最后提交 2026-09-28),无重大更新。

## 模型生命周期(MLflow / Registry / Feast)
- **MLflow** 明显转向 GenAI / Agent 运维:
  - 支持 **包装式 MCP registry server 定义**(https://github.com/mlflow/mlflow/pull/25764)、评估数据集 `name IN (...)` 过滤;
  - **RBAC 细化**:为 runs/traces/versions 等子资源加子权限(https://github.com/mlflow/mlflow/pull/26157);
  - **安全**:把自定义 scorer 代码执行限制在 job executor 内(https://github.com/mlflow/mlflow/pull/26225);
  - Databricks 评审队列、TypeSafe/OpenRouter judges、GenAI semconv trace 完善。
- **Kubeflow Hub(原 model-registry,已并入 hub)**:https://github.com/kubeflow/hub —— 本周多为依赖 bump;实质项:catalog 缺失已保存的 HuggingFace token 时报错(https://github.com/kubeflow/hub/pull/3321)、async-upload 校验归档解压(https://github.com/kubeflow/hub/pull/3322)、支持 MCP 架构过滤、规避滚动升级初始化死锁。catalog + HF 门控方向延续。
- **Feast** 向"向量 / RAG 特征库"持续加码:
  - **新增 Chronon 在线/离线 store 集成**:https://github.com/feast-dev/feast/pull/6188 ;
  - Lance / LanceFormat 数据源(非 JVM 读路径、版本/tag 钉定);
  - Milvus 在线 store 增强(consistency_level、token/uri/db_name、索引与检索参数可配);
  - 向量宽度推断、Field 相等纳入向量属性;服务器全面支持双栈 IPv6 绑定。

## LLM 评估 & 安全
- **lm-evaluation-harness**:窗口内无提交(最后 2026-09-14),无重大更新。
- **NVIDIA/garak**:仅 2 次提交(plugin_cache 更新、HF InferenceAPI 404 报错更清晰),无重大更新。
- **meta-llama/llama-stack**(release 仍发在此,代码内部为 ogx):本周主题是 **RAG 向量检索 + MCP + Agent 响应**:
  - vector_io 全面对齐 upsert 语义(FAISS/weaviate/pgvector/elasticsearch),responses 支持 file_search 的 hybrid_search、ES RRF rank_window_size;
  - **支持 MCP 2.x 客户端 SDK**(https://github.com/meta-llama/llama-stack/pull/6684);
  - storage 支持 PostgreSQL 连接 URI;responses API 把 conversations/prompts 一并纳入服务;skills 对畸形 SKILL.md frontmatter 返回 400。

## 值得跟进
- [ ] **KServe llmisvc 的 KVCacheOffloading / reconcile 钩子**:对照我们 InferenceService 是否需要把 KV 卸载做成声明式 API,以及如何接 vLLM/SGLang 的 KV 下沉。https://github.com/kserve/kserve/pull/6006
- [ ] **KServe KernelCache 制品验签默认开启**:评估我们模型/内核缓存链路是否要做同等"可信来源 + registry 凭据"治理。https://github.com/kserve/kserve/pull/6323
- [ ] **推理网关鲁棒性**:SGLang sgl-router 的重试/退避/超时边界,是生产级流量入口的参考实现。https://github.com/sgl-project/sglang/pull/42632
- [ ] **多租户安全默认**:Ray 2.59 默认 token 鉴权,反思我们组件间通信的默认安全姿态。https://github.com/ray-project/ray/pull/66675
- [ ] **训练+调优统一**:Kubeflow Trainer OptimizationJob(KEP-3562)是否纳入我们训练平台路线。https://github.com/kubeflow/trainer/pull/3828
- [ ] **MCP 纳管成行业默认**:MLflow、llama-stack、Kubeflow Hub 本周都在加 MCP 支持,与 OAI 的 MCP Registry 方向一致,值得统一规划。
