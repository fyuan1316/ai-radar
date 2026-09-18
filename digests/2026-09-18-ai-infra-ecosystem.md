# AI 推理 & MLOps 生态周报 2026-09-18

> 窗口:2026-09-11 ~ 2026-09-18(过去 7 天)。已过滤版本 bump / dependabot / CI / 纯 e2e 修复等噪音,只留对"云原生 AI 基础设施产品"有借鉴或威胁的变化。

## 摘要(5 条)

1. **KServe v0.21.0-rc0 切版**,`LLMInferenceService`(llmisvc)本周密集加固:新增 **DRA(resourceClaims)GPU 分配**、**金丝雀发布(RawDeployment HTTPRoute 流量切分)**、集群 TLS 安全 profile 集成、Controller ClusterRole 收敛,并把 tokenizer sidecar 换成 vLLM render deployment。是本周对我们最直接对标的信号。https://github.com/kserve/kserve/releases/tag/v0.21.0-rc0
2. **vLLM v0.29.0**:Model Runner V2 成为全模型默认(MRV1 计划 v0.32 移除),新增 `--max-num-queued-reqs/-tokens` 准入控制、`sharded_rdt` RL 权重同步 P2P 后端;`python -m vllm.entrypoints.openai.api_server` 被弃用,统一用 `vllm serve`。https://github.com/vllm-project/vllm/releases/tag/v0.29.0
3. **llama-stack v1.4.0** 大幅补企业能力:`local_api_key` 认证 provider、结构化日志脱敏、`upstream_header` 可信代理校验、Postgres SSL + 多租户列限定、可关闭 chat 持久化、一批 CVE 修复。仓库内部已改名 ogx(release 仍发在 meta-llama/llama-stack)。https://github.com/meta-llama/llama-stack/releases/tag/v1.4.0
4. **MLflow 3.16.0/3.16.1**:自然语言生成的"自定义 Trace 视图"(Assistant 驱动)、Span Links、AI Gateway 按用户预算策略;安全上默认 fail-closed 授权并**删除 basic_auth.ini 里内置的默认 admin 密码**(GHSA)。https://github.com/mlflow/mlflow/releases/tag/v3.16.0
5. **安全/合规两个信号**:garak v0.17.0 上线 **EU AI Act 风险映射**;Ray 把本地集群 **token 认证改为默认开启**。合规与"默认安全"正在成为上游标配。https://github.com/NVIDIA/garak/releases/tag/v0.17.0

---

## 推理引擎动态

### vLLM — v0.29.0(594 commits / 277 contributors)
- **Model Runner V2 全模型默认**,补齐 CUDA graph 显存 profiling 做 KV cache 自动定容、batch-sharded sampling(logits 显存降到 1/TP);MRV1 标记弃用,目标 v0.32 移除。https://github.com/vllm-project/vllm/releases/tag/v0.29.0
- **准入控制**:新增 `--max-num-queued-reqs` / `--max-num-queued-tokens`,可在网关/调度层做过载保护。
- **RL 权重同步**:`sharded_rdt` P2P 后端(每 worker 只拉自己 TP/EP 分片,走 NIXL 或 Ray Direct Transport)、rank-local IPC 权重更新——训推一体/在线 RL 场景值得关注。
- **破坏性**:`python -m vllm.entrypoints.openai.api_server` 弃用改 `vllm serve`;删 10 个旧模型架构;默认 CUDA 13.0。**启示**:我们若封装了 vLLM 启动命令,需检查是否还在用被弃用的 module 入口。

### SGLang — v0.5.19(786 PRs / 214 contributors)
- **DeepEP v2(ElasticBuffer)** `--moe-a2a-backend deepep_v2`:固定 buffer 尺寸,跨节点 decode 也能跑在 CUDA graph 下,大 MoE(DeepSeek-V3/V4、Qwen3-MoE FP8)性能与旧后端持平。
- **Beam search** 落地、**LayerNorm 序列并行** `--enable-layernorm-sp`(prefill 提速随 TP 增大)、默认 Blackwell MLA 后端支持 DCP(长上下文更抗压)。https://github.com/sgl-project/sglang/releases/tag/v0.5.19
- **启示**:vLLM 与 SGLang 都在往"大 MoE + 长上下文 + 跨节点 EP"深水区卷,我们的推理运行时选型/多引擎抽象需覆盖 EP/DCP 这类跨节点拓扑参数。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM** 仍在 v1.3.0 rc 滚动(本周 rc26→rc27):`trtllm-serve` **新增 Anthropic 兼容 Messages / token-counting / Message Batches API**、新增 LLM profiling 端点;**移除遗留 C++ runtime、batch-manager API 与旧两模型投机解码(均为 BREAKING)**。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc27
- **TGI**:仓库已 archived(最后 push 2026-03),窗口内 0 提交,视为停维护,无需再跟。
- **Ollama** v0.34.0~0.34.2:可在 **ChatGPT Desktop 里直接用 Ollama 本地模型**、OpenAI 兼容的 client 工具搜索与响应 compaction、Apple Silicon 结构化输出提速。https://github.com/ollama/ollama/releases/tag/v0.34.0

---

## 模型服务 & 编排

### KServe 上游 — v0.21.0-rc0(本周切版,重点)
围绕 `LLMInferenceService`(llmisvc)几乎重写了一轮编排语义,和我们的产品高度重叠:
- **DRA 支持**:ServingRuntime 新增 `resourceClaims`,对接 K8s Dynamic Resource Allocation 做 GPU 分配(#5828)。
- **金丝雀发布**:RawDeployment 下用 HTTPRoute 做流量切分 + canary 生命周期(#5912、#5833)。
- **安全**:集成集群 TLS 安全 profile(#5791)、硬化 controller-manager ClusterRole(#5785);agent 在 model spec 反序列化失败时不再 crash(#5700)。
- **架构解耦**:CRD 重构成可独立安装(#5843);把 UDS tokenizer sidecar 换成 vLLM render deployment(#5712);WVA 从 VA CRD 迁到**注解发现**(#5722);metrics/flag 向 llm-d 插件化迁移(#5877、#5930)。
- 新增 **agentic 工具调用**指南与样例(#5906)。
- 全部 PR:https://github.com/kserve/kserve/releases/tag/v0.21.0-rc0
- **启示**:DRA + 金丝雀 + TLS profile + 注解化发现,基本是我们模型服务层下一步该对齐的清单;尤其 DRA 落地方式(resourceClaims 直挂 ServingRuntime)值得直接参考。

### Ray(v2.58 后无新 release,90 commits)
- **[Core/Auth] 本地集群默认开启 token 认证**(#64755)——"默认安全"信号。https://github.com/ray-project/ray/commit
- **[serve]** gRPC proxy 支持 opt-in server reflection(#65854)、autoscaling 指标列式零拷贝摄取(#66070)。
- **[Data]** 大量收敛:shuffle v2 成默认(#66260)、Arrow 分区 join 换成 Polars streaming join(#66075)、弃用 RandomAccessDataset(#61287)。
- 链接:https://github.com/ray-project/ray/commits/master

### KubeAI / lingo
- 静默,窗口内 0 提交(近期整体不活跃)。无重大更新。

---

## 训练 & 微调
- **kubeflow/trainer(Trainer v2)**:窗口内无实质提交,无重大更新。
- **LLaMA-Factory**:仅一条 v1 文档更新(#10684),无重大更新。https://github.com/hiyouga/LLaMA-Factory/releases/tag/v0.9.5

---

## 模型生命周期(MLflow / Registry / Feast)

### MLflow — v3.16.0 + v3.16.1(patch)
- **自定义 Trace 视图**:用自然语言描述想要的视图,MLflow Assistant 直接生成、可按 experiment 保存复用;Trace explorer 全新改版并设为默认(列重排、自定义列、会话分组)。
- **Span Links**:首类 span 间关系(检索步、工具调用、下游 trace),UI 有专门 Links tab。
- **AI Gateway**:支持**按用户预算策略**(USER scope + principal,#24371);新增 K8s 认证(TS SDK)。
- **安全(3.16.1)**:默认 fail-closed 授权;**删除 basic_auth.ini 内置默认 admin 密码(GHSA-gq3w-7jj3-x7gr)**;修 S3 分片上传加密参数。https://github.com/mlflow/mlflow/releases/tag/v3.16.1
- **启示**:Trace/可观测 + Gateway 预算配额是 GenAI 平台化的方向;"Assistant 生成 UI 视图"是差异化交互点,可评估是否纳入我们平台的观测面板。

### kubeflow/model-registry(v0.3.16,13 commits)
- 本周主线是 **HuggingFace 模型 catalog 化**:阻止未授权的 gated 模型进 catalog(#3241)、移除私有 HF 部署阻断、preview 加 `hasGated`、对齐 MCP catalog 布局(#3239)、移除 HF token 临时 feature flag(#3205)。
- `GetInferenceServices`/`GetServeModels` 透传 `filterQuery`(#3208)。https://github.com/kubeflow/model-registry/commits/main
- **启示**:上游正把 Registry 往"带准入策略的 HF/技能/MCP catalog"演进,和我们的模型仓/目录能力直接对标。

### Feast(v0.66 后 9 commits)
- **MCP feature server 结构化审计日志**(#6456)、**FeatureService 版本锁定**(在线+离线,#6718)、UI 暴露运行时版本(#6843)。https://github.com/feast-dev/feast/commits/master

---

## LLM 评估 & 安全

### EleutherAI/lm-evaluation-harness(v0.4.13 后 7 commits)
- 增量维护为主:新增 MedMCQA/MedQA 的 zero-shot CoT 变体(#4081)、修 bbh/basqueglue、CLI 参数解析修复。无架构级变化。https://github.com/EleutherAI/lm-evaluation-harness/commits/main

### NVIDIA/garak — v0.17.0
- **EU AI Act 映射**:用参考标签把 probe 结果按 EU AI Act 各风险类别归组(#2094)——**合规可追溯**能力,对做企业级安全合规很有参考。
- 大量 agent_breaker / packagehallucination 检测器加固、Ollama 生成参数与鉴权透传;drop Py3.10 加 Py3.13。https://github.com/NVIDIA/garak/releases/tag/v0.17.0

### meta-llama/llama-stack — v1.4.0(安全/多租户重头)
- `local_api_key` 认证 provider(带属性 + 启动期校验,#6400)、**结构化日志敏感信息脱敏**(#6433)、`upstream_header` provider 做**可信代理校验**(#6436)。
- 多租户/持久化:Postgres `ssl_mode`/`ca_cert_path`(#6196)、Postgres upsert 限定 tenant 列(#6509)、可**关闭 chat completions 持久化**(#6412);一批 CVE 修复(#6488)。
- Responses API 的 `truncation=auto` 反应式截断(#6410);Milvus 切 AsyncMilvusClient。https://github.com/meta-llama/llama-stack/releases/tag/v1.4.0
- **注意**:仓库内部已改名 ogx(PR 链接指向 ogx-ai/ogx),release 仍发在 meta-llama/llama-stack。

---

## 值得跟进
- [ ] **KServe DRA(resourceClaims)落地方式**:研究其把 DRA 直挂 ServingRuntime 的设计,评估我们模型服务层如何对齐 K8s DRA GPU 分配。https://github.com/kserve/kserve/pull/5828
- [ ] **KServe llmisvc 金丝雀发布**:RawDeployment + HTTPRoute 流量切分模型,对比我们现有灰度方案。https://github.com/kserve/kserve/pull/5912
- [ ] **vLLM 准入控制新 flag**(`--max-num-queued-reqs/-tokens`):是否在我们网关层暴露/默认配置以做过载保护。
- [ ] **MLflow AI Gateway 按用户预算配额**:GenAI 平台成本治理参考。https://github.com/mlflow/mlflow/pull/24371
- [ ] **model-registry 的 HF/MCP catalog + gated 准入**:对标我们模型目录的准入策略。https://github.com/kubeflow/model-registry/pull/3241
- [ ] **合规基线**:garak EU AI Act 映射 + MLflow 默认 fail-closed/删默认密码 + Ray 默认 token 认证,纳入我们"默认安全 + 合规可追溯"的基线清单。
