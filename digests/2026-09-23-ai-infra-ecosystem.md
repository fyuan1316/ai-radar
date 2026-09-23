# AI 推理 & MLOps 生态周报 2026-09-23

> 窗口:2026-09-16 ~ 09-23。只筛"对做云原生 AI 基础设施产品有借鉴/威胁"的变化,版本 bump / dependabot / CI 修复已过滤。

## 摘要(5 条以内)

1. **vLLM v0.30.0 大版本落地**:引擎冷启动被系统性优化——"Fast Start"常驻每卡权重缓存 daemon,重启引擎走 CUDA IPC 而非磁盘重载(`--load-format ipc_cache`);Model Runner V2 把 H200 上引擎 init 从 28.9s 压到 8.2s、图捕获 12s→2s。对"秒级扩缩容 / 抢占式调度"的产品叙事是直接利好,也是对标基线抬高。
2. **KServe v0.21.0-rc1 把 llmisvc(LLMInferenceService)推向生产**:新增 ServingRuntime 的 **DRA resourceClaims** 支持、CRD 拆分为可独立安装、canary 流量切分下沉到 RawDeployment HTTPRoute、集群 TLS 安全 profile 集成、ClusterRole 收紧。上游正把"LLM 专用 CRD + 网关"补齐到企业级。
3. **SGLang v0.5.20 放出 CPU-only Simulator**:不占 GPU 就能跑真实 scheduler/radix cache 预测 TTFT(误差约 6%)——容量规划/调度策略验证的新工具;同时统一 radix tree 把共享前缀命中率 43.8%→60.8%。
4. **MLflow AI Gateway 往"LLM 网关"演进**:新增 OpenAI 兼容的模型发现、prompt 缓存按 registry 隔离。它在悄悄补 LiteLLM/网关这块能力,值得盯与我们模型服务层的重叠。
5. **Kubeflow model-registry 全面 catalog 化**:HF gated/私有模型接入 + token 校验、alpha catalog API 加 RFC 8594 弃用头。注意该仓库现已迁到 `kubeflow/hub` 路径(release/PR 链接均为 hub)。

---

## 推理引擎动态

### vLLM — v0.30.0(大版本,762 commits / 315 contributors)
Release: https://github.com/vllm-project/vllm/releases/tag/v0.30.0

对基础设施最相关的几点:
- **Fast Start**:常驻的 per-GPU 权重缓存 daemon 持有量化后、TP 分片好的权重于显存,重启引擎用 `--load-format ipc_cache` 经 CUDA IPC 映射,不再从磁盘重载;已覆盖 FP4 checkpoint 和多节点 TP(#54921/#55465/#55468)。
- **Model Runner V2**:eager 模式双 batch overlap;图捕获期冻结 GC 使捕获 12s→2s、引擎 init 28.9s→8.2s(H200,#54646);PP 下的 MTP/EAGLE3 投机解码。
- **HiSparse**:sparse-MLA decode 的 host 常驻分层,GPU 压力下把 KV page 溢出到 pinned host 内存,`HiSparseConnector` 启用(#53781)——KV 分层/卸载又进一步。
- **大规模服务**:Elastic EP 跨重配复用 CUDA graph、DeepEP v2、Mooncake Store 异构 TP 共享、NIXL/Mooncake 上的 encoder-cache 共享。
- **水印**:Gumbel-max 生成+检测,带 per-request opt-out 和检测端点(#54053)——合规/溯源场景可关注。
- **破坏性变更**:scale-out 端点改为 `vllm serve --enable-scale-out` 显式开启(替代旧环境变量);GPTQ g_idx 移除;`grpc_server` 入口改 `vllm serve --grpc`。升级需回归。

### SGLang — v0.5.20(713 PR / 237 contributors)
Release: https://github.com/sgl-project/sglang/releases/tag/v0.5.20

- **SGLang Simulator**(#33824):CPU-only,跑真实 scheduler + radix cache + 分层缓存,用延迟预测器替代前向,TTFT 预测误差约 6%、前缀复用误差 0.05pp。**无 GPU 做缓存/调度研究**,对我们的调度策略选型和容量规划有用。
- **统一 radix tree**(#34565):SWA 分叉点缓存,DeepSeek-V4-Flash 共享系统提示下 token 命中率 43.8%→60.8%、TTFT 1.57s→1.07s;可选外部 linker 经 Mooncake/UMBP 寻址全局显存池(#37381)。
- **Responses API 存储改 opt-in**(#39122):`--enable-response-store` 才留存,PD 部署不可开——多租户下的状态管理取舍。
- **平台面**:CUDA 12 lane 退役(v0.5.19 为最后一个 -cu12x);新增 Intel XPU 正式发布镜像、ROCm 10 (MI30x/MI35x)、Strix Halo gfx1151、摩尔线程 MUSA 镜像。多硬件后端在快速铺开。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc27**(https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc27):仍是 rc,release note 里一长串 Known Issues(GPT-OSS Eagle3 多卡可能 hang、多处 NVFP4 精度问题),生产慎用。有价值的:per-request 缓存 KV token 日志(#19375)、OpenAI 协议 tool enum 上限与 `parallel_tool_calls`(#19459)、PyTorch 升 2.14 + Triton 3.8。
- **TGI**:仓库已 archived(最后 push 2026-03-21),本周及以后均无更新,属正常停维护,不再单列。
- **Ollama v0.34.3 / v0.34.4-rc0**(https://github.com/ollama/ollama/releases/tag/v0.34.3):`GET /api/show` 现在暴露每个模型的 thinking 档位与默认值(如 low/high/max),云模型同样可查——**推理"思考强度"作为一等能力被标准化到 API**,值得在我们的模型元数据/网关里对齐;另 Nemotron H 视觉模型在 Apple Silicon MLX 上可跑。

---

## 模型服务 & 编排

### KServe 上游 — v0.21.0-rc1
Release: https://github.com/kserve/kserve/releases/tag/v0.21.0-rc1

本周重心几乎全在 **LLMInferenceService(llmisvc)** 的生产化 + 企业级能力,直接对标我们的模型服务层:
- **DRA 支持**:ServingRuntime 新增 `resourceClaims`(Dynamic Resource Allocation),GPU/加速器分配走 K8s DRA(#5828)。
- **CRD 拆分**:重构 CRD 管理以支持独立安装(#5843),便于按需装子集。
- **tokenizer 架构变化**:用 vLLM render deployment 替换 UDS tokenizer sidecar(#5712);WVA 从 VA CRD 迁到基于 annotation 的发现(#5722)。
- **发布策略**:canary 流量切分下沉到 RawDeployment 的 HTTPRoute(#5912),不再强依赖 service mesh。
- **安全合规**:集成集群 TLS 安全 profile(#5791)、收紧 controller manager ClusterRole(#5785)。
- **Agentic**:新增 agentic tool calling 指南与样例(#5906),llmisvc 往"服务 Agent 应用"扩。
- 其余大量 metrics-data-source / latency-producer 插件化改造,说明 llmisvc 的可观测与调度插件在标准化。

**启示**:如果我们的推理服务基于 KServe fork,DRA、CRD 独立安装、canary→HTTPRoute、TLS profile 这四条建议逐条评估合入路径;tokenizer sidecar→render deployment 是架构级变化,升级时要注意兼容。

### Ray
Commits: https://github.com/ray-project/ray/commits/master

无 release,但主干持续在做分布式健壮性,几条对基础设施有意义:
- **Data 容错**:fan-in 的 lineage 跟踪(Data Fault Tolerance 3/n,#66136)、job 级开关 lineage reconstruction(#65487)。
- **自动扩缩**:Backlog-aware Actor Autoscaler(#66035)、Serve 列式零拷贝 autoscaling 指标(#66240)、按节点跟踪 autoscaling coordinator reservation(#66001/#66002)。
- **沙箱**:把镜像缓存为 EROFS 根文件系统(#65992)——启动/隔离方向的小改进。

### KubeAI(原 substratusai/lingo)
近期静默(2026-07-31 后基本无提交),本周**无重大更新**。

---

## 训练 & 微调

- **Kubeflow Trainer**(原 training-operator):本周 9 条提交全是 dependabot 依赖 bump,**无重大更新**。
- **LLaMA-Factory**:本周窗口内无新提交(最后 push 09-14),**无重大更新**。

---

## 模型生命周期(MLflow / Registry / Feast)

### MLflow — v3.16.1
Release: https://github.com/mlflow/mlflow/releases/tag/v3.16.1

**AI Gateway 在往"LLM 网关"补能力**,值得跟我们模型服务层做重叠分析:
- OpenAI 兼容的模型发现(#25940)、TypeSafe Jev 支持(#26048)、网关请求鉴权解析修复(#25937/#26031)。
- prompt 缓存按 registry 隔离(#26066)、`search_prompts` 支持 order_by(#25967)——prompt registry 在成型。
- Trace 侧:支持 OpenInference request/response model-name 属性(#26047)、修复 Claude Code 工具调用的 usage span(#25931),GenAI 可观测持续加强。

### Kubeflow model-registry — v0.3.17(注意:仓库已迁到 `kubeflow/hub` 路径)
Release: https://github.com/kubeflow/hub/releases/tag/v0.3.17

本周全面 **catalog 化 + HuggingFace 接入**:
- HF gated/私有模型接入:移除私有 HF 部署阻断 + preview 加 `hasGated`(#3244)、HF access token 校验(#3167)、按 source 解析 HF API key(#3171)。
- catalog API 加 RFC 8594 弃用头(#3221)、拒绝 v1 spec 未声明的 orderBy 返 400(#3222)、分页游标保留 float 精度(#3213)。

**启示**:上游 registry 正把"直连 HF(含私有/门控)+ 规范化 catalog API"做成标配,和 ODH 的 model-registry fork 路线一致;我们的模型注册中心若要对标,HF 门控模型的凭据管理是必答题。

### Feast
Commits: https://github.com/feast-dev/feast/commits/master

- **MCP feature server 结构化审计日志**(#6456)——feature store 接入 Agent/MCP 生态并补合规审计,方向值得记。
- FeatureService 版本钉扎(online+offline,#6718)、Iceberg 离线批量写(#6690 类)、在线服务热路径去 metrics/audit 开销、offline server 改 `do_exchange` 以支持 HPA。企业级(版本管理、审计、弹性)在补齐。

---

## LLM 评估 & 安全

- **lm-evaluation-harness**:本周无新提交,**无重大更新**。
- **garak**(NVIDIA LLM 红队):仅 paraphrase buff 的小修复(#2200),无实质新探针。
- **llama-stack**(release 仍发在 meta-llama/llama-stack,内部 SDK 已改名 ogx):本周多为 CI/record-replay 与重构;值得记的一条是 **transformers 迁 5.x + sentence-transformers 迁 6.x 以修 CVE**(#6592),以及 vector_io 的 usage_bytes 计量修复(#6552)。无面向使用者的能力新增。

---

## 值得跟进

- [ ] 读 vLLM Fast Start / Model Runner V2 两组 PR(#54921、#54646),评估"引擎秒级重启 + IPC 权重缓存"能否纳入我们的弹性/抢占调度叙事,并做冷启动 benchmark 对标。
- [ ] 跟 KServe v0.21 的 DRA(#5828)、CRD 独立安装(#5843)、canary→HTTPRoute(#5912)、TLS profile(#5791)——逐条评估对我们 KServe 相关组件的合入优先级;tokenizer sidecar→render deployment(#5712)是架构变更需专门验证。
- [ ] 试用 SGLang Simulator(#33824)做一次无 GPU 的调度/缓存策略验证,判断能否用于我们的容量规划工具链。
- [ ] 对齐 Ollama `/api/show` 的 thinking 档位模型(low/high/max)与我们模型网关的元数据/推理参数抽象。
- [ ] 评估 MLflow AI Gateway 的 OpenAI 兼容模型发现(#25940)与我们模型服务层的功能重叠/差异;同步看 model-registry 的 HF 门控模型凭据管理(#3167/#3171)作为我们注册中心的对标项。
