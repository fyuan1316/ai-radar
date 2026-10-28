# AI 推理 & MLOps 生态周报 2026-10-28

窗口:2026-10-21 ~ 2026-10-28(过去 7 天)。版本 bump / dependabot / CI / 纯文档修复已过滤。
说明:本期与 10-23 期窗口重叠约 5 天。上期已详述的版本(TensorRT-LLM v1.4.0rc1、Ray 2.58.1、Kubeflow Hub v0.3.18、MLflow v3.17.2、Ollama v0.40.9 的 d3)不再重复,**只写 10-23 以来的增量信号**,主要来自无新 release 仓库的主线 commit。

## 摘要(5 条以内)

1. **vLLM 与 SGLang 同时在建 Rust 前端/服务,并向 Python 实现对齐**:vLLM 本周一口气补了一批 "Rust Frontend" 的 Python parity 提交——导出 `vllm:engine_sleep_state` / `num_requests_kv_fetch_by_stage` 指标(#63959/#63962)、缺失 LoRA 路径返 404(#63961)、接受 list 形式 chat template(#63963)、拒绝超 `max_model_len` 的 max_tokens(#63964)、识别 Lark 语法(#63709);SGLang 侧 rust_server 支持 `--sidecar` 每节点跑一次(#46635)、在 scheduler abort 时像 Python 一样终止原生 `/generate` 流(#46513)。两大引擎的接入/网关层正并行用 Rust 重写——我们产品的推理网关若贴着上游走,要预判 Rust runtime 的部署与可观测口径。 https://github.com/vllm-project/vllm/pull/63962
2. **Ray 把"集群认证"推成企业部署基线(安全硬化)**:`ray start --head` 现在会为 ray.init() 与测试头节点创建 auth token 并**要求**认证(#67258);HTTP server 在禁用认证时拒绝 auth header、并拒绝在 K8s token auth 下跑 disabled 模式(#67150);runtime env 变量在报错里脱敏(#67358);文档补齐 token auth 开启下的 CloudWatch Prometheus 抓取(#67313)。多租户/企业场景里 Ray 从"默认无认证"转向"默认需认证",对标我们产品的租户隔离与接入安全值得跟。 https://github.com/ray-project/ray/pull/67258
3. **Kubeflow Trainer 引入 OptimizationJob(KEP-3562),并补调度器对接**:新增 OptimizationJob alpha feature gate(#4331)+ 名称/参数校验(#4155/#4062),把超参优化做成一等 Job;同时允许 per-TrainJob `schedulerName` override(#4265,便于接 Volcano/Kueue)、支持多切片 TPU 的 Job Replicas(#4250)。注意一处破坏性变更:MPI launcher/node 现在会被设成 TrainJob image(#4301)。 https://github.com/kubeflow/trainer/pull/4331
4. **"决策/判别模型"原语持续跨端跨厂扩散**:Ollama v0.40.12 上架 Liquid AI 的 `d1`(2B,基于 LFM3,文本+图像判别,d1-omni 加音频)——继上期移植 vLLM Semantic Router 的 d3 之后,**第二家厂商的决策模型**进入桌面侧;llama-stack 同时开启 `vllm-systemone` 集成 CI lane(#6880)。推理网关层的"分类/是非/打分"判别位已成跨生态既定方向。 https://github.com/ollama/ollama/releases/tag/v0.40.12
5. **KServe llmisvc 继续企业化收尾**:暴露 LLMInferenceService 副本与 condition 指标(#6177)、识别 KEDA External/PodMetric 目标类型做自动扩缩(#6185)、重写旧版 InferencePool 的 `--pool-group`(#6490,贴 Gateway API Inference Extension)。主线功能上期已覆盖,本周是多租/自动扩缩/网关细节的加固。 https://github.com/kserve/kserve/pull/6177

---

## 推理引擎动态

### vLLM
本周无新 release(仍为 v0.32.0),但主线很活跃,几条对产品清单有意义:
- **Rust 前端对齐 Python**(见摘要 1):一整批 "Rust Frontend" 提交把指标导出、LoRA 404、chat template、grammar 检测、max_tokens 校验、server 上报 prompt_tokens 等逐项补齐(#63959~#63964、#63709、#59694)。信号:vLLM 的 serving 前端正在 Rust 化,Python 版逐步成为"参考实现"。 https://github.com/vllm-project/vllm/pull/63964
- **安全**:修复校验错误路径 sanitizer 的 ReDoS(#52120);修复 Anthropic inline-system 探测导致启动崩溃(#64020)——Anthropic API 兼容面继续补。 https://github.com/vllm-project/vllm/pull/52120
- **弹性/RL**:新增 opt-in 的多 worker CUDA checkpoint sleep(#64186);NCCL 权重传输支持 per-update source ranks(#62557)——sleep/wakeup + RL 在线权重同步在深化。 https://github.com/vllm-project/vllm/pull/64186
- **默认值变更**:best-effort NUMA 绑定默认开启(#61258)——升级后注意拓扑绑定行为变化。 https://github.com/vllm-project/vllm/pull/61258
- KV offload / Mooncake / KVCR 路径多项优化(#62478/#63889/#60469),延续上期 KV 分层主线。

### SGLang
本周无新 release(仍为 v0.5.22),主线以 DeepSeek-v4.1(Engram/MoE)性能为主,挑对产品有用的:
- **异构加速卡**:新增 Ascend NPU 的 MoE prefill/decode Ops 后端(#46282)——国产 NPU 在上游推理引擎继续一等化,接上期 AMD/壁仞线。 https://github.com/sgl-project/sglang/pull/46282
- **Rust server 对齐**(见摘要 1):`--sidecar` 每节点运行一次(#46635)、scheduler abort 时终止原生 `/generate` 流(#46513)、info 端点上报实际 `--tokenizer-path`(#46879)。 https://github.com/sgl-project/sglang/pull/46635
- **NVIDIA megakernels**:Qwen3.5 的 megakernel 插件绑定与 EAGLE 入口接线(#45266)——投机解码 + megakernel 路径成形。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:本周无新 rc(仍为上期已详述的 v1.4.0rc1,KV cache V2 默认 + Mooncake 整合),无增量。
- **TGI**:仍为 archived 状态(最后 push 2026-03-21),窗口内 0 提交,属正常停维护。
- **Ollama**:窗口内连发 v0.40.10~v0.40.12:
  - v0.40.12 新增 Liquid AI `LFM3` 家族(1.7B,256K 上下文,含 vl/audio/omni)与 **`d1` 2B 决策模型**(第二家决策模型厂商,见摘要 4);另有 Apple 侧 Gemma 4 prompt 加速、MLX 上 DFlash2 投机解码。 https://github.com/ollama/ollama/releases/tag/v0.40.12
  - v0.40.11 落地 **macOS 语音/TTS**,通过 OpenAI 兼容 `/v1/audio/speech` 流式输出,并正式上架 d3 决策模型族。 https://github.com/ollama/ollama/releases/tag/v0.40.11
  - v0.40.10 新增 NVIDIA Nemotron 3.5 Bolt E4B(Gemma 4 基座 VLM,含 DFlash draft 投机解码)。 https://github.com/ollama/ollama/releases/tag/v0.40.10

## 模型服务 & 编排

### KServe 上游
无新 release。本周 llmisvc 以企业化加固为主(见摘要 5):副本/condition 指标(#6177)、KEDA External/PodMetric 目标(#6185)、`--pool-group` 重写旧 InferencePool(#6490);另 helm 支持对可选资源显式 `enabled: false`(#6441)、KernelCache 注入端到端测试(#6362)。 https://github.com/kserve/kserve/pull/6490

### Ray
无新 release(2.58.1 上期已述,2.59.0 perf 指标在备货 #66496)。本周两条主线:
- **认证/安全硬化**(见摘要 2):cluster auth token 成为 `ray start --head` 必需(#67258/#67150),runtime env 脱敏(#67358)。 https://github.com/ray-project/ray/pull/67150
- **沙箱隔离**:core sandbox 用 runsc(gVisor)支持 checkpoint/restore、pause/resume(#66471/#66469)——多租户强隔离方向,值得关注。 https://github.com/ray-project/ray/pull/66471
- Serve/LLM:升级内置 vLLM 到 0.32.0(#67197);修复 PrefixCacheAffinityRouter 的 LoRA 路由(#66660);Train V2 回退了 reservation pinning(#67337)。

### KubeAI(原 lingo)
本周无实质提交,无重大更新。

## 训练 & 微调
- **Kubeflow Trainer(原 training-operator)**:见摘要 3——OptimizationJob/KEP-3562(#4331)、per-TrainJob schedulerName(#4265)、多切片 TPU Replicas(#4250);破坏性变更 MPI launcher/node image 设置(#4301)。 https://github.com/kubeflow/trainer/pull/4265
- **LLaMA-Factory**:本周无实质提交,无重大更新。

## 模型生命周期(MLflow / Registry / Feast)
- **Kubeflow Hub(原 model-registry)/ MLflow**:本周无新增量(Hub v0.3.18、MLflow v3.17.2 均在上期窗口,已详述)。
- **Feast**:仅 Go feature server 镜像改两阶段构建,无产品级变化,无重大更新。

## LLM 评估 & 安全
- **garak**:CAS(越狱/攻击面)探针重构——把探针 intent 抽成可复用 stub(#2358)、从 `apikey.GetKey` 加 S009 凭证类 intent stub、保留 S008 终端请求全变体;并把 summary 适用范围扩到"所有 LLM 驱动的应用"(#2346)。红队探针正从"模型"扩到"LLM 应用凭证面"。 https://github.com/NVIDIA/garak/pull/2358
- **llama-stack**:一批 tool-call 健壮性修复(畸形 tool-call 参数回喂模型而非崩溃 #6839、非对象 JSON 回退空参数 #6864、tool_choice=none 时清 parallel_tool_calls #6903)、file_search 按向量库维度 embedding(#6892)、开启 vllm-systemone CI lane(#6880)。 https://github.com/meta-llama/llama-stack/pull/6839
- **lm-evaluation-harness**:本周无实质提交,无重大更新。

## 值得跟进
- [ ] **推理前端 Rust 化**:vLLM / SGLang 双引擎的 Rust frontend/server 若成主线,评估我们推理网关的部署形态、指标口径与 Python 版行为差异。
- [ ] **Ray 认证基线上移**:确认我们托管 Ray 的方案在"默认需 auth token"下是否需要适配(尤其 `ray start --head` 与 K8s token auth 组合)。
- [ ] **Ray gVisor 沙箱**:runsc checkpoint/restore 是否可借鉴到多租户训练/推理的强隔离与可迁移性。
- [ ] **Kubeflow OptimizationJob(KEP-3562)**:跟踪其 API 稳定度,评估是否纳入我们训练产品的 HPO 能力。
- [ ] **决策模型原语**:d3/d1/systemone 跨引擎跨厂扩散,推理网关预留"判别/路由"接入位。
