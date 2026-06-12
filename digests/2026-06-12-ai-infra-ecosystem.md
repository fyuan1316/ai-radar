# AI 推理 & MLOps 生态周报 2026-06-12

> 扫描窗口:2026-06-05 ~ 2026-06-12。每条带源链接,版本 bump / dependabot / CI 噪音已过滤。
> 与 [上一期 06-10](https://github.com/fyuan1316/ai-radar/blob/main/digests/2026-06-10-ai-infra-ecosystem.md) 重叠部分只记本周新增量。重命名仓库沿用新 slug(ogx-ai/ogx、kubeai-project/kubeai、kubeflow/hub、kubeflow/trainer、hiyouga/LlamaFactory)。

## 摘要(5 条以内)

1. **KServe v0.19.0 临近发版,llmisvc 继续加企业调度能力**:本周开 `release: prepare release v0.19.0` [#5654](https://github.com/kserve/kserve/pull/5654);llmisvc 给 LoRA adapter 自动启用 lora-affinity-scorer [#5655](https://github.com/kserve/kserve/pull/5655)、把 vLLM 列为一等支持的 runtime [#4769](https://github.com/kserve/kserve/pull/4769)、加 platform hooks 做 service 定制 [#5617](https://github.com/kserve/kserve/pull/5617)。这是本周最该贴的上游主线。
2. **通用推理引擎集体进军扩散/图像生成**:vLLM 新增 DiffusionGemma [#45163](https://github.com/vllm-project/vllm/pull/45163);SGLang 给 Ideogram 4 上 GPU DCT 渐进分辨率(最高 1.56×)[#27736](https://github.com/sgl-project/sglang/pull/27736);TRT-LLM 对齐 VisualGen serve 请求 schema [#14733](https://github.com/NVIDIA/TensorRT-LLM/pull/14733) + Cache-DiT 文档。非 LLM 生成负载正成为通用推理栈一等公民。
3. **分离式推理(P/D disaggregation)从引擎下沉到编排层**:Ray Serve.llm 把 P/D 编排下放给 KV-connector 后端 [#63950](https://github.com/ray-project/ray/pull/63950);TRT-LLM 开 gen-only spec decoding [#14546](https://github.com/NVIDIA/TensorRT-LLM/pull/14546) + disagg 取消压测 [#15174](https://github.com/NVIDIA/TensorRT-LLM/pull/15174);SGLang 修 PD ZMQ stale socket 重连 [#27796](https://github.com/sgl-project/sglang/pull/27796)。
4. **vLLM 三连安全修复 + Rust 前端继续收编网关职责**:拒绝非有限采样参数 [#45116](https://github.com/vllm-project/vllm/pull/45116)、修 GGUF 反量化内核 int32 截断信息泄露 [#44971](https://github.com/vllm-project/vllm/pull/44971)、Anthropic/STT 错误路径脱敏 [#45119](https://github.com/vllm-project/vllm/pull/45119);Rust 前端补 continuous_usage_stats [#43965](https://github.com/vllm-project/vllm/pull/43965)、导出 lora_requests_info 指标 [#45030](https://github.com/vllm-project/vllm/pull/45030)、校验越界 token id [#44680](https://github.com/vllm-project/vllm/pull/44680)。
5. **MLOps 人审闭环走向多租户/企业级**:MLflow review-queue 加 owner-aware 授权(experiment ACL + per-queue owner)[#23844](https://github.com/mlflow/mlflow/pull/23844)、per-reviewer 答案 source-scoped + 重提覆盖 [#23846](https://github.com/mlflow/mlflow/pull/23846)、并发加固;kubeflow/hub 把 cold-start / vRAM / container-size 过滤接到真实 catalog API [#2815](https://github.com/kubeflow/hub/pull/2815)。可调度模型元数据与人审 ACL 同步成熟。

## 推理引擎动态

### vLLM
- **进军扩散生成**:新增 DiffusionGemma 支持 [#45163](https://github.com/vllm-project/vllm/pull/45163),与 SGLang/TRT-LLM 同步把图像生成纳入通用引擎。
- **安全三连**:拒绝非有限 `temperature`/`repetition_penalty` [#45116](https://github.com/vllm-project/vllm/pull/45116)、修 GGUF dequantize 内核 int32 截断导致的信息泄露 [#44971](https://github.com/vllm-project/vllm/pull/44971)、对 Anthropic 与 STT 错误路径施加 `sanitize_message` [#45119](https://github.com/vllm-project/vllm/pull/45119)。继上期音频/图片 DoS 后,采样参数与量化输入又成新攻击面。
- **Rust 前端持续补能力**:`continuous_usage_stats` 流选项 [#43965](https://github.com/vllm-project/vllm/pull/43965)、从前端导出 `vllm:lora_requests_info` 指标 [#45030](https://github.com/vllm-project/vllm/pull/45030)、校验请求里越界 token id [#44680](https://github.com/vllm-project/vllm/pull/44680)、修 DeepSeek V3.2 `continue_final_message` 渲染 [#45155](https://github.com/vllm-project/vllm/pull/45155)。
- **Anthropic API 兼容**:修 Anthropic `tool_use` 内容处理丢失 args [#45287](https://github.com/vllm-project/vllm/pull/45287)。
- **内核/serving**:加 kvcache watermark 降抢占 [#44594](https://github.com/vllm-project/vllm/pull/44594);DSv4 flash-decode split-K 解码内核 [#44899](https://github.com/vllm-project/vllm/pull/44899);Dockerfile GCC 10→12 上 C++20 [#44923](https://github.com/vllm-project/vllm/pull/44923);发布 v0.23/v0.24 弃用计划 [#44992](https://github.com/vllm-project/vllm/pull/44992)。
- **启示**:Rust 前端把鉴权、限流、usage、LoRA 指标、token 校验逐项内置——上游正在把"推理网关"做成引擎自带件,自建网关层的边界需持续收窄。三连安全修复说明采样参数与权重文件(GGUF)都要在入口校验。

### SGLang
- **diffusion 子系统继续加速**:Ideogram 4 GPU DCT 渐进分辨率最高 1.56× [#27736](https://github.com/sgl-project/sglang/pull/27736)、Ideogram4 opt-in fused w8a8 内核 [#27590](https://github.com/sgl-project/sglang/pull/27590)、优化 flux1 TP 切分 [#27826](https://github.com/sgl-project/sglang/pull/27826)、修 wan ti2v sp timestep padding [#27876](https://github.com/sgl-project/sglang/pull/27876)。
- **Spec V2 收口**:`Retire Spec V1` [#27964](https://github.com/sgl-project/sglang/pull/27964) + 删除 dead spec V1 调度路径 [#27977](https://github.com/sgl-project/sglang/pull/27977)、DFLASH V1 worker 下线 [#27959](https://github.com/sgl-project/sglang/pull/27959)。投机解码架构统一到 V2。
- **PD 分离式稳定性**:修 PD ZMQ stale socket 重连 [#27796](https://github.com/sgl-project/sglang/pull/27796)、修乐观 prefill 下负的 `kv_transfer_alloc_ms` [#27885](https://github.com/sgl-project/sglang/pull/27885)。
- **NPU/多硬件**:Ascend 后端加 Gemma4 滑窗注意力 [#26147](https://github.com/sgl-project/sglang/pull/26147);MiMo v2 ASR [#26278](https://github.com/sgl-project/sglang/pull/26278);AMD/Intel XPU 多路内核修复。
- **启示**:扩散负载在 SGLang 已是常态化迭代而非实验;Spec V1 的彻底下线提示我们若依赖其投机解码 API 要跟 V2 迁移。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**(最新 [v1.3.0rc18](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc18),06-10):VisualGen serve 请求 schema 对齐 VisualGenParams [#14733](https://github.com/NVIDIA/TensorRT-LLM/pull/14733)、为 trtllm-serve visual-gen 保留 ip:port [#14355](https://github.com/NVIDIA/TensorRT-LLM/pull/14355);KV cache 事件保留 `cache_salt` 字符串 [#13051](https://github.com/NVIDIA/TensorRT-LLM/pull/13051) + 新增 `reset_prefix_cache` API [#14970](https://github.com/NVIDIA/TensorRT-LLM/pull/14970);gen-only spec decoding [#14546](https://github.com/NVIDIA/TensorRT-LLM/pull/14546);backend-agnostic SourceIdentity 权重共享门 [#14878](https://github.com/NVIDIA/TensorRT-LLM/pull/14878);Cache-DiT(扩散缓存)文档 [#15268](https://github.com/NVIDIA/TensorRT-LLM/pull/15268)。
- **TGI(HuggingFace)**:**无重大更新**——最新仍是 2025-12 的 v3.3.7,本周 0 提交。维护态持续,作为长期依赖风险不变。
- **Ollama**:连发 v0.30.4~[v0.30.7](https://github.com/ollama/ollama/releases/tag/v0.30.7);把 prompt 缓存与上下文位移解耦 [#16639](https://github.com/ollama/ollama/pull/16639);MLX 后端经 cache 快照驱动 MTP 投机、gated-delta 内核、embedding 用 nvfp4 全局 scale [#16527](https://github.com/ollama/ollama/pull/16527);加 hermes-desktop / oh-my-pi 桌面启动器与原生 Windows 配置;仓库根加 AGENTS.md / CLAUDE.md [#16604](https://github.com/ollama/ollama/pull/16604)。偏端侧。

## 模型服务 & 编排

### KServe 上游
- **v0.19.0 发版准备**:`release: prepare release v0.19.0` [#5654](https://github.com/kserve/kserve/pull/5654)。
- **llmisvc 企业调度能力**:LoRA adapter 自动启用 lora-affinity-scorer(LoRA 亲和调度)[#5655](https://github.com/kserve/kserve/pull/5655);把 vLLM 列为受支持 runtime [#4769](https://github.com/kserve/kserve/pull/4769);加 platform hooks 做 service 定制 [#5617](https://github.com/kserve/kserve/pull/5617);按 gateway name 过滤 HTTPRoute parent status [#5583](https://github.com/kserve/kserve/pull/5583);修 probe 阈值 / EPP grace period [#5602](https://github.com/kserve/kserve/pull/5602)。
- **存储 & 安全**:加 `storageContainerName` 显式选 CSC [#5314](https://github.com/kserve/kserve/pull/5314);llmisvc PVC 存储 e2e [#5623](https://github.com/kserve/kserve/pull/5623);bump starlette 修 CVE-2026-48710 [#5632](https://github.com/kserve/kserve/pull/5632);scheduler v0.6→v0.7 迁移 e2e [#5564](https://github.com/kserve/kserve/pull/5564)。
- **启示**:llmisvc 这周从"接线"转到"调度 + runtime 集成 + 定制钩子"——LoRA 亲和调度、vLLM 一等支持、platform hooks 三件直接对应我们 LLM 推理服务要做的差异化能力,建议逐条比对自家 CRD。

### Ray
- **Serve.llm 分离式 & 路由**:把 P/D 编排下放给 KV-connector 后端 [#63950](https://github.com/ray-project/ray/pull/63950);direct streaming + session affinity 测试 [#63927](https://github.com/ray-project/ray/pull/63927)、ingress request router 文档 [#63860](https://github.com/ray-project/ray/pull/63860);让 `request.request_id` 对 engine 权威 [#63949](https://github.com/ray-project/ray/pull/63949)。
- **HAProxy 化继续**:优雅 drain 等待在途/排队请求 [#63886](https://github.com/ray-project/ray/pull/63886)、跨 node-manager prune 保留 direct-ingress 端口隔离 [#63920](https://github.com/ray-project/ray/pull/63920)、`RAY_SERVE_PORT_QUARANTINE_S` 默认硬停 [#64021](https://github.com/ray-project/ray/pull/64021)。
- **Ray Data**:单集群多 dataset 按 subcluster label 切资源 [#63375](https://github.com/ray-project/ray/pull/63375);移除 `ExecutionPlan` [#63662](https://github.com/ray-project/ray/pull/63662)。
- **启示**:Ray 把 P/D 编排交给 KV-connector 后端,与 SGLang/TRT-LLM 的 disagg 同源——分离式推理的"控制面"正在从引擎内上移到 Serve 编排层,我们若做 P/D 需对齐 KV-connector 抽象。

### kubeai(原 substratusai/lingo)
- 仓库已迁至 [kubeai-project/kubeai](https://github.com/kubeai-project/kubeai)(旧 slug 现 301);本周 0 提交。**无重大更新**,节奏持续放缓。

## 训练 & 微调
- **kubeflow/trainer(原 training-operator)**:JAX `EnforceMLPolicy` 防 nil trainer PodSet [#3563](https://github.com/kubeflow/trainer/pull/3563)、自动化 release 流程 [#3536](https://github.com/kubeflow/trainer/pull/3536)。**无重大功能更新**,Trainer v2 仍停在 v2.2.0(03-20)。
- **LLaMA-Factory(原 [hiyouga/LlamaFactory](https://github.com/hiyouga/LlamaFactory))**:加 MiniCPM5-1B-Chat [#10558](https://github.com/hiyouga/LlamaFactory/pull/10558)、checkpoint resume 时 unsloth 加载回退 [#10551](https://github.com/hiyouga/LlamaFactory/pull/10551)、修 embedding 填充时新 token 放置 [#10547](https://github.com/hiyouga/LlamaFactory/pull/10547)。常规模型适配。

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
- **review-queue 企业化**:owner-aware 授权(experiment ACL + per-queue owner)[#23844](https://github.com/mlflow/mlflow/pull/23844);per-reviewer 答案 source-scoped 读取 + 重提覆盖 [#23846](https://github.com/mlflow/mlflow/pull/23846);并发加固(add/create 防竞态 [#23925](https://github.com/mlflow/mlflow/pull/23925)、编辑时锁行 [#23924](https://github.com/mlflow/mlflow/pull/23924));`ListReviewQueues` 加 item_id 过滤 [#23931](https://github.com/mlflow/mlflow/pull/23931);完成 focused review 至少答一题 [#23923](https://github.com/mlflow/mlflow/pull/23923)。
- **GenAI 评估/Agent**:加 `MLFLOW_GENAI_JUDGE_DEFAULT_MODEL` 环境变量 [#23860](https://github.com/mlflow/mlflow/pull/23860)、`mlflow skills view/list` CLI [#23907](https://github.com/mlflow/mlflow/pull/23907)、支持 RETRIEVER chunk 内容字段 [#23867](https://github.com/mlflow/mlflow/pull/23867)、保留 OTLP trace 的 OTel resource 属性 [#23829](https://github.com/mlflow/mlflow/pull/23829)。
- **启示**:上期是"上线 review-queue",本周是"把它做成可多人协作的企业能力"——ACL、per-reviewer、并发锁,这套人审数据结构与权限模型可直接借鉴到我们的模型评估闭环。

### Registry → kubeflow/hub
- **可调度元数据接入真实 API**:把 cold-start / vRAM / container size 过滤接到真实 catalog API [#2815](https://github.com/kubeflow/hub/pull/2815);cold-start artifact 名按 modelID 去重 [#2818](https://github.com/kubeflow/hub/pull/2818);新增 cold-start & vRAM 数据类型 [#2812](https://github.com/kubeflow/hub/pull/2812);加 catalog 插件脚手架 skill chain [#2794](https://github.com/kubeflow/hub/pull/2794)、CSV 导出器 [#2784](https://github.com/kubeflow/hub/pull/2784)。
- **启示**:上期这些字段还在定义,本周已接到可过滤的真实 API——模型目录正从"展示元数据"变成"按 vRAM/冷启动筛选可部署模型"的调度输入,我们的目录该补齐同款可过滤字段。

### Feast
- **新增 Flink 计算引擎**:加 Apache Flink compute engine [#6476](https://github.com/feast-dev/feast/pull/6476) + Flink 检索兼容文档。补齐流式特征计算。
- 上期覆盖的 Data Quality Monitoring [#6202](https://github.com/feast-dev/feast/pull/6202)、FeatureStore CRD DRA 字段、远程 registry mTLS [#6474](https://github.com/feast-dev/feast/pull/6474)、UI CRUD [#6412](https://github.com/feast-dev/feast/pull/6412) 仍在本窗口内;另修 milvus VARCHAR max_length 可配置(去掉硬编码 512)。
- **启示**:Flink 引擎落地说明 Feast 在补实时特征管线,配合上期的 DRA + mTLS,Feature Store 的"实时 + 企业合规"两条线同时推进。

## LLM 评估 & 安全
- **lm-evaluation-harness**:本周 0 提交,最新 [v0.4.12](https://github.com/EleutherAI/lm-evaluation-harness/releases/tag/v0.4.12)(2026-05-11)。**无重大更新**。
- **garak(NVIDIA)**:发 [v0.15.1](https://github.com/NVIDIA/garak/releases/tag/v0.15.1)(06-05);新增原生 Anthropic generator [#1809](https://github.com/NVIDIA/garak/pull/1809)(可直接红队 Claude 模型)、修缺失时下载 wordnet 词库 [#1820](https://github.com/NVIDIA/garak/pull/1820)、补 glitch/snowball/ansiescape 探针单测。
- **ogx(原 meta-llama/llama-stack)**:发首个 1.x [v1.1.0](https://github.com/ogx-ai/ogx/releases/tag/v1.1.0)(06-11);把 Skills API 写进 README/ARCHITECTURE/provider 文档 [#6087](https://github.com/ogx-ai/ogx/pull/6087);上期覆盖的 builtin Skills provider [#6078](https://github.com/ogx-ai/ogx/pull/6078)、Anthropic SDK 兼容(ping/error 流事件 [#6007](https://github.com/ogx-ai/ogx/pull/6007)、disable_parallel_tool_use/pause_turn [#5975](https://github.com/ogx-ai/ogx/pull/5975))、`ogx connect codex` [#5896](https://github.com/ogx-ai/ogx/pull/5896) 仍在窗口内。
- **横向信号——Anthropic API 兼容成生态标配**:本周 vLLM 修 Anthropic tool_use、garak 加原生 Anthropic generator、ogx 续做 Anthropic SDK 兼容。推理/评估/应用三层都在对齐 Anthropic(及 OpenAI Responses)接口,我们的推理平台应评估是否原生暴露兼容端点。

## 值得跟进
- [ ] 紧盯 **KServe v0.19.0** 发版与 llmisvc 三件新能力:LoRA 亲和调度 [#5655](https://github.com/kserve/kserve/pull/5655)、vLLM 一等 runtime [#4769](https://github.com/kserve/kserve/pull/4769)、platform hooks [#5617](https://github.com/kserve/kserve/pull/5617),逐条比对自家 LLM 推理服务 CRD。
- [ ] 评估**分离式推理控制面上移**:Ray Serve.llm 把 P/D 交给 KV-connector 后端 [#63950](https://github.com/ray-project/ray/pull/63950),判断我们做 P/D 是否对齐 KV-connector 抽象。
- [ ] 复盘 **vLLM 三连安全修复**(非有限采样参数 [#45116](https://github.com/vllm-project/vllm/pull/45116)、GGUF int32 截断 [#44971](https://github.com/vllm-project/vllm/pull/44971)、错误脱敏 [#45119](https://github.com/vllm-project/vllm/pull/45119)),在入口补采样参数与权重文件校验。
- [ ] 跟进**通用引擎扩散化**(vLLM DiffusionGemma / SGLang Ideogram4 / TRT-LLM VisualGen),判断调度与计量是否需支持图像生成负载。
- [ ] 借鉴 **MLflow review-queue 企业化**(ACL + per-reviewer + 并发锁 [#23844](https://github.com/mlflow/mlflow/pull/23844))与 **kubeflow/hub 可过滤调度元数据** [#2815](https://github.com/kubeflow/hub/pull/2815),补齐自家评估闭环与模型目录。
- [ ] 评估**原生 Anthropic / OpenAI Responses 兼容端点**是否纳入我们推理平台路线(vLLM / garak / ogx 三层都在对齐)。
