# AI 推理 & MLOps 生态周报 2026-09-16

窗口:2026-09-09 ~ 2026-09-16。仅筛与"云原生 AI 基础设施产品"相关的实质变化,版本 bump / dependabot / CI 修复已略。

## 摘要(5 条以内)

1. **KServe v0.21.0-rc0** 把 SGLang 纳为一等推理运行时,并给 InferenceService 注入 OTEL 变量、暴露 OCI 模型支持 —— 多运行时 + 可观测性 + OCI 模型分发同步推进,和我们产品的 runtime 抽象直接对标。
2. **SGLang** 本周 Router 大幅工程化:存储分层感知的 KV 缓存路由(KV storage-tier)、`--worker-queue-limit` 排队保护、按 worker 解析线协议 —— 推理网关正在长成"带 KV 感知的 L7 调度器"。
3. **TensorRT-LLM v1.3.0rc26** 默认启用 KVCacheManagerV2(Llama/Llama4/Nemotron 多模态),并 BREAKING 删除 TRT 遗留代码与双模型投机路径 —— NVIDIA 推理栈彻底转向纯 PyTorch + 统一 KV 管理。
4. **Ray Serve** 把自定义自动扩缩策略从 experimental 升到 beta,新增 RoundRobinRouter/直连入口的模型多路复用,Data 侧上线基于速率的集群 Autoscaler —— serving 层弹性能力成熟。
5. **合规/安全信号**:garak v0.17.0 加入 EU AI Act 探针映射;MLflow v3.16.0 basic-auth 改为 fail-closed 授权、Helm 探针可配 —— 上游都在补企业级合规与鉴权。

---

## 推理引擎动态

### vLLM
- **v0.29.0**(09-09 发布,https://github.com/vllm-project/vllm/releases/tag/v0.29.0)。本周主线两条基础设施相关值得看:
  - **Rust 前端持续落地**:新增 per-request 抢占直方图指标(https://github.com/vllm-project/vllm/pull/57033),`max_num_queued_reqs` 跨 API server 进程共享(#54746)。Rust 前端 + Prometheus 指标化,是 vLLM 向"生产级服务组件"演进的方向,和我们网关/指标体系对标。
  - **P/D 分离与 KV 传输**:KVConnector/NIXL 多处增强 —— 支持 PP push prefill 的 attention-HMA 布局(#50494)、P2P 可配 unbound-store 超时与一次 RTT 拒绝迟到 fetch(#53453)、修多 handle 传输竞态(#56104)。KV 连接器正在硬化,是解耦 prefill/decode 集群的关键底座。
  - 模型侧大量 DeepSeek V4.1(DSpark)/MXFP8 KV 优化,属模型适配,产品层关注度低。

### SGLang
- 本周无 release(最新 v0.5.19,09-05),但 Router 子系统是全场信息密度最高的:
  - **存储分层感知的 KV 缓存路由**:四连 PR 把 KV storage-tier 引入缓存感知路由树、暴露到 `/metrics`、上 Grafana 面板、加真机 e2e(#39108/#39109/#39110/#39111)。意味着 SGLang Router 能按"KV 在哪一层存储"做路由决策 —— 这是把 KV 缓存当成集群级分层资源来调度。
  - **网关工程化**:`--worker-queue-limit` 避免把亲和流量打到已排队 worker(#39168);按 worker 在注册时解析线协议、支持 h2c 明文 HTTP/2(#39004/#39006);worker 选择逻辑抽成 `policies::selection`(#39322)。
  - **PD 分离**:拒绝把 intake-rejected 请求塞进 PD handoff(#38935);`[PD][LoRA]` 按 adapter 槽位门控 decode 准入(#39332)。
  - 启示:SGLang Router 已具备"KV 感知 + LoRA 感知 + 排队保护"的 L7 调度能力,和我们要做的推理网关高度重叠,值得逐 PR 拆解其路由策略接口。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc26**(09-09,https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc26):
  - **KVCacheManagerV2 默认化**:Llama/Llama4(#19004)、Nemotron 多模态(#19140)默认切到 V2;NVFP4 KV for DSV4(#18723)。统一 KV 管理器是其 disagg / 长上下文的基础。
  - **BREAKING 去 TRT 化**:移除 serve/eval 里的 TRT 遗留(#19022)、删掉双模型投机解码路径与死掉的 C++ spec-dec 代码(#18721)。NVIDIA 官方栈正式以 PyTorch 为主干。
  - disagg 服务扩到 Qwen3.8-Flash-Next(#18921),cache transceiver 加 NIXL bounce buffer(#15780)—— 又一个押注 NIXL 做 KV 传输的栈。
- **TGI**:仓库已 archived(最后 push 2026-03-21),窗口内 0 提交,属正常停维护,不再跟踪。
- **Ollama v0.34.1**(09-14,https://github.com/ollama/ollama/releases/tag/v0.34.1):新增服务端 MLX 导入并弃用 GGUF 转换(#14969)、移除内置 agent(#18393)。主打 Apple MLX 与桌面集成,与云原生服务关系不大,MLX 服务端化是可留意的边缘推理信号。

## 模型服务 & 编排

### KServe 上游
- **v0.21.0-rc0**(09-10,https://github.com/kserve/kserve/releases/tag/v0.21.0-rc0),本周对我们最相关的一批:
  - **SGLang 成为一等推理运行时**(#5124,已合入 09-11 https://github.com/kserve/kserve/pull/5124)—— KServe 官方多运行时阵营再加一员,vLLM 之外多了 SGLang 选项。
  - **可观测性**:向 InferenceService 注入 OTEL 变量(#6172);给 LLMISVC 注入 `--root-path` 让 vLLM `/docs` 能穿过 gateway 访问(#6056)。
  - **OCI 模型分发**:Helm 暴露 `enableOciModelSupport` / `ociModelMode`(#6152);kernelcache 按 GPU flavor 产出 mcv 容器镜像(#6176)并加 cert-mode 镜像签名(#6124)。
  - **LLMISVC 细化**:把 LoRA PVC adapter 卷按 claim 收敛为一个(#6197)、去重覆盖 ServingRuntime 默认值的 isvc 参数(#6178)、HPA 按 metric 施加 scale target 边界(#6140)。
  - 启示:KServe 这个 rc 几乎每条都踩在我们产品面上(多运行时、OTEL、OCI 模型、LoRA 卷管理),建议把 v0.21.0 的 LLMISVC 变更作为下个对标基线细读。

### Ray
- 无 release(最新 ray-2.58.0,08-23),但 Serve/Autoscaler 提交密集:
  - **弹性成熟**:自定义自动扩缩策略从 experimental 升 beta(#66058);Data 侧上线基于速率的集群 Autoscaler(#65954);V2 autoscaler 支持 Spark node provider(#65579)与多资源需求预筛精度提升(#65171)。
  - **模型多路复用**:RoundRobinRouter(#65679)与直连入口(#65678)都支持 model multiplexing —— 单副本承载多模型,和我们多租户密度诉求一致。
  - **可观测性硬化**:自动扩缩指标改零拷贝列式编解码(#64281/#66104),托管服务下 Prometheus 健康检查回退到 query API(#63428)。
  - 启示:Ray Serve 的 model multiplexing + 自定义扩缩策略接口值得评估能否直接复用于我们的多模型密度场景。

## 训练 & 微调

- **kubeflow/trainer**(原 training-operator,Trainer v2):本周仅 k8s 1.37 适配(#4005)与 data cache 镜像迁 Debian bookworm(#4051),无重大功能变化。
- **hiyouga/LlamaFactory**:v1 分支推进中 —— 支持 Kimi K2.5/2.6 LoRA 微调(#10826)、多模态 Ulysses 上下文并行 + SFT 内存高效 chunk loss(#10762)。长上下文/多模态训练的显存优化方向可留意。
- **kubeai-project/kubeai**(原 substratusai/lingo):窗口内 0 提交,持续静默。

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow v3.16.0**(09-04 已发,窗口内主线为企业化补强):basic-auth 对非 admin 改为 fail-closed 授权、非管理员在 fail-closed 下才 serve UI(#25672/#25754);batch trace/scorer 端点加 `experiment_ids` 作 per-request 鉴权范围(#24999);Helm chart 暴露 liveness/readiness/startup 探针(#25560)与 topology spread 约束(#25778)。整体是鉴权 + K8s 部署可运维性的补齐。
- **kubeflow/model-registry**:延续 catalog 化,本周聚焦 gated/private HF 模型门控 —— 阻止未授权 gated 模型进 catalog(#3241)、HF token 支持转正(去临时 feature flag,#3205)、Add source 表单处理门控(#3183),并修多个 catalog 预览分页 panic/循环 bug。对"模型来源合规接入"是直接参考。
- **feast-dev/feast**:仅小修(Trino auth SecretStr 解包 #6771、registry cache key 快照 tag 过滤),无重大更新。

## LLM 评估 & 安全

- **NVIDIA/garak v0.17.0**(09-09,https://github.com/NVIDIA/garak/releases/tag/v0.17.0):新增 **EU AI Act 探针映射**(#2094)—— 把红队探针对齐到 EU AI Act 条款,合规导向的评测正在成形;另修 analyze 报告聚合时保留 attempt uuid(#2158)、包幻觉检测器覆盖点号/缩进 import(#2108)。对我们做"合规可审计的模型安全评测"有参考价值。
- **EleutherAI/lm-evaluation-harness**:新增 MedMCQA/MedQA 的 zero-shot CoT 变体(#4081)、gguf 支持新版 llama.cpp logprobs 格式(#4012),属任务与后端兼容性小修。
- **meta-llama/llama-stack v1.4.0 / v1.0.3**(09-10/09-11,release 页已迁 ogx-ai/ogx):本周基本是 OGX 改名收尾(stainless→openapi 生成器迁移 #6547、文档/CLI 里 meta-llama/ogx 引用修正)、Fireworks provider 刷新(#6556)、vector_io 从已索引 chunk 计算 usage_bytes(#6549)。无架构级新能力,以工程债清理为主。

## 值得跟进

- [ ] 细读 **KServe v0.21.0 LLMISVC 变更**(SGLang runtime #5124、OTEL 注入 #6172、OCI 模型 #6152、LoRA PVC 收敛 #6197),作为我们推理服务对标基线。
- [ ] 拆解 **SGLang Router 的 KV storage-tier 路由**四连 PR(#39108~#39111)与 worker 选择策略接口(#39322),评估 KV 感知路由能否借鉴到我们的推理网关。
- [ ] 评估 **Ray Serve 模型多路复用**(#65678/#65679)+ 自定义自动扩缩 beta(#66058)是否适配我们多租户多模型密度场景。
- [ ] 跟踪 **TensorRT-LLM 去 TRT 化 / KVCacheManagerV2 默认化**(#19022/#19004),判断 NVIDIA 官方栈纯 PyTorch 化对我们运行时选型的影响。
- [ ] 关注 **garak EU AI Act 映射**(#2094),纳入合规评测能力的调研。
