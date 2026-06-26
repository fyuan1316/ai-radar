# AI 推理 & MLOps 生态周报 2026-06-26

> 窗口:2026-06-19 ~ 2026-06-26。覆盖 16 个上游仓库,已过滤 version bump / dependabot / CI / lint 噪音,只保留对"做云原生 AI 基础设施产品(对标 OpenShift AI)"有借鉴或威胁意义的变化。

## 摘要(5 条以内)

1. **KServe 上游继续猛攻我们赛道**:本周合入「机密模型服务(confidential model serving)」(https://github.com/kserve/kserve/pull/5382)、给 llmisvc 加 `kvCacheOffloading` spec 做 CPU KV cache 分层(https://github.com/kserve/kserve/pull/5599)、新增 latency predictor sidecar 自动注入(https://github.com/kserve/kserve/pull/5678),并把 llm-d 组件升到 v0.7.0(https://github.com/kserve/kserve/pull/5596)。LLMInferenceService 这条线一周一个台阶。
2. **Ray Serve 把 HAProxy 正式做成默认 ingress**:补齐 gRPC(https://github.com/ray-project/ray/pull/63735)、系统指标(https://github.com/ray-project/ray/pull/64255)、root_path(https://github.com/ray-project/ray/pull/64295)与 fallback 代理回退;同时 KV-aware 路由让 `KVRouterActor` 跟踪副本(https://github.com/ray-project/ray/pull/64085),并落地 SGLangServer 控制面对齐(https://github.com/ray-project/ray/pull/63021)。
3. **vLLM 主干在 KV 分层卸载上做架构级重构**:`OffloadingWorker` 取代旧 `OffloadingHandler`(https://github.com/vllm-project/vllm/pull/45053)、明确卸载请求生命周期契约(https://github.com/vllm-project/vllm/pull/46284)、Mooncake 用接收线程池并行加载 KV(https://github.com/vllm-project/vllm/pull/45971);Rust 前端持续替换 Python 入口。
4. **MLOps 侧治理与生命周期信号密集**:MLflow 官方文档加「Red Hat OpenShift AI」接入页(https://github.com/mlflow/mlflow/pull/24108)且重心全面转 GenAI Assistant/工具权限;kubeflow/model-registry 给模型目录加 MCP source preview 端点(https://github.com/kubeflow/model-registry/pull/2885)与 security-metrics 枚举(https://github.com/kubeflow/model-registry/pull/2814);feast 接入 OpenLineage 跨产出方血缘(https://github.com/feast-dev/feast/pull/6549)。
5. **TRT-LLM 出 v1.3.0rc19**,新增基于 BaseResourceManager 的 KV-cache 压缩管理框架(https://github.com/NVIDIA/TensorRT-LLM/pull/15106)、WideEP 容错 MPI 信号处理(https://github.com/NVIDIA/TensorRT-LLM/pull/14160);llama-stack 开出 Containers API(`/v1alpha`,https://github.com/meta-llama/llama-stack/pull/5913),把"跑容器"纳入栈内能力。

---

## 推理引擎动态

### vLLM
无新 release,主干高频(7 天远超 100 commit)。产品相关方向:
- **KV 卸载抽象重写**:把 `OffloadingHandler` 升级为 `OffloadingWorker`(https://github.com/vllm-project/vllm/pull/45053),修正卸载请求"已完成"生命周期契约(https://github.com/vllm-project/vllm/pull/46284),并把 lookup 返回从 `bool|None` 换成 `LookupResult` 枚举(https://github.com/vllm-project/vllm/pull/46363);Mooncake connector 用接收线程池并行 KV 加载(https://github.com/vllm-project/vllm/pull/45971)、只检查/存储新 KV 区间(https://github.com/vllm-project/vllm/pull/46412)。**启示**:vLLM 把"显存放不下就分层卸 CPU/二级介质"做成稳定的一等公民接口,和我们 KV cache 容量规划、连接器选型(Mooncake/NIXL)直接相关。
- **Rust 前端推进**:引入统一 parser 接口与组合 parser(https://github.com/vllm-project/vllm/pull/46583),把 gemma4/seed_oss 迁到统一解析,TLS 从 `rustls` 换 `native-tls`/OpenSSL(https://github.com/vllm-project/vllm/pull/46696)。**启示**:vLLM 把 API 入口往 Rust 搬以压高并发前端开销,值得盯它 serving 入口形态。
- **MLA / KV 量化**:支持 DCP + FP8 KV cache 走 MLA decode(https://github.com/vllm-project/vllm/pull/44044)、Triton INT4 per-token-head KV 量化(https://github.com/vllm-project/vllm/pull/40835)。
- **P/D 解耦**:给 NIXL P/D 加 Mamba1 支持(https://github.com/vllm-project/vllm/pull/45019)。
- 新模型抢首发:GLM-5 NVFP4、Qwen3.5/3.6、Kimi K2 工具调用、minimax-m3 稀疏注意力优化。

### SGLang
无新 release,主干同样高频。产品相关信号:
- **DeepSeek V4 支持成体系铺开**:多硬件(Intel XPU、AMD aiter)落地(https://github.com/sgl-project/sglang/pull/27783),并加 V4 Pro GB300 nightly + Flash demo notebook。
- **PD 路由 DP 感知**:支持 DP-aware 的 PD router 分发(https://github.com/sgl-project/sglang/pull/26245);PD 早发缓存前缀 KV、与未缓存 prefill forward 重叠(https://github.com/sgl-project/sglang/pull/29316)。**启示**:PD 分离的路由层正快速成熟,和我们做大规模 LLM serving 拓扑直接相关。
- **投机解码 v2 重构**:dflash triton 内核合并到单文件(https://github.com/sgl-project/sglang/pull/29228)、统一 spec/non-spec decode 结果处理(https://github.com/sgl-project/sglang/pull/29225)。
- 加调度器指标扩展钩子(https://github.com/sgl-project/sglang/pull/29207);prefill/decode 共享 CUDA graph 显存池(https://github.com/sgl-project/sglang/pull/28973)。
- 继续往 Diffusion 扩(Qwen-Image NVFP4)。

### TensorRT-LLM / TGI / Ollama
- **TRT-LLM**:出 v1.3.0rc19(https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc19)。重点:① 新增基于 `BaseResourceManager` 的 KV-cache 压缩管理框架(https://github.com/NVIDIA/TensorRT-LLM/pull/15106)——KV 压缩开始进框架层;② WideEP 容错加 MPI 信号处理替换(https://github.com/NVIDIA/TensorRT-LLM/pull/14160);③ AutoDeploy 持续(重开 disagg 测试、gpt-oss-120b 低并发性能优化、Gemma-4 NVFP4 入注册表);④ GPT-OSS disagg 走 transceiver v2(https://github.com/NVIDIA/TensorRT-LLM/pull/15301)。
- **TGI**:仓库**已 archived**(最后 push 2026-03-21),HuggingFace 已把推理重心移走,可从我们的竞品跟踪清单降级。
- **Ollama**:出 v0.30.11(rc0,https://github.com/ollama/ollama/releases/tag/v0.30.11-rc0)。主干一批 MLX 投机解码(MTP)工程化、Vulkan/CUDA 设备发现修复;另持续做"启动即自动装 Claude Code / opencode / Codex"的客户端集成(https://github.com/ollama/ollama/pull/16802)。对我们影响小,属边缘/桌面场景。

## 模型服务 & 编排

### KServe 上游
本周信息量最大,直接对标我们产品:
- **机密模型服务**:`feat: add support for confidential model serving`(https://github.com/kserve/kserve/pull/5382)——机密计算(TEE)路线进主干,企业安全合规卖点。
- **llmisvc 持续打磨**:加 `kvCacheOffloading` spec 做 CPU KV cache 分层(https://github.com/kserve/kserve/pull/5599)、加 `LLMInferenceServiceConfig` finalizer 防误删(https://github.com/kserve/kserve/pull/5400)、把 InferencePool readiness 收窄到 gateway refs(https://github.com/kserve/kserve/pull/5691)、EPP 端口默认 9002(https://github.com/kserve/kserve/pull/5698)。
- **latency predictor sidecar 自动注入**(按插件探测,https://github.com/kserve/kserve/pull/5678):SLO/排队预测能力开始内建。
- 依赖:llm-d 组件升 v0.7.0(https://github.com/kserve/kserve/pull/5596)、Gateway API 升 v1.5.1(https://github.com/kserve/kserve/pull/5478);修多节点 InferenceService Ready 卡 Unknown(https://github.com/kserve/kserve/pull/5703)。
- **启示**:KServe 把"机密计算 + KV 分层 + 延迟预测 + llm-d 集成"一周内全推进,我们 LLM serving 模块的差异化空间在被快速压缩,需盯紧 llmisvc CRD 形态。

### Ray
Serve 做架构换血,主线是 **HAProxy 取代 Python proxy 成默认 ingress**:
- HAProxy 加 gRPC(https://github.com/ray-project/ray/pull/63735)、系统/直连 ingress 指标(https://github.com/ray-project/ray/pull/64255、https://github.com/ray-project/ray/pull/64166)、root_path 支持(https://github.com/ray-project/ray/pull/64295);ingress 路由 pin-miss 回退到 fallback 代理而非 503(https://github.com/ray-project/ray/pull/64218);移除从源码构建 HAProxy(https://github.com/ray-project/ray/pull/64164)。
- **KV-aware 路由**:在 `KVRouterActor` 启用副本跟踪(https://github.com/ray-project/ray/pull/64085);为 body-aware router 解析直连流式路由 payload(https://github.com/ray-project/ray/pull/64328)。
- **SGLangServer 控制面对齐 vLLM**(https://github.com/ray-project/ray/pull/63021):Ray Serve LLM 多引擎策略落地;另用 model_id(而非 remote URI)作 VLLMEngineConfig 缓存键(https://github.com/ray-project/ray/pull/64110)。
- Train 侧:抢占信号扇出到 worker(https://github.com/ray-project/ray/pull/64099)。
- **启示**:Ray Serve 朝"生产级 LLM 网关 + PD/KV 感知路由"靠拢,和 KServe 在同一战场;HAProxy 化值得我们在做服务网关选型时参考。

### substratusai/lingo
仅测试清理与竞态修复(https://github.com/substratusai/lingo/pull/673)、openwebui chart 升级,无重大功能更新。

## 训练 & 微调
- **kubeflow/training-operator**:本周以工程治理为主(MPI SSH Secret 卷 defaultMode 修复 https://github.com/kubeflow/training-operator/pull/3649、KEP 迁到 proposals 目录、加 govulncheck CVE 扫描),无新训练能力。
- **LLaMA-Factory**:v1 线持续(修 device mesh / reward model LoRA / sequence parallel,https://github.com/hiyouga/LLaMA-Factory/pull/10555),新增 HyperParallel Context Parallel 特性(https://github.com/hiyouga/LLaMA-Factory/pull/10559)、新增模型支持(Hy-MT2、MiniCPM 4/5),并开始内置 "sft skills" 引导。社区活跃但偏单机微调,对平台侧借鉴有限。

## 模型生命周期(MLflow / Registry / Feast)
- **MLflow**:无 KV 级别功能,但战略信号强——① 官方文档新增「Add Red Hat OpenShift AI to Running Anywhere」(https://github.com/mlflow/mlflow/pull/24108),OAI 被列为一等部署目标;② 全面转 GenAI:Assistant 工具调用权限策略(静态 allow / 授权,https://github.com/mlflow/mlflow/pull/24084)、Playground 每工具 Monaco JSON 编辑卡片(https://github.com/mlflow/mlflow/pull/24129)、WAL daemon 把 OTLP span 写进 tracking store(https://github.com/mlflow/mlflow/pull/24089)。**启示**:实验追踪标准件正在变成"GenAI agent 可观测 + 权限治理"平台,我们的 tracing/治理选型要把它当事实标准对齐。
- **kubeflow/model-registry**:① catalog 加 **MCP source preview 端点**(https://github.com/kubeflow/model-registry/pull/2885)——Model Context Protocol 进模型目录;② Artifacts 端点加 security-metrics 枚举(https://github.com/kubeflow/model-registry/pull/2814);③ 冷启动 & VRAM 元数据文档更新(https://github.com/kubeflow/model-registry/pull/2882)。模型治理往"安全评估 + 冷启动资源画像 + MCP"扩,和我们模型生命周期模块强相关。
- **feast**:① 接入 **OpenLineage consumer**,接收/存储/可视化跨产出方血缘(https://github.com/feast-dev/feast/pull/6549);② 数据源创建做成可视化目录(https://github.com/feast-dev/feast/pull/6557);③ 文档明确用内建 Feature Quality Monitoring 取代 Great Expectations(https://github.com/feast-dev/feast/pull/6548);④ 新增时区时间戳特征类型。

## LLM 评估 & 安全
- **lm-evaluation-harness**:本周以任务/数据修复为主(LegalBench HELM-lite 子集 https://github.com/EleutherAI/lm-evaluation-harness/pull/3860;修 sglang args https://github.com/EleutherAI/lm-evaluation-harness/pull/3817;vLLM 忽略 device 参数时告警 https://github.com/EleutherAI/lm-evaluation-harness/pull/3803),无框架级变化。
- **NVIDIA/garak**:窗口内 main 无更新(最后实质 commit 2026-06-17,新增 simple adaptive attacks 探针刚好落在窗口前一天)。本周无重大更新。
- **meta-llama/llama-stack**:① **开出 Containers API**(`/v1alpha`,https://github.com/meta-llama/llama-stack/pull/5913)——把容器编排纳入栈内;② server 解耦 `stack.initialize` 与 authn/租户中间件(https://github.com/meta-llama/llama-stack/pull/6171);③ **breaking**:rerank 代码移到 sentence_transformers(https://github.com/meta-llama/llama-stack/pull/5882);④ 向量后端(Qdrant/Milvus/Elasticsearch)转 eager 集合初始化(https://github.com/meta-llama/llama-stack/pull/6144)。Meta 把 llama-stack 从"推理+安全"往"应用运行时(含容器/多租户)"扩,是潜在的全栈竞品形态。

## 值得跟进
- [ ] **KServe 机密模型服务(#5382)**:TEE 路线落地方式、对运行时/镜像的约束——直接关系我们企业安全合规卖点是否要跟。
- [ ] **KServe llmisvc `kvCacheOffloading`(#5599) vs vLLM OffloadingWorker(#45053)**:上下两层都在做 KV 分层,确认我们产品在哪一层接、是否复用 llm-d。
- [ ] **Ray Serve HAProxy 默认化 + KV 路由(#63735 / #64085)**:评估对我们服务网关/PD 路由选型的参考价值。
- [ ] **kubeflow/model-registry MCP source preview(#2885)+ security-metrics(#2814)**:模型目录"安全评估 + MCP"方向,看我们 registry 是否要对齐。
- [ ] **MLflow 把 OAI 列为一等部署目标(#24108)**:确认其 GenAI tracing/治理是否成为我们必须对接的事实标准。
- [ ] **llama-stack Containers API(#5913)**:留意 Meta 是否在做"全栈应用运行时"竞品,评估威胁等级。
- [ ] TGI 已 archived,建议从竞品跟踪清单降级或移除。
