# AI 推理 & MLOps 生态周报 2026-07-29

> 窗口:2026-07-22 ~ 2026-07-29。仓库改名已核对(lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、llama-stack→ogx-ai/ogx、LLaMA-Factory 大小写)。TGI、lm-evaluation-harness 窗口内无提交,略。

## 摘要(5 条以内)

1. **vLLM v0.26.0 与 SGLang v0.5.16 同周发版,双双为 Thinking Machines 的 Inkling(975B 多模态 MoE、1M 上下文)做 day-0 支持**——两大引擎对同一新旗舰模型抢首发,且 vLLM 把 **KV offloading + 分层二级存储(object-store 二级层带 workload identity)** 做成一等公民,KV 缓存分层正成为推理引擎的竞争前沿。
2. **KServe 上游 llmisvc 继续加固,并首次给出"agentic 工具调用"指南与样例(#5906)**:disagg-sidecar 换新 TLS flag(#5875)、LLMIServiceConfig CRD 剥离校验(#5888)、v1alpha2 InferencePool 缺 CRD 时跳过 reconcile(#5890)——企业级 LLM 服务面 + Agent 方向明确,仍是对标我们产品的头号专项。
3. **MCP 继续渗透 MLOps 控制面,并冒出"Skills Catalog"新形态**:MLflow 本周把 **MCP Registry UI 整套建起**(RBAC 门禁、对比视图、别名/标签、遥测);Kubeflow Hub 提出 **Skills Catalog 提案(SKC-101,#2973/#3015)**,模型目录正扩展为"模型 + Agent + MCP + Skill"目录。
4. **安全信号密集且偏"供应链/反序列化/注入"**:Ray 修 `read_lance` 任意代码执行 RCE(#64881);MLflow 给 statsmodels 加 pickle 反序列化开关、强制 presigned 下载鉴权;ogx 三条发布线(0.4.x/0.7.x/1.2.x)集中刷 CVE 依赖;garak 硬化 markdown 数据外泄检测器。
5. **异构算力抽象全面前移**:Ray 一周内落地 **TPU backend for Ray Train、GB200/GB300 加速器常量、RDT NIXL 跨设备传输、TTNPU 资源**;LLaMA-Factory 改进 NPU 镜像。调度层对多加速器的抽象是硬门槛。

---

## 推理引擎动态

### vLLM
**v0.26.0(07-27,411 commits / 212 contributors)** —— 对我们最有意义的结构性变化:
- **KV offloading 与分层二级存储成熟**:offloading 指标(#45958/#47666)、tier-owned 事件处理(#46544/#47923)、**带 workload identity 的 object-store 二级层**(#47063/#47274/#48150)、DP-replica 感知的分层(#47987)、encoder-cache 连接器含 CPU offload(#42433)。这是把"KV 缓存当分布式存储管"的方向,直接关系推理集群的成本与弹性。
- **灵活注意力后端**:注意力后端可**按 KV-cache group 逐组选择**(#48012),滑窗成为后端显式能力(#48011)——为混合注意力模型(全注意力+滑窗+线性)铺路。
- **Inkling 全栈支持**:基座建模 + piecewise CUDA graph + Hopper FA4 相对注意力 + MTP=1 投机 + LoRA + NVFP4 量化(#48799 起一整串)。
- **DeepSeek-V4 性能推进**:专用路由 kernel(E2E TPOT +2.94%)、`fused_topk_bias`(kernel 1.5–2x)、冗余 copy 移除;ROCm/XPU 上 DSpark 投机解码。
- **Rust 前端**补齐多模态 video/audio、原生 `vllm-bench` 移植;升 Transformers 5.13.0,更多模型迁到 transformers 建模后端。
- 来源:https://github.com/vllm-project/vllm/releases/tag/v0.26.0

### SGLang
**v0.5.16(07-25,574 PRs / 169 contributors)** —— 亮点密集:
- **DSpark:置信度驱动投机解码**(新算法)——按草稿自身置信度动态定 verify 窗口而非固定草稿长度,DeepSeek-V4-Pro / B300 / TP8 上达 **383.7 tok/s**(accept length ~5)。`--speculative-algorithm DSPARK`。(#30261/#31434)
- **Inkling day-0**:975B 多模态 MoE,混合滑窗/全/Mamba2 线性注意力 + NVFP4 MoE,Blackwell 上 71.7k tok/s 输入、171 tok/s/用户解码;H200、AMD MI350X/MI355X 均验证。(#31681)
- **UnifiedRadixTree 成为 SWA/Mamba/DSA 模型默认**,缓存命中只重置用到的状态(#30468 等)。
- **GLM-5.2 DSA 缓存按层在 prefill CP 下切分**:每 rank 只持有不相交层区间,8192 token 下每 rank KV 内存 **-74%**(0.77→0.20 GB)。`--enable-dsa-cache-layer-split`(#29421)。
- 来源:https://github.com/sgl-project/sglang/releases/tag/v0.5.16

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:本窗口无新 release(v1.3.0rc22 已在上周覆盖),无重大更新。
- **Ollama v0.32.4(07-25)/ v0.32.5(07-27)**:Apple GPU 经 **MLX 引擎跑 Laguna**;**投机解码草稿模型的输出头按请求类型量化**;修 Qwen3 MoE 不同量化 expert 解码 + 打包 gate/up 投影提速 4–9%(M5 Max);0.32.5 修 NVFP4 模型(尤其 Laguna)MLX Metal 精度 bug。https://github.com/ollama/ollama/releases/tag/v0.32.5
- **TGI**:窗口内无提交,无重大更新。

> **跨引擎信号**:Inkling(Thinking Machines 975B)一周内被 vLLM 与 SGLang 同时 day-0 收编,说明前沿模型的引擎适配窗口已压缩到"发布即支持"。若我们平台内嵌推理引擎,选型需以"能否 day-0 跟上主流新模型"为硬指标。

## 模型服务 & 编排

### KServe 上游
提交仍高度集中在 `llmisvc`,并新增 Agent 方向:
- **Agentic**:`docs(llmisvc): agentic tool calling guide and samples`(#5906)——首次给出 LLM 服务面做工具调用/Agent 的官方样例。
- **安全**:`feat: integrate with cluster TLS security profile`(#5791);disagg-sidecar 换用新 TLS flag(#5875)。
- **API 收敛**:LLMIServiceConfig CRD 剥离校验逻辑(#5888)、tokenizer 关闭时跳过 pod spec 构建(#5913)、v1alpha2 InferencePool 缺 CRD 时跳过 reconcile(#5890)、`--model-server-metrics-scheme` 迁移(#5892)、`--kv-transfer-config` 引号转义(#5880)。
- 来源:https://github.com/kserve/kserve/commits/master
- **启示**:llmisvc = 集群 TLS profile + InferencePool + KV-transfer(P/D 分离)+ 现在的 agentic 工具调用,一整套企业级 LLM 服务面持续成型,建议单开专项跟 v1alpha2 API 定型。

### Ray
无新 release(2.56.1 已覆盖),但主干信号极强:
- **Serve LLM 性能**:把 **tokenization 移进 `LLMRouter` ingress replica 进程内**(#64642);direct-streaming ingress 路由到同置 router(#64489);新增 Ray Serve LLM 的 **SGLang metrics dashboard**(#64797)。
- **安全(高危)**:修 `read_lance` / 嵌套 pickle 的**任意代码执行 RCE**(#64881)。
- **抢占/容错**:公开 **preemption API 与 controller PreemptingState**(#64360);active-passive 引入原生轻量 C++ leader election(#63773);多处 GCS actor 调度/背压死锁修复。
- **异构算力**:**Ray Train 的 PyTorch TPU backend**(#64796)、**GB200/GB300 加速器常量**(#65009)、**RDT NIXL 跨设备传输**(#64815)、TTNPU 自定义加速器资源(#61554)、TPU 子切片 gang 调度(#64578)。
- 升级到 **vLLM 0.26.0**(#65045)。
- 来源:https://github.com/ray-project/ray/commits/master

### KubeAI(原 substratusai/lingo)
- 窗口内无新提交,无重大更新(v0.23.3 已在上周覆盖)。

## 训练 & 微调

### Kubeflow Trainer(原 training-operator)
- v2.3.0-rc.3(07-24)后进入收尾,仅稳定性修复:校验 cache storage URI(#3741)、PodSets.Count 传播进 Parallelism/Completions(#3651)、移除重复 TrainJob status patch(#3448)。**OptimizationJob(KEP-3562)已在上周落地,本周无新结构变化**,静待 v2.3.0 GA。https://github.com/kubeflow/trainer/commits/master

### LLaMA-Factory
- **接入 megatron-bridge 做 PT/SFT 训练**(#10645)——向 Megatron 大规模并行栈靠拢;v1 registry plugin 结构重构(#10641);**改进 NPU 镜像构建与分发**(#10664)。https://github.com/hiyouga/LLaMA-Factory/commits/main

## 模型生命周期(MLflow / Registry / Feast)

### MLflow
无新 release,但方向明确——**MCP 一等公民化 + AI Gateway 治理**:
- **MCP Registry UI 整套建起**:foundation/列表卡片/详情页(版本/别名/标签)/RBAC 门禁 + 对比视图(#24145→#24509)、遥测埋点(#24477)、图标解析、自动发现工具。
- **AI Gateway 治理增强**:**按 endpoint 的预算策略**(#24370)、**Portkey 路由配置**(#24398)。
- **原生 FastAPI 流式 artifact 上传/下载**(#24340)+ presigned 能力经 `/server-info` 广播、Python 客户端自动探测(#24341)。
- **安全**:`MLFLOW_ALLOW_PICKLE_DESERIALIZATION` 守卫 statsmodels flavor(#24686)、强制 presigned 下载路由鉴权(#24571)、修 k8s auth token 提取(#24687)。
- GenAI:`{{ trace }}` judge 可看轨迹里的图像(#24590)。https://github.com/mlflow/mlflow/commits/master

### Kubeflow Hub(原 model-registry / AI Hub)
- **Skills Catalog 提案(SKC-101)**:Kubeflow 里加 Skills Catalog 的设计提案(#2973)+ OpenAPI spec 与 codegen(#3015)——目录从"模型 + Agent + MCP"再扩到 **Skill**。
- MCP/Agent catalog 的 YAML 数据文件热重载(#2997);为 Model Registry 出 **v1 OpenAPI specs**(#3013)。https://github.com/kubeflow/hub/commits/main

### Feast
无新 release(v0.65.0 已覆盖),主干偏**多租户 + 企业鉴权 + 向量检索**:
- **共享 registry 上支持受保护 project**(protected project on shared registry)——多租户隔离;
- **OIDC 支持 Entra ID(Azure AD)token claims**(#6631);feast operator 镜像多架构发布;
- **Feast 向量库兼容 OpenAI search API**(#6121);UI 加 Feature Service 创建、datasets 分组/命名空间。https://github.com/feast-dev/feast/commits/master

## LLM 评估 & 安全

- **ogx(原 llama-stack)**:三条发布线同日刷版(**v1.2.2 / v0.7.3 / v0.4.7**,07-27),内容以 **CVE 依赖收敛**为主(pyasn1/pillow/urllib3/aiohttp/litellm 等一大批)。主干功能:**新增 DeepSeek 远程推理 provider**(#6240)、**对不可信 web_search/file_search 工具输出做定界再回喂模型防注入**(#6337)、responses 补 file_citation 注解(#6292)、passthrough OpenAI 客户端 `_enforce_credentials=False`(#6344)。https://github.com/ogx-ai/ogx/releases
- **NVIDIA/garak**:**web_injection markdown 数据外泄检测器硬化**(对抗域名/扩展名/参数规避,#1928)、StringDetector 加 **Unicode 归一化**(#1884)、新增 **technique/intent 标注与 IntentProbe**(#1984)、NeMoGuardrails/LangServe generator 兼容性修复。无新 release。https://github.com/NVIDIA/garak/commits/main
- **EleutherAI/lm-evaluation-harness**:窗口内无提交,无重大更新。

## 值得跟进

- [ ] **KServe llmisvc 加入 agentic 工具调用**:企业级 LLM 服务面 + Agent 融合,直接对标我们产品,建议开专项跟 v1alpha2 API 与 agentic 样例。https://github.com/kserve/kserve/pull/5906
- [ ] **KV 缓存分层成推理引擎竞争前沿**:vLLM object-store 二级层(带 workload identity)、SGLang UnifiedRadixTree + DSA 按层切分(-74% KV 内存)——评估我们服务面是否要暴露 KV 分层/远端缓存能力。https://github.com/vllm-project/vllm/releases/tag/v0.26.0
- [ ] **"Catalog"从模型扩到 MCP/Agent/Skill**:MLflow MCP Registry UI、Kubeflow Hub Skills Catalog(SKC-101)同周推进,需判断我们的模型/工具/技能目录路线。https://github.com/kubeflow/hub/pull/2973
- [ ] **供应链/反序列化/注入类安全**:Ray read_lance RCE、MLflow pickle 守卫、ogx CVE 批量、garak 外泄检测——把"反序列化安全 + 工具输出定界"纳入我们平台安全基线。https://github.com/ray-project/ray/pull/64881
- [ ] **异构算力抽象**:Ray 一周内 TPU/GB200/GB300/TTNPU 全上,LLaMA-Factory NPU 镜像——校验我们调度层对多加速器的抽象覆盖度与 day-0 跟进能力。https://github.com/ray-project/ray/pull/64796
