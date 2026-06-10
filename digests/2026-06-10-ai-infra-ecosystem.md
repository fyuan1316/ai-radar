# AI 推理 & MLOps 生态周报 2026-06-10

> 扫描窗口:2026-06-03 ~ 2026-06-10。每条带源链接,版本 bump / dependabot / CI 噪音已过滤。
> 注:本周扫描中发现 4 个仓库已重命名/迁移(详见各节),旧 slug 仍 301 重定向但建议改用新名。

## 摘要(5 条以内)

1. **vLLM 的 Rust 前端正在成形**:本周继续补 API key 鉴权、`/tokenize` `/detokenize`、`/pause` `/resume` `/is_paused`、结构化输出后端等端点;同时发 v0.22.1(DeepSeek-V4 修复、Mellum v2、AMD Zen zentorch)并修了两个安全漏洞(音频解压炸弹 DoS、图片 EXIF/tRNS 处理)。推理网关层从 Python 往 Rust 迁是值得跟的架构信号。
2. **生态密集重命名/重组**:Meta `llama-stack` → `ogx-ai/ogx`(转向 Skills + OpenAI Responses / Anthropic SDK 兼容的应用层);`substratusai/lingo` → `kubeai-project/kubeai`;`kubeflow/model-registry` → `kubeflow/hub`(转向 Model Catalog);`kubeflow/training-operator` → `kubeflow/trainer`。
3. **KServe 主线几乎全压在 `LLMInferenceService`(llmisvc)**:本周提交集中在 TLS 接线、多网卡 NVSHMEM/UCX 设备导出(分布式/分离式推理),v0.19.0-rc0 已出。这正是我们做 LLM 推理产品要对齐的上游 CRD。
4. **推理引擎集体进军「视觉/扩散生成」**:SGLang 新增 diffusion 子系统(LTX-2 VAE、realtime control),TRT-LLM 注册 FLUX / Wan2.2-T2V / Cosmos3。基础设施侧要开始考虑非 LLM 的生成式负载形态。
5. **MLOps 工具链转向 GenAI 运维**:MLflow 上 review-queue(人审队列)+ `mlflow agent setup`(对接 Claude Code/Codex);Feast 加 Data Quality Monitoring、FeatureStore CRD 的 DRA 字段、mTLS。与此同时 HF TGI、lm-evaluation-harness、kubeai 本周基本静默。

## 推理引擎动态

### vLLM
- 发布 [v0.22.1](https://github.com/vllm-project/vllm/releases/tag/v0.22.1):补 JetBrains Mellum v2(MoE 代码模型),修 DeepSeek-V4 初始化(CUTLASS `fmin` 兼容)、多节点 Ray data-parallel 死锁、AMD Zen CPU 走 zentorch 量化内核。
- **Rust 前端持续补能力**:API key 鉴权 [#44321](https://github.com/vllm-project/vllm/pull/44321)、`/tokenize` `/detokenize` [#44222](https://github.com/vllm-project/vllm/pull/44222)、`/pause` `/resume` `/is_paused` [#44499](https://github.com/vllm-project/vllm/pull/44499)、结构化输出后端默认值修复 [#44729](https://github.com/vllm-project/vllm/pull/44729)、Kimi K2 tool-call ID [#44901](https://github.com/vllm-project/vllm/pull/44901)。
- **安全**:修音频解压炸弹导致的 speech-to-text 端点 DoS [#44970](https://github.com/vllm-project/vllm/pull/44970)、图片 EXIF 方向与 tRNS 透明度处理 [#44974](https://github.com/vllm-project/vllm/pull/44974)。
- **大规模 serving / 内核**:DeepEP v2 集成 [#41183](https://github.com/vllm-project/vllm/pull/41183)、KV Events 编码从 array 改 map [#42892](https://github.com/vllm-project/vllm/pull/42892)、移除 `P2pNcclConnector` [#44854](https://github.com/vllm-project/vllm/pull/44854)、Model Runner V2、Qwen3.5/Gemma4/Cohere2 适配。
- **启示**:Rust 前端把鉴权、限流、暂停/恢复、tokenize 这些「网关职责」内置到引擎,我们若在 vLLM 前自建网关层要重新评估边界——很多能力上游正在收编。安全两连修也提醒:多模态输入(音频/图片)是新的攻击面,产品侧应在入口做体量/格式校验。

### SGLang
- **新增 diffusion 子系统**:realtime control state/adapters 重构、LTX-2 VAE 走 channels_last_3d 降显存峰值 [#27431](https://github.com/sgl-project/sglang/pull/27431)、Mistral3 diffusion 文本编码器 TP 支持 [#25950](https://github.com/sgl-project/sglang/pull/25950)。
- **sgl-router(实验)**:加 request/TTFT/worker 指标 + Grafana 面板 [#27591](https://github.com/sgl-project/sglang/pull/27591)、`/flush_cache` 端点 [#27612](https://github.com/sgl-project/sglang/pull/27612)。
- CUDA Graph Runner/Backend 大重构 [#23906](https://github.com/sgl-project/sglang/pull/23906)、spec v2(移除 v1 worker)、MSCCL++ 集成 [#22734](https://github.com/sgl-project/sglang/pull/22734)、NPU 适配(确定性推理、MiMo-V2-Flash)。
- **启示**:sgl-router 在补 K8s 友好的可观测性(Prometheus/Grafana),是 vLLM 之外又一个「自带路由层」的引擎,选型时值得和 KServe llmisvc 的网关方案对照。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM** [v1.3.0rc18](https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc18):KVCacheManagerV2 加磁盘缓存配置 [#14845](https://github.com/NVIDIA/TensorRT-LLM/pull/14845) 与 `adjust()`;KV cache connector 暴露 block-hash 链 [#14806](https://github.com/NVIDIA/TensorRT-LLM/pull/14806)(利于跨实例 KV 复用/分离式);加 prompt cache / spec decoding / batch 占用 Prometheus 指标 [#12636](https://github.com/NVIDIA/TensorRT-LLM/pull/12636);视觉生成 FLUX/Wan2.2-T2V/Cosmos3 注册;NIXL 升 v1.0.1、UCX 1.21。
- **TGI(HuggingFace)**:**无重大更新**——最新 release 仍是 2025-12 的 v3.3.7,本周 0 提交。HF 官方推理栈事实上进入维护态,作为长期依赖需评估风险。
- **Ollama**:连发 v0.30.3~v0.30.7;MLX 后端补 MTP 投机解码(cache 快照驱动)、gated-delta 内核、nvfp4 embedding;新增 gemma4-12b 支持;并在做 "hermes-desktop" / "pi" 桌面启动器。偏端侧,但 MLX 投机解码值得留意 Apple Silicon 推理路线。

## 模型服务 & 编排

### KServe 上游
- 本周提交几乎全在 **`llmisvc`(LLMInferenceService)**:接线 `enableLLMInferenceServiceTLS` [#5525](https://github.com/kserve/kserve/pull/5525)、在 `NVSHMEM_HCA_LIST`/`UCX_NET_DEVICES` 导出全部 HCA 网卡 [#5603](https://github.com/kserve/kserve/pull/5603)(多网卡 RDMA,面向分布式/分离式推理)。
- 最新 [v0.19.0-rc0](https://github.com/kserve/kserve/releases/tag/v0.19.0-rc0)(2026-05-28,窗口外但相关)。
- **启示**:KServe 把 LLM 推理独立成一类 CRD 并往多网卡 RDMA、TLS 等企业能力上堆,这是我们对标 OAI 推理服务时最该贴的上游主线;建议专门拉一条 llmisvc 的能力跟踪。

### Ray
- **Serve 代理换 HAProxy**:出现 `ray-haproxy` 二进制解析与 `RAY_SERVE_HAPROXY_BINARY_PATH` [#63829](https://github.com/ray-project/ray/pull/63829),并有 HAProxy 稳定性/直连 ingress 端口隔离系列 [#63920](https://github.com/ray-project/ray/pull/63920)。Serve 入口从 Python proxy 转向 HAProxy 是架构级变化。
- Serve LLM 遥测/Grafana 面板修复 [#63893](https://github.com/ray-project/ray/pull/63893)、[#63782](https://github.com/ray-project/ray/pull/63782)。
- KubeRay 自动伸缩加 `noDriverTimeoutSeconds` 终止集群 [#63465](https://github.com/ray-project/ray/pull/63465)。
- Ray Data 支持一个集群内多 dataset(按 subcluster label 切资源)[#63375](https://github.com/ray-project/ray/pull/63375)、移除 `ExecutionPlan` [#63662](https://github.com/ray-project/ray/pull/63662)。
- **启示**:Ray Serve 的 HAProxy 化和 vLLM Rust 前端是同一趋势——推理入口层在去 Python、上专用高性能代理。我们若用 Ray Serve 托管,需重新评估自定义 proxy/中间件的兼容性。

### kubeai(原 substratusai/lingo)
- 仓库已迁至 [kubeai-project/kubeai](https://github.com/kubeai-project/kubeai);本周 0 提交,最新 release v0.23.2(2026-03-31)。**无重大更新**,节奏明显放缓。

## 训练 & 微调
- **kubeflow/trainer(原 training-operator)**:已重命名为 [kubeflow/trainer](https://github.com/kubeflow/trainer)(Trainer v2 路线);本周仅 manager client QPS/burst 修复 [#3432](https://github.com/kubeflow/trainer/pull/3432) 等少量提交,**无重大功能更新**。
- **LLaMA-Factory(原 hiyouga/LLaMA-Factory → [hiyouga/LlamaFactory](https://github.com/hiyouga/LlamaFactory))**:加 gemma-4-12B-it [#10549](https://github.com/hiyouga/LlamaFactory/pull/10549)、为 NPU 打 GDN patch [#10504](https://github.com/hiyouga/LlamaFactory/pull/10504)、修嵌入填充时新 token embedding 放置 [#10547](https://github.com/hiyouga/LlamaFactory/pull/10547)。常规模型适配。

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
- 发 [v3.13.0](https://github.com/mlflow/mlflow/releases/tag/v3.13.0)(2026-06-01)。
- **GenAI 人审/评估**:落地 review-queue(proto/REST/SDK [#23801](https://github.com/mlflow/mlflow/pull/23801)、OSS 数据层 [#23799](https://github.com/mlflow/mlflow/pull/23799)、Review tab UI [#23804](https://github.com/mlflow/mlflow/pull/23804));label schemas 系列;UI 触发评估 `POST /genai/evaluate/invoke` [#23779](https://github.com/mlflow/mlflow/pull/23779)。
- **对接编码 Agent**:新增 `mlflow agent setup` CLI [#23595](https://github.com/mlflow/mlflow/pull/23595),支持安装 Claude Code/Codex/OpenCode skills、Databricks 后端。
- **启示**:MLflow 正从「实验追踪」扩成「GenAI 评估 + 人工标注 + Agent 运维」平台。我们做模型生命周期时,human-in-the-loop 的 review-queue 与 label schema 是可借鉴的数据结构。

### Registry → kubeflow/hub
- `kubeflow/model-registry` 已重命名为 [kubeflow/hub](https://github.com/kubeflow/hub),重心转向 **Model Catalog**:custom prop 加 cold-start & vRAM 指标 [#2812](https://github.com/kubeflow/hub/pull/2812)、security-metrics 枚举 [#2777](https://github.com/kubeflow/hub/pull/2777)、hardware_tag 标签 [#2758](https://github.com/kubeflow/hub/pull/2758)、catalog 插件代码生成器 [#2762](https://github.com/kubeflow/hub/pull/2762)、CSV 导出器 [#2784](https://github.com/kubeflow/hub/pull/2784)。
- **启示**:上游把「模型注册中心」升级成带冷启动/显存/安全元数据的目录(Hub),这些字段直接服务于调度与选型——我们的模型目录该补齐 vRAM、cold-start、安全这类可调度元数据。

### Feast
- **数据质量监控**:原生计算 + 多后端 + REST/CLI [#6202](https://github.com/feast-dev/feast/pull/6202)。
- **K8s/企业化**:FeatureStore CRD 加 DRA(Dynamic Resource Allocation)字段、远程 registry gRPC 加 mTLS [#6474](https://github.com/feast-dev/feast/pull/6474)、离线存储运维指标 + SOX 合规指标 [#6340](https://github.com/feast-dev/feast/pull/6340)、首类 LabelView [#6292](https://github.com/feast-dev/feast/pull/6292)、UI 支持 entity/数据源/特征视图 CRUD [#6412](https://github.com/feast-dev/feast/pull/6412)。
- **启示**:Feast 的 CRD 引入 DRA 字段,说明 Feature Store 也在抢 K8s 设备调度通道;mTLS + SOX 指标是冲企业合规去的,值得对照我们自家的多租户/合规能力。

## LLM 评估 & 安全
- **lm-evaluation-harness**:本周 0 提交,最新 v0.4.12(2026-05-11)。**无重大更新**。
- **garak(NVIDIA)**:发 [v0.15.1](https://github.com/NVIDIA/garak/releases/tag/v0.15.1),仅修 NVMultimodal 多轮 prompt 保留 [#1837](https://github.com/NVIDIA/garak/pull/1837)。小补丁。
- **llama-stack → ogx-ai/ogx**:Meta 的 llama-stack 已迁至 [ogx-ai/ogx](https://github.com/ogx-ai/ogx) 并明显转向「Agent 应用栈」:内置 Skills provider(manifest 解析 + zip 校验)[#6078](https://github.com/ogx-ai/ogx/pull/6078) + FastAPI 路由 [#6066](https://github.com/ogx-ai/ogx/pull/6066);OpenAI Responses / OpenResponses 一致性 + WebSocket 传输 [#6054](https://github.com/ogx-ai/ogx/pull/6054);Anthropic SDK 兼容(ping/error 流事件、`disable_parallel_tool_use`、`pause_turn`)[#5975](https://github.com/ogx-ai/ogx/pull/5975);`ogx connect codex` CLI [#5896](https://github.com/ogx-ai/ogx/pull/5896);guardrails 改 fail-closed 语义 [#6026](https://github.com/ogx-ai/ogx/pull/6026)。
- **启示**:llama-stack 改名 ogx 并重押 Skills + 多家 API(OpenAI Responses / Anthropic)兼容,本质是要做「跨模型的 Agent 运行时」。这是应用层标准之争,我们的推理平台应关注是否要原生暴露 Responses / Anthropic 兼容端点。

## 值得跟进
- [ ] 跟一条 **KServe llmisvc** 能力线:读 [#5603](https://github.com/kserve/kserve/pull/5603) 多网卡导出 + TLS 接线,评估对标我们 LLM 推理服务 CRD 的差距。
- [ ] 评估 **vLLM Rust 前端**收编网关能力(鉴权/限流/pause)对我们自建推理网关的影响:[#44321](https://github.com/vllm-project/vllm/pull/44321)、[#44499](https://github.com/vllm-project/vllm/pull/44499)。
- [ ] 复盘两个 **vLLM 多模态安全修复**([#44970](https://github.com/vllm-project/vllm/pull/44970)、[#44974](https://github.com/vllm-project/vllm/pull/44974)),在我们入口加音频/图片体量与格式校验。
- [ ] 跟 **Ray Serve HAProxy 化** [#63829](https://github.com/ray-project/ray/pull/63829),确认对自定义 proxy/中间件的兼容性。
- [ ] 调研 **生成式视觉负载**(SGLang diffusion / TRT-LLM FLUX·Wan2.2),判断我们调度与计量是否需要支持非 LLM 生成模型。
- [ ] 借鉴 **kubeflow/hub 的可调度模型元数据**(vRAM / cold-start / security-metrics)与 **MLflow review-queue** 的人审数据结构,补齐自家模型目录与评估闭环。
