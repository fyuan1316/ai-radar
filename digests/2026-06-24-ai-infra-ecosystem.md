# AI 推理 & MLOps 生态周报 2026-06-24

> 窗口:2026-06-17 ~ 2026-06-24。覆盖 16 个上游仓库,已过滤 version bump / dependabot / CI 噪音,只保留对"做云原生 AI 基础设施产品(对标 OpenShift AI)"有借鉴或威胁意义的变化。

## 摘要(5 条以内)

1. **KServe 这周信息量最大**:合入「机密模型服务(confidential model serving)」、新增 AutoGluon 运行时、把 Gateway Inference Extension 升到 v1.5.0、llm-d 组件升到 v0.7.0,LLMInferenceService(llmisvc)CRD 持续打磨 —— 直接踩在我们产品的赛道上。
2. **Ray Serve 做架构级换血**:把 HAProxy 定为默认 ingress 代理(取代 Python proxy),并落地 KV-aware 路由(KVRouterActor + 副本 KV 跟踪),朝 PD 分离 / 大规模 LLM 服务靠拢。
3. **MLflow 3.14.0 发版**,文档里专门加了 "Red Hat OpenShift AI" 接入页;产品重心明显转向 GenAI(Playground 工具卡、agent setup、OTLP tracing 落 WAL daemon)。
4. **推理引擎主线**:vLLM 推进 KV 分层卸载(tiering)与 Rust 前端;SGLang 落地解耦式投机解码 v2 + session radix cache;TRT-LLM 做 WideEP 容错(EPGroupHealth)。三家都在抢 DeepSeek-V4 / MiniMax-M3 的首发支持。
5. **模型治理 & 安全**:kubeflow/model-registry 给模型目录加 security-evaluations 与硬件/VRAM 冷启动元数据;garak 新增自适应越狱探针;feast 用内建 Feature Quality Monitoring 取代 Great Expectations。

---

## 推理引擎动态

### vLLM
无新 release,但主干高频(7 天 100+ commit)。值得看的方向:
- **KV 分层卸载持续加固**:加了 tiering 指标埋点与二级层工厂的单测(https://github.com/vllm-project/vllm/pull/45959 、 https://github.com/vllm-project/vllm/pull/46355),修了 CPU 卸载 connector 的 GPU→CPU store 竞态(https://github.com/vllm-project/vllm/pull/46278)。**启示**:vLLM 把"显存放不下就分层往 CPU/二级介质卸"做成一等公民,和我们 KV cache 容量规划、分层存储选型直接相关。
- **Rust 前端推进**:为 HTTP / 请求处理 / ZMQ 启用独立 runtime(https://github.com/vllm-project/vllm/pull/46051),并对齐 Rust 与 Python 的 token-id 校验语义。**启示**:vLLM 把 API gateway 层往 Rust 迁,瞄准高并发下的前端开销,值得关注其 serving 入口形态的变化。
- **新模型抢首发**:DeepSeek-V4 / GLM-5.1 在 SM120 上启用(https://github.com/vllm-project/vllm/pull/43477)、MiniMax-M3 BF16/FP8 indexer。
- DP 调度:按本地 prefill 工作量做 prefill 节流(https://github.com/vllm-project/vllm/pull/46532)。

### SGLang
无新 release,主干同样高频。产品相关信号:
- **解耦式投机解码 v2**:跨进程 request id + IPC 协议 + server flags 落地(https://github.com/sgl-project/sglang/pull/27634),配合 sync-free fast_prefill_plan。
- **session radix cache**(https://github.com/sgl-project/sglang/pull/27058):会话级前缀缓存,利好多轮对话场景命中率。
- **gRPC 原生 server** Python bridge 入口推进(https://github.com/sgl-project/sglang/pull/23507);ServerArgs 全量迁到 Annotated 风格,砍掉约 2400 行 CLI 代码(https://github.com/sgl-project/sglang/pull/28919)。
- 持续往 Diffusion / 图像生成扩(Krea 2、SANA、ERNIE-Image),SGLang 不再只盯 LLM。

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:发了 v1.3.0rc19(https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc19),已滚到 rc20。技术看点:**WideEP 容错**(EPGroupHealth 线程安全 rank mask、MPI 信号处理替换,https://github.com/NVIDIA/TensorRT-LLM/pull/13302 、 https://github.com/NVIDIA/TensorRT-LLM/pull/14160)—— 大规模专家并行下的故障恢复;以及成片的 "DSv4 prep"(compressor/IndexerTopK/attention fusion)和 MiniMax-M3 PyTorch 后端(BREAKING,https://github.com/NVIDIA/TensorRT-LLM/pull/15292)。注:该仓 commit 里大量是 QA CI waive,基本是噪音。
- **TGI**:本周无新提交,无重大更新。
- **Ollama**:发 v0.30.10(https://github.com/ollama/ollama/releases/tag/v0.30.10)。两点值得记:① Apple Silicon 的 MLX 引擎补齐投机解码(MTP);② launch 子命令开始**自动安装 Claude Code / opencode / codex**(https://github.com/ollama/ollama/pull/16802),Ollama 在把自己做成本地编码 agent 的模型后端入口 —— 是端侧/桌面侧的生态卡位。

---

## 模型服务 & 编排

### KServe 上游(本周重点)
- **机密模型服务**:`feat: add support for confidential model serving`(https://github.com/kserve/kserve/pull/5382)。TEE/机密计算进入模型服务,对企业级合规是强信号,**建议重点跟进其实现路径(CDI hook、readOnlyRootFilesystem 例外见 #5711)**。
- **新增 AutoGluon Server 运行时**(https://github.com/kserve/kserve/pull/5269):和昨天 OAI v3.5 把 AutoGluon 时序作为一等组件相互印证 —— 经典 ML / 时序在上游也补齐了。
- **GIE 升级到 v1.5.0**(带本地 v1alpha2 InferencePool shim,https://github.com/kserve/kserve/pull/5571)、**llm-d 组件升到 v0.7.0**(https://github.com/kserve/kserve/pull/5596)。LLM-native 服务这条线(llmisvc + InferencePool + EPP)在快速对齐 Gateway API Inference Extension。
- **LLMInferenceService(llmisvc)持续打磨**:加 config finalizer 防误删(https://github.com/kserve/kserve/pull/5400)、InferencePool readiness 限定到 gateway refs、EPP 端口缺省 9002;并修了多节点 InferenceService 的 Ready 卡 Unknown(https://github.com/kserve/kserve/pull/5703)。**启示**:KServe 的 LLM 专用 CRD 正从能用走向可生产,我们若有自研 LLM serving CRD 要对照它的 readiness / 多节点语义。

### Ray
无新 release,但 Serve 在做架构级调整:
- **HAProxy 成为默认 ingress 代理**(ray-haproxy,分 3 步合入,https://github.com/ray-project/ray/pull/64163),取代原 Python proxy,直奔吞吐与稳定性;配套大量 HAProxy stability 工作(优雅排空、reload 接管)。
- **KV-aware 路由落地**:新增 KVAwareRouter 接口与 KVRouterActor、副本 KV 跟踪(https://github.com/ray-project/ray/pull/64084 、 https://github.com/ray-project/ray/pull/64085);并在 PD 分离里避免双重 tokenize(https://github.com/ray-project/ray/pull/64049)。**启示**:Ray Serve 正把 PD 分离 + KV 感知路由做进框架核心,和我们(或 KServe llm-d)是同一套思路的竞品参照。
- Train 侧补了抢占处理(把 preemption 信号 fan-out 到 worker,https://github.com/ray-project/ray/pull/64099),利好 spot 训练。
- 移除了 Serve LLM config generator(https://github.com/ray-project/ray/pull/64075),配置生成方式有变,迁移时注意。

### 轻量部署(lingo / kubeai)
substratusai/lingo 仓库已 301 迁移(归到 kubeai 体系),本周仅测试清理与 openwebui chart 升级,无实质功能更新。

---

## 训练 & 微调
- **kubeflow/training-operator(现 kubeflow/trainer)**:准备 v2.2.1 发版(https://github.com/kubeflow/trainer/pull/3600),上线独立文档站,新增 govulncheck CVE 检测工作流。功能面无大变化,主要是工程化/合规收尾。
- **LLaMA-Factory**:新增 HyperParallel Context Parallel 能力(长上下文训练,https://github.com/hiyouga/LLaMA-Factory/pull/10559),并开始内置 "SFT skills" 引导。国内微调侧仍活跃。

---

## 模型生命周期(MLflow / Registry / Feast)
- **MLflow 3.14.0 发版**(https://github.com/mlflow/mlflow/releases/tag/v3.14.0)。两个对我们有用的点:① 文档新增 **"Red Hat OpenShift AI" 的 Running Anywhere 接入页**(https://github.com/mlflow/mlflow/pull/24108)—— 直接说明 MLflow 把 OAI 当一等部署目标;② 重心明显转 GenAI:Playground 工具卡 + Monaco JSON 编辑器、`mlflow agent setup`、OTLP span 落 tracking store(WAL daemon,https://github.com/mlflow/mlflow/pull/24089)、`@mlflow.test` 回归测试。**启示**:实验追踪标准品正在变成"GenAI 应用可观测 + agent 评测"平台,我们的模型生命周期模块要考虑 tracing/OTLP 对接。
- **kubeflow/model-registry**:给模型目录补**安全评估元数据**(security-evaluations.ndjson loader #2779、Artifacts 端点加 security-metrics 枚举 #2814)与**硬件/VRAM 冷启动元数据**(从 cold-start artifacts 解析硬件配置 #2852、冷启动&VRAM 文档)。**启示**:Registry 不只存模型,还要带"安全评估结果 + 硬件需求",对接调度/容量规划,值得我们 Registry 设计参考。catalog 还加了 `orderBy=RECOMMENDED`(#2819)。
- **Feast**:新增 zoned timestamp 特征类型(#6536);**弃用 Great Expectations DQM,改用内建 Feature Quality Monitoring**(https://github.com/feast-dev/feast/pull/6548)—— 数据质量监控收归框架内置。

---

## LLM 评估 & 安全
- **NVIDIA/garak**:新增 simple adaptive attacks 自适应越狱探针(https://github.com/NVIDIA/garak/pull/1742)。红队工具在往自适应攻击演进,做安全护栏要跟着升级测试集。
- **meta-llama/llama-stack**:① 新增 **Containers API**(/v1alpha 下,https://github.com/meta-llama/llama-stack/pull/5913),把"跑容器/代码执行"纳入栈内;② 重构把 stack.initialize 与 authn/多租户中间件**解耦**(https://github.com/meta-llama/llama-stack/pull/6171),多租户路径更清晰;③ vector-io(Qdrant/Milvus/Elasticsearch)改为 eager collection 初始化;④ 发了 Guardrails Responses API 博客。
- **lm-evaluation-harness**:本周只有小修(sglang 参数、vLLM device 警告、anthropic stop 序列),无重大更新。

---

## 值得跟进
- [ ] **KServe 机密模型服务(#5382)**:看它怎么落 TEE / 机密计算 —— 这是企业合规差异化点,优先级最高。
- [ ] **KServe llmisvc + GIE v1.5.0 + llm-d v0.7.0** 这条 LLM-native 服务线整体演进,对照我们自研 LLM serving 的 CRD/readiness 语义。
- [ ] **Ray Serve 的 HAProxy 默认化 + KV-aware 路由**:作为 PD 分离/KV 路由的竞品实现参照,评估是否影响我们架构选型。
- [ ] **model-registry 的 security-evaluations + 硬件/VRAM 元数据**:Registry 带安全评估与资源画像的设计,值得借鉴进我们的模型治理。
- [ ] **MLflow GenAI/OTLP tracing 转向**:评估模型生命周期模块对 OTLP span / agent 评测的对接需求。
- [ ] vLLM KV 分层卸载(tiering)成熟度,关系到我们 KV cache 容量与分层存储策略。
