# AI 推理 & MLOps 生态周报 2026-09-25

> 窗口:2026-09-18 ~ 09-25。只筛"对做云原生 AI 基础设施产品有借鉴/威胁"的变化,版本 bump / dependabot / CI 修复已过滤。
> 说明:vLLM v0.30.0、SGLang v0.5.20、KServe v0.21.0-rc1、kubeflow/hub v0.3.17 这几个大版本已在 09-23 周报详述,本期不重复,**只写 09-23 之后的增量**(新 release、新提交主题)。

## 摘要(5 条以内)

1. **Ollama v0.40.0-rc0:Apple Silicon 上默认切到 MLX runner**。MLX 支持的模型架构在 Apple Silicon 上默认用 MLX 跑(非 llama.cpp),这是边缘/桌面侧运行时的一次默认后端切换。参考:https://github.com/ollama/ollama/releases/tag/v0.40.0-rc0
2. **KServe master 正在造"分布式编译内核缓存"(KernelCache)**:新增 KernelCacheNode 生命周期 + node agent + reconciliation/watches,并接入 InferenceService config 与 Helm。这是继"Fast Start / OCI 模型交付"之后,上游又一条冷启动加速路线,直接对标我们的秒级扩缩容叙事。https://github.com/kserve/kserve/commits/master
3. **KServe 同期推进 mcv(模型缓存 OCI 交付)与 DisaggregatedSet(PD 分离)**:mcv 补齐 OCI image builder、snapshot/delta、capture sidecar;llmisvc 加 DisaggregatedSet groundwork(feature gate 后)+ CPU 推理遥测。llmisvc 在"OCI 交付 + PD 分离 + CPU 推理"三线并进。
4. **MLflow 引入服务端 executor 作业执行引擎**:job store 生命周期 API、执行恢复持久化 schema、租约续期、互斥锁、按 job 选择/持久化 executor backend,自定义 scorer 用 `MLFLOW_SERVER_ENABLE_CUSTOM_SCORERS` 门控。MLflow 在往"服务端任务执行/调度平台"扩,而不只是实验追踪。https://github.com/mlflow/mlflow/commits/master
5. **TensorRT-LLM v1.3.0rc28:KV cache 管理 V2 对 Llama/Llama4 默认开启 + 按源分层统计 KV 复用**;同时一批 BREAKING 移除(TensorRT serve / evaluation / benchmark / stress 旧路径)。仍是 rc、Known Issues 一长串,生产慎用。https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc28

---

## 推理引擎动态

### vLLM
本周无新 release(v0.30.0 已在 09-23 详述)。master 提交多为 v0.30 后的收尾:ROCm/MI355 性能与 CI、各家新模型(GLM-5.3-Flash / Kimi-K3 / Qwen3.8-Flash-Next / Minimax-M3)的 kernel 修补、Mamba2 prefill 去 GPU↔CPU 同步等,均属常规迭代,无架构级新动向。Commits: https://github.com/vllm-project/vllm/commits/main

### SGLang
本周无新 release(v0.5.20 已在 09-23 详述)。master 值得留意的方向:
- **PD 分离健壮性**:`gracefully_exit` 在 disaggregation event loop 中被尊重、非 0 rank launcher 在 SIGTERM 下存活(#40793)——PD 部署的优雅退出在补齐。
- **RL 训练面**:新增 `/v1/systemone` 兼容路由(#41208);启动期懒加载内建模型定义与 nixl_ep(#41061),缩短冷启动。
Commits: https://github.com/sgl-project/sglang/commits/main

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM v1.3.0rc28**(https://github.com/NVIDIA/TensorRT-LLM/releases/tag/v1.3.0rc28):对基础设施最相关的是 KV cache 侧——**KV-cache manager V2 对 Llama/Llama4 默认启用**(#19004)、**按源分层(source tier)统计 KV 复用并扩展 connector**(#18583/#18762)、统一原生 KV 传输的协调/准入/后端契约(#19128 等),外加 NCCL-EP 0.2 低延迟专家并行(#18689)。**BREAKING**:移除 TensorRT serve/evaluation/benchmark/stress 旧路径(#19022 等)、移除 Eagle choices 配置字段。Known Issues 覆盖多节点启动、disagg hostname 解析、多模型精度/hang,不建议上生产。
- **TGI**:仓库仍 archived,无更新(正常停维护)。
- **Ollama**:**v0.40.0-rc0**——MLX 支持的架构在 Apple Silicon 默认走 MLX runner(https://github.com/ollama/ollama/releases/tag/v0.40.0-rc0)。**v0.34.4**(https://github.com/ollama/ollama/releases/tag/v0.34.4):thinking 模型的结构化输出改单趟完成(更快更稳)、修大本地库下的 "model not found"、Qwen3.8 在 Apple Silicon 提速。

---

## 模型服务 & 编排

### KServe 上游
无新 release(rc1 已详述),但 **master 在 rc1 之后加了几块重量级功能**,是本期最值得盯的信号:
- **KernelCache(分布式编译内核缓存)**:新增 KernelCacheNode 生命周期与 node agent(#6251)、reconciliation 与 watches(#6267)、runtime 选项 identity resolver(#6279),并把 KernelCache 设置接入 InferenceService config(#6249)与 Helm ConfigMap(#6283)。判断是把编译后内核/图缓存做成集群级、按节点管理的资源,服务于冷启动/重复编译消除。
- **mcv(模型缓存 / OCI 交付)**:一整条链路落地——cache snapshot(#6225)、OCI image builder(#6226)、snapshot 与 delta CLI(#6233)、capture sidecar 编排(#6240),并文档化 OCI delta 与 capture sidecar(#6242)。与上游"OCI 模型交付"方向一致。
- **PD 分离**:llmisvc 加 DisaggregatedSet groundwork(feature gate 后,#6271)。
- **CPU 推理**:llmisvc 新增 CPU 推理遥测指标(#6232)、用 `CPUOffloadingSpec` 做 CPU-only KV cache 卸载(#6086)。
- 安全:所有 controller 的 metrics 端点启用 SecureServing(#6007)。

**启示**:KernelCache + mcv 两条线合起来,是 KServe 把"模型/内核交付与缓存"做成一等的集群资源。如果我们基于 KServe fork,建议提前评估 KernelCacheNode/node-agent 这套新组件对现有部署拓扑的影响,以及 mcv 的 OCI 交付是否与我们自有的模型分发方案冲突或可复用。

### Ray
无新 release。master 基础设施相关:
- **GCS 主动-被动(Active-Passive)HA 推进**:Phase 2.3 被动 head 生命周期变更(#66222)、actor 在 GCS init 时缺 task spec 不再 FATAL(#66073)——控制面高可用在补。
- **Ray Serve 稳定性**:修 deployment 移除时 KeyError 卡住应用控制循环(#66438);移除 async inference 的 QueueMonitor 及其 controller 侧指标(#66405)。
- **实验性 Ray Sandbox**:新增 HTTP API service(#65633)、gVisor 后端支持 per-exec user(#65942)——沙箱执行方向。
Commits: https://github.com/ray-project/ray/commits/master

### KubeAI(原 substratusai/lingo)
本周无提交,持续静默(与 memory 记录一致)。

---

## 训练 & 微调
- **Kubeflow Trainer**(原 training-operator):仅 1 条实质提交——给"无数据文件的 worker"一条 readiness 路径(#4058)。无重大更新。https://github.com/kubeflow/trainer/commits/master
- **LLaMA-Factory**:窗口内无过滤后提交,无重大更新。

---

## 模型生命周期(MLflow / Registry / Feast)

### MLflow — v2.11.5(patch) + master executor 引擎
- **v2.11.5**(https://github.com/mlflow/mlflow/releases/tag/v2.11.5):仅一条 feature——UC 模型注册表制品上传/下载可选走 Databricks SDK Files API。
- **master 重头戏:服务端 executor 作业执行引擎**。一连串提交搭出框架:executor registry 与启动校验(#22974)、job 持久化恢复 schema(#22520)、job store 生命周期 API(#23128)、LocalJobExecutor(#24680)、按 job 选择并持久化 executor backend(#25550)、执行引擎上的互斥锁(#25555)、运行中续租(#25293),自定义 scorer 用 `MLFLOW_SERVER_ENABLE_CUSTOM_SCORERS` 门控(#25993)。**判读**:MLflow 在把"服务端可恢复的任务执行/调度"做成平台能力,和我们模型服务/评估流水线的作业编排可能重叠,值得盯。

### Kubeflow Model Registry(现 kubeflow/hub)
无新 release(v0.3.17 已详述)。master 延续 catalog 化 + HF 门控主题:MCP runtimeMetadata 加 storage(#3238)、OpenAPI 保留子资源过滤参数(#3237)、拒绝 v1 spec 未声明的 orderBy 返 400(#3222)、catalog alpha API 加 RFC 8594 弃用头(#3221)。无架构级新变化。https://github.com/kubeflow/hub/commits/main

### Feast
无新 release。master 有几条实质变化:IcebergSource 的离线批量写(offline write batch)、在线服务热路径削减 metrics/audit 开销(perf)、离线 server 读用 do_exchange 以支持 HPA、Trino DECIMAL→pyarrow decimal128 映射修复。属稳步补数据源与在线服务性能。https://github.com/feast-dev/feast/commits/master

---

## LLM 评估 & 安全
- **lm-evaluation-harness**:窗口内无过滤后提交,无重大更新。
- **NVIDIA/garak**:窗口内无过滤后提交,无重大更新。
- **meta-llama/llama-stack**(release 仍发在此仓,PR 指向 ogx-ai/ogx):本周无新 release。master 值得注意:**新增 Serply web search provider**(#6636)、vLLM rerank 走 raw-httpx 拦截以便录制(#6638),以及大量 CI 录制/回放(vLLM 原生跑、llama.cpp router 作为录制后端)与依赖治理(transformers 迁 5.x、pymongo 补 CVE)。**判读**:应用栈在补 web search / rerank 这类 provider,并把 provider 兼容性用录制/回放锁死——对做"可插拔推理/工具 provider"的产品是可借鉴的测试范式。https://github.com/meta-llama/llama-stack/commits/main

---

## 值得跟进
- [ ] **KServe KernelCache**:评估 KernelCacheNode + node agent 这套新集群组件对我们部署拓扑的影响,以及能否用于消除重复编译/加速冷启动。https://github.com/kserve/kserve/commits/master
- [ ] **KServe mcv(OCI 模型交付)**:snapshot/delta/capture sidecar 是否与我们自有模型分发方案冲突或可复用。
- [ ] **MLflow 服务端 executor 引擎**:与我们评估/服务流水线的作业编排是否重叠,是竞品还是可集成。
- [ ] **Ollama MLX 默认化**:若我们涉及边缘/桌面侧,注意 Apple Silicon 默认 runtime 从 llama.cpp 变 MLX 带来的行为差异。
- [ ] **TensorRT-LLM KV manager V2 / 按源分层 KV 复用**:关注其 connector 契约与我们 KV 分层/卸载设计的可对齐点(仍 rc,勿上生产)。
