# AI 推理 & MLOps 生态周报 2026-10-14

> 窗口:2026-10-07 ~ 2026-10-14。只筛"做云原生 AI 基础设施产品"有用的变化,版本 bump / dependabot / CI 噪音已剔除。每条带源链接。

## 摘要(5 条以内)

1. **P/D 分离 + KV connector 正在从推理引擎下沉到编排层**:KServe 新增 opt-in `DisaggregatedSet` P/D 后端,Ray Serve 的 `KVAwareRouter` 支持 Anthropic `/v1/messages`,同期 vLLM(Mooncake over RDMA)、TensorRT-LLM(Mooncake 进 KVCMv2、默认切 KV cache manager V2)三引擎 KV 连接器趋同。prefill/decode 分离 + KV 感知路由正在成为 K8s LLM 服务的"桌面标配"。
2. **"OpenAI Decisions API" 一周内横扫全生态**:vLLM 落地 text-only Decisions API MVP、Ollama 出 decision model、MLflow 的 `make_judge()` 支持 Decision API 并全链路 trace、TensorRT-LLM/SGLang 搞 DSpark 置信度。一个新的"决策/判别"API 标准正在形成,服务层和评估层都要预留对接。
3. **DRA 落进 Kubeflow Trainer**:TrainJob 实现 Dynamic Resource Allocation(KEP-2782),配合 Volcano gang 调度配置收敛——上游训练编排开始把 GPU 分配交给 DRA,和我们 GPU 调度路线直接相关。
4. **企业级安全/机密计算多点开花**:KServe 支持"不整体载入内存即解密机密模型",MLflow 给远程 Assistant 工具执行强制沙箱并限权,Feast 把 UI CORS 收窄到可信源。合规/多租户是本周横切主题。
5. **MLflow 继续重仓 GenAI 评估与可观测**:judge/scorer、agent lineage、OpenAI Decisions 的 Python/TS/UI 全链路 tracing——它在抢"Agent 评估 + 观测"这一层。

---

## 推理引擎动态

### vLLM
主仓一周 400+ 提交,产品相关信号:

- **新 API 面**:`[Feat] Add text-only OpenAI Decisions API MVP` — https://github.com/vllm-project/vllm/pull/60465 。Decisions API 是本周全生态共同动作,vLLM 先上文本版 MVP。
- **KV 分离/卸载生态成熟**:KVConnector 把 peer 注册移出 scheduler 线程(#57139)、Mooncake over RDMA 支持 sleep 模式(#59625)、KV offload 跨 worker 预取分片(#59545)、MoRIIO 读缓存命中需挂起远程 prefill(#60638)。方向是 disaggregated serving 的连接器层在补齐。参考:https://github.com/vllm-project/vllm/pull/59625
- **可复现性**:`[Feature] Support batch invariance on ROCm`(#52231)——批次无关(batch-invariant)推理,对需要确定性输出的企业/评测场景有意义。
- **扩展性**:`[Core] Add lifecycle hooks for worker extensions`(#59463),给 worker 加生命周期钩子,利于二次开发插件化。
- **多加速卡**:ROCm/AMD、Intel XPU 的 kernel/后端占了很大比重(AITER、Triton 回退、XPU KV RoPE 等),vLLM 的硬件中立性持续走强。

### SGLang
一周 500+ 提交(实际更多),产品相关信号:

- **分层 KV(HiCache)+ 统一内存池持续深化**:HiCache 预取/载回生命周期抽成 pipeline 操作(#43870)、block-group 池命中与 FULL 淘汰(#43868)、统一内存池在 HiCache 后端/PD decode 下优先 SWA 回收(#43919)。和 vLLM/TRT-LLM 的 KV 分离是同一战场。
- **Rust 前端增强**:OpenAI chat/completions 路由可服务任意 `model` 名(#43923)、在绑定前拒绝不支持的多模态模型(#43925)。前端网关化方向清晰。
- **安全/溯源**:`[Feature] Add Aaronson-Gumbel text watermarking`(#37577)——文本水印,内容溯源能力。https://github.com/sgl-project/sglang/pull/37577
- **多租户 LoRA**:多模型 LoRA 的 fused expand 去空 CTA + split-K(#41951),LoRA 服务密度提升。

### TensorRT-LLM / TGI / Ollama

**TensorRT-LLM**(144 提交,Release 1.4 筹备中):
- **重大架构切换(BREAKING)**:`Default to KV cache manager V2 and Python transceiver`(#17495)——默认启用 KV cache manager V2。https://github.com/NVIDIA/TensorRT-LLM/pull/17495
- **跨引擎 KV 连接器趋同**:`Integrate Mooncake connector into KVCMv2`(#19171)——和 vLLM 同拥抱 Mooncake。
- 统一缓存目录 `TRTLLM_CACHE_DIR`(#18897)、disagg gen-init KV 接收改轮询不阻塞 overlap scheduler(#19857)、支持 DeepSeek-V4.1-Flash(#19727)。

**TGI**:仓库已 archived(最后 push 2026-03),窗口内 0 提交,属正常停维护,不再跟踪。

**Ollama**(一周 4 个 release,v0.40.1 → v0.40.4,https://github.com/ollama/ollama/releases/tag/v0.40.4):
- **Decision model**:CLI `ollama run` 加 decision model 支持(#18962)、MLX 决策模型 JSON 状态修复(#18974)——又是 Decisions 主题。
- MLX Metal 自定义 kernel 移植到 CUDA(#18657);服务端复用已验证 manifest 与已载模型(#18947)。
- 产品侧更偏消费:cloud 积分、Codex/Claude Code 连接器集成(`CLAUDE_CODE_MAX_CONTEXT_TOKENS` 对齐模型上下文窗口)。对企业基础设施借鉴有限。

---

## 模型服务 & 编排

### KServe 上游
本周最值得看的编排层动作:

- **P/D 分离进编排层**:`feat(llmisvc): add opt-in DisaggregatedSet backend for P/D services` — https://github.com/kserve/kserve/pull/6330(已合)。KServe 的 LLMISVC 开始提供 prefill/decode 分离后端,和上面引擎侧 KV 分离形成上下游闭环。**对我们产品:这是 K8s 原生 LLM 服务的关键能力,需评估对标。**
- **机密模型服务**:`fix: decrypt confidential models without loading them entirely into memory` — https://github.com/kserve/kserve/pull/6219 。机密计算/受保护模型的内存安全处理。
- **GIE 对齐**:Gateway API Inference Extension bump 到 v1.6.2(#6348);`routingSpecAnnotations` 重命名(#6377)。
- **模型缓存**:LocalModelCache OCI 导入支持 imagePullSecrets(#6213);KernelCache 补 E2E 脚手架(#6352)。OCI 化模型分发继续推进。
- 弃用 llmisvc 的 WVA 自动扩缩(#6263);修 maxSurge:0 下 DS 滚动停滞(#6378)。

### Ray
无 release,76 提交,产品相关:

- **KV 感知路由 + Anthropic API**:`[serve][llm] Support Anthropic /v1/messages in KVAwareRouter` — https://github.com/ray-project/ray/pull/66827 。Ray Serve 的 KV 感知路由接入 Anthropic Messages 协议。
- **训练健康/容错契约**:新增 `ray.train.health` —— probe/health state/decision/policy 契约(#66536)、ControllerProbe(#66648)、NCCL hang detector 加 flight recorder 与 nvidia-smi 诊断(#66203/#66229)。训练可观测与自愈在补齐。
- **数据容错**:mid-epoch 恢复(data iterator checkpointing,#66563)、数据血缘 tracker 接入流式执行器(#66220)。
- 运行时环境值在 train endpoints/agent 日志中脱敏(#66597);vLLM 升到 0.31.0(#66720)。

### KubeAI(原 substratusai/lingo)
发 v0.24.0 — https://github.com/kubeai-project/kubeai/releases/tag/v0.24.0 。内容轻量:API endpoint 迁移(#753)、新增 Spark-X2.5-4B 的 SGLang/vLLM 模型配置(#755)、benchmark 移出主仓。整体仍偏安静。

---

## 训练 & 微调

- **Kubeflow Trainer(原 training-operator)**:
  - **DRA 落地**:`feat(api): implement DRA support for TrainJob (KEP-2782)` — https://github.com/kubeflow/trainer/pull/4027 。TrainJob 支持 Dynamic Resource Allocation,GPU/加速卡分配走 DRA。**对我们 GPU 调度路线直接相关,建议跟进 KEP-2782 落地细节。**
  - Volcano gang 调度配置文档(#4199);拒绝 podGroupPolicy 同时设 coscheduling+volcano(#4061)。
  - 两处 BREAKING Helm 变更:尊重 `dataCache.lws.install`(#4120)、helm uninstall 保留 CRD(#4122)——升级需留意。
- **LLaMA-Factory**:本周仅 1 条提交(NPU Docker 文档加安全说明,#10883),无重大更新。

---

## 模型生命周期(MLflow / Registry / Feast)

- **MLflow v3.17.1**(https://github.com/mlflow/mlflow/releases/tag/v3.17.1):主题全在 GenAI 评估/可观测:
  - **判别/评估**:`make_judge()` 支持 Decision API(#26578)、服务端运行的自定义 scorer 可拿到 trace 输入输出(#26690)、`mlflow.genai.evaluate` 记录 dataset/scorer/agent lineage(#26543)。
  - **OpenAI Decisions 全链路 trace**:Python(#26575)、TypeScript(#26576)、v2 trace viewer 显示(#26577)。
  - **安全**:远程 MLflow Assistant 工具执行强制沙箱并限权(#25844)。
  - Claude Code 的 OTel trace 在 MLflow UI 渲染/导出(#26547/#26472)——把 agent 运行轨迹接进 MLflow 观测。
- **Kubeflow Hub(原 model-registry)**:一周基本是 dependabot,唯一产品信号:`feat(catalog): add evaluation-metrics artifact type`(#3332)——registry catalog 开始纳管评估指标类型。其余无重大更新。
- **Feast v0.67.0**(https://github.com/feast-dev/feast/releases/tag/v0.67.0):
  - 新计算后端/存储:Trino 批量检索与物化(#6898)、Lance 存储与非 JVM 写路径(#6945/#6958)、Postgres online 批量读跨 feature view(#6832)。
  - 治理:OpenLineage 改进(数据集版本化、列级血缘、owner);MCP server 支持 dual-stack(`--host ::`)。
  - 安全:UI server CORS 收窄到可信源(#6986)。

---

## LLM 评估 & 安全

- **lm-evaluation-harness**:窗口内 0 提交,无重大更新。
- **garak**:16 提交,全是维护性修复——DAN prompt 兼容恢复(#2282)、ApiKey safe-token 抑制作用域收敛到匹配凭证(#2270)、尊重 `parallel_capable`(#2274)、复用 WebSocket 事件循环(#2269)。无新攻击/探针类别,稳定期。
- **llama-stack v1.5.0 / v1.0.4**(release 在 meta-llama/llama-stack,PR 指向 ogx-ai/ogx):
  - **新判别 API**:`SystemOne judgment model API with TypeSafe provider`(#6748)+ Ollama provider 接 SystemOne 判别(#6769)——又一个"判别/评估"API 面,呼应全生态 Decisions 趋势。
  - 推理模型思考链:Anthropic 翻译路径支持 thinking(#6663)。
  - 多租户/一致性:`delete_many` 应用 tenant filter(#6725)、conversations item id 对齐 OpenAI 语义(#6716)、MCP 工具结果块与错误文本完整保留(#6745)。

---

## 值得跟进

- [ ] **P/D 分离对标**:KServe `DisaggregatedSet`(#6330)+ Ray `KVAwareRouter`(#66827)— 评估我们产品在 K8s 原生 prefill/decode 分离 + KV 感知路由上的差距与落地路径。
- [ ] **Decisions API 走向**:vLLM(#60465)、MLflow(#26578)、Ollama、llama-stack SystemOne(#6748)一周内同时上"决策/判别"API——判断这是否会成事实标准,我们的服务层/评估层是否需要预留对接。
- [ ] **DRA on Trainer**:跟进 Kubeflow Trainer KEP-2782(#4027)的 DRA 实现,对照我们 GPU 调度(DRA vs device-plugin)取舍。
- [ ] **跨引擎 KV 连接器(Mooncake)**:vLLM + TensorRT-LLM 都在接 Mooncake(#59625 / #19171),评估是否以 Mooncake/NIXL 作为我们统一 KV 传输层的候选。
- [ ] **机密模型服务**:KServe #6219 的"不整体载入内存解密"模式,对标我们机密计算/受保护模型分发方案。
- [ ] **Feast 新后端**:Trino 计算引擎 + Lance 存储(#6898/#6945)扩大了 Feature Store 的部署形态,按客户需求评估纳入。
