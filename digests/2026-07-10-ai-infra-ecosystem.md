# AI 推理 & MLOps 生态周报 2026-07-10

> 窗口:2026-07-03 ~ 2026-07-10(过去 7 天)。仅筛选对"做云原生 AI 基础设施产品(对标 OpenShift AI)"有用的变化;版本 bump / dependabot / CI / 纯 docs 噪声已跳过。源仓库改名沿用记忆(lingo→kubeai、training-operator→trainer、model-registry→hub、llama-stack→ogx)。

## 摘要(5 条以内)

1. **Kubeflow Model Registry(现 kubeflow/hub / AI Hub)本周主线是"Agent + MCP catalog"**:新增 Agent catalog 端点与 UI、MCP catalog 设置 API、agent 插件的 artifacts 端点——上游把模型注册表往"Agent/MCP 资产目录"扩,是模型生命周期赛道最值得警惕的方向变化 https://github.com/kubeflow/hub/pull/2912
2. **分层 KV 缓存/卸载继续成跨项目主线**:vLLM 二级 FS/OBJ 层发 tier-owned BlockStored 事件 + CPU 卸载空闲块调度,KServe 给 KV offloading 加二级文件系统层,SGLang 在 DeepSeek-V4 上打通 unified-KV HiCache——显存不足下托管大模型/长上下文的成本优化仍是共识焦点。
3. **"AI 网关 + RBAC/鉴权"在 MLflow 与 OGX(原 llama-stack)双线收紧**:MLflow 让 OpenAI 协议的编码 Agent 走 RBAC 网关鉴权、并对 LogInputs 等端点强制授权;OGX 加 --insecure 自签 TLS、把 Anthropic 消息统一走 InferenceProvider——企业级多租户接入正在被标准化。
4. **服务化接口向"生产级 + 可观测"演进**:SGLang 推 gRPC 解耦(disaggregated)生成接口、支持 CPU 上投机解码;Ray Serve 给 LLM Grafana 面板加 Cluster 过滤、从 haproxy 直接吐请求指标、修控制面 recovery 的 rank 错乱;KServe llmisvc 补受控灰度 traffic splitting API。
5. **无重大更新的**:TGI(窗口内零提交)、lm-evaluation-harness(零提交)、garak(仅测试重构)、Kubeflow Trainer / LLaMA-Factory(仅 docs/webui/deps 级改动)。

## 推理引擎动态

### vLLM
- 本周切 v0.25.0 RC 列车(rc1→rc3,窗口内 100+ commit;最近稳定版仍是 v0.24.0 / 6-29) https://github.com/vllm-project/vllm/releases/tag/v0.24.0
- 分层 KV 卸载继续体系化:二级 FS/OBJ 层发出 tier-owned BlockStored 事件(#47923),并为 CPU 卸载加空闲块迭代器做调度(#47849)——多租户/显存不足下的托管成本优化 https://github.com/vllm-project/vllm/pull/47923
- KV 缓存可观测性:全量报告模式下上报 prefix-cache 复用块(#45261),利于缓存命中率量化与计费 https://github.com/vllm-project/vllm/pull/45261
- 安全硬化:清洗校验错误响应里的服务器文件路径(#46415),并给 completion prompt 列表设界防止引擎无界 fan-out(#47845)——面向多租户暴露 API 的准入相关 https://github.com/vllm-project/vllm/pull/47845
- 投机解码:支持混合(SWA+full attention)DFlash drafter(#47914),低延迟推理能力继续补 https://github.com/vllm-project/vllm/pull/47914

### SGLang
- 窗口内无新正式版(v0.5.14 / 6-26 为最新,主线在备 v0.5.15),100+ commit https://github.com/sgl-project/sglang/releases/tag/v0.5.14
- 服务化:gRPC 支持解耦(disaggregated)生成请求(#30440),朝生产级 P/D 分离接口演进,利于与云原生控制面集成 https://github.com/sgl-project/sglang/pull/30440
- 支持在 CPU 上做投机解码(#27862),扩大无 GPU/边缘部署面 https://github.com/sgl-project/sglang/pull/27862
- 分层缓存:DeepSeek-V4 打通 unified-KV HiCache(#29417)、JIT staged HiCache 回写(#28534),与 vLLM/KServe 的分层卸载呼应 https://github.com/sgl-project/sglang/pull/29417
- 调度器加固:去除 Scheduler 基于字段的隐式旁路(#29408)、CUDA graph 关闭按 P/D 角色区分(#30409),对稳定性有利 https://github.com/sgl-project/sglang/pull/30409

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**(v1.3.0rc20 / 6-30,100+ commit):暴露启动期 KV cache 容量查询(#15385,利于容量规划)、Disaggregated KV-cache bounce transfer(#15618)、PyTorch encoder-decoder 张量并行(#15897),cache transceiver 传输上报确定化(#15893) https://github.com/NVIDIA/TensorRT-LLM/pull/15385
- **TGI**:窗口内零提交、无新版本,无重大更新 https://github.com/huggingface/text-generation-inference
- **Ollama**:发稳定版 v0.31.2(7-6),CC 6.x 老 NVIDIA GPU 启用 FlashAttention、iGPU 视觉模型带 padding 卸载、`ollama launch` 对接 Claude Code 默认关遥测;偏边缘/桌面,基础设施侧借鉴有限 https://github.com/ollama/ollama/releases/tag/v0.31.2

## 模型服务 & 编排

### KServe 上游
- llmisvc 新增 traffic splitting API,支持受控灰度部署(#5727),补齐模型上线的金丝雀/蓝绿能力 https://github.com/kserve/kserve/pull/5727
- KV cache offloading 加二级文件系统层(#5740,GPU→CPU→POSIX 多级),长上下文/高并发下的显存与成本优化 https://github.com/kserve/kserve/pull/5740
- Envoy AI Gateway 升到 v1.0.0 + Envoy Gateway v1.8.1(#5723),LLM 网关依赖走向 GA https://github.com/kserve/kserve/pull/5723
- llmisvc 升级 llm-d-sim 镜像并在启用时设 TLS(#5783),延续与 llm-d 的深度绑定 https://github.com/kserve/kserve/pull/5783

### Ray
- Ray Serve LLM 可观测性:Grafana 面板加 Cluster 过滤(#64596)、从 haproxy 直接 emit 请求指标(#64329) https://github.com/ray-project/ray/pull/64596
- Serve 控制面稳定性:health-check 就地 reconcile(#64507)、修 recovery 后 rank 错乱(#64636)、修 direct-ingress backpressure 计数泄漏(#64348) https://github.com/ray-project/ray/pull/64636
- Serve LLM direct-streaming 模式启用 `/classify` 与 `/pooling` 端点(#64494),扩非生成类推理接口 https://github.com/ray-project/ray/pull/64494
- 移除 cluster autoscaler v1(#64380),弹性伸缩全面转 v2 https://github.com/ray-project/ray/pull/64380

## 训练 & 微调
- **Kubeflow Trainer**(原 training-operator):无重大更新,窗口内以 docs/deps 为主;实质改动仅 TrainJob reconciler 尊重 managedBy 字段(#3681)、Runtimes 支持 label 关闭 webhook 校验(#3683) https://github.com/kubeflow/trainer/pull/3681
- **LLaMA-Factory**:无重大更新,主要是 v1 上手文档、webui 加复现种子控制(#10629)、排除 broken transformers 版本;无框架级变化 https://github.com/hiyouga/LLaMA-Factory/pull/10629

## 模型生命周期(MLflow / Registry / Feast)

### Kubeflow Hub(原 model-registry / AI Hub)—— 本周重点
- 新增 Agent catalog:创建 Agents catalog(#2908)、加 Agent catalog 端点(#2912)、agent 插件加 artifacts 端点与 template artifact type(#2928) https://github.com/kubeflow/hub/pull/2912
- MCP catalog:新增 MCP catalog 设置 API 状态/类型(#2905)、UI 展示 MCP server displayName(#2906)——注册表正在扩成"模型 + Agent + MCP" 统一资产目录 https://github.com/kubeflow/hub/pull/2905
- 安全:CSI 驱动拒绝格式非法的 model-registry URI(#2911) https://github.com/kubeflow/hub/pull/2911

### MLflow
- 让 OpenAI 协议的编码 Agent 走 RBAC 网关鉴权(#24294),AI Gateway 的企业级接入继续收紧 https://github.com/mlflow/mlflow/pull/24294
- 鉴权硬化:LogInputs 端点强制 update-run 授权(#24291)、auth proxy 解析带 workspace 前缀的 artifact 路径(#24214)、修 basic-auth before-request 校验器(#24354) https://github.com/mlflow/mlflow/pull/24291
- Agent 工具化:in-app MLflow Assistant + `mlflow agent setup`(#24041) https://github.com/mlflow/mlflow/pull/24041

### Feast
- 新增 ScyllaDB online store 且带向量检索(#6508),在线特征库继续往"向量+特征"融合扩 https://github.com/feast-dev/feast/pull/6508
- 修 MySQL 上 SQL registry proto 列改用 LONGBLOB(#6566) https://github.com/feast-dev/feast/pull/6566

## LLM 评估 & 安全
- **lm-evaluation-harness**:窗口内零提交,无重大更新 https://github.com/EleutherAI/lm-evaluation-harness
- **garak**:仅测试重构(leakreplay probe 结构测试去阴影,#1914),无新探针,无重大更新 https://github.com/NVIDIA/garak/pull/1914
- **OGX(原 meta-llama/llama-stack)**:加 --insecure 自签 TLS 一键起(#6243)、把 Anthropic 消息统一走 InferenceProvider 抽象(#6264)、telemetry 加 agentic depth / RAG depth 指标(#6252)、docling VLM 处理走 stack inference API(#6225) https://github.com/ogx-ai/ogx/pull/6252

## 值得跟进
- [ ] **Registry→AI Hub 的 Agent/MCP catalog**:上游把模型注册表扩成 Agent+MCP 资产目录,评估我们模型生命周期产品是否要跟进"Agent/MCP 目录"这一层 https://github.com/kubeflow/hub/pull/2912
- [ ] **分层 KV 卸载三家趋同**(vLLM tier 事件 / KServe 二级 FS 层 / SGLang unified-KV HiCache):可对照我们托管面的显存卸载策略与可观测事件 https://github.com/kserve/kserve/pull/5740
- [ ] **AI 网关 RBAC 收紧**(MLflow 编码 Agent 走 RBAC 网关 + OGX TLS/InferenceProvider):对标我们多租户 Agent/LLM 接入的鉴权门禁 https://github.com/mlflow/mlflow/pull/24294
- [ ] **KServe llmisvc traffic splitting**:上游金丝雀/灰度 API 成型,评估与我们发布流水线的整合 https://github.com/kserve/kserve/pull/5727
- [ ] **vLLM v0.25.0 正式版**:关注 RC 转正后的 KV 卸载/安全硬化默认项 https://github.com/vllm-project/vllm/releases
