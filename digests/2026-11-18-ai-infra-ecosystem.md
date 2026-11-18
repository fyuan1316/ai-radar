# AI 推理 & MLOps 生态周报 2026-11-18

窗口:2026-11-11 ~ 2026-11-18(过去 7 天)。已过滤版本 bump、dependabot、CI、纯文档和测试 waive。
源仓库沿用改名后的路径:lingo→kubeai-project/kubeai、training-operator→kubeflow/trainer、model-registry→kubeflow/hub、llama-stack→ogx-ai/ogx(release 仍看 meta-llama/llama-stack)。

## 摘要(5 条以内)

1. **vLLM v0.34.0 默认行为变化大,升级要逐项核对**:可扩展 KV cache 默认开启,`gpu_memory_utilization` 默认值改成 1.0,KV 按 warmup 后实际空闲显存分配(#56492);Model Runner V1 删除,只剩 V2(#63373);默认 `--block-size` 从 16 改为 64(#63231);要求 `huggingface_hub>=2.0`;ROCm 7.2 镜像停发。release 也把 CRIU + `cuda-checkpoint` 进程级 checkpoint/restore 做成了 HTTP 生命周期接口(#62570)。对平台的影响:按 0.9 显存比例做 GPU 共享或配额估算的部署会被打破,冷启动加速也多了一条「快照恢复」的路。 https://github.com/vllm-project/vllm/releases/tag/v0.34.0
2. **Feast 修复一个可绕过 RBAC 的伪造令牌漏洞**:服务间调用原先只比对令牌里未验签的 username/sub 是否等于 `INTRA_COMMUNICATION_BASE64`,而 Helm chart 把这个值写死在模板里,任何人都能伪造无签名令牌跳过全部 RBAC。修复后改为 HS256 签名并验签,chart 改从 Secret 读取,未配置时关闭服务间调用;同周 K8s 令牌解析改走 TokenReview。用 Feast 做 Feature Store 的部署需要升级并重新配置 Helm。 https://github.com/feast-dev/feast/commit/b5326fd0811ee162a813f8ea6a09890cb62c147e
3. **SGLang 删除 sgl-model-gateway(约 12.6 万行),路由层统一到 sgl-router**:网关专有路径(`/workers`、`/ha/*`、`/engine_metrics` 等)现在直接返回 404(#50732、#50671);鉴权方面,Python 和 Rust server 改读同一张路由鉴权级别表(#50559),HiCache 存储凭据从 server info、日志和 gRPC 输出中脱敏(#49761)。依赖 sgl-model-gateway 的 K8s 集成需要迁移。 https://github.com/sgl-project/sglang/pull/50732
4. **TensorRT-LLM 和 Ray 都在补推理的控制面**:TRT-LLM 的解耦服务集群存储(etcd)支持凭据、TLS 和记录签名(#21716),并回收失败或超时的 KV 传输资源(#21909);Ray Serve LLM 启动「按 token 自动扩缩」三连 PR 的第 1 步,由 KV-aware router 跟踪扣除缓存后的 prefill 负载(#67937)。PD 解耦的服务发现安全、按 token 而不是按 QPS 扩缩,是我们推理平台控制面接下来要对标的两个点。 https://github.com/ray-project/ray/pull/67937
5. **Ray core 原生支持寒武纪 MLU 资源**(#66368):继 Ascend NPU 之后,又一家国产加速卡进入 Ray 调度的资源模型;KubeRay autoscaler 修复了把 worker group 副本数缩到 minReplicas 以下的问题(#67332)。 https://github.com/ray-project/ray/pull/66368

---

## 推理引擎动态

### vLLM
**v0.34.0**(2026-11-16,1061 commits)。https://github.com/vllm-project/vllm/releases/tag/v0.34.0
- **破坏性默认值**(运维和平台侧需要逐项核对):
  - 可扩展 KV cache 默认开启,`gpu_memory_utilization` 默认 1.0(#56492)。官方数据:MiniMax-M3 在 H200 上 KV 容量从 433k 增到 672k token,代价是部分模型在并发 128 时 TPOT 上升 6–18%。要恢复旧行为,传 `--gpu-memory-utilization 0.9` 或 `--no-enable-extensible-kv-cache`。**启示**:我们如果用显存比例切分或共享 GPU(例如与 HAMi 类方案配合),升级前必须显式固定这个参数,否则 vLLM 会吃满整卡。 https://github.com/vllm-project/vllm/pull/56492
  - Model Runner V1 删除,设置 `VLLM_USE_V2_MODEL_RUNNER=0` 会直接启动失败(#63373);默认 block size 改为 64(#63231);fp_quant、Marlin W4A8 删除。 https://github.com/vllm-project/vllm/pull/63373
- **进程级 checkpoint/restore**:新增 `/checkpoint/prepare|status|restore` 接口和 `--checkpoint-prepare-on-startup`,由外部编排器(例如 ai-dynamo/snapshot)驱动 CRIU + cuda-checkpoint,Python 和 Rust 前端都支持(#62570)。**启示**:这是推理服务冷启动和缩容到零的新做法,可以评估与我们模型服务的弹性和快速拉起方案结合。 https://github.com/vllm-project/vllm/pull/62570
- **Rust 前端持续补齐**:支持 `--hf-token`、`n>1`、abort、`X-Vllm-Priority` 优先级头,模型目录可从对象存储拉取后传给 Rust 前端(#61788),引擎断连时让在途请求直接失败(#67187)。 https://github.com/vllm-project/vllm/pull/67187
- **PD 解耦和 KV 的容错**:Mooncake 从丢失的 prefill worker 拉取时快速失败(#65575),NIXL 支持从 PP 多段 prefill 拉取 KV(#65336),CPU KV offload 缓冲区不写入 core dump(#67960)。另有一个可配置选项:故障恢复后继续服务未完成的请求(#50265)。 https://github.com/vllm-project/vllm/pull/65575
- **安全**:错误信息中的非法模型名做长度截断(#67765)。

### SGLang
本周无新 release。
- **网关收敛**:先把用户迁移到 sgl-router(#50671),再删除 sgl-model-gateway 目录,包括其 Python/Go 绑定和 k8s manifests(#50732)。 https://github.com/sgl-project/sglang/pull/50732
- **鉴权和安全**:路由鉴权级别统一由一张 JSON 表声明,Python 和 Rust server 共用,改动会在测试中以 diff 形式暴露(#50559);修正错误 HTTP 方法的鉴权检查,并给 `/internal/peer` 加白名单(#50586);HiCache 存储凭据脱敏(#49761);DiffusionServer 入站请求改用 safe_pickle_loads(#49290)。 https://github.com/sgl-project/sglang/pull/50559
- **兼容性**:一次性删除已弃用的 flag、取值和环境变量(#51074),升级前需要核对启动参数。 https://github.com/sgl-project/sglang/pull/51074
- **Ascend NPU 继续大批合入**:GLM-5.3-Flash 支持 A3/A5(#43305)、L2 HiCache 支持 modelslim MLA fp8 KV(#50023)、decode 图编译走 npugraph_ex(#49999)。 https://github.com/sgl-project/sglang/pull/43305

### TensorRT-LLM / TGI / Ollama
- **TensorRT-LLM**:本周无新 release(仍为 v1.4.0rc2)。主线:
  - 解耦集群存储(etcd)支持凭据、TLS 和记录签名,开启签名后拒绝未签名或签名无效的记录(#21716)。 https://github.com/NVIDIA/TensorRT-LLM/pull/21716
  - 失败或超时的解耦 KV 传输会回收资源(#21909),空闲时也会清理超时的 KV 接收(#22419)。
  - KV Cache Manager V2 面向 agentic 流量的优化(#21935)、SSD offload 优化(#21822)。
  - BREAKING:简化 `ModelLoader.load()`(#20711)。 https://github.com/NVIDIA/TensorRT-LLM/pull/21909
- **TGI**:仍为 archived 状态(最后 push 2026-03-21),无更新。
- **Ollama**:窗口内无正式 release(最新 v0.40.17-rc1 发于 11-10)。主线改动集中在 MLX 后端(跨请求槽复用前缀 #19677、批量投机验证 #19663)和工具调用细节,对云原生平台参考价值低。 https://github.com/ollama/ollama/pull/19677

## 模型服务 & 编排

### KServe 上游
本周无新 release,也没有新功能合入,主要是修复:
- **qpext 启动崩溃循环修复**:OTel SDK 升到 v1.45.0 后,与 knative.dev/pkg 的 semconv 版本不一致,导致 queue-proxy 在启动时报 schema URL 冲突后退出(#6627,前置 #6497)。**启示**:我们的 fork 如果跟进了 OTel bump,要同步升级 knative pkg。 https://github.com/kserve/kserve/pull/6627
- llmisvc:只带 `HF_TOKEN` 的 Pod 在升级时不再滚动重建(#6512)。 https://github.com/kserve/kserve/pull/6512
- 安全:mcv 镜像中的 podman 升到 v5.8.8,修复 GHSA-2cvf-wqm6-wr9g(#6609)。 https://github.com/kserve/kserve/pull/6609

### Ray
本周无新 release。
- **Serve LLM 按 token 自动扩缩**(三连 PR 第 1 步):KV router 跟踪扣除缓存后的 prefill 工作量和请求所处阶段,后续两步会把这些指标传给 controller 并新增扩缩策略(#67937)。 https://github.com/ray-project/ray/pull/67937
- **异构加速卡**:core 新增寒武纪 MLU 资源支持(#66368)。 https://github.com/ray-project/ray/pull/66368
- **KubeRay**:autoscaler 不再把 worker group 副本数 patch 到 minReplicas 以下(#67332)。 https://github.com/ray-project/ray/pull/67332
- **Train 健康管理**:WorkerProbe 接入 HealthManager,controller 根据健康判断执行处置(#67915、#67856);删除 local mode(#68239)。 https://github.com/ray-project/ray/pull/67856
- **Serve 可观测**:TracingConfig 在启动时下发到 proxy(#65437)。
- **Sandbox**:沙箱可以提交为新的镜像推送到 registry(#67972),并支持镜像层缓存(#67874),沙箱隔离运行时还在建设中。

### KubeAI
仅一条修复:Infinity 引擎应用容器 securityContext(#795)。 https://github.com/kubeai-project/kubeai/pull/795

## 训练 & 微调
- **Kubeflow Trainer**:Helm chart 支持 controller manager 高可用,新增可选的 PDB、topologySpreadConstraints 和 priorityClassName(#4147);runtime 创建时忽略已删除 TrainJob 的快照(#4373)。 https://github.com/kubeflow/trainer/pull/4147
- **LlamaFactory**:适配 FSDPTurbo(专家归属、CP 梯度修复 #10936),依赖升级到 transformers 5.17,无框架级变化。 https://github.com/hiyouga/LlamaFactory/pull/10936

## 模型生命周期(MLflow / Registry / Feast)
- **Feast**(见摘要 2):
  - 服务间令牌改为签名并验签,Helm 不再内置固定值(修复 #6785)。 https://github.com/feast-dev/feast/commit/b5326fd0811ee162a813f8ea6a09890cb62c147e
  - K8s 令牌解析改用 TokenReview 获取 username、groups 和 namespace。 https://github.com/feast-dev/feast/commit/ff8abe04deb3923d06ac7d83add4d8c94234cfd6
  - 其他:K8s 异步物化报告真实状态(#7153)、feature server 请求指标新增 HTTP 状态类标签、MCP feature 工具支持搜索过滤和在线写入。 https://github.com/feast-dev/feast/pull/7153
- **MLflow**:basic-auth 下 `/v1/traces` 带 `X-Mlflow-Run-Id` 时要求 run 的 update 权限(#27853);支持注册权重存放在 Volume 中的 Unity Catalog 模型(#27625)。其余提交大多是 AI Gateway、trace UI 和定时刷新的模型目录,对平台参考有限。 https://github.com/mlflow/mlflow/pull/27853
- **Kubeflow Hub(原 model-registry)**:只有测试数据和 Go 1.27 升级,无重大更新。

## LLM 评估 & 安全
- **lm-evaluation-harness**:窗口内无提交,无重大更新。
- **garak**:窗口内无提交,无重大更新。
- **OGX(原 llama-stack)**:无新 release。web search 从 tool_runtime 拆成独立的可路由 API,brave/bing/tavily/exa 等后端各自作为 provider(#7014);Responses API 在超出上下文窗口时改为返回 400 而不是 500,关闭截断时直接失败而不是丢弃对话轮次(#6992、#6856)。 https://github.com/ogx-ai/ogx/pull/7014

## 值得跟进
- [ ] 在 vLLM v0.34.0 上验证我们的 GPU 共享和配额场景:可扩展 KV + `gpu_memory_utilization=1.0` 默认值对显存切分的影响,决定平台是否在模板里固定 0.9(#56492)
- [ ] 评估 vLLM checkpoint/restore HTTP 接口 + ai-dynamo/snapshot,能否用于缩容到零后的快速恢复(#62570)
- [ ] 排查自家或客户环境中 Feast Helm 部署是否使用了写死的 intra-communication 值,推动升级(b5326fd)
- [ ] 跟踪 Ray Serve token 扩缩 PR 的第 2、3 步,对比 KServe/KEDA 现有的扩缩指标
- [ ] 如果有 SGLang 集成用到 sgl-model-gateway,规划迁移到 sgl-router(#50732)
