# AI 推理 & MLOps 生态周报 2026-08-05

> 覆盖窗口:2026-07-29 ~ 08-05(近 7 天)。vLLM / SGLang 单周提交均 >100(此处采样前 100),已过滤 bump/CI/waive/typo 噪音。TGI(上游最后 push 停在 2026-03)、lm-evaluation-harness(最后 push 07-13)本窗口无提交,判定"无重大更新"。

## 摘要(5 条)

1. **全生态在同一件事上收敛:PD 分离 + KV 缓存分层/卸载 + KV 感知路由。** vLLM 落地 Model Runner v2 的 E/P/D 分离,Ray Serve LLM 连推 6 个 PR 把 CPU KV 卸载+前缀感知路由做进 LLMRouter,SGLang 打磨 HiCache/HiSparse 分层缓存,TRT-LLM 把 DeepSeekV3 的 KV 传输默认切到 V2。这已是推理层的架构主线,直接决定我们网关/调度层怎么设计。
2. **vLLM 与 SGLang 不约而同上 Rust 前端。** vLLM Rust 前端加 gRPC 多模态图像推理,SGLang 新增 `rust sglang server openai apis` + gRPC 生成语义——两大引擎都在把 OpenAI/gRPC 接入面从 Python 迁到 Rust 抢吞吐。
3. **KServe 上游 v0.20.0-rc1:llmisvc 全面向 llm-d 靠拢并补企业能力。** 直连 KEDA 扩缩、RawDeployment 金丝雀流量拆分、LoRA/DRA 校验补齐、disagg-sidecar TLS、controller ClusterRole 收紧。这是与我们(对标 OAI)最贴脸的赛道。
4. **MLflow 3.15.x 把自己坐实成 GenAI 评估/追踪中枢。** scorer_ensemble 组合评分、评估运行内嵌 Assistant 分析、MCP Registry、A2UI 自定义 trace 视图、Pydantic AI 自动埋点,甚至给 Claude Code 插件 trace 算成本。
5. **注册表在向 Skill/Agent/MCP catalog 演进。** kubeflow model-registry(hub)本周落 Model Catalog v1 OpenAPI + MCP serverJson + Skill 插件(SKILL.md parser),与上周 oai-weekly 观察到的 ODH v3.5 方向一致。

## 推理引擎动态

### vLLM
- **Model Runner v2:E/P/D 分离支持落地** —— https://github.com/vllm-project/vllm/pull/38390 。配套 KV 卸载支持二级存储的部分加载结果 https://github.com/vllm-project/vllm/pull/50321 。这是把 prefill/decode 拆开、KV 走多级存储的核心底座。
- **Rust 前端 + gRPC 多模态图像推理** —— https://github.com/vllm-project/vllm/pull/50368 ;Rust benchmark 保留 UTF-8 流式分块 https://github.com/vllm-project/vllm/pull/50868 。前端 Rust 化在推进。
- 投机解码继续做 DSpark Markov 投影(top-k / 量化头)https://github.com/vllm-project/vllm/pull/49969 ;NVFP4 量化 out_dtype 对齐模型 dtype https://github.com/vllm-project/vllm/pull/48861 ;CPU MoE 迁到 modular-kernel experts 结构 https://github.com/vllm-project/vllm/pull/50133 。
- 新模型:K-EXAONE-2.0-750B-A37B https://github.com/vllm-project/vllm/pull/50524 ;Transformers 后端正式支持 MLA https://github.com/vllm-project/vllm/pull/48250 。

### SGLang
- **Rust 版 OpenAI API server** —— https://github.com/sgl-project/sglang/pull/33103 ;gRPC 生成请求语义 https://github.com/sgl-project/sglang/pull/32588 。与 vLLM 前端 Rust 化同频。
- **HiCache/HiSparse 分层 KV 打磨**:L2 分层缓存的乐观 prefill + 回写策略 https://github.com/sgl-project/sglang/pull/33545 ;DCP 下按聚合 KV 池而非单 rank 份额限流请求 https://github.com/sgl-project/sglang/pull/33448 ;DeepSeek V4 HiSparse PD 传输主机/设备 KV 索引分离修复 https://github.com/sgl-project/sglang/pull/31901 。
- 多模态视觉流水线核心(fetch/driver/pipeline + Qwen VL)https://github.com/sgl-project/sglang/pull/32364 ;flashinfer rmsnorm+quant 融合(SM90/100/120)https://github.com/sgl-project/sglang/pull/32994 。

### TensorRT-LLM / TGI / Ollama
- **TRT-LLM v1.3.0rc23** —— https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc23 。DeepSeekV3 默认切 Python KV-cache transceiver V2 https://github.com/NVIDIA/TensorRT-LLM/pull/16908 ;disagg server keep-alive 超时可配 https://github.com/NVIDIA/TensorRT-LLM/pull/16430 。同时大量扩散/视频生成能力(Cosmos3 V2V、FLUX.2 参考图、Qwen-Image TeaCache)——NVIDIA 明显把 TRT-LLM 往多模态生成栈推,不止 LLM。
- **TGI:无重大更新。** 上游主仓最后 push 停在 2026-03,HF 推理重心已迁走,可下调跟踪优先级。
- **Ollama v0.32.6-rc0** —— https://github.com/ollama/ollama/releases/tag/v0.32.6-rc0 。qwen3.5 加载并运行 MTP 头做投机草稿;OpenAI 流式 wire 格式对齐 https://github.com/ollama/ollama/pull/17485 。边缘侧也在追投机解码。

## 模型服务 & 编排

### KServe 上游(v0.20.0-rc1)
Release:https://github.com/kserve/kserve/releases/tag/v0.20.0-rc1 。llmisvc(LLMInferenceService)本周信息量最大:
- **直连 KEDA 扩缩** https://github.com/kserve/kserve/pull/5839 ;**RawDeployment HTTPRoute 金丝雀流量拆分** https://github.com/kserve/kserve/pull/5912 。
- llm-d 对接:迁移剩余 `--model-server-metrics-*` flag https://github.com/kserve/kserve/pull/5930 ;从模板参数探测 scheduler / latency-producer 插件 https://github.com/kserve/kserve/pull/5931 https://github.com/kserve/kserve/pull/5937 。
- 校验补齐:关闭 LoRA 与 DRA 注解的 v1alpha1 校验缺口 https://github.com/kserve/kserve/pull/5938 。
- 安全:收紧 controller manager ClusterRole https://github.com/kserve/kserve/pull/5785 ;disagg-sidecar 改用新 TLS flag https://github.com/kserve/kserve/pull/5875 。
- **启示**:KServe 上游 = llm-d + LLMInferenceService + RawDeployment 金丝雀 + KEDA,与我们对标的 OAI 推理栈完全同构,这条线要逐 PR 跟。

### Ray
- **Ray Serve LLM 的 KV 卸载 + KV 感知路由系列(第 9~14/N 连发)** ——把 CPU KV 缓存纳入卸载与路由感知 https://github.com/ray-project/ray/pull/65063 ;token 带外传输、引擎侧跳过 tokenize https://github.com/ray-project/ray/pull/65095 ;原子选择+预留广播避免惊群 https://github.com/ray-project/ray/pull/65010 ;KV 生命周期事件广播到所有 LLMRouter ingress 副本 https://github.com/ray-project/ray/pull/64949 ;KV 卸载/重载 dashboard https://github.com/ray-project/ray/pull/65122 。Ray 把前缀缓存感知路由做进网关层,和我们的路由/网关最直接对标。
- Serve 调度:best-fit 节点调度加可选 tie-break key https://github.com/ray-project/ray/pull/64914 。

### KubeAI(原 Lingo)
- 本周仅 release 工作流/Helm chart 打包(v0.23.4,chart 发成 OCI 制品)https://github.com/kubeai-project/kubeai/releases/tag/helm-chart-kubeai-0.23.4 ,无功能变化,判定无重大更新。

## 训练 & 微调

### Kubeflow Trainer(原 training-operator)
- 本周基本静默:多为 nightly 安全依赖更新 + controller-gen 升 0.21;唯一实质项是 status server bearer token 解析加固与测试 https://github.com/kubeflow/trainer/pull/3782 。无重大更新。

### LLaMA-Factory
- **v1 重构推进**:多模态数据训练支持 https://github.com/hiyouga/LLaMA-Factory/pull/10656 ;新增 MOSS-VL https://github.com/hiyouga/LLaMA-Factory/pull/10708 ;**按模型类型重构 NPU kernel 匹配** https://github.com/hiyouga/LLaMA-Factory/pull/10643 (与我们昇腾/NPU 方向相关,值得看它怎么按模型分派 NPU kernel)。

## 模型生命周期(MLflow / Registry / Feast)

### MLflow(3.15.0 / 3.15.1)
Release:https://github.com/mlflow/mlflow/releases/tag/v3.15.0 、https://github.com/mlflow/mlflow/releases/tag/v3.15.1 。GenAI 评估/追踪继续加码:
- scorer_ensemble 组合多个 scorer https://github.com/mlflow/mlflow/pull/24749 ;评估运行内嵌 Assistant 分析动作 https://github.com/mlflow/mlflow/pull/24865 。
- MCP Registry 特性文档 https://github.com/mlflow/mlflow/pull/24713 ;A2UI catalog schema + 自定义 trace 视图 https://github.com/mlflow/mlflow/pull/24788 ;Pydantic AI 2.x 自动埋点 https://github.com/mlflow/mlflow/pull/24721 。
- **启示**:MLflow 已不是"实验追踪",而是 GenAI 评估 + trace + MCP/Agent 治理的中枢,和 kubeflow hub、TrustyAI 抢同一块地。

### kubeflow model-registry(hub / AI Hub)
- **Model Catalog v1 OpenAPI 规范** https://github.com/kubeflow/model-registry/pull/3038 + v1 endpoints 实现 https://github.com/kubeflow/model-registry/pull/3037 ;MCP server 加 serverJson 字段 https://github.com/kubeflow/model-registry/pull/3043 ;**Skill 插件体系**(SKILL.md parser + skill plugin 脚手架)https://github.com/kubeflow/model-registry/pull/3041 。注册表正扩成 Model + Skill + MCP catalog。

### Feast
- **Operator 企业化**:OIDC audience/issuer 校验透传 https://github.com/feast-dev/feast/pull/6677 https://github.com/feast-dev/feast/pull/6670 ;打包式 feature repo 支持;init 容器镜像可覆写 https://github.com/feast-dev/feast/pull/6598 ;online store 可整体关闭 opt-out。
- 数据面:get_historical_features 加 created_timestamp 截断过滤 https://github.com/feast-dev/feast/pull/6617 ;DynamoDB online store 加 plan() 支持;FIPS 密码套件/中级 TLS 默认。企业多租户+安全合规能力在补齐。

## LLM 评估 & 安全

### garak(v0.16.0)
- Release:https://github.com/NVIDIA/garak/releases/tag/v0.16.0 。本周多为稳健性:detector 尊重 config_root、长跑修 httpx FD 泄漏 https://github.com/NVIDIA/garak/pull/1787 、锁定 nltk 版本。无新攻击面能力。

### OGX(原 meta-llama/llama-stack)
- **持久化的进程外作业调度**(file_processors)https://github.com/meta-llama/llama-stack/pull/6160 ;检索后**分类器重排序**做 chunk 过滤 https://github.com/meta-llama/llama-stack/pull/5890 ;Bedrock 经 ListFoundationModels 自动发现模型 https://github.com/meta-llama/llama-stack/pull/6315 ;推理 httpx 连接池上限可配 https://github.com/meta-llama/llama-stack/pull/6306 。CLI `ogx letsgo` 改名 `ogx go`(保留别名)。RAG/Agent 栈在做工程化收口。

### lm-evaluation-harness
- 本窗口无提交(最后 push 2026-07-13),无重大更新。

## 值得跟进
- [ ] **KV 感知路由/PD 分离的横向对比**:Ray LLMRouter(#64949 系列)vs KServe llm-d scheduler 插件 vs vLLM MRv2 EPD——三家都在做"前缀缓存感知 + PD 分离",出一份对我们网关/调度层的选型与差距分析。
- [ ] **KServe llmisvc 逐 PR 跟踪**:KEDA 直连扩缩(#5839)+ RawDeployment 金丝雀(#5912)是否要在我们产品对齐;LoRA/DRA 注解校验(#5938)看它的 CRD 契约。
- [ ] **推理引擎 Rust 前端趋势**:vLLM(#50368)+ SGLang(#33103)都在 Rust 化接入面,评估对我们自研网关/适配层的影响与吞吐收益。
- [ ] **注册表→Skill/Agent/MCP catalog**:kubeflow hub(#3038/#3041)与 MLflow MCP Registry(#24713)方向重叠,确认我们模型注册中心是否需要纳入 Skill/MCP 维度。
- [ ] **Feast Operator 企业安全**:OIDC 校验(#6677)、FIPS/TLS 默认——对照我们多租户 Feature Store 的合规基线。
- [ ] **LLaMA-Factory NPU kernel 按模型分派(#10643)**:昇腾方向可借鉴的微调侧 NPU 适配思路。
